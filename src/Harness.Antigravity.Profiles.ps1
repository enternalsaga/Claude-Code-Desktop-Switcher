# Harness.Antigravity.Profiles.ps1 - Antigravity adapter, part 1: installs, profiles, launch, registration.
# Two separate apps: Antigravity (data in ~\.gemini\antigravity) and Antigravity IDE (~\.gemini\antigravity-ide).
# Sign-in lives in one Windows Credential Manager entry shared by every profile (spike S4), so there is exactly one
# account per app and no NewProfile / RemoveProfile / Rename. Nothing here reads or writes credentials.
# Needs Harness.Core.ps1; the chat functions live in Harness.Antigravity.Chats.ps1.

function Get-AgyAppDefinitions {
    return @(
        @{ Kind = 'app'; Id = 'app'; Name = 'Antigravity';     ExeRel = 'Antigravity\Antigravity.exe';         DataRel = '.gemini\antigravity' },
        @{ Kind = 'ide'; Id = 'ide'; Name = 'Antigravity IDE'; ExeRel = 'Antigravity IDE\Antigravity IDE.exe'; DataRel = '.gemini\antigravity-ide' }
    )
}

# The three places that touch the system. Tests set $script:AgyHooks to replace them.
function Get-AgyHooks {
    if ($script:AgyHooks) { return $script:AgyHooks }
    return @{
        GetProcesses = { param($ExeName) @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $ExeName.Replace("'", "''"))) }
        StartProcess = { param($Exe) Start-Process -FilePath $Exe -WindowStyle Normal | Out-Null }
        ShowWindow   = { param($ProcessId) Show-ProfileWindow -ProcessId $ProcessId }
        SetClipboard = { param($Text) [System.Windows.Forms.Clipboard]::SetText($Text) }
    }
}

# One entry per installed app: @{ Kind; Id; Name; Exe; Version; DataDir }.
function Find-AntigravityInstall {
    param(
        [string]$ProgramsDir = (Join-Path $env:LOCALAPPDATA 'Programs'),
        [string]$UserHome = $env:USERPROFILE
    )
    foreach ($def in Get-AgyAppDefinitions) {
        $exe = Join-Path $ProgramsDir $def.ExeRel
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
        [pscustomobject]@{ Kind = $def.Kind; Id = $def.Id; Name = $def.Name; Exe = $exe; Version = $version; DataDir = (Join-Path $UserHome $def.DataRel) }
    }
}

# The main process of a running app: not a Chromium child (--type=), not the node sidecar host (--import=), inside the
# install folder, not a test instance (--user-data-dir under AgyProfile-*), and not the child of another candidate.
# Returns $null when it is not running.
function Find-AgyMainProcessId {
    param([Parameter(Mandatory)][string]$Exe)
    $hooks = Get-AgyHooks
    $dir = (Split-Path -Parent $Exe).TrimEnd('\') + '\'
    $candidates = @(& $hooks.GetProcesses (Split-Path -Leaf $Exe) | Where-Object {
        $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch '--import=' -and $_.CommandLine -notmatch 'AgyProfile-' -and
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)
    })
    if (-not $candidates.Count) { return $null }
    $ids = @($candidates | ForEach-Object { [int]$_.ProcessId })
    $roots = @($candidates | Where-Object { $ids -notcontains [int]$_.ParentProcessId })
    if (-not $roots.Count) { $roots = $candidates }
    return [int](($roots | Sort-Object { [int]$_.ProcessId } | Select-Object -First 1).ProcessId)
}

# One profile per installed app. IsDefault is always true: there is nothing to add.
function Get-AntigravityProfiles {
    param([string]$ProgramsDir = (Join-Path $env:LOCALAPPDATA 'Programs'), [string]$UserHome = $env:USERPROFILE)
    foreach ($i in @(Find-AntigravityInstall -ProgramsDir $ProgramsDir -UserHome $UserHome)) {
        [pscustomobject]@{
            Harness = 'antigravity'; Id = $i.Id; Name = $i.Name; IsDefault = $true; Kind = $i.Kind
            Exe = $i.Exe; DataDir = $i.DataDir; Pid = (Find-AgyMainProcessId -Exe $i.Exe)
        }
    }
}

# Running: bring its window forward ('focused'). Otherwise start the app as the user would: no env, no
# --user-data-dir ('started').
function Start-AntigravityProfile {
    param([Parameter(Mandatory)]$Profile)
    $hooks = Get-AgyHooks
    $procId = Find-AgyMainProcessId -Exe $Profile.Exe
    if ($procId -and (& $hooks.ShowWindow $procId)) { return 'focused' }
    & $hooks.StartProcess $Profile.Exe
    return 'started'
}

# One adapter for both apps. No NewProfile / RemoveProfile / Rename: sign-in is shared, so there is nothing to add
# (spike S4), and the UI hides "Add account" for a harness without NewProfile.
function Register-AntigravityHarness {
    Register-Harness -Name 'antigravity' -Adapter @{
        DisplayName      = 'Antigravity'
        Detect           = {
            $found = @(Find-AntigravityInstall)
            [pscustomobject]@{ Installed = [bool]$found.Count; Kind = (($found | ForEach-Object { $_.Kind }) -join ','); Exe = (($found | ForEach-Object { $_.Exe }) -join ';'); Version = (($found | ForEach-Object { $_.Version }) -join ',') }
        }
        GetProfiles      = { Get-AntigravityProfiles }
        Launch           = { param($Profile) Start-AntigravityProfile -Profile $Profile }
        ListChats        = { param($Profile) Get-AntigravityChats -Profile $Profile }
        Export           = { param($Chat, $OutPath) Export-AgyChat -Chat $Chat -OutPath $OutPath }
        ImportNative     = { param($BundlePath, $Profile) Import-AgyNative -BundlePath $BundlePath -Profile $Profile }
        ImportHandoff    = { param($BundlePath, $Profile) Start-AgyHandoff -BundlePath $BundlePath -Profile $Profile }
        ImportNeedsClose = { param($Profile) $true }
    }
}
