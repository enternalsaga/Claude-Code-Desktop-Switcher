# Builds the one-file release: copies ClaudeSwitcher.ps1 and replaces everything between the
# "# >>> harness-src" and "# <<< harness-src" marker lines with the contents of src\*.ps1,
# in a fixed order. The result goes to dist\ClaudeSwitcher.ps1 (dist\ is git-ignored).
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$Script = (Join-Path $Root 'ClaudeSwitcher.ps1'),
    [string]$SrcDir = (Join-Path $Root 'src'),
    [string]$OutPath = (Join-Path $Root 'dist\ClaudeSwitcher.ps1')
)
$ErrorActionPreference = 'Stop'

# Files not listed here are appended in name order, so a new adapter is never silently left out.
$order = @(
    'Harness.Core.ps1', 'Harness.Sqlite.ps1', 'Harness.Claude.ps1',
    'Harness.Codex.Profiles.ps1', 'Harness.Codex.Chats.ps1',
    'Harness.Antigravity.Profiles.ps1', 'Harness.Antigravity.Chats.ps1',
    'Sync.Drive.ps1', 'Ui.Harness.ps1'
)
$present = @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1' -File | ForEach-Object { $_.Name })
$files = @($order | Where-Object { $present -contains $_ }) + @($present | Where-Object { $order -notcontains $_ } | Sort-Object)

$lines = [IO.File]::ReadAllLines($Script)
$start = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l.Trim() -eq '# >>> harness-src' })
$end = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l.Trim() -eq '# <<< harness-src' })
if ($start -lt 0 -or $end -lt 0 -or $end -le $start) { throw "Marker lines '# >>> harness-src' / '# <<< harness-src' not found in $Script" }

$body = New-Object Collections.Generic.List[string]
foreach ($f in $files) {
    $body.Add("# ---- src\$f ----")
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $SrcDir $f))) { $body.Add($l) }
}
$result = @($lines[0..$start]) + $body.ToArray() + @($lines[$end..($lines.Length - 1)])
$dir = Split-Path -Parent $OutPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutPath, (($result -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
Write-Output "Built $OutPath from $($files.Count) source file(s)."
