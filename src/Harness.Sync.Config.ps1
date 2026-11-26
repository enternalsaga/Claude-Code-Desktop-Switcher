# Harness.Sync.Config.ps1 - finds the Google Drive folder and keeps the Sync.* settings (phase 4, lane D).
# Reads the registry only; nothing here writes to Drive. Uses Get-Setting and Set-Setting from ClaudeSwitcher.ps1.
# Tests replace the registry and the volume label through $script:SyncHooks (ReadRegistry, VolumeLabel). ASCII only.

# The two names of "My Drive" we know; anything else is found by the fallback in Find-DriveFsMyDrive.
function Get-DriveFsMyDriveNames {
    return @('My Drive', ('Drive c' + [char]0x1EE7 + 'a t' + [char]0x00F4 + 'i'))
}

function Get-SyncHook {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:SyncHooks -and $script:SyncHooks[$Name] -is [scriptblock]) { return $script:SyncHooks[$Name] }
    return $null
}

# The raw JSON of HKCU:\Software\Google\DriveFS\PerAccountPreferences, or $null.
function Read-DriveFsPreferences {
    $hook = Get-SyncHook 'ReadRegistry'
    if ($hook) { return (& $hook) }
    try { return (Get-ItemProperty -LiteralPath 'HKCU:\Software\Google\DriveFS' -Name 'PerAccountPreferences' -ErrorAction Stop).PerAccountPreferences } catch { return $null }
}

function Get-DriveVolumeLabel {
    param([Parameter(Mandatory)][string]$Mount)
    $hook = Get-SyncHook 'VolumeLabel'
    if ($hook) { return [string](& $hook $Mount) }
    try { return [string]([IO.DriveInfo]::new($Mount.Substring(0, 1)).VolumeLabel) } catch { return '' }
}

# The user's own folder inside a Drive mount: a folder with a known name, else (when the mount holds
# .shortcut-targets-by-id, which only a Drive mount does) the first folder that is not Other computers or Shared drives.
function Find-DriveFsMyDrive {
    param([Parameter(Mandatory)][string]$MountPoint)
    if (-not (Test-Path -LiteralPath $MountPoint -PathType Container)) { return $null }
    foreach ($name in (Get-DriveFsMyDriveNames)) {
        $p = Join-Path $MountPoint $name
        if (Test-Path -LiteralPath $p -PathType Container) { return $p }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $MountPoint '.shortcut-targets-by-id') -PathType Container)) { return $null }
    $skip = @('Other computers', 'Shared drives', 'Computers')
    $hit = @(Get-ChildItem -LiteralPath $MountPoint -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\A[.$]' -and $_.Name -notin $skip } | Sort-Object Name) | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

# One entry per signed-in Drive account: @{ Token; MountPoint; Label; MyDrive } (MyDrive is $null when not mounted).
# Label is the volume label, which Drive sets to the account's address: show it to the user, never store it.
function Get-DriveFsAccounts {
    $raw = Read-DriveFsPreferences
    if (-not $raw) { return @() }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json } catch { return @() }
    $list = New-Object Collections.Generic.List[object]
    $entries = @($doc.per_account_preferences | Where-Object { $_ -is [pscustomobject] -and $_.key })
    $unmounted = @($entries | Where-Object { -not ($_.value -and $_.value.mount_point_path) })
    $claimed = @{}
    foreach ($e in $entries) {
        $mount = $(if ($e.value) { [string]$e.value.mount_point_path } else { '' })
        if ($mount -match '\A[A-Za-z]\z') { $mount = $mount.ToUpperInvariant() + ':\' }
        if ($mount) { $claimed[$mount.ToUpperInvariant()] = $true }
        Add-Member -InputObject $e -NotePropertyName MountPoint -NotePropertyValue $mount -Force
    }
    # Drive writes no mount_point_path for an account on its default letter. Only when exactly one account lacks it and
    # exactly one Drive volume is not taken by another account do the two surely belong together.
    if ($unmounted.Count -eq 1) {
        $free = @(Get-DriveFsVolumes | Where-Object { -not $claimed.ContainsKey(([string]$_).ToUpperInvariant()) })
        if ($free.Count -eq 1) { $unmounted[0].MountPoint = [string]$free[0] }
    }
    foreach ($e in $entries) {
        if (-not $e.MountPoint) { continue }
        $list.Add([pscustomobject]@{
            Token = [string]$e.key; MountPoint = $e.MountPoint
            Label = (Get-DriveVolumeLabel -Mount $e.MountPoint); MyDrive = (Find-DriveFsMyDrive -MountPoint $e.MountPoint)
        })
    }
    return $list.ToArray()
}

# Root paths (X:\) of the local volumes that Drive mounted: fixed drives holding .shortcut-targets-by-id. Network drives
# are skipped so a dead share cannot stall the read.
function Get-DriveFsVolumes {
    $hook = Get-SyncHook 'DriveVolumes'
    if ($hook) { return @(& $hook) }
    $roots = foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try { if ($d.DriveType -eq 'Fixed' -and $d.IsReady -and (Test-Path -LiteralPath (Join-Path $d.Name '.shortcut-targets-by-id') -PathType Container)) { $d.Name } } catch { }
    }
    return @($roots)
}

# ---- settings (keys Sync.*) --------------------------------------------------------------------------------------------

function Get-SyncSetting {
    param([Parameter(Mandatory)][string]$Name)
    return (Get-Setting "Sync.$Name")
}

function Test-SyncFolderName {
    param([string]$Name)
    return ($Name -match '\A[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}\z' -and -not $Name.Contains('..'))
}

function Set-SyncSetting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    if ($Name -notmatch '\A[A-Za-z0-9]+\z') { throw "Bad sync setting name: $Name" }
    if ($Name -eq 'Folder' -and $null -ne $Value -and -not (Test-SyncFolderName ([string]$Value))) { throw 'Sync.Folder must be one plain folder name.' }
    Set-Setting "Sync.$Name" $Value
}

# A full path on a drive letter or a UNC share: no '..' segment, no control or reserved characters, no ':' past the drive.
function Test-SyncAbsolutePath {
    param([string]$Path)
    if (-not $Path -or $Path -match '[\x00-\x1f<>|"*?]') { return $false }
    if ($Path -notmatch '\A(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\])') { return $false }
    $rest = $(if ($Path.StartsWith('\\')) { $Path.Substring(2) } else { $Path.Substring(3) })
    if ($rest.Contains(':')) { return $false }
    foreach ($seg in ($rest -split '\\')) { if ($seg -eq '..') { return $false } }
    return $true
}

# Where the sync folder is on this machine. Path is $null when it cannot be found (Reason says why); a Drive
# folder that is mounted but not created yet still gets a Path, because the first machine creates it.
function Resolve-SyncRoot {
    $custom = [string](Get-SyncSetting 'CustomPath')
    if ($custom) {
        if ((Test-SyncAbsolutePath $custom) -and (Test-Path -LiteralPath $custom -PathType Container)) { return [pscustomobject]@{ Path = $custom; Source = 'custom'; Reason = $null } }
        return [pscustomobject]@{ Path = $null; Source = 'custom'; Reason = 'custom-missing' }
    }
    $token = [string](Get-SyncSetting 'DriveAccountToken')
    $folder = [string](Get-SyncSetting 'Folder')
    if (-not $folder) { $folder = 'HarnessSync' }
    if (-not $token -or -not (Test-SyncFolderName $folder)) { return [pscustomobject]@{ Path = $null; Source = $null; Reason = 'no-settings' } }
    $acc = @(Get-DriveFsAccounts | Where-Object { $_.Token -eq $token }) | Select-Object -First 1
    if (-not $acc -or -not $acc.MyDrive) { return [pscustomobject]@{ Path = $null; Source = 'drive'; Reason = 'token-not-mounted' } }
    return [pscustomobject]@{ Path = (Join-Path $acc.MyDrive $folder); Source = 'drive'; Reason = $null }
}

# The id of this machine: a GUID made once and kept in the settings.
function Get-SyncMachine {
    $id = [string](Get-SyncSetting 'MachineId')
    if ($id -notmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') {
        $id = [guid]::NewGuid().ToString()
        Set-SyncSetting 'MachineId' $id
    }
    return [pscustomobject]@{ Id = $id; Name = $env:COMPUTERNAME }
}

# Named folders that differ per machine ("Proj" is D:\Work on one, E:\Code on another), for cwd mapping.
function Get-SyncPathRoots {
    $map = @{}
    $stored = Get-SyncSetting 'PathRoots'
    if ($stored -is [pscustomobject]) {
        foreach ($p in $stored.PSObject.Properties) {
            if ($p.Name -match '\A[A-Za-z0-9_-]+\z' -and (Test-SyncAbsolutePath ([string]$p.Value))) { $map[$p.Name] = [string]$p.Value }
        }
    }
    return $map
}

function Set-SyncPathRoot {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ($Name -notmatch '\A[A-Za-z0-9_-]+\z') { throw "Bad path root name: $Name" }
    if (-not (Test-SyncAbsolutePath $Path)) { throw "The path root must be a full path (D:\folder or \\server\share): $Path" }
    $clean = $(if ($Path.Length -gt 3) { $Path.TrimEnd('\') } else { $Path })
    $roots = Get-SyncPathRoots
    $roots[$Name] = $clean
    Set-SyncSetting 'PathRoots' $roots
}
