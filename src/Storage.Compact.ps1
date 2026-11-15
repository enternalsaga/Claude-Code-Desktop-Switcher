# Storage.Compact.ps1 - trim the large tool outputs of a session (phase 6, lane C1). A tool output over 16 KB keeps its first 2 KB,
# a marker and its last 1 KB; an image in a tool result becomes [image trimmed]. Every other line of a file is copied byte for
# byte (the file is read as bytes, one line at a time, never whole). InPlace first puts a verified archive of the session in the
# store and only then swaps the file (tmp + rename); ReadOnlyCopy leaves the session alone and writes <key>.trimmed.md beside
# the archives. Needs Storage.Archive.ps1 (New-StorageArchive, the store functions), Storage.Guard.ps1, Storage.Scan.ps1
# (Test-StorageCancel), Harness.Core.ps1 and the transcript readers of the harnesses. ASCII only.

Add-Type -AssemblyName System.Web.Extensions

# Which harness may be cut in place. Codex passed spike S15; Claude stays a read-only copy until spike S14 passes (then this is
# a one-line change). A Codex sub-agent rollout is never cut in place.
$script:StorageTrimInPlace = @{ claude = $false; codex = $true }

function Get-StorageTrimLimits { return @{ Threshold = 16KB; Head = 2KB; Tail = 1KB } }

function Get-StorageJsonSerializer {
    if (-not $script:StorageJsonSerializer) { $s = New-Object Web.Script.Serialization.JavaScriptSerializer; $s.MaxJsonLength = [int]::MaxValue; $s.RecursionLimit = 1000; $script:StorageJsonSerializer = $s }
    return $script:StorageJsonSerializer
}

# The cut text: first 2 KB, a marker, last 1 KB. Text of 16 KB or less is returned as it is.
function Get-StorageTrimmedText {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Key)
    $lim = Get-StorageTrimLimits
    if ($Text.Length -le $lim.Threshold) { return @{ Text = $Text; Cut = $false } }
    $gone = $Text.Length - $lim.Head - $lim.Tail
    $marker = "`n[... {0} KB trimmed; full output in archive {1} ...]`n" -f [Math]::Round($gone / 1KB), $Key
    return @{ Text = ($Text.Substring(0, $lim.Head) + $marker + $Text.Substring($Text.Length - $lim.Tail)); Cut = $true }
}

# Copies a jsonl file line by line. A line shorter than MinBytes is copied as bytes. A longer one is given to -Transform as
# text (without its line end): it returns @{ Text; Items } for a changed line, or $null to keep the bytes as they are.
function Convert-StorageJsonlFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OutPath, [Parameter(Mandatory)][scriptblock]$Transform, [long]$MinBytes = (Get-StorageTrimLimits).Threshold)
    $utf8 = New-Object Text.UTF8Encoding($false)
    $stats = @{ Lines = 0; Changed = 0; Items = 0; BytesBefore = [long](New-Object IO.FileInfo $Path).Length; BytesAfter = [long]0 }
    $in = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $out = [IO.File]::Create($OutPath)
    try {
        $line = New-Object IO.MemoryStream
        $emit = {
            $bytes = $line.ToArray(); $line.SetLength(0); $stats.Lines++
            if ($bytes.Length -ge $MinBytes) {
                $text = $utf8.GetString($bytes)
                $end = $(if ($text.EndsWith("`r`n")) { "`r`n" } elseif ($text.EndsWith("`n")) { "`n" } else { '' })
                $r = & $Transform $text.Substring(0, $text.Length - $end.Length)
                if ($r) { $bytes = $utf8.GetBytes($r.Text + $end); $stats.Changed++; $stats.Items += [int]$r.Items }
            }
            $out.Write($bytes, 0, $bytes.Length)
        }
        $buf = New-Object byte[] (1MB)
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $pos = 0
            while ($pos -lt $n) {
                $nl = [Array]::IndexOf($buf, [byte]10, $pos, $n - $pos)
                if ($nl -lt 0) { $line.Write($buf, $pos, $n - $pos); $pos = $n }
                else { $line.Write($buf, $pos, $nl - $pos + 1); $pos = $nl + 1; & $emit }
            }
        }
        if ($line.Length) { & $emit }
        $stats.BytesAfter = $out.Length
    } finally { $out.Dispose(); $in.Dispose() }
    return $stats
}

function Get-StorageJsonValue {
    param($Dict, [string]$Name)
    if ($Dict -is [Collections.IDictionary] -and $Dict.ContainsKey($Name)) { return , $Dict[$Name] }   # the comma keeps a one-item list a list
    return $null
}

# One Claude line: the tool results of its message. Returns @{ Text; Items } or $null when nothing was cut.
function ConvertTo-StorageTrimmedClaudeLine {
    param([Parameter(Mandatory)][string]$Line, [Parameter(Mandatory)][string]$Key)
    if (-not $Line.Contains('"tool_result"')) { return $null }
    $ser = Get-StorageJsonSerializer
    try { $o = $ser.DeserializeObject($Line) } catch { return $null }
    $content = Get-StorageJsonValue (Get-StorageJsonValue $o 'message') 'content'
    if ($content -isnot [Collections.IList]) { return $null }
    $items = 0
    foreach ($blk in $content) {
        if ((Get-StorageJsonValue $blk 'type') -ne 'tool_result') { continue }
        $c = Get-StorageJsonValue $blk 'content'
        if ($c -is [string]) { $r = Get-StorageTrimmedText -Text $c -Key $Key; if ($r.Cut) { $blk['content'] = $r.Text; $items++ } }
        elseif ($c -is [Collections.IList]) {
            for ($i = 0; $i -lt $c.Count; $i++) {
                $type = Get-StorageJsonValue $c[$i] 'type'
                if ($type -eq 'image') { $c[$i] = @{ type = 'text'; text = '[image trimmed]' }; $items++ }
                elseif ($type -eq 'text' -and (Get-StorageJsonValue $c[$i] 'text') -is [string]) { $r = Get-StorageTrimmedText -Text $c[$i]['text'] -Key $Key; if ($r.Cut) { $c[$i]['text'] = $r.Text; $items++ } }
            }
        }
    }
    if (-not $items) { return $null }
    return @{ Text = $ser.Serialize($o); Items = $items }
}

# One Codex line: function_call_output and custom_tool_call_output of a response_item.
function ConvertTo-StorageTrimmedCodexLine {
    param([Parameter(Mandatory)][string]$Line, [Parameter(Mandatory)][string]$Key)
    if (-not $Line.Contains('_output"')) { return $null }
    $ser = Get-StorageJsonSerializer
    try { $o = $ser.DeserializeObject($Line) } catch { return $null }
    if ((Get-StorageJsonValue $o 'type') -ne 'response_item') { return $null }
    $p = Get-StorageJsonValue $o 'payload'
    if ((Get-StorageJsonValue $p 'type') -notin 'function_call_output', 'custom_tool_call_output') { return $null }
    $out = Get-StorageJsonValue $p 'output'
    if ($out -isnot [string]) { return $null }
    $r = Get-StorageTrimmedText -Text $out -Key $Key
    if (-not $r.Cut) { return $null }
    $p['output'] = $r.Text
    return @{ Text = $ser.Serialize($o); Items = 1 }
}

function ConvertTo-TrimmedClaudeJsonl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OutPath, [Parameter(Mandatory)][string]$Key)
    return (Convert-StorageJsonlFile -Path $Path -OutPath $OutPath -Transform { param($l) ConvertTo-StorageTrimmedClaudeLine -Line $l -Key $Key }.GetNewClosure())
}

function ConvertTo-TrimmedCodexRollout {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OutPath, [Parameter(Mandatory)][string]$Key)
    if ($Path -like '*.zst') { throw 'trim-unsupported: a compressed (.zst) rollout cannot be trimmed.' }
    return (Convert-StorageJsonlFile -Path $Path -OutPath $OutPath -Transform { param($l) ConvertTo-StorageTrimmedCodexLine -Line $l -Key $Key }.GetNewClosure())
}

# A plain text file of <cli>\tool-results\ : the same rule on the whole text.
function ConvertTo-TrimmedTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OutPath, [Parameter(Mandatory)][string]$Key)
    $utf8 = New-Object Text.UTF8Encoding($false)
    $before = [long](New-Object IO.FileInfo $Path).Length
    $r = Get-StorageTrimmedText -Text ([IO.File]::ReadAllText($Path, $utf8)) -Key $Key
    if ($r.Cut) { [IO.File]::WriteAllText($OutPath, $r.Text, $utf8) } else { [IO.File]::Copy($Path, $OutPath, $true) }
    return @{ Lines = 1; Changed = [int]$r.Cut; Items = [int]$r.Cut; BytesBefore = $before; BytesAfter = [long](New-Object IO.FileInfo $OutPath).Length }
}

# ---- the files and the transcript of a session -----------------------------------------------------------------------------------

# The files InPlace cuts: the Claude transcript, the big text files of the tool-results folder, the Codex rollout.
function Get-StorageTrimTargets {
    param([Parameter(Mandatory)]$Session)
    $list = New-Object Collections.Generic.List[object]
    foreach ($p in $Session.Parts) {
        $path = [string]$p.Path
        if ($Session.Harness -eq 'claude' -and $p.Role -eq 'transcript') { $list.Add(@{ Path = $path; Kind = 'claude-jsonl' }) }
        elseif ($Session.Harness -eq 'codex' -and $p.Role -eq 'rollout') { $list.Add(@{ Path = $path; Kind = 'codex-rollout' }) }
        elseif ($Session.Harness -eq 'claude' -and $p.Role -eq 'cli-dir' -and [IO.Directory]::Exists((Join-Path $path 'tool-results'))) {
            foreach ($f in @(Get-StorageFilesRecursive -Path (Join-Path $path 'tool-results'))) { if ($f.Length -gt (Get-StorageTrimLimits).Threshold) { $list.Add(@{ Path = $f.FullName; Kind = 'text' }) } }
        }
    }
    return $list.ToArray()
}

# The normalized transcript entries of a session ({role, text, ts, tool{name,arg,output}}), through the reader of its harness.
function Get-StorageSessionEntries {
    param([Parameter(Mandatory)]$Session)
    switch ([string]$Session.Harness) {
        'claude' { $p = @($Session.Parts | Where-Object { $_.Role -eq 'transcript' })[0]; if ($p) { return @(ConvertFrom-ClaudeJsonl -Path ([string]$p.Path)) } }
        'codex' { $p = @($Session.Parts | Where-Object { $_.Role -eq 'rollout' })[0]; if ($p) { return @(Get-CodexTranscriptEntries -Chat ([pscustomobject]@{ RolloutPath = [string]$p.Path })) } }
        'antigravity' { $p = @($Session.Parts | Where-Object { $_.Role -like 'conversation-*' -and ([string]$_.Path) -like '*.db' })[0]; if ($p) { return @(ConvertFrom-AgyDb -Path ([string]$p.Path)) } }
    }
    throw 'transcript-missing: this session has no transcript file to read.'
}

# The readable copy: the chat with every tool output over 16 KB cut by the rule above. Redacted like a handoff.
function ConvertTo-StorageTrimmedMarkdown {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries, [Parameter(Mandatory)]$Session)
    $sb = New-Object Text.StringBuilder; $items = 0
    [void]$sb.AppendLine("# $($Session.Title)"); [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Session: $($Session.Key)"); if ($Session.Cwd) { [void]$sb.AppendLine("- Working directory: $($Session.Cwd)") }; [void]$sb.AppendLine('')
    foreach ($e in @(Protect-TranscriptEntries -Entries $Entries)) {
        if ($e.role -eq 'tool') {
            $arg = ([string]$e.tool.arg -replace '\s+', ' ').Trim(); if ($arg.Length -gt 200) { $arg = $arg.Substring(0, 200) + '...' }
            [void]$sb.AppendLine(('- tool `{0}`: {1}' -f $e.tool.name, $arg))
            if ($e.tool.output) {
                $r = Get-StorageTrimmedText -Text ([string]$e.tool.output) -Key ([string]$Session.Key); if ($r.Cut) { $items++ }
                [void]$sb.AppendLine('~~~'); [void]$sb.AppendLine($r.Text); [void]$sb.AppendLine('~~~')
            }
        } else { [void]$sb.AppendLine("### $($e.role)"); [void]$sb.AppendLine([string]$e.text); [void]$sb.AppendLine('') }
    }
    return @{ Text = $sb.ToString(); Items = $items }
}

# ---- the archive made before anything is changed ----------------------------------------------------------------------------------

# The steps of archiving 1 to 4 and the index row (as Invoke-StorageArchiveOne does them), without removing the original.
# Throws when any step fails, and then nothing of the session was touched. Returns @{ ZipPath; Dir } (Dir is $null on Drive).
function Save-StorageSafetyArchive {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target, [string]$MachineId = '', [Parameter(Mandatory)][string]$WorkDir)
    $a = New-StorageArchive -Session $Session -OutDir $WorkDir -MachineId $MachineId
    $placed = $null
    try {
        if ($Target.Kind -eq 'drive') { return @{ ZipPath = (Save-StorageArchiveToDriveChecked -Archive $a -Session $Session -Target $Target -WorkDir $WorkDir); Dir = $null } }
        $placed = Copy-StorageArchiveToStore -Archive $a -Session $Session -StorePath $Target.Path
        $again = Read-StorageArchive -ZipPath $placed.Path
        if (-not $again.Verified -or (Get-StorageFileSha256 $placed.Path) -ne $a.Sha256) { throw "store-verify-failed: the stored archive does not verify ($($again.Reason))." }
        Add-StorageArchiveIndex -Target $Target -Row ([pscustomobject][ordered]@{ key = [string]$Session.Key; harness = [string]$Session.Harness; title = [string]$Session.Title; bytes = [long]$Session.Bytes
            zipBytes = (Get-Item -LiteralPath $placed.Path).Length; lastActivity = $Session.LastActivity; archivedAt = (Get-Date).ToUniversalTime().ToString('o'); machineId = $MachineId; entry = $placed.Entry; sha256 = $a.Sha256 })
        return @{ ZipPath = $placed.Path; Dir = (Split-Path -Parent $placed.Path) }
    } catch {
        if ($placed -and [IO.File]::Exists($placed.Path)) { Remove-Item -LiteralPath $placed.Path -Force -ErrorAction SilentlyContinue }
        throw
    } finally { if ($a -and [IO.File]::Exists($a.ZipPath)) { Remove-Item -LiteralPath $a.ZipPath -Force -ErrorAction SilentlyContinue } }
}

# <store>\<harness>\<yyyy-MM>\ : where the archives of this month are, and the files that go beside them.
function Get-StorageSidecarDir {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target)
    if ($Target.Kind -ne 'local') { throw 'store-unsupported: this file is kept in a local archive folder; choose a local folder.' }
    return (Join-Path (Join-Path $Target.Path ([string]$Session.Harness)) (Get-Date -Format 'yyyy-MM'))
}

function Write-StorageSidecar {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Suffix, [Parameter(Mandatory)][string]$Text)
    Write-StorageTextAtomic -Path (Join-Path $Dir ((Get-StorageKeySafe $Key) + $Suffix)) -Text $Text
}

# ---- trim ---------------------------------------------------------------------------------------------------------------------------------

# Cuts one file into a tmp file next to it and swaps it in (File.Replace), keeping its modified time. A file that changed
# while it was cut is left alone. Returns the stats, with Items = 0 when nothing was swapped.
function Convert-StorageFileInPlace {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Key)
    $path = [string]$Target.Path
    $info = New-Object IO.FileInfo $path; $mtime = $info.LastWriteTimeUtc; $len = $info.Length
    $tmp = $path + '.trim-' + [guid]::NewGuid().ToString('N')
    try {
        $st = switch ($Target.Kind) {
            'claude-jsonl' { ConvertTo-TrimmedClaudeJsonl -Path $path -OutPath $tmp -Key $Key }
            'codex-rollout' { ConvertTo-TrimmedCodexRollout -Path $path -OutPath $tmp -Key $Key }
            default { ConvertTo-TrimmedTextFile -Path $path -OutPath $tmp -Key $Key }
        }
        if (-not $st.Items -or $st.BytesAfter -ge $st.BytesBefore) { $st.Items = 0; return $st }
        $now = New-Object IO.FileInfo $path
        if ($now.Length -ne $len -or $now.LastWriteTimeUtc -ne $mtime) { throw 'changed-while-trimming: the file was written to while it was being cut, so it was left alone.' }
        (New-Object IO.FileInfo $tmp).LastWriteTimeUtc = $mtime
        [IO.File]::Replace($tmp, $path, [NullString]::Value)
        return $st
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function Invoke-StorageTrimInPlace {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target, [string]$MachineId, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)]$Res)
    $arch = Save-StorageSafetyArchive -Session $Session -Target $Target -MachineId $MachineId -WorkDir $WorkDir   # throws: the original is untouched
    $done = 0; $failed = New-Object Collections.Generic.List[string]
    foreach ($t in @(Get-StorageTrimTargets -Session $Session)) {
        try {
            $st = Convert-StorageFileInPlace -Target $t -Key ([string]$Session.Key)
            $Res.BytesBefore += $st.BytesBefore; $Res.BytesAfter += $st.BytesAfter; $Res.Items += $st.Items; if ($st.Items) { $done++ }
        } catch { $failed.Add("$($t.Path): $($_.Exception.Message)") }
    }
    if ($failed.Count -and -not $done) { throw ('trim-failed: ' + $failed[0]) }
    foreach ($f in $failed) { $Res.Warnings += "Not trimmed: $f" }
    if ($arch.Dir) {
        $info = [ordered]@{ key = [string]$Session.Key; mode = 'InPlace'; trimmedAt = (Get-Date).ToUniversalTime().ToString('o'); bytesBefore = $Res.BytesBefore; bytesAfter = $Res.BytesAfter; items = $Res.Items }
        Write-StorageSidecar -Dir $arch.Dir -Key $Session.Key -Suffix '.trim.json' -Text ($info | ConvertTo-Json)
    } else { $Res.Warnings += 'The archive is on Drive; trim.json is only kept for a local archive folder.' }
}

function Invoke-StorageTrimReadOnlyCopy {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Res)
    $dir = Get-StorageSidecarDir -Session $Session -Target $Target
    $md = ConvertTo-StorageTrimmedMarkdown -Entries @(Get-StorageSessionEntries -Session $Session) -Session $Session
    $Res.BytesBefore = [long]$Session.Bytes; $Res.BytesAfter = [long]([Text.Encoding]::UTF8.GetByteCount($md.Text)); $Res.Items = $md.Items
    Write-StorageSidecar -Dir $dir -Key $Session.Key -Suffix '.trimmed.md' -Text $md.Text
    $info = [ordered]@{ key = [string]$Session.Key; mode = 'ReadOnlyCopy'; trimmedAt = (Get-Date).ToUniversalTime().ToString('o'); bytesBefore = $Res.BytesBefore; bytesAfter = $Res.BytesAfter; items = $md.Items }
    Write-StorageSidecar -Dir $dir -Key $Session.Key -Suffix '.trim.json' -Text ($info | ConvertTo-Json)
}

function Invoke-StorageTrimOne {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target, [string]$Mode, [string]$MachineId, [Parameter(Mandatory)][string]$WorkDir, $Guard)
    $res = @{ Key = [string]$Session.Key; Ok = $false; Skipped = $false; Reason = ''; Mode = 'ReadOnlyCopy'; Warnings = @(); BytesBefore = [long]0; BytesAfter = [long]0; Items = 0 }
    if ($Session.Harness -notin 'claude', 'codex') { $res.Skipped = $true; $res.Reason = $(if ($Session.Harness -eq 'antigravity') { 'Trim is not supported for Antigravity sessions.' } else { "Trim is not supported for $($Session.Harness) sessions." }); return $res }
    if (-not $Session.Flags.Trimmable -or $Session.Flags.HasZst) { $res.Skipped = $true; $res.Reason = 'This session cannot be trimmed.'; return $res }
    $inPlace = ($Mode -eq 'InPlace' -and [bool]$script:StorageTrimInPlace[[string]$Session.Harness] -and -not $Session.Flags.Subagent)
    if ($Mode -eq 'InPlace' -and -not $inPlace) { $res.Warnings += $(if ($Session.Flags.Subagent) { 'A sub-agent rollout is not cut in place; a read-only copy was made instead.' } else { "Trim in place is not available for $($Session.Harness) yet; a read-only copy was made instead." }) }
    if ($inPlace) {
        $res.Mode = 'InPlace'
        $safe = Test-StorageSessionSafe -Session $Session @Guard
        if (-not $safe.Safe) { $res.Skipped = $true; $res.Reason = $safe.Reason; return $res }
        # Codex is changed through its app-server elsewhere, but a trim in place writes the rollout directly: its app must be closed.
        if ($Session.Harness -eq 'codex') {
            $open = @($Session.Profiles | Where-Object { @($Guard.Running['codex']) -contains [string]$_.Id } | ForEach-Object { $_.Name })
            if ($open.Count) { $res.Skipped = $true; $res.Reason = "Close Codex ($($open -join ', ')) first: trimming in place writes the rollout directly."; return $res }
        }
    }
    try {
        if ($inPlace) { Invoke-StorageTrimInPlace -Session $Session -Target $Target -MachineId $MachineId -WorkDir $WorkDir -Res $res }
        else { Invoke-StorageTrimReadOnlyCopy -Session $Session -Target $Target -Res $res }
        $res.Ok = $true
    } catch { $res.Reason = $_.Exception.Message }
    return $res
}

# Trims sessions one after the other. -Mode InPlace is a request: it is only done for a harness that $script:StorageTrimInPlace
# allows, otherwise the session gets a read-only copy. One that fails or is skipped does not stop the rest; Cancel stops before
# the next session. Returns @{ Key; Ok; Skipped; Reason; Mode; Warnings; BytesBefore; BytesAfter; Items } per session.
function Invoke-StorageTrim {
    param([Parameter(Mandatory)][array]$Sessions, [Parameter(Mandatory)]$Target, [ValidateSet('InPlace', 'ReadOnlyCopy')][string]$Mode = 'ReadOnlyCopy', [string]$MachineId = '',
          [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'harness-archive-work'), $Running = @{}, [string[]]$CliCwds = @(), [int]$RecentMinutes = 30, [string[]]$IncludeRecent = @(),
          [scriptblock]$LockProbe, $Progress, $CancelToken)
    $results = New-Object Collections.Generic.List[object]
    foreach ($s in $Sessions) {
        if (Test-StorageCancel $CancelToken) { break }
        $guard = @{ RecentMinutes = $RecentMinutes; Running = $Running; CliCwds = $CliCwds }
        if ($LockProbe) { $guard['LockProbe'] = $LockProbe }
        if ($IncludeRecent -contains [string]$s.Key) { $guard['IncludeRecent'] = $true }
        $results.Add((Invoke-StorageTrimOne -Session $s -Target $Target -Mode $Mode -MachineId $MachineId -WorkDir $WorkDir -Guard $guard))
        if ($Progress) { $Progress['Done'] = [int]$Progress['Done'] + 1 }
    }
    if ([IO.Directory]::Exists($WorkDir) -and -not @(Get-ChildItem -LiteralPath $WorkDir -Force).Count) { Remove-Item -LiteralPath $WorkDir -Force -ErrorAction SilentlyContinue }
    return $results.ToArray()
}
