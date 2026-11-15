# Storage.Harness.ps1 - what removing a session means for each harness, and the Recycle Bin (phase 6, lane A1).
# Needs Storage.Guard.ps1 (Test-StoragePathAllowed, Test-StorageRecyclable). Nothing here touches Codex's database: Codex is
# changed only through its app-server, reached through the -CodexRpc scriptblock { param($CodexHome, $Method, $Params) }
# (tests pass a fake). ASCII only.

# Sends one path (file or folder) to the Recycle Bin. Windows only; the default -Recycler of Invoke-StorageRecycle.
function Send-StoragePathToRecycleBin {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs; $opt = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    if ([IO.Directory]::Exists($Path)) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $ui, $opt) }
    elseif ([IO.File]::Exists($Path)) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $ui, $opt) }
}

# Recycles paths, but only after Test-StorageRecyclable said every one will really land in the bin (spike S18). Refuses
# the whole call otherwise: nothing is removed. -Session carries the parts the check is based on.
function Invoke-StorageRecycle {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string[]]$Paths, [scriptblock]$Recycler = { param($p) Send-StoragePathToRecycleBin -Path $p },
          [scriptblock]$VolumeInfo)
    if ($Session.Flags.DbUnreadable) { throw 'recycle-refused: the database of this profile could not be read, so what belongs to this session is not known.' }
    $args2 = @{ Session = $Session }; if ($VolumeInfo) { $args2['VolumeInfo'] = $VolumeInfo }
    $ok = Test-StorageRecyclable @args2
    if (-not $ok.Ok) { throw ('recycle-refused: ' + $ok.Reason) }
    foreach ($p in $Paths) { if (-not (Test-Path -LiteralPath $p)) { throw "recycle-missing: $p" } }   # before anything moves: a path that is not there is not a success
    foreach ($p in $Paths) { & $Recycler $p }
    return @($Paths)
}

function Get-StorageCodexHomeOf {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Roots)
    $pid2 = $(if (@($Session.Profiles).Count) { [string]@($Session.Profiles)[0].Id } else { '' })
    $h = @($Roots.CodexHomes | Where-Object { [string]$_.Id -ieq $pid2 })
    if (-not $h.Count) { throw "codex-home-unknown: no CODEX_HOME is known for profile '$pid2'." }
    return [string]$h[0].Home
}

function Remove-StorageClaudePaths {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Roots, [Parameter(Mandatory)][string]$Mode, [scriptblock]$Recycler, [scriptblock]$VolumeInfo)
    $allowed = @($Roots.ClaudeProjects) + @($Roots.ClaudeProfiles | ForEach-Object { $_.SessionRoot })
    $paths = New-Object Collections.Generic.List[string]
    foreach ($p in @($Session.Parts | Where-Object { $_.Kind -ne 'row' })) {
        if (-not (Test-StoragePathAllowed -Path ([string]$p.Path) -Roots $allowed)) { throw "remove-refused: $($p.Path) is not inside a known Claude folder." }
        $paths.Add([string]$p.Path)
    }
    $done = New-Object Collections.Generic.List[string]
    if ($Mode -eq 'Recycle') {
        $ra = @{ Session = $Session; Paths = $paths.ToArray() }; if ($Recycler) { $ra['Recycler'] = $Recycler }; if ($VolumeInfo) { $ra['VolumeInfo'] = $VolumeInfo }
        foreach ($d in (Invoke-StorageRecycle @ra)) { $done.Add($d) }
    } else {
        foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }; $done.Add($p) }
    }
    return @{ Removed = $done.ToArray(); Skipped = @() }
}

# Codex. Through the app-server: a permanent removal (after a verified archive) is thread/delete, which removes the row and
# the rollout together; Recycle is thread/archive (the rollout moves to archived_sessions) and then that file goes to the bin.
# Three cases skip part of that: a thread that is already archived is not archived again; a rollout with no row (NoRow) cannot
# be reached by the app-server, so its file is removed directly (only inside CODEX_HOME); a row with no file (NoFile) has
# nothing to send to the bin, and Delete still calls thread/delete.
function Remove-StorageCodexSession {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Roots, [Parameter(Mandatory)][string]$Mode, [scriptblock]$CodexRpc, [scriptblock]$Recycler, [scriptblock]$VolumeInfo)
    $home2 = Get-StorageCodexHomeOf -Session $Session -Roots $Roots
    $rollout = @($Session.Parts | Where-Object { $_.Role -eq 'rollout' })[0]
    $noRow = [bool]$Session.Flags.NoRow; $archivedAlready = [bool]$Session.Flags.CodexArchived
    if ($rollout -and ($noRow -or $Mode -eq 'Recycle') -and -not (Test-StoragePathAllowed -Path ([string]$rollout.Path) -Roots @($home2))) { throw "remove-refused: $($rollout.Path) is not inside CODEX_HOME." }
    if ($Mode -ne 'Recycle') {
        if ($noRow) {
            if ($rollout -and (Test-Path -LiteralPath ([string]$rollout.Path))) { Remove-Item -LiteralPath ([string]$rollout.Path) -Force }
            return @{ Removed = @($(if ($rollout) { [string]$rollout.Path })); Skipped = @() }
        }
        if (-not $CodexRpc) { throw 'codex-rpc-missing: Codex sessions are changed through the Codex app-server only.' }
        [void](& $CodexRpc $home2 'thread/delete' @{ threadId = [string]$Session.Id })
        return @{ Removed = @([string]$Session.Id); Skipped = @() }
    }
    if (-not $rollout) { throw 'recycle-refused: nothing to send to the Recycle Bin (this session has no file).' }
    $viaRpc = -not ($noRow -or $archivedAlready)
    if ($viaRpc -and -not $CodexRpc) { throw 'codex-rpc-missing: Codex sessions are changed through the Codex app-server only.' }
    $target = $(if ($viaRpc) { Join-Path (Join-Path $home2 'archived_sessions') (Split-Path -Leaf ([string]$rollout.Path)) } else { [string]$rollout.Path })
    $check = $Session.PSObject.Copy(); $check.Parts = @([pscustomobject]@{ Role = 'rollout'; Path = $target; Bytes = $rollout.Bytes; Kind = 'file' })
    $va = @{ Session = $check }; if ($VolumeInfo) { $va['VolumeInfo'] = $VolumeInfo }
    $ok = Test-StorageRecyclable @va
    if (-not $ok.Ok) { throw ('recycle-refused: ' + $ok.Reason) }   # asked before anything moves
    if ($viaRpc) { [void](& $CodexRpc $home2 'thread/archive' @{ threadId = [string]$Session.Id }) }
    $ra = @{ Session = $check; Paths = @($target) }; if ($Recycler) { $ra['Recycler'] = $Recycler }; if ($VolumeInfo) { $ra['VolumeInfo'] = $VolumeInfo }
    [void](Invoke-StorageRecycle @ra)
    return @{ Removed = @($target); Skipped = @() }
}

# Removes what a session is made of. Mode Delete = for good (used after a verified archive); Recycle = Recycle Bin, refused as a
# whole when Windows would delete for good. Antigravity is not handled yet (spike S17). Returns @{ Removed; Skipped }.
function Remove-StorageSessionOriginal {
    param([Parameter(Mandatory)]$Session, [ValidateSet('Delete', 'Recycle')][string]$Mode = 'Delete', [Parameter(Mandatory)]$Roots,
          [scriptblock]$CodexRpc, [scriptblock]$Recycler, [scriptblock]$VolumeInfo)
    if ($Session.Flags.DbUnreadable) { throw 'remove-refused: the database of this profile could not be read, so what belongs to this session is not known.' }
    switch ($Session.Harness) {
        'claude' { return (Remove-StorageClaudePaths -Session $Session -Roots $Roots -Mode $Mode -Recycler $Recycler -VolumeInfo $VolumeInfo) }
        'codex' { return (Remove-StorageCodexSession -Session $Session -Roots $Roots -Mode $Mode -CodexRpc $CodexRpc -Recycler $Recycler -VolumeInfo $VolumeInfo) }
        default { throw "remove-unsupported: $($Session.Harness) sessions cannot be removed yet." }
    }
}
