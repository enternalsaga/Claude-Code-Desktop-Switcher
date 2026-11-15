$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Import-TestFunctions -Files @((Join-Path $root 'ClaudeSwitcher.ps1')) -Names @('Get-Setting', 'Set-Setting'))
. (Join-Path $root 'src\Harness.Core.ps1')
. (Join-Path $root 'src\Harness.Sync.Crypto.ps1')
. (Join-Path $root 'src\Harness.Sync.Config.ps1')
. (Join-Path $root 'src\Harness.Sync.Store.ps1')
. (Join-Path $root 'src\Storage.DriveArchive.ps1')

# The "Drive" is a folder in %TEMP% named HarnessSync-test; the passphrase is made up and the key derivation is lowered to
# 1000 rounds. Nothing touches a real Drive, a real profile or any session.
$tmp = New-TestTempDir
$savedName = $env:COMPUTERNAME
try {
    $script:ProfileRoot = Join-Path $tmp 'profile'
    $script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
    $script:SwitcherHome = Join-Path $tmp 'profile\.switcher'
    $script:SyncRetryDelayMs = 5
    $drive = Join-Path $tmp 'drive\HarnessSync-test'
    New-Item -ItemType Directory -Path $drive -Force | Out-Null
    $idA = 'aaaaaaaa-0000-4000-8000-000000000001'
    $idB = 'bbbbbbbb-0000-4000-8000-000000000002'
    function Use-Machine($id, $name) { Set-Setting 'Sync.MachineId' $id; $env:COMPUTERNAME = $name }
    $kdf = New-SyncKdf -Passphrase 'test-only fake passphrase' -Iterations 1000
    $key = Get-SyncKey -Passphrase 'test-only fake passphrase' -Kdf $kdf
    $otherKdf = New-SyncKdf -Passphrase 'a different fake passphrase' -Iterations 1000
    $wrongKey = Get-SyncKey -Passphrase 'a different fake passphrase' -Kdf $otherKdf

    # a finished archive zip as A1 makes it (the content is opaque here: made-up bytes)
    function New-FakeZip($name, [int]$size) {
        $p = Join-Path $tmp $name
        $b = New-Object byte[] $size; (New-Object Random 7).NextBytes($b); [IO.File]::WriteAllBytes($p, $b)
        return $p
    }
    $zip1 = New-FakeZip 'one.harchive.zip' 300000
    $entry1 = [pscustomobject]@{ Key = 'claude:11111111-2222-4333-8444-555555555555'; Harness = 'claude'; Title = 'Fix the login redirect'; Bytes = 900000; ZipBytes = 300000; LastActivity = 1760000000000; ArchivedAt = '2026-11-15T10:00:00Z' }

    # ---------------------------------------------------------------- D1-1: save, encrypted
    Use-Machine $idA 'LAPTOP-A'
    $row1 = Save-StorageArchiveToDrive -ZipPath $zip1 -Entry $entry1 -SyncRoot $drive -MachineId $idA -Key $key
    $rel = "archives/$idA/claude/claude_11111111-2222-4333-8444-555555555555.$($row1.archiveId).harchive.zip.enc"
    Assert ([string]$row1.archiveId -match '\A\d{8}T\d{9}\z' -and [string]$row1.path -ceq $rel) "R1-1: the file goes under archives/<machine>/<harness>/<key>.<archiveId>.harchive.zip.enc, got $($row1.path)"
    $enc = Join-Path $drive ($rel -replace '/', '\')
    Assert (Test-Path -LiteralPath $enc -PathType Leaf) 'the .enc file exists on the Drive'
    $head = [IO.File]::ReadAllBytes($enc)[0..3]
    Assert ([Text.Encoding]::ASCII.GetString($head) -eq 'HSE1') 'the file starts with the HSE1 magic'
    Assert ((Get-SyncFileSha256 $enc) -eq [string]$row1.sha256) 'the row holds the sha256 of the .enc file'
    Assert ([string]$row1.zipSha256 -eq (Get-SyncFileSha256 $zip1)) 'the row holds the sha256 of the plain zip'
    $plain = Join-Path $tmp 'plain.zip'
    Unprotect-SyncFile -In $enc -Out $plain -Key $key
    Assert ((Get-SyncFileSha256 $plain) -eq (Get-SyncFileSha256 $zip1)) 'decrypting gives back the same zip, byte for byte'
    $raw = [IO.File]::ReadAllBytes($enc); $needle = [IO.File]::ReadAllBytes($zip1)[100..131]
    $hit = $false; for ($i = 0; $i -lt ($raw.Length - 32) -and -not $hit; $i++) { if ($raw[$i] -eq $needle[0] -and $raw[$i + 1] -eq $needle[1] -and $raw[$i + 2] -eq $needle[2] -and $raw[$i + 3] -eq $needle[3]) { $same = $true; for ($j = 0; $j -lt 32; $j++) { if ($raw[$i + $j] -ne $needle[$j]) { $same = $false; break } }; if ($same) { $hit = $true } } }
    Assert (-not $hit) 'the plain bytes of the zip do not appear in the file on the Drive'
    Assert (@(Get-ChildItem -LiteralPath $drive -Recurse -File | Where-Object { $_.Name -match '\.tmp-' }).Count -eq 0) 'no tmp file is left on the Drive'
    $indexFile = Join-Path $drive "archives\$idA.jsonl"
    Assert (Test-Path -LiteralPath $indexFile) 'this machine has an index file archives/<machine>.jsonl'
    $indexText = [IO.File]::ReadAllText($indexFile)
    Assert ($indexText -notmatch 'Fix the login redirect') 'the title is not readable in the index file'
    Assert ($indexText -match 'titleEnc') 'the title is stored encrypted'

    # a second archive and a re-archive of the same key (R1-1: the older archive is kept, both are listed)
    $zip2 = New-FakeZip 'two.harchive.zip' 120000
    $entry2 = [pscustomobject]@{ Key = 'codex:019a0000-aaaa-7bbb-8ccc-ddddeeeeffff'; Harness = 'codex'; Title = 'Parser bug'; Bytes = 400000; ZipBytes = 120000; LastActivity = 1760000100000; ArchivedAt = '2026-11-15T11:00:00Z' }
    $row2 = Save-StorageArchiveToDrive -ZipPath $zip2 -Entry $entry2 -SyncRoot $drive -MachineId $idA -Key $key
    $zip1b = New-FakeZip 'one-b.harchive.zip' 50000
    Start-Sleep -Milliseconds 20
    $entry1b = $entry1.PSObject.Copy(); $entry1b.ArchivedAt = '2026-11-15T10:30:00Z'
    $row1b = Save-StorageArchiveToDrive -ZipPath $zip1b -Entry $entry1b -SyncRoot $drive -MachineId $idA -Key $key
    $idx = @(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key)
    Assert ($idx.Count -eq 3) "R1-1: a re-archive of the same key adds a row, got $($idx.Count)"
    Assert ([string]$row1b.path -cne [string]$row1.path -and (Get-SyncFileSha256 (Join-Path $drive ($rel -replace '/', '\'))) -eq [string]$row1.sha256 -and (Get-SyncFileSha256 (Join-Path $drive ([string]$row1b.path -replace '/', '\'))) -eq [string]$row1b.sha256) 'R1-1: both files are on the Drive, the older one unchanged'
    $legacy = $row1.PSObject.Copy(); $legacy.PSObject.Properties.Remove('archiveId'); $legacy.path = 'archives/' + $idA + '/claude/claude_11111111-2222-4333-8444-555555555555.harchive.zip.enc'
    Assert ((Test-StorageDriveRow -Row $legacy -MachineId $idA) -eq $true) 'R1-1: a row of the old shape (no archiveId, key-only file name) is still valid'
    $badId = $row1.PSObject.Copy(); $badId.archiveId = '..\x'
    Assert ((Test-StorageDriveRow -Row $badId -MachineId $idA) -eq $false) 'an archiveId of another shape is not valid'

    # R1-8: a line this code does not understand survives the next save and the next remove
    $aIdxFile = Join-Path $drive "archives\$idA.jsonl"
    [IO.File]::AppendAllText($aIdxFile, '{"key":"claude:future","newer":"app version"}' + "`n")
    $zip9 = New-FakeZip 'nine.harchive.zip' 30000
    $e9 = [pscustomobject]@{ Key = 'claude:99999999-2222-4333-8444-555555555555'; Harness = 'claude'; Title = 'Nine'; Bytes = 1; ZipBytes = 30000; LastActivity = 1; ArchivedAt = '2026-11-15T09:00:00Z' }
    $row9 = Save-StorageArchiveToDrive -ZipPath $zip9 -Entry $e9 -SyncRoot $drive -MachineId $idA -Key $key
    Assert ([IO.File]::ReadAllText($aIdxFile).Contains('"key":"claude:future","newer":"app version"')) 'R1-8: an unknown line is kept by Save'
    Remove-StorageDriveArchive -Entry $row9 -SyncRoot $drive -MachineId $idA
    Assert ([IO.File]::ReadAllText($aIdxFile).Contains('"key":"claude:future","newer":"app version"') -and @(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key -WarningAction SilentlyContinue).Count -eq 3) 'R1-8: and by Remove, which takes only its own row'
    Assert (Test-Path -LiteralPath (Join-Path $drive ($rel -replace '/', '\'))) 'removing one archive of a key leaves the other archives of that key'

    # bad input never writes
    Assert-Throws { Save-StorageArchiveToDrive -ZipPath $zip1 -Entry ([pscustomobject]@{ Key = 'claude:..\..\evil'; Harness = 'claude'; Title = 'x' }) -SyncRoot $drive -MachineId $idA -Key $key } 'an unsafe key is refused'
    Assert-Throws { Save-StorageArchiveToDrive -ZipPath $zip1 -Entry ([pscustomobject]@{ Key = 'codex:abc'; Harness = 'claude'; Title = 'x' }) -SyncRoot $drive -MachineId $idA -Key $key } 'a harness that does not match the key is refused'
    Assert-Throws { Save-StorageArchiveToDrive -ZipPath (Join-Path $tmp 'nope.zip') -Entry $entry1 -SyncRoot $drive -MachineId $idA -Key $key } 'a missing zip is refused'
    Assert-Throws { Save-StorageArchiveToDrive -ZipPath $zip1 -Entry $entry1 -SyncRoot $drive -MachineId $idA -Key ([byte[]](1..10)) } 'a key of the wrong size is refused'
    Assert (@(Get-ChildItem -LiteralPath $drive -Recurse -File | Where-Object { $_.Name -match '\.tmp-' }).Count -eq 0) 'refused saves leave no tmp file'

    # ---------------------------------------------------------------- D1-2: the index, per machine
    $a = @($idx | Where-Object { $_.Key -eq $entry1.Key })[0]; $enc = Join-Path $drive ([string]$a.path -replace '/', '\')
    Assert ($a.Title -eq 'Fix the login redirect' -and $a.Harness -eq 'claude' -and $a.Bytes -eq 900000 -and $a.machineId -eq $idA) 'the index decrypts the title and keeps the fields'
    Assert ($a.MachineName -eq $idA -or $a.MachineName -eq 'LAPTOP-A') 'a machine name or its id is given'
    Assert ($idx[0].Key -eq $entry2.Key) 'newest first'

    Use-Machine $idB 'DESKTOP-B'
    Assert (@(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key).Count -eq 0) 'machine B alone has no archives'
    $all = @(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key -AllMachines)
    Assert ($all.Count -eq 3 -and ($all | Where-Object { $_.machineId -ne $idA }).Count -eq 0) 'machine B reads the index of machine A with -AllMachines'
    Assert-Throws { Save-StorageArchiveToDrive -ZipPath $zip1 -Entry $entry1 -SyncRoot $drive -MachineId $idA -Key $key } 'machine B cannot write into the folder of machine A'
    Assert-Throws { Remove-StorageDriveArchive -Entry $a -SyncRoot $drive -MachineId $idA } 'machine B cannot delete from machine A'
    Assert (Test-Path -LiteralPath $enc) 'machine A files are untouched by the refused writes'
    $zipB = New-FakeZip 'b.harchive.zip' 20000
    $entryB = [pscustomobject]@{ Key = 'agy:7e7e7e7e-0000-4000-8000-123412341234'; Harness = 'agy'; Title = 'Landing page'; Bytes = 70000; ZipBytes = 20000; LastActivity = 1760000200000; ArchivedAt = '2026-11-15T12:00:00Z' }
    [void](Save-StorageArchiveToDrive -ZipPath $zipB -Entry $entryB -SyncRoot $drive -MachineId $idB -Key $key)
    Assert (@(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key).Count -eq 1) 'machine B alone lists only its own'
    Assert (@(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key -AllMachines).Count -eq 4) 'all machines list four'
    Assert (Test-Path -LiteralPath (Join-Path $drive "archives\$idB\agy")) 'machine B writes in its own folder'
    Assert-Throws { Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key -MachineId '..\x' } 'a -MachineId that is not a GUID is refused'
    Assert (@(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key -MachineId $idA).Count -eq 3) 'a GUID -MachineId reads that machine'

    # hostile or damaged lines are skipped with a warning, the rest is listed
    $bIndex = Join-Path $drive "archives\$idB.jsonl"
    $good = [IO.File]::ReadAllText($bIndex)
    $evil = '{"key":"claude:x","harness":"claude","titleEnc":"AAAA","bytes":1,"zipBytes":1,"lastActivity":1,"archivedAt":"2026-11-15T12:00:00Z","machineId":"' + $idB + '","path":"archives/' + $idB + '/../../sync.json","sha256":"' + ('a' * 64) + '","zipSha256":"' + ('b' * 64) + '"}'
    [IO.File]::WriteAllText($bIndex, ($good + $evil + "`nnot json`n"))
    $warn = $null
    $rows = @(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key -WarningVariable warn -WarningAction SilentlyContinue)
    Assert ($rows.Count -eq 1 -and $warn) 'a path that climbs out and a non-JSON line are skipped with a warning'
    [IO.File]::WriteAllText($bIndex, $good)

    # a row that claims another machine inside machine A's file is not trusted
    $aIndex = Join-Path $drive "archives\$idA.jsonl"
    $aGood = [IO.File]::ReadAllText($aIndex)
    $forged = ($aGood -split "`n")[0] -replace $idA, $idB
    [IO.File]::WriteAllText($aIndex, ($aGood + $forged + "`n"))
    Assert (@(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key -AllMachines).Count -eq 4) 'a row naming another machine in this file is skipped'
    [IO.File]::WriteAllText($aIndex, $aGood)

    # ---------------------------------------------------------------- D1-3: receive
    $out = Join-Path $tmp 'received'
    $got = Receive-StorageDriveArchive -Entry $a -SyncRoot $drive -Key $key -OutDir $out
    Assert ($got -is [string] -and (Test-Path -LiteralPath $got -PathType Leaf) -and (Split-Path -Parent $got) -eq $out) 'the zip is in OutDir'
    Assert ((Get-SyncFileSha256 $got) -eq (Get-SyncFileSha256 $zip1b)) 'the received zip is the archived one'
    Assert (@(Get-ChildItem -LiteralPath $out).Count -eq 1) 'only the zip is in OutDir'
    $out2 = Join-Path $tmp 'received-wrong'
    $msg = $null; try { [void](Receive-StorageDriveArchive -Entry $a -SyncRoot $drive -Key $wrongKey -OutDir $out2) } catch { $msg = $_.Exception.Message }
    Assert ($msg -and $msg -match 'key') "a wrong key gives a clear error, got: $msg"
    Assert (-not (Test-Path -LiteralPath $out2) -or @(Get-ChildItem -LiteralPath $out2 -Force).Count -eq 0) 'a wrong key leaves no file behind'
    # sha of the .enc does not match the row (Drive handed back something else)
    $tampered = $a.PSObject.Copy(); $tampered.sha256 = ('0' * 64)
    $out3 = Join-Path $tmp 'received-sha'
    $msg = $null; try { [void](Receive-StorageDriveArchive -Entry $tampered -SyncRoot $drive -Key $key -OutDir $out3) } catch { $msg = $_.Exception.Message }
    Assert ($msg -match 'sha') "a changed file is refused: $msg"
    Assert (-not (Test-Path -LiteralPath $out3) -or @(Get-ChildItem -LiteralPath $out3 -Force).Count -eq 0) 'a refused download leaves no file'
    # a damaged .enc: one byte flipped on the Drive and the row updated to match: the MAC still stops it
    $copy = Join-Path $tmp 'damaged.enc'; Copy-Item -LiteralPath $enc -Destination $copy
    $bytes = [IO.File]::ReadAllBytes($copy); $bytes[200] = $bytes[200] -bxor 1; [IO.File]::WriteAllBytes($copy, $bytes)
    $savedEnc = [IO.File]::ReadAllBytes($enc); [IO.File]::WriteAllBytes($enc, $bytes)
    $dmg = $a.PSObject.Copy(); $dmg.sha256 = (Get-SyncFileSha256 $enc)
    $out4 = Join-Path $tmp 'received-dmg'
    Assert-Throws { [void](Receive-StorageDriveArchive -Entry $dmg -SyncRoot $drive -Key $key -OutDir $out4) } 'a damaged archive is refused by its MAC'
    Assert (-not (Test-Path -LiteralPath $out4) -or @(Get-ChildItem -LiteralPath $out4 -Force).Count -eq 0) 'a damaged archive leaves no file'
    [IO.File]::WriteAllBytes($enc, $savedEnc)
    # a path from the row that climbs out of archives\ is refused before any read
    $evilRow = $a.PSObject.Copy(); $evilRow.path = "archives/$idA/../../sync.json"
    Assert-Throws { [void](Receive-StorageDriveArchive -Entry $evilRow -SyncRoot $drive -Key $key -OutDir (Join-Path $tmp 'received-evil')) } 'a row path that climbs out of archives is refused'
    # R1-9: the zip name comes from the key, so a key that is not this path's key is refused and nothing is written outside OutDir
    $evilKey = $a.PSObject.Copy(); $evilKey.key = 'x:..\..\evil'
    $outK = Join-Path $tmp 'received-key'
    Assert-Throws { [void](Receive-StorageDriveArchive -Entry $evilKey -SyncRoot $drive -Key $key -OutDir $outK) } 'R1-9: a key that climbs out is refused'
    $otherKey = $a.PSObject.Copy(); $otherKey.key = 'claude:aaaaaaaa-2222-4333-8444-555555555555'
    Assert-Throws { [void](Receive-StorageDriveArchive -Entry $otherKey -SyncRoot $drive -Key $key -OutDir $outK) } 'R1-9: a key that does not match the path is refused'
    Assert (-not (Test-Path -LiteralPath $outK) -and -not (Test-Path (Join-Path $tmp 'evil.harchive.zip'))) 'and nothing was written'
    # the temp area is cleaned after a good receive
    $leftovers = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'harness-sync-*' -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-5) })
    Assert ($leftovers.Count -eq 0) 'no harness-sync-* work folder is left in %TEMP%'

    # ---------------------------------------------------------------- delete from the Drive (own archives only)
    Use-Machine $idA 'LAPTOP-A'
    # an Entry whose key says one session but whose path names another archive of this machine must not delete that one
    $mixed = $a.PSObject.Copy(); $mixed.path = [string]$row2.path
    Assert-Throws { Remove-StorageDriveArchive -Entry $mixed -SyncRoot $drive -MachineId $idA } 'an Entry whose path does not match its own harness and key is refused'
    Assert ((Test-Path -LiteralPath (Join-Path $drive ($mixed.path -replace '/', '\'))) -and @(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key).Count -eq 3) 'the refused delete changed nothing'
    $b1 = @(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key | Where-Object { $_.Key -eq $entry2.Key })[0]
    Remove-StorageDriveArchive -Entry $b1 -SyncRoot $drive -MachineId $idA
    Assert (@(Get-StorageDriveArchiveIndex -SyncRoot $drive -Key $key).Count -eq 2) 'the row is gone'
    Assert (-not (Test-Path -LiteralPath (Join-Path $drive ([string]$b1.path -replace '/', '\')))) 'the file is gone'

    # ---------------------------------------------------------------- D1-4: path map for a restore from another machine
    Set-Content -LiteralPath (Join-Path $drive 'x.tmp') -Value 'x'; Remove-Item -LiteralPath (Join-Path $drive 'x.tmp')
    New-Item -ItemType Directory -Path (Join-Path $drive 'machines') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $drive "machines\$idB.json"), (@{ name = 'DESKTOP-B'; pathRoots = @{ Work = 'E:\Code'; Notes = 'F:\Notes'; Only = 'G:\Only'; Evil = 'E:\..\x'; 'bad name' = 'E:\x' } } | ConvertTo-Json -Depth 4))
    Set-Setting 'Sync.PathRoots' ([pscustomobject]@{ Work = 'D:\Work'; Notes = 'F:\Notes' })
    $map = Get-StorageDrivePathMap -SyncRoot $drive -MachineId $idB
    Assert ($map -is [hashtable] -and $map.Count -eq 1 -and $map['E:\Code'] -eq 'D:\Work') "the map holds the other machine's root -> this machine's root only where they differ: $($map.Keys -join ',')"
    Assert ((Get-StorageDrivePathMap -SyncRoot $drive -MachineId 'cccccccc-0000-4000-8000-000000000003').Count -eq 0) 'an unknown machine gives an empty map'
    Assert-Throws { Get-StorageDrivePathMap -SyncRoot $drive -MachineId '..\x' } 'a machine id that is not a GUID is refused'
}
finally {
    $env:COMPUTERNAME = $savedName
    Remove-TestTempDir $tmp
}
Write-Output 'PASS: Storage.DriveArchive - encrypted save, per-machine index, receive with sha and MAC checks, delete, path map.'
