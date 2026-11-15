$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Harness.Sqlite.ps1')
. (Join-Path $root 'src\Harness.Codex.Chats.ps1')
. (Join-Path $root 'src\Storage.Scan.ps1')
. (Join-Path $root 'src\Storage.Inventory.ps1')

# Only a fake tree under %TEMP%\storage-test-*; nothing of ~\.claude, CODEX_HOME or Antigravity is ever touched.
function New-StorageTestDir {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('storage-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

Add-Type -TypeDefinition @'
public class StorageCountingStream : System.IO.Stream {
  System.IO.Stream inner; public long BytesRead;
  public StorageCountingStream(System.IO.Stream s) { inner = s; }
  public override int Read(byte[] b, int o, int c) { int n = inner.Read(b, o, c); BytesRead += n; return n; }
  public override bool CanRead { get { return true; } }
  public override bool CanSeek { get { return inner.CanSeek; } }
  public override bool CanWrite { get { return false; } }
  public override long Length { get { return inner.Length; } }
  public override long Position { get { return inner.Position; } set { inner.Position = value; } }
  public override void Flush() { }
  public override long Seek(long o, System.IO.SeekOrigin k) { return inner.Seek(o, k); }
  public override void SetLength(long v) { throw new System.NotSupportedException(); }
  public override void Write(byte[] b, int o, int c) { throw new System.NotSupportedException(); }
  protected override void Dispose(bool d) { if (d) inner.Dispose(); base.Dispose(d); }
}
'@

$tmp = New-StorageTestDir
try {
    # ---------------------------------------------------------------- I1-2: head and tail of a big jsonl, never the middle
    $big = Join-Path $tmp 'big.jsonl'
    $sw = New-Object IO.StreamWriter($big, $false, (New-Object Text.UTF8Encoding($false)))
    $n = 20000
    for ($i = 1; $i -le $n; $i++) { $sw.Write(('{{"type":"user","n":{0},"timestamp":"2026-11-15T10:{1:00}:{2:00}.000Z","pad":"{3}"}}' -f $i, ($i % 60), ($i % 60), ('x' * 200)) + "`n") }
    $sw.Close()
    Assert ((Get-Item $big).Length -gt 4MB) 'the fixture is a few MB'
    $counter = $null
    $open = { param($p) $script:counter = New-Object StorageCountingStream ([IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')); $script:counter }
    $r = Read-JsonlHeadTail -Path $big -OpenStream $open
    Assert ($script:counter.BytesRead -le 131072) "only the head and the tail are read: $($script:counter.BytesRead) bytes"
    Assert ((($r.Head[0] | ConvertFrom-Json).n) -eq 1) 'the first line is whole and first'
    Assert ((($r.Tail[$r.Tail.Count - 1] | ConvertFrom-Json).n) -eq $n) 'the last line is whole and last'
    Assert (@($r.Head | ForEach-Object { $_ | ConvertFrom-Json }).Count -eq $r.Head.Count) 'the cut last line of the head is dropped (every head line is valid JSON)'
    Assert (@($r.Tail | ForEach-Object { $_ | ConvertFrom-Json }).Count -eq $r.Tail.Count) 'the cut first line of the tail is dropped (every tail line is valid JSON)'
    Assert ($r.Size -eq (Get-Item $big).Length -and $r.Complete -eq $false) 'size is reported and the file is not complete'
    $small = Join-Path $tmp 'small.jsonl'
    [IO.File]::WriteAllText($small, "{`"a`":1}`r`n{`"a`":2}`n`n{`"a`":3}")
    $r = Read-JsonlHeadTail -Path $small
    Assert ($r.Complete -and $r.Head.Count -eq 3 -and $r.Tail.Count -eq 3 -and $r.Tail[2] -eq '{"a":3}') "a small file is read once, whole: $($r.Head -join '|')"
    $empty = Join-Path $tmp 'empty.jsonl'; [IO.File]::WriteAllBytes($empty, [byte[]]@())
    $r = Read-JsonlHeadTail -Path $empty
    Assert ($r.Head.Count -eq 0 -and $r.Tail.Count -eq 0 -and $r.Complete) 'an empty file'
    # a file somebody else holds open for writing can still be read
    $fs = [IO.File]::Open($small, 'Open', 'Write', 'ReadWrite')
    try { $r = Read-JsonlHeadTail -Path $small; Assert ($r.Head.Count -eq 3) 'a file open for writing is read' } finally { $fs.Dispose() }

    # ---------------------------------------------------------------- cache: file format, atomic write, damaged file
    $cachePath = Join-Path $tmp 'sub\storage-cache.json'
    $c = New-StorageCache
    $c.Entries['C:\x\a.jsonl'] = @{ size = 10; mtimeTicks = 637000000000000000; meta = @{ title = 'T'; cwd = 'C:\x'; n = 3; list = @(1, 2) } }
    Write-StorageCache -Cache $c -Path $cachePath
    Assert ((Test-Path -LiteralPath $cachePath) -and @(Get-ChildItem (Split-Path $cachePath)).Count -eq 1) 'cache written, no tmp file left'
    $c2 = Read-StorageCache -Path $cachePath
    $e = $c2.Entries['C:\x\a.jsonl']
    Assert ([long]$e['size'] -eq 10 -and [long]$e['mtimeTicks'] -eq 637000000000000000 -and $e['meta']['title'] -eq 'T') 'cache round trip'
    Assert ($c2.Reads -eq 0) 'a loaded cache starts with no reads'
    [IO.File]::WriteAllText($cachePath, '{ not json')
    $c3 = Read-StorageCache -Path $cachePath
    Assert ($c3.Entries.Count -eq 0) 'a damaged cache is dropped'
    [IO.File]::WriteAllText($cachePath, '{"version":999,"entries":{"a":{"size":1,"mtimeTicks":1,"meta":{}}}}')
    Assert ((Read-StorageCache -Path $cachePath).Entries.Count -eq 0) 'a cache of another version is dropped'
    Assert ((Read-StorageCache -Path (Join-Path $tmp 'nothing.json')).Entries.Count -eq 0) 'no cache file: empty cache'

    # a reader that throws stores nothing, so the next scan tries again
    $c4 = New-StorageCache
    $threw = $false
    try { [void](Get-StorageCachedMeta -Cache $c4 -Key 'k' -Size 1 -Ticks 1 -Reader { param($k) throw 'locked' }) } catch { $threw = $true }
    Assert ($threw -and -not $c4.Entries.ContainsKey('k') -and -not $c4.Seen.ContainsKey('k')) 'a failing reader leaves no cache entry'
    $m4 = Get-StorageCachedMeta -Cache $c4 -Key 'k' -Size 1 -Ticks 1 -Reader { param($k) @{ ok = 1 } }
    Assert ($m4['ok'] -eq 1 -and $c4.Entries.ContainsKey('k')) 'the retry reads and caches'

    # ---------------------------------------------------------------- directory walking: junctions skipped, sizes added
    $walk = Join-Path $tmp 'walk'
    New-Item -ItemType Directory -Path (Join-Path $walk 'a\b') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $walk 'one.bin'), (New-Object byte[] 100))
    [IO.File]::WriteAllBytes((Join-Path $walk 'a\two.bin'), (New-Object byte[] 200))
    [IO.File]::WriteAllBytes((Join-Path $walk 'a\b\three.bin'), (New-Object byte[] 300))
    $outside = Join-Path $tmp 'outside'; New-Item -ItemType Directory -Path $outside | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $outside 'huge.bin'), (New-Object byte[] 5000))
    New-Item -ItemType Junction -Path (Join-Path $walk 'link') -Target $outside | Out-Null
    try {
        $m = Measure-StorageDir -Path $walk
        Assert ($m.Bytes -eq 600 -and $m.Files -eq 3) "the junction is not followed: $($m | ConvertTo-Json -Compress)"
        Assert ($m.NewestTicks -gt 0) 'the newest mtime is reported'
        Assert ((Measure-StorageDir -Path (Join-Path $tmp 'does-not-exist')).Bytes -eq 0) 'a missing folder counts as empty'
        $cancel = @{ Cancel = $true }
        Assert ((Measure-StorageDir -Path $walk -Cancel $cancel).Files -eq 0) 'a cancelled walk stops at once'
    } finally { [IO.Directory]::Delete((Join-Path $walk 'link')) }

    # ---------------------------------------------------------------- I1-7: the background scan
    $proj = Join-Path $tmp 'bg\projects'
    $cwdText = 'C:\\work\\p'
    foreach ($s in 1..8) {
        $d = Join-Path $proj "slug$s"; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $id = '10000000-0000-4000-8000-0000000000{0:00}' -f $s
        [IO.File]::WriteAllText((Join-Path $d "$id.jsonl"), ('{"type":"user","cwd":"' + $cwdText + '","timestamp":"2026-11-15T10:00:00.000Z","message":{"role":"user","content":"hello ' + $s + '"}}' + "`n"))
    }
    $roots = @{ ClaudeProjects = $proj; ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @() }
    $cacheFile = Join-Path $tmp 'bg\cache.json'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $scan = Start-StorageScan -Roots $roots -CachePath $cacheFile -ItemDelayMs 150
    $startMs = $sw.ElapsedMilliseconds
    Assert ($startMs -lt 1500) "Start-StorageScan returns at once ($startMs ms) while the scan takes about a second"
    Assert (-not $scan.Progress.Finished) 'the scan is still running when Start returns'
    $seen = New-Object Collections.Generic.List[int]
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $scan.Progress.Finished -and [DateTime]::UtcNow -lt $deadline) { $seen.Add([int]$scan.Progress.Done); Start-Sleep -Milliseconds 40 }
    Assert ($scan.Progress.Finished) 'the scan finished'
    Assert (-not $scan.Progress.Error) "no error: $($scan.Progress.Error)"
    $distinct = @($seen | Sort-Object -Unique)
    Assert ($distinct.Count -ge 3) "Done grows while the scan runs: $($distinct -join ',')"
    $mono = $true; for ($i = 1; $i -lt $seen.Count; $i++) { if ($seen[$i] -lt $seen[$i - 1]) { $mono = $false } }
    Assert $mono 'Done never goes back'
    Assert ($scan.Progress.Result.Sessions.Count -eq 8 -and $scan.Progress.Done -ge 8) 'the result holds the 8 sessions'
    Assert (Test-Path -LiteralPath $cacheFile) 'a finished scan saved the cache'
    Close-StorageScan -Scan $scan

    # a second scan is served from the cache: no file is read again
    $scan = Start-StorageScan -Roots $roots -CachePath $cacheFile
    $deadline = [DateTime]::UtcNow.AddSeconds(30); while (-not $scan.Progress.Finished -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    Assert ($scan.Progress.Result.Reads -eq 0 -and $scan.Progress.Result.Sessions.Count -eq 8) "cache hit: no read, got $($scan.Progress.Result.Reads)"
    Close-StorageScan -Scan $scan

    # Stop ends the scan within a second and says so
    $scan = Start-StorageScan -Roots $roots -CachePath (Join-Path $tmp 'bg\cache-stop.json') -ItemDelayMs 400
    Start-Sleep -Milliseconds 300
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Stop-StorageScan -Scan $scan
    Assert ($sw.ElapsedMilliseconds -lt 1000) "Stop-StorageScan returns within a second ($($sw.ElapsedMilliseconds) ms)"
    Assert ($scan.Progress.Finished -and $scan.Progress.Cancelled) 'a stopped scan is finished and marked cancelled'
    Assert (-not (Test-Path -LiteralPath (Join-Path $tmp 'bg\cache-stop.json'))) 'a cancelled scan does not write a half cache'
    Close-StorageScan -Scan $scan

    # an error inside the runspace comes back through Progress.Error and is never thrown at the caller
    $blocker = Join-Path $tmp 'blocker'; [IO.File]::WriteAllText($blocker, 'a file where a folder is needed')
    $scan = Start-StorageScan -Roots $roots -CachePath (Join-Path $blocker 'cache.json')
    $deadline = [DateTime]::UtcNow.AddSeconds(30); while (-not $scan.Progress.Finished -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    Assert ($scan.Progress.Finished -and $scan.Progress.Error) 'a failure in the runspace is reported in Progress.Error'
    Close-StorageScan -Scan $scan

    # every function the runspace needs is shipped to it
    $names = @(Get-StorageScanFunctionNames)
    foreach ($nm in $names) { Assert (Get-Command $nm -CommandType Function -ErrorAction SilentlyContinue) "shipped function not defined: $nm" }
    $defined = New-Object Collections.Generic.List[string]
    foreach ($f in 'Storage.Scan.ps1', 'Storage.Inventory.ps1') {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "src\$f"), [ref]$null, [ref]$null)
        foreach ($d in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined.Add($d.Name) }
    }
    $notShipped = @($defined | Where-Object { $names -notcontains $_ -and $_ -notin 'Start-StorageScan', 'Stop-StorageScan', 'Close-StorageScan', 'Get-StorageScanFunctionNames', 'Get-StorageRootsFromConfig', 'Get-StorageStats' })
    Assert ($notShipped.Count -eq 0) "functions of the scan files that the runspace would miss: $($notShipped -join ', ')"
    Assert (-not (Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'sqlite-snap-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) })) 'no snapshot folder left behind'
} finally {
    Remove-TestTempDir $tmp
}
Write-Output 'Storage.Scan.Tests: OK'
