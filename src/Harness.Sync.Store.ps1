# Harness.Sync.Store.ps1 - the sync folder on Drive: sync.json, encrypted bundles, per-machine index and state
# (phase 4, lane S). Needs Harness.Sync.Crypto.ps1 and Harness.Sync.Config.ps1 (Get-SyncMachine, Get-SyncPathRoots).
# Rules the code keeps: every file has one writer (the machine whose id is in its name); every write goes through a
# tmp file in the same folder and a rename, then is read back and compared; everything read from Drive is treated as
# hostile and checked before use (id, chat key, path, sha256, numbers). Nothing here prints a passphrase or key.
# $script:SyncRetryDelayMs lets tests shorten the retry wait. ASCII only.

$script:SyncGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:SyncChatKeyPattern = '\A[a-z][a-z0-9]{0,31}:[A-Za-z0-9_.-]{1,128}\z'

function Get-SyncRetryDelay {
    return $(if ($script:SyncRetryDelayMs) { [int]$script:SyncRetryDelayMs } else { 200 })
}

# Drive (spike S10) answers with a sharing violation or access denied for a moment while it syncs or while another
# program holds a file: retry 10 times, 200 ms apart. A missing file is not transient and fails at once.
function Invoke-SyncRetry {
    param([Parameter(Mandatory)][scriptblock]$Script, [int]$Tries = 10)
    for ($i = 1; ; $i++) {
        try { return (& $Script) }
        catch {
            # .NET calls made from PowerShell arrive wrapped in a MethodInvocationException: look at the real one.
            $e = $_.Exception
            while ($e.InnerException -and $e -isnot [IO.IOException] -and $e -isnot [UnauthorizedAccessException]) { $e = $e.InnerException }
            $transient = (($e -is [IO.IOException] -or $e -is [UnauthorizedAccessException]) -and $e -isnot [IO.FileNotFoundException] -and $e -isnot [IO.DirectoryNotFoundException])
            if (-not $transient -or $i -ge $Tries) { throw }
            Start-Sleep -Milliseconds (Get-SyncRetryDelay)
        }
    }
}

# Every read of a file on Drive shares ReadWrite|Delete, so a reader never blocks the machine that replaces the file.
function Open-SyncRead {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::Open($Path, 'Open', 'Read', ([IO.FileShare]'ReadWrite,Delete'))
}

function Read-SyncAllText {
    param([Parameter(Mandatory)][string]$Path)
    return (Invoke-SyncRetry {
        $s = Open-SyncRead $Path
        try { $r = New-Object IO.StreamReader ($s, (New-Object Text.UTF8Encoding($false)), $true); return $r.ReadToEnd() } finally { $s.Dispose() }
    })
}

function Get-SyncFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Invoke-SyncRetry {
        $s = Open-SyncRead $Path
        $h = [Security.Cryptography.SHA256]::Create()
        try { return (($h.ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $h.Dispose(); $s.Dispose() }
    })
}

function Copy-SyncFileShared {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    Invoke-SyncRetry {
        $in = Open-SyncRead $Source
        try { $out = [IO.File]::Create($Destination); try { $in.CopyTo($out) } finally { $out.Dispose() } } finally { $in.Dispose() }
    }
}

# MoveFileEx with REPLACE_EXISTING | WRITE_THROUGH: Move-Item -Force failed 37 of 40 times on DriveFS while a reader
# had the file open, MoveFileEx 0 of 40 (spike S10). Without Replace (NoClobber) an existing target is an error.
function Initialize-SyncNative {
    if ('HarnessSyncNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HarnessSyncNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string from, string to, int flags);
}
'@
}

function Move-SyncFile {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, [switch]$NoClobber)
    Initialize-SyncNative
    $flags = $(if ($NoClobber) { 8 } else { 9 })
    if (-not [HarnessSyncNative]::MoveFileEx($From, $To, $flags)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw (New-Object IO.IOException ("MoveFileEx failed with Windows error $code."))
    }
}

# Renames a finished tmp file into place, then reads it back and compares the sha256 (Drive can hand back a short file).
function Move-SyncTmpIntoPlace {
    param([Parameter(Mandatory)][string]$Tmp, [Parameter(Mandatory)][string]$Path, [switch]$NoClobber)
    if ($NoClobber -and (Test-Path -LiteralPath $Path)) { throw "$Path already exists." }
    $sha = Get-SyncFileSha256 $Tmp
    Invoke-SyncRetry { Move-SyncFile -From $Tmp -To $Path -NoClobber:$NoClobber }
    if ((Get-SyncFileSha256 $Path) -ne $sha) { throw 'write-verify-failed' }
}

function Write-SyncFileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$NoClobber)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $tmp = "$Path.tmp-" + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($tmp, (New-Object Text.UTF8Encoding($false)).GetBytes($Text))
        Move-SyncTmpIntoPlace -Tmp $tmp -Path $Path -NoClobber:$NoClobber
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}

function Copy-SyncFileAtomic {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Path, [switch]$NoClobber)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $tmp = "$Path.tmp-" + [guid]::NewGuid().ToString('N')
    try {
        Invoke-SyncRetry { Copy-Item -LiteralPath $Source -Destination $tmp -Force }
        Move-SyncTmpIntoPlace -Tmp $tmp -Path $Path -NoClobber:$NoClobber
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}

# ---- sync.json -------------------------------------------------------------------------------------------------------

function Read-SyncJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    # $null means "not there or not JSON". A lock that outlasts the retries is an I/O error and is thrown.
    try { $text = Read-SyncAllText -Path $Path } catch {
        $e = $_.Exception
        while ($e.InnerException -and $e -isnot [IO.IOException]) { $e = $e.InnerException }
        if ($e -is [IO.FileNotFoundException] -or $e -is [IO.DirectoryNotFoundException]) { return $null }
        throw
    }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# The first machine creates sync.json; later machines read it and check the passphrase. Returns the kdf record.
function Initialize-SyncFolder {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Passphrase, [int]$Iterations = 600000, [int]$MinIterations = 600000)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $main = Join-Path $Root 'sync.json'
    $doc = $(if (Test-Path -LiteralPath $main) { Read-SyncJsonFile $main } else { $null })
    if ((Test-Path -LiteralPath $main) -and (-not $doc -or $doc.format -ne 'harness-sync' -or $doc.version -ne 1 -or -not $doc.kdf)) { throw 'sync-invalid: sync.json is not a Harness sync file.' }
    foreach ($dup in @(Get-ChildItem -LiteralPath $Root -File -Filter 'sync (*).json' -ErrorAction SilentlyContinue)) {
        $d = Read-SyncJsonFile $dup.FullName
        if ($d -and $d.kdf -and (-not $doc -or $d.kdf.salt -ne $doc.kdf.salt)) {
            throw "sync-conflict: '$($dup.Name)' was made by another machine at the same time as sync.json. Keep one of them, delete the other, then set up sync again."
        }
    }
    if ($doc) {
        try { $v = Get-SyncKdfValues -Kdf $doc.kdf } catch { throw 'sync-invalid: sync.json holds a damaged key record.' }
        # sync.json comes from Drive: a copy with a lowered round count must not weaken the key derivation on a new machine.
        if ($v.Iterations -lt $MinIterations) { throw "sync-invalid: sync.json asks for only $($v.Iterations) key rounds (at least $MinIterations are required)." }
        [void](Get-SyncKey -Passphrase $Passphrase -Kdf $doc.kdf)   # throws wrong-passphrase
        return $doc.kdf
    }
    $kdf = New-SyncKdf -Passphrase $Passphrase -Iterations $Iterations
    Write-SyncFileAtomic -Path $main -NoClobber -Text ([ordered]@{ format = 'harness-sync'; version = 1; kdf = $kdf } | ConvertTo-Json -Depth 5)
    return $kdf
}

# ---- sync state (this machine only) ----------------------------------------------------------------------------------

function Get-SyncStatePath {
    return (Join-Path $script:SwitcherHome 'sync-state.json')
}

# @{ <chatKey> = { lastBundleId; localChatId; harness; profileId; localActivityAtSync } }
function Get-SyncState {
    $path = Get-SyncStatePath
    $map = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    $doc = Read-SyncJsonFile $path
    if ($doc -isnot [pscustomobject]) { Write-Warning 'The sync state file is damaged; starting from an empty state.'; return $map }
    foreach ($p in $doc.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}

function Set-SyncState {
    param([Parameter(Mandatory)][hashtable]$State)
    Write-SyncFileAtomic -Path (Get-SyncStatePath) -Text ($State | ConvertTo-Json -Depth 4)
}

# ---- reading what Drive holds ------------------------------------------------------------------------------------------

function Test-SyncNumber {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double])
}

# One index row from Drive: every field is checked, because the file may have been written by anything.
function Test-SyncRow {
    param($Row, [string]$MachineId)
    if ($Row -isnot [pscustomobject]) { return $false }
    $guid = '\A' + $script:SyncGuidPattern + '\z'
    if ([string]$Row.bundleId -notmatch $guid -or [string]$Row.machineId -ne $MachineId) { return $false }
    if ([string]$Row.chatKey -notmatch $script:SyncChatKeyPattern -or ([string]$Row.chatKey).Contains('..')) { return $false }
    if ([string]$Row.harness -notmatch '\A[a-z][a-z0-9]{0,31}\z' -or ([string]$Row.chatKey).Split(':')[0] -ne [string]$Row.harness) { return $false }
    if ($null -ne $Row.previousBundleId -and [string]$Row.previousBundleId -notmatch $guid) { return $false }
    if ([string]$Row.sha256 -notmatch '\A[0-9a-f]{64}\z') { return $false }
    if (-not (Test-SyncNumber $Row.lastActivityAt) -or -not (Test-SyncNumber $Row.size) -or $Row.size -lt 0) { return $false }
    if ($Row.titleEnc -isnot [string] -or $Row.pushedAt -isnot [string]) { return $false }
    return ([string]$Row.path -match ('\Abundles/[a-z][a-z0-9]{0,31}/[A-Za-z0-9_.-]{1,170}/' + $script:SyncGuidPattern + '\.hbundle\.zip\.enc\z') -and -not ([string]$Row.path).Contains('..'))
}

# The valid rows of one machine's index file; bad lines are counted in one warning.
function Read-SyncIndexRows {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$MachineId)
    $rows = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $bad = New-Object Collections.Generic.List[int]
    $lines = @((Read-SyncAllText -Path $Path) -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].Trim()) { continue }
        $r = $null
        try { $r = $lines[$i] | ConvertFrom-Json } catch { }
        if (Test-SyncRow -Row $r -MachineId $MachineId) { $rows.Add($r) } else { $bad.Add($i + 1) }
    }
    if ($bad.Count) { Write-Warning "Skipped $($bad.Count) bad line(s) in $(Split-Path -Leaf $Path): line $($bad -join ', ')." }
    return $rows.ToArray()   # callers wrap the call in @(...)
}

# Root\<relative path> for a bundle, only when the row's path is a bundle path and stays under Root\bundles\.
function Resolve-SyncBundlePath {
    param([Parameter(Mandatory)][string]$Root, [string]$RelPath)
    if ($RelPath -notmatch ('\Abundles/[a-z][a-z0-9]{0,31}/[A-Za-z0-9_.-]{1,170}/' + $script:SyncGuidPattern + '\.hbundle\.zip\.enc\z') -or $RelPath.Contains('..')) { throw 'bundle-path-invalid' }
    $full = [IO.Path]::GetFullPath((Join-Path $Root ($RelPath -replace '/', '\')))
    $bundles = [IO.Path]::GetFullPath((Join-Path $Root 'bundles')).TrimEnd('\') + '\'
    if (-not $full.StartsWith($bundles, [StringComparison]::OrdinalIgnoreCase)) { throw 'bundle-path-invalid' }
    return $full
}

function Get-SyncMachineNames {
    param([Parameter(Mandatory)][string]$Root)
    $names = @{}
    $dir = Join-Path $Root 'machines'
    if (-not (Test-Path -LiteralPath $dir)) { return $names }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json')) {
        if ($f.Name -notmatch ('\A(' + $script:SyncGuidPattern + ')\.json\z')) { continue }
        $m = Read-SyncJsonFile $f.FullName
        if ($m -and $m.name -is [string]) { $names[$Matches[1].ToLowerInvariant()] = ($m.name -replace '[\x00-\x1f]', '') }
    }
    return $names
}

# One entry per chat: the version with the latest activity, from any machine, with its decrypted title and the
# name of the machine that pushed it. Newest first.
function Get-SyncCatalog {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][byte[]]$Key)
    $names = Get-SyncMachineNames -Root $Root
    $all = New-Object Collections.Generic.List[object]
    $indexDir = Join-Path $Root 'index'
    $files = $(if (Test-Path -LiteralPath $indexDir) { @(Get-ChildItem -LiteralPath $indexDir -File -Filter '*.jsonl') } else { @() })
    foreach ($f in $files) {
        if ($f.Name -notmatch ('\A(' + $script:SyncGuidPattern + ')\.jsonl\z')) { continue }   # skips tmp files and "name (1).jsonl"
        $mid = $Matches[1]
        foreach ($r in @(Read-SyncIndexRows -Path $f.FullName -MachineId $mid)) { $all.Add($r) }
    }
    # A version that another version names as its predecessor was replaced on purpose (a "push mine"), even when its
    # activity is later; among what is left the latest activity wins.
    $replaced = @{}
    foreach ($r in $all) { if ($r.previousBundleId) { $replaced[$r.chatKey + '|' + $r.previousBundleId] = $true } }
    $best = @{}
    foreach ($r in $all) {
        if ($replaced.ContainsKey($r.chatKey + '|' + $r.bundleId)) { continue }
        $cur = $best[$r.chatKey]
        if (-not $cur -or $r.lastActivityAt -gt $cur.lastActivityAt -or ($r.lastActivityAt -eq $cur.lastActivityAt -and $r.pushedAt -gt $cur.pushedAt)) { $best[$r.chatKey] = $r }
    }
    $out = foreach ($r in $best.Values) {
        $title = [string]$r.chatKey
        try { $title = Unprotect-SyncString -Text $r.titleEnc -Key $Key } catch { }
        $o = [ordered]@{}
        foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value }
        $o['Title'] = $title
        $o['MachineName'] = $(if ($names.ContainsKey(([string]$r.machineId).ToLowerInvariant())) { $names[([string]$r.machineId).ToLowerInvariant()] } else { [string]$r.machineId })
        [pscustomobject]$o
    }
    return @($out | Sort-Object { $_.lastActivityAt } -Descending)
}

# ---- Push --------------------------------------------------------------------------------------------------------------

# Only manifest.json is read, and never more than 1 MiB of it.
function Read-SyncBundleManifest {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $e = $zip.GetEntry('manifest.json')
        if (-not $e -or $e.Length -gt 1048576) { throw 'bundle-invalid: no usable manifest.json' }
        $s = $e.Open(); $ms = New-Object IO.MemoryStream
        try { $buf = New-Object byte[] 65536; while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n); if ($ms.Length -gt 1048576) { throw 'bundle-invalid: manifest.json is too large' } } } finally { $s.Dispose() }
        $m = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
    } finally { $zip.Dispose() }
    if ($m.format -ne 'harness-bundle' -or [string]$m.bundleId -notmatch ('\A' + $script:SyncGuidPattern + '\z')) { throw 'bundle-invalid: not a Harness bundle' }
    return $m
}

function ConvertTo-SyncIndexText {
    param([array]$Rows)
    if (-not $Rows.Count) { return '' }
    return ((@($Rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "`n") + "`n")
}

function Write-SyncMachineFile {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Machine, [array]$Rows)
    $roots = $(if (Get-Command Get-SyncPathRoots -CommandType Function -ErrorAction SilentlyContinue) { Get-SyncPathRoots } else { @{} })
    $doc = [ordered]@{ name = $Machine.Name; lastSeen = (Get-Date).ToUniversalTime().ToString('o'); harnesses = @($Rows | ForEach-Object { $_.harness } | Sort-Object -Unique); pathRoots = $roots }
    Write-SyncFileAtomic -Path (Join-Path $Root "machines\$($Machine.Id).json") -Text ($doc | ConvertTo-Json -Depth 4)
}

# Encrypts the bundle, writes it under bundles/, adds a row to this machine's index (rewritten whole, decision D8),
# updates machines/<id>.json and the sync state. Returns the new row.
function Push-SyncBundle {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)]$Chat, [string]$PreviousBundleId)
    $m = Read-SyncBundleManifest -Path $BundlePath
    $chatKey = [string]$m.chatKey
    if ($chatKey -notmatch $script:SyncChatKeyPattern -or $chatKey.Contains('..')) { throw "bundle-invalid: unsafe chat key '$chatKey'" }
    $harness = $chatKey.Split(':')[0]
    $machine = Get-SyncMachine
    $rel = 'bundles/{0}/{1}/{2}.hbundle.zip.enc' -f $harness, ($chatKey -replace ':', '_'), $m.bundleId
    $dest = Resolve-SyncBundlePath -Root $Root -RelPath $rel
    $work = Join-Path ([IO.Path]::GetTempPath()) ('harness-sync-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        Protect-SyncFile -In $BundlePath -Out (Join-Path $work 'out.enc') -Key $Key   # encrypted here, so Drive only ever sees the finished file
        Copy-SyncFileAtomic -Source (Join-Path $work 'out.enc') -Path $dest -NoClobber
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    $state = Get-SyncState
    $activity = $(if ($null -ne $Chat.Activity) { $Chat.Activity } else { $m.source.lastActivityAt })
    $title = $(if ($m.source.title) { [string]$m.source.title } else { [string]$Chat.Title })
    $row = [pscustomobject][ordered]@{
        bundleId = [string]$m.bundleId; chatKey = $chatKey; previousBundleId = $(if ($PreviousBundleId) { $PreviousBundleId } elseif ($state.ContainsKey($chatKey)) { $state[$chatKey].lastBundleId } else { $null })
        contentSha256 = $m.lineage.contentSha256; harness = $harness; titleEnc = (Protect-SyncString -Text $title -Key $Key)
        lastActivityAt = $(if ($null -ne $m.source.lastActivityAt) { $m.source.lastActivityAt } else { $activity }); path = $rel
        size = (Get-Item -LiteralPath $dest).Length; sha256 = (Get-SyncFileSha256 $dest); machineId = $machine.Id; pushedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $indexPath = Join-Path $Root "index\$($machine.Id).jsonl"
    $rows = @(Read-SyncIndexRows -Path $indexPath -MachineId $machine.Id) + @($row)
    Write-SyncFileAtomic -Path $indexPath -Text (ConvertTo-SyncIndexText -Rows $rows)
    Write-SyncMachineFile -Root $Root -Machine $machine -Rows $rows
    $state[$chatKey] = @{ lastBundleId = $row.bundleId; localChatId = [string]$Chat.ChatId; harness = $harness; profileId = [string]$Chat.Profile.Id; localActivityAtSync = $activity }
    Set-SyncState -State $state
    return $row
}

# ---- Pull --------------------------------------------------------------------------------------------------------------

# Copies the .enc into %TEMP% (Drive may still be downloading it: retried), checks sha256 against the row, checks the
# MAC and decrypts. Returns the path of the plain bundle; the caller removes it with Remove-SyncReceived.
function Receive-SyncBundle {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Row, [Parameter(Mandatory)][byte[]]$Key)
    $full = Resolve-SyncBundlePath -Root $Root -RelPath ([string]$Row.path)
    if ([string]$Row.sha256 -notmatch '\A[0-9a-f]{64}\z' -or [string]$Row.bundleId -notmatch ('\A' + $script:SyncGuidPattern + '\z')) { throw 'bundle-path-invalid' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'bundle-missing' }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('harness-sync-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $enc = Join-Path $work 'in.enc'
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            Copy-SyncFileShared -Source $full -Destination $enc
            $ok = ((Get-SyncFileSha256 $enc) -eq [string]$Row.sha256)
            if (-not $ok -and $try -lt 3) { Start-Sleep -Milliseconds (Get-SyncRetryDelay) }   # Drive may still be updating the file
        }
        if (-not $ok) { throw 'sha-mismatch' }
        $zip = Join-Path $work "$($Row.bundleId).hbundle.zip"
        Unprotect-SyncFile -In $enc -Out $zip -Key $Key
        Remove-Item -LiteralPath $enc -Force
        return $zip
    } catch {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

# Deletes what Receive-SyncBundle returned, with its temp folder (only a folder that function made).
function Remove-SyncReceived {
    param([string]$Path)
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Leaf $dir) -match '\Aharness-sync-[0-9a-f]{32}\z' -and ([IO.Path]::GetFullPath((Split-Path -Parent $dir)).TrimEnd('\')) -ieq $temp) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# new | update | same | diverged, by decision D4: only a chat that has not moved since the last sync may be updated in place.
function Get-SyncDivergence {
    param([Parameter(Mandatory)]$Row, $LocalChat)
    if (-not $LocalChat) { return 'new' }
    $state = Get-SyncState
    $s = $(if ($state.ContainsKey([string]$Row.chatKey)) { $state[[string]$Row.chatKey] } else { $null })
    if ($s -and [string]$Row.bundleId -eq [string]$s.lastBundleId) { return 'same' }
    if ($s -and $null -ne $s.localActivityAtSync -and $null -ne $LocalChat.Activity -and $LocalChat.Activity -le $s.localActivityAtSync) { return 'update' }
    return 'diverged'
}

# ---- cleanup -----------------------------------------------------------------------------------------------------------

# Keeps the newest $Keep versions of each chat among this machine's own rows. The index is rewritten first, then the
# files are deleted, so the index never points at a file that is gone. Other machines' files are never touched.
function Remove-SyncOldBundles {
    param([Parameter(Mandatory)][string]$Root, [int]$Keep = 3)
    $machine = Get-SyncMachine
    $indexPath = Join-Path $Root "index\$($machine.Id).jsonl"
    $rows = @(Read-SyncIndexRows -Path $indexPath -MachineId $machine.Id)
    $drop = @{}
    foreach ($g in ($rows | Group-Object chatKey)) {
        $newest = @($g.Group | Sort-Object @{ Expression = { $_.pushedAt }; Descending = $true }, @{ Expression = { $_.lastActivityAt }; Descending = $true })
        foreach ($r in ($newest | Select-Object -Skip $Keep)) { $drop[[string]$r.bundleId] = $r }
    }
    $kept = @($rows | Where-Object { -not $drop.ContainsKey([string]$_.bundleId) })
    $text = ConvertTo-SyncIndexText -Rows $kept
    if (-not (Test-Path -LiteralPath $indexPath) -or (Read-SyncAllText -Path $indexPath) -ne $text) { Write-SyncFileAtomic -Path $indexPath -Text $text }
    foreach ($r in $drop.Values) {
        try {
            $f = Resolve-SyncBundlePath -Root $Root -RelPath ([string]$r.path)
            if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force }
            $d = Split-Path -Parent $f
            if ((Test-Path -LiteralPath $d) -and -not @(Get-ChildItem -LiteralPath $d -Force).Count) { Remove-Item -LiteralPath $d -Force }
        } catch { Write-Warning "Could not remove an old bundle: $($_.Exception.Message)" }
    }
}
