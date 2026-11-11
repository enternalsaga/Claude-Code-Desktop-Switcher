# Harness.Codex.Profiles.ps1 - Codex desktop (OpenAI.Codex MSIX): install detection, profiles, launch, login,
# shortcuts and the adapter registration. A profile is a CODEX_HOME plus an Electron user-data folder, both
# kept under %USERPROFILE%\.codex-profiles so the MSIX does not redirect their writes (spike S1).
# Chat capabilities live in Harness.Codex.Chats.ps1 (another lane) and are called by name at run time.
# Uses from ClaudeSwitcher.ps1: Get-Setting, Set-Setting, Show-ProfileWindow, Set-LauncherTarget. ASCII only.

function Get-CodexProfilesRoot {
    return (Join-Path $env:USERPROFILE '.codex-profiles')
}

# Package may be passed in (tests); otherwise the installed OpenAI.Codex package is used.
function Find-CodexInstall {
    param($Package)
    if (-not $PSBoundParameters.ContainsKey('Package')) { $Package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $exe = $(if ($Package -and $Package.InstallLocation) { Join-Path $Package.InstallLocation 'app\ChatGPT.exe' })
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ Installed = $false; Kind = 'Msix'; Exe = $null; CodexExe = $null; Version = $null; Aumid = $null; InstallLocation = $null }
    }
    $appId = 'App'
    $manifest = Join-Path $Package.InstallLocation 'AppxManifest.xml'
    if (Test-Path -LiteralPath $manifest) {
        try {
            $ids = @(([xml](Get-Content -LiteralPath $manifest -Raw)).Package.Applications.Application | ForEach-Object { $_.Id })
            if ($ids.Count -and $ids -notcontains 'App') { $appId = $ids[0] }
        } catch { }
    }
    $codex = Join-Path $Package.InstallLocation 'app\resources\codex.exe'
    if (-not (Test-Path -LiteralPath $codex)) {
        # Fallback: the real codex.exe of the npm CLI. Never a .cmd shim (spike F8).
        $codex = (Get-Command 'codex.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    }
    return [pscustomobject]@{
        Installed = $true; Kind = 'Msix'; Exe = $exe; CodexExe = $codex; Version = [string]$Package.Version
        Aumid = ('{0}!{1}' -f $Package.PackageFamilyName, $appId); InstallLocation = $Package.InstallLocation
    }
}

# --- labels (settings.json: Harnesses.codex.Labels) --------------------------------

function Get-CodexLabels {
    $map = @{}
    $h = Get-Setting 'Harnesses'
    if ($h -and $h.codex -and $h.codex.Labels) { $h.codex.Labels.PSObject.Properties | ForEach-Object { $map[$_.Name] = [string]$_.Value } }
    return $map
}

function Set-CodexLabel {
    param([Parameter(Mandatory)][string]$Id, [string]$Label)
    $labels = Get-CodexLabels
    if ([string]::IsNullOrWhiteSpace($Label) -or $Label -ceq $Id) { $labels.Remove($Id) } else { $labels[$Id] = $Label }
    # Rebuild the whole Harnesses bag so other harnesses' keys survive.
    $bag = @{}
    $raw = Get-Setting 'Harnesses'
    if ($raw) { $raw.PSObject.Properties | ForEach-Object { $bag[$_.Name] = $_.Value } }
    $codex = @{}
    if ($bag['codex']) { $bag['codex'].PSObject.Properties | ForEach-Object { $codex[$_.Name] = $_.Value } }
    $codex['Labels'] = $labels
    $bag['codex'] = $codex
    Set-Setting 'Harnesses' $bag
}

# --- running instances ---------------------------------------------------------------

# Maps each running main ChatGPT.exe to its profile key: the --user-data-dir (trailing slash trimmed), or
# '' for Default. Child processes (--type=) and ChatGPT.exe copies outside the OpenAI.Codex package are ignored.
function Get-CodexRunningMap {
    param($Processes)
    if (-not $PSBoundParameters.ContainsKey('Processes')) {
        # $script:CodexProcessSource lets tests supply fake processes.
        $Processes = $(if ($script:CodexProcessSource) { & $script:CodexProcessSource } else { Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue })
    }
    $map = @{}
    foreach ($p in @($Processes)) {
        if (-not $p.CommandLine -or $p.CommandLine -match '--type=' -or -not $p.ExecutablePath -or $p.ExecutablePath -notmatch '\\OpenAI\.Codex_') { continue }
        $key = ''
        if ($p.CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') { $key = $(if ($Matches[1]) { $Matches[1] } else { $Matches[2] }).TrimEnd('\') }
        if (-not $map.ContainsKey($key)) { $map[$key] = [int]$p.ProcessId }
    }
    return $map
}

# --- profiles ------------------------------------------------------------------------

# Folders named spike* are test profiles of the spikes: hidden from lists unless -IncludeTest (used when a
# profile is looked up by name, so "-Launch codex:spike1" still works for manual checks).
function Get-CodexProfiles {
    param($Processes, [switch]$IncludeTest)
    $running = $(if ($PSBoundParameters.ContainsKey('Processes')) { Get-CodexRunningMap -Processes $Processes } else { Get-CodexRunningMap })
    $labels = Get-CodexLabels
    $list = New-Object Collections.Generic.List[object]
    $list.Add([pscustomobject]@{
        Harness = 'codex'; Id = 'Default'; Name = $(if ($labels['Default']) { $labels['Default'] } else { 'Default' }); IsDefault = $true
        CodexHome = (Join-Path $env:USERPROFILE '.codex'); UserDataDir = $null; Pid = $running['']
    })
    $root = Get-CodexProfilesRoot
    if (Test-Path -LiteralPath $root) {
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory | Where-Object { $IncludeTest -or $_.Name -notlike 'spike*' } | Sort-Object Name)) {
            $electron = Join-Path $d.FullName 'electron'
            $list.Add([pscustomobject]@{
                Harness = 'codex'; Id = $d.Name; Name = $(if ($labels[$d.Name]) { $labels[$d.Name] } else { $d.Name }); IsDefault = $false
                CodexHome = $d.FullName; UserDataDir = $electron; Pid = $running[$electron.TrimEnd('\')]
            })
        }
    }
    return $list.ToArray()
}

# Same rules as the Claude side (written separately on purpose), plus: no spike* or Default names.
function Test-CodexProfileName {
    param([string]$Name, [string]$ExceptId)
    if ([string]::IsNullOrWhiteSpace($Name))          { return 'Name cannot be empty.' }
    if ($Name -match '[\\/:*?"<>|\x00-\x1f]')         { return 'Name cannot contain \ / : * ? " < > |' }
    if ($Name -match '^\.|[. ]$')                     { return 'Name cannot start with a dot or end with a dot or space.' }
    if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return "'$Name' is a reserved name on Windows." }
    if ($Name.Length -gt 40)                          { return 'Name is too long (40 characters max).' }
    if ($Name -like 'spike*')                         { return "Names starting with 'spike' are reserved for test profiles." }
    foreach ($p in (Get-CodexProfiles)) {
        if ($p.Id -eq $ExceptId) { continue }
        if ($p.Id -eq $Name -or $p.Name -eq $Name)    { return "A profile named '$Name' already exists." }
    }
    return $null
}

function New-CodexProfile {
    param([Parameter(Mandatory)][string]$Name)
    $problem = Test-CodexProfileName -Name $Name
    if ($problem) { throw $problem }
    $home_ = Join-Path (Get-CodexProfilesRoot) $Name
    New-Item -ItemType Directory -Path (Join-Path $home_ 'electron') -Force | Out-Null
    return (Get-CodexProfiles | Where-Object { $_.Id -eq $Name } | Select-Object -First 1)
}

function Rename-CodexProfile {
    param([Parameter(Mandatory)]$Profile, [string]$NewName)
    $problem = Test-CodexProfileName -Name $NewName -ExceptId $Profile.Id
    if ($problem) { throw $problem }
    Set-CodexLabel -Id $Profile.Id -Label $NewName
}

function Remove-CodexProfile {
    param([Parameter(Mandatory)]$Profile)
    if ($Profile.IsDefault) { throw 'The Default Codex profile cannot be removed.' }
    $live = Get-CodexProfiles | Where-Object { $_.Id -eq $Profile.Id } | Select-Object -First 1
    if ($live -and $live.Pid) { throw "'$($Profile.Name)' is running. Close it first." }
    $root = [IO.Path]::GetFullPath((Get-CodexProfilesRoot)).TrimEnd('\') + '\'
    $dir = [IO.Path]::GetFullPath($Profile.CodexHome)
    if (-not $dir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $dir.TrimEnd('\') -eq $root.TrimEnd('\')) { throw "Refusing to delete a folder outside $root" }
    $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing to delete a junction or symbolic link.' }
    if ($item) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Set-CodexLabel -Id $Profile.Id -Label ''
}

# --- launch and login ------------------------------------------------------------------

# Tests replace these two to avoid starting real processes.
$script:CodexStartProcess = { param($File, $Arguments) Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Normal -PassThru }
$script:CodexLoginRunner = {
    param($CodexExe, $CodexHome)
    # "start /wait" gives codex.exe its own console window for the OAuth link, and cmd waits for it.
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "start `"Codex login`" /wait `"$CodexExe`" login" -WindowStyle Hidden -Wait
}

# Runs $Action with CODEX_HOME and CODEX_ELECTRON_USER_DATA_PATH set for this process only, then restores them.
function Invoke-WithCodexEnv {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][scriptblock]$Action)
    $names = 'CODEX_HOME', 'CODEX_ELECTRON_USER_DATA_PATH'
    $old = @{}
    foreach ($n in $names) { $old[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $Profile.CodexHome, 'Process')
        [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH', $Profile.UserDataDir, 'Process')
        & $Action
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $old[$n], 'Process') }
    }
}

# Returns 'focused' when the profile was already open, 'started' otherwise.
function Start-CodexProfile {
    param([Parameter(Mandatory)]$Profile, $Install)
    if (-not $Install) { $Install = Find-CodexInstall }
    if (-not $Install.Installed) { throw 'The Codex desktop app (OpenAI.Codex) is not installed.' }
    $open = (Get-CodexProfiles -IncludeTest | Where-Object { $_.Id -eq $Profile.Id } | Select-Object -First 1).Pid
    if ($open -and (Show-ProfileWindow -ProcessId $open)) { return 'focused' }
    if ($Profile.IsDefault) {
        # Through the shell so the app keeps its package identity.
        [void](& $script:CodexStartProcess 'explorer.exe' ('shell:AppsFolder\' + $Install.Aumid))
        return 'started'
    }
    New-Item -ItemType Directory -Path $Profile.UserDataDir -Force | Out-Null
    Invoke-WithCodexEnv -Profile $Profile -Action { [void](& $script:CodexStartProcess $Install.Exe ('--user-data-dir="{0}"' -f $Profile.UserDataDir)) }
    return 'started'
}

# The app's own Sign in button does not work in a second instance (spike S1), and the login callback port is
# fixed, so: "codex login" with this profile's CODEX_HOME, one at a time. Never reads auth.json.
# Returns 'signed-in', 'cancelled' or 'busy'.
function Invoke-CodexLogin {
    param([Parameter(Mandatory)]$Profile, $Install)
    if (-not $Install) { $Install = Find-CodexInstall }
    if (-not $Install.CodexExe) { throw 'Could not find codex.exe (neither in the Codex app nor on PATH).' }
    $mutex = New-Object System.Threading.Mutex($false, 'Local\HarnessSwitcher-CodexLogin')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return 'busy' }
        New-Item -ItemType Directory -Path $Profile.CodexHome -Force | Out-Null
        Invoke-WithCodexEnv -Profile $Profile -Action { [void](& $script:CodexLoginRunner $Install.CodexExe $Profile.CodexHome) }
        return $(if (Test-Path -LiteralPath (Join-Path $Profile.CodexHome 'auth.json')) { 'signed-in' } else { 'cancelled' })
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# New profile, log in, then open it. A profile that never got signed in is removed again (it only holds the
# empty folders created here). Returns 'started' | 'focused' | 'cancelled' | 'busy'.
function Add-CodexAccount {
    param([Parameter(Mandatory)][string]$Name)
    $profile = New-CodexProfile -Name $Name
    $state = 'cancelled'
    try { $state = Invoke-CodexLogin -Profile $profile } catch { Remove-CodexProfile -Profile $profile; throw }
    if ($state -ne 'signed-in') { Remove-CodexProfile -Profile $profile; return $state }
    return (Start-CodexProfile -Profile $profile)
}

# --- -Launch codex:<id> and shortcuts ----------------------------------------------------

function Resolve-CodexProfile {
    param([Parameter(Mandatory)][string]$Name)
    return (Get-CodexProfiles -IncludeTest | Where-Object { $_.Id -ieq $Name -or $_.Name -ieq $Name } | Select-Object -First 1)
}

function New-CodexShortcut {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Directory, $Install)
    if (-not $Install) { $Install = Find-CodexInstall }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $Directory "Codex - $($Profile.Name).lnk"))
    if ($Profile.IsDefault) {
        $link.TargetPath = 'explorer.exe'
        $link.Arguments = 'shell:AppsFolder\' + $Install.Aumid
    } else {
        Set-LauncherTarget -Link $link -ScriptArgs ('-Launch "codex:{0}"' -f $Profile.Id)
    }
    $link.IconLocation = "$($Install.Exe),0"
    $link.Description = "Open Codex with the '$($Profile.Name)' account"
    $link.WorkingDirectory = $env:USERPROFILE
    $link.Save()
    return $link.FullName
}

# --- adapter -----------------------------------------------------------------------------

# Chat capabilities belong to Harness.Codex.Chats.ps1. They are looked up by name when called, so this file
# loads and registers without it; a missing function gives a clear error (ListChats: an empty list and a warning).
function Invoke-CodexChatFunction {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Arguments = @{})
    if (-not (Get-Command $Name -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Codex chat support is not available yet ($Name is not loaded)."
    }
    return (& $Name @Arguments)
}

function Register-CodexHarness {
    Register-Harness -Name 'codex' -Adapter @{
        DisplayName          = 'Codex'
        # Also finds spike* test profiles, which GetProfiles hides, so -Launch codex:spike1 works.
        ResolveProfile       = { param($Name) Resolve-CodexProfile -Name $Name }
        TestProfileName      = { param($Name) Test-CodexProfileName -Name $Name }
        NewShortcut          = { param($Profile, $Directory) New-CodexShortcut -Profile $Profile -Directory $Directory }
        Detect              = { $i = Find-CodexInstall; [pscustomobject]@{ Installed = $i.Installed; Kind = $i.Kind; Exe = $i.Exe; Version = $i.Version; Aumid = $i.Aumid } }
        GetProfiles          = { Get-CodexProfiles }
        Launch               = { param($Profile) Start-CodexProfile -Profile $Profile }
        NewProfile           = { param($Name) Add-CodexAccount -Name $Name }
        RemoveProfile        = { param($Profile) Remove-CodexProfile -Profile $Profile }
        Rename               = { param($Profile, $NewName) Rename-CodexProfile -Profile $Profile -NewName $NewName }
        ListChats            = {
            param($Profile)
            if (-not (Get-Command Get-CodexChats -CommandType Function -ErrorAction SilentlyContinue)) { Write-Warning 'Codex chat support is not available yet (Get-CodexChats is not loaded).'; return @() }
            Get-CodexChats -Profile $Profile
        }
        Export               = { param($Chat, $OutPath) Invoke-CodexChatFunction 'Export-CodexChat' @{ Chat = $Chat; OutPath = $OutPath } }
        ImportNative         = { param($BundlePath, $Profile) Invoke-CodexChatFunction 'Import-CodexNative' @{ BundlePath = $BundlePath; Profile = $Profile } }
        ImportHandoff        = { param($BundlePath, $Profile) Invoke-CodexChatFunction 'Start-CodexHandoff' @{ BundlePath = $BundlePath; Profile = $Profile } }
        ImportExternalClaude = { param($BundlePath, $Profile) Invoke-CodexChatFunction 'Import-CodexExternalClaude' @{ BundlePath = $BundlePath; Profile = $Profile } }
        ImportNeedsClose     = { param($Profile) Invoke-CodexChatFunction 'Test-CodexImportNeedsClose' @{ Profile = $Profile } }
    }
}
