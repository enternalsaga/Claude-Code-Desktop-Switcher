# Ui.Harness.ps1 - handoff files and the "Export chat for handoff" dialog. The functions at the top
# are plain file work (tested without a window); Show-HarnessExportDialog is the only WinForms code.
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
            if ($r.Status -ne 'not-detected') { $res.Status = $r.Status; $res.ThreadId = $r.ThreadId; return $res }
            $res.Status = 'not-detected'; $res.Mode = 'handoff'
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

function Show-HarnessExportDialog {
    param($Source, [string]$Mode = '')
    $sources = @(Get-HarnessTransferSources)
    if (-not $sources.Count) { return }
    $targets = @(Get-HarnessTransferTargets)
    # Google Drive is one more source (pull) and one more target (push) once sync works on this machine.
    $syncReady = [bool]((Get-Command Test-SyncReady -ErrorAction SilentlyContinue) -and (Test-SyncReady))
    $entries = @(Get-SyncDialogTargets -Targets $targets -SyncReady $syncReady)
    $state = @{ Harness = $sources[0]; Profiles = @(); Drive = $false }

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = 'Move or hand off a chat'
    $dlg.Size          = New-Object System.Drawing.Size(620, 520)
    $dlg.MinimumSize   = New-Object System.Drawing.Size(480, 420)
    $dlg.StartPosition = 'CenterParent'
    $dlg.ShowInTaskbar = $false
    $dlg.MinimizeBox   = $false
    $dlg.BackColor     = $bg
    $dlg.Font          = $fontUI

    $sourceBox               = New-Object System.Windows.Forms.ComboBox
    $sourceBox.DropDownStyle = 'DropDownList'
    $sourceBox.Location      = New-Object System.Drawing.Point(16, 14)
    $sourceBox.Size          = New-Object System.Drawing.Size(120, 26)
    foreach ($s in $sources) { $sourceBox.Items.Add((Get-HarnessDisplayName $s)) | Out-Null }
    if ($syncReady) { $sourceBox.Items.Add('Google Drive') | Out-Null }
    $dlg.Controls.Add($sourceBox)

    $profileBox               = New-Object System.Windows.Forms.ComboBox
    $profileBox.DropDownStyle = 'DropDownList'
    $profileBox.Location      = New-Object System.Drawing.Point(146, 14)
    $profileBox.Size          = New-Object System.Drawing.Size(440, 26)
    $profileBox.Anchor        = 'Top,Left,Right'
    $dlg.Controls.Add($profileBox)

    $chatList          = New-Object System.Windows.Forms.ListBox
    $chatList.Location = New-Object System.Drawing.Point(16, 50)
    $chatList.Size     = New-Object System.Drawing.Size(570, 270)
    $chatList.Anchor   = 'Top,Left,Right,Bottom'
    $dlg.Controls.Add($chatList)

    $targetBox               = New-Object System.Windows.Forms.ComboBox
    $targetBox.DropDownStyle = 'DropDownList'
    $targetBox.Location      = New-Object System.Drawing.Point(16, 330)
    $targetBox.Size          = New-Object System.Drawing.Size(570, 26)
    $targetBox.Anchor        = 'Left,Right,Bottom'
    foreach ($e in $entries) {
        $targetBox.Items.Add($(switch ($e.Kind) { 'file' { 'Handoff file only (no target)' } 'drive' { 'Google Drive (push, encrypted)' } default { '{0} / {1}' -f (Get-HarnessDisplayName (Get-Harness -Name $e.Profile.Harness)), $e.Profile.Name } })) | Out-Null
    }
    $dlg.Controls.Add($targetBox)

    $note           = New-Object System.Windows.Forms.Label
    $note.ForeColor = $ink
    $note.Location  = New-Object System.Drawing.Point(16, 364)
    $note.Size      = New-Object System.Drawing.Size(570, 40)
    $note.Anchor    = 'Left,Right,Bottom'
    $dlg.Controls.Add($note)

    $go          = New-Object System.Windows.Forms.Button
    $go.Text     = 'Go'
    $go.Location = New-Object System.Drawing.Point(16, 416)
    $go.Size     = New-Object System.Drawing.Size(108, 34)
    $go.Anchor   = 'Left,Bottom'
    $dlg.Controls.Add($go)

    $refreshNote = {
        $note.Text = 'Writes a bundle and a handoff file under the switcher folder. A handoff also copies an opening prompt to the clipboard.'
        $e = $entries[[Math]::Max(0, $targetBox.SelectedIndex)]
        if ($state.Drive) { $note.Text = 'Pick a chat from Drive and the profile that should receive it. A chat that changed on both machines arrives as a new chat.' }
        elseif ($e.Kind -eq 'drive') { $note.Text = 'Pushes an encrypted copy of the chat to your Drive sync folder. Pull it on another machine from the same dialog.' }
        elseif ($e.Kind -eq 'profile') {
            $kind = switch (Resolve-TransferMode -Source $state.Harness.Name -Target $e.Profile.Harness) {
                'native'       { 'Native copy: the chat keeps its history and can be resumed in the target.' }
                'codex-import' { "Codex's own importer: the Claude chat becomes a Codex chat." }
                default        { 'Handoff: the target starts a new chat from the transcript.' }
            }
            $note.Text = "Kind: $kind"
        }
    }
    $loadProfiles = {
        $state.Drive = [bool]($syncReady -and $sourceBox.SelectedIndex -eq $sources.Count)
        $profileBox.Enabled = -not $state.Drive
        if ($state.Drive) {
            $profileBox.Items.Clear(); $chatList.Items.Clear(); $chatList.Tag = @()
            $chatList.Tag = @(Get-SyncCatalogForDialog)
            foreach ($row in $chatList.Tag) { $chatList.Items.Add((Get-SyncCatalogLine -Row $row)) | Out-Null }
            & $refreshNote; return
        }
        $state.Harness = $sources[[Math]::Max(0, $sourceBox.SelectedIndex)]
        $state.Profiles = @(& $state.Harness.Adapter.GetProfiles)
        $profileBox.Items.Clear()
        foreach ($p in $state.Profiles) { $profileBox.Items.Add($p.Name) | Out-Null }
        if ($state.Profiles.Count) {
            $pick = 0
            if ($Source -and $state.Harness.Name -eq 'claude') { for ($i = 0; $i -lt $state.Profiles.Count; $i++) { if ($state.Profiles[$i].Id -eq $Source.Id) { $pick = $i } } }
            $profileBox.SelectedIndex = $pick
        } else { $chatList.Items.Clear(); $chatList.Tag = @() }
        & $refreshNote
    }
    $sourceBox.Add_SelectedIndexChanged($loadProfiles)
    $targetBox.Add_SelectedIndexChanged($refreshNote)
    $profileBox.Add_SelectedIndexChanged({
        $chatList.Items.Clear()
        if ($profileBox.SelectedIndex -lt 0) { return }
        try { $chatList.Tag = @(& $state.Harness.Adapter.ListChats $state.Profiles[$profileBox.SelectedIndex]) }
        catch { $chatList.Tag = @(); Show-Message "Could not list chats: $($_.Exception.Message)" 'Move or hand off a chat' 'OK' 'Error' | Out-Null; return }
        foreach ($c in $chatList.Tag) { $chatList.Items.Add(('{0}   ({1})' -f $c.Title, $(if ($c.PSObject.Properties['HasRollout'] -and -not $c.HasRollout) { 'chat file no longer on disk' } elseif ($c.Cwd) { Split-Path $c.Cwd -Leaf } else { 'no folder' }))) | Out-Null }
    })
    $go.Add_Click({
        if ($chatList.SelectedIndex -lt 0) { return }
        $item = $chatList.Tag[$chatList.SelectedIndex]
        if ($item.PSObject.Properties['HasRollout'] -and -not $item.HasRollout) { Show-Message 'The file of this chat is no longer on disk, so it cannot be moved.' 'Move or hand off a chat' 'OK' 'Warning' | Out-Null; return }
        $src = $(if ($state.Drive) { @{ Kind = 'drive' } } else { @{ Kind = 'harness'; Harness = $state.Harness.Name; Profile = $state.Profiles[[Math]::Max(0, $profileBox.SelectedIndex)] } })
        $askRoot = { param($rootName) Read-SyncFolder -Description "Where is the folder '$rootName' on this machine? The chat's working folder is inside it." }
        $r = Invoke-HarnessDialogAction -Source $src -TargetEntry $entries[[Math]::Max(0, $targetBox.SelectedIndex)] -Item $item -AskRoot $askRoot
        if ($r.Prompt) { [System.Windows.Forms.Clipboard]::SetText($r.Prompt) }
        $level = switch ($r.Kind) { 'error' { 'Error' } 'warning' { 'Warning' } default { 'Information' } }
        Show-Message ((@($r.Text, $r.Where) | Where-Object { $_ }) -join "`r`n`r`n") $(if ($r.Kind -eq 'message') { 'Done' } else { 'Move or hand off a chat' }) 'OK' $level | Out-Null
    })

    if ($Mode -eq 'push') { for ($i = 0; $i -lt $entries.Count; $i++) { if ($entries[$i].Kind -eq 'drive') { $targetBox.SelectedIndex = $i } } } else { $targetBox.SelectedIndex = 0 }
    $sourceBox.SelectedIndex = $(if ($Mode -eq 'pull' -and $syncReady) { $sources.Count } else { 0 })
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}
