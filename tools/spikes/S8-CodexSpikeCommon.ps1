# Spike S8 helper: dot-sources the S2a app-server client and widens its safety guard to the spike profiles.
# Allowed CODEX_HOME: %TEMP%\harness-spike\... or %USERPROFILE%\.codex-profiles\spike*. Never the real ~\.codex.
. (Join-Path $PSScriptRoot 'S2a-AppServerClient.ps1')

function Assert-SpikeHome([string]$Home_) {
    $full = [IO.Path]::GetFullPath($Home_).TrimEnd('\')
    $tmp = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'harness-spike')) + '\'
    $prof = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex-profiles')) + '\spike'
    $real = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')).TrimEnd('\')
    if ($full -ieq $real) { throw 'refusing real ~\.codex' }
    if (-not ($full.StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($prof, [StringComparison]::OrdinalIgnoreCase))) {
        throw "CODEX_HOME is not a spike home: $full"
    }
}

# Rows of a scratch/spike home's state_5.sqlite via a snapshot copy (never opens the live file).
function Get-SpikeThreadIds([string]$CodexHome) {
    . (Join-Path $PSScriptRoot '..\..\src\Harness.Sqlite.ps1')
    $db = Join-Path $CodexHome 'state_5.sqlite'
    if (-not (Test-Path -LiteralPath $db)) { return @() }
    $snap = Copy-SqliteSnapshot $db
    try {
        $h = Open-SqliteReadOnly $snap
        try { return @(Invoke-SqliteQuery $h 'select id from threads' | ForEach-Object { $_.id }) } finally { Close-Sqlite $h }
    } finally { Remove-Item -LiteralPath (Split-Path $snap) -Recurse -Force -ErrorAction SilentlyContinue }
}

function Test-SpikeAppRunning([string]$ProfileName) {
    $p = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($ProfileName) -and $_.CommandLine -notmatch '--type=' })
    return ($p.Count -gt 0)
}
