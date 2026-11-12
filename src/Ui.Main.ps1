# Ui.Main.ps1 - the main window as tabs (phase 5, lane V2): Claude, Codex, Antigravity and Drive. Convert-SwitcherToTabs
# moves the controls the old window already has into the Claude tab while the program runs, so ClaudeSwitcher.ps1 keeps all
# its own code; if anything goes wrong the old window is put back exactly as it was. The chat lists are in Ui.MainChats.ps1,
# the Drive tab in Ui.MainDrive.ps1. The functions without WinForms are tested without a window. ASCII only.

# ---- style and state -----------------------------------------------------------------------------------------------------

# The colours and fonts of ClaudeSwitcher.ps1 when they exist (the window is built from its script scope), plain defaults otherwise.
function Get-MainUiStyle {
    $pick = { param($v, $d) if ($null -ne $v) { $v } else { $d } }
    return @{
        Bg = (& $pick $bg ([System.Drawing.Color]::FromArgb(250, 249, 245))); Ink = (& $pick $ink ([System.Drawing.Color]::FromArgb(38, 38, 36)))
        Muted = (& $pick $muted ([System.Drawing.Color]::FromArgb(120, 118, 112))); Accent = (& $pick $accent ([System.Drawing.Color]::FromArgb(203, 123, 93)))
        Border = (& $pick $border ([System.Drawing.Color]::FromArgb(220, 217, 210)))
        Bold = (& $pick $fontBold (New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)))
        Title = (& $pick $fontTitle (New-Object System.Drawing.Font('Segoe UI Semibold', 14)))
    }
}

# Everything the window keeps between events: the form, the tab control, the panels, the cached picture of Drive.
function Get-MainState {
    if (-not $script:MainUiState) {
        $script:MainUiState = @{ Form = $null; Tabs = $null; Panels = @{}; Profiles = @{}; Drive = $null; Sync = $null; LocalChats = $null; Stale = @{}; Timers = @(); Installed = @{} }
    }
    return $script:MainUiState
}

# What Drive says, read once and reused until the next refresh: Ready (sync works on this machine), Catalog (rows), State
# (sync-state of this machine), Error. Never throws; a Drive that cannot be read is an Error and no catalog.
function Get-MainSync {
    $st = Get-MainState
    if (-not $st.Sync) { Update-MainCatalog }
    return $st.Sync
}

function Update-MainCatalog {
    $st = Get-MainState
    $sync = @{ Ready = $false; Catalog = $null; State = @{}; Error = $null; At = Get-Date }
    try {
        if (Test-SyncReady) {
            $sync.Ready = $true
            $s = Get-SyncSession
            $sync.Catalog = @(Get-SyncCatalog -Root $s.Root -Key $s.Key)
            $sync.State = Get-SyncState
        }
    } catch { $sync.Catalog = $null; $sync.Error = Get-SyncErrorMessage -Message $_.Exception.Message }
    $st.Sync = $sync
    $st.LocalChats = $null
}

# ---- tab bookkeeping (pure) ----------------------------------------------------------------------------------------------

function Get-MainTabKeys { return @('claude', 'codex', 'antigravity', 'drive') }

function Get-MainLastTab {
    $v = [string](Get-Setting 'Ui.LastTab')
    if ($v -in (Get-MainTabKeys)) { return $v }
    return 'claude'
}

function Set-MainLastTab {
    param([string]$Key)
    if ($Key -in (Get-MainTabKeys)) { Set-Setting 'Ui.LastTab' $Key }
}

# True when some chat on Drive waits for this machine: newer on Drive, or changed on both.
function Get-DriveTabBadge {
    param([string[]]$Statuses)
    return [bool]@($Statuses | Where-Object { $_ -in 'DriveNewer', 'Diverged' }).Count
}

function Get-DriveTabText {
    param([bool]$Badge)
    if ($Badge) { return ('Drive ' + [char]0x25CF) }
    return 'Drive'
}

function Update-MainTabBadge {
    $st = Get-MainState
    if (-not $st.Tabs) { return }
    $statuses = @(Get-MainDriveViews | ForEach-Object { $_.Status })
    $st.Tabs.TabPages['drive'].Text = Get-DriveTabText -Badge (Get-DriveTabBadge -Statuses $statuses)
}

# Redraws the tab that is open when its data is stale (after a refresh); other tabs wait until they are opened.
function Update-MainTab {
    param([string]$Key)
    $st = Get-MainState
    if (-not $st.Tabs) { return }
    if (-not $Key) { $Key = [string]$st.Tabs.SelectedTab.Name }
    if ($Key -eq 'drive') { if ($st.Drive) { Update-SyncDriveTab -Ctx $st.Drive } }
    elseif ($st.Panels.ContainsKey($Key)) {
        if ($st.Profiles.ContainsKey($Key)) { Update-HarnessProfilePanel -Ctx $st.Profiles[$Key] }
        Update-ChatPanel -Ctx $st.Panels[$Key] -Reload
    }
    $st.Stale[$Key] = $false
}

# Asks Drive again and redraws: the Refresh buttons and the end of a push or a pull.
function Invoke-MainRefresh {
    $st = Get-MainState
    Update-MainCatalog
    foreach ($k in Get-MainTabKeys) { $st.Stale[$k] = $true }
    try { Update-MainTab } catch { Write-HarnessLog "Main window: refresh failed: $($_.Exception.Message)" }
    try { Update-MainTabBadge } catch { Write-HarnessLog "Main window: tab badge failed: $($_.Exception.Message)" }
}

# ---- profiles of Codex and Antigravity ------------------------------------------------------------------------------------

# The buttons of a profile panel: Launch always; Add account and Shortcuts only when the adapter can do them.
function Get-ProfilePanelButtons {
    param([Parameter(Mandatory)]$Adapter)
    $names = @('Launch')
    if ($Adapter['NewProfile'] -is [scriptblock]) { $names += 'Add account' }
    if ($Adapter['NewShortcut'] -is [scriptblock]) { $names += 'Shortcuts' }
    return $names
}

function New-HarnessProfilePanel {
    param([Parameter(Mandatory)]$Harness)
    $s = Get-MainUiStyle
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Top'; $panel.Height = 190; $panel.BackColor = $s.Bg
    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false
    $list.BackColor = [System.Drawing.Color]::White; $list.ForeColor = $s.Ink
    $head = New-Object System.Windows.Forms.Label
    $head.Text = $(if ($Harness.Adapter['NewProfile'] -is [scriptblock]) { '{0} accounts' -f (Get-HarnessDisplayName $Harness) } else { Get-HarnessDisplayName $Harness })
    $head.Font = $s.Title; $head.ForeColor = $s.Ink; $head.AutoSize = $false
    $head.Location = New-Object System.Drawing.Point(8, 8); $head.Size = New-Object System.Drawing.Size(500, 28)
    $panel.Controls.Add($head)
    $list.Location = New-Object System.Drawing.Point(8, 44); $list.Size = New-Object System.Drawing.Size(860, 88); $list.Anchor = 'Top,Left,Right,Bottom'
    foreach ($c in @(@('Profile', 260), @('Status', 140), @('Account', 380))) { [void]$list.Columns.Add($c[0], $c[1]) }
    $panel.Controls.Add($list)
    $buttons = @{}
    $x = 8
    foreach ($n in (Get-ProfilePanelButtons -Adapter $Harness.Adapter)) {
        $b = New-MainButton -Text $n -X $x -Width 120; $b.Location = New-Object System.Drawing.Point($x, 144); $b.Anchor = 'Left,Bottom'; $b.Tag = $n
        $panel.Controls.Add($b); $buttons[$n] = $b; $x += 128
    }
    $ctx = @{ Harness = $Harness; Panel = $panel; List = $list; Buttons = $buttons }
    $list.Add_DoubleClick({ Invoke-HarnessProfileAction -Ctx $ctx -Name 'Launch' }.GetNewClosure())
    foreach ($n in $buttons.Keys) { $buttons[$n].Add_Click({ Invoke-HarnessProfileAction -Ctx $ctx -Name $this.Tag }.GetNewClosure()) }
    return $ctx
}

function Get-HarnessProfileSelection {
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.List.SelectedItems.Count -eq 0) { return $null }
    return $Ctx.List.SelectedItems[0].Tag
}

function Update-HarnessProfilePanel {
    param([Parameter(Mandatory)]$Ctx)
    $s = Get-MainUiStyle
    $keep = $(if ($Ctx.List.SelectedItems.Count) { [string]$Ctx.List.SelectedItems[0].Tag.Id } else { '' })
    $profiles = @(); try { $profiles = @(& $Ctx.Harness.Adapter.GetProfiles) } catch { Write-HarnessLog "Main window: could not list $($Ctx.Harness.Name) profiles: $($_.Exception.Message)" }
    $Ctx.List.BeginUpdate(); $Ctx.List.Items.Clear()
    foreach ($p in $profiles) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$p.Name)
        $it.UseItemStyleForSubItems = $false; $it.Tag = $p
        [void]$it.SubItems.Add($(if ($p.Pid) { 'Running' } else { 'Not running' }))
        $it.SubItems[1].ForeColor = $(if ($p.Pid) { [System.Drawing.Color]::FromArgb(46, 125, 74) } else { $s.Muted })
        [void]$it.SubItems.Add($(if ($p.PSObject.Properties['Account'] -and $p.Account) { [string]$p.Account } else { '' }))
        [void]$Ctx.List.Items.Add($it)
        if ($keep -and [string]$p.Id -eq $keep) { $it.Selected = $true }
    }
    if (-not $Ctx.List.SelectedItems.Count -and $Ctx.List.Items.Count) { $Ctx.List.Items[0].Selected = $true }
    $Ctx.List.EndUpdate()
}

function Invoke-HarnessProfileAction {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    $p = Get-HarnessProfileSelection -Ctx $Ctx
    switch ($Name) {
        'Launch'      { if ($p) { Invoke-HarnessTrayLaunch -Harness $Ctx.Harness -Profile $p } }
        'Add account' { Invoke-HarnessTrayAddAccount -Harness $Ctx.Harness; Update-HarnessProfilePanel -Ctx $Ctx }
        'Shortcuts'   { if ($p) { Invoke-HarnessTrayShortcut -Harness $Ctx.Harness -Profile $p } }
    }
}

# ---- the window ----------------------------------------------------------------------------------------------------------

# Calls the action 250 ms after the last call: a list that is rebuilt raises its selection event many times in a row.
function New-MainDebounce {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 250
    $t.Add_Tick({ $t.Stop(); try { & $Action } catch { Write-HarnessLog "Main window: $($_.Exception.Message)" } }.GetNewClosure())
    (Get-MainState).Timers += $t
    return { $t.Stop(); $t.Start() }.GetNewClosure()
}

function New-MainTabPage {
    param([string]$Key, [string]$Text)
    $s = Get-MainUiStyle
    $p = New-Object System.Windows.Forms.TabPage
    $p.Name = $Key; $p.Text = $Text; $p.BackColor = $s.Bg; $p.Padding = New-Object System.Windows.Forms.Padding(0)
    return $p
}

# Fills the Codex or Antigravity tab: profiles on top, chats below, or a note when the harness is not installed.
function Add-HarnessTabContent {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$Page)
    $st = Get-MainState
    $h = Get-Harness -Name $Key
    if (-not $h) { $h = [pscustomobject]@{ Name = $Key; Adapter = @{} } }
    $st.Installed[$Key] = [bool]($h.Adapter['Detect'] -and (Test-HarnessInstalled $h))
    if (-not $st.Installed[$Key]) { $Page.Controls.Add((New-HarnessMissingNote -Harness $h)); return }
    $profiles = New-HarnessProfilePanel -Harness $h
    $getProfile = { Get-HarnessProfileSelection -Ctx $profiles }.GetNewClosure()
    $chats = New-HarnessChatPanel -Harness $h -GetProfile $getProfile
    $Page.Controls.Add($chats.Panel); $Page.Controls.Add($profiles.Panel)
    $st.Panels[$Key] = $chats; $st.Profiles[$Key] = $profiles
    $reload = New-MainDebounce -Action { if ((& $getProfile) -and [string](& $getProfile).Id -ne [string]$chats.Profile.Id) { Update-ChatPanel -Ctx $chats -Reload } }.GetNewClosure()
    $profiles.List.Add_SelectedIndexChanged($reload)
}

# Puts the old window's controls on a panel as tall as its client area and the chat list of the selected Claude profile under
# them. $RefreshClaude is the old window's own list refresh. Throws; Convert-SwitcherToTabs catches and restores.
function Add-ClaudeTabContent {
    param([Parameter(Mandatory)]$Form, [Parameter(Mandatory)]$Page, [Parameter(Mandatory)][array]$Controls, [Parameter(Mandatory)]$Client)
    $st = Get-MainState
    $legacy = New-Object System.Windows.Forms.Panel
    $legacy.Name = 'switcherLegacy'; $legacy.Size = $Client; $legacy.BackColor = $Form.BackColor
    foreach ($c in $Controls) { $legacy.Controls.Add($c) }
    $legacy.Dock = 'Top'
    $h = Get-Harness -Name 'claude'
    if (-not $h) { throw 'The Claude harness is not registered.' }
    $lv = $Controls | Where-Object { $_ -is [System.Windows.Forms.ListView] } | Select-Object -First 1
    $getProfile = { if ($lv -and $lv.SelectedItems.Count) { $lv.SelectedItems[0].Tag } else { $null } }.GetNewClosure()
    $chats = New-HarnessChatPanel -Harness $h -GetProfile $getProfile
    $Page.Controls.Add($chats.Panel); $Page.Controls.Add($legacy)
    $st.Panels['claude'] = $chats
    if ($lv) {
        $reload = New-MainDebounce -Action { if ((& $getProfile) -and [string](& $getProfile).Id -ne [string]$chats.Profile.Id) { Update-ChatPanel -Ctx $chats -Reload } }.GetNewClosure()
        $lv.Add_SelectedIndexChanged($reload)
    }
}

# Puts the form back as it was: the old controls in their old order on the form, the old size, no tabs.
function Restore-SwitcherForm {
    param([Parameter(Mandatory)]$Form, [Parameter(Mandatory)]$Snapshot)
    foreach ($c in @($Form.Controls)) { if ($Snapshot.Controls -notcontains $c) { $Form.Controls.Remove($c); $c.Dispose() } }
    foreach ($c in $Snapshot.Controls) {
        if ($c.Parent -ne $Form) { if ($c.Parent) { $c.Parent.Controls.Remove($c) }; $Form.Controls.Add($c) }
    }
    for ($i = 0; $i -lt $Snapshot.Controls.Count; $i++) { $Form.Controls.SetChildIndex($Snapshot.Controls[$i], $i) }
    $Form.MinimumSize = $Snapshot.Min; $Form.Size = $Snapshot.Size; $Form.Text = $Snapshot.Text
}

# The hook of ClaudeSwitcher.ps1 (harness-ui-main). Without this function, or when it fails, the old window stays as it was.
function Convert-SwitcherToTabs {
    param([Parameter(Mandatory)]$Form, [scriptblock]$RefreshClaude)
    $snap = @{ Controls = @($Form.Controls | ForEach-Object { $_ }); Size = $Form.Size; Min = $Form.MinimumSize; Client = $Form.ClientSize; Text = $Form.Text }
    $script:MainUiState = $null
    try {
        $st = Get-MainState
        $st.Form = $Form
        $Form.Text = 'Profile Switcher'
        $Form.SuspendLayout()
        $tabs = New-Object System.Windows.Forms.TabControl
        $tabs.Dock = 'Fill'; $tabs.Name = 'mainTabs'
        $pages = @{}
        foreach ($k in Get-MainTabKeys) { $pages[$k] = New-MainTabPage -Key $k -Text $(if ($k -eq 'drive') { 'Drive' } else { $k.Substring(0, 1).ToUpperInvariant() + $k.Substring(1) }) }
        Add-ClaudeTabContent -Form $Form -Page $pages['claude'] -Controls $snap.Controls -Client $snap.Client
        foreach ($k in 'codex', 'antigravity') { Add-HarnessTabContent -Key $k -Page $pages[$k] }
        $st.Drive = New-SyncDriveTab
        $pages['drive'].Controls.Add($st.Drive.Panel)
        foreach ($k in Get-MainTabKeys) { [void]$tabs.TabPages.Add($pages[$k]) }
        $st.Tabs = $tabs
        $Form.Controls.Add($tabs)
        $Form.MinimumSize = New-Object System.Drawing.Size(820, 620)
        $Form.Size = New-Object System.Drawing.Size([Math]::Max(900, $snap.Size.Width), [Math]::Max(820, $snap.Size.Height))
        $last = Get-MainLastTab
        $tabs.SelectedTab = $pages[$last]
        $tabs.Add_SelectedIndexChanged({
            Set-MainLastTab -Key $tabs.SelectedTab.Name
            if ($RefreshClaude -and $tabs.SelectedTab.Name -eq 'claude') { & $RefreshClaude }
            $age = $(if ((Get-MainState).Sync) { ((Get-Date) - (Get-MainState).Sync.At).TotalSeconds } else { 9999 })
            if ($age -gt 30) { Invoke-MainRefresh } else { Update-MainTab }
        }.GetNewClosure())
        $boot = New-Object System.Windows.Forms.Timer
        $boot.Interval = 300
        $boot.Add_Tick({ $boot.Stop(); try { Invoke-MainRefresh } catch { Write-HarnessLog "Main window: first load failed: $($_.Exception.Message)" } }.GetNewClosure())
        $st.Timers += $boot
        $Form.Add_Shown({ $boot.Start() }.GetNewClosure())
        $Form.ResumeLayout($true)
    } catch {
        try { Write-HarnessLog "Tabbed main window failed, the old window stays: $($_.Exception.Message)" } catch { }
        try { Restore-SwitcherForm -Form $Form -Snapshot $snap } catch { }
        try { $Form.ResumeLayout($true) } catch { }
        foreach ($t in @((Get-MainState).Timers)) { try { $t.Dispose() } catch { } }
        $script:MainUiState = $null
    }
}

# Shows the window on the tab of a harness (claude, codex, antigravity or drive; none keeps the last tab) and selects a chat.
function Show-SwitcherTab {
    param([string]$Harness = '', [string]$ChatId = '')
    if (Get-Command Show-Switcher -ErrorAction SilentlyContinue) { Show-Switcher }
    $st = Get-MainState
    if (-not $st.Tabs) { return }
    $key = $(if ($Harness -in (Get-MainTabKeys)) { $Harness } else { Get-MainLastTab })
    $st.Tabs.SelectedTab = $st.Tabs.TabPages[$key]
    Update-MainTab -Key $key
    if ($ChatId -and $st.Panels.ContainsKey($key)) {
        foreach ($it in $st.Panels[$key].List.Items) { if ([string]$it.Tag.Chat.ChatId -eq $ChatId) { $it.Selected = $true; $it.EnsureVisible() } }
    }
}
