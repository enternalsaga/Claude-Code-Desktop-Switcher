$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent

# Settings, Drive and the machine are fakes; the guard is the real one of lane A1 with fake locks and running apps. Nothing real
# is read, written or started: the Codex app-server, the background jobs and the batches run on made-up sessions.
$script:Store = @{}
function Get-Setting { param($Name) return $script:Store[$Name] }
function Set-Setting { param($Name, $Value) $script:Store[$Name] = $Value }
function Write-HarnessLog { param($Message) $script:Logged += , $Message }
foreach ($f in 'Harness.Sync.Config', 'Storage.Scan', 'Storage.Inventory', 'Storage.Guard', 'Ui.ChatStatus', 'Ui.Main', 'Ui.MainChats', 'Ui.Storage', 'Ui.StorageActions') { . (Join-Path $root "src\$f.ps1") }

$MB = 1MB
$now = Get-Date
$ms = { param($days) [DateTimeOffset]::new($now.AddDays(-$days)).ToUnixTimeMilliseconds() }
function New-Sess($harness, $key, $title, $bytes, $days, $profiles, $flags = @{}) {
    $f = @{ IsCliOnly = $false; HasZst = $false; Trimmable = $true; ArchivedRef = $false; DbUnreadable = $false }
    foreach ($k in $flags.Keys) { $f[$k] = $flags[$k] }
    [pscustomobject]@{ Harness = $harness; Key = $key; Id = $key.Split(':')[1]; Title = $title; Cwd = 'D:\Work\x'; LastActivity = (& $ms $days); Created = $null
        Profiles = @($profiles | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }); Parts = @(); Bytes = [long]$bytes; State = $(if ($days -lt 0.01) { 'recent' } else { 'idle' }); Flags = $f }
}
$sC1 = New-Sess 'claude' 'claude:c1' 'Fix the login' (10 * $MB) 40 @('Default', 'Work2')
$sC2 = New-Sess 'claude' 'claude:c2' 'CLI chat' (5 * $MB) 0 @()
$sG1 = New-Sess 'antigravity' 'antigravity:g1.aabbccdd' 'Landing page' (3 * $MB) 5 @('Default') @{ Trimmable = $false }
$sX2 = New-Sess 'codex' 'codex:x2.11223344' 'Broken db chat' (2 * $MB) 60 @('P1') @{ DbUnreadable = $true }
$sX1 = New-Sess 'codex' 'codex:x1.11223344' 'Parser bug' (1 * $MB) 100 @('P1')
$sZ = New-Sess 'codex' 'codex:z.11223344' 'Zst rollout' (1 * $MB) 100 @('P1') @{ HasZst = $true; Trimmable = $false }
$inv = [pscustomobject]@{ Sessions = @($sC1, $sC2, $sG1, $sX2, $sX1, $sZ); Profiles = @(); Warnings = @(); ScannedAt = $now; Files = 1; Seconds = 1; Cancelled = $false }
$all = @(Get-StorageSessionRows -Inventory $inv -Now $now)
function Row($key) { $all | Where-Object { $_.Key -eq $key } }

# ---- U1-5: the selection label and which buttons are on ----------------------------------------------------------------------------------
Assert ((Get-StorageSelectionLabel -Rows @()) -eq 'Selected: 0 sessions') 'nothing selected'
Assert ((Get-StorageSelectionLabel -Rows @((Row 'claude:c1'))) -eq 'Selected: 1 session, 10 MB') 'one session'
Assert ((Get-StorageSelectionLabel -Rows @((Row 'claude:c1'), (Row 'codex:x1.11223344'), (Row 'antigravity:g1.aabbccdd'))) -eq 'Selected: 3 sessions, 14 MB') 'three sessions and their total size'
$off = @{ Archive = $false; Trim = $false; Summarize = $false; Delete = $false; Include = $false }
function Same($a, $b) { (($a.Keys | Sort-Object | ForEach-Object { "$_=$($a[$_])" }) -join ',') -eq (($b.Keys | Sort-Object | ForEach-Object { "$_=$($b[$_])" }) -join ',') }
Assert (Same (Get-StorageActionState -Rows @()) $off) 'U1-5: with no session ticked every button is off'
Assert (Same (Get-StorageActionState -Rows @((Row 'codex:x2.11223344'))) $off) 'U1-5: an unreadable session turns nothing on'
$st = Get-StorageActionState -Rows @((Row 'claude:c1'))
Assert ($st.Archive -and $st.Delete -and -not $st.Trim -and -not $st.Summarize -and -not $st.Include) 'an idle Claude session: Archive and Delete on; Trim and Summarize off while lane C1 is missing'
$st = Get-StorageActionState -Rows @((Row 'claude:c2'))
Assert (-not $st.Archive -and -not $st.Delete -and $st.Include) 'a recent session: nothing on, only Include anyway'
$st = Get-StorageActionState -Rows @((Row 'claude:c2'), (Row 'claude:c1'))
Assert ($st.Archive -and -not $st.Include) 'two ticked: Archive is on for the idle one, Include anyway is only for exactly one'
$inc = @(Get-StorageSessionRows -Inventory $inv -Include @{ 'claude:c2' = $true } -Now $now | Where-Object { $_.Key -eq 'claude:c2' })
Assert ((Get-StorageActionState -Rows $inc).Archive) 'after Include anyway the recent session can be archived'
$st = Get-StorageActionState -Rows @((Row 'antigravity:g1.aabbccdd'))
Assert (-not $st.Archive -and -not $st.Delete) 'U1-11: Antigravity Archive and Delete stay off until lane A1-6 lands'
function Test-StorageHarnessSupported { param($Harness, $Action) $true }
Assert ((Get-StorageActionState -Rows @((Row 'antigravity:g1.aabbccdd'))).Archive) '... and come on when Test-StorageHarnessSupported says yes'
Remove-Item function:Test-StorageHarnessSupported
Assert ((Get-StorageActionState -Rows @((Row 'antigravity:g1.aabbccdd'), (Row 'claude:c1'))).Archive) 'a mixed selection can still be archived (the Antigravity one is left out with a reason)'
function Invoke-StorageTrim { param($Sessions, $Target, $Mode) }
function Invoke-StorageSummarize { param($Sessions, $Target, [switch]$Confirmed) }
$st = Get-StorageActionState -Rows @((Row 'claude:c1'))
Assert ($st.Trim -and -not $st.Summarize) 'C1 present: Trim comes on; Summarize stays off until its gate (Test-StorageSummarizeReady) exists and is open'
$script:GateOpen = $false; function Test-StorageSummarizeReady { return $script:GateOpen }
Assert (-not (Get-StorageActionState -Rows @((Row 'claude:c1'))).Summarize) 'a closed gate keeps Summarize off'
$script:GateOpen = $true
$st = Get-StorageActionState -Rows @((Row 'claude:c1'))
Assert ($st.Trim -and $st.Summarize) 'an open gate turns Summarize on without a change to the window'
$st = Get-StorageActionState -Rows @((Row 'antigravity:g1.aabbccdd'))
Assert (-not $st.Trim -and $st.Summarize) 'Antigravity cannot be trimmed but can be summarized'
Assert (-not (Get-StorageActionState -Rows @((Row 'codex:z.11223344'))).Trim) 'a .zst rollout cannot be trimmed'
$jobTrim = Get-StorageJobScript -Action 'Trim'; $jobSum = Get-StorageJobScript -Action 'Summarize'
Assert ($jobTrim -like '*Invoke-StorageTrim*-Running $A.Running*-Progress $Progress -CancelToken $Cancel*' -and $jobSum -like '*Invoke-StorageSummarize*-Confirmed:$true*-Running $A.Running*-CancelToken $Cancel*') 'the Trim and Summarize jobs pass the running apps, the machine, Progress and Cancel'
Remove-Item Function:\Invoke-StorageTrim, Function:\Invoke-StorageSummarize, Function:\Test-StorageSummarizeReady

$a = Get-StorageArchivedActionState -Row ([pscustomobject]@{ Restored = $false; Source = 'local'; MachineId = 'm1' }) -ThisMachine 'm1'
Assert ($a.Restore -and $a.DeleteArchive -and -not $a.OpenSummary) 'archived view: Restore and Delete archive on a local row'
$a = Get-StorageArchivedActionState -Row ([pscustomobject]@{ Restored = $true; Source = 'drive'; MachineId = 'm2' }) -ThisMachine 'm1' -SummaryExists $true
Assert (-not $a.Restore -and -not $a.DeleteArchive -and $a.OpenSummary) 'U1-11: a restored row cannot be restored again; another machine archive cannot be deleted from here'
Assert (-not (Get-StorageArchivedActionState -Row $null).Restore) 'no archived row selected: all off'

# ---- the guard decides what a button may touch -----------------------------------------------------------------------------------------------
$rows2 = @((Row 'claude:c1'), (Row 'codex:x1.11223344'), (Row 'antigravity:g1.aabbccdd'), (Row 'claude:c2'))
$plan = Get-StorageActionPlan -Rows $rows2 -Action 'Archive' -Running @{ claude = @('Work2') } -LockProbe { param($p) $false }
Assert ((@($plan.Safe | ForEach-Object { $_.Key }) -join ',') -eq 'codex:x1.11223344') "only the Codex session is safe: $(@($plan.Safe | ForEach-Object { $_.Key }) -join ',')"
$why = @{}; foreach ($b in $plan.Blocked) { $why[$b.Key] = $b.Reason }
Assert ($why['claude:c1'] -like '*Close Work2*' -and $why['antigravity:g1.aabbccdd'] -like '*cannot be archived or deleted yet*' -and $why['claude:c2'] -like '*last 30 minutes*') "reasons: $($why.Values -join ' | ')"
$plan2 = Get-StorageActionPlan -Rows @((Row 'claude:c2')) -Action 'Archive' -Include @{ 'claude:c2' = $true } -LockProbe { param($p) $false }
Assert ($plan2.Safe.Count -eq 1) 'a recent session that was included anyway passes the guard'
$locked = $sC1.PSObject.Copy(); $locked.Parts = @([pscustomobject]@{ Kind = 'file'; Path = 'C:\fake\a.jsonl'; Bytes = 1; MTimeTicks = [long]0 })
$plan3 = Get-StorageActionPlan -Rows @([pscustomobject]@{ Key = 'claude:c1'; Title = 'Fix'; Session = $locked }) -Action 'Delete' -LockProbe { param($p) $true }
Assert ($plan3.Safe.Count -eq 0 -and $plan3.Blocked[0].Reason -like '*open in another program*') 'a locked session is left out'
$ids = Get-StorageRunningIds -Roots @{} -Source { @{ claude = @('A'); codex = @(); antigravity = @() } }
Assert ($ids.claude -contains 'A') 'running ids come from the source given'
# the folders of the running Claude CLIs ride in the same table, so every action (archive, delete, trim, summarize) sees them
function Get-StorageClaudeCliCwds { return @('D:\Work\alpha') }
Assert ((Get-StorageRunningIds -Roots @{ ClaudeProfiles = @() }).cli -contains 'D:\Work\alpha') 'Running.cli lists the folders of the running Claude CLIs'
function Get-StorageClaudeCliCwds { throw 'wmi down' }
Assert ((Get-StorageRunningIds -Roots @{ ClaudeProfiles = @() }).cli -contains '*') 'when the CLIs cannot be listed the token * blocks every Claude session'
Remove-Item Function:\Get-StorageClaudeCliCwds
$planCli = Get-StorageActionPlan -Rows @((Row 'claude:c1'), (Row 'codex:x1.11223344')) -Action 'Delete' -Running @{ cli = @('*') }
Assert (@($planCli.Blocked | Where-Object { $_.Key -eq 'claude:c1' -and $_.Reason -like 'A Claude CLI is running*' }).Count -eq 1 -and @($planCli.Safe | Where-Object { $_.Key -eq 'codex:x1.11223344' }).Count -eq 1) 'an unreadable CLI folder blocks the Claude session of the plan, not the Codex one'
foreach ($act in 'Archive', 'Delete', 'Trim') { Assert ((Get-StorageJobScript -Action $act) -like '*-Running $A.Running*') "the $act job passes the running table (with the CLI folders) to the guard" }

# ---- U1-6: what every confirmation says ----------------------------------------------------------------------------------------------------------
$sel = @((Row 'claude:c1'), (Row 'codex:x1.11223344'))
$c = Get-StorageConfirmContent -Action 'Archive' -Rows $sel -TargetText 'D:\HarnessArchive'
Assert ($c.Text -like '*2 sessions (11 MB)*' -and $c.Text -like '*D:\HarnessArchive*' -and $c.Text -like '*Default, P1, Work2*' -and $c.Text -like '*bring it back*Archived view*' -and $c.DefaultButton -eq 'Cancel' -and $c.Ok -eq 'Archive') 'Archive: count, size, store, profiles, how to undo; Cancel is the default'
$c = Get-StorageConfirmContent -Action 'Delete' -Rows $sel -Blocked @([pscustomobject]@{ Title = 'Busy one'; Reason = 'Used in the last 30 minutes.' })
Assert ($c.Text -like '*2 sessions (11 MB)*' -and $c.Text -like '*Recoverable from the Recycle Bin until it is emptied*' -and $c.Text -like '*Default, P1, Work2*' -and $c.Text -like '*Left out:*Busy one: Used in the last 30 minutes.*' -and $c.DefaultButton -eq 'Cancel') 'Delete: sessions, size, profiles, the Recycle Bin sentence, what is left out'
$cliWarn = '*Close any Claude Code terminal still working in these folders first; it cannot be detected.*'
Assert ((Get-StorageConfirmContent -Action 'Archive' -Rows $sel -TargetText 'x').Text -like $cliWarn -and $c.Text -like $cliWarn) 'Archive and Delete with a Claude session warn about open Claude Code terminals'
Assert ((Get-StorageConfirmContent -Action 'Delete' -Rows @((Row 'codex:x1.11223344'))).Text -notlike $cliWarn) 'a Codex-only batch has no such warning'
. (Import-TestFunctions -Files @((Join-Path $root 'src\Storage.Harness.ps1')) -Names @('Get-StorageHarnessRemovalNotice'))
$agyBatch = @((Row 'claude:c1'), (Row 'antigravity:g1.aabbccdd'))
Assert ((Get-StorageConfirmContent -Action 'Archive' -Rows $agyBatch -TargetText 'x').Text -like '*Conversation unavailable*' -and (Get-StorageConfirmContent -Action 'Delete' -Rows $agyBatch).Text -like '*Conversation unavailable*') 'S17: Archive and Delete with an Antigravity session say the conversation stays listed as unavailable'
Assert ((Get-StorageConfirmContent -Action 'Archive' -Rows $sel -TargetText 'x').Text -notlike '*Conversation unavailable*' -and (Get-StorageConfirmContent -Action 'Delete' -Rows $sel).Text -notlike '*Conversation unavailable*') 'a Claude and Codex batch has no such sentence'
Assert ((Get-StorageConfirmContent -Action 'Restore' -Rows $agyBatch).Text -notlike '*Conversation unavailable*') 'Restore does not say it'
$plan = @(@{ Key = 'claude:c1'; Tool = 'claude'; InputChars = 40000; EstTokens = 10000 }, @{ Key = 'codex:x1.11223344'; Tool = 'codex'; InputChars = 8000; EstTokens = 2000 })
$c = Get-StorageConfirmContent -Action 'Summarize' -Rows $sel -Plan $plan
Assert ($c.Text -like '*claude, codex*' -and $c.Text -like '*12,000 input tokens*' -and $c.Text -like '*sends the redacted transcript to Anthropic, OpenAI using your claude, codex sign-in and uses tokens*' -and $c.DefaultButton -eq 'Cancel' -and $c.Ok -eq 'Summarize') "Summarize: tool, tokens and the cost sentence: $($c.Text)"
$c = Get-StorageConfirmContent -Action 'Trim' -Rows $sel -Mode 'ReadOnlyCopy'
Assert ($c.Text -like '*full archive is made first*' -and $c.Text -like '*ReadOnlyCopy*') 'Trim says an archive comes first and the mode'
$c = Get-StorageConfirmContent -Action 'DeleteArchive' -Rows @([pscustomobject]@{ Bytes = 4MB; Title = 'x' })
Assert ($c.Text -like '*cannot be undone*' -and $c.Text -like '*not sent to the Recycle Bin*') 'Delete archive says it is for good'
$c = Get-StorageConfirmContent -Action 'Restore' -Rows @([pscustomobject]@{ Bytes = 4MB; Title = 'x' })
Assert ($c.Text -like '*.bak*' -and $c.Text -like '*Close the apps*') 'Restore warns about .bak copies and running apps'
$def = (Get-Command Show-StorageConfirm).Definition
Assert ($def -match "'OKCancel'" -and $def -match "'Button2'") 'the box has OK and Cancel and Cancel (the second button) is the default'

# ---- U1-8: where archives go --------------------------------------------------------------------------------------------------------------------------
Assert ($null -eq (Get-StorageTargetSetting) -and (Get-StorageTargetText) -eq 'not chosen yet' -and $null -eq (Resolve-StorageTarget)) 'no target chosen: unset'
$ch = @(Get-StorageTargetChoices -SyncReady $false -UserProfile 'C:\Users\someone')
Assert ($ch.Count -eq 1 -and $ch[0].Kind -eq 'local' -and $ch[0].Path -eq 'C:\Users\someone\HarnessArchive') 'the first archive suggests a folder under the user profile'
$ch = @(Get-StorageTargetChoices -SyncReady $true -UserProfile 'C:\Users\someone')
Assert ($ch.Count -eq 2 -and $ch[1].Kind -eq 'drive') 'Drive is offered once sync is set up'
Assert-Throws { Set-StorageTargetSetting -Kind 'local' -Path 'relative\folder' } 'a folder that is not a full path is refused'
Set-StorageTargetSetting -Kind 'local' -Path 'D:\HarnessArchive\'
Assert ((Get-StorageTargetText) -eq 'D:\HarnessArchive' -and (Resolve-StorageTarget).Kind -eq 'local' -and (Resolve-StorageTarget).Path -eq 'D:\HarnessArchive') 'a local target is stored and resolved'
$script:Store['Storage.ArchiveTarget'] = [pscustomobject]@{ kind = 'local'; path = 'nonsense' }
Assert ($null -eq (Get-StorageTargetSetting)) 'a damaged stored target is unset'
Set-StorageTargetSetting -Kind 'drive'
function Get-SyncSession { [pscustomobject]@{ Root = 'X:\HarnessSync-test'; Key = [byte[]](1..64) } }
function Get-SyncMachine { [pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'PC' } }
$t = Resolve-StorageTarget
Assert ((Get-StorageTargetText) -like 'Google Drive*' -and $t.Kind -eq 'drive' -and $t.SyncRoot -eq 'X:\HarnessSync-test' -and $t.MachineId -eq 'aaaaaaaa-0000-4000-8000-000000000001' -and $t.Key.Length -eq 64) 'a Drive target carries the sync folder, the machine and the key'

# ---- U1-10: the Codex app-server wrapper ---------------------------------------------------------------------------------------------------------------
$script:Started = New-Object Collections.ArrayList; $script:Calls = New-Object Collections.ArrayList; $script:Stopped = New-Object Collections.ArrayList
$start = { param($h) [void]$script:Started.Add($h); [pscustomobject]@{ Home = $h } }
$call = { param($srv, $m, $p, $notify) [void]$script:Calls.Add(('{0}|{1}{2}' -f $srv.Home, $m, $(if ($notify) { '!' } else { '' }))); if ($m -eq 'thread/boom') { throw 'rpc error' }; return @{ ok = $true } }
$stop = { param($srv) [void]$script:Stopped.Add($srv.Home) }
$rpc = New-StorageCodexRpc -Start $start -Call $call -Stop $stop
[void](& $rpc 'C:\h\one' 'thread/read' @{ threadId = 'a' }); [void](& $rpc 'C:\h\one' 'thread/archive' @{ threadId = 'b' })
Assert ($script:Started.Count -eq 1) 'one app-server per CodexHome, reused in the batch'
Assert (($script:Calls -join ',') -eq 'C:\h\one|initialize,C:\h\one|initialized!,C:\h\one|thread/read,C:\h\one|thread/archive') "initialize, initialized, then the calls: $($script:Calls -join ',')"
[void](& $rpc 'C:\H\ONE' 'thread/read' @{}); [void](& $rpc 'C:\h\two' 'thread/read' @{})
Assert ($script:Started.Count -eq 2) 'the same home in another case is the same server; another home starts another'
$r = & $rpc 'C:\h\two' 'thread/read' @{}
Assert ($r.ok) 'the result of the call is returned'
$threw = $false; try { [void](& $rpc 'C:\h\two' 'thread/boom' @{}) } catch { $threw = $_.Exception.Message -like '*rpc error*' }
Assert $threw 'an RPC error throws, it is not an empty result'
Close-StorageCodexRpc -Rpc $rpc
Assert ($script:Stopped.Count -eq 2) 'Close stops every server it started'
Close-StorageCodexRpc -Rpc $rpc
Assert ($script:Stopped.Count -eq 2) 'closing twice stops nothing twice'
# a batch that dies in the middle still closes (the way the job script uses it)
$script:Stopped.Clear(); $script:Started.Clear()
$rpc2 = New-StorageCodexRpc -Start $start -Call $call -Stop $stop
try { try { [void](& $rpc2 'C:\h\three' 'thread/read' @{}); [void](& $rpc2 'C:\h\three' 'thread/boom' @{}) } finally { Close-StorageCodexRpc -Rpc $rpc2 } } catch { }
Assert ($script:Stopped.Count -eq 1) 'Close in a finally stops the server even when the batch failed'
# a server that cannot start or cannot handshake is not left running
$script:Stopped.Clear()
$badCall = { param($srv, $m, $p, $notify) throw 'handshake failed' }
$rpc3 = New-StorageCodexRpc -Start $start -Call $badCall -Stop $stop
$threw = $false; try { [void](& $rpc3 'C:\h\four' 'thread/read' @{}) } catch { $threw = $true }
Assert ($threw -and $script:Stopped.Count -eq 1) 'a failed handshake stops the server it just started and throws'
Assert ((Get-Command New-StorageCodexRpc).Definition -match 'Start-CodexAppServer' -and (Get-Command New-StorageCodexRpc).Definition -match 'Invoke-CodexRpc' -and (Get-Command New-StorageCodexRpc).Definition -match 'Stop-CodexAppServer') 'the defaults reuse the client of phase 2'

# ---- the background runner ------------------------------------------------------------------------------------------------------------------------------
function Get-TestJobValue { return ('value-' + $script:StorageTestValue) }
$script:StorageTestValue = 42
$job = Start-StorageJob -Script 'param($A, $Progress, $Cancel) 1..3 | ForEach-Object { $Progress.Done = $_ }; (Get-TestJobValue) + "/" + $A.x' -Arguments @{ x = 'arg' } -Total 3
$sw = [Diagnostics.Stopwatch]::StartNew(); while (-not $job.Progress['Finished'] -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 50 }
Assert ($job.Progress['Finished'] -and -not $job.Progress['Error'] -and $job.Progress['Done'] -eq 3 -and $job.Progress['Total'] -eq 3) "the job ran: error=$($job.Progress['Error'])"
Assert ($job.Progress['Result'] -eq 'value-42/arg') "the job has the program functions and the script variables: $($job.Progress['Result'])"
Close-StorageScan -Scan $job
$job = Start-StorageJob -Script 'param($A, $Progress, $Cancel) throw "job went wrong"'
$sw.Restart(); while (-not $job.Progress['Finished'] -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 50 }
Assert ($job.Progress['Error'] -like '*job went wrong*' -and $job.Progress['Finished']) 'an error in the job ends in Progress.Error and is not thrown'
Close-StorageScan -Scan $job
$job = Start-StorageJob -Script 'param($A, $Progress, $Cancel) while (-not $Cancel["Cancel"]) { Start-Sleep -Milliseconds 20 }; "stopped"'
$t0 = Get-Date; Stop-StorageScan -Scan $job
Assert ($job.Progress['Finished'] -and $job.Progress['Cancelled'] -and ((Get-Date) - $t0).TotalSeconds -lt 3) 'Stop ends a running job within a few seconds'
Close-StorageScan -Scan $job
foreach ($act in 'Archive', 'Delete', 'Restore', 'Trim', 'Summarize') {
    $txt = Get-StorageJobScript -Action $act; $e = $null
    [void][Management.Automation.Language.Parser]::ParseInput($txt, [ref]$null, [ref]$e)
    Assert (-not $e.Count) "the $act job script parses"
    Assert ($txt -match 'Close-StorageCodexRpc' -and $txt -match 'New-StorageCodexRpc') "the $act job script starts and always closes the Codex wrapper"
}
Assert ((Get-StorageJobScript -Action 'Archive') -match 'Invoke-StorageArchive' -and (Get-StorageJobScript -Action 'Delete') -match 'Invoke-StorageDeleteBatch' -and (Get-StorageJobScript -Action 'Restore') -match 'Invoke-StorageRestore') 'each job calls the function of its action'

# ---- delete in a batch -----------------------------------------------------------------------------------------------------------------------------------------
$script:Removed = New-Object Collections.ArrayList
function Remove-StorageSessionOriginal { param($Session, $Mode, $Roots, [scriptblock]$CodexRpc, [scriptblock]$Recycler, [scriptblock]$VolumeInfo)
    if ($Session.Key -eq 'codex:x1.11223344') { throw 'recycle-refused: no Recycle Bin on that drive' }
    [void]$script:Removed.Add($Session.Key + '|' + $Mode)
    if ($script:CancelAfter -and $script:Removed.Count -ge $script:CancelAfter) { $script:CancelTok['Cancel'] = $true }
    return @{ Removed = @('p'); Skipped = @() } }
$prog = [hashtable]::Synchronized(@{ Done = 0 }); $cancel = [hashtable]::Synchronized(@{ Cancel = $false })
$res = @(Invoke-StorageDeleteBatch -Sessions @($sC1, $sC2, $sX1, $sZ) -Roots @{} -Progress $prog -CancelToken $cancel -LockProbe { param($p) $false })
Assert ($res.Count -eq 4 -and $res[0].Ok -and $res[1].Skipped -and $res[1].Reason -like '*last 30 minutes*' -and -not $res[2].Ok -and $res[2].Reason -like '*no Recycle Bin*' -and $res[3].Ok) 'a recent session is skipped, a failing one fails, and neither stops the rest'
Assert (($script:Removed -join ',') -eq 'claude:c1|Recycle,codex:z.11223344|Recycle' -and $prog['Done'] -eq 4) 'what was removed went with Mode Recycle; progress counted every session'
$script:Removed.Clear(); $prog['Done'] = 0; $script:CancelTok = $cancel; $script:CancelAfter = 1
$res = @(Invoke-StorageDeleteBatch -Sessions @($sC1, $sZ, $sX1) -Roots @{} -Progress $prog -CancelToken $cancel -LockProbe { param($p) $false })
Assert ($res.Count -eq 1 -and $res[0].Ok -and $prog['Done'] -eq 1) "Cancel stops before the next session, never in the middle of one: $($res.Count) result(s)"
Remove-Item Function:\Remove-StorageSessionOriginal

# ---- results ------------------------------------------------------------------------------------------------------------------------------------------------------
$rr = @(Get-StorageResultRows -Results @(@{ Key = 'claude:c1'; Ok = $true; Skipped = $false; Reason = ''; Warnings = @('Not removed: x') }, @{ Key = 'claude:c2'; Ok = $false; Skipped = $true; Reason = 'recent' }, @{ Key = 'codex:q'; Ok = $false; Skipped = $false; Reason = 'broke' }) -Rows @((Row 'claude:c1'), (Row 'claude:c2')))
Assert ($rr[0].Status -eq 'Done' -and $rr[0].Title -eq 'Fix the login' -and $rr[0].Reason -eq 'Not removed: x' -and $rr[1].Status -eq 'Skipped' -and $rr[1].Reason -eq 'recent' -and $rr[2].Status -eq 'Failed' -and $rr[2].Title -eq 'codex:q') 'result rows: done, skipped with the reason, failed; a key with no row shows the key'
$inv2 = Remove-StorageInventorySessions -Inventory $inv -Keys @('claude:c1', 'codex:x1.11223344')
Assert (@($inv2.Sessions).Count -eq 4 -and @($inv.Sessions).Count -eq 6 -and $inv2.Files -eq 1) 'archived or deleted sessions leave a copy of the inventory; the scan result itself is untouched'

Write-Output 'PASS: Ui.StorageActions - action state, guard plan, confirmations, targets, Codex wrapper, background job, delete batch, results.'
