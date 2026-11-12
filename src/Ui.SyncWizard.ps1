# Ui.SyncWizard.ps1 - the first-time Drive sync setup as three steps: Where, Passphrase, This machine (phase 5, lane V3).
# The functions down to Complete-SyncWizard are plain logic (tested without a window); Show-SyncSetupWizard is the
# WinForms shell on top of them. The passphrase is only ever held in the text boxes and in the state handed to
# Complete-SyncWizard: it is never logged, never put into a message and never stored (Invoke-SyncSetup keeps the key only).

# What the wizard shows for a state: @{ Page; Choice; Passphrase; Confirmation; Acknowledged }. Page 1 needs a choice,
# page 2 needs a valid passphrase (Test-SyncSetupInput; one field when the folder already holds sync.json), page 3 is
# the last one. The result carries the problems as sentences, never the passphrase.
function Get-SyncWizardStep {
    param([Parameter(Mandatory)]$State)
    $page = [Math]::Min(3, [Math]::Max(1, [int]$State['Page']))
    $choice = $State['Choice']
    $existing = [bool]($choice -and $choice.Existing)
    $problems = @()
    if ($page -eq 2) { $problems = @(Test-SyncSetupInput -Passphrase ([string]$State['Passphrase']) -Confirmation ([string]$State['Confirmation']) -Acknowledged ([bool]$State['Acknowledged']) -Existing:$existing) }
    return [pscustomobject]@{
        Page      = $page
        CanBack   = ($page -gt 1)
        CanNext   = (($page -eq 1 -and [bool]$choice) -or ($page -eq 2 -and $problems.Count -eq 0))
        CanFinish = ($page -eq 3 -and [bool]$choice)
        Existing  = $existing
        Problems  = $problems
    }
}

# The folder roots offered on step 3: Get-SuggestedPathRoots (Ui.ChatStatus.ps1) when it is loaded, nothing otherwise.
function Get-SyncWizardRoots {
    param([string[]]$Cwds = @())
    if (-not (Get-Command Get-SuggestedPathRoots -CommandType Function -ErrorAction SilentlyContinue)) { return @() }
    return @(Get-SuggestedPathRoots -Cwds $Cwds)
}

# The working folders of the most recent chats of every installed harness (for the suggestions).
function Get-SyncWizardCwds {
    param([int]$PerProfile = 30)
    $cwds = New-Object Collections.Generic.List[string]
    foreach ($p in @(Get-HarnessTransferTargets)) {
        try {
            $chats = @(& (Get-Harness -Name $p.Harness).Adapter.ListChats $p | Sort-Object Activity -Descending | Select-Object -First $PerProfile)
            foreach ($c in $chats) { if ($c.PSObject.Properties['Cwd'] -and $c.Cwd) { $cwds.Add([string]$c.Cwd) } }
        } catch { }
    }
    return $cwds.ToArray()
}

# The Finish button: validates, sets sync up (Invoke-SyncSetup), then saves the ticked folder roots. A root that cannot
# be saved is reported in RootErrors and does not stop the others. -Iterations and -MinIterations are only lowered by tests.
function Complete-SyncWizard {
    param([Parameter(Mandatory)]$State, [array]$Roots = @(), [int]$Iterations = 600000, [int]$MinIterations = 600000)
    $choice = $State['Choice']
    if (-not $choice) { throw 'Pick where the chats should be kept.' }
    $step = Get-SyncWizardStep -State @{ Page = 2; Choice = $choice; Passphrase = $State['Passphrase']; Confirmation = $State['Confirmation']; Acknowledged = $State['Acknowledged'] }
    if ($step.Problems.Count) { throw ($step.Problems -join ' ') }
    $args2 = @{ Passphrase = [string]$State['Passphrase']; Iterations = $Iterations; MinIterations = $MinIterations }
    if ($choice.Kind -eq 'drive') { $args2['DriveToken'] = $choice.Token } else { $args2['CustomPath'] = $choice.Path }
    $res = Invoke-SyncSetup @args2
    $rootErrors = New-Object Collections.Generic.List[string]
    foreach ($r in @($Roots)) {
        try { Set-SyncPathRoot -Name ([string]$r.Name) -Path ([string]$r.Path) } catch { $rootErrors.Add(('{0}: {1}' -f $r.Name, $_.Exception.Message)) }
    }
    return [pscustomobject]@{ Root = $res.Root; FirstMachine = $res.FirstMachine; RootErrors = $rootErrors.ToArray() }
}

# ---- the window ----------------------------------------------------------------------------------------------------------

function New-SyncWizardControl {
    param($Parent, [string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
    $c = New-Object "System.Windows.Forms.$Type"
    if ($Type -ne 'ListBox' -and $Type -ne 'CheckedListBox' -and $Type -ne 'ProgressBar') { $c.Text = $Text }
    if ($Type -eq 'Label' -or $Type -eq 'CheckBox') { $c.ForeColor = $ink }
    $c.Location = New-Object System.Drawing.Point($X, $Y); $c.Size = New-Object System.Drawing.Size($W, $H)
    $Parent.Controls.Add($c)
    return $c
}

# Step 1: one entry per Drive account, plus "Another folder...".
function New-SyncWizardPageWhere {
    param($Panel, $Choices)
    $null = New-SyncWizardControl $Panel 'Label' 'Where should the synced chats be kept?' 0 0 520 20
    $list = New-SyncWizardControl $Panel 'ListBox' '' 0 26 400 150
    $other = New-SyncWizardControl $Panel 'Button' 'Another folder...' 408 24 112 28
    foreach ($c in $Choices) { [void]$list.Items.Add($c.Text) }
    $note = New-SyncWizardControl $Panel 'Label' 'Pick a Google Drive account, or another folder that Drive (or anything else) keeps in sync.' 0 190 520 60
    return @{ List = $list; Other = $other; Note = $note }
}

# Step 2: the passphrase twice with the warning for a new folder, once for a folder that is already set up.
function New-SyncWizardPagePassphrase {
    param($Panel)
    $head = New-SyncWizardControl $Panel 'Label' 'Passphrase' 0 0 520 20
    $p1 = New-SyncWizardControl $Panel 'TextBox' '' 0 24 520 26
    $l2 = New-SyncWizardControl $Panel 'Label' 'Type it again' 0 60 520 20
    $p2 = New-SyncWizardControl $Panel 'TextBox' '' 0 84 520 26
    foreach ($t in $p1, $p2) { $t.UseSystemPasswordChar = $true }
    $bar = New-SyncWizardControl $Panel 'ProgressBar' '' 0 118 520 8
    $bar.Maximum = 12
    $ack = New-SyncWizardControl $Panel 'CheckBox' 'Losing the passphrase means losing the bundles on Drive (the chats on this machine are kept).' 0 138 520 44
    $ack.Font = New-Object System.Drawing.Font($ack.Font, [System.Drawing.FontStyle]::Bold)
    $note = New-SyncWizardControl $Panel 'Label' '' 0 190 520 70
    return @{ Head = $head; Pass1 = $p1; Label2 = $l2; Pass2 = $p2; Bar = $bar; Ack = $ack; Note = $note }
}

# Step 3: this machine's name and the suggested folder roots, each with a tick.
function New-SyncWizardPageMachine {
    param($Panel)
    $null = New-SyncWizardControl $Panel 'Label' ('This machine: {0}' -f $env:COMPUTERNAME) 0 0 520 20
    $null = New-SyncWizardControl $Panel 'Label' 'Chats remember their working folder. Tick the folders below to let them be found even when another machine keeps the same projects in a different place.' 0 24 520 44
    $list = New-SyncWizardControl $Panel 'CheckedListBox' '' 0 74 520 150
    $list.CheckOnClick = $true
    return @{ List = $list }
}

function Show-SyncSetupWizard {
    $choices = New-Object System.Collections.ArrayList
    foreach ($c in @(Get-SyncSetupChoices)) {
        if ($c.Existing) { $c.Text = $c.Text + ' - sync already set up here' }
        [void]$choices.Add($c)
    }
    $roots = @(Get-SyncWizardRoots -Cwds (Get-SyncWizardCwds))

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Set up Drive sync'; $dlg.Size = New-Object System.Drawing.Size(580, 470)
    $dlg.StartPosition = 'CenterParent'; $dlg.ShowInTaskbar = $false; $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.BackColor = $bg; $dlg.Font = $fontUI
    $title = New-SyncWizardControl $dlg 'Label' '' 16 12 540 22
    $title.Font = New-Object System.Drawing.Font($fontUI, [System.Drawing.FontStyle]::Bold)
    $panels = foreach ($i in 1..3) {
        $p = New-Object System.Windows.Forms.Panel
        $p.Location = New-Object System.Drawing.Point(16, 44); $p.Size = New-Object System.Drawing.Size(540, 290); $p.BackColor = $bg
        $dlg.Controls.Add($p); $p
    }
    $pg1 = New-SyncWizardPageWhere -Panel $panels[0] -Choices $choices
    $pg2 = New-SyncWizardPagePassphrase -Panel $panels[1]
    $pg3 = New-SyncWizardPageMachine -Panel $panels[2]
    foreach ($r in $roots) { [void]$pg3.List.Items.Add(('{0} = {1}' -f $r.Name, $r.Path), $true) }
    $back = New-SyncWizardControl $dlg 'Button' 'Back' 16 388 96 34
    $next = New-SyncWizardControl $dlg 'Button' 'Next' 120 388 96 34
    $finish = New-SyncWizardControl $dlg 'Button' 'Finish' 224 388 96 34
    $cancel = New-SyncWizardControl $dlg 'Button' 'Cancel' 328 388 96 34
    $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel

    # Event handlers are plain script blocks: they run inside ShowDialog, so they see this function's variables.
    $nav = @{ Page = 1; Done = $false }
    $pg1.Other.Add_Click({
        $path = Read-SyncFolder -Description 'Pick the folder that holds the synced chats (create an empty one first if needed).'
        if (-not $path) { return }
        $existing = (Test-Path -LiteralPath (Join-Path $path 'sync.json'))
        $entry = [pscustomobject]@{ Kind = 'custom'; Path = $path; Text = $(if ($existing) { "Folder: $path - sync already set up here" } else { "Folder: $path" }); Existing = $existing }
        [void]$choices.Add($entry); [void]$pg1.List.Items.Add($entry.Text); $pg1.List.SelectedIndex = $pg1.List.Items.Count - 1
    })
    $getState = {
        $i = $pg1.List.SelectedIndex
        @{ Page = $nav.Page; Choice = $(if ($i -ge 0) { $choices[$i] } else { $null }); Passphrase = $pg2.Pass1.Text; Confirmation = $pg2.Pass2.Text; Acknowledged = $pg2.Ack.Checked }
    }
    $refresh = {
        $st = & $getState; $s = Get-SyncWizardStep -State $st
        $titles = 'Step 1 of 3 - Where', 'Step 2 of 3 - Passphrase', 'Step 3 of 3 - This machine'
        $title.Text = $titles[$s.Page - 1]
        for ($k = 0; $k -lt 3; $k++) { $panels[$k].Visible = ($k -eq $s.Page - 1) }
        $back.Enabled = $s.CanBack; $next.Enabled = $s.CanNext; $next.Visible = ($s.Page -lt 3); $finish.Visible = ($s.Page -eq 3); $finish.Enabled = $s.CanFinish
        $pg2.Head.Text = $(if ($s.Existing) { 'Join the sync folder: type the passphrase chosen on the first machine' } else { 'Choose a passphrase' })
        foreach ($c in $pg2.Label2, $pg2.Pass2, $pg2.Ack, $pg2.Bar) { $c.Visible = -not $s.Existing }
        $pg2.Bar.Value = [Math]::Min(12, $pg2.Pass1.Text.Length)
        $pg2.Note.Text = $(if ($s.Page -eq 2 -and ($pg2.Pass1.Text.Length -or $pg2.Pass2.Text.Length)) { $s.Problems -join "`r`n" }
                           elseif ($s.Existing) { 'This folder already holds synced chats.' }
                           else { 'The chats are encrypted on this machine before they reach the folder. It is the only way to read them on another machine.' })
    }
    $pg1.List.Add_SelectedIndexChanged($refresh); $pg2.Pass1.Add_TextChanged($refresh); $pg2.Pass2.Add_TextChanged($refresh); $pg2.Ack.Add_CheckedChanged($refresh)
    $back.Add_Click({ $nav.Page--; & $refresh })
    $next.Add_Click({ $nav.Page++; & $refresh })
    $finish.Add_Click({
        $ticked = @(foreach ($k in $pg3.List.CheckedIndices) { $roots[$k] })
        $dlg.UseWaitCursor = $true
        try {
            $st = & $getState; $st['Page'] = 3
            $r = Complete-SyncWizard -State $st -Roots $ticked
            $nav.Done = $true
            $text = $(if ($r.FirstMachine) { 'Drive sync is set up. Push a chat from the Chats tab, then pull it on your other machine.' } else { 'This machine now uses the existing sync folder. Pull chats from the Chats tab.' })
            if ($r.RootErrors.Count) { $text += "`r`n`r`nThese folders were not saved:`r`n" + ($r.RootErrors -join "`r`n") }
            Show-Message $text 'Set up Drive sync' | Out-Null
            $dlg.Close()
        } catch {
            Show-Message (Get-SyncErrorMessage -Message $_.Exception.Message) 'Set up Drive sync' 'OK' 'Error' | Out-Null
        } finally { $dlg.UseWaitCursor = $false }
    })
    & $refresh
    [void]$dlg.ShowDialog()
    $pg2.Pass1.Text = ''; $pg2.Pass2.Text = ''
    $dlg.Dispose()
    return $nav.Done
}
