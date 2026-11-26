$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
foreach ($f in 'Ui.ChatStatus', 'Ui.Main', 'Ui.MainChats', 'Ui.MainDrive', 'Ui.Storage', 'Ui.StorageActions') { . (Join-Path $root "src\$f.ps1") }

# ---- fakes for what ClaudeSwitcher.ps1 and the harness layer give the window --------------------------------------------
$script:Store = @{}
function Get-Setting { param($Name) return $script:Store[$Name] }
function Set-Setting { param($Name, $Value) $script:Store[$Name] = $Value }
function Write-HarnessLog { param($Message) $script:Logged += , $Message }
$script:Logged = @()
function Get-HarnessDisplayName { param($Harness) $Harness.Name.Substring(0, 1).ToUpperInvariant() + $Harness.Name.Substring(1) }
function Test-HarnessInstalled { param($Harness) return [bool]$Harness.Adapter.Installed }
$script:FakeCatalog = @()
$script:FakeState = @{}
$script:SyncOn = $true
function Test-SyncReady { return $script:SyncOn }
function Get-SyncSession { return [pscustomobject]@{ Root = 'X:\none'; Key = [byte[]](1..4) } }
function Get-SyncCatalog { param($Root, $Key) return $script:FakeCatalog }
function Get-SyncState { return $script:FakeState }
function Get-SyncPathRoots { return @{ Work = 'D:\Work' } }
$script:Harnesses = @()
function Get-Harnesses { return $script:Harnesses }
function Get-Harness { param($Name) return ($script:Harnesses | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
function New-FakeHarness($name, $installed, $chats, [switch]$NoNew) {
    $profiles = @([pscustomobject]@{ Harness = $name; Id = 'Default'; Name = 'Default'; Pid = $null; IsDefault = $true })
    $ad = @{ Installed = $installed; Detect = { [pscustomobject]@{ Installed = $true } }; GetProfiles = { $profiles }.GetNewClosure(); Launch = { param($p) 'launched' }; ListChats = { param($p) $chats }.GetNewClosure() }
    if (-not $NoNew) { $ad['NewProfile'] = { param($n) 'ok' }; $ad['NewShortcut'] = { param($p, $d) 'ok' } }
    [pscustomobject]@{ Name = $name; Adapter = $ad }
}

# ---- pure helpers ---------------------------------------------------------------------------------------------------------
$bullet = [string][char]0x25CF
Assert ((Get-DriveTabBadge -Statuses @('UpToDate', 'NotHere')) -eq $false) 'badge: nothing to do'
Assert ((Get-DriveTabBadge -Statuses @('UpToDate', 'DriveNewer')) -eq $true) 'badge: newer on drive'
Assert ((Get-DriveTabBadge -Statuses @('Diverged')) -eq $true) 'badge: diverged'
Assert ((Get-DriveTabBadge -Statuses @()) -eq $false) 'badge: empty'
Assert ((Get-DriveTabText -Badge $false) -eq 'Drive') 'tab text plain'
Assert ((Get-DriveTabText -Badge $true) -eq "Drive $bullet") 'tab text with dot'

Assert ((Get-MainLastTab) -eq 'claude') 'default tab'
Set-MainLastTab -Key 'drive'
Assert ((Get-MainLastTab) -eq 'drive' -and $script:Store['Ui.LastTab'] -eq 'drive') 'tab is stored and read back'
$script:Store['Ui.LastTab'] = 'nonsense'
Assert ((Get-MainLastTab) -eq 'claude') 'an unknown stored tab falls back to claude'
Set-MainLastTab -Key 'bogus'
Assert ($script:Store['Ui.LastTab'] -eq 'nonsense') 'an unknown tab is not stored'

# chat rows: one per state
$chat = [pscustomobject]@{ ChatId = 'c1'; Title = 'Fix login'; Cwd = $root; Activity = 1000 }
$gone = [pscustomobject]@{ ChatId = 'c2'; Title = 'Notes'; Cwd = 'Q:\no\such\folder'; Activity = 2000 }
$none = [pscustomobject]@{ ChatId = 'c3'; Title = 'Loose'; Cwd = $null; Activity = 3000 }
$rowOf = { param($sync, $c, [bool]$miss = $false) Get-ChatListRow -Chat $c -Status ([pscustomobject]@{ Sync = $sync; Row = [pscustomobject]@{ MachineName = 'LAPTOP'; pushedAt = 1000; lastActivityAt = 1000 }; FromMachine = 'LAPTOP'; CwdMissing = $miss }) }
$expect = @(
    @('NoSync', 'Set up Drive sync', 'none'), @('NotOnDrive', 'Not on Drive', 'off'), @('LocalNewer', 'Changed here, push to update', 'up'),
    @('DriveNewer', 'Newer on Drive (from LAPTOP)', 'down'), @('Diverged', 'Changed on both machines', 'warn'))
foreach ($e in $expect) {
    $r = & $rowOf $e[0] $chat
    Assert ($r.DriveText -eq $e[1] -and $r.ImageKey -eq $e[2]) "row view $($e[0]): '$($r.DriveText)' / $($r.ImageKey)"
}
$syn = & $rowOf 'Synced' $chat
Assert ($syn.DriveText -like 'On Drive, *' -and $syn.ImageKey -eq 'ok') "synced row view: $($syn.DriveText)"
$m = & $rowOf 'NotOnDrive' $gone $true
Assert ($m.CwdMissing -and $m.Folder -eq 'folder (not found)' -and $m.Tooltip -eq 'Q:\no\such\folder') "missing folder view: $($m.Folder)"
Assert ((& $rowOf 'NotOnDrive' $none).Folder -eq 'no folder') 'a chat without folder'
Assert ((& $rowOf 'NotOnDrive' $chat).Folder -eq (Split-Path $root -Leaf)) 'folder column shows the leaf'

# buttons
$a = Get-ChatPanelActions -Sync 'NotOnDrive' -HasSelection $false -CwdMissing $false -Gone $false
Assert ($a.Continue -and -not $a.Move -and -not $a.Push -and -not $a.Pull -and -not $a.Choose) 'no selection: only Continue'
$a = Get-ChatPanelActions -Sync 'NotOnDrive' -HasSelection $true -CwdMissing $false -Gone $false
Assert ($a.Move -and $a.Push -and -not $a.Pull -and -not $a.Choose -and $a.Highlight -eq 'Push') 'NotOnDrive: push is the move'
$a = Get-ChatPanelActions -Sync 'Synced' -HasSelection $true -CwdMissing $false -Gone $false
Assert ($a.Push -and -not $a.Pull -and -not $a.Highlight) 'Synced: nothing highlighted'
$a = Get-ChatPanelActions -Sync 'DriveNewer' -HasSelection $true -CwdMissing $false -Gone $false
Assert ($a.Pull -and $a.Highlight -eq 'Pull') 'DriveNewer: pull'
$a = Get-ChatPanelActions -Sync 'Diverged' -HasSelection $true -CwdMissing $true -Gone $false
Assert ($a.Pull -and $a.Choose -and $a.Highlight -eq 'Pull') 'Diverged with missing folder'
$a = Get-ChatPanelActions -Sync 'LocalNewer' -HasSelection $true -CwdMissing $false -Gone $false
Assert ($a.Highlight -eq 'Push' -and -not $a.Pull) 'LocalNewer: push'
$a = Get-ChatPanelActions -Sync 'NoSync' -HasSelection $true -CwdMissing $false -Gone $false
Assert ($a.Push -and $a.Pull) 'no sync yet: push and pull open the setup'
$a = Get-ChatPanelActions -Sync 'NotOnDrive' -HasSelection $true -CwdMissing $false -Gone $true
Assert (-not $a.Move -and -not $a.Push) 'a chat whose file is gone cannot be moved or pushed'

# search
$views = @((& $rowOf 'NotOnDrive' $chat), (& $rowOf 'NotOnDrive' $gone $true), (& $rowOf 'NotOnDrive' $none))
Assert (@(Select-ChatListRows -Rows $views -Text '').Count -eq 3) 'empty search keeps all'
Assert (@(Select-ChatListRows -Rows $views -Text 'NOTES').Count -eq 1) 'search by title, any case'
Assert (@(Select-ChatListRows -Rows $views -Text 'not found').Count -eq 1) 'search by folder column'
Assert (@(Select-ChatListRows -Rows $views -Text 'zzz').Count -eq 0) 'search with no hit'

# choose folder
$fix = Get-ChatFolderFix -Cwd 'D:\Work\proj\sub' -Roots @{ Work = 'D:\Work' }
Assert ($fix.Kind -eq 'root' -and $fix.Name -eq 'Work' -and $fix.OldPath -eq 'D:\Work') 'a folder under a known root fixes the root'
$fix = Get-ChatFolderFix -Cwd (Join-Path $root 'no-such-sub\deeper') -Roots @{ Work = 'D:\Work' }
Assert ($fix.Kind -eq 'open' -and $fix.Path -eq $root) "otherwise open the nearest existing parent: $($fix.Path)"
Assert ((Get-ChatFolderFix -Cwd 'Q:\a\b' -Roots @{}).Kind -eq 'none') 'nothing exists up the path: no fix'

# drive tab rows
$rows = @(
    [pscustomobject]@{ chatKey = 'claude:a'; bundleId = 'b1'; harness = 'claude'; Title = 'Same'; MachineName = 'LAPTOP'; lastActivityAt = 1000 },
    [pscustomobject]@{ chatKey = 'claude:b'; bundleId = 'b2'; harness = 'claude'; Title = 'Newer'; MachineName = 'LAPTOP'; lastActivityAt = 2000 },
    [pscustomobject]@{ chatKey = 'codex:c'; bundleId = 'b3'; harness = 'codex'; Title = 'Absent'; MachineName = 'LAPTOP'; lastActivityAt = 3000 },
    [pscustomobject]@{ chatKey = 'claude:d'; bundleId = 'b4'; harness = 'claude'; Title = 'Both'; MachineName = 'LAPTOP'; lastActivityAt = 4000 },
    [pscustomobject]@{ chatKey = 'claude:e'; bundleId = 'b5'; harness = 'claude'; Title = 'Edited here'; MachineName = 'LAPTOP'; lastActivityAt = 5000 })
$state = @{
    'claude:e' = @{ lastBundleId = 'b5'; localActivityAtSync = 100; profileId = 'Default' }
    'claude:a' = @{ lastBundleId = 'b1'; localActivityAtSync = 1000; profileId = 'Default' }
    'claude:b' = @{ lastBundleId = 'old'; localActivityAtSync = 500; profileId = 'Default' }
    'claude:d' = @{ lastBundleId = 'old'; localActivityAtSync = 100; profileId = 'Default' } }
$local = @{
    'a' = [pscustomobject]@{ ChatId = 'a'; Activity = 1000; Profile = [pscustomobject]@{ Id = 'Default' } }
    'b' = [pscustomobject]@{ ChatId = 'b'; Activity = 500; Profile = [pscustomobject]@{ Id = 'Default' } }
    'd' = [pscustomobject]@{ ChatId = 'd'; Activity = 900; Profile = [pscustomobject]@{ Id = 'Default' } }
    'e' = [pscustomobject]@{ ChatId = 'e'; Activity = 900; Profile = [pscustomobject]@{ Id = 'Default' } } }
$lookup = New-MainChatLookup -LocalChats @($local.Values | ForEach-Object { [pscustomobject]@{ Harness = 'claude'; Chat = $_ } }) -State $state
$view = @(Get-DriveCatalogRows -Rows $rows -State $state -LocalChatLookup $lookup)
Assert ($view.Count -eq 5) 'drive tab: one view per row'
$by = @{}; foreach ($v in $view) { $by[$v.Row.Title] = $v }
Assert ($by['Same'].Status -eq 'UpToDate' -and $by['Same'].StatusText -eq 'Up to date') 'drive row UpToDate'
Assert ($by['Newer'].Status -eq 'DriveNewer' -and $by['Newer'].StatusText -eq 'Newer on Drive') 'drive row DriveNewer'
Assert ($by['Absent'].Status -eq 'NotHere' -and $by['Absent'].StatusText -eq 'Not here') 'drive row NotHere'
Assert ($by['Both'].Status -eq 'Diverged' -and $by['Both'].StatusText -eq 'Changed on both') 'drive row Diverged'
Assert ($by['Edited here'].Status -eq 'LocalNewer' -and $by['Edited here'].StatusText -eq 'Changed here, not pushed') 'drive row LocalNewer, as the chat list says'
Assert ($by['Newer'].HarnessText -eq 'Claude') 'drive row harness name'
# the two tabs never disagree about a chat
foreach ($k in 'a', 'b', 'd', 'e') {
    $row = $rows | Where-Object { $_.chatKey -eq "claude:$k" }
    $s1 = Get-HarnessChatSyncStatus -Chat $local[$k] -Harness 'claude' -Catalog @($row) -State $state
    $want = @{ Synced = 'UpToDate'; LocalNewer = 'LocalNewer'; DriveNewer = 'DriveNewer'; Diverged = 'Diverged' }[$s1.Sync]
    Assert ($by[$row.Title].Status -eq $want) "chat '$($row.Title)': list says $($s1.Sync), Drive tab says $($by[$row.Title].Status)"
}
$need = @(Get-DriveCatalogRows -Rows $rows -State $state -LocalChatLookup $lookup -NeedsActionOnly)
Assert ($need.Count -eq 2 -and (@($need | ForEach-Object { $_.Status } | Sort-Object) -join ',') -eq 'Diverged,DriveNewer') 'needs-action filter keeps DriveNewer and Diverged'

$targets = @(
    [pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default'; IsDefault = $true },
    [pscustomobject]@{ Harness = 'claude'; Id = 'Work2'; Name = 'Work2'; IsDefault = $false },
    [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default'; IsDefault = $true })
$t = Get-DefaultPullTarget -Row $rows[1] -State @{ 'claude:b' = @{ profileId = 'Work2' } } -Targets $targets
Assert ($t.Id -eq 'Work2' -and $t.Harness -eq 'claude') 'pull target: the profile that received it before'
$t = Get-DefaultPullTarget -Row $rows[1] -State @{} -Targets $targets
Assert ($t.Id -eq 'Default' -and $t.Harness -eq 'claude') 'pull target: Default of the same harness'
$t = Get-DefaultPullTarget -Row $rows[2] -State @{} -Targets $targets
Assert ($t.Harness -eq 'codex') 'pull target: the harness of the row'

# the move dialog never offers the profile the chat is already in
$mt = @(
    [pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default' }, [pscustomobject]@{ Harness = 'claude'; Id = 'Work2'; Name = 'Work2' },
    [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default' })
. (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.Harness.ps1')) -Names @('Get-HarnessMoveTargets'))
$mc = [pscustomobject]@{ ChatId = 'a'; Profile = [pscustomobject]@{ Id = 'Default' } }
$left = @(Get-HarnessMoveTargets -Chat $mc -SourceHarness 'claude' -Targets $mt)
Assert ($left.Count -eq 2 -and -not ($left | Where-Object { $_.Harness -eq 'claude' -and $_.Id -eq 'Default' })) 'the source profile is not a target (same id in another harness stays)'
Assert (@(Get-HarnessMoveTargets -Chat ([pscustomobject]@{ ChatId = 'a' }) -SourceHarness 'claude' -Targets $mt).Count -eq 3) 'a chat without profile keeps every target'

# the setup wizard: step 2 has two password boxes that are on the page and wide enough (the wizard is built, never shown)
. (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.Sync.ps1')) -Names @('Test-SyncSetupInput'))
. (Join-Path $root 'src\Ui.SyncWizard.ps1')
$bg = [System.Drawing.Color]::FromArgb(250, 249, 245); $ink = [System.Drawing.Color]::FromArgb(38, 38, 36); $fontUI = New-Object System.Drawing.Font('Segoe UI', 9.5)
function Get-SyncSetupChoices { return @([pscustomobject]@{ Kind = 'drive'; Token = 't'; Text = 'Drive A'; Existing = $false }) }
function Get-SyncWizardCwds { return @() }
$wast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\Ui.SyncWizard.ps1'), [ref]$null, [ref]$null)
$wdef = $wast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-SyncSetupWizard' }, $true) | Select-Object -First 1
$wtext = $wdef.Extent.Text -replace '(?m)\[void\]\$dlg\.ShowDialog\(\)', '$pg1.List.SelectedIndex = 0; $nav.Page = 2; & $refresh; $script:Wiz = @{ Dlg = $dlg; Pg2 = $pg2; Panel = $panels[1] }; return'
Assert ($wtext -ne $wdef.Extent.Text) 'wizard: ShowDialog call found'
. ([scriptblock]::Create(($wtext -replace '^function Show-SyncSetupWizard', 'function Build-WizardForTest')))
Build-WizardForTest
$flag = { param($c) [bool][System.Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance', $null, [Type[]]@([int]), $null).Invoke($c, @(2)) }
Assert (& $flag $script:Wiz.Panel) 'wizard: the step 2 panel is the visible one'
foreach ($tb in $script:Wiz.Pg2.Pass1, $script:Wiz.Pg2.Pass2) {
    Assert ($tb.UseSystemPasswordChar -and (& $flag $tb) -and $tb.Width -ge 200 -and $tb.Height -gt 10) 'wizard: passphrase box is a visible password box, wide enough'
    Assert ($script:Wiz.Panel.ClientRectangle.Contains($tb.Bounds) -and [object]::ReferenceEquals($tb.Parent, $script:Wiz.Panel)) 'wizard: passphrase box sits inside the step 2 panel'
}
$script:Wiz.Dlg.Dispose()

# profile panel title: "<name> accounts" when accounts can be added, the plain name otherwise
$titleOf = { param($h) @((New-HarnessProfilePanel -Harness $h).Panel.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] })[0].Text }
Assert ((& $titleOf (New-FakeHarness 'codex' $true @())) -eq 'Codex accounts') 'Codex tab title'
Assert ((& $titleOf (New-FakeHarness 'antigravity' $true @() -NoNew)) -eq 'Antigravity') 'Antigravity tab title'

# profile panel buttons
Assert ((Get-ProfilePanelButtons -Adapter @{ NewProfile = {}; NewShortcut = {} }) -join ',' -eq 'Launch,Add account,Shortcuts') 'profile buttons with everything'
Assert ((Get-ProfilePanelButtons -Adapter @{ NewShortcut = {} }) -join ',' -eq 'Launch,Shortcuts') 'no Add account without NewProfile'
Assert ((Get-ProfilePanelButtons -Adapter @{}) -join ',' -eq 'Launch') 'Launch is always there'

# ---- the chat panel on a real (never shown) control tree --------------------------------------------------------------------
$c1 = [pscustomobject]@{ ChatId = 'a'; Title = 'Same'; Cwd = $root; Activity = 1000 }
$c2 = [pscustomobject]@{ ChatId = 'b'; Title = 'Newer'; Cwd = $root; Activity = 500 }
$c3 = [pscustomobject]@{ ChatId = 'z'; Title = 'Alone'; Cwd = 'Q:\gone\dir'; Activity = 50 }
$script:Harnesses = @((New-FakeHarness 'claude' $true @($c1, $c2, $c3)))
$script:FakeCatalog = @($rows[0], $rows[1])
$script:FakeState = $state
$script:SyncOn = $true
$prof = $script:Harnesses[0].Adapter.GetProfiles.Invoke()[0]
$ctx = New-HarnessChatPanel -Harness $script:Harnesses[0] -GetProfile { $prof }.GetNewClosure()
Assert ($ctx.Panel -is [System.Windows.Forms.Control]) 'chat panel is a control'
[void]$ctx.List.Handle   # a ListView only keeps its selection once it has a window handle; it is never shown
Update-ChatPanel -Ctx $ctx -Load
$items = @($ctx.List.Items)
Assert ($items.Count -eq 3) "three chats listed, got $($items.Count)"
$byTitle = @{}; foreach ($i in $items) { $byTitle[$i.Text] = $i }
Assert (@($ctx.List.Columns | ForEach-Object { $_.Text }) -join '|' -eq ('Title|Folder|Last active ' + [char]0x25BC + '|Drive')) 'columns, newest first by default'
Assert ($byTitle['Same'].SubItems[3].Text -like 'On Drive*' -and $byTitle['Same'].ImageKey -eq 'ok') "Same: $($byTitle['Same'].SubItems[3].Text)"
Assert ($byTitle['Newer'].SubItems[3].Text -eq 'Newer on Drive (from LAPTOP)' -and $byTitle['Newer'].ImageKey -eq 'down') 'Newer'
Assert ($byTitle['Alone'].SubItems[3].Text -eq 'Not on Drive' -and $byTitle['Alone'].SubItems[1].Text -like '*(not found)') 'Alone: not on Drive, folder missing'
Assert ($ctx.List.SmallImageList.Images.ContainsKey('warn') -and $ctx.List.SmallImageList.Images.ContainsKey('off')) 'status icons are drawn into the image list'
Assert (-not $ctx.Buttons.Push.Enabled -and -not $ctx.Buttons.Move.Enabled -and $ctx.Buttons.Continue.Enabled) 'no selection: buttons off, Continue on'
$byTitle['Newer'].Selected = $true
Update-ChatButtons -Ctx $ctx
Assert ($ctx.Buttons.Pull.Enabled -and $ctx.Buttons.Push.Enabled -and $ctx.Buttons.Move.Enabled -and -not $ctx.Buttons.Choose.Enabled) 'DriveNewer chat: pull, push and move on'
$ctx.List.SelectedItems[0].Selected = $false
$ctx.List.Items | Where-Object { $_.Text -eq 'Alone' } | ForEach-Object { $_.Selected = $true }
Update-ChatButtons -Ctx $ctx
Assert ($ctx.Buttons.Choose.Enabled -and -not $ctx.Buttons.Pull.Enabled) 'missing folder: Choose folder on'
$ctx.Search.Text = 'alo'
Update-ChatPanel -Ctx $ctx
Assert ($ctx.List.Items.Count -eq 1 -and $ctx.List.Items[0].Text -eq 'Alone') 'the search box filters the loaded list'
$ctx.Search.Text = ''
$script:SyncOn = $false
Update-ChatPanel -Ctx $ctx -Load
Assert (@($ctx.List.Items | ForEach-Object { $_.SubItems[3].Text } | Select-Object -Unique) -join '' -eq 'Set up Drive sync') 'without sync every row says how to start'

# the handlers live on after New-HarnessChatPanel returned: a click reaches the right action with the right context
$script:Clicked = @()
function Invoke-ChatPanelAction { param($Ctx, $Name) $script:Clicked += $Name; $script:ClickCtx = $Ctx }
$click = { param($control) $control.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($control, @([EventArgs]::Empty)) }
foreach ($n in 'Continue', 'Move', 'Push', 'Pull', 'Choose') { & $click $ctx.Buttons[$n] }
& $click $ctx.Refresh
Assert (($script:Clicked -join ',') -eq 'Continue,Move,Push,Pull,Choose,Load') "button clicks: $($script:Clicked -join ',')"
Assert ([object]::ReferenceEquals($script:ClickCtx, $ctx)) 'the click handler holds the panel context'

# a harness that is not installed shows a note, not a list
$off = New-FakeHarness 'codex' $false @()
$note = New-HarnessMissingNote -Harness $off
Assert ($note -is [System.Windows.Forms.Control] -and $note.Text -like '*not installed*') 'missing harness note'

# ---- Convert-SwitcherToTabs -------------------------------------------------------------------------------------------------
function New-FakeSwitcherForm {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Claude Profile Switcher'
    $f.ClientSize = New-Object System.Drawing.Size(744, 481)
    $f.MinimumSize = New-Object System.Drawing.Size(700, 440)
    $lv = New-Object System.Windows.Forms.ListView; $lv.View = 'Details'; $lv.Location = '20,72'; $lv.Size = '704,318'; $lv.Anchor = 'Top,Left,Right,Bottom'
    $lv.Columns.Add('Profile', 200) | Out-Null
    $it = New-Object System.Windows.Forms.ListViewItem('Default'); $it.Tag = [pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default' }; $lv.Items.Add($it) | Out-Null
    $b1 = New-Object System.Windows.Forms.Button; $b1.Text = 'Launch'; $b1.Location = '20,426'; $b1.Size = '116,34'; $b1.Anchor = 'Left,Bottom'
    $b2 = New-Object System.Windows.Forms.Button; $b2.Text = 'Delete'; $b2.Location = '616,426'; $b2.Size = '108,34'; $b2.Anchor = 'Right,Bottom'
    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Claude accounts'; $l1.Location = '20,16'; $l1.Size = '400,28'
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'status'; $l2.Location = '21,398'; $l2.Size = '500,18'; $l2.Anchor = 'Left,Right,Bottom'
    $l1.AutoSize = $false; $l2.AutoSize = $false   # a Label sizes itself to its text by default, which would hide anchor effects
    foreach ($c in $l1, $lv, $l2, $b1, $b2) { $f.Controls.Add($c) }
    return $f
}
function Get-FormSnapshot($f) { @($f.Controls | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.GetType().Name, $_.Text, $_.Location, $_.Size, $_.Anchor }) -join ';' }
# The distances of each control to the edges it is anchored to: what an anchored layout keeps when its container is resized.
function Get-MarginSnapshot($c, $w, $h) {
    @($c.Controls | ForEach-Object {
        $a = [string]$_.Anchor
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.Text, $a, $(if ($a -match 'Left') { $_.Left } else { '-' }), $(if ($a -match 'Top') { $_.Top } else { '-' }),
            $(if ($a -match 'Right') { $w - $_.Right } else { '-' }), $(if ($a -match 'Bottom') { $h - $_.Bottom } else { '-' })
    }) -join ';'
}

$script:Harnesses = @((New-FakeHarness 'claude' $true @($c1)), (New-FakeHarness 'codex' $true @($c2)), (New-FakeHarness 'antigravity' $false @() -NoNew))
$form = New-FakeSwitcherForm
$before = Get-FormSnapshot $form
$beforeMargins = Get-MarginSnapshot $form $form.ClientSize.Width $form.ClientSize.Height
$beforeOrder = @($form.Controls | ForEach-Object { $_.GetType().Name + $_.Text }) -join ','
$origSize = $form.Size
[void]$form.Handle   # makes the tab pages take their real size; the form is never shown
$refreshed = $false
Convert-SwitcherToTabs -Form $form -RefreshClaude { $script:refreshedClaude = $true }
$tabs = @($form.Controls | Where-Object { $_ -is [System.Windows.Forms.TabControl] })
Assert ($tabs.Count -eq 1 -and $form.Controls.Count -eq 1) "the form holds only the TabControl, got $($form.Controls.Count) controls"
Assert ($tabs[0].TabPages.Count -eq 5 -and (@($tabs[0].TabPages | ForEach-Object { $_.Name }) -join ',') -eq 'claude,codex,antigravity,drive,storage') 'five tabs, Storage last'
Assert ($tabs[0].TabPages['storage'].Text -eq 'Storage' -and $tabs[0].TabPages['storage'].Controls.Count -eq 1) 'U1-2: the Storage tab holds its panel'
$stg = (Get-MainState).Storage
Assert ($stg -and $stg.ScanLabel.Text -like 'Not scanned yet*' -and -not $stg.Busy -and $null -eq $stg.Job) 'U1-2: Storage starts as Not scanned yet, nothing running'
$claudePage = $tabs[0].TabPages['claude']
$old = @($claudePage.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] -and $_.Name -eq 'switcherLegacy' })
Assert ($old.Count -eq 1) 'the old controls sit in one panel on the Claude tab'
Assert ($old[0].Controls.Count -eq 5) "all 5 old controls moved, got $($old[0].Controls.Count)"
Assert ((@($old[0].Controls | ForEach-Object { $_.GetType().Name + $_.Text }) -join ',') -eq $beforeOrder) "old controls keep their order: $(@($old[0].Controls | ForEach-Object { $_.GetType().Name + $_.Text }) -join ',') vs $beforeOrder"
# A tab page that was never shown keeps its default size; give it the size it has in a real window, as WinForms does on show.
$claudePage.Size = New-Object System.Drawing.Size(884, 680); $claudePage.PerformLayout()
Assert ($old[0].Width -eq 884 -and $old[0].Dock -eq 'Top') 'the legacy panel follows the width of the tab'
Assert ((Get-MarginSnapshot $old[0] $old[0].Width $old[0].Height) -eq $beforeMargins) "anchors and the distances to the anchored edges are unchanged`n$beforeMargins`n$(Get-MarginSnapshot $old[0] $old[0].Width $old[0].Height)"
Assert ($form.Size.Width -ge 900 -and $form.Size.Height -ge 720 -and $form.MinimumSize.Width -ge 820 -and $form.MinimumSize.Height -ge 620) "form grew: $($form.Size) / min $($form.MinimumSize)"
Assert ($old[0].Height -eq 481) 'the legacy panel is as tall as the old client area'
Assert ($form.Text -eq 'Profile Switcher') "window title is the shorter one, got '$($form.Text)'"
Assert ($null -ne (Get-MainState) -and (Get-MainState).Panels.ContainsKey('claude')) 'window state knows the Claude chat panel'

# a failure after the move puts everything back
function New-HarnessChatPanel { param($Harness, $GetProfile) throw 'boom' }
$form2 = New-FakeSwitcherForm
$before2 = Get-FormSnapshot $form2; $size2 = $form2.Size; $min2 = $form2.MinimumSize
$script:Logged = @()
$threw = $false
try { Convert-SwitcherToTabs -Form $form2 -RefreshClaude { } } catch { $threw = $true }
Assert (-not $threw) 'a failing conversion is logged, not thrown'
Assert ($form2.Controls.Count -eq 5 -and -not @($form2.Controls | Where-Object { $_ -is [System.Windows.Forms.TabControl] }).Count) "old controls back on the form, got $($form2.Controls.Count)"
Assert ((Get-FormSnapshot $form2) -eq $before2) 'restored controls keep position, size, anchor and order'
Assert ($form2.Size -eq $size2 -and $form2.MinimumSize -eq $min2) 'form size restored'
Assert ($form2.Text -eq 'Claude Profile Switcher') 'old title restored'
Assert ($script:Logged.Count -ge 1 -and ($script:Logged -join ' ') -like '*boom*') 'the failure is logged'

# ---- V4: nothing is read until a button is pressed ---------------------------------------------------------------------------
. (Join-Path $root 'src\Ui.MainChats.ps1')   # the earlier tests replaced some of its functions with fakes
$flag = { param($c) [bool][System.Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance', $null, [Type[]]@([int]), $null).Invoke($c, @(2)) }
$counter = @{ Calls = (New-Object Collections.ArrayList) }
function New-CountingHarness($name, $profiles, $chatsById) {
    $ad = @{ Installed = $true; Detect = { [pscustomobject]@{ Installed = $true } }; GetProfiles = { $profiles }.GetNewClosure(); Launch = { param($p) }
             ListChats = { param($p) [void]$counter.Calls.Add("$name|$($p.Id)"); $chatsById[[string]$p.Id] }.GetNewClosure() }
    [pscustomobject]@{ Name = $name; Adapter = $ad }
}
$pr = { param($h, $id) [pscustomobject]@{ Harness = $h; Id = $id; Name = $id; Pid = $null; IsDefault = ($id -eq 'Default') } }
$v1 = [pscustomobject]@{ ChatId = 'a'; Title = 'Same'; Cwd = $root; Activity = 1000 }
$v2 = [pscustomobject]@{ ChatId = 'b'; Title = 'Newer'; Cwd = $root; Activity = 500 }
$v3 = [pscustomobject]@{ ChatId = 'w'; Title = 'Work chat'; Cwd = $root; Activity = 700 }
$script:Harnesses = @(
    (New-CountingHarness 'claude' @((& $pr 'claude' 'Default'), (& $pr 'claude' 'Work2')) @{ Default = @($v1, $v2); Work2 = @($v3) }),
    (New-CountingHarness 'codex' @((& $pr 'codex' 'Default')) @{ Default = @($v1) }),
    (New-FakeHarness 'antigravity' $false @() -NoNew))
$script:CatalogCalls = 0
function Get-SyncCatalog { param($Root, $Key) $script:CatalogCalls++; return $script:FakeCatalog }
$script:SyncOn = $true
$formV4 = New-FakeSwitcherForm
$lvV4 = @($formV4.Controls | Where-Object { $_ -is [System.Windows.Forms.ListView] })[0]
$it2 = New-Object System.Windows.Forms.ListViewItem('Work2'); $it2.Tag = (& $pr 'claude' 'Work2'); [void]$lvV4.Items.Add($it2)
$lvV4.Items[0].Tag = (& $pr 'claude' 'Default')
[void]$lvV4.Handle; $lvV4.Items[0].Selected = $true
Convert-SwitcherToTabs -Form $formV4 -RefreshClaude { }
$st = Get-MainState; $cp = $st.Panels['claude']
Assert ($counter.Calls.Count -eq 0 -and $script:CatalogCalls -eq 0) 'opening the window reads nothing'
function Start-StorageScan { $script:StorageScanCalls++; throw 'a scan must only start when Scan is pressed' }
foreach ($k in 'claude', 'codex', 'drive', 'storage', 'claude') { Update-MainTab -Key $k }
Assert ($counter.Calls.Count -eq 0 -and $script:CatalogCalls -eq 0 -and [int]$script:StorageScanCalls -eq 0) 'changing tabs reads nothing, and no storage scan starts'
Assert ($cp.List.Items.Count -eq 0 -and $cp.Status.Text -like '*not loaded*' -and (& $flag $cp.LoadButton)) 'before the first load: empty list, a note and the Load chats button'
Assert ($cp.LoadButton.Text -eq 'Load chats') 'the button says Load chats'
Update-ChatPanel -Ctx $cp -Load
Assert (($counter.Calls -join ',') -eq 'claude|Default' -and $script:CatalogCalls -eq 1) "Load reads the selected profile and the catalog once: $($counter.Calls -join ',') / $script:CatalogCalls"
Assert ($cp.List.Items.Count -eq 2 -and $cp.Status.Text -like 'Loaded *' -and -not (& $flag $cp.LoadButton)) 'after the load: the chats, a Loaded line, no button'
$lvV4.Items[0].Selected = $false; $lvV4.Items[1].Selected = $true
Update-ChatPanel -Ctx $cp
Assert ($counter.Calls.Count -eq 1 -and $cp.List.Items.Count -eq 0 -and (& $flag $cp.LoadButton)) 'another profile that was never loaded: nothing is read, the button is back'
Update-ChatPanel -Ctx $cp -Load
Assert (($counter.Calls -join ',') -eq 'claude|Default,claude|Work2' -and $cp.List.Items.Count -eq 1) 'Load of the second profile reads only that profile'
$lvV4.Items[1].Selected = $false; $lvV4.Items[0].Selected = $true
Update-ChatPanel -Ctx $cp
Assert ($counter.Calls.Count -eq 2 -and $cp.List.Items.Count -eq 2 -and $cp.Status.Text -like 'Loaded *') 'back to a loaded profile: shown from the cache, nothing is read'
Invoke-MainRefresh -Tab 'claude'
Assert ($counter.Calls.Count -eq 3 -and $counter.Calls[2] -eq 'claude|Default') 'Refresh on a harness tab reads only the selected profile'
Assert ($null -eq $st.LocalChats) 'the Drive tab has not read the local chats yet'
$before = $counter.Calls.Count
Update-MainTab -Key 'drive'
Assert ($counter.Calls.Count -eq $before -and $st.Drive.List.Items.Count -eq 0 -and $st.Drive.Status.Text -like '*Refresh*') 'the Drive tab asks for Refresh and reads nothing'
Invoke-MainRefresh -Tab 'drive'
Assert (($counter.Calls | Select-Object -Skip $before) -join ',' -eq 'claude|Default,claude|Work2,codex|Default') "Refresh on the Drive tab reads every installed profile: $(($counter.Calls | Select-Object -Skip $before) -join ',')"
Assert ($null -ne $st.LocalChats -and $st.Drive.List.Items.Count -gt 0) 'the Drive tab now lists the catalog'
$busyRan = $false
try { Use-ChatPanelBusy -Ctx $st.Drive -Block { $script:busyRan = $true }; $busyOk = $true } catch { $busyOk = $false }
Assert ($busyOk -and $script:busyRan -and -not $st.Drive.Busy) 'the Drive tab Refresh button can mark the tab busy: it has no chat buttons'
$after = $counter.Calls.Count
Update-MainTab -Key 'drive'; Update-MainTab -Key 'claude'
Assert ($counter.Calls.Count -eq $after) 'redrawing tabs after the Drive refresh reads nothing'
$formV4.Dispose()

# ---- V4: filter and sort (pure) ---------------------------------------------------------------------------------------------
$mk = {
    param($title, $sync, $folder, $act, [bool]$miss = $false)
    $c = [pscustomobject]@{ ChatId = $title; Title = $title; Cwd = $folder; Activity = $act }
    Get-ChatListRow -Chat $c -Status ([pscustomobject]@{ Sync = $sync; Row = [pscustomobject]@{ MachineName = 'M'; lastActivityAt = 1 }; FromMachine = 'M'; CwdMissing = $miss })
}
$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$set = @(
    (& $mk 'Beta' 'Synced' 'D:\zeta' ($now - 1000)), (& $mk 'alpha' 'LocalNewer' 'D:\Mid' ($now - 5000)), (& $mk 'Gamma' 'DriveNewer' 'D:\alef' ($now - 90000000)),
    (& $mk 'Delta' 'Diverged' 'D:\Mid' ($now - 2000)), (& $mk 'Eps' 'NotOnDrive' 'D:\x' ($now - 3000)), (& $mk 'Zed' 'NotOnDrive' 'Q:\gone' ($now - 4000) $true))
$titles = { param($rows) (@($rows | ForEach-Object { $_.Title }) -join ',') }
Assert (@(Select-ChatListRows -Rows $set -Text '' -Show 'All').Count -eq 6) 'show All'
Assert ((& $titles (Select-ChatListRows -Rows $set -Text '' -Show 'NeedsAction')) -eq 'alpha,Gamma,Delta,Zed') 'show Needs action: local newer, drive newer, diverged, folder missing'
Assert ((& $titles (Select-ChatListRows -Rows $set -Text '' -Show 'NotOnDrive')) -eq 'Eps,Zed') 'show Not on Drive'
Assert ((& $titles (Select-ChatListRows -Rows $set -Text '' -Show 'OnDrive')) -eq 'Beta,alpha,Gamma,Delta') 'show On Drive'
Assert ((& $titles (Select-ChatListRows -Rows $set -Text '' -Show 'FolderMissing')) -eq 'Zed') 'show Folder missing'
Assert ((& $titles (Select-ChatListRows -Rows $set -Text 'mid' -Show 'NeedsAction')) -eq 'alpha,Delta') 'search and show combine'
Assert ((& $titles (Select-ChatListRows -Rows $set -Text '')) -eq 'Beta,alpha,Gamma,Delta,Eps,Zed') 'no Show argument means All'
Assert ((& $titles (Sort-ChatListRows -Rows $set -Column 'Title' -Descending $false)) -eq 'alpha,Beta,Delta,Eps,Gamma,Zed') 'sort by title, any case, ascending'
Assert ((& $titles (Sort-ChatListRows -Rows $set -Column 'Title' -Descending $true)) -eq 'Zed,Gamma,Eps,Delta,Beta,alpha') 'sort by title descending'
Assert ((& $titles (Sort-ChatListRows -Rows $set -Column 'Folder' -Descending $false)) -eq 'Gamma,Zed,alpha,Delta,Eps,Beta') 'sort by folder text, any case, ties keep their order'
Assert ((& $titles (Sort-ChatListRows -Rows $set -Column 'Last active' -Descending $true)) -eq 'Beta,Delta,Eps,Zed,alpha,Gamma') 'sort by last active as a number, newest first'
Assert ((& $titles (Sort-ChatListRows -Rows $set -Column 'Last active' -Descending $false)) -eq 'Gamma,alpha,Zed,Eps,Delta,Beta') 'sort by last active, oldest first'
Assert ((& $titles (Sort-ChatListRows -Rows $set -Column 'Drive' -Descending $false)) -eq 'Delta,Gamma,alpha,Eps,Zed,Beta') 'sort by Drive: needs the most attention first, ties keep their order'
Assert ((& $titles (Sort-ChatListRows -Rows $set -Column 'Drive' -Descending $true)) -eq 'Beta,Eps,Zed,alpha,Gamma,Delta') 'sort by Drive, reversed'
Assert ((Get-ChatColumnHeader -Name 'Title' -SortColumn 'Title' -Descending $false) -eq ('Title ' + [char]0x25B2)) 'header arrow up'
Assert ((Get-ChatColumnHeader -Name 'Title' -SortColumn 'Title' -Descending $true) -eq ('Title ' + [char]0x25BC)) 'header arrow down'
Assert ((Get-ChatColumnHeader -Name 'Folder' -SortColumn 'Title' -Descending $true) -eq 'Folder') 'other headers stay plain'

# Drive tab: search, harness and sort
$dv = @(
    [pscustomobject]@{ Title = 'Fix'; HarnessText = 'Claude'; From = 'Laptop'; Activity = 3000; Status = 'UpToDate' }, [pscustomobject]@{ Title = 'Notes'; HarnessText = 'Codex'; From = 'Desk'; Activity = 9000; Status = 'DriveNewer' },
    [pscustomobject]@{ Title = 'Plan'; HarnessText = 'Claude'; From = 'Desk'; Activity = 1000; Status = 'Diverged' }, [pscustomobject]@{ Title = 'Idea'; HarnessText = 'Antigravity'; From = 'Laptop'; Activity = 5000; Status = 'NotHere' })
Assert ((& $titles (Select-DriveViews -Views $dv -Text '' -Harness 'Claude')) -eq 'Fix,Plan') 'drive filter by harness'
Assert ((& $titles (Select-DriveViews -Views $dv -Text 'no' -Harness 'All')) -eq 'Notes') 'drive search by title'
Assert ((& $titles (Select-DriveViews -Views (Select-DriveViews -Views $dv -Text '' -Harness 'Claude') -Text 'p' -Harness 'All')) -eq 'Plan') 'drive search and harness combine'
Assert ((& $titles (Sort-DriveViews -Views $dv -Column 'From' -Descending $false)) -eq 'Notes,Plan,Fix,Idea') 'drive sort by From, ties keep their order'
Assert ((& $titles (Sort-DriveViews -Views $dv -Column 'Last active' -Descending $true)) -eq 'Notes,Idea,Fix,Plan') 'drive sort by last active, number'
Assert ((& $titles (Sort-DriveViews -Views $dv -Column 'On this machine' -Descending $false)) -eq 'Plan,Notes,Idea,Fix') 'drive sort by status: needs action first'
Assert ((& $titles (Sort-DriveViews -Views $dv -Column 'Harness' -Descending $false)) -eq 'Idea,Fix,Plan,Notes') 'drive sort by harness'
$combined = Select-DriveViews -Views (@($dv | Where-Object { $_.Status -in 'DriveNewer', 'Diverged' })) -Text '' -Harness 'Claude'
Assert ((& $titles $combined) -eq 'Plan') 'harness filter after Needs action'

# remembered choices
$script:Store.Remove('Ui.ChatView.claude'); $script:Store.Remove('Ui.DriveView')
$d = Get-MainViewSetting -Name 'Ui.ChatView.claude' -Kind 'chat'
Assert ($d.show -eq 'All' -and $d.sortColumn -eq 'Last active' -and $d.descending -eq $true) 'chat view default: all, last active, newest first'
$dd = Get-MainViewSetting -Name 'Ui.DriveView' -Kind 'drive'
Assert ($dd.show -eq 'All' -and $dd.harness -eq 'All' -and $dd.sortColumn -eq 'Last active' -and $dd.descending -eq $true) 'drive view default'
Set-MainViewSetting -Name 'Ui.ChatView.claude' -View @{ show = 'NeedsAction'; sortColumn = 'Drive'; descending = $false }
$script:Store['Ui.ChatView.claude'] = (ConvertTo-Json $script:Store['Ui.ChatView.claude'] | ConvertFrom-Json)   # settings.json hands back an object, not a hashtable
$r = Get-MainViewSetting -Name 'Ui.ChatView.claude' -Kind 'chat'
Assert ($r.show -eq 'NeedsAction' -and $r.sortColumn -eq 'Drive' -and $r.descending -eq $false) 'chat view read back'
$script:Store['Ui.ChatView.claude'] = [pscustomobject]@{ show = 'bogus'; sortColumn = 'nope'; descending = 'x' }
$r = Get-MainViewSetting -Name 'Ui.ChatView.claude' -Kind 'chat'
Assert ($r.show -eq 'All' -and $r.sortColumn -eq 'Last active' -and $r.descending -eq $true) 'a damaged stored view falls back to the default'
Set-MainViewSetting -Name 'Ui.ChatView.claude' -View @{ show = 'FolderMissing'; sortColumn = 'Title'; descending = $true }
$script:Harnesses = @((New-FakeHarness 'claude' $true @($c1, $c2, $c3)))
$cp2 = New-HarnessChatPanel -Harness $script:Harnesses[0] -GetProfile { $null }
Assert ($cp2.View.show -eq 'FolderMissing' -and $cp2.ShowBox.SelectedItem -eq 'Folder missing' -and $cp2.View.sortColumn -eq 'Title' -and $cp2.View.descending -eq $true) 'a new panel starts from the remembered choice'
Assert ($cp2.List.Columns[0].Text -eq ('Title ' + [char]0x25BC)) 'the remembered sort shows in the header'
Set-MainViewSetting -Name 'Ui.DriveView' -View @{ show = 'NeedsAction'; harness = 'Codex'; sortColumn = 'From'; descending = $false }
$dd = Get-MainViewSetting -Name 'Ui.DriveView' -Kind 'drive'
Assert ($dd.show -eq 'NeedsAction' -and $dd.harness -eq 'Codex' -and $dd.sortColumn -eq 'From') 'drive view stored and read back'

# ---- layout: every button, box and list lies inside its parent at any window size -----------------------------------------------
# Controls were put at absolute positions with a Right anchor inside panels that were still 200 px wide, so WinForms kept a
# negative distance to the right edge and pushed them out of the window once the panel grew.
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
foreach ($size in @(@(900, 820), @(1200, 900))) {
    $fl = New-FakeSwitcherForm
    [void]$fl.Handle
    Convert-SwitcherToTabs -Form $fl -RefreshClaude { }
    $stl = Get-MainState
    $fl.ClientSize = New-Object System.Drawing.Size($size[0], $size[1])
    $stl.Tabs.Size = $fl.ClientSize
    foreach ($pg in $stl.Tabs.TabPages) { $pg.Size = $stl.Tabs.DisplayRectangle.Size }
    Invoke-DeepLayout $fl
    $bad = @(Get-OutOfBounds $fl)
    Assert ($bad.Count -eq 0) "controls outside their parent at $($size -join 'x'):`n$($bad -join "`n")"
    $fl.Dispose()
}

# ---- hook budget and the old dialog is gone ---------------------------------------------------------------------------------
$main = [IO.File]::ReadAllText((Join-Path $root 'ClaudeSwitcher.ps1'))
$errs = $null; [void][Management.Automation.Language.Parser]::ParseInput($main, [ref]$null, [ref]$errs)
Assert (-not $errs.Count) 'ClaudeSwitcher.ps1 parses'
$code = 0; $inBlock = $false
foreach ($line in ($main -split "`r?`n")) {
    if ($line -match '^\s*# >>> harness-') { $inBlock = $true; continue }
    if ($line -match '^\s*# <<< harness-') { $inBlock = $false; continue }
    if ($inBlock -and $line.Trim() -and $line.Trim() -notmatch '^#') { $code++ }
}
Assert ($code -le 30) "hook code lines are $code, the budget is 30"
Assert ($main -match '# >>> harness-ui-main' -and $main -match '# <<< harness-ui-main') 'harness-ui-main block exists'
Assert ($main -notmatch 'Show-HarnessExportDialog') 'menu and tray no longer open the old dialog'
foreach ($f in Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1') {
    Assert ([IO.File]::ReadAllText($f.FullName) -notmatch 'Show-HarnessExportDialog') "$($f.Name) still mentions the old dialog"
    Assert ((Get-Content $f.FullName | Measure-Object -Line).Lines -le 500) "$($f.Name) is over 500 lines"
}

Write-Output 'PASS: main window - tabs, chat rows and buttons, drive rows, profile panel, restore on failure, hook budget.'
