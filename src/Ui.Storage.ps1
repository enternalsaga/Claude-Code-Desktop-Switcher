# Ui.Storage.ps1 - the Storage tab of the main window (phase 6, lane U1): sizes of the profiles and of every session, filters,
# sort, and the view of what was archived. The functions without WinForms (rows, filters, text) are tested without a window;
# what the buttons do is in Ui.StorageActions.ps1. Nothing is read when the tab opens: a scan only runs when Scan is pressed.
# Needs Storage.Inventory.ps1 (Get-StorageStats), Ui.MainChats.ps1 (Sort-MainRows, Set-MainRightEdge, New-MainButton), Ui.ChatStatus.ps1
# (Format-SyncWhen). ASCII only.

# ---- text ----------------------------------------------------------------------------------------------------------------------

function Format-StorageSize {
    param($Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $b = [double]$Bytes
    if ($b -lt 1024) { return ('{0} B' -f [long]$b) }
    if ($b -lt 1MB) { return ($(($b / 1KB).ToString('0.#', $inv)) + ' KB') }
    if ($b -lt 1GB) { return ($(($b / 1MB).ToString('0.#', $inv)) + ' MB') }
    return ($(($b / 1GB).ToString('0.#', $inv)) + ' GB')
}

function Get-StorageHarnessText {
    param([string]$Harness)
    switch ($Harness) { 'claude' { return 'Claude' } 'codex' { return 'Codex' } 'antigravity' { return 'Antigravity' } default { return [string]$Harness } }
}

# ---- the remembered view (Ui.StorageView) ------------------------------------------------------------------------------------------

function Get-StorageColumnNames { return @('Title', 'Harness', 'Profiles', 'Size', 'Last active', 'Folder', 'State') }

function Get-StorageViewDefault {
    return @{ harness = 'All'; minMb = 0; idleDays = 0; state = 'Any'; sortColumn = 'Size'; descending = $true }
}

# The stored filters and sort, or the default for anything missing, unknown or damaged (settings give a hashtable or an object).
function Get-StorageViewSetting {
    $view = Get-StorageViewDefault
    $stored = Get-Setting 'Ui.StorageView'
    if ($null -eq $stored) { return $view }
    $get = { param($k) if ($stored -is [System.Collections.IDictionary]) { $stored[$k] } elseif ($stored.PSObject.Properties[$k]) { $stored.PSObject.Properties[$k].Value } }
    if ([string](& $get 'harness') -in 'All', 'claude', 'codex', 'antigravity') { $view.harness = [string](& $get 'harness') }
    $n = 0
    if ([int]::TryParse([string](& $get 'minMb'), [ref]$n) -and $n -in 0, 1, 10, 100) { $view.minMb = $n }
    if ([int]::TryParse([string](& $get 'idleDays'), [ref]$n) -and $n -in 0, 7, 30, 90) { $view.idleDays = $n }
    if ([string](& $get 'state') -in 'Any', 'idle', 'recent', 'unreadable') { $view.state = [string](& $get 'state') }
    if ([string](& $get 'sortColumn') -in (Get-StorageColumnNames)) { $view.sortColumn = [string](& $get 'sortColumn') }
    if ((& $get 'descending') -is [bool]) { $view.descending = [bool](& $get 'descending') }
    return $view
}

function Set-StorageViewSetting {
    param([Parameter(Mandatory)][hashtable]$View)
    Set-Setting 'Ui.StorageView' $View
}

# ---- rows (pure) -------------------------------------------------------------------------------------------------------------------

# One display row per session of the inventory, filtered and sorted. Harness: All | claude | codex | antigravity. State: Any |
# idle | recent | unreadable. IdleDays: days since the last activity (a session with no time passes). -Include is
# @{ <key> = $true } for recent sessions the user chose to include anyway. Selectable = may be ticked; Actionable = may be changed now.
function Get-StorageSessionRows {
    param($Inventory, [string]$Harness = 'All', [long]$MinBytes = 0, [int]$IdleDays = 0, [string]$State = 'Any', [string]$Text = '',
          [string]$SortColumn = 'Size', [bool]$Descending = $true, [hashtable]$Include = @{}, [datetime]$Now = (Get-Date))
    if (-not $Inventory -or -not @($Inventory.Sessions).Count) { return @() }
    $nowMs = ([DateTimeOffset]$Now).ToUnixTimeMilliseconds()
    $rows = foreach ($s in @($Inventory.Sessions)) {
        if ($null -eq $s -or $s.Flags.ArchivedRef) { continue }
        $unreadable = [bool]$s.Flags.DbUnreadable
        $stateKey = $(if ($unreadable) { 'unreadable' } else { [string]$s.State })
        if ($Harness -ne 'All' -and [string]$s.Harness -ne $Harness) { continue }
        if ([long]$s.Bytes -lt $MinBytes) { continue }
        if ($State -ne 'Any' -and $stateKey -ne $State) { continue }
        if ($IdleDays -gt 0 -and $s.LastActivity -and (($nowMs - [long]$s.LastActivity) / 86400000.0) -lt $IdleDays) { continue }
        $folder = $(if ($s.Cwd) { Split-Path -Leaf ([string]$s.Cwd).TrimEnd('\') } else { '' })
        if ($Text -and $s.Title.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $folder.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and ([string]$s.Key).IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $included = [bool]$Include[[string]$s.Key]
        $stateText = switch ($stateKey) { 'unreadable' { 'Unreadable' } 'recent' { $(if ($included) { 'Recent (included)' } else { 'Recent' }) } default { 'Idle' } }
        $warning = $(if ($unreadable) { 'The database of this profile could not be read, so what belongs to this session is not known.' } else { '' })
        [pscustomobject]@{
            Key = [string]$s.Key; Title = [string]$s.Title; Harness = [string]$s.Harness; HarnessText = (Get-StorageHarnessText $s.Harness)
            ProfilesText = $(if (@($s.Profiles).Count) { (@($s.Profiles | ForEach-Object { $_.Name }) -join ', ') } else { 'CLI only' })
            Bytes = [long]$s.Bytes; SizeText = (Format-StorageSize $s.Bytes); LastActivity = $(if ($s.LastActivity) { [long]$s.LastActivity } else { [long]0 })
            WhenText = (Format-SyncWhen $s.LastActivity $Now); Folder = $folder; State = $stateKey; StateText = $stateText; Warning = $warning
            Selectable = (-not $unreadable); Actionable = (-not $unreadable -and ($stateKey -eq 'idle' -or ($stateKey -eq 'recent' -and $included)))
            Tooltip = ((@('Key: ' + $s.Key) + $(if ($s.Cwd) { 'Folder: ' + $s.Cwd }) + $(if ($warning) { $warning })) -join "`n"); Session = $s
        }
    }
    $key = switch ($SortColumn) {
        'Title'       { { param($r) $r.Title.ToLowerInvariant() } }
        'Harness'     { { param($r) $r.HarnessText.ToLowerInvariant() } }
        'Profiles'    { { param($r) $r.ProfilesText.ToLowerInvariant() } }
        'Folder'      { { param($r) $r.Folder.ToLowerInvariant() } }
        'State'       { { param($r) $r.State } }
        'Last active' { { param($r) [double]$r.LastActivity } }
        default       { { param($r) [double]$r.Bytes } }
    }
    return @(Sort-MainRows -Rows @($rows) -Key $key -Descending $Descending)
}

function Get-StorageProfileNote { return 'A session shared by several profiles is listed under each of them; shared counted once in the totals.' }

# The profile table: every profile of the three apps, then the Claude CLI sessions that belong to no profile.
function Get-StorageProfileRows {
    param($Stats, $Inventory)
    if (-not $Stats) { return @() }
    $rows = New-Object Collections.Generic.List[object]
    foreach ($p in @($Stats.ByProfile)) {
        $rows.Add([pscustomobject]@{ Name = [string]$p.Name; Harness = [string]$p.Harness; HarnessText = (Get-StorageHarnessText $p.Harness); Sessions = [int]$p.Sessions
            SizeText = (Format-StorageSize $p.SessionBytes); SharedText = $(if ($p.SharedBytes) { Format-StorageSize $p.SharedBytes } else { '' }); AppDataText = (Format-StorageSize $p.AppDataBytes) })
    }
    $rows.Add([pscustomobject]@{ Name = 'CLI / no profile'; Harness = 'claude'; HarnessText = 'Claude'; Sessions = [int]$Stats.CliOnly.Sessions
        SizeText = (Format-StorageSize $Stats.CliOnly.Bytes); SharedText = ''; AppDataText = '' })
    return $rows.ToArray()
}

# The lines above the tables: when and how the last scan went, the totals, and the warnings the scan gave.
function Get-StorageHeaderLines {
    param($Inventory, $Stats, [datetime]$Now = (Get-Date))
    if (-not $Inventory) { return @{ Scan = 'Not scanned yet. Press Scan to measure the sessions.'; Totals = ''; Warnings = @() } }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $scan = 'Last scan {0} ({1} files, {2} s)' -f ([datetime]$Inventory.ScannedAt).ToString('HH:mm', $inv), ([long]$Inventory.Files).ToString('N0', $inv), ([double]$Inventory.Seconds).ToString('0.#', $inv)
    if ($Inventory.Cancelled) { $scan += ' - stopped early' }
    $live = @(@($Inventory.Sessions) | Where-Object { $null -ne $_ -and -not $_.Flags.ArchivedRef })
    $bytes = [long]0; foreach ($s in $live) { $bytes += $s.Bytes }
    $totals = '{0} sessions, {1} (shared counted once)' -f $live.Count, (Format-StorageSize $bytes)
    if ($Stats -and $Stats.Archive.Sessions) { $totals += '; archived: {0} sessions, {1} saved' -f $Stats.Archive.Sessions, (Format-StorageSize $Stats.Archive.Saved) }
    return @{ Scan = $scan; Totals = $totals; Warnings = @($Inventory.Warnings | Where-Object { $_ }) }
}

# ---- the archived view (pure) -------------------------------------------------------------------------------------------------------

# Rows of the archive indexes: -Local the rows of archive-index.jsonl, -Drive the rows Get-StorageDriveArchiveIndex gives (titles
# decrypted). A key that is back in the inventory is marked Restored; its index row stays until the user deletes the archive.
function Get-StorageArchivedRows {
    param($Local = @(), $Drive = @(), [string[]]$InventoryKeys = @(), [string]$ThisMachine = '', [string]$Harness = 'All', [string]$Text = '')
    $rows = New-Object Collections.Generic.List[object]
    $add = { param($r, $source, $sourceText, $title)
        $rows.Add([pscustomobject]@{
            Key = [string]$r.key; Title = [string]$title; Harness = [string]$r.harness; HarnessText = (Get-StorageHarnessText $r.harness); Bytes = [long]$r.bytes; SizeText = (Format-StorageSize $r.bytes)
            ZipBytes = [long]$r.zipBytes; SavedText = (Format-StorageSize ([Math]::Max(0, [long]$r.bytes - [long]$r.zipBytes))); ArchivedAt = [string]$r.archivedAt
            ArchivedText = $(try { ([datetime]::Parse([string]$r.archivedAt, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')).ToLocalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { '' })
            Source = $source; SourceText = $sourceText; MachineId = [string]$r.machineId; Restored = ($InventoryKeys -contains [string]$r.key)
            StatusText = $(if ($InventoryKeys -contains [string]$r.key) { 'Live' } else { 'Archived' }); Row = $r }) }
    foreach ($r in @($Local)) { if ($r) { & $add $r 'local' 'Local folder' $r.title } }
    foreach ($r in @($Drive)) {
        if (-not $r) { continue }
        $where = $(if ([string]$r.machineId -eq $ThisMachine) { 'Drive (this machine)' } else { 'Drive (' + $(if ($r.MachineName) { $r.MachineName } else { $r.machineId }) + ')' })
        & $add $r 'drive' $where $r.Title
    }
    $keep = @($rows | Where-Object { ($Harness -eq 'All' -or $_.Harness -eq $Harness) -and (-not $Text -or $_.Title.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0) })
    return @(Sort-MainRows -Rows $keep -Key { param($r) $r.ArchivedAt } -Descending $true)
}

# ---- the tab (WinForms) ----------------------------------------------------------------------------------------------------------------

function New-StorageLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20, [bool]$Bold = $false, [bool]$Dim = $false)
    $s = Get-MainUiStyle
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $false; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.ForeColor = $(if ($Dim) { $s.Muted } else { $s.Ink }); if ($Bold) { $l.Font = $s.Bold }
    return $l
}

function New-StorageCombo {
    param([int]$X, [int]$W, [string[]]$Items)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.Location = New-Object System.Drawing.Point($X, 5); $c.Size = New-Object System.Drawing.Size($W, 24)
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    return $c
}

function New-StorageListView {
    param([array]$Columns, [bool]$Checks = $false)
    $s = Get-MainUiStyle
    $l = New-Object System.Windows.Forms.ListView
    $l.View = 'Details'; $l.FullRowSelect = $true; $l.MultiSelect = $false; $l.HideSelection = $false; $l.CheckBoxes = $Checks; $l.ShowItemToolTips = $true
    $l.BackColor = [System.Drawing.Color]::White; $l.ForeColor = $s.Ink
    foreach ($c in $Columns) { [void]$l.Columns.Add($c[0], $c[1]) }
    return $l
}

# The top of the tab: title, where archives go, Change / Scan / Stop, the scan line and its progress bar.
function New-StorageHead {
    param([hashtable]$T)
    $s = Get-MainUiStyle
    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = 64
    $T.ArchiveLabel = New-StorageLabel 'not chosen yet' 232 12 330 20
    $T.Change = New-MainButton -Text 'Change...' -X 0 -Width 90; $T.Scan = New-MainButton -Text 'Scan' -X 0 -Width 70; $T.Stop = New-MainButton -Text 'Stop' -X 0 -Width 70
    $T.ScanLabel = New-StorageLabel '' 8 40 560 20 $false $true
    $T.Progress = New-Object System.Windows.Forms.ProgressBar
    $T.Progress.Location = New-Object System.Drawing.Point(580, 42); $T.Progress.Size = New-Object System.Drawing.Size(210, 14); $T.Progress.Visible = $false
    foreach ($ctl in (New-Object System.Windows.Forms.Label -Property @{ Text = 'Storage'; Font = $s.Title; ForeColor = $s.Ink; AutoSize = $false; Location = (New-Object System.Drawing.Point(8, 6)); Size = (New-Object System.Drawing.Size(120, 28)) }), (New-StorageLabel 'Archive to:' 150 12 78 20 $false $true), $T.ArchiveLabel, $T.Change, $T.Scan, $T.Stop, $T.ScanLabel, $T.Progress) { $head.Controls.Add($ctl) }
    Set-MainRightEdge -Control $T.Stop -Margin 8; Set-MainRightEdge -Control $T.Scan -Margin 84; Set-MainRightEdge -Control $T.Change -Margin 160
    Set-MainRightEdge -Control $T.Progress -Margin 8
    return $head
}

function New-StorageFilters {
    param([hashtable]$T, $View)
    $f = New-Object System.Windows.Forms.Panel
    $f.Dock = 'Top'; $f.Height = 34
    $T.HarnessBox = New-StorageCombo 66 110 @('All', 'Claude', 'Codex', 'Antigravity')
    $T.SizeBox = New-StorageCombo 240 86 @('Any', '1 MB', '10 MB', '100 MB')
    $T.IdleBox = New-StorageCombo 386 90 @('Any', '7 days', '30 days', '90 days')
    $T.StateBox = New-StorageCombo 528 100 @('Any', 'Idle', 'Recent', 'Unreadable')
    $T.Search = New-Object System.Windows.Forms.TextBox
    $T.Search.Location = New-Object System.Drawing.Point(640, 5); $T.Search.Size = New-Object System.Drawing.Size(170, 24)
    foreach ($ctl in (New-StorageLabel 'Harness:' 8 9 56 20 $false $true), $T.HarnessBox, (New-StorageLabel 'Size >=' 186 9 52 20 $false $true), $T.SizeBox, (New-StorageLabel 'Idle >=' 336 9 48 20 $false $true), $T.IdleBox, (New-StorageLabel 'State:' 486 9 40 20 $false $true), $T.StateBox, $T.Search) { $f.Controls.Add($ctl) }
    Set-MainRightEdge -Control $T.Search -Margin 8
    return $f
}

# The bar at the bottom: what is selected, the buttons of the live view or of the archived view, and the view switch.
function New-StorageBar {
    param([hashtable]$T)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 42
    $T.SelLabel = New-StorageLabel 'Selected: 0 sessions' 8 12 194 20
    $T.Buttons = @{}
    $x = 206
    foreach ($b in @(@('Archive', 'Archive...', 84), @('Trim', 'Trim...', 70), @('Summarize', 'Summarize...', 96), @('Delete', 'Delete...', 72), @('Include', 'Include anyway', 116))) {
        $T.Buttons[$b[0]] = New-MainButton -Text $b[1] -X $x -Width $b[2]; $x += $b[2] + 4
    }
    $x = 206
    foreach ($b in @(@('Restore', 'Restore...', 84), @('DeleteArchive', 'Delete archive...', 110), @('OpenSummary', 'Open summary', 110))) {
        $T.Buttons[$b[0]] = New-MainButton -Text $b[1] -X $x -Width $b[2]; $T.Buttons[$b[0]].Visible = $false; $x += $b[2] + 4
    }
    $T.Live = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Live'; Checked = $true; Location = (New-Object System.Drawing.Point(660, 10)); Size = (New-Object System.Drawing.Size(52, 24)) }
    $T.Archived = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Archived'; Location = (New-Object System.Drawing.Point(716, 10)); Size = (New-Object System.Drawing.Size(76, 24)) }
    foreach ($ctl in @($T.SelLabel) + @($T.Buttons.Values) + @($T.Live, $T.Archived)) { $bar.Controls.Add($ctl) }
    Set-MainRightEdge -Control $T.Archived -Margin 6; Set-MainRightEdge -Control $T.Live -Margin 84
    return $bar
}

# Builds the tab and returns its context (Panel is the control to place on the tab page). Nothing is read here.
function New-StorageTab {
    $s = Get-MainUiStyle
    $view = Get-StorageViewSetting
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.BackColor = $s.Bg
    $c = @{ Panel = $panel; View = $view; Inventory = $null; Stats = $null; Rows = @(); Checked = @{}; Include = @{}; Filling = $false; Busy = $false; Job = $null; Timer = $null; Mode = 'Live'; Archived = $null; ArchivedRows = @() }
    $c.List = New-StorageListView @(@('Title', 270), @('Harness', 90), @('Profiles', 150), @('Size', 80), @('Last active', 90), @('Folder', 130), @('State', 110)) $true
    $c.List.Dock = 'Fill'
    $c.ArchList = New-StorageListView @(@('Title', 270), @('Harness', 90), @('Size', 80), @('Saved', 80), @('Archived', 130), @('Where', 150), @('Status', 90))
    $c.ArchList.Dock = 'Fill'; $c.ArchList.Visible = $false
    $panel.Controls.Add($c.List); $panel.Controls.Add($c.ArchList)
    $c.Status = New-StorageLabel '' 0 0 100 22 $false $true; $c.Status.Dock = 'Bottom'; $c.Status.Padding = New-Object System.Windows.Forms.Padding(8, 4, 0, 0)
    $panel.Controls.Add($c.Status)
    $panel.Controls.Add((New-StorageBar $c))
    $filters = New-StorageFilters $c $view
    $c.Warn = New-StorageLabel '' 8 0 800 18; $c.Warn.Dock = 'Top'; $c.Warn.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 10); $c.Warn.Height = 0
    $c.Note = New-StorageLabel (Get-StorageProfileNote) 0 0 100 20 $false $true; $c.Note.Dock = 'Top'; $c.Note.Padding = New-Object System.Windows.Forms.Padding(8, 3, 0, 0)
    $c.ProfileList = New-StorageListView @(@('Profile', 220), @('Harness', 100), @('Sessions', 80), @('Size', 90), @('Shared', 90), @('App data', 100))
    $c.ProfileList.Dock = 'Top'; $c.ProfileList.Height = 110
    foreach ($ctl in $filters, $c.Warn, $c.Note, $c.ProfileList, (New-StorageHead $c)) { $panel.Controls.Add($ctl) }
    Set-StorageControlsFromView -Ctx $c
    Connect-StorageEvents -Ctx $c
    Update-StorageTab -Ctx $c
    return $c
}

function Set-StorageControlsFromView {
    param($Ctx)
    $v = $Ctx.View
    $Ctx.Filling = $true
    $Ctx.HarnessBox.SelectedItem = $(if ($v.harness -eq 'All') { 'All' } else { Get-StorageHarnessText $v.harness })
    $Ctx.SizeBox.SelectedItem = $(if ($v.minMb) { "$($v.minMb) MB" } else { 'Any' })
    $Ctx.IdleBox.SelectedItem = $(if ($v.idleDays) { "$($v.idleDays) days" } else { 'Any' })
    $Ctx.StateBox.SelectedItem = $(if ($v.state -eq 'Any') { 'Any' } else { (Get-Culture).TextInfo.ToTitleCase($v.state) })
    $Ctx.Filling = $false
}

# The sessions of the list that are ticked.
function Get-StorageCheckedRows {
    param($Ctx)
    return @($Ctx.Rows | Where-Object { $Ctx.Checked.ContainsKey($_.Key) })
}

# Redraws everything from what is in memory (the inventory of the last scan, the archived rows): never reads a disk.
function Update-StorageTab {
    param([Parameter(Mandatory)]$Ctx)
    $inv = $Ctx.Inventory
    $hdr = Get-StorageHeaderLines -Inventory $inv -Stats $Ctx.Stats
    $Ctx.ScanLabel.Text = $(if ($hdr.Totals) { $hdr.Scan + '   |   ' + $hdr.Totals } else { $hdr.Scan })
    $Ctx.Warn.Text = ($hdr.Warnings -join '  '); $Ctx.Warn.Height = $(if ($hdr.Warnings.Count) { 18 * [Math]::Min(3, $hdr.Warnings.Count) } else { 0 })
    $Ctx.ArchiveLabel.Text = Get-StorageTargetText
    $Ctx.ProfileList.Items.Clear()
    foreach ($p in @(Get-StorageProfileRows -Stats $Ctx.Stats -Inventory $inv)) {
        $it = New-Object System.Windows.Forms.ListViewItem($p.Name)
        foreach ($t in $p.HarnessText, [string]$p.Sessions, $p.SizeText, $p.SharedText, $p.AppDataText) { [void]$it.SubItems.Add($t) }
        [void]$Ctx.ProfileList.Items.Add($it)
    }
    if ($Ctx.Mode -eq 'Archived') { Update-StorageArchivedList -Ctx $Ctx } else { Update-StorageSessionList -Ctx $Ctx }
    Update-StorageButtons -Ctx $Ctx
}

function Update-StorageSessionList {
    param([Parameter(Mandatory)]$Ctx)
    $v = $Ctx.View
    $Ctx.Rows = @(Get-StorageSessionRows -Inventory $Ctx.Inventory -Harness $v.harness -MinBytes ([long]$v.minMb * 1MB) -IdleDays $v.idleDays -State $v.state -Text $Ctx.Search.Text `
        -SortColumn $v.sortColumn -Descending $v.descending -Include $Ctx.Include)
    $Ctx.Filling = $true
    $Ctx.List.BeginUpdate(); $Ctx.List.Items.Clear()
    foreach ($r in $Ctx.Rows) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Title)
        foreach ($t in $r.HarnessText, $r.ProfilesText, $r.SizeText, $r.WhenText, $r.Folder, $r.StateText) { [void]$it.SubItems.Add($t) }
        $it.Tag = $r; $it.ToolTipText = $r.Tooltip
        if (-not $r.Selectable -or -not $r.Actionable) { $it.ForeColor = (Get-MainUiStyle).Muted }
        [void]$Ctx.List.Items.Add($it)
        if ($Ctx.Checked.ContainsKey($r.Key)) { $it.Checked = $true }
    }
    $i = 0
    foreach ($n in (Get-StorageColumnNames)) { $Ctx.List.Columns[$i].Text = Get-ChatColumnHeader -Name $n -SortColumn $v.sortColumn -Descending $v.descending; $i++ }
    $Ctx.List.EndUpdate()
    $Ctx.Filling = $false
    $Ctx.List.Visible = $true; $Ctx.ArchList.Visible = $false
}

function Update-StorageArchivedList {
    param([Parameter(Mandatory)]$Ctx)
    $Ctx.ArchList.BeginUpdate(); $Ctx.ArchList.Items.Clear()
    foreach ($r in @($Ctx.ArchivedRows)) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Title)
        foreach ($t in $r.HarnessText, $r.SizeText, $r.SavedText, $r.ArchivedText, $r.SourceText, $r.StatusText) { [void]$it.SubItems.Add($t) }
        $it.Tag = $r; $it.ToolTipText = $r.Key
        [void]$Ctx.ArchList.Items.Add($it)
    }
    $Ctx.ArchList.EndUpdate()
    $Ctx.ArchList.Visible = $true; $Ctx.List.Visible = $false
}

# Wires the controls to their handlers. The handlers keep the context through closures: they outlive this call.
function Connect-StorageEvents {
    param($Ctx)
    $c = $Ctx
    $changed = {
        if ($c.Filling) { return }
        $h = $c.HarnessBox.SelectedItem; $c.View.harness = $(if ($h -eq 'All' -or -not $h) { 'All' } else { ([string]$h).ToLowerInvariant() })
        $c.View.minMb = $(if ($c.SizeBox.SelectedItem -match '^(\d+) MB') { [int]$Matches[1] } else { 0 })
        $c.View.idleDays = $(if ($c.IdleBox.SelectedItem -match '^(\d+) days') { [int]$Matches[1] } else { 0 })
        $c.View.state = $(if ($c.StateBox.SelectedItem -and $c.StateBox.SelectedItem -ne 'Any') { ([string]$c.StateBox.SelectedItem).ToLowerInvariant() } else { 'Any' })
        Set-StorageViewSetting -View $c.View
        Update-StorageTab -Ctx $c
    }.GetNewClosure()
    foreach ($b in $c.HarnessBox, $c.SizeBox, $c.IdleBox, $c.StateBox) { $b.Add_SelectedIndexChanged($changed) }
    $c.Search.Add_TextChanged({ if (-not $c.Filling) { Update-StorageTab -Ctx $c } }.GetNewClosure())
    $c.List.Add_ColumnClick({ Set-StorageSort -Ctx $c -Index $_.Column }.GetNewClosure())
    $c.List.Add_ItemCheck({ if (-not $c.Filling -and -not $c.List.Items[$_.Index].Tag.Selectable) { $_.NewValue = 'Unchecked' } }.GetNewClosure())
    $c.List.Add_ItemChecked({
        if ($c.Filling) { return }
        $r = $_.Item.Tag
        if ($_.Item.Checked) { $c.Checked[$r.Key] = $true } else { $c.Checked.Remove($r.Key) }
        Update-StorageButtons -Ctx $c
    }.GetNewClosure())
    $c.List.Add_SelectedIndexChanged({ Update-StorageButtons -Ctx $c }.GetNewClosure())
    $c.ArchList.Add_SelectedIndexChanged({ Update-StorageButtons -Ctx $c }.GetNewClosure())
    $c.Live.Add_CheckedChanged({ if ($c.Live.Checked) { Set-StorageMode -Ctx $c -Mode 'Live' } }.GetNewClosure())
    $c.Archived.Add_CheckedChanged({ if ($c.Archived.Checked) { Set-StorageMode -Ctx $c -Mode 'Archived' } }.GetNewClosure())
    $c.Scan.Add_Click({ Start-StorageScanUi -Ctx $c }.GetNewClosure())
    $c.Stop.Add_Click({ Stop-StorageJobUi -Ctx $c }.GetNewClosure())
    $c.Change.Add_Click({ Select-StorageArchiveTarget -Ctx $c }.GetNewClosure())
    foreach ($n in @($c.Buttons.Keys)) { $c.Buttons[$n].Tag = $n; $c.Buttons[$n].Add_Click({ Invoke-StorageAction -Ctx $c -Name $this.Tag }.GetNewClosure()) }
}

# A click on a column header: sort by it, or reverse the order when it already is the sort column. Remembered.
function Set-StorageSort {
    param([Parameter(Mandatory)]$Ctx, [int]$Index)
    $names = Get-StorageColumnNames
    if ($Index -lt 0 -or $Index -ge $names.Count) { return }
    if ($Ctx.View.sortColumn -eq $names[$Index]) { $Ctx.View.descending = -not $Ctx.View.descending }
    else { $Ctx.View.sortColumn = $names[$Index]; $Ctx.View.descending = ($names[$Index] -in 'Size', 'Last active') }
    Set-StorageViewSetting -View $Ctx.View
    Update-StorageTab -Ctx $Ctx
}

# ---- buttons, view switch, scan and job polling ------------------------------------------------------------------------------------------

function Update-StorageButtons {
    param([Parameter(Mandatory)]$Ctx)
    $b = $Ctx.Buttons
    $live = ($Ctx.Mode -eq 'Live'); $idle = -not $Ctx.Busy
    foreach ($n in 'Archive', 'Trim', 'Summarize', 'Delete', 'Include') { $b[$n].Visible = $live }
    foreach ($n in 'Restore', 'DeleteArchive', 'OpenSummary') { $b[$n].Visible = -not $live }
    if ($live) {
        $rows = Get-StorageCheckedRows -Ctx $Ctx
        $Ctx.SelLabel.Text = Get-StorageSelectionLabel -Rows $rows
        $st = Get-StorageActionState -Rows $rows
        foreach ($n in 'Archive', 'Trim', 'Summarize', 'Delete', 'Include') { $b[$n].Enabled = ($idle -and $st[$n]) }
    } else {
        $sel = $(if ($Ctx.ArchList.SelectedItems.Count) { $Ctx.ArchList.SelectedItems[0].Tag } else { $null })
        $Ctx.SelLabel.Text = '{0} archived session{1}' -f @($Ctx.ArchivedRows).Count, $(if (@($Ctx.ArchivedRows).Count -eq 1) { '' } else { 's' })
        $st = Get-StorageArchivedActionState -Row $sel -ThisMachine ([string]$Ctx.ThisMachine) -SummaryExists ([bool](Get-StorageSummaryFile -Row $sel))
        foreach ($n in 'Restore', 'DeleteArchive', 'OpenSummary') { $b[$n].Enabled = ($idle -and $st[$n]) }
    }
    $Ctx.Scan.Enabled = $idle; $Ctx.Change.Enabled = $idle; $Ctx.Stop.Enabled = (-not $idle)
}

function Set-StorageMode {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][ValidateSet('Live', 'Archived')][string]$Mode)
    $Ctx.Mode = $Mode
    if ($Mode -eq 'Archived') { Read-StorageArchivedList -Ctx $Ctx }
    Update-StorageTab -Ctx $Ctx
}

# Scan was pressed: the only thing that reads the sessions. Runs in a runspace; the timer below follows it.
function Start-StorageScanUi {
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.Busy) { return }
    try {
        $roots = Get-StorageRootsFromConfig -Config $null
        $Ctx.Job = Start-StorageScan -Roots $roots -CachePath (Join-Path $script:SwitcherHome 'storage-cache.json')
        Start-StorageJobTimer -Ctx $Ctx -Kind 'scan' -Label 'Scanning'
    } catch { $Ctx.Status.Text = 'Could not start the scan: ' + $_.Exception.Message }
}

# Marks the tab busy and ticks every 250 ms to show progress until the job says it is finished.
function Start-StorageJobTimer {
    param([Parameter(Mandatory)]$Ctx, [string]$Kind, [string]$Label)
    $Ctx.Busy = $true; $Ctx.JobKind = $Kind; $Ctx.JobLabel = $Label
    $Ctx.Progress.Value = 0; $Ctx.Progress.Visible = $true
    if (-not $Ctx.Timer) {
        $Ctx.Timer = New-Object System.Windows.Forms.Timer
        $Ctx.Timer.Interval = 250
        $c = $Ctx
        $Ctx.Timer.Add_Tick({ try { Update-StorageJobProgress -Ctx $c } catch { $c.Status.Text = 'Progress failed: ' + $_.Exception.Message } }.GetNewClosure())
    }
    $Ctx.Timer.Start()
    Update-StorageButtons -Ctx $Ctx
}

# One tick: the bar and the line follow the job's Progress; when it has finished the job is completed and closed.
function Update-StorageJobProgress {
    param([Parameter(Mandatory)]$Ctx)
    $j = $Ctx.Job
    if (-not $j) { return }
    $p = $j.Progress
    $total = [int]$p['Total']; $done = [int]$p['Done']
    $Ctx.Progress.Maximum = [Math]::Max(1, $total); $Ctx.Progress.Value = [Math]::Min($Ctx.Progress.Maximum, [Math]::Max(0, $done))
    if (-not $p['Finished']) {
        $Ctx.Status.Text = $(if ($total) { '{0}... {1} / {2}' -f $Ctx.JobLabel, $done, $total } else { '{0}... {1}' -f $Ctx.JobLabel, [string]$p['Phase'] })
        return
    }
    if ($Ctx.Timer) { $Ctx.Timer.Stop() }
    $Ctx.Job = $null; $Ctx.Busy = $false; $Ctx.Progress.Visible = $false
    try { Complete-StorageJob -Ctx $Ctx -Job $j } finally { try { Close-StorageScan -Scan $j } catch { } }
    Update-StorageTab -Ctx $Ctx
}

function Stop-StorageJobUi {
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.Job) { $Ctx.Status.Text = 'Stopping...'; Stop-StorageScan -Scan $Ctx.Job }
}
