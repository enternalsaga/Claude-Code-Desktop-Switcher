$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
$core = Join-Path $root 'src\Harness.Core.ps1'
$sqlite = Join-Path $root 'src\Harness.Sqlite.ps1'
$appServer = Join-Path $root 'src\Harness.Codex.AppServer.ps1'
. (Import-TestFunctions -Files @($appServer) -Names @('Start-CodexAppServer', 'Read-CodexLine', 'Invoke-CodexRpc', 'Get-CodexStderrTail', 'Wait-CodexNotification', 'Stop-CodexAppServer'))

# ---------------------------------------------------------------- K1: app-server client against a fake server
$fixture = New-TestTempDir
try {
    $fake = Join-Path $fixture 'fake-app-server.ps1'
    @'
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if (-not $line.Trim()) { continue }
    $m = $line | ConvertFrom-Json
    switch ($m.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":' + $m.id + ',"result":{"codexHome":"' + ($env:CODEX_HOME -replace '\\', '/') + '"}}') }
        'initialized' { }
        'echo' {
            [Console]::Out.WriteLine('{"method":"noise/first","params":{}}')
            [Console]::Out.WriteLine('{"id":999,"result":"someone else"}')
            [Console]::Out.WriteLine('{"id":' + $m.id + ',"result":{"said":"' + $m.params.text + '"}}')
        }
        'boom' { [Console]::Out.WriteLine('{"id":' + $m.id + ',"error":{"code":-32000,"message":"nope"}}') }
        'notify-later' {
            [Console]::Out.WriteLine('{"id":' + $m.id + ',"result":{}}')
            [Console]::Out.WriteLine('{"method":"thing/done","params":{"importId":"abc"}}')
        }
        'silent' { }
    }
}
'@ | Set-Content -LiteralPath $fake -Encoding ASCII

    $psExe = (Get-Command powershell.exe).Source
    $srv = Start-CodexAppServer -CodexHome $fixture -CodexExe $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $fake)
    try {
        $init = Invoke-CodexRpc -Server $srv -Method 'initialize' -Params @{ clientInfo = @{ name = 't'; version = '1' } } -TimeoutSec 30
        Assert ($init.codexHome -like '*harness-test-*') 'CODEX_HOME must reach the child process'
        Invoke-CodexRpc -Server $srv -Method 'initialized' -Notify

        $e = Invoke-CodexRpc -Server $srv -Method 'echo' -Params @{ text = 'hi' } -TimeoutSec 30
        Assert ($e.said -eq 'hi') 'response matched by id, ignoring other ids and notifications'
        Assert (@($srv.Notes | Where-Object { $_.method -eq 'noise/first' }).Count -eq 1) 'non-matching notification is kept'

        $threw = $null
        try { Invoke-CodexRpc -Server $srv -Method 'boom' -TimeoutSec 30 } catch { $threw = $_.Exception.Message }
        Assert ($threw -like '*nope*') 'JSON-RPC error becomes an exception'

        [void](Invoke-CodexRpc -Server $srv -Method 'notify-later' -TimeoutSec 30)
        $n = Wait-CodexNotification -Server $srv -Method 'thing/done' -TimeoutSec 30
        Assert ($n.params.importId -eq 'abc') 'Wait-CodexNotification finds a notification that arrives after the response'

        $threw = $null
        try { Invoke-CodexRpc -Server $srv -Method 'silent' -TimeoutSec 2 } catch { $threw = $_.Exception.Message }
        Assert ($threw -like '*timed out*') 'timeout throws'
        Assert ($null -eq (Wait-CodexNotification -Server $srv -Method 'never/comes' -TimeoutSec 1)) 'missing notification returns $null'

        # the pending read from the timeout must not break the next request
        $again = Invoke-CodexRpc -Server $srv -Method 'echo' -Params @{ text = 'again' } -TimeoutSec 30
        Assert ($again.said -eq 'again') 'client keeps working after a timeout'
    } finally {
        Stop-CodexAppServer -Server $srv
    }
    Assert $srv.Proc.HasExited 'Stop-CodexAppServer ends its own process'
} finally {
    Remove-TestTempDir $fixture
}

# ---------------------------------------------------------------- K2: listing chats from state_5.sqlite
. (Import-TestFunctions -Files @($sqlite) -Names @('Initialize-WinSqlite', 'ConvertTo-SqliteUtf8', 'Open-SqliteReadOnly', 'Close-Sqlite', 'Invoke-SqliteQuery', 'Copy-SqliteSnapshot'))
$chats = Join-Path $root 'src\Harness.Codex.Chats.ps1'
. (Import-TestFunctions -Files @($chats) -Names @('ConvertFrom-CodexPath', 'Resolve-CodexRolloutFile', 'Get-CodexChats'))

# Creates a fixture state_5.sqlite with winsqlite3 itself (read-write, temp folder only), same columns the code reads.
function New-CodexStateFixture {
    param([string]$Path, [string[]]$InsertSql)
    Initialize-WinSqlite
    $h = [IntPtr]::Zero
    Assert (([HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 $Path), [ref]$h, 6, [IntPtr]::Zero)) -eq 0) 'fixture open'
    $ddl = 'create table threads (id text primary key, rollout_path text not null, created_at integer not null default 0, updated_at integer not null default 0, source text not null default '''', model_provider text not null default ''openai'', cwd text not null default '''', title text not null default '''', archived integer not null default 0, cli_version text not null default '''', thread_source text, preview text not null default '''', name text, updated_at_ms integer, first_user_message text not null default '''');' +
        'create table thread_spawn_edges (parent_thread_id text not null, child_thread_id text not null primary key, status text not null);' + ($InsertSql -join ';') + ';'
    $rc = [HarnessWinSqlite]::sqlite3_exec($h, (ConvertTo-SqliteUtf8 $ddl), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $err = [HarnessWinSqlite]::Err($h)
    [void][HarnessWinSqlite]::sqlite3_close($h)
    Assert ($rc -eq 0) "fixture ddl: $err"
}

Assert ((ConvertFrom-CodexPath '\\?\C:\a\b') -eq 'C:\a\b') 'strip extended prefix'
Assert ((ConvertFrom-CodexPath 'C:\a\b') -eq 'C:\a\b') 'plain path untouched'
Assert ((ConvertFrom-CodexPath $null) -eq '') 'null path gives empty string'

$fixture = New-TestTempDir
try {
    $codexHome = Join-Path $fixture 'codexhome'
    $sess = Join-Path $codexHome 'sessions\2026\11\11'
    New-Item -ItemType Directory -Path $sess -Force | Out-Null
    $plain = Join-Path $sess 'rollout-2026-11-11T10-00-00-aaaaaaaa-0000-0000-0000-000000000001.jsonl'
    $zst = Join-Path $sess 'rollout-2026-11-11T09-00-00-aaaaaaaa-0000-0000-0000-000000000002.jsonl.zst'
    Set-Content -LiteralPath $plain -Value '{}' -Encoding ASCII
    Set-Content -LiteralPath $zst -Value 'x' -Encoding ASCII
    Assert ((Resolve-CodexRolloutFile $plain) -eq $plain) 'existing path is returned'
    Assert ((Resolve-CodexRolloutFile ($zst -replace '\.zst$', '')) -eq $zst) 'DB path without .zst finds the .zst file'
    Assert ($null -eq (Resolve-CodexRolloutFile (Join-Path $sess 'missing.jsonl'))) 'missing rollout gives $null'

    $zstDbPath = $zst -replace '\.zst$', ''   # what Codex's DB stores after compressing the rollout
    $sql = @(
        "insert into threads(id,rollout_path,source,model_provider,cwd,title,thread_source,updated_at,updated_at_ms,name,cli_version) values('aaaaaaaa-0000-0000-0000-000000000001','\\?\$plain','vscode','openai','\\?\C:\work\demo','First message of the chat','user',1700000000,1700000000123,'Named chat','0.167.1')",
        "insert into threads(id,rollout_path,source,model_provider,cwd,title,thread_source,updated_at,updated_at_ms) values('aaaaaaaa-0000-0000-0000-000000000002','$zstDbPath','exec','codex_local_access','C:\work\other','Exec chat','user',1700000100,NULL)",
        "insert into threads(id,rollout_path,source,thread_source,updated_at,updated_at_ms) values('aaaaaaaa-0000-0000-0000-000000000003','C:\none.jsonl','{""subagent"":{""thread_spawn"":{}}}','subagent',1700000200,1700000200000)",
        "insert into threads(id,rollout_path,source,thread_source,updated_at,updated_at_ms,archived) values('aaaaaaaa-0000-0000-0000-000000000004','C:\gone.jsonl','vscode','user',1700000300,1700000300000,1)",
        "insert into threads(id,rollout_path,source,thread_source,updated_at,updated_at_ms,title) values('aaaaaaaa-0000-0000-0000-000000000005','C:\child.jsonl','vscode','agent_created_thread',1700000400,1700000400000,'Child chat')",
        "insert into thread_spawn_edges values('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000005','open')"
    )
    New-CodexStateFixture -Path (Join-Path $codexHome 'state_5.sqlite') -InsertSql $sql
    $profile = [pscustomobject]@{ Harness = 'codex'; Id = 'fx'; Name = 'Fixture'; IsDefault = $false; CodexHome = $codexHome; UserDataDir = $null; Pid = $null }

    $list = @(Get-CodexChats -Profile $profile)
    Assert ($list.Count -eq 3) "3 visible chats expected (no subagent, no archived), got $($list.Count)"
    Assert ($list[0].ChatId -eq 'aaaaaaaa-0000-0000-0000-000000000005') 'newest first (updated_at_ms, falling back to updated_at*1000)'
    $first = $list | Where-Object ChatId -eq 'aaaaaaaa-0000-0000-0000-000000000001'
    Assert ($first.Title -eq 'Named chat') 'user-set name wins over the first message'
    Assert ($first.Cwd -eq 'C:\work\demo') 'extended prefix removed from cwd'
    Assert ($first.RolloutPath -eq $plain) 'extended prefix removed from rollout path'
    Assert ($first.Source -eq 'vscode' -and $first.ModelProvider -eq 'openai') 'source and provider carried'
    Assert ($first.Activity -eq 1700000000123) 'Activity is updated_at_ms'
    Assert ($first.Profile.Id -eq 'fx') 'chat knows its profile'
    $exec = $list | Where-Object ChatId -eq 'aaaaaaaa-0000-0000-0000-000000000002'
    Assert ($exec.Source -eq 'exec') 'exec threads are listed too'
    Assert ($exec.Title -eq 'Exec chat') 'title falls back to the stored title'
    Assert ($exec.RolloutPath -eq $zst) "rollout path resolved to the real .zst file: got [$($exec.RolloutPath)] want [$zst]"
    Assert ($exec.Activity -eq 1700000100000) 'Activity falls back to updated_at*1000'
    $child = $list | Where-Object ChatId -eq 'aaaaaaaa-0000-0000-0000-000000000005'
    Assert ($child.Parent -eq 'aaaaaaaa-0000-0000-0000-000000000001') 'Parent comes from thread_spawn_edges'
    Assert ($first.HasRollout -eq $true -and $exec.HasRollout -eq $true -and $child.HasRollout -eq $false) 'HasRollout says whether the rollout file is on disk'

    $empty = [pscustomobject]@{ Harness = 'codex'; Id = 'none'; Name = 'None'; IsDefault = $false; CodexHome = (Join-Path $fixture 'nodb'); UserDataDir = $null; Pid = $null }
    Assert (@(Get-CodexChats -Profile $empty).Count -eq 0) 'profile without a database lists nothing'
} finally {
    Remove-TestTempDir $fixture
}

# ---------------------------------------------------------------- K3: rollout transcript, export, native import
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-HarnessRequiredCapabilities', 'Register-Harness', 'Get-Harness', 'Reset-HarnessRegistry', 'Register-Harnesses',
    'Get-BytesSha256Hex', 'Get-FileSha256Hex', 'Test-BundleEntryName', 'New-HarnessBundle', 'Read-ZipEntryBytes', 'Read-HarnessBundle', 'Get-HarnessBundleLimits', 'Copy-ZipEntryChecked', 'ConvertTo-CwdRef', 'Get-HarnessMachineInfo', 'Get-HarnessPathRoots',
    'Get-SecretPatterns', 'Invoke-SecretScan', 'Protect-TranscriptText', 'Measure-SecretFindings', 'Protect-TranscriptEntries', 'Get-FirstSentence', 'Format-TranscriptTurn', 'ConvertTo-HandoffMarkdown'))
. (Import-TestFunctions -Files @($chats) -Names @('ConvertTo-CodexToolOutput', 'Get-CodexToolArg', 'Test-CodexSystemMessage', 'ConvertFrom-CodexRollout', 'ConvertFrom-CodexItems',
    'Get-CodexThreadRow', 'Get-CodexRolloutRelPath', 'Get-CodexTranscriptEntries', 'Export-CodexChat', 'Get-CodexConfigProvider', 'Test-CodexProviderSupported', 'Import-CodexNative', 'Test-CodexImportNeedsClose'))

$fixture = New-TestTempDir
try {
    $fakeKey = 'sk-' + 'ant-TEST' + ('Z' * 30)
    $threadId = 'bbbbbbbb-0000-0000-0000-000000000001'
    $rolloutName = "rollout-2026-11-11T10-00-00-$threadId.jsonl"
    $srcHome = Join-Path $fixture 'srchome'
    $srcSess = Join-Path $srcHome 'sessions\2026\11\11'
    New-Item -ItemType Directory -Path $srcSess -Force | Out-Null
    $rollout = Join-Path $srcSess $rolloutName
    function J($o) { $o | ConvertTo-Json -Depth 8 -Compress }
    $lines = @(
        (J @{ timestamp = 't0'; type = 'session_meta'; payload = @{ id = $threadId; cwd = 'C:\work\demo' } }),
        (J @{ timestamp = 't1'; type = 'response_item'; payload = @{ type = 'message'; role = 'developer'; content = @(@{ type = 'input_text'; text = 'You are Codex' }) } }),
        (J @{ timestamp = 't2'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = "# AGENTS.md instructions`n<INSTRUCTIONS>rules</INSTRUCTIONS>" }) } }),
        (J @{ timestamp = 't3'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = '<environment_context><cwd>C:\work</cwd></environment_context>' }) } }),
        (J @{ timestamp = 't4'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = "Fix the login bug. key=$fakeKey" }) } }),
        (J @{ timestamp = 't5'; type = 'response_item'; payload = @{ type = 'reasoning'; summary = @(); encrypted_content = 'gAAAA' } }),
        (J @{ timestamp = 't6'; type = 'response_item'; payload = @{ type = 'function_call'; name = 'shell'; arguments = '{"cmd":"git status","cwd":"C:\\work"}'; call_id = 'c1' } }),
        (J @{ timestamp = 't7'; type = 'response_item'; payload = @{ type = 'function_call_output'; call_id = 'c1'; output = 'On branch main' } }),
        (J @{ timestamp = 't8'; type = 'response_item'; payload = @{ type = 'custom_tool_call'; name = 'exec'; input = "text(await tools.exec_command({cmd:'ls'}))"; call_id = 'c2' } }),
        (J @{ timestamp = 't9'; type = 'response_item'; payload = @{ type = 'custom_tool_call_output'; call_id = 'c2'; output = @(@{ type = 'input_text'; text = 'Script completed' }, @{ type = 'input_text'; text = 'a.txt' }) } }),
        (J @{ timestamp = 't10'; type = 'event_msg'; payload = @{ type = 'token_count'; info = @{} } }),
        'this line is not json',
        (J @{ timestamp = 't11'; type = 'response_item'; payload = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Fixed it.' }) } })
    )
    [IO.File]::WriteAllText($rollout, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))

    $entries = @(ConvertFrom-CodexRollout -Path $rollout)
    Assert ($entries.Count -eq 4) "expected user, 2 tools, assistant; got $($entries.Count): $(($entries | ForEach-Object { $_.role }) -join ',')"
    Assert ($entries[0].role -eq 'user' -and $entries[0].text -like 'Fix the login bug*') 'real user message kept; AGENTS.md, environment_context, developer and reasoning dropped'
    Assert ($entries[1].role -eq 'tool' -and $entries[1].tool.name -eq 'shell' -and $entries[1].tool.arg -eq 'git status' -and $entries[1].tool.output -eq 'On branch main') 'function_call paired with its output by call_id; arg is the command'
    Assert ($entries[2].tool.name -eq 'exec' -and $entries[2].tool.arg -like 'text(await*' -and $entries[2].tool.output -eq "Script completed`na.txt") 'custom_tool_call paired with array output'
    Assert ($entries[3].role -eq 'assistant' -and $entries[3].text -eq 'Fixed it.') 'assistant message kept'
    Assert ($entries[0].ts -eq 't4') 'timestamp carried'
    Assert (Test-CodexSystemMessage '  <environment_context>x') 'environment_context is a system message'
    Assert (-not (Test-CodexSystemMessage 'Please read <environment_context> docs')) 'only a leading tag counts'

    # items from app-server (used for .zst rollouts)
    $items = @(
        @{ item = @{ type = 'userMessage'; content = @(@{ type = 'text'; text = 'Hello' }) }; startedAtMs = 1700000000000 },
        @{ item = @{ type = 'reasoning'; summary = @(); content = @() } },
        @{ item = @{ type = 'commandExecution'; command = 'dir'; aggregatedOutput = 'file.txt' }; startedAtMs = 1700000001000 },
        @{ item = @{ type = 'webSearch'; query = 'powershell zip' }; startedAtMs = 1700000002000 },
        @{ item = @{ type = 'agentMessage'; text = 'Done' }; startedAtMs = 1700000003000 }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress | ConvertFrom-Json }
    $fromItems = @(ConvertFrom-CodexItems -Items $items)
    Assert ($fromItems.Count -eq 4) 'items: user, command, web search, agent'
    Assert ($fromItems[1].tool.name -eq 'shell' -and $fromItems[1].tool.arg -eq 'dir' -and $fromItems[1].tool.output -eq 'file.txt') 'commandExecution becomes a tool entry'
    Assert ($fromItems[2].tool.name -eq 'web_search' -and $fromItems[2].tool.arg -eq 'powershell zip') 'webSearch becomes a tool entry'

    # source profile with a database row for this thread
    $row = "insert into threads(id,rollout_path,source,model_provider,cwd,title,thread_source,updated_at,updated_at_ms,cli_version,created_at,first_user_message,preview) values('$threadId','$($rollout -replace "'", "''")','vscode','openai','C:\work\demo','Fix login','user',1700000000,1700000000123,'0.167.1',1699999999,'Fix the login bug','Fix the login bug')"
    New-CodexStateFixture -Path (Join-Path $srcHome 'state_5.sqlite') -InsertSql @($row)
    $srcProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'src'; Name = 'Src'; IsDefault = $false; CodexHome = $srcHome; UserDataDir = $null; Pid = $null }
    $chat = @(Get-CodexChats -Profile $srcProfile)[0]
    $dbRow = Get-CodexThreadRow -Profile $srcProfile -ChatId $threadId
    Assert ($dbRow.id -eq $threadId -and $dbRow.model_provider -eq 'openai') 'full thread row readable'

    $bundle = Join-Path $fixture 'out\chat.hbundle.zip'
    New-Item -ItemType Directory -Path (Split-Path $bundle) -Force | Out-Null
    $manifest = Export-CodexChat -Chat $chat -OutPath $bundle
    $x = Join-Path $fixture 'x1'
    $m = Read-HarnessBundle -Path $bundle -ExtractTo $x
    Assert ($m.source.harness -eq 'codex' -and $m.source.chatId -eq $threadId) 'manifest names the chat'
    Assert ($m.source.codex.modelProvider -eq 'openai' -and $m.source.codex.source -eq 'vscode' -and $m.source.codex.cliVersion -eq '0.167.1') 'codex source block'
    Assert ($m.source.codex.rolloutRelPath -eq "sessions/2026/11/11/$rolloutName") "rolloutRelPath: $($m.source.codex.rolloutRelPath)"
    Assert ((Get-FileSha256Hex (Join-Path $x "native\$rolloutName")) -eq (Get-FileSha256Hex $rollout)) 'rollout copied byte for byte'
    $rowJson = Get-Content -LiteralPath (Join-Path $x 'native\threads-row.json') -Raw | ConvertFrom-Json
    Assert ($rowJson.id -eq $threadId -and $null -eq $rowJson.PSObject.Properties['first_user_message'] -and $null -eq $rowJson.PSObject.Properties['preview']) 'threads-row.json drops first_user_message and preview'
    $md = Get-Content -LiteralPath (Join-Path $x 'transcript.md') -Raw
    Assert ($md -notmatch [regex]::Escape($fakeKey)) 'transcript.md is redacted'
    Assert ((Get-Content -LiteralPath (Join-Path $x 'transcript.jsonl') -Raw) -notmatch [regex]::Escape($fakeKey)) 'transcript.jsonl is redacted'
    Assert ((Get-FileSha256Hex (Join-Path $x "native\$rolloutName")) -eq (Get-FileSha256Hex $rollout)) 'native file keeps its secret (counted, not edited)'
    Assert ($m.redaction.findings -ge 1) 'secret findings counted'

    # native import into a fresh target
    $dstHome = Join-Path $fixture 'dsthome'
    $dstProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'dst'; Name = 'Dst'; IsDefault = $false; CodexHome = $dstHome; UserDataDir = $null; Pid = $null }
    $script:registered = @()
    $reg = { param($Profile, $ThreadId) $script:registered += $ThreadId; $true }   # the real one returns $true; that must not leak into the result
    $r1 = Import-CodexNative -BundlePath $bundle -Profile $dstProfile -Register $reg
    Assert (@($r1).Count -eq 1 -and $r1 -is [string] -and $r1 -eq 'copied') "first import copied as one string, got $(@($r1) -join ',')"
    $landed = Join-Path $dstHome "sessions\2026\11\11\$rolloutName"
    Assert ((Get-FileSha256Hex $landed) -eq (Get-FileSha256Hex $rollout)) 'rollout lands at the same relative path'
    Assert ($script:registered.Count -eq 1 -and $script:registered[0] -eq $threadId) 'thread registered after the copy'
    # X2: a failed registration is reported, and the next import registers again instead of saying "exists"
    $unHome = Join-Path $fixture 'unhome'
    $unProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'un'; Name = 'Un'; IsDefault = $false; CodexHome = $unHome; UserDataDir = $null; Pid = $null }
    $failReg = { param($Profile, $ThreadId) $false }
    $u1 = Import-CodexNative -BundlePath $bundle -Profile $unProfile -Register $failReg
    Assert ($u1 -eq 'copied-unregistered') "register returned false: got $u1"
    $throwReg = { param($Profile, $ThreadId) throw 'no codex.exe' }
    Remove-Item -LiteralPath (Join-Path $unHome 'sessions') -Recurse -Force
    $u1b = Import-CodexNative -BundlePath $bundle -Profile $unProfile -Register $throwReg 3>$null
    Assert ($u1b -eq 'copied-unregistered') "register threw: got $u1b"
    $script:registered = @()
    $u2 = Import-CodexNative -BundlePath $bundle -Profile $unProfile -Register $reg
    Assert ($u2 -eq 'registered' -and $script:registered.Count -eq 1) "retry registers the thread that has no threads row, got $u2"
    $script:registered = @()
    $u3 = Import-CodexNative -BundlePath $bundle -Profile $unProfile -Register $failReg
    Assert ($u3 -eq 'copied-unregistered') "retry that fails again is still reported, got $u3"
    New-CodexStateFixture -Path (Join-Path $unHome 'state_5.sqlite') -InsertSql @("insert into threads(id,rollout_path,source,model_provider,updated_at) values('$threadId','x','vscode','openai',1)")
    $u4 = Import-CodexNative -BundlePath $bundle -Profile $unProfile -Register $reg
    Assert ($u4 -eq 'exists' -and $script:registered.Count -eq 0) 'exists once the threads row is there; no registration'

    # X4: an older sibling with the other suffix is replaced, so one thread never has two rollout files
    $sibHome = Join-Path $fixture 'sibhome'
    $sibDir = Join-Path $sibHome 'sessions\2026\11\11'
    New-Item -ItemType Directory -Path $sibDir -Force | Out-Null
    $oldZst = Join-Path $sibDir "$rolloutName.zst"
    [IO.File]::WriteAllBytes($oldZst, [byte[]](9, 9, 9))
    (Get-Item -LiteralPath $oldZst).LastWriteTimeUtc = [datetime]'2000-01-01'
    $sibProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'sib'; Name = 'Sib'; IsDefault = $false; CodexHome = $sibHome; UserDataDir = $null; Pid = $null }
    $sb = Import-CodexNative -BundlePath $bundle -Profile $sibProfile -Register $reg
    $left = @(Get-ChildItem -LiteralPath $sibDir -File | ForEach-Object Name)
    Assert ($sb -eq 'copied' -and $left.Count -eq 1 -and $left[0] -eq $rolloutName) "the old .zst is replaced by the bundle's .jsonl, left: $($left -join ',')"

    New-CodexStateFixture -Path (Join-Path $dstHome 'state_5.sqlite') -InsertSql @("insert into threads(id,rollout_path,source,model_provider,updated_at) values('$threadId','x','vscode','openai',1)")
    $r2 = Import-CodexNative -BundlePath $bundle -Profile $dstProfile -Register $reg
    Assert ($r2 -eq 'exists') "second import is exists, got $r2"
    Assert ($script:registered.Count -eq 0 -or $script:registered.Count -eq 1) 'registration untouched'
    $script:registered = @($threadId)

    # provider mismatch: target config declares another provider
    $other = Join-Path $fixture 'otherhome'
    New-Item -ItemType Directory -Path $other -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $other 'config.toml') -Value "model = `"x`"`nmodel_provider = `"codex_local_access`"`n[profiles.a]`nmodel_provider = `"openai`"`n" -Encoding ASCII
    Assert ((Get-CodexConfigProvider -CodexHome $other) -eq 'codex_local_access') 'top-level model_provider read; tables ignored'
    Assert ((Get-CodexConfigProvider -CodexHome (Join-Path $fixture 'nohome')) -eq 'openai') 'no config means openai'
    $otherProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'oth'; Name = 'Oth'; IsDefault = $false; CodexHome = $other; UserDataDir = $null; Pid = $null }
    # provider rule: openai always works; else the top-level model_provider, or a [model_providers.<name>] table
    $script:registered = @()
    Assert ((Import-CodexNative -BundlePath $bundle -Profile $otherProfile -Register $reg) -eq 'copied') 'an openai chat is accepted by any home (built-in provider)'
    Remove-Item -LiteralPath (Join-Path $other 'sessions') -Recurse -Force
    $chatX = $chat.PSObject.Copy(); $chatX.ModelProvider = 'custom_x'
    $bundleX = Join-Path $fixture 'out\chatx.hbundle.zip'
    [void](Export-CodexChat -Chat $chatX -OutPath $bundleX)
    $script:registered = @()
    $r3 = Import-CodexNative -BundlePath $bundleX -Profile $otherProfile -Register $reg
    Assert ($r3 -eq 'provider-mismatch') "mismatch, got $r3"
    Assert (-not (Test-Path -LiteralPath (Join-Path $other 'sessions'))) 'nothing is copied on a mismatch'
    Assert ($script:registered.Count -eq 0) 'nothing registered on a mismatch'
    $topHome = Join-Path $fixture 'tophome'; New-Item -ItemType Directory -Path $topHome -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $topHome 'config.toml') -Value 'model_provider = "custom_x"' -Encoding ASCII
    $tblHome = Join-Path $fixture 'tblhome'; New-Item -ItemType Directory -Path $tblHome -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tblHome 'config.toml') -Value "model_provider = `"other`"`n[model_providers.custom_x]`nname = `"X`"`n" -Encoding ASCII
    foreach ($h in $topHome, $tblHome) {
        $pp = [pscustomobject]@{ Harness = 'codex'; Id = 'p'; Name = 'P'; IsDefault = $false; CodexHome = $h; UserDataDir = $null; Pid = $null }
        Assert ((Import-CodexNative -BundlePath $bundleX -Profile $pp -Register $reg) -eq 'copied') "provider declared by $(Split-Path -Leaf $h) is accepted"
    }

    # the bundle is untrusted: bad rollout paths and ids throw and write nothing
    $evilHome = Join-Path $fixture 'evilhome'
    $evilProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'e'; Name = 'E'; IsDefault = $false; CodexHome = $evilHome; UserDataDir = $null; Pid = $null }
    foreach ($bad in "sessions/2026/11/11/rollout-a.jsonl`n", 'sessions/2026/11/11/rollout-a:stream.jsonl', 'sessions/../../x.jsonl', '../../x.jsonl', 'sessions/2026/11/11/rollout-..\..\x.jsonl', 'sessions/2026/11/11/../../../x.jsonl', 'sessions/2026/11/11/rollout-a.txt') {
        $eb = Join-Path $fixture 'out\evil.hbundle.zip'
        if (Test-Path -LiteralPath $eb) { Remove-Item -LiteralPath $eb }
        [void](New-HarnessBundle -OutPath $eb -Source @{ harness = 'codex'; chatId = $threadId; title = 'e'; cwd = @{ absolute = $null; root = $null; relative = $null }; codex = @{ modelProvider = 'openai'; source = 'x'; rolloutRelPath = $bad } } -Files @(@{ Role = 'native'; Path = 'native/rollout-x.jsonl'; Content = '{}' }))
        Assert-Throws { Import-CodexNative -BundlePath $eb -Profile $evilProfile -Register $reg } "unsafe rolloutRelPath rejected: $bad"
    }
    $eb = Join-Path $fixture 'out\evil2.hbundle.zip'
    [void](New-HarnessBundle -OutPath $eb -Source @{ harness = 'codex'; chatId = 'not-a-uuid'; title = 'e'; cwd = @{ absolute = $null; root = $null; relative = $null }; codex = @{ modelProvider = 'openai'; source = 'x'; rolloutRelPath = "sessions/2026/11/11/$rolloutName" } } -Files @(@{ Role = 'native'; Path = "native/$rolloutName"; Content = '{}' }))
    Assert-Throws { Import-CodexNative -BundlePath $eb -Profile $evilProfile -Register $reg } 'chat id must be a UUID'
    $eb = Join-Path $fixture 'out\evil3.hbundle.zip'
    [void](New-HarnessBundle -OutPath $eb -Source @{ harness = 'codex'; chatId = "$threadId`n"; title = 'e'; cwd = @{ absolute = $null; root = $null; relative = $null }; codex = @{ modelProvider = 'openai'; source = 'x'; rolloutRelPath = "sessions/2026/11/11/$rolloutName" } } -Files @(@{ Role = 'native'; Path = "native/$rolloutName"; Content = '{}' }))
    Assert-Throws { Import-CodexNative -BundlePath $eb -Profile $evilProfile -Register $reg } 'a UUID with a trailing newline is not a UUID'    Assert (-not (Test-Path -LiteralPath $evilHome)) 'nothing written for rejected bundles'

    # .zst chat: transcript comes from the supplied provider; an empty result gives the one-line note
    $zstName = "rollout-2026-11-10T09-00-00-bbbbbbbb-0000-0000-0000-000000000002.jsonl.zst"
    $zstDir = Join-Path $srcHome 'sessions\2026\11\10'
    New-Item -ItemType Directory -Path $zstDir -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $zstDir $zstName), [byte[]](1, 2, 3, 4))
    $zchat = [pscustomobject]@{ ChatId = 'bbbbbbbb-0000-0000-0000-000000000002'; Title = 'Zst chat'; Cwd = 'C:\work'; Updated = $null; Activity = 1700000000000; Parent = $null; Source = 'vscode'; ModelProvider = 'openai'; RolloutPath = (Join-Path $zstDir $zstName); Profile = $srcProfile }
    $got = @(Get-CodexTranscriptEntries -Chat $zchat -ZstEntries { param($c) @(@{ role = 'user'; text = 'from app-server'; ts = 'x' }) })
    Assert ($got.Count -eq 1 -and $got[0].text -eq 'from app-server') '.zst transcript uses the supplied reader'
    $none = @(Get-CodexTranscriptEntries -Chat $zchat -ZstEntries { param($c) @() })
    Assert ($none.Count -eq 1 -and $none[0].text -like '*native*') 'empty .zst transcript gives the native-only note'

    # X1: the check looks at the running processes now, not at the Pid the profile had when the dialog opened
    . (Import-TestFunctions -Files @((Join-Path $root 'src\Harness.Codex.Profiles.ps1')) -Names @('Get-CodexRunningMap'))
    $pkgExe = 'C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__x\app\ChatGPT.exe'
    $udd = Join-Path $fixture 'wd\electron'
    $stale = [pscustomobject]@{ Harness = 'codex'; Id = 'wd'; Name = 'Wd'; IsDefault = $false; CodexHome = $srcHome; UserDataDir = $udd; Pid = $null }
    $procWd = @([pscustomobject]@{ ProcessId = 4242; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '" --user-data-dir="' + $udd + '"' })
    $procDef = @([pscustomobject]@{ ProcessId = 4243; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '"' })
    Assert (Test-CodexImportNeedsClose -Profile $stale -Processes $procWd) 'Codex opened after the dialog: close first, although Pid was empty'
    Assert (-not (Test-CodexImportNeedsClose -Profile $stale -Processes $procDef)) 'the Default instance does not block another profile'
    Assert (-not (Test-CodexImportNeedsClose -Profile $stale -Processes @())) 'no process means no need to close'
    $self = [pscustomobject]@{ Harness = 'codex'; Id = 'me'; Name = 'Me'; IsDefault = $false; CodexHome = $srcHome; UserDataDir = $udd; Pid = $PID }
    Assert (-not (Test-CodexImportNeedsClose -Profile $self -Processes @())) 'a stale Pid with no matching process does not block'
    $defP = [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default'; IsDefault = $true; CodexHome = $srcHome; UserDataDir = $null; Pid = $null }
    Assert (Test-CodexImportNeedsClose -Profile $defP -Processes $procDef) 'Default is blocked by its own instance'
} finally {
    Remove-TestTempDir $fixture
}

# ---------------------------------------------------------------- K4: Claude -> Codex import and handoff
$claudeSrc = Join-Path $root 'src\Harness.Claude.ps1'
$ui = Join-Path $root 'src\Ui.Harness.ps1'
. (Import-TestFunctions -Files @($claudeSrc) -Names @('ConvertTo-ClaudeProjectSlug', 'Find-ClaudeProjectDir', 'Get-ClaudeHomePath'))
. (Import-TestFunctions -Files @($ui) -Names @('Get-HandoffDir', 'New-HandoffPrompt', 'Export-HarnessHandoffFiles'))
. (Import-TestFunctions -Files @($core) -Names @('Resolve-CwdRef'))
. (Import-TestFunctions -Files @($chats) -Names @('ConvertFrom-CodexPath', 'Get-CodexNormalPath','Get-CodexExternalImportRecord', 'Select-CodexDetectedSession', 'Import-CodexExternalClaude', 'New-CodexDeepLink', 'Start-CodexHandoff'))

$fixture = New-TestTempDir
try {
    # detect filtering: match by path, ignoring case, slashes and the \\?\ prefix
    $detected = '{"items":[{"itemType":"CONFIG","description":"c","details":null},{"itemType":"SESSIONS","description":"s","cwd":null,"details":{"sessions":[{"cwd":"C:\\w","path":"C:\\Users\\X\\.claude\\projects\\p\\one.jsonl","title":"One"},{"cwd":"C:\\w","path":"C:\\Users\\X\\.claude\\projects\\p\\two.jsonl","title":"Two"}]}}],"connectors":[]}' | ConvertFrom-Json
    $pick = Select-CodexDetectedSession -DetectResult $detected -Path '\\?\c:/users/x/.CLAUDE/projects/p/TWO.jsonl'
    Assert ($pick.title -eq 'Two') 'detect filter matches ignoring case, slashes and prefix'
    Assert ($null -eq (Select-CodexDetectedSession -DetectResult $detected -Path 'C:\other.jsonl')) 'no match gives $null'
    Assert ($null -eq (Select-CodexDetectedSession -DetectResult ('{"items":[],"connectors":[]}' | ConvertFrom-Json) -Path 'C:\x.jsonl')) 'empty detect gives $null'

    # a Claude bundle whose jsonl exists in a fake ~\.claude
    $cwd = 'C:\work\demo_project'
    $cli = 'cccccccc-1111-2222-3333-444444444444'
    $claudeHome = Join-Path $fixture 'claudehome'
    $proj = Join-Path $claudeHome ('projects\' + (ConvertTo-ClaudeProjectSlug $cwd))
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $jsonl = Join-Path $proj "$cli.jsonl"
    Set-Content -LiteralPath $jsonl -Value '{"type":"user"}' -Encoding ASCII
    $cb = Join-Path $fixture 'claude.hbundle.zip'
    $srcMeta = @{ harness = 'claude'; chatId = 'local_x'; title = 'Claude chat'; lastActivityAt = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 86400000 * 3)
        cwd = @{ absolute = $cwd; root = $null; relative = $null }; claude = @{ account = 'a'; org = 'o'; cliSessionId = $cli } }
    [void](New-HarnessBundle -OutPath $cb -Source $srcMeta -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = '# transcript' }))
    $cProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'tgt'; Name = 'Tgt'; IsDefault = $false; CodexHome = (Join-Path $fixture 'tgthome'); UserDataDir = $null; Pid = $null }
    New-Item -ItemType Directory -Path $cProfile.CodexHome -Force | Out-Null

    # fake app-server: detect returns our jsonl; import records its params and reports success or failure
    $fake = Join-Path $fixture 'fake-codex.ps1'
    @'
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if (-not $line.Trim()) { continue }
    $m = $line | ConvertFrom-Json
    switch ($m.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":' + $m.id + ',"result":{}}') }
        'externalAgentConfig/detect' {
            Set-Content -LiteralPath (Join-Path $env:FAKE_DIR 'detect-params.json') -Value $line
            $p = ($env:FAKE_JSONL | ConvertTo-Json)
            [Console]::Out.WriteLine('{"id":' + $m.id + ',"result":{"items":[{"itemType":"AGENTS_MD","description":"a"},{"itemType":"SESSIONS","description":"s","cwd":null,"details":{"sessions":[{"cwd":"C:\\work","path":' + $p + ',"title":"Claude chat"},{"cwd":"C:\\w2","path":"C:\\elsewhere.jsonl","title":"Other"}]}}],"connectors":[]}}')
        }
        'externalAgentConfig/import' {
            Set-Content -LiteralPath (Join-Path $env:FAKE_DIR 'import-params.json') -Value $line
            [Console]::Out.WriteLine('{"id":' + $m.id + ',"result":{"importId":"imp1"}}')
            if ($env:FAKE_MODE -eq 'fail') {
                [Console]::Out.WriteLine('{"method":"externalAgentConfig/import/completed","params":{"importId":"imp1","itemTypeResults":[{"itemType":"SESSIONS","successes":[],"failures":[{"subErrorType":"session_not_detected","message":"nope"}]}]}}')
            } else {
                [Console]::Out.WriteLine('{"method":"externalAgentConfig/import/progress","params":{}}')
                [Console]::Out.WriteLine('{"method":"externalAgentConfig/import/completed","params":{"importId":"imp1","itemTypeResults":[{"itemType":"SESSIONS","successes":[{"itemType":"SESSIONS","target":"new-thread-1"}],"failures":[]}]}}')
            }
        }
    }
}
'@ | Set-Content -LiteralPath $fake -Encoding ASCII
    $psExe = (Get-Command powershell.exe).Source
    $factory = { param($p) Start-CodexAppServer -CodexHome $p.CodexHome -CodexExe $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $fake) }
    $env:FAKE_DIR = $fixture; $env:FAKE_JSONL = $jsonl; $env:FAKE_MODE = ''

    $res = Import-CodexExternalClaude -BundlePath $cb -Profile $cProfile -ClaudeHome $claudeHome -StartServer $factory
    Assert ($res.Status -eq 'imported' -and $res.ThreadId -eq 'new-thread-1') "import result: $($res.Status) $($res.ThreadId)"
    $imp = Get-Content -LiteralPath (Join-Path $fixture 'import-params.json') -Raw | ConvertFrom-Json
    Assert (@($imp.params.migrationItems).Count -eq 1 -and $imp.params.migrationItems[0].itemType -eq 'SESSIONS') 'only a SESSIONS item is sent'
    Assert (@($imp.params.migrationItems[0].details.sessions).Count -eq 1 -and $imp.params.migrationItems[0].details.sessions[0].path -eq $jsonl) 'only the chosen session is sent'
    $det = Get-Content -LiteralPath (Join-Path $fixture 'detect-params.json') -Raw | ConvertFrom-Json
    Assert ($det.params.includeHome -eq $true -and $det.params.maxSessions -ge 1000 -and $det.params.maxSessionAgeDays -ge 3) 'detect asks for the home with a wide enough window'

    $env:FAKE_MODE = 'fail'
    $bad = Import-CodexExternalClaude -BundlePath $cb -Profile $cProfile -ClaudeHome $claudeHome -StartServer $factory
    Assert ($bad.Status -eq 'not-detected') "session_not_detected maps to not-detected, got $($bad.Status)"
    $env:FAKE_MODE = ''

    # already imported in this home: no server needed
    $sha = (Get-FileSha256Hex $jsonl)
    $rec = @{ records = @(@{ source_path = "\\?\$jsonl"; content_sha256 = $sha; imported_thread_id = 'old-thread'; title = 'x' }); detected_connector_records = @() } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $cProfile.CodexHome 'external_agent_session_imports.json') -Value $rec -Encoding ASCII
    Assert ((Get-CodexExternalImportRecord -CodexHome $cProfile.CodexHome -Path $jsonl).imported_thread_id -eq 'old-thread') 'import record found by path and hash'
    $again = Import-CodexExternalClaude -BundlePath $cb -Profile $cProfile -ClaudeHome $claudeHome -StartServer { throw 'server must not start' }
    Assert ($again.Status -eq 'exists' -and $again.ThreadId -eq 'old-thread') 'already imported gives exists'
    Remove-Item -LiteralPath (Join-Path $cProfile.CodexHome 'external_agent_session_imports.json')

    # a cliSessionId that is not a UUID is never used to build a path
    $badCli = Join-Path $fixture 'badcli.hbundle.zip'
    $badSrc = $srcMeta.Clone(); $badSrc.claude = @{ account = 'a'; org = 'o'; cliSessionId = '..\..\evil' }
    [void](New-HarnessBundle -OutPath $badCli -Source $badSrc -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = '# t' }))
    Assert ((Import-CodexExternalClaude -BundlePath $badCli -Profile $cProfile -ClaudeHome $claudeHome -StartServer { throw 'server must not start' }).Status -eq 'not-detected') 'non-UUID cliSessionId is refused'

    $nl = Join-Path $fixture 'nl.hbundle.zip'
    $nlSrc = $srcMeta.Clone(); $nlSrc.claude = @{ account = 'a'; org = 'o'; cliSessionId = "$cli`n" }
    [void](New-HarnessBundle -OutPath $nl -Source $nlSrc -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = '# t' }))
    Assert ((Import-CodexExternalClaude -BundlePath $nl -Profile $cProfile -ClaudeHome $claudeHome -StartServer { throw 'server must not start' }).Status -eq 'not-detected') 'a cliSessionId with a trailing newline is refused'

    # jsonl missing on this machine: not-detected without starting a server
    $missing = Import-CodexExternalClaude -BundlePath $cb -Profile $cProfile -ClaudeHome (Join-Path $fixture 'emptyclaude') -StartServer { throw 'server must not start' }
    Assert ($missing.Status -eq 'not-detected') 'no jsonl on this machine gives not-detected'

    # deep link and handoff
    $url = New-CodexDeepLink -Prompt 'Continue "x" & y' -Path 'C:\work\my project'
    Assert ($url -eq 'codex://threads/new?prompt=Continue%20%22x%22%20%26%20y&path=C%3A%5Cwork%5Cmy%20project') "deep link encoding: $url"
    Assert ((New-CodexDeepLink -Prompt 'hi' -Path '') -eq 'codex://threads/new?prompt=hi') 'path omitted when empty'

    $script:started = @()
    $startProc = { param($u) $script:started += $u }
    $handoffDir = Join-Path $fixture 'handoff'
    $workDir = Join-Path $fixture 'projdir'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $hb = Join-Path $fixture 'h.hbundle.zip'
    $hSrc = @{ harness = 'claude'; chatId = 'local_h'; title = 'Hand chat'; cwd = @{ absolute = $workDir; root = $null; relative = $null } }
    [void](New-HarnessBundle -OutPath $hb -Source $hSrc -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = '# Hand chat' }))
    $defProfile = [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default'; IsDefault = $true; CodexHome = (Join-Path $fixture 'defhome'); UserDataDir = $null; Pid = $null }
    $r = Start-CodexHandoff -BundlePath $hb -Profile $defProfile -HandoffDir $handoffDir -StartProcess $startProc
    Assert ($r.Mode -eq 'deeplink' -and $script:started.Count -eq 1 -and $script:started[0] -like 'codex://threads/new?prompt=*') 'Default profile opens a deep link'
    Assert ($script:started[0] -like '*&path=*projdir*' -or $script:started[0] -like '*&path=*') 'deep link carries the existing working folder'
    Assert ($r.Prompt -like '*Hand chat*' -and (Test-Path -LiteralPath $r.Path)) 'handoff file written and prompt built'

    $script:viaClip = $null
    function Start-HarnessHandoff { param($BundlePath, $TargetHarness, $Profile) $script:viaClip = @{ Harness = $TargetHarness; Id = $Profile.Id }; [pscustomobject]@{ Path = 'p'; Prompt = 'q'; Launch = 'launched' } }
    $script:started = @()
    $r2 = Start-CodexHandoff -BundlePath $hb -Profile $cProfile -HandoffDir $handoffDir -StartProcess $startProc
    Assert ($r2.Mode -eq 'clipboard' -and $script:viaClip.Harness -eq 'codex' -and $script:viaClip.Id -eq 'tgt') 'extra profile uses clipboard handoff (deep links always reach Default)'
    Assert ($script:started.Count -eq 0) 'no deep link for an extra profile'

    # X3: a link longer than 2000 characters goes by the clipboard instead
    $longB = Join-Path $fixture 'long.hbundle.zip'
    $longSrc = @{ harness = 'claude'; chatId = 'local_l'; title = ('Long title ' * 300); cwd = @{ absolute = $workDir; root = $null; relative = $null } }
    [void](New-HarnessBundle -OutPath $longB -Source $longSrc -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = '# long' }))
    $script:viaClip = $null; $script:started = @()
    $r3 = Start-CodexHandoff -BundlePath $longB -Profile $defProfile -HandoffDir $handoffDir -StartProcess $startProc
    Assert ($r3.Mode -eq 'clipboard' -and $script:started.Count -eq 0 -and $script:viaClip.Id -eq 'Default') 'a deep link over 2000 characters falls back to the clipboard'
    $script:started = @()
    $r4 = Start-CodexHandoff -BundlePath $hb -Profile $defProfile -HandoffDir $handoffDir -StartProcess $startProc
    Assert ($r4.Mode -eq 'deeplink' -and $script:started.Count -eq 1) 'a short link still opens the deep link'
} finally {
    $env:FAKE_DIR = $null; $env:FAKE_JSONL = $null; $env:FAKE_MODE = $null
    Remove-TestTempDir $fixture
}

# ---------------------------------------------------------------- K5: Invoke-HarnessTransfer dispatch
. (Import-TestFunctions -Files @($core) -Names @('Register-Harness', 'Get-Harness', 'Get-Harnesses', 'Reset-HarnessRegistry', 'Get-HarnessRequiredCapabilities', 'Resolve-TransferMode'))
. (Import-TestFunctions -Files @($ui) -Names @('Invoke-HarnessTransfer','Test-HarnessImportBlocked','Export-HarnessChatBundle','Invoke-HarnessImport'))
$tdir = New-TestTempDir
try {
    $script:SwitcherHome = $tdir
    $script:calls = New-Object System.Collections.ArrayList
    $mkExport = { param($chat, $out) [void](New-HarnessBundle -OutPath $out -Source @{ harness = $chat.Harness; chatId = $chat.ChatId; title = 'T'; cwd = @{ absolute = $null; root = $null; relative = $null } } -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = '# t' })); [pscustomobject]@{ redaction = @{ findings = 0 } } }
    function New-FakeAdapter($name, $native, $ext, $close) {
        $a = @{
            Detect = { $true }; GetProfiles = { @() }; Launch = { 'ok' }; ListChats = { @() }; Export = $mkExport
            ImportHandoff = { param($b, $p) [void]$script:calls.Add('handoff'); [pscustomobject]@{ Path = 'hp'; Prompt = 'hq' } }
        }
        if ($native) { $a.ImportNative = { param($b, $p) [void]$script:calls.Add('native'); $script:nativeResult } }
        if ($ext) { $a.ImportExternalClaude = { param($b, $p) [void]$script:calls.Add('ext'); $script:extResult } }
        $a.ImportNeedsClose = $close
        Register-Harness -Name $name -Adapter $a
    }
    Reset-HarnessRegistry
    $script:closeAnswer = $false
    New-FakeAdapter 'claude' $true $false { $false }
    New-FakeAdapter 'codex' $true $true { $script:closeAnswer }
    $codexT = [pscustomobject]@{ Harness = 'codex'; Id = 'tgt'; Name = 'Tgt' }
    $claudeT = [pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default' }
    $cChat = [pscustomobject]@{ Harness = 'codex'; ChatId = 'c1'; Title = 'T' }
    $lChat = [pscustomobject]@{ Harness = 'claude'; ChatId = 'l1'; Title = 'T' }
    $bd = Join-Path $tdir 'bundles'

    $script:nativeResult = 'copied'
    $r = Invoke-HarnessTransfer -Chat $cChat -SourceHarness 'codex' -Target $codexT -BundleDir $bd
    Assert ($r.Mode -eq 'native' -and $r.Status -eq 'copied' -and $script:calls[-1] -eq 'native') 'codex to codex goes native'

    $script:calls.Clear(); $script:nativeResult = 'provider-mismatch'
    $r = Invoke-HarnessTransfer -Chat $cChat -SourceHarness 'codex' -Target $codexT -BundleDir $bd
    Assert ($r.Status -eq 'provider-mismatch' -and $r.Mode -eq 'handoff' -and $script:calls -join ',' -eq 'native,handoff') 'provider mismatch falls back to handoff'

    $script:calls.Clear(); $script:extResult = @{ Status = 'imported'; ThreadId = 't9' }
    $r = Invoke-HarnessTransfer -Chat $lChat -SourceHarness 'claude' -Target $codexT -BundleDir $bd
    Assert ($r.Mode -eq 'codex-import' -and $r.Status -eq 'imported' -and $r.ThreadId -eq 't9') 'claude to codex uses the importer'

    $script:calls.Clear(); $script:extResult = @{ Status = 'not-detected'; ThreadId = $null }
    $r = Invoke-HarnessTransfer -Chat $lChat -SourceHarness 'claude' -Target $codexT -BundleDir $bd
    Assert ($r.Status -eq 'not-detected' -and $r.Mode -eq 'handoff' -and $script:calls -join ',' -eq 'ext,handoff') 'not-detected falls back to handoff'

    $script:calls.Clear()
    $r = Invoke-HarnessTransfer -Chat $cChat -SourceHarness 'codex' -Target $claudeT -BundleDir $bd
    Assert ($r.Mode -eq 'handoff' -and $r.Status -eq 'handoff' -and $r.Prompt -eq 'hq') 'codex to claude is a handoff'

    $script:calls.Clear(); $script:closeAnswer = $true
    $r = Invoke-HarnessTransfer -Chat $cChat -SourceHarness 'codex' -Target $codexT -BundleDir $bd
    Assert ($r.Status -eq 'close-first' -and $script:calls.Count -eq 0) 'a running target blocks a native import before anything is written'
    $r = Invoke-HarnessTransfer -Chat $cChat -SourceHarness 'codex' -Target $claudeT -BundleDir $bd
    Assert ($r.Status -eq 'handoff') 'close check does not apply to a handoff'
    $script:closeAnswer = $false

    $script:calls.Clear()
    $r = Invoke-HarnessTransfer -Chat $cChat -SourceHarness 'codex' -Target $null -BundleDir $bd
    Assert ($r.Mode -eq 'files' -and $r.Prompt -like '*T*' -and (Test-Path -LiteralPath $r.Path) -and $script:calls.Count -eq 0) 'no target writes the handoff file only'
} finally {
    Remove-TestTempDir $tdir
}

# ---------------------------------------------------------------- X5: harnesses that are not installed are hidden
. (Import-TestFunctions -Files @($ui) -Names @('Test-HarnessInstalled', 'Get-HarnessTransferSources', 'Get-HarnessTransferTargets'))
Reset-HarnessRegistry
function New-DetectAdapter($detect, $profiles) {
    @{ Detect = $detect; GetProfiles = $profiles; Launch = { }; ListChats = { @() }; Export = { }; ImportHandoff = { } }
}
Register-Harness -Name 'claude' -Adapter (New-DetectAdapter { [pscustomobject]@{ Installed = $true } } { @([pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default' }) })
Register-Harness -Name 'codex' -Adapter (New-DetectAdapter { [pscustomobject]@{ Installed = $false } } { @([pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default' }) })
Register-Harness -Name 'antigravity' -Adapter (New-DetectAdapter { throw 'probe failed' } { @([pscustomobject]@{ Harness = 'antigravity'; Id = 'Default'; Name = 'Default' }) })
Register-Harness -Name 'other' -Adapter (New-DetectAdapter { $true } { @([pscustomobject]@{ Harness = 'other'; Id = 'Default'; Name = 'Default' }) })
Assert (Test-HarnessInstalled (Get-Harness 'claude')) 'Installed = true'
Assert (-not (Test-HarnessInstalled (Get-Harness 'codex'))) 'Installed = false is hidden'
Assert (-not (Test-HarnessInstalled (Get-Harness 'antigravity'))) 'a failing Detect counts as not installed'
Assert (Test-HarnessInstalled (Get-Harness 'other')) 'a plain $true counts as installed'
Assert ((@(Get-HarnessTransferSources) | ForEach-Object Name) -join ',' -eq 'claude') 'only installed Claude or Codex are sources'
Assert ((@(Get-HarnessTransferTargets) | ForEach-Object Harness) -join ',' -eq 'claude,other') 'targets come only from installed harnesses'

Write-Host 'HarnessCodexChats.Tests: OK'
