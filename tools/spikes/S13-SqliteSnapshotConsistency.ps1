# S13 - Is VACUUM INTO from a read-only winsqlite3 connection a consistent snapshot of a WAL database that is being written?
# Writes only under %TEMP%. Plain Windows PowerShell 5.1.
param([int]$Snapshots = 50, [int]$WriterSeconds = 25)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'src\Harness.Sqlite.ps1')
Initialize-WinSqlite

$work = Join-Path ([IO.Path]::GetTempPath()) ('s13-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$db = Join-Path $work 'live.db'

function Invoke-Exec($h, [string]$sql) {
    $rc = [HarnessWinSqlite]::sqlite3_exec($h, (ConvertTo-SqliteUtf8 $sql), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($rc -ne 0) { throw "exec rc=$rc $([HarnessWinSqlite]::Err($h)) :: $sql" }
}
function Open-Rw([string]$path) {
    $h = [IntPtr]::Zero
    $rc = [HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 $path), [ref]$h, 6, [IntPtr]::Zero)   # READWRITE | CREATE
    if ($rc -ne 0) { throw "open rw rc=$rc" }
    return $h
}

try {
    $w = Open-Rw $db
    Invoke-Exec $w 'PRAGMA journal_mode=WAL;'
    Invoke-Exec $w 'CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b BLOB);'
    Invoke-Exec $w 'CREATE INDEX ix_a ON t(a);'
    [void][HarnessWinSqlite]::sqlite3_close($w)

    $writerScript = @"
`$ErrorActionPreference = 'Stop'
. '$($root -replace "'", "''")\src\Harness.Sqlite.ps1'
Initialize-WinSqlite
`$h = [IntPtr]::Zero
[void][HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 '$($db -replace "'", "''")'), [ref]`$h, 6, [IntPtr]::Zero)
function X(`$s) { [void][HarnessWinSqlite]::sqlite3_exec(`$h, (ConvertTo-SqliteUtf8 `$s), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero) }
X 'PRAGMA busy_timeout=5000;'
`$end = (Get-Date).AddSeconds($WriterSeconds); `$n = 0
while ((Get-Date) -lt `$end) {
    X 'BEGIN;'
    for (`$i = 0; `$i -lt 20; `$i++) { `$n++; X "INSERT INTO t(a,b) VALUES ('row`$n', randomblob(2000));" }
    X 'COMMIT;'
    if (`$n % 400 -eq 0) { X 'DELETE FROM t WHERE id % 7 = 0;' }
}
"@
    $writerFile = Join-Path $work 'writer.ps1'
    [IO.File]::WriteAllText($writerFile, $writerScript)
    $writer = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $writerFile -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2

    $ok = 0; $bad = @(); $fileCopyOk = 0; $fileCopyBad = 0; $ms = @()
    for ($i = 1; $i -le $Snapshots; $i++) {
        $snap = Join-Path $work ("snap$i.db")
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # (1) VACUUM INTO from a read-only connection
        $r = Open-SqliteReadOnly -Path $db
        try {
            $rc = [HarnessWinSqlite]::sqlite3_exec($r, (ConvertTo-SqliteUtf8 'PRAGMA busy_timeout=5000;'), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
            $rc = [HarnessWinSqlite]::sqlite3_exec($r, (ConvertTo-SqliteUtf8 ("VACUUM INTO '" + $snap.Replace("'", "''") + "'")), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
            if ($rc -ne 0) { $bad += "snap${i}: vacuum rc=$rc $([HarnessWinSqlite]::Err($r))"; continue }
        } finally { Close-Sqlite $r }
        $sw.Stop(); $ms += $sw.ElapsedMilliseconds
        $c = Open-SqliteReadOnly -Path $snap
        try {
            $res = @(Invoke-SqliteQuery -Handle $c -Sql 'PRAGMA integrity_check')
            $cnt = @(Invoke-SqliteQuery -Handle $c -Sql 'SELECT count(*) AS n FROM t')[0].n
            if ($res.Count -eq 1 -and $res[0].integrity_check -eq 'ok') { $ok++ } else { $bad += "snap${i}: $($res[0].integrity_check)" }
        } finally { Close-Sqlite $c }
        # (2) the old way (file copy of db + wal + shm), for comparison
        $cp = $null
        try { $cp = Copy-SqliteSnapshot -Path $db } catch { $fileCopyBad++; $copyErr = $_.Exception.Message; Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'sqlite-snap-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-5) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        if ($cp) { try {
            $c2 = Open-SqliteReadOnly -Path $cp
            try { $r2 = @(Invoke-SqliteQuery -Handle $c2 -Sql 'PRAGMA integrity_check'); if ($r2[0].integrity_check -eq 'ok') { $fileCopyOk++ } else { $fileCopyBad++ } }
            catch { $fileCopyBad++ } finally { Close-Sqlite $c2 }
        } finally { Remove-Item -LiteralPath (Split-Path -Parent $cp) -Recurse -Force } }
        Start-Sleep -Milliseconds 100
    }
    $verRow = $null; $v = Open-SqliteReadOnly -Path $db; try { $verRow = @(Invoke-SqliteQuery -Handle $v -Sql 'SELECT sqlite_version() AS v')[0].v } finally { Close-Sqlite $v }
    "sqlite version: $verRow"
    "VACUUM INTO: $ok/$Snapshots integrity ok; failures: $($bad.Count)"
    $bad | Select-Object -First 5 | ForEach-Object { "  $_" }
    if ($ms.Count) { "VACUUM INTO ms: min=$(($ms | Measure-Object -Minimum).Minimum) max=$(($ms | Measure-Object -Maximum).Maximum) avg=$([int](($ms | Measure-Object -Average).Average))" }
    "file-copy snapshot (current Copy-SqliteSnapshot): ok=$fileCopyOk bad=$fileCopyBad (last error: $copyErr)"
    "live db size KB: $([int]((Get-Item $db).Length/1KB))"
} finally {
    if ($writer -and -not $writer.HasExited) { Stop-Process -Id $writer.Id -Force }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
