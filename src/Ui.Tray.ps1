# Ui.Tray.ps1 - tray menu items and -Launch <harness>:<id> for every registered harness except claude (the
# Claude tray stays as it was). Add-HarnessTrayItems is called from the harness-ui-tray hook each time the
# tray menu opens; Invoke-HarnessLaunchArg from the harness-launch hook. Uses Show-Message, Show-Prompt,
# Get-ShortcutDirs and $fontBold from ClaudeSwitcher.ps1. The Invoke-* helpers hold the logic, so the click
# handlers stay one line. Optional adapter keys used here: DisplayName, NewProfile, NewShortcut, ResolveProfile.
# ASCII only.

function Get-HarnessDisplayName {
    param([Parameter(Mandatory)]$Harness)
    if ($Harness.Adapter['DisplayName']) { return [string]$Harness.Adapter['DisplayName'] }
    return ($Harness.Name.Substring(0, 1).ToUpperInvariant() + $Harness.Name.Substring(1))
}

function Invoke-HarnessTrayLaunch {
    param([Parameter(Mandatory)]$Harness, [Parameter(Mandatory)]$Profile)
    try { [void](& $Harness.Adapter.Launch $Profile) }
    catch { Show-Message "Could not open $(Get-HarnessDisplayName $Harness) '$($Profile.Name)': $($_.Exception.Message)" (Get-HarnessDisplayName $Harness) 'OK' 'Error' | Out-Null }
}

# Asks for a name, then runs the adapter's NewProfile (which may sign in and open the app). The tray waits
# while that runs. NewProfile may return 'busy' or 'cancelled'; anything else counts as success.
function Invoke-HarnessTrayAddAccount {
    param([Parameter(Mandatory)]$Harness)
    $label = Get-HarnessDisplayName $Harness
    $answer = Show-Prompt -Message "Name for the new $label account:" -Title "Add $label account" -OkText 'Next'
    if (-not $answer) { return }
    Show-Message "Follow the sign-in steps that open next, then come back here.`r`nThe tray stays busy until the sign-in ends." "Add $label account" | Out-Null
    try {
        $state = & $Harness.Adapter.NewProfile $answer.Text
        if ($state -eq 'busy') { Show-Message "Another $label sign-in is already running. Finish it first." "Add $label account" 'OK' 'Warning' | Out-Null }
        elseif ($state -eq 'cancelled') { Show-Message 'The sign-in did not finish, so no account was added.' "Add $label account" | Out-Null }
    } catch { Show-Message "Could not add the account: $($_.Exception.Message)" "Add $label account" 'OK' 'Error' | Out-Null }
}

function Invoke-HarnessTrayShortcut {
    param([Parameter(Mandatory)]$Harness, [Parameter(Mandatory)]$Profile)
    $label = Get-HarnessDisplayName $Harness
    try {
        foreach ($dir in (Get-ShortcutDirs)) { [void](& $Harness.Adapter.NewShortcut $Profile $dir) }
        Show-Message "Added shortcuts for $label '$($Profile.Name)' on the Desktop and in the Start menu." $label | Out-Null
    } catch { Show-Message "Could not add the shortcut: $($_.Exception.Message)" $label 'OK' 'Error' | Out-Null }
}

function New-HarnessTrayItem {
    param([string]$Text, $Tag, [scriptblock]$OnClick)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    if ($null -ne $Tag) { $mi.Tag = $Tag }
    if ($OnClick) { $mi.Add_Click($OnClick) }
    return $mi
}

# One submenu per registered harness except claude: its profiles (bold and marked "open" while running),
# "Add <name> account..." only when the adapter has NewProfile, and "Add shortcut" only when it has NewShortcut.
# A harness that is not installed adds nothing; one that fails shows a disabled "(error)" item instead.
function Add-HarnessTrayItems {
    param([Parameter(Mandatory)]$Menu)
    foreach ($h in @(Get-Harnesses | Where-Object { $_.Name -ne 'claude' })) {
        $label = Get-HarnessDisplayName $h
        try {
            if (-not (& $h.Adapter.Detect).Installed) { continue }
            $profiles = @(& $h.Adapter.GetProfiles)
            $root = New-HarnessTrayItem -Text $label
            foreach ($p in $profiles) {
                $mi = New-HarnessTrayItem -Text $p.Name -Tag @{ Harness = $h; Profile = $p } -OnClick { Invoke-HarnessTrayLaunch -Harness $this.Tag.Harness -Profile $this.Tag.Profile }
                if ($p.Pid) { $mi.Font = $fontBold; $mi.ShortcutKeyDisplayString = 'open' }
                [void]$root.DropDownItems.Add($mi)
            }
            if ($h.Adapter['NewProfile'] -is [scriptblock]) {
                [void]$root.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
                [void]$root.DropDownItems.Add((New-HarnessTrayItem -Text "Add $label account..." -Tag $h -OnClick { Invoke-HarnessTrayAddAccount -Harness $this.Tag }))
            }
            if ($h.Adapter['NewShortcut'] -is [scriptblock]) {
                $sc = New-HarnessTrayItem -Text 'Add shortcut'
                foreach ($p in $profiles) {
                    [void]$sc.DropDownItems.Add((New-HarnessTrayItem -Text $p.Name -Tag @{ Harness = $h; Profile = $p } -OnClick { Invoke-HarnessTrayShortcut -Harness $this.Tag.Harness -Profile $this.Tag.Profile }))
                }
                [void]$root.DropDownItems.Add($sc)
            }
            [void]$Menu.Items.Add($root)
        } catch {
            $bad = New-HarnessTrayItem -Text "$label (error)"
            $bad.Enabled = $false
            [void]$Menu.Items.Add($bad)
        }
    }
}

# -Launch <harness>:<id>. Returns $false when the value is not for a registered non-Claude harness (the caller
# then treats it as a Claude profile name); otherwise launches the profile and returns $true, or throws with the
# profile list when there is no such profile. An adapter may offer ResolveProfile to find profiles its list hides.
function Invoke-HarnessLaunchArg {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -cnotmatch '^(?<h>[a-z]+):(?<id>.+)$') { return $false }
    $h = Get-Harness -Name $Matches['h']
    if (-not $h -or $h.Name -eq 'claude') { return $false }
    $id = $Matches['id']
    $target = $null
    if ($h.Adapter['ResolveProfile'] -is [scriptblock]) { $target = & $h.Adapter.ResolveProfile $id }
    else { $target = @(& $h.Adapter.GetProfiles) | Where-Object { $_.Id -ieq $id -or $_.Name -ieq $id } | Select-Object -First 1 }
    if (-not $target) {
        $known = (@(& $h.Adapter.GetProfiles) | ForEach-Object { $_.Name }) -join ', '
        throw "There is no $(Get-HarnessDisplayName $h) profile called '$id'.`r`n`r`nProfiles: $known"
    }
    [void](& $h.Adapter.Launch $target)
    return $true
}
