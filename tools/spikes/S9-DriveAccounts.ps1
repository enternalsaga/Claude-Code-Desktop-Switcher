# S9 - Is the Google Drive for desktop account token the same on two machines for the same account?
# Reads HKCU:\Software\Google\DriveFS (read-only) and prints, per account: a short SHA-256 hash of the token (so two machines can be compared
# without exposing the token), the mount letter, the volume label with the e-mail masked (first 3 characters kept), and what the root
# of the mounted drive looks like. Nothing is written. Run it on BOTH machines and compare the "tokenHash" column.
$ErrorActionPreference = 'Stop'
function Get-ShortHash([string]$Text) {
    $b = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    return (([BitConverter]::ToString($b) -replace '-', '').Substring(0, 12).ToLower())
}
function Hide-Text([string]$Text) { if (-not $Text) { return '' }; return $Text.Substring(0, [Math]::Min(3, $Text.Length)) + '***' }

$key = 'HKCU:\Software\Google\DriveFS'
if (-not (Test-Path $key)) { 'DriveFS registry key not found: Google Drive for desktop is not installed for this user.'; return }
$p = Get-ItemProperty $key
$current = if ($p.PSObject.Properties['CurrentAccountToken']) { [string]$p.CurrentAccountToken } else { '' }
$prefs = $null
try { $prefs = ($p.PerAccountPreferences | ConvertFrom-Json).per_account_preferences } catch { }
if (-not $prefs) { 'PerAccountPreferences missing or unreadable.'; return }

$rows = foreach ($a in @($prefs)) {
    $mp = [string]$a.value.mount_point_path
    $root = $null; $label = ''
    if ($mp) {
        $letter = $mp.Substring(0, 1)
        try { $di = New-Object IO.DriveInfo $letter; if ($di.IsReady) { $root = $di.RootDirectory.FullName; $label = $di.VolumeLabel } } catch { }
    }
    $folders = @(); if ($root) { $folders = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    $myDrive = @($folders | Where-Object { $_ -in 'My Drive', 'Drive của tôi' -or $_ -like 'My Drive*' }) | Select-Object -First 1
    [pscustomobject]@{
        tokenHash     = Get-ShortHash ([string]$a.key)
        tokenLength   = ([string]$a.key).Length
        isCurrent     = ([string]$a.key -eq $current)
        mount         = $mp
        volumeLabel   = (Hide-Text $label)
        labelIsEmail  = ($label -match '@')
        rootFolders   = (($folders | ForEach-Object { if ($_ -in 'My Drive', 'Drive của tôi', '.shortcut-targets-by-id', 'Other computers', 'Shared drives', '.Encrypted') { $_ } else { '<other>' } }) -join '; ')
        myDriveFolder = $myDrive
        machineRootHash = Get-ShortHash ([string]$a.value.machine_root_doc_id)
    }
}
'Computer name hash: ' + (Get-ShortHash $env:COMPUTERNAME)
$rows | Format-List
'Send the lines above back as they are (no e-mail or token is shown). Compare tokenHash between the two machines for the same account.'
