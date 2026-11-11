$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
$switcher = Join-Path $root 'ClaudeSwitcher.ps1'
$core = Join-Path $root 'src\Harness.Core.ps1'
$claude = Join-Path $root 'src\Harness.Claude.ps1'
. (Import-TestFunctions -Files @($switcher) -Names @('Get-FirstValue','Get-SessionActivity','Get-SessionActivityAt','Read-ChatJson','Test-TitleNeedsSync','Set-JsonTopLevelString','Get-CodeSessionRoot','Get-CodeSessions','Get-CodeSessionStore','Copy-CodeSession'))
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-HarnessRequiredCapabilities','Register-Harness','Get-Harness','Reset-HarnessRegistry','Register-Harnesses',
    'Get-BytesSha256Hex','Get-FileSha256Hex','Test-BundleEntryName','New-HarnessBundle','Read-ZipEntryBytes','Read-HarnessBundle','Get-HarnessBundleLimits','Copy-ZipEntryChecked','ConvertTo-CwdRef','Resolve-CwdRef','Get-HarnessMachineInfo','Get-HarnessPathRoots',
    'Get-SecretPatterns','Invoke-SecretScan','Protect-TranscriptText','Measure-SecretFindings','Protect-TranscriptEntries','Get-FirstSentence','Format-TranscriptTurn','ConvertTo-HandoffMarkdown'))
. (Import-TestFunctions -Files @($claude) -Names @('ConvertTo-ClaudeProjectSlug','Find-ClaudeProjectDir','Get-ClaudeHomePath','Get-ClaudeToolArg','ConvertTo-ClaudeResultText','ConvertFrom-ClaudeJsonl','Get-ClaudeNativeFiles','Get-ClaudeFolderFiles','Export-ClaudeChat','Import-ClaudeNative','Resolve-ClaudeImportCwd','Register-ClaudeHarness'))

function Assert-FilesIdentical($a, $b, $what) {
    Assert ((Get-FileSha256Hex $a) -eq (Get-FileSha256Hex $b)) "$what differs"
}

Assert ((ConvertTo-ClaudeProjectSlug 'H:\AI_Software\Claude-Code-Desktop-Switcher') -eq 'H--AI-Software-Claude-Code-Desktop-Switcher') 'slug example'
Assert ((ConvertTo-ClaudeProjectSlug 'C:\a_b\c d') -eq 'C--a-b-c-d') 'slug other chars'

$fixture = New-TestTempDir
try {
    $script:ClaudeApp = [pscustomobject]@{ Kind = 'Classic' }
    $cwd = 'C:\work\demo_project'
    $slug = ConvertTo-ClaudeProjectSlug $cwd
    $cli = 'cli-session-1'
    $fakeKey = 'sk-' + 'ant-TEST' + ('Z' * 30)

    # source profile with one chat
    $srcProfile = [pscustomobject]@{ Path = (Join-Path $fixture 'profA') }
    $srcStore = Join-Path $srcProfile.Path 'claude-code-sessions\acctA\orgA'
    New-Item -ItemType Directory -Path $srcStore -Force | Out-Null
    $chatJson = '{"title":"Demo chat","cwd":"C:\\work\\demo_project","account":"acctA","org":"orgA","sessionId":"local_demo","cliSessionId":"' + $cli + '","lastActivityAt":1700000000000,"createdAt":1699999999000}'
    [IO.File]::WriteAllText((Join-Path $srcStore 'local_demo.json'), $chatJson)

    # fake ~\.claude with the transcript, a subfolder and a secret in it
    $home1 = Join-Path $fixture 'claudehome1'
    $proj = Join-Path $home1 "projects\$slug"
    New-Item -ItemType Directory -Path (Join-Path $proj "$cli\subagents"), (Join-Path $proj "$cli\tool-results") -Force | Out-Null
    $lines = @(
        '{"type":"queue-operation","operation":"enqueue"}',
        '{"type":"user","timestamp":"t1","message":{"role":"user","content":"Fix the bug in a.ps1. Please."}}',
        ('{"type":"assistant","timestamp":"t2","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking now."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo ' + $fakeKey + '"}}]}}'),
        ('{"type":"user","timestamp":"t3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"out ' + $fakeKey + '"}]}}'),
        '{"type":"user","isMeta":true,"message":{"role":"user","content":"meta noise"}}',
        '{"type":"assistant","timestamp":"t4","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}'
    )
    $jsonlPath = Join-Path $proj "$cli.jsonl"
    [IO.File]::WriteAllText($jsonlPath, ($lines -join "`n") + "`n")
    [IO.File]::WriteAllBytes((Join-Path $proj "$cli\subagents\agent-1.jsonl"), [byte[]](0..50))
    [IO.File]::WriteAllText((Join-Path $proj "$cli\tool-results\r.txt"), 'result')

    # normalization
    $entries = @(ConvertFrom-ClaudeJsonl -Path $jsonlPath)
    Assert ($entries.Count -eq 4) "normalized entries: $($entries.Count) ($(($entries | ForEach-Object { $_.role }) -join ','))"
    Assert ($entries[0].role -eq 'user' -and $entries[0].text -like 'Fix the bug*') 'user entry'
    Assert ($entries[1].role -eq 'assistant' -and $entries[1].text -eq 'Looking now.') 'assistant text without thinking'
    Assert ($entries[2].role -eq 'tool' -and $entries[2].tool.name -eq 'Bash' -and $entries[2].tool.output -like 'out sk-*') 'tool call with attached result'
    Assert ($entries[3].text -eq 'Done.') 'last assistant entry'

    # export
    $session = @(Get-CodeSessions -Source $srcProfile)[0]
    Assert ($session.Id -eq 'local_demo') 'source chat listed'
    $bundle = Join-Path $fixture 'out\demo.hbundle.zip'
    $m = Export-ClaudeChat -Session $session -OutPath $bundle -ClaudeHome $home1 -ProfileLabel 'Work' -MachineName 'PC1' -PathRoots @{ Work = 'C:\work' }
    $paths = @($m.files | ForEach-Object { $_.path })
    foreach ($p in 'native/local_demo.json', "native/$cli.jsonl", "native/$cli/subagents/agent-1.jsonl", "native/$cli/tool-results/r.txt", 'transcript.md', 'transcript.jsonl') {
        Assert ($paths -contains $p) "bundle is missing $p (has: $($paths -join ', '))"
    }
    Assert ($m.chatKey -eq 'claude:local_demo' -and $m.source.title -eq 'Demo chat' -and $m.source.cwd.root -eq 'Work' -and $m.source.cwd.relative -eq 'demo_project') 'manifest source'
    Assert ($m.source.claude.account -eq 'acctA' -and $m.source.claude.org -eq 'orgA') 'manifest keeps account and org'
    Assert ($m.redaction.findings -ge 1 -and $m.redaction.transcriptRedacted) 'native secret counted'
    $check = Join-Path $fixture 'check'
    [void](Read-HarnessBundle -Path $bundle -ExtractTo $check)
    Assert-FilesIdentical $jsonlPath (Join-Path $check "native\$cli.jsonl") 'native jsonl (must stay unredacted)'
    $md = [IO.File]::ReadAllText((Join-Path $check 'transcript.md'))
    $tj = [IO.File]::ReadAllText((Join-Path $check 'transcript.jsonl'))
    Assert (-not $md.Contains('ZZZZ') -and -not $tj.Contains('ZZZZ') -and $md.Contains('[REDACTED]')) 'transcripts are redacted'
    Assert ($md.Contains('Fix the bug in a.ps1.') -and $md.Contains('Done.')) 'transcript.md content'
    Assert (@($tj -split "`n" | Where-Object { $_ }).Count -eq 4) 'transcript.jsonl has one line per entry'

    # import == old Copy-CodeSession, byte for byte
    $dstProfile = [pscustomobject]@{ Path = (Join-Path $fixture 'profB') }
    $dstOld = Join-Path $dstProfile.Path 'claude-code-sessions\acctB\orgB'
    $dstNew = Join-Path $fixture 'profC\claude-code-sessions\acctB\orgB'
    New-Item -ItemType Directory -Path $dstOld, $dstNew -Force | Out-Null
    $oldResult = Copy-CodeSession -Session $session -Store (Get-Item -LiteralPath $dstOld)
    $home2 = Join-Path $fixture 'claudehome2'
    $newResult = Import-ClaudeNative -BundlePath $bundle -Store (Get-Item -LiteralPath $dstNew) -ClaudeHome $home2
    Assert ($oldResult -eq 'copied' -and $newResult -eq 'copied') "results old=$oldResult new=$newResult"
    Assert-FilesIdentical (Join-Path $dstOld 'local_demo.json') (Join-Path $dstNew 'local_demo.json') 'chat json after transfer'
    $copied = Get-Content -LiteralPath (Join-Path $dstNew 'local_demo.json') -Raw | ConvertFrom-Json
    Assert ($copied.account -eq 'acctB' -and $copied.org -eq 'orgB') 'target identity rewritten'
    Assert-FilesIdentical $jsonlPath (Join-Path $home2 "projects\$slug\$cli.jsonl") 'transcript restored'
    Assert-FilesIdentical (Join-Path $proj "$cli\subagents\agent-1.jsonl") (Join-Path $home2 "projects\$slug\$cli\subagents\agent-1.jsonl") 'subagent file restored'
    Assert ((Import-ClaudeNative -BundlePath $bundle -Store (Get-Item -LiteralPath $dstNew) -ClaudeHome $home2) -eq 'exists') 'second import keeps what is there'
    Assert ((Copy-CodeSession -Session $session -Store (Get-Item -LiteralPath $dstOld)) -eq 'exists') 'old path also reports exists'

    # a transcript already present on this machine is not overwritten
    $before = Get-FileSha256Hex $jsonlPath
    $dstThird = Join-Path $fixture 'profD\claude-code-sessions\acctB\orgB'
    New-Item -ItemType Directory -Path $dstThird -Force | Out-Null
    [void](Import-ClaudeNative -BundlePath $bundle -Store (Get-Item -LiteralPath $dstThird) -ClaudeHome $home1)
    Assert ((Get-FileSha256Hex $jsonlPath) -eq $before) 'existing shared transcript untouched'

    # transcript stored under a folder that is not the cwd slug (shortened slug, or cwd changed later)
    $home3 = Join-Path $fixture 'claudehome3'
    $odd = Join-Path $home3 'projects\some-other-folder-name-abc123'
    New-Item -ItemType Directory -Path (Join-Path $odd $cli) -Force | Out-Null
    Copy-Item -LiteralPath $jsonlPath -Destination (Join-Path $odd "$cli.jsonl")
    [IO.File]::WriteAllText((Join-Path $odd "$cli\x.txt"), 'x')
    $m3 = Export-ClaudeChat -Session $session -OutPath (Join-Path $fixture 'out\odd.hbundle.zip') -ClaudeHome $home3
    $paths3 = @($m3.files | ForEach-Object { $_.path })
    Assert (($paths3 -contains "native/$cli.jsonl") -and ($paths3 -contains "native/$cli/x.txt")) "export must find the jsonl outside the slug folder: $($paths3 -join ', ')"
    $dstOdd = Join-Path $fixture 'profE\claude-code-sessions\acctB\orgB'
    New-Item -ItemType Directory -Path $dstOdd -Force | Out-Null
    [void](Import-ClaudeNative -BundlePath (Join-Path $fixture 'out\odd.hbundle.zip') -Store (Get-Item -LiteralPath $dstOdd) -ClaudeHome $home3)
    Assert (-not (Test-Path -LiteralPath (Join-Path $home3 "projects\$slug"))) 'import must not create a second copy under the slug folder'

    # a chat whose transcript is not on this machine (or empty) still exports
    $mNone = Export-ClaudeChat -Session $session -OutPath (Join-Path $fixture 'out\none.hbundle.zip') -ClaudeHome (Join-Path $fixture 'claudehome-empty')
    $pathsNone = @($mNone.files | ForEach-Object { $_.path })
    Assert (($pathsNone -contains 'native/local_demo.json') -and ($pathsNone -contains 'transcript.md') -and ($pathsNone -notcontains "native/$cli.jsonl")) "export without a transcript: $($pathsNone -join ', ')"
    $noneOut = Join-Path $fixture 'none-extract'
    [void](Read-HarnessBundle -Path (Join-Path $fixture 'out\none.hbundle.zip') -ExtractTo $noneOut)
    Assert ((Get-Item -LiteralPath (Join-Path $noneOut 'transcript.jsonl')).Length -eq 0) 'the empty transcript.jsonl round-trips through the bundle'

    # the manifest does not leak a secret that sits in the title or the working directory
    $leakySource = @{ harness = 'claude'; chatId = 'leak'; title = "deploy with $fakeKey"; cwd = @{ absolute = "C:\work\$fakeKey\app"; root = 'Work'; relative = "$fakeKey\app" } }
    $mLeak = New-HarnessBundle -OutPath (Join-Path $fixture 'out\leak.hbundle.zip') -Source $leakySource -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' })
    $leakText = $mLeak | ConvertTo-Json -Depth 10
    Assert (-not $leakText.Contains('ZZZZ') -and $mLeak.source.title -eq 'deploy with [REDACTED]' -and $mLeak.source.cwd.absolute -eq 'C:\work\[REDACTED]\app') "manifest title and cwd are redacted: $leakText"
    Assert ($leakySource.title -like '*ZZZZ*') 'the caller source hashtable is not modified'
    $zipText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $fixture 'out\leak.hbundle.zip')))
    Assert (-not $zipText.Contains('ZZZZ')) 'nothing secret in the zip bytes of a small bundle'

    # hooks: a broken file in src\ must not stop ClaudeSwitcher.ps1 (runs a copy in a child process, own LOCALAPPDATA)
    $hookRoot = Join-Path $fixture 'hookcopy'
    New-Item -ItemType Directory -Path $hookRoot | Out-Null
    Copy-Item -LiteralPath $switcher -Destination $hookRoot
    Copy-Item -LiteralPath (Join-Path $root 'src') -Destination (Join-Path $hookRoot 'src') -Recurse
    [IO.File]::WriteAllText((Join-Path $hookRoot 'src\Zz.Broken.ps1'), "throw 'broken src file'`r`n")
    [IO.File]::WriteAllText((Join-Path $hookRoot 'src\Zy.Syntax.ps1'), "function {{{ oops`r`n")
    [IO.File]::WriteAllText((Join-Path $hookRoot 'src\Zx.Register.ps1'), "function Register-AntigravityHarness { throw 'register exploded' }`r`n")
    $fakeLocal = Join-Path $fixture 'fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal | Out-Null
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $fakeLocal
        $listOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $hookRoot 'ClaudeSwitcher.ps1') -List 2>&1 | Out-String
        $listExit = $LASTEXITCODE
    } finally { $env:LOCALAPPDATA = $savedLocal }
    Assert ($listExit -eq 0 -and $listOut -match 'Default') "-List still works with broken src files (exit $listExit): $listOut"
    $errLog = [IO.File]::ReadAllText((Join-Path $fakeLocal 'ClaudeProfiles\switcher-error.log'))
    Assert ($errLog.Contains('Zz.Broken.ps1') -and $errLog.Contains('Zy.Syntax.ps1') -and $errLog.Contains('register exploded')) "failures are logged: $errLog"

    # a subagent jsonl must never become the chat transcript
    $home4 = Join-Path $fixture 'claudehome4'
    New-Item -ItemType Directory -Path (Join-Path $home4 "projects\$slug\$cli\subagents") -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $home4 "projects\$slug\$cli\subagents\agent-9.jsonl"), '{"type":"user","timestamp":"t","message":{"role":"user","content":"SUBAGENT PROMPT"}}' + "`n")
    $m4 = Export-ClaudeChat -Session $session -OutPath (Join-Path $fixture 'out\sub.hbundle.zip') -ClaudeHome $home4
    $out4 = Join-Path $fixture 'sub-extract'
    [void](Read-HarnessBundle -Path (Join-Path $fixture 'out\sub.hbundle.zip') -ExtractTo $out4)
    Assert (@($m4.files | Where-Object { $_.path -eq "native/$cli/subagents/agent-9.jsonl" }).Count -eq 1) 'subagent file is still carried as native'
    Assert (-not ([IO.File]::ReadAllText((Join-Path $out4 'transcript.md'))).Contains('SUBAGENT PROMPT') -and -not ([IO.File]::ReadAllText((Join-Path $out4 'transcript.jsonl'))).Contains('SUBAGENT PROMPT')) 'subagent text must not appear in the chat transcript'

    # --- lane C: a bundle that comes from another machine (this machine is 'machine-B') ---
    function Get-SyncMachine { [pscustomobject]@{ Id = 'machine-B'; Name = 'PCB' } }
    $junction = $null
    try {
        $cliX = '11111111-2222-3333-4444-555555555555'
        $profX = [pscustomobject]@{ Path = (Join-Path $fixture 'profX') }
        $storeX = Join-Path $profX.Path 'claude-code-sessions\acctA\orgA'
        New-Item -ItemType Directory -Path $storeX -Force | Out-Null
        $writeChatX = { param($act) [IO.File]::WriteAllText((Join-Path $storeX 'local_x.json'), ('{"title":"Cross chat","cwd":"C:\\work\\demo_project","originCwd":"C:\\work\\demo_project","workingDirectory":"C:\\work\\demo_project","account":"acctA","org":"orgA","sessionId":"local_x","cliSessionId":"' + $cliX + '","lastActivityAt":' + $act + ',"createdAt":1699999999000}')) }
        & $writeChatX 1700000000000
        $projX = Join-Path $home1 "projects\$slug"
        New-Item -ItemType Directory -Path (Join-Path $projX $cliX) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $projX "$cliX.jsonl"), '{"type":"user","timestamp":"t1","message":{"role":"user","content":"first version"}}' + "`n")
        [IO.File]::WriteAllText((Join-Path $projX "$cliX\keep.txt"), 'keep')

        # C3: a junction inside <cli>\ is never followed
        $outside = Join-Path $fixture 'outside-junction'
        New-Item -ItemType Directory -Path $outside | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'secret.txt'), 'outside the chat folder')
        $junction = Join-Path $projX "$cliX\link"
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $sx = @(Get-CodeSessions -Source $profX)[0]
        $xb = Join-Path $fixture 'out\x.hbundle.zip'
        $mx = Export-ClaudeChat -Session $sx -OutPath $xb -ClaudeHome $home1 -MachineId 'machine-A' -MachineName 'PCA' -PathRoots @{ Proj = 'C:\work' }
        $px = @($mx.files | ForEach-Object { $_.path })
        Assert (($px -contains "native/$cliX/keep.txt") -and -not @($px | Where-Object { $_ -like "native/$cliX/link*" }).Count) "junction content must not be exported: $($px -join ', ')"
        Assert ($mx.source.machineId -eq 'machine-A' -and $mx.source.cwd.root -eq 'Proj' -and $mx.source.cwd.relative -eq 'demo_project') 'cross-machine fixture manifest'

        # C1: unknown root asks for it and writes nothing
        $dstX = Join-Path $fixture 'profY\claude-code-sessions\acctB\orgB'
        New-Item -ItemType Directory -Path $dstX -Force | Out-Null
        $homeX = Join-Path $fixture 'claudehomeX'
        $r = Import-ClaudeNative -BundlePath $xb -Store (Get-Item -LiteralPath $dstX) -ClaudeHome $homeX -PathRoots @{ Other = 'D:\other' }
        Assert ($r.Status -eq 'needs-root' -and $r.Root -eq 'Proj') "needs-root result: $($r | ConvertTo-Json -Compress)"
        Assert (-not (Test-Path -LiteralPath $homeX) -and @(Get-ChildItem -LiteralPath $dstX).Count -eq 0) 'needs-root writes nothing'

        # C1 + C4: known root; the folder is missing here, so the result says so
        $rootHere = Join-Path $fixture 'projects-here'
        $newCwd = Join-Path $rootHere 'demo_project'
        $r = Import-ClaudeNative -BundlePath $xb -Store (Get-Item -LiteralPath $dstX) -ClaudeHome $homeX -PathRoots @{ Proj = $rootHere }
        Assert ($r.Status -eq 'copied' -and $r.CwdMissing -eq $true) "cross-machine import result: $($r | ConvertTo-Json -Compress)"
        $newProj = Join-Path $homeX ('projects\' + (ConvertTo-ClaudeProjectSlug $newCwd))
        Assert (Test-Path -LiteralPath (Join-Path $newProj "$cliX.jsonl")) 'jsonl is placed under the slug of the new cwd'
        Assert (Test-Path -LiteralPath (Join-Path $newProj "$cliX\keep.txt")) 'the <cli> folder follows the jsonl'
        Assert (-not (Test-Path -LiteralPath (Join-Path $homeX "projects\$slug"))) 'nothing under the old machine slug'
        $cj = Get-Content -LiteralPath (Join-Path $dstX 'local_x.json') -Raw | ConvertFrom-Json
        Assert ($cj.cwd -eq $newCwd -and $cj.originCwd -eq $newCwd -and $cj.workingDirectory -eq $newCwd -and $cj.account -eq 'acctB') 'cwd, originCwd and workingDirectory are rewritten, identity too'
        New-Item -ItemType Directory -Path $newCwd -Force | Out-Null
        $dstZ = Join-Path $fixture 'profZ\claude-code-sessions\acctB\orgB'
        New-Item -ItemType Directory -Path $dstZ -Force | Out-Null
        $r = Import-ClaudeNative -BundlePath $xb -Store (Get-Item -LiteralPath $dstZ) -ClaudeHome (Join-Path $fixture 'claudehomeZ') -PathRoots @{ Proj = $rootHere }
        Assert ($r.Status -eq 'copied' -and $r.CwdMissing -eq $false) 'CwdMissing is false when the folder exists'
        $badRoots = $null; try { [void](Import-ClaudeNative -BundlePath $xb -Store (Get-Item -LiteralPath $dstZ) -ClaudeHome (Join-Path $fixture 'claudehomeZ2') -PathRoots @{ Proj = 'rel\path' }) } catch { $badRoots = $_.Exception.Message }

        # C2: a newer bundle replaces the transcript (old one kept as .bak), an older one changes nothing
        $r = Import-ClaudeNative -BundlePath $xb -Store (Get-Item -LiteralPath $dstX) -ClaudeHome $homeX -PathRoots @{ Proj = $rootHere }
        Assert ($r.Status -eq 'exists') "same bundle again: $($r.Status)"
        & $writeChatX 1800000000000
        [IO.File]::WriteAllText((Join-Path $projX "$cliX.jsonl"), '{"type":"user","timestamp":"t1","message":{"role":"user","content":"second version"}}' + "`n")
        $sx2 = @(Get-CodeSessions -Source $profX)[0]
        $xb2 = Join-Path $fixture 'out\x2.hbundle.zip'
        [void](Export-ClaudeChat -Session $sx2 -OutPath $xb2 -ClaudeHome $home1 -MachineId 'machine-A' -MachineName 'PCA' -PathRoots @{ Proj = 'C:\work' })
        $r = Import-ClaudeNative -BundlePath $xb2 -Store (Get-Item -LiteralPath $dstX) -ClaudeHome $homeX -PathRoots @{ Proj = $rootHere }
        Assert ($r.Status -eq 'updated') "newer bundle: $($r.Status)"
        Assert (([IO.File]::ReadAllText((Join-Path $newProj "$cliX.jsonl"))).Contains('second version')) 'transcript replaced by the newer one'
        $baks = @(Get-ChildItem -LiteralPath $newProj -Filter "$cliX.jsonl.bak-*")
        Assert ($baks.Count -eq 1 -and ([IO.File]::ReadAllText($baks[0].FullName)).Contains('first version')) 'the old transcript is kept as .bak'
        $r = Import-ClaudeNative -BundlePath $xb -Store (Get-Item -LiteralPath $dstX) -ClaudeHome $homeX -PathRoots @{ Proj = $rootHere }
        Assert ($r.Status -eq 'exists' -and ([IO.File]::ReadAllText((Join-Path $newProj "$cliX.jsonl"))).Contains('second version') -and @(Get-ChildItem -LiteralPath $newProj -Filter "$cliX.jsonl.bak-*").Count -eq 1) 'an older bundle changes nothing'

        # a bundle from another machine is untrusted input: ids that are not what Claude writes are refused before any write
        foreach ($evil in @(@{ Name = 'traversal'; Json = '..\\..\\x' }, @{ Name = 'newline'; Json = 'abc\n' }, @{ Name = 'slash'; Json = 'a/b' })) {
            $profE = [pscustomobject]@{ Path = (Join-Path $fixture ('profEvil-' + $evil.Name)) }
            $storeE = Join-Path $profE.Path 'claude-code-sessions\acctA\orgA'
            New-Item -ItemType Directory -Path $storeE -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $storeE 'local_evil.json'), ('{"title":"Evil","cwd":"C:\\work\\demo_project","account":"acctA","org":"orgA","sessionId":"local_evil","cliSessionId":"' + $evil.Json + '","lastActivityAt":1700000000000}'))
            $eb = Join-Path $fixture ('out\evil-' + $evil.Name + '.hbundle.zip')
            [void](Export-ClaudeChat -Session @(Get-CodeSessions -Source $profE)[0] -OutPath $eb -ClaudeHome (Join-Path $fixture 'claudehome-empty') -MachineId 'machine-A' -MachineName 'PCA' -PathRoots @{ Proj = 'C:\work' })
            $dstE = Join-Path $fixture ('profEvilDst-' + $evil.Name + '\claude-code-sessions\acctB\orgB')
            New-Item -ItemType Directory -Path $dstE -Force | Out-Null
            $homeE = Join-Path $fixture ('claudehomeEvil-' + $evil.Name)
            $emsg = $null; try { [void](Import-ClaudeNative -BundlePath $eb -Store (Get-Item -LiteralPath $dstE) -ClaudeHome $homeE -PathRoots @{ Proj = $rootHere }) } catch { $emsg = $_.Exception.Message }
            Assert ($emsg -like '*not a UUID*') "cliSessionId '$($evil.Name)' must be refused: $emsg"
            Assert (-not (Test-Path -LiteralPath $homeE) -and @(Get-ChildItem -LiteralPath $dstE).Count -eq 0) "nothing written for '$($evil.Name)'"
        }
    } finally {
        if ($junction -and (Test-Path -LiteralPath $junction)) { [IO.Directory]::Delete($junction) }
        Remove-Item Function:\Get-SyncMachine
    }
    Assert ($null -ne $badRoots -and $badRoots -like '*not valid*') "a root that is not an absolute path is refused: $badRoots"

    # handoff files (same machine, Claude -> file -> prompt)
    . (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.Harness.ps1')) -Names @('Get-HandoffDir','New-HandoffPrompt','Export-HarnessHandoffFiles'))
    $handoffDir = Join-Path $fixture 'handoff'
    $ho = Export-HarnessHandoffFiles -BundlePath $bundle -HandoffDir $handoffDir -Target 'claude'
    Assert ($ho.Path -eq (Join-Path $handoffDir "$($m.bundleId).md") -and (Test-Path -LiteralPath $ho.Path)) 'handoff md written under the handoff dir'
    Assert ([IO.File]::ReadAllText($ho.Path) -eq $md) 'handoff md is the bundle transcript'
    Assert ($ho.Prompt.Contains($ho.Path) -and $ho.Prompt.Contains('Demo chat') -and $ho.Prompt.Contains('claude')) "prompt: $($ho.Prompt)"
    $log = @([IO.File]::ReadAllLines((Join-Path $handoffDir 'handoff-log.jsonl')))
    Assert ($log.Count -eq 1 -and ($log[0] | ConvertFrom-Json).bundleId -eq $m.bundleId -and ($log[0] | ConvertFrom-Json).target -eq 'claude') 'handoff log line'
    [void](Export-HarnessHandoffFiles -BundlePath $bundle -HandoffDir $handoffDir)
    Assert (@([IO.File]::ReadAllLines((Join-Path $handoffDir 'handoff-log.jsonl'))).Count -eq 2) 'handoff log appends'

    # registration
    Register-Harnesses
    $h = Get-Harness -Name 'claude'
    Assert ($null -ne $h) 'claude registered'
    foreach ($k in 'Detect','GetProfiles','Launch','ListChats','Export','ImportHandoff','ImportNative') { Assert ($h.Adapter[$k] -is [scriptblock]) "adapter lacks $k" }

    Write-Output 'PASS: Claude slug, jsonl normalization, export bundle, native import identical to Copy-CodeSession, registration.'
} finally {
    Remove-TestTempDir $fixture
}
