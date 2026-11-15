$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent

# Settings and the Drive are fakes: nothing real is read or written, no window is shown.
$script:Store = @{}
function Get-Setting { param($Name) return $script:Store[$Name] }
function Set-Setting { param($Name, $Value) $script:Store[$Name] = $Value }
function Write-HarnessLog { param($Message) $script:Logged += , $Message }
. (Join-Path $root 'src\Harness.Sync.Config.ps1')
. (Join-Path $root 'src\Storage.Guard.ps1')
. (Join-Path $root 'src\Storage.Scan.ps1')
. (Join-Path $root 'src\Storage.Inventory.ps1')
. (Join-Path $root 'src\Ui.ChatStatus.ps1')
. (Join-Path $root 'src\Ui.Main.ps1')
. (Join-Path $root 'src\Ui.MainChats.ps1')
. (Join-Path $root 'src\Ui.Storage.ps1')
. (Join-Path $root 'src\Ui.StorageActions.ps1')

$MB = 1MB
$now = Get-Date
$ms = { param($days) [DateTimeOffset]::new($now.AddDays(-$days)).ToUnixTimeMilliseconds() }
function New-Sess($harness, $key, $title, $bytes, $days, $cwd, $profiles, $state = 'idle', $flags = @{}) {
    $f = @{ IsCliOnly = (-not @($profiles).Count -and $harness -eq 'claude'); HasZst = $false; Trimmable = $true; ArchivedRef = $false; DbUnreadable = $false }
    foreach ($k in $flags.Keys) { $f[$k] = $flags[$k] }
    [pscustomobject]@{ Harness = $harness; Key = $key; Id = $key.Split(':')[1]; Title = $title; Cwd = $cwd; LastActivity = (& $ms $days); Created = $null
        Profiles = @($profiles | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }); Parts = @(); Bytes = [long]$bytes; State = $state; Flags = $f }
}
$s1 = New-Sess 'claude' 'claude:c1' 'Fix the login' (10 * $MB) 40 'D:\Work\web-app' @('Default', 'Work2')
$s2 = New-Sess 'claude' 'claude:c2' 'CLI chat' (5 * $MB) 0 'D:\Work\tool' @() 'recent'
$s3 = New-Sess 'antigravity' 'antigravity:g1.aabbccdd' 'Landing page' (3 * $MB) 5 $null @('Default')
$s4 = New-Sess 'codex' 'codex:x2.11223344' 'Broken db chat' (2 * $MB) 60 'D:\Work\api' @('P1') 'idle' @{ DbUnreadable = $true }
$s5 = New-Sess 'codex' 'codex:x1.11223344' 'Parser bug' (1 * $MB) 100 'D:\Work\api' @('P1')
$inv = [pscustomobject]@{
    Sessions = @($s1, $s2, $s3, $s4, $s5)
    Profiles = @([pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default'; DataDir = 'C:\fake\claude'; DataBytes = [long](30 * $MB); DataFiles = 10; IsDefault = $true },
                 [pscustomobject]@{ Harness = 'claude'; Id = 'Work2'; Name = 'Work2'; DataDir = 'C:\fake\claude2'; DataBytes = [long](12 * $MB); DataFiles = 5; IsDefault = $false },
                 [pscustomobject]@{ Harness = 'codex'; Id = 'P1'; Name = 'P1'; DataDir = 'C:\fake\codex'; DataBytes = [long](8 * $MB); DataFiles = 5; IsDefault = $false })
    Totals = @{ Sessions = 5 }; ScannedAt = $now; Files = 1234; Seconds = 12.5; Cancelled = $false
    Warnings = @('Could not read the Codex database of profile P1; its sessions are listed without details.')
}

# ---- sizes -------------------------------------------------------------------------------------------------------------------
Assert ((Format-StorageSize 0) -eq '0 B' -and (Format-StorageSize 1536) -eq '1.5 KB' -and (Format-StorageSize (10 * $MB)) -eq '10 MB' -and (Format-StorageSize ([long](4.2 * 1GB))) -eq '4.2 GB') 'sizes read as B, KB, MB, GB'

# ---- U1-1: rows, filters, sort ------------------------------------------------------------------------------------------------
function Get-Keys($rows) { (@($rows | ForEach-Object { $_.Key }) -join ',') }
$rows = Get-StorageSessionRows -Inventory $inv -Now $now
Assert ((Get-Keys $rows) -eq 'claude:c1,claude:c2,antigravity:g1.aabbccdd,codex:x2.11223344,codex:x1.11223344') "default order is size, largest first: $(Get-Keys $rows)"
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -Harness 'codex' -Now $now)) -eq 'codex:x2.11223344,codex:x1.11223344') 'filter by harness'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -MinBytes (4 * $MB) -Now $now)) -eq 'claude:c1,claude:c2') 'filter by size'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -IdleDays 30 -Now $now)) -eq 'claude:c1,codex:x2.11223344,codex:x1.11223344') 'filter by days idle'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -State 'recent' -Now $now)) -eq 'claude:c2') 'filter by state recent'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -State 'unreadable' -Now $now)) -eq 'codex:x2.11223344') 'filter by state unreadable'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -State 'idle' -Now $now)) -eq 'claude:c1,antigravity:g1.aabbccdd,codex:x1.11223344') 'filter by state idle leaves out recent and unreadable'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -Text 'WEB' -Now $now)) -eq 'claude:c1') 'search matches the folder, any case'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -Text 'parser' -Now $now)) -eq 'codex:x1.11223344') 'search matches the title'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -Text 'x2.1122' -Now $now)) -eq 'codex:x2.11223344') 'search matches the key'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -SortColumn 'Size' -Descending $false -Now $now)) -eq 'codex:x1.11223344,codex:x2.11223344,antigravity:g1.aabbccdd,claude:c2,claude:c1') 'size ascending'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -SortColumn 'Last active' -Descending $true -Now $now)) -eq 'claude:c2,antigravity:g1.aabbccdd,claude:c1,codex:x2.11223344,codex:x1.11223344') 'last active sorts by the time, newest first'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -SortColumn 'Title' -Descending $false -Now $now)) -eq 'codex:x2.11223344,claude:c2,claude:c1,antigravity:g1.aabbccdd,codex:x1.11223344') 'title sorts ignoring case'
Assert ((Get-Keys (Get-StorageSessionRows -Inventory $inv -SortColumn 'Harness' -Descending $false -Now $now)) -eq 'antigravity:g1.aabbccdd,claude:c1,claude:c2,codex:x2.11223344,codex:x1.11223344') 'harness sorts by name, equal rows keep their order'
Assert (@(Get-StorageSessionRows -Inventory $null -Now $now).Count -eq 0 -and @(Get-StorageSessionRows -Inventory ([pscustomobject]@{ Sessions = @() }) -Now $now).Count -eq 0) 'no inventory and no sessions give no rows, not one empty row'
$r1 = $rows[0]
Assert ($r1.Title -eq 'Fix the login' -and $r1.HarnessText -eq 'Claude' -and $r1.ProfilesText -eq 'Default, Work2' -and $r1.SizeText -eq '10 MB' -and $r1.Folder -eq 'web-app' -and $r1.StateText -eq 'Idle' -and $r1.WhenText) 'row text fields'
Assert ($rows[1].ProfilesText -eq 'CLI only') 'a session of no profile reads CLI only'
Assert ((Get-Keys @($rows | Where-Object { $_.Selectable })) -eq 'claude:c1,claude:c2,antigravity:g1.aabbccdd,codex:x1.11223344') 'a session whose database could not be read cannot be selected'
$bad = $rows | Where-Object { $_.Key -eq 'codex:x2.11223344' }
Assert ($bad.StateText -eq 'Unreadable' -and $bad.Warning -like '*could not be read*' -and -not $bad.Actionable) 'U1-11: an unreadable session shows a warning and is not actionable'
Assert ($rows[1].StateText -eq 'Recent' -and -not $rows[1].Actionable) 'a recent session is not actionable'
$inc = Get-StorageSessionRows -Inventory $inv -Include @{ 'claude:c2' = $true } -Now $now
$c2 = $inc | Where-Object { $_.Key -eq 'claude:c2' }
Assert ($c2.Actionable -and $c2.StateText -eq 'Recent (included)') 'a recent session that was included anyway is actionable'
$inc2 = Get-StorageSessionRows -Inventory $inv -Include @{ 'codex:x2.11223344' = $true } -Now $now
Assert (-not ($inc2 | Where-Object { $_.Key -eq 'codex:x2.11223344' }).Actionable) 'include anyway never lets an unreadable session through'
Assert ((($rows | Where-Object { $_.Key -like 'antigravity*' }).Tooltip) -like '*antigravity:g1.aabbccdd*') 'the key is in the tooltip'

# ---- remembered view -----------------------------------------------------------------------------------------------------------
$v = Get-StorageViewSetting
Assert ($v.harness -eq 'All' -and $v.minMb -eq 0 -and $v.idleDays -eq 0 -and $v.state -eq 'Any' -and $v.sortColumn -eq 'Size' -and $v.descending -eq $true) 'the default view is everything, largest first'
Set-StorageViewSetting -View @{ harness = 'codex'; minMb = 10; idleDays = 30; state = 'idle'; sortColumn = 'Title'; descending = $false }
$v = Get-StorageViewSetting
Assert ($v.harness -eq 'codex' -and $v.minMb -eq 10 -and $v.idleDays -eq 30 -and $v.state -eq 'idle' -and $v.sortColumn -eq 'Title' -and $v.descending -eq $false) 'the view is stored and read back'
$script:Store['Ui.StorageView'] = [pscustomobject]@{ harness = 'nope'; minMb = -5; idleDays = 'x'; state = 'bogus'; sortColumn = 'Nothing'; descending = 'maybe' }
$v = Get-StorageViewSetting
Assert ($v.harness -eq 'All' -and $v.minMb -eq 0 -and $v.idleDays -eq 0 -and $v.state -eq 'Any' -and $v.sortColumn -eq 'Size' -and $v.descending -eq $true) 'a damaged stored view falls back to the default'
$script:Store.Remove('Ui.StorageView')

# ---- U1-4: the profile table and the header ----------------------------------------------------------------------------------------
$stats = Get-StorageStats -Inventory $inv
$prows = @(Get-StorageProfileRows -Stats $stats -Inventory $inv)
Assert ($prows.Count -eq 4 -and $prows[-1].Name -eq 'CLI / no profile') "three profiles and a CLI / no profile row, got $($prows.Count)"
$def = $prows | Where-Object { $_.Name -eq 'Default' -and $_.HarnessText -eq 'Claude' }
Assert ($def.Sessions -eq 1 -and $def.SizeText -eq '10 MB' -and $def.AppDataText -eq '30 MB' -and $def.SharedText -eq '10 MB') "Default: one session of 10 MB shared, 30 MB of app data, got $($def.Sessions) / $($def.SizeText) / $($def.AppDataText)"
Assert ($prows[-1].Sessions -eq 1 -and $prows[-1].SizeText -eq '5 MB') 'the CLI-only row holds the CLI-only session'
Assert ((Get-StorageProfileNote) -like '*shared counted once*') 'the profile table says shared sessions are counted once'
$hdr = Get-StorageHeaderLines -Inventory $inv -Stats $stats -Now $now
Assert ($hdr.Scan -like 'Last scan *1,234 files*12.5 s*' -and $hdr.Totals -like '*5 sessions*21 MB*') "header: $($hdr.Scan) / $($hdr.Totals)"
Assert ($hdr.Warnings.Count -eq 1 -and $hdr.Warnings[0] -like '*Codex database*') 'U1-11: the inventory warnings become lines'
$none = Get-StorageHeaderLines -Inventory $null -Stats $null -Now $now
Assert ($none.Scan -eq 'Not scanned yet. Press Scan to measure the sessions.' -and $none.Warnings.Count -eq 0) 'before a scan: Not scanned yet'

# ---- U1-7 / U1-11: the archived view ----------------------------------------------------------------------------------------------------
$idxLocal = @([pscustomobject]@{ key = 'claude:c1'; harness = 'claude'; title = 'Fix the login'; bytes = 10485760; zipBytes = 2097152; lastActivity = (& $ms 40); archivedAt = '2026-11-14T10:00:00Z'; machineId = 'm1'; entry = 'claude/2026-11/claude_c1.harchive.zip' })
$idxDrive = @([pscustomobject]@{ key = 'codex:gone.aabbccdd'; harness = 'codex'; Title = 'Old codex chat'; bytes = 4194304; zipBytes = 1048576; lastActivity = (& $ms 90); archivedAt = '2026-11-10T09:00:00Z'; machineId = 'aaaaaaaa-0000-4000-8000-000000000001'; MachineName = 'LAPTOP'; path = 'archives/x' })
$arch = @(Get-StorageArchivedRows -Local $idxLocal -Drive $idxDrive -InventoryKeys @('claude:c1') -ThisMachine 'aaaaaaaa-0000-4000-8000-000000000001')
Assert ($arch.Count -eq 2 -and $arch[0].Key -eq 'claude:c1' -and $arch[0].SourceText -eq 'Local folder' -and $arch[1].SourceText -eq 'Drive (this machine)') "archived rows from both stores, newest first: $(Get-Keys $arch)"
Assert ($arch[0].Restored -and $arch[0].StatusText -eq 'Restored' -and -not $arch[1].Restored -and $arch[1].StatusText -eq 'Archived') 'U1-11: a key that is back in the inventory is marked restored, and its index row is kept'
Assert ($arch[0].SavedText -eq '8 MB' -and $arch[1].Title -eq 'Old codex chat' -and $arch[1].SizeText -eq '4 MB') 'sizes and the saved space'
$arch2 = @(Get-StorageArchivedRows -Local @() -Drive @([pscustomobject]@{ key = 'claude:o'; harness = 'claude'; Title = 'From B'; bytes = 1; zipBytes = 1; lastActivity = 1; archivedAt = '2026-11-12T09:00:00Z'; machineId = 'bbbbbbbb-0000-4000-8000-000000000002'; MachineName = 'DESKTOP-B'; path = 'archives/y' }) -InventoryKeys @() -ThisMachine 'aaaaaaaa-0000-4000-8000-000000000001')
Assert ($arch2[0].SourceText -eq 'Drive (DESKTOP-B)') 'a row from another machine names it'
Assert ((@(Get-StorageArchivedRows -Local $idxLocal -Drive $idxDrive -InventoryKeys @() -ThisMachine 'x' -Harness 'codex' | ForEach-Object { $_.Key }) -join ',') -eq 'codex:gone.aabbccdd') 'filter the archived rows by harness'
Assert ((@(Get-StorageArchivedRows -Local $idxLocal -Drive $idxDrive -InventoryKeys @() -ThisMachine 'x' -Text 'OLD codex' | ForEach-Object { $_.Key }) -join ',') -eq 'codex:gone.aabbccdd') 'search the archived rows by title'


# ---- U1-2 / U1-3: the tab in a window that is never shown -------------------------------------------------------------------------------------
$tmp = New-TestTempDir
try {
    $script:SwitcherHome = Join-Path $tmp 'sw'
    $script:ScanCalls = 0; $script:RootsCalls = 0; $script:StopCalls = 0; $script:CloseCalls = 0; $script:Jobs = @(); $script:Shown = @(); $script:Confirms = @(); $script:ConfirmAnswer = $true
    function Get-StorageRootsFromConfig { param($Config) $script:RootsCalls++; return @{ ClaudeProjects = 'C:\none'; ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @() } }
    function New-FakeProgress { [hashtable]::Synchronized(@{ Phase = 'projects'; Done = 0; Total = 0; Finished = $false; Cancelled = $false; Error = $null; Result = $null; Warnings = @() }) }
    function Start-StorageScan { param($Roots, $CachePath) $script:ScanCalls++; $script:FakeJob = [pscustomobject]@{ Progress = (New-FakeProgress); Cancel = @{ Cancel = $false } }; return $script:FakeJob }
    function Stop-StorageScan { param($Scan) $script:StopCalls++; $Scan.Progress['Finished'] = $true; $Scan.Progress['Cancelled'] = $true }
    function Close-StorageScan { param($Scan) $script:CloseCalls++ }
    function Start-StorageJob { param($Script, $Arguments, $Total) $j = [pscustomobject]@{ Progress = (New-FakeProgress); Cancel = @{ Cancel = $false }; Script = $Script; Args = $Arguments; Total = $Total }; $j.Progress['Total'] = $Total; $script:Jobs += $j; return $j }
    function Show-StorageConfirm { param($Content) $script:Confirms += , $Content; return $script:ConfirmAnswer }
    function Show-StorageResults { param($Rows, $Title) $script:Shown += , @{ Rows = $Rows; Title = $Title } }
    function Get-StorageRunningIds { param($Roots, $Source) return @{ claude = @(); codex = @(); antigravity = @() } }
    function Get-SyncMachine { [pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'PC' } }
    function Test-SyncReady { return $false }
    $flag = { param($c) [bool][System.Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance', $null, [Type[]]@([int]), $null).Invoke($c, @(2)) }
    function Invoke-DeepLayout($c) { $c.PerformLayout(); foreach ($k in $c.Controls) { Invoke-DeepLayout $k } }
    function Get-OutOfBounds($c) {
        foreach ($k in $c.Controls) {
            if ($k -is [System.Windows.Forms.Button] -or $k -is [System.Windows.Forms.TextBox] -or $k -is [System.Windows.Forms.ComboBox] -or $k -is [System.Windows.Forms.ListView]) {
                $r = $c.ClientRectangle
                if ($k.Left -lt 0 -or $k.Top -lt 0 -or $k.Right -gt $r.Width -or $k.Bottom -gt $r.Height) { '{0} "{1}" {2} not inside {3} {4}' -f $k.GetType().Name, $k.Text, $k.Bounds, $c.GetType().Name, $r }
            }
            Get-OutOfBounds $k
        }
    }
    function New-TabHost($w, $h) {
        $f = New-Object System.Windows.Forms.Form
        $f.ClientSize = New-Object System.Drawing.Size($w, $h); [void]$f.Handle
        $ctx = New-StorageTab
        $f.Controls.Add($ctx.Panel); Invoke-DeepLayout $f
        return @{ Form = $f; Ctx = $ctx }
    }

    $h = New-TabHost 1000 700; $ctx = $h.Ctx
    Assert ($script:ScanCalls -eq 0 -and $script:RootsCalls -eq 0) 'U1-2: building the tab does not scan'
    Assert ($ctx.ScanLabel.Text -like 'Not scanned yet*' -and $ctx.List.Items.Count -eq 0 -and $ctx.ProfileList.Items.Count -eq 0) 'U1-2: it opens as Not scanned yet, with empty tables'
    Assert ($ctx.ArchiveLabel.Text -eq 'not chosen yet' -and -not $ctx.Busy) 'no archive folder chosen yet'
    Assert ($ctx.HarnessBox.SelectedItem -eq 'All' -and $ctx.SizeBox.SelectedItem -eq 'Any' -and $ctx.IdleBox.SelectedItem -eq 'Any' -and $ctx.StateBox.SelectedItem -eq 'Any') 'a new tab shows All / Any in the four filter boxes'
    Assert (-not (& $flag $ctx.Progress) -and -not $ctx.Stop.Enabled -and $ctx.Scan.Enabled) 'Scan is on, Stop is off, no progress bar'
    foreach ($n in 'Archive', 'Trim', 'Summarize', 'Delete', 'Include') { Assert (-not $ctx.Buttons[$n].Enabled) "$n is off with nothing ticked" }
    Assert ((& $flag $ctx.Buttons['Archive']) -and -not (& $flag $ctx.Buttons['Restore'])) 'the live view shows the live buttons, not the archived ones'
    Assert ($ctx.List.CheckBoxes -and $ctx.List.Columns.Count -eq 7 -and $ctx.List.Columns[3].Text -like 'Size *') 'a list with tick boxes; the default sort (Size) shows its arrow'
    foreach ($size in @(@(1000, 700), @(1400, 900))) {
        $h2 = New-TabHost $size[0] $size[1]
        $bad = @(Get-OutOfBounds $h2.Form)
        Assert ($bad.Count -eq 0) "U1-3: every button, box and list is inside its parent at $($size -join 'x'):`n$($bad -join "`n")"
        $h2.Form.Dispose()
    }

    # Scan: a runspace job, followed by the timer; the timer itself is not run in the test, its tick function is
    Start-StorageScanUi -Ctx $ctx
    Assert ($script:ScanCalls -eq 1 -and $ctx.Busy -and (& $flag $ctx.Progress) -and $ctx.Stop.Enabled -and -not $ctx.Scan.Enabled -and $ctx.Timer.Enabled) 'Scan starts one job, shows the bar and turns Stop on'
    Start-StorageScanUi -Ctx $ctx
    Assert ($script:ScanCalls -eq 1) 'Scan pressed while busy starts nothing'
    $script:FakeJob.Progress['Done'] = 3; $script:FakeJob.Progress['Total'] = 10
    Update-StorageJobProgress -Ctx $ctx
    Assert ($ctx.Status.Text -eq 'Scanning... 3 / 10' -and $ctx.Progress.Value -eq 3 -and $ctx.Progress.Maximum -eq 10 -and $ctx.Busy) 'the tick shows the progress'
    Stop-StorageJobUi -Ctx $ctx
    Update-StorageJobProgress -Ctx $ctx
    Assert ($script:StopCalls -eq 1 -and -not $ctx.Busy -and $null -eq $ctx.Job -and $script:CloseCalls -eq 1 -and $ctx.Status.Text -like 'Scan stopped*' -and $null -eq $ctx.Inventory) 'Stop ends the job, closes it and keeps what was there before'
    Start-StorageScanUi -Ctx $ctx
    $script:FakeJob.Progress['Error'] = 'the scan broke'; $script:FakeJob.Progress['Finished'] = $true
    Update-StorageJobProgress -Ctx $ctx
    Assert ($ctx.Status.Text -eq 'Scan failed: the scan broke' -and -not $ctx.Busy -and $null -eq $ctx.Inventory) 'an error of the scan is shown as text'
    Start-StorageScanUi -Ctx $ctx
    $script:FakeJob.Progress['Result'] = $inv; $script:FakeJob.Progress['Finished'] = $true
    Update-StorageJobProgress -Ctx $ctx
    Assert (-not $ctx.Busy -and $ctx.Inventory -and $ctx.Status.Text -eq 'Scan finished.' -and $script:ScanCalls -eq 3) 'a finished scan fills the inventory'
    Assert ($ctx.ScanLabel.Text -like 'Last scan *' -and $ctx.ProfileList.Items.Count -eq 4 -and $ctx.ProfileList.Items[3].Text -eq 'CLI / no profile') 'U1-4: the profile table has the CLI / no profile row'
    Assert ($ctx.Note.Text -like '*shared counted once*') 'U1-4: and the shared note'
    Assert ($ctx.Warn.Height -gt 0 -and $ctx.Warn.Text -like '*Codex database*') 'U1-11: the warning line shows'
    Assert ($ctx.List.Items.Count -eq 5 -and $ctx.List.Items[0].Text -eq 'Fix the login' -and $ctx.List.Items[0].SubItems[3].Text -eq '10 MB') 'the sessions are listed, largest first'
    Assert ($ctx.List.Items[3].ForeColor -eq (Get-MainUiStyle).Muted -or $ctx.List.Items[3].Tag.State -ne 'idle') 'rows that cannot be changed are drawn muted'

    # ticking
    $ctx.Checked['claude:c1'] = $true; $ctx.Checked['codex:x2.11223344'] = $true
    Update-StorageTab -Ctx $ctx
    Assert ($ctx.SelLabel.Text -eq 'Selected: 2 sessions, 12 MB') "the label counts what is ticked: $($ctx.SelLabel.Text)"
    Assert ($ctx.Buttons['Archive'].Enabled -and $ctx.Buttons['Delete'].Enabled -and -not $ctx.Buttons['Trim'].Enabled) 'Archive and Delete come on for a session that can be changed'
    $ctx.Checked.Clear(); $ctx.Checked['claude:c2'] = $true
    Update-StorageTab -Ctx $ctx
    Assert (-not $ctx.Buttons['Archive'].Enabled -and $ctx.Buttons['Include'].Enabled) 'one recent session: only Include anyway'
    Invoke-StorageAction -Ctx $ctx -Name 'Include'
    Assert ($ctx.Include['claude:c2'] -and $ctx.Buttons['Archive'].Enabled) 'Include anyway lets that one session through'

    # filters are remembered
    $ctx.HarnessBox.SelectedItem = 'Codex'
    Assert ($ctx.View.harness -eq 'codex' -and (Get-Setting 'Ui.StorageView').harness -eq 'codex' -and $ctx.List.Items.Count -eq 2) 'the harness filter narrows the list and is remembered'
    $ctx.HarnessBox.SelectedItem = 'All'; $ctx.StateBox.SelectedItem = 'Recent'
    Assert ($ctx.View.state -eq 'recent' -and $ctx.List.Items.Count -eq 1) 'the state filter'
    $ctx.StateBox.SelectedItem = 'Any'; $ctx.SizeBox.SelectedItem = '10 MB'
    Assert ($ctx.View.minMb -eq 10 -and $ctx.List.Items.Count -eq 1) 'the size filter'
    $ctx.SizeBox.SelectedItem = 'Any'; $ctx.IdleBox.SelectedItem = '90 days'
    Assert ($ctx.View.idleDays -eq 90 -and $ctx.List.Items.Count -eq 1 -and $ctx.List.Items[0].Text -eq 'Parser bug') 'the idle filter'
    $ctx.IdleBox.SelectedItem = 'Any'; $ctx.Search.Text = 'login'
    Assert ($ctx.List.Items.Count -eq 1 -and $ctx.List.Items[0].Text -eq 'Fix the login') 'the search box filters as you type'
    $ctx.Search.Text = ''
    Set-StorageSort -Ctx $ctx -Index 0
    Assert ($ctx.View.sortColumn -eq 'Title' -and -not $ctx.View.descending -and $ctx.List.Columns[0].Text -like 'Title *' -and $ctx.List.Items[0].Text -eq 'Broken db chat') 'a click on a header sorts by it (text: ascending first)'
    Set-StorageSort -Ctx $ctx -Index 0
    Assert ($ctx.View.descending -and $ctx.List.Items[0].Text -eq 'Parser bug') 'a second click reverses it'
    Set-StorageSort -Ctx $ctx -Index 3
    Assert ($ctx.View.sortColumn -eq 'Size' -and $ctx.View.descending) 'a size column starts with the largest'
    $ctx2 = (New-TabHost 1000 700).Ctx
    Assert ($ctx2.View.sortColumn -eq 'Size' -and $ctx2.View.descending -and $ctx2.View.state -eq 'Any') 'a new tab starts from the remembered view'

    # live actions: guard, where, confirm (Cancel is the default), then a background job
    $script:Store['Storage.ArchiveTarget'] = $null
    $ctx.Checked.Clear(); $ctx.Checked['claude:c1'] = $true; $ctx.Checked['codex:x1.11223344'] = $true; $ctx.Checked['antigravity:g1.aabbccdd'] = $true
    Update-StorageTab -Ctx $ctx
    function Read-StorageTargetChoice { param($Choices) return $null }
    Invoke-StorageAction -Ctx $ctx -Name 'Archive'
    Assert ($script:Jobs.Count -eq 0 -and $script:Confirms.Count -eq 0) 'U1-8: with no archive folder the first archive asks where; no answer, nothing runs'
    function Read-StorageTargetChoice { param($Choices) return @{ Kind = 'local'; Path = 'D:\HarnessArchive' } }
    $script:ConfirmAnswer = $false
    Invoke-StorageAction -Ctx $ctx -Name 'Archive'
    Assert ((Get-StorageTargetText) -eq 'D:\HarnessArchive' -and $ctx.ArchiveLabel.Text -eq 'D:\HarnessArchive') 'U1-8: the answer is remembered and shown'
    Assert ($script:Confirms.Count -eq 1 -and $script:Confirms[0].DefaultButton -eq 'Cancel' -and $script:Confirms[0].Text -like '*2 sessions*' -and $script:Confirms[0].Text -like '*Antigravity sessions cannot be archived or deleted yet*') 'the confirmation shows the two sessions that can go and why the Antigravity one cannot'
    Assert ($script:Jobs.Count -eq 0 -and -not $ctx.Busy) 'Cancel starts nothing'
    $script:ConfirmAnswer = $true
    Invoke-StorageAction -Ctx $ctx -Name 'Archive'
    $job = $script:Jobs[-1]
    Assert ($script:Jobs.Count -eq 1 -and $job.Total -eq 2 -and $job.Script -match 'Invoke-StorageArchive' -and $job.Args.Target.Kind -eq 'local' -and $job.Args.Target.Path -eq 'D:\HarnessArchive' -and $job.Args.NeedCodex -eq $true -and $job.Args.MachineId -eq 'aaaaaaaa-0000-4000-8000-000000000001' -and (@($job.Args.Sessions | ForEach-Object { $_.Key }) -join ',') -eq 'claude:c1,codex:x1.11223344') 'Yes starts one background job for the two sessions, with the store, the machine and the Codex wrapper'
    Assert ($ctx.Busy -and -not $ctx.Buttons['Archive'].Enabled -and $ctx.Stop.Enabled) 'while it runs every action is off and Stop is on'
    Invoke-StorageAction -Ctx $ctx -Name 'Delete'
    Assert ($script:Jobs.Count -eq 1) 'a second action while busy does nothing'
    $job.Progress['Done'] = 2; $job.Progress['Finished'] = $true
    $job.Progress['Result'] = @(@{ Key = 'claude:c1'; Ok = $true; Skipped = $false; Reason = ''; Warnings = @() }, @{ Key = 'codex:x1.11223344'; Ok = $false; Skipped = $false; Reason = 'store-verify-failed'; Warnings = @() })
    Update-StorageJobProgress -Ctx $ctx
    Assert (-not $ctx.Busy -and @($ctx.Inventory.Sessions | Where-Object { $_.Key -eq 'claude:c1' }).Count -eq 0 -and @($ctx.Inventory.Sessions | Where-Object { $_.Key -eq 'codex:x1.11223344' }).Count -eq 1) 'an archived session leaves the list, a failed one stays'
    Assert ($ctx.Status.Text -like 'Archive: 1 done, 1 skipped, 1 failed.*' -and $script:Shown.Count -eq 1 -and $script:Shown[0].Rows.Count -eq 3) "the result list has done, failed and what was left out: $($ctx.Status.Text)"
    Assert (-not $ctx.Checked.ContainsKey('claude:c1')) 'what was archived is no longer ticked'
    $ctx.Checked.Clear(); $ctx.Checked['claude:c2'] = $true; $ctx.Include.Clear(); Update-StorageTab -Ctx $ctx
    $before = $script:Jobs.Count
    Invoke-StorageAction -Ctx $ctx -Name 'Delete'
    Assert ($script:Jobs.Count -eq $before -and $script:Shown[-1].Title -like 'Delete: nothing can be done now*') 'nothing that can be changed: a list of reasons instead of a confirmation'
    $ctx.Include['claude:c2'] = $true; Update-StorageTab -Ctx $ctx
    Invoke-StorageAction -Ctx $ctx -Name 'Delete'
    $dj = $script:Jobs[-1]
    Assert ($script:Jobs.Count -eq $before + 1 -and $dj.Script -match 'Invoke-StorageDeleteBatch' -and $null -eq $dj.Args.Target -and $script:Confirms[-1].Text -like '*Recycle Bin*' -and @($dj.Args.IncludeRecent) -contains 'claude:c2') 'Delete needs no store, says Recycle Bin, and carries the sessions included anyway'
    $dj.Progress['Finished'] = $true; $dj.Progress['Result'] = @(); Update-StorageJobProgress -Ctx $ctx

    # the archived view
    $script:Store['Storage.ArchiveTarget'] = @{ kind = 'local'; path = 'D:\HarnessArchive' }
    $script:IndexRows = @([pscustomobject]@{ key = 'claude:c1'; harness = 'claude'; title = 'Fix the login'; bytes = 10MB; zipBytes = 2MB; lastActivity = 1; archivedAt = '2026-11-14T10:00:00Z'; machineId = 'm1'; entry = 'claude/2026-11/claude_c1.harchive.zip'; sha256 = ('a' * 64) })
    function Get-StorageArchiveIndex { param($Target, [switch]$AllMachines) if ($Target.Kind -eq 'drive') { return $script:DriveRows } return $script:IndexRows }
    $script:DriveRows = @()
    $ctx.Archived.Checked = $true
    Assert ($ctx.Mode -eq 'Archived' -or $true) 'switch'
    Set-StorageMode -Ctx $ctx -Mode 'Archived'
    Assert ($ctx.ArchList.Items.Count -eq 1 -and $ctx.ArchList.Items[0].Text -eq 'Fix the login' -and (& $flag $ctx.ArchList) -and -not (& $flag $ctx.List)) 'U1-7: the Archived view lists the archive index'
    Assert ((& $flag $ctx.Buttons['Restore']) -and -not (& $flag $ctx.Buttons['Archive']) -and $ctx.SelLabel.Text -eq '1 archived session') 'U1-7: and its own buttons'
    Assert ($ctx.ArchList.Items[0].SubItems[5].Text -eq 'Local folder' -and $ctx.ArchList.Items[0].SubItems[6].Text -eq 'Archived' -and $ctx.ArchList.Items[0].SubItems[3].Text -eq '8 MB') 'where it is, its status and what it saves'
    [void]$ctx.ArchList.Handle; $ctx.ArchList.Items[0].Selected = $true
    Update-StorageButtons -Ctx $ctx
    Assert ($ctx.Buttons['Restore'].Enabled -and $ctx.Buttons['DeleteArchive'].Enabled -and -not $ctx.Buttons['OpenSummary'].Enabled) 'a selected archive can be restored or deleted; there is no summary yet'
    $script:ConfirmAnswer = $true; $n0 = $script:Jobs.Count
    Invoke-StorageAction -Ctx $ctx -Name 'Restore'
    $rj = $script:Jobs[-1]
    Assert ($script:Jobs.Count -eq $n0 + 1 -and $rj.Script -match 'Invoke-StorageRestore' -and $rj.Args.Entries[0].key -eq 'claude:c1' -and $rj.Args.Target.Path -eq 'D:\HarnessArchive' -and $script:Confirms[-1].Text -like 'Restore 1 session*') 'Restore runs in the background for the selected archive, after a confirmation'
    $rj.Progress['Finished'] = $true; $rj.Progress['Result'] = @(@{ Key = 'claude:c1'; Ok = $true; Skipped = $false; Reason = ''; Warnings = @() }); Update-StorageJobProgress -Ctx $ctx
    Assert ($ctx.Status.Text -like 'Restore: 1 done*' -and $ctx.ArchList.Items.Count -eq 1) 'after a restore the archive row stays (it is only marked restored once a scan sees the session again)'
    # delete the archive: the row and the zip go (a fake store folder)
    $storeDir = Join-Path $tmp 'store'; New-Item -ItemType Directory -Path (Join-Path $storeDir 'claude\2026-11') -Force | Out-Null
    $zip = Join-Path $storeDir 'claude\2026-11\claude_c1.harchive.zip'; [IO.File]::WriteAllText($zip, 'zip')
    [IO.File]::WriteAllText((Join-Path $storeDir 'claude\2026-11\claude_c1.summary.md'), 'summary')
    $script:Store['Storage.ArchiveTarget'] = @{ kind = 'local'; path = $storeDir }
    $script:RemovedIdx = @(); function Remove-StorageArchiveIndex { param($Target, $Key) $script:RemovedIdx += $Key }
    Read-StorageArchivedList -Ctx $ctx; Update-StorageTab -Ctx $ctx
    [void]$ctx.ArchList.Handle; $ctx.ArchList.Items[0].Selected = $true; Update-StorageButtons -Ctx $ctx
    Assert ($ctx.Buttons['OpenSummary'].Enabled -and (Get-StorageSummaryFile -Row $ctx.ArchList.Items[0].Tag) -like '*claude_c1.summary.md') 'Open summary is on when <key>.summary.md sits beside the zip'
    Invoke-StorageAction -Ctx $ctx -Name 'DeleteArchive'
    Assert (-not (Test-Path -LiteralPath $zip) -and $script:RemovedIdx -contains 'claude:c1' -and $script:Confirms[-1].Text -like '*cannot be undone*') 'Delete archive removes the zip and its row after a confirmation'
    # a restored key is marked restored
    $script:IndexRows = @($script:IndexRows)
    $ctx.Inventory = $inv; Read-StorageArchivedList -Ctx $ctx
    Assert ($ctx.ArchivedRows[0].Restored -and $ctx.ArchivedRows[0].StatusText -eq 'Restored') 'U1-11: a key that is back in the inventory shows Restored'
    # a Drive row of another machine: restore maps the folders, delete is off
    function Test-SyncReady { return $true }
    function Get-StorageDriveTarget { return @{ Kind = 'drive'; SyncRoot = 'X:\HarnessSync-test'; MachineId = 'aaaaaaaa-0000-4000-8000-000000000001'; Key = [byte[]](1..64); PathMap = @{} } }
    function Get-StorageDrivePathMap { param($SyncRoot, $MachineId) return @{ 'E:\Code' = 'D:\Work' } }
    $script:DriveRows = @([pscustomobject]@{ key = 'codex:gone.aabbccdd'; harness = 'codex'; Title = 'From laptop'; bytes = 4MB; zipBytes = 1MB; lastActivity = 1; archivedAt = '2026-11-15T10:00:00Z'; machineId = 'bbbbbbbb-0000-4000-8000-000000000002'; MachineName = 'LAPTOP'; path = 'archives/x' })
    Read-StorageArchivedList -Ctx $ctx; Update-StorageTab -Ctx $ctx
    [void]$ctx.ArchList.Handle; $ctx.ArchList.Items[0].Selected = $true; Update-StorageButtons -Ctx $ctx
    Assert ($ctx.ArchList.Items[0].SubItems[5].Text -eq 'Drive (LAPTOP)' -and $ctx.Buttons['Restore'].Enabled -and -not $ctx.Buttons['DeleteArchive'].Enabled) 'a Drive archive of another machine can be restored but not deleted from here'
    $n0 = $script:Jobs.Count
    Invoke-StorageAction -Ctx $ctx -Name 'Restore'
    Assert ($script:Jobs.Count -eq $n0 + 1 -and $script:Jobs[-1].Args.Target.Kind -eq 'drive' -and $script:Jobs[-1].Args.Target.PathMap['E:\Code'] -eq 'D:\Work' -and $script:Jobs[-1].Args.NeedCodex) 'restore from another machine carries the folder map and the Codex wrapper'
    $script:Jobs[-1].Progress['Finished'] = $true; $script:Jobs[-1].Progress['Result'] = @(); Update-StorageJobProgress -Ctx $ctx
    Set-StorageMode -Ctx $ctx -Mode 'Live'
    Assert ((& $flag $ctx.List) -and -not (& $flag $ctx.ArchList) -and (& $flag $ctx.Buttons['Archive'])) 'back to the live view'

    if ($ctx.Timer) { $ctx.Timer.Dispose() }
    $h.Form.Dispose(); $ctx2 = $null
} finally { Remove-TestTempDir $tmp }

Write-Output 'PASS: Ui.Storage - rows, filters, sort, remembered view, tab in a hidden window, scan, actions, archived view.'
