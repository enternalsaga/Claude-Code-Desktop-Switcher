# Spike S5: schema-less protobuf decode of Antigravity `steps.step_payload` (wire format only), run on a COPY of a conversation .db.
# Prints, per step, the UTF-8 strings of >= MinLen chars with their field path, then a step_type summary.
param(
  [Parameter(Mandatory)][string]$DbPath,
  [int]$MinLen = 20,
  [int]$MaxStepsShown = 60,
  [int]$ClipChars = 160,
  [string]$ReportDir,
  [string]$BrainTranscript   # optional: copy of brain\<id>\.system_generated\logs\transcript.jsonl, used only to label step_type
)
$ErrorActionPreference = 'Stop'
if (-not ([System.Management.Automation.PSTypeName]'WSql').Type) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WSql {
  const string D = "winsqlite3.dll";
  [DllImport(D, CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern int sqlite3_open_v2(string f, out IntPtr db, int flags, IntPtr vfs);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPStr)] string sql, int n, out IntPtr st, IntPtr tail);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_step(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_text16(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_blob(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_column_bytes(IntPtr st, int i);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_finalize(IntPtr st);
  [DllImport(D, CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_close(IntPtr db);
  public static string Text(IntPtr st, int i) { IntPtr p = sqlite3_column_text16(st, i); return p == IntPtr.Zero ? null : Marshal.PtrToStringUni(p); }
  public static byte[] Blob(IntPtr st, int i) { int n = sqlite3_column_bytes(st, i); IntPtr p = sqlite3_column_blob(st, i); if (p == IntPtr.Zero || n <= 0) return new byte[0]; byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return b; }
}
'@
}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
public static class PbWalk {
  // Returns false when the bytes are not a well-formed protobuf message. Leaves are collected as (path, text).
  static bool ReadVarint(byte[] b, ref int p, int e, out ulong v) {
    v = 0; int shift = 0;
    while (p < e && shift < 70) { byte x = b[p++]; v |= (ulong)(x & 0x7F) << shift; if ((x & 0x80) == 0) return true; shift += 7; }
    return false;
  }
  static bool LooksLikeText(byte[] b, int s, int len, out string text) {
    text = null;
    if (len == 0) return false;
    string t;
    try { t = new UTF8Encoding(false, true).GetString(b, s, len); } catch { return false; }
    int bad = 0;
    foreach (char c in t) { if (c < 0x20 && c != '\n' && c != '\r' && c != '\t') bad++; }
    if (bad > 0) return false;
    text = t; return true;
  }
  public static bool Walk(byte[] b, int s, int e, string path, int depth, List<string[]> outLeaves) {
    int p = s; var mine = new List<string[]>();
    if (s == e) return false;
    while (p < e) {
      ulong tag; if (!ReadVarint(b, ref p, e, out tag)) return false;
      ulong field = tag >> 3; int wt = (int)(tag & 7);
      if (field == 0) return false;
      string fp = path + "/" + field;
      if (wt == 0) { ulong v; if (!ReadVarint(b, ref p, e, out v)) return false; }
      else if (wt == 1) { if (p + 8 > e) return false; p += 8; }
      else if (wt == 5) { if (p + 4 > e) return false; p += 4; }
      else if (wt == 2) {
        ulong l; if (!ReadVarint(b, ref p, e, out l)) return false;
        if (l > (ulong)(e - p)) return false;
        int len = (int)l; string text;
        if (LooksLikeText(b, p, len, out text)) mine.Add(new string[] { fp, text });
        else if (depth < 12) { var sub = new List<string[]>(); if (Walk(b, p, p + len, fp, depth + 1, sub)) mine.AddRange(sub); }
        p += len;
      } else return false;
    }
    outLeaves.AddRange(mine);
    return true;
  }
}
'@

function Read-Rows($file, $sql, [bool[]]$blob) {
  $d = [IntPtr]::Zero
  if ([WSql]::sqlite3_open_v2($file, [ref]$d, 1, [IntPtr]::Zero) -ne 0) { throw 'open failed' }
  try {
    $st = [IntPtr]::Zero
    if ([WSql]::sqlite3_prepare_v2($d, $sql, -1, [ref]$st, [IntPtr]::Zero) -ne 0) { throw 'prepare failed' }
    try {
      while ([WSql]::sqlite3_step($st) -eq 100) {
        $r = @(for ($i = 0; $i -lt $blob.Count; $i++) { if ($blob[$i]) { , [WSql]::Blob($st, $i) } else { [WSql]::Text($st, $i) } })
        , $r
      }
    } finally { [void][WSql]::sqlite3_finalize($st) }
  } finally { [void][WSql]::sqlite3_close($d) }
}

$rows = Read-Rows $DbPath 'select idx, step_type, status, step_payload from steps order by idx' @($false, $false, $false, $true)
$byType = @{}
$shown = 0
$report = New-Object Collections.ArrayList
foreach ($r in $rows) {
  $idx = [int]$r[0]; $type = [int]$r[1]; $payload = [byte[]]$r[3]
  $leaves = New-Object 'System.Collections.Generic.List[string[]]'
  $ok = [PbWalk]::Walk($payload, 0, $payload.Length, '', 0, $leaves)
  $long = @($leaves | Where-Object { $_[1].Length -ge $MinLen })
  if (-not $byType.ContainsKey($type)) { $byType[$type] = [ordered]@{ steps = 0; wellFormed = 0; strings = 0; firstIdx = $idx; paths = @{} } }
  $t = $byType[$type]; $t.steps++; if ($ok) { $t.wellFormed++ }; $t.strings += $long.Count
  foreach ($l in $long) { $t.paths[$l[0]] = 1 + [int]$t.paths[$l[0]] }
  [void]$report.Add([pscustomobject]@{ Idx = $idx; Type = $type; Ok = $ok; Leaves = $long })
  if ($shown -lt $MaxStepsShown) {
    $shown++
    "[step $idx type=$type wellFormed=$ok bytes=$($payload.Length) strings>=$MinLen : $($long.Count)]"
    foreach ($l in ($long | Select-Object -First 6)) {
      $s = ($l[1] -replace '\s+', ' '); if ($s.Length -gt $ClipChars) { $s = $s.Substring(0, $ClipChars) + '...' }
      "    $($l[0])  $s"
    }
  }
}
'--- step_type summary'
foreach ($k in ($byType.Keys | Sort-Object)) {
  $t = $byType[$k]
  $top = ($t.paths.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { "$($_.Key)x$($_.Value)" }) -join ' '
  "type $k : steps=$($t.steps) wellFormed=$($t.wellFormed) longStrings=$($t.strings) firstIdx=$($t.firstIdx) topPaths=$top"
}

# --- Readable transcript built ONLY from the decoded protobuf (no brain\ files): the answer to "can we get user/model text?"
# Role table learned from this spike (see the results doc): 14 = user input (text at /19/2), 15 = model turn (text /20/1,
# thinking /20/3, tool calls /20/7/*), tool-step types 5, 8, 9, 21, 127, 132 = tool calls whose args JSON is at /5/4/3.
$userPath = '/19/2'; $modelText = '/20/1'; $modelCalls = '/20/7/3'; $toolArgs = '/5/4/3'
$md = New-Object Text.StringBuilder
foreach ($r in $report) {
  $text = { param($p) (@($r.Leaves | Where-Object { $_[0] -eq $p } | ForEach-Object { $_[1] }) -join "`n") }
  switch ($r.Type) {
    14 { [void]$md.AppendLine("## USER (step $($r.Idx))"); [void]$md.AppendLine(((& $text $userPath) -replace '^\s+', '')); [void]$md.AppendLine() }
    15 {
      $t = & $text $modelText; $c = & $text $modelCalls
      if ($t -or $c) { [void]$md.AppendLine("## MODEL (step $($r.Idx))"); if ($t) { [void]$md.AppendLine($t) }; if ($c) { [void]$md.AppendLine("tool calls: $c") }; [void]$md.AppendLine() }
    }
    { $_ -in 5, 8, 9, 21, 127, 132 } { $a = & $text $toolArgs; if ($a) { [void]$md.AppendLine("- tool step $($r.Idx) (type $($r.Type)): $($a -replace '\s+', ' ')") } }
  }
}
$transcript = $md.ToString()
"--- readable transcript from decoded steps: $($transcript.Length) chars, USER blocks=$([regex]::Matches($transcript,'## USER').Count), MODEL blocks=$([regex]::Matches($transcript,'## MODEL').Count)"
if ($ReportDir) { New-Item -ItemType Directory -Force $ReportDir | Out-Null; Set-Content (Join-Path $ReportDir 'transcript-from-protobuf.md') $transcript -Encoding UTF8 }

# --- Cross-check against Antigravity's own brain\<id>\.system_generated\logs\transcript.jsonl (join on step_index = steps.idx)
if ($BrainTranscript) {
  $map = @{}; $bad = 0
  foreach ($line in [IO.File]::ReadAllLines($BrainTranscript, [Text.Encoding]::UTF8)) {
    try { $o = $line | ConvertFrom-Json } catch { $bad++; continue }
    $map[[int]$o.step_index] = "$($o.type)/$($o.source)"
  }
  '--- step_type -> Antigravity transcript.jsonl type/source (join on step_index; unparsable lines skipped: ' + $bad + ')'
  $report | Group-Object Type | Sort-Object { [int]$_.Name } | ForEach-Object {
    $names = ($_.Group | ForEach-Object { $map[[int]$_.Idx] } | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    "type $($_.Name) => $names"
  }
}
if ($ReportDir) {
  New-Item -ItemType Directory -Force $ReportDir | Out-Null
  $report | ForEach-Object { [pscustomobject]@{ idx = $_.Idx; type = $_.Type; leaves = @($_.Leaves | ForEach-Object { @{ path = $_[0]; text = $_[1] } }) } } |
    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ReportDir 'steps-decoded.json') -Encoding UTF8
}

