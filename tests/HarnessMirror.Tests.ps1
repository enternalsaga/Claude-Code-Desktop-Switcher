$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')

$root = Split-Path $PSScriptRoot -Parent
$switcher = Join-Path $root 'ClaudeSwitcher.ps1'
$core = Join-Path $root 'src\Harness.Core.ps1'
$claude = Join-Path $root 'src\Harness.Claude.ps1'
$codex = Join-Path $root 'src\Harness.Codex.Chats.ps1'
$agy = Join-Path $root 'src\Harness.Antigravity.Chats.ps1'
$mirror = Join-Path $root 'src\Harness.Mirror.ps1'
$fixturesDir = Join-Path $PSScriptRoot 'fixtures\mirror'

. (Import-TestFunctions -Files @($switcher) -Names @('Get-FirstValue', 'Read-ChatJson'))
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-SecretPatterns', 'Invoke-SecretScan', 'Protect-TranscriptText',
    'Protect-TranscriptEntries', 'Get-FirstSentence', 'Format-TranscriptTurn',
    'ConvertTo-HandoffMarkdown'
))
. (Import-TestFunctions -Files @($claude) -Names @(
    'ConvertTo-ClaudeProjectSlug', 'Get-ClaudeHomePath', 'Get-ClaudeToolArg',
    'ConvertTo-ClaudeResultText', 'ConvertFrom-ClaudeJsonl', 'Find-ClaudeProjectDir'
))
. (Import-TestFunctions -Files @($codex) -Names @(
    'ConvertFrom-CodexPath', 'Resolve-CodexRolloutFile', 'ConvertTo-CodexToolOutput',
    'Get-CodexToolArg', 'Test-CodexSystemMessage', 'ConvertFrom-CodexRollout',
    'Get-CodexTranscriptEntries'
))
. (Import-TestFunctions -Files @($agy) -Names @(
    'Get-AgyToolArg', 'Get-AgyUserText', 'Get-AgySystemStepTypes',
    'ConvertFrom-AgyTranscriptJsonl'
))
. $mirror

$fixture = New-TestTempDir
try {
    $script:SwitcherHome = Join-Path $fixture 'switcher'
    $mirrorDir = Get-MirrorDir
    Assert ($mirrorDir -eq (Join-Path $script:SwitcherHome 'live-mirror')) "Get-MirrorDir: $mirrorDir"
    Assert (@(Read-MirrorPins).Count -eq 0) 'empty pins when pins.json does not exist'

    # Prepare synthetic homes and sources for Claude, Codex, Antigravity
    $cwd = 'C:\work\demo'
    $claudeHome = Join-Path $fixture 'claude-home'
    $claudeCliId = '11111111-1111-1111-1111-111111111111'
    $claudeSlug = ConvertTo-ClaudeProjectSlug $cwd
    $claudeProj = Join-Path $claudeHome "projects\$claudeSlug"
    New-Item -ItemType Directory -Path $claudeProj -Force | Out-Null
    $claudeSrc = Join-Path $claudeProj "$claudeCliId.jsonl"
    Copy-Item -LiteralPath (Join-Path $fixturesDir 'claude-session.jsonl') -Destination $claudeSrc
    $claudeMetaPath = Join-Path $fixture 'local_c1.json'
    [IO.File]::WriteAllText($claudeMetaPath, ('{"title":"Claude Demo","cwd":"C:\\work\\demo","sessionId":"local_c1","cliSessionId":"' + $claudeCliId + '"}'))
    $claudeChat = [pscustomobject]@{
        ChatId = 'local_c1'; Title = 'Claude Demo'; Cwd = $cwd
        Profile = [pscustomobject]@{ Id = 'Default'; Name = 'Default' }
        Session = [pscustomobject]@{ File = (Get-Item -LiteralPath $claudeMetaPath) }
    }

    $codexHome = Join-Path $fixture 'codex-home'
    $codexSess = Join-Path $codexHome 'sessions\2026\11\25'
    New-Item -ItemType Directory -Path $codexSess -Force | Out-Null
    $codexId = '22222222-2222-2222-2222-222222222222'
    $codexSrc = Join-Path $codexSess "rollout-2026-11-25T10-00-00-$codexId.jsonl"
    Copy-Item -LiteralPath (Join-Path $fixturesDir 'codex-rollout.jsonl') -Destination $codexSrc
    $codexChat = [pscustomobject]@{
        ChatId = $codexId; Title = 'Codex Demo'; Cwd = $cwd
        RolloutPath = $codexSrc
        Profile = [pscustomobject]@{ Id = 'work'; Name = 'Work' }
    }

    $agyData = Join-Path $fixture 'agy-data'
    $agyId = '33333333-3333-3333-3333-333333333333'
    $agyLogDir = Join-Path $agyData "brain\$agyId\.system_generated\logs"
    New-Item -ItemType Directory -Path $agyLogDir -Force | Out-Null
    $agySrc = Join-Path $agyLogDir 'transcript.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixturesDir 'agy-transcript.jsonl') -Destination $agySrc
    $agyChat = [pscustomobject]@{
        ChatId = $agyId; Title = 'Agy Demo'; Cwd = $cwd
        Profile = [pscustomobject]@{ Id = 'app'; Name = 'Antigravity'; DataDir = $agyData }
    }

    # Resolve-MirrorSource for all 3 harnesses and missing sources
    Assert ((Resolve-MirrorSource -Harness 'claude' -Chat $claudeChat -ClaudeHome $claudeHome) -eq $claudeSrc) 'resolve claude source'
    Assert ((Resolve-MirrorSource -Harness 'codex' -Chat $codexChat) -eq $codexSrc) 'resolve codex source'
    Assert ((Resolve-MirrorSource -Harness 'antigravity' -Chat $agyChat) -eq $agySrc) 'resolve agy source'

    $noClaude = [pscustomobject]@{
        ChatId = 'local_missing'; Title = 'Missing'; Cwd = $cwd
        CliSessionId = '99999999-9999-9999-9999-999999999999'
        Profile = [pscustomobject]@{ Id = 'Default' }
    }
    Assert ($null -eq (Resolve-MirrorSource -Harness 'claude' -Chat $noClaude -ClaudeHome $claudeHome)) 'missing claude source -> $null'
    $noCodex = [pscustomobject]@{ ChatId = 'missing-codex'; Title = 'Missing'; RolloutPath = (Join-Path $codexSess 'missing.jsonl'); Profile = [pscustomobject]@{ Id = 'work' } }
    Assert ($null -eq (Resolve-MirrorSource -Harness 'codex' -Chat $noCodex)) 'missing codex source -> $null'
    $noAgy = [pscustomobject]@{ ChatId = '44444444-4444-4444-4444-444444444444'; Title = 'No transcript'; Profile = [pscustomobject]@{ Id = 'app'; DataDir = $agyData } }
    Assert ($null -eq (Resolve-MirrorSource -Harness 'antigravity' -Chat $noAgy)) 'agy without transcript -> $null'

    # no-source throws
    $err = $null; try { [void](Add-MirrorPin -Harness 'antigravity' -Chat $noAgy) } catch { $err = $_.Exception.Message }
    Assert ($err -like '*no-source*') "missing source throws no-source: $err"

    # pin and unpin + round-trip through pins.json
    $pinC = Add-MirrorPin -Harness 'claude' -Chat $claudeChat -ClaudeHome $claudeHome
    $pinX = Add-MirrorPin -Harness 'codex' -Chat $codexChat
    $pinA = Add-MirrorPin -Harness 'antigravity' -Chat $agyChat
    $pins = @(Read-MirrorPins)
    Assert ($pins.Count -eq 3) "3 pins saved, got $($pins.Count)"
    Assert ($pins[0].harness -eq 'claude' -and $pins[0].id -eq 'local_c1' -and $pins[0].profileId -eq 'Default' -and $pins[0].title -eq 'Claude Demo') 'claude pin fields'
    Assert ($pins[0].sourcePath -eq $claudeSrc -and $pins[0].mirrorPath -eq (Join-Path $mirrorDir 'claude-local_c1.md')) 'claude paths'
    Assert ($pins[0].codexSync -eq $false -and $null -eq $pins[0].codexProfileId -and $pins[0].state -eq 'ok') 'default sync/state fields'

    # already-pinned throws
    $err = $null; try { [void](Add-MirrorPin -Harness 'claude' -Chat $claudeChat -ClaudeHome $claudeHome) } catch { $err = $_.Exception.Message }
    Assert ($err -like '*already-pinned*') "duplicate pin throws already-pinned: $err"

    # export all 3, verify header, content, redaction, unchanged skip
    $tNow = [datetime]::new(2026, 11, 25, 15, 0, 0, [DateTimeKind]::Utc)
    foreach ($p in $pins) {
        $r = Export-MirrorPin -Pin $p -Now $tNow
        Assert ($r -eq 'written') "first export for $($p.harness) returned $r"
        Assert (Test-Path -LiteralPath $p.mirrorPath -PathType Leaf) "mirror md exists for $($p.harness)"
    }
    $mdC = [IO.File]::ReadAllText($pinC.mirrorPath)
    $mdX = [IO.File]::ReadAllText($pinX.mirrorPath)
    $mdA = [IO.File]::ReadAllText($pinA.mirrorPath)
    Assert ($mdC.StartsWith('<!-- live mirror, updated 2026-11-25T15:00:00.0000000Z -->')) "header line on claude md: $($mdC.Substring(0, [Math]::Min(80, $mdC.Length)))"
    Assert ($mdC.Contains('Claude final answer.') -and $mdX.Contains('Codex final answer.') -and $mdA.Contains('Antigravity final answer.')) 'all 3 mirrors have final assistant replies'

    # redacted: fake secrets must never appear
    foreach ($sec in 'sk-FakeClaudeSecretValueXYZ', 'sk-FakeCodexSecretValueABCD', 'sk-FakeAgySecretValueABCDEF') {
        Assert (-not $mdC.Contains($sec) -and -not $mdX.Contains($sec) -and -not $mdA.Contains($sec)) "secret $sec leaked into mirror md"
    }
    Assert ($mdC.Contains('[REDACTED]') -and $mdX.Contains('[REDACTED]') -and $mdA.Contains('[REDACTED]')) 'redaction marker present in all 3 mirrors'

    # prompt text exact match
    $expectedPrompt = 'Read ' + $pinC.mirrorPath + '. It updates itself after every turn of the claude chat "Claude Demo"; read it again when you need newer context. If the harness-transcripts tool is available, call read_session_tail with harness=claude id=local_c1 instead.'
    Assert ((New-MirrorHandoffPrompt -Pin $pinC) -ceq $expectedPrompt) "prompt text mismatch: $(New-MirrorHandoffPrompt -Pin $pinC)"

    # unchanged skip
    $backTime = $tNow.AddSeconds(-30)
    (Get-Item -LiteralPath $pins[0].mirrorPath).LastWriteTimeUtc = $backTime
    $ticksBefore = (Get-Item -LiteralPath $pins[0].mirrorPath).LastWriteTimeUtc.Ticks
    Assert ((Export-MirrorPin -Pin $pins[0] -Now $tNow.AddSeconds(5)) -eq 'unchanged') 'second export without file change skips'
    Assert ((Get-Item -LiteralPath $pins[0].mirrorPath).LastWriteTimeUtc.Ticks -eq $ticksBefore) 'mirror md mtime unchanged when skipped'

    # .zst Codex pin uses -ZstEntries stub
    $zstSrc = Join-Path $codexSess 'rollout-2026-11-25T11-00-00-55555555-5555-5555-5555-555555555555.jsonl.zst'
    [IO.File]::WriteAllBytes($zstSrc, [byte[]](1, 2, 3, 4))
    $zstPin = [pscustomobject]@{
        harness = 'codex'; id = '55555555-5555-5555-5555-555555555555'; profileId = 'work'
        title = 'Zst Pin'; cwd = $cwd; sourcePath = $zstSrc; mirrorPath = (Join-Path $mirrorDir 'codex-zst.md')
        codexSync = $false; codexProfileId = $null; lastSize = 0; lastTicks = 0; state = 'ok'
    }
    $zstRes = Export-MirrorPin -Pin $zstPin -Now $tNow -ZstEntries { param($c) @(@{ role = 'user'; text = 'zst prompt'; ts = 't1' }, @{ role = 'assistant'; text = 'zst reply'; ts = 't2' }) }
    Assert ($zstRes -eq 'written' -and ([IO.File]::ReadAllText($zstPin.mirrorPath)).Contains('zst reply')) 'codex .zst export via ZstEntries stub'

    # unpin removes from pins.json and keeps .md
    $keptMd = $pinX.mirrorPath
    Remove-MirrorPin -Harness 'codex' -Id $codexId
    $afterRemove = @(Read-MirrorPins)
    Assert ($afterRemove.Count -eq 2 -and -not ($afterRemove | Where-Object { $_.harness -eq 'codex' -and $_.id -eq $codexId })) 'pin removed from pins.json'
    Assert (Test-Path -LiteralPath $keptMd -PathType Leaf) 'mirror md kept after unpin'

    # pin limit (5 max, 6th throws pin-limit)
    for ($i = 1; $i -le 3; $i++) {
        $lid = "44444444-4444-4444-4444-44444444440$i"
        $lDir = Join-Path $agyData "brain\$lid\.system_generated\logs"
        New-Item -ItemType Directory -Path $lDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixturesDir 'agy-transcript.jsonl') -Destination (Join-Path $lDir 'transcript.jsonl')
        [void](Add-MirrorPin -Harness 'antigravity' -Chat ([pscustomobject]@{ ChatId = $lid; Title = "Chat $i"; Profile = [pscustomobject]@{ Id = 'app'; DataDir = $agyData } }))
    }
    Assert (@(Read-MirrorPins).Count -eq 5) '5 pins allowed'
    $lid6 = '44444444-4444-4444-4444-444444444406'
    $lDir6 = Join-Path $agyData "brain\$lid6\.system_generated\logs"
    New-Item -ItemType Directory -Path $lDir6 -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixturesDir 'agy-transcript.jsonl') -Destination (Join-Path $lDir6 'transcript.jsonl')
    $err = $null; try { [void](Add-MirrorPin -Harness 'antigravity' -Chat ([pscustomobject]@{ ChatId = $lid6; Title = 'Chat 6'; Profile = [pscustomobject]@{ Id = 'app'; DataDir = $agyData } })) } catch { $err = $_.Exception.Message }
    Assert ($err -like '*pin-limit*') "6th pin throws pin-limit: $err"

    # debounce: 3 events within 1s -> empty at +1.9s, due at +2.0s, cleared after
    $q = New-MirrorQueue
    Assert ($q.DelayMs -eq 2000) 'default DelayMs is 2000'
    $t0 = [datetime]::new(2026, 11, 25, 12, 0, 0, [DateTimeKind]::Utc)
    Add-MirrorEvent -Queue $q -Key 'claude:local_c1' -Now $t0
    Add-MirrorEvent -Queue $q -Key 'claude:local_c1' -Now $t0.AddMilliseconds(400)
    Add-MirrorEvent -Queue $q -Key 'claude:local_c1' -Now $t0.AddMilliseconds(1000)
    Assert (@(Get-MirrorDue -Queue $q -Now $t0.AddMilliseconds(2900)).Count -eq 0) 'not due at +1.9s from last event'
    $due = @(Get-MirrorDue -Queue $q -Now $t0.AddMilliseconds(3000))
    Assert ($due.Count -eq 1 -and $due[0] -eq 'claude:local_c1') "due at +2.0s: $($due -join ',')"
    Assert (@(Get-MirrorDue -Queue $q -Now $t0.AddMilliseconds(5000)).Count -eq 0) 'due key removed from pending'

    # mirror skips partial last line across all 3 harnesses
    $partialCases = @(
        @{ Harness = 'claude'; Src = $claudeSrc; Expected = 'Claude final answer.' },
        @{ Harness = 'codex'; Src = $codexSrc; Expected = 'Codex final answer.' },
        @{ Harness = 'antigravity'; Src = $agySrc; Expected = 'Antigravity final answer.' }
    )
    foreach ($pc in $partialCases) {
        $pCopy = Join-Path $fixture ("partial-$($pc.Harness).jsonl")
        Copy-Item -LiteralPath $pc.Src -Destination $pCopy
        [IO.File]::AppendAllText($pCopy, '{"type":"assistant","message":{"content":"cut', (New-Object Text.UTF8Encoding($false)))
        $pPin = [pscustomobject]@{
            harness = $pc.Harness; id = 'partial'; profileId = 'p'; title = 'Partial'; cwd = $cwd
            sourcePath = $pCopy; mirrorPath = (Join-Path $mirrorDir ("partial-$($pc.Harness).md"))
            codexSync = $false; codexProfileId = $null; lastSize = 0; lastTicks = 0; state = 'ok'
        }
        $pr = Export-MirrorPin -Pin $pPin -Now $tNow
        $pmd = [IO.File]::ReadAllText($pPin.mirrorPath)
        Assert ($pr -eq 'written' -and $pmd.Contains($pc.Expected)) "partial last line skipped for $($pc.Harness)"
    }

    # big source tail: > 50 MB reads only last 8 MB tail and notes it in header
    $bigPath = Join-Path $fixture 'big-claude.jsonl'
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $earlyBytes = $utf8NoBom.GetBytes('{"type":"user","timestamp":"t0","message":{"role":"user","content":"EARLY_MARKER_SHOULD_NOT_APPEAR"}}' + "`n")
    $padLine = '{"type":"user","timestamp":"t1","message":{"role":"user","content":"' + ('P' * 200) + '"}}' + "`n"
    $padChunk = $utf8NoBom.GetBytes($padLine * 4000) # ~960 KB per write
    $tailBytes = $utf8NoBom.GetBytes('{"type":"user","timestamp":"t2","message":{"role":"user","content":"FINAL_TAIL_TURN_VISIBLE"}}' + "`n" + '{"type":"assistant","timestamp":"t3","message":{"role":"assistant","content":[{"type":"text","text":"Tail reply ok."}]}}' + "`n")
    $fs = [IO.File]::Create($bigPath)
    try {
        $fs.Write($earlyBytes, 0, $earlyBytes.Length)
        for ($i = 0; $i -lt 54; $i++) { $fs.Write($padChunk, 0, $padChunk.Length) }
        $fs.Write($tailBytes, 0, $tailBytes.Length)
    } finally { $fs.Dispose() }
    Assert ((Get-Item -LiteralPath $bigPath).Length -gt 50MB) 'big fixture exceeds 50 MB'
    $bigPin = [pscustomobject]@{
        harness = 'claude'; id = 'big1'; profileId = 'Default'; title = 'Big Chat'; cwd = $cwd
        sourcePath = $bigPath; mirrorPath = (Join-Path $mirrorDir 'claude-big1.md')
        codexSync = $false; codexProfileId = $null; lastSize = 0; lastTicks = 0; state = 'ok'
    }
    [long]$bytesRead = 0
    $bigRes = Export-MirrorPin -Pin $bigPin -Now $tNow -BytesRead ([ref]$bytesRead)
    Assert ($bigRes -eq 'written') "big source export returned $bigRes"
    Assert ($bytesRead -gt 0 -and $bytesRead -le 8MB) "big source read $bytesRead bytes (limit 8 MB)"
    $bigMd = [IO.File]::ReadAllText($bigPin.mirrorPath)
    Assert ($bigMd.StartsWith('<!-- live mirror, updated ')) 'big mirror keeps live header on line 1'
    Assert ($bigMd -match '8 MB') 'big mirror notes 8 MB tail in header'
    Assert ($bigMd.Contains('FINAL_TAIL_TURN_VISIBLE') -and $bigMd.Contains('Tail reply ok.')) 'big mirror includes tail turns'
    Assert (-not $bigMd.Contains('EARLY_MARKER_SHOULD_NOT_APPEAR')) 'big mirror skipped earlier turns'

    # deleted or unpinned while pending
    $q2 = New-MirrorQueue
    Add-MirrorEvent -Queue $q2 -Key 'claude:local_c1' -Now $t0
    Add-MirrorEvent -Queue $q2 -Key 'codex:unpinned-id' -Now $t0
    Remove-Item -LiteralPath $claudeSrc -Force
    $livePins = @(Read-MirrorPins)
    $dueRes = @(Invoke-MirrorDue -Queue $q2 -Pins $livePins -Now $t0.AddMilliseconds(2500))
    Assert ($dueRes.Count -eq 1 -and $dueRes[0].Key -eq 'claude:local_c1' -and $dueRes[0].Result -eq 'missing') "deleted source returns missing without throw"
    $missingPin = $livePins | Where-Object { $_.harness -eq 'claude' -and $_.id -eq 'local_c1' } | Select-Object -First 1
    Assert ($missingPin.state -eq 'missing') 'pin state updated to missing'
    Assert (Test-Path -LiteralPath $missingPin.mirrorPath -PathType Leaf) 'existing mirror md kept when source missing'

    # one failing export does not stop the others
    $failPin = [pscustomobject]@{
        harness = 'codex'; id = 'a-fail'; profileId = 'work'; title = 'Fail Pin'; cwd = $cwd
        sourcePath = $zstSrc; mirrorPath = (Join-Path $mirrorDir 'codex-a-fail.md')
        codexSync = $false; codexProfileId = $null; lastSize = 0; lastTicks = 0; state = 'ok'
    }
    $okPin = [pscustomobject]@{
        harness = 'codex'; id = 'z-ok'; profileId = 'work'; title = 'Ok Pin'; cwd = $cwd
        sourcePath = $codexSrc; mirrorPath = (Join-Path $mirrorDir 'codex-z-ok.md')
        codexSync = $false; codexProfileId = $null; lastSize = 0; lastTicks = 0; state = 'ok'
    }
    $q3 = New-MirrorQueue
    Add-MirrorEvent -Queue $q3 -Key 'codex:a-fail' -Now $t0
    Add-MirrorEvent -Queue $q3 -Key 'codex:z-ok' -Now $t0
    $res3 = @(Invoke-MirrorDue -Queue $q3 -Pins @($failPin, $okPin) -Now $t0.AddMilliseconds(2500) -ZstEntries { param($c) throw 'zst reader boom' })
    Assert ($res3.Count -eq 2) "expected 2 results even when one export throws, got $($res3.Count)"
    $rFail = $res3 | Where-Object { $_.Key -eq 'codex:a-fail' } | Select-Object -First 1
    $rOk = $res3 | Where-Object { $_.Key -eq 'codex:z-ok' } | Select-Object -First 1
    Assert ($rFail -and $rFail.Result -eq 'error' -and -not [string]::IsNullOrEmpty($rFail.Error) -and $rFail.Error -like '*zst reader boom*' -and $failPin.state -eq 'error') 'failing export returns error result and sets state'
    Assert ($rOk -and $rOk.Result -eq 'written' -and $okPin.state -eq 'ok' -and (Test-Path -LiteralPath $okPin.mirrorPath -PathType Leaf)) 'healthy export still writes after failing pin'

    Write-Output 'HarnessMirror: OK'
} finally {
    Remove-TestTempDir $fixture
}
