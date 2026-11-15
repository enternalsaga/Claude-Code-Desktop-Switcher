# Spike S17: what does Antigravity show when a conversation's .db and brain\<id> are gone but its row in conversation_summaries.db stays,
# and does putting the .db and brain back bring the chat back? Runs ONLY against a spike instance of the app: its own --user-data-dir
# (%LOCALAPPDATA%\AgyProfile-spike-s17) and a fake home (%USERPROFILE%\.gemini-profiles\spike-s17\home), as in S4. The real
# ~\.gemini\antigravity is only read (one small conversation is copied out of it). The seeing part is USER ACTION (see the stage list).
#
#   -Action Prepare   copy one small real conversation (db + brain) into the spike data dir; keep a backup copy under %TEMP%
#   -Action Launch    start the spike instance (no other Antigravity window is touched)
#   -Action Inspect   names/counts only: files present for the test conversation, its row in conversation_summaries.db
#   -Action Remove    (spike instance closed) delete the test conversation's .db, -wal, -shm and brain folder from the spike data dir
#   -Action Restore   (spike instance closed) copy them back from the backup
#   -Action RemoveRow (spike instance closed) delete the test conversation's row from the spike summaries db, keep nothing else changed
#   -Action RemoveOtherStores (spike instance closed) delete the test conversation from the copies the app itself made in the spike home\n#                     (.gemini\antigravity-ide and .gemini\antigravity-backup; found in the first run: the new app copies conversations there)\n#   -Action RemoveHubCache (spike instance closed) delete agyhub_summaries_proto.pb, the hub's own summary cache, from the spike data dir\n#                     (found in the second run: the row and the conversation came back from it)\n#   -Action Cleanup   (spike instance closed) delete the spike data dir, the user-data-dir and the backup
param([Parameter(Mandatory)][ValidateSet('Prepare', 'Launch', 'Inspect', 'Remove', 'Restore', 'RemoveRow', 'RemoveOtherStores', 'RemoveHubCache', 'Cleanup')][string]$Action)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'src\Harness.Sqlite.ps1')
$name = 'spike-s17'
$gem = Join-Path $env:USERPROFILE ".gemini-profiles\$name"
$fakeHome = Join-Path $gem 'home'
$data = Join-Path $fakeHome '.gemini\antigravity'
$ud = Join-Path $env:LOCALAPPDATA "AgyProfile-$name"
$tmp = Join-Path $env:TEMP 'harness-spike\S17'
$state = Join-Path $tmp 'state.json'
$real = Join-Path $env:USERPROFILE '.gemini\antigravity'
foreach ($p in $data, $ud, $tmp) { if ($p -notlike "*$name*" -and $p -notlike '*harness-spike\S17*') { throw "refusing a path that is not a spike path: $p" } }

function Test-Running {
    return (@(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^Antigravity' -and $_.CommandLine -match [regex]::Escape("AgyProfile-$name") -and $_.CommandLine -notmatch '--type=' }).Count -gt 0)
}
function Get-State { if (-not (Test-Path -LiteralPath $state)) { throw 'run -Action Prepare first' }; Get-Content -LiteralPath $state -Raw | ConvertFrom-Json }
function Invoke-Rw([string]$Db, [string]$Sql) {
    Initialize-WinSqlite; $h = [IntPtr]::Zero
    if ([HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 $Db), [ref]$h, 2, [IntPtr]::Zero) -ne 0) { throw 'open rw failed' }
    try { $rc = [HarnessWinSqlite]::sqlite3_exec($h, (ConvertTo-SqliteUtf8 $Sql), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero); if ($rc -ne 0) { throw "exec rc=$rc $([HarnessWinSqlite]::Err($h))" } } finally { [void][HarnessWinSqlite]::sqlite3_close($h) }
}
function Short([string]$Id) { return $Id.Substring(0, 8) }

switch ($Action) {
    'Prepare' {
        if (Test-Path -LiteralPath $state) { throw 'already prepared; run -Action Cleanup first' }
        # smallest real conversation that has a brain folder
        $pick = Get-ChildItem (Join-Path $real 'conversations') -File -Filter *.db | Where-Object { Test-Path (Join-Path $real "brain\$($_.BaseName)") } | Sort-Object Length | Select-Object -First 1
        if (-not $pick) { throw 'no sample conversation found' }
        $id = $pick.BaseName
        New-Item -ItemType Directory -Force (Join-Path $data 'conversations'), (Join-Path $tmp 'backup\conversations'), $ud | Out-Null
        $snap = Copy-SqliteSnapshot $pick.FullName   # a consistent copy; the real db is only read
        Copy-Item -LiteralPath $snap -Destination (Join-Path $data "conversations\$id.db"); Remove-Item (Split-Path $snap) -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $real "brain\$id") -Destination (Join-Path $data "brain\$id") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $data "conversations\$id.db") -Destination (Join-Path $tmp "backup\conversations\$id.db")
        Copy-Item -LiteralPath (Join-Path $data "brain\$id") -Destination (Join-Path $tmp "backup\brain-$id") -Recurse -Force
        [pscustomobject]@{ id = $id } | ConvertTo-Json | Set-Content -LiteralPath $state
        "prepared: conversation $(Short $id), db $([int]((Get-Item (Join-Path $data "conversations\$id.db")).Length/1KB)) KB, brain $(@(Get-ChildItem (Join-Path $data "brain\$id") -Recurse -File -Force).Count) files; no summaries db yet (the app builds it)"
    }
    'Launch' {
        if (Test-Running) { 'the spike instance is already running'; return }
        $exe = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'
        $old = @{ U = $env:USERPROFILE; H = $env:HOME }
        try { $env:USERPROFILE = $fakeHome; $env:HOME = $fakeHome; $p = Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$ud`"" -PassThru } finally { $env:USERPROFILE = $old.U; $env:HOME = $old.H }
        "launched the spike instance (pid $($p.Id)); close ONLY that window when done"
    }
    'Inspect' {
        $id = (Get-State).id
        "conversation $(Short $id): db present=$(Test-Path (Join-Path $data "conversations\$id.db")) -wal=$(Test-Path (Join-Path $data "conversations\$id.db-wal")) -shm=$(Test-Path (Join-Path $data "conversations\$id.db-shm")) brain folder present=$(Test-Path (Join-Path $data "brain\$id"))"
        $files = @(Get-ChildItem (Join-Path $data 'conversations') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name -replace [regex]::Escape($id), '<id>' })
        "files in conversations\: $($files -join ', ')"
        $sum = Join-Path $data 'conversation_summaries.db'
        if (-not (Test-Path -LiteralPath $sum)) { 'conversation_summaries.db: not created yet'; return }
        $s = Copy-SqliteSnapshot $sum
        try {
            $h = Open-SqliteReadOnly $s
            try {
                $r = @(Invoke-SqliteQuery $h "select conversation_id, status, step_count, killed, last_modified_time from conversation_summaries")
                $mine = @($r | Where-Object conversation_id -eq $id)
                "summaries db: $($r.Count) row(s) in total; row for the test conversation: $($mine.Count -gt 0)$(if ($mine.Count) { " (status=$($mine[0].status) step_count=$($mine[0].step_count) killed=$($mine[0].killed))" })"
                "fts rows: $((@(Invoke-SqliteQuery $h 'select count(*) as n from conversations_fts_docsize'))[0].n)"
            } finally { Close-Sqlite $h }
        } finally { Remove-Item (Split-Path $s) -Recurse -Force -ErrorAction SilentlyContinue }
    }
    'Remove' {
        if (Test-Running) { throw 'close the spike instance first' }
        $id = (Get-State).id
        foreach ($sfx in '', '-wal', '-shm') { Remove-Item -LiteralPath (Join-Path $data "conversations\$id.db$sfx") -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath (Join-Path $data "brain\$id") -Recurse -Force -ErrorAction SilentlyContinue
        "removed db/-wal/-shm and brain of $(Short $id) from the spike data dir (summaries db untouched)"
    }
    'Restore' {
        if (Test-Running) { throw 'close the spike instance first' }
        $id = (Get-State).id
        Copy-Item -LiteralPath (Join-Path $tmp "backup\conversations\$id.db") -Destination (Join-Path $data "conversations\$id.db") -Force
        Copy-Item -LiteralPath (Join-Path $tmp "backup\brain-$id") -Destination (Join-Path $data "brain\$id") -Recurse -Force
        "restored db and brain of $(Short $id) from the backup"
    }
    'RemoveRow' {
        if (Test-Running) { throw 'close the spike instance first' }
        $id = (Get-State).id
        Invoke-Rw (Join-Path $data 'conversation_summaries.db') "delete from conversation_summaries where conversation_id='$id'"
        "deleted the summaries row of $(Short $id) from the spike summaries db"
    }
    'RemoveOtherStores' {
        if (Test-Running) { throw 'close the spike instance first' }
        $id = (Get-State).id
        foreach ($store in 'antigravity-ide', 'antigravity-backup') {
            $dir = Join-Path $fakeHome ".gemini\$store"
            if ($dir -notlike "*$name*") { throw 'not a spike path' }
            foreach ($sfx in '', '-wal', '-shm') { Remove-Item -LiteralPath (Join-Path $dir "conversations\$id.db$sfx") -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath (Join-Path $dir "brain\$id") -Recurse -Force -ErrorAction SilentlyContinue
        }
        "removed the test conversation from the app-made copies in the spike home"
    }
    'RemoveHubCache' {
        if (Test-Running) { throw 'close the spike instance first' }
        $pb = Join-Path $data 'agyhub_summaries_proto.pb'
        if ($pb -notlike "*$name*") { throw 'not a spike path' }
        Remove-Item -LiteralPath $pb -Force -ErrorAction SilentlyContinue
        "agyhub_summaries_proto.pb removed from the spike data dir: $(-not (Test-Path -LiteralPath $pb))"
    }
    'Cleanup' {
        if (Test-Running) { throw 'close the spike instance first' }
        foreach ($p in $gem, $ud, $tmp) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        "cleanup: spike dirs gone = $(-not ((Test-Path $gem) -or (Test-Path $ud) -or (Test-Path $tmp)))"
    }
}
