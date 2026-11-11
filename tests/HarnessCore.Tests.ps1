$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$core = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Harness.Core.ps1'
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-HarnessRequiredCapabilities','Register-Harness','Get-Harness','Get-Harnesses','Reset-HarnessRegistry','Resolve-TransferMode',
    'Get-SecretPatterns','Invoke-SecretScan','Protect-TranscriptText','Measure-SecretFindings','Protect-TranscriptEntries',
    'Get-FirstSentence','Format-TranscriptTurn','ConvertTo-HandoffMarkdown','Register-Harnesses','Write-HarnessLog','Install-HarnessSource'))

function New-FakeAdapter([string[]]$Extra = @()) {
    $a = @{}
    foreach ($k in 'Detect','GetProfiles','Launch','ListChats','Export','ImportHandoff') { $a[$k] = { } }
    foreach ($k in $Extra) { $a[$k] = { } }
    return $a
}

# --- registry ---
$script:Harnesses = $null
Reset-HarnessRegistry
Assert (@(Get-Harnesses).Count -eq 0) 'Registry should start empty'
Register-Harness -Name 'claude' -Adapter (New-FakeAdapter)
$h = Get-Harness -Name 'claude'
Assert ($h.Name -eq 'claude' -and $h.Adapter.ContainsKey('Launch')) 'Get-Harness returns registered adapter'
Assert ($null -eq (Get-Harness -Name 'nope')) 'Unknown harness returns null'
Assert (@(Get-Harnesses).Count -eq 1) 'Get-Harnesses count'
Register-Harness -Name 'claude' -Adapter (New-FakeAdapter @('ImportNative'))
Assert (@(Get-Harnesses).Count -eq 1) 'Re-register replaces, not duplicates'
Assert ((Get-Harness -Name 'claude').Adapter.ContainsKey('ImportNative')) 'Re-register replaced adapter'
Assert ((Get-Harness -Name 'CLAUDE').Name -eq 'claude') 'Lookup is case-insensitive'

# --- required capabilities ---
foreach ($missing in 'Detect','GetProfiles','Launch','ListChats','Export','ImportHandoff') {
    $bad = New-FakeAdapter
    $bad.Remove($missing)
    $msg = ''
    try { Register-Harness -Name 'bad' -Adapter $bad } catch { $msg = $_.Exception.Message }
    Assert ($msg -like "*$missing*") "Missing $missing must be rejected, got: $msg"
}
Assert ($null -eq (Get-Harness -Name 'bad')) 'Rejected adapter must not be registered'
$notBlock = New-FakeAdapter
$notBlock['Launch'] = 'not a scriptblock'
Assert-Throws { Register-Harness -Name 'bad' -Adapter $notBlock } 'Non-scriptblock capability must be rejected'
Register-Harness -Name 'minimal' -Adapter (New-FakeAdapter)
Assert ($null -ne (Get-Harness -Name 'minimal')) 'ImportNative is optional'

# --- one broken adapter must not stop the others (or the switcher) ---
$script:LogPath = Join-Path ([IO.Path]::GetTempPath()) ('harness-reg-' + [guid]::NewGuid().ToString('N') + '.log')
function Register-ClaudeHarness { Register-Harness -Name 'claude' -Adapter (New-FakeAdapter) }
function Register-CodexHarness { throw 'codex adapter exploded' }
function Register-AntigravityHarness { Register-Harness -Name 'antigravity' -Adapter (New-FakeAdapter) }
try {
    Register-Harnesses
    Assert ($null -ne (Get-Harness -Name 'claude') -and $null -ne (Get-Harness -Name 'antigravity') -and $null -eq (Get-Harness -Name 'codex')) 'healthy adapters registered, broken one skipped'
    $logText = [IO.File]::ReadAllText($script:LogPath)
    Assert ($logText -like '*Register-CodexHarness*codex adapter exploded*') "failure is logged: $logText"
} finally {
    Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Register-ClaudeHarness, Function:\Register-CodexHarness, Function:\Register-AntigravityHarness
    $script:LogPath = $null
}

# --- installing src\ next to the installed script ---
$inst = New-TestTempDir
try {
    $srcNew = Join-Path $inst 'clone\src'
    New-Item -ItemType Directory -Path $srcNew -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $srcNew 'A.ps1'), 'new A')
    [IO.File]::WriteAllText((Join-Path $srcNew 'B.ps1'), 'new B')
    $scriptNew = Join-Path $inst 'clone\ClaudeSwitcher.ps1'
    [IO.File]::WriteAllText($scriptNew, "line1`r`nline2")
    $home1 = Join-Path $inst 'LocalApp\.switcher'
    New-Item -ItemType Directory -Path (Join-Path $home1 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $home1 'src\A.ps1'), 'old A')
    [IO.File]::WriteAllText((Join-Path $home1 'src\Gone.ps1'), 'removed upstream')

    # the user kept the installed script: its "last install" record is not this version -> leave src alone
    [IO.File]::WriteAllText((Join-Path $home1 'ClaudeSwitcher.base.ps1'), 'an older version')
    Assert ((Install-HarnessSource -SourceDir $srcNew -SwitcherHome $home1 -ScriptPath $scriptNew) -eq 'kept') 'kept installed script: src is not touched'
    Assert ([IO.File]::ReadAllText((Join-Path $home1 'src\A.ps1')) -eq 'old A' -and (Test-Path -LiteralPath (Join-Path $home1 'src\Gone.ps1'))) 'src unchanged when the user kept their copy'

    # installed this version (the base record equals the new script, line endings aside)
    [IO.File]::WriteAllText((Join-Path $home1 'ClaudeSwitcher.base.ps1'), "line1`nline2")
    Assert ((Install-HarnessSource -SourceDir $srcNew -SwitcherHome $home1 -ScriptPath $scriptNew) -eq 'installed') 'installed'
    Assert ([IO.File]::ReadAllText((Join-Path $home1 'src\A.ps1')) -eq 'new A' -and (Test-Path -LiteralPath (Join-Path $home1 'src\B.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $home1 'src\Gone.ps1'))) 'src replaced, stale file gone'
    Assert (-not (Test-Path -LiteralPath (Join-Path $home1 'src.new')) -and -not (Test-Path -LiteralPath (Join-Path $home1 'src.old'))) 'no temp folders left behind'

    # a copy that fails halfway must not cost the existing src: lock one source file exclusively
    [IO.File]::WriteAllText((Join-Path $srcNew 'A.ps1'), 'newer A')
    $lock = [IO.File]::Open((Join-Path $srcNew 'B.ps1'), 'Open', 'ReadWrite', 'None')
    try {
        $failed = Install-HarnessSource -SourceDir $srcNew -SwitcherHome $home1 -ScriptPath $scriptNew
    } finally { $lock.Dispose() }
    Assert ($failed -eq 'failed') "failed copy is reported: $failed"
    Assert ([IO.File]::ReadAllText((Join-Path $home1 'src\A.ps1')) -eq 'new A' -and (Test-Path -LiteralPath (Join-Path $home1 'src\B.ps1'))) 'the previous src is still complete'
    Assert (-not (Test-Path -LiteralPath (Join-Path $home1 'src.new'))) 'half-copied src.new is cleaned up'

    # only a folder called .switcher is ever replaced
    $other = Join-Path $inst 'LocalApp\NotSwitcher'
    New-Item -ItemType Directory -Path (Join-Path $other 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $other 'src\keep.txt'), 'x')
    [IO.File]::WriteAllText((Join-Path $other 'ClaudeSwitcher.base.ps1'), "line1`nline2")
    Assert ((Install-HarnessSource -SourceDir $srcNew -SwitcherHome $other -ScriptPath $scriptNew) -eq 'skipped' -and (Test-Path -LiteralPath (Join-Path $other 'src\keep.txt'))) 'other folders are never touched'
} finally { Remove-TestTempDir $inst }

# --- transfer mode ---
Reset-HarnessRegistry
Register-Harness -Name 'claude' -Adapter (New-FakeAdapter @('ImportNative'))
Register-Harness -Name 'codex' -Adapter (New-FakeAdapter @('ImportNative','ImportExternalClaude'))
Register-Harness -Name 'antigravity' -Adapter (New-FakeAdapter)
Assert ((Resolve-TransferMode -Source 'claude' -Target 'claude') -eq 'native') 'same harness with native'
Assert ((Resolve-TransferMode -Source 'antigravity' -Target 'antigravity') -eq 'handoff') 'same harness without native'
Assert ((Resolve-TransferMode -Source 'codex' -Target 'claude') -eq 'handoff') 'codex to claude is handoff'
Assert ((Resolve-TransferMode -Source 'claude' -Target 'antigravity') -eq 'handoff') 'claude to antigravity is handoff'
Assert ((Resolve-TransferMode -Source 'claude' -Target 'codex') -eq 'codex-import') 'claude to codex uses official import'
Assert ((Resolve-TransferMode -Source 'antigravity' -Target 'codex') -eq 'handoff') 'only claude source uses codex import'
Register-Harness -Name 'codex' -Adapter (New-FakeAdapter @('ImportNative'))
Assert ((Resolve-TransferMode -Source 'claude' -Target 'codex') -eq 'handoff') 'no ImportExternalClaude falls back to handoff'
Assert-Throws { Resolve-TransferMode -Source 'claude' -Target 'ghost' } 'Unknown target must throw'

# --- redaction (fake secrets are assembled at run time so secret scanners do not flag this file) ---
$pad = 'A' * 30
$fake = @{
    anthropic = 'sk-' + 'ant-TEST' + $pad
    openai    = 'sk-' + 'proj' + $pad
    ghp       = 'gh' + 'p_' + $pad
    gho       = 'gh' + 'o_' + $pad
    ghpat     = 'github' + '_pat_' + $pad
    aws       = 'AK' + 'IA' + ('B' * 16)
    slack     = 'xo' + 'xb-' + '1234567890-abcdefghij'
    google    = 'AI' + 'za' + ('C' * 35)
    bearer    = 'Bearer ' + 'abcdefghijklmnop1234567890'
}
foreach ($k in $fake.Keys) {
    $text = "before $($fake[$k]) after"
    $out = Protect-TranscriptText $text
    Assert ($out -like 'before*after' -and -not $out.Contains($fake[$k].Substring(8)) -and $out.Contains('[REDACTED]')) "pattern $k not redacted: $out"
    Assert ((Measure-SecretFindings -Text $text) -eq 1) "pattern $k not counted"
}
$pem = "x`n-----BEGIN RSA PRIVATE" + " KEY-----`nMIIEabc`nDEFghi`n-----END RSA PRIVATE" + " KEY-----`ny"
$out = Protect-TranscriptText $pem
Assert ($out -eq "x`n[REDACTED]`ny") "private key block: $out"
$envText = "DB_PASSWORD=hunter2hunter2`nexport GITHUB_TOKEN = abcdef`nNORMAL=fine`nMY_SECRET_KEY=zzz"
$out = Protect-TranscriptText $envText
Assert ($out -eq "DB_PASSWORD=[REDACTED]`nexport GITHUB_TOKEN = [REDACTED]`nNORMAL=fine`nMY_SECRET_KEY=[REDACTED]") "KEY=value lines: $out"
Assert ((Measure-SecretFindings -Text $envText) -eq 3) 'KEY=value lines counted'
$plain = "Use sk-learn, the key idea, and Bearer tokens in general. Path C:\a\b and https://x.y/z?k=v"
Assert ((Protect-TranscriptText $plain) -eq $plain) 'plain text must be unchanged'
Assert ((Measure-SecretFindings -Text $plain) -eq 0) 'plain text has no findings'
Assert ((Measure-SecretFindings -Text (Protect-TranscriptText $envText)) -eq 0) 'redacted text has no findings'
$twice = "a $($fake.anthropic) b $($fake.ghp)"
Assert ((Protect-TranscriptText $twice) -eq 'a [REDACTED] b [REDACTED]') 'multiple secrets in one line'
$mfile = Join-Path ([IO.Path]::GetTempPath()) ('measure-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    [IO.File]::WriteAllText($mfile, "k $($fake.aws)")
    $before = [IO.File]::ReadAllText($mfile)
    Assert ((Measure-SecretFindings -Path $mfile) -eq 1) 'Measure by path'
    Assert ([IO.File]::ReadAllText($mfile) -eq $before) 'Measure must not modify the file'
} finally { Remove-Item -LiteralPath $mfile -Force -ErrorAction SilentlyContinue }

$mid = 'cd app && TOKEN=abcdef123 npm run x'
Assert ((Protect-TranscriptText $mid) -eq 'cd app && TOKEN=[REDACTED] npm run x') "mid-line KEY=value: $(Protect-TranscriptText $mid)"
Assert ((Protect-TranscriptText 'run API_KEY="a b c" now') -eq 'run API_KEY=[REDACTED] now') 'quoted value with spaces, mid-line'
Assert ((Protect-TranscriptText '{"password": "hunter2", "user": "bob"}') -eq '{"password": "[REDACTED]", "user": "bob"}') 'JSON password value'
Assert ((Protect-TranscriptText '{"accessToken":"abc.def","client_secret" : "x\"y"}') -eq '{"accessToken":"[REDACTED]","client_secret" : "[REDACTED]"}') 'JSON camelCase and snake_case keys, escaped quote'
Assert ((Protect-TranscriptText 'mysql --password=hunter2 --user=bob') -eq 'mysql --password=[REDACTED] --user=bob') '--password=value'
Assert ((Protect-TranscriptText 'curl --api-key=zzz9 http://x') -eq 'curl --api-key=[REDACTED] http://x') '--api-key=value'
foreach ($keep in '{"tokenizer": "gpt"}', '{"max_tokens": 100}', '{"monkey": "banana", "hotkey": "Ctrl+S"}', 'run --tokenizer=gpt --keys=3', 'x && monkey=banana') {
    Assert ((Protect-TranscriptText $keep) -eq $keep) "must stay unchanged: $keep"
    Assert ((Measure-SecretFindings -Text $keep) -eq 0) "no finding for: $keep"
}
Assert ((Measure-SecretFindings -Text 'a && TOKEN=x b && PASSWORD=y --password=z {"secret":"q"}') -eq 4) 'all four new shapes counted once each'
$notEnv ="hotkey = Ctrl+S`nmonkey = banana`nAPI_KEY=abc"
Assert ((Protect-TranscriptText $notEnv) -eq "hotkey = Ctrl+S`nmonkey = banana`nAPI_KEY=[REDACTED]") 'only UPPER_SNAKE names are treated as secrets'
Assert ((Measure-SecretFindings -Text $notEnv) -eq 1) 'hotkey and monkey are not findings'

# --- transcript ---
function New-Entries([int]$Turns) {
    $e = @()
    for ($i = 1; $i -le $Turns; $i++) {
        $e += @{ role = 'user'; text = "Question $i. Second sentence of $i." }
        $e += @{ role = 'assistant'; text = "Answer $i body" }
    }
    return $e
}
$entries = @(New-Entries 50)
$md = ConvertTo-HandoffMarkdown -Entries $entries -Harness 'claude' -Title 'My chat' -Cwd 'C:\proj' -Branch 'feature/x' -Artifacts @('task.md','plan.md')
Assert ($md -match '(?m)^# .*My chat') 'title heading'
Assert ($md.Contains('claude') -and $md.Contains('C:\proj') -and $md.Contains('feature/x')) 'header fields'
Assert ($md.Contains('task.md') -and $md.Contains('plan.md')) 'artifacts listed'
Assert ($md.Contains('Answer 50 body') -and $md.Contains('Answer 11 body') -and $md.Contains('Question 11. Second sentence of 11.')) 'last 40 turns kept in full'
Assert (-not $md.Contains('Answer 10 body')) 'earlier assistant text dropped'
Assert (-not $md.Contains('Second sentence of 10.')) 'earlier turns only keep the first sentence'
Assert ($md.Contains('Question 10.') -and $md.Contains('Question 1.')) 'earlier turns summarised mechanically'
$emptyMd = ConvertTo-HandoffMarkdown -Entries @() -Harness 'claude' -Title 'Empty chat'
Assert ($emptyMd.Contains('# Handoff: Empty chat')) 'empty transcript still gives a handoff file'
$nullMd = ConvertTo-HandoffMarkdown -Entries $null -Harness 'claude' -Title 'Null chat'
Assert ($nullMd.Contains('# Handoff: Null chat')) 'null entries tolerated'
Assert (@(Protect-TranscriptEntries -Entries @()).Count -eq 0 -and @(Protect-TranscriptEntries -Entries $null).Count -eq 0) 'Protect-TranscriptEntries accepts empty and null'
$small = ConvertTo-HandoffMarkdown -Entries @(New-Entries 3) -Harness 'claude' -Title 't'
Assert ($small.Contains('Second sentence of 1.') -and $small.Contains('Answer 1 body')) 'short chat keeps everything'
$custom = ConvertTo-HandoffMarkdown -Entries $entries -Harness 'claude' -Title 't' -KeepTurns 5
Assert ($custom.Contains('Answer 46 body') -and -not $custom.Contains('Answer 45 body')) 'KeepTurns respected'

$long = 'x' * 5000
$toolEntries = @(
    @{ role = 'user'; text = 'run it' },
    @{ role = 'tool'; text = ''; tool = @{ name = 'Bash'; arg = "ls -la`nsecond line"; output = $long } },
    @{ role = 'tool'; text = ''; tool = @{ name = 'Read'; arg = 'C:\a\b.txt'; output = 'short' } }
)
$tmd = ConvertTo-HandoffMarkdown -Entries $toolEntries -Harness 'claude' -Title 't'
Assert ($tmd -match '(?m)^- tool `Bash`: ls -la second line$') "tool call one-liner: $tmd"
Assert ($tmd -match '(?m)^- tool `Read`: C:\\a\\b.txt$') 'second tool one-liner'
Assert ($tmd.Contains('x' * 2048) -and -not $tmd.Contains('x' * 2049)) 'tool output cut at 2 KB'
Assert ($tmd.Contains('truncated')) 'truncation is marked'
Assert ($tmd.Contains('short')) 'short output kept'

$cut = @(@{ role = 'user'; text = 'go' }, @{ role = 'tool'; text = ''; tool = @{ name = 'Bash'; arg = ('y' * 190) + $fake.anthropic; output = ('x' * 2029) + $fake.anthropic } })
$cmd = ConvertTo-HandoffMarkdown -Entries $cut -Harness 'claude' -Title 't'
Assert (-not $cmd.Contains('sk-' + 'ant-T') -and -not $cmd.Contains('TEST')) 'secret straddling a truncation boundary must not leak'

$secretEntries = @(@{ role = 'user'; text = "my key is $($fake.anthropic)" }, @{ role = 'assistant'; text = "token $($fake.ghp)" })
$smd = ConvertTo-HandoffMarkdown -Entries $secretEntries -Harness 'claude' -Title 't'
Assert (-not $smd.Contains('TEST' + $pad) -and -not $smd.Contains($pad) -and $smd.Contains('[REDACTED]')) 'handoff markdown is always redacted'
$prot = @(Protect-TranscriptEntries -Entries (@($secretEntries) + @(@{ role = 'tool'; text = ''; tool = @{ name = 'Bash'; arg = "echo $($fake.aws)"; output = "o $($fake.slack)" } })))
Assert ($prot.Count -eq 3 -and -not $prot[0].text.Contains($pad) -and -not $prot[2].tool.arg.Contains('BBBB') -and -not $prot[2].tool.output.Contains('1234567890')) 'Protect-TranscriptEntries covers text, arg, output'
Assert ($secretEntries[0].text.Contains($pad)) 'Protect-TranscriptEntries must not mutate its input'

# --- SQLite (fixture is created with winsqlite3 itself, read-write, in a temp folder only) ---
. (Import-TestFunctions -Files @((Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Harness.Sqlite.ps1')) -Names @('Initialize-WinSqlite','ConvertTo-SqliteUtf8','Open-SqliteReadOnly','Close-Sqlite','Invoke-SqliteQuery','Copy-SqliteSnapshot'))
$sqlDir = New-TestTempDir
try {
    Initialize-WinSqlite
    $accent = [string][char]0xE9
    $folder = Join-Path $sqlDir ('d' + $accent + 'p')
    New-Item -ItemType Directory -Path $folder | Out-Null
    $dbPath = Join-Path $folder 'fixture.sqlite'
    $title = 'Ti' + [char]0xEA + 'u ' + [char]0x65E5 + [char]0x672C
    $h = [IntPtr]::Zero
    Assert (([HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 $dbPath), [ref]$h, 6, [IntPtr]::Zero)) -eq 0) 'fixture open'
    $ddl = "create table threads(id text, title text, n integer, f real, data blob, nul_col text);" +
           "insert into threads values('t1','$title',42,1.5,x'0001FF80',null);" +
           "insert into threads values('t2','plain',-7,0.0,x'',null);"
    $execRc = [HarnessWinSqlite]::sqlite3_exec($h, (ConvertTo-SqliteUtf8 $ddl), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $execErr = [HarnessWinSqlite]::Err($h)
    [void][HarnessWinSqlite]::sqlite3_close($h)
    Assert ($execRc -eq 0) "fixture ddl rc=$execRc $execErr"

    $snap = Copy-SqliteSnapshot -Path $dbPath
    $snapDir = Split-Path -Parent $snap
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert ($snap -ne $dbPath -and ([IO.Path]::GetFullPath($snap)).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) 'snapshot lives in a different temp folder'
    $db = Open-SqliteReadOnly -Path $snap
    try {
        $rows = @(Invoke-SqliteQuery -Handle $db -Sql 'select id,title,n,f,data,nul_col from threads order by id')
        Assert ($rows.Count -eq 2) "row count $($rows.Count)"
        Assert ($rows[0].id -eq 't1' -and $rows[0].title -eq $title) 'unicode text via UTF-16 column'
        Assert ($rows[0].n -eq 42 -and $rows[1].n -eq -7 -and $rows[0].n -is [int64]) 'integers'
        Assert ($rows[0].f -eq 1.5) 'real'
        Assert (($rows[0].data -join ',') -eq '0,1,255,128' -and $rows[0].data -is [byte[]]) 'blob bytes'
        Assert ($rows[1].data.Length -eq 0) 'empty blob'
        Assert ($null -eq $rows[0].nul_col) 'NULL'
        Assert-Throws { Invoke-SqliteQuery -Handle $db -Sql "insert into threads(id) values('x')" | Out-Null } 'writes must fail on a read-only handle'
        Assert-Throws { Invoke-SqliteQuery -Handle $db -Sql 'select * from missing_table' | Out-Null } 'bad SQL must throw'
        Assert (@(Invoke-SqliteQuery -Handle $db -Sql 'select count(*) as c from threads')[0].c -eq 2) 'still 2 rows after rejected insert'
    } finally { Close-Sqlite -Handle $db }
    Assert-Throws { Open-SqliteReadOnly -Path (Join-Path $sqlDir 'nope.sqlite') } 'missing file must throw'

    $walSource = Join-Path $folder 'wal.sqlite'
    Copy-Item -LiteralPath $dbPath -Destination $walSource
    [IO.File]::WriteAllBytes($walSource + '-wal', [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes($walSource + '-shm', [byte[]](4, 5))
    $walSnap = Copy-SqliteSnapshot -Path $walSource
    Assert ((Test-Path -LiteralPath ($walSnap + '-wal')) -and (Test-Path -LiteralPath ($walSnap + '-shm'))) 'snapshot copies -wal and -shm'
    Assert ((Get-Item -LiteralPath $dbPath).Length -gt 0 -and -not (Test-Path -LiteralPath ($dbPath + '-wal'))) 'original untouched'
    Remove-Item -LiteralPath $snapDir, (Split-Path -Parent $walSnap) -Recurse -Force
} finally { Remove-TestTempDir $sqlDir }

Write-Output 'PASS: helper loading, registry, capability validation, transfer mode, redaction, handoff transcript, read-only SQLite.'
