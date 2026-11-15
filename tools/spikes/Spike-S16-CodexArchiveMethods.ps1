# Spike S16: what do the Codex app-server methods thread/archive, thread/unarchive and thread/delete do to the rollout file and to the
# threads row, and is writing archived=1 straight into state_5.sqlite (app closed) enough? Scratch home under
# %TEMP%\harness-spike\S16 only (Assert-SpikeHome); the source rollout is read-only; no auth.json, no model call.
param([Parameter(Mandatory)][string]$SourceRollout)    # a small plain .jsonl rollout named ...-<threadId>.jsonl
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S8-CodexSpikeCommon.ps1')
. (Join-Path $PSScriptRoot '..\..\src\Harness.Sqlite.ps1')
$H = Join-Path $env:TEMP 'harness-spike\S16\home'
Assert-SpikeHome $H
if ($SourceRollout -notmatch '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$') { throw 'need rollout-...-<threadId>.jsonl' }
$oldId = $Matches[1]
$first = (Get-Content -LiteralPath $SourceRollout -TotalCount 1 | ConvertFrom-Json).payload
$esc = { param($p) ($p | ConvertTo-Json -Compress).Trim('"') }

function New-Thread {
    $id = [guid]::NewGuid().ToString()
    $text = [IO.File]::ReadAllText($SourceRollout, [Text.Encoding]::UTF8).Replace($oldId, $id)
    $text = $text.Replace((& $esc ([string]$first.cwd)), (& $esc ([IO.Path]::GetTempPath().TrimEnd('\'))))
    $dst = Join-Path $H "sessions\2026\11\15\rollout-2026-11-15T09-00-00-$id.jsonl"
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding($false)))
    return $id
}
function Get-Rows([string]$Id) {
    $db = Join-Path $H 'state_5.sqlite'; if (-not (Test-Path -LiteralPath $db)) { return @() }
    $s = Copy-SqliteSnapshot $db
    try { $h = Open-SqliteReadOnly $s; try { @(Invoke-SqliteQuery $h "select id, archived, archived_at, rollout_path from threads where id='$Id'") } finally { Close-Sqlite $h } }
    finally { Remove-Item -LiteralPath (Split-Path $s) -Recurse -Force -ErrorAction SilentlyContinue }
}
function Get-RowsFull([string]$Id) {
    $db = Join-Path $H 'state_5.sqlite'; $s = Copy-SqliteSnapshot $db
    try { $h = Open-SqliteReadOnly $s; try { @(Invoke-SqliteQuery $h "select * from threads where id='$Id'") } finally { Close-Sqlite $h } } finally { Remove-Item -LiteralPath (Split-Path $s) -Recurse -Force -ErrorAction SilentlyContinue }
}
function Show([string]$When, [string]$Id) {
    $r = @(Get-Rows $Id)
    $files = @(Get-ChildItem $H -Recurse -File -Filter "rollout-*$Id*" | ForEach-Object { $_.FullName.Substring($H.Length + 1).Split('\')[0] })
    $row = if ($r.Count) { "row archived=$($r[0].archived) archived_at set=$([bool]$r[0].archived_at) path-in=$((Split-Path (Split-Path $r[0].rollout_path -Parent) -Leaf))" } else { 'no row' }
    "  [$When] $row; rollout file under: $($files -join ',')"
}
function Invoke-Db([string]$Sql) {      # writes only the scratch db, only while no app-server runs
    $dbp = Join-Path $H 'state_5.sqlite'; Initialize-WinSqlite
    $h = [IntPtr]::Zero
    if ([HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 $dbp), [ref]$h, 2, [IntPtr]::Zero) -ne 0) { throw 'open rw failed' }
    try { $rc = [HarnessWinSqlite]::sqlite3_exec($h, (ConvertTo-SqliteUtf8 $Sql), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero); if ($rc -ne 0) { throw "exec rc=$rc $([HarnessWinSqlite]::Err($h))" } } finally { [void][HarnessWinSqlite]::sqlite3_close($h) }
}
function Invoke-Session([scriptblock]$Body) {
    $srv = Start-AppServer $H
    try { [void](Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } }); Send-Notification $srv 'initialized'; & $Body $srv } finally { Stop-AppServer $srv }
}
$listQ = @{ limit = 100; modelProviders = @(); sourceKinds = @('cli', 'vscode', 'exec', 'appServer', 'unknown') }
function Test-Listed($srv, [string]$Id, [bool]$Archived) { $q = $listQ.Clone(); if ($Archived) { $q.archived = $true }; return (@((Invoke-Rpc $srv 'thread/list' $q).result.data | Where-Object id -eq $Id).Count -gt 0) }

Remove-Item (Split-Path $H) -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $H | Out-Null
try {
    # empty start makes the database; then three rollouts, one per scenario
    Invoke-Session { param($s) Start-Sleep 3 }
    $a = New-Thread; $b = New-Thread; $c = New-Thread; $d = New-Thread; $e = New-Thread
    "threads: A (app-server archive/unarchive), B (app-server delete), C (direct SQL, app closed), D (delete then put the rollout back), E (archive then remove the file by hand)"
    Invoke-Session {
        param($s)
        Start-Sleep 8
        foreach ($id in $a, $b, $c, $d, $e) { [void](Invoke-Rpc $s 'thread/read' @{ threadId = $id; includeTurns = $false }) }
        '--- A: thread/archive then thread/unarchive through the app-server'
        Show 'registered' $a
        $r = Invoke-Rpc $s 'thread/archive' @{ threadId = $a }; "  thread/archive -> $(if ($r.error) { ($r.error | ConvertTo-Json -Compress) } else { 'ok ' + ($r.result | ConvertTo-Json -Compress) })"
        Start-Sleep 2; Show 'after archive' $a
        "  thread/list default has it: $(Test-Listed $s $a $false); archived=true list has it: $(Test-Listed $s $a $true)"
        $rd = Invoke-Rpc $s 'thread/read' @{ threadId = $a; includeTurns = $true }; "  thread/read while archived: ok=$([bool]$rd.result)"
        $r = Invoke-Rpc $s 'thread/unarchive' @{ threadId = $a }; "  thread/unarchive -> $(if ($r.error) { ($r.error | ConvertTo-Json -Compress) } else { 'ok, returns the thread object' })"
        Start-Sleep 2; Show 'after unarchive' $a
        "  thread/list default has it again: $(Test-Listed $s $a $false)"
        '--- B: thread/delete through the app-server'
        Show 'before delete' $b
        $r = Invoke-Rpc $s 'thread/delete' @{ threadId = $b }; "  thread/delete -> $(if ($r.error) { ($r.error | ConvertTo-Json -Compress) } else { 'ok ' + ($r.result | ConvertTo-Json -Compress) })"
        Start-Sleep 2; Show 'after delete' $b
        "  listed after delete: $(Test-Listed $s $b $false) / archived list: $(Test-Listed $s $b $true)"
    }
    '--- D: thread/delete, then the same rollout dropped back into sessions\ (what a restore would do)'
    $dRow = @(Get-RowsFull $d)[0]; $dFile = (Get-ChildItem $H -Recurse -File -Filter "rollout-*$d*" | Select-Object -First 1).FullName; $dKeep = Join-Path (Split-Path $H) 'keep-d.jsonl'; Copy-Item $dFile $dKeep
    Invoke-Session { param($s) $r = Invoke-Rpc $s 'thread/delete' @{ threadId = $d }; "  thread/delete -> $(if ($r.error) { 'error' } else { 'ok' })" }
    Show 'after delete' $d
    Copy-Item $dKeep $dFile
    Invoke-Session { param($s) Start-Sleep 8; $rd = Invoke-Rpc $s 'thread/read' @{ threadId = $d; includeTurns = $false }; "  thread/read of the put-back rollout ok=$([bool]$rd.result)" }
    Show 'after put back + read' $d
    $dRow2 = @(Get-RowsFull $d)[0]
    "  columns compared before delete / after put back: " + (($dRow.PSObject.Properties | ForEach-Object { $n = $_.Name; if ([string]$dRow.$n -eq [string]$dRow2.$n) { $null } else { $n } } | Where-Object { $_ }) -join ', ') + " differ (empty = identical)"
    '--- E: archived through the app-server, then the rollout file removed by hand'
    Invoke-Session { param($s) [void](Invoke-Rpc $s 'thread/archive' @{ threadId = $e }) }
    Get-ChildItem $H -Recurse -File -Filter "rollout-*$e*" | Remove-Item -Force
    Show 'file removed' $e
    Invoke-Session { param($s) Start-Sleep 5; "  archived list has it: $(Test-Listed $s $e $true)"; $rd = Invoke-Rpc $s 'thread/read' @{ threadId = $e; includeTurns = $false }; "  thread/read ok=$([bool]$rd.result) $(if ($rd.error) { ($rd.error.message -replace '[A-Za-z]:\\\\[^ ]*','<path>') })" }
    Show 'after restart' $e
    '--- C: app closed, archived=1 written straight into state_5.sqlite, rollout left where it is'
    Show 'before' $c
    Invoke-Db "update threads set archived=1, archived_at=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) where id='$c'"
    Show 'after SQL update' $c
    Invoke-Session { param($s) Start-Sleep 4; "  after restart: default list has it: $(Test-Listed $s $c $false); archived list has it: $(Test-Listed $s $c $true)"; $rd = Invoke-Rpc $s 'thread/read' @{ threadId = $c; includeTurns = $false }; "  thread/read ok=$([bool]$rd.result)" }
    Show 'after restart' $c
    '--- C2: same, then move the rollout to archived_sessions\ by hand and point rollout_path at it'
    Invoke-Db "update threads set archived=0, archived_at=NULL where id='$c'"
    $src = Get-ChildItem $H -Recurse -File -Filter "rollout-*$c*" | Select-Object -First 1
    New-Item -ItemType Directory -Force (Join-Path $H 'archived_sessions') | Out-Null
    $to = Join-Path $H "archived_sessions\$($src.Name)"; Move-Item $src.FullName $to
    Invoke-Db ("update threads set archived=1, archived_at=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()), rollout_path='" + $to.Replace("'", "''") + "' where id='$c'")
    Invoke-Session { param($s) Start-Sleep 4; "  after restart: default list has it: $(Test-Listed $s $c $false); archived list has it: $(Test-Listed $s $c $true)"; $u = Invoke-Rpc $s 'thread/unarchive' @{ threadId = $c }; "  thread/unarchive of a hand-archived thread: $(if ($u.error) { ($u.error | ConvertTo-Json -Compress) } else { 'ok' })" }
    Show 'after unarchive' $c
} finally {
    Remove-Item -LiteralPath (Split-Path (Split-Path $H)) -Recurse -Force -ErrorAction SilentlyContinue
    "cleanup: scratch folder gone = $(-not (Test-Path -LiteralPath $H))"
}
