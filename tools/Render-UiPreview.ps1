# Renders the main window (its four tabs) and the dialogs of the chat list to PNG files, so the screens can be reviewed
# without opening a window on anybody's desktop: the forms get a window handle but are never shown, and everything they
# read comes from fake harnesses, a fake Drive catalog and a fake settings store. Nothing real is read or written.
# Output: <OutDir>\*.png (default: a new folder under %TEMP%); the paths are printed. Windows PowerShell 5.1 or 7.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) ('harness-ui-preview-' + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$env:COMPUTERNAME = 'PREVIEW-PC'   # this process only: the pictures must not carry the real machine name
foreach ($f in 'Ui.ChatStatus', 'Ui.Main', 'Ui.MainChats', 'Ui.MainDrive', 'Ui.Harness', 'Ui.Sync', 'Ui.SyncWizard', 'Ui.Tray') { . (Join-Path $Root "src\$f.ps1") }

# ---- the look of ClaudeSwitcher.ps1 --------------------------------------------------------------------------------------------
$bg = [System.Drawing.Color]::FromArgb(250, 249, 245); $ink = [System.Drawing.Color]::FromArgb(38, 38, 36); $muted = [System.Drawing.Color]::FromArgb(120, 118, 112)
$accent = [System.Drawing.Color]::FromArgb(203, 123, 93); $border = [System.Drawing.Color]::FromArgb(220, 217, 210); $running = [System.Drawing.Color]::FromArgb(46, 125, 74)
$fontUI = New-Object System.Drawing.Font('Segoe UI', 9.5); $fontBold = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 14); $fontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)

# ---- fakes: settings, Drive, harnesses -------------------------------------------------------------------------------------------
$script:Store = @{}
function Get-Setting { param($Name) return $script:Store[$Name] }
function Set-Setting { param($Name, $Value) $script:Store[$Name] = $Value }
function Write-HarnessLog { param($Message) Write-Host "log: $Message" }
function Show-Message { param($Text) Write-Host "message: $Text"; return 'OK' }
function Resolve-TransferMode { param($Source, $Target) if ($Source -eq $Target) { return 'native' } elseif ($Target -eq 'codex') { return 'codex-import' } else { return 'handoff' } }
function Test-SyncReady { return $true }
function Get-SyncSession { return [pscustomobject]@{ Root = 'X:\preview'; Key = [byte[]](1..4) } }
function Get-SyncPathRoots { return @{ Work = 'D:\Work'; Notes = 'E:\Notes' } }
function Resolve-SyncRoot { return [pscustomobject]@{ Path = 'G:\My Drive\HarnessSync'; Source = 'drive'; Reason = $null } }
function Get-SyncSetting { param($Name) if ($Name -eq 'DriveAccountToken') { return 'fake' } return $null }
function Get-DriveFsAccounts { return @([pscustomobject]@{ Token = 'fake'; Label = 'Drive account A'; MyDrive = 'G:\My Drive' }) }
function Get-SyncSetupChoices { return @([pscustomobject]@{ Kind = 'drive'; Token = 'fake'; Text = 'Google Drive: Drive account A'; Existing = $false }, [pscustomobject]@{ Kind = 'drive'; Token = 'fake2'; Text = 'Google Drive: Drive account B - sync already set up here'; Existing = $true }) }
function Get-SyncWizardCwds { return @('D:\Work\web-app', 'D:\Work\switcher', 'E:\Notes\import', 'C:\Users\someone\source\tool') }
function Get-HarnessTransferTargets {
    return @([pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default' }, [pscustomobject]@{ Harness = 'claude'; Id = 'Work2'; Name = 'Work2' }, [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default' })
}
$ms = { param($h, $m) [DateTimeOffset]::Now.AddHours(-$h).AddMinutes(-$m).ToUnixTimeMilliseconds() }
$t20 = & $ms 0 20   # one value, so the chat list and the Drive tab agree about this chat
$script:Rows = @(
    [pscustomobject]@{ chatKey = 'claude:c1'; bundleId = 'b1'; harness = 'claude'; Title = 'Fix login redirect'; MachineName = 'LAPTOP'; lastActivityAt = $t20 },
    [pscustomobject]@{ chatKey = 'claude:c2'; bundleId = 'b2'; harness = 'claude'; Title = 'Refactor tray menu'; MachineName = 'LAPTOP'; lastActivityAt = (& $ms 5 0) },
    [pscustomobject]@{ chatKey = 'claude:c3'; bundleId = 'b3'; harness = 'claude'; Title = 'Notes import'; MachineName = 'LAPTOP'; lastActivityAt = (& $ms 50 0) },
    [pscustomobject]@{ chatKey = 'codex:x1'; bundleId = 'b4'; harness = 'codex'; Title = 'Market research'; MachineName = 'LAPTOP'; lastActivityAt = (& $ms 30 0) })
$script:FakeState = @{
    'claude:c1' = @{ lastBundleId = 'b1'; localActivityAtSync = $t20; profileId = 'Default'; localChatId = 'c1' }
    'claude:c2' = @{ lastBundleId = 'old'; localActivityAtSync = (& $ms 30 0); profileId = 'Default'; localChatId = 'c2' }
    'claude:c3' = @{ lastBundleId = 'old'; localActivityAtSync = (& $ms 60 0); profileId = 'Default'; localChatId = 'c3' } }
function Get-SyncCatalog { param($Root, $Key) return $script:Rows }
function Get-SyncState { return $script:FakeState }
$here = $Root
$chatsClaude = @(
    [pscustomobject]@{ ChatId = 'c1'; Title = 'Fix login redirect'; Cwd = $here; Activity = $t20 },
    [pscustomobject]@{ ChatId = 'c2'; Title = 'Refactor tray menu'; Cwd = $here; Activity = (& $ms 3 0) },
    [pscustomobject]@{ ChatId = 'c3'; Title = 'Notes import'; Cwd = 'Q:\gone\notes'; Activity = (& $ms 60 0) },
    [pscustomobject]@{ ChatId = 'c4'; Title = 'Draft spec'; Cwd = $here; Activity = (& $ms 70 0) })
$chatsCodex = @([pscustomobject]@{ ChatId = 'x1'; Title = 'Market research'; Cwd = $here; Activity = (& $ms 30 0) }, [pscustomobject]@{ ChatId = 'x2'; Title = 'Parser bug'; Cwd = $here; Activity = (& $ms 8 0) })
function New-PreviewHarness($name, $profiles, $chats, $installed) {
    $ad = @{ Detect = { [pscustomobject]@{ Installed = $installed } }.GetNewClosure(); GetProfiles = { $profiles }.GetNewClosure(); Launch = { param($p) }; ListChats = { param($p) $chats }.GetNewClosure() }
    if ($name -ne 'antigravity') { $ad['NewProfile'] = { param($n) 'ok' }; $ad['NewShortcut'] = { param($p, $d) 'ok' } }
    [pscustomobject]@{ Name = $name; Adapter = $ad }
}
$prof = { param($h, $id, $name, $pid1) [pscustomobject]@{ Harness = $h; Id = $id; Name = $name; Pid = $pid1; IsDefault = ($id -eq 'Default'); Account = $(if ($h -eq 'codex') { 'ChatGPT account' } else { 'Google account' }) } }
$script:Harnesses = @(
    (New-PreviewHarness 'claude' @((& $prof 'claude' 'Default' 'Default' 4242), (& $prof 'claude' 'Work2' 'Work2' $null)) $chatsClaude $true),
    (New-PreviewHarness 'codex' @((& $prof 'codex' 'Default' 'Default' $null), (& $prof 'codex' 'Spare' 'Spare' $null)) $chatsCodex $true),
    (New-PreviewHarness 'antigravity' @((& $prof 'antigravity' 'Default' 'Default' $null)) @([pscustomobject]@{ ChatId = 'a1'; Title = 'Landing page copy'; Cwd = $null; Activity = (& $ms 2 0) }) $true))
function Get-Harnesses { return $script:Harnesses }
function Get-Harness { param($Name) return ($script:Harnesses | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
function Test-HarnessInstalled { param($Harness) return [bool](& $Harness.Adapter.Detect).Installed }
function Get-HarnessDisplayName { param($Harness) $Harness.Name.Substring(0, 1).ToUpperInvariant() + $Harness.Name.Substring(1) }

# ---- the window as ClaudeSwitcher.ps1 builds it (same texts, positions and anchors) ----------------------------------------------
function New-PreviewSwitcherForm {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Claude Profile Switcher'; $f.ClientSize = New-Object System.Drawing.Size(744, 481); $f.MinimumSize = New-Object System.Drawing.Size(700, 440)
    $f.BackColor = $bg; $f.Font = $fontUI
    $add = { param($c, $x, $y, $w, $h, $a) $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($w, $h); if ($a) { $c.Anchor = $a }; $f.Controls.Add($c) }
    $t = New-Object System.Windows.Forms.Label; $t.Text = 'Claude accounts'; $t.Font = $fontTitle; $t.ForeColor = $ink; $t.AutoSize = $false; & $add $t 20 16 400 28 $null
    $s = New-Object System.Windows.Forms.Label; $s.Text = 'Each profile is a separate login. Several can run at the same time. Right-click a profile for more.'; $s.Font = $fontSmall; $s.ForeColor = $muted; $s.AutoSize = $false; & $add $s 21 44 700 18 $null
    $lv = New-Object System.Windows.Forms.ListView; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.BackColor = [System.Drawing.Color]::White
    foreach ($c in @(@('Profile', 210), @('Status', 150), @('Last used', 170), @('', 150))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    foreach ($r in @(@('Default', 'Running', 'now', 'your original'), @('Work2', 'Not running', '10 Nov 2026, 09:12', ''))) {
        $it = New-Object System.Windows.Forms.ListViewItem($r[0]); $it.Tag = [pscustomobject]@{ Harness = 'claude'; Id = $r[0]; Name = $r[0] }
        foreach ($x in $r[1..3]) { [void]$it.SubItems.Add($x) }
        [void]$lv.Items.Add($it)
    }
    & $add $lv 20 72 704 318 'Top,Left,Right,Bottom'
    $st = New-Object System.Windows.Forms.Label; $st.Text = '2 profile(s), 1 running   |   Claude 1.0'; $st.Font = $fontSmall; $st.ForeColor = $muted; $st.AutoSize = $false; & $add $st 21 398 500 18 'Left,Right,Bottom'
    $ck = New-Object System.Windows.Forms.CheckBox; $ck.Text = 'Keep running in the tray'; $ck.Font = $fontSmall; $ck.ForeColor = $muted; $ck.Checked = $true; & $add $ck 544 396 180 22 'Right,Bottom'
    foreach ($b in @(@('Launch', 20, 116, 'Left,Bottom'), @('Add account', 144, 108, 'Left,Bottom'), @('Rename', 260, 92, 'Left,Bottom'), @('Add shortcuts', 360, 116, 'Left,Bottom'), @('Transfer chats', 484, 116, 'Left,Bottom'), @('Delete', 616, 108, 'Right,Bottom'))) {
        $bt = New-Object System.Windows.Forms.Button; $bt.Text = $b[0]; $bt.FlatStyle = 'Flat'; $bt.BackColor = [System.Drawing.Color]::White; $bt.ForeColor = $ink
        $bt.FlatAppearance.BorderColor = $border; if ($b[0] -eq 'Launch') { $bt.BackColor = $accent; $bt.ForeColor = [System.Drawing.Color]::White }
        & $add $bt $b[1] 426 $b[2] 34 $b[3]
    }
    return $f
}

# A form that is never shown does not paint the page of a TabControl, so the page is drawn on its own and placed onto the
# picture of the window (the frame and the tab strip) where it would be.
function Save-PreviewForm {
    param($Form, [string]$Name, $Page, $Tabs)
    # Create the windows of the form and everything on it even though nothing is visible (the private overload that ignores Visible).
    $create = [System.Windows.Forms.Control].GetMethod('CreateControl', [Reflection.BindingFlags]'NonPublic,Instance', $null, [Type[]]@([bool]), $null)
    [void]$create.Invoke($Form, @($true))
    $Form.PerformLayout()
    $bmp = New-Object System.Drawing.Bitmap($Form.Width, $Form.Height)
    try {
        $Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)))
        if ($Page) {
            [void]$create.Invoke($Page, @($true))
            $pb = New-Object System.Drawing.Bitmap($Page.Width, $Page.Height)
            $Page.DrawToBitmap($pb, (New-Object System.Drawing.Rectangle(0, 0, $Page.Width, $Page.Height)))
            $border = [int](($Form.Width - $Form.ClientSize.Width) / 2)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.DrawImage($pb, $border + $Tabs.Left + $Page.Left, ($Form.Height - $Form.ClientSize.Height - $border) + $Tabs.Top + $Page.Top)
            $g.Dispose(); $pb.Dispose()
        }
        # A text box is not painted by DrawToBitmap on a form that was never shown, so draw its frame and text here.
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $edge = [int](($Form.Width - $Form.ClientSize.Width) / 2); $top = $Form.Height - $Form.ClientSize.Height - $edge
        # Control.Visible is false for everything on a form that is not shown, so read each control's own visible flag.
        $getState = [System.Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance', $null, [Type[]]@([int]), $null)
        $stack = New-Object Collections.Generic.Stack[object]; $stack.Push(@($Form, 0, 0, $true))
        while ($stack.Count) {
            $item = $stack.Pop(); $parent = $item[0]
            foreach ($c in $parent.Controls) {
                $x = $item[1] + $c.Left; $y = $item[2] + $c.Top
                $on = ($item[3] -and [bool]$getState.Invoke($c, @(2)))
                if ($c -is [System.Windows.Forms.TextBox] -and $on) {
                    $r = New-Object System.Drawing.Rectangle(($edge + $x), ($top + $y), $c.Width, $c.Height)
                    $g.FillRectangle([System.Drawing.Brushes]::White, $r); $g.DrawRectangle([System.Drawing.Pens]::Gray, $r)
                    $shown = $(if ($c.UseSystemPasswordChar) { [string]([char]0x25CF) * $c.Text.Length } else { $c.Text })
                    $g.DrawString($shown, $c.Font, [System.Drawing.Brushes]::Black, ($r.X + 3), ($r.Y + 4))
                }
                if ($c.Controls.Count) { $stack.Push(@($c, $x, $y, $on)) }
            }
        }
        $g.Dispose()
        $path = Join-Path $OutDir "$Name.png"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host $path
    } finally { $bmp.Dispose() }
}

# Runs a dialog function with its ShowDialog call replaced by "draw pictures and carry on", so it is built but never shown.
function Get-PreviewFunction {
    param([string]$File, [string]$Name, [string]$Replacement)
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root "src\$File"), [ref]$null, [ref]$null)
    $def = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
    $text = $def.Extent.Text -replace '(?m)\[void\]\$dlg\.ShowDialog\(\)', $Replacement
    if ($text -eq $def.Extent.Text) { throw "ShowDialog call not found in $Name" }
    return [scriptblock]::Create(($text -replace ('^function ' + $Name), ('function global:Preview-' + $Name)))
}

# ---- the four tabs ---------------------------------------------------------------------------------------------------------
$form = New-PreviewSwitcherForm
Convert-SwitcherToTabs -Form $form -RefreshClaude { }
$st = Get-MainState
if (-not $st.Tabs) { throw 'The tabbed window was not built (see the log lines above).' }
Update-MainCatalog
[void]$form.Handle
foreach ($k in Get-MainTabKeys) {
    $st.Tabs.SelectedTab = $st.Tabs.TabPages[$k]
    foreach ($pg in $st.Tabs.TabPages) { $pg.Size = $st.Tabs.DisplayRectangle.Size }
    $st.Tabs.PerformLayout()
    if ($k -eq 'claude') {
        $legacyList = @($st.Tabs.TabPages['claude'].Controls['switcherLegacy'].Controls | Where-Object { $_ -is [System.Windows.Forms.ListView] })[0]
        [void]$legacyList.Handle; $legacyList.Items[0].Selected = $true
    }
    if ($k -in 'codex', 'antigravity') { [void]$st.Profiles[$k].List.Handle }
    Update-MainTab -Key $k   # draws from the cache only: nothing is read until a button is pressed
    if ($k -eq 'claude') { Save-PreviewForm -Form $form -Name 'tab-claude-not-loaded' -Page $st.Tabs.TabPages[$k] -Tabs $st.Tabs }
    # What pressing Load chats / Refresh does.
    if ($k -eq 'drive') { Invoke-MainRefresh -Tab 'drive' } else { Update-ChatPanel -Ctx $st.Panels[$k] -Load }
    if ($k -in 'claude', 'codex', 'antigravity') { $panelCtx = $st.Panels[$k]; if ($panelCtx.List.Items.Count) { $panelCtx.List.Items[1 % $panelCtx.List.Items.Count].Selected = $true } }
    Update-MainTabBadge
    Save-PreviewForm -Form $form -Name ("tab-$k") -Page $st.Tabs.TabPages[$k] -Tabs $st.Tabs
    if ($k -eq 'claude') {   # a chosen sort (title, ascending) and filter (needs action)
        $c = $st.Panels[$k]; $c.View.show = 'NeedsAction'; $c.View.sortColumn = 'Title'; $c.View.descending = $false
        $c.ShowBox.SelectedItem = (Get-ChatShowChoices)['NeedsAction']; Update-ChatPanel -Ctx $c
        Save-PreviewForm -Form $form -Name 'tab-claude-filtered' -Page $st.Tabs.TabPages[$k] -Tabs $st.Tabs
    }
    if ($k -eq 'drive') {   # the Drive tab with a harness filter and a sort by title
        $dc = $st.Drive; $dc.HarnessBox.SelectedItem = 'Claude'; $dc.View.sortColumn = 'Title'; $dc.View.descending = $false; Update-SyncDriveTab -Ctx $dc
        Save-PreviewForm -Form $form -Name 'tab-drive-filtered' -Page $st.Tabs.TabPages[$k] -Tabs $st.Tabs
    }
}
$form.Dispose()

# ---- the dialogs ------------------------------------------------------------------------------------------------------------
$row = $script:Rows[1]
$d = New-SyncDivergedForm -Row $row -Chat $chatsClaude[1]
Save-PreviewForm -Form $d.Form -Name 'dialog-diverged'
$d.Form.Dispose()

. (Get-PreviewFunction -File 'Ui.Harness.ps1' -Name 'Show-HarnessMoveDialog' -Replacement '$list.SelectedIndex = 1; Save-PreviewForm -Form $dlg -Name "dialog-move"')
$moveChat = $chatsClaude[1].PSObject.Copy(); $moveChat | Add-Member -NotePropertyName Profile -NotePropertyValue ([pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default' })
[void](Preview-Show-HarnessMoveDialog -Chat $moveChat -SourceHarness 'claude')
. (Get-PreviewFunction -File 'Ui.SyncWizard.ps1' -Name 'Show-SyncSetupWizard' -Replacement 'Save-PreviewForm -Form $dlg -Name "dialog-wizard-1"; $pg1.List.SelectedIndex = 0; $nav.Page = 2; & $refresh; $pg2.Pass1.Text = "xxxxxxxxxxxx"; $pg2.Pass2.Text = "xxxxxxxxxxxx"; $pg2.Ack.Checked = $true; & $refresh; Save-PreviewForm -Form $dlg -Name "dialog-wizard-2"; $nav.Page = 3; & $refresh; Save-PreviewForm -Form $dlg -Name "dialog-wizard-3"')
[void](Preview-Show-SyncSetupWizard)
