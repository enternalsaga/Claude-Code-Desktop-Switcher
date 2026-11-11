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
        return [pscustomobject]@{ Path = $md; Prompt = (New-HandoffPrompt -Harness $m.source.harness -Title $m.source.title -Path $md); Manifest = $m }
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

function Show-HarnessExportDialog {
    param($Source)
    $harness = Get-Harness -Name 'claude'
    $profiles = @(& $harness.Adapter.GetProfiles)
    if (-not $Source) { $Source = $profiles | Select-Object -First 1 }

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = 'Export chat for handoff'
    $dlg.Size          = New-Object System.Drawing.Size(620, 440)
    $dlg.MinimumSize   = New-Object System.Drawing.Size(480, 340)
    $dlg.StartPosition = 'CenterParent'
    $dlg.ShowInTaskbar = $false
    $dlg.MinimizeBox   = $false
    $dlg.BackColor     = $bg
    $dlg.Font          = $fontUI

    $profileBox               = New-Object System.Windows.Forms.ComboBox
    $profileBox.DropDownStyle = 'DropDownList'
    $profileBox.Location      = New-Object System.Drawing.Point(16, 14)
    $profileBox.Size          = New-Object System.Drawing.Size(570, 26)
    $profileBox.Anchor        = 'Top,Left,Right'
    foreach ($p in $profiles) { $profileBox.Items.Add($p.Name) | Out-Null }
    $dlg.Controls.Add($profileBox)

    $chatList          = New-Object System.Windows.Forms.ListBox
    $chatList.Location = New-Object System.Drawing.Point(16, 50)
    $chatList.Size     = New-Object System.Drawing.Size(570, 280)
    $chatList.Anchor   = 'Top,Left,Right,Bottom'
    $dlg.Controls.Add($chatList)

    $note           = New-Object System.Windows.Forms.Label
    $note.Text      = 'Writes a bundle and a handoff file under the switcher folder and copies an opening prompt to the clipboard.'
    $note.ForeColor = $ink
    $note.Location  = New-Object System.Drawing.Point(16, 338)
    $note.Size      = New-Object System.Drawing.Size(570, 20)
    $note.Anchor    = 'Left,Right,Bottom'
    $dlg.Controls.Add($note)

    $export          = New-Object System.Windows.Forms.Button
    $export.Text     = 'Export'
    $export.Location = New-Object System.Drawing.Point(16, 364)
    $export.Size     = New-Object System.Drawing.Size(108, 34)
    $export.Anchor   = 'Left,Bottom'
    $dlg.Controls.Add($export)

    $profileBox.Add_SelectedIndexChanged({
        $chatList.Items.Clear()
        $chatList.Tag = @(& $harness.Adapter.ListChats $profiles[$profileBox.SelectedIndex])
        foreach ($c in $chatList.Tag) { $chatList.Items.Add(('{0}   ({1})' -f $c.Title, $(if ($c.Cwd) { Split-Path $c.Cwd -Leaf } else { 'no folder' }))) | Out-Null }
    })
    $export.Add_Click({
        if ($chatList.SelectedIndex -lt 0) { return }
        $chat = $chatList.Tag[$chatList.SelectedIndex]
        try {
            $bundleDir = Join-Path (Get-HandoffDir) 'bundles'
            $bundle = Join-Path $bundleDir ('{0}-{1}.hbundle.zip' -f $chat.ChatId, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $manifest = & $harness.Adapter.Export $chat $bundle
            $files = Export-HarnessHandoffFiles -BundlePath $bundle -Target ''
            [System.Windows.Forms.Clipboard]::SetText($files.Prompt)
            $warn = $(if ($manifest.redaction.findings -gt 0) { "`r`n`r`nThe chat files hold $($manifest.redaction.findings) possible secret(s). The handoff file is redacted; the bundle's native files are not." } else { '' })
            Show-Message "Saved:`r`n$($files.Path)`r`n$bundle`r`n`r`nThe opening prompt is on the clipboard. Paste it into a new chat.$warn" 'Handoff ready' | Out-Null
        } catch {
            Show-Message "Export failed: $($_.Exception.Message)" 'Export chat for handoff' 'OK' 'Error' | Out-Null
        }
    })

    $start = [Math]::Max(0, [Array]::FindIndex($profiles, [Predicate[object]]{ param($p) $p.Id -eq $Source.Id }))
    if ($profiles.Count) { $profileBox.SelectedIndex = $start }
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}
