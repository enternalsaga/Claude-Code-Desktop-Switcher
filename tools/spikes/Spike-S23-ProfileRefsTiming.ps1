# Spike S23: cold and hot timing of Get-ClaudeProfileRefs and 100% metadata parity on real local_*.json files.
# READ ONLY: never saves a cache or modifies app data. ASCII only. Run: powershell -NoProfile -ExecutionPolicy Bypass -File <this>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

# Load the app's own functions without running the UI (same pattern as Spike-S22-ScanPhaseTiming.ps1).
$script:ProfileRoot = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
$script:ProfileDirPrefix = 'ClaudeProfile-'
$script:SwitcherHome = Join-Path $script:ProfileRoot '.switcher'
$script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
$script:DefaultName = 'Default'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ClaudeSwitcher.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach ($f in Get-ChildItem (Join-Path $repo 'src') -Filter '*.ps1' | Where-Object { $_.Name -notlike 'Ui*' }) { . $f.FullName }
$ClaudePath = $null
Update-ClaudeInstall -AllowCache

$roots = Get-StorageRootsFromConfig -Config $null
$profiles = @($roots.ClaudeProfiles)

$files = New-Object Collections.Generic.List[object]
foreach ($p in $profiles) {
    $root = [string]$p.SessionRoot
    if (-not $root -or -not [IO.Directory]::Exists($root)) { continue }
    foreach ($acct in @(Get-StorageEntries -Dir $root | Where-Object { $_ -is [IO.DirectoryInfo] })) {
        foreach ($org in @(Get-StorageEntries -Dir $acct.FullName | Where-Object { $_ -is [IO.DirectoryInfo] })) {
            foreach ($f in @(Get-StorageEntries -Dir $org.FullName | Where-Object { $_ -is [IO.FileInfo] -and $_.Name -like 'local_*.json' })) {
                $files.Add($f)
            }
        }
    }
}

$totalBytes = [long]0
$maxBytes = [long]0
foreach ($f in $files) {
    $totalBytes += $f.Length
    if ($f.Length -gt $maxBytes) { $maxBytes = $f.Length }
}
"profiles {0}, files {1}, total {2:N1} MB, max {3:N0} KB" -f $profiles.Count, $files.Count, ($totalBytes / 1MB), ($maxBytes / 1KB)

$c = New-StorageCache
$wCold = New-Object Collections.Generic.List[string]
$sw = [Diagnostics.Stopwatch]::StartNew()
$rCold = @(Get-ClaudeProfileRefs -Profiles $profiles -Cache $c -Warnings $wCold)
$sw.Stop()
$coldSec = $sw.Elapsed.TotalSeconds
"Get-ClaudeProfileRefs cold: {0:N3} s, refs {1}, reads {2}, warnings {3}" -f $coldSec, $rCold.Count, $c.Reads, $wCold.Count

$readsBefore = $c.Reads
$wHot = New-Object Collections.Generic.List[string]
$sw.Restart()
$rHot = @(Get-ClaudeProfileRefs -Profiles $profiles -Cache $c -Warnings $wHot)
$sw.Stop()
$hotSec = $sw.Elapsed.TotalSeconds
"Get-ClaudeProfileRefs hot:  {0:N3} s, refs {1}, reads {2}, warnings {3}" -f $hotSec, $rHot.Count, ($c.Reads - $readsBefore), $wHot.Count

function Get-S23OldFirstString {
    param($Object, [string[]]$Names)
    if (-not $Object) { return $null }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $p.Value -is [string] -and $p.Value.Trim()) { return $p.Value.Trim() }
    }
    return $null
}

function Read-S23OldLocalMeta {
    param([Parameter(Mandatory)][string]$Path)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
    $o = $text | ConvertFrom-Json
    if ($o -isnot [pscustomobject]) { throw 'the file is not a JSON object' }
    $act = $null; $created = $null
    if ($o -and $o.PSObject.Properties['lastActivityAt'] -and $o.lastActivityAt -is [ValueType]) { $act = [long]$o.lastActivityAt }
    if ($o -and $o.PSObject.Properties['createdAt'] -and $o.createdAt -is [ValueType]) { $created = [long]$o.createdAt }
    return @{ cli = (Get-S23OldFirstString $o @('cliSessionId')); title = (Get-S23OldFirstString $o @('title', 'name', 'summary', 'customTitle', 'displayName'))
        cwd = (Get-S23OldFirstString $o @('cwd', 'originCwd', 'workingDirectory')); activity = $act; created = $created }
}

function Test-S23SameLocalMeta {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    foreach ($k in 'cli', 'title', 'cwd') {
        $av = $A[$k]; $bv = $B[$k]
        if (($null -eq $av) -ne ($null -eq $bv)) { return $false }
        if ($null -ne $av -and ($av -isnot [string] -or $bv -isnot [string] -or -not ($av -ceq $bv))) { return $false }
    }
    foreach ($k in 'activity', 'created') {
        $av = $A[$k]; $bv = $B[$k]
        if (($null -eq $av) -ne ($null -eq $bv)) { return $false }
        if ($null -ne $av -and ($av -isnot [long] -or $bv -isnot [long] -or [long]$av -ne [long]$bv)) { return $false }
    }
    return $true
}

function Invoke-S23ReadPair {
    param([Parameter(Mandatory)][string]$Path, $CachedMeta)
    $newMeta = $null; $newErr = $null
    try { $newMeta = Read-StorageLocalMeta -Path $Path } catch { $newErr = $_.Exception.Message }
    $oldMeta = $null; $oldErr = $null
    try { $oldMeta = Read-S23OldLocalMeta -Path $Path } catch { $oldErr = $_.Exception.Message }
    $ok = $false
    if ($null -ne $newErr -and $null -ne $oldErr) {
        $ok = ($null -eq $CachedMeta)
    } elseif ($null -eq $newErr -and $null -eq $oldErr) {
        $ok = Test-S23SameLocalMeta $newMeta $oldMeta
        if ($ok -and $null -ne $CachedMeta) {
            $ok = Test-S23SameLocalMeta $CachedMeta $oldMeta
        }
    }
    return [pscustomobject]@{ Ok = $ok; BothErr = ($null -ne $newErr -and $null -ne $oldErr); NewMeta = $newMeta; OldMeta = $oldMeta; NewErr = $newErr; OldErr = $oldErr }
}

$checked = 0
$unreadable = 0
$retried = 0
$mismatches = 0
$mismatchDetails = New-Object Collections.Generic.List[string]

foreach ($f in $files) {
    $checked++
    $p = $f.FullName
    $cached = $(if ($c.Entries.ContainsKey($p)) { $c.Entries[$p]['meta'] } else { $null })
    $cmp = Invoke-S23ReadPair -Path $p -CachedMeta $cached
    if (-not $cmp.Ok) {
        $retried++
        $cmp = Invoke-S23ReadPair -Path $p -CachedMeta $null
    }
    if ($cmp.Ok) {
        if ($cmp.BothErr) { $unreadable++ }
    } else {
        $mismatches++
        if ($mismatchDetails.Count -lt 10) {
            $ns = $(if ($cmp.NewErr) { "ERR:$($cmp.NewErr)" } else { $cmp.NewMeta | ConvertTo-Json -Compress })
            $os = $(if ($cmp.OldErr) { "ERR:$($cmp.OldErr)" } else { $cmp.OldMeta | ConvertTo-Json -Compress })
            $mismatchDetails.Add("$p | new=$ns | old=$os")
        }
    }
}

"parity: checked={0}, unreadable={1}, retried={2}, mismatches={3}" -f $checked, $unreadable, $retried, $mismatches
if ($mismatches -gt 0) {
    foreach ($d in $mismatchDetails) { Write-Output "MISMATCH: $d" }
    throw "Parity check failed with $mismatches mismatch(es)"
}
