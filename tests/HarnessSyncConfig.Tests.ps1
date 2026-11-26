$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Import-TestFunctions -Files @((Join-Path $root 'ClaudeSwitcher.ps1')) -Names @('Get-Setting', 'Set-Setting'))
. (Join-Path $root 'src\Harness.Sync.Config.ps1')

# Nothing here touches the real registry, settings file or Drive: the registry is a hook, the settings live in a temp
# file, and the "Drive" is a temp folder. Tokens and labels are made up.
$tmp = New-TestTempDir
try {
    $script:ProfileRoot = Join-Path $tmp 'profile'
    $script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'

    # ---------------------------------------------------------------- D1: Drive accounts from the registry
    $viName = 'Drive c' + [char]0x1EE7 + 'a t' + [char]0x00F4 + 'i'    # the Vietnamese name of "My Drive"
    $mountA = Join-Path $tmp 'mountA'; New-Item -ItemType Directory -Path (Join-Path $mountA 'My Drive') -Force | Out-Null
    $mountB = Join-Path $tmp 'mountB'; New-Item -ItemType Directory -Path (Join-Path $mountB $viName) -Force | Out-Null
    $mountC = Join-Path $tmp 'mountC'
    foreach ($d in '.shortcut-targets-by-id', 'Other computers', 'Shared drives', 'Zeta folder', 'Alpha folder') { New-Item -ItemType Directory -Path (Join-Path $mountC $d) -Force | Out-Null }
    $mountD = Join-Path $tmp 'mountD'; New-Item -ItemType Directory -Path $mountD -Force | Out-Null
    function New-FakePrefs($entries) {
        @{ per_account_preferences = @($entries | ForEach-Object { @{ key = $_.Token; value = @{ mount_point_path = $_.Mount; machine_root_doc_id = 'doc' } } }) } | ConvertTo-Json -Depth 6 -Compress
    }
    $script:fakeJson = New-FakePrefs @(
        @{ Token = '100000000000000000001'; Mount = $mountA },
        @{ Token = '100000000000000000002'; Mount = $mountB },
        @{ Token = '100000000000000000003'; Mount = $mountC },
        @{ Token = '100000000000000000004'; Mount = $mountD },
        @{ Token = '100000000000000000005'; Mount = 'Q' })
    $script:SyncHooks = @{
        ReadRegistry = { $script:fakeJson }
        VolumeLabel  = { param($Mount) 'label-of-' + (Split-Path -Leaf $Mount) }
        DriveVolumes = { $script:fakeVolumes }
    }
    $script:fakeVolumes = @()
    $acc = @(Get-DriveFsAccounts)
    Assert ($acc.Count -eq 5) "five accounts, got $($acc.Count)"
    Assert ($acc[0].Token -eq '100000000000000000001' -and $acc[0].MyDrive -eq (Join-Path $mountA 'My Drive')) 'English My Drive found'
    Assert ($acc[0].MountPoint -eq $mountA -and $acc[0].Label -eq 'label-of-mountA') 'mount point and label from the hooks'
    Assert ($acc[1].MyDrive -eq (Join-Path $mountB $viName)) 'Vietnamese My Drive name found'
    Assert ($acc[2].MyDrive -eq (Join-Path $mountC 'Alpha folder')) "fallback: first folder that is not Other computers or Shared drives, got $($acc[2].MyDrive)"
    Assert ($null -eq $acc[3].MyDrive) 'no My Drive and no .shortcut-targets-by-id gives $null'
    Assert ($acc[4].MountPoint -eq 'Q:\' -and $null -eq $acc[4].MyDrive) 'a bare drive letter becomes X:\ and a missing drive gives $null, without an error'

    $script:fakeJson = $null
    Assert (@(Get-DriveFsAccounts).Count -eq 0) 'no registry value gives an empty array'
    $script:fakeJson = 'this is not json'
    Assert (@(Get-DriveFsAccounts).Count -eq 0) 'damaged JSON gives an empty array'
    $script:fakeJson = '{"per_account_preferences":[{"key":"x"},{"value":{"mount_point_path":"Q"}},"junk"]}'
    Assert (@(Get-DriveFsAccounts).Count -eq 0) 'entries without a key or a mount are skipped'

    # an account on Drive's default letter has no mount_point_path (seen on a real machine: {"key":"...","value":{}})
    $script:fakeJson = '{"per_account_preferences":[{"key":"100000000000000000001","value":{}},{"key":"100000000000000000002","value":{"mount_point_path":"' + ($mountB -replace '\\', '\\') + '"}}]}'
    $script:fakeVolumes = @($mountB, $mountA)
    $acc = @(Get-DriveFsAccounts)
    Assert ($acc.Count -eq 2 -and $acc[0].Token -eq '100000000000000000001' -and $acc[0].MountPoint -eq $mountA -and $acc[0].MyDrive -eq (Join-Path $mountA 'My Drive')) "the account without a letter gets the one Drive volume no other account holds: $($acc | ConvertTo-Json -Compress)"
    Assert ($acc[1].MountPoint -eq $mountB) 'the account with a letter keeps it'
    $script:fakeVolumes = @($mountB, $mountA, $mountC)
    Assert (@(Get-DriveFsAccounts).Count -eq 1) 'two free Drive volumes: which one is unknown, so the account is left out'
    $script:fakeVolumes = @($mountA)
    $script:fakeJson = '{"per_account_preferences":[{"key":"100000000000000000001","value":{}},{"key":"100000000000000000002","value":{}}]}'
    Assert (@(Get-DriveFsAccounts).Count -eq 0) 'two accounts without a letter: which one is unknown, so both are left out'
    $script:fakeVolumes = @()
    $script:fakeJson = New-FakePrefs @(@{ Token = '100000000000000000001'; Mount = $mountA })

    # ---------------------------------------------------------------- settings helpers
    Assert ($null -eq (Get-SyncSetting 'DriveAccountToken')) 'unset setting is $null'
    Set-SyncSetting 'DriveAccountToken' '100000000000000000001'
    Assert ((Get-SyncSetting 'DriveAccountToken') -eq '100000000000000000001') 'setting round trip'
    Assert ((Get-Setting 'Sync.DriveAccountToken') -eq '100000000000000000001') 'stored under the Sync.* key'
    Assert-Throws { Set-SyncSetting 'bad name' 'x' } 'only plain names are accepted'
    Assert-Throws { Set-SyncSetting 'Folder' '..\evil' } 'Folder must be a single plain folder name'
    Assert-Throws { Set-SyncSetting 'Folder' 'a\b' } 'Folder may not hold a path separator'
    Set-SyncSetting 'Folder' 'HarnessSync-test'
    Assert ((Get-SyncSetting 'Folder') -eq 'HarnessSync-test') 'a plain folder name is accepted'

    # ---------------------------------------------------------------- D2: Resolve-SyncRoot
    Remove-Item -LiteralPath $script:SettingsPath -Force
    $r = Resolve-SyncRoot
    Assert ($null -eq $r.Path -and $r.Reason -eq 'no-settings') 'nothing set: no-settings'

    $custom = Join-Path $tmp 'custom-root'; New-Item -ItemType Directory -Path $custom | Out-Null
    Set-SyncSetting 'CustomPath' $custom
    $r = Resolve-SyncRoot
    Assert ($r.Path -eq $custom -and $r.Source -eq 'custom' -and -not $r.Reason) 'custom folder that exists'
    Set-SyncSetting 'CustomPath' (Join-Path $tmp 'gone')
    $r = Resolve-SyncRoot
    Assert ($null -eq $r.Path -and $r.Source -eq 'custom' -and $r.Reason -eq 'custom-missing') 'custom folder that is gone'
    Set-SyncSetting 'CustomPath' 'relative\path'
    Assert ((Resolve-SyncRoot).Reason -eq 'custom-missing') 'a relative custom path is not accepted'
    Set-SyncSetting 'CustomPath' $custom
    Set-SyncSetting 'DriveAccountToken' '100000000000000000001'
    Assert ((Resolve-SyncRoot).Source -eq 'custom') 'a custom path wins over the Drive account'

    Set-SyncSetting 'CustomPath' $null
    Set-SyncSetting 'Folder' 'HarnessSync-test'
    $r = Resolve-SyncRoot
    Assert ($r.Source -eq 'drive' -and $r.Path -eq (Join-Path (Join-Path $mountA 'My Drive') 'HarnessSync-test') -and -not $r.Reason) "mounted token: Path is My Drive\Sync.Folder, got $($r.Path)"
    Set-SyncSetting 'Folder' $null
    Assert ((Resolve-SyncRoot).Path -eq (Join-Path (Join-Path $mountA 'My Drive') 'HarnessSync')) 'the default folder is HarnessSync'
    Assert (-not (Test-Path -LiteralPath (Resolve-SyncRoot).Path)) 'resolving never creates the folder'
    Set-SyncSetting 'DriveAccountToken' '999999999999999999999'
    $r = Resolve-SyncRoot
    Assert ($null -eq $r.Path -and $r.Source -eq 'drive' -and $r.Reason -eq 'token-not-mounted') 'a token that is not mounted'
    Set-SyncSetting 'DriveAccountToken' '100000000000000000004'
    Assert ((Resolve-SyncRoot).Reason -eq 'token-not-mounted') 'an account without a My Drive counts as not mounted'

    # ---------------------------------------------------------------- D3: machine id
    $m1 = Get-SyncMachine
    $m2 = Get-SyncMachine
    Assert ($m1.Id -match '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') 'the machine id is a GUID'
    Assert ($m1.Id -eq $m2.Id) 'the same id every time'
    Assert ($m1.Name -eq $env:COMPUTERNAME) 'the name is the computer name'
    Assert ((Get-Setting 'Sync.MachineId') -eq $m1.Id) 'the id is stored in the settings'
    Set-Setting 'Sync.MachineId' 'not-a-guid'
    $m3 = Get-SyncMachine
    Assert ($m3.Id -ne 'not-a-guid' -and $m3.Id -match '\A[0-9a-f]{8}-') 'a damaged id is replaced by a new one'

    # ---------------------------------------------------------------- D4: path roots
    Assert ((Get-SyncPathRoots).Count -eq 0) 'no roots to begin with'
    Set-SyncPathRoot -Name 'Proj' -Path 'D:\Work\Projects'
    Set-SyncPathRoot -Name 'my_docs-2' -Path 'E:\Docs\'
    $roots = Get-SyncPathRoots
    Assert ($roots -is [hashtable] -and $roots['Proj'] -eq 'D:\Work\Projects' -and $roots['my_docs-2'] -eq 'E:\Docs') 'roots round trip as a hashtable, trailing slash trimmed'
    Set-SyncPathRoot -Name 'Proj' -Path 'D:\Elsewhere'
    Assert ((Get-SyncPathRoots)['Proj'] -eq 'D:\Elsewhere' -and (Get-SyncPathRoots).Count -eq 2) 'setting a name again replaces it'
    Set-SyncPathRoot -Name 'Share' -Path '\\server\share\proj'
    Assert ((Get-SyncPathRoots)['Share'] -eq '\\server\share\proj') 'a UNC path is accepted'
    foreach ($badName in 'bad name', 'a/b', '', '..', 'x:y', "a`nb") { Assert-Throws { Set-SyncPathRoot -Name $badName -Path 'D:\x' } "bad root name [$badName]" }
    foreach ($badPath in 'relative\path', '.\x', 'D:x', '\rooted', 'D:\a\..\b', "D:\a`nb", '', 'D:\a:b') { Assert-Throws { Set-SyncPathRoot -Name 'Bad' -Path $badPath } "bad root path [$badPath]" }
    Assert (-not (Get-SyncPathRoots).ContainsKey('Bad')) 'nothing stored for refused roots'
} finally {
    Remove-TestTempDir $tmp
}

Write-Host 'HarnessSyncConfig.Tests: OK'
