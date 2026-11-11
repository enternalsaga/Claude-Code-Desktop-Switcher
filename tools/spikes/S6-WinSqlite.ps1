# Spike S6: read SQLite through winsqlite3.dll P/Invoke on Windows PowerShell 5.1. Read-only, works on copies.
param([string]$Dir = (Join-Path $env:TEMP 'harness-spike\S6'))
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WSql {
  const string D = "winsqlite3.dll";
  [DllImport(D, CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern int sqlite3_open_v2(string f, out IntPtr db, int flags, IntPtr vfs);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPStr)] string sql, int n, out IntPtr st, IntPtr tail);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_step(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_column_count(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_text16(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_blob(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_column_bytes(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_column_type(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_finalize(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_close(IntPtr db);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_errmsg16(IntPtr db);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_libversion();
  public static string Text(IntPtr st, int i) { IntPtr p = sqlite3_column_text16(st, i); return p == IntPtr.Zero ? null : Marshal.PtrToStringUni(p); }
  public static byte[] Blob(IntPtr st, int i) { int n = sqlite3_column_bytes(st, i); IntPtr p = sqlite3_column_blob(st, i); if (p == IntPtr.Zero || n <= 0) return new byte[0]; byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return b; }
  public static string Err(IntPtr db) { return Marshal.PtrToStringUni(sqlite3_errmsg16(db)); }
  public static string Version() { return Marshal.PtrToStringAnsi(sqlite3_libversion()); }
}
'@
function Invoke-Q($file, $sql, [int[]]$blobCols = @()) {
  $db = [IntPtr]::Zero
  $rc = [WSql]::sqlite3_open_v2($file, [ref]$db, 1, [IntPtr]::Zero)   # 1 = SQLITE_OPEN_READONLY
  if ($rc -ne 0) { throw "open rc=$rc" }
  try {
    $st = [IntPtr]::Zero
    $rc = [WSql]::sqlite3_prepare_v2($db, $sql, -1, [ref]$st, [IntPtr]::Zero)
    if ($rc -ne 0) { throw "prepare rc=$rc $([WSql]::Err($db))" }
    try {
      $n = [WSql]::sqlite3_column_count($st)
      while ([WSql]::sqlite3_step($st) -eq 100) {   # SQLITE_ROW
        $row = [ordered]@{}
        for ($i = 0; $i -lt $n; $i++) {
          if ($blobCols -contains $i) { $row["c$i"] = [WSql]::Blob($st, $i) } else { $row["c$i"] = [WSql]::Text($st, $i) }
        }
        [pscustomobject]$row
      }
    } finally { [void][WSql]::sqlite3_finalize($st) }
  } finally { [void][WSql]::sqlite3_close($db) }
}
"PS $($PSVersionTable.PSVersion)  sqlite $([WSql]::Version())"
$codex = Join-Path $Dir 'state_5.sqlite'
'--- Codex threads (title UTF-16 text; first 5)'
Invoke-Q $codex 'select id,title,cwd from threads limit 5' | Format-Table -AutoSize | Out-String -Width 220
$agy = Get-ChildItem $Dir -Filter '*-*-*-*-*.db' | Select-Object -First 1
"--- Antigravity db: $($agy.Name)"
Invoke-Q $agy.FullName "select name from sqlite_master where type='table'" | ForEach-Object c0
$rows = @(Invoke-Q $agy.FullName 'select idx, step_type, step_payload from steps order by idx limit 5' -blobCols 2)
foreach ($r in $rows) { "idx=$($r.c0) step_type=$($r.c1) payload_bytes=$($r.c2.Length) first8=$(($r.c2[0..7] | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')" }
$sum = Join-Path $Dir 'conversation_summaries.db'
'--- conversation_summaries.db tables'
Invoke-Q $sum "select name, sql from sqlite_master" | ForEach-Object { "$($_.c0): $($_.c1)" }
