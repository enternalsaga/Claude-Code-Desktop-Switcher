# Storage.Inventory.ps1 - every session of Claude, Codex and Antigravity with its parts and sizes, and the statistics
# (phase 6, lane I1). Read-only: nothing is written into app data. ASCII only. Needs Storage.Scan.ps1 and, for Codex and
# Antigravity, Harness.Sqlite.ps1 (the databases are only read through a snapshot copy).
#
# A session (StorageSession): Harness, Key, Id, Title, Cwd, LastActivity (unix ms), Created, Profiles (@{Id;Name}),
# Parts (@{Role; Path; Bytes; Kind = file|dir|row; Files; MTimeTicks; ProfileId}), Bytes (sum of the parts), State
# (idle|recent here; the guard of lane A1 adds live and protected) and Flags (IsCliOnly, HasZst, Trimmable, ArchivedRef,
# CodexArchived, NoTranscript, NoFile).
# Roots: @{ ClaudeProjects; ClaudeProfiles = @(@{Id;Name;SessionRoot;DataDir;IsDefault}); CodexHomes = @(@{Id;Name;Home});
#          AgyDirs = @(@{Id;Name;DataDir}) }. Tests pass fake roots; Get-StorageRootsFromConfig builds the real ones.

# A function, not a script variable, because the runspace of the background scan only gets functions.
function Get-StorageGuidPattern {
    return '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
}

function ConvertTo-StorageMs {
    param($Text)
    $d = [datetimeoffset]::MinValue
    if ($Text -and [datetimeoffset]::TryParse(([string]$Text).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return [long]$d.ToUnixTimeMilliseconds() }
    return $null
}

function Set-StorageProgress {
    param($Progress, [string]$Phase, [int]$Done = 0, [int]$Total = 0)
    if (-not $Progress) { return }
    if ($Phase) { $Progress['Phase'] = $Phase }
    if ($Done) { $Progress['Done'] = [int]$Progress['Done'] + $Done }
    if ($Total) { $Progress['Total'] = [int]$Progress['Total'] + $Total }
}

function Add-StoragePart {
    param([Parameter(Mandatory)]$List, [string]$Role, [string]$Path, [long]$Bytes = 0, [string]$Kind = 'file', [int]$Files = 1, [long]$Ticks = 0, [string]$ProfileId = '')
    $List.Add(@{ Role = $Role; Path = $Path; Bytes = $Bytes; Kind = $Kind; Files = $Files; MTimeTicks = $Ticks; ProfileId = $ProfileId })
}

# A session with no activity time of its own is as recent as its newest file.
function Set-StorageActivityFromParts {
    param([Parameter(Mandatory)]$Builder)
    if ($Builder.Activity -gt 0) { return }
    $newest = [long]0
    foreach ($p in $Builder.Parts) { if ($p.MTimeTicks -gt $newest) { $newest = $p.MTimeTicks } }
    if ($newest -gt 0) { $Builder.Activity = [long]([DateTimeOffset][DateTime]::new($newest, [DateTimeKind]::Utc)).ToUnixTimeMilliseconds() }
}

function Get-StorageFirstString {
    param($Object, [string[]]$Names)
    if (-not $Object) { return $null }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $p.Value -is [string] -and $p.Value.Trim()) { return $p.Value.Trim() }
    }
    return $null
}

# ---- Claude -----------------------------------------------------------------------------------------------------------

# The small local_<id>.json of the desktop app: which transcript (cliSessionId), the title, the folder, the times.
function Read-StorageLocalMeta {
    param([Parameter(Mandatory)][string]$Path)
    # Throws when the file cannot be opened or is not JSON (the app may be writing it right now): an empty answer would be cached
    # and would make the session look CLI-only. The caller turns the error into a warning and does not cache it.
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
    $o = $text | ConvertFrom-Json
    if ($o -isnot [pscustomobject]) { throw 'the file is not a JSON object' }
    $act = $null; $created = $null
    if ($o -and $o.PSObject.Properties['lastActivityAt'] -and $o.lastActivityAt -is [ValueType]) { $act = [long]$o.lastActivityAt }
    if ($o -and $o.PSObject.Properties['createdAt'] -and $o.createdAt -is [ValueType]) { $created = [long]$o.createdAt }
    return @{ cli = (Get-StorageFirstString $o @('cliSessionId')); title = (Get-StorageFirstString $o @('title', 'name', 'summary', 'customTitle', 'displayName'))
        cwd = (Get-StorageFirstString $o @('cwd', 'originCwd', 'workingDirectory')); activity = $act; created = $created }
}

# A title line of a transcript: custom-title, ai-title or summary. Returns @{ Kind; Text } or $null.
function Get-StorageTitleLine {
    param([string]$Line)
    if ($Line -notmatch '^\{"type":"(custom-title|ai-title|summary)"') { return $null }
    $kind = $Matches[1]
    try { $o = $Line | ConvertFrom-Json } catch { return $null }
    $text = Get-StorageFirstString $o @('customTitle', 'aiTitle', 'title', 'summary')
    if (-not $text) { return $null }
    return @{ Kind = $kind; Text = $text }
}

# Title, folder, first and last time of a Claude transcript from its head and tail only (never the middle). The regular
# expressions avoid parsing the big lines; only title lines and the first user message are parsed as JSON.
function Read-StorageClaudeJsonlMeta {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-StorageCloudPlaceholder ([IO.File]::GetAttributes($Path))) {
        return @{ title = $null; cwd = $null; first = $null; last = $null }
    }
    # A line longer than the window is cut at its edge and dropped, so a folder or a time can be missing: read again with a
    # window twice as big, up to 1 MB, until the folder and both times are found or the whole file has been read.
    $window = 65536
    while ($true) {
        $ht = Read-JsonlHeadTail -Path $Path -HeadBytes $window -TailBytes $window
        $meta = Get-StorageClaudeWindowMeta -HeadTail $ht
        if (($meta.cwd -and $meta.first -and $meta.last) -or $ht.Complete -or $window -ge 1MB) { return $meta }
        $window *= 2
    }
}

function Get-StorageClaudeWindowMeta {
    param([Parameter(Mandatory)]$HeadTail)
    $ht = $HeadTail
    $cwd = $null; $first = $null; $last = $null; $user = $null
    $titles = @{}
    $n = 0
    foreach ($l in $ht.Head) {
        if (++$n -gt 80 -or $l.Length -gt 300000) { continue }
        if (-not $cwd -and $l -match '"cwd":"((?:[^"\\]|\\.)*)"') { $cwd = [regex]::Unescape($Matches[1]) }
        if (-not $first -and $l -match '"timestamp":"([^"]+)"') { $first = ConvertTo-StorageMs $Matches[1] }
        $t = Get-StorageTitleLine $l
        if ($t -and -not $titles.ContainsKey($t.Kind)) { $titles[$t.Kind] = $t.Text }
        if (-not $user -and $l.Length -lt 20000 -and $l -match '"type":"user"' -and $l -notmatch '"isMeta":true') {
            try {
                $o = $l | ConvertFrom-Json
                $c = $o.message.content
                $text = $(if ($c -is [string]) { $c } else { (@($c) | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text })
                if ($text -and -not $text.TrimStart().StartsWith('<')) { $user = (($text -replace '\s+', ' ').Trim()); if ($user.Length -gt 80) { $user = $user.Substring(0, 80) } }
            } catch { }
        }
    }
    $tailKinds = @{}
    for ($i = $ht.Tail.Count - 1; $i -ge 0; $i--) {
        $l = $ht.Tail[$i]
        if ($l.Length -gt 300000) { continue }
        if ($null -eq $last -and $l -match '"timestamp":"([^"]+)"') { $last = ConvertTo-StorageMs $Matches[1] }
        $t = Get-StorageTitleLine $l
        if ($t -and -not $tailKinds.ContainsKey($t.Kind)) { $titles[$t.Kind] = $t.Text; $tailKinds[$t.Kind] = $true }   # a rename is appended at the end: walking back, the first one seen is the newest and the tail beats the head
    }
    $title = $(if ($titles['custom-title']) { $titles['custom-title'] } elseif ($titles['ai-title']) { $titles['ai-title'] } elseif ($titles['summary']) { $titles['summary'] } else { $user })
    return @{ title = $title; cwd = $cwd; first = $first; last = $last }
}

# Every local_*.json of every profile (account and organisation folders in between), with the cached meta.
function Get-ClaudeProfileRefs {
    param([array]$Profiles = @(), $Cache, $Cancel, $Warnings)
    $refs = New-Object Collections.Generic.List[object]
    foreach ($p in $Profiles) {
        $root = [string]$p.SessionRoot
        if (-not $root -or -not [IO.Directory]::Exists($root)) { continue }
        foreach ($acct in @(Get-StorageEntries -Dir $root | Where-Object { $_ -is [IO.DirectoryInfo] })) {
            foreach ($org in @(Get-StorageEntries -Dir $acct.FullName | Where-Object { $_ -is [IO.DirectoryInfo] })) {
                foreach ($f in @(Get-StorageEntries -Dir $org.FullName | Where-Object { $_ -is [IO.FileInfo] -and $_.Name -like 'local_*.json' })) {
                    if (Test-StorageCancel $Cancel) { return $refs.ToArray() }
                    $unreadable = $false
                    try { $meta = Get-StorageCachedMeta -Cache $Cache -Key $f.FullName -Size $f.Length -Ticks $f.LastWriteTimeUtc.Ticks -Reader { param($k) Read-StorageLocalMeta -Path $k } }
                    catch {
                        $unreadable = $true; $meta = @{ cli = $null; title = $null; cwd = $null; activity = $null; created = $null }
                        if ($null -ne $Warnings) { $Warnings.Add("Could not read $($f.FullName): $($_.Exception.Message) The sessions of this profile are marked unreadable until the next scan can read it.") }
                    }
                    $refs.Add(@{ ProfileId = [string]$p.Id; ProfileName = [string]$p.Name; Path = $f.FullName; Bytes = [long]$f.Length; Ticks = $f.LastWriteTimeUtc.Ticks; Name = $f.BaseName; Meta = $meta; Unreadable = $unreadable })
                }
            }
        }
    }
    return $refs.ToArray()
}

# Every <slug>\<id>.jsonl under projects, with its <id> folder (subagents, tool results) when there is one.
function Get-ClaudeTranscripts {
    param([string]$ProjectsDir, $Cancel)
    $found = New-Object Collections.Generic.List[object]
    if (-not $ProjectsDir -or -not [IO.Directory]::Exists($ProjectsDir)) { return $found.ToArray() }
    foreach ($slug in @(Get-StorageEntries -Dir $ProjectsDir | Where-Object { $_ -is [IO.DirectoryInfo] })) {
        if (Test-StorageCancel $Cancel) { break }
        $entries = @(Get-StorageEntries -Dir $slug.FullName)
        $dirs = @{}; foreach ($d in $entries) { if ($d -is [IO.DirectoryInfo]) { $dirs[$d.Name] = $d } }
        $seen = @{}
        foreach ($f in $entries) {
            if ($f -isnot [IO.FileInfo] -or $f.Extension -ne '.jsonl') { continue }
            $seen[$f.BaseName] = $true
            $found.Add(@{ Cli = $f.BaseName; File = $f; Dir = $dirs[$f.BaseName] })
        }
        foreach ($name in $dirs.Keys) { if (-not $seen.ContainsKey($name) -and $name -match ('\A' + (Get-StorageGuidPattern) + '\z')) { $found.Add(@{ Cli = $name; File = $null; Dir = $dirs[$name] }) } }
    }
    return $found.ToArray()
}

# The first 8 hex characters of the SHA-256 of a profile id (lower case). Codex and Antigravity keep a chat's id when a
# chat is moved between profiles, so the same id can sit in two profiles; the tag makes the keys differ without putting
# the profile name into a key (keys are stored unencrypted in the Drive index).
function Get-StorageProfileTag {
    param([Parameter(Mandatory)][string]$ProfileId)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProfileId.ToLowerInvariant())) } finally { $sha.Dispose() }
    return (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# -Tag (a profile id) makes the key <harness>:<id>.<p8>. Characters a key may not hold become '_'; the key is at most 128 long.
function New-StorageSessionBuilder {
    param([string]$Harness, [string]$Id, [string]$Tag)
    $suffix = $(if ($Tag) { '.' + (Get-StorageProfileTag -ProfileId $Tag) } else { '' })
    $safe = ($Id -replace '[^A-Za-z0-9_.-]', '_')
    if ($safe.Length + $suffix.Length -gt 128) { $safe = $safe.Substring(0, 128 - $suffix.Length) }
    return @{ Harness = $Harness; Id = $Id; Key = ($Harness + ':' + $safe + $suffix); Parts = (New-Object Collections.Generic.List[object]); Profiles = [ordered]@{}; RefTitle = $null; RefAct = [long]-1; AltTitle = $null
        Cwd = $null; Activity = [long]0; Created = $null; Flags = @{} }
}

# Builder -> StorageSession object: Bytes, State and Flags filled in.
function ConvertTo-StorageSession {
    param([Parameter(Mandatory)]$Builder, [datetime]$Now, [int]$RecentMinutes = 30)
    $bytes = [long]0; $newest = [long]0
    foreach ($p in $Builder.Parts) { $bytes += $p.Bytes; if ($p.MTimeTicks -gt $newest) { $newest = $p.MTimeTicks } }
    $window = [long]$RecentMinutes * [TimeSpan]::TicksPerMinute
    $recent = ($newest -gt 0 -and ($Now.Ticks - $newest) -lt $window)
    if (-not $recent -and $Builder.Activity -gt 0) { $nowMs = ([DateTimeOffset]$Now).ToUnixTimeMilliseconds(); $recent = (($nowMs - $Builder.Activity) -lt ([long]$RecentMinutes * 60000) -and $Builder.Activity -le $nowMs + 60000) }
    $title = $(if ($Builder.RefTitle) { $Builder.RefTitle } elseif ($Builder.AltTitle) { $Builder.AltTitle } else { $Builder.Id })
    $profiles = @($Builder.Profiles.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $Builder.Profiles[$_] } })
    $flags = @{ IsCliOnly = $false; HasZst = $false; Trimmable = $false; ArchivedRef = $false; CodexArchived = $false; NoTranscript = $false; NoFile = $false }
    foreach ($k in $Builder.Flags.Keys) { $flags[$k] = $Builder.Flags[$k] }
    return [pscustomobject]@{
        Harness = $Builder.Harness; Key = $Builder.Key; Id = $Builder.Id; Title = $title; Cwd = $Builder.Cwd
        LastActivity = $(if ($Builder.Activity -gt 0) { [long]$Builder.Activity } else { $null }); Created = $Builder.Created
        Profiles = $profiles; Parts = @($Builder.Parts | ForEach-Object { [pscustomobject]$_ }); Bytes = $bytes; State = $(if ($recent) { 'recent' } else { 'idle' }); Flags = $flags
    }
}

# One session per transcript id: the jsonl, its folder, and the local file of every profile that refers to it. A session
# with no local file at all is CLI-only. Sessions come back in no particular order.
function Get-ClaudeStorageSessions {
    param([string]$ProjectsDir, [array]$Profiles = @(), $Cache, $Cancel, $Progress, $Warnings, [int]$ItemDelayMs = 0, [datetime]$Now = [DateTime]::UtcNow, [int]$RecentMinutes = 30)
    $refs = @(Get-ClaudeProfileRefs -Profiles $Profiles -Cache $Cache -Cancel $Cancel -Warnings $Warnings)
    $transcripts = @(Get-ClaudeTranscripts -ProjectsDir $ProjectsDir -Cancel $Cancel)
    Set-StorageProgress -Progress $Progress -Phase 'claude' -Total ($refs.Count + $transcripts.Count)
    $workCache = $(if ($Cache) { $Cache } else { New-StorageCache })
    $counted = @{}
    # -ItemDelayMs is only raised by tests to pace the loop one item at a time.
    if (-not $ItemDelayMs -and -not (Test-StorageCancel $Cancel)) {
        $misses = New-Object Collections.Generic.List[object]
        $seenMiss = @{}
        foreach ($t in $transcripts) {
            if (-not $t.File) { continue }
            $f = $t.File
            if ((Test-StorageCloudPlaceholder $f.Attributes) -or $seenMiss.ContainsKey($f.FullName)) { continue }
            $e = $workCache.Entries[$f.FullName]
            if ($e -and [long]$e['size'] -eq $f.Length -and [long]$e['mtimeTicks'] -eq $f.LastWriteTimeUtc.Ticks) { continue }
            $seenMiss[$f.FullName] = $true
            $misses.Add(@{ Key = $f.FullName; Size = [long]$f.Length; Ticks = $f.LastWriteTimeUtc.Ticks })
        }
        if ($misses.Count -gt 1) {
            Read-StorageClaudeMetaParallel -Misses $misses.ToArray() -Cache $workCache -Cancel $Cancel -Progress $Progress -Counted $counted
        }
    }
    $by = @{}
    foreach ($t in $transcripts) {
        if (Test-StorageCancel $Cancel) { break }
        if ($ItemDelayMs) { Start-Sleep -Milliseconds $ItemDelayMs }
        if (-not $by.ContainsKey($t.Cli)) { $by[$t.Cli] = New-StorageSessionBuilder -Harness 'claude' -Id $t.Cli }
        $b = $by[$t.Cli]
        if ($t.File) {
            $f = $t.File
            Add-StoragePart -List $b.Parts -Role 'transcript' -Path $f.FullName -Bytes $f.Length -Ticks $f.LastWriteTimeUtc.Ticks
            if (-not (Test-StorageCloudPlaceholder $f.Attributes)) {
                $m = Get-StorageCachedMeta -Cache $workCache -Key $f.FullName -Size $f.Length -Ticks $f.LastWriteTimeUtc.Ticks -Reader { param($k) Read-StorageClaudeJsonlMeta -Path $k }
                if (-not $b.AltTitle) { $b.AltTitle = $m['title'] }
                if (-not $b.Cwd) { $b.Cwd = $m['cwd'] }
                if ($m['last'] -and [long]$m['last'] -gt $b.Activity) { $b.Activity = [long]$m['last'] }
                if ($m['first'] -and -not $b.Created) { $b.Created = [long]$m['first'] }
            }
        } else { $b.Flags['NoTranscript'] = $true }
        if ($t.Dir) {
            $d = Measure-StorageDir -Path $t.Dir.FullName -Cancel $Cancel
            Add-StoragePart -List $b.Parts -Role 'cli-dir' -Path $t.Dir.FullName -Bytes $d.Bytes -Kind 'dir' -Files $d.Files -Ticks $d.NewestTicks
        }
        if (-not ($t.File -and $counted.ContainsKey($t.File.FullName))) { Set-StorageProgress -Progress $Progress -Done 1 }
    }
    foreach ($r in $refs) {
        $id = $(if ($r.Meta['cli']) { [string]$r.Meta['cli'] } else { [string]$r.Name })
        if (-not $by.ContainsKey($id)) { $by[$id] = New-StorageSessionBuilder -Harness 'claude' -Id $id; $by[$id].Flags['NoTranscript'] = $true }
        $b = $by[$id]
        Add-StoragePart -List $b.Parts -Role 'profile-meta' -Path $r.Path -Bytes $r.Bytes -Ticks $r.Ticks -ProfileId $r.ProfileId
        $b.Profiles[$r.ProfileId] = $r.ProfileName
        if ($r.Unreadable) { $b.Flags['DbUnreadable'] = $true }
        $act = $(if ($null -ne $r.Meta['activity']) { [long]$r.Meta['activity'] } else { [long]([DateTimeOffset][DateTime]::new($r.Ticks, [DateTimeKind]::Utc)).ToUnixTimeMilliseconds() })
        if ($r.Meta['title'] -and $act -gt $b.RefAct) { $b.RefTitle = [string]$r.Meta['title']; $b.RefAct = $act }
        if ($r.Meta['cwd']) { $b.Cwd = [string]$r.Meta['cwd'] }
        if ($act -gt $b.Activity) { $b.Activity = $act }
        if ($r.Meta['created']) { $b.Created = [long]$r.Meta['created'] }
        Set-StorageProgress -Progress $Progress -Done 1
    }
    foreach ($b in $by.Values) {
        $b.Flags['IsCliOnly'] = ($b.Profiles.Count -eq 0)
        if ($b.Flags['IsCliOnly'] -and @($refs | Where-Object { $_.Unreadable }).Count) { $b.Flags['DbUnreadable'] = $true }   # it may belong to the profile file that could not be read
        $b.Flags['Trimmable'] = [bool]@($b.Parts | Where-Object { $_.Role -eq 'transcript' }).Count
        if (-not $b.AltTitle -and -not $b.RefTitle -and $b.Id.Length -ge 8) { $b.AltTitle = 'Chat ' + $b.Id.Substring(0, 8) }
        ConvertTo-StorageSession -Builder $b -Now $Now -RecentMinutes $RecentMinutes
    }
}

# ---- Codex ------------------------------------------------------------------------------------------------------------

# The size and mtime a database is cached by: the file and its -wal together, because the app writes the -wal first.
function Get-StorageDbSignature {
    param([Parameter(Mandatory)][string]$Path)
    $size = [long]0; $ticks = [long]0
    foreach ($p in $Path, ($Path + '-wal')) {
        if ([IO.File]::Exists($p)) { $fi = New-Object IO.FileInfo $p; $size += $fi.Length; if ($fi.LastWriteTimeUtc.Ticks -gt $ticks) { $ticks = $fi.LastWriteTimeUtc.Ticks } }
    }
    return @{ Size = $size; Ticks = $ticks }
}

# All threads of a state_5.sqlite, archived ones included, from a snapshot copy that is deleted afterwards.
function Read-StorageCodexRows {
    param([Parameter(Mandatory)][string]$Path)
    $snap = $null
    try {
        $snap = Copy-SqliteSnapshot -Path $Path
        $h = Open-SqliteReadOnly -Path $snap
        try {
            $rows = @(Invoke-SqliteQuery -Handle $h -Sql 'select id, cwd, title, name, archived, created_at, updated_at, updated_at_ms, source from threads')
        } finally { Close-Sqlite -Handle $h }
        return @($rows | ForEach-Object { @{ id = [string]$_.id; cwd = (ConvertFrom-CodexPath $_.cwd); title = $_.title; name = $_.name; archived = [long]$_.archived
            created = $_.created_at; updated = $_.updated_at; updatedMs = $_.updated_at_ms; source = [string]$_.source } })
    } finally {
        if ($snap -and [IO.Directory]::Exists((Split-Path -Parent $snap))) { Remove-Item -LiteralPath (Split-Path -Parent $snap) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# One session per Codex thread: the rollout (.jsonl or .jsonl.zst, under sessions or archived_sessions) and the threads
# row. Thread rows without a file and files without a row are both listed.
function Get-CodexStorageSessions {
    param([array]$Homes = @(), $Cache, $Cancel, $Progress, $Warnings, [int]$ItemDelayMs = 0, [datetime]$Now = [DateTime]::UtcNow, [int]$RecentMinutes = 30)
    foreach ($h in $Homes) {
        $cxHome = [string]$h.Home
        if (-not $cxHome -or -not [IO.Directory]::Exists($cxHome)) { continue }
        $files = @{}
        foreach ($sub in 'sessions', 'archived_sessions') {
            $dir = Join-Path $cxHome $sub
            if (-not [IO.Directory]::Exists($dir)) { continue }
            foreach ($f in @(Get-StorageFilesRecursive -Path $dir -Cancel $Cancel)) {
                if ($f.Name -match ('-(' + (Get-StorageGuidPattern) + ')\.jsonl(\.zst)?\z')) { if (-not $files.ContainsKey($Matches[1])) { $files[$Matches[1]] = New-Object Collections.Generic.List[object] }; $files[$Matches[1]].Add($f) }
            }
        }
        $db = Join-Path $cxHome 'state_5.sqlite'
        $rows = @(); $unreadable = $false
        if ([IO.File]::Exists($db)) {
            $sig = Get-StorageDbSignature -Path $db
            try { $rows = @(Get-StorageCachedMeta -Cache $Cache -Key $db -Size $sig.Size -Ticks $sig.Ticks -Reader { param($k) Read-StorageCodexRows -Path $k }) }
            catch { $unreadable = $true; if ($null -ne $Warnings) { $Warnings.Add("Codex database of profile '$($h.Name)' could not be read: $($_.Exception.Message)") } }
        }
        Set-StorageProgress -Progress $Progress -Phase 'codex' -Total ([Math]::Max($rows.Count, $files.Count))
        $byId = @{}; foreach ($r in $rows) { $byId[[string]$r['id']] = $r }
        foreach ($id in @($byId.Keys) + @($files.Keys | Where-Object { -not $byId.ContainsKey($_) })) {
            if (Test-StorageCancel $Cancel) { return }
            if ($ItemDelayMs) { Start-Sleep -Milliseconds $ItemDelayMs }
            $row = $byId[$id]
            $b = New-StorageSessionBuilder -Harness 'codex' -Id $id -Tag ([string]$h.Id)
            if ($unreadable) { $b.Flags['DbUnreadable'] = $true }
            $b.Profiles[[string]$h.Id] = [string]$h.Name
            $mine = $(if ($files.ContainsKey($id)) { $files[$id].ToArray() } else { @() })
            foreach ($f in $mine) { if ($f) { Add-StoragePart -List $b.Parts -Role 'rollout' -Path $f.FullName -Bytes $f.Length -Ticks $f.LastWriteTimeUtc.Ticks; if ($f.Name.EndsWith('.zst')) { $b.Flags['HasZst'] = $true } } }
            if ($row) {
                Add-StoragePart -List $b.Parts -Role 'threads-row' -Path $db -Kind 'row' -Files 0
                $b.AltTitle = $(if ($row['name']) { [string]$row['name'] } elseif ($row['title']) { [string]$row['title'] } else { $null })
                $b.Cwd = $(if ($row['cwd']) { [string]$row['cwd'] } else { $null })
                $b.Activity = $(if ($null -ne $row['updatedMs']) { [long]$row['updatedMs'] } elseif ($null -ne $row['updated']) { [long]([double]$row['updated'] * 1000) } else { [long]0 })
                if ($row['created'] -and [long]$row['created'] -gt 0) { $b.Created = [long]([double]$row['created'] * 1000) }
                $b.Flags['CodexArchived'] = ([long]$row['archived'] -ne 0)
                $b.Flags['Subagent'] = ([string]$row['source']).Contains('subagent')
            } else { $b.Flags['NoRow'] = $true }
            if (-not @($b.Parts | Where-Object { $_.Role -eq 'rollout' }).Count) { $b.Flags['NoFile'] = $true }
            $b.Flags['Trimmable'] = ([bool]@($b.Parts | Where-Object { $_.Role -eq 'rollout' }).Count -and -not $b.Flags['HasZst'])
            Set-StorageActivityFromParts -Builder $b
            ConvertTo-StorageSession -Builder $b -Now $Now -RecentMinutes $RecentMinutes
            Set-StorageProgress -Progress $Progress -Done 1
        }
    }
}

# ---- the inventory and the statistics --------------------------------------------------------------------------------

# Is Path the folder Dir or below it (whole folder names, case ignored)?
function Test-StorageUnderDir {
    param([string]$Path, [string]$Dir)
    if (-not $Path -or -not $Dir) { return $false }
    $p = $Path.TrimEnd('\'); $d = $Dir.TrimEnd('\')
    return ($p -ieq $d -or $p.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-StorageProfileFolder {
    param([string]$Harness, $P, [string]$DataDir, $Cancel)
    $m = $(if ($DataDir -and [IO.Directory]::Exists($DataDir)) { Measure-StorageDir -Path $DataDir -Cancel $Cancel } else { [pscustomobject]@{ Bytes = [long]0; Files = 0 } })
    $bytes = [long]$m.Bytes; $files = [int]$m.Files
    # A Claude profile can keep its chat files outside its data folder (the Default profile of the Store app): measure that too.
    $sr = [string]$P.SessionRoot
    if ($sr -and [IO.Directory]::Exists($sr) -and -not (Test-StorageUnderDir -Path $sr -Dir $DataDir)) { $s = Measure-StorageDir -Path $sr -Cancel $Cancel; $bytes += [long]$s.Bytes; $files += [int]$s.Files }
    return [pscustomobject]@{ Harness = $Harness; Id = [string]$P.Id; Name = [string]$P.Name; DataDir = $DataDir; SessionRoot = $sr; DataBytes = $bytes; DataFiles = $files; IsDefault = [bool]$P.IsDefault }
}

# Walks the three harnesses and returns @{ Sessions; Profiles; Totals; ScannedAt; Files; Reads; Seconds; Cancelled }.
# Progress and CancelToken are the synchronized hashtables of Start-StorageScan (both optional). With a Cache a file whose
# size and mtime did not change is not opened again. -ItemDelayMs is only raised by tests.
function Get-StorageInventory {
    param([Parameter(Mandatory)][hashtable]$Roots, $Cache, $Progress, $CancelToken, [int]$RecentMinutes = 30, [int]$ItemDelayMs = 0)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $now = [DateTime]::UtcNow
    if ($Cache) { $Cache.Seen = @{} }
    $sessions = New-Object Collections.Generic.List[object]
    $profiles = New-Object Collections.Generic.List[object]
    $warnings = New-Object Collections.Generic.List[string]
    $common = @{ Cache = $Cache; Cancel = $CancelToken; Progress = $Progress; Warnings = $warnings; ItemDelayMs = $ItemDelayMs; Now = $now; RecentMinutes = $RecentMinutes }
    foreach ($s in @(Get-ClaudeStorageSessions -ProjectsDir ([string]$Roots['ClaudeProjects']) -Profiles @($Roots['ClaudeProfiles']) @common)) { $sessions.Add($s) }
    foreach ($s in @(Get-CodexStorageSessions -Homes @($Roots['CodexHomes']) @common)) { $sessions.Add($s) }
    foreach ($s in @(Get-AgyStorageSessions -Dirs @($Roots['AgyDirs']) @common)) { $sessions.Add($s) }
    if ($Progress) { $Progress['Warnings'] = $warnings.ToArray() }
    Set-StorageProgress -Progress $Progress -Phase 'folders'
    foreach ($p in @($Roots['ClaudeProfiles'])) { if ($p -and -not (Test-StorageCancel $CancelToken)) { $profiles.Add((Get-StorageProfileFolder -Harness 'claude' -P $p -DataDir ([string]$p.DataDir) -Cancel $CancelToken)) } }
    foreach ($p in @($Roots['CodexHomes'])) { if ($p -and -not (Test-StorageCancel $CancelToken)) { $profiles.Add((Get-StorageProfileFolder -Harness 'codex' -P $p -DataDir ([string]$p.Home) -Cancel $CancelToken)) } }
    foreach ($p in @($Roots['AgyDirs'])) { if ($p -and -not (Test-StorageCancel $CancelToken)) { $profiles.Add((Get-StorageProfileFolder -Harness 'antigravity' -P $p -DataDir ([string]$p.DataDir) -Cancel $CancelToken)) } }
    $cancelled = Test-StorageCancel $CancelToken
    if ($Cache -and -not $cancelled) { Remove-StorageCacheUnseen -Cache $Cache }
    $by = @{ claude = @{ Sessions = 0; Bytes = [long]0 }; codex = @{ Sessions = 0; Bytes = [long]0 }; antigravity = @{ Sessions = 0; Bytes = [long]0 } }
    $bytes = [long]0; $files = 0
    foreach ($s in $sessions) {
        $bytes += $s.Bytes; $by[$s.Harness].Sessions++; $by[$s.Harness].Bytes += $s.Bytes
        foreach ($p in $s.Parts) { $files += [int]$p.Files }
    }
    return [pscustomobject]@{
        Sessions = $sessions.ToArray(); Profiles = $profiles.ToArray(); Totals = @{ Sessions = $sessions.Count; Bytes = $bytes; Files = $files; ByHarness = $by }
        ScannedAt = (Get-Date); Files = $files; Reads = $(if ($Cache) { $Cache.Reads } else { 0 }); Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); Cancelled = $cancelled; Warnings = $warnings.ToArray()
    }
}

# Sizes by harness, by profile and for the CLI-only group, with every session counted once. A profile's SessionBytes holds
# every session it refers to, SharedBytes the ones another profile refers to as well, so the profiles add up to more than
# the harness total. AppDataBytes is the profile folder minus the session parts that sit inside it.
function Get-StorageStats {
    param([Parameter(Mandatory)]$Inventory)
    $by = @{ claude = @{ Sessions = 0; Bytes = [long]0 }; codex = @{ Sessions = 0; Bytes = [long]0 }; antigravity = @{ Sessions = 0; Bytes = [long]0 } }
    $archive = @{ Sessions = 0; Bytes = [long]0; ZipBytes = [long]0; Saved = [long]0 }
    $cli = @{ Sessions = 0; Bytes = [long]0 }
    $live = New-Object Collections.Generic.List[object]
    foreach ($s in @($Inventory.Sessions)) {
        if ($s.Flags.ArchivedRef) { $archive.Sessions++; $archive.Bytes += $s.Bytes; if ($s.PSObject.Properties['ZipBytes']) { $archive.ZipBytes += $s.ZipBytes }; continue }
        $live.Add($s)
        if ($by.ContainsKey($s.Harness)) { $by[$s.Harness].Sessions++; $by[$s.Harness].Bytes += $s.Bytes }
        if ($s.Flags.IsCliOnly) { $cli.Sessions++; $cli.Bytes += $s.Bytes }
    }
    $archive.Saved = $archive.Bytes - $archive.ZipBytes
    $perProfile = foreach ($p in @($Inventory.Profiles)) {
        $mine = @($live | Where-Object { $_.Harness -eq $p.Harness -and @($_.Profiles | Where-Object { $_.Id -eq $p.Id }).Count })
        $sr = $(if ($p.PSObject.Properties['SessionRoot']) { [string]$p.SessionRoot } else { '' })
        $inside = [long]0
        foreach ($s in $mine) { foreach ($part in $s.Parts) { if ((Test-StorageUnderDir -Path ([string]$part.Path) -Dir ([string]$p.DataDir)) -or (Test-StorageUnderDir -Path ([string]$part.Path) -Dir $sr)) { $inside += $part.Bytes } } }
        $shared = [long]0; $sum = [long]0
        foreach ($s in $mine) { $sum += $s.Bytes; if (@($s.Profiles).Count -gt 1) { $shared += $s.Bytes } }
        [pscustomobject]@{ Harness = $p.Harness; Id = $p.Id; Name = $p.Name; Sessions = $mine.Count; SessionBytes = $sum; SharedBytes = $shared
            AppDataBytes = [long][Math]::Max(0, $p.DataBytes - $inside); DataBytes = $p.DataBytes }
    }
    return @{ ByHarness = $by; ByProfile = @($perProfile); CliOnly = $cli; Archive = $archive }
}

# The real roots for the UI, from the adapters' own functions. Not used in tests (they would name real folders).
# -Config may carry ClaudeHome to point the transcripts somewhere else.
function Get-StorageRootsFromConfig {
    param($Config)
    $claudeHome = $(if ($Config -and $Config['ClaudeHome']) { [string]$Config['ClaudeHome'] } else { Join-Path $env:USERPROFILE '.claude' })
    $roots = @{ ClaudeProjects = (Join-Path $claudeHome 'projects'); ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @() }
    try {
        $roots.ClaudeProfiles = @(Get-ProfileList -SkipStatus | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; SessionRoot = (Get-CodeSessionRoot -TargetProfile $_); DataDir = $_.Path; IsDefault = [bool]$_.IsDefault } })
    } catch { }
    try { $roots.CodexHomes = @(Get-CodexProfiles | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; Home = $_.CodexHome; IsDefault = [bool]$_.IsDefault } }) } catch { }
    try { $roots.AgyDirs = @(Find-AntigravityInstall | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; DataDir = $_.DataDir; IsDefault = $false } }) } catch { }
    return $roots
}
