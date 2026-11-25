$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
$core = Join-Path $root 'src\Harness.Core.ps1'
$claude = Join-Path $root 'src\Harness.Claude.ps1'
$codex = Join-Path $root 'src\Harness.Codex.Chats.ps1'
$agy = Join-Path $root 'src\Harness.Antigravity.Chats.ps1'
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-SecretPatterns', 'Invoke-SecretScan', 'Protect-TranscriptText', 'Protect-TranscriptEntries'
))
. (Import-TestFunctions -Files @($claude) -Names @(
    'Get-ClaudeToolArg', 'ConvertTo-ClaudeResultText', 'ConvertFrom-ClaudeJsonl'
))
. (Import-TestFunctions -Files @($codex) -Names @(
    'ConvertTo-CodexToolOutput', 'Get-CodexToolArg', 'Test-CodexSystemMessage', 'ConvertFrom-CodexRollout'
))
. (Import-TestFunctions -Files @($agy) -Names @(
    'Get-AgyToolArg', 'Get-AgyUserText', 'Get-AgySystemStepTypes', 'ConvertFrom-AgyTranscriptJsonl'
))

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
}

Write-Output 'XharnessParity: OK'
