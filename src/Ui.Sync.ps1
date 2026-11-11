# Ui.Sync.ps1 - Drive sync from the user's side: push, pull, first-time setup and the CLI (phase 4, lane U).
# The functions at the top are plain logic (tested without a window); Show-SyncSetupDialog is the only WinForms code.
# Needs Harness.Core, Harness.Sync.* and Ui.Harness. The passphrase is never logged or shown. ASCII only.

# ---- errors the user can act on ------------------------------------------------------------------------------------------

# The sync code throws "<code>: details". This turns a code into a sentence; anything else passes through unchanged.
function Get-SyncErrorMessage {
    param([Parameter(Mandatory)][string]$Message)
    switch -Regex ($Message) {
        'bundle-missing'    { return 'This chat is not on Drive (yet). Wait for Drive to finish syncing, or push it again from the other machine.' }
        'wrong-passphrase'  { return 'That passphrase does not match the one this Drive folder was set up with.' }
        'sync-key-missing'  { return 'This machine has no saved sync key: open the switcher once to set up Drive sync.' }
        'sync-not-set-up'   { return 'Drive sync is not set up on this machine: open the switcher once to set it up.' }
        'sha-mismatch'      { return 'The file on Drive does not match its record, which usually means Drive is still uploading it. Try again in a moment.' }
        'mac-mismatch'      { return 'The bundle could not be verified: it is damaged, or it was made with another passphrase.' }
        'sync-conflict'     { return ($Message -replace '^.*?sync-conflict:\s*', '') }
        default             { return $Message }
    }
}

# ---- the sync folder and key -----------------------------------------------------------------------------------------

# Where the sync folder is on this machine and the key to use with it. Throws sync-not-set-up when there is no folder
# or no sync.json in it, and sync-key-missing when the key is not in this machine's DPAPI cache (the passphrase is
# only ever asked for in the setup dialog, never in the CLI).
function Get-SyncSession {
    $root = Resolve-SyncRoot
    if (-not $root.Path) { throw "sync-not-set-up: the sync folder was not found ($($root.Reason))." }
    $main = Join-Path $root.Path 'sync.json'
    $doc = $(if (Test-Path -LiteralPath $main -PathType Leaf) { Read-SyncJsonFile $main } else { $null })
    if (-not $doc -or -not $doc.kdf) { throw 'sync-not-set-up: there is no sync.json in the sync folder.' }
    $key = Get-SyncKeyCache -Kdf $doc.kdf
    if (-not $key) { throw 'sync-key-missing: the key of this sync folder is not saved on this machine.' }
    return [pscustomobject]@{ Root = $root.Path; Key = $key }
}

# ---- push and pull ----------------------------------------------------------------------------------------------------

# Export the chat, encrypt it onto Drive, keep the newest 3 bundles of this machine, and delete the plain local bundle.
# -Profile is the profile the chat came from (kept in the sync state). Returns the index row.
function Invoke-SyncPush {
    param([Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$SourceHarness, $Profile, [string]$BundleDir = (Join-Path (Get-HandoffDir) 'bundles'))
    $s = Get-SyncSession
    $pushChat = $Chat.PSObject.Copy()
    if ($Profile -and -not $pushChat.PSObject.Properties['Profile']) { $pushChat | Add-Member -NotePropertyName Profile -NotePropertyValue $Profile }
    $exp = Export-HarnessChatBundle -Chat $Chat -SourceHarness $SourceHarness -BundleDir $BundleDir
    try {
        $row = Push-SyncBundle -Root $s.Root -BundlePath $exp.Bundle -Key $s.Key -Chat $pushChat
        Remove-SyncOldBundles -Root $s.Root
    } finally { Remove-Item -LiteralPath $exp.Bundle -Force -ErrorAction SilentlyContinue }
    return $row
}

# The chat this row would update in the target profile, or $null (a different harness never has one).
function Get-SyncLocalChat {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Target)
    if ([string]$Target.Harness -ne [string]$Row.harness) { return $null }
    $key = [string]$Row.chatKey
    $state = Get-SyncState
    $id = $(if ($state.ContainsKey($key) -and $state[$key].localChatId) { [string]$state[$key].localChatId } else { $key.Substring($key.IndexOf(':') + 1) })
    $h = Get-Harness -Name $Target.Harness
    return (@(& $h.Adapter.ListChats $Target) | Where-Object { $_ -and [string]$_.ChatId -eq $id } | Select-Object -First 1)
}

# Brings one catalog row into $Target. Divergence says what was found: new and update are imported (natively when
# the harness allows), diverged becomes a handoff whose title names the other machine, same does nothing. The result
# is Invoke-HarnessImport's plus Divergence; Status 'needs-root' (with Root) means the caller asks for that folder,
# calls Set-SyncPathRoot and pulls again. The decrypted bundle never outlives the call.
function Invoke-SyncPull {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Target)
    $s = Get-SyncSession
    $zip = Receive-SyncBundle -Root $s.Root -Row $Row -Key $s.Key
    try {
        $manifest = Read-SyncBundleManifest -Path $zip
        $div = Get-SyncDivergence -Row $Row -LocalChat (Get-SyncLocalChat -Row $Row -Target $Target)
        if ($div -eq 'same') {
            return [pscustomobject]@{ Divergence = $div; Mode = 'native'; Status = 'same'; Bundle = $null; Manifest = $manifest; ThreadId = $null; Path = $null; Prompt = $null; Root = $null; CwdMissing = $false }
        }
        if ($div -eq 'diverged') { $res = Invoke-HarnessImport -BundlePath $zip -Manifest $manifest -Target $Target -Handoff -TitleSuffix " (from $($Row.MachineName))" }
        else { $res = Invoke-HarnessImport -BundlePath $zip -Manifest $manifest -Target $Target }
        $res | Add-Member -NotePropertyName Divergence -NotePropertyValue $div
        if ($res.Mode -eq 'native' -and $res.Status -notin 'needs-root', 'close-first') {
            # The app may report a later activity for the imported chat than the bundle's (re-registered thread, file time);
            # the state records what the chat reads as now, or the next pull would call an untouched chat diverged.
            $activity = $Row.lastActivityAt
            try { $after = Get-SyncLocalChat -Row $Row -Target $Target; if ($after -and $null -ne $after.Activity -and $after.Activity -gt $activity) { $activity = $after.Activity } } catch { }
            $state = Get-SyncState
            $state[[string]$Row.chatKey] = @{ lastBundleId = [string]$Row.bundleId; localChatId = [string]$manifest.source.chatId; harness = [string]$Target.Harness; profileId = [string]$Target.Id; localActivityAtSync = $activity }
            Set-SyncState -State $state
        }
        return $res
    } finally { Remove-SyncReceived -Path $zip }
}

# ---- first-time setup --------------------------------------------------------------------------------------------------

# The problems with what was typed in the setup dialog, as plain sentences (empty array = fine). A machine that joins a
# folder which already has sync.json (-Existing) only types the passphrase; the first machine types it twice, with at
# least 12 characters, and must tick the warning. The messages never contain the passphrase.
function Test-SyncSetupInput {
    param([string]$Passphrase, [string]$Confirmation, $Acknowledged = $false, [switch]$Existing)
    $errs = New-Object Collections.Generic.List[string]
    if (-not $Passphrase) { $errs.Add('Type the passphrase.') }
    if ($Existing) { return $errs.ToArray() }
    if ($Passphrase -and $Passphrase.Length -lt 12) { $errs.Add('The passphrase needs at least 12 characters.') }
    if ($Passphrase -ne $Confirmation) { $errs.Add('The two passphrases are not the same.') }
    if (-not $Acknowledged) { $errs.Add('Tick the box to confirm you understand that a lost passphrase cannot be recovered.') }
    return $errs.ToArray()
}

# One entry per mounted Google Drive account (Token, Text for the list, Existing = the sync folder is already there).
function Get-SyncSetupChoices {
    $folder = [string](Get-SyncSetting 'Folder'); if (-not $folder) { $folder = 'HarnessSync' }
    $n = 0
    $list = foreach ($a in @(Get-DriveFsAccounts)) {
        $n++
        if (-not $a.MyDrive) { continue }
        $label = $(if ($a.Label) { $a.Label } else { "account $n" })
        [pscustomobject]@{ Kind = 'drive'; Token = $a.Token; Text = "Google Drive: $label"; Existing = (Test-Path -LiteralPath (Join-Path (Join-Path $a.MyDrive $folder) 'sync.json')) }
    }
    return @($list)
}

# Saves the folder choice, creates or joins the sync folder and keeps the derived key in the DPAPI cache. Exactly one of
# -DriveToken and -CustomPath. If anything fails the previous settings come back and no key is kept. -Iterations and
# -MinIterations are only lowered by tests. Returns Root and FirstMachine.
function Invoke-SyncSetup {
    param([string]$DriveToken, [string]$CustomPath, [Parameter(Mandatory)][string]$Passphrase, [int]$Iterations = 600000, [int]$MinIterations = 600000)
    if ([bool]$DriveToken -eq [bool]$CustomPath) { throw 'Choose either a Drive account or a folder.' }
    if ($CustomPath -and (-not (Test-SyncAbsolutePath $CustomPath) -or -not (Test-Path -LiteralPath $CustomPath -PathType Container))) { throw "The sync folder must be an existing full path: $CustomPath" }
    $prevCustom = Get-SyncSetting 'CustomPath'; $prevToken = Get-SyncSetting 'DriveAccountToken'
    try {
        Set-SyncSetting 'CustomPath' $(if ($CustomPath) { $CustomPath } else { $null })
        Set-SyncSetting 'DriveAccountToken' $(if ($DriveToken) { $DriveToken } else { $null })
        $root = Resolve-SyncRoot
        if (-not $root.Path) { throw "sync-not-set-up: the sync folder was not found ($($root.Reason))." }
        $first = -not (Test-Path -LiteralPath (Join-Path $root.Path 'sync.json'))
        [void](Get-SyncMachine)
        $kdf = Initialize-SyncFolder -Root $root.Path -Passphrase $Passphrase -Iterations $Iterations -MinIterations $MinIterations
        Save-SyncKeyCache -Key (Get-SyncKey -Passphrase $Passphrase -Kdf $kdf) -Kdf $kdf
        return [pscustomobject]@{ Root = $root.Path; FirstMachine = $first }
    } catch {
        Set-SyncSetting 'CustomPath' $prevCustom; Set-SyncSetting 'DriveAccountToken' $prevToken
        throw
    }
}

# A folder picker; returns the chosen path or $null.
function Read-SyncFolder {
    param([string]$Description)
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = $Description
    if ($fb.ShowDialog() -eq 'OK') { return $fb.SelectedPath }
    return $null
}

# The Drive catalog for the transfer dialog's list; shows the problem and returns an empty list when sync does not work.
function Get-SyncCatalogForDialog {
    try { $s = Get-SyncSession; return @(Get-SyncCatalog -Root $s.Root -Key $s.Key) }
    catch { Show-Message (Get-SyncErrorMessage -Message $_.Exception.Message) 'Drive sync' 'OK' 'Error' | Out-Null; return @() }
}

# The setup dialog: a thin shell over Get-SyncSetupChoices, Test-SyncSetupInput and Invoke-SyncSetup (all tested).
# Uses the colours and fonts of ClaudeSwitcher.ps1 and Show-Message. Returns $true when sync was set up.
function Show-SyncSetupDialog {
    $choices = New-Object System.Collections.ArrayList
    foreach ($c in @(Get-SyncSetupChoices)) { [void]$choices.Add($c) }

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = 'Set up Drive sync'
    $dlg.Size          = New-Object System.Drawing.Size(560, 440)
    $dlg.StartPosition = 'CenterParent'
    $dlg.ShowInTaskbar = $false; $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.BackColor     = $bg
    $dlg.Font          = $fontUI

    $mkLabel = {
        param($text, $y, $h)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.ForeColor = $ink
        $l.Location = New-Object System.Drawing.Point(16, $y); $l.Size = New-Object System.Drawing.Size(520, $h)
        $dlg.Controls.Add($l)
        return $l
    }
    $null = & $mkLabel 'Where should the synced chats be kept?' 14 20
    $where = New-Object System.Windows.Forms.ComboBox
    $where.DropDownStyle = 'DropDownList'
    $where.Location = New-Object System.Drawing.Point(16, 38); $where.Size = New-Object System.Drawing.Size(400, 26)
    foreach ($c in $choices) { [void]$where.Items.Add($c.Text) }
    $dlg.Controls.Add($where)
    $other = New-Object System.Windows.Forms.Button
    $other.Text = 'Other folder...'
    $other.Location = New-Object System.Drawing.Point(424, 36); $other.Size = New-Object System.Drawing.Size(112, 28)
    $dlg.Controls.Add($other)

    $mkPass = {
        param($y)
        $t = New-Object System.Windows.Forms.TextBox
        $t.UseSystemPasswordChar = $true
        $t.Location = New-Object System.Drawing.Point(16, $y); $t.Size = New-Object System.Drawing.Size(520, 26)
        $dlg.Controls.Add($t)
        return $t
    }
    $null = & $mkLabel 'Passphrase' 78 20
    $pass1 = & $mkPass 100
    $null = & $mkLabel 'Type it again' 134 20
    $pass2 = & $mkPass 156

    $ack = New-Object System.Windows.Forms.CheckBox
    $ack.Text = 'Losing the passphrase means losing the bundles on Drive (the chats on this machine are kept).'
    $ack.ForeColor = $ink
    $ack.Location = New-Object System.Drawing.Point(16, 200); $ack.Size = New-Object System.Drawing.Size(520, 44)
    $dlg.Controls.Add($ack)

    $note = & $mkLabel '' 256 80

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Set up'
    $ok.Location = New-Object System.Drawing.Point(16, 350); $ok.Size = New-Object System.Drawing.Size(108, 34)
    $dlg.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel
    $cancel.Location = New-Object System.Drawing.Point(132, 350); $cancel.Size = New-Object System.Drawing.Size(108, 34)
    $dlg.Controls.Add($cancel)

    # The folder the user picked by hand is kept next to the Drive accounts; Existing says whether sync.json is already there.
    $refresh = {
        $c = $(if ($where.SelectedIndex -ge 0) { $choices[$where.SelectedIndex] } else { $null })
        $existing = [bool]($c -and $c.Existing)
        $pass2.Enabled = -not $existing; $ack.Enabled = -not $existing
        $note.Text = $(if (-not $c) { 'Pick a Google Drive account, or another folder that Drive (or anything else) keeps in sync.' }
                       elseif ($existing) { 'This folder already holds synced chats. Type the passphrase that was chosen on the first machine.' }
                       else { 'The chats are encrypted on this machine before they reach the folder. Choose a passphrase you will not lose: it is the only way to read them on another machine.' })
    }
    $where.Add_SelectedIndexChanged($refresh)
    $other.Add_Click({
        $path = Read-SyncFolder -Description 'Pick the folder that holds the synced chats (create an empty one first if needed).'
        if (-not $path) { return }
        $entry = [pscustomobject]@{ Kind = 'custom'; Path = $path; Text = "Folder: $path"; Existing = (Test-Path -LiteralPath (Join-Path $path 'sync.json')) }
        [void]$choices.Add($entry); [void]$where.Items.Add($entry.Text); $where.SelectedIndex = $where.Items.Count - 1
    })
    $script:SyncSetupDone = $false
    $ok.Add_Click({
        $c = $(if ($where.SelectedIndex -ge 0) { $choices[$where.SelectedIndex] } else { $null })
        if (-not $c) { Show-Message 'Pick where the chats should be kept.' 'Set up Drive sync' 'OK' 'Warning' | Out-Null; return }
        $problems = @(Test-SyncSetupInput -Passphrase $pass1.Text -Confirmation $pass2.Text -Acknowledged $ack.Checked -Existing:([bool]$c.Existing))
        if ($problems.Count) { Show-Message ($problems -join "`r`n") 'Set up Drive sync' 'OK' 'Warning' | Out-Null; return }
        $dlg.UseWaitCursor = $true
        try {
            $r = $(if ($c.Kind -eq 'drive') { Invoke-SyncSetup -DriveToken $c.Token -Passphrase $pass1.Text } else { Invoke-SyncSetup -CustomPath $c.Path -Passphrase $pass1.Text })
            $script:SyncSetupDone = $true
            Show-Message $(if ($r.FirstMachine) { 'Drive sync is set up. Push a chat from the tray menu, then pull it on your other machine.' } else { 'This machine now uses the existing sync folder. Pull chats from the tray menu.' }) 'Set up Drive sync' | Out-Null
            $dlg.Close()
        } catch {
            Show-Message (Get-SyncErrorMessage -Message $_.Exception.Message) 'Set up Drive sync' 'OK' 'Error' | Out-Null
        } finally { $dlg.UseWaitCursor = $false }
    })
    & $refresh
    [void]$dlg.ShowDialog()
    $pass1.Text = ''; $pass2.Text = ''
    $dlg.Dispose()
    return $script:SyncSetupDone
}

# ---- what the dialogs and the tray show ---------------------------------------------------------------------------------

# lastActivityAt as local "yyyy-MM-dd HH:mm"; the adapters store milliseconds or seconds since 1970.
function Format-SyncActivity {
    param($Value)
    if ($null -eq $Value -or $Value -isnot [ValueType]) { return '' }
    $ms = $(if ([double]$Value -gt 100000000000) { [long]$Value } else { [long]([double]$Value * 1000) })
    return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
}

function Get-SyncCatalogLine {
    param([Parameter(Mandatory)]$Row)
    return ('{0}   ({1}, {2})' -f $Row.Title, $Row.MachineName, (Format-SyncActivity $Row.lastActivityAt))
}

function Test-SyncReady {
    try { [void](Get-SyncSession); return $true } catch { return $false }
}

# Tray entries by setup state: Push and Pull once sync works on this machine, otherwise one entry that sets it up.
function Get-SyncTrayItems {
    if (Test-SyncReady) {
        return @([pscustomobject]@{ Text = 'Sync: Push...'; Action = 'push' }, [pscustomobject]@{ Text = 'Sync: Pull...'; Action = 'pull' })
    }
    return @([pscustomobject]@{ Text = 'Set up Drive sync...'; Action = 'setup' })
}

function Invoke-SyncTrayAction {
    param([Parameter(Mandatory)][string]$Action)
    try {
        switch ($Action) {
            'setup' { [void](Show-SyncSetupDialog) }
            'push'  { Show-HarnessExportDialog -Mode push }
            'pull'  { Show-HarnessExportDialog -Mode pull }
        }
    } catch { Show-Message (Get-SyncErrorMessage -Message $_.Exception.Message) 'Drive sync' 'OK' 'Error' | Out-Null }
}

# The entries of the dialog's target list: a handoff file, Google Drive (only when sync is ready), then every profile.
function Get-SyncDialogTargets {
    param([array]$Targets = @(), [bool]$SyncReady = $false)
    $list = New-Object Collections.Generic.List[object]
    $list.Add([pscustomobject]@{ Kind = 'file'; Profile = $null })
    if ($SyncReady) { $list.Add([pscustomobject]@{ Kind = 'drive'; Profile = $null }) }
    foreach ($t in $Targets) { $list.Add([pscustomobject]@{ Kind = 'profile'; Profile = $t }) }
    return $list.ToArray()
}

# Pull; when the bundle's working folder is under a root this machine has not set (needs-root), -AskRoot is called
# with the root's name and returns a full path (or $null to give up). The answer is remembered and the pull repeated.
function Invoke-SyncPullAskingRoot {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Target, [scriptblock]$AskRoot)
    $asked = @{}
    $res = Invoke-SyncPull -Row $Row -Target $Target
    while ($res.Status -eq 'needs-root' -and $AskRoot -and -not $asked.ContainsKey([string]$res.Root)) {
        $asked[[string]$res.Root] = $true
        $path = & $AskRoot $res.Root
        if (-not $path) { break }
        Set-SyncPathRoot -Name ([string]$res.Root) -Path ([string]$path)
        $res = Invoke-SyncPull -Row $Row -Target $Target
    }
    return $res
}

# What the transfer dialog's Go button does, without a window. $Source is @{ Kind = 'harness'; Harness; Profile } or
# @{ Kind = 'drive' }; $TargetEntry comes from Get-SyncDialogTargets; $Item is a chat (harness source) or a catalog row.
# Returns Kind (message | warning | error), Text, Prompt (for the clipboard) and Where (files written).
function Invoke-HarnessDialogAction {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)]$TargetEntry, $Item, [scriptblock]$AskRoot)
    $out = { param($kind, $text, $prompt, $where) [pscustomobject]@{ Kind = $kind; Text = $text; Prompt = $prompt; Where = $where } }
    try {
        if ($Source.Kind -eq 'drive') {
            if ($TargetEntry.Kind -ne 'profile') { return (& $out 'warning' 'Pick the profile that should receive the chat.' $null $null) }
            $r = Invoke-SyncPullAskingRoot -Row $Item -Target $TargetEntry.Profile -AskRoot $AskRoot
            if ($r.Status -eq 'needs-root') { return (& $out 'warning' (Get-HarnessTransferMessage -Result $r -Target $TargetEntry.Profile) $null $null) }
            return (& $out 'message' (Get-HarnessTransferMessage -Result $r -Target $TargetEntry.Profile) $r.Prompt $r.Path)
        }
        if ($TargetEntry.Kind -eq 'drive') {
            [void](Invoke-SyncPush -Chat $Item -SourceHarness $Source.Harness -Profile $Source.Profile)
            return (& $out 'message' 'Pushed to Drive. The chat is encrypted there; pull it on your other machine.' $null $null)
        }
        $target = $(if ($TargetEntry.Kind -eq 'profile') { $TargetEntry.Profile } else { $null })
        $r = Invoke-HarnessTransfer -Chat $Item -SourceHarness $Source.Harness -Target $target
        if ($r.Status -eq 'close-first') { return (& $out 'warning' "Close $($target.Name) first, then try again. Its chat list is not refreshed while it is open." $null $null) }
        $text = $(if ($target) { Get-HarnessTransferMessage -Result $r -Target $target } else { 'Handoff file saved. The opening prompt is on the clipboard; paste it into a new chat.' })
        $warn = $(if ($r.Manifest.redaction.findings -gt 0) { "`r`n`r`nThe chat files hold $($r.Manifest.redaction.findings) possible secret(s). The handoff file is redacted; the bundle's native files are not." } else { '' })
        return (& $out 'message' ($text + $warn) $r.Prompt ((@($r.Path, $r.Bundle) | Where-Object { $_ }) -join "`r`n"))
    } catch {
        return (& $out 'error' (Get-SyncErrorMessage -Message $_.Exception.Message) $null $null)
    }
}

# ---- command line (-SyncPush / -SyncPull) --------------------------------------------------------------------------------

# "<harness>:<profile>" -> the profile (matched by id or name). Throws with the choices when there is none.
function Resolve-SyncCliProfile {
    param([Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)][string]$Profile)
    $h = Get-Harness -Name $Harness
    if (-not $h) { throw "There is no harness called '$Harness'. Known: $((Get-Harnesses | ForEach-Object { $_.Name }) -join ', ')." }
    $profiles = @(& $h.Adapter.GetProfiles)
    $hit = $profiles | Where-Object { $_.Id -ieq $Profile -or $_.Name -ieq $Profile } | Select-Object -First 1
    if (-not $hit) { throw "There is no $Harness profile called '$Profile'. Profiles: $((@($profiles | ForEach-Object { $_.Name })) -join ', ')." }
    return $hit
}

# -SyncPush <harness>:<profile>:<chatId>   -SyncPull <chatKey|bundleId> [-SyncTarget <harness>:<profile>]
# Never asks for the passphrase: a machine without the cached key is told to open the switcher once. Output lines are
# the result; failures throw.
function Invoke-SyncCli {
    param([string]$Push, [string]$Pull, [string]$Target)
    if ($Push -and $Pull) { throw 'Use either -SyncPush or -SyncPull, not both.' }
    try {
        if ($Push) {
            $parts = @($Push -split ':', 3)
            if ($parts.Count -ne 3 -or $parts -contains '') { throw 'Use -SyncPush <harness>:<profile>:<chatId>.' }
            $profile = Resolve-SyncCliProfile -Harness $parts[0] -Profile $parts[1]
            $chat = @(& (Get-Harness -Name $parts[0]).Adapter.ListChats $profile) | Where-Object { $_ -and [string]$_.ChatId -eq $parts[2] } | Select-Object -First 1
            if (-not $chat) { throw "There is no chat '$($parts[2])' in $($parts[0]) profile '$($profile.Name)'." }
            $row = Invoke-SyncPush -Chat $chat -SourceHarness $parts[0] -Profile $profile
            "Pushed '$($chat.Title)' to Drive (bundle $($row.bundleId))."
            return
        }
        $s = Get-SyncSession
        $row = @(Get-SyncCatalog -Root $s.Root -Key $s.Key) | Where-Object { $_.chatKey -eq $Pull -or $_.bundleId -eq $Pull } | Select-Object -First 1
        if (-not $row) { throw "No chat on Drive matches '$Pull'. Use a chat key such as claude:local_xxx, or a bundle id." }
        if ($Target) {
            $tp = @($Target -split ':', 2)
            if ($tp.Count -ne 2 -or $tp -contains '') { throw 'Use -SyncTarget <harness>:<profile>.' }
            $dest = Resolve-SyncCliProfile -Harness $tp[0] -Profile $tp[1]
        } else {
            $dest = @(& (Get-Harness -Name $row.harness).Adapter.GetProfiles) | Select-Object -First 1
            if (-not $dest) { throw "There is no $($row.harness) profile to pull into. Use -SyncTarget <harness>:<profile>." }
        }
        $res = Invoke-SyncPull -Row $row -Target $dest
        if ($res.Status -eq 'needs-root') { throw "The folder '$($res.Root)' is not set on this machine, so the chat cannot be placed. Pull it once from the tray menu (Sync: Pull...) to choose the folder." }
        Get-HarnessTransferMessage -Result $res -Target $dest
        if ($res.Path) { "Handoff file: $($res.Path)" }
        if ($res.Prompt) { "Opening prompt: $($res.Prompt)" }
    } catch {
        throw (Get-SyncErrorMessage -Message $_.Exception.Message)
    }
}
