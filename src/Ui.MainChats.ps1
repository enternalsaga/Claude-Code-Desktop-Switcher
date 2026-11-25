# Ui.MainChats.ps1 - the chat list under each harness tab of the main window (phase 5, lane V2): what a chat row shows,
# which buttons are on, the panel itself and what its buttons do. The functions at the top are plain logic (tested without
# a window); New-HarnessChatPanel and the handlers are WinForms. Needs Ui.ChatStatus, Ui.Main, Ui.Sync, Ui.Harness and
# Ui.Tray. Drive is read only when the tab opens, on Refresh, and after a push or pull; never while a list is drawn. ASCII only.

# ---- what a row shows ----------------------------------------------------------------------------------------------------

# One row of the list: the texts of the columns, the icon key (the Drive state) and the tooltip (full path of the folder).
function Get-ChatListRow {
    param([Parameter(Mandatory)]$Chat, [Parameter(Mandatory)]$Status)
    $row = $Status.Row
    $when = $(if ($row) { Format-SyncWhen $row.lastActivityAt } else { '' })
    $drive = switch ($Status.Sync) {
        'NotOnDrive' { @('Not on Drive', 'off') }
        'Synced'     { @(('On Drive, ' + $when).TrimEnd(', '.ToCharArray()), 'ok') }
        'LocalNewer' { @('Changed here, push to update', 'up') }
        'DriveNewer' { @("Newer on Drive (from $($Status.FromMachine))", 'down') }
        'Diverged'   { @('Changed on both machines', 'warn') }
        default      { @('Set up Drive sync', 'none') }
    }
    $cwd = $(if ($Chat.Cwd) { [string]$Chat.Cwd } else { '' })
    $folder = $(if (-not $cwd) { 'no folder' } else { Split-Path $cwd -Leaf })
    if ($cwd -and $Status.CwdMissing) { $folder += ' (not found)' }
    return [pscustomobject]@{
        Chat = $Chat; Status = $Status; Title = [string]$Chat.Title; Folder = $folder; Tooltip = $cwd; CwdMissing = [bool]$Status.CwdMissing
        When = (Format-SyncWhen $Chat.Activity); DriveText = $drive[0]; ImageKey = $drive[1]; Activity = (ConvertTo-MainUnixMs $Chat.Activity)
    }
}

# Milliseconds since 1970 for a time the adapters give in seconds or milliseconds; 0 when there is none (sorts last when newest first).
function ConvertTo-MainUnixMs {
    param($Value)
    if ($null -eq $Value -or $Value -isnot [ValueType]) { return [double]0 }
    $n = [double]$Value
    return $(if ($n -gt 100000000000) { $n } else { $n * 1000 })
}

# Which buttons are on for the selected chat, and which one to stress. Continue is always on; push and pull also work
# before sync is set up (they open the setup).
function Get-ChatPanelActions {
    param([string]$Sync, [bool]$HasSelection, [bool]$CwdMissing, [bool]$Gone)
    $pull = $HasSelection -and ($Sync -in 'DriveNewer', 'Diverged', 'NoSync')
    $light = switch ($Sync) { { $_ -in 'NotOnDrive', 'LocalNewer' } { 'Push' } { $_ -in 'DriveNewer', 'Diverged' } { 'Pull' } default { $null } }
    return @{
        Continue = $true; Move = ($HasSelection -and -not $Gone); Push = ($HasSelection -and -not $Gone); Pull = $pull
        Choose = ($HasSelection -and $CwdMissing); Highlight = $(if ($HasSelection) { $light } else { $null })
    }
}

# The rows whose title or folder contains the text (any case), limited by Show: All | NeedsAction (newer on Drive, changed on
# both, changed here, or folder missing) | NotOnDrive | OnDrive | FolderMissing. Order is kept.
function Select-ChatListRows {
    param([array]$Rows, [string]$Text, [string]$Show = 'All')
    $keep = foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        if ($Text -and $r.Title.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $r.Folder.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $sync = [string]$r.Status.Sync
        $ok = switch ($Show) {
            'NeedsAction'   { $sync -in 'DriveNewer', 'Diverged', 'LocalNewer' -or $r.CwdMissing }
            'NotOnDrive'    { $sync -eq 'NotOnDrive' }
            'OnDrive'       { $sync -in 'Synced', 'LocalNewer', 'DriveNewer', 'Diverged' }
            'FolderMissing' { [bool]$r.CwdMissing }
            default         { $true }
        }
        if ($ok) { $r }
    }
    return @($keep)
}

# Sorts rows by one key with a tie-break on the original position, so equal rows never swap places. Key is a scriptblock of a row.
function Sort-MainRows {
    param([array]$Rows, [Parameter(Mandatory)][scriptblock]$Key, [bool]$Descending)
    $Rows = @(@($Rows) | Where-Object { $null -ne $_ })   # an empty list passed on as $null must stay empty, not become one empty row
    if (-not $Rows.Count) { return @() }
    $i = 0
    $decorated = foreach ($r in @($Rows)) { [pscustomobject]@{ Row = $r; Key = (& $Key $r); Index = $i++ } }
    $sorted = @($decorated | Sort-Object -Property @{ Expression = { $_.Key }; Descending = $Descending }, @{ Expression = { $_.Index }; Descending = $false })
    return @($sorted | ForEach-Object { $_.Row })
}

# Column is Title | Folder | Last active | Drive. Text sorts ignore case, Last active sorts by the number, Drive by how much
# attention a row needs (ascending: most urgent first).
function Sort-ChatListRows {
    param([array]$Rows, [string]$Column = 'Last active', [bool]$Descending = $true)
    $rank = @{ Diverged = 0; DriveNewer = 1; LocalNewer = 2; NotOnDrive = 3; Synced = 4; NoSync = 5 }
    $key = switch ($Column) {
        'Title'  { { param($r) $r.Title.ToLowerInvariant() } }
        'Folder' { { param($r) $r.Folder.ToLowerInvariant() } }
        'Drive'  { { param($r) $rank[[string]$r.Status.Sync] }.GetNewClosure() }
        default  { { param($r) [double]$r.Activity } }
    }
    return (Sort-MainRows -Rows $Rows -Key $key -Descending $Descending)
}

# The header text of a column: its name, plus an arrow when the list is sorted by it (built from char codes to stay ASCII).
function Get-ChatColumnHeader {
    param([string]$Name, [string]$SortColumn, [bool]$Descending)
    if ($Name -ne $SortColumn) { return $Name }
    return ('{0} {1}' -f $Name, [char]$(if ($Descending) { 0x25BC } else { 0x25B2 }))
}

# ---- remembered view and cached chats --------------------------------------------------------------------------------------

function Get-MainViewDefault {
    param([string]$Kind)
    if ($Kind -eq 'drive') { return @{ show = 'All'; harness = 'All'; sortColumn = 'Last active'; descending = $true } }
    return @{ show = 'All'; sortColumn = 'Last active'; descending = $true }
}

# The stored { show, sortColumn, descending } (drive: also harness) of a panel, from settings; anything unknown or damaged
# falls back to the default. Settings hand back a hashtable or an object read from JSON.
function Get-MainViewSetting {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Kind)
    $view = Get-MainViewDefault -Kind $Kind
    $stored = Get-Setting $Name
    if ($null -eq $stored) { return $view }
    $get = { param($k) if ($stored -is [System.Collections.IDictionary]) { $stored[$k] } elseif ($stored.PSObject.Properties[$k]) { $stored.PSObject.Properties[$k].Value } }
    $cols = $(if ($Kind -eq 'drive') { 'Title', 'Harness', 'From', 'Last active', 'On this machine' } else { 'Title', 'Folder', 'Last active', 'Drive' })
    $shows = $(if ($Kind -eq 'drive') { 'All', 'NeedsAction' } else { 'All', 'NeedsAction', 'NotOnDrive', 'OnDrive', 'FolderMissing' })
    if ([string](& $get 'show') -in $shows) { $view.show = [string](& $get 'show') }
    if ([string](& $get 'sortColumn') -in $cols) { $view.sortColumn = [string](& $get 'sortColumn') }
    if ((& $get 'descending') -is [bool]) { $view.descending = [bool](& $get 'descending') }
    if ($Kind -eq 'drive' -and [string](& $get 'harness') -in 'All', 'Claude', 'Codex', 'Antigravity') { $view.harness = [string](& $get 'harness') }
    return $view
}

function Set-MainViewSetting {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$View)
    Set-Setting $Name $View
}

# Chats already read, per '<harness>|<profile id>', in memory only. Nothing here reads a disk.
function Get-MainCacheKey {
    param([string]$Harness, $Profile)
    if (-not $Profile) { return '' }
    return ('{0}|{1}' -f $Harness, $Profile.Id)
}

function Clear-MainChatCache {
    param([string]$Harness, $Profile)
    $key = Get-MainCacheKey -Harness $Harness -Profile $Profile
    if ($key) { (Get-MainState).Cache.Remove($key) }
}

# What "Choose folder..." does for a chat whose working folder is gone: a folder under a path root of this machine means
# the root moved (root: ask where it is now); otherwise open the nearest parent that still exists (open), or nothing (none).
function Get-ChatFolderFix {
    param([string]$Cwd, [hashtable]$Roots)
    if (-not $Cwd) { return @{ Kind = 'none' } }
    foreach ($name in @($Roots.Keys | Sort-Object { $Roots[$_].Length } -Descending)) {
        if (Test-PathCoveredByRoot -Path $Cwd -Root ([string]$Roots[$name])) { return @{ Kind = 'root'; Name = [string]$name; OldPath = [string]$Roots[$name] } }
    }
    $p = $Cwd
    while ($p) {
        $parent = Split-Path $p -Parent
        if (-not $parent -or $parent -eq $p) { break }
        if (Test-Path -LiteralPath $parent -PathType Container) { return @{ Kind = 'open'; Path = $parent } }
        $p = $parent
    }
    return @{ Kind = 'none' }
}

# ---- what the buttons do (no window; the handlers show the answer) -------------------------------------------------------

# Each returns @{ Kind = message|warning|error; Text; Prompt }.
function Invoke-ChatPush {
    param([Parameter(Mandatory)]$Harness, [Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Chat)
    try {
        [void](Invoke-SyncPush -Chat $Chat -SourceHarness $Harness.Name -Profile $Profile)
        return @{ Kind = 'message'; Text = ('Pushed "{0}" to Drive.' -f $Chat.Title); Prompt = $null }
    } catch { return @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message); Prompt = $null } }
}

function Invoke-ChatPull {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Status, [scriptblock]$AskRoot, [scriptblock]$OnDiverged)
    try {
        $r = Invoke-SyncPullAskingRoot -Row $Status.Row -Target $Profile -AskRoot $AskRoot -OnDiverged $OnDiverged
        if ($r.Status -eq 'close-first') { return @{ Kind = 'warning'; Text = "Close $($Profile.Name) first, then try again. Its chat list is not refreshed while it is open."; Prompt = $null } }
        $kind = $(if ($r.Status -eq 'needs-root') { 'warning' } else { 'message' })
        return @{ Kind = $kind; Text = (Get-HarnessTransferMessage -Result $r -Target $Profile); Prompt = $r.Prompt }
    } catch { return @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message); Prompt = $null } }
}

# ---- icons ---------------------------------------------------------------------------------------------------------------

function New-ChatStatusBitmap {
    param([Parameter(Mandatory)][string]$Kind)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $color = switch ($Kind) {
            'ok' { [System.Drawing.Color]::FromArgb(46, 125, 74) } 'up' { [System.Drawing.Color]::FromArgb(203, 123, 93) }
            'down' { [System.Drawing.Color]::FromArgb(48, 110, 190) } 'warn' { [System.Drawing.Color]::FromArgb(224, 140, 20) }
            default { [System.Drawing.Color]::FromArgb(160, 158, 150) }
        }
        $pen = New-Object System.Drawing.Pen($color, 1.6); $brush = New-Object System.Drawing.SolidBrush($color); $white = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.8)
        switch ($Kind) {
            'warn' { $g.FillPolygon($brush, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(8, 1)), (New-Object System.Drawing.Point(15, 14)), (New-Object System.Drawing.Point(1, 14)))); $g.DrawLine($white, 8, 6, 8, 10); $g.DrawLine($white, 8, 12, 8, 12) }
            'ok'   { $g.FillEllipse($brush, 1, 1, 14, 14); $g.DrawLines($white, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(4, 8)), (New-Object System.Drawing.Point(7, 11)), (New-Object System.Drawing.Point(12, 5)))) }
            'up'   { $g.FillEllipse($brush, 1, 1, 14, 14); $g.DrawLines($white, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(5, 8)), (New-Object System.Drawing.Point(8, 5)), (New-Object System.Drawing.Point(11, 8)))); $g.DrawLine($white, 8, 5, 8, 12) }
            'down' { $g.FillEllipse($brush, 1, 1, 14, 14); $g.DrawLines($white, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(5, 8)), (New-Object System.Drawing.Point(8, 11)), (New-Object System.Drawing.Point(11, 8)))); $g.DrawLine($white, 8, 4, 8, 11) }
            default { $g.DrawEllipse($pen, 2, 2, 11, 11) }
        }
    } finally { $g.Dispose() }
    return $bmp
}

function New-ChatStatusImages {
    $il = New-Object System.Windows.Forms.ImageList
    $il.ColorDepth = 'Depth32Bit'; $il.ImageSize = New-Object System.Drawing.Size(16, 16)
    foreach ($k in 'none', 'off', 'ok', 'up', 'down', 'warn') { $il.Images.Add($k, (New-ChatStatusBitmap -Kind $k)) | Out-Null }
    return $il
}

# ---- the panel -----------------------------------------------------------------------------------------------------------

# Keeps a control a fixed distance from its parent's right edge (Stretch: it grows instead of moving). A Right anchor is not
# used because WinForms takes the distance from the parent's width at the time the control is added, and these panels are
# still at their default width then: the distance came out negative and the control left the window once the panel grew.
# Call after the control is added to its parent.
function Set-MainRightEdge {
    param([Parameter(Mandatory)]$Control, [Parameter(Mandatory)][int]$Margin, [switch]$Stretch)
    $parent = $Control.Parent
    $Control.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $place = {
        $w = $parent.ClientSize.Width
        if ($Stretch) { $v = [Math]::Max(60, $w - $Control.Left - $Margin); if ($Control.Width -ne $v) { $Control.Width = $v } }
        else { $v = $w - $Margin - $Control.Width; if ($Control.Left -ne $v) { $Control.Left = $v } }
    }.GetNewClosure()
    $parent.Add_Layout($place)
    & $place
}

function New-MainButton {
    param([string]$Text, [int]$X, [int]$Width = 124)
    $s = Get-MainUiStyle
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, 6); $b.Size = New-Object System.Drawing.Size($Width, 30)
    $b.FlatStyle = 'Flat'; $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.BackColor = [System.Drawing.Color]::White; $b.ForeColor = $s.Ink; $b.FlatAppearance.BorderColor = $s.Border
    return $b
}

# A harness that is not on this machine gets a note in place of its panels.
function New-HarnessMissingNote {
    param([Parameter(Mandatory)]$Harness)
    $s = Get-MainUiStyle
    $l = New-Object System.Windows.Forms.Label
    $l.Text = ('{0} is not installed on this machine, so there is nothing to show here.' -f (Get-HarnessDisplayName $Harness))
    $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.ForeColor = $s.Muted; $l.BackColor = $s.Bg
    return $l
}

# The chat panel of one harness. GetProfile returns the profile whose chats to list. Returns the context the Update-/Invoke-
# functions work on (Panel is the control to place). Handlers keep the context through closures: they outlive this call.
# Nothing is read here or when the panel is drawn: chats come from the cache until Load chats / Refresh is pressed.
function New-HarnessChatPanel {
    param([Parameter(Mandatory)]$Harness, [Parameter(Mandatory)][scriptblock]$GetProfile)
    $s = Get-MainUiStyle
    $view = Get-MainViewSetting -Name ('Ui.ChatView.' + $Harness.Name) -Kind 'chat'
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.BackColor = $s.Bg
    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false; $list.ShowItemToolTips = $true
    $list.Dock = 'Fill'; $list.BackColor = [System.Drawing.Color]::White; $list.ForeColor = $s.Ink; $list.SmallImageList = (New-ChatStatusImages)
    foreach ($c in @(@('Title', 300), @('Folder', 150), @('Last active', 90), @('Drive', 280), @('Mirror', 180))) { [void]$list.Columns.Add((Get-ChatColumnHeader -Name $c[0] -SortColumn $view.sortColumn -Descending $view.descending), $c[1]) }
    $load = New-MainButton -Text 'Load chats' -X 0 -Width 140; $load.Size = New-Object System.Drawing.Size(140, 36); $load.BackColor = $s.Accent; $load.ForeColor = [System.Drawing.Color]::White
    $list.Controls.Add($load)
    $panel.Controls.Add($list)
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Bottom'; $status.Height = 24; $status.ForeColor = $s.Muted; $status.Padding = New-Object System.Windows.Forms.Padding(8, 4, 0, 0)
    $panel.Controls.Add($status)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 42
    $buttons = @{}
    $x = 8
    foreach ($b in @(@('Continue', 'Continue here', 120), @('Move', 'Move to...', 100), @('Push', 'Push to Drive', 116), @('Pull', 'Pull from Drive', 124), @('Choose', 'Choose folder...', 124))) {
        $buttons[$b[0]] = New-MainButton -Text $b[1] -X $x -Width $b[2]; $bar.Controls.Add($buttons[$b[0]]); $x += $b[2] + 8
    }
    $panel.Controls.Add($bar)
    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = 34
    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object System.Drawing.Point(8, 8); $title.Size = New-Object System.Drawing.Size(250, 22); $title.Font = $s.Bold; $title.ForeColor = $s.Ink
    $showLabel = New-Object System.Windows.Forms.Label
    $showLabel.Text = 'Show:'; $showLabel.ForeColor = $s.Muted; $showLabel.Location = New-Object System.Drawing.Point(266, 9); $showLabel.Size = New-Object System.Drawing.Size(44, 20)
    $showBox = New-Object System.Windows.Forms.ComboBox
    $showBox.DropDownStyle = 'DropDownList'; $showBox.Location = New-Object System.Drawing.Point(312, 5); $showBox.Size = New-Object System.Drawing.Size(130, 24)
    foreach ($n in (Get-ChatShowChoices).Values) { [void]$showBox.Items.Add($n) }
    $showBox.SelectedItem = (Get-ChatShowChoices)[$view.show]
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location = New-Object System.Drawing.Point(460, 5); $search.Size = New-Object System.Drawing.Size(220, 24); $search.Anchor = 'Top,Left'
    $refresh = New-MainButton -Text 'Refresh' -X 690 -Width 80; $refresh.Location = New-Object System.Drawing.Point(690, 3); $refresh.Size = New-Object System.Drawing.Size(80, 28)
    foreach ($c in $title, $showLabel, $showBox, $search, $refresh) { $head.Controls.Add($c) }
    Set-MainRightEdge -Control $refresh -Margin 12; Set-MainRightEdge -Control $search -Margin 100
    $panel.Controls.Add($head)

    $ctx = @{ Harness = $Harness; GetProfile = $GetProfile; Panel = $panel; List = $list; Search = $search; Status = $status; Title = $title; Buttons = $buttons; ButtonBar = $bar; Refresh = $refresh
              LoadButton = $load; ShowBox = $showBox; View = $view; Profile = $null; Views = @(); Busy = $false }
    $list.Add_SelectedIndexChanged({ Update-ChatButtons -Ctx $ctx }.GetNewClosure())
    $list.Add_DoubleClick({ Invoke-ChatPanelAction -Ctx $ctx -Name 'Continue' }.GetNewClosure())
    $list.Add_Resize({ $ctx.LoadButton.Location = New-Object System.Drawing.Point([int](($ctx.List.ClientSize.Width - $ctx.LoadButton.Width) / 2), [int]($ctx.List.ClientSize.Height / 2 - 18)) }.GetNewClosure())
    $list.Add_ColumnClick({ Set-ChatPanelSort -Ctx $ctx -Index $_.Column }.GetNewClosure())
    $search.Add_TextChanged({ Update-ChatPanel -Ctx $ctx }.GetNewClosure())
    $showBox.Add_SelectedIndexChanged({
        $key = @((Get-ChatShowChoices).GetEnumerator() | Where-Object { $_.Value -eq $ctx.ShowBox.SelectedItem })[0].Key
        if ($key -and $key -ne $ctx.View.show) { $ctx.View.show = $key; Set-MainViewSetting -Name ('Ui.ChatView.' + $ctx.Harness.Name) -View $ctx.View; Update-ChatPanel -Ctx $ctx }
    }.GetNewClosure())
    foreach ($b in $refresh, $load) { $b.Tag = 'Load'; $b.Add_Click({ Invoke-ChatPanelAction -Ctx $ctx -Name 'Load' }.GetNewClosure()) }
    foreach ($n in $buttons.Keys) { $buttons[$n].Tag = $n; $buttons[$n].Add_Click({ Invoke-ChatPanelAction -Ctx $ctx -Name $this.Tag }.GetNewClosure()) }
    if (Get-Command Add-MirrorChatContextMenu -ErrorAction SilentlyContinue) { Add-MirrorChatContextMenu -Ctx $ctx }
    return $ctx
}

# The Show: box: stored key -> text.
function Get-ChatShowChoices {
    return ([ordered]@{ All = 'All'; NeedsAction = 'Needs action'; NotOnDrive = 'Not on Drive'; OnDrive = 'On Drive'; FolderMissing = 'Folder missing' })
}

# A click on a column header: sort by it, or reverse the order when it already is the sort column. Remembered.
function Set-ChatPanelSort {
    param([Parameter(Mandatory)]$Ctx, [int]$Index)
    $names = 'Title', 'Folder', 'Last active', 'Drive'
    if ($Index -lt 0 -or $Index -ge $names.Count) { return }
    if ($Ctx.View.sortColumn -eq $names[$Index]) { $Ctx.View.descending = -not $Ctx.View.descending }
    else { $Ctx.View.sortColumn = $names[$Index]; $Ctx.View.descending = ($names[$Index] -eq 'Last active') }
    Set-MainViewSetting -Name ('Ui.ChatView.' + $Ctx.Harness.Name) -View $Ctx.View
    Update-ChatPanel -Ctx $Ctx
}

# Reads the chats of the selected profile into the cache (and the Drive catalog): only when -Load is given, which is only
# done by a button. Without it the panel is drawn from the cache: no ListChats, no Drive.
function Read-ChatPanelChats {
    param([Parameter(Mandatory)]$Ctx, $Profile)
    $problem = ''; $chats = New-Object Collections.Generic.List[object]
    try {
        foreach ($c in @(& $Ctx.Harness.Adapter.ListChats $Profile)) {
            if (-not $c) { continue }
            $copy = $c.PSObject.Copy()
            if (-not $copy.PSObject.Properties['Profile']) { $copy | Add-Member -NotePropertyName Profile -NotePropertyValue $Profile }
            $chats.Add($copy)
        }
    } catch { $problem = "Could not list chats: $($_.Exception.Message)" }
    (Get-MainState).Cache[(Get-MainCacheKey -Harness $Ctx.Harness.Name -Profile $Profile)] = @{ Chats = $chats.ToArray(); At = Get-Date; Problem = $problem }
}

function Update-ChatPanel {
    param([Parameter(Mandatory)]$Ctx, [switch]$Load)
    $st = Get-MainState
    $p = & $Ctx.GetProfile
    $Ctx.Profile = $p
    $Ctx.Title.Text = $(if ($p) { 'Chats of {0}' -f $p.Name } else { 'Chats' })
    if ($Load -and $p) { Update-MainCatalog; Read-ChatPanelChats -Ctx $Ctx -Profile $p }
    $entry = $(if ($p) { $st.Cache[(Get-MainCacheKey -Harness $Ctx.Harness.Name -Profile $p)] } else { $null })
    $sync = Get-MainSync
    $Ctx.Views = @()
    if ($entry) {
        $Ctx.Views = @(foreach ($c in $entry.Chats) { Get-ChatListRow -Chat $c -Status (Get-HarnessChatSyncStatus -Chat $c -Harness $Ctx.Harness.Name -Catalog $sync.Catalog -State $sync.State) })
        $Ctx.Status.Text = $(if ($entry.Problem) { $entry.Problem } elseif ($sync.Error) { $sync.Error } else { 'Loaded {0} - {1} chat(s)' -f $entry.At.ToString('HH:mm'), $Ctx.Views.Count })
    } else { $Ctx.Status.Text = $(if ($p) { 'Chats not loaded yet.' } else { '' }) }
    $Ctx.LoadButton.Visible = [bool]($p -and -not $entry)
    $Ctx.LoadButton.Text = 'Load chats'
    $keep = $(if ($Ctx.List.SelectedItems.Count) { [string]$Ctx.List.SelectedItems[0].Tag.Chat.ChatId } else { '' })
    $rows = Sort-ChatListRows -Rows (Select-ChatListRows -Rows $Ctx.Views -Text $Ctx.Search.Text -Show $Ctx.View.show) -Column $Ctx.View.sortColumn -Descending $Ctx.View.descending
    $Ctx.List.BeginUpdate()
    $Ctx.List.Items.Clear()
    foreach ($v in $rows) {
        $it = New-Object System.Windows.Forms.ListViewItem($v.Title)
        $it.ImageKey = $v.ImageKey; $it.Tag = $v; $it.UseItemStyleForSubItems = $false
        $mirrorText = $(if (Get-Command Get-MirrorChatStatusText -ErrorAction SilentlyContinue) { Get-MirrorChatStatusText -Harness $Ctx.Harness.Name -Chat $v.Chat } else { '' })
        foreach ($t in $v.Folder, $v.When, $v.DriveText, $mirrorText) { [void]$it.SubItems.Add($t) }
        if ($v.CwdMissing) { $it.SubItems[1].ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 10); $it.ToolTipText = $v.Tooltip }
        [void]$Ctx.List.Items.Add($it)
        if ($keep -and [string]$v.Chat.ChatId -eq $keep) { $it.Selected = $true }
    }
    $i = 0
    foreach ($n in 'Title', 'Folder', 'Last active', 'Drive', 'Mirror') { $Ctx.List.Columns[$i].Text = Get-ChatColumnHeader -Name $n -SortColumn $Ctx.View.sortColumn -Descending $Ctx.View.descending; $i++ }
    $Ctx.List.EndUpdate()
    Update-ChatButtons -Ctx $Ctx
}

function Get-ChatPanelSelection {
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.List.SelectedItems.Count -eq 0) { return $null }
    return $Ctx.List.SelectedItems[0].Tag
}

function Update-ChatButtons {
    param([Parameter(Mandatory)]$Ctx)
    $v = Get-ChatPanelSelection -Ctx $Ctx
    $sync = $(if ($v) { [string]$v.Status.Sync } else { '' })
    $gone = [bool]($v -and $v.Chat.PSObject.Properties['HasRollout'] -and -not $v.Chat.HasRollout)
    $a = Get-ChatPanelActions -Sync $sync -HasSelection ([bool]$v) -CwdMissing ([bool]($v -and $v.CwdMissing)) -Gone $gone
    $s = Get-MainUiStyle
    foreach ($n in 'Continue', 'Move', 'Push', 'Pull', 'Choose') {
        $b = $Ctx.Buttons[$n]
        $b.Enabled = ($a[$n] -and -not $Ctx.Busy)
        $lit = ($a.Highlight -eq $n)
        $b.BackColor = $(if ($lit) { $s.Accent } else { [System.Drawing.Color]::White })
        $b.ForeColor = $(if ($lit) { [System.Drawing.Color]::White } else { $s.Ink })
    }
}

# Shows the answer of an action in the status line; only errors get a message box.
function Show-ChatPanelResult {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Result)
    $s = Get-MainUiStyle
    $Ctx.Status.Text = [string]$Result.Text
    $Ctx.Status.ForeColor = $(if ($Result.Kind -eq 'message') { $s.Muted } else { [System.Drawing.Color]::FromArgb(180, 70, 30) })
    if ($Result.Prompt) { try { [System.Windows.Forms.Clipboard]::SetText([string]$Result.Prompt) } catch { } }
    if ($Result.Kind -eq 'error' -and (Get-Command Show-Message -ErrorAction SilentlyContinue)) { [void](Show-Message ([string]$Result.Text) 'Chats and Drive' 'OK' 'Error') }
}

# Runs a block with the buttons locked and the wait cursor, always restoring both.
function Use-ChatPanelBusy {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][scriptblock]$Block)
    $Ctx.Busy = $true; Update-ChatButtons -Ctx $Ctx
    $Ctx.Panel.UseWaitCursor = $true
    try { & $Block } finally { $Ctx.Busy = $false; $Ctx.Panel.UseWaitCursor = $false; Update-ChatButtons -Ctx $Ctx }
}

function Invoke-ChatPanelAction {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    $v = Get-ChatPanelSelection -Ctx $Ctx
    $profile = $Ctx.Profile
    if ($Name -eq 'Continue') {
        if ($profile) { Invoke-HarnessTrayLaunch -Harness $Ctx.Harness -Profile $profile }
        return
    }
    if ($Name -eq 'Load') {
        Use-ChatPanelBusy -Ctx $Ctx -Block { Update-ChatPanel -Ctx $Ctx -Load }
        return
    }
    if (-not $v) { return }
    try {
        $res = $null; $reload = $false
        switch ($Name) {
            'Move' {
                $r = Show-HarnessMoveDialog -Chat $v.Chat -SourceHarness $Ctx.Harness.Name
                if ($r) { Clear-MainChatCache -Harness $r.Target.Harness -Profile $r.Target; $reload = $true; $res = @{ Kind = 'message'; Text = (Get-HarnessTransferMessage -Result $r.Result -Target $r.Target); Prompt = $r.Result.Prompt } }
            }
            'Push' {
                if (-not (Test-SyncReady)) { [void](Show-SyncSetupWizard); return }
                Use-ChatPanelBusy -Ctx $Ctx -Block { $script:ChatActionResult = Invoke-ChatPush -Harness $Ctx.Harness -Profile $profile -Chat $v.Chat }
                $res = $script:ChatActionResult; $reload = $true
            }
            'Pull' {
                if (-not (Test-SyncReady) -or -not $v.Status.Row) { [void](Show-SyncSetupWizard); return }
                $askRoot = { param($rootName) Read-SyncFolder -Description "Where is the folder '$rootName' on this machine? The chat's working folder is inside it." }
                $onDiverged = { param($row, $chat) Show-SyncDivergedDialog -Row $row -Chat $chat }
                Use-ChatPanelBusy -Ctx $Ctx -Block { $script:ChatActionResult = Invoke-ChatPull -Profile $profile -Status $v.Status -AskRoot $askRoot -OnDiverged $onDiverged }
                $res = $script:ChatActionResult; $reload = $true
            }
            'Choose' { Invoke-ChatChooseFolder -Ctx $Ctx -View $v }
        }
        # Only this profile and the catalog are read again; the Drive tab is told it is out of date.
        if ($reload) { Use-ChatPanelBusy -Ctx $Ctx -Block { Update-ChatPanel -Ctx $Ctx -Load }; (Get-MainState).DriveStale = $true }
        if ($res) { Show-ChatPanelResult -Ctx $Ctx -Result $res }
    } catch { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message) } }
}

function Invoke-ChatChooseFolder {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$View)
    $fix = Get-ChatFolderFix -Cwd ([string]$View.Chat.Cwd) -Roots (Get-SyncPathRoots)
    switch ($fix.Kind) {
        'root' {
            $path = Read-SyncFolder -Description "Where is the folder '$($fix.Name)' on this machine now? It used to be $($fix.OldPath)."
            if ($path) { Set-SyncPathRoot -Name $fix.Name -Path $path; Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = "The folder '$($fix.Name)' is now $path." }; Update-ChatPanel -Ctx $Ctx }
        }
        'open' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $fix.Path); Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = "Opened $($fix.Path). Create the missing folder there, or move the project back." } }
        default { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'warning'; Text = 'This chat has no working folder to fix.' } }
    }
}
