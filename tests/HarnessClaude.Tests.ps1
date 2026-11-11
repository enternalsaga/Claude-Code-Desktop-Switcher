$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
$switcher = Join-Path $root 'ClaudeSwitcher.ps1'
$core = Join-Path $root 'src\Harness.Core.ps1'
$claude = Join-Path $root 'src\Harness.Claude.ps1'
. (Import-TestFunctions -Files @($switcher) -Names @('Get-FirstValue','Get-SessionActivity','Get-SessionActivityAt','Read-ChatJson','Test-TitleNeedsSync','Set-JsonTopLevelString','Get-CodeSessionRoot','Get-CodeSessions','Get-CodeSessionStore','Copy-CodeSession'))
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-HarnessRequiredCapabilities','Register-Harness','Get-Harness','Reset-HarnessRegistry','Register-Harnesses',
    'Get-BytesSha256Hex','Get-FileSha256Hex','Test-BundleEntryName','New-HarnessBundle','Read-ZipEntryBytes','Read-HarnessBundle','ConvertTo-CwdRef',
    'Get-SecretPatterns','Invoke-SecretScan','Protect-TranscriptText','Measure-SecretFindings','Protect-TranscriptEntries','Get-FirstSentence','Format-TranscriptTurn','ConvertTo-HandoffMarkdown'))
. (Import-TestFunctions -Files @($claude) -Names @('ConvertTo-ClaudeProjectSlug','Find-ClaudeProjectDir','Get-ClaudeHomePath','Get-ClaudeToolArg','ConvertTo-ClaudeResultText','ConvertFrom-ClaudeJsonl','Get-ClaudeNativeFiles','Export-ClaudeChat','Import-ClaudeNative','Register-ClaudeHarness'))

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
