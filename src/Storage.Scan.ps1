# Storage.Scan.ps1 - the reading primitives of the session inventory and the background scan (phase 6, lane I1).
# Everything here is read-only: no function writes into app data. The only file written is the scan cache, and only to
# the path the caller gives. ASCII only. Needs nothing from the other harness files; the inventory (Storage.Inventory.ps1)
# builds on it. The scan runs in a runspace, so every function it needs is listed in Get-StorageScanFunctionNames.

# ---- reading the head and the tail of a jsonl ------------------------------------------------------------------------

function Read-StorageBytes {
    param([Parameter(Mandatory)]$Stream, [long]$Offset, [int]$Count)
    [void]$Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $Count
    $got = 0
    while ($got -lt $Count) {
        $n = $Stream.Read($buf, $got, $Count - $got)
        if ($n -le 0) { break }
        $got += $n
    }
    if ($got -lt $Count) { $short = New-Object byte[] $got; [Array]::Copy($buf, $short, $got); return , $short }
    return , $buf
}

function Split-StorageLines {
    param([string]$Text)
    $out = New-Object Collections.Generic.List[string]
    foreach ($l in $Text.Split("`n")) { $t = $l.TrimEnd("`r"); if ($t.Trim().Length) { $out.Add($t) } }
    return $out.ToArray()
}

# The first and the last -HeadBytes / -TailBytes of a file as lines, never the middle. A line cut by the edge of a chunk
# is dropped (the end of the head, the start of the tail), so every line returned is whole. A file that fits in both
# chunks together is read once, whole. -OpenStream is only replaced by tests (a stream that counts what is read).
# Returns Size, Head, Tail, Complete (the whole file was read) and BytesRead.
function Read-JsonlHeadTail {
    param([Parameter(Mandatory)][string]$Path, [int]$HeadBytes = 65536, [int]$TailBytes = 65536, [scriptblock]$OpenStream)
    $fs = $(if ($OpenStream) { & $OpenStream $Path } else { [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) })
    try {
        $utf8 = New-Object Text.UTF8Encoding($false)
        $size = [long]$fs.Length
        if ($size -le ($HeadBytes + $TailBytes)) {
            $all = @(Split-StorageLines -Text $utf8.GetString((Read-StorageBytes -Stream $fs -Offset 0 -Count ([int]$size))))
            return [pscustomobject]@{ Size = $size; Head = $all; Tail = $all; Complete = $true; BytesRead = $size }
        }
        $head = @(Split-StorageLines -Text $utf8.GetString((Read-StorageBytes -Stream $fs -Offset 0 -Count $HeadBytes)))
        if ($head.Count -gt 0) { $head = @($head | Select-Object -First ($head.Count - 1)) }
        $tail = @(Split-StorageLines -Text $utf8.GetString((Read-StorageBytes -Stream $fs -Offset ($size - $TailBytes) -Count $TailBytes)))
        $tail = @($tail | Select-Object -Skip 1)
        return [pscustomobject]@{ Size = $size; Head = $head; Tail = $tail; Complete = $false; BytesRead = [long]($HeadBytes + $TailBytes) }
    } finally { $fs.Dispose() }
}

# ---- the cache: .switcher\storage-cache.json ---------------------------------------------------------------------------

# Entries: path -> @{ size; mtimeTicks; meta }. Seen is the set of keys the current scan met (not saved). Reads counts the
# times a file was opened for its content, which is what the cache is there to avoid.
function New-StorageCache {
    return @{ Version = 1; Entries = @{}; Seen = @{}; Reads = 0 }
}

function Read-StorageCache {
    param([Parameter(Mandatory)][string]$Path)
    $cache = New-StorageCache
    if (-not [IO.File]::Exists($Path)) { return $cache }
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue; $ser.RecursionLimit = 64
        $doc = $ser.DeserializeObject([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
        if ($doc -isnot [Collections.IDictionary] -or [int]$doc['version'] -ne 1 -or $doc['entries'] -isnot [Collections.IDictionary]) { return $cache }
        foreach ($k in $doc['entries'].Keys) { $cache.Entries[[string]$k] = $doc['entries'][$k] }
    } catch { return (New-StorageCache) }
    return $cache
}

# Written to a temp file next to the cache and then moved over it, so a reader never sees half a file.
function Write-StorageCache {
    param([Parameter(Mandatory)]$Cache, [Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue; $ser.RecursionLimit = 64
    $json = $ser.Serialize(@{ version = 1; entries = $Cache.Entries })
    $dir = Split-Path -Parent $Path
    if ($dir -and -not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, $null) } else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

# The meta of one key from the cache when its size and mtime are unchanged; otherwise $Reader runs (it gets the key), the
# read is counted and the result is stored. Without a cache the reader always runs.
function Get-StorageCachedMeta {
    param($Cache, [Parameter(Mandatory)][string]$Key, [long]$Size, [long]$Ticks, [Parameter(Mandatory)][scriptblock]$Reader)
    if (-not $Cache) { return (& $Reader $Key) }
    $e = $Cache.Entries[$Key]
    if ($e -and [long]$e['size'] -eq $Size -and [long]$e['mtimeTicks'] -eq $Ticks) { $Cache.Seen[$Key] = $true; return $e['meta'] }
    $Cache.Reads++
    $meta = & $Reader $Key
    $Cache.Entries[$Key] = @{ size = $Size; mtimeTicks = $Ticks; meta = $meta }
    $Cache.Seen[$Key] = $true
    return $meta
}

# Drops the entries the finished scan did not meet (files that are gone).
function Remove-StorageCacheUnseen {
    param([Parameter(Mandatory)]$Cache)
    foreach ($k in @($Cache.Entries.Keys)) { if (-not $Cache.Seen.ContainsKey($k)) { $Cache.Entries.Remove($k) } }
}

# ---- walking folders ---------------------------------------------------------------------------------------------------

function Test-StorageCancel {
    param($Cancel)
    return [bool]($Cancel -and $Cancel['Cancel'])
}

# The entries of one folder, junctions and symlinks left out. A folder that cannot be read gives what was read so far.
function Get-StorageEntries {
    param([Parameter(Mandatory)][string]$Dir)
    $out = New-Object Collections.Generic.List[object]
    try {
        foreach ($e in (New-Object IO.DirectoryInfo $Dir).EnumerateFileSystemInfos()) {
            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $out.Add($e)
        }
    } catch { }
    return $out.ToArray()
}

# Pure-PowerShell fallback for Measure-StorageDir when Add-Type cannot compile C#.
function Measure-StorageDirPs {
    param([Parameter(Mandatory)][string]$Path, $Cancel)
    $bytes = [long]0; $files = 0; $newest = [long]0
    $stack = New-Object Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if (Test-StorageCancel $Cancel) { break }
        $dir = $stack.Pop()
        foreach ($e in @(Get-StorageEntries -Dir $dir)) {
            if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName); continue }
            $bytes += $e.Length; $files++
            $t = $e.LastWriteTimeUtc.Ticks; if ($t -gt $newest) { $newest = $t }
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; NewestTicks = $newest }
}

function Initialize-StorageDirMeasure {
    if ('HarnessStorage.DirMeasure' -as [type]) { return $true }
    if ($script:StorageDirMeasureUnavailable) { return $false }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace HarnessStorage {
    public static class DirMeasure {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct FindData {
            public uint Attr;
            public uint CreateLo, CreateHi, AccessLo, AccessHi, WriteLo, WriteHi;
            public uint SizeHi, SizeLo, Res0, Res1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AltName;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        static extern IntPtr FindFirstFileExW(string name, int infoLevel, out FindData data, int searchOp, IntPtr filter, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        static extern bool FindNextFileW(IntPtr h, out FindData data);
        [DllImport("kernel32.dll", ExactSpelling = true)]
        static extern bool FindClose(IntPtr h);

        const int FindExInfoBasic = 1, FindExSearchNameMatch = 0, LargeFetch = 2;
        const uint AttrDir = 0x10, AttrReparse = 0x400;
        const long MaxFileTime = 2650467743999999999L;
        static readonly IntPtr InvalidHandle = new IntPtr(-1);

        static string ToExtended(string path) {
            if (string.IsNullOrEmpty(path)) return null;
            if (!path.StartsWith(@"\\?\", StringComparison.Ordinal) && !path.StartsWith(@"\\.\", StringComparison.Ordinal)) {
                try { path = Path.GetFullPath(path); } catch { path = path.Replace('/', '\\'); }
                path = path.StartsWith(@"\\", StringComparison.Ordinal) ? (@"\\?\UNC\" + path.Substring(2)) : (@"\\?\" + path);
            }
            return path.TrimEnd('\\');
        }

        static bool Cancelled(IDictionary cancel) {
            if (cancel == null) return false;
            object v = cancel["Cancel"];
            if (v == null) return false;
            if (v is bool) return (bool)v;
            try { return Convert.ToBoolean(v); } catch { return true; }
        }

        public static long[] Measure(string path, IDictionary cancel) {
            long bytes = 0, files = 0, newest = 0;
            string root = ToExtended(path);
            if (string.IsNullOrEmpty(root)) return new long[] { 0, 0, 0 };
            var stack = new Stack<string>();
            stack.Push(root);
            while (stack.Count > 0) {
                if (Cancelled(cancel)) break;
                string dir = stack.Pop();
                FindData d;
                IntPtr h = FindFirstFileExW(dir + @"\*", FindExInfoBasic, out d, FindExSearchNameMatch, IntPtr.Zero, LargeFetch);
                if (h == InvalidHandle) continue;
                try {
                    long seen = 0;
                    do {
                        string n = d.Name;
                        if (n == "." || n == "..") continue;
                        if ((d.Attr & AttrReparse) != 0) continue;
                        if ((d.Attr & AttrDir) != 0) { stack.Push(dir + @"\" + n); continue; }
                        bytes += ((long)d.SizeHi << 32) | (long)d.SizeLo;
                        files++;
                        long ft = ((long)d.WriteHi << 32) | (long)d.WriteLo;
                        if (ft >= 0 && ft <= MaxFileTime) { long t = DateTime.FromFileTimeUtc(ft).Ticks; if (t > newest) newest = t; }
                        if ((++seen & 255) == 0 && Cancelled(cancel)) break;
                    } while (FindNextFileW(h, out d));
                } finally { FindClose(h); }
            }
            return new long[] { bytes, files, newest };
        }
    }
}
'@ -ErrorAction Stop
        return [bool]('HarnessStorage.DirMeasure' -as [type])
    } catch {
        if ('HarnessStorage.DirMeasure' -as [type]) { return $true }
        $script:StorageDirMeasureUnavailable = $true
        return $false
    }
}

# Bytes, file count and the newest mtime (ticks) under a folder, without following links.
function Measure-StorageDir {
    param([Parameter(Mandatory)][string]$Path, $Cancel)
    if (Initialize-StorageDirMeasure) {
        $r = [HarnessStorage.DirMeasure]::Measure($Path, $Cancel)
        return [pscustomobject]@{ Bytes = $r[0]; Files = [int]$r[1]; NewestTicks = $r[2] }
    }
    return (Measure-StorageDirPs -Path $Path -Cancel $Cancel)
}

# Every file under a folder (FileInfo), without following links.
function Get-StorageFilesRecursive {
    param([Parameter(Mandatory)][string]$Path, $Cancel)
    $list = New-Object Collections.Generic.List[object]
    $stack = New-Object Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if (Test-StorageCancel $Cancel) { break }
        foreach ($e in @(Get-StorageEntries -Dir $stack.Pop())) { if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName) } else { $list.Add($e) } }
    }
    return $list.ToArray()
}

# True when file attributes mark a cloud placeholder: OFFLINE (0x1000), RECALL_ON_OPEN (0x40000) or RECALL_ON_DATA_ACCESS (0x400000).
function Test-StorageCloudPlaceholder {
    param($Attributes)
    if ($null -eq $Attributes) { return $false }
    return (([int]$Attributes -band (0x1000 -bor 0x40000 -bor 0x400000)) -ne 0)
}

# Collects uncached, non-placeholder, distinct file entries for parallel metadata pre-read.
function Get-StorageCacheMisses {
    param([array]$Files = @(), [Parameter(Mandatory)]$Cache)
    $misses = New-Object Collections.Generic.List[object]
    $seen = @{}
    foreach ($f in $Files) {
        if (-not $f -or (Test-StorageCloudPlaceholder $f.Attributes) -or $seen.ContainsKey($f.FullName)) { continue }
        $e = $Cache.Entries[$f.FullName]
        if ($e -and [long]$e['size'] -eq $f.Length -and [long]$e['mtimeTicks'] -eq $f.LastWriteTimeUtc.Ticks) { continue }
        $seen[$f.FullName] = $true
        $misses.Add(@{ Key = $f.FullName; Size = [long]$f.Length; Ticks = $f.LastWriteTimeUtc.Ticks })
    }
    return $misses.ToArray()
}

# Reads meta for cache-missed Claude files in a bounded RunspacePool using $ReaderName. Workers only parse and
# enqueue results; only the caller's scan thread writes into $Cache and increments Progress.Done.
function Read-StorageClaudeMetaParallel {
    param(
        [Parameter(Mandatory)][array]$Misses,
        [Parameter(Mandatory)]$Cache,
        $Cancel,
        $Progress,
        [hashtable]$Counted,
        [int]$MaxThreads = 0,
        [string]$ReaderName = 'Read-StorageClaudeJsonlMeta',
        [string[]]$HelperNames = @('Read-StorageBytes', 'Split-StorageLines', 'Read-JsonlHeadTail', 'Test-StorageCloudPlaceholder', 'ConvertTo-StorageMs', 'Get-StorageFirstString', 'Get-StorageTitleLine', 'Get-StorageClaudeWindowMeta')
    )
    $cap = $(if ($MaxThreads -gt 0) { $MaxThreads } else { [Math]::Min(8, [Environment]::ProcessorCount) })
    $threads = [Math]::Min($Misses.Count, $cap)
    if ($threads -le 1 -or (Test-StorageCancel $Cancel)) { return }
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $shipped = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in (@($HelperNames) + @($ReaderName))) {
        if (-not $n -or -not $shipped.Add($n)) { continue }
        $c = Get-Command -Name $n -CommandType Function -ErrorAction Stop
        $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($n, $c.Definition)))
    }
    $pool = [runspacefactory]::CreateRunspacePool($iss)
    [void]$pool.SetMinRunspaces(1); [void]$pool.SetMaxRunspaces($threads); $pool.Open()
    $work = New-Object Collections.Concurrent.ConcurrentQueue[object]
    $results = New-Object Collections.Concurrent.ConcurrentQueue[object]
    $ready = New-Object Threading.AutoResetEvent($false)
    foreach ($m in $Misses) { $work.Enqueue($m) }
    $workerScript = @'
param($Work, $Results, $Ready, $Cancel, $ReaderName)
$item = $null
while (-not ($Cancel -and $Cancel['Cancel']) -and $Work.TryDequeue([ref]$item)) {
    $meta = $null; $ok = $false
    try { $meta = & $ReaderName -Path $item.Key; $ok = ($meta -is [Collections.IDictionary]) } catch { $ok = $false }
    $Results.Enqueue(@{ Item = $item; Meta = $meta; Ok = $ok })
    try { [void]$Ready.Set() } catch { }
}
try { [void]$Ready.Set() } catch { }
'@
    $drain = {
        $res = $null
        while ($results.TryDequeue([ref]$res)) {
            if ($res.Ok) {
                $it = $res.Item
                $Cache.Entries[$it.Key] = @{ size = $it.Size; mtimeTicks = $it.Ticks; meta = $res.Meta }
                $Cache.Seen[$it.Key] = $true
                $Cache.Reads++
                if ($Counted) { $Counted[$it.Key] = $true }
                Set-StorageProgress -Progress $Progress -Done 1
            }
        }
    }
    $workers = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $threads; $i++) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript).AddArgument($work).AddArgument($results).AddArgument($ready).AddArgument($Cancel).AddArgument($ReaderName)
        $workers.Add(@{ PowerShell = $ps; Handle = $ps.BeginInvoke() })
    }
    try {
        while ($true) {
            . $drain
            if (Test-StorageCancel $Cancel) { break }
            $running = $false
            foreach ($w in $workers) { if (-not $w.Handle.IsCompleted) { $running = $true; break } }
            if (-not $running) { break }
            [void]$ready.WaitOne(25)
        }
        . $drain
    } finally {
        $stops = New-Object Collections.Generic.List[object]
        foreach ($w in $workers) { if (-not $w.Handle.IsCompleted) { try { $stops.Add($w.PowerShell.BeginStop($null, $null)) } catch { } } }
        if ($stops.Count -gt 0) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            foreach ($s in $stops) {
                $left = [int][Math]::Max(0, 400 - $sw.ElapsedMilliseconds)
                if ($left -gt 0) { try { [void]$s.AsyncWaitHandle.WaitOne($left) } catch { } }
            }
        }
        . $drain
        $allDone = $true
        foreach ($w in $workers) {
            if ($w.Handle.IsCompleted) {
                try { [void]$w.PowerShell.EndInvoke($w.Handle) } catch { }
                try { $w.PowerShell.Dispose() } catch { }
            } else { $allDone = $false }
        }
        if ($allDone) { try { $pool.Close(); $pool.Dispose() } catch { } }
        else { try { [void]$pool.BeginClose($null, $null) } catch { } }
        try { $ready.Dispose() } catch { }
    }
}

# ---- the background scan -----------------------------------------------------------------------------------------------

# Every function the runspace needs. Tests check that this list covers both scan files and that each name resolves, so a
# new helper cannot be forgotten. The Sqlite and Codex path helpers come from the harness files.
function Get-StorageScanFunctionNames {
    return @(
        'Read-StorageBytes', 'Split-StorageLines', 'Read-JsonlHeadTail', 'New-StorageCache', 'Read-StorageCache', 'Write-StorageCache',
        'Get-StorageCachedMeta', 'Remove-StorageCacheUnseen', 'Test-StorageCancel', 'Get-StorageEntries', 'Measure-StorageDirPs', 'Initialize-StorageDirMeasure', 'Measure-StorageDir',
        'Get-StorageFilesRecursive', 'Test-StorageCloudPlaceholder', 'Get-StorageCacheMisses', 'Read-StorageClaudeMetaParallel',
        'ConvertTo-StorageMs', 'Set-StorageProgress', 'Set-StorageActivityFromParts', 'Add-StoragePart', 'Get-StorageFirstString', 'Read-StorageLocalMeta',
        'Get-StorageTitleLine', 'Read-StorageClaudeJsonlMeta', 'Get-ClaudeProfileRefs', 'Get-ClaudeTranscripts',
        'New-StorageSessionBuilder', 'ConvertTo-StorageSession', 'Get-ClaudeStorageSessions',
        'Read-StorageCodexRows', 'Get-StorageDbSignature', 'Get-CodexStorageSessions',
        'Get-StorageClaudeWindowMeta', 'Test-StorageUnderDir',
        'Read-StorageAgyRows', 'ConvertFrom-StorageWorkspace', 'Get-AgyStorageSessions', 'Get-StorageProfileFolder', 'Get-StorageGuidPattern', 'Get-StorageProfileTag', 'Get-StorageInventory',
        'Initialize-WinSqlite', 'ConvertTo-SqliteUtf8', 'Open-SqliteReadOnly', 'Close-Sqlite', 'Invoke-SqliteQuery', 'Copy-SqliteSnapshot', 'ConvertFrom-CodexPath'
    )
}

# Starts the inventory in a runspace and returns at once. Progress (Phase, Done, Total, Finished, Cancelled, Error, Result)
# is a synchronized hashtable the UI timer reads. The cache is loaded and saved inside the runspace; a cancelled scan saves it
# too: what it read is kept and the entries it did not reach stay (Remove-StorageCacheUnseen does not run on a cancel). An error does not
# save it. An error in the runspace ends up in Progress.Error and is never thrown at the caller.
# -ItemDelayMs is only raised by tests, to make a small fixture last long enough to watch.
function Start-StorageScan {
    param([Parameter(Mandatory)][hashtable]$Roots, [string]$CachePath, [int]$ItemDelayMs = 0, [int]$RecentMinutes = 30)
    Clear-StoragePendingClose
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($n in (Get-StorageScanFunctionNames)) {
        $c = Get-Command -Name $n -CommandType Function -ErrorAction Stop
        $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($n, $c.Definition)))
    }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $progress = [hashtable]::Synchronized(@{ Phase = 'starting'; Done = 0; Total = 0; Finished = $false; Cancelled = $false; Error = $null; Result = $null; Warnings = @() })
    $cancel = [hashtable]::Synchronized(@{ Cancel = $false })
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $body = @'
param($Roots, $Progress, $Cancel, $CachePath, $Delay, $Recent)
try {
    $cache = $(if ($CachePath) { Read-StorageCache -Path $CachePath } else { New-StorageCache })
    $inv = Get-StorageInventory -Roots $Roots -Cache $cache -Progress $Progress -CancelToken $Cancel -ItemDelayMs $Delay -RecentMinutes $Recent
    $Progress.Result = $inv
    if ($inv.Cancelled) { $Progress.Cancelled = $true }
    if ($CachePath) { Write-StorageCache -Cache $cache -Path $CachePath }
} catch { $Progress.Error = $_.Exception.Message } finally { $Progress.Finished = $true }
'@
    [void]$ps.AddScript($body).AddArgument($Roots).AddArgument($progress).AddArgument($cancel).AddArgument($CachePath).AddArgument($ItemDelayMs).AddArgument($RecentMinutes)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ Progress = $progress; Cancel = $cancel; PowerShell = $ps; Runspace = $rs; Handle = $handle }
}

# Asks the scan to stop and waits up to 900 ms for it to notice (it checks between items). A scan that is still busy after
# that is stopped hard and marked finished and cancelled.
function Stop-StorageScan {
    param([Parameter(Mandatory)]$Scan)
    $Scan.Cancel['Cancel'] = $true
    Stop-StorageChildProcesses -Progress $Scan.Progress   # a CLI that is working would otherwise run until its timeout
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Scan.Progress['Finished'] -and $sw.ElapsedMilliseconds -lt 900) { Start-Sleep -Milliseconds 10 }
    if (-not $Scan.Progress['Finished']) {
        [void]$Scan.PowerShell.BeginStop($null, $null)
        $Scan.Progress['Cancelled'] = $true; $Scan.Progress['HardStopped'] = $true; $Scan.Progress['Finished'] = $true
    }
}

# The process ids a job started for itself (Progress.ChildPids, a list the job writes, e.g. a claude or codex CLI) are killed
# with their children: taskkill /T /F. Never throws.
function Stop-StorageChildProcesses {
    param($Progress)
    try {
        foreach ($id in @($Progress['ChildPids'])) { if ($id) { try { & taskkill.exe /PID ([int]$id) /T /F 2>&1 | Out-Null } catch { } } }
    } catch { }
}

# Scans whose runspace was told to stop but has not finished stopping: they are disposed later, so that closing never waits.
$script:StoragePendingClose = New-Object Collections.Generic.List[object]

function Clear-StoragePendingClose {
    foreach ($p in $script:StoragePendingClose.ToArray()) {
        $done = $true
        try { $done = ($p.Handle.IsCompleted -or ($p.Stop -and $p.Stop.IsCompleted)) } catch { }
        if (-not $done) { continue }
        try { $p.Scan.PowerShell.Dispose() } catch { }
        try { $p.Scan.Runspace.Dispose() } catch { }
        [void]$script:StoragePendingClose.Remove($p)
    }
}

# Frees the runspace of a finished or stopped scan. A job that is still running is not waited for (the UI thread must not
# hang on a long VACUUM or a CLI): its children are killed, it is told to stop asynchronously and it is disposed by a later
# call (here, Start-StorageScan or Start-StorageJob).
function Close-StorageScan {
    param([Parameter(Mandatory)]$Scan)
    Clear-StoragePendingClose
    $running = $false
    try { $running = -not $Scan.Handle.IsCompleted } catch { }
    if ($running) {
        Stop-StorageChildProcesses -Progress $Scan.Progress
        $stop = $null
        try { $stop = $Scan.PowerShell.BeginStop($null, $null) } catch { }
        $script:StoragePendingClose.Add(@{ Scan = $Scan; Handle = $Scan.Handle; Stop = $stop })
        return
    }
    try { $Scan.PowerShell.Dispose() } catch { }
    try { $Scan.Runspace.Dispose() } catch { }
}
