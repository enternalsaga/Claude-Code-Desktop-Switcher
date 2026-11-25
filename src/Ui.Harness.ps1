# Ui.Harness.ps1 - handoff files, moving a chat between profiles, and the two small dialogs of the chat list (move, diverged).
# The functions at the top are plain file work (tested without a window); the dialogs at the end are the only WinForms code.
# Uses $script:SwitcherHome and the colours/fonts of ClaudeSwitcher.ps1. Needs Harness.Core.ps1.
# This file stays ASCII-only like the rest of the script, so the opening prompt is in English.

function Get-HandoffDir {
    return (Join-Path $script:SwitcherHome 'handoff')
}

function New-HandoffPrompt {
    param([Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Path)
    return ('Continue the work from the {0} session "{1}". Read the context in {2}, then summarize the current state before continuing.' -f $Harness, $Title, $Path)
}

# Writes the bundle's transcript.md to <HandoffDir>\<bundleId>.md (outside any repo), logs it in
# handoff-log.jsonl and returns the file path, the opening prompt and the manifest.
function Export-HarnessHandoffFiles {
    param([Parameter(Mandatory)][string]$BundlePath, [string]$HandoffDir = (Get-HandoffDir), [string]$Target = '')
    $work = Join-Path ([IO.Path]::GetTempPath()) ('handoff-' + [guid]::NewGuid().ToString('N'))
    try {
        $m = Read-HarnessBundle -Path $BundlePath -ExtractTo $work
        New-Item -ItemType Directory -Path $HandoffDir -Force | Out-Null
        $md = Join-Path $HandoffDir "$($m.bundleId).md"
        Copy-Item -LiteralPath (Join-Path $work 'transcript.md') -Destination $md -Force
        $entry = [ordered]@{ bundleId = $m.bundleId; source = $m.source.harness; target = $Target; at = (Get-Date).ToUniversalTime().ToString('o') }
        [IO.File]::AppendAllText((Join-Path $HandoffDir 'handoff-log.jsonl'), (($entry | ConvertTo-Json -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
        # $script:HandoffTitleSuffix is set by Invoke-HarnessImport for a chat that changed on two machines: the new chat is named apart
        return [pscustomobject]@{ Path = $md; Prompt = (New-HandoffPrompt -Harness $m.source.harness -Title ([string]$m.source.title + $script:HandoffTitleSuffix) -Path $md); Manifest = $m }
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

# ImportHandoff for an adapter: write the files, put the opening prompt on the clipboard and launch the
# target profile. The user pastes the prompt into the new chat.
function Start-HarnessHandoff {
    param([Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)][string]$TargetHarness, [Parameter(Mandatory)]$Profile)
    $files = Export-HarnessHandoffFiles -BundlePath $BundlePath -Target $TargetHarness
    [System.Windows.Forms.Clipboard]::SetText($files.Prompt)
    $h = Get-Harness -Name $TargetHarness
    $state = & $h.Adapter.Launch $Profile
    return [pscustomobject]@{ Path = $files.Path; Prompt = $files.Prompt; Launch = $state }
}

# True when the target app must be closed before a native or Codex-import move (its chat list is not refreshed while open).
function Test-HarnessImportBlocked {
    param($Target, [string]$Mode)
    if (-not $Target -or $Mode -notin 'native', 'codex-import') { return $false }
    $to = Get-Harness -Name $Target.Harness
    return [bool]($to.Adapter['ImportNeedsClose'] -is [scriptblock] -and (& $to.Adapter.ImportNeedsClose $Target))
}

# Step 1 of a transfer: the source adapter writes a bundle under $BundleDir. Returns the bundle path and its manifest.
function Export-HarnessChatBundle {
    param([Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$SourceHarness, [string]$BundleDir = (Join-Path (Get-HandoffDir) 'bundles'))
    $from = Get-Harness -Name $SourceHarness
    New-Item -ItemType Directory -Path $BundleDir -Force | Out-Null
    $bundle = Join-Path $BundleDir ('{0}-{1}.hbundle.zip' -f $Chat.ChatId, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $manifest = & $from.Adapter.Export $Chat $bundle
    return [pscustomobject]@{ Bundle = $bundle; Manifest = $manifest }
}

# Step 2: brings a bundle into $Target (or only writes the handoff file when $Target is $null) by the mode
# Resolve-TransferMode picks from the bundle's own harness. -Handoff forces a handoff (a chat that changed on both
# machines), with -TitleSuffix added to the title in the opening prompt. Status is one of files, handoff, copied,
# updated, exists, imported, close-first, needs-root (Root says which folder to ask for), or provider-mismatch /
# not-detected (both already fell back to a handoff). CwdMissing is set by a native import from another machine.
function Invoke-HarnessImport {
    param([Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)]$Manifest, $Target, [switch]$Handoff, [string]$TitleSuffix = '', [string]$SourceHarness = '')
    $source = $(if ($SourceHarness) { $SourceHarness } else { [string]$Manifest.source.harness })
    $mode = $(if (-not $Target) { 'files' } elseif ($Handoff) { 'handoff' } else { Resolve-TransferMode -Source $source -Target $Target.Harness })
    $res = [pscustomobject]@{ Mode = $mode; Status = $mode; Bundle = $BundlePath; Manifest = $Manifest; ThreadId = $null; Path = $null; Prompt = $null; Root = $null; CwdMissing = $false }
    if (Test-HarnessImportBlocked -Target $Target -Mode $mode) { $res.Status = 'close-first'; return $res }
    $to = $(if ($Target) { Get-Harness -Name $Target.Harness } else { $null })
    $script:HandoffTitleSuffix = $TitleSuffix
    try {
        if ($mode -eq 'files') {
            $f = Export-HarnessHandoffFiles -BundlePath $BundlePath -Target ''
            $res.Path = $f.Path; $res.Prompt = $f.Prompt
            return $res
        }
        if ($mode -eq 'native') {
            $r = & $to.Adapter.ImportNative $BundlePath $Target
            # Claude between two machines answers with a hashtable; everything else with a string.
            if ($r -is [System.Collections.IDictionary]) {
                $res.Root = $r['Root']; $res.CwdMissing = [bool]$r['CwdMissing']
                $r = $r['Status']
            }
            if ($r -ne 'provider-mismatch') { $res.Status = $(if ($r -is [string] -and $r) { $r } else { 'copied' }); return $res }
            $res.Status = 'provider-mismatch'; $res.Mode = 'handoff'
        } elseif ($mode -eq 'codex-import') {
            $r = & $to.Adapter.ImportExternalClaude $BundlePath $Target
            if ($r.Status -notin 'not-detected', 'skipped') { $res.Status = $r.Status; $res.ThreadId = $r.ThreadId; return $res }
            $res.Status = $(if ($r.Status -eq 'not-detected') { 'not-detected' } else { 'handoff' }); $res.Mode = 'handoff'
        }
        $h = & $to.Adapter.ImportHandoff $BundlePath $Target
        $res.Path = $h.Path; $res.Prompt = $h.Prompt
        if ($res.Status -in 'native', 'codex-import', 'handoff') { $res.Status = 'handoff' }
        return $res
    } finally { $script:HandoffTitleSuffix = '' }
}

# Moves one chat to a target profile (or only writes the handoff file when $Target is $null): export, then import.
# No WinForms: the dialog shows the result.
function Invoke-HarnessTransfer {
    param(
        [Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$SourceHarness, $Target,
        [string]$BundleDir = (Join-Path (Get-HandoffDir) 'bundles')
    )
    $mode = $(if ($Target) { Resolve-TransferMode -Source $SourceHarness -Target $Target.Harness } else { 'files' })
    if (Test-HarnessImportBlocked -Target $Target -Mode $mode) {
        return [pscustomobject]@{ Mode = $mode; Status = 'close-first'; Bundle = $null; Manifest = $null; ThreadId = $null; Path = $null; Prompt = $null; Root = $null; CwdMissing = $false }
    }
    $exp = Export-HarnessChatBundle -Chat $Chat -SourceHarness $SourceHarness -BundleDir $BundleDir
    return (Invoke-HarnessImport -BundlePath $exp.Bundle -Manifest $exp.Manifest -Target $Target -SourceHarness $SourceHarness)
}

# Detect says whether the app is on this machine. A harness that is not installed, or whose Detect fails, is not
# offered: moving a chat into it would write into a home no app uses.
function Test-HarnessInstalled {
    param([Parameter(Mandatory)]$Harness)
    try {
        $d = & $Harness.Adapter.Detect
        if ($d -is [bool]) { return $d }
        return [bool]($d -and $d.PSObject.Properties['Installed'] -and $d.Installed)
    } catch { return $false }
}

function Get-HarnessTransferSources {
    return @(Get-Harnesses | Where-Object { $_.Name -in 'claude', 'codex' -and (Test-HarnessInstalled $_) } | Sort-Object Name)
}

# One entry per profile of every installed harness.
function Get-HarnessTransferTargets {
    $list = New-Object System.Collections.ArrayList
    foreach ($h in (Get-Harnesses | Sort-Object Name)) {
        if (-not (Test-HarnessInstalled $h)) { continue }
        try { foreach ($p in @(& $h.Adapter.GetProfiles)) { [void]$list.Add($p) } } catch { }
    }
    return $list.ToArray()
}

function Get-HarnessTransferMessage {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)]$Target)
    $name = '{0} / {1}' -f (Get-HarnessDisplayName (Get-Harness -Name $Target.Harness)), $Target.Name
    # A native import from another machine can say the working folder is not there; every success message then adds that.
    $folderNote = $(if ($Result.PSObject.Properties['CwdMissing'] -and $Result.CwdMissing) { " The chat's working folder does not exist on this machine yet; create it, or the chat opens without one." } else { '' })
    if ($Result.PSObject.Properties['Divergence'] -and $Result.Divergence -eq 'diverged' -and $Result.Status -eq 'handoff') {
        return "This chat changed on both machines, so it was not overwritten. A new chat was started in $name from the copy on Drive instead; the opening prompt is on the clipboard."
    }
    switch ($Result.Status) {
        'copied'            { return "Copied into $name.$folderNote" }
        'updated'           { return "Updated $name with the newer version.$folderNote" }
        'renamed'           { return "$name already has this chat; only its title was updated." }
        'same'              { return "$name already has this version of the chat." }
        'pushed-mine'       { return 'Pushed this machine''s version to Drive as the latest. The other machine will see that the chat changed on both.' }
        'cancelled'         { return 'Nothing was changed.' }
        'needs-root'        { return "Choose where the folder '$($Result.Root)' is on this machine, then try again." }
        'bundle-missing'    { return (Get-SyncErrorMessage -Message 'bundle-missing') }
        'sync-conflict'     { return (Get-SyncErrorMessage -Message $(if ($Result.PSObject.Properties['Error'] -and $Result.Error) { [string]$Result.Error } else { 'sync-conflict' })) }
        'registered'        { return "The chat file was already in $name; it is now registered, so it should show in the list." }
        'copied-unregistered' { return "The chat file was copied into $name, but Codex could not register it, so it may not show in the list yet. Try the same move again." }
        'exists'            { return "$name already has this chat." }
        'imported'          { return "Imported into $name through Codex's own importer." }
        'provider-mismatch' { return "The model provider of this chat is not set up in $name, so it cannot be resumed there. A handoff was made instead; the opening prompt is on the clipboard." }
        'not-detected'      { return "Codex did not find the Claude session on this machine. A handoff was made instead; the opening prompt is on the clipboard." }
        default             { return "Handoff into $name started. The opening prompt is on the clipboard; paste it into the new chat." }
    }
}

# ---- dialogs of lane V3 (phase 5) ---------------------------------------------------------------------------------------

# One sentence under the target list of the move dialog: what will happen to the chat (Resolve-TransferMode's answer).
function Get-HarnessMoveHint {
    param([Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][string]$TargetName)
    switch ($Mode) {
        'native'       { return "Native copy: the chat keeps its history and is copied into $TargetName, where it can be resumed." }
        'codex-import' { return "Codex's own importer turns the Claude chat into a Codex chat in $TargetName." }
        'files'        { return 'Writes a bundle and a handoff file under the switcher folder; nothing is imported.' }
        default        { return "Handoff: a new chat starts in $TargetName from the transcript; the opening prompt is copied to the clipboard." }
    }
}

# The window of the "chat differs on both machines" choice. Built apart from Show-SyncDivergedDialog so it can be checked
# without showing it. Buttons: Handoff (Yes, the default: brings theirs in as a new chat), Push (No), Cancel.
function New-SyncDivergedForm {
    param([Parameter(Mandatory)]$Row, $Chat)
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'This chat changed on both machines'; $dlg.Size = New-Object System.Drawing.Size(540, 300)
    $dlg.StartPosition = 'CenterParent'; $dlg.ShowInTaskbar = $false; $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.FormBorderStyle = 'FixedDialog'
    if ($bg) { $dlg.BackColor = $bg }
    if ($fontUI) { $dlg.Font = $fontUI }
    $title = $(if ($Chat -and $Chat.PSObject.Properties['Title'] -and $Chat.Title) { [string]$Chat.Title } else { [string]$Row.Title })
    $label = New-Object System.Windows.Forms.Label
    $label.Text = ('"{0}" changed on this machine and on {1} since they last synced.' -f $title, $Row.MachineName)
    if ($ink) { $label.ForeColor = $ink }
    $label.Location = New-Object System.Drawing.Point(16, 14); $label.Size = New-Object System.Drawing.Size(490, 50)
    $dlg.Controls.Add($label)
    $make = {
        param($text, $help, $y, $result)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.DialogResult = $result
        $b.Location = New-Object System.Drawing.Point(16, $y); $b.Size = New-Object System.Drawing.Size(250, 34)
        $dlg.Controls.Add($b)
        $h = New-Object System.Windows.Forms.Label
        $h.Text = $help; if ($ink) { $h.ForeColor = $ink }
        $h.Location = New-Object System.Drawing.Point(274, ($y + 2)); $h.Size = New-Object System.Drawing.Size(240, 34)
        $dlg.Controls.Add($h)
        return $b
    }
    $handoff = & $make 'Bring theirs in as a new chat' 'Your chat stays as it is.' 76 'Yes'
    $push    = & $make 'Push mine as the latest' 'The other machine will see that it changed on both.' 124 'No'
    $cancel  = & $make 'Cancel' 'Change nothing.' 172 'Cancel'
    $dlg.AcceptButton = $handoff; $dlg.CancelButton = $cancel
    return [pscustomobject]@{ Form = $dlg; Handoff = $handoff; Push = $push; Cancel = $cancel }
}

# Asks what to do with a chat that changed on both machines: 'handoff' (default), 'push' or 'cancel'. The -OnDiverged
# callback of Invoke-SyncPull.
function Show-SyncDivergedDialog {
    param([Parameter(Mandatory)]$Row, $Chat)
    $f = New-SyncDivergedForm -Row $Row -Chat $Chat
    try {
        $answer = $f.Form.ShowDialog()
        return (Resolve-SyncDivergedChoice $(switch ([string]$answer) { 'Yes' { 'handoff' } 'No' { 'push' } default { 'cancel' } }))
    } finally { $f.Form.Dispose() }
}

# Move one chat to any profile of any installed harness. Returns @{ Result; Target } of the transfer, or $null when the
# user cancels. A failed transfer is shown here and the window stays open.
# The profiles a chat can move to: every profile except the one it is in.
function Get-HarnessMoveTargets {
    param([Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$SourceHarness, [array]$Targets = @())
    $own = $(if ($Chat.PSObject.Properties['Profile'] -and $Chat.Profile) { [string]$Chat.Profile.Id } else { '' })
    return @($Targets | Where-Object { -not ($own -and [string]$_.Harness -eq $SourceHarness -and [string]$_.Id -eq $own) })
}

function Show-HarnessMoveDialog {
    param([Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$SourceHarness)
    Add-Type -AssemblyName System.Windows.Forms
    $targets = @(Get-HarnessMoveTargets -Chat $Chat -SourceHarness $SourceHarness -Targets @(Get-HarnessTransferTargets))
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Move to...'; $dlg.Size = New-Object System.Drawing.Size(520, 400); $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'; $dlg.ShowInTaskbar = $false; $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.BackColor = $bg; $dlg.Font = $fontUI
    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16, 16); $list.Size = New-Object System.Drawing.Size(470, 230); $list.Anchor = 'Top,Left,Right,Bottom'
    foreach ($t in $targets) { [void]$list.Items.Add(('{0} / {1}' -f (Get-HarnessDisplayName (Get-Harness -Name $t.Harness)), $t.Name)) }
    $dlg.Controls.Add($list)
    $hint = New-Object System.Windows.Forms.Label
    $hint.ForeColor = $ink; $hint.Location = New-Object System.Drawing.Point(16, 256); $hint.Size = New-Object System.Drawing.Size(470, 50); $hint.Anchor = 'Left,Right,Bottom'
    $dlg.Controls.Add($hint)
    $go = New-Object System.Windows.Forms.Button
    $go.Text = 'Move'; $go.Location = New-Object System.Drawing.Point(16, 318); $go.Size = New-Object System.Drawing.Size(108, 34); $go.Anchor = 'Left,Bottom'; $go.Enabled = $false
    $dlg.Controls.Add($go)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel
    $cancel.Location = New-Object System.Drawing.Point(132, 318); $cancel.Size = New-Object System.Drawing.Size(108, 34); $cancel.Anchor = 'Left,Bottom'
    $dlg.Controls.Add($cancel)

    $out = @{ Value = $null }
    $list.Add_SelectedIndexChanged({
        $go.Enabled = ($list.SelectedIndex -ge 0)
        if ($list.SelectedIndex -lt 0) { $hint.Text = ''; return }
        $t = $targets[$list.SelectedIndex]
        $hint.Text = Get-HarnessMoveHint -Mode (Resolve-TransferMode -Source $SourceHarness -Target $t.Harness) -TargetName $list.SelectedItem
    })
    $go.Add_Click({
        $t = $targets[$list.SelectedIndex]
        $dlg.UseWaitCursor = $true; $go.Enabled = $false
        try {
            $r = Invoke-HarnessTransfer -Chat $Chat -SourceHarness $SourceHarness -Target $t
            if ($r.Prompt) { [System.Windows.Forms.Clipboard]::SetText($r.Prompt) }
            $out.Value = [pscustomobject]@{ Result = $r; Target = $t }
            $dlg.Close()
        } catch {
            Show-Message (Get-SyncErrorMessage -Message $_.Exception.Message) 'Move to...' 'OK' 'Error' | Out-Null
        } finally { $dlg.UseWaitCursor = $false; $go.Enabled = ($list.SelectedIndex -ge 0) }
    })
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return $out.Value
}
