# Storage.DriveArchive.ps1 - session archives on Drive, encrypted (phase 6, lane D1).
# An archive zip (made by New-StorageArchive) is encrypted with the sync key (HSE1, Protect-SyncFile) and kept at
#   <SyncRoot>\archives\<machineId>\<harness>\<keySafe>.harchive.zip.enc
# with one index per machine at <SyncRoot>\archives\<machineId>.jsonl. The rules are those of the sync store: one writer
# per file (the machine whose id is in the name), every write through a tmp file and a rename that is read back, and
# everything read from Drive is hostile until checked (machine id, key, path, sha256, numbers). The title in the index is
# encrypted. Nothing here prints a passphrase or a key. Needs Harness.Sync.Crypto/Config/Store.ps1. ASCII only.

$script:StorageDriveKeyPattern = '\A[a-z][a-z0-9]{0,31}:[A-Za-z0-9_.-]{1,128}\z'
$script:StorageDriveGuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Get-StorageDriveRelPath {
    param([Parameter(Mandatory)][string]$MachineId, [Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)][string]$Key)
    return ('archives/{0}/{1}/{2}.harchive.zip.enc' -f $MachineId, $Harness, ($Key -replace ':', '_'))
}

# Root\<relative path>, only for a path of exactly this shape that stays under Root\archives\.
function Resolve-StorageDrivePath {
    param([Parameter(Mandatory)][string]$SyncRoot, [string]$RelPath)
    $shape = '\Aarchives/' + $script:StorageDriveGuid + '/[a-z][a-z0-9]{0,31}/[A-Za-z0-9_.-]{1,170}\.harchive\.zip\.enc\z'
    if ($RelPath -notmatch $shape -or $RelPath.Contains('..')) { throw 'archive-path-invalid' }
    $full = [IO.Path]::GetFullPath((Join-Path $SyncRoot ($RelPath -replace '/', '\')))
    $base = [IO.Path]::GetFullPath((Join-Path $SyncRoot 'archives')).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'archive-path-invalid' }
    return $full
}

# One index row read from Drive. The path must be the one this machine id, harness and key would give.
function Test-StorageDriveRow {
    param($Row, [string]$MachineId)
    if ($Row -isnot [pscustomobject]) { return $false }
    if ([string]$Row.machineId -ne $MachineId) { return $false }
    $key = [string]$Row.key
    if ($key -notmatch $script:StorageDriveKeyPattern -or $key.Contains('..')) { return $false }
    if ([string]$Row.harness -notmatch '\A[a-z][a-z0-9]{0,31}\z' -or $key.Split(':')[0] -ne [string]$Row.harness) { return $false }
    if ([string]$Row.sha256 -notmatch '\A[0-9a-f]{64}\z' -or [string]$Row.zipSha256 -notmatch '\A[0-9a-f]{64}\z') { return $false }
    foreach ($n in 'bytes', 'zipBytes', 'lastActivity') { if (-not (Test-SyncNumber $Row.$n) -or $Row.$n -lt 0) { return $false } }
    if ($Row.titleEnc -isnot [string] -or $Row.archivedAt -isnot [string]) { return $false }
    return ([string]$Row.path -ceq (Get-StorageDriveRelPath -MachineId $MachineId -Harness ([string]$Row.harness) -Key $key))
}

# The valid rows of one machine's index; bad lines are counted in one warning. Callers wrap the call in @(...).
function Read-StorageDriveIndexRows {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$MachineId)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $rows = New-Object Collections.Generic.List[object]
    $bad = New-Object Collections.Generic.List[int]
    $lines = @((Read-SyncAllText -Path $Path) -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].Trim()) { continue }
        $r = $null
        try { $r = $lines[$i] | ConvertFrom-Json } catch { }
        if (Test-StorageDriveRow -Row $r -MachineId $MachineId) { $rows.Add($r) } else { $bad.Add($i + 1) }
    }
    if ($bad.Count) { Write-Warning "Skipped $($bad.Count) bad line(s) in $(Split-Path -Leaf $Path): line $($bad -join ', ')." }
    return $rows.ToArray()
}

# Only the machine that owns a folder writes to it.
function Assert-StorageDriveOwnMachine {
    param([Parameter(Mandatory)][string]$MachineId)
    if ($MachineId -notmatch ('\A' + $script:StorageDriveGuid + '\z')) { throw 'machine-id-invalid' }
    if ($MachineId -ne [string](Get-SyncMachine).Id) { throw 'not-own-machine: archives on Drive are written only by the machine that owns them.' }
}

# Encrypts the zip, writes it under archives\<machine>\, then rewrites this machine's index (one row per key: a newer
# archive of the same session replaces the older row). Entry: Key, Harness, Title, Bytes, ZipBytes, LastActivity.
# Returns the new index row.
function Save-StorageArchiveToDrive {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$SyncRoot,
          [Parameter(Mandatory)][string]$MachineId, [Parameter(Mandatory)][byte[]]$Key)
    Assert-SyncKey $Key
    Assert-StorageDriveOwnMachine -MachineId $MachineId
    $skey = [string]$Entry.Key; $harness = [string]$Entry.Harness
    if ($skey -notmatch $script:StorageDriveKeyPattern -or $skey.Contains('..') -or $skey.Split(':')[0] -ne $harness) { throw "archive-key-invalid: unsafe session key '$skey'" }
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "archive-missing: $ZipPath" }
    $rel = Get-StorageDriveRelPath -MachineId $MachineId -Harness $harness -Key $skey
    $dest = Resolve-StorageDrivePath -SyncRoot $SyncRoot -RelPath $rel
    $work = Join-Path ([IO.Path]::GetTempPath()) ('harness-sync-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $encTmp = Join-Path $work 'out.enc'
        Protect-SyncFile -In $ZipPath -Out $encTmp -Key $Key   # encrypted here, so Drive only ever sees the finished file
        Copy-SyncFileAtomic -Source $encTmp -Path $dest
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    $num = { param($v) $(if (Test-SyncNumber $v) { $v } else { 0 }) }
    $row = [pscustomobject][ordered]@{
        key = $skey; harness = $harness; titleEnc = (Protect-SyncString -Text ([string]$Entry.Title) -Key $Key)
        bytes = (& $num $Entry.Bytes); zipBytes = (& $num $Entry.ZipBytes); lastActivity = (& $num $Entry.LastActivity)
        archivedAt = $(if ($Entry.ArchivedAt) { [string]$Entry.ArchivedAt } else { (Get-Date).ToUniversalTime().ToString('o') })
        machineId = $MachineId; path = $rel; sha256 = (Get-SyncFileSha256 $dest); zipSha256 = (Get-SyncFileSha256 $ZipPath)
    }
    $indexPath = Join-Path $SyncRoot "archives\$MachineId.jsonl"
    $rows = @(@(Read-StorageDriveIndexRows -Path $indexPath -MachineId $MachineId) | Where-Object { [string]$_.key -ne $skey }) + @($row)
    Write-SyncFileAtomic -Path $indexPath -Text (ConvertTo-SyncIndexText -Rows $rows)
    return $row
}

# This machine's archives; with -AllMachines every machine's, read only. Newest first, titles decrypted.
function Get-StorageDriveArchiveIndex {
    param([Parameter(Mandatory)][string]$SyncRoot, [Parameter(Mandatory)][byte[]]$Key, [switch]$AllMachines, [string]$MachineId)
    Assert-SyncKey $Key
    $dir = Join-Path $SyncRoot 'archives'
    $ids = New-Object Collections.Generic.List[string]
    if ($AllMachines) {
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.jsonl')) {
                if ($f.Name -match ('\A(' + $script:StorageDriveGuid + ')\.jsonl\z')) { $ids.Add($Matches[1]) }   # skips tmp files and "name (1).jsonl"
            }
        }
    } else {
        if ($MachineId -and $MachineId -notmatch ('\A' + $script:StorageDriveGuid + '\z')) { throw 'machine-id-invalid' }
        $ids.Add($(if ($MachineId) { $MachineId } else { [string](Get-SyncMachine).Id }))
    }
    $names = Get-SyncMachineNames -Root $SyncRoot
    $out = New-Object Collections.Generic.List[object]
    foreach ($id in $ids) {
        foreach ($r in @(Read-StorageDriveIndexRows -Path (Join-Path $dir "$id.jsonl") -MachineId $id)) {
            $title = [string]$r.key
            try { $title = Unprotect-SyncString -Text $r.titleEnc -Key $Key } catch { }
            $o = [ordered]@{}
            foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value }
            $o['Key'] = $r.key; $o['Harness'] = $r.harness; $o['Bytes'] = $r.bytes
            $o['Title'] = ($title -replace '[\x00-\x1f]', ' ')
            $o['MachineName'] = $(if ($names.ContainsKey($id.ToLowerInvariant())) { $names[$id.ToLowerInvariant()] } else { $id })
            $out.Add([pscustomobject]$o)
        }
    }
    return @($out | Sort-Object { [string]$_.archivedAt } -Descending)
}

# Downloads the archive into a work folder in %TEMP%, checks the sha256 against the row, checks the MAC and decrypts
# into OutDir\<keySafe>.harchive.zip, then checks the plain zip's sha256. Returns the zip path. Whatever goes wrong,
# nothing is left in OutDir.
function Receive-StorageDriveArchive {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$SyncRoot, [Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)][string]$OutDir)
    Assert-SyncKey $Key
    $full = Resolve-StorageDrivePath -SyncRoot $SyncRoot -RelPath ([string]$Entry.path)
    if ([string]$Entry.sha256 -notmatch '\A[0-9a-f]{64}\z') { throw 'archive-path-invalid' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'archive-missing' }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('harness-sync-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $OutDir (([string]$Entry.key -replace ':', '_') + '.harchive.zip')
    try {
        $enc = Join-Path $work 'in.enc'
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            Copy-SyncFileShared -Source $full -Destination $enc
            $ok = ((Get-SyncFileSha256 $enc) -eq [string]$Entry.sha256)
            if (-not $ok -and $try -lt 3) { Start-Sleep -Milliseconds (Get-SyncRetryDelay) }   # Drive may still be updating the file
        }
        if (-not $ok) { throw 'sha-mismatch: the archive on Drive is not the file the index describes.' }
        $plain = Join-Path $work 'plain.zip'
        try { Unprotect-SyncFile -In $enc -Out $plain -Key $Key }
        catch { throw 'wrong-key: the archive could not be decrypted with this key (wrong passphrase, or the file is damaged).' }
        if ([string]$Entry.zipSha256 -match '\A[0-9a-f]{64}\z' -and (Get-SyncFileSha256 $plain) -ne [string]$Entry.zipSha256) { throw 'sha-mismatch: the decrypted zip does not match the index.' }
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        Move-Item -LiteralPath $plain -Destination $zip -Force
        return $zip
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# Deletes one of this machine's archives from Drive: the index is rewritten first, then the file goes, so the index
# never points at a file that is gone.
function Remove-StorageDriveArchive {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$SyncRoot, [Parameter(Mandatory)][string]$MachineId)
    Assert-StorageDriveOwnMachine -MachineId $MachineId
    $file = Resolve-StorageDrivePath -SyncRoot $SyncRoot -RelPath ([string]$Entry.path)
    if (([string]$Entry.path).Split('/')[1] -ne $MachineId) { throw 'not-own-machine: archives on Drive are deleted only by the machine that owns them.' }
    # The path must be the one this entry's own harness and key give, so an entry cannot delete another archive.
    if ([string]$Entry.key -notmatch $script:StorageDriveKeyPattern -or [string]$Entry.harness -notmatch '\A[a-z][a-z0-9]{0,31}\z' -or
        [string]$Entry.path -cne (Get-StorageDriveRelPath -MachineId $MachineId -Harness ([string]$Entry.harness) -Key ([string]$Entry.key))) { throw 'archive-path-invalid' }
    $indexPath = Join-Path $SyncRoot "archives\$MachineId.jsonl"
    $kept = @(@(Read-StorageDriveIndexRows -Path $indexPath -MachineId $MachineId) | Where-Object { [string]$_.key -ne [string]$Entry.key })
    Write-SyncFileAtomic -Path $indexPath -Text (ConvertTo-SyncIndexText -Rows $kept)
    if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
    $d = Split-Path -Parent $file
    if ((Test-Path -LiteralPath $d) -and -not @(Get-ChildItem -LiteralPath $d -Force).Count) { Remove-Item -LiteralPath $d -Force }
}

# For a restore from another machine (Target.PathMap): the folder roots of that machine (machines\<id>.json) matched by name
# with the roots of this one, as @{ '<path there>' = '<path here>' }; roots that are the same or missing on either side are
# left out. Names and paths read from Drive are checked first.
function Get-StorageDrivePathMap {
    param([Parameter(Mandatory)][string]$SyncRoot, [Parameter(Mandatory)][string]$MachineId)
    if ($MachineId -notmatch ('\A' + $script:StorageDriveGuid + '\z')) { throw 'machine-id-invalid' }
    $map = @{}
    $doc = Read-SyncJsonFile (Join-Path $SyncRoot "machines\$MachineId.json")
    if (-not $doc -or $doc.pathRoots -isnot [pscustomobject]) { return $map }
    $here = Get-SyncPathRoots
    foreach ($p in $doc.pathRoots.PSObject.Properties) {
        $there = [string]$p.Value
        if ($p.Name -notmatch '\A[A-Za-z0-9_-]+\z' -or -not (Test-SyncAbsolutePath $there) -or -not $here.ContainsKey($p.Name)) { continue }
        $thereClean = $(if ($there.Length -gt 3) { $there.TrimEnd('\') } else { $there })
        if ($thereClean -ine [string]$here[$p.Name]) { $map[$thereClean] = [string]$here[$p.Name] }
    }
    return $map
}
