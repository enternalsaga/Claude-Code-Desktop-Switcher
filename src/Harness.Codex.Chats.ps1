# Harness.Codex.Chats.ps1 - Codex chats: list (state_5.sqlite), export to a bundle, native and Claude imports, handoff.
# Needs Harness.Core.ps1, Harness.Sqlite.ps1 and Harness.Codex.AppServer.ps1. A profile is the object from Harness.Codex.Profiles.ps1:
# @{ Harness='codex'; Id; Name; IsDefault; CodexHome; UserDataDir; Pid }.

# Codex stores some paths with the \\?\ extended prefix.
function ConvertFrom-CodexPath {
    param([AllowNull()][string]$Path)
    if (-not $Path) { return '' }
    return ($Path -replace '^\\\\\?\\', '')
}

# threads.rollout_path does not always match the file on disk: Codex compresses old rollouts to .jsonl.zst
# without updating the column. Returns the real file, or $null.
function Resolve-CodexRolloutFile {
    param([AllowNull()][string]$Path)
    $p = ConvertFrom-CodexPath $Path
    if (-not $p) { return $null }
    foreach ($candidate in $p, "$p.zst") { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    return $null
}

# Chats of one Codex profile, newest first. Reads a snapshot copy of state_5.sqlite (never the live file).
# Every source is listed (exec included); subagent threads and archived chats are not.
function Get-CodexChats {
    param([Parameter(Mandatory)]$Profile)
    $db = Join-Path $Profile.CodexHome 'state_5.sqlite'
    if (-not (Test-Path -LiteralPath $db)) { return @() }
    $snap = Copy-SqliteSnapshot -Path $db
    try {
        $h = Open-SqliteReadOnly -Path $snap
        try {
            $hasEdges = @(Invoke-SqliteQuery -Handle $h -Sql "select name from sqlite_master where name='thread_spawn_edges'").Count -gt 0
            $parent = $(if ($hasEdges) { '(select e.parent_thread_id from thread_spawn_edges e where e.child_thread_id = t.id)' } else { 'NULL' })
            $rows = @(Invoke-SqliteQuery -Handle $h -Sql ("select t.id, t.rollout_path, t.source, t.model_provider, t.cwd, t.title, t.name, t.updated_at, t.updated_at_ms, $parent as parent " +
                "from threads t where t.archived = 0 and (t.thread_source is null or t.thread_source <> 'subagent') and t.source not like '{""subagent""%' " +
                'order by coalesce(t.updated_at_ms, t.updated_at * 1000) desc'))
        } finally { Close-Sqlite -Handle $h }
    } finally { Remove-Item -LiteralPath (Split-Path -Parent $snap) -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($r in $rows) {
        $activity = $(if ($null -ne $r.updated_at_ms) { [double]$r.updated_at_ms } else { [double]$r.updated_at * 1000 })
        $rollout = Resolve-CodexRolloutFile $r.rollout_path
        [pscustomobject]@{
            ChatId = $r.id; Title = $(if ($r.name) { $r.name } elseif ($r.title) { $r.title } else { $r.id })
            Cwd = (ConvertFrom-CodexPath $r.cwd); Updated = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$activity).LocalDateTime
            Activity = $activity; Parent = $r.parent; Source = $r.source; ModelProvider = $r.model_provider
            RolloutPath = $(if ($rollout) { $rollout } else { ConvertFrom-CodexPath $r.rollout_path }); Profile = $Profile
            HasRollout = [bool]$rollout
        }
    }
}

# --- Transcript from a rollout ---------------------------------------------------------------------------------

function ConvertTo-CodexToolOutput {
    param($Output)
    if ($null -eq $Output) { return '' }
    if ($Output -is [string]) { return $Output }
    return ((@($Output) | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.PSObject.Properties['text']) { [string]$_.text } }) -join "`n")
}

# The one-line argument shown for a tool call: the command or path inside a JSON arguments string, else the raw text.
function Get-CodexToolArg {
    param([AllowNull()][string]$Arguments)
    if (-not $Arguments) { return '' }
    $obj = $null
    try { $obj = $Arguments | ConvertFrom-Json } catch { return $Arguments }
    if ($obj -isnot [pscustomobject]) { return $Arguments }
    foreach ($name in 'cmd', 'command', 'path', 'query', 'url', 'pattern', 'input') {
        $p = $obj.PSObject.Properties[$name]
        if ($p -and $p.Value) { return ((@($p.Value) | ForEach-Object { [string]$_ }) -join ' ') }
    }
    return $Arguments
}

# Codex injects project instructions and environment data as "user" messages. They start with a recognisable tag.
function Test-CodexSystemMessage {
    param([AllowNull()][string]$Text)
    $t = ([string]$Text).TrimStart()
    foreach ($prefix in '# AGENTS.md instructions', '<INSTRUCTIONS>', '<environment_context', '<user_instructions', '<permissions', '<collaboration_mode', '<turn_aborted', '<skill>', '<user_shell_command') {
        if ($t.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Normalizes a .jsonl rollout into {role, text, ts, tool{name,arg,output}} entries (same shape as the Claude adapter).
# Reasoning, token counts, turn context and injected system messages are dropped; a tool output joins its call by call_id.
function ConvertFrom-CodexRollout {
    param([Parameter(Mandatory)][string]$Path)
    $entries = New-Object Collections.Generic.List[object]
    $toolById = @{}
    foreach ($line in [IO.File]::ReadLines($Path, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.type -ne 'response_item' -or -not $o.payload) { continue }
        $p = $o.payload
        switch ($p.type) {
            'message' {
                if ($p.role -ne 'user' -and $p.role -ne 'assistant') { break }
                $text = (@($p.content | Where-Object { $_.text } | ForEach-Object { [string]$_.text }) -join "`n")
                if (-not $text -or ($p.role -eq 'user' -and (Test-CodexSystemMessage $text))) { break }
                $entries.Add(@{ role = $p.role; text = $text; ts = $o.timestamp })
            }
            { $_ -eq 'function_call' -or $_ -eq 'custom_tool_call' } {
                $arg = $(if ($p.type -eq 'function_call') { Get-CodexToolArg $p.arguments } else { [string]$p.input })
                $t = @{ role = 'tool'; text = ''; ts = $o.timestamp; tool = @{ name = $p.name; arg = $arg; output = '' } }
                $toolById[$p.call_id] = $t; $entries.Add($t)
            }
            { $_ -eq 'function_call_output' -or $_ -eq 'custom_tool_call_output' } {
                if ($toolById.ContainsKey($p.call_id)) { $toolById[$p.call_id].tool.output = ConvertTo-CodexToolOutput $p.output }
            }
        }
    }
    return $entries.ToArray()
}

# Same entries from app-server `thread/items/list` data (used for .zst rollouts, which PowerShell cannot unpack).
function ConvertFrom-CodexItems {
    param([Parameter(Mandatory)][array]$Items)
    foreach ($d in $Items) {
        $i = $d.item
        $ts = $(if ($d.startedAtMs) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$d.startedAtMs).ToString('o') } else { $null })
        switch ($i.type) {
            'userMessage' {
                $text = (@($i.content | Where-Object { $_.text } | ForEach-Object { [string]$_.text }) -join "`n")
                if ($text -and -not (Test-CodexSystemMessage $text)) { @{ role = 'user'; text = $text; ts = $ts } }
            }
            'agentMessage' { if ($i.text) { @{ role = 'assistant'; text = [string]$i.text; ts = $ts } } }
            'commandExecution' { @{ role = 'tool'; text = ''; ts = $ts; tool = @{ name = 'shell'; arg = [string]$i.command; output = [string]$i.aggregatedOutput } } }
            'webSearch' { @{ role = 'tool'; text = ''; ts = $ts; tool = @{ name = 'web_search'; arg = [string]$i.query; output = '' } } }
        }
    }
}

function Resolve-CodexExePath {
    if (Get-Command Find-CodexInstall -CommandType Function -ErrorAction SilentlyContinue) {
        $i = Find-CodexInstall
        if ($i -and $i.CodexExe -and (Test-Path -LiteralPath $i.CodexExe)) { return $i.CodexExe }
    }
    $npm = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    if (Test-Path -LiteralPath $npm) { return $npm }
    return $null
}

# Transcript of a .zst rollout through app-server (spike S8b): a scratch home that holds only a copy of the rollout,
# no auth, no model call. thread/resume loads the thread; thread/items/list then returns its items.
function Get-CodexZstEntries {
    param([Parameter(Mandatory)]$Chat, [int]$TimeoutSec = 30)
    $exe = Resolve-CodexExePath
    if (-not $exe) { Write-Warning 'codex.exe not found; no transcript for this compressed chat.'; return @() }
    $leaf = Split-Path -Leaf $Chat.RolloutPath
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('codex-transcript-' + [guid]::NewGuid().ToString('N'))
    $srv = $null
    try {
        $dir = Join-Path $scratch 'sessions\scratch'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath $Chat.RolloutPath -Destination (Join-Path $dir $leaf)
        $srv = Start-CodexAppServer -CodexHome $scratch -CodexExe $exe
        [void](Invoke-CodexRpc -Server $srv -Method 'initialize' -Params @{ clientInfo = @{ name = 'harness-switcher'; version = '1' } } -TimeoutSec $TimeoutSec)
        [void](Invoke-CodexRpc -Server $srv -Method 'initialized' -Notify)
        [void](Invoke-CodexRpc -Server $srv -Method 'thread/read' -Params @{ threadId = $Chat.ChatId; includeTurns = $false } -TimeoutSec $TimeoutSec)
        [void](Invoke-CodexRpc -Server $srv -Method 'thread/resume' -Params @{ threadId = $Chat.ChatId } -TimeoutSec $TimeoutSec)
        $all = New-Object Collections.ArrayList; $cursor = $null
        do {
            $p = @{ threadId = $Chat.ChatId; limit = 200 }; if ($cursor) { $p.cursor = $cursor }
            $r = Invoke-CodexRpc -Server $srv -Method 'thread/items/list' -Params $p -TimeoutSec $TimeoutSec
            foreach ($d in @($r.data)) { [void]$all.Add($d) }
            $cursor = $r.nextCursor
        } while ($cursor -and $all.Count -lt 20000)
        return @(ConvertFrom-CodexItems -Items $all.ToArray())
    } catch {
        Write-Warning "No transcript for compressed chat $($Chat.ChatId): $($_.Exception.Message)"
        return @()
    } finally {
        if ($srv) { Stop-CodexAppServer -Server $srv }
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-CodexTranscriptEntries {
    param(
        [Parameter(Mandatory)]$Chat,
        [scriptblock]$ZstEntries = { param($c) Get-CodexZstEntries -Chat $c }
    )
    if ($Chat.RolloutPath -notlike '*.zst') { return @(ConvertFrom-CodexRollout -Path $Chat.RolloutPath) }
    $entries = @(& $ZstEntries $Chat)
    if ($entries.Count) { return $entries }
    return @(@{ role = 'assistant'; text = 'No transcript: this chat is stored compressed and could not be read. Only the native copy is in this bundle.'; ts = $null })
}

# --- Export and native import ----------------------------------------------------------------------------------

function Get-CodexThreadRow {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$ChatId)
    $db = Join-Path $Profile.CodexHome 'state_5.sqlite'
    if (-not (Test-Path -LiteralPath $db)) { return $null }
    $snap = Copy-SqliteSnapshot -Path $db
    try {
        $h = Open-SqliteReadOnly -Path $snap
        try { return @(Invoke-SqliteQuery -Handle $h -Sql ("select * from threads where id = '{0}'" -f ($ChatId -replace "'", "''"))) | Select-Object -First 1 } finally { Close-Sqlite -Handle $h }
    } finally { Remove-Item -LiteralPath (Split-Path -Parent $snap) -Recurse -Force -ErrorAction SilentlyContinue }
}

# sessions/YYYY/MM/DD/<rollout name>, taken from the file name (the date is part of it).
function Get-CodexRolloutRelPath {
    param([Parameter(Mandatory)][string]$FileName)
    $m = [regex]::Match($FileName, '^rollout-(\d{4})-(\d{2})-(\d{2})T')
    if (-not $m.Success) { throw "Not a Codex rollout file name: $FileName" }
    return ('sessions/{0}/{1}/{2}/{3}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $FileName)
}

# Bundle for one Codex chat: the rollout unchanged, the threads row (without first_user_message and preview), and a
# redacted transcript. Secrets inside the rollout are counted, not edited.
function Export-CodexChat {
    param(
        [Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$OutPath,
        [string]$HarnessVersion = '', [string]$MachineId = '', [string]$MachineName = $env:COMPUTERNAME,
        [hashtable]$PathRoots = @{}, $PreviousBundleId = $null, [scriptblock]$ZstEntries
    )
    if (-not $Chat.RolloutPath -or -not (Test-Path -LiteralPath $Chat.RolloutPath -PathType Leaf)) { throw "Rollout file not found for chat $($Chat.ChatId)" }
    $leaf = Split-Path -Leaf $Chat.RolloutPath
    $row = Get-CodexThreadRow -Profile $Chat.Profile -ChatId $Chat.ChatId
    $rowOut = [ordered]@{}
    if ($row) { foreach ($p in $row.PSObject.Properties) { if ($p.Name -notin 'first_user_message', 'preview') { $rowOut[$p.Name] = $p.Value } } }
    $getArgs = @{ Chat = $Chat }; if ($ZstEntries) { $getArgs.ZstEntries = $ZstEntries }
    $entries = @(Get-CodexTranscriptEntries @getArgs)
    $findings = $(if ($leaf -like '*.jsonl') { Measure-SecretFindings -Path $Chat.RolloutPath } else { Measure-SecretFindings -Text (($entries | ForEach-Object { "$($_.text) $($_.tool.arg) $($_.tool.output)" }) -join "`n") })
    $md = ConvertTo-HandoffMarkdown -Entries $entries -Harness 'codex' -Title $Chat.Title -Cwd $Chat.Cwd
    $jsonLines = (@(Protect-TranscriptEntries -Entries $entries) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }) -join "`n"
    $source = @{
        harness = 'codex'; harnessVersion = $HarnessVersion; profileLabel = $Chat.Profile.Name; machineId = $MachineId; machineName = $MachineName
        chatId = $Chat.ChatId; parentChatId = $Chat.Parent; title = $Chat.Title
        cwd = $(if ($Chat.Cwd) { ConvertTo-CwdRef -Path $Chat.Cwd -PathRoots $PathRoots } else { @{ absolute = $null; root = $null; relative = $null } })
        createdAt = $(if ($row -and $row.created_at) { [double]$row.created_at * 1000 } else { $null }); lastActivityAt = $Chat.Activity
        codex = @{ modelProvider = $Chat.ModelProvider; source = $Chat.Source; rolloutRelPath = (Get-CodexRolloutRelPath $leaf); cliVersion = $(if ($row) { $row.cli_version } else { '' }) }
    }
    $files = @(
        @{ Role = 'native'; Path = "native/$leaf"; SourcePath = $Chat.RolloutPath },
        @{ Role = 'native'; Path = 'native/threads-row.json'; Content = ($rowOut | ConvertTo-Json -Depth 4) },
        @{ Role = 'transcript'; Path = 'transcript.md'; Content = $md },
        @{ Role = 'transcript'; Path = 'transcript.jsonl'; Content = $jsonLines }
    )
    return New-HarnessBundle -OutPath $OutPath -Source $source -Files $files -PreviousBundleId $PreviousBundleId `
        -Redaction @{ scanned = $true; findings = $findings; transcriptRedacted = $true }
}

# model_provider of a Codex home: the top-level line of config.toml, openai when absent.
function Get-CodexConfigProvider {
    param([Parameter(Mandatory)][string]$CodexHome)
    $cfg = Join-Path $CodexHome 'config.toml'
    if (Test-Path -LiteralPath $cfg) {
        foreach ($line in [IO.File]::ReadAllLines($cfg)) {   # not ReadLines: an enumerator left by `break` keeps the file locked
            if ($line -match '^\s*\[') { break }
            if ($line -match '^\s*model_provider\s*=\s*"([^"]*)"') { return $Matches[1] }
        }
    }
    return 'openai'
}

# Can the target home resume a rollout written under $Provider? Yes when it is the built-in openai (the profile's
# own auth), the home's top-level model_provider, or a [model_providers.<name>] table of its config.toml. Lines
# are matched, TOML is not parsed (spike S2b).
function Test-CodexProviderSupported {
    param([Parameter(Mandatory)][string]$CodexHome, [string]$Provider)
    if (-not $Provider -or $Provider -ieq 'openai') { return $true }
    if ((Get-CodexConfigProvider -CodexHome $CodexHome) -ieq $Provider) { return $true }
    $cfg = Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $cfg)) { return $false }
    $name = [regex]::Escape($Provider)
    foreach ($line in [IO.File]::ReadAllLines($cfg)) {
        if ($line -match ('^\s*\[\s*model_providers\s*\.\s*("?)' + $name + '\1\s*\]')) { return $true }
    }
    return $false
}

# Asks a scratch app-server on the profile's home to read the thread, which makes Codex register it in state_5.sqlite
# (spike S8a), then waits for the row. No model call, no thread/resume. Returns $true when the row appeared.
function Register-CodexThread {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$ThreadId, [int]$TimeoutSec = 30)
    $exe = Resolve-CodexExePath
    if (-not $exe) { throw 'codex.exe not found' }
    $srv = Start-CodexAppServer -CodexHome $Profile.CodexHome -CodexExe $exe
    try {
        [void](Invoke-CodexRpc -Server $srv -Method 'initialize' -Params @{ clientInfo = @{ name = 'harness-switcher'; version = '1' } } -TimeoutSec $TimeoutSec)
        [void](Invoke-CodexRpc -Server $srv -Method 'initialized' -Notify)
        [void](Invoke-CodexRpc -Server $srv -Method 'thread/read' -Params @{ threadId = $ThreadId; includeTurns = $false } -TimeoutSec $TimeoutSec)
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do { if (Get-CodexThreadRow -Profile $Profile -ChatId $ThreadId) { return $true }; Start-Sleep -Seconds 1 } while ((Get-Date) -lt $deadline)
        return $false
    } finally { Stop-CodexAppServer -Server $srv }
}

# Native import on this machine. Returns copied | exists | provider-mismatch. A rollout whose provider the target
# config does not declare cannot be resumed there (spike S2b), so it is not copied at all.
function Import-CodexNative {
    param(
        [Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)]$Profile,
        [scriptblock]$Register = { param($p, $id) Register-CodexThread -Profile $p -ThreadId $id }
    )
    $work = Join-Path ([IO.Path]::GetTempPath()) ('codex-import-' + [guid]::NewGuid().ToString('N'))
    try {
        $m = Read-HarnessBundle -Path $BundlePath -ExtractTo $work
        if ($m.source.harness -ne 'codex') { throw "Not a Codex bundle: $($m.source.harness)" }
        $rel = [string]$m.source.codex.rolloutRelPath
        # The bundle may come from another machine: check every value that ends up in a path or an RPC call.
        if ($rel -notmatch '^sessions/\d{4}/\d{2}/\d{2}/rollout-[0-9A-Za-z_.:-]+\.jsonl(\.zst)?$' -or $rel.Contains('..')) { throw "Unsafe rollout path in bundle: $rel" }
        if ([string]$m.source.chatId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw "Chat id in bundle is not a UUID: $($m.source.chatId)" }
        $dest = [IO.Path]::GetFullPath((Join-Path $Profile.CodexHome ($rel -replace '/', '\')))
        $sessionsRoot = [IO.Path]::GetFullPath((Join-Path $Profile.CodexHome 'sessions')).TrimEnd('\') + '\'
        if (-not $dest.StartsWith($sessionsRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Rollout path leaves the sessions folder: $rel" }
        if (-not (Test-CodexProviderSupported -CodexHome $Profile.CodexHome -Provider ([string]$m.source.codex.modelProvider))) { return 'provider-mismatch' }
        $leaf = Split-Path -Leaf $dest
        $from = Join-Path $work "native\$leaf"
        $siblings = @($dest, ($dest -replace '\.zst$', ''), ($dest -replace '\.jsonl$', '.jsonl.zst')) | Select-Object -Unique
        $present = @($siblings | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
        if ($present) {
            if ((Get-FileSha256Hex $present) -eq (Get-FileSha256Hex $from)) { return 'exists' }
            $mtimeMs = [DateTimeOffset]::new((Get-Item -LiteralPath $present).LastWriteTimeUtc).ToUnixTimeMilliseconds()
            if ($null -eq $m.source.lastActivityAt -or [double]$m.source.lastActivityAt -le $mtimeMs) { return 'exists' }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath $from -Destination $dest -Force
        try { [void](& $Register $Profile $m.source.chatId) } catch { Write-Warning "Copied the rollout but could not register the thread: $($_.Exception.Message)" }
        return 'copied'
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

# Spike S8c found no lock trouble with the app open, but the open app may not refresh its list, so the safe answer
# is to ask for it to be closed.
function Test-CodexImportNeedsClose {
    param([Parameter(Mandatory)]$Profile)
    return [bool]($Profile.Pid -and (Get-Process -Id $Profile.Pid -ErrorAction SilentlyContinue))
}

# ---- Claude -> Codex -------------------------------------------------------------------------------------------

function Get-CodexNormalPath {
    param([string]$Path)
    return (ConvertFrom-CodexPath $Path).Replace('/', '\').ToLowerInvariant()
}

# The record Codex keeps in <home>\external_agent_session_imports.json for a source file it already imported.
function Get-CodexExternalImportRecord {
    param([Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$Path)
    $f = Join-Path $CodexHome 'external_agent_session_imports.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $sha = Get-FileSha256Hex $Path
    $want = Get-CodexNormalPath $Path
    $doc = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($doc.records) | Where-Object { $_.content_sha256 -eq $sha -and (Get-CodexNormalPath $_.source_path) -eq $want } | Select-Object -First 1
}

# The one session of a detect result whose path is $Path (case, slashes and the \\?\ prefix ignored).
function Select-CodexDetectedSession {
    param([Parameter(Mandatory)]$DetectResult, [Parameter(Mandatory)][string]$Path)
    $want = Get-CodexNormalPath $Path
    foreach ($item in @($DetectResult.items)) {
        if ($item.itemType -ne 'SESSIONS' -or -not $item.details) { continue }
        foreach ($s in @($item.details.sessions)) { if ((Get-CodexNormalPath $s.path) -eq $want) { return $s } }
    }
    return $null
}

# Imports one Claude Code session through Codex's own importer (spike S3). Only that session is sent, never other
# item types. Returns @{Status = imported | exists | not-detected; ThreadId}.
function Import-CodexExternalClaude {
    param(
        [Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)]$Profile,
        [string]$ClaudeHome = (Get-ClaudeHomePath),
        [scriptblock]$StartServer = { param($p) Start-CodexAppServer -CodexHome $p.CodexHome -CodexExe (Resolve-CodexExePath) },
        [int]$TimeoutSec = 120
    )
    $work = Join-Path ([IO.Path]::GetTempPath()) ('codex-ext-' + [guid]::NewGuid().ToString('N'))
    try {
        $m = Read-HarnessBundle -Path $BundlePath -ExtractTo $work
        if ($m.source.harness -ne 'claude') { throw "Not a Claude bundle: $($m.source.harness)" }
        $cli = [string]$m.source.claude.cliSessionId
        if ($cli -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return @{ Status = 'not-detected'; ThreadId = $null } }
        $cwd = Resolve-CwdRef -Ref $m.source.cwd
        $dir = Find-ClaudeProjectDir -ClaudeHome $ClaudeHome -Cwd ([string]$cwd) -Cli $cli
        $jsonl = Join-Path $dir "$cli.jsonl"
        if (-not (Test-Path -LiteralPath $jsonl -PathType Leaf)) { return @{ Status = 'not-detected'; ThreadId = $null } }
        $rec = Get-CodexExternalImportRecord -CodexHome $Profile.CodexHome -Path $jsonl
        if ($rec) { return @{ Status = 'exists'; ThreadId = $rec.imported_thread_id } }

        $ageDays = 30
        if ($m.source.lastActivityAt) { $ageDays = [Math]::Max(30, [int][Math]::Ceiling(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [double]$m.source.lastActivityAt) / 86400000) + 2) }
        $srv = & $StartServer $Profile
        try {
            [void](Invoke-CodexRpc -Server $srv -Method 'initialize' -Params @{ clientInfo = @{ name = 'harness-switcher'; version = '1' } } -TimeoutSec 60)
            [void](Invoke-CodexRpc -Server $srv -Method 'initialized' -Notify)
            $det = Invoke-CodexRpc -Server $srv -Method 'externalAgentConfig/detect' -Params @{ includeHome = $true; maxSessions = 5000; maxSessionAgeDays = $ageDays } -TimeoutSec 120
            $session = Select-CodexDetectedSession -DetectResult $det -Path $jsonl
            if (-not $session) { return @{ Status = 'not-detected'; ThreadId = $null } }
            $item = @{ itemType = 'SESSIONS'; description = 'Claude Code session'; cwd = $null; details = @{ sessions = @($session) } }
            [void](Invoke-CodexRpc -Server $srv -Method 'externalAgentConfig/import' -Params @{ migrationItems = @($item) } -TimeoutSec 60)
            $done = Wait-CodexNotification -Server $srv -Method 'externalAgentConfig/import/completed' -TimeoutSec $TimeoutSec
            if (-not $done) { throw 'Codex did not finish the import in time.' }
            foreach ($r in @($done.params.itemTypeResults)) {
                $ok = @($r.successes) | Select-Object -First 1
                if ($ok) { return @{ Status = 'imported'; ThreadId = [string]$ok.target } }
                $fail = @($r.failures) | Select-Object -First 1
                if ($fail -and $fail.subErrorType -eq 'session_not_detected') { return @{ Status = 'not-detected'; ThreadId = $null } }
                if ($fail) { throw "Codex import failed: $($fail.message)" }
            }
            throw 'Codex reported no result for the session.'
        } finally { Stop-CodexAppServer -Server $srv }
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

# codex://threads/new opens a new chat in the Default app with the prompt filled in (spike S7).
function New-CodexDeepLink {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Path = '')
    $url = 'codex://threads/new?prompt=' + [Uri]::EscapeDataString($Prompt)
    if ($Path) { $url += '&path=' + [Uri]::EscapeDataString($Path) }
    return $url
}

# Handoff into Codex. Deep links always reach the Default app, so an extra profile takes the clipboard route.
function Start-CodexHandoff {
    param(
        [Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)]$Profile,
        [string]$HandoffDir = (Get-HandoffDir), [scriptblock]$StartProcess = { param($u) Start-Process $u }
    )
    if (-not $Profile.IsDefault) {
        $r = Start-HarnessHandoff -BundlePath $BundlePath -TargetHarness 'codex' -Profile $Profile
        return [pscustomobject]@{ Mode = 'clipboard'; Path = $r.Path; Prompt = $r.Prompt }
    }
    $files = Export-HarnessHandoffFiles -BundlePath $BundlePath -HandoffDir $HandoffDir -Target 'codex'
    $cwd = Resolve-CwdRef -Ref $files.Manifest.source.cwd
    $path = $(if ($cwd -and (Test-Path -LiteralPath $cwd -PathType Container)) { [string]$cwd } else { '' })
    [void](& $StartProcess (New-CodexDeepLink -Prompt $files.Prompt -Path $path))
    return [pscustomobject]@{ Mode = 'deeplink'; Path = $files.Path; Prompt = $files.Prompt }
}
