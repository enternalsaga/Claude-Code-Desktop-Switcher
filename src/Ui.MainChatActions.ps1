# Ui.MainChatActions.ps1 - what the buttons of a chat list do: Push, Pull, Move and Choose folder, for one chat or several.
# Split from Ui.MainChats.ps1 (the list and its rows) to keep each file under 500 lines. No window here except the dialogs
# the actions open; Invoke-ChatPanelAction shows the answer in the panel. ASCII only, like the rest of the script.

# ---- what the buttons do (no window; the handlers show the answer) -------------------------------------------------------

# Each returns @{ Kind = message|warning|error; Text; Prompt }.
function Invoke-ChatPush {
    param([Parameter(Mandatory)]$Harness, [Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Chat)
    try {
        [void](Invoke-SyncPush -Chat $Chat -SourceHarness $Harness.Name -Profile $Profile)
        return @{ Kind = 'message'; Text = ('Pushed "{0}" to Drive.' -f $Chat.Title); Prompt = $null }
    } catch { return @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message); Prompt = $null } }
}

function Invoke-ChatPull {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Status, [scriptblock]$AskRoot, [scriptblock]$OnDiverged)
    try {
        $r = Invoke-SyncPullAskingRoot -Row $Status.Row -Target $Profile -AskRoot $AskRoot -OnDiverged $OnDiverged
        if ($r.Status -eq 'close-first') { return @{ Kind = 'warning'; Text = "Close $($Profile.Name) first, then try again. Its chat list is not refreshed while it is open."; Prompt = $null } }
        $kind = $(if ($r.Status -eq 'needs-root') { 'warning' } else { 'message' })
        return @{ Kind = $kind; Text = (Get-HarnessTransferMessage -Result $r -Target $Profile); Prompt = $r.Prompt; Restart = (Test-ChatPullNeedsRestart -Profile $Profile -Status ([string]$r.Status)) }
    } catch { return @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message); Prompt = $null } }
}

# Pulls several chats into one profile; $Items: @{ Title; Status } with Status.Row the Drive catalog row. Each folder root
# is asked about once: a folder picked is saved and the next chats under it need no question, a question left unanswered
# is not asked again in this batch. A chat that changed on both machines gets its own question. -Ask is for tests.
function Invoke-ChatPullBatch {
    param([Parameter(Mandatory)]$Profile, [array]$Items, [int]$Skipped = 0, [string]$SkipReason = '',
        [scriptblock]$Ask = { param($rootName) Read-SyncFolder -Description "Where is the folder '$rootName' on this machine? The chat's working folder is inside it." })
    $declined = @{}
    $askRoot = {
        param($rootName)
        if ($declined.ContainsKey([string]$rootName)) { return $null }
        $path = & $Ask $rootName
        if (-not $path) { $declined[[string]$rootName] = $true }
        return $path
    }.GetNewClosure()
    $onDiverged = { param($row, $chat) Show-SyncDivergedDialog -Row $row -Chat $chat }
    $results = foreach ($it in @($Items)) { @{ Title = [string]$it.Title; Result = (Invoke-ChatPull -Profile $Profile -Status $it.Status -AskRoot $askRoot -OnDiverged $onDiverged) } }
    return (Get-ChatBatchResult -Verb 'Pulled' -Results @($results) -Skipped $Skipped -SkipReason $SkipReason)
}

# Claude Desktop reads its chat list only at start-up, so a chat written into a Claude profile shows after a restart.
function Test-ChatPullNeedsRestart {
    param([Parameter(Mandatory)]$Profile, [string]$Status)
    return ([string]$Profile.Harness -eq 'claude' -and $Status -in 'copied', 'updated', 'renamed')
}

# After a pull: when the Claude profile that got the chat is open, offer to restart it (as the old Copy did).
function Request-ChatPullRestart {
    param([Parameter(Mandatory)]$Profile, $Result)
    if (-not ($Result -and $Result.Restart) -or -not $Profile.Path) { return }
    $live = (Get-RunningProfileMap)[([string]$Profile.Path).TrimEnd('\')]
    if (-not $live) { return }
    $ask = "$($Result.Text)`n`n'$($Profile.Name)' is open and only lists new chats after a restart. Restart it now?`n`nAny Code session still running in '$($Profile.Name)' will be stopped."
    if ((Show-Message $ask 'Chat pulled' 'YesNo' 'Question') -eq 'Yes') { Restart-ClaudeProfile -Target $Profile -ProcessId $live }
}

# ---- several chats at once ----------------------------------------------------------------------------------------------

# Get-ChatPanelActions for one row of the list.
function Get-ChatViewActions {
    param([Parameter(Mandatory)]$View)
    $gone = [bool]($View.Chat.PSObject.Properties['HasRollout'] -and -not $View.Chat.HasRollout)
    return (Get-ChatPanelActions -Sync ([string]$View.Status.Sync) -HasSelection $true -CwdMissing ([bool]$View.CwdMissing) -Gone $gone)
}

# The buttons for several selected rows: Move, Push and Pull are on when they fit at least one row (they then act on those
# rows only); Choose folder fits one row at a time; the highlight shows only when every row asks for the same button.
function Get-ChatSelectionActions {
    param([array]$Views)
    $rows = @($Views | Where-Object { $_ })
    if (-not $rows.Count) { return (Get-ChatPanelActions -Sync '' -HasSelection $false -CwdMissing $false -Gone $false) }
    $each = @($rows | ForEach-Object { Get-ChatViewActions -View $_ })
    $a = @{ Continue = $true; Choose = ($rows.Count -eq 1 -and $each[0].Choose) }
    foreach ($n in 'Move', 'Push', 'Pull') { $a[$n] = [bool]@($each | Where-Object { $_[$n] }).Count }
    $lights = @($each | ForEach-Object { [string]$_.Highlight } | Select-Object -Unique)
    $a.Highlight = $(if ($lights.Count -eq 1 -and $lights[0]) { $lights[0] } else { $null })
    return $a
}

# One answer for an action on several chats. $Results: @{ Title; Result = @{ Kind; Text; Prompt; Restart } } per chat that
# was tried; $Skipped chats did not fit the action. One chat with nothing skipped keeps its own answer.
function Get-ChatBatchResult {
    param([Parameter(Mandatory)][string]$Verb, [array]$Results, [int]$Skipped = 0, [string]$SkipReason = '')
    $items = @($Results | Where-Object { $_ })
    if ($items.Count -eq 1 -and -not $Skipped) { return $items[0].Result }
    $failed = @($items | Where-Object { $_.Result.Kind -ne 'message' })
    $done = $items.Count - $failed.Count
    $parts = @('{0} {1} of {2} chat(s).' -f $Verb, $done, ($items.Count + $Skipped))
    if ($Skipped) { $parts += '{0} skipped ({1}).' -f $Skipped, $SkipReason }
    foreach ($f in $failed) { $parts += '"{0}": {1}' -f $f.Title, $f.Result.Text }
    $prompts = @($items | Where-Object { $_.Result.Prompt } | ForEach-Object { [string]$_.Result.Prompt })
    if ($prompts.Count -gt 1) { $parts += 'Only the last opening prompt is on the clipboard.' }
    $errors = @($failed | Where-Object { $_.Result.Kind -eq 'error' }).Count
    $kind = $(if ($items.Count -and -not $done -and $errors) { 'error' } elseif ($failed.Count -or $Skipped) { 'warning' } else { 'message' })
    return @{ Kind = $kind; Text = ($parts -join ' '); Prompt = $(if ($prompts.Count) { $prompts[-1] } else { $null }); Restart = [bool]@($items | Where-Object { $_.Result.Restart }).Count }
}

# ---- the click handler ---------------------------------------------------------------------------------------------------

function Invoke-ChatPanelAction {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    $views = @(Get-ChatPanelSelections -Ctx $Ctx)
    $profile = $Ctx.Profile
    if ($Name -eq 'Continue') {
        if ($profile) { Invoke-HarnessTrayLaunch -Harness $Ctx.Harness -Profile $profile }
        return
    }
    if ($Name -eq 'Load') {
        Use-ChatPanelBusy -Ctx $Ctx -Block { Update-ChatPanel -Ctx $Ctx -Load }
        return
    }
    if (-not $views.Count) { return }
    # Several rows: the action runs on the rows it fits (as Get-ChatSelectionActions turned the button on); the rest are counted.
    $fits = @($views | Where-Object { (Get-ChatViewActions -View $_)[$Name] })
    if ($Name -eq 'Pull') { $fits = @($fits | Where-Object { $_.Status.Row }) }
    $skipped = $views.Count - $fits.Count
    try {
        $res = $null; $reload = $false
        switch ($Name) {
            'Move' {
                if (-not $fits.Count) { return }
                $r = Show-HarnessMoveDialog -Chats @($fits | ForEach-Object { $_.Chat }) -SourceHarness $Ctx.Harness.Name
                if ($r) {
                    Clear-MainChatCache -Harness $r.Target.Harness -Profile $r.Target; $reload = $true
                    $res = Get-ChatBatchResult -Verb 'Moved' -Results @($r.Items | ForEach-Object { @{ Title = [string]$_.Chat.Title; Result = $_.Result } }) -Skipped $skipped -SkipReason 'their chat file is missing'
                }
            }
            'Push' {
                if (-not (Test-SyncReady)) { [void](Show-SyncSetupWizard); return }
                if (-not $fits.Count) { return }
                Start-ChatPushJob -Ctx $Ctx -Chats @($fits | ForEach-Object { $_.Chat }) -Profile $profile -Skipped $skipped
                return   # the job shows its own result when it ends
            }
            'Pull' {
                if (-not (Test-SyncReady)) { [void](Show-SyncSetupWizard); return }
                if (-not $fits.Count) { return }
                $items = @($fits | ForEach-Object { @{ Title = [string]$_.Chat.Title; Status = $_.Status } })
                Use-ChatPanelBusy -Ctx $Ctx -Block { $script:ChatActionResult = Invoke-ChatPullBatch -Profile $profile -Items $items -Skipped $skipped -SkipReason 'not on Drive, or nothing newer there' }
                $res = $script:ChatActionResult; $reload = $true
            }
            'Choose' { if ($views.Count -eq 1) { Invoke-ChatChooseFolder -Ctx $Ctx -View $views[0] } }
        }
        # Only this profile and the catalog are read again; the Drive tab is told it is out of date.
        if ($reload) { Use-ChatPanelBusy -Ctx $Ctx -Block { Update-ChatPanel -Ctx $Ctx -Load }; (Get-MainState).DriveStale = $true }
        if ($res) { Show-ChatPanelResult -Ctx $Ctx -Result $res }
        if ($Name -eq 'Pull') { Request-ChatPullRestart -Profile $profile -Result $res }
    } catch { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message $_.Exception.Message) } }
}

# ---- push in the background --------------------------------------------------------------------------------------------
# A chat with a big transcript takes about half a minute to push (scan, redact, zip, encrypt, write to Drive). On the window's
# thread the window froze for the whole batch, so Push runs on a runspace of its own (Start-StorageJob) and the window only
# polls its progress.

# The job: every chat in turn, one @{ Title; Result } each. The harness registry the job gets is a copy that holds scriptblocks
# of the window's runspace, which must not run on another thread, so the job registers its own first.
function Get-ChatPushJobScript {
    return @'
param($A, $Progress, $Cancel)
Register-Harnesses
$h = Get-Harness -Name $A.HarnessName
foreach ($c in @($A.Chats)) {
    $Progress['Current'] = [string]$c.Title
    @{ Title = [string]$c.Title; Result = (Invoke-ChatPush -Harness $h -Profile $A.Profile -Chat $c) }
    $Progress['Done'] = [int]$Progress['Done'] + 1
}
'@
}

function Get-ChatPushProgressText {
    param([Parameter(Mandatory)]$Progress)
    $n = [Math]::Min([int]$Progress['Done'] + 1, [int]$Progress['Total'])
    return ('Pushing {0} of {1}: {2}...' -f $n, $Progress['Total'], $Progress['Current'])
}

# Starts the push and a timer that shows which chat is being pushed. The chat buttons stay locked until it ends.
function Start-ChatPushJob {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][array]$Chats, $Profile, [int]$Skipped = 0)
    $job = Start-StorageJob -Script (Get-ChatPushJobScript) -Arguments @{ HarnessName = $Ctx.Harness.Name; Profile = $Profile; Chats = $Chats } -Total $Chats.Count
    $job.Progress['Current'] = [string]$Chats[0].Title
    $Ctx.Busy = $true; Update-ChatButtons -Ctx $Ctx
    $Ctx.Status.Text = Get-ChatPushProgressText -Progress $job.Progress
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $state = @{ Ctx = $Ctx; Job = $job; Timer = $timer; Skipped = $Skipped }
    $timer.Add_Tick({
        if (-not $state.Job.Progress['Finished']) { $state.Ctx.Status.Text = Get-ChatPushProgressText -Progress $state.Job.Progress; return }
        $state.Timer.Stop(); $state.Timer.Dispose()
        Complete-ChatPushJob -Ctx $state.Ctx -Job $state.Job -Skipped $state.Skipped
    }.GetNewClosure())
    $timer.Start()
}

# The end of a push: frees the runspace, unlocks the buttons, reads this profile and the catalog again, shows the result.
function Complete-ChatPushJob {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Job, [int]$Skipped = 0)
    $p = $Job.Progress
    Close-StorageScan -Scan $Job
    $Ctx.Busy = $false
    $res = $(if ($p['Error']) { @{ Kind = 'error'; Text = (Get-SyncErrorMessage -Message ([string]$p['Error'])) } }
             else { Get-ChatBatchResult -Verb 'Pushed' -Results @($p['Result']) -Skipped $Skipped -SkipReason 'their chat file is missing' })
    try { Update-ChatPanel -Ctx $Ctx -Load } catch { Write-HarnessLog "Push: reading the chats again failed: $($_.Exception.Message)" }
    (Get-MainState).DriveStale = $true
    Show-ChatPanelResult -Ctx $Ctx -Result $res
    return $res
}

function Invoke-ChatChooseFolder {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$View)
    $fix = Get-ChatFolderFix -Cwd ([string]$View.Chat.Cwd) -Roots (Get-SyncPathRoots)
    switch ($fix.Kind) {
        'root' {
            $path = Read-SyncFolder -Description "Where is the folder '$($fix.Name)' on this machine now? It used to be $($fix.OldPath)."
            if ($path) { Set-SyncPathRoot -Name $fix.Name -Path $path; Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = "The folder '$($fix.Name)' is now $path." }; Update-ChatPanel -Ctx $Ctx }
        }
        'open' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $fix.Path); Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = "Opened $($fix.Path). Create the missing folder there, or move the project back." } }
        default { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'warning'; Text = 'This chat has no working folder to fix.' } }
    }
}
