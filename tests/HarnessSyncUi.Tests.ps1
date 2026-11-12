$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Import-TestFunctions -Files @((Join-Path $root 'ClaudeSwitcher.ps1')) -Names @('Get-Setting', 'Set-Setting'))
. (Join-Path $root 'src\Harness.Core.ps1')
. (Join-Path $root 'src\Harness.Sync.Crypto.ps1')
. (Join-Path $root 'src\Harness.Sync.Config.ps1')
. (Join-Path $root 'src\Harness.Sync.Store.ps1')
. (Join-Path $root 'src\Ui.Tray.ps1')
. (Join-Path $root 'src\Ui.Harness.ps1')
. (Join-Path $root 'src\Ui.Sync.ps1')
. (Join-Path $root 'src\Ui.SyncWizard.ps1')

# No window is opened and nothing real is touched: the "Drive" is a temp folder, settings and switcher home are temp,
# the adapters are fakes, the passphrase is made up and key derivation is lowered to 1000 rounds.
$tmp = New-TestTempDir
$savedName = $env:COMPUTERNAME
try {
    $script:ProfileRoot = Join-Path $tmp 'profile'
    $script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
    $script:SwitcherHome = Join-Path $tmp 'profile\.switcher'
    $script:SyncRetryDelayMs = 5
    $pass = 'test-only fake passphrase'
    $idA = 'aaaaaaaa-0000-4000-8000-000000000001'
    $idB = 'bbbbbbbb-0000-4000-8000-000000000002'
    function Use-Machine($id, $name) { Set-Setting 'Sync.MachineId' $id; $env:COMPUTERNAME = $name }

    # fake adapters: 'fakea' (Claude-like, native import between its own profiles) and 'fakeb' (handoff only)
    Reset-HarnessRegistry
    $script:imports = New-Object Collections.ArrayList
    $script:chatsOf = @{}
    function New-FakeBundle($Chat, $OutPath) {
        $src = @{ harness = $Chat.Harness; chatId = $Chat.ChatId; title = $Chat.Title; lastActivityAt = $Chat.Activity; cwd = @{ absolute = 'C:\work\p'; root = $null; relative = $null } }
        return New-HarnessBundle -OutPath $OutPath -Source $src -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = ('# ' + $Chat.Title) })
    }
    $script:nativeResult = 'copied'
    $common = @{
        Detect = { [pscustomobject]@{ Installed = $true } }
        GetProfiles = { @() }
        Launch = { param($p) 'started' }
        ListChats = { param($p) @($script:chatsOf[$p.Id]) }
        Export = { param($Chat, $OutPath) New-FakeBundle -Chat $Chat -OutPath $OutPath }
        ImportHandoff = { param($BundlePath, $Profile) [void]$script:imports.Add(@('handoff', $Profile.Id)); [pscustomobject]@{ Path = 'handoff.md'; Prompt = 'prompt' } }
    }
    $adA = @{} + $common
    $adA['ImportNative'] = { param($BundlePath, $Profile) [void]$script:imports.Add(@('native', $Profile.Id)); $script:nativeResult }
    $adA['ImportNeedsClose'] = { param($Profile) [bool]$Profile.Busy }
    Register-Harness -Name 'fakea' -Adapter $adA
    Register-Harness -Name 'fakeb' -Adapter $common.Clone()

    $profA1 = [pscustomobject]@{ Harness = 'fakea'; Id = 'a1'; Name = 'A one'; Pid = $null }
    $profA2 = [pscustomobject]@{ Harness = 'fakea'; Id = 'a2'; Name = 'A two'; Pid = $null }
    $profB1 = [pscustomobject]@{ Harness = 'fakeb'; Id = 'b1'; Name = 'B one'; Pid = $null }
    $chat1 = [pscustomobject]@{ Harness = 'fakea'; ChatId = 'chat-1'; Title = 'First chat'; Activity = 1700000000000 }

    # ---------------------------------------------------------------- U1: the transfer is two steps
    $bdir = Join-Path $tmp 'bundles'
    $exp = Export-HarnessChatBundle -Chat $chat1 -SourceHarness 'fakea' -BundleDir $bdir
    Assert ((Test-Path -LiteralPath $exp.Bundle) -and $exp.Manifest.chatKey -eq 'fakea:chat-1') 'Export-HarnessChatBundle writes a bundle and returns its manifest'
    $r = Invoke-HarnessImport -BundlePath $exp.Bundle -Manifest $exp.Manifest -Target $profA2
    Assert ($r.Mode -eq 'native' -and $r.Status -eq 'copied' -and $r.Bundle -eq $exp.Bundle) "native import: $($r | ConvertTo-Json -Compress)"
    $r = Invoke-HarnessImport -BundlePath $exp.Bundle -Manifest $exp.Manifest -Target $profB1
    Assert ($r.Mode -eq 'handoff' -and $r.Status -eq 'handoff' -and $r.Path -eq 'handoff.md') 'a harness without ImportNative gets a handoff'
    $profBusy = [pscustomobject]@{ Harness = 'fakea'; Id = 'a3'; Name = 'busy'; Pid = $null; Busy = $true }
    $r = Invoke-HarnessImport -BundlePath $exp.Bundle -Manifest $exp.Manifest -Target $profBusy
    Assert ($r.Status -eq 'close-first') 'close-first is reported by the import step too'
    $r = Invoke-HarnessTransfer -Chat $chat1 -SourceHarness 'fakea' -Target $profA2 -BundleDir $bdir
    Assert ($r.Mode -eq 'native' -and $r.Status -eq 'copied' -and (Test-Path -LiteralPath $r.Bundle)) 'Invoke-HarnessTransfer still does both steps'

    # ---------------------------------------------------------------- U2 / U3: push and pull against a fake Drive
    $drive = Join-Path $tmp 'drive\HarnessSync-test'
    New-Item -ItemType Directory -Path $drive -Force | Out-Null
    $handoffDir = Join-Path $tmp 'handoff'
    $adA['ImportHandoff'] = { param($BundlePath, $Profile) [void]$script:imports.Add(@('handoff', $Profile.Id)); $f = Export-HarnessHandoffFiles -BundlePath $BundlePath -HandoffDir $handoffDir -Target 'fakea'; [pscustomobject]@{ Path = $f.Path; Prompt = $f.Prompt } }
    Register-Harness -Name 'fakea' -Adapter $adA
    function Use-Machine($id, $name) {
        Set-Setting 'Sync.MachineId' $id; $env:COMPUTERNAME = $name
        $script:SwitcherHome = Join-Path $tmp ('home-' + $name)
        New-Item -ItemType Directory -Path $script:SwitcherHome -Force | Out-Null
    }
    function Save-FakeKey { $kdf = Initialize-SyncFolder -Root $drive -Passphrase $pass -Iterations 1000 -MinIterations 1000; Save-SyncKeyCache -Key (Get-SyncKey -Passphrase $pass -Kdf $kdf) -Kdf $kdf }
    function Get-TempSyncDirs { @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'harness-sync-*' -ErrorAction SilentlyContinue).Count }

    Use-Machine $idA 'PCA'
    Set-SyncSetting 'CustomPath' $drive
    $msg = $null; try { Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 -BundleDir (Join-Path $tmp 'pushb') } catch { $msg = $_.Exception.Message }
    Assert ($msg -like '*sync-not-set-up*') "no sync.json yet: $msg"
    [void](Initialize-SyncFolder -Root $drive -Passphrase $pass -Iterations 1000 -MinIterations 1000)
    $msg = $null; try { Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 -BundleDir (Join-Path $tmp 'pushb') } catch { $msg = $_.Exception.Message }
    Assert ($msg -like '*sync-key-missing*') "no key in the cache: $msg"
    Save-FakeKey
    $row1 = Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 -BundleDir (Join-Path $tmp 'pushb')
    Assert ($row1.chatKey -eq 'fakea:chat-1' -and @(Get-ChildItem -LiteralPath (Join-Path $drive 'bundles') -Recurse -File -Filter '*.enc').Count -eq 1) 'one encrypted bundle on the fake Drive'
    $indexText = [IO.File]::ReadAllText((Join-Path $drive "index\$idA.jsonl"))
    Assert ($indexText.Split("`n", [StringSplitOptions]::RemoveEmptyEntries).Count -eq 1 -and -not $indexText.Contains('First chat')) 'one index row, no plain title'
    Assert (-not @(Get-ChildItem -LiteralPath (Join-Path $tmp 'pushb') -Filter '*.zip' -ErrorAction SilentlyContinue).Count) 'the plain local bundle is removed after the push'
    foreach ($i in 1..4) { Start-Sleep -Milliseconds 1100; [void](Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 -BundleDir (Join-Path $tmp 'pushb')) }
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $drive 'bundles') -Recurse -File -Filter '*.enc').Count -eq 3) 'push keeps the 3 newest bundles of the chat'

    # machine B pulls
    Use-Machine $idB 'PCB'
    Save-FakeKey
    $key = Get-SyncKeyCache -Kdf (Read-SyncJsonFile (Join-Path $drive 'sync.json')).kdf
    $row = @(Get-SyncCatalog -Root $drive -Key $key)[0]
    $tempBefore = Get-TempSyncDirs
    $script:imports.Clear()
    $res = Invoke-SyncPull -Row $row -Target $profA2
    Assert ($res.Divergence -eq 'new' -and $res.Status -eq 'copied' -and $script:imports[0][0] -eq 'native') "new chat is imported natively: $($res | ConvertTo-Json -Compress)"
    Assert ((Get-SyncState)['fakea:chat-1'].lastBundleId -eq $row.bundleId) 'state remembers the pulled bundle'
    Assert ((Get-TempSyncDirs) -eq $tempBefore) 'the decrypted temp bundle is removed'
    $script:imports.Clear()
    $script:chatsOf['a2'] = @([pscustomobject]@{ ChatId = 'chat-1'; Activity = $row.lastActivityAt })
    $res = Invoke-SyncPull -Row $row -Target $profA2
    Assert ($res.Divergence -eq 'same' -and $res.Status -eq 'same' -and $script:imports.Count -eq 0) 'the same bundle again changes nothing'

    # a newer version from A; B's local chat has not moved since the last sync -> update
    Use-Machine $idA 'PCA'
    $chat1.Activity = 1800000000000
    $rowNew = Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 -BundleDir (Join-Path $tmp 'pushb')
    Use-Machine $idB 'PCB'
    $row2 = @(Get-SyncCatalog -Root $drive -Key $key)[0]
    Assert ($row2.bundleId -eq $rowNew.bundleId) 'the catalog shows the newest version'
    $script:imports.Clear()
    $res = Invoke-SyncPull -Row $row2 -Target $profA2
    Assert ($res.Divergence -eq 'update' -and $res.Status -eq 'copied' -and $script:imports[0][0] -eq 'native') "unchanged local chat is updated in place: $($res | ConvertTo-Json -Compress)"

    # B continued the chat meanwhile, A pushes again -> diverged: a handoff whose title says where it came from
    $script:chatsOf['a2'] = @([pscustomobject]@{ ChatId = 'chat-1'; Activity = ($row2.lastActivityAt + 5000) })
    Use-Machine $idA 'PCA'
    $chat1.Activity = 1900000000000
    [void](Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 -BundleDir (Join-Path $tmp 'pushb'))
    Use-Machine $idB 'PCB'
    $row3 = @(Get-SyncCatalog -Root $drive -Key $key)[0]
    $script:imports.Clear()
    $stateBefore = (Get-SyncState)['fakea:chat-1'].lastBundleId
    $res = Invoke-SyncPull -Row $row3 -Target $profA2
    Assert ($res.Divergence -eq 'diverged' -and $res.Status -eq 'handoff' -and $script:imports[0][0] -eq 'handoff') "diverged chat becomes a handoff: $($res | ConvertTo-Json -Compress)"
    Assert ($res.Prompt.Contains('First chat (from PCA)')) "the title carries the machine name: $($res.Prompt)"
    Assert ((Get-SyncState)['fakea:chat-1'].lastBundleId -eq $stateBefore) 'a handoff does not move the sync state'
    Assert (-not $script:HandoffTitleSuffix) 'the title suffix does not leak into later handoffs'

    # V3a: the user picks what happens to a diverged chat
    Assert ((Resolve-SyncDivergedChoice 'handoff') -eq 'handoff' -and (Resolve-SyncDivergedChoice 'theirs') -eq 'handoff' -and (Resolve-SyncDivergedChoice 'push') -eq 'push' -and (Resolve-SyncDivergedChoice 'mine') -eq 'push' -and (Resolve-SyncDivergedChoice 'cancel') -eq 'cancel') 'choice mapping'
    Assert ((Resolve-SyncDivergedChoice $null) -eq 'cancel' -and (Resolve-SyncDivergedChoice 'whatever') -eq 'cancel') 'anything unknown cancels'
    $localChat = [pscustomobject]@{ Harness = 'fakea'; ChatId = 'chat-1'; Title = 'Local copy'; Activity = ($row2.lastActivityAt + 5000) }
    $script:chatsOf['a2'] = @($localChat)
    $tempBefore = Get-TempSyncDirs
    $idxB = Join-Path $drive "index\$idB.jsonl"
    function Get-IdxCount { if (Test-Path -LiteralPath $idxB) { @([IO.File]::ReadAllLines($idxB)).Count } else { 0 } }
    $rowsBefore = (Get-IdxCount)
    $script:imports.Clear(); $script:asked = $null
    $res = Invoke-SyncPull -Row $row3 -Target $profA2 -OnDiverged { param($r, $c) $script:asked = @($r.bundleId, $c.ChatId); 'cancel' }
    Assert ($res.Status -eq 'cancelled' -and $res.Divergence -eq 'diverged' -and $script:imports.Count -eq 0) "cancel does nothing: $($res | ConvertTo-Json -Compress)"
    Assert ($script:asked[0] -eq $row3.bundleId -and $script:asked[1] -eq 'chat-1') 'the callback gets the row and the local chat'
    Assert ((Get-SyncState)['fakea:chat-1'].lastBundleId -eq $stateBefore -and (Get-IdxCount) -eq $rowsBefore -and (Get-TempSyncDirs) -eq $tempBefore) 'cancel changes nothing and leaves no temp file'
    $res = Invoke-SyncPull -Row $row3 -Target $profA2 -OnDiverged { 'handoff' }
    Assert ($res.Status -eq 'handoff' -and $script:imports[0][0] -eq 'handoff') 'handoff through the callback behaves like the default'
    $script:imports.Clear()
    $stateSnap = Get-SyncState
    $res = Invoke-SyncPull -Row $row3 -Target $profA2 -OnDiverged { 'push' }
    Assert ($res.Status -eq 'pushed-mine' -and $res.Divergence -eq 'diverged' -and $script:imports.Count -eq 0) "push mine: $($res | ConvertTo-Json -Compress)"
    Assert ((Get-IdxCount) -eq $rowsBefore + 1) 'this machine pushed its own copy as a new row'
    Assert ((Get-SyncState)['fakea:chat-1'].lastBundleId -ne $stateBefore -and (Get-TempSyncDirs) -eq $tempBefore) 'the state follows the push and no temp file is left'
    # the pushed row replaces A's version in the catalog even though its activity is older (lineage), so B is in sync with
    # it and A sees it as an ordinary newer version instead of never hearing about B's copy
    $head = @(Get-SyncCatalog -Root $drive -Key $key | Where-Object { $_.chatKey -eq 'fakea:chat-1' })
    Assert ($head.Count -eq 1 -and $head[0].previousBundleId -eq $row3.bundleId -and $head[0].machineId -eq $idB) "push mine heads the catalog: $($head | ConvertTo-Json -Compress)"
    Assert ((Get-SyncDivergence -Row $head[0] -LocalChat $localChat) -eq 'same') 'on the machine that pushed mine the chat is in sync'
    $stateAfterPush = Get-SyncState
    $stateA = Get-SyncState; $stateA['fakea:chat-1'] = @{ lastBundleId = $row3.bundleId; localChatId = 'chat-1'; harness = 'fakea'; profileId = 'a1'; localActivityAtSync = 1900000000000 }
    Set-SyncState -State $stateA
    Assert ((Get-SyncDivergence -Row $head[0] -LocalChat ([pscustomobject]@{ Harness = 'fakea'; ChatId = 'chat-1'; Activity = 1900000000000 })) -eq 'update') 'the other machine, unchanged since it pushed, is offered B''s copy as an update'
    Set-SyncState -State $stateAfterPush
    Set-SyncState -State $stateSnap   # back to the diverged situation, to test a callback that fails
    Assert ((Get-SyncState)['fakea:chat-1'].lastBundleId -eq $stateBefore) 'state restored for the next case'
    $script:imports.Clear(); $res = $null
    try { $res = Invoke-SyncPull -Row $row3 -Target $profA2 -OnDiverged { throw 'the callback failed' } } catch { }
    Assert ($null -eq $res -and $script:imports.Count -eq 0) 'a failing callback never imports'
    Assert ((Get-TempSyncDirs) -eq $tempBefore) 'and leaves no temp file'
    # the same choice through the dialog's action, with a fake window
    $script:imports.Clear()
    $act = Invoke-HarnessDialogAction -Source @{ Kind = 'drive' } -TargetEntry ([pscustomobject]@{ Kind = 'profile'; Profile = $profA2 }) -Item $row3 -OnDiverged { 'cancel' }
    Assert ($act.Kind -eq 'message' -and $act.Text -eq 'Nothing was changed.' -and $script:imports.Count -eq 0) "cancel through Invoke-HarnessDialogAction: $($act | ConvertTo-Json -Compress)"
    $act = Invoke-HarnessDialogAction -Source @{ Kind = 'drive' } -TargetEntry ([pscustomobject]@{ Kind = 'profile'; Profile = $profA2 }) -Item $row3 -OnDiverged { 'handoff' }
    Assert ($act.Kind -eq 'message' -and $script:imports.Count -eq 1 -and $script:imports[0][0] -eq 'handoff') 'handoff through Invoke-HarnessDialogAction'

    # a root the user has not set yet: nothing is recorded, the temp file is gone
    $script:chatsOf['a2'] = @()
    $script:nativeResult = @{ Status = 'needs-root'; Root = 'Proj' }
    $tempBefore = Get-TempSyncDirs
    $res = Invoke-SyncPull -Row $row3 -Target $profA1
    Assert ($res.Status -eq 'needs-root' -and $res.Root -eq 'Proj') 'needs-root is handed back to the UI'
    Assert ((Get-SyncState)['fakea:chat-1'].lastBundleId -eq $stateBefore -and (Get-TempSyncDirs) -eq $tempBefore) 'needs-root records nothing and leaves no temp file'
    $script:nativeResult = @{ Status = 'copied'; CwdMissing = $true; Cwd = 'D:\x' }
    $res = Invoke-SyncPull -Row $row3 -Target $profA1
    Assert ($res.Status -eq 'copied' -and $res.CwdMissing -eq $true) 'CwdMissing is passed on'
    $script:nativeResult = 'copied'

    # errors the dialog explains
    Get-ChildItem -LiteralPath (Join-Path $drive 'bundles') -Recurse -File -Filter '*.enc' | Remove-Item -Force
    $msg = $null; try { Invoke-SyncPull -Row $row3 -Target $profA2 } catch { $msg = $_.Exception.Message }
    Assert ($msg -like '*bundle-missing*') "missing bundle: $msg"
    Assert ((Get-SyncErrorMessage -Message $msg) -like '*not on Drive*') 'bundle-missing has a plain-language message'
    foreach ($code in 'wrong-passphrase', 'sync-key-missing', 'sync-not-set-up', 'sha-mismatch', 'mac-mismatch') {
        Assert ((Get-SyncErrorMessage -Message "x $code y") -notlike "*$code*") "message for $code"
    }
    Assert ((Get-SyncErrorMessage -Message 'sync-conflict: two sync.json') -like '*two sync.json*') 'sync-conflict keeps the instructions of the original message'
    Assert ((Get-SyncErrorMessage -Message 'something else') -eq 'something else') 'unknown errors pass through'
    $script:SwitcherHome = Join-Path $tmp 'home-none'
    $msg = $null; try { Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 } catch { $msg = $_.Exception.Message }
    Assert ($msg -like '*sync-key-missing*') 'a machine without the cached key is told to set sync up'

    # ---------------------------------------------------------------- U4: first-time setup (logic only; the dialog is a shell)
    $okPass = 'twelve chars!'
    Assert (@(Test-SyncSetupInput -Passphrase $okPass -Confirmation $okPass -Acknowledged $true).Count -eq 0) 'valid first-machine input'
    Assert (@(Test-SyncSetupInput -Passphrase $okPass -Confirmation 'something else' -Acknowledged $true).Count -eq 1) 'two different passphrases'
    Assert (@(Test-SyncSetupInput -Passphrase 'short one' -Confirmation 'short one' -Acknowledged $true).Count -eq 1) 'shorter than 12 characters'
    Assert (@(Test-SyncSetupInput -Passphrase $okPass -Confirmation $okPass -Acknowledged $false).Count -eq 1) 'the warning box must be ticked'
    Assert (@(Test-SyncSetupInput -Passphrase '' -Confirmation '' -Acknowledged $false).Count -ge 2) 'empty input reports every problem'
    Assert (@(Test-SyncSetupInput -Passphrase 'whatever' -Existing).Count -eq 0) 'a machine joining an existing folder only types the passphrase once'
    Assert (@(Test-SyncSetupInput -Passphrase '' -Existing).Count -eq 1) 'but it cannot be empty'
    $errs = (Test-SyncSetupInput -Passphrase 'a' -Confirmation 'b' -Acknowledged $false) -join '|'
    Assert (-not $errs.Contains('a|') -and -not $errs.Contains('|b')) 'messages never echo the passphrase'

    $setupDrive = Join-Path $tmp 'setupdrive'
    New-Item -ItemType Directory -Path $setupDrive -Force | Out-Null
    Set-SyncSetting 'CustomPath' $null; Set-SyncSetting 'DriveAccountToken' $null
    Use-Machine $idA 'PCA'
    $r = Invoke-SyncSetup -CustomPath $setupDrive -Passphrase $okPass -Iterations 1000 -MinIterations 1000
    Assert ($r.Root -eq $setupDrive -and $r.FirstMachine -eq $true -and (Test-Path -LiteralPath (Join-Path $setupDrive 'sync.json'))) 'the first machine creates sync.json'
    Assert ((Get-SyncSetting 'CustomPath') -eq $setupDrive) 'the folder is remembered in the settings'
    Assert ($null -ne (Get-SyncSession).Key -and (Get-SyncSession).Root -eq $setupDrive) 'the key is in the DPAPI cache, so push and pull work without the passphrase'
    $settingsText = [IO.File]::ReadAllText($script:SettingsPath)
    Assert (-not $settingsText.Contains($okPass)) 'the passphrase is not written to the settings'
    # a second machine (a fresh switcher home: no cached key yet)
    Use-Machine $idB 'PCB2'
    Set-SyncSetting 'CustomPath' $null
    $msg = $null; try { Invoke-SyncSetup -CustomPath $setupDrive -Passphrase 'not the passphrase' -Iterations 1000 -MinIterations 1000 } catch { $msg = $_.Exception.Message }
    Assert ($msg -like '*wrong-passphrase*') "wrong passphrase on the second machine: $msg"
    Assert (-not (Get-SyncSetting 'CustomPath') -and -not (Test-Path -LiteralPath (Get-SyncKeyCachePath))) 'a failed setup leaves no setting and no cached key'
    $r = Invoke-SyncSetup -CustomPath $setupDrive -Passphrase $okPass -Iterations 1000 -MinIterations 1000
    Assert ($r.FirstMachine -eq $false -and $null -ne (Get-SyncSession).Key) 'the second machine joins with the same passphrase'
    $msg = $null; try { Invoke-SyncSetup -CustomPath 'rel\path' -Passphrase $okPass } catch { $msg = $_.Exception.Message }
    Assert ($msg) 'a relative folder is refused'

    # Drive accounts are offered by label; a folder that already holds sync.json is marked as existing
    $mount = Join-Path $tmp 'mountA'
    New-Item -ItemType Directory -Path (Join-Path $mount 'My Drive') -Force | Out-Null
    $script:SyncHooks = @{
        ReadRegistry = { (@{ per_account_preferences = @(@{ key = '100000000000000000009'; value = @{ mount_point_path = $mount } }) } | ConvertTo-Json -Depth 6 -Compress) }
        VolumeLabel = { param($m) 'someone@example.test' }
    }
    $choices = @(Get-SyncSetupChoices)
    Assert ($choices.Count -eq 1 -and $choices[0].Token -eq '100000000000000000009' -and $choices[0].Text -like '*someone@example.test*' -and $choices[0].Existing -eq $false) "choices: $($choices | ConvertTo-Json -Compress)"
    New-Item -ItemType Directory -Path (Join-Path $mount 'My Drive\HarnessSync') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $mount 'My Drive\HarnessSync\sync.json'), '{}')
    Assert ((@(Get-SyncSetupChoices))[0].Existing -eq $true) 'an existing sync.json is detected'
    $script:SyncHooks = $null

    # ---------------------------------------------------------------- U5: messages, the dialog's action, the catalog list
    function New-Res($status, $extra = @{}) { $o = [pscustomobject]@{ Status = $status; Mode = 'native'; Root = $null; CwdMissing = $false; Divergence = $null; Error = $null }; foreach ($k in $extra.Keys) { $o.$k = $extra[$k] }; $o }
    $nm = { param($r) Get-HarnessTransferMessage -Result $r -Target $profA2 }
    Assert ((& $nm (New-Res 'updated')) -like 'Updated*A two*') 'updated message'
    Assert ((& $nm (New-Res 'same')) -like '*already has this version*') 'same message'
    Assert ((& $nm (New-Res 'needs-root' @{ Root = 'Proj' })) -like "*'Proj'*") 'needs-root message names the folder'
    Assert ((& $nm (New-Res 'copied' @{ CwdMissing = $true })) -like 'Copied into*working folder*does not exist*') 'a missing working folder is mentioned'
    $dm = & $nm (New-Res 'handoff' @{ Mode = 'handoff'; Divergence = 'diverged' })
    Assert ($dm -like '*changed on both*' -and $dm -like '*clipboard*') 'diverged message'
    Assert ((& $nm (New-Res 'handoff' @{ Mode = 'handoff' })) -like 'Handoff into*') 'a plain handoff keeps its message'
    Assert ((& $nm (New-Res 'bundle-missing')) -like '*not on Drive*') 'bundle-missing message'
    Assert ((& $nm (New-Res 'sync-conflict' @{ Error = 'sync-conflict: two sync.json files, keep one' })) -like '*two sync.json files*') 'sync-conflict message keeps the instructions'
    Assert ((& $nm (New-Res 'copied')) -eq 'Copied into Fakea / A two.') 'copied message unchanged'

    $t0 = [DateTimeOffset]::FromUnixTimeMilliseconds(1700000000000).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
    Assert ((Format-SyncActivity 1700000000000) -eq $t0 -and (Format-SyncActivity 1700000000) -eq $t0 -and (Format-SyncActivity $null) -eq '') 'activity time from ms or seconds'
    $line = Get-SyncCatalogLine -Row ([pscustomobject]@{ Title = 'My chat'; MachineName = 'PCA'; lastActivityAt = 1700000000000 })
    Assert ($line -eq "My chat   (PCA, $t0)") "catalog line: $line"

    # tray entries follow the setup state
    Use-Machine $idA 'PCA-tray'
    Set-SyncSetting 'CustomPath' $null; Set-SyncSetting 'DriveAccountToken' $null
    $items = @(Get-SyncTrayItems)
    Assert ($items.Count -eq 1 -and $items[0].Action -eq 'setup' -and $items[0].Text -eq 'Set up Drive sync...') 'not set up: one entry to set it up'
    $trayRoot = Join-Path $tmp 'trayroot'; New-Item -ItemType Directory -Path $trayRoot | Out-Null
    [void](Invoke-SyncSetup -CustomPath $trayRoot -Passphrase $okPass -Iterations 1000 -MinIterations 1000)
    $items = @(Get-SyncTrayItems)
    Assert ($items.Count -eq 2 -and $items[0].Text -eq 'Sync: Push...' -and $items[0].Action -eq 'push' -and $items[1].Text -eq 'Sync: Pull...' -and $items[1].Action -eq 'pull') 'set up: push and pull entries'
    Assert (@(Get-SyncDialogTargets -Targets @($profA1, $profB1) -SyncReady $true | ForEach-Object { $_.Kind }) -join ',' -eq 'file,drive,profile,profile') 'target list: file, Drive, then the profiles'
    Assert (@(Get-SyncDialogTargets -Targets @($profA1) -SyncReady $false | ForEach-Object { $_.Kind }) -join ',' -eq 'file,profile') 'no Drive target before setup'

    # push from the dialog, then pull on the other machine asking for the folder root once
    $adA['ImportNative'] = { param($BundlePath, $Profile) [void]$script:imports.Add(@('native', $Profile.Id)); if (-not (Get-SyncPathRoots).ContainsKey('Proj')) { @{ Status = 'needs-root'; Root = 'Proj' } } else { 'copied' } }
    Register-Harness -Name 'fakea' -Adapter $adA
    $chat1.Activity = 2000000000000
    $push = Invoke-HarnessDialogAction -Source @{ Kind = 'harness'; Harness = 'fakea'; Profile = $profA1 } -TargetEntry @{ Kind = 'drive' } -Item $chat1
    Assert ($push.Kind -eq 'message' -and $push.Text -like '*Drive*encrypted*') "push from the dialog: $($push | ConvertTo-Json -Compress)"
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $trayRoot 'bundles') -Recurse -File -Filter '*.enc').Count -eq 1) 'the dialog push wrote one bundle'
    $warn = Invoke-HarnessDialogAction -Source @{ Kind = 'drive' } -TargetEntry @{ Kind = 'file' } -Item $null
    Assert ($warn.Kind -eq 'warning') 'pulling needs a target profile'
    $file = Invoke-HarnessDialogAction -Source @{ Kind = 'harness'; Harness = 'fakea'; Profile = $profA1 } -TargetEntry @{ Kind = 'file' } -Item $chat1
    Assert ($file.Kind -eq 'message' -and $file.Prompt) 'a handoff file from the dialog'

    Use-Machine $idB 'PCB-tray'
    [void](Invoke-SyncSetup -CustomPath $trayRoot -Passphrase $okPass -Iterations 1000 -MinIterations 1000)
    $trayKey = (Get-SyncSession).Key
    $trayRow = @(Get-SyncCatalog -Root $trayRoot -Key $trayKey)[0]
    $script:asked = New-Object Collections.ArrayList
    $pullNo = Invoke-HarnessDialogAction -Source @{ Kind = 'drive' } -TargetEntry @{ Kind = 'profile'; Profile = $profA2 } -Item $trayRow -AskRoot { param($name) [void]$script:asked.Add($name); $null }
    Assert ($pullNo.Kind -eq 'warning' -and $script:asked[0] -eq 'Proj' -and -not (Get-SyncPathRoots).ContainsKey('Proj')) "declining the root: $($pullNo | ConvertTo-Json -Compress)"
    $projDir = Join-Path $tmp 'proj-here'
    $pullYes = Invoke-HarnessDialogAction -Source @{ Kind = 'drive' } -TargetEntry @{ Kind = 'profile'; Profile = $profA2 } -Item $trayRow -AskRoot { param($name) $projDir }
    Assert ($pullYes.Kind -eq 'message' -and $pullYes.Text -like 'Copied into*' -and (Get-SyncPathRoots)['Proj'] -eq $projDir) "after choosing the root: $($pullYes | ConvertTo-Json -Compress)"
    $bad = Invoke-HarnessDialogAction -Source @{ Kind = 'drive' } -TargetEntry @{ Kind = 'profile'; Profile = $profA2 } -Item ([pscustomobject]@{ chatKey = 'fakea:x'; bundleId = 'nope'; path = 'x'; sha256 = 'x'; harness = 'fakea'; MachineName = 'm' })
    Assert ($bad.Kind -eq 'error' -and $bad.Text) 'a failure comes back as an error message, not an exception'

    # After a native import the app may report a later activity than the bundle's (Codex re-registers the thread, Antigravity
    # reads the copied file's time): the state must record what the chat reads as, or the next pull calls it diverged.
    Use-Machine $idA 'PCA-act'
    [void](Invoke-SyncSetup -CustomPath $trayRoot -Passphrase $okPass -Iterations 1000 -MinIterations 1000)
    $actKey = (Get-SyncSession).Key
    $r1 = @(Get-SyncCatalog -Root $trayRoot -Key $actKey | Where-Object { $_.chatKey -eq 'fakea:chat-1' })[0]
    $script:imported = $false; $script:postActivity = $r1.lastActivityAt + 5000
    $adA['ImportNative'] = { param($BundlePath, $Profile) $script:imported = $true; 'copied' }
    $adA['ListChats'] = { param($p) if ($p.Id -eq 'a2' -and $script:imported) { @([pscustomobject]@{ ChatId = 'chat-1'; Activity = $script:postActivity }) } else { @($script:chatsOf[$p.Id]) } }
    Register-Harness -Name 'fakea' -Adapter $adA
    $res = Invoke-SyncPull -Row $r1 -Target $profA2
    Assert ($res.Divergence -eq 'new' -and $res.Status -eq 'copied') 'first pull of the chat on a fresh machine'
    Assert ((Get-SyncState)['fakea:chat-1'].localActivityAtSync -eq $script:postActivity) 'the state records the activity the chat reads as after the import'
    Use-Machine $idB 'PCB-tray'
    $chat1.Activity = $r1.lastActivityAt + 100000
    [void](Invoke-SyncPush -Chat $chat1 -SourceHarness 'fakea' -Profile $profA1 -BundleDir (Join-Path $tmp 'pushb'))
    Use-Machine $idA 'PCA-act'
    $r2 = @(Get-SyncCatalog -Root $trayRoot -Key $actKey | Where-Object { $_.chatKey -eq 'fakea:chat-1' })[0]
    Assert ($r2.bundleId -ne $r1.bundleId) 'a newer version is on Drive'
    $res = Invoke-SyncPull -Row $r2 -Target $profA2
    Assert ($res.Divergence -eq 'update' -and $res.Status -eq 'copied') "an untouched chat is updated, not called diverged: $($res | ConvertTo-Json -Compress)"

    # back to the plain fake for the command-line tests
    $script:imported = $false
    $adA['ImportNative'] = { param($BundlePath, $Profile) [void]$script:imports.Add(@('native', $Profile.Id)); if (-not (Get-SyncPathRoots).ContainsKey('Proj')) { @{ Status = 'needs-root'; Root = 'Proj' } } else { 'copied' } }
    $adA['ListChats'] = { param($p) @($script:chatsOf[$p.Id]) }
    Register-Harness -Name 'fakea' -Adapter $adA

    # ---------------------------------------------------------------- U7: the command line
    $adA['GetProfiles'] = { @($profA1, $profA2) }
    Register-Harness -Name 'fakea' -Adapter $adA
    $script:chatsOf['a1'] = @($chat1)
    $script:chatsOf['a2'] = @()
    $chat1.Activity = 2100000000000
    Use-Machine $idB 'PCB-tray'
    $out = @(Invoke-SyncCli -Push 'fakea:a1:chat-1') -join "`n"
    Assert ($out -like "*Pushed 'First chat'*") "CLI push: $out"
    Use-Machine $idA 'PCA-tray'
    $out = @(Invoke-SyncCli -Pull 'fakea:chat-1' -Target 'fakea:a2') -join "`n"
    Assert ($out -like '*Copied into Fakea / A two*') "CLI pull by chat key: $out"
    $bundleId = (Get-SyncState)['fakea:chat-1'].lastBundleId
    $out = @(Invoke-SyncCli -Pull $bundleId -Target 'fakea:A two') -join "`n"
    Assert ($out -like '*already has this version*' -or $out -like '*Copied*') "CLI pull by bundle id, target by name: $out"
    $out = @(Invoke-SyncCli -Pull 'fakea:chat-1') -join "`n"
    Assert ($out -like '*A one*' -or $out -like '*Copied*' -or $out -like '*version*') "CLI pull without a target uses the first profile of the harness: $out"
    foreach ($bad in @(@{ P = 'fakea:a1' }, @{ P = 'nope:a1:chat-1' }, @{ P = 'fakea:zzz:chat-1' }, @{ P = 'fakea:a1:no-such-chat' })) {
        $m = $null; try { [void](Invoke-SyncCli -Push $bad.P) } catch { $m = $_.Exception.Message }
        Assert ($m) "CLI push '$($bad.P)' must fail with a message"
    }
    $m = $null; try { [void](Invoke-SyncCli -Pull 'fakea:not-on-drive') } catch { $m = $_.Exception.Message }
    Assert ($m -like '*No chat on Drive*') "unknown chat on pull: $m"
    $m = $null; try { [void](Invoke-SyncCli -Push 'fakea:a1:chat-1' -Pull 'x') } catch { $m = $_.Exception.Message }
    Assert ($m -like '*either*') 'push and pull together are refused'
    $m = $null; try { [void](Invoke-SyncCli -Pull 'fakea:chat-1' -Target 'bad') } catch { $m = $_.Exception.Message }
    Assert ($m) 'a bad -SyncTarget is refused'
    # needs-root cannot be asked in a console: the message says where to do it
    Use-Machine $idA 'PCA-nr'; [void](Invoke-SyncSetup -CustomPath $trayRoot -Passphrase $okPass -Iterations 1000 -MinIterations 1000)   # fresh home: no sync state, so the pull is a new chat
    $rootsBefore = Get-SyncSetting 'PathRoots'
    Set-SyncSetting 'PathRoots' $null
    $m = $null; try { [void](Invoke-SyncCli -Pull 'fakea:chat-1' -Target 'fakea:a2') } catch { $m = $_.Exception.Message }
    Set-SyncSetting 'PathRoots' $rootsBefore
    Assert ($m -like "*'Proj'*tray*") "needs-root in the CLI: $m"
    # no cached key: told to open the switcher, never asked for the passphrase
    $script:SwitcherHome = Join-Path $tmp 'home-nokey'
    $m = $null; try { [void](Invoke-SyncCli -Push 'fakea:a1:chat-1') } catch { $m = $_.Exception.Message }
    Assert ($m -like '*open the switcher once*') "no key: $m"

    # the script itself: parameters, markers, hook budget (parsed, never run)
    $swPath = Join-Path $root 'ClaudeSwitcher.ps1'
    $perr = $null; $swAst = [Management.Automation.Language.Parser]::ParseFile($swPath, [ref]$null, [ref]$perr)
    Assert (-not $perr.Count) 'ClaudeSwitcher.ps1 parses'
    $pnames = @($swAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert ($pnames[0] -eq 'Launch') 'Launch stays the first parameter, so "ClaudeSwitcher.ps1 Work" still binds to it'
    Assert (($pnames[-3..-1] -join ',') -eq 'SyncPush,SyncPull,SyncTarget' -and $pnames[-4] -eq 'OpenLinksIn') 'the new parameters come last, after OpenLinksIn'
    $swLines = [IO.File]::ReadAllLines($swPath)
    $iParams = [Array]::FindIndex($swLines, [Predicate[string]]{ param($l) $l.Trim() -eq '# >>> harness-params' })
    $iParamsEnd = [Array]::FindIndex($swLines, [Predicate[string]]{ param($l) $l.Trim() -eq '# <<< harness-params' })
    $iClose = [Array]::FindIndex($swLines, $iParamsEnd, [Predicate[string]]{ param($l) $l.Trim() -eq ')' })
    Assert ($iParams -gt 0 -and $iParamsEnd -gt $iParams -and $iClose -eq $iParamsEnd + 1) 'harness-params sits at the end of the param block'
    Assert (@($swLines[($iParams + 1)..($iParamsEnd - 1)] | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith(',') }).Count -eq 0) 'every harness-params line starts with a comma'
    $iCli = [Array]::FindIndex($swLines, [Predicate[string]]{ param($l) $l.Trim() -eq '# >>> harness-cli' })
    $iLaunch = [Array]::FindIndex($swLines, [Predicate[string]]{ param($l) $l.Trim() -eq 'if ($Launch) {' })
    Assert ($iCli -gt 0 -and $iCli -lt $iLaunch -and ($iLaunch - $iCli) -lt 10) 'harness-cli sits right before if ($Launch)'
    $hookLines = 0; $inBlock = $false
    foreach ($l in $swLines) {
        if ($l.Trim() -match '^# >>> harness-') { $inBlock = $true }
        if ($inBlock) { $hookLines++ }
        if ($l.Trim() -match '^# <<< harness-') { $inBlock = $false }
    }
    Write-Output "hook lines in ClaudeSwitcher.ps1 (all harness-* blocks, markers included): $hookLines"
    Assert ($hookLines -le 60) 'the hook blocks stay small'
    . (Import-TestFunctions -Files @($swPath) -Names @('Test-HandleLinkAlone'))
    Assert (-not (Test-HandleLinkAlone -Bound @{ HandleLink = 'claude://x'; SyncPush = 'a:b:c' })) '-HandleLink next to -SyncPush is refused'
    Assert (-not (Test-HandleLinkAlone -Bound @{ HandleLink = 'claude://x'; SyncPull = 'a' })) '-HandleLink next to -SyncPull is refused'
    Assert (Test-HandleLinkAlone -Bound @{ SyncPush = 'a:b:c' }) 'a sync switch alone is fine'

    # ---------------------------------------------------------------- V3b: the diverged choice window (built, never shown)
    $divRow = [pscustomobject]@{ Title = 'Their title'; MachineName = 'PCA' }
    $f = New-SyncDivergedForm -Row $divRow -Chat ([pscustomobject]@{ Title = 'My copy' })
    try {
        Assert ($f.Handoff.Text -like 'Bring theirs in*' -and $f.Push.Text -like 'Push mine*' -and $f.Cancel.Text -eq 'Cancel') 'three buttons with the agreed labels'
        Assert ([object]::ReferenceEquals($f.Form.AcceptButton, $f.Handoff)) 'the default (Enter) is bring theirs in as a new chat'
        Assert ([object]::ReferenceEquals($f.Form.CancelButton, $f.Cancel)) 'Escape cancels'
        Assert ((@($f.Form.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -like '*PCA*' -and $_.Text -like '*My copy*' })).Count -eq 1) 'the text names the chat and the other machine'
        Assert ([string]$f.Handoff.DialogResult -eq 'Yes' -and [string]$f.Push.DialogResult -eq 'No' -and [string]$f.Cancel.DialogResult -eq 'Cancel') 'each button closes with its own result'
    } finally { $f.Form.Dispose() }
    Assert ((Get-HarnessTransferMessage -Result (New-Res 'pushed-mine') -Target $profA2) -like 'Pushed*latest*') 'pushed-mine message'
    Assert ((Get-HarnessTransferMessage -Result (New-Res 'cancelled') -Target $profA2) -eq 'Nothing was changed.') 'cancelled message'

    # ---------------------------------------------------------------- V3d: the move dialog's one-line hint (pure)
    $hn = { param($mode) Get-HarnessMoveHint -Mode $mode -TargetName 'Codex / Work' }
    Assert ((& $hn 'native') -like '*Codex / Work*' -and (& $hn 'native') -like '*copied*') "native hint: $(& $hn 'native')"
    Assert ((& $hn 'codex-import') -like '*Codex / Work*' -and (& $hn 'codex-import') -like '*Codex*import*') "codex-import hint: $(& $hn 'codex-import')"
    Assert ((& $hn 'handoff') -like '*Codex / Work*' -and (& $hn 'handoff') -like '*clipboard*') "handoff hint: $(& $hn 'handoff')"
    Assert ((& $hn 'files') -like '*file*') "files hint: $(& $hn 'files')"
    Assert ((& $hn 'native') -ne (& $hn 'handoff') -and (& $hn 'native') -ne (& $hn 'codex-import')) 'the hints differ'
    Assert ((Get-HarnessMoveHint -Mode (Resolve-TransferMode -Source 'fakea' -Target 'fakea') -TargetName 'x') -like '*copied*') 'fakea to fakea reads as native'
    Assert ((Get-HarnessMoveHint -Mode (Resolve-TransferMode -Source 'fakea' -Target 'fakeb') -TargetName 'x') -like '*clipboard*') 'fakea to fakeb reads as handoff'

    # ---------------------------------------------------------------- V3c: the 3-step setup wizard (pure state + the finish action)
    $w = { param($h) $base = @{ Page = 1; Choice = $null; Passphrase = ''; Confirmation = ''; Acknowledged = $false }; foreach ($k in $h.Keys) { $base[$k] = $h[$k] }; Get-SyncWizardStep -State $base }
    $newCh = [pscustomobject]@{ Kind = 'custom'; Path = $setupDrive; Text = 'Folder'; Existing = $false }
    $oldCh = [pscustomobject]@{ Kind = 'custom'; Path = $setupDrive; Text = 'Folder'; Existing = $true }
    $s = & $w @{}
    Assert ($s.Page -eq 1 -and -not $s.CanNext -and -not $s.CanBack -and -not $s.CanFinish) 'step 1 without a choice has no Next'
    $s = & $w @{ Choice = $newCh }
    Assert ($s.Page -eq 1 -and $s.CanNext -and -not $s.CanBack) 'step 1 with a choice can go on'
    $s = & $w @{ Page = 2; Choice = $newCh }
    Assert ($s.Page -eq 2 -and $s.CanBack -and -not $s.CanNext -and -not $s.Existing -and $s.Problems.Count -ge 2) "step 2 of a new folder needs the passphrase twice and the tick: $($s.Problems -join '|')"
    $s = & $w @{ Page = 2; Choice = $newCh; Passphrase = $okPass; Confirmation = $okPass; Acknowledged = $true }
    Assert ($s.CanNext -and $s.Problems.Count -eq 0) 'step 2 is complete with a matching passphrase and the tick'
    $s = & $w @{ Page = 2; Choice = $oldCh; Passphrase = 'x' }
    Assert ($s.Existing -and $s.CanNext -and $s.Problems.Count -eq 0) 'joining an existing folder: one passphrase field is enough'
    $s = & $w @{ Page = 2; Choice = $oldCh }
    Assert ($s.Existing -and -not $s.CanNext -and $s.Problems.Count -eq 1) 'joining an existing folder: still not empty'
    Assert (-not (($s | ConvertTo-Json -Depth 4) -like '*twelve chars*')) 'the step never carries the passphrase'
    $s = & $w @{ Page = 3; Choice = $newCh }
    Assert ($s.Page -eq 3 -and $s.CanBack -and $s.CanFinish -and -not $s.CanNext) 'step 3 can finish'
    $s = & $w @{ Page = 7; Choice = $newCh }
    Assert ($s.Page -eq 3) 'a page number out of range is clamped'

    # Finish: Invoke-SyncSetup, then the ticked roots. Fakes for the suggestions; real sync folder in a temp dir.
    $wizDrive = Join-Path $tmp 'wizdrive'; New-Item -ItemType Directory -Path $wizDrive -Force | Out-Null
    $rootDir = Join-Path $tmp 'wizroot'; New-Item -ItemType Directory -Path $rootDir -Force | Out-Null
    Use-Machine $idA 'PCW'; Set-SyncSetting 'CustomPath' $null; Set-SyncSetting 'DriveAccountToken' $null
    $script:SwitcherHome = Join-Path $tmp 'home-wizard'
    $state = @{ Page = 3; Choice = [pscustomobject]@{ Kind = 'custom'; Path = $wizDrive; Text = 'Folder'; Existing = $false }; Passphrase = $okPass; Confirmation = $okPass; Acknowledged = $true }
    $before = Get-SyncPathRoots
    $res = Complete-SyncWizard -State $state -Roots @(@{ Name = 'Proj'; Path = $rootDir }, @{ Name = 'Bad name!'; Path = $rootDir }) -Iterations 1000 -MinIterations 1000
    Assert ($res.Root -eq $wizDrive -and $res.FirstMachine -eq $true) "wizard finish sets sync up: $($res | ConvertTo-Json -Compress)"
    Assert ((Get-SyncPathRoots)['Proj'] -eq $rootDir) 'the ticked folder root is saved'
    Assert ($res.RootErrors.Count -eq 1 -and $res.RootErrors[0] -like '*Bad name!*') 'a bad root is reported, the others still get saved'
    Assert ($null -ne (Get-SyncSession).Key) 'the key is cached after the wizard'
    Assert (-not ([IO.File]::ReadAllText($script:SettingsPath)).Contains($okPass)) 'the wizard never writes the passphrase to the settings'
    $msg = $null; try { Complete-SyncWizard -State @{ Page = 3; Choice = $newCh; Passphrase = 'short'; Confirmation = 'short'; Acknowledged = $true } -Roots @() } catch { $msg = $_.Exception.Message }
    Assert ($msg -and -not $msg.Contains('short''')) 'finishing with bad input is refused'
    $msg = $null; try { Complete-SyncWizard -State @{ Page = 3; Choice = $null } -Roots @() } catch { $msg = $_.Exception.Message }
    Assert ($msg) 'finishing without a choice is refused'
    # the suggestion list: V1's Get-SuggestedPathRoots when it exists, nothing otherwise
    function Get-SuggestedPathRoots { param([string[]]$Cwds) @(@{ Name = 'Fake'; Path = 'C:\fake' }) }
    $sug = @(Get-SyncWizardRoots -Cwds @('C:\fake\x'))
    Assert ($sug.Count -eq 1 -and $sug[0].Name -eq 'Fake') 'suggestions come from Get-SuggestedPathRoots'
    Remove-Item function:\Get-SuggestedPathRoots
    Assert (@(Get-SyncWizardRoots -Cwds @('C:\fake\x')).Count -eq 0) 'without Get-SuggestedPathRoots there are no suggestions'

    Write-Output 'PASS: sync UI helpers.'
} finally {
    $env:COMPUTERNAME = $savedName
    Remove-TestTempDir $tmp
}
