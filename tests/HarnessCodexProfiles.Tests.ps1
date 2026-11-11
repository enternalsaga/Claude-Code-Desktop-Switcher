$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
$profilesSrc = Join-Path $root 'src\Harness.Codex.Profiles.ps1'
. (Import-TestFunctions -Files @($profilesSrc) -Names @(
    'Get-CodexProfilesRoot','Find-CodexInstall','Get-CodexLabels','Set-CodexLabel','Get-CodexRunningMap','Get-CodexProfiles',
    'Test-CodexProfileName','New-CodexProfile','Rename-CodexProfile','Remove-CodexProfile','Invoke-WithCodexEnv','Start-CodexProfile',
    'Invoke-CodexLogin','Add-CodexAccount','Resolve-CodexProfile','New-CodexShortcut','Invoke-CodexChatFunction','Register-CodexHarness'))
. (Import-TestFunctions -Files @((Join-Path $root 'src\Harness.Core.ps1')) -Names @(
    'Get-HarnessRequiredCapabilities','Register-Harness','Get-Harness','Reset-HarnessRegistry','Register-Harnesses','Resolve-TransferMode'))
. (Import-TestFunctions -Files @((Join-Path $root 'ClaudeSwitcher.ps1')) -Names @('Get-Setting','Set-Setting','Get-LauncherScript','Set-LauncherTarget'))

$fixture = New-TestTempDir
$origProfile = $env:USERPROFILE
$origCodexHome = $env:CODEX_HOME
$origElectron = $env:CODEX_ELECTRON_USER_DATA_PATH
try {
    # Everything below happens under a fake USERPROFILE and a fake settings file.
    $env:USERPROFILE = Join-Path $fixture 'user'
    New-Item -ItemType Directory -Path $env:USERPROFILE | Out-Null
    $script:ProfileRoot = Join-Path $fixture 'switcher'
    $script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
    $script:ScriptPath = Join-Path $fixture 'ClaudeSwitcher.ps1'
    $script:InstalledScript = Join-Path $fixture 'nonexistent\ClaudeSwitcher.ps1'
    $script:CodexProcessSource = { @() }

    # --- P1: install detection ---
    $pkgDir = Join-Path $fixture 'WindowsApps\OpenAI.Codex_1.2.3_x64__abc'
    New-Item -ItemType Directory -Path (Join-Path $pkgDir 'app\resources') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $pkgDir 'app\ChatGPT.exe'), 'x')
    [IO.File]::WriteAllText((Join-Path $pkgDir 'app\resources\codex.exe'), 'x')
    [IO.File]::WriteAllText((Join-Path $pkgDir 'AppxManifest.xml'), '<Package xmlns="urn:x"><Applications><Application Id="App" /><Application Id="Other" /></Applications></Package>')
    $pkg = [pscustomobject]@{ InstallLocation = $pkgDir; PackageFamilyName = 'OpenAI.Codex_abc'; Version = '1.2.3.0' }
    $inst = Find-CodexInstall -Package $pkg
    Assert ($inst.Installed -and $inst.Kind -eq 'Msix' -and $inst.Exe -eq (Join-Path $pkgDir 'app\ChatGPT.exe')) 'install exe'
    Assert ($inst.CodexExe -eq (Join-Path $pkgDir 'app\resources\codex.exe') -and $inst.Version -eq '1.2.3.0') 'codex exe and version'
    Assert ($inst.Aumid -eq 'OpenAI.Codex_abc!App') "aumid: $($inst.Aumid)"
    Remove-Item -LiteralPath (Join-Path $pkgDir 'app\resources\codex.exe')
    $inst2 = Find-CodexInstall -Package $pkg
    Assert ($inst2.Installed -and ($null -eq $inst2.CodexExe -or $inst2.CodexExe -notlike "$pkgDir*")) 'bundled codex missing falls back outside the package'
    [IO.File]::WriteAllText((Join-Path $pkgDir 'app\resources\codex.exe'), 'x')
    Assert (-not (Find-CodexInstall -Package $null).Installed) 'no package means not installed'
    Assert (-not (Find-CodexInstall -Package ([pscustomobject]@{ InstallLocation = (Join-Path $fixture 'gone'); PackageFamilyName = 'x'; Version = '1' })).Installed) 'package without exe is not installed'

    # --- P2: running map ---
    $pkgExe = Join-Path $pkgDir 'app\ChatGPT.exe'
    $procs = @(
        [pscustomobject]@{ ProcessId = 10; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '"' },
        [pscustomobject]@{ ProcessId = 11; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '" --user-data-dir="C:\Users\a b\.codex-profiles\Work\electron"' },
        [pscustomobject]@{ ProcessId = 12; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '" --type=renderer --user-data-dir="C:\x"' },
        [pscustomobject]@{ ProcessId = 13; ExecutablePath = 'C:\other\ChatGPT.exe'; CommandLine = 'C:\other\ChatGPT.exe' },
        [pscustomobject]@{ ProcessId = 14; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '" --user-data-dir=C:\p\Plain\electron\' }
    )
    $map = Get-CodexRunningMap -Processes $procs
    Assert ($map.Count -eq 3 -and $map[''] -eq 10) "map size $($map.Count)"
    Assert ($map['C:\Users\a b\.codex-profiles\Work\electron'] -eq 11 -and $map['C:\p\Plain\electron'] -eq 14) 'quoted and unquoted user-data-dir, trailing slash trimmed'
    Assert (-not ($map.Values -contains 12) -and -not ($map.Values -contains 13)) 'child and foreign processes ignored'

    # --- P2: profiles ---
    $def = @(Get-CodexProfiles)
    Assert ($def.Count -eq 1 -and $def[0].IsDefault -and $def[0].Id -eq 'Default' -and $def[0].Harness -eq 'codex') 'default only'
    Assert ($def[0].CodexHome -eq (Join-Path $env:USERPROFILE '.codex') -and $null -eq $def[0].UserDataDir) 'default paths'
    $work = New-CodexProfile -Name 'Work'
    Assert ($work.CodexHome -eq (Join-Path $env:USERPROFILE '.codex-profiles\Work') -and $work.UserDataDir -eq (Join-Path $work.CodexHome 'electron')) 'profile paths'
    Assert ((Test-Path -LiteralPath $work.CodexHome) -and (Test-Path -LiteralPath $work.UserDataDir)) 'folders created'
    New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.codex-profiles\spike1') | Out-Null
    $ids = @(Get-CodexProfiles | ForEach-Object { $_.Id })
    Assert (($ids -join ',') -eq 'Default,Work') "spike* hidden, got $($ids -join ',')"
    $script:CodexProcessSource = { @([pscustomobject]@{ ProcessId = 77; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '" --user-data-dir="' + (Join-Path $env:USERPROFILE '.codex-profiles\Work\electron') + '"' }) }
    $listed = @(Get-CodexProfiles)
    Assert (($listed | Where-Object { $_.Id -eq 'Work' }).Pid -eq 77 -and $null -eq ($listed | Where-Object { $_.IsDefault }).Pid) 'Pid matched through --user-data-dir'
    $script:CodexProcessSource = { @([pscustomobject]@{ ProcessId = 5; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '"' }) }
    Assert ((Get-CodexProfiles | Where-Object { $_.IsDefault }).Pid -eq 5) 'process without the flag is Default'
    $script:CodexProcessSource = { @() }

    foreach ($bad in '', ' ', 'a/b', 'a:b', '.hid', 'end.', 'end ', 'CON', 'LPT1', ('x' * 41), 'spike2', 'Work', 'Default') {
        Assert ($null -ne (Test-CodexProfileName -Name $bad)) "name '$bad' must be rejected"
    }
    Assert ($null -eq (Test-CodexProfileName -Name 'Home 2')) 'valid name accepted'
    Assert-Throws { New-CodexProfile -Name 'Work' } 'duplicate profile must throw'

    Rename-CodexProfile -Profile $work -NewName 'Office'
    Assert ((Get-CodexProfiles | Where-Object { $_.Id -eq 'Work' }).Name -eq 'Office') 'rename changes the label only'
    Assert (Test-Path -LiteralPath $work.CodexHome) 'folder untouched by rename'
    Set-Setting 'Other' 'keep'
    Rename-CodexProfile -Profile $work -NewName 'Office2'
    Assert ((Get-Setting 'Other') -eq 'keep' -and (Get-CodexLabels)['Work'] -eq 'Office2') 'labels stored under Harnesses.codex.Labels, other settings kept'
    Assert-Throws { Rename-CodexProfile -Profile $work -NewName 'CON' } 'rename validates'

    # --- P2: remove ---
    Assert-Throws { Remove-CodexProfile -Profile $def[0] } 'Default is never removed'
    $script:CodexProcessSource = { @([pscustomobject]@{ ProcessId = 77; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '" --user-data-dir="' + (Join-Path $env:USERPROFILE '.codex-profiles\Work\electron') + '"' }) }
    Assert-Throws { Remove-CodexProfile -Profile $work } 'running profile is not removed'
    Assert (Test-Path -LiteralPath $work.CodexHome) 'still there'
    $script:CodexProcessSource = { @() }
    $outside = Join-Path $fixture 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    Assert-Throws { Remove-CodexProfile -Profile ([pscustomobject]@{ IsDefault = $false; Id = 'x'; Name = 'x'; CodexHome = $outside }) } 'folder outside .codex-profiles refused'
    Assert-Throws { Remove-CodexProfile -Profile ([pscustomobject]@{ IsDefault = $false; Id = 'x'; Name = 'x'; CodexHome = (Get-CodexProfilesRoot) }) } 'the root itself refused'
    Assert (Test-Path -LiteralPath $outside) 'outside folder intact'
    $junction = Join-Path (Get-CodexProfilesRoot) 'Linked'
    cmd /c mklink /J "$junction" "$outside" | Out-Null
    Assert-Throws { Remove-CodexProfile -Profile ([pscustomobject]@{ IsDefault = $false; Id = 'Linked'; Name = 'Linked'; CodexHome = $junction }) } 'junction refused'
    Assert (Test-Path -LiteralPath $outside) 'junction target intact'
    cmd /c rmdir "$junction" | Out-Null
    Remove-CodexProfile -Profile $work
    Assert (-not (Test-Path -LiteralPath $work.CodexHome) -and -not (Get-CodexLabels).ContainsKey('Work')) 'profile and label removed'
    Assert (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex-profiles\spike1')) 'spike profile untouched'

    # --- P3: launch ---
    $started = New-Object Collections.Generic.List[object]
    $script:CodexStartProcess = {
        param($File, $Arguments)
        $started.Add([pscustomobject]@{ File = $File; Args = $Arguments; Home = $env:CODEX_HOME; Electron = $env:CODEX_ELECTRON_USER_DATA_PATH })
        return $null
    }
    function Show-ProfileWindow { param([int]$ProcessId) return ($ProcessId -eq 5) }
    $env:CODEX_HOME = 'PRE-EXISTING'
    Remove-Item Env:\CODEX_ELECTRON_USER_DATA_PATH -ErrorAction SilentlyContinue
    $inst = Find-CodexInstall -Package $pkg
    $extra = New-CodexProfile -Name 'Extra'
    Assert ((Start-CodexProfile -Profile $extra -Install $inst) -eq 'started') 'launch non-default'
    Assert ($started.Count -eq 1 -and $started[0].File -eq $inst.Exe -and $started[0].Args -eq ('--user-data-dir="{0}"' -f $extra.UserDataDir)) 'exe and --user-data-dir argument'
    Assert ($started[0].Home -eq $extra.CodexHome -and $started[0].Electron -eq $extra.UserDataDir) 'env set during the start'
    Assert ($env:CODEX_HOME -eq 'PRE-EXISTING' -and $null -eq $env:CODEX_ELECTRON_USER_DATA_PATH) 'env restored afterwards'
    $defaultProfile = Get-CodexProfiles | Where-Object { $_.IsDefault }
    Assert ((Start-CodexProfile -Profile $defaultProfile -Install $inst) -eq 'started') 'launch default'
    Assert ($started[1].File -eq 'explorer.exe' -and $started[1].Args -eq 'shell:AppsFolder\OpenAI.Codex_abc!App') 'default goes through the shell'
    $script:CodexProcessSource = { @([pscustomobject]@{ ProcessId = 5; ExecutablePath = $pkgExe; CommandLine = '"' + $pkgExe + '"' }) }
    Assert ((Start-CodexProfile -Profile $defaultProfile -Install $inst) -eq 'focused' -and $started.Count -eq 2) 'running profile is focused, not started again'
    $script:CodexProcessSource = { @() }
    Assert-Throws { Start-CodexProfile -Profile $extra -Install ([pscustomobject]@{ Installed = $false }) } 'not installed throws'
    Remove-Item Env:\CODEX_HOME

    # --- P3: login ---
    $logins = New-Object Collections.Generic.List[object]
    $script:CodexLoginRunner = {
        param($CodexExe, $CodexHome)
        $logins.Add([pscustomobject]@{ Exe = $CodexExe; Home = $env:CODEX_HOME })
        if ($script:FakeLoginWritesAuth) { [IO.File]::WriteAllText((Join-Path $CodexHome 'auth.json'), 'not-read') }
    }
    $script:FakeLoginWritesAuth = $false
    Assert ((Invoke-CodexLogin -Profile $extra -Install $inst) -eq 'cancelled') 'no auth.json means cancelled'
    Assert ($logins[0].Exe -eq $inst.CodexExe -and $logins[0].Home -eq $extra.CodexHome) 'login runs codex.exe with the profile CODEX_HOME'
    $script:FakeLoginWritesAuth = $true
    Assert ((Invoke-CodexLogin -Profile $extra -Install $inst) -eq 'signed-in') 'auth.json present means signed in'
    Assert-Throws { Invoke-CodexLogin -Profile $extra -Install ([pscustomobject]@{ Installed = $true; CodexExe = $null }) } 'no codex.exe throws'

    # a login already running elsewhere (another thread holds the named mutex)
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        $m = New-Object System.Threading.Mutex($false, 'Local\HarnessSwitcher-CodexLogin')
        [void]$m.WaitOne()
        'held'
        [System.Threading.Thread]::Sleep(4000)
        $m.ReleaseMutex()
    })
    $async = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(3)
    $probe = New-Object System.Threading.Mutex($false, 'Local\HarnessSwitcher-CodexLogin')
    $busy = $false
    while ((Get-Date) -lt $deadline) {
        if (-not $probe.WaitOne(0)) { $busy = $true; break } else { $probe.ReleaseMutex() }
        Start-Sleep -Milliseconds 50
    }
    $probe.Dispose()
    Assert $busy 'test setup: other thread holds the login mutex'
    $before = $logins.Count
    Assert ((Invoke-CodexLogin -Profile $extra -Install $inst) -eq 'busy' -and $logins.Count -eq $before) 'second login reports busy and does not run'
    [void]$ps.EndInvoke($async); $ps.Dispose()

    # --- P3: add account ---
    $script:FakeLoginWritesAuth = $true
    Assert ((Add-CodexAccount -Name 'Fresh') -eq 'started') 'add account: new profile, login, launch'
    Assert (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex-profiles\Fresh\auth.json')) 'fresh profile is signed in'
    $script:FakeLoginWritesAuth = $false
    Assert ((Add-CodexAccount -Name 'Nope') -eq 'cancelled') 'cancelled login'
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex-profiles\Nope'))) 'unused profile cleaned up after a cancelled login'
    Assert-Throws { Add-CodexAccount -Name 'bad/name' } 'invalid name throws before anything is created'

    # --- P4: -Launch codex:<id> and shortcuts ---
    Assert ((Resolve-CodexProfile -Name 'spike1').Id -eq 'spike1' -and (Get-CodexProfiles | Where-Object { $_.Id -eq 'spike1' }) -eq $null) 'spike profiles launch by name but stay out of lists'
    Assert ((Resolve-CodexProfile -Name 'fresh').Id -eq 'Fresh' -and (Resolve-CodexProfile -Name 'default').IsDefault) 'resolve by id or name, case-insensitive'
    . (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.Tray.ps1')) -Names @('Get-HarnessDisplayName','Invoke-HarnessLaunchArg'))
    Reset-HarnessRegistry
    Register-CodexHarness
    $threw = ''
    try { [void](Invoke-HarnessLaunchArg -Value 'codex:ghost') } catch { $threw = $_.Exception.Message }
    Assert ($threw -like "*no Codex profile called 'ghost'*Profiles:*Default*Fresh*") "missing profile message: $threw"
    $count = $started.Count
    Assert ((Invoke-HarnessLaunchArg -Value 'codex:Fresh') -eq $true -and $started.Count -eq $count + 1) 'codex:<id> starts the profile'
    Assert ((Invoke-HarnessLaunchArg -Value 'codex:spike1') -eq $true -and $started[-1].Args -like '*spike1*') 'codex:spike1 reaches the hidden test profile through ResolveProfile'
    $count = $started.Count
    foreach ($notMine in 'Fresh', 'claude:x', 'unknown:x', 'Codex:Fresh') { Assert ((Invoke-HarnessLaunchArg -Value $notMine) -eq $false) "'$notMine' is not a harness launch value" }
    Assert ($started.Count -eq $count) 'nothing started for values that are not for a harness'

    $lnkDir = Join-Path $fixture 'lnk'
    $freshProfile = Resolve-CodexProfile -Name 'Fresh'
    $lnk = New-CodexShortcut -Profile $freshProfile -Directory $lnkDir -Install $inst
    Assert ((Split-Path -Leaf $lnk) -eq 'Codex - Fresh.lnk' -and (Test-Path -LiteralPath $lnk)) 'shortcut file name'
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    Assert ($sc.Arguments -like '*-Launch "codex:Fresh"*') "shortcut arguments: $($sc.Arguments)"
    Assert ($sc.IconLocation -like "$($inst.Exe),*") 'shortcut icon is the app icon'
    $lnkDef = New-CodexShortcut -Profile $defaultProfile -Directory $lnkDir -Install $inst
    $scDef = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkDef)
    Assert ($scDef.TargetPath -like '*explorer.exe' -and $scDef.Arguments -eq 'shell:AppsFolder\OpenAI.Codex_abc!App') 'default shortcut opens through the shell'

    # --- P5: adapter ---
    Reset-HarnessRegistry
    Register-Harnesses
    Assert ($null -ne (Get-Harness -Name 'codex')) 'codex registered by Register-Harnesses when its function exists'
    $a = (Get-Harness -Name 'codex').Adapter
    foreach ($k in 'Detect','GetProfiles','Launch','NewProfile','RemoveProfile','Rename','ListChats','Export','ImportNative','ImportHandoff','ImportExternalClaude','ImportNeedsClose') { Assert ($a[$k] -is [scriptblock]) "adapter lacks $k" }
    Register-Harness -Name 'claude' -Adapter @{ Detect = {}; GetProfiles = {}; Launch = {}; ListChats = {}; Export = {}; ImportHandoff = {}; ImportNative = {} }
    Assert ((Resolve-TransferMode -Source 'codex' -Target 'codex') -eq 'native') 'codex to codex is native'
    Assert ((Resolve-TransferMode -Source 'claude' -Target 'codex') -eq 'codex-import') 'claude to codex is codex-import'
    Assert ((Resolve-TransferMode -Source 'codex' -Target 'claude') -eq 'handoff') 'codex to claude is handoff'
    $det = & $a.Detect
    Assert ($det -is [psobject] -and $det.PSObject.Properties['Aumid']) 'Detect has the common shape'

    # chat functions of the other lane are not loaded here: clear errors, no crash
    $msg = ''
    try { & $a.ImportNative 'x.zip' $extra } catch { $msg = $_.Exception.Message }
    Assert ($msg -like '*Import-CodexNative*not loaded*') "missing chat function message: $msg"
    $chats = @(& $a.ListChats $extra 3>&1 | Where-Object { $_ -is [Management.Automation.WarningRecord] })
    Assert ($chats.Count -eq 1) 'ListChats without chat support warns instead of crashing'
    function Get-CodexChats { param($Profile) return @([pscustomobject]@{ ChatId = 'c1'; Title = 'T' }) }
    function Import-CodexNative { param($BundlePath, $Profile) return ('native:{0}:{1}' -f $BundlePath, $Profile.Id) }
    Assert ((@(& $a.ListChats $extra))[0].ChatId -eq 'c1') 'ListChats calls Get-CodexChats once present'
    Assert ((& $a.ImportNative 'b.zip' $extra) -eq 'native:b.zip:Extra') 'ImportNative passes its arguments through'

    # --- P4: tray, generic over registered harnesses (the stubs below replace the real helpers) ---
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.Tray.ps1')) -Names @('Invoke-HarnessTrayLaunch','Invoke-HarnessTrayAddAccount','Invoke-HarnessTrayShortcut','New-HarnessTrayItem','Add-HarnessTrayItems'))
    . (Import-TestFunctions -Files @((Join-Path $root 'src\Harness.Core.ps1')) -Names @('Get-Harnesses'))
    $script:Messages = New-Object Collections.Generic.List[string]
    function Show-Message { param($Text, $Caption, $Buttons = 'OK', $Icon = 'Information') $script:Messages.Add($Text); return 'OK' }
    $script:Answer = $null
    function Show-Prompt { param($Message, $Title, $OkText, $Initial) return $script:Answer }
    function Get-ShortcutDirs { return @('D1', 'D2') }
    $fontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $script:Log = New-Object Collections.Generic.List[string]
    $script:NewResult = 'started'
    function New-FakeAdapter([hashtable]$Extra) { $a = @{ Detect = { [pscustomobject]@{ Installed = $true } }; ImportHandoff = {}; ListChats = {}; Export = {} }; foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }; return $a }
    $alpha = New-FakeAdapter @{
        DisplayName = 'Alpha App'
        GetProfiles = { @([pscustomobject]@{ Id = 'a1'; Name = 'One'; Pid = 5 }, [pscustomobject]@{ Id = 'a2'; Name = 'Two'; Pid = $null }) }
        Launch = { param($Profile) $script:Log.Add("launch:$($Profile.Id)") }
        NewProfile = { param($Name) $script:Log.Add("new:$Name"); if ($Name -eq 'boom') { throw 'kaboom' }; return $script:NewResult }
        NewShortcut = { param($Profile, $Directory) $script:Log.Add("lnk:$($Profile.Id)@$Directory") }
    }
    $beta = New-FakeAdapter @{
        GetProfiles = { @([pscustomobject]@{ Id = 'b1'; Name = 'Solo'; Pid = $null }) }
        Launch = { param($Profile) $script:Log.Add("launch:$($Profile.Id)"); if ($Profile.Id -eq 'bad') { throw 'cannot start' } }
    }
    $gamma = New-FakeAdapter @{ Detect = { [pscustomobject]@{ Installed = $false } }; GetProfiles = { @() }; Launch = {} }
    $delta = New-FakeAdapter @{ GetProfiles = { throw 'broken adapter' }; Launch = {}; DisplayName = 'Delta' }
    Reset-HarnessRegistry
    Register-Harness -Name 'claude' -Adapter (New-FakeAdapter @{ GetProfiles = { @() }; Launch = {} })
    Register-Harness -Name 'alpha' -Adapter $alpha
    Register-Harness -Name 'beta' -Adapter $beta
    Register-Harness -Name 'gamma' -Adapter $gamma
    Register-Harness -Name 'delta' -Adapter $delta

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    Add-HarnessTrayItems -Menu $menu
    $top = @($menu.Items | ForEach-Object { $_.Text })
    Assert (($top -join '|') -eq 'Alpha App|Beta|Delta (error)') "top level: $($top -join '|') (claude and not-installed are skipped, DisplayName or capitalised name, failing adapter shows an error item)"
    Assert (-not $menu.Items[2].Enabled) 'error item is disabled'
    $a = $menu.Items[0].DropDownItems
    $texts = @($a | ForEach-Object { if ($_ -is [System.Windows.Forms.ToolStripSeparator]) { '---' } else { $_.Text } })
    Assert (($texts -join '|') -eq 'One|Two|---|Add Alpha App account...|Add shortcut') "alpha items: $($texts -join '|')"
    Assert ($a[0].ShortcutKeyDisplayString -eq 'open' -and $a[0].Font.Bold -and -not $a[1].ShortcutKeyDisplayString) 'running profile marked, idle plain'
    Assert ((@($a[4].DropDownItems | ForEach-Object { $_.Text }) -join ',') -eq 'One,Two') 'shortcut submenu lists the profiles'
    $b = @($menu.Items[1].DropDownItems | ForEach-Object { $_.Text })
    Assert (($b -join '|') -eq 'Solo') "beta has no NewProfile or NewShortcut items: $($b -join '|')"

    $a[1].PerformClick()
    Assert (($script:Log -join ',') -eq 'launch:a2') 'clicking a profile calls that adapter Launch'
    $script:Log.Clear()
    $a[4].DropDownItems[1].PerformClick()
    Assert (($script:Log -join ',') -eq 'lnk:a2@D1,lnk:a2@D2' -and $script:Messages[-1] -like '*shortcuts*Alpha App*') 'shortcut item goes through NewShortcut for every folder'
    $script:Messages.Clear(); $script:Log.Clear()
    Invoke-HarnessTrayLaunch -Harness (Get-Harness -Name 'beta') -Profile ([pscustomobject]@{ Id = 'bad'; Name = 'Bad' })
    Assert ($script:Messages.Count -eq 1 -and $script:Messages[0] -like '*Beta*cannot start*') 'launch failure is shown, not thrown'

    $alphaHarness = Get-Harness -Name 'alpha'
    $script:Messages.Clear(); $script:Log.Clear()
    $script:Answer = $null
    Invoke-HarnessTrayAddAccount -Harness $alphaHarness
    Assert ($script:Messages.Count -eq 0 -and $script:Log.Count -eq 0) 'cancelled prompt does nothing'
    $script:Answer = [pscustomobject]@{ Text = 'Home' }
    Invoke-HarnessTrayAddAccount -Harness $alphaHarness
    Assert (($script:Log -join ',') -eq 'new:Home' -and $script:Messages.Count -eq 1) 'valid name: one heads-up, NewProfile runs'
    $script:Messages.Clear(); $script:NewResult = 'cancelled'
    Invoke-HarnessTrayAddAccount -Harness $alphaHarness
    Assert ($script:Messages[-1] -like '*did not finish*') 'cancelled explained'
    $script:Messages.Clear(); $script:NewResult = 'busy'
    Invoke-HarnessTrayAddAccount -Harness $alphaHarness
    Assert ($script:Messages[-1] -like '*already running*') 'busy explained'
    $script:Messages.Clear(); $script:Answer = [pscustomobject]@{ Text = 'boom' }
    Invoke-HarnessTrayAddAccount -Harness $alphaHarness
    Assert ($script:Messages[-1] -like '*kaboom*') 'adapter error is shown, not thrown'

    # -Launch <harness>:<id> with the fake adapters (no ResolveProfile: found through GetProfiles)
    . (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.Tray.ps1')) -Names @('Get-HarnessDisplayName','Invoke-HarnessLaunchArg'))
    $script:Log.Clear()
    Assert ((Invoke-HarnessLaunchArg -Value 'alpha:two') -eq $true -and ($script:Log -join ',') -eq 'launch:a2') 'launch arg resolves by id or name through GetProfiles'
    $threw = ''
    try { [void](Invoke-HarnessLaunchArg -Value 'beta:nope') } catch { $threw = $_.Exception.Message }
    Assert ($threw -like "*no Beta profile called 'nope'*Profiles: Solo*") "message: $threw"

    Write-Output 'PASS: Codex install, profiles, tray, labels, running map, launch env, login lock, add account, -Launch, shortcuts, adapter.'
} finally {
    $env:USERPROFILE = $origProfile
    if ($null -eq $origCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $origCodexHome }
    if ($null -eq $origElectron) { Remove-Item Env:\CODEX_ELECTRON_USER_DATA_PATH -ErrorAction SilentlyContinue } else { $env:CODEX_ELECTRON_USER_DATA_PATH = $origElectron }
    Remove-TestTempDir $fixture
}
