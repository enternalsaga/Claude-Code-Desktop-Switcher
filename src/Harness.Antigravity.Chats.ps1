# Harness.Antigravity.Chats.ps1 - Antigravity adapter, part 2: chat list, transcript, export, native import, handoff.
# A conversation is conversations\<id>.db (SQLite, protobuf blobs; the old .pb files are encrypted) plus brain\<id>\.
# Always works on snapshots of the app's databases. Needs Harness.Core.ps1, Harness.Sqlite.ps1 and
# Harness.Antigravity.Proto.ps1 (db fallback). Nothing here reads credentials.

# file:///h:/x%20y -> H:\x y. Returns $null for anything that is not a file URI.
function ConvertFrom-AgyWorkspaceUri {
    param([string]$Uri)
    if (-not $Uri -or $Uri -notmatch '^file:///(.+)$') { return $null }
    $path = [Uri]::UnescapeDataString($Matches[1]).Replace('/', '\')
    if ($path -match '^[A-Za-z]:') { $path = $path.Substring(0, 1).ToUpperInvariant() + $path.Substring(1) }
    return $path
}

# The first workspace of a summaries row (workspace_uris is a JSON array of file URIs).
function Get-AgyFirstWorkspace {
    param([string]$WorkspaceUris)
    if (-not $WorkspaceUris) { return $null }
    try { $parsed = $WorkspaceUris | ConvertFrom-Json } catch { return $null }
    $uris = @($parsed)   # a separate step: Windows PowerShell 5.1 hands the whole JSON array down as one object
    if (-not $uris.Count) { return $null }
    return (ConvertFrom-AgyWorkspaceUri -Uri ([string]$uris[0]))
}

# Title fallback: the first line of the first top-level brain\<id>\*.md, without markdown heading marks.
function Get-AgyBrainTitle {
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$Id)
    $dir = Join-Path $DataDir "brain\$Id"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    foreach ($md in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object Name)) {
        # Get-Content closes the file even when we stop early; a lazy ReadLines enumerator would keep it open.
        $line = Get-Content -LiteralPath $md.FullName -Encoding UTF8 -TotalCount 12 | Where-Object { $_.Trim() } | Select-Object -First 1
        if ($line) { return ($line -replace '^\s*#+\s*', '').Trim() }
    }
    return $null
}

# id -> summaries row, read from a snapshot of conversation_summaries.db. $null when the file is missing or cannot be
# read (for example winsqlite3 without FTS5 support), so the caller falls back to the files.
function Get-AgySummaryRows {
    param([Parameter(Mandatory)][string]$DataDir)
    $path = Join-Path $DataDir 'conversation_summaries.db'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $snap = $null
    try {
        $snap = Copy-SqliteSnapshot -Path $path
        $db = Open-SqliteReadOnly -Path $snap
        try {
            $rows = @{}
            $sql = 'select conversation_id, title, preview, last_modified_time, workspace_uris, parent_conversation_id, status from conversation_summaries'
            foreach ($r in Invoke-SqliteQuery -Handle $db -Sql $sql) { $rows[[string]$r.conversation_id] = $r }
            return $rows
        } finally { Close-Sqlite -Handle $db }
    } catch { return $null } finally {
        if ($snap -and (Test-Path -LiteralPath (Split-Path -Parent $snap))) { Remove-Item -LiteralPath (Split-Path -Parent $snap) -Recurse -Force }
    }
}

# Unix milliseconds of a summaries timestamp ("2026-11-11 07:08:46.2135894+00:00") or of a file's mtime.
function ConvertTo-AgyActivity {
    param($Text, [datetime]$Fallback)
    $stamp = [datetimeoffset]::MinValue
    if ($Text -and [datetimeoffset]::TryParse([string]$Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$stamp)) {
        return [double]$stamp.ToUnixTimeMilliseconds()
    }
    return [double]([datetimeoffset]$Fallback.ToUniversalTime()).ToUnixTimeMilliseconds()
}

# One chat per local conversation file (.db, or the old encrypted .pb). Metadata comes from conversation_summaries.db
# when the app has one (the IDE has none): rows without a local file are not listed, because they cannot be exported.
function Get-AntigravityChats {
    param([Parameter(Mandatory)]$Profile)
    $convDir = Join-Path $Profile.DataDir 'conversations'
    if (-not (Test-Path -LiteralPath $convDir -PathType Container)) { return }
    $files = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $convDir -File | Where-Object { $_.Extension -in '.db', '.pb' })) {
        if ($f.Extension -eq '.db' -or -not $files.ContainsKey($f.BaseName)) { $files[$f.BaseName] = $f }
    }
    $summaries = Get-AgySummaryRows -DataDir $Profile.DataDir
    foreach ($id in ($files.Keys | Sort-Object)) {
        $file = $files[$id]
        $row = if ($summaries -and $summaries.ContainsKey($id)) { $summaries[$id] } else { $null }
        $title = $null; $cwd = $null; $parent = $null; $lastModified = $null
        if ($row) {
            if ($row.title) { $title = [string]$row.title } elseif ($row.preview) { $title = [string]$row.preview }
            $cwd = Get-AgyFirstWorkspace -WorkspaceUris $row.workspace_uris
            if ($row.parent_conversation_id) { $parent = [string]$row.parent_conversation_id }
            $lastModified = $row.last_modified_time
        }
        if (-not $title) { $title = Get-AgyBrainTitle -DataDir $Profile.DataDir -Id $id }
        if (-not $title) { $title = $id }
        $activity = ConvertTo-AgyActivity -Text $lastModified -Fallback $file.LastWriteTime
        [pscustomobject]@{
            ChatId = $id; Title = $title; Cwd = $cwd; Updated = ([datetimeoffset]::FromUnixTimeMilliseconds([int64]$activity)).LocalDateTime
            Activity = $activity; Parent = $parent; Kind = $Profile.Kind; Format = $file.Extension.TrimStart('.'); Profile = $Profile
        }
    }
}

# --- Transcript (brain\<id>\.system_generated\logs\transcript.jsonl, written by the app itself) ---------------------

# The one-line argument of a tool call: its own summary first, then command or path. Takes the args object or its JSON.
function Get-AgyToolArg {
    param([string]$Json, $ToolArgs)
    if ($Json) {
        try { $ToolArgs = $Json | ConvertFrom-Json } catch { return (($Json -replace '\s+', ' ').Trim()) }
    }
    if (-not $ToolArgs -or $ToolArgs -is [string]) { return [string]$ToolArgs }
    $props = @($ToolArgs.PSObject.Properties)
    foreach ($name in 'toolSummary', 'CommandLine', 'command', 'TargetFile', 'AbsolutePath', 'Path', 'Query', 'Url') {
        $hit = $props | Where-Object { $_.Name -ieq $name -and $_.Value -is [string] -and $_.Value } | Select-Object -First 1
        if ($hit) { return [string]$hit.Value }
    }
    $first = $props | Where-Object { $_.Value -is [string] -and $_.Value } | Select-Object -First 1
    if ($first) { return [string]$first.Value }
    return ''
}

# Text of a USER_INPUT step: what is inside <USER_REQUEST>, or the content without its <ADDITIONAL_METADATA> block.
function Get-AgyUserText {
    param([AllowEmptyString()][string]$Content)
    $m = [regex]::Match($Content, '(?s)<USER_REQUEST>(.*?)</USER_REQUEST>')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ([regex]::Replace($Content, '(?s)<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>', '')).Trim()
}

# Step types that carry no conversation: dropped from the transcript.
function Get-AgySystemStepTypes {
    return @('SYSTEM_MESSAGE', 'CHECKPOINT', 'CONVERSATION_HISTORY', 'ERROR_MESSAGE')
}

# Normalizes the app's transcript.jsonl into {role, text, ts, tool{name,arg,output}} entries. thinking is dropped.
# A tool call comes from PLANNER_RESPONSE.tool_calls; the content of the following tool step becomes its output.
# Lines that are not valid JSON are skipped and counted in $Skipped (a [ref]).
function ConvertFrom-AgyTranscriptJsonl {
    param([Parameter(Mandatory)][string]$Path, [ref]$Skipped, [ref]$Steps)
    $entries = New-Object Collections.Generic.List[object]
    $pending = New-Object Collections.Generic.Queue[object]
    $system = Get-AgySystemStepTypes
    $bad = 0; $lineCount = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { $bad++; continue }
        if ($o) { $lineCount++ }   # every readable line is one step, system steps included (the same unit the db's steps table counts)
        if (-not $o -or $system -contains $o.type) { continue }
        switch ($o.type) {
            'USER_INPUT' {
                $text = Get-AgyUserText -Content ([string]$o.content)
                if ($text) { $entries.Add(@{ role = 'user'; text = $text; ts = $o.created_at }) }
            }
            'PLANNER_RESPONSE' {
                if ($o.content) { $entries.Add(@{ role = 'assistant'; text = [string]$o.content; ts = $o.created_at }) }
                foreach ($call in @($o.tool_calls)) {
                    if (-not $call) { continue }
                    $t = @{ role = 'tool'; text = ''; ts = $o.created_at; tool = @{ name = [string]$call.name; arg = (Get-AgyToolArg -ToolArgs $call.args); output = '' } }
                    $entries.Add($t); $pending.Enqueue($t)
                }
            }
            default {
                # any other step is a tool result: it belongs to the oldest call that has no output yet
                if ($o.content -and $pending.Count) { $pending.Dequeue().tool.output = [string]$o.content }
            }
        }
    }
    if ($Skipped) { $Skipped.Value = $bad }
    if ($Steps) { $Steps.Value = $lineCount }
    return $entries.ToArray()
}

# --- Export (bundle) --------------------------------------------------------------------------------------------

# Files under brain\<id>\ that go into a bundle: everything except browser_recordings (can be huge). @{Role;Path;SourcePath}.
function Get-AgyBrainFiles {
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$Id)
    $dir = Join-Path $DataDir "brain\$Id"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $prefix = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\') + '\'
    # walked by hand: Get-ChildItem -Recurse follows junctions and symlinks out of the chat's folder
    $pending = New-Object Collections.Generic.Stack[string]; $pending.Push($dir)
    while ($pending.Count) {
        foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { if ($item.Name -ne 'browser_recordings') { $pending.Push($item.FullName) }; continue }
            $rel = $item.FullName.Substring($prefix.Length)
            @{ Role = 'native'; Path = ("native/brain/$Id/" + $rel.Replace('\', '/')); SourcePath = $item.FullName }
        }
    }
}

function Get-AgyStepCount {
    param([Parameter(Mandatory)][string]$SnapshotDb)
    try {
        $db = Open-SqliteReadOnly -Path $SnapshotDb
        try { return [int]((Invoke-SqliteQuery -Handle $db -Sql 'select count(*) as n from steps') | Select-Object -First 1).n } finally { Close-Sqlite -Handle $db }
    } catch { return $null }
}

# Builds <OutPath> (a .hbundle.zip) for one chat. native\ holds conversations\<id>.db (+ -wal, taken from a snapshot,
# never checkpointed; -shm is rebuilt by SQLite) and brain\<id>\**. A .pb chat (old, encrypted) has only the brain files
# and no transcript. A database over MaxDbMB is refused unless -AllowLarge: nothing is cut down silently.
function Export-AgyChat {
    param(
        [Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$OutPath,
        [double]$MaxDbMB = 50, [switch]$AllowLarge,
        [string]$HarnessVersion = '', [string]$MachineId = '', [string]$MachineName = $env:COMPUTERNAME,
        [hashtable]$PathRoots = @{}, $PreviousBundleId = $null
    )
    $id = $Chat.ChatId; $dataDir = $Chat.Profile.DataDir
    $files = @(Get-AgyBrainFiles -DataDir $dataDir -Id $id)
    $entries = @(); $stepCount = $null; $snapDir = $null; $transcriptSource = 'none'
    try {
        if ($Chat.Format -eq 'db') {
            $dbPath = Join-Path $dataDir "conversations\$id.db"
            $mb = (Get-Item -LiteralPath $dbPath).Length / 1MB
            if ($mb -gt $MaxDbMB -and -not $AllowLarge) { throw ("Conversation database is {0:N1} MB, over the {1} MB limit. Export it again with the large-file option." -f $mb, $MaxDbMB) }
            $snap = Copy-SqliteSnapshot -Path $dbPath; $snapDir = Split-Path -Parent $snap
            $files += @(@{ Role = 'native'; Path = "native/conversations/$id.db"; SourcePath = $snap })
            if (Test-Path -LiteralPath ($snap + '-wal')) { $files += @(@{ Role = 'native'; Path = "native/conversations/$id.db-wal"; SourcePath = ($snap + '-wal') }) }
            # stepCount and the transcript come from the same source: the app's transcript.jsonl when there is one, else the db
            $jsonl = $files | Where-Object { $_.Path -like "native/brain/$id/.system_generated/logs/transcript.jsonl" } | Select-Object -First 1
            if ($jsonl) {
                $jsonlSteps = 0
                $entries = @(ConvertFrom-AgyTranscriptJsonl -Path $jsonl.SourcePath -Steps ([ref]$jsonlSteps))
                $stepCount = $jsonlSteps; $transcriptSource = 'jsonl'
            } else {
                $entries = @(ConvertFrom-AgyDb -Path $dbPath)
                $stepCount = Get-AgyStepCount -SnapshotDb $snap; $transcriptSource = 'db'
            }
        }
        # the core helpers reject an empty entry list, so an empty transcript gets a one-line note in transcript.md only
        $note = @(@{ role = 'user'; text = '(No transcript is available for this conversation; see the listed artifacts.)'; ts = $null })
        $mdEntries = $(if ($entries.Count) { $entries } else { $note })
        $entries = $(if ($entries.Count) { @(Protect-TranscriptEntries -Entries $entries) } else { @() })
        $findings = 0
        foreach ($f in $files) { if ($f.SourcePath -match '\.(jsonl?|txt|md|log)$') { $findings += Measure-SecretFindings -Path $f.SourcePath } }
        $artifacts = @($files | Where-Object { $_.Path -match "^native/brain/$([regex]::Escape($id))/[^/]+\.md$" } | ForEach-Object { $_.Path.Split('/')[-1] })
        $md = ConvertTo-HandoffMarkdown -Entries $mdEntries -Harness 'antigravity' -Title $Chat.Title -Cwd $Chat.Cwd -Artifacts $artifacts
        # a trailing newline also keeps the file non-empty: the bundle hasher rejects a zero-length byte array
        $jsonLines = (($entries | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }) -join "`n") + "`n"
        $source = @{
            harness = 'antigravity'; harnessVersion = $HarnessVersion; profileLabel = $Chat.Profile.Name; machineId = $MachineId; machineName = $MachineName
            chatId = $id; parentChatId = $Chat.Parent; title = $Chat.Title
            cwd = $(if ($Chat.Cwd) { ConvertTo-CwdRef -Path $Chat.Cwd -PathRoots $PathRoots } else { @{ absolute = $null; root = $null; relative = $null } })
            createdAt = $null; lastActivityAt = $Chat.Activity
            antigravity = @{ kind = $Chat.Kind; format = $Chat.Format; stepCount = $stepCount; transcriptSource = $transcriptSource }
        }
        $files += @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = $md }, @{ Role = 'transcript'; Path = 'transcript.jsonl'; Content = $jsonLines })
        return New-HarnessBundle -OutPath $OutPath -Source $source -Files $files -PreviousBundleId $PreviousBundleId `
            -Redaction @{ scanned = $true; findings = $findings; transcriptRedacted = $true }
    } finally {
        if ($snapDir -and (Test-Path -LiteralPath $snapDir)) { Remove-Item -LiteralPath $snapDir -Recurse -Force }
    }
}

# --- Native import ----------------------------------------------------------------------------------------------

# Antigravity conversation ids are UUIDs; anything else from a bundle is refused.
function Test-AgyConversationId {
    param([string]$Id)
    return [bool]($Id -match '\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z')
}

# True when Path is strictly inside Root (not Root itself, not outside it).
function Test-AgyPathBelow {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    return ($p.Length -gt $r.Length -and $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase))
}

# Copies a file through a temp name in the same folder, so the target is never left half written.
function Copy-AgyFileAtomic {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    New-Item -ItemType Directory -Path (Split-Path -Parent $To) -Force | Out-Null
    $tmp = $To + '.tmp-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $From -Destination $tmp
    Move-Item -LiteralPath $tmp -Destination $To -Force
}

# Puts a bundle's conversation into the app's data dir. Returns copied | updated | exists | kind-mismatch | no-native.
# The app must be closed (it rewrites its own files); conversation_summaries.db is left alone because the app restores
# the conversation by itself when it starts (spike S4).
function Import-AgyNative {
    param([Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)]$Profile)
    $work = Join-Path ([IO.Path]::GetTempPath()) ('agy-import-' + [guid]::NewGuid().ToString('N'))
    try {
        $m = Read-HarnessBundle -Path $BundlePath -ExtractTo $work
        if ($m.source.harness -ne 'antigravity') { throw "Not an Antigravity bundle: $($m.source.harness)" }
        if ($m.source.antigravity.kind -ne $Profile.Kind) { return 'kind-mismatch' }
        $id = [string]$m.source.chatId
        # A bundle may come from another machine: its chat id is used to build paths we write to and delete from.
        if (-not (Test-AgyConversationId -Id $id)) { throw 'Invalid conversation id in bundle' }
        $dbRow = @($m.files | Where-Object { $_.path -eq "native/conversations/$id.db" }) | Select-Object -First 1
        if (-not $dbRow) { return 'no-native' }
        if ($Profile.Exe -and (Find-AgyMainProcessId -Exe $Profile.Exe)) { throw "Close $($Profile.Name) first" }
        $convDir = Join-Path $Profile.DataDir 'conversations'
        $target = Join-Path $convDir "$id.db"
        $status = 'copied'
        if (Test-Path -LiteralPath $target) {
            # the newest write to the db or its -wal counts: the app writes new steps to the -wal first
            $newest = @($target, ($target + '-wal') | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } | Sort-Object -Descending)[0]
            $targetMs = [double]([datetimeoffset]$newest).ToUnixTimeMilliseconds()
            if ($null -ne $m.source.lastActivityAt -and [double]$m.source.lastActivityAt -gt $targetMs) { $status = 'updated' } else { return 'exists' }
            # keep what is replaced: rename db, -wal and -shm to .bak-<ts> instead of deleting them
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
            foreach ($suffix in '', '-wal', '-shm') {
                if (Test-Path -LiteralPath ($target + $suffix)) { Move-Item -LiteralPath ($target + $suffix) -Destination ($target + $suffix + '.bak-' + $stamp) -Force }
            }
        }
        Copy-AgyFileAtomic -From (Join-Path $work "native\conversations\$id.db") -To $target
        $walRow = @($m.files | Where-Object { $_.path -eq "native/conversations/$id.db-wal" }) | Select-Object -First 1
        if ($walRow) { Copy-AgyFileAtomic -From (Join-Path $work "native\conversations\$id.db-wal") -To ($target + '-wal') }
        $brainSrc = Join-Path $work "native\brain\$id"
        if (Test-Path -LiteralPath $brainSrc) {
            $brainDst = Join-Path $Profile.DataDir "brain\$id"
            if (-not (Test-AgyPathBelow -Path $brainDst -Root (Join-Path $Profile.DataDir 'brain'))) { throw 'Conversation folder escapes the brain folder' }
            # file by file, overwriting: files only the local side has (browser_recordings, newer notes) stay;
            # Copy-Item on a folder that already exists would nest the copy inside it
            $prefix = (Get-Item -LiteralPath $brainSrc).FullName.TrimEnd('\') + '\'
            foreach ($f in (Get-ChildItem -LiteralPath $brainSrc -Recurse -File -Force)) {
                Copy-AgyFileAtomic -From $f.FullName -To (Join-Path $brainDst $f.FullName.Substring($prefix.Length))
            }
        }
        return $status
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

# --- Handoff ----------------------------------------------------------------------------------------------------

# manifest.json of a bundle, read without extracting anything.
function Read-AgyBundleManifest {
    param([Parameter(Mandatory)][string]$BundlePath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($BundlePath)
    try {
        $entry = $zip.GetEntry('manifest.json')
        if (-not $entry) { throw 'Bundle has no manifest.json' }
        return ([Text.Encoding]::UTF8.GetString((Read-ZipEntryBytes $entry)) | ConvertFrom-Json)
    } finally { $zip.Dispose() }
}

# Handoff into Antigravity: the shared handoff (files, opening prompt on the clipboard, launch the app). Antigravity has
# no deep link, so the user pastes the prompt. The IDE opens on a folder of its own choosing, so its prompt also names
# the original working directory.
function Start-AgyHandoff {
    param([Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)]$Profile)
    $result = Start-HarnessHandoff -BundlePath $BundlePath -TargetHarness 'antigravity' -Profile $Profile
    if ($Profile.Kind -ne 'ide') { return $result }
    $cwd = (Read-AgyBundleManifest -BundlePath $BundlePath).source.cwd.absolute
    # the manifest may come from another machine: quote only an absolute path with no control characters
    if (-not $cwd -or $cwd -notmatch '\A(?:[A-Za-z]:\\|\\\\[^\\])' -or $cwd -match '[\x00-\x1F\x7F]') { return $result }
    $prompt = '{0} The work was done in the folder {1}; open that folder first.' -f $result.Prompt, $cwd
    & (Get-AgyHooks).SetClipboard $prompt
    $result.Prompt = $prompt
    return $result
}
