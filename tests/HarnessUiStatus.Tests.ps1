$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Harness.Core.ps1')
. (Join-Path $root 'src\Ui.ChatStatus.ps1')

# Pure functions: no window, no Drive. Folders are made in a temp directory, everything else is made-up data.
$tmp = New-TestTempDir
try {
    $here = Join-Path $tmp 'project'; New-Item -ItemType Directory -Path $here | Out-Null
    $gone = Join-Path $tmp 'not-there'
    function New-Chat($id, $activity, $cwd = $here, $profile = 'Default', $harness = 'claude') { [pscustomobject]@{ ChatId = $id; Title = 't'; Cwd = $cwd; Activity = $activity; Profile = [pscustomobject]@{ Id = $profile; Harness = $harness } } }
    function New-Row($key, $bundle, $machine = 'OTHER-PC', $activity = 1000) { [pscustomobject]@{ chatKey = $key; bundleId = $bundle; lastActivityAt = $activity; MachineName = $machine; Title = 't' } }
    function New-State($key, $bundle, $activityAtSync, $profile = 'Default') { @{ $key = [pscustomobject]@{ lastBundleId = $bundle; localChatId = 'x'; harness = 'claude'; profileId = $profile; localActivityAtSync = $activityAtSync } } }

    # ---------------------------------------------------------------- V1d: chat key and time
    Assert ((Get-HarnessChatKey -Harness 'claude' -Chat (New-Chat 'local_abc' 1)) -eq 'claude:local_abc') 'Claude chat key'
    Assert ((Get-HarnessChatKey -Harness 'Codex' -Chat (New-Chat 'thread-1' 1)) -eq 'codex:thread-1') 'the harness name is lower-cased'
    foreach ($case in @(@('claude', 'local_f1'), @('codex', '01a1b9d7-ce84-7613-9859-58999a3ece5f'), @('antigravity', '3f2c9a10-0000-4000-8000-000000000001'))) {
        $bp = Join-Path $tmp ('k-' + $case[0] + '.zip')
        $m = New-HarnessBundle -OutPath $bp -Source @{ harness = $case[0]; chatId = $case[1]; title = 't'; cwd = @{ absolute = $null; root = $null; relative = $null } } -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' })
        Assert ((Get-HarnessChatKey -Harness $case[0] -Chat (New-Chat $case[1] 1)) -eq $m.chatKey) "the key matches the chatKey New-HarnessBundle writes for $($case[0])"
    }
    $now = [datetime]'2026-11-12T15:30:00'
    function ToMs([datetime]$d) { [DateTimeOffset]::new($d).ToUnixTimeMilliseconds() }
    Assert ((Format-SyncWhen -UnixMs (ToMs ([datetime]'2026-11-12T10:42:00')) -Now $now) -eq '10:42') 'today: the time'
    Assert ((Format-SyncWhen -UnixMs (ToMs ([datetime]'2026-11-12T00:05:00')) -Now $now) -eq '00:05') 'today just after midnight'
    Assert ((Format-SyncWhen -UnixMs (ToMs ([datetime]'2026-11-11T23:59:00')) -Now $now) -eq 'yesterday') 'yesterday, even a minute before midnight'
    Assert ((Format-SyncWhen -UnixMs (ToMs ([datetime]'2026-11-10T08:00:00')) -Now $now) -eq '2 days') 'two days'
    Assert ((Format-SyncWhen -UnixMs (ToMs ([datetime]'2026-11-06T08:00:00')) -Now $now) -eq '6 days') 'six days'
    Assert ((Format-SyncWhen -UnixMs (ToMs ([datetime]'2026-11-05T08:00:00')) -Now $now) -eq '2026-11-05') 'a week or more: the date'
    Assert ((Format-SyncWhen -UnixMs (ToMs ([datetime]'2026-12-25T08:00:00')) -Now $now) -eq '2026-12-25') 'a time in the future: the date'
    Assert ((Format-SyncWhen -UnixMs $null -Now $now) -eq '') 'no time: empty'
    Assert ((Format-SyncWhen -UnixMs 'soon' -Now $now) -eq '') 'junk: empty'

    # ---------------------------------------------------------------- V1a: the chat status table
    $key = 'claude:c1'
    $chat = New-Chat 'c1' 5000
    $s = Get-HarnessChatSyncStatus -Chat $chat -Harness 'claude' -Catalog $null -State @{}
    Assert ($s.Sync -eq 'NoSync' -and $null -eq $s.Row -and $s.CwdMissing -eq $false) 'no catalog loaded (sync not set up): NoSync'
    $s = Get-HarnessChatSyncStatus -Chat $chat -Harness 'claude' -Catalog @() -State @{}
    Assert ($s.Sync -eq 'NotOnDrive' -and $null -eq $s.Row) 'an empty catalog: NotOnDrive'
    $s = Get-HarnessChatSyncStatus -Chat $chat -Harness 'claude' -Catalog @(New-Row 'claude:other' 'b9') -State @{}
    Assert ($s.Sync -eq 'NotOnDrive') 'a catalog without this chat: NotOnDrive'
    $row = New-Row $key 'b1' 'OTHER-PC'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5000) -Harness 'claude' -Catalog @($row) -State (New-State $key 'b1' 5000)
    Assert ($s.Sync -eq 'Synced' -and $s.Row.bundleId -eq 'b1') 'newest row is the last synced bundle and the chat did not change: Synced'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5001) -Harness 'claude' -Catalog @($row) -State (New-State $key 'b1' 5000)
    Assert ($s.Sync -eq 'LocalNewer') 'same bundle but the chat changed since: LocalNewer'
    $row2 = New-Row $key 'b2' 'OTHER-PC'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5000) -Harness 'claude' -Catalog @($row2) -State (New-State $key 'b1' 5000)
    Assert ($s.Sync -eq 'DriveNewer' -and $s.FromMachine -eq 'OTHER-PC' -and $s.Row.bundleId -eq 'b2') 'another bundle and the chat did not change: DriveNewer, with the machine name'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5001) -Harness 'claude' -Catalog @($row2) -State (New-State $key 'b1' 5000)
    Assert ($s.Sync -eq 'Diverged') 'another bundle and the chat changed too: Diverged'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5000) -Harness 'claude' -Catalog @($row2) -State @{}
    Assert ($s.Sync -eq 'Diverged') 'a local chat that was never synced but has a row on Drive: Diverged (same rule as Get-SyncDivergence)'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5000) -Harness 'claude' -Catalog @($row) -State (New-State $key 'b1' 5000 'Work')
    Assert ($s.Sync -eq 'Diverged') "state that belongs to another profile does not count: got $($s.Sync)"
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' $null) -Harness 'claude' -Catalog @($row2) -State (New-State $key 'b1' 5000)
    Assert ($s.Sync -eq 'Diverged') 'a chat with unknown activity cannot be called unchanged'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5000) -Harness 'claude' -Catalog @($row2) -State ([pscustomobject](New-State $key 'b1' 5000))
    Assert ($s.Sync -eq 'DriveNewer') 'state read back from JSON (an object, not a hashtable) works too'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 5000) -Harness 'claude' -Catalog @($row2) -State $null
    Assert ($s.Sync -eq 'Diverged') 'no state at all: Diverged'
    # same rule as Get-SyncDivergence: the cases the two functions both name must agree
    foreach ($act in 4000, 5000, 6000) {
        foreach ($rowBundle in 'b1', 'b2') {
            $r = New-Row $key $rowBundle
            $st = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' $act) -Harness 'claude' -Catalog @($r) -State (New-State $key 'b1' 5000)
            $script:probeAct = $act
            $dv =Get-SyncCatalogRowStatus -Row $r -State (New-State $key 'b1' 5000) -LocalChatLookup { param($row) New-Chat 'c1' $script:probeAct }
            if ($rowBundle -eq 'b1') { Assert ($dv -eq 'UpToDate') 'row is the synced bundle: UpToDate' }
            elseif ($act -le 5000) { Assert ($st.Sync -eq 'DriveNewer' -and $dv -eq 'DriveNewer') "act $act : both say DriveNewer" }
            else { Assert ($st.Sync -eq 'Diverged' -and $dv -eq 'Diverged') "act $act : both say Diverged" }
        }
    }

    # the folder flag
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 1 $here) -Harness 'claude' -Catalog @() -State @{}
    Assert ($s.CwdMissing -eq $false) 'a folder that exists'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 1 $gone) -Harness 'claude' -Catalog @() -State @{}
    Assert ($s.CwdMissing -eq $true) 'a folder that is gone'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 1 $null) -Harness 'claude' -Catalog $null -State @{}
    Assert ($s.CwdMissing -eq $false) 'a chat without a folder is not flagged'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 1 "bad`0path") -Harness 'claude' -Catalog $null -State @{}
    Assert ($s.CwdMissing -eq $true) 'a path that cannot be tested counts as missing, without an error'
    $s = Get-HarnessChatSyncStatus -Chat (New-Chat 'c1' 1 $gone) -Harness 'claude' -Catalog $null -State @{}
    Assert ($s.Sync -eq 'NoSync' -and $s.CwdMissing -eq $true) 'the folder flag is independent of the sync state'

    # ---------------------------------------------------------------- V1b: rows in the Drive tab
    $lookupNone = { param($row) $null }
    Assert ((Get-SyncCatalogRowStatus -Row $row -State @{} -LocalChatLookup $lookupNone) -eq 'NotHere') 'no local chat: NotHere'
    $lk = { param($row) New-Chat 'c1' 5000 }
    Assert ((Get-SyncCatalogRowStatus -Row $row -State (New-State $key 'b1' 5000) -LocalChatLookup $lk) -eq 'UpToDate') 'the row is what we last synced: UpToDate'
    Assert ((Get-SyncCatalogRowStatus -Row $row2 -State (New-State $key 'b1' 5000) -LocalChatLookup $lk) -eq 'DriveNewer') 'Drive moved, the chat did not: DriveNewer'
    $lk2 = { param($row) New-Chat 'c1' 9000 }
    Assert ((Get-SyncCatalogRowStatus -Row $row2 -State (New-State $key 'b1' 5000) -LocalChatLookup $lk2) -eq 'Diverged') 'both moved: Diverged'
    Assert ((Get-SyncCatalogRowStatus -Row $row2 -State @{} -LocalChatLookup $lk) -eq 'Diverged') 'a local chat that was never synced: Diverged'
    Assert ((Get-SyncCatalogRowStatus -Row $row2 -State (New-State $key 'b1' 5000 'Work') -LocalChatLookup $lk) -eq 'Diverged') 'state of another profile does not count'

    # ---------------------------------------------------------------- V1c: suggested path roots
    $sugg = @(Get-SuggestedPathRoots -Cwds @('H:\AI_Software\x\y', 'H:\AI_Software\z', 'D:\Work\a', 'D:\Work\b\c', 'H:\AI_Software') -ExistingRoots @{})
    Assert ($sugg.Count -eq 2) "five folders in two roots give two suggestions, got $($sugg.Count)"
    Assert ($sugg[0].Name -eq 'AI_Software' -and $sugg[0].Path -eq 'H:\AI_Software') 'first root'
    Assert ($sugg[1].Name -eq 'Work' -and $sugg[1].Path -eq 'D:\Work') 'second root'
    $s2 = @(Get-SuggestedPathRoots -Cwds @('H:\AI_Software\x', 'D:\Work\a') -ExistingRoots @{ Proj = 'H:\AI_Software' })
    Assert ($s2.Count -eq 1 -and $s2[0].Path -eq 'D:\Work') 'a root that already exists is not suggested again'
    $s3 = @(Get-SuggestedPathRoots -Cwds @('H:\AI_Software\sub\deep\x', 'H:\AI_Software\other') -ExistingRoots @{ Deep = 'h:\ai_software\sub\deep' })
    Assert ($s3.Count -eq 1 -and $s3[0].Path -eq 'H:\AI_Software') 'a folder under an existing root is covered by it (case-insensitive); the rest still groups'
    $s4 = @(Get-SuggestedPathRoots -Cwds @('D:\Work\a', 'E:\Work\b') -ExistingRoots @{})
    Assert ($s4.Count -eq 2 -and $s4[0].Name -eq 'Work' -and $s4[1].Name -eq 'Work_E') "same name on two drives: the second gets a drive suffix, got $(($s4 | ForEach-Object Name) -join ',')"
    $s5 = @(Get-SuggestedPathRoots -Cwds @('D:\Work\a') -ExistingRoots @{ Work = 'Z:\Other' })
    Assert ($s5.Count -eq 1 -and $s5[0].Name -eq 'Work_D') 'a name already used for another path gets the suffix too'
    $s6 = @(Get-SuggestedPathRoots -Cwds @('D:\My Proj (v2)!\a', 'E:\$$$\b') -ExistingRoots @{})
    foreach ($x in $s6) { Assert ($x.Name -match '\A[A-Za-z0-9_-]+\z') "name is clean: [$($x.Name)]" }
    Assert ($s6[0].Name -eq 'My_Proj_v2' -and $s6[0].Path -eq 'D:\My Proj (v2)!') 'odd characters become underscores; the path is untouched'
    $s7 = @(Get-SuggestedPathRoots -Cwds @('\\srv\share\team\a', '\\srv\share\team\b\c') -ExistingRoots @{})
    Assert ($s7.Count -eq 1 -and $s7[0].Path -eq '\\srv\share\team' -and $s7[0].Name -eq 'team') 'a UNC path groups under the first folder of the share'
    $s8 = @(Get-SuggestedPathRoots -Cwds @('C:\Windows\System32', 'C:\Program Files\App', 'C:\Users\bob', 'C:\', 'relative\path', '', $null, 'D:\ok\x') -ExistingRoots @{})
    Assert ($s8.Count -eq 1 -and $s8[0].Path -eq 'D:\ok') "system folders, a lone profile folder, drive roots and junk are left out, got $(($s8 | ForEach-Object Path) -join ',')"
    # inside a user profile the root is the folder right under the user folder: user names differ between machines, so
    # a root named after the user would never match, and the name would end up in the manifest and on Drive
    $s9 = @(Get-SuggestedPathRoots -Cwds @('C:\Users\a\source\x', 'C:\Users\a\Documents\y') -ExistingRoots @{})
    Assert ($s9.Count -eq 2 -and $s9[0].Name -eq 'source' -and $s9[0].Path -eq 'C:\Users\a\source' -and $s9[1].Name -eq 'Documents' -and $s9[1].Path -eq 'C:\Users\a\Documents') "roots are the folders under the user folder, got $(($s9 | ForEach-Object Name) -join ',')"
    foreach ($x in $s9) { Assert ($x.Name -ne 'a') 'no root is named after the user' }
    Assert (@(Get-SuggestedPathRoots -Cwds @('C:\Users\a\AppData\Local\z') -ExistingRoots @{}).Count -eq 0) 'AppData is not suggested'
    Assert (@(Get-SuggestedPathRoots -Cwds @('C:\Users\a\.config\k', 'C:\Users\a\.hidden') -ExistingRoots @{}).Count -eq 0) 'hidden folders are not suggested'
    Assert (@(Get-SuggestedPathRoots -Cwds @('C:\Users\a', 'C:\Users') -ExistingRoots @{}).Count -eq 0) 'the user folder itself gives nothing'
    $s9b = @(Get-SuggestedPathRoots -Cwds @('C:\Users\a\source', 'D:\Users\b\repos\app') -ExistingRoots @{})
    Assert ($s9b.Count -eq 2 -and $s9b[0].Path -eq 'C:\Users\a\source' -and $s9b[1].Path -eq 'D:\Users\b\repos' -and $s9b[1].Name -eq 'repos') 'a folder that is itself the root is fine; other drives work the same'
    Assert (@(Get-SuggestedPathRoots -Cwds @('C:\Users\a\appdata\x') -ExistingRoots @{}).Count -eq 0) 'AppData in any case'
    Assert (@(Get-SuggestedPathRoots -Cwds @() -ExistingRoots @{}).Count -eq 0) 'no folders: no suggestions'
    Assert (@(Get-SuggestedPathRoots -Cwds @('H:\a\b', 'h:\A\c') -ExistingRoots @{}).Count -eq 1) 'the same root spelt in two cases is one suggestion'
} finally {
    Remove-TestTempDir $tmp
}

Write-Host 'HarnessUiStatus.Tests: OK'
