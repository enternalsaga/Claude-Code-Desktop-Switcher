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
            From = [string]$r.MachineName; When = (Format-SyncWhen $r.lastActivityAt)
        }
    }
    return @($views)
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

# Every chat of every installed harness and profile, once per refresh (cached until the next Update-MainCatalog).
function Get-MainLocalChats {
    $st = Get-MainState
    if ($null -ne $st.LocalChats) { return $st.LocalChats }
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
    return $st.LocalChats
}

# The statuses of every Drive row against this machine's chats: the badge of the tab and the list share it.
function Get-MainDriveViews {
    param([switch]$NeedsActionOnly)
    $sync = Get-MainSync
    if (-not $sync.Ready -or $null -eq $sync.Catalog) { return @() }
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
    $btnRefresh = New-MainButton -Text 'Refresh' -X 660 -Width 96; $btnRefresh.Location = New-Object System.Drawing.Point(660, 54); $btnRefresh.Anchor = 'Top,Right'
    $btnSettings = New-MainButton -Text 'Settings' -X 764 -Width 96; $btnSettings.Location = New-Object System.Drawing.Point(764, 54); $btnSettings.Anchor = 'Top,Right'
    $btnSetup = New-MainButton -Text 'Set up Drive sync...' -X 12 -Width 170; $btnSetup.Location = New-Object System.Drawing.Point(12, 54); $btnSetup.BackColor = $s.Accent; $btnSetup.ForeColor = [System.Drawing.Color]::White
    foreach ($c in $cardHead, $cardLine1, $cardLine2, $btnRefresh, $btnSettings, $btnSetup) { $card.Controls.Add($c) }

    $roots = New-Object System.Windows.Forms.Panel
    $roots.Dock = 'Bottom'; $roots.Height = 170
    $rootsHead = New-DriveLabel 'Folder roots (where project folders live on this machine)' 12 6 560 20 $true
    $rootList = New-DriveList @(@('Name', 160), @('Path on this machine', 480))
    $rootList.Location = New-Object System.Drawing.Point(12, 30); $rootList.Size = New-Object System.Drawing.Size(640, 126); $rootList.Anchor = 'Top,Left,Right,Bottom'
    $btnAdd = New-MainButton -Text 'Add' -X 664 -Width 90; $btnAdd.Location = New-Object System.Drawing.Point(664, 30); $btnAdd.Anchor = 'Top,Right'
    $btnChange = New-MainButton -Text 'Change' -X 664 -Width 90; $btnChange.Location = New-Object System.Drawing.Point(664, 66); $btnChange.Anchor = 'Top,Right'
    $btnRemove = New-MainButton -Text 'Remove' -X 664 -Width 90; $btnRemove.Location = New-Object System.Drawing.Point(664, 102); $btnRemove.Anchor = 'Top,Right'
    foreach ($c in $rootsHead, $rootList, $btnAdd, $btnChange, $btnRemove) { $roots.Controls.Add($c) }

    $mid = New-Object System.Windows.Forms.Panel
    $mid.Dock = 'Fill'
    $list = New-DriveList @(@('Title', 280), @('Harness', 100), @('From', 110), @('Last active', 90), @('On this machine', 150))
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
    $rbAll = New-Object System.Windows.Forms.RadioButton; $rbAll.Text = 'All'; $rbAll.Checked = $true; $rbAll.Location = New-Object System.Drawing.Point(220, 4); $rbAll.Size = New-Object System.Drawing.Size(60, 24)
    $rbNeed = New-Object System.Windows.Forms.RadioButton; $rbNeed.Text = 'Needs action'; $rbNeed.Location = New-Object System.Drawing.Point(284, 4); $rbNeed.Size = New-Object System.Drawing.Size(130, 24)
    $head.Controls.Add($rbAll); $head.Controls.Add($rbNeed)
    $mid.Controls.Add($head)
    $panel.Controls.Add($mid); $panel.Controls.Add($roots); $panel.Controls.Add($card)

    $ctx = @{ Panel = $panel; Status = $status; Card = $card; CardLine1 = $cardLine1; CardLine2 = $cardLine2; Refresh = $btnRefresh; Settings = $btnSettings; Setup = $btnSetup
              List = $list; Pull = $btnPull; All = $rbAll; Need = $rbNeed; RootList = $rootList; Add = $btnAdd; Change = $btnChange; Remove = $btnRemove; Views = @(); Busy = $false }
    $btnRefresh.Add_Click({ Invoke-MainRefresh }.GetNewClosure())
    foreach ($b in $btnSettings, $btnSetup) { $b.Add_Click({ try { [void](Show-SyncSetupWizard) } catch { Show-ChatPanelResult -Ctx $ctx -Result @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message) } }; Invoke-MainRefresh }.GetNewClosure()) }
    $list.Add_SelectedIndexChanged({ $ctx.Pull.Enabled = [bool]$ctx.List.SelectedItems.Count }.GetNewClosure())
    $rbNeed.Add_CheckedChanged({ Update-SyncDriveTab -Ctx $ctx }.GetNewClosure())
    $btnPull.Add_Click({ Show-DrivePullMenu -Ctx $ctx }.GetNewClosure())
    $rootList.Add_SelectedIndexChanged({ $on = [bool]$ctx.RootList.SelectedItems.Count; $ctx.Change.Enabled = $on; $ctx.Remove.Enabled = $on }.GetNewClosure())
    foreach ($b in $btnAdd, $btnChange, $btnRemove) { $b.Add_Click({ Invoke-DriveRootAction -Ctx $ctx -Name $this.Text }.GetNewClosure()) }
    return $ctx
}

function Get-DriveCardLines {
    $sync = Get-MainSync
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
    $lines = @(Get-DriveCardLines)
    $Ctx.CardLine1.Text = $lines[0]; $Ctx.CardLine2.Text = $lines[1]
    $Ctx.Setup.Visible = (-not $sync.Ready); $Ctx.Refresh.Visible = $sync.Ready; $Ctx.Settings.Visible = $sync.Ready
    $Ctx.Views = @(Get-MainDriveViews -NeedsActionOnly:$Ctx.Need.Checked)
    $keys = @{ UpToDate = 'ok'; LocalNewer = 'up'; DriveNewer = 'down'; Diverged = 'warn'; NotHere = 'off' }
    $Ctx.List.BeginUpdate(); $Ctx.List.Items.Clear()
    foreach ($v in $Ctx.Views) {
        $it = New-Object System.Windows.Forms.ListViewItem($v.Title)
        $it.ImageKey = $keys[$v.Status]; $it.Tag = $v
        foreach ($t in $v.HarnessText, $v.From, $v.When, $v.StatusText) { [void]$it.SubItems.Add($t) }
        [void]$Ctx.List.Items.Add($it)
    }
    $Ctx.List.EndUpdate()
    $Ctx.Pull.Enabled = $false
    if ($sync.Error) { $Ctx.Status.Text = $sync.Error }
    elseif (-not $sync.Ready) { $Ctx.Status.Text = 'Set up Drive sync to see the chats other computers pushed.' }
    elseif (-not $Ctx.Views.Count) { $Ctx.Status.Text = $(if ($Ctx.Need.Checked) { 'Nothing needs your attention.' } else { 'No chats on Drive yet. Push one from a Chats list.' }) }
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
    Use-ChatPanelBusy -Ctx $Ctx -Block { Show-ChatPanelResult -Ctx $Ctx -Result (Invoke-ChatPull -Profile $Target -Status @{ Row = $View.Row } -AskRoot $askRoot -OnDiverged $onDiverged) }
    Invoke-MainRefresh
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
