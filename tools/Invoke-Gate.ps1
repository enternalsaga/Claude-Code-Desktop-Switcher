# Full local gate: parse every script, run every tests\*.Tests.ps1 (Windows PowerShell 5.1, plus
# PowerShell 7 when pwsh is installed), then PSScriptAnalyzer. Like CI, only Error-level lint findings
# fail. Exits non-zero when anything failed. Run it once per batch, never alongside another suite.
param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Root
$failures = New-Object Collections.Generic.List[string]
function Get-Scripts { Get-ChildItem -Recurse -Filter *.ps1 -File | Where-Object { $_.FullName -notmatch '\\(\.worktrees|dist|\.git)\\' } }

Write-Host '== parse'
foreach ($f in Get-Scripts) {
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
    foreach ($e in $errors) { $failures.Add("parse: $($f.Name):$($e.Extent.StartLineNumber) $($e.Message)") }
}

$hosts = @(@{ Name = 'powershell 5.1'; Exe = 'powershell' })
if (Get-Command pwsh -ErrorAction SilentlyContinue) { $hosts += @{ Name = 'pwsh 7'; Exe = 'pwsh' } }
foreach ($h in $hosts) {
    foreach ($t in Get-ChildItem -LiteralPath (Join-Path $Root 'tests') -Filter '*.Tests.ps1' -File) {
        Write-Host "== $($h.Name): $($t.Name)"
        & $h.Exe -NoProfile -ExecutionPolicy Bypass -File $t.FullName
        if ($LASTEXITCODE -ne 0) { $failures.Add("$($h.Name): $($t.Name) exited $LASTEXITCODE") }
    }
}

Write-Host '== PSScriptAnalyzer (errors only)'
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    foreach ($f in Get-Scripts) {
        foreach ($r in @(Invoke-ScriptAnalyzer -Path $f.FullName -Severity Error)) { $failures.Add("lint: $($f.Name):$($r.Line) $($r.RuleName): $($r.Message)") }
    }
} else {
    Write-Host 'PSScriptAnalyzer not installed: skipped (CI still runs it).'
}

if ($failures.Count) {
    Write-Host "`nGATE FAILED ($($failures.Count)):"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "`nGATE PASSED"
exit 0
