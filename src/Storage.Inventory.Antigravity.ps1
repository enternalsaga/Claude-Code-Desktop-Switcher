# Storage.Inventory.Antigravity.ps1 - the Antigravity part of the inventory, split from Storage.Inventory.ps1 (file size limit; no change of behavior).
# ASCII only. Needs Storage.Inventory.ps1 (the session builders) and Harness.Sqlite.ps1; Get-StorageInventory calls Get-AgyStorageSessions.


function Read-StorageAgyRows {
    param([Parameter(Mandatory)][string]$Path)
    $snap = $null
    try {
        $snap = Copy-SqliteSnapshot -Path $Path
        $h = Open-SqliteReadOnly -Path $snap
        try { $rows = @(Invoke-SqliteQuery -Handle $h -Sql 'select conversation_id, title, preview, last_modified_time, workspace_uris from conversation_summaries') } finally { Close-Sqlite -Handle $h }
        return @($rows | ForEach-Object { @{ id = [string]$_.conversation_id; title = $_.title; preview = $_.preview; modified = $_.last_modified_time; uris = $_.workspace_uris } })
    } finally {
        if ($snap -and [IO.Directory]::Exists((Split-Path -Parent $snap))) { Remove-Item -LiteralPath (Split-Path -Parent $snap) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# The first file:/// workspace of a summaries row as a Windows path.
function ConvertFrom-StorageWorkspace {
    param($Uris)
    if (-not $Uris -or ([string]$Uris) -notmatch 'file:///([^\s",\]]+)') { return $null }
    return ([uri]::UnescapeDataString($Matches[1])).Replace('/', '\')
}

# One session per conversation file (.db or .pb, with its -wal and -shm), plus its brain folder and its summaries row.
function Get-AgyStorageSessions {
    param([array]$Dirs = @(), $Cache, $Cancel, $Progress, $Warnings, [int]$ItemDelayMs = 0, [datetime]$Now = [DateTime]::UtcNow, [int]$RecentMinutes = 30)
    $roles = @{ '' = 'conversation-db'; '-wal' = 'conversation-wal'; '-shm' = 'conversation-shm' }
    foreach ($d in $Dirs) {
        $data = [string]$d.DataDir
        $convDir = Join-Path $data 'conversations'
        if (-not $data -or -not [IO.Directory]::Exists($convDir)) { continue }
        $byId = @{}
        foreach ($f in @(Get-StorageEntries -Dir $convDir | Where-Object { $_ -is [IO.FileInfo] })) {
            if ($f.Name -notmatch '\A(.+?)\.(db|pb)(-wal|-shm)?\z') { continue }
            if (-not $byId.ContainsKey($Matches[1])) { $byId[$Matches[1]] = New-Object Collections.Generic.List[object] }
            $role = $(if ($Matches[2] -eq 'pb') { 'conversation-pb' } else { $roles[[string]$Matches[3]] })
            $byId[$Matches[1]].Add(@{ File = $f; Role = $role })
        }
        $sumDb = Join-Path $data 'conversation_summaries.db'
        $rows = @(); $unreadable = $false
        if ([IO.File]::Exists($sumDb)) {
            $sig = Get-StorageDbSignature -Path $sumDb
            try { $rows = @(Get-StorageCachedMeta -Cache $Cache -Key $sumDb -Size $sig.Size -Ticks $sig.Ticks -Reader { param($k) Read-StorageAgyRows -Path $k }) }
            catch { $unreadable = $true; if ($null -ne $Warnings) { $Warnings.Add("Antigravity summaries of '$($d.Name)' could not be read: $($_.Exception.Message)") } }
        }
        $row = @{}; foreach ($r in $rows) { $row[[string]$r['id']] = $r }
        Set-StorageProgress -Progress $Progress -Phase 'antigravity' -Total $byId.Count
        foreach ($id in $byId.Keys) {
            if (Test-StorageCancel $Cancel) { return }
            if ($ItemDelayMs) { Start-Sleep -Milliseconds $ItemDelayMs }
            $b = New-StorageSessionBuilder -Harness 'antigravity' -Id $id -Tag ([string]$d.Id)
            if ($unreadable) { $b.Flags['DbUnreadable'] = $true }
            $b.Profiles[[string]$d.Id] = [string]$d.Name
            foreach ($p in $byId[$id]) { Add-StoragePart -List $b.Parts -Role $p.Role -Path $p.File.FullName -Bytes $p.File.Length -Ticks $p.File.LastWriteTimeUtc.Ticks }
            $brain = Join-Path (Join-Path $data 'brain') $id
            if ([IO.Directory]::Exists($brain)) { $m = Measure-StorageDir -Path $brain -Cancel $Cancel; Add-StoragePart -List $b.Parts -Role 'brain' -Path $brain -Bytes $m.Bytes -Kind 'dir' -Files $m.Files -Ticks $m.NewestTicks }
            if ($row.ContainsKey($id)) {
                $r = $row[$id]
                Add-StoragePart -List $b.Parts -Role 'summary-row' -Path $sumDb -Kind 'row' -Files 0
                $b.AltTitle = $(if ($r['title']) { [string]$r['title'] } elseif ($r['preview']) { [string]$r['preview'] } else { $null })
                $b.Cwd = ConvertFrom-StorageWorkspace $r['uris']
                $ms = ConvertTo-StorageMs $r['modified']; if ($ms) { $b.Activity = $ms }
            }
            Set-StorageActivityFromParts -Builder $b
            ConvertTo-StorageSession -Builder $b -Now $Now -RecentMinutes $RecentMinutes
            Set-StorageProgress -Progress $Progress -Done 1
        }
    }
}
