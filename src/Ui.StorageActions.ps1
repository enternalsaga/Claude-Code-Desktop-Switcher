# Ui.StorageActions.ps1 - what the buttons of the Storage tab do (phase 6, lane U1): which actions a selection allows, the text of
# every confirmation, where archives go, the Codex app-server wrapper, the background runner and the batches it runs. Everything
# that decides something is a function without WinForms and is tested without a window. Real work goes through the functions
# of the other lanes: Invoke-StorageArchive / Restore (A1), Remove-StorageSessionOriginal (A1), Invoke-StorageTrim /
# Invoke-StorageSummarize (C1, optional: their buttons stay off until those functions exist). ASCII only.

# Whether Archive | Delete | Restore works for a harness: asks Test-StorageHarnessSupported (lane A1-6) when it exists, else the
# default is claude and codex yes, antigravity no (until A1-6 can remove an Antigravity session).
function Test-StorageUiHarnessSupported {
    param([AllowEmptyString()][string]$Harness, [Parameter(Mandatory)][string]$Action)
    if (Get-Command Test-StorageHarnessSupported -CommandType Function -ErrorAction SilentlyContinue) { return [bool](Test-StorageHarnessSupported -Harness $Harness -Action $Action) }
    return ($Harness -ne 'antigravity')
}

# ---- Codex app-server (U1-10) -------------------------------------------------------------------------------------------------------

# The -CodexRpc of lane A1: a scriptblock { param($CodexHome, $Method, $Params) }. One app-server is started per CodexHome the
# first time it is asked and reused for the rest of the batch; an RPC error throws (never an empty result). Close-StorageCodexRpc
# stops every server it started. The three hooks are replaced by tests; the defaults reuse the client of phase 2.
function New-StorageCodexRpc {
    param([scriptblock]$Start = { param($home2) $exe = Resolve-CodexExePath; if (-not $exe) { throw 'codex-not-found: Codex is not installed on this machine.' }; Start-CodexAppServer -CodexHome $home2 -CodexExe $exe },
          [scriptblock]$Call = { param($srv, $method, $params, $notify) if ($notify) { Invoke-CodexRpc -Server $srv -Method $method -Notify } else { Invoke-CodexRpc -Server $srv -Method $method -Params $params -TimeoutSec 60 } },
          [scriptblock]$Stop = { param($srv) Stop-CodexAppServer -Server $srv })
    $servers = @{}
    return { param($CodexHome, $Method, $Params)
        if ($Method -eq '__close') {
            foreach ($k in @($servers.Keys)) { try { & $Stop $servers[$k] } catch { } ; $servers.Remove($k) }
            return
        }
        $k = ([string]$CodexHome).ToLowerInvariant()
        if (-not $servers.ContainsKey($k)) {
            $srv = & $Start $CodexHome
            try {
                [void](& $Call $srv 'initialize' @{ clientInfo = @{ name = 'harness-switcher'; version = '1' } } $false)
                [void](& $Call $srv 'initialized' $null $true)
            } catch { try { & $Stop $srv } catch { } ; throw }
            $servers[$k] = $srv
        }
        return (& $Call $servers[$k] $Method $Params $false)
    }.GetNewClosure()
}

function Close-StorageCodexRpc {
    param([scriptblock]$Rpc)
    if ($Rpc) { & $Rpc $null '__close' $null }
}

# ---- where archives go (U1-8) ---------------------------------------------------------------------------------------------------------

# The stored Storage.ArchiveTarget as @{ kind = 'local'; path } or @{ kind = 'drive' }, or $null when unset or not usable.
function Get-StorageTargetSetting {
    $v = Get-Setting 'Storage.ArchiveTarget'
    if ($null -eq $v) { return $null }
    $get = { param($k) if ($v -is [System.Collections.IDictionary]) { $v[$k] } elseif ($v.PSObject.Properties[$k]) { $v.PSObject.Properties[$k].Value } }
    $kind = [string](& $get 'kind'); $path = [string](& $get 'path')
    if ($kind -eq 'drive') { return @{ kind = 'drive'; path = '' } }
    if ($kind -eq 'local' -and (Test-SyncAbsolutePath $path)) { return @{ kind = 'local'; path = $path.TrimEnd('\') } }
    return $null
}

function Set-StorageTargetSetting {
    param([Parameter(Mandatory)][ValidateSet('local', 'drive')][string]$Kind, [string]$Path = '')
    if ($Kind -eq 'local' -and -not (Test-SyncAbsolutePath $Path)) { throw "The archive folder must be a full path (D:\folder or \\server\share): $Path" }
    Set-Setting 'Storage.ArchiveTarget' @{ kind = $Kind; path = $(if ($Kind -eq 'local') { $Path.TrimEnd('\') } else { '' }) }
}

function Get-StorageTargetText {
    $t = Get-StorageTargetSetting
    if (-not $t) { return 'not chosen yet' }
    return $(if ($t.kind -eq 'drive') { 'Google Drive (encrypted)' } else { [string]$t.path })
}

# What the first archive offers: a folder (suggested under the user profile) and, when Drive sync works here, Drive.
function Get-StorageTargetChoices {
    param([bool]$SyncReady, [string]$UserProfile = $env:USERPROFILE)
    $c = @(@{ Kind = 'local'; Path = (Join-Path $UserProfile 'HarnessArchive'); Text = 'A folder on this computer' })
    if ($SyncReady) { $c += @{ Kind = 'drive'; Path = ''; Text = 'Google Drive, encrypted with your sync key' } }
    return $c
}

# The store for lane A1, from the setting: @{ Kind = 'local'; Path } or @{ Kind = 'drive'; SyncRoot; MachineId; Key }. $null when unset.
function Resolve-StorageTarget {
    $t = Get-StorageTargetSetting
    if (-not $t) { return $null }
    if ($t.kind -eq 'local') { return @{ Kind = 'local'; Path = $t.path; PathMap = @{} } }
    return (Get-StorageDriveTarget)
}

function Get-StorageDriveTarget {
    $s = Get-SyncSession
    return @{ Kind = 'drive'; SyncRoot = $s.Root; MachineId = [string](Get-SyncMachine).Id; Key = $s.Key; PathMap = @{} }
}

# ---- what is allowed (U1-5, U1-11) -----------------------------------------------------------------------------------------------------

function Get-StorageSelectionLabel {
    param([array]$Rows)
    $rows = @($Rows | Where-Object { $null -ne $_ })
    $bytes = [long]0; foreach ($r in $rows) { $bytes += $r.Bytes }
    if (-not $rows.Count) { return 'Selected: 0 sessions' }
    return ('Selected: {0} session{1}, {2}' -f $rows.Count, $(if ($rows.Count -eq 1) { '' } else { 's' }), (Format-StorageSize $bytes))
}

# Why an action cannot be done to this session, or '' when it can. Action: Archive | Delete | Trim | Summarize.
function Get-StorageActionBlock {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Action)
    if ($Session.Flags.DbUnreadable) { return 'The database of this profile could not be read, so what belongs to this session is not known.' }
    if ($Action -in 'Archive', 'Delete' -and -not (Test-StorageUiHarnessSupported -Harness $Session.Harness -Action $Action)) { return 'Antigravity sessions cannot be archived or deleted yet.' }
    if ($Action -eq 'Trim') {
        if (-not (Get-Command Invoke-StorageTrim -CommandType Function -ErrorAction SilentlyContinue)) { return 'Trim is not available yet.' }
        if ($Session.Harness -eq 'antigravity' -or -not $Session.Flags.Trimmable -or $Session.Flags.HasZst) { return 'This session cannot be trimmed.' }
    }
    if ($Action -eq 'Summarize' -and -not (Get-Command Invoke-StorageSummarize -CommandType Function -ErrorAction SilentlyContinue)) { return 'Summarize is not available yet.' }
    return ''
}

# Which buttons of the live view are on for the ticked rows: an action is on when at least one ticked session can have it done
# now. Include anyway is for exactly one ticked recent session.
function Get-StorageActionState {
    param([array]$Rows)
    $rows = @($Rows | Where-Object { $null -ne $_ })
    $on = { param($a) [bool]@($rows | Where-Object { $_.Actionable -and -not (Get-StorageActionBlock -Session $_.Session -Action $a) }).Count }
    $one = $(if ($rows.Count -eq 1) { $rows[0] } else { $null })
    return @{ Archive = (& $on 'Archive'); Trim = (& $on 'Trim'); Summarize = (& $on 'Summarize'); Delete = (& $on 'Delete')
              Include = [bool]($one -and $one.State -eq 'recent' -and -not $one.Actionable -and $one.Selectable) }
}

# The buttons of the archived view for the selected row: Restore (not when it is back already), Delete archive (not another
# machine's Drive archive: only the machine that owns it deletes it), Open summary (when a summary file exists).
function Get-StorageArchivedActionState {
    param($Row, [string]$ThisMachine = '', [bool]$SummaryExists = $false)
    if (-not $Row) { return @{ Restore = $false; DeleteArchive = $false; OpenSummary = $false } }
    return @{ Restore = (-not $Row.Restored -and (Test-StorageUiHarnessSupported -Harness ([string]$Row.Harness) -Action 'Restore')); DeleteArchive = ($Row.Source -eq 'local' -or [string]$Row.MachineId -eq $ThisMachine); OpenSummary = $SummaryExists }
}

# The ticked sessions split into what can be done now and what is left out with the reason. Uses the guard of lane A1.
# -Running is @{ claude = @(profile ids); antigravity = @(...) }; -CliCwds the folders of running Claude CLIs.
function Get-StorageActionPlan {
    param([array]$Rows, [Parameter(Mandatory)][string]$Action, $Running = @{}, [string[]]$CliCwds = @(), [hashtable]$Include = @{}, [scriptblock]$LockProbe)
    $safe = New-Object Collections.Generic.List[object]; $blocked = New-Object Collections.Generic.List[object]
    foreach ($r in @($Rows | Where-Object { $null -ne $_ })) {
        $why = Get-StorageActionBlock -Session $r.Session -Action $Action
        if (-not $why) {
            $g = @{ Session = $r.Session; Running = $Running; CliCwds = $CliCwds }
            if ($Include[[string]$r.Key]) { $g.IncludeRecent = $true }
            if ($LockProbe) { $g.LockProbe = $LockProbe }
            $s = Test-StorageSessionSafe @g
            if (-not $s.Safe) { $why = $s.Reason }
        }
        if ($why) { $blocked.Add([pscustomobject]@{ Key = $r.Key; Title = $r.Title; Reason = $why }) } else { $safe.Add($r) }
    }
    return @{ Safe = $safe.ToArray(); Blocked = $blocked.ToArray() }
}

# Profile ids whose app is running, per harness, for the guard. Source is replaced by tests; the default asks the machine.
function Get-StorageRunningIds {
    param($Roots, [scriptblock]$Source)
    if ($Source) { return (& $Source) }
    $ids = @{ claude = @(); codex = @(); antigravity = @() }
    try {
        $map = Get-RunningProfileMap
        $ids.claude = @($Roots.ClaudeProfiles | Where-Object { $_ -and $map.ContainsKey(([string]$_.DataDir).TrimEnd('\')) } | ForEach-Object { [string]$_.Id })
    } catch { Write-HarnessLog "Storage: could not tell which Claude profiles run: $($_.Exception.Message)" }
    try {
        $ids.antigravity = @(Find-AntigravityInstall | Where-Object { Find-AgyMainProcessId -Exe $_.Exe } | ForEach-Object { [string]$_.Id })
    } catch { Write-HarnessLog "Storage: could not tell whether Antigravity runs: $($_.Exception.Message)" }
    return $ids
}

# ---- the text of every confirmation (U1-6) ----------------------------------------------------------------------------------------------

function Get-StorageProviderText {
    param([string]$Tool)
    switch ($Tool) { 'claude' { return 'Anthropic' } 'codex' { return 'OpenAI' } default { return $Tool } }
}

# What the confirmation box says. Rows are the sessions that will be touched (or archived rows for Restore / DeleteArchive);
# -Blocked the ones left out; -Plan the rows of Get-StorageSummaryPlan; -Target the text of where archives go. The box has two
# buttons and the default is Cancel.
function Get-StorageConfirmContent {
    param([Parameter(Mandatory)][string]$Action, [array]$Rows, [array]$Blocked = @(), [array]$Plan = @(), [string]$TargetText = '', [string]$Mode = '')
    $rows = @($Rows | Where-Object { $null -ne $_ })
    $bytes = [long]0; foreach ($r in $rows) { $bytes += $r.Bytes }
    $n = '{0} session{1} ({2})' -f $rows.Count, $(if ($rows.Count -eq 1) { '' } else { 's' }), (Format-StorageSize $bytes)
    $names = @($rows | ForEach-Object { if ($_.Session) { @($_.Session.Profiles | ForEach-Object { $_.Name }) } } | Where-Object { $_ } | Sort-Object -Unique)
    $profiles = $(if ($names.Count) { 'Profiles affected: ' + ($names -join ', ') + '. A session shared by several profiles disappears from all of them.' } else { 'No profile is affected (CLI sessions only).' })
    $t = switch ($Action) {
        'Archive' { @{ Title = 'Archive sessions'; Ok = 'Archive'; Body = "Archive $n to ${TargetText}?`n`n$profiles`n`nEach session is zipped, checked, and copied to the archive. Only after the copy is verified is it removed from the app, and the original is then deleted for good. You can bring it back from the Archived view." } }
        'Delete'  { @{ Title = 'Delete sessions'; Ok = 'Delete'; Body = "Delete ${n}?`n`n$profiles`n`nRecoverable from the Recycle Bin until it is emptied. If Windows would delete a file for good instead (a drive without a Recycle Bin, or a file too large for it), that session is refused and nothing is deleted." } }
        'Trim'    { @{ Title = 'Trim sessions'; Ok = 'Trim'; Body = "Trim the large tool outputs of ${n}?`n`n$profiles`n`nA full archive is made first, so the cut text can be brought back. Mode: $Mode." } }
        'Restore' { @{ Title = 'Restore sessions'; Ok = 'Restore'; Body = "Restore $n to where they were?`n`nA file that already exists and differs is renamed to .bak first. Close the apps of the profiles involved before you restore." } }
        'DeleteArchive' { @{ Title = 'Delete archive'; Ok = 'Delete archive'; Body = "Delete the archive of $n for good?`n`nThis cannot be undone: the archive is not sent to the Recycle Bin." } }
        'Summarize' {
            $tokens = [long]0; foreach ($p in $Plan) { $tokens += [long]$p.EstTokens }
            $tools = @($Plan | ForEach-Object { $_.Tool } | Sort-Object -Unique)
            $prov = @($tools | ForEach-Object { Get-StorageProviderText $_ } | Sort-Object -Unique)
            @{ Title = 'Summarize sessions'; Ok = 'Summarize'
               Body = "Summarize $n with $($tools -join ', ')?`n`nAbout $($tokens.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)) input tokens in total.`n`nThis sends the redacted transcript to $($prov -join ', ') using your $($tools -join ', ') sign-in and uses tokens. A full archive is made first." }
        }
    }
    $body = $t.Body
    if ($Action -in 'Archive', 'Delete' -and @($rows | Where-Object { $_.Session -and $_.Session.Harness -eq 'claude' }).Count) { $body += "`n`nClose any Claude Code terminal still working in these folders first; it cannot be detected." }
    if (@($Blocked).Count) { $body += "`n`nLeft out:`n" + ((@($Blocked | Select-Object -First 8 | ForEach-Object { '- {0}: {1}' -f $_.Title, $_.Reason }) -join "`n")) + $(if (@($Blocked).Count -gt 8) { "`n- and $(@($Blocked).Count - 8) more" } else { '' }) }
    return @{ Title = $t.Title; Text = $body; Ok = $t.Ok; DefaultButton = 'Cancel' }
}

# Shows it. Cancel is the default button, so Enter never confirms. Returns $true only for the action button.
function Show-StorageConfirm {
    param([Parameter(Mandatory)]$Content)
    $r = [System.Windows.Forms.MessageBox]::Show($Content.Text, $Content.Title, 'OKCancel', 'Warning', 'Button2')
    return ($r -eq 'OK')
}

# ---- the background runner (U1-7: every action runs here, with a progress bar and Stop) ---------------------------------------------------

function Get-StorageJobVariableNames { return '^(Sync|Storage|Switcher|ProfileRoot|SettingsPath|LogPath|DefaultName|DefaultProfilePath|ProfileDirPrefix|Codex|Agy|Harness)' }

# A runspace that has every function the program defines (the ones that come from a script file) and the script-scope values the
# sync and storage code needs. The job gets its own copies of the functions, so it never touches the UI thread.
function New-StorageJobRunspace {
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in @(Get-ChildItem Function:)) {
        if ($f.ScriptBlock -and $f.ScriptBlock.File) { $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($f.Name, $f.Definition))) }
    }
    foreach ($v in @(Get-Variable -Scope Script | Where-Object { $_.Name -match (Get-StorageJobVariableNames) -and $null -ne $_.Value })) {
        $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry($v.Name, $v.Value, $null)))
    }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    return $rs
}

# Runs script text { param($A, $Progress, $Cancel) ... } in a runspace and returns at once, in the shape Stop-StorageScan and
# Close-StorageScan work on: Progress (Phase, Done, Total, Finished, Cancelled, Error, Result) and Cancel are synchronized
# hashtables. An error in the job ends in Progress.Error; it is never thrown at the caller.
function Start-StorageJob {
    param([Parameter(Mandatory)][string]$Script, [hashtable]$Arguments = @{}, [int]$Total = 0)
    $rs = New-StorageJobRunspace
    $progress = [hashtable]::Synchronized(@{ Phase = 'working'; Done = 0; Total = $Total; Finished = $false; Cancelled = $false; Error = $null; Result = $null; Warnings = @() })
    $cancel = [hashtable]::Synchronized(@{ Cancel = $false })
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $body = @'
param($Text, $A, $Progress, $Cancel)
try {
    $r = & ([scriptblock]::Create($Text)) $A $Progress $Cancel
    $Progress.Result = $r
    if ($Cancel['Cancel']) { $Progress.Cancelled = $true }
} catch { $Progress.Error = $_.Exception.Message } finally { $Progress.Finished = $true }
'@
    [void]$ps.AddScript($body).AddArgument($Script).AddArgument($Arguments).AddArgument($progress).AddArgument($cancel)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ Progress = $progress; Cancel = $cancel; PowerShell = $ps; Runspace = $rs; Handle = $handle }
}

# The script text of one action. Archive and Restore start a Codex app-server only when the batch holds a Codex session.
function Get-StorageJobScript {
    param([Parameter(Mandatory)][ValidateSet('Archive', 'Delete', 'Restore', 'Trim', 'Summarize')][string]$Action)
    $body = switch ($Action) {
        'Archive' { '@(Invoke-StorageArchive -Sessions $A.Sessions -Target $A.Target -Roots $A.Roots -MachineId $A.MachineId -Running $A.Running -IncludeRecent $A.IncludeRecent -Progress $Progress -CancelToken $Cancel @rpcArg)' }
        'Delete' { '@(Invoke-StorageDeleteBatch -Sessions $A.Sessions -Roots $A.Roots -Running $A.Running -IncludeRecent $A.IncludeRecent -Progress $Progress -CancelToken $Cancel @rpcArg)' }
        'Restore' { '@(Invoke-StorageRestore -Entries $A.Entries -Target $A.Target -Roots $A.Roots -Running $A.Running -CancelToken $Cancel @rpcArg)' }
        'Trim' { '@(Invoke-StorageTrim -Sessions $A.Sessions -Target $A.Target -Mode $A.Mode)' }
        'Summarize' { '@(Invoke-StorageSummarize -Sessions $A.Sessions -Target $A.Target -Confirmed:$true)' }
    }
    return @"
param(`$A, `$Progress, `$Cancel)
`$rpc = `$null; `$rpcArg = @{}
try {
    if (`$A.NeedCodex) { `$rpc = New-StorageCodexRpc; `$rpcArg = @{ CodexRpc = `$rpc } }
    $body
} finally { if (`$rpc) { Close-StorageCodexRpc -Rpc `$rpc } }
"@
}

# Delete (Recycle Bin) for a batch: each session goes through the guard first; one that is skipped or fails does not stop the
# rest; Cancel stops before the next session. Returns @{ Key; Ok; Skipped; Reason; Warnings } per session.
function Invoke-StorageDeleteBatch {
    param([Parameter(Mandatory)][array]$Sessions, [Parameter(Mandatory)]$Roots, $Running = @{}, [string[]]$IncludeRecent = @(), [scriptblock]$CodexRpc, $Progress, $CancelToken,
          [scriptblock]$Recycler, [scriptblock]$VolumeInfo, [scriptblock]$LockProbe, [string[]]$CliCwds = @())
    $results = New-Object Collections.Generic.List[object]
    foreach ($s in $Sessions) {
        if (Test-StorageCancel $CancelToken) { break }
        $res = @{ Key = [string]$s.Key; Ok = $false; Skipped = $false; Reason = ''; Warnings = @() }
        $g = @{ Session = $s; Running = $Running; CliCwds = $CliCwds }
        if ($IncludeRecent -contains [string]$s.Key) { $g.IncludeRecent = $true }
        if ($LockProbe) { $g.LockProbe = $LockProbe }
        $safe = Test-StorageSessionSafe @g
        if (-not $safe.Safe) { $res.Skipped = $true; $res.Reason = $safe.Reason }
        else {
            try {
                $r = @{ Session = $s; Roots = $Roots; Mode = 'Recycle' }
                foreach ($p in 'CodexRpc', 'Recycler', 'VolumeInfo') { if ((Get-Variable $p).Value) { $r[$p] = (Get-Variable $p).Value } }
                $rm = Remove-StorageSessionOriginal @r
                if (@($rm.Skipped).Count) { $res.Warnings = @($rm.Skipped | ForEach-Object { "Not removed: $_" }) }
                $res.Ok = $true
            } catch { $res.Reason = $_.Exception.Message }
        }
        $results.Add($res)
        if ($Progress) { $Progress['Done'] = [int]$Progress['Done'] + 1 }
    }
    return $results.ToArray()
}

# One line per result for the box that follows an action: done, skipped with the reason, or failed with the reason.
function Get-StorageResultRows {
    param([array]$Results, [array]$Rows = @())
    $titles = @{}; foreach ($r in @($Rows)) { if ($r) { $titles[[string]$r.Key] = [string]$r.Title } }
    return @(foreach ($x in @($Results)) {
        if ($null -eq $x) { continue }
        $status = $(if ($x.Ok) { 'Done' } elseif ($x.Skipped) { 'Skipped' } else { 'Failed' })
        [pscustomobject]@{ Key = [string]$x.Key; Title = $(if ($titles.ContainsKey([string]$x.Key)) { $titles[[string]$x.Key] } else { [string]$x.Key }); Status = $status
            Reason = (@([string]$x.Reason) + @($x.Warnings) | Where-Object { $_ }) -join ' ' }
    })
}

# After an action: the sessions that were archived or deleted leave the inventory in memory (a scan is not repeated for that).
function Remove-StorageInventorySessions {
    param($Inventory, [string[]]$Keys)
    if (-not $Inventory -or -not $Keys.Count) { return $Inventory }
    $o = [ordered]@{}; foreach ($p in $Inventory.PSObject.Properties) { $o[$p.Name] = $p.Value }
    $o['Sessions'] = @(@($Inventory.Sessions) | Where-Object { $Keys -notcontains [string]$_.Key })
    return [pscustomobject]$o
}

# ---- dialogs -------------------------------------------------------------------------------------------------------------------------------

# Asks where archives go. Returns @{ Kind; Path } or $null. Real dialog; tests replace this function.
function Read-StorageTargetChoice {
    param([array]$Choices)
    $s = Get-MainUiStyle
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Where should archives go?'; $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(540, 170); $dlg.BackColor = $s.Bg
    $path = New-Object System.Windows.Forms.TextBox; $path.Location = New-Object System.Drawing.Point(40, 34); $path.Size = New-Object System.Drawing.Size(380, 24); $path.Text = [string]$Choices[0].Path
    $browse = New-MainButton -Text 'Browse...' -X 430 -Width 90; $browse.Location = New-Object System.Drawing.Point(430, 31)
    $browse.Add_Click({ $p = Read-SyncFolder -Description 'Folder for the archives'; if ($p) { $path.Text = $p } }.GetNewClosure())
    $radios = @(); $y = 8
    foreach ($c in $Choices) {
        $r = New-Object System.Windows.Forms.RadioButton; $r.Text = $c.Text; $r.Tag = $c; $r.Location = New-Object System.Drawing.Point(16, $y); $r.Size = New-Object System.Drawing.Size(500, 24)
        $radios += $r; $dlg.Controls.Add($r); $y += $(if ($c.Kind -eq 'local') { 60 } else { 30 })
    }
    $radios[0].Checked = $true
    $ok = New-MainButton -Text 'OK' -X 330 -Width 90; $ok.Location = New-Object System.Drawing.Point(330, 126); $ok.DialogResult = 'OK'
    $cancel = New-MainButton -Text 'Cancel' -X 430 -Width 90; $cancel.Location = New-Object System.Drawing.Point(430, 126); $cancel.DialogResult = 'Cancel'
    foreach ($c in $path, $browse, $ok, $cancel) { $dlg.Controls.Add($c) }
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    if ($dlg.ShowDialog() -ne 'OK') { return $null }
    $pick = @($radios | Where-Object { $_.Checked })[0].Tag
    return @{ Kind = [string]$pick.Kind; Path = $(if ($pick.Kind -eq 'local') { $path.Text.Trim() } else { '' }) }
}

# Change... and the first archive: ask, validate, remember. Returns $true when a target is set afterwards.
function Select-StorageArchiveTarget {
    param([Parameter(Mandatory)]$Ctx)
    $pick = Read-StorageTargetChoice -Choices (Get-StorageTargetChoices -SyncReady (Test-SyncReady))
    if ($pick) {
        try { Set-StorageTargetSetting -Kind $pick.Kind -Path $pick.Path } catch { $Ctx.Status.Text = $_.Exception.Message; return $false }
        $Ctx.ArchiveLabel.Text = Get-StorageTargetText
    }
    return [bool](Get-StorageTargetSetting)
}

# The compact list that follows an action: what was done, what was skipped and why, what failed.
function Show-StorageResults {
    param([array]$Rows, [string]$Title = 'Result')
    $s = Get-MainUiStyle
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.StartPosition = 'CenterParent'; $dlg.ClientSize = New-Object System.Drawing.Size(720, 360); $dlg.BackColor = $s.Bg
    $l = New-StorageListView @(@('Session', 260), @('Result', 80), @('Why', 360))
    $l.Dock = 'Fill'
    foreach ($r in $Rows) { $it = New-Object System.Windows.Forms.ListViewItem($r.Title); [void]$it.SubItems.Add($r.Status); [void]$it.SubItems.Add($r.Reason); [void]$l.Items.Add($it) }
    $dlg.Controls.Add($l)
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}

# ---- the archived view and the buttons ------------------------------------------------------------------------------------------------------

# The summary file next to a local archive (<key>.summary.md beside the zip), or $null.
function Get-StorageSummaryFile {
    param($Row)
    if (-not $Row -or $Row.Source -ne 'local' -or -not $Row.Row.entry) { return $null }
    $t = Get-StorageTargetSetting
    if (-not $t -or $t.kind -ne 'local') { return $null }
    $zip = Join-Path $t.path (([string]$Row.Row.entry) -replace '/', '\')
    if (-not (Test-StoragePathAllowed -Path $zip -Roots @($t.path))) { return $null }
    $f = Join-Path (Split-Path -Parent $zip) ((Split-Path -Leaf $zip) -replace '\.harchive\.zip$', '.summary.md')
    return $(if ([IO.File]::Exists($f)) { $f } else { $null })
}

# Reads the archive indexes (the local folder, and Drive when sync works here, every machine's) into the archived rows. A store
# that cannot be read is a line of text, not an error.
function Read-StorageArchivedList {
    param([Parameter(Mandatory)]$Ctx)
    $local = @(); $drive = @(); $notes = @()
    $t = Get-StorageTargetSetting
    try { if ($t -and $t.kind -eq 'local') { $local = @(Get-StorageArchiveIndex -Target @{ Kind = 'local'; Path = $t.path }) } } catch { $notes += "Local archives: $($_.Exception.Message)" }
    try {
        if (Test-SyncReady) { $d = Get-StorageDriveTarget; $Ctx.ThisMachine = $d.MachineId; $drive = @(Get-StorageArchiveIndex -Target $d -AllMachines) }
    } catch { $notes += "Drive archives: $($_.Exception.Message)" }
    $keys = @(if ($Ctx.Inventory) { @($Ctx.Inventory.Sessions) | ForEach-Object { [string]$_.Key } })
    $Ctx.ArchivedRows = @(Get-StorageArchivedRows -Local $local -Drive $drive -InventoryKeys $keys -ThisMachine ([string]$Ctx.ThisMachine))
    $Ctx.Status.Text = $(if ($notes.Count) { $notes -join ' ' } elseif (-not $t -and -not $drive.Count) { 'No archive folder chosen yet.' } else { '' })
}

# What a button does. Errors become the status line; nothing here throws at the window.
function Invoke-StorageAction {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    if ($Ctx.Busy) { return }
    try {
        if ($Name -eq 'Include') { $r = @(Get-StorageCheckedRows -Ctx $Ctx)[0]; if ($r) { $Ctx.Include[$r.Key] = $true }; Update-StorageTab -Ctx $Ctx }
        elseif ($Name -in 'Archive', 'Delete', 'Trim', 'Summarize') { Start-StorageLiveAction -Ctx $Ctx -Name $Name }
        else { Start-StorageArchivedAction -Ctx $Ctx -Name $Name }
    } catch { $Ctx.Status.Text = ('{0} failed: {1}' -f $Name, $_.Exception.Message) }
}

function Get-StorageThisMachine {
    try { return [string](Get-SyncMachine).Id } catch { return '' }
}

# Archive, Delete, Trim or Summarize the ticked sessions: guard, ask where, confirm (Cancel is the default), then run in the background.
function Start-StorageLiveAction {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    $roots = Get-StorageRootsFromConfig -Config $null
    $running = Get-StorageRunningIds -Roots $roots
    $plan = Get-StorageActionPlan -Rows (Get-StorageCheckedRows -Ctx $Ctx) -Action $Name -Running $running -Include $Ctx.Include
    $Ctx.JobRows = @($plan.Safe)
    $Ctx.JobBlocked = @($plan.Blocked | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Title = $_.Title; Status = 'Skipped'; Reason = $_.Reason } })
    if (-not $plan.Safe.Count) { Show-StorageResults -Rows $Ctx.JobBlocked -Title "${Name}: nothing can be done now"; return }
    $target = $null
    if ($Name -ne 'Delete') {
        if (-not (Get-StorageTargetSetting) -and -not (Select-StorageArchiveTarget -Ctx $Ctx)) { return }
        $target = Resolve-StorageTarget
    }
    $sessions = @($plan.Safe | ForEach-Object { $_.Session })
    $mode = 'ReadOnlyCopy'
    if ($Name -eq 'Trim' -and $script:StorageTrimInPlace -and -not @($sessions | Where-Object { -not $script:StorageTrimInPlace[[string]$_.Harness] }).Count) { $mode = 'InPlace' }
    $sumPlan = $(if ($Name -eq 'Summarize') { @(Get-StorageSummaryPlan -Sessions $sessions) } else { @() })
    $content = Get-StorageConfirmContent -Action $Name -Rows $plan.Safe -Blocked $plan.Blocked -Plan $sumPlan -TargetText (Get-StorageTargetText) -Mode $mode
    if (-not (Show-StorageConfirm -Content $content)) { return }
    $a = @{ Sessions = $sessions; Target = $target; Roots = $roots; MachineId = (Get-StorageThisMachine); Running = $running; IncludeRecent = @($Ctx.Include.Keys); Mode = $mode
            NeedCodex = [bool]@($sessions | Where-Object { $_.Harness -eq 'codex' }).Count }
    $Ctx.Job = Start-StorageJob -Script (Get-StorageJobScript -Action $Name) -Arguments $a -Total $sessions.Count
    Start-StorageJobTimer -Ctx $Ctx -Kind $Name -Label $Name
}

# Restore, Delete archive or Open summary for the selected archived row.
function Start-StorageArchivedAction {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    $sel = $(if ($Ctx.ArchList.SelectedItems.Count) { $Ctx.ArchList.SelectedItems[0].Tag } else { $null })
    if (-not $sel) { return }
    if ($Name -eq 'OpenSummary') { $f = Get-StorageSummaryFile -Row $sel; if ($f) { Start-Process -FilePath $f }; return }
    $target = $(if ($sel.Source -eq 'drive') { Get-StorageDriveTarget } else { Resolve-StorageTarget })
    if (-not $target) { $Ctx.Status.Text = 'No archive folder chosen yet.'; return }
    $content = Get-StorageConfirmContent -Action $(if ($Name -eq 'Restore') { 'Restore' } else { 'DeleteArchive' }) -Rows @($sel)
    if (-not (Show-StorageConfirm -Content $content)) { return }
    if ($Name -eq 'DeleteArchive') { Remove-StorageArchiveRow -Row $sel -Target $target; Read-StorageArchivedList -Ctx $Ctx; Update-StorageTab -Ctx $Ctx; return }
    if ($sel.Source -eq 'drive' -and $sel.MachineId -ne $target.MachineId) { $target.PathMap = Get-StorageDrivePathMap -SyncRoot $target.SyncRoot -MachineId $sel.MachineId }
    $roots = Get-StorageRootsFromConfig -Config $null
    $Ctx.JobRows = @($sel); $Ctx.JobBlocked = @()
    $a = @{ Entries = @($sel.Row); Target = $target; Roots = $roots; Running = (Get-StorageRunningIds -Roots $roots); NeedCodex = ($sel.Harness -eq 'codex') }
    $Ctx.Job = Start-StorageJob -Script (Get-StorageJobScript -Action 'Restore') -Arguments $a -Total 1
    Start-StorageJobTimer -Ctx $Ctx -Kind 'Restore' -Label 'Restoring'
}

# Deletes the archive itself: its row and its file, from the local folder or (own machine only) from Drive.
function Remove-StorageArchiveRow {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Target)
    if ($Row.Source -eq 'drive') { Remove-StorageDriveArchive -Entry $Row.Row -SyncRoot $Target.SyncRoot -MachineId $Target.MachineId; return }
    $zip = Join-Path $Target.Path (([string]$Row.Row.entry) -replace '/', '\')
    if (-not (Test-StoragePathAllowed -Path $zip -Roots @($Target.Path))) { throw 'The index row points outside the archive folder.' }
    Remove-StorageArchiveIndex -Target $Target -Key $Row.Key
    if ([IO.File]::Exists($zip)) { Remove-Item -LiteralPath $zip -Force }
}

# What happens when a job has finished: a scan fills the inventory; an action shows its result list and drops what is gone.
function Complete-StorageJob {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Job)
    $p = $Job.Progress; $kind = [string]$Ctx.JobKind
    if ($p['Error']) { $Ctx.Status.Text = ('{0} failed: {1}' -f $(if ($kind -eq 'scan') { 'Scan' } else { $kind }), $p['Error']); return }
    if ($kind -eq 'scan') {
        if ($p['Cancelled']) { $Ctx.Status.Text = 'Scan stopped. The list is as it was before.'; return }
        $Ctx.Inventory = $p['Result']; $Ctx.Stats = Get-StorageStats -Inventory $Ctx.Inventory
        $have = @($Ctx.Inventory.Sessions | ForEach-Object { [string]$_.Key })
        foreach ($k in @($Ctx.Checked.Keys)) { if ($have -notcontains $k) { $Ctx.Checked.Remove($k) } }
        $Ctx.Status.Text = 'Scan finished.'
        return
    }
    $results = @($p['Result'])
    $rows = @(Get-StorageResultRows -Results $results -Rows $Ctx.JobRows) + @($Ctx.JobBlocked)
    $done = @($results | Where-Object { $_ -and $_.Ok } | ForEach-Object { [string]$_.Key })
    if ($kind -in 'Archive', 'Delete') {
        $Ctx.Inventory = Remove-StorageInventorySessions -Inventory $Ctx.Inventory -Keys $done
        $Ctx.Stats = Get-StorageStats -Inventory $Ctx.Inventory
        foreach ($k in $done) { $Ctx.Checked.Remove($k) }
    }
    if ($Ctx.Mode -eq 'Archived' -or $kind -eq 'Restore') { Read-StorageArchivedList -Ctx $Ctx }
    $Ctx.Status.Text = '{0}: {1} done, {2} skipped, {3} failed.{4}' -f $kind, $done.Count, @($rows | Where-Object { $_.Status -eq 'Skipped' }).Count, @($rows | Where-Object { $_.Status -eq 'Failed' }).Count, $(if ($p['Cancelled']) { ' Stopped before the end.' } else { ' Scan again to refresh the sizes.' })
    Show-StorageResults -Rows $rows -Title "$kind result"
}
