# Ui.MainDrive.ps1 - the Drive tab of the main window (phase 5, lane V2): the state card, the chats on Drive, the folder
# roots of this machine. The functions at the top are plain logic (tested without a window); New-SyncDriveTab and the
# handlers are WinForms. Needs Ui.ChatStatus, Ui.Main, Ui.MainChats, Ui.Sync, Ui.Harness and Harness.Sync.*. ASCII only.

# ---- logic ----------------------------------------------------------------------------------------------------------------

function Get-DriveStatusText {
    param([string]$Status)
    switch ($Status) {
        'UpToDate'   { return 'Up to date' }
        'LocalNewer' { return 'Changed here, not pushed' }
        'DriveNewer' { return 'Newer on Drive' }
        'Diverged'   { return 'Changed on both' }
        default      { return 'Not here' }
    }
}

# { param($row) -> the local chat this Drive row belongs to, or $null }. LocalChats are @{ Harness; Chat } entries (the chat
# carries its Profile). The state says which local chat a row was last synced with; without it the chat id in the key counts.
function New-MainChatLookup {
    param([array]$LocalChats, $State)
    return {
        param($row)
        $key = [string]$row.chatKey
        $entry = $null
        if ($State -is [System.Collections.IDictionary] -and $State.Contains($key)) { $entry = $State[$key] }
        $id = $(if ($entry -and $entry.localChatId) { [string]$entry.localChatId } else { $key.Substring($key.IndexOf(':') + 1) })
        $hits = @($LocalChats | Where-Object { $_ -and [string]$_.Harness -eq [string]$row.harness -and [string]$_.Chat.ChatId -eq $id })
        $mine = @($hits | Where-Object { $entry -and $entry.profileId -and [string]$_.Chat.Profile.Id -eq [string]$entry.profileId }) | Select-Object -First 1
        if ($mine) { return $mine.Chat }
        return ($hits | Select-Object -First 1 | ForEach-Object { $_.Chat })
    }.GetNewClosure()
}

# One view per Drive row for the catalog list. -NeedsActionOnly keeps the rows that wait for the user: newer on Drive and
# changed on both machines.
function Get-DriveCatalogRows {
    param([array]$Rows, $State, [Parameter(Mandatory)][scriptblock]$LocalChatLookup, [switch]$NeedsActionOnly)
    $views = foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $st = Get-SyncCatalogRowStatus -Row $r -State $State -LocalChatLookup $LocalChatLookup
        # Same bundle as the last sync but the chat moved on since: the chat list calls that "changed here".
        if ($st -eq 'UpToDate') {
            $chat = & $LocalChatLookup $r
            if (-not (Test-ChatUnchangedSinceSync -Chat $chat -Entry (Get-ChatSyncStateEntry -State $State -ChatKey ([string]$r.chatKey) -Chat $chat))) { $st = 'LocalNewer' }
        }
        if ($NeedsActionOnly -and $st -notin 'DriveNewer', 'Diverged') { continue }
        $name = [string]$r.harness
        [pscustomobject]@{
            Row = $r; Status = $st; StatusText = (Get-DriveStatusText $st); Title = [string]$r.Title
            HarnessText = $(if ($name) { $name.Substring(0, 1).ToUpperInvariant() + $name.Substring(1) } else { '' })
            From = [string]$r.MachineName; When = (Format-SyncWhen $r.lastActivityAt); Activity = (ConvertTo-MainUnixMs $r.lastActivityAt)
        }
    }
    return @($views)
}

# Search by title and limit to one harness (All | Claude | Codex | Antigravity); order is kept.
function Select-DriveViews {
    param([array]$Views, [string]$Text = '', [string]$Harness = 'All')
    return @(@($Views) | Where-Object {
        $null -ne $_ -and (-not $Text -or $_.Title.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and ($Harness -eq 'All' -or [string]$_.HarnessText -eq $Harness)
    })
}

# Column is Title | Harness | From | Last active | On this machine. Text sorts ignore case, Last active sorts by the number, the
# last column by how much attention a row needs (ascending: most urgent first). Equal rows keep their order.
function Sort-DriveViews {
    param([array]$Views, [string]$Column = 'Last active', [bool]$Descending = $true)
    $rank = @{ Diverged = 0; DriveNewer = 1; LocalNewer = 2; NotHere = 3; UpToDate = 4 }
    $key = switch ($Column) {
        'Title'   { { param($v) $v.Title.ToLowerInvariant() } }
        'Harness' { { param($v) $v.HarnessText.ToLowerInvariant() } }
        'From'    { { param($v) $v.From.ToLowerInvariant() } }
        'On this machine' { { param($v) $rank[[string]$v.Status] }.GetNewClosure() }
        default   { { param($v) [double]$v.Activity } }
    }
    return (Sort-MainRows -Rows $Views -Key $key -Descending $Descending)
}

# The profile "Pull to..." offers first: the one that received this chat before, else the Default profile of the row's
# harness, else any profile of that harness, else the first profile there is.
function Get-DefaultPullTarget {
    param([Parameter(Mandatory)]$Row, $State, [array]$Targets)
    $key = [string]$Row.chatKey
    $entry = $(if ($State -is [System.Collections.IDictionary] -and $State.Contains($key)) { $State[$key] } else { $null })
    $same = @($Targets | Where-Object { [string]$_.Harness -eq [string]$Row.harness })
    if ($entry -and $entry.profileId) { $hit = $same | Where-Object { [string]$_.Id -eq [string]$entry.profileId } | Select-Object -First 1; if ($hit) { return $hit } }
    $default = $same | Where-Object { $_.IsDefault -or $_.Id -eq 'Default' } | Select-Object -First 1
    if ($default) { return $default }
    if ($same.Count) { return $same[0] }
    return ($Targets | Select-Object -First 1)
}

# Reads every chat of every installed harness and profile: the one slow read of the Drive tab, done only when its Refresh is
# pressed. Get-MainLocalChats then hands back what was read (nothing before that).
function Read-MainLocalChats {
    $st = Get-MainState
    $list = New-Object Collections.Generic.List[object]
    foreach ($h in @(Get-Harnesses)) {
        if (-not (Test-HarnessInstalled $h)) { continue }
        try {
            foreach ($p in @(& $h.Adapter.GetProfiles)) {
                foreach ($c in @(& $h.Adapter.ListChats $p)) {
                    if (-not $c) { continue }
                    $copy = $c.PSObject.Copy()
                    if (-not $copy.PSObject.Properties['Profile']) { $copy | Add-Member -NotePropertyName Profile -NotePropertyValue $p }
                    $list.Add([pscustomobject]@{ Harness = $h.Name; Chat = $copy })
                }
            }
        } catch { Write-HarnessLog "Drive tab: could not list the chats of $($h.Name): $($_.Exception.Message)" }
    }
    $st.LocalChats = $list.ToArray()
}

function Get-MainLocalChats {
    $st = Get-MainState
    return $(if ($null -ne $st.LocalChats) { $st.LocalChats } else { @() })
}

# The statuses of every Drive row against the chats this machine had when the Drive tab was last refreshed: the badge of the
# tab and the list share it. Nothing until then.
function Get-MainDriveViews {
    param([switch]$NeedsActionOnly)
    $sync = Get-MainSync
    if (-not $sync.Ready -or $null -eq $sync.Catalog -or $null -eq (Get-MainState).LocalChats) { return @() }
    $lookup = New-MainChatLookup -LocalChats (Get-MainLocalChats) -State $sync.State
    return @(Get-DriveCatalogRows -Rows $sync.Catalog -State $sync.State -LocalChatLookup $lookup -NeedsActionOnly:$NeedsActionOnly)
}

function Remove-MainPathRoot {
    param([Parameter(Mandatory)][string]$Name)
    $roots = Get-SyncPathRoots
    if ($roots.ContainsKey($Name)) { $roots.Remove($Name); Set-SyncSetting 'PathRoots' $roots }
}

# ---- the tab -----------------------------------------------------------------------------------------------------------

function New-DriveList {
    param([Parameter(Mandatory)][array]$Columns)
    $s = Get-MainUiStyle
    $l = New-Object System.Windows.Forms.ListView
    $l.View = 'Details'; $l.FullRowSelect = $true; $l.MultiSelect = $false; $l.HideSelection = $false
    $l.BackColor = [System.Drawing.Color]::White; $l.ForeColor = $s.Ink
    foreach ($c in $Columns) { [void]$l.Columns.Add($c[0], $c[1]) }
    return $l
}

function New-DriveLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20, [bool]$Bold = $false)
    $s = Get-MainUiStyle
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H); $l.ForeColor = $s.Ink
    if ($Bold) { $l.Font = $s.Bold }
    return $l
}

# Builds the Drive tab's content and returns its context (Panel is the control to place on the tab page).
function New-SyncDriveTab {
    $s = Get-MainUiStyle
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.BackColor = $s.Bg

    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = 'Top'; $card.Height = 92; $card.BackColor = [System.Drawing.Color]::White
    $cardHead = New-DriveLabel 'Drive sync' 12 8 500 22 $true
    $cardLine1 = New-DriveLabel '' 12 34 640 20
    $cardLine2 = New-DriveLabel '' 12 56 520 20
    $cardLine2.ForeColor = $s.Muted
    $btnRefresh = New-MainButton -Text 'Refresh' -X 660 -Width 96; $btnRefresh.Location = New-Object System.Drawing.Point(660, 54); $btnRefresh.Anchor = 'Top,Left'
    $btnSettings = New-MainButton -Text 'Settings' -X 764 -Width 96; $btnSettings.Location = New-Object System.Drawing.Point(764, 54); $btnSettings.Anchor = 'Top,Left'
    $btnSetup = New-MainButton -Text 'Set up Drive sync...' -X 12 -Width 170; $btnSetup.Location = New-Object System.Drawing.Point(12, 54); $btnSetup.BackColor = $s.Accent; $btnSetup.ForeColor = [System.Drawing.Color]::White
    foreach ($c in $cardHead, $cardLine1, $cardLine2, $btnRefresh, $btnSettings, $btnSetup) { $card.Controls.Add($c) }
    Set-MainRightEdge -Control $btnSettings -Margin 12; Set-MainRightEdge -Control $btnRefresh -Margin 116

    $roots = New-Object System.Windows.Forms.Panel
    $roots.Dock = 'Bottom'; $roots.Height = 170
    $rootsHead = New-DriveLabel 'Folder roots (where project folders live on this machine)' 12 6 560 20 $true
    $rootList = New-DriveList @(@('Name', 160), @('Path on this machine', 480))
    $rootList.Location = New-Object System.Drawing.Point(12, 30); $rootList.Size = New-Object System.Drawing.Size(640, 126); $rootList.Anchor = 'Top,Left'
    $btnAdd = New-MainButton -Text 'Add' -X 664 -Width 90; $btnAdd.Location = New-Object System.Drawing.Point(664, 30)
    $btnChange = New-MainButton -Text 'Change' -X 664 -Width 90; $btnChange.Location = New-Object System.Drawing.Point(664, 66)
    $btnRemove = New-MainButton -Text 'Remove' -X 664 -Width 90; $btnRemove.Location = New-Object System.Drawing.Point(664, 102)
    foreach ($c in $rootsHead, $rootList, $btnAdd, $btnChange, $btnRemove) { $roots.Controls.Add($c) }
    foreach ($c in $btnAdd, $btnChange, $btnRemove) { Set-MainRightEdge -Control $c -Margin 12 }
    Set-MainRightEdge -Control $rootList -Margin 114 -Stretch

    $mid = New-Object System.Windows.Forms.Panel
    $mid.Dock = 'Fill'
    $viewForColumns = Get-MainViewSetting -Name 'Ui.DriveView' -Kind 'drive'
    $cols = foreach ($c in @(@('Title', 280), @('Harness', 100), @('From', 110), @('Last active', 90), @('On this machine', 150))) {
        , @((Get-ChatColumnHeader -Name $c[0] -SortColumn $viewForColumns.sortColumn -Descending $viewForColumns.descending), $c[1])
    }
    $list = New-DriveList @($cols)
    $list.Dock = 'Fill'; $list.SmallImageList = (New-ChatStatusImages)
    $mid.Controls.Add($list)
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Bottom'; $status.Height = 24; $status.ForeColor = $s.Muted; $status.Padding = New-Object System.Windows.Forms.Padding(8, 4, 0, 0)
    $mid.Controls.Add($status)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 42
    $btnPull = New-MainButton -Text 'Pull to...' -X 8 -Width 110; $btnPull.Enabled = $false
    $bar.Controls.Add($btnPull)
    $mid.Controls.Add($bar)
    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = 32
    $head.Controls.Add((New-DriveLabel 'Chats on Drive' 8 6 200 20 $true))
    $view = Get-MainViewSetting -Name 'Ui.DriveView' -Kind 'drive'
    $rbAll = New-Object System.Windows.Forms.RadioButton; $rbAll.Text = 'All'; $rbAll.Checked = ($view.show -ne 'NeedsAction'); $rbAll.Location = New-Object System.Drawing.Point(130, 4); $rbAll.Size = New-Object System.Drawing.Size(50, 24)
    $rbNeed = New-Object System.Windows.Forms.RadioButton; $rbNeed.Text = 'Needs action'; $rbNeed.Checked = ($view.show -eq 'NeedsAction'); $rbNeed.Location = New-Object System.Drawing.Point(184, 4); $rbNeed.Size = New-Object System.Drawing.Size(116, 24)
    $hLabel = New-DriveLabel 'Harness:' 312 7 62 20; $hLabel.ForeColor = $s.Muted
    $hBox = New-Object System.Windows.Forms.ComboBox
    $hBox.DropDownStyle = 'DropDownList'; $hBox.Location = New-Object System.Drawing.Point(376, 4); $hBox.Size = New-Object System.Drawing.Size(116, 24)
    foreach ($n in 'All', 'Claude', 'Codex', 'Antigravity') { [void]$hBox.Items.Add($n) }
    $hBox.SelectedItem = $view.harness
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location = New-Object System.Drawing.Point(560, 4); $search.Size = New-Object System.Drawing.Size(220, 24); $search.Anchor = 'Top,Left'
    foreach ($c in $rbAll, $rbNeed, $hLabel, $hBox, $search) { $head.Controls.Add($c) }
    Set-MainRightEdge -Control $search -Margin 12
    $mid.Controls.Add($head)
    $panel.Controls.Add($mid); $panel.Controls.Add($roots); $panel.Controls.Add($card)

    $ctx = @{ Panel = $panel; Status = $status; Card = $card; CardLine1 = $cardLine1; CardLine2 = $cardLine2; Refresh = $btnRefresh; Settings = $btnSettings; Setup = $btnSetup
              List = $list; Pull = $btnPull; All = $rbAll; Need = $rbNeed; HarnessBox = $hBox; Search = $search; View = $viewForColumns; CardAt = $null
              RootList = $rootList; Add = $btnAdd; Change = $btnChange; Remove = $btnRemove; Views = @(); Busy = $false }
    $btnRefresh.Add_Click({ Use-ChatPanelBusy -Ctx $ctx -Block { Invoke-MainRefresh -Tab 'drive' } }.GetNewClosure())
    # After the wizard only the catalog is read; the chats of this machine are read by Refresh.
    foreach ($b in $btnSettings, $btnSetup) { $b.Add_Click({ try { [void](Show-SyncSetupWizard) } catch { Show-ChatPanelResult -Ctx $ctx -Result @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message) } }; Update-MainCatalog; Update-SyncDriveTab -Ctx $ctx }.GetNewClosure()) }
    $list.Add_SelectedIndexChanged({ $ctx.Pull.Enabled = [bool]$ctx.List.SelectedItems.Count }.GetNewClosure())
    $list.Add_ColumnClick({ Set-DriveTabSort -Ctx $ctx -Index $_.Column }.GetNewClosure())
    $rbNeed.Add_CheckedChanged({ $ctx.View.show = $(if ($ctx.Need.Checked) { 'NeedsAction' } else { 'All' }); Set-MainViewSetting -Name 'Ui.DriveView' -View $ctx.View; Update-SyncDriveTab -Ctx $ctx }.GetNewClosure())
    $hBox.Add_SelectedIndexChanged({ if ($ctx.HarnessBox.SelectedItem -and $ctx.HarnessBox.SelectedItem -ne $ctx.View.harness) { $ctx.View.harness = [string]$ctx.HarnessBox.SelectedItem; Set-MainViewSetting -Name 'Ui.DriveView' -View $ctx.View; Update-SyncDriveTab -Ctx $ctx } }.GetNewClosure())
    $search.Add_TextChanged({ Update-SyncDriveTab -Ctx $ctx }.GetNewClosure())
    $btnPull.Add_Click({ Show-DrivePullMenu -Ctx $ctx }.GetNewClosure())
    $rootList.Add_SelectedIndexChanged({ $on = [bool]$ctx.RootList.SelectedItems.Count; $ctx.Change.Enabled = $on; $ctx.Remove.Enabled = $on }.GetNewClosure())
    foreach ($b in $btnAdd, $btnChange, $btnRemove) { $b.Add_Click({ Invoke-DriveRootAction -Ctx $ctx -Name $this.Text }.GetNewClosure()) }
    return $ctx
}

function Get-DriveCardLines {
    $sync = Get-MainSync
    if (-not $sync.Loaded) { return @('Nothing is read until you press Refresh.', 'Refresh reads the Drive folder and the chats of every profile on this machine.') }
    if (-not $sync.Ready) { return @('Chats are encrypted on this computer and kept in a folder on your Google Drive.', 'Other computers with the same passphrase can then pull them.') }
    $label = ''
    try {
        $r = Resolve-SyncRoot
        $tok = [string](Get-SyncSetting 'DriveAccountToken')
        if ($tok) { $a = @(Get-DriveFsAccounts | Where-Object { $_.Token -eq $tok }) | Select-Object -First 1; if ($a -and $a.Label) { $label = [string]$a.Label } }
        $folder = $(if ($r.Path) { Split-Path $r.Path -Leaf } else { '' })
    } catch { $folder = '' }
    $where = $(if ($label) { "Google Drive: $label" } else { 'Sync folder' })
    return @(('{0}    Folder: {1}    This machine: {2}' -f $where, $folder, $env:COMPUTERNAME), ('Key: remembered on this machine    Last refresh: {0}' -f (Get-Date -Format 'HH:mm')))
}

function Update-SyncDriveTab {
    param([Parameter(Mandatory)]$Ctx)
    $sync = Get-MainSync
    # The card is worked out once per read of Drive (it asks the registry about the account label), not at every draw.
    if ($Ctx.CardAt -ne $sync.At -or -not $Ctx.CardLines) { $Ctx.CardLines = @(Get-DriveCardLines); $Ctx.CardAt = $sync.At }
    $Ctx.CardLine1.Text = $Ctx.CardLines[0]; $Ctx.CardLine2.Text = $Ctx.CardLines[1]
    $showSetup = [bool]($sync.Loaded -and -not $sync.Ready)
    $Ctx.Setup.Visible = $showSetup; $Ctx.Refresh.Visible = -not $showSetup; $Ctx.Settings.Visible = [bool]($sync.Loaded -and $sync.Ready)
    $all = @(Get-MainDriveViews -NeedsActionOnly:$Ctx.Need.Checked)
    $Ctx.Views = @(Sort-DriveViews -Views (Select-DriveViews -Views $all -Text $Ctx.Search.Text -Harness $Ctx.View.harness) -Column $Ctx.View.sortColumn -Descending $Ctx.View.descending)
    $keys = @{ UpToDate = 'ok'; LocalNewer = 'up'; DriveNewer = 'down'; Diverged = 'warn'; NotHere = 'off' }
    $i = 0
    foreach ($n in 'Title', 'Harness', 'From', 'Last active', 'On this machine') { $Ctx.List.Columns[$i].Text = Get-ChatColumnHeader -Name $n -SortColumn $Ctx.View.sortColumn -Descending $Ctx.View.descending; $i++ }
    $Ctx.List.BeginUpdate(); $Ctx.List.Items.Clear()
    foreach ($v in $Ctx.Views) {
        $it = New-Object System.Windows.Forms.ListViewItem($v.Title)
        $it.ImageKey = $keys[$v.Status]; $it.Tag = $v
        foreach ($t in $v.HarnessText, $v.From, $v.When, $v.StatusText) { [void]$it.SubItems.Add($t) }
        [void]$Ctx.List.Items.Add($it)
    }
    $Ctx.List.EndUpdate()
    $Ctx.Pull.Enabled = $false
    $read = $null -ne (Get-MainState).LocalChats
    if ($sync.Error) { $Ctx.Status.Text = $sync.Error }
    elseif (-not $sync.Loaded -or ($sync.Ready -and -not $read)) { $Ctx.Status.Text = 'Press Refresh to read Drive and the chats on this machine.' }
    elseif (-not $sync.Ready) { $Ctx.Status.Text = 'Set up Drive sync to see the chats other computers pushed.' }
    elseif ((Get-MainState).DriveStale) { $Ctx.Status.Text = 'Press Refresh to update (something changed since this list was read).' }
    elseif (-not $Ctx.Views.Count) { $Ctx.Status.Text = $(if ($Ctx.Need.Checked -or $Ctx.Search.Text -or $Ctx.View.harness -ne 'All') { 'Nothing matches the filter.' } else { 'No chats on Drive yet. Push one from a Chats list.' }) }
    else { $Ctx.Status.Text = '{0} chat(s) on Drive' -f $Ctx.Views.Count }
    $Ctx.RootList.Items.Clear()
    $r = Get-SyncPathRoots
    foreach ($n in @($r.Keys | Sort-Object)) { $it = New-Object System.Windows.Forms.ListViewItem([string]$n); [void]$it.SubItems.Add([string]$r[$n]); [void]$Ctx.RootList.Items.Add($it) }
    $Ctx.Change.Enabled = $false; $Ctx.Remove.Enabled = $false
}

# "Pull to...": a menu of the profiles that can receive the chat, the likely one first and in bold.
function Show-DrivePullMenu {
    param([Parameter(Mandatory)]$Ctx)
    if (-not $Ctx.List.SelectedItems.Count) { return }
    $view = $Ctx.List.SelectedItems[0].Tag
    $targets = @(Get-HarnessTransferTargets)
    $first = Get-DefaultPullTarget -Row $view.Row -State (Get-MainSync).State -Targets $targets
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($t in @($first) + @($targets | Where-Object { $_ -ne $first })) {
        if (-not $t) { continue }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem(('{0} / {1}' -f (Get-HarnessDisplayName (Get-Harness -Name $t.Harness)), $t.Name))
        if ($t -eq $first) { $mi.Font = New-Object System.Drawing.Font($mi.Font, [System.Drawing.FontStyle]::Bold) }
        $mi.Tag = @{ Target = $t; View = $view }
        $mi.Add_Click({ Invoke-DrivePull -Ctx $ctx -Target $this.Tag.Target -View $this.Tag.View }.GetNewClosure())
        [void]$menu.Items.Add($mi)
    }
    $menu.Show($Ctx.Pull, (New-Object System.Drawing.Point(0, $Ctx.Pull.Height)))
}

function Invoke-DrivePull {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$View)
    $askRoot = { param($rootName) Read-SyncFolder -Description "Where is the folder '$rootName' on this machine? The chat's working folder is inside it." }
    $onDiverged = { param($row, $chat) Show-SyncDivergedDialog -Row $row -Chat $chat }
    Use-ChatPanelBusy -Ctx $Ctx -Block { $script:DrivePullResult = Invoke-ChatPull -Profile $Target -Status @{ Row = $View.Row } -AskRoot $askRoot -OnDiverged $onDiverged }
    # The target profile's cached chats are out of date now; nothing is read again until a button asks for it.
    Clear-MainChatCache -Harness $Target.Harness -Profile $Target
    (Get-MainState).DriveStale = $true
    Update-SyncDriveTab -Ctx $Ctx
    Show-ChatPanelResult -Ctx $Ctx -Result $script:DrivePullResult
    Request-ChatPullRestart -Profile $Target -Result $script:DrivePullResult
}

# A click on a column header of the Drive list: sort by it, or reverse the order when it already is the sort column.
function Set-DriveTabSort {
    param([Parameter(Mandatory)]$Ctx, [int]$Index)
    $names = 'Title', 'Harness', 'From', 'Last active', 'On this machine'
    if ($Index -lt 0 -or $Index -ge $names.Count) { return }
    if ($Ctx.View.sortColumn -eq $names[$Index]) { $Ctx.View.descending = -not $Ctx.View.descending }
    else { $Ctx.View.sortColumn = $names[$Index]; $Ctx.View.descending = ($names[$Index] -eq 'Last active') }
    Set-MainViewSetting -Name 'Ui.DriveView' -View $Ctx.View
    Update-SyncDriveTab -Ctx $Ctx
}

function Invoke-DriveRootAction {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    try {
        $sel = $(if ($Ctx.RootList.SelectedItems.Count) { [string]$Ctx.RootList.SelectedItems[0].Text } else { '' })
        switch ($Name) {
            'Add' {
                $answer = Show-Prompt -Message 'Name of the folder root (letters, digits, - and _):' -Title 'Add folder root' -OkText 'Next'
                if (-not $answer) { return }
                if ($answer.Text -notmatch '\A[A-Za-z0-9_-]+\z') { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'warning'; Text = 'A root name may only hold letters, digits, - and _.' }; return }
                $path = Read-SyncFolder -Description "Where is '$($answer.Text)' on this machine?"
                if ($path) { Set-SyncPathRoot -Name $answer.Text -Path $path }
            }
            'Change' { if ($sel) { $path = Read-SyncFolder -Description "Where is '$sel' on this machine now?"; if ($path) { Set-SyncPathRoot -Name $sel -Path $path } } }
            'Remove' { if ($sel) { Remove-MainPathRoot -Name $sel } }
        }
        Update-SyncDriveTab -Ctx $Ctx
    } catch { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'error'; Text = $_.Exception.Message } }
}
