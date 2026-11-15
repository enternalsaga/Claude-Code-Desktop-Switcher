# Storage.Guard.ps1 - what may be touched and what may go to the Recycle Bin (phase 6, lane A1). Pure decisions: every
# look at the machine (a locked file, the volume and its bin) goes through a parameter, so tests never ask the real one.
# Needs nothing else. ASCII only.

# Is this file held open by someone without sharing? Used as the default -LockProbe. A file that is not there is not locked;
# a file we may not open is treated as locked, because then we cannot tell.
function Test-StorageFileLocked {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    try { $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None); $fs.Dispose(); return $false }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch { return $true }
}

# Decides whether a session may be changed now. State is live (a file is locked, or a Claude CLI runs in the session's
# folder), protected (the app of a profile that refers to it is running: Claude and Antigravity; Codex is changed through
# its app-server, so it is never protected), recent (activity or any file newer than -RecentMinutes) or idle. Only idle
# is safe; -IncludeRecent lets a recent one through, never a live or protected one. -Running is
# @{ claude = @(profile ids); antigravity = @(...); codex = @(...) }; -CliCwds the folders of running Claude CLIs.
function Test-StorageSessionSafe {
    param(
        [Parameter(Mandatory)]$Session, [int]$RecentMinutes = 30, $Running = @{}, [string[]]$CliCwds = @(),
        [scriptblock]$LockProbe = { param($p) Test-StorageFileLocked -Path $p }, [switch]$IncludeRecent, [datetime]$Now = [DateTime]::UtcNow
    )
    $out = { param($safe, $state, $reason) @{ Safe = $safe; State = $state; Reason = $reason } }
    if ($Session.Flags.DbUnreadable) { return (& $out $false $Session.State 'The database of this profile could not be read, so what belongs to this session is not known.') }
    foreach ($p in @($Session.Parts | Where-Object { $_.Kind -eq 'file' })) {
        if (& $LockProbe ([string]$p.Path)) { return (& $out $false 'live' 'A file of this session is open in another program.') }
    }
    $cwd = ([string]$Session.Cwd).TrimEnd('\')
    if ($Session.Harness -eq 'claude' -and $cwd -and @($CliCwds | Where-Object { $_.TrimEnd('\') -ieq $cwd }).Count) {
        return (& $out $false 'live' 'A Claude CLI is running in the folder of this session.')
    }
    $running = @($Running[[string]$Session.Harness])
    if ($Session.Harness -ne 'codex') {
        $hit = @($Session.Profiles | Where-Object { $running -contains $_.Id } | ForEach-Object { $_.Name })
        if ($hit.Count) { return (& $out $false 'protected' ('Close ' + ($hit -join ', ') + ' first: its app is running.')) }
    }
    $newest = [long]0
    foreach ($p in $Session.Parts) { if ($p.MTimeTicks -gt $newest) { $newest = $p.MTimeTicks } }
    $window = [long]$RecentMinutes * [TimeSpan]::TicksPerMinute
    $recent = ($newest -gt 0 -and ($Now.Ticks - $newest) -lt $window)
    if (-not $recent -and $Session.LastActivity) { $ms = ([DateTimeOffset]$Now).ToUnixTimeMilliseconds(); $recent = (($ms - [long]$Session.LastActivity) -lt ([long]$RecentMinutes * 60000) -and [long]$Session.LastActivity -le $ms + 60000) }
    if ($recent) {
        if ($IncludeRecent) { return (& $out $true 'recent' 'Included anyway although it was used in the last minutes.') }
        return (& $out $false 'recent' "Used in the last $RecentMinutes minutes.")
    }
    return (& $out $true 'idle' '')
}

# True only for a full path with no .. segment that lies below one of the roots (not the root itself). Used before anything
# is written or deleted from a path that came out of a manifest or a scan.
function Test-StoragePathAllowed {
    param([string]$Path, [string[]]$Roots = @())
    if (-not $Path -or $Path.Contains("`0") -or $Path -notmatch '\A(?:[A-Za-z]:\\|\\\\)') { return $false }
    if (@($Path -split '[\\/]' | Where-Object { $_ -eq '..' }).Count) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($r in $Roots) {
        if (-not $r) { continue }
        $base = [IO.Path]::GetFullPath($r).TrimEnd('\') + '\'
        if ($full.Length -gt $base.Length -and $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ---- the Recycle Bin ---------------------------------------------------------------------------------------------------

# What Windows says about the volume of a path: DriveType, IsDriveFs (a Google Drive for desktop drive), and the bin's
# NukeOnDelete and MaxCapacityMB from HKCU\...\Explorer\BitBucket\Volume (spike S18). Anything unknown is $null.
# Read-only. Tests replace it through -VolumeInfo of Test-StorageRecyclable.
function Get-StorageVolumeInfo {
    param([Parameter(Mandatory)][string]$Path)
    $info = @{ DriveType = $null; IsDriveFs = $false; NukeOnDelete = $null; MaxCapacityMB = $null }
    $rootPath = [IO.Path]::GetPathRoot($Path)
    try { $info.DriveType = [string](New-Object IO.DriveInfo $rootPath).DriveType } catch { return $info }
    try {
        if (Get-Command Get-DriveFsAccounts -ErrorAction SilentlyContinue) {
            foreach ($a in @(Get-DriveFsAccounts)) { if ($a.MyDrive -and ([IO.Path]::GetPathRoot([string]$a.MyDrive) -ieq $rootPath)) { $info.IsDriveFs = $true } }
        }
    } catch { }
    try {
        if (-not ('StorageVolumeName' -as [type])) {
            Add-Type -TypeDefinition 'using System.Text; using System.Runtime.InteropServices; public static class StorageVolumeName { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetVolumeNameForVolumeMountPointW(string mp, StringBuilder name, uint len); public static string Get(string mp) { var sb = new StringBuilder(64); return GetVolumeNameForVolumeMountPointW(mp, sb, 64) ? sb.ToString() : null; } }'
        }
        $vn = [StorageVolumeName]::Get($rootPath)
        if ($vn -match '\{([0-9A-Fa-f-]{36})\}') {
            $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume'
            $key = Get-ChildItem -LiteralPath $base -ErrorAction Stop | Where-Object { $_.PSChildName.Trim('{}') -ieq $Matches[1] } | Select-Object -First 1
            if ($key) {
                $p = Get-ItemProperty -LiteralPath $key.PSPath
                if ($p.PSObject.Properties['NukeOnDelete']) { $info.NukeOnDelete = [int]$p.NukeOnDelete }
                if ($p.PSObject.Properties['MaxCapacity']) { $info.MaxCapacityMB = [long]$p.MaxCapacity }
            }
        }
    } catch { }
    return $info
}

# Will every file of the session go to the Recycle Bin, or would Windows delete some for good (spike S18)? Ok only when, for
# every volume the session's files are on: the drive is Fixed, is not a Google Drive drive, the bin has NukeOnDelete = 0
# and a MaxCapacity, and the session's files on that volume add up to less than MaxCapacity (Windows judges one deletion at
# a time). Whatever is unknown, or a probe that throws, counts as no. -VolumeInfo is called with a path on the volume.
function Test-StorageRecyclable {
    param([Parameter(Mandatory)]$Session, [scriptblock]$VolumeInfo = { param($p) Get-StorageVolumeInfo -Path $p })
    $no = { param($why) @{ Ok = $false; Reason = "cannot go to the Recycle Bin, archive it instead ($why)." } }
    $by = @{}
    foreach ($p in @($Session.Parts | Where-Object { $_.Kind -ne 'row' })) {
        $v = ([IO.Path]::GetPathRoot([string]$p.Path)).ToUpperInvariant()
        if (-not $by.ContainsKey($v)) { $by[$v] = @{ Bytes = [long]0; Sample = [string]$p.Path } }
        $by[$v].Bytes += [long]$p.Bytes
    }
    foreach ($v in $by.Keys) {
        $i = $null
        try { $i = & $VolumeInfo $by[$v].Sample } catch { return (& $no 'the drive could not be checked') }
        if (-not $i) { return (& $no 'the drive could not be checked') }
        if ($i.DriveType -ne 'Fixed') { return (& $no "$v is not a fixed drive") }
        if ($i.IsDriveFs) { return (& $no "$v is a Google Drive drive") }
        if ($null -eq $i.NukeOnDelete -or [int]$i.NukeOnDelete -ne 0) { return (& $no "the Recycle Bin of $v is not set to keep deleted files") }
        if ($null -eq $i.MaxCapacityMB) { return (& $no "the size of the Recycle Bin of $v is not known") }
        if ($by[$v].Bytes -ge ([long]$i.MaxCapacityMB * 1MB)) { return (& $no "the session is larger than the Recycle Bin of $v") }
    }
    return @{ Ok = $true; Reason = '' }
}
