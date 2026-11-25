# Harness.Mirror.ps1 - live mirror core for pinned chats (no WinForms).
# Uses Harness.Core.ps1, Harness.Claude.ps1, Harness.Codex.Chats.ps1, Harness.Antigravity.Chats.ps1
# and $script:SwitcherHome. Stays ASCII-only.

function Get-MirrorDir {
    return (Join-Path $script:SwitcherHome 'live-mirror')
}

function Write-MirrorTextAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $tmp = $full + '.tmp-' + [guid]::NewGuid().ToString('N')
    $utf8 = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($tmp, $Text, $utf8)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            [IO.File]::Replace($tmp, $full, [NullString]::Value)
        } else {
            [IO.File]::Move($tmp, $full)
        }
    } catch {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Resolve-MirrorMcpId {
    param([string]$Harness, [string]$SourcePath, [string]$FallbackId = '')
    $h = $(if ($Harness) { $Harness.ToLowerInvariant() } else { '' })
    if ($SourcePath) {
        switch ($h) {
            'claude' {
                $stem = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
                if ($stem) { return $stem }
            }
            'codex' {
                if (-not $SourcePath.EndsWith('.zst', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
                    $sr = $null
                    try {
                        $fs = [IO.File]::Open($SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                        for ($i = 0; $i -lt 20 -and -not $sr.EndOfStream; $i++) {
                            $line = $sr.ReadLine()
                            if ($i -eq 0 -and $line) { $line = $line.TrimStart([char]0xFEFF) }
                            if (-not $line -or -not $line.Trim()) { continue }
                            try { $o = $line | ConvertFrom-Json } catch { continue }
                            if ($o -and $o.type -eq 'session_meta' -and $o.payload -and $o.payload.id) { return [string]$o.payload.id }
                        }
                    } catch { } finally { if ($sr) { $sr.Dispose() } }
                }
                $leaf = [IO.Path]::GetFileName($SourcePath)
                if ($leaf -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
                $base = $leaf -replace '\.jsonl(\.zst)?$', ''
                if ($base) { return $base }
            }
            'antigravity' {
                $logsDir = Split-Path -Parent $SourcePath
                $sysDir = $(if ($logsDir) { Split-Path -Parent $logsDir } else { '' })
                if ($logsDir -and $sysDir -and ((Split-Path -Leaf $logsDir) -ieq 'logs') -and ((Split-Path -Leaf $sysDir) -ieq '.system_generated')) {
                    $brainDir = Split-Path -Parent $sysDir
                    if ($brainDir) { return (Split-Path -Leaf $brainDir) }
                }
            }
        }
    }
    return $FallbackId
}

function ConvertTo-MirrorPinObject {
    param([Parameter(Mandatory)]$Raw)
    $get = {
        param([string]$Name, $Default = $null)
        if ($Raw -is [System.Collections.IDictionary]) {
            if ($Raw.Contains($Name)) { return $Raw[$Name] }
            return $Default
        }
        $prop = $Raw.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $Default
    }
    $state = [string](& $get 'state' 'ok')
    if (-not $state) { $state = 'ok' }
    $harness = [string](& $get 'harness' '')
    $id = [string](& $get 'id' '')
    $sourcePath = [string](& $get 'sourcePath' '')
    $mcpId = [string](& $get 'mcpId' '')
    if (-not $mcpId) { $mcpId = Resolve-MirrorMcpId -Harness $harness -SourcePath $sourcePath -FallbackId $id }
    $syncAtRaw = & $get 'codexSyncAt' $null
    $syncAt = $null
    if ($syncAtRaw -is [datetime]) { $syncAt = $syncAtRaw.ToUniversalTime().ToString('o') }
    elseif ($null -ne $syncAtRaw -and [string]$syncAtRaw) { $syncAt = [string]$syncAtRaw }
    return [pscustomobject]@{
        harness         = $harness
        id              = $id
        mcpId           = $mcpId
        profileId       = [string](& $get 'profileId' '')
        title           = [string](& $get 'title' '')
        cwd             = [string](& $get 'cwd' '')
        sourcePath      = $sourcePath
        mirrorPath      = [string](& $get 'mirrorPath' '')
        codexSync       = [bool](& $get 'codexSync' $false)
        codexProfileId  = $(if ($null -ne (& $get 'codexProfileId' $null) -and [string](& $get 'codexProfileId' '')) { [string](& $get 'codexProfileId' '') } else { $null })
        codexSyncStatus = [string](& $get 'codexSyncStatus' '')
        codexSyncAt     = $syncAt
        codexSyncError  = [string](& $get 'codexSyncError' '')
        lastSize        = [long](& $get 'lastSize' 0)
        lastTicks       = [long](& $get 'lastTicks' 0)
        state           = $state
    }
}

function Read-MirrorPins {
    param([string]$Dir = (Get-MirrorDir))
    $path = Join-Path $Dir 'pins.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if (-not $raw -or -not $raw.Trim()) { return @() }
    $parsed = $raw | ConvertFrom-Json
    $list = New-Object Collections.Generic.List[object]
    foreach ($item in @($parsed)) {
        if ($null -eq $item) { continue }
        $list.Add((ConvertTo-MirrorPinObject -Raw $item))
    }
    return $list.ToArray()
}

function Write-MirrorPins {
    param([AllowNull()][AllowEmptyCollection()][array]$Pins = @(), [string]$Dir = (Get-MirrorDir))
    $norm = New-Object Collections.Generic.List[object]
    foreach ($p in @($Pins)) {
        if ($null -eq $p) { continue }
        $norm.Add((ConvertTo-MirrorPinObject -Raw $p))
    }
    $json = ConvertTo-Json -InputObject @($norm.ToArray()) -Depth 6
    Write-MirrorTextAtomic -Path (Join-Path $Dir 'pins.json') -Text ($json + "`n")
}

function Get-MirrorProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Resolve-MirrorSource {
    param([Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)]$Chat, [string]$ClaudeHome)
    switch ($Harness.ToLowerInvariant()) {
        'claude' {
            $homeDir = $(if ($ClaudeHome) { $ClaudeHome } elseif (Get-Command Get-ClaudeHomePath -ErrorAction SilentlyContinue) { Get-ClaudeHomePath } else { Join-Path $env:USERPROFILE '.claude' })
            $cli = [string](Get-MirrorProp $Chat 'CliSessionId')
            if (-not $cli) { $cli = [string](Get-MirrorProp $Chat 'cliSessionId') }
            $cwd = [string](Get-MirrorProp $Chat 'Cwd')
            $sess = Get-MirrorProp $Chat 'Session'
            $sessFile = $(if ($sess) { Get-MirrorProp $sess 'File' } else { $null })
            if ((-not $cli -or -not $cwd) -and $sessFile -and (Get-Command Read-ChatJson -ErrorAction SilentlyContinue)) {
                $data = Read-ChatJson $sessFile.FullName
                if (-not $cli) { $cli = [string](Get-FirstValue $data 'cliSessionId') }
                if (-not $cwd) { $cwd = [string](Get-FirstValue $data 'cwd', 'originCwd', 'workingDirectory') }
            }
            if (-not $cli -or $cli.Contains('/') -or $cli.Contains('\') -or $cli.Contains('..')) { return $null }
            $proj = Find-ClaudeProjectDir -ClaudeHome $homeDir -Cwd $(if ($cwd) { $cwd } else { '_' }) -Cli $cli
            $jsonl = Join-Path $proj "$cli.jsonl"
            if (Test-Path -LiteralPath $jsonl -PathType Leaf) { return ([IO.Path]::GetFullPath($jsonl)) }
            return $null
        }
        'codex' {
            $rp = [string](Get-MirrorProp $Chat 'RolloutPath')
            $resolved = Resolve-CodexRolloutFile $rp
            if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) { return ([IO.Path]::GetFullPath($resolved)) }
            return $null
        }
        'antigravity' {
            $id = [string](Get-MirrorProp $Chat 'ChatId')
            if (-not $id) { $id = [string](Get-MirrorProp $Chat 'Id') }
            $prof = Get-MirrorProp $Chat 'Profile'
            $dataDir = $(if ($prof) { [string](Get-MirrorProp $prof 'DataDir') } else { [string](Get-MirrorProp $Chat 'DataDir') })
            if (-not $id -or -not $dataDir -or $id.Contains('/') -or $id.Contains('\') -or $id.Contains('..') -or $id.Contains(':')) { return $null }
            $jsonl = Join-Path $dataDir "brain\$id\.system_generated\logs\transcript.jsonl"
            if (Test-Path -LiteralPath $jsonl -PathType Leaf) { return ([IO.Path]::GetFullPath($jsonl)) }
            return $null
        }
        default { return $null }
    }
}

function Add-MirrorPin {
    param(
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)]$Chat,
        [string]$Dir = (Get-MirrorDir),
        [string]$ClaudeHome
    )
    $h = $Harness.ToLowerInvariant()
    $id = [string](Get-MirrorProp $Chat 'ChatId')
    if (-not $id) { $id = [string](Get-MirrorProp $Chat 'Id') }
    if (-not $id) { throw 'no-source' }
    $pins = @(Read-MirrorPins -Dir $Dir)
    foreach ($existing in $pins) {
        if ($existing.harness -eq $h -and $existing.id -eq $id) { throw 'already-pinned' }
    }
    if ($pins.Count -ge 5) { throw 'pin-limit' }
    $src = Resolve-MirrorSource -Harness $h -Chat $Chat -ClaudeHome $ClaudeHome
    if (-not $src) { throw 'no-source' }
    $prof = Get-MirrorProp $Chat 'Profile'
    $profileId = $(if ($prof) { [string](Get-MirrorProp $prof 'Id') } else { '' })
    $title = [string](Get-MirrorProp $Chat 'Title')
    if (-not $title) { $title = $id }
    $cwd = [string](Get-MirrorProp $Chat 'Cwd')
    $safeId = $id -replace '[^A-Za-z0-9._-]', '_'
    $mirrorPath = Join-Path $Dir ("$h-$safeId.md")
    $mcpId = Resolve-MirrorMcpId -Harness $h -SourcePath $src -FallbackId $id
    $pin = ConvertTo-MirrorPinObject -Raw @{
        harness = $h; id = $id; mcpId = $mcpId; profileId = $profileId; title = $title; cwd = $cwd
        sourcePath = $src; mirrorPath = $mirrorPath
        codexSync = $false; codexProfileId = $null; lastSize = [long]0; lastTicks = [long]0; state = 'ok'
    }
    Write-MirrorPins -Pins ($pins + @($pin)) -Dir $Dir
    return $pin
}

function Remove-MirrorPin {
    param([Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)][string]$Id, [string]$Dir = (Get-MirrorDir))
    $h = $Harness.ToLowerInvariant()
    $kept = @(Read-MirrorPins -Dir $Dir | Where-Object { -not ($_.harness -eq $h -and $_.id -eq $Id) })
    Write-MirrorPins -Pins $kept -Dir $Dir
}

function Copy-MirrorTailToTemp {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$TailBytes, [ref]$BytesRead)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [Math]::Max([long]0, $fs.Length - $TailBytes)
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $len = [int]($fs.Length - $start)
        $buf = New-Object byte[] $len
        $readTotal = 0
        while ($readTotal -lt $len) {
            $n = $fs.Read($buf, $readTotal, $len - $readTotal)
            if ($n -le 0) { break }
            $readTotal += $n
        }
        if ($BytesRead) { $BytesRead.Value = [long]$readTotal }
    } finally { $fs.Dispose() }
    $offset = 0
    if ($start -gt 0) {
        $nl = [Array]::IndexOf($buf, [byte]10, 0, $readTotal)
        if ($nl -ge 0) { $offset = $nl + 1 } else { $offset = $readTotal }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mirror-tail-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $out = [IO.File]::Create($tmp)
    try {
        if ($readTotal -gt $offset) { $out.Write($buf, $offset, $readTotal - $offset) }
    } finally { $out.Dispose() }
    return $tmp
}

function Export-MirrorPin {
    param(
        [Parameter(Mandatory)]$Pin,
        [datetime]$Now = [datetime]::UtcNow,
        [scriptblock]$ZstEntries,
        [long]$LargeThresholdBytes = 50MB,
        [long]$TailWindowBytes = 8MB,
        [ref]$BytesRead
    )
    if (-not $Pin.sourcePath) {
        $Pin.state = 'missing'
        return 'missing'
    }
    $fi = New-Object IO.FileInfo $Pin.sourcePath
    if (-not $fi.Exists) {
        $Pin.state = 'missing'
        return 'missing'
    }
    $size = [long]$fi.Length
    $ticks = [long]$fi.LastWriteTimeUtc.Ticks
    if ([long]$Pin.lastSize -eq $size -and [long]$Pin.lastTicks -eq $ticks -and $Pin.mirrorPath -and (Test-Path -LiteralPath $Pin.mirrorPath -PathType Leaf)) {
        $Pin.state = 'ok'
        return 'unchanged'
    }
    $tailOnly = ($Pin.sourcePath -notlike '*.zst') -and ($size -gt $LargeThresholdBytes)
    $tempTail = $null
    $readPath = $Pin.sourcePath
    try {
        if ($tailOnly) {
            $tempTail = Copy-MirrorTailToTemp -Path $Pin.sourcePath -TailBytes $TailWindowBytes -BytesRead $BytesRead
            $readPath = $tempTail
        } elseif ($BytesRead) {
            $BytesRead.Value = $size
        }
        $entries = switch ($Pin.harness.ToLowerInvariant()) {
            'claude'      { @(ConvertFrom-ClaudeJsonl -Path $readPath) }
            'codex'       {
                $chatArg = [pscustomobject]@{ ChatId = $Pin.id; RolloutPath = $readPath }
                if ($ZstEntries) { @(Get-CodexTranscriptEntries -Chat $chatArg -ZstEntries $ZstEntries) } else { @(Get-CodexTranscriptEntries -Chat $chatArg) }
            }
            'antigravity' { @(ConvertFrom-AgyTranscriptJsonl -Path $readPath) }
            default       { throw "Unknown mirror harness: $($Pin.harness)" }
        }
    } finally {
        if ($tempTail -and (Test-Path -LiteralPath $tempTail -PathType Leaf)) {
            Remove-Item -LiteralPath $tempTail -Force -ErrorAction SilentlyContinue
        }
    }
    $title = $(if ($Pin.title) { [string]$Pin.title } elseif ($Pin.id) { [string]$Pin.id } else { 'Chat' })
    $cwd = $(if ($Pin.cwd) { [string]$Pin.cwd } else { '' })
    $body = ConvertTo-HandoffMarkdown -Entries $entries -Harness $Pin.harness -Title $title -Cwd $cwd -KeepTurns 40
    $stamp = $Now.ToUniversalTime().ToString('o')
    $header = "<!-- live mirror, updated $stamp -->`n"
    if ($tailOnly) {
        $header += "> Note: Source file exceeds 50 MB; only the last 8 MB tail was read.`n`n"
    }
    Write-MirrorTextAtomic -Path $Pin.mirrorPath -Text ($header + $body)
    $Pin.lastSize = $size
    $Pin.lastTicks = $ticks
    $Pin.state = 'ok'
    return 'written'
}

function New-MirrorQueue {
    param([int]$DelayMs = 2000)
    return @{ Pending = @{}; DelayMs = $DelayMs }
}

function Add-MirrorEvent {
    param([Parameter(Mandatory)][hashtable]$Queue, [Parameter(Mandatory)][string]$Key, [datetime]$Now = [datetime]::UtcNow)
    $Queue.Pending[$Key] = $Now.ToUniversalTime()
}

function Get-MirrorDue {
    param([Parameter(Mandatory)][hashtable]$Queue, [datetime]$Now = [datetime]::UtcNow)
    $utcNow = $Now.ToUniversalTime()
    $due = New-Object Collections.Generic.List[string]
    foreach ($k in @($Queue.Pending.Keys)) {
        $at = [datetime]$Queue.Pending[$k]
        if (($utcNow - $at).TotalMilliseconds -ge $Queue.DelayMs) {
            $due.Add([string]$k)
            $Queue.Pending.Remove($k)
        }
    }
    $due.Sort()
    return $due.ToArray()
}

function Invoke-MirrorDue {
    param(
        [Parameter(Mandatory)][hashtable]$Queue,
        [AllowNull()][AllowEmptyCollection()][array]$Pins = @(),
        [datetime]$Now = [datetime]::UtcNow,
        [scriptblock]$ZstEntries
    )
    $dueKeys = @(Get-MirrorDue -Queue $Queue -Now $Now)
    if (-not $dueKeys.Count) { return @() }
    $byKey = @{}
    foreach ($p in @($Pins)) {
        if ($null -eq $p) { continue }
        $byKey[('{0}:{1}' -f $p.harness, $p.id).ToLowerInvariant()] = $p
    }
    $results = New-Object Collections.Generic.List[object]
    foreach ($k in $dueKeys) {
        $lookup = $k.ToLowerInvariant()
        if (-not $byKey.ContainsKey($lookup)) { continue }
        $pin = $byKey[$lookup]
        try {
            $res = $(if ($ZstEntries) { Export-MirrorPin -Pin $pin -Now $Now -ZstEntries $ZstEntries } else { Export-MirrorPin -Pin $pin -Now $Now })
            $results.Add(@{ Key = $k; Result = $res })
        } catch {
            $pin.state = 'error'
            $results.Add(@{ Key = $k; Result = 'error'; Error = $_.Exception.Message })
        }
    }
    return $results.ToArray()
}

function New-MirrorHandoffPrompt {
    param([Parameter(Mandatory)]$Pin)
    $title = $(if ($Pin.title) { [string]$Pin.title } else { [string]$Pin.id })
    if (Get-Command Protect-TranscriptText -ErrorAction SilentlyContinue) {
        $title = Protect-TranscriptText $title
    }
    $mcpId = [string](Get-MirrorProp $Pin 'mcpId')
    if (-not $mcpId) { $mcpId = Resolve-MirrorMcpId -Harness ([string]$Pin.harness) -SourcePath ([string](Get-MirrorProp $Pin 'sourcePath')) -FallbackId ([string]$Pin.id) }
    return ('If the harness-transcripts tool is available, call read_session_tail with harness={1} id={3}. Otherwise read {0}. It updates itself after every turn of the {1} chat "{2}"; read it again when you need newer context.' -f $Pin.mirrorPath, $Pin.harness, $title, $mcpId)
}
