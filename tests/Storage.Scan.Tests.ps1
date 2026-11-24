$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Harness.Sqlite.ps1')
. (Join-Path $root 'src\Harness.Codex.Chats.ps1')
. (Join-Path $root 'src\Storage.Scan.ps1')
. (Join-Path $root 'src\Storage.Inventory.ps1')
. (Join-Path $root 'src\Storage.Inventory.Antigravity.ps1')

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

    # ---------------------------------------------------------------- fast C# Measure-StorageDir parity, long paths, fallback
    Assert ((Initialize-StorageDirMeasure) -and ($null -ne ('HarnessStorage.DirMeasure' -as [type]))) 'DirMeasure C# type compiles lazily'
    $pwalk = Join-Path $tmp 'parity'
    $jTarget = Join-Path $tmp 'mklink-target'
    try {
        $sub1 = Join-Path $pwalk 'nested\sub1'
        $sub2 = Join-Path $sub1 'sub2'
        $emptyDir = Join-Path $pwalk 'empty'
        [void][IO.Directory]::CreateDirectory($sub2)
        [void][IO.Directory]::CreateDirectory((Join-Path $emptyDir 'inner-empty'))
        $f1 = Join-Path $pwalk 'root.bin'
        $f2 = Join-Path $sub1 'mid.bin'
        $f3 = Join-Path $sub2 'leaf.bin'
        [IO.File]::WriteAllBytes($f1, (New-Object byte[] 111))
        [IO.File]::WriteAllBytes($f2, (New-Object byte[] 222))
        [IO.File]::WriteAllBytes($f3, (New-Object byte[] 333))
        [IO.File]::SetLastWriteTimeUtc($f1, [datetime]::new(2026, 1, 10, 1, 2, 3, [DateTimeKind]::Utc))
        [IO.File]::SetLastWriteTimeUtc($f2, [datetime]::new(2026, 2, 20, 4, 5, 6, [DateTimeKind]::Utc))
        [IO.File]::SetLastWriteTimeUtc($f3, [datetime]::new(2026, 3, 25, 7, 8, 9, [DateTimeKind]::Utc))

        $seg = 'seg_' + ('x' * 52)
        $deepDir = Join-Path $pwalk ($seg + '\' + $seg + '\' + $seg + '\' + $seg + '\' + $seg)
        $deepFile = Join-Path $deepDir 'deep.bin'
        Assert ($deepFile.Length -gt 260) "deep fixture path exceeds MAX_PATH ($($deepFile.Length))"
        [void][IO.Directory]::CreateDirectory(('\\?\' + $deepDir))
        [IO.File]::WriteAllBytes(('\\?\' + $deepFile), (New-Object byte[] 444))
        $newestDt = [datetime]::new(2026, 6, 15, 12, 34, 56, [DateTimeKind]::Utc)
        [IO.File]::SetLastWriteTimeUtc(('\\?\' + $deepFile), $newestDt)

        $expBytes = [long](111 + 222 + 333 + 444)
        $expFiles = 4
        $expTicks = $newestDt.Ticks
        $fast = Measure-StorageDir -Path $pwalk
        $slow = Measure-StorageDirPs -Path $pwalk
        Assert ($fast.Bytes -eq $expBytes -and $fast.Files -eq $expFiles -and $fast.NewestTicks -eq $expTicks) "C# walk exact totals: $($fast | ConvertTo-Json -Compress)"
        Assert ($fast.Bytes -eq $slow.Bytes -and $fast.Files -eq $slow.Files -and $fast.NewestTicks -eq $slow.NewestTicks) "C# matches PS walk: fast=$($fast | ConvertTo-Json -Compress) slow=$($slow | ConvertTo-Json -Compress)"

        $em = Measure-StorageDir -Path $emptyDir
        $emPs = Measure-StorageDirPs -Path $emptyDir
        Assert ($em.Bytes -eq 0 -and $em.Files -eq 0 -and $em.NewestTicks -eq 0) 'empty folder gives 0/0/0'
        Assert ($emPs.Bytes -eq 0 -and $emPs.Files -eq 0 -and $emPs.NewestTicks -eq 0) 'empty folder PS gives 0/0/0'

        [void][IO.Directory]::CreateDirectory($jTarget)
        $jFile = Join-Path $jTarget 'ignored.bin'
        [IO.File]::WriteAllBytes($jFile, (New-Object byte[] 9999))
        [IO.File]::SetLastWriteTimeUtc($jFile, [datetime]::new(2027, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
        $jLink = Join-Path $pwalk 'junc'
        cmd.exe /c mklink /J "$jLink" "$jTarget" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $jLink)) {
            try {
                $mj = Measure-StorageDir -Path $pwalk
                $mjPs = Measure-StorageDirPs -Path $pwalk
                Assert ($mj.Bytes -eq $expBytes -and $mj.Files -eq $expFiles -and $mj.NewestTicks -eq $expTicks) "mklink junction skipped by C#: $($mj | ConvertTo-Json -Compress)"
                Assert ($mjPs.Bytes -eq $expBytes -and $mjPs.Files -eq $expFiles -and $mjPs.NewestTicks -eq $expTicks) "mklink junction skipped by PS: $($mjPs | ConvertTo-Json -Compress)"
            } finally { [IO.Directory]::Delete($jLink) }
        }

        $miss = Measure-StorageDir -Path (Join-Path $tmp 'missing-root-xyz')
        $missPs = Measure-StorageDirPs -Path (Join-Path $tmp 'missing-root-xyz')
        Assert ($miss.Bytes -eq 0 -and $miss.Files -eq 0 -and $miss.NewestTicks -eq 0) 'missing root gives 0/0/0'
        Assert ($missPs.Bytes -eq 0 -and $missPs.Files -eq 0 -and $missPs.NewestTicks -eq 0) 'missing root PS gives 0/0/0'

        $syncCancel = [hashtable]::Synchronized(@{ Cancel = $true })
        $cm = Measure-StorageDir -Path $pwalk -Cancel $syncCancel
        Assert ($cm.Bytes -eq 0 -and $cm.Files -eq 0 -and $cm.NewestTicks -eq 0) 'pre-set synchronized Cancel stops immediately'
        $plainCancel = Measure-StorageDir -Path $pwalk -Cancel @{ Cancel = $true }
        Assert ($plainCancel.Bytes -eq 0 -and $plainCancel.Files -eq 0 -and $plainCancel.NewestTicks -eq 0) 'pre-set plain Cancel stops immediately'

        $origInit = (Get-Command Initialize-StorageDirMeasure -CommandType Function).ScriptBlock
        try {
            function Initialize-StorageDirMeasure { return $false }
            $fb = Measure-StorageDir -Path $pwalk
            Assert ($fb.Bytes -eq $fast.Bytes -and $fb.Files -eq $fast.Files -and $fb.NewestTicks -eq $fast.NewestTicks) "fallback matches C#: $($fb | ConvertTo-Json -Compress)"
            $fbMiss = Measure-StorageDir -Path (Join-Path $tmp 'missing-root-xyz')
            Assert ($fbMiss.Bytes -eq 0 -and $fbMiss.Files -eq 0 -and $fbMiss.NewestTicks -eq 0) 'fallback missing root gives 0/0/0'
            $fbCancel = Measure-StorageDir -Path $pwalk -Cancel $syncCancel
            Assert ($fbCancel.Bytes -eq 0 -and $fbCancel.Files -eq 0 -and $fbCancel.NewestTicks -eq 0) 'fallback Cancel gives 0/0/0'
        } finally { Set-Item -Path Function:\Initialize-StorageDirMeasure -Value $origInit }
    } finally {
        if (Test-Path -LiteralPath ('\\?\' + $pwalk)) { [IO.Directory]::Delete(('\\?\' + $pwalk), $true) }
    }

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
    Assert (Test-Path -LiteralPath (Join-Path $tmp 'bg\cache-stop.json')) 'a cancelled scan still saves the entries it read'
    $stopN = @((Get-Content -LiteralPath (Join-Path $tmp 'bg\cache-stop.json') -Raw | ConvertFrom-Json).entries.PSObject.Properties).Count
    Assert ($stopN -ge 1 -and $stopN -lt 8) "the saved cache holds the files read before Stop ($stopN of 8)"
    Close-StorageScan -Scan $scan
    $scan = Start-StorageScan -Roots $roots -CachePath (Join-Path $tmp 'bg\cache-stop.json')
    $deadline = [DateTime]::UtcNow.AddSeconds(30); while (-not $scan.Progress.Finished -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    Assert ($scan.Progress.Result.Reads -eq (8 - $stopN) -and $scan.Progress.Result.Sessions.Count -eq 8) "the next scan reads only what the stopped one did not: $($scan.Progress.Result.Reads) reads"
    Close-StorageScan -Scan $scan
    # old entries of files the stopped scan did not reach stay: every file changed, full cache from before, Stop early
    Copy-Item -LiteralPath $cacheFile -Destination (Join-Path $tmp 'bg\cache-stale.json')
    foreach ($f in Get-ChildItem -LiteralPath $proj -Recurse -Filter *.jsonl) { [IO.File]::AppendAllText($f.FullName, ' ') }
    $scan = Start-StorageScan -Roots $roots -CachePath (Join-Path $tmp 'bg\cache-stale.json') -ItemDelayMs 400
    Start-Sleep -Milliseconds 500
    Stop-StorageScan -Scan $scan
    $staleN = @((Get-Content -LiteralPath (Join-Path $tmp 'bg\cache-stale.json') -Raw | ConvertFrom-Json).entries.PSObject.Properties).Count
    Assert ($scan.Progress.Cancelled -and $staleN -eq 8) "old entries of files the stopped scan did not reach are kept ($staleN of 8)"
    Close-StorageScan -Scan $scan

    # R3-2: a job that hangs for 30 s and has a child process: Stop and Close return at once, the child is killed, the runspace is freed later
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript('Start-Sleep -Seconds 30')
    $kid = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
    $pids = New-Object Collections.Generic.List[int]; $pids.Add($kid.Id)
    $hang = [pscustomobject]@{ Progress = [hashtable]::Synchronized(@{ Finished = $false; Cancelled = $false; ChildPids = $pids }); Cancel = [hashtable]::Synchronized(@{ Cancel = $false }); PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
    Start-Sleep -Milliseconds 300
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Stop-StorageScan -Scan $hang
    $stopMs = $sw.ElapsedMilliseconds; $sw.Restart()
    Close-StorageScan -Scan $hang
    $closeMs = $sw.ElapsedMilliseconds
    Assert ($stopMs -lt 2000 -and $closeMs -lt 2000) "R3-2: Stop ($stopMs ms) and Close ($closeMs ms) of a hanging job return in under 2 s"
    $kid.Refresh(); $deadline = [DateTime]::UtcNow.AddSeconds(5); while (-not $kid.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert $kid.HasExited 'R3-2: the child process in Progress.ChildPids was killed'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ($script:StoragePendingClose.Count -and [DateTime]::UtcNow -lt $deadline) { Clear-StoragePendingClose; Start-Sleep -Milliseconds 100 }
    Assert ($script:StoragePendingClose.Count -eq 0 -and $rs.RunspaceStateInfo.State -eq 'Closed') 'R3-2: the stopped runspace is disposed afterwards, not by the caller'
    Stop-StorageChildProcesses -Progress @{ ChildPids = @(2147480000, $null) }
    Assert $true 'killing a process that does not exist is not an error'

    # parallel pool: Stop cancels quickly, keeps read entries, and skips the rest
    $parCancelProj = Join-Path $tmp 'bg-par-cancel\projects'
    foreach ($s in 1..32) {
        $d = Join-Path $parCancelProj "slug$s"; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $id = '20000000-0000-4000-8000-0000000000{0:00}' -f $s
        [IO.File]::WriteAllText((Join-Path $d "$id.jsonl"), ('{"type":"user","cwd":"C:\\work\\p","timestamp":"2026-11-15T10:00:00.000Z","message":{"role":"user","content":"hello ' + $s + '"}}' + "`n"))
    }
    $parCancelRoots = @{ ClaudeProjects = $parCancelProj; ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @() }
    $parCancelCache = Join-Path $tmp 'bg-par-cancel\cache.json'
    $origReadMeta = (Get-Command Read-StorageClaudeJsonlMeta -CommandType Function).ScriptBlock
    try {
        function Read-StorageClaudeJsonlMeta { param([Parameter(Mandatory)][string]$Path) Start-Sleep -Milliseconds 250; return @{ title = 'Slow'; cwd = 'C:\w'; first = [long]1000; last = [long]2000 } }
        $scan = Start-StorageScan -Roots $parCancelRoots -CachePath $parCancelCache
        $waitDone = [DateTime]::UtcNow.AddSeconds(10)
        while ($scan.Progress.Done -lt 1 -and -not $scan.Progress.Finished -and [DateTime]::UtcNow -lt $waitDone) { Start-Sleep -Milliseconds 15 }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Stop-StorageScan -Scan $scan
        $stopElapsed = $sw.ElapsedMilliseconds
        Assert ($stopElapsed -lt 1000) "parallel Stop-StorageScan returns within a second ($stopElapsed ms)"
        Assert ($scan.Progress.Finished -and $scan.Progress.Cancelled -and -not $scan.Progress.HardStopped) 'parallel pool stops cleanly on cancel without HardStopped'
        Assert (Test-Path -LiteralPath $parCancelCache) 'cancelled parallel scan saves partial cache'
        $parStopN = @((Get-Content -LiteralPath $parCancelCache -Raw | ConvertFrom-Json).entries.PSObject.Properties).Count
        Assert ($parStopN -ge 1 -and $parStopN -lt 32) "cancelled parallel scan saved completed entries before stop ($parStopN of 32)"
        Close-StorageScan -Scan $scan
    } finally {
        Set-Item -Path Function:\Read-StorageClaudeJsonlMeta -Value $origReadMeta
    }
    $scan = Start-StorageScan -Roots $parCancelRoots -CachePath $parCancelCache
    $deadline = [DateTime]::UtcNow.AddSeconds(30); while (-not $scan.Progress.Finished -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    Assert ($scan.Progress.Result.Reads -eq (32 - $parStopN) -and $scan.Progress.Result.Sessions.Count -eq 32 -and $scan.Progress.Done -eq $scan.Progress.Total) "parallel resume reads only remaining ($($scan.Progress.Result.Reads)) and Done equals Total"
    Close-StorageScan -Scan $scan

    $parHangCache = Join-Path $tmp 'bg-par-cancel\cache-hang.json'
    try {
        function Read-StorageClaudeJsonlMeta { param([Parameter(Mandatory)][string]$Path) Start-Sleep -Milliseconds 5000; return @{ title = 'Hang'; cwd = 'C:\w'; first = [long]1000; last = [long]2000 } }
        $scan = Start-StorageScan -Roots $parCancelRoots -CachePath $parHangCache
        Start-Sleep -Milliseconds 300
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Stop-StorageScan -Scan $scan
        $hangStopMs = $sw.ElapsedMilliseconds
        Assert ($hangStopMs -lt 1000) "parallel pool interrupts slow workers within a second ($hangStopMs ms)"
        Assert ($scan.Progress.Finished -and $scan.Progress.Cancelled -and -not $scan.Progress.HardStopped) 'parallel pool stops slow workers cleanly without HardStopped'
        Close-StorageScan -Scan $scan
    } finally {
        Set-Item -Path Function:\Read-StorageClaudeJsonlMeta -Value $origReadMeta
    }

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
    foreach ($f in 'Storage.Scan.ps1', 'Storage.Inventory.ps1', 'Storage.Inventory.Antigravity.ps1') {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "src\$f"), [ref]$null, [ref]$null)
        foreach ($d in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined.Add($d.Name) }
    }
    $notShipped = @($defined | Where-Object { $names -notcontains $_ -and $_ -notin 'Start-StorageScan', 'Stop-StorageScan', 'Close-StorageScan', 'Stop-StorageChildProcesses', 'Clear-StoragePendingClose', 'Get-StorageScanFunctionNames', 'Get-StorageRootsFromConfig', 'Get-StorageStats' })
    Assert ($notShipped.Count -eq 0) "functions of the scan files that the runspace would miss: $($notShipped -join ', ')"
    Assert (-not (Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'sqlite-snap-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) })) 'no snapshot folder left behind'
} finally {
    Remove-TestTempDir $tmp
}
Write-Output 'Storage.Scan.Tests: OK'
