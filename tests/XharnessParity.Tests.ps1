$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
$switcher = Join-Path $root 'ClaudeSwitcher.ps1'
$core = Join-Path $root 'src\Harness.Core.ps1'
$claude = Join-Path $root 'src\Harness.Claude.ps1'
$codex = Join-Path $root 'src\Harness.Codex.Chats.ps1'
$agy = Join-Path $root 'src\Harness.Antigravity.Chats.ps1'
$mirror = Join-Path $root 'src\Harness.Mirror.ps1'
. (Import-TestFunctions -Files @($switcher) -Names @('Get-FirstValue', 'Read-ChatJson'))
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-SecretPatterns', 'Invoke-SecretScan', 'Protect-TranscriptText', 'Protect-TranscriptEntries'
))
. (Import-TestFunctions -Files @($claude) -Names @(
    'Get-ClaudeToolArg', 'ConvertTo-ClaudeResultText', 'ConvertFrom-ClaudeJsonl',
    'ConvertTo-ClaudeProjectSlug', 'Get-ClaudeHomePath', 'Find-ClaudeProjectDir'
))
. (Import-TestFunctions -Files @($codex) -Names @(
    'ConvertTo-CodexToolOutput', 'Get-CodexToolArg', 'Test-CodexSystemMessage', 'ConvertFrom-CodexRollout',
    'ConvertFrom-CodexPath', 'Resolve-CodexRolloutFile'
))
. (Import-TestFunctions -Files @($agy) -Names @(
    'Get-AgyToolArg', 'Get-AgyUserText', 'Get-AgySystemStepTypes', 'ConvertFrom-AgyTranscriptJsonl'
))
. $mirror

function Test-NodeSupported {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    $verText = (& $cmd.Source --version 2>$null | Out-String).Trim()
    if ($verText -notmatch '^v?(\d+)\.(\d+)\.') { return $false }
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]
    return ($maj -gt 22 -or ($maj -eq 22 -and $min -ge 15))
}

function Invoke-NodeDump {
    param([Parameter(Mandatory)][Alias('Args')][string[]]$ArgumentList)
    $cmd = Get-Command node -ErrorAction Stop
    $dumpPath = Join-Path $root 'mcp\harness-transcripts\dump.mjs'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Source
    $quoted = @($dumpPath) + $ArgumentList | ForEach-Object {
        '"' + ($_ -replace '"', '\"') + '"'
    }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "node dump.mjs exited $($proc.ExitCode): $stderr"
    }
    return $stdout
}

$samplesPath = Join-Path $PSScriptRoot 'fixtures\xharness\secret-samples.json'
$samples = Get-Content -LiteralPath $samplesPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($s in $samples) {
    Assert ((Protect-TranscriptText $s.in) -ceq $s.out) "PS sample: $($s.in)"
}

if (-not (Test-NodeSupported)) {
    Write-Output 'XharnessParity: node not found, entry parity skipped'
} else {
    $fxDir = Join-Path $PSScriptRoot 'fixtures\xharness'
    $cases = @(
        @{ Harness = 'claude'; File = (Join-Path $fxDir 'claude-session.jsonl'); Reader = { param($p) ConvertFrom-ClaudeJsonl -Path $p } },
        @{ Harness = 'codex'; File = (Join-Path $fxDir 'codex-rollout.jsonl'); Reader = { param($p) ConvertFrom-CodexRollout -Path $p } },
        @{ Harness = 'antigravity'; File = (Join-Path $fxDir 'agy-transcript.jsonl'); Reader = { param($p) ConvertFrom-AgyTranscriptJsonl -Path $p } }
    )
    foreach ($c in $cases) {
        $psRaw = @(& $c.Reader $c.File)
        $psRedacted = @(Protect-TranscriptEntries -Entries $psRaw)
        $psProjected = @($psRedacted | ForEach-Object {
            [pscustomobject]@{
                role = [string]$_.role
                text = [string]$_.text
                tool = $(if ($_.tool) { [string]$_.tool.name } else { $null })
            }
        })
        $nodeJson = Invoke-NodeDump -Args @($c.Harness, $c.File)
        $parsedNode = $nodeJson | ConvertFrom-Json
        $nodeEntries = @($parsedNode)
        Assert ($psProjected.Count -eq $nodeEntries.Count) "$($c.Harness) entry count mismatch: ps=$($psProjected.Count) node=$($nodeEntries.Count)"
        for ($i = 0; $i -lt $psProjected.Count; $i++) {
            $p = $psProjected[$i]; $n = $nodeEntries[$i]
            Assert ($p.role -ceq $n.role) "$($c.Harness)[$i].role mismatch: $($p.role) vs $($n.role)"
            Assert ($p.text -ceq $n.text) "$($c.Harness)[$i].text mismatch: [$($p.text)] vs [$($n.text)]"
            Assert ($p.tool -ceq $n.tool) "$($c.Harness)[$i].tool mismatch: $($p.tool) vs $($n.tool)"
        }
    }

    # mcpId parity across all 3 harnesses against Node listSessions
    $idTemp = New-TestTempDir
    try {
        $script:SwitcherHome = Join-Path $idTemp 'switcher'
        $cHome = Join-Path $idTemp 'claude'
        $xHome = Join-Path $idTemp 'codex'
        $aHome = Join-Path $idTemp 'agy'
        $cUuid = '11111111-1111-1111-1111-111111111111'
        $xUuid = '22222222-2222-2222-2222-222222222222'
        $aUuid = '33333333-3333-3333-3333-333333333333'
        $cProj = Join-Path $cHome 'projects\C--work-demo'
        $xSess = Join-Path $xHome 'sessions\2026\11\25'
        $aLogs = Join-Path $aHome "brain\$aUuid\.system_generated\logs"
        New-Item -ItemType Directory -Path $cProj, $xSess, $aLogs -Force | Out-Null
        $cFile = Join-Path $cProj "$cUuid.jsonl"
        $xFile = Join-Path $xSess "rollout-2026-11-25T10-00-00-$xUuid.jsonl"
        $aFile = Join-Path $aLogs 'transcript.jsonl'
        Copy-Item -LiteralPath (Join-Path $fxDir 'claude-session.jsonl') -Destination $cFile
        Copy-Item -LiteralPath (Join-Path $fxDir 'codex-rollout.jsonl') -Destination $xFile
        Copy-Item -LiteralPath (Join-Path $fxDir 'agy-transcript.jsonl') -Destination $aFile

        $pinDir = Join-Path $idTemp 'pins'
        $psClaude = Add-MirrorPin -Harness 'claude' -Dir $pinDir -ClaudeHome $cHome -Chat ([pscustomobject]@{
            ChatId = 'local_e503005d-213d-41e4-8cf7-3457de519fa8'; CliSessionId = $cUuid; Cwd = 'C:\work\demo'; Title = 'C'
            Profile = [pscustomobject]@{ Id = 'Default' }
        })
        $psCodex = Add-MirrorPin -Harness 'codex' -Dir $pinDir -Chat ([pscustomobject]@{
            ChatId = $xUuid; RolloutPath = $xFile; Cwd = 'C:\work\demo'; Title = 'X'
            Profile = [pscustomobject]@{ Id = 'Default' }
        })
        $psAgy = Add-MirrorPin -Harness 'antigravity' -Dir $pinDir -Chat ([pscustomobject]@{
            ChatId = $aUuid; Cwd = 'C:\work\demo'; Title = 'A'
            Profile = [pscustomobject]@{ Id = 'app'; DataDir = $aHome }
        })

        $sessionsJsUrl = ([uri](Join-Path $root 'mcp\harness-transcripts\sessions.mjs')).AbsoluteUri
        $nodeCmd = (Get-Command node -ErrorAction Stop).Source
        $prevC = $env:HT_CLAUDE_HOME; $prevX = $env:HT_CODEX_HOMES; $prevA = $env:HT_AGY_HOME
        try {
            $env:HT_CLAUDE_HOME = $cHome; $env:HT_CODEX_HOMES = $xHome; $env:HT_AGY_HOME = $aHome
            $nodeOut = & $nodeCmd --input-type=module -e "import { getRoots, listSessions } from '$sessionsJsUrl'; console.log(JSON.stringify(await listSessions(getRoots(), {})));"
            Assert ($LASTEXITCODE -eq 0) "node listSessions failed with exit $LASTEXITCODE"
        } finally {
            $env:HT_CLAUDE_HOME = $prevC; $env:HT_CODEX_HOMES = $prevX; $env:HT_AGY_HOME = $prevA
        }
        $parsedSessions = $nodeOut | ConvertFrom-Json
        $nodeSessions = @($parsedSessions)
        Assert ($nodeSessions.Count -eq 3) "expected 3 node sessions, got $($nodeSessions.Count): $nodeOut"
        $byH = @{}; foreach ($ns in $nodeSessions) { $byH[[string]$ns.harness] = [string]$ns.id }
        Assert (-not [string]::IsNullOrEmpty($psClaude.mcpId)) 'psClaude.mcpId empty'
        Assert ($psClaude.mcpId -ceq $byH['claude']) "claude mcpId parity: ps=$($psClaude.mcpId) node=$($byH['claude'])"
        Assert ($psCodex.mcpId -ceq $byH['codex']) "codex mcpId parity: ps=$($psCodex.mcpId) node=$($byH['codex'])"
        Assert ($psAgy.mcpId -ceq $byH['antigravity']) "antigravity mcpId parity: ps=$($psAgy.mcpId) node=$($byH['antigravity'])"
    } finally {
        Remove-TestTempDir $idTemp
    }
}

Write-Output 'XharnessParity: OK'
