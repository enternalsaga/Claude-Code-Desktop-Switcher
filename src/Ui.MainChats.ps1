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
        When = (Format-SyncWhen $Chat.Activity); DriveText = $drive[0]; ImageKey = $drive[1]
    }
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

# The rows whose title or folder contains the text (any case); an empty text keeps all.
function Select-ChatListRows {
    param([array]$Rows, [string]$Text)
    if (-not $Text) { return @($Rows) }
    return @($Rows | Where-Object { $_.Title.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Folder.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
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
function New-HarnessChatPanel {
    param([Parameter(Mandatory)]$Harness, [Parameter(Mandatory)][scriptblock]$GetProfile)
    $s = Get-MainUiStyle
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.BackColor = $s.Bg
    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false; $list.ShowItemToolTips = $true
    $list.Dock = 'Fill'; $list.BackColor = [System.Drawing.Color]::White; $list.ForeColor = $s.Ink; $list.SmallImageList = (New-ChatStatusImages)
    foreach ($c in @(@('Title', 300), @('Folder', 150), @('Last active', 90), @('Drive', 280))) { [void]$list.Columns.Add($c[0], $c[1]) }
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
    $title.Location = New-Object System.Drawing.Point(8, 8); $title.Size = New-Object System.Drawing.Size(430, 22); $title.Font = $s.Bold; $title.ForeColor = $s.Ink
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location = New-Object System.Drawing.Point(480, 5); $search.Size = New-Object System.Drawing.Size(200, 24); $search.Anchor = 'Top,Right'
    $refresh = New-MainButton -Text 'Refresh' -X 690 -Width 80; $refresh.Location = New-Object System.Drawing.Point(690, 3); $refresh.Size = New-Object System.Drawing.Size(80, 28); $refresh.Anchor = 'Top,Right'
    foreach ($c in $title, $search, $refresh) { $head.Controls.Add($c) }
    $panel.Controls.Add($head)

    $ctx = @{ Harness = $Harness; GetProfile = $GetProfile; Panel = $panel; List = $list; Search = $search; Status = $status; Title = $title; Buttons = $buttons; Refresh = $refresh
              Profile = $null; Views = @(); Busy = $false }
    $list.Add_SelectedIndexChanged({ Update-ChatButtons -Ctx $ctx }.GetNewClosure())
    $list.Add_DoubleClick({ Invoke-ChatPanelAction -Ctx $ctx -Name 'Continue' }.GetNewClosure())
    $search.Add_TextChanged({ Update-ChatPanel -Ctx $ctx }.GetNewClosure())
    $refresh.Add_Click({ Invoke-MainRefresh }.GetNewClosure())
    foreach ($n in $buttons.Keys) { $buttons[$n].Tag = $n; $buttons[$n].Add_Click({ Invoke-ChatPanelAction -Ctx $ctx -Name $this.Tag }.GetNewClosure()) }
    return $ctx
}

# Reload re-reads the chat list of the selected profile (and Drive's picture of the chats, through Get-MainSync); without it
# the loaded chats are only filtered and drawn again. RefreshCatalog also asks Drive again.
function Update-ChatPanel {
    param([Parameter(Mandatory)]$Ctx, [switch]$Reload, [switch]$RefreshCatalog)
    if ($RefreshCatalog) { Update-MainCatalog }
    if ($Reload -or $RefreshCatalog) {
        $p = & $Ctx.GetProfile
        $Ctx.Profile = $p
        $Ctx.Title.Text = $(if ($p) { 'Chats of {0}' -f $p.Name } else { 'Chats' })
        $chats = @(); $problem = ''
        if ($p) { try { $chats = @(& $Ctx.Harness.Adapter.ListChats $p) } catch { $problem = "Could not list chats: $($_.Exception.Message)" } }
        $sync = Get-MainSync
        $Ctx.Views = @(foreach ($c in $chats) {
            if (-not $c) { continue }
            $copy = $c.PSObject.Copy()
            if ($p -and -not $copy.PSObject.Properties['Profile']) { $copy | Add-Member -NotePropertyName Profile -NotePropertyValue $p }
            Get-ChatListRow -Chat $copy -Status (Get-HarnessChatSyncStatus -Chat $copy -Harness $Ctx.Harness.Name -Catalog $sync.Catalog -State $sync.State)
        })
        $Ctx.Status.Text = $(if ($problem) { $problem } elseif ($sync.Error) { $sync.Error } else { '{0} chat(s)' -f $Ctx.Views.Count })
    }
    $keep = $(if ($Ctx.List.SelectedItems.Count) { [string]$Ctx.List.SelectedItems[0].Tag.Chat.ChatId } else { '' })
    $Ctx.List.BeginUpdate()
    $Ctx.List.Items.Clear()
    foreach ($v in (Select-ChatListRows -Rows $Ctx.Views -Text $Ctx.Search.Text)) {
        $it = New-Object System.Windows.Forms.ListViewItem($v.Title)
        $it.ImageKey = $v.ImageKey; $it.Tag = $v; $it.UseItemStyleForSubItems = $false
        foreach ($t in $v.Folder, $v.When, $v.DriveText) { [void]$it.SubItems.Add($t) }
        if ($v.CwdMissing) { $it.SubItems[1].ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 10); $it.ToolTipText = $v.Tooltip }
        [void]$Ctx.List.Items.Add($it)
        if ($keep -and [string]$v.Chat.ChatId -eq $keep) { $it.Selected = $true }
    }
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
    if (-not $v) { return }
    try {
        switch ($Name) {
            'Move' {
                $r = Show-HarnessMoveDialog -Chat $v.Chat -SourceHarness $Ctx.Harness.Name
                if ($r) { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = (Get-HarnessTransferMessage -Result $r.Result -Target $r.Target); Prompt = $r.Result.Prompt } }
            }
            'Push' {
                if (-not (Test-SyncReady)) { [void](Show-SyncSetupWizard); Invoke-MainRefresh; return }
                Use-ChatPanelBusy -Ctx $Ctx -Block { Show-ChatPanelResult -Ctx $Ctx -Result (Invoke-ChatPush -Harness $Ctx.Harness -Profile $profile -Chat $v.Chat) }
                Invoke-MainRefresh
            }
            'Pull' {
                if (-not (Test-SyncReady) -or -not $v.Status.Row) { [void](Show-SyncSetupWizard); Invoke-MainRefresh; return }
                $askRoot = { param($rootName) Read-SyncFolder -Description "Where is the folder '$rootName' on this machine? The chat's working folder is inside it." }
                $onDiverged = { param($row, $chat) Show-SyncDivergedDialog -Row $row -Chat $chat }
                Use-ChatPanelBusy -Ctx $Ctx -Block { Show-ChatPanelResult -Ctx $Ctx -Result (Invoke-ChatPull -Profile $profile -Status $v.Status -AskRoot $askRoot -OnDiverged $onDiverged) }
                Invoke-MainRefresh
            }
            'Choose' { Invoke-ChatChooseFolder -Ctx $Ctx -View $v }
        }
    } catch { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message) } }
}

function Invoke-ChatChooseFolder {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$View)
    $fix = Get-ChatFolderFix -Cwd ([string]$View.Chat.Cwd) -Roots (Get-SyncPathRoots)
    switch ($fix.Kind) {
        'root' {
            $path = Read-SyncFolder -Description "Where is the folder '$($fix.Name)' on this machine now? It used to be $($fix.OldPath)."
            if ($path) { Set-SyncPathRoot -Name $fix.Name -Path $path; Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = "The folder '$($fix.Name)' is now $path." }; Invoke-MainRefresh }
        }
        'open' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $fix.Path); Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = "Opened $($fix.Path). Create the missing folder there, or move the project back." } }
        default { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'warning'; Text = 'This chat has no working folder to fix.' } }
    }
}
