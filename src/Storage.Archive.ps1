# Storage.Archive.ps1 - archive a session into a zip, check it, put it in the store, remove the original, restore it
# (phase 6, lane A1). Needs Storage.Guard.ps1, Storage.Scan.ps1 (Get-StorageFilesRecursive), Storage.Harness.ps1 (what removing
# a session means per harness), Harness.Claude.ps1 (ConvertTo-ClaudeProjectSlug) and, for a Drive store, Storage.DriveArchive.ps1.
# Nothing is removed before the zip has been read back and its sha256 matches both inside (every file) and outside (the
# file in the store). Everything read from a zip is hostile until checked. ASCII only.
#
# Roots is the table of the inventory: @{ ClaudeProjects; ClaudeProfiles = @(@{Id;Name;SessionRoot;DataDir;IsDefault});
#   CodexHomes = @(@{Id;Name;Home}); AgyDirs }. A Target is @{ Kind = 'local'; Path; PathMap } or
#   @{ Kind = 'drive'; SyncRoot; MachineId; Key = <sync key bytes>; PathMap }.

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-StorageArchiveLimits {
    return @{ MaxBytes = [long]4GB; MaxEntries = 20000; MaxManifestBytes = 1MB }
}

function Get-StorageKeySafe {
    param([Parameter(Mandatory)][string]$Key)
    return ($Key -replace ':', '_')
}

function Get-StorageFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}

# Where a file sits relative to the root it is restored under (a project, a profile's chat folder, CODEX_HOME\sessions).
function Get-StoragePartRel {
    param([Parameter(Mandatory)]$Part, [Parameter(Mandatory)][string]$FilePath)
    switch ([string]$Part.Role) {
        'transcript' { return ((Split-Path -Leaf (Split-Path -Parent $FilePath)) + '\' + (Split-Path -Leaf $FilePath)) }
        'cli-dir' {
            $dir = ([string]$Part.Path).TrimEnd('\')
            $head = (Split-Path -Leaf (Split-Path -Parent $dir)) + '\' + (Split-Path -Leaf $dir)
            return ($head + $FilePath.Substring($dir.Length))
        }
        'profile-meta' { if ($FilePath -match '\\claude-code-sessions\\(.+)\z') { return $Matches[1] }; throw "archive-source-invalid: not a chat file of a profile: $FilePath" }
        'rollout' { if ($FilePath -match '\\(sessions\\\d{4}\\\d{2}\\\d{2}\\[^\\]+|archived_sessions\\[^\\]+)\z') { return $Matches[1] }; throw "archive-source-invalid: not a rollout under sessions: $FilePath" }
        default { throw "archive-source-invalid: unknown part '$($Part.Role)'" }
    }
}

# The files of a session as @{ Part; Path; Rel; Size}. A part that is gone means the session changed since the scan.
function Get-StorageArchiveFiles {
    param([Parameter(Mandatory)]$Session)
    $list = New-Object Collections.Generic.List[object]
    foreach ($p in $Session.Parts) {
        if ($p.Kind -eq 'row') { continue }
        $files = @()
        if ($p.Kind -eq 'dir') {
            if (-not [IO.Directory]::Exists([string]$p.Path)) { throw "archive-source-missing: the folder is gone: $($p.Path)" }
            $files = @(Get-StorageFilesRecursive -Path ([string]$p.Path))
        } else {
            if (-not [IO.File]::Exists([string]$p.Path)) { throw "archive-source-missing: the file is gone: $($p.Path)" }
            $files = @(New-Object IO.FileInfo ([string]$p.Path))
        }
        foreach ($f in $files) { $list.Add(@{ Part = $p; Path = $f.FullName; Rel = (Get-StoragePartRel -Part $p -FilePath $f.FullName); Size = [long]$f.Length; MTimeTicks = [long]$f.LastWriteTimeUtc.Ticks }) }
    }
    return $list.ToArray()
}

function Get-StorageArchiveRestoreInfo {
    param([Parameter(Mandatory)]$Session)
    $names = @{}; foreach ($p in $Session.Profiles) { $names[[string]$p.Id] = [string]$p.Name }
    $profiles = @($Session.Profiles | ForEach-Object { @{ profileId = [string]$_.Id; name = [string]$_.Name } })
    switch ($Session.Harness) {
        'claude' { return @{ claude = @{ profiles = $profiles } } }
        'codex' { return @{ codex = @{ profileId = $(if ($profiles.Count) { $profiles[0].profileId } else { '' }); threadsRow = @{ id = [string]$Session.Id; title = [string]$Session.Title; cwd = [string]$Session.Cwd; lastActivity = $Session.LastActivity; created = $Session.Created; archived = [bool]$Session.Flags.CodexArchived } } } }
        default { throw "archive-unsupported: $($Session.Harness) sessions cannot be archived yet." }
    }
}

# Builds <OutDir>\<keySafe>.harchive.zip (files/0001.. plus archive.json), reads it back, and only then gives it its name.
# Changes nothing it archives. Returns ZipPath, Sha256 (of the whole zip) and Manifest. -MaxBytes and -MaxEntries are
# raised or lowered by tests only.
function New-StorageArchive {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$OutDir, [string]$MachineId = '',
          [long]$MaxBytes = (Get-StorageArchiveLimits).MaxBytes, [int]$MaxEntries = (Get-StorageArchiveLimits).MaxEntries)
    $restore = Get-StorageArchiveRestoreInfo -Session $Session
    $files = @(Get-StorageArchiveFiles -Session $Session)
    $total = [long]0; foreach ($f in $files) { $total += $f.Size }
    if ($total -gt $MaxBytes) { throw ('archive-too-large: {0:N1} GB is over the {1:N1} GB limit for one archive.' -f ($total / 1GB), ($MaxBytes / 1GB)) }
    if ($files.Count -gt $MaxEntries) { throw "archive-too-large: $($files.Count) files is over the limit of $MaxEntries for one archive." }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $final = Join-Path $OutDir ((Get-StorageKeySafe $Session.Key) + '.harchive.zip')
    $tmp = $final + '.tmp-' + [guid]::NewGuid().ToString('N')
    $parts = New-Object Collections.Generic.List[object]
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::Open($tmp, [IO.Compression.ZipArchiveMode]::Create)
        $n = 0
        foreach ($f in $files) {
            $n++; $name = 'files/{0:0000}' -f $n
            $sha = [Security.Cryptography.SHA256]::Create()
            $src = [IO.File]::Open($f.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $dst = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Fastest).Open()
            try {
                $buf = New-Object byte[] 81920; $size = [long]0
                while (($r = $src.Read($buf, 0, $buf.Length)) -gt 0) { [void]$sha.TransformBlock($buf, 0, $r, $null, 0); $dst.Write($buf, 0, $r); $size += $r }
                [void]$sha.TransformFinalBlock($buf, 0, 0)
            } finally { $dst.Dispose(); $src.Dispose() }
            $parts.Add([ordered]@{ role = [string]$f.Part.Role; originalPath = $f.Path; rel = $f.Rel; entry = $name; size = $size; sha256 = (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''); kind = 'file'; profileId = [string]$f.Part.ProfileId; mtimeUtcTicks = $f.MTimeTicks })
            $sha.Dispose()
        }
        $manifest = [ordered]@{ format = 'harness-archive'; version = 1; key = [string]$Session.Key; harness = [string]$Session.Harness; id = [string]$Session.Id; title = [string]$Session.Title
            cwd = [string]$Session.Cwd; lastActivity = $Session.LastActivity; archivedAt = (Get-Date).ToUniversalTime().ToString('o'); machineId = $MachineId; parts = @($parts.ToArray()); restore = $restore }
        $w = New-Object IO.StreamWriter($zip.CreateEntry('archive.json').Open(), (New-Object Text.UTF8Encoding($false)))
        try { $w.Write(($manifest | ConvertTo-Json -Depth 10)) } finally { $w.Dispose() }
        $zip.Dispose(); $zip = $null
        $check = Read-StorageArchive -ZipPath $tmp
        if (-not $check.Verified) { throw "archive-verify-failed: the new archive does not read back correctly ($($check.Reason))." }
        if ([IO.File]::Exists($final)) { [IO.File]::Delete($final) }
        [IO.File]::Move($tmp, $final)
        return @{ ZipPath = $final; Sha256 = (Get-StorageFileSha256 $final); Manifest = $check.Manifest }
    } finally {
        if ($zip) { $zip.Dispose() }
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

# Opens a zip and checks it against its own archive.json: format, limits, every entry listed and no other, sizes and
# sha256 of every file. Never throws for a bad archive: Verified is $false and Reason says why.
function Read-StorageArchive {
    param([Parameter(Mandatory)][string]$ZipPath)
    $lim = Get-StorageArchiveLimits
    $fail = { param($why) @{ Manifest = $null; Verified = $false; Reason = $why } }
    if (-not [IO.File]::Exists($ZipPath)) { return (& $fail 'the archive file is missing') }
    $zip = $null
    try {
        try { $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath) } catch { return (& $fail 'not a valid zip file') }
        if ($zip.Entries.Count -gt ($lim.MaxEntries + 1)) { return (& $fail 'too many entries') }
        $me = $zip.GetEntry('archive.json')
        if (-not $me -or $me.Length -gt $lim.MaxManifestBytes) { return (& $fail 'archive.json is missing or too large') }
        $r = New-Object IO.StreamReader($me.Open(), (New-Object Text.UTF8Encoding($false)))
        try { $m = $r.ReadToEnd() | ConvertFrom-Json } finally { $r.Dispose() }
        if ($m.format -ne 'harness-archive' -or $m.version -ne 1 -or $m.parts -isnot [array]) { return (& $fail 'not a harness archive') }
        if ([string]$m.key -notmatch '\A[a-z][a-z0-9]{0,31}:[A-Za-z0-9_.-]{1,128}\z') { return (& $fail 'the session key is not valid') }
        $listed = @{}; $declared = [long]0
        foreach ($p in $m.parts) {
            if ([string]$p.entry -notmatch '\Afiles/\d{1,6}\z' -or [string]$p.sha256 -notmatch '\A[0-9a-f]{64}\z' -or $p.size -isnot [ValueType] -or $p.size -lt 0 -or $listed.ContainsKey([string]$p.entry)) { return (& $fail 'a part of the manifest is not valid') }
            $listed[[string]$p.entry] = $true; $declared += [long]$p.size
        }
        if ($declared -gt $lim.MaxBytes) { return (& $fail 'larger than the limit for one archive') }
        foreach ($e in $zip.Entries) { if ($e.FullName -ne 'archive.json' -and -not $listed.ContainsKey($e.FullName)) { return (& $fail "an entry the manifest does not list: $($e.FullName)") } }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            foreach ($p in $m.parts) {
                $e = $zip.GetEntry([string]$p.entry)
                if (-not $e) { return (& $fail "entry missing: $($p.entry)") }
                if ($e.Length -ne [long]$p.size) { return (& $fail "size differs: $($p.entry)") }
                $s = $e.Open()
                try { $h = (($sha.ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $s.Dispose() }
                if ($h -ne [string]$p.sha256) { return (& $fail "sha256 differs: $($p.entry)") }
            }
        } finally { $sha.Dispose() }
        return @{ Manifest = $m; Verified = $true; Reason = '' }
    } catch { return (& $fail "the archive could not be read: $($_.Exception.Message)") } finally { if ($zip) { $zip.Dispose() } }
}

# ---- the local store index ---------------------------------------------------------------------------------------------

function Write-StorageTextAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { $old = $tmp + '.old'; [IO.File]::Replace($tmp, $Path, $old); if ([IO.File]::Exists($old)) { [IO.File]::Delete($old) } } else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function Read-StorageLocalIndex {
    param([Parameter(Mandatory)][string]$Path)
    $rows = New-Object Collections.Generic.List[object]
    if (-not [IO.File]::Exists($Path)) { return $rows.ToArray() }
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        try {
            $r = $line | ConvertFrom-Json
            if ($r -isnot [pscustomobject] -or [string]$r.key -notmatch '\A[a-z][a-z0-9]{0,31}:[A-Za-z0-9_.-]{1,128}\z') { throw 'not a row' }
            $rows.Add($r)
        } catch { Write-Warning 'A line of the archive index is damaged and was skipped.' }
    }
    return $rows.ToArray()
}

# The archives of a store, newest first. Local: archive-index.jsonl in the store folder. Drive: this machine's index (or all
# machines' with -AllMachines) through Storage.DriveArchive.ps1.
function Get-StorageArchiveIndex {
    param([Parameter(Mandatory)]$Target, [switch]$AllMachines)
    if ($Target.Kind -eq 'drive') { return @(Get-StorageDriveArchiveIndex -SyncRoot $Target.SyncRoot -Key $Target.Key -MachineId $Target.MachineId -AllMachines:$AllMachines) }
    $rows = @(Read-StorageLocalIndex -Path (Join-Path $Target.Path 'archive-index.jsonl'))
    return @($rows | Sort-Object { [string]$_.archivedAt } -Descending)
}

# One row per session key: a newer archive of the same session replaces the older row.
function Add-StorageArchiveIndex {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Row)
    $path = Join-Path $Target.Path 'archive-index.jsonl'
    $rows = @(@(Read-StorageLocalIndex -Path $path) | Where-Object { [string]$_.key -ne [string]$Row.key }) + @($Row)
    Write-StorageTextAtomic -Path $path -Text ((@($rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "`n") + "`n")
}

function Remove-StorageArchiveIndex {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Key)
    $path = Join-Path $Target.Path 'archive-index.jsonl'
    $all = @(Read-StorageLocalIndex -Path $path)
    $rows = @($all | Where-Object { [string]$_.key -ne $Key })
    if ($rows.Count -eq $all.Count) { return }
    Write-StorageTextAtomic -Path $path -Text $(if ($rows.Count) { (@($rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "`n") + "`n" } else { '' })
}

# ---- archive ----------------------------------------------------------------------------------------------------------

# Copies the zip into <store>\<harness>\<yyyy-MM>\ through a tmp file whose sha256 is checked before it gets its name.
function Copy-StorageArchiveToStore {
    param([Parameter(Mandatory)]$Archive, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$StorePath)
    $sub = Join-Path ([string]$Session.Harness) (Get-Date -Format 'yyyy-MM')
    $dir = Join-Path $StorePath $sub
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $name = (Get-StorageKeySafe $Session.Key) + '.harchive.zip'
    $final = Join-Path $dir $name; $tmp = $final + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($Archive.ZipPath, $tmp)
        if ((Get-StorageFileSha256 $tmp) -ne $Archive.Sha256) { throw 'store-verify-failed: the copy in the store is not the archive that was built.' }
        if ([IO.File]::Exists($final)) { [IO.File]::Delete($final) }
        [IO.File]::Move($tmp, $final)
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
    return @{ Path = $final; Entry = ((([string]$Session.Harness) + '/' + (Get-Date -Format 'yyyy-MM') + '/' + $name)) }
}

# Sends the zip to Drive, then fetches it back (sha of the .enc, MAC, sha of the zip), reads the zip and compares the whole file
# with what was built. When that fails the row and file on Drive are removed again and this throws.
function Save-StorageArchiveToDriveChecked {
    param([Parameter(Mandatory)]$Archive, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$WorkDir, [scriptblock]$OnPlaced)
    $entry = @{ Key = $Session.Key; Harness = $Session.Harness; Title = $Session.Title; Bytes = $Session.Bytes; ZipBytes = (Get-Item -LiteralPath $Archive.ZipPath).Length; LastActivity = $Session.LastActivity }
    $row = Save-StorageArchiveToDrive -ZipPath $Archive.ZipPath -Entry $entry -SyncRoot $Target.SyncRoot -MachineId $Target.MachineId -Key $Target.Key
    $recv = Join-Path $WorkDir ('recv-' + [guid]::NewGuid().ToString('N'))
    try {
        if ($OnPlaced) { & $OnPlaced (Join-Path $Target.SyncRoot (([string]$row.path) -replace '/', '\')) }
        $got = Receive-StorageDriveArchive -Entry $row -SyncRoot $Target.SyncRoot -Key $Target.Key -OutDir $recv
        $again = Read-StorageArchive -ZipPath $got
        if (-not $again.Verified -or (Get-StorageFileSha256 $got) -ne $Archive.Sha256) { throw "store-verify-failed: the copy on Drive does not verify ($($again.Reason))." }
    } catch {
        $why = $_.Exception.Message
        try { Remove-StorageDriveArchive -Entry $row -SyncRoot $Target.SyncRoot -MachineId $Target.MachineId } catch { $why += ' (the damaged copy on Drive could not be removed)' }
        throw $(if ($why -like 'store-verify-failed*') { $why } else { "store-verify-failed: the copy on Drive could not be read back ($why)" })
    } finally { if ([IO.Directory]::Exists($recv)) { Remove-Item -LiteralPath $recv -Recurse -Force -ErrorAction SilentlyContinue } }
    return [string]$row.path
}

# One session: guard, build, check, store, check the stored copy, index, and only then remove the original. Returns
# @{ Key; Ok; Skipped; Reason; ZipPath; Warnings }.
function Invoke-StorageArchiveOne {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Roots, [string]$MachineId, [string]$WorkDir, $Guard, [scriptblock]$CodexRpc,
          [scriptblock]$OnZipBuilt, [scriptblock]$OnPlaced, [switch]$RecycleOriginals, [scriptblock]$Recycler)
    $res = @{ Key = [string]$Session.Key; Ok = $false; Skipped = $false; Reason = ''; ZipPath = $null; Warnings = @() }
    $safe = Test-StorageSessionSafe -Session $Session @Guard
    if (-not $safe.Safe) { $res.Skipped = $true; $res.Reason = $safe.Reason; return $res }
    if ($Session.Harness -notin 'claude', 'codex') { $res.Reason = "$($Session.Harness) sessions cannot be archived yet (Antigravity waits for spike S17)."; $res.Reason = $res.Reason.Replace('antigravity', 'Antigravity'); return $res }
    $a = $null; $placed = $null
    try {
        $a = New-StorageArchive -Session $Session -OutDir $WorkDir -MachineId $MachineId
        if ($OnZipBuilt) { & $OnZipBuilt $a.ZipPath }
        if ($Target.Kind -eq 'drive') {
            $res.ZipPath = Save-StorageArchiveToDriveChecked -Archive $a -Session $Session -Target $Target -WorkDir $WorkDir -OnPlaced $OnPlaced
        } else {
            $placed = Copy-StorageArchiveToStore -Archive $a -Session $Session -StorePath $Target.Path
            if ($OnPlaced) { & $OnPlaced $placed.Path }
            $again = Read-StorageArchive -ZipPath $placed.Path
            if (-not $again.Verified -or (Get-StorageFileSha256 $placed.Path) -ne $a.Sha256) { throw "store-verify-failed: the stored archive does not verify ($($again.Reason))." }
            Add-StorageArchiveIndex -Target $Target -Row ([pscustomobject][ordered]@{ key = [string]$Session.Key; harness = [string]$Session.Harness; title = [string]$Session.Title; bytes = [long]$Session.Bytes
                zipBytes = (Get-Item -LiteralPath $placed.Path).Length; lastActivity = $Session.LastActivity; archivedAt = (Get-Date).ToUniversalTime().ToString('o'); machineId = $MachineId; entry = $placed.Entry; sha256 = $a.Sha256 })
            $res.ZipPath = $placed.Path
        }
    } catch {
        if ($placed -and [IO.File]::Exists($placed.Path)) { Remove-Item -LiteralPath $placed.Path -Force -ErrorAction SilentlyContinue }
        $res.Reason = $_.Exception.Message; $res.ZipPath = $null
        return $res
    } finally { if ($a -and [IO.File]::Exists($a.ZipPath)) { Remove-Item -LiteralPath $a.ZipPath -Force -ErrorAction SilentlyContinue } }
    try {
        $mode = $(if ($RecycleOriginals) { 'Recycle' } else { 'Delete' })
        $rm = Remove-StorageSessionOriginal -Session $Session -Roots $Roots -Mode $mode -CodexRpc $CodexRpc -Recycler $Recycler
        if (@($rm.Skipped).Count) { $res.Warnings = @($rm.Skipped | ForEach-Object { "Not removed: $_" }) }
        $res.Ok = $true
    } catch { $res.Ok = $true; $res.Warnings = @("The archive is safe, but the original could not be removed: $($_.Exception.Message)") }
    return $res
}

# Archives sessions one after the other. The guard decides per session; a session that fails or is skipped does not stop the
# rest; Cancel (a hashtable with Cancel = $true) stops before the next session, never in the middle of one.
# -Running, -CliCwds, -RecentMinutes, -IncludeRecent (keys) and -LockProbe go to Test-StorageSessionSafe. -OnZipBuilt,
# -OnPlaced and -OnSession are hooks for tests.
function Invoke-StorageArchive {
    param([Parameter(Mandatory)][array]$Sessions, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Roots, [string]$MachineId = '', [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'harness-archive-work'),
          $Running = @{}, [string[]]$CliCwds = @(), [int]$RecentMinutes = 30, [string[]]$IncludeRecent = @(), [scriptblock]$LockProbe, [scriptblock]$CodexRpc,
          [switch]$RecycleOriginals, [scriptblock]$Recycler, $Progress, $CancelToken, [scriptblock]$OnZipBuilt, [scriptblock]$OnPlaced, [scriptblock]$OnSession)
    $results = New-Object Collections.Generic.List[object]
    foreach ($s in $Sessions) {
        if (Test-StorageCancel $CancelToken) { break }
        if ($OnSession) { & $OnSession $s }
        $guard = @{ RecentMinutes = $RecentMinutes; Running = $Running; CliCwds = $CliCwds }
        if ($LockProbe) { $guard['LockProbe'] = $LockProbe }
        if ($IncludeRecent -contains [string]$s.Key) { $guard['IncludeRecent'] = $true }
        $one = @{ Session = $s; Target = $Target; Roots = $Roots; MachineId = $MachineId; WorkDir = $WorkDir; Guard = $guard; CodexRpc = $CodexRpc; OnZipBuilt = $OnZipBuilt; OnPlaced = $OnPlaced; Recycler = $Recycler; RecycleOriginals = $RecycleOriginals }
        $results.Add((Invoke-StorageArchiveOne @one))
        if ($Progress) { $Progress['Done'] = [int]$Progress['Done'] + 1 }
    }
    if ([IO.Directory]::Exists($WorkDir) -and -not @(Get-ChildItem -LiteralPath $WorkDir -Force).Count) { Remove-Item -LiteralPath $WorkDir -Force -ErrorAction SilentlyContinue }
    return $results.ToArray()
}

# ---- restore ----------------------------------------------------------------------------------------------------------

# Applies Target.PathMap @{ '<other machine root>' = '<this machine root>' } to a folder path (first matching prefix).
function Convert-StoragePathByMap {
    param([string]$Path, $Map)
    foreach ($k in @($Map.Keys)) {
        $kk = ([string]$k).TrimEnd('\')
        if ($Path -ieq $kk -or $Path.StartsWith($kk + '\', [StringComparison]::OrdinalIgnoreCase)) { return (([string]$Map[$k]).TrimEnd('\') + $Path.Substring($kk.Length)) }
    }
    return $Path
}

# Where every file of the manifest goes on this machine, decided before anything is written. Throws when a path is not
# safe or a profile that gets files has its app running. Returns @{ Items = @(@{Part; Dest}); Warnings }.
function Get-StorageRestorePlan {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$Roots, $Map = @{}, $Running = @{})
    $warn = New-Object Collections.Generic.List[string]; $items = New-Object Collections.Generic.List[object]; $used = @{}
    $cwd = [string]$Manifest.cwd; $newCwd = Convert-StoragePathByMap -Path $cwd -Map $Map
    $codexHome = $null
    if ($Manifest.harness -eq 'codex') {
        $c = @($Roots.CodexHomes | Where-Object { [string]$_.Id -ieq [string]$Manifest.restore.codex.profileId }); if (-not $c.Count) { $c = @($Roots.CodexHomes) }
        if (-not $c.Count) { throw 'restore-refused: no CODEX_HOME is known.' }
        $codexHome = [string]$c[0].Home
    }
    $allowed = @($Roots.ClaudeProjects) + @($Roots.ClaudeProfiles | ForEach-Object { $_.SessionRoot }) + @($codexHome)
    foreach ($p in $Manifest.parts) {
        $rel = [string]$p.rel
        if ($rel -match '\A[\\/]' -or $rel.Contains(':') -or $rel.Contains("`0")) { throw "restore-refused: unsafe path in the archive: $rel" }
        $root = $null
        switch ([string]$p.role) {
            { $_ -in 'transcript', 'cli-dir' } {
                $root = [string]$Roots.ClaudeProjects
                if ($newCwd -ne $cwd -and $rel.Contains('\')) { $rel = (ConvertTo-ClaudeProjectSlug $newCwd) + $rel.Substring($rel.IndexOf('\')) }
            }
            'profile-meta' {
                $prof = @($Roots.ClaudeProfiles | Where-Object { [string]$_.Id -ieq [string]$p.profileId })
                if (-not $prof.Count) {
                    $prof = @($Roots.ClaudeProfiles | Where-Object { $_.IsDefault }); if (-not $prof.Count) { throw 'restore-refused: no profile to restore into.' }
                    if (-not $used.ContainsKey('missing:' + $p.profileId)) { $used['missing:' + $p.profileId] = $true; $warn.Add("The profile '$($p.profileId)' no longer exists, so its file was restored into '$($prof[0].Name)' (Default).") }
                }
                $root = [string]$prof[0].SessionRoot; $used[[string]$prof[0].Id] = [string]$prof[0].Name
            }
            'rollout' {
                $root = $codexHome
                if ($rel -match '\Aarchived_sessions\\rollout-(\d{4})-(\d{2})-(\d{2})T[^\\]*\z') { $rel = "sessions\$($Matches[1])\$($Matches[2])\$($Matches[3])\" + (Split-Path -Leaf $rel) }
            }
            default { throw "restore-refused: unknown part '$($p.role)'" }
        }
        $dest = Join-Path $root $rel
        if (-not (Test-StoragePathAllowed -Path $dest -Roots $allowed)) { throw "restore-refused: the path would leave the session folders: $rel" }
        $items.Add(@{ Part = $p; Dest = $dest })
    }
    $run = @($Running[[string]$Manifest.harness])
    $busy = @($used.Keys | Where-Object { -not $_.StartsWith('missing:') -and $run -contains $_ } | ForEach-Object { $used[$_] })
    if ($busy.Count) { throw ('restore-refused: close ' + ($busy -join ', ') + ' first: its app is running.') }
    return @{ Items = $items.ToArray(); Warnings = $warn.ToArray() }
}

# Extracts one entry beside its destination (tmp), checks its sha256, applies the PathMap to chat files, then puts it in place:
# same content = left alone, other content in the way = renamed to .bak-<time>. Returns $true when a file was written.
function Restore-StorageFile {
    param([Parameter(Mandatory)]$Zip, [Parameter(Mandatory)]$Item, $Map = @{})
    $p = $Item.Part; $dest = [string]$Item.Dest
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
    $tmp = $dest + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $in = $Zip.GetEntry([string]$p.entry).Open(); $out = [IO.File]::Create($tmp)
        try { $buf = New-Object byte[] 81920; while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) { [void]$sha.TransformBlock($buf, 0, $r, $null, 0); $out.Write($buf, 0, $r) }; [void]$sha.TransformFinalBlock($buf, 0, 0) } finally { $out.Dispose(); $in.Dispose() }
        if ((($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '') -ne [string]$p.sha256) { throw "restore-verify-failed: $($p.entry) does not match its sha256." }
        if ($p.role -eq 'profile-meta' -and @($Map.Keys).Count) {
            $text = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
            foreach ($k in @($Map.Keys)) { $text = [regex]::Replace($text, [regex]::Escape(([string]$k).TrimEnd('\').Replace('\', '\\')) + '(?=\\\\|")', ([string]$Map[$k]).TrimEnd('\').Replace('\', '\\').Replace('$', '$$'), 'IgnoreCase') }
            [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
        }
        $ticks = [long]0   # archives made before this field existed have none: the file then keeps the time of the restore
        if ($p.PSObject.Properties['mtimeUtcTicks'] -and [long]::TryParse([string]$p.mtimeUtcTicks, [ref]$ticks) -and $ticks -gt 0 -and $ticks -le [DateTime]::MaxValue.Ticks) { [IO.File]::SetLastWriteTimeUtc($tmp, (New-Object DateTime ($ticks, [DateTimeKind]::Utc))) }
        if ([IO.File]::Exists($dest)) {
            if ((Get-StorageFileSha256 $dest) -eq (Get-StorageFileSha256 $tmp)) { return $false }
            [IO.File]::Move($dest, $dest + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmssfff'))
        }
        [IO.File]::Move($tmp, $dest)
        return $true
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

# Gives the zip of an entry: its ZipPath, a file of the local store (index row), or a download from Drive into TempDir.
function Resolve-StorageRestoreZip {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$TempDir)
    if ($Entry.ZipPath) { return [string]$Entry.ZipPath }
    if ($Target.Kind -eq 'drive') { return (Receive-StorageDriveArchive -Entry $Entry -SyncRoot $Target.SyncRoot -Key $Target.Key -OutDir $TempDir) }
    $zip = Join-Path $Target.Path (([string]$Entry.entry) -replace '/', '\')
    if (-not (Test-StoragePathAllowed -Path $zip -Roots @($Target.Path))) { throw 'restore-refused: the index row points outside the store.' }
    return $zip
}

# Puts archived sessions back. Entries are @{ Key; ZipPath } or rows of Get-StorageArchiveIndex. Nothing is written unless the
# zip verifies and every destination is safe. Returns one @{ Key; Ok; Reason; Warnings; Restored } per entry.
function Invoke-StorageRestore {
    param([Parameter(Mandatory)][array]$Entries, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Roots, $Running = @{}, [scriptblock]$CodexRpc, $CancelToken)
    $results = New-Object Collections.Generic.List[object]
    $map = $(if ($Target.PathMap) { $Target.PathMap } else { @{} })
    foreach ($e in $Entries) {
        if (Test-StorageCancel $CancelToken) { break }
        $res = @{ Key = [string]$e.key; Ok = $false; Reason = ''; Warnings = @(); Restored = @() }
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('harness-restore-' + [guid]::NewGuid().ToString('N')); $zip = $null
        try {
            $zipPath = Resolve-StorageRestoreZip -Entry $e -Target $Target -TempDir $temp
            $chk = Read-StorageArchive -ZipPath $zipPath
            if (-not $chk.Verified) { throw "restore-verify-failed: the archive does not verify ($($chk.Reason))." }
            $m = $chk.Manifest
            if ($e.key -and [string]$e.key -ne [string]$m.key) { throw 'restore-refused: the archive is for another session than the one asked for.' }
            $res.Key = [string]$m.key
            $plan = Get-StorageRestorePlan -Manifest $m -Roots $Roots -Map $map -Running $Running
            $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
            $written = New-Object Collections.Generic.List[string]
            foreach ($it in $plan.Items) { if (Restore-StorageFile -Zip $zip -Item $it -Map $map) { $written.Add([string]$it.Dest) } }
            $res.Warnings = @($plan.Warnings); $res.Restored = $written.ToArray()
            if ($m.harness -eq 'codex') {
                if ($CodexRpc) {
                    $c = @($Roots.CodexHomes | Where-Object { [string]$_.Id -ieq [string]$m.restore.codex.profileId }); if (-not $c.Count) { $c = @($Roots.CodexHomes) }
                    [void](& $CodexRpc ([string]$c[0].Home) 'thread/read' @{ threadId = [string]$m.id; includeTurns = $false })
                } else { $res.Warnings += 'The rollout is back; Codex has not been asked to pick it up yet.' }
            }
            if ($Target.Kind -ne 'drive' -and $Target.Path) { Remove-StorageArchiveIndex -Target $Target -Key ([string]$m.key) }
            $res.Ok = $true
        } catch { $res.Reason = $_.Exception.Message } finally {
            if ($zip) { $zip.Dispose() }
            if ([IO.Directory]::Exists($temp)) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $results.Add($res)
    }
    return $results.ToArray()
}
