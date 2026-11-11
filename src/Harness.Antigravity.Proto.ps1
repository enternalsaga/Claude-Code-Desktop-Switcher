# Harness.Antigravity.Proto.ps1 - schema-less protobuf reader for Antigravity conversation databases (from spike S5).
# There is no .proto file, so this walks the wire format only: every length-delimited field is taken as UTF-8 text when
# it is clean text, otherwise as a nested message. It is the fallback when brain\<id>\.system_generated\logs\transcript.jsonl
# is missing. Needs Harness.Sqlite.ps1.

function Initialize-AgyProtoWalker {
    if ('HarnessPbWalk' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
public static class HarnessPbWalk {
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
    foreach (char c in t) { if (c < 0x20 && c != '\n' && c != '\r' && c != '\t') return false; }
    text = t; return true;
  }
  // False when the bytes are not one well-formed message. Text leaves are added as (path, text).
  public static bool Walk(byte[] b, int s, int e, string path, int depth, List<string[]> leaves) {
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
    leaves.AddRange(mine);
    return true;
  }
}
'@
}

# Text leaves of one protobuf message as @{ Path = '/19/2'; Text = '...' } objects, in wire order.
# $null when the bytes are not a well-formed message.
function ConvertFrom-AgyProtobuf {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    Initialize-AgyProtoWalker
    $leaves = New-Object 'System.Collections.Generic.List[string[]]'
    if (-not [HarnessPbWalk]::Walk($Bytes, 0, $Bytes.Length, '', 0, $leaves)) { return $null }
    return @($leaves | ForEach-Object { [pscustomobject]@{ Path = $_[0]; Text = $_[1] } })
}

# step_type -> role and the protobuf paths that hold the text (spike S5, checked against Antigravity's own transcript).
function Get-AgyStepTypeTable {
    return @{
        14  = @{ Role = 'user';      Name = 'USER_INPUT';       Text = '/19/2' }
        15  = @{ Role = 'assistant'; Name = 'PLANNER_RESPONSE'; Text = '/20/1' }
        5   = @{ Role = 'tool'; Name = 'CODE_ACTION';      Args = '/5/4/3' }
        8   = @{ Role = 'tool'; Name = 'VIEW_FILE';        Args = '/5/4/3' }
        9   = @{ Role = 'tool'; Name = 'LIST_DIRECTORY';   Args = '/5/4/3' }
        21  = @{ Role = 'tool'; Name = 'RUN_COMMAND';      Args = '/5/4/3' }
        127 = @{ Role = 'tool'; Name = 'INVOKE_SUBAGENT';  Args = '/143/9/3' }
        132 = @{ Role = 'tool'; Name = 'GENERIC';          Args = '/5/4/3' }
    }
}

# Normalized {role, text, ts, tool{name,arg,output}} entries from a conversation .db, in step order. System steps
# (SYSTEM_MESSAGE, CHECKPOINT, CONVERSATION_HISTORY, ERROR_MESSAGE) and unknown step types are skipped. Reads a snapshot.
function ConvertFrom-AgyDb {
    param([Parameter(Mandatory)][string]$Path)
    $table = Get-AgyStepTypeTable
    $systemTypes = @(17, 23, 98, 101)   # ERROR_MESSAGE, CHECKPOINT, CONVERSATION_HISTORY, SYSTEM_MESSAGE
    $snap = Copy-SqliteSnapshot -Path $Path
    $entries = New-Object Collections.Generic.List[object]
    try {
        $db = Open-SqliteReadOnly -Path $snap
        try {
            foreach ($row in Invoke-SqliteQuery -Handle $db -Sql 'select idx, step_type, step_payload from steps order by idx') {
                $type = [int]$row.step_type
                if ($systemTypes -contains $type -or $row.step_payload -isnot [byte[]]) { continue }
                # a step type the table does not know still counts as a tool step when it carries tool-call JSON
                $spec = $table[$type]
                if (-not $spec) { $spec = @{ Role = 'tool'; Name = "STEP_$type"; Args = '/5/4/3' } }
                $leaves = ConvertFrom-AgyProtobuf -Bytes $row.step_payload
                if (-not $leaves) { continue }
                if ($spec.Role -eq 'tool') {
                    $json = (@($leaves | Where-Object { $_.Path -eq $spec.Args } | ForEach-Object { $_.Text }) -join "`n")
                    if (-not $json) { continue }
                    $entries.Add(@{ role = 'tool'; text = ''; ts = $null; tool = @{ name = $spec.Name; arg = (Get-AgyToolArg -Json $json); output = '' } })
                } else {
                    $text = (@($leaves | Where-Object { $_.Path -eq $spec.Text } | ForEach-Object { $_.Text }) -join "`n").Trim()
                    if ($text) { $entries.Add(@{ role = $spec.Role; text = $text; ts = $null }) }
                }
            }
        } finally { Close-Sqlite -Handle $db }
    } finally {
        if (Test-Path -LiteralPath (Split-Path -Parent $snap)) { Remove-Item -LiteralPath (Split-Path -Parent $snap) -Recurse -Force }
    }
    return $entries.ToArray()
}
