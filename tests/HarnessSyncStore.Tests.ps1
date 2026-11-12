$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Import-TestFunctions -Files @((Join-Path $root 'ClaudeSwitcher.ps1')) -Names @('Get-Setting', 'Set-Setting'))
. (Join-Path $root 'src\Harness.Core.ps1')
. (Join-Path $root 'src\Harness.Sync.Crypto.ps1')
. (Join-Path $root 'src\Harness.Sync.Config.ps1')
. (Join-Path $root 'src\Harness.Sync.Store.ps1')

# The "Drive" is a temp folder, the settings are a temp file, the passphrase is made up and the key derivation is
# lowered to 1000 rounds. Nothing touches a real Drive, registry or profile.
$tmp = New-TestTempDir
$savedName = $env:COMPUTERNAME
try {
    $script:ProfileRoot = Join-Path $tmp 'profile'
    $script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
    $script:SwitcherHome = Join-Path $tmp 'profile\.switcher'
    $script:SyncRetryDelayMs = 5
    $drive = Join-Path $tmp 'drive\HarnessSync-test'
    $pass = 'test-only fake passphrase'
    $idA = 'aaaaaaaa-0000-4000-8000-000000000001'
    $idB = 'bbbbbbbb-0000-4000-8000-000000000002'
    function Use-Machine($id, $name) { Set-Setting 'Sync.MachineId' $id; $env:COMPUTERNAME = $name }
    function Get-SidecarFiles { @(Get-ChildItem -LiteralPath $drive -Recurse -File | Where-Object { $_.Name -match '\.tmp-' }) }

    # ---------------------------------------------------------------- S2: atomic writes
    $f = Join-Path $tmp 'atomic\x.json'
    Write-SyncFileAtomic -Path $f -Text '{"a":1}'
    Assert ([IO.File]::ReadAllText($f) -eq '{"a":1}') 'atomic write content'
    Assert (-not ([IO.File]::ReadAllBytes($f)[0] -eq 0xEF)) 'no BOM'
    Write-SyncFileAtomic -Path $f -Text '{"a":2}'
    Assert ([IO.File]::ReadAllText($f) -eq '{"a":2}') 'atomic overwrite'
    Assert (@(Get-ChildItem -LiteralPath (Split-Path $f)).Count -eq 1) 'no tmp file left'
    Assert-Throws { Write-SyncFileAtomic -Path $f -Text 'x' -NoClobber } 'NoClobber refuses to replace a file'
    Assert ([IO.File]::ReadAllText($f) -eq '{"a":2}') 'the refused write changed nothing'
    Assert (@(Get-ChildItem -LiteralPath (Split-Path $f)).Count -eq 1) 'no tmp file left after a refused write'

    # S10 (real DriveFS): replacing a file a reader has open needs MoveFileEx; Move-Item -Force failed 37/40 times
    $busy = Join-Path $tmp 'atomic\busy.json'
    Write-SyncFileAtomic -Path $busy -Text 'old'
    # On local NTFS an open file cannot be replaced even with Delete sharing (error 5; DriveFS allowed it in S10), so the
    # replace must wait for the reader: here the reader lets go after ~150 ms, in the middle of the retries.
    $reader = [IO.File]::Open($busy, 'Open', 'Read', [IO.FileShare]'ReadWrite,Delete')   # how the sync code itself opens files
    $ps = [powershell]::Create(); [void]$ps.AddScript({ param($r) Start-Sleep -Milliseconds 150; $r.Dispose() }).AddArgument($reader); $async = $ps.BeginInvoke()
    $script:SyncRetryDelayMs = 40
    try { Write-SyncFileAtomic -Path $busy -Text 'new' } finally { $script:SyncRetryDelayMs = 5; [void]$ps.EndInvoke($async); $ps.Dispose() }
    Assert ([IO.File]::ReadAllText($busy) -eq 'new') 'the replacement waits for a reader and then succeeds'
    $holder = [IO.File]::Open($busy, 'Open', 'Read', 'Read')   # a reader that does not share Delete: the replace cannot succeed
    $script:SyncRetryDelayMs = 1
    $msg = $null; try { Write-SyncFileAtomic -Path $busy -Text 'newer' } catch { $msg = $_.Exception.Message } finally { $holder.Dispose() }
    $script:SyncRetryDelayMs = 5
    Assert ($msg) 'a file that stays locked makes the write throw after the retries'
    Assert ([IO.File]::ReadAllText($busy) -eq 'new' -and @(Get-ChildItem -LiteralPath (Split-Path $busy) -Filter 'busy*').Count -eq 1) 'the old file is intact and no tmp is left'
    Assert ((Read-SyncAllText -Path $busy) -eq 'new') 'Read-SyncAllText reads with shared access'
    $script:SyncRetryDelayMs = 300   # with 10 retries a missing file would take ~2.7 s
    $msg = $null; $t0 = Get-Date; try { Read-SyncAllText -Path (Join-Path $tmp 'atomic\nope.json') } catch { $msg = $_.Exception.Message }
    $script:SyncRetryDelayMs = 5
    Assert ($msg -like '*find*' -and ((Get-Date) - $t0).TotalSeconds -lt 1) "a missing file fails at once, without retries: [$msg]"
    # a sharing violation, by contrast, is retried: a reader that lets go in time does not make the read fail
    $lock = [IO.File]::Open($busy, 'Open', 'ReadWrite', 'None')
    $ps = [powershell]::Create(); [void]$ps.AddScript({ param($r) Start-Sleep -Milliseconds 150; $r.Dispose() }).AddArgument($lock); $async = $ps.BeginInvoke()
    $script:SyncRetryDelayMs = 40
    try { $got = Read-SyncAllText -Path $busy } finally { $script:SyncRetryDelayMs = 5; [void]$ps.EndInvoke($async); $ps.Dispose() }
    Assert ($got -eq 'new') 'a read that hits an exclusive lock is retried until the lock goes'

    # ---------------------------------------------------------------- S1: sync.json
    # a lock that never goes is an I/O error, not "damaged JSON" (which would read as sync-invalid)
    $jf = Join-Path $tmp 'atomic\lockedjson.json'; [IO.File]::WriteAllText($jf, '{"a":1}')
    $lock = [IO.File]::Open($jf, 'Open', 'ReadWrite', 'None'); $script:SyncRetryDelayMs = 1
    $msg = $null; try { Read-SyncJsonFile $jf } catch { $msg = $_.Exception.Message } finally { $lock.Dispose(); $script:SyncRetryDelayMs = 5 }
    Assert ($msg -and $msg -notlike 'sync-invalid*') "a locked file throws its I/O error, got [$msg]"
    Assert ($null -eq (Read-SyncJsonFile (Join-Path $tmp 'atomic\nope.json'))) 'a file that is gone gives $null'
    [IO.File]::WriteAllText($jf, '{broken')
    Assert ($null -eq (Read-SyncJsonFile $jf)) 'damaged JSON gives $null'

    $weak = Join-Path $tmp 'weakdrive'
    [void](Initialize-SyncFolder -Root $weak -Passphrase $pass -Iterations 1000)
    $msg = $null; try { Initialize-SyncFolder -Root $weak -Passphrase $pass } catch { $msg = $_.Exception.Message }
    Assert ($msg -like 'sync-invalid*') "a sync.json with fewer than 600000 iterations is refused by default, got [$msg]"
    Assert ((Initialize-SyncFolder -Root $weak -Passphrase $pass -MinIterations 1000).iterations -eq 1000) '-MinIterations lowers the floor for tests'
    Use-Machine $idA 'MACHINE-A'
    $kdf = Initialize-SyncFolder -Root $drive -Passphrase $pass -Iterations 1000
    Assert ($kdf.salt -and $kdf.iterations -eq 1000 -and $kdf.keyCheck) 'first call creates the kdf'
    $syncPath = Join-Path $drive 'sync.json'
    $doc = Get-Content -LiteralPath $syncPath -Raw | ConvertFrom-Json
    Assert ($doc.format -eq 'harness-sync' -and $doc.version -eq 1 -and $doc.kdf.salt -eq $kdf.salt) 'sync.json layout'
    Assert ((Get-Content -LiteralPath $syncPath -Raw) -notlike "*$pass*") 'the passphrase is never written'
    $kdf2 = Initialize-SyncFolder -Root $drive -Passphrase $pass -MinIterations 1000
    Assert ($kdf2.salt -eq $kdf.salt -and $kdf2.iterations -eq 1000) 'the second machine reads the existing kdf'
    $msg = $null; try { Initialize-SyncFolder -Root $drive -Passphrase "a different fake passphrase" -MinIterations 1000 } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'wrong-passphrase') "wrong passphrase on an existing folder, got [$msg]"
    $kdfOther = New-SyncKdf -Passphrase 'some other passphrase' -Iterations 1000
    $dupText = (@{ format = 'harness-sync'; version = 1; kdf = $kdf } | ConvertTo-Json -Depth 5)
    [IO.File]::WriteAllText((Join-Path $drive 'sync (1).json'), $dupText)
    [void](Initialize-SyncFolder -Root $drive -Passphrase $pass -MinIterations 1000)   # same salt: a harmless duplicate
    [IO.File]::WriteAllText((Join-Path $drive 'sync (1).json'), (@{ format = 'harness-sync'; version = 1; kdf = $kdfOther } | ConvertTo-Json -Depth 5))
    $msg = $null; try { Initialize-SyncFolder -Root $drive -Passphrase $pass -MinIterations 1000 } catch { $msg = $_.Exception.Message }
    Assert ($msg -like 'sync-conflict*') "a (1) copy with another salt is a conflict, got [$msg]"
    Remove-Item -LiteralPath (Join-Path $drive 'sync (1).json')
    [IO.File]::WriteAllText($syncPath, 'not json')
    $msg = $null; try { Initialize-SyncFolder -Root $drive -Passphrase $pass -MinIterations 1000 } catch { $msg = $_.Exception.Message }
    Assert ($msg -like 'sync-invalid*') "a damaged sync.json, got [$msg]"
    Write-SyncFileAtomic -Path $syncPath -Text $dupText
    $key = Get-SyncKey -Passphrase $pass -Kdf $kdf

    # ---------------------------------------------------------------- helpers for bundles
    function New-TestBundle($chatId, $title, $activity, $harness = 'claude') {
        $p = Join-Path $tmp ('b-' + [guid]::NewGuid().ToString('N') + '.hbundle.zip')
        $m = New-HarnessBundle -OutPath $p -Source @{ harness = $harness; chatId = $chatId; title = $title; lastActivityAt = $activity; cwd = @{ absolute = $null; root = $null; relative = $null } } -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = "# $title" })
        return @{ Path = $p; Id = $m.bundleId }
    }
    function New-TestChat($chatId, $title, $activity, $harness = 'claude') { [pscustomobject]@{ ChatId = $chatId; Title = $title; Activity = $activity; Profile = [pscustomobject]@{ Id = 'Default'; Harness = $harness } } }

    # ---------------------------------------------------------------- S3: Push
    $t1 = 'Quarterly layoff plan'
    $b1 = New-TestBundle 'local_c1' $t1 1000
    $row1 = Push-SyncBundle -Root $drive -BundlePath $b1.Path -Key $key -Chat (New-TestChat 'local_c1' $t1 1000)
    Assert ($row1.bundleId -eq $b1.Id -and $row1.chatKey -eq 'claude:local_c1' -and $row1.harness -eq 'claude' -and $row1.machineId -eq $idA) 'row identity fields'
    Assert ($row1.path -eq "bundles/claude/claude_local_c1/$($b1.Id).hbundle.zip.enc") "row path, got $($row1.path)"
    Assert ($row1.lastActivityAt -eq 1000 -and $row1.pushedAt -and $null -eq $row1.previousBundleId) 'activity, pushedAt, no previous bundle yet'
    $encPath = Join-Path $drive ($row1.path -replace '/', '\')
    Assert ((Test-Path -LiteralPath $encPath) -and $row1.size -eq (Get-Item -LiteralPath $encPath).Length -and $row1.sha256 -eq (Get-FileSha256Hex $encPath)) 'the .enc file exists; size and sha256 match it'
    $head = [IO.File]::ReadAllBytes($encPath)[0..3]
    Assert ([Text.Encoding]::ASCII.GetString($head) -eq 'HSE1') 'the bundle on Drive is encrypted'
    $indexA = Join-Path $drive "index\$idA.jsonl"
    $indexText = [IO.File]::ReadAllText($indexA)
    Assert ($indexText -notlike "*$t1*" -and $indexText -notlike '*layoff*') 'the index holds no plain title'
    Assert ((Unprotect-SyncString -Text (($indexText.Trim() | ConvertFrom-Json).titleEnc) -Key $key) -ceq $t1) 'titleEnc decrypts to the title'
    $mach = Get-Content -LiteralPath (Join-Path $drive "machines\$idA.json") -Raw | ConvertFrom-Json
    Assert ($mach.name -eq 'MACHINE-A' -and $mach.lastSeen -and $null -ne $mach.PSObject.Properties['harnesses'] -and $null -ne $mach.PSObject.Properties['pathRoots']) 'machines/<id>.json'
    Assert ((Get-SidecarFiles).Count -eq 0) 'no tmp files left on the drive'

    $b2 = New-TestBundle 'local_c1' $t1 2000
    $row2 = Push-SyncBundle -Root $drive -BundlePath $b2.Path -Key $key -Chat (New-TestChat 'local_c1' $t1 2000)
    Assert ($row2.previousBundleId -eq $row1.bundleId) 'the second push points back at the first'
    Assert (@([IO.File]::ReadAllLines($indexA) | Where-Object { $_ }).Count -eq 2) 'two rows in the index'
    $st = Get-SyncState
    Assert ($st['claude:local_c1'].lastBundleId -eq $row2.bundleId -and $st['claude:local_c1'].localChatId -eq 'local_c1' -and $st['claude:local_c1'].localActivityAtSync -eq 2000 -and $st['claude:local_c1'].harness -eq 'claude' -and $st['claude:local_c1'].profileId -eq 'Default') 'push records the sync state'
    $bad = New-TestBundle 'local_c1' 'x' 1
    # a chat key with a path in it must not reach the folder layout
    $evil = Join-Path $tmp 'evil.hbundle.zip'
    [void](New-HarnessBundle -OutPath $evil -Source @{ harness = 'claude'; chatId = '..\..\x'; title = 'x'; cwd = @{ absolute = $null; root = $null; relative = $null } } -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' }))
    Assert-Throws { Push-SyncBundle -Root $drive -BundlePath $evil -Key $key -Chat (New-TestChat '..\..\x' 'x' 1) } 'an unsafe chat key is refused'
    Assert (-not (Test-Path -LiteralPath (Join-Path $tmp 'drive\x'))) 'nothing written outside the folder'

    # ---------------------------------------------------------------- second machine and S4 catalog
    Use-Machine $idB 'MACHINE-B'
    $t2 = 'Release notes'; $t3 = 'Hiring list'
    $b3 = New-TestBundle 'local_c2' $t2 1500
    [void](Push-SyncBundle -Root $drive -BundlePath $b3.Path -Key $key -Chat (New-TestChat 'local_c2' $t2 1500))
    $b4 = New-TestBundle 'local_c2' $t2 3000
    $row4 = Push-SyncBundle -Root $drive -BundlePath $b4.Path -Key $key -Chat (New-TestChat 'local_c2' $t2 3000)
    $b5 = New-TestBundle 'thread-3' $t3 500 'codex'
    $row5 = Push-SyncBundle -Root $drive -BundlePath $b5.Path -Key $key -Chat (New-TestChat 'thread-3' $t3 500 'codex')
    Use-Machine $idA 'MACHINE-A'
    # one settings file stands for both machines here; machine A has never seen B's versions, so it has no predecessor
    $st = Get-SyncState; $st.Remove('claude:local_c2'); Set-SyncState -State $st
    $b6 = New-TestBundle 'local_c2' $t2 2500
    [void](Push-SyncBundle -Root $drive -BundlePath $b6.Path -Key $key -Chat (New-TestChat 'local_c2' $t2 2500))

    $idxLines = @([IO.File]::ReadAllLines($indexA))
    Assert ($idxLines.Count -eq 3 -and $idxLines[0].StartsWith('{')) 'index: one JSON object per line, never an array'
    $cat = @(Get-SyncCatalog -Root $drive -Key $key)
    Assert ($cat.Count -eq 3) "three chats, got $($cat.Count)"
    $c1 = $cat | Where-Object chatKey -eq 'claude:local_c1'
    $c2 = $cat | Where-Object chatKey -eq 'claude:local_c2'
    $c3 = $cat | Where-Object chatKey -eq 'codex:thread-3'
    Assert ($c1.bundleId -eq $row2.bundleId -and $c1.Title -ceq $t1 -and $c1.MachineName -eq 'MACHINE-A') 'c1: newest version, decrypted title, machine name'
    Assert ($c2.bundleId -eq $row4.bundleId -and $c2.lastActivityAt -eq 3000 -and $c2.MachineName -eq 'MACHINE-B') 'c2: the version with the latest activity wins, even from the other machine'
    Assert ($c3.Title -ceq $t3 -and $c3.harness -eq 'codex') 'c3 listed'
    Assert (($cat | ForEach-Object { $_.lastActivityAt }) -join ',' -eq '3000,2000,500') 'newest first'

    # hostile or damaged input from the drive
    $goodRow = Get-Content -LiteralPath $indexA | Select-Object -First 1 | ConvertFrom-Json
    function Add-IndexLine([string]$Path, $Row) { [IO.File]::AppendAllText($Path, (($Row | ConvertTo-Json -Compress) + "`n")) }
    function Copy-Row($o, [hashtable]$over) { $h = @{}; $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }; foreach ($k in $over.Keys) { $h[$k] = $over[$k] }; [pscustomobject]$h }
    $hostile = @{ path = '../../x.enc' }, @{ path = 'bundles/claude/x/../../../y.enc' }, @{ path = 'C:/Windows/x.enc' }, @{ path = 'bundles/claude/claude_local_c1/not-a-guid.hbundle.zip.enc' },
        @{ bundleId = 'not-a-guid' }, @{ chatKey = '../../x' }, @{ harness = '..' }, @{ sha256 = 'zz' }, @{ machineId = $idB }, @{ lastActivityAt = 'soon' }
    foreach ($h in $hostile) {
        $over = @{ bundleId = [guid]::NewGuid().ToString(); chatKey = 'claude:evil' }
        foreach ($k in $h.Keys) { $over[$k] = $h[$k] }
        Add-IndexLine $indexA (Copy-Row $goodRow $over)
    }
    [IO.File]::AppendAllText($indexA, "{this is not json`n`n")
    [IO.File]::WriteAllText((Join-Path $drive "index\$idA.jsonl.tmp-0123"), (($goodRow | ConvertTo-Json -Compress) -replace 'local_c1', 'local_tmp'))
    [IO.File]::WriteAllText((Join-Path $drive "index\$idA (1).jsonl"), (($goodRow | ConvertTo-Json -Compress) -replace 'local_c1', 'local_dup'))
    [IO.File]::WriteAllText((Join-Path $drive 'index\notaguid.jsonl'), (($goodRow | ConvertTo-Json -Compress) -replace 'local_c1', 'local_name'))
    $cat2 = @(Get-SyncCatalog -Root $drive -Key $key 3>$null)
    Assert ($cat2.Count -eq 3) "hostile rows, tmp, duplicate and oddly named index files are all ignored, got $($cat2.Count): $(($cat2 | ForEach-Object chatKey) -join ',')"
    $titleRow = Copy-Row $goodRow @{ bundleId = [guid]::NewGuid().ToString(); chatKey = 'claude:badtitle'; titleEnc = 'AAAA' }
    Add-IndexLine $indexA $titleRow
    $cat3 = @(Get-SyncCatalog -Root $drive -Key $key 3>$null)
    Assert (($cat3 | Where-Object chatKey -eq 'claude:badtitle').Title -eq 'claude:badtitle') 'an unreadable title falls back to the chat key'
    foreach ($junk in "index\$idA.jsonl.tmp-0123", "index\$idA (1).jsonl", 'index\notaguid.jsonl') { Remove-Item -LiteralPath (Join-Path $drive $junk) }
    Remove-Item -LiteralPath $indexA
    Assert (@(Get-SyncCatalog -Root $drive -Key $key).Count -eq 2) 'a missing index file just removes its chats'
    # put the index back for the next sections: rewrite from the two good rows
    foreach ($r in @($row1, $row2)) { Add-IndexLine $indexA $r }

    # ---------------------------------------------------------------- S5 Receive
    $tempDirsBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'harness-sync-*').Count
    $zip = Receive-SyncBundle -Root $drive -Row $row2 -Key $key
    try {
        Assert ((Test-Path -LiteralPath $zip) -and $zip -like (Join-Path ([IO.Path]::GetTempPath()) 'harness-sync-*')) 'decrypted into the temp folder'
        Assert ((Get-FileSha256Hex $zip) -eq (Get-FileSha256Hex $b2.Path)) 'the decrypted bundle is byte for byte the one that was pushed'
        Assert (@(Get-ChildItem -LiteralPath (Split-Path $zip)).Count -eq 1) 'no .enc copy left beside the bundle'
    } finally { Remove-SyncReceived -Path $zip }
    Assert (-not (Test-Path -LiteralPath $zip)) 'Remove-SyncReceived deletes the bundle'
    Assert (@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'harness-sync-*').Count -eq $tempDirsBefore) 'and its temp folder'

    $msg = $null; try { Receive-SyncBundle -Root $drive -Row (Copy-Row $row2 @{ sha256 = ('0' * 64) }) -Key $key } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'sha-mismatch') "a changed sha, got [$msg]"
    $enc2 = Join-Path $drive ($row2.path -replace '/', '\')
    $bytes = [IO.File]::ReadAllBytes($enc2); $orig = [byte[]]$bytes.Clone(); $bytes[40] = $bytes[40] -bxor 1; [IO.File]::WriteAllBytes($enc2, $bytes)
    $msg = $null; try { Receive-SyncBundle -Root $drive -Row (Copy-Row $row2 @{ sha256 = (Get-FileSha256Hex $enc2) }) -Key $key } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'mac-mismatch') "a damaged file with a matching sha, got [$msg]"
    [IO.File]::WriteAllBytes($enc2, $orig)
    $otherKey = [byte[]]$key.Clone(); $otherKey[3] = $otherKey[3] -bxor 255
    $msg = $null; try { Receive-SyncBundle -Root $drive -Row $row2 -Key $otherKey } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'mac-mismatch') "another key, got [$msg]"
    Move-Item -LiteralPath $enc2 -Destination "$enc2.away"
    $msg = $null; try { Receive-SyncBundle -Root $drive -Row $row2 -Key $key } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'bundle-missing') "a file that is gone, got [$msg]"
    Move-Item -LiteralPath "$enc2.away" -Destination $enc2
    $msg = $null; try { Receive-SyncBundle -Root $drive -Row (Copy-Row $row2 @{ path = '../../x.enc' }) -Key $key } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'bundle-path-invalid') "a path that leaves bundles/, got [$msg]"
    Assert (@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'harness-sync-*').Count -eq $tempDirsBefore) 'failed receives leave no temp folder'

    # ---------------------------------------------------------------- S6 divergence
    $cat0 = [pscustomobject]@{ chatKey = 'claude:local_c1'; bundleId = 'new-remote-bundle' }
    $local = [pscustomobject]@{ ChatId = 'local_c1'; Activity = 5000 }
    Set-SyncState -State @{}
    Assert ((Get-SyncDivergence -Row $cat0 -LocalChat $null) -eq 'new') 'no local chat: new'
    Assert ((Get-SyncDivergence -Row $cat0 -LocalChat $local) -eq 'diverged') 'a local chat but no sync state: diverged'
    Set-SyncState -State @{ 'claude:local_c1' = @{ lastBundleId = 'old-bundle'; localChatId = 'local_c1'; harness = 'claude'; profileId = 'Default'; localActivityAtSync = 5000 } }
    Assert ((Get-SyncDivergence -Row $cat0 -LocalChat $local) -eq 'update') 'the local chat did not change since the last sync: update'
    Assert ((Get-SyncDivergence -Row $cat0 -LocalChat ([pscustomobject]@{ ChatId = 'local_c1'; Activity = 5001 })) -eq 'diverged') 'the local chat moved on since the last sync: diverged'
    Assert ((Get-SyncDivergence -Row ([pscustomobject]@{ chatKey = 'claude:local_c1'; bundleId = 'old-bundle' }) -LocalChat ([pscustomobject]@{ ChatId = 'local_c1'; Activity = 9999 })) -eq 'same') 'the row is the bundle we last synced: same'
    Assert ((Get-SyncDivergence -Row ([pscustomobject]@{ chatKey = 'claude:other'; bundleId = 'x' }) -LocalChat $local) -eq 'diverged') 'state of another chat does not count'

    # ---------------------------------------------------------------- S8 state file
    $stFile = Join-Path $script:SwitcherHome 'sync-state.json'
    Set-SyncState -State @{ 'k:1' = @{ lastBundleId = 'b'; localChatId = 'c'; harness = 'h'; profileId = 'p'; localActivityAtSync = 7 } }
    $rt = Get-SyncState
    Assert ($rt['k:1'].lastBundleId -eq 'b' -and $rt['k:1'].localActivityAtSync -eq 7) 'state round trip'
    [IO.File]::WriteAllText($stFile, '{broken')
    $w = @(Get-SyncState 3>&1)
    Assert (@($w | Where-Object { $_ -is [Management.Automation.WarningRecord] }).Count -eq 1) 'a damaged state file gives a warning'
    Assert ((Get-SyncState 3>$null).Count -eq 0) 'and an empty state'
    Remove-Item -LiteralPath $stFile
    Assert ((Get-SyncState).Count -eq 0) 'no state file: empty'

    # ---------------------------------------------------------------- S7 cleanup
    Use-Machine $idA 'MACHINE-A'
    Remove-Item -LiteralPath $indexA
    $mineBefore = @(); foreach ($i in 1..5) { $b = New-TestBundle 'local_c9' 'Old chat' (100 * $i); $mineBefore += Push-SyncBundle -Root $drive -BundlePath $b.Path -Key $key -Chat (New-TestChat 'local_c9' 'Old chat' (100 * $i)); Start-Sleep -Milliseconds 15 }
    $other = New-TestBundle 'local_o1' 'Other chat' 50
    $mineBefore += Push-SyncBundle -Root $drive -BundlePath $other.Path -Key $key -Chat (New-TestChat 'local_o1' 'Other chat' 50)
    $indexB = Join-Path $drive "index\$idB.jsonl"
    $shaB = Get-FileSha256Hex $indexB
    $bFiles = @(Get-ChildItem -LiteralPath (Join-Path $drive 'bundles') -Recurse -File | Where-Object { $_.Name -in @(@($row4, $row5) | ForEach-Object { "$($_.bundleId).hbundle.zip.enc" }) })
    Assert ($bFiles.Count -eq 2) 'machine B bundles are on the drive'
    Remove-SyncOldBundles -Root $drive -Keep 3
    $mine = @([IO.File]::ReadAllLines($indexA) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $c9 = @($mine | Where-Object chatKey -eq 'claude:local_c9')
    Assert ($c9.Count -eq 3 -and (($c9 | ForEach-Object lastActivityAt) -join ',') -eq '300,400,500') "the three newest of five are kept, got $(($c9 | ForEach-Object lastActivityAt) -join ',')"
    Assert (@($mine | Where-Object chatKey -eq 'claude:local_o1').Count -eq 1) 'a chat with fewer than three versions is untouched'
    foreach ($r in $mine) { Assert (Test-Path -LiteralPath (Join-Path $drive ($r.path -replace '/', '\'))) "the index still points at an existing file: $($r.path)" }
    foreach ($r in ($mineBefore | Select-Object -First 2)) { Assert (-not (Test-Path -LiteralPath (Join-Path $drive ($r.path -replace '/', '\')))) "the oldest file is deleted: $($r.path)" }
    Assert ((Get-FileSha256Hex $indexB) -eq $shaB -and @(Get-ChildItem -LiteralPath (Join-Path $drive 'bundles') -Recurse -File | Where-Object { $_.Name -in @(@($row4, $row5) | ForEach-Object { "$($_.bundleId).hbundle.zip.enc" }) }).Count -eq 2) 'the other machine index and bundles are untouched'
    Assert ((Get-SidecarFiles).Count -eq 0) 'no tmp files left after cleanup'
    Remove-SyncOldBundles -Root $drive -Keep 3
    Assert (@([IO.File]::ReadAllLines($indexA) | Where-Object { $_ }).Count -eq $mine.Count) 'a second cleanup changes nothing'
    # a row of mine whose path was tampered with must never lead to a delete outside bundles/
    $victim = Join-Path $tmp 'drive\victim.txt'; Set-Content -LiteralPath $victim -Value 'keep me'
    $lines = @([IO.File]::ReadAllLines($indexA) | Where-Object { $_ })
    foreach ($i in 1..4) { $lines += (Copy-Row ($lines[0] | ConvertFrom-Json) @{ bundleId = [guid]::NewGuid().ToString(); lastActivityAt = (10 + $i); path = '../victim.txt' } | ConvertTo-Json -Compress) }
    [IO.File]::WriteAllText($indexA, (($lines -join "`n") + "`n"))
    Remove-SyncOldBundles -Root $drive -Keep 3 3>$null
    Assert (Test-Path -LiteralPath $victim) 'cleanup never deletes outside bundles/'

    # ---------------------------------------------------------------- lineage: a replaced version never wins the catalog
    function Push-Lin($machineId, $machineName, $chatId, $activity, $prev = $null) {
        Use-Machine $machineId $machineName
        $b = New-TestBundle $chatId "Lineage $chatId" $activity
        $a = @{ Root = $drive; BundlePath = $b.Path; Key = $key; Chat = (New-TestChat $chatId "Lineage $chatId" $activity) }
        if ($prev) { $a['PreviousBundleId'] = $prev }
        return (Push-SyncBundle @a)
    }
    $r0 = Push-Lin $idA 'PCA' 'lin1' 100
    $r1 = Push-Lin $idA 'PCA' 'lin1' 1000      # previous = r0 from the state of this machine
    Assert ($r1.previousBundleId -eq $r0.bundleId) 'without -PreviousBundleId the state decides the predecessor'
    $r2 = Push-Lin $idB 'PCB' 'lin1' 900 $r1.bundleId   # B saw A's r1 and replaced it on purpose, with an older activity
    Assert ($r2.previousBundleId -eq $r1.bundleId) '-PreviousBundleId is written into the row'
    $c = @(Get-SyncCatalog -Root $drive -Key $key | Where-Object { $_.chatKey -eq 'claude:lin1' })
    Assert ($c.Count -eq 1 -and $c[0].bundleId -eq $r2.bundleId) "a replaced version loses even with later activity: $($c.bundleId -join ',')"
    # two real heads (both continue r0): the latest activity still wins
    $s0 = Push-Lin $idA 'PCA' 'lin2' 100
    $s1 = Push-Lin $idA 'PCA' 'lin2' 1000
    $s2 = Push-Lin $idB 'PCB' 'lin2' 900 $s0.bundleId
    $c = @(Get-SyncCatalog -Root $drive -Key $key | Where-Object { $_.chatKey -eq 'claude:lin2' })
    Assert ($c.Count -eq 1 -and $c[0].bundleId -eq $s1.bundleId) "two heads: the latest activity wins, got $($c.bundleId -join ',')"
} finally {
    $env:COMPUTERNAME = $savedName
    Remove-TestTempDir $tmp
}

Write-Host 'HarnessSyncStore.Tests: OK'
