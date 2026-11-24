# Spike S21: cold first-scan timing and 100% metadata parity on real ~\.claude\projects transcripts.
# READ ONLY under ProjectsRoot; writes only a temporary cache in %TEMP% and removes it before returning. ASCII only.
param([string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.claude\projects'))
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ProjectsRoot)) { throw "ProjectsRoot not found: $ProjectsRoot" }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'src\Storage.Scan.ps1')
. (Join-Path $repoRoot 'src\Storage.Inventory.ps1')

function Invoke-S21SeqPass {
    param([array]$Subset, $Cache, [hashtable]$Errors)
    foreach ($it in $Subset) {
        try {
            [void](Get-StorageCachedMeta -Cache $Cache -Key $it.Key -Size $it.Size -Ticks $it.Ticks -Reader { param($k) Read-StorageClaudeJsonlMeta -Path $k })
        } catch {
            $Errors[$it.Key] = $_.Exception.Message
        }
    }
}

function Test-S21SameMeta {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if (-not ($A['title'] -ceq $B['title'])) { return $false }
    if (-not ($A['cwd'] -ceq $B['cwd'])) { return $false }
    foreach ($k in 'first', 'last') {
        $av = $A[$k]; $bv = $B[$k]
        if (($null -eq $av) -ne ($null -eq $bv)) { return $false }
        if ($null -ne $av -and [long]$av -ne [long]$bv) { return $false }
    }
    return $true
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$transcripts = @(Get-ClaudeTranscripts -ProjectsDir $ProjectsRoot)
$enumMs = $sw.ElapsedMilliseconds

$items = New-Object Collections.Generic.List[object]
$totalBytes = [long]0
$placeholders = 0
foreach ($t in $transcripts) {
    if (-not $t.File) { continue }
    $f = $t.File
    $totalBytes += $f.Length
    if (Test-StorageCloudPlaceholder $f.Attributes) { $placeholders++; continue }
    $items.Add(@{ Key = $f.FullName; Size = [long]$f.Length; Ticks = $f.LastWriteTimeUtc.Ticks })
}
if ($items.Count -lt 2) { throw "Need at least 2 readable transcripts under $ProjectsRoot, found $($items.Count)" }

$halfA = New-Object Collections.Generic.List[object]
$halfB = New-Object Collections.Generic.List[object]
for ($i = 0; $i -lt $items.Count; $i++) {
    if (($i % 2) -eq 0) { $halfA.Add($items[$i]) } else { $halfB.Add($items[$i]) }
}

$threads = [Math]::Min(8, [Environment]::ProcessorCount)
Write-Output ("transcripts: {0} files, {1} GB, placeholders skipped: {2}, enum: {3} ms, pool threads: {4}" -f $items.Count, [math]::Round($totalBytes / 1GB, 2), $placeholders, $enumMs, $threads)
Write-Output 'cold-cache method: disjoint interleaved halves (even indices = cold sequential, odd indices = cold parallel)'

$seqCache = New-StorageCache
$seqErr = @{}
$sw.Restart()
Invoke-S21SeqPass -Subset $halfA.ToArray() -Cache $seqCache -Errors $seqErr
$sw.Stop()
$seqHalfSec = $sw.Elapsed.TotalSeconds

$parCache = New-StorageCache
$sw.Restart()
Read-StorageClaudeMetaParallel -Misses $halfB.ToArray() -Cache $parCache
$sw.Stop()
$parHalfSec = $sw.Elapsed.TotalSeconds

$seqEstSec = $seqHalfSec * ($items.Count / [double]$halfA.Count)
$parEstSec = $parHalfSec * ($items.Count / [double]$halfB.Count)
$seqMsPer = ($seqHalfSec * 1000.0) / $halfA.Count
$parMsPer = ($parHalfSec * 1000.0) / $halfB.Count
$speedup = $(if ($parEstSec -gt 0) { $seqEstSec / $parEstSec } else { 0 })

Write-Output ("cold sequential (Half A, {0} files): {1} s ({2} ms/file; extrapolated full {3} files: {4} s)" -f $halfA.Count, [math]::Round($seqHalfSec, 2), [math]::Round($seqMsPer, 2), $items.Count, [math]::Round($seqEstSec, 2))
Write-Output ("cold parallel   (Half B, {0} files): {1} s ({2} ms/file; extrapolated full {3} files: {4} s)" -f $halfB.Count, [math]::Round($parHalfSec, 2), [math]::Round($parMsPer, 2), $items.Count, [math]::Round($parEstSec, 2))
Write-Output ("speedup: {0}x" -f [math]::Round($speedup, 2))

# Cross-check the remaining halves so every file has both sequential and parallel metadata for 100% parity verification.
Invoke-S21SeqPass -Subset $halfB.ToArray() -Cache $seqCache -Errors $seqErr
Read-StorageClaudeMetaParallel -Misses $halfA.ToArray() -Cache $parCache

$mismatches = 0
$unreadable = 0
$liveRetried = 0
$mismatchDetails = New-Object Collections.Generic.List[string]
foreach ($it in $items) {
    $k = $it.Key
    $seqFailed = $seqErr.ContainsKey($k)
    $parHas = $parCache.Entries.ContainsKey($k)
    $ok = $false
    if ($seqFailed -and -not $parHas) {
        $unreadable++; $ok = $true
    } elseif (-not $seqFailed -and $parHas) {
        $ok = Test-S21SameMeta $seqCache.Entries[$k]['meta'] $parCache.Entries[$k]['meta']
    }
    if (-not $ok) {
        $fiNow = New-Object IO.FileInfo $k
        if ($fiNow.Exists -and ($fiNow.Length -ne $it.Size -or $fiNow.LastWriteTimeUtc.Ticks -ne $it.Ticks)) {
            for ($try = 0; $try -lt 2; $try++) {
                $fiBefore = New-Object IO.FileInfo $k
                $sErr = @{}; $sOne = New-StorageCache; $pOne = New-StorageCache
                $one = @(@{ Key = $k; Size = [long]$fiBefore.Length; Ticks = $fiBefore.LastWriteTimeUtc.Ticks })
                $pad = $(if ($items[0].Key -ne $k) { $items[0] } else { $items[1] })
                Invoke-S21SeqPass -Subset $one -Cache $sOne -Errors $sErr
                Read-StorageClaudeMetaParallel -Misses @($one[0], $pad) -Cache $pOne -MaxThreads 2
                $fiAfter = New-Object IO.FileInfo $k
                if ($fiAfter.Length -ne $fiBefore.Length -or $fiAfter.LastWriteTimeUtc.Ticks -ne $fiBefore.LastWriteTimeUtc.Ticks) { continue }
                if (($sErr.ContainsKey($k) -and -not $pOne.Entries.ContainsKey($k)) -or ((-not $sErr.ContainsKey($k)) -and $pOne.Entries.ContainsKey($k) -and (Test-S21SameMeta $sOne.Entries[$k]['meta'] $pOne.Entries[$k]['meta']))) {
                    $liveRetried++; $ok = $true; break
                }
            }
        }
    }
    if (-not $ok) {
        $mismatches++
        if ($mismatchDetails.Count -lt 10) {
            $sm = $(if ($seqCache.Entries.ContainsKey($k)) { $seqCache.Entries[$k]['meta'] | ConvertTo-Json -Compress } else { "ERR:$($seqErr[$k])" })
            $pm = $(if ($parCache.Entries.ContainsKey($k)) { $parCache.Entries[$k]['meta'] | ConvertTo-Json -Compress } else { 'MISSING' })
            $mismatchDetails.Add("$k | seq=$sm | par=$pm")
        }
    }
}

Write-Output ("parity: checked={0}, mismatches={1}, unreadable={2}, live_retried={3}" -f $items.Count, $mismatches, $unreadable, $liveRetried)

$cachePath = Join-Path $env:TEMP ('harness-spike-S21-cache-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    Write-StorageCache -Cache $parCache -Path $cachePath
    $kb = [int]((Get-Item -LiteralPath $cachePath).Length / 1KB)
    Write-Output "temp cache written: $kb KB"
} finally {
    if (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath -Force }
    Write-Output "cache removed: $(-not (Test-Path -LiteralPath $cachePath))"
}

if ($mismatches -gt 0) {
    foreach ($d in $mismatchDetails) { Write-Output "MISMATCH: $d" }
    throw "Parity check failed with $mismatches mismatch(es)"
}
