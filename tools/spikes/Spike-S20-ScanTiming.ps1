# Spike S20: how long does the inventory scan take on the real ~\.claude\projects? READ ONLY: lists files and reads the first and last
# 64 KB of each jsonl; writes nothing under the data folder. The cache lives in %TEMP% and is deleted at the end.
#   pass 1: no scanner cache  (enumerate + read head and tail of every file)
#   pass 2: hot cache         (enumerate, compare size + mtime with the cache, read nothing)
#   pass 3: hot cache, 1% of the files pretended to have changed (only those are read again)
# The OS file cache is not flushed, so pass 1 is "no scanner cache" and may be partly warm; whether it was cold is reported by the
# bytes/second of pass 1 (a cold disk read is far slower).
param([string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.claude\projects'), [int]$ChunkKB = 64)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ProjectsRoot)) { throw 'projects root not found' }
$cachePath = Join-Path $env:TEMP 'harness-spike-S20-cache.json'
$chunk = $ChunkKB * 1024

function Get-JsonlFiles([string]$Root) {
    # the way the scanner will do it: EnumerateDirectories + FileInfo from the directory listing, reparse points skipped, errors per folder
    $found = New-Object Collections.Generic.List[IO.FileInfo]; $errors = 0
    $stack = New-Object Collections.Generic.Stack[string]; $stack.Push($Root)
    while ($stack.Count) {
        $dir = New-Object IO.DirectoryInfo($stack.Pop())
        try {
            foreach ($f in $dir.EnumerateFiles('*.jsonl')) { if (-not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $found.Add($f) } }
            foreach ($d in $dir.EnumerateDirectories()) { if (-not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($d.FullName) } }
        } catch { $errors++ }
    }
    return [pscustomobject]@{ Files = $found; Errors = $errors }
}
function Read-HeadTail([IO.FileInfo]$File) {
    $fs = [IO.File]::Open($File.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        $n = [int][Math]::Min($chunk, $fs.Length); $head = New-Object byte[] $n; [void]$fs.Read($head, 0, $n); $read = $n
        $tailText = ''
        if ($fs.Length -gt $chunk) { $fs.Seek(-$chunk, 'End') | Out-Null; $t = New-Object byte[] $chunk; [void]$fs.Read($t, 0, $chunk); $read += $chunk; $tailText = [Text.Encoding]::UTF8.GetString($t) }
        $headText = [Text.Encoding]::UTF8.GetString($head)
        $cwd = if ($headText -match '"cwd":"((?:[^"\\]|\\.)*)"') { $Matches[1] } else { $null }
        # last timestamp by LastIndexOf: a greedy ".*" regex over 128 KB backtracks and made the first run take over half an hour
        $src = if ($tailText) { $tailText } else { $headText }
        $i = $src.LastIndexOf('"timestamp":"')
        $last = if ($i -ge 0) { $e = $src.IndexOf('"', $i + 13); if ($e -gt 0) { $src.Substring($i + 13, $e - $i - 13) } else { $null } } else { $null }
        return [pscustomobject]@{ Cwd = $cwd; Last = $last; Bytes = $read }
    } finally { $fs.Dispose() }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$list = Get-JsonlFiles $ProjectsRoot
$enumMs = $sw.ElapsedMilliseconds
$files = $list.Files
$totalBytes = ($files | Measure-Object Length -Sum).Sum
"files: $($files.Count), total $([math]::Round($totalBytes / 1GB, 1)) GB, largest $([int](($files | Measure-Object Length -Maximum).Maximum / 1MB)) MB, enumeration errors: $($list.Errors)"
"enumeration only: $enumMs ms"

# pass 1
$cache = @{}; $readBytes = [long]0; $sw.Restart(); $bad = 0
foreach ($f in $files) {
    try { $m = Read-HeadTail $f; $readBytes += $m.Bytes; $cache[$f.FullName] = @{ s = $f.Length; t = $f.LastWriteTimeUtc.Ticks; c = $m.Cwd; l = $m.Last } } catch { $bad++ }
}
$p1 = $sw.Elapsed.TotalSeconds
"pass 1 (no scanner cache): $([math]::Round($p1, 1)) s plus enumeration $([math]::Round($enumMs / 1000, 1)) s; read $([math]::Round($readBytes / 1MB)) MB ($([math]::Round($readBytes / 1MB / [math]::Max($p1, 0.1))) MB/s); unreadable files: $bad"
$cache | ConvertTo-Json -Compress -Depth 3 | Set-Content -LiteralPath $cachePath -Encoding UTF8
"cache file: $([int]((Get-Item $cachePath).Length / 1KB)) KB"

# pass 2: load the cache from disk, enumerate again, compare
$sw.Restart()
$loaded = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
$lookup = @{}; foreach ($p in $loaded.PSObject.Properties) { $lookup[$p.Name] = $p.Value }
$loadMs = $sw.ElapsedMilliseconds
$list2 = Get-JsonlFiles $ProjectsRoot
$changed = @($list2.Files | Where-Object { $e = $lookup[$_.FullName]; -not $e -or $e.s -ne $_.Length -or $e.t -ne $_.LastWriteTimeUtc.Ticks })
$p2 = $sw.Elapsed.TotalSeconds
"pass 2 (hot cache): $([math]::Round($p2, 1)) s in total (cache load $loadMs ms); files needing a re-read: $($changed.Count)"

# pass 3: 1% re-read
$sw.Restart()
$every = [math]::Max(1, [int]($list2.Files.Count / [math]::Max(1, [int]($list2.Files.Count / 100))))
$pretend = @(for ($i = 0; $i -lt $list2.Files.Count; $i += $every) { $list2.Files[$i] })
foreach ($f in $pretend) { [void](Read-HeadTail $f) }
"pass 3: re-reading $($pretend.Count) changed files (about 1%): $([math]::Round($sw.Elapsed.TotalSeconds, 2)) s on top of pass 2"
Remove-Item -LiteralPath $cachePath -Force
"cache removed: $(-not (Test-Path -LiteralPath $cachePath))"
