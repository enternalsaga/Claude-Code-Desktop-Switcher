# Harness.Sqlite.ps1 - read-only SQLite access through winsqlite3.dll (spike S6). Plain functions; no app data is touched.

# --- Read-only SQLite through winsqlite3.dll (spike S6) -------------------------
# Always work on a copy (Copy-SqliteSnapshot): never open an app's live database, and never one on Drive.

function Initialize-WinSqlite {
    if ('HarnessWinSqlite' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HarnessWinSqlite {
  const string D = "winsqlite3.dll";
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_open_v2(byte[] file, out IntPtr db, int flags, IntPtr vfs);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, IntPtr err);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_step(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_column_count(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_column_type(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_name16(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_text16(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_blob(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_column_bytes(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern long sqlite3_column_int64(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern double sqlite3_column_double(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_finalize(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_close(IntPtr db);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_errmsg16(IntPtr db);
  public static string Name(IntPtr st, int i) { return Marshal.PtrToStringUni(sqlite3_column_name16(st, i)); }
  public static string Text(IntPtr st, int i) { IntPtr p = sqlite3_column_text16(st, i); return p == IntPtr.Zero ? null : Marshal.PtrToStringUni(p); }
  public static byte[] Blob(IntPtr st, int i) {
    int n = sqlite3_column_bytes(st, i); IntPtr p = sqlite3_column_blob(st, i);
    if (p == IntPtr.Zero || n <= 0) return new byte[0];
    byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return b;
  }
  public static string Err(IntPtr db) { return Marshal.PtrToStringUni(sqlite3_errmsg16(db)); }
}
'@
}

function ConvertTo-SqliteUtf8 {
    param([Parameter(Mandatory)][string]$Text)
    return , [Text.Encoding]::UTF8.GetBytes($Text + "`0")
}

# Flags 1 = SQLITE_OPEN_READONLY. Returns an opaque handle for Invoke-SqliteQuery / Close-Sqlite.
function Open-SqliteReadOnly {
    param([Parameter(Mandatory)][string]$Path)
    Initialize-WinSqlite
    if (-not (Test-Path -LiteralPath $Path)) { throw "SQLite file not found: $Path" }
    $db = [IntPtr]::Zero
    $rc = [HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 ([IO.Path]::GetFullPath($Path))), [ref]$db, 1, [IntPtr]::Zero)
    if ($rc -ne 0) { if ($db -ne [IntPtr]::Zero) { [void][HarnessWinSqlite]::sqlite3_close($db) }; throw "sqlite3_open_v2 failed (rc=$rc): $Path" }
    return $db
}

function Close-Sqlite {
    param([Parameter(Mandatory)][IntPtr]$Handle)
    [void][HarnessWinSqlite]::sqlite3_close($Handle)
}

# Rows come back as objects keyed by column name: NULL -> $null, integer -> int64, real -> double,
# text -> string (UTF-16), blob -> byte[]. Anything other than a clean read throws, including write attempts.
function Invoke-SqliteQuery {
    param([Parameter(Mandatory)][IntPtr]$Handle, [Parameter(Mandatory)][string]$Sql)
    $st = [IntPtr]::Zero
    $rc = [HarnessWinSqlite]::sqlite3_prepare_v2($Handle, (ConvertTo-SqliteUtf8 $Sql), -1, [ref]$st, [IntPtr]::Zero)
    if ($rc -ne 0) { throw "sqlite3_prepare_v2 failed (rc=$rc): $([HarnessWinSqlite]::Err($Handle))" }
    try {
        $n = [HarnessWinSqlite]::sqlite3_column_count($st)
        while (($rc = [HarnessWinSqlite]::sqlite3_step($st)) -eq 100) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $n; $i++) {
                $value = switch ([HarnessWinSqlite]::sqlite3_column_type($st, $i)) {
                    1 { [HarnessWinSqlite]::sqlite3_column_int64($st, $i) }
                    2 { [HarnessWinSqlite]::sqlite3_column_double($st, $i) }
                    3 { [HarnessWinSqlite]::Text($st, $i) }
                    4 { , [HarnessWinSqlite]::Blob($st, $i) }
                    default { $null }
                }
                $row[[HarnessWinSqlite]::Name($st, $i)] = $value
            }
            [pscustomobject]$row
        }
        if ($rc -ne 101) { throw "sqlite3_step failed (rc=$rc): $([HarnessWinSqlite]::Err($Handle))" }
    } finally { [void][HarnessWinSqlite]::sqlite3_finalize($st) }
}

# Copies the database plus its -wal / -shm companions into a fresh temp folder and returns the copy's path.
# The caller deletes the parent folder when done.
function Copy-SqliteSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "SQLite file not found: $Path" }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('sqlite-snap-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($suffix in '', '-wal', '-shm') {
        if (Test-Path -LiteralPath ($Path + $suffix)) { Copy-Item -LiteralPath ($Path + $suffix) -Destination (Join-Path $dir ((Split-Path -Leaf $Path) + $suffix)) }
    }
    return (Join-Path $dir (Split-Path -Leaf $Path))
}
