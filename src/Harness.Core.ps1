# Harness.Core.ps1 - shared core for the multi-harness switcher (Claude, Codex, Antigravity).
# Plain functions and hashtables only: PowerShell classes are fragile when dot-sourced on 5.1.
# Sections: registry (C2), bundle and cwd mapping (C3), redaction and transcript (C4),
# read-only SQLite (C5). Nothing in here touches real app data.

# --- Registry -----------------------------------------------------------------

# Optional: ImportNative, ImportNeedsClose, ImportExternalClaude, NewProfile, RemoveProfile, Rename.
# A function, not a script variable, so tests that load single functions by AST still work.
function Get-HarnessRequiredCapabilities {
    return @('Detect', 'GetProfiles', 'Launch', 'ListChats', 'Export', 'ImportHandoff')
}

function Reset-HarnessRegistry {
    $script:Harnesses = [ordered]@{}
}

function Register-Harness {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Adapter
    )
    $missing = @(Get-HarnessRequiredCapabilities | Where-Object { -not ($Adapter[$_] -is [scriptblock]) })
    if ($missing.Count) { throw ("Harness '{0}' is missing required capabilities: {1}" -f $Name, ($missing -join ', ')) }
    if ($null -eq $script:Harnesses) { Reset-HarnessRegistry }
    $script:Harnesses[$Name.ToLowerInvariant()] = [pscustomobject]@{ Name = $Name.ToLowerInvariant(); Adapter = $Adapter }
}

function Get-Harness {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -eq $script:Harnesses) { return $null }
    return $script:Harnesses[$Name.ToLowerInvariant()]
}

function Get-Harnesses {
    if ($null -eq $script:Harnesses) { return @() }
    return @($script:Harnesses.Values)
}

# Hook 2 in ClaudeSwitcher.ps1 calls this. Each adapter file defines Register-<Name>Harness; the ones that are
# loaded get registered, so adding an adapter never means editing this file.
function Register-Harnesses {
    Reset-HarnessRegistry
    foreach ($fn in 'Register-ClaudeHarness', 'Register-CodexHarness', 'Register-AntigravityHarness') {
        if (-not (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { continue }
        # One broken adapter must not take the others, or the switcher, down with it.
        try { & $fn } catch { Write-HarnessLog "$fn failed: $($_.Exception.Message)" }
    }
}

# Appends a line to the switcher's error log ($script:LogPath of ClaudeSwitcher.ps1); a warning when there is none.
function Write-HarnessLog {
    param([Parameter(Mandatory)][string]$Message)
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $Message) } catch { }
    } else { Write-Warning $Message }
}

# Copies the clone's src\ next to the installed script. Returns:
#   'skipped'   not a .switcher folder (never replace anything else)
#   'kept'      the user kept their own installed script, so its src\ stays as it is
#   'installed' src\ replaced
#   'failed'    the copy failed; the previous src\ is untouched
# "Kept" is read from ClaudeSwitcher.base.ps1: Update-InstalledScript copies the new script over it
# whenever this version was installed or merged, and leaves it alone when the user chose to keep the old copy.
function Install-HarnessSource {
    param([Parameter(Mandatory)][string]$SourceDir, [Parameter(Mandatory)][string]$SwitcherHome, [Parameter(Mandatory)][string]$ScriptPath)
    if ((Split-Path $SwitcherHome -Leaf) -ne '.switcher') { return 'skipped' }
    $base = Join-Path $SwitcherHome 'ClaudeSwitcher.base.ps1'
    $same = $false
    if (Test-Path -LiteralPath $base) {
        $same = ([IO.File]::ReadAllText($base).Replace("`r`n", "`n") -ceq [IO.File]::ReadAllText($ScriptPath).Replace("`r`n", "`n"))
    }
    if (-not $same) { return 'kept' }
    $dst = Join-Path $SwitcherHome 'src'
    $new = Join-Path $SwitcherHome 'src.new'
    $old = Join-Path $SwitcherHome 'src.old'
    try {
        foreach ($p in $new, $old) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
        Copy-Item -LiteralPath $SourceDir -Destination $new -Recurse -ErrorAction Stop
        if (Test-Path -LiteralPath $dst) { Rename-Item -LiteralPath $dst -NewName 'src.old' -ErrorAction Stop }
        try { Rename-Item -LiteralPath $new -NewName 'src' -ErrorAction Stop }
        catch {
            if (Test-Path -LiteralPath $old) { Rename-Item -LiteralPath $old -NewName 'src' }
            throw
        }
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
        return 'installed'
    } catch {
        Write-HarnessLog "Could not install src\: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force -ErrorAction SilentlyContinue }
        return 'failed'
    }
}

# native: same harness and the adapter can import natively.
# codex-import: Claude chat into Codex through Codex's own external-agent importer.
# handoff: everything else (transcript plus opening prompt).
function Resolve-TransferMode {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    $to = Get-Harness -Name $Target
    if (-not $to) { throw "Unknown harness: $Target" }
    $from = Get-Harness -Name $Source
    if (-not $from) { throw "Unknown harness: $Source" }
    if ($from.Name -eq $to.Name) {
        if ($to.Adapter['ImportNative'] -is [scriptblock]) { return 'native' }
        return 'handoff'
    }
    if ($from.Name -eq 'claude' -and $to.Name -eq 'codex' -and $to.Adapter['ImportExternalClaude'] -is [scriptblock]) { return 'codex-import' }
    return 'handoff'
}

# --- Bundle v1 (harness-bundle) -------------------------------------------------

function Get-BytesSha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

# A zip entry name is safe when it is a relative, forward-slash path with no empty, '.' or '..' segment.
function Test-BundleEntryName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name) -or $Name.Contains('\') -or $Name.Contains(':') -or $Name.StartsWith('/')) { return $false }
    foreach ($segment in $Name.Split('/')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { return $false }
    }
    return $true
}

# Machine id/name and named folder roots come from the Sync lane (Get-SyncMachine / Get-SyncPathRoots)
# when it is loaded; without it the values are empty, as before.
function Get-HarnessMachineInfo {
    if (Get-Command Get-SyncMachine -ErrorAction SilentlyContinue) {
        $m = Get-SyncMachine
        if ($m) { return [pscustomobject]@{ Id = $m.Id; Name = $m.Name } }
    }
    return [pscustomobject]@{ Id = $null; Name = $null }
}

function Get-HarnessPathRoots {
    if (Get-Command Get-SyncPathRoots -ErrorAction SilentlyContinue) {
        $r = Get-SyncPathRoots
        if ($r -is [System.Collections.IDictionary]) { return $r }
    }
    return @{}
}

# Files: array of @{ Role; Path (entry name); SourcePath | Content }.
function New-HarnessBundle {
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][hashtable]$Source,
        [Parameter(Mandatory)][array]$Files,
        [hashtable]$Redaction = @{ scanned = $false; findings = 0; transcriptRedacted = $false },
        $PreviousBundleId = $null,
        [long]$MaxBytes = 512MB
    )
    Add-Type -AssemblyName System.IO.Compression
    $utf8 = New-Object Text.UTF8Encoding($false)
    # The cap is checked on sizes alone, before any file is read or written.
    $total = [long]0
    foreach ($f in $Files) {
        if ($f.ContainsKey('Content')) { $total += $utf8.GetByteCount([string]$f.Content) } else { $total += (New-Object IO.FileInfo $f.SourcePath).Length }
    }
    if ($total -gt $MaxBytes) { throw "bundle-too-large: $total bytes is over the $MaxBytes byte limit" }
    $entries = @()
    foreach ($f in $Files) {
        if (-not (Test-BundleEntryName $f.Path)) { throw "Unsafe bundle entry name: $($f.Path)" }
        # Plain assignments in both branches: an empty byte[] coming out of an if-expression would become $null.
        if ($f.ContainsKey('Content')) { $bytes = $utf8.GetBytes([string]$f.Content) } else { $bytes = [IO.File]::ReadAllBytes($f.SourcePath) }
        $entries += [pscustomobject]@{ Role = $f.Role; Path = $f.Path; Bytes = $bytes }
    }
    $fileRows = @($entries | ForEach-Object { [ordered]@{ role = $_.Role; path = $_.Path; size = $_.Bytes.Length; sha256 = (Get-BytesSha256Hex $_.Bytes) } })
    $lines = @($fileRows | Sort-Object { $_.path } | ForEach-Object { '{0}:{1}' -f $_.path, $_.sha256 })
    # The manifest is readable without the passphrase and is never encrypted, so a secret in the title or
    # the working directory is redacted here (on a copy; the caller's hashtable is left alone).
    $safeSource = @{}
    foreach ($k in $Source.Keys) { $safeSource[$k] = $Source[$k] }
    if (-not $safeSource['machineId'] -or -not $safeSource['machineName']) {
        $mi = Get-HarnessMachineInfo
        if (-not $safeSource['machineId']) { $safeSource['machineId'] = $mi.Id }
        if (-not $safeSource['machineName']) { $safeSource['machineName'] = $mi.Name }
    }
    if ($safeSource['title']) { $safeSource['title'] = Protect-TranscriptText ([string]$safeSource['title']) }
    if ($safeSource['cwd'] -is [System.Collections.IDictionary]) {
        $cwdCopy = @{}
        foreach ($k in $safeSource['cwd'].Keys) { $cwdCopy[$k] = $safeSource['cwd'][$k] }
        foreach ($k in 'absolute', 'relative') { if ($cwdCopy[$k]) { $cwdCopy[$k] = Protect-TranscriptText ([string]$cwdCopy[$k]) } }
        $safeSource['cwd'] = $cwdCopy
    }
    $manifest = [ordered]@{
        format = 'harness-bundle'; version = 1; bundleId = [guid]::NewGuid().ToString()
        chatKey = ('{0}:{1}' -f $Source.harness, $Source.chatId)
        source = $safeSource; files = $fileRows
        lineage = [ordered]@{ previousBundleId = $PreviousBundleId; contentSha256 = (Get-BytesSha256Hex $utf8.GetBytes(($lines -join "`n"))) }
        redaction = $Redaction; encryption = $null
    }
    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $OutPath -PathType Container) { throw "OutPath is a folder: $OutPath" }
    # Written beside the target and moved into place last, so a failure never leaves a half-written bundle.
    $tmp = $OutPath + '.tmp'
    try {
        $fs = [IO.File]::Create($tmp)
        try {
            $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $all = @([pscustomobject]@{ Path = 'manifest.json'; Bytes = $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 10)) }) + $entries
                foreach ($e in $all) {
                    $s = $zip.CreateEntry($e.Path, [IO.Compression.CompressionLevel]::Optimal).Open()
                    try { $s.Write($e.Bytes, 0, $e.Bytes.Length) } finally { $s.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $fs.Dispose() }
        Move-Item -LiteralPath $tmp -Destination $OutPath -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
    return ($manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}

function Read-ZipEntryBytes {
    param([Parameter(Mandatory)]$Entry)
    $s = $Entry.Open()
    $ms = New-Object IO.MemoryStream
    try { $s.CopyTo($ms); return , $ms.ToArray() } finally { $s.Dispose(); $ms.Dispose() }
}

# Limits for a bundle that may come from another machine (plan D6). The ratio is only judged above RatioFloor.
function Get-HarnessBundleLimits {
    return @{ MaxTotalBytes = 1GB; MaxEntries = 20000; MaxManifestBytes = 1MB; MaxRatio = 200; RatioFloor = 1MB }
}

# Streams one entry into $Out (when given), counting the bytes actually produced, never the sizes in the zip
# header, and hashing on the way. Throws bundle-limit past $MaxBytes or an absurd compression ratio.
function Copy-ZipEntryChecked {
    param([Parameter(Mandatory)]$Entry, [IO.Stream]$Out, [Parameter(Mandatory)][long]$MaxBytes, [Parameter(Mandatory)][hashtable]$Limits)
    $sha = [Security.Cryptography.SHA256]::Create()
    $in = $Entry.Open()
    try {
        $buf = New-Object byte[] 81920; $n = [long]0
        while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $n += $r
            if ($n -gt $MaxBytes) { throw "bundle-limit: $($Entry.FullName) is larger than allowed ($MaxBytes bytes)" }
            if ($n -gt $Limits.RatioFloor -and $n -gt $Limits.MaxRatio * [Math]::Max([long]$Entry.CompressedLength, 1)) { throw "bundle-limit: $($Entry.FullName) compresses suspiciously well" }
            [void]$sha.TransformBlock($buf, 0, $r, $null, 0)
            if ($Out) { $Out.Write($buf, 0, $r) }
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
        return [pscustomobject]@{ Size = $n; Sha256 = (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '') }
    } finally { $in.Dispose(); $sha.Dispose() }
}

# Validates names, format, version, listing, sizes and sha256 while extracting into <ExtractTo>.part, which is
# renamed to ExtractTo only when every entry is good: a failure leaves nothing behind.
function Read-HarnessBundle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExtractTo,
        [hashtable]$Limits = @{}
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $lim = Get-HarnessBundleLimits
    foreach ($k in $Limits.Keys) { $lim[$k] = $Limits[$k] }
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    $part = [IO.Path]::GetFullPath($ExtractTo).TrimEnd('\') + '.part'
    try {
        if ($zip.Entries.Count -gt $lim.MaxEntries) { throw "bundle-limit: more than $($lim.MaxEntries) entries" }
        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }
            if (-not (Test-BundleEntryName $e.FullName)) { throw "Unsafe entry in bundle: $($e.FullName)" }
        }
        $mEntry = $zip.GetEntry('manifest.json')
        if (-not $mEntry) { throw 'Bundle has no manifest.json' }
        $mStream = New-Object IO.MemoryStream
        try { [void](Copy-ZipEntryChecked -Entry $mEntry -Out $mStream -MaxBytes $lim.MaxManifestBytes -Limits $lim); $manifest = [Text.Encoding]::UTF8.GetString($mStream.ToArray()) | ConvertFrom-Json } finally { $mStream.Dispose() }
        if ($manifest.format -ne 'harness-bundle') { throw "Unknown bundle format: $($manifest.format)" }
        if ($manifest.version -ne 1) { throw "Unsupported bundle version: $($manifest.version)" }
        $seen = @{}
        foreach ($e in $zip.Entries) {
            if ($seen.ContainsKey($e.FullName)) { throw "Duplicate entry in bundle: $($e.FullName)" }
            $seen[$e.FullName] = $true
        }
        $listed = @{}
        foreach ($f in @($manifest.files)) { $listed[$f.path] = $f }
        foreach ($e in $zip.Entries) {
            if ($e.FullName -eq 'manifest.json' -or $e.FullName.EndsWith('/')) { continue }
            if (-not $listed.ContainsKey($e.FullName)) { throw "Entry not listed in manifest: $($e.FullName)" }
        }
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Recurse -Force }
        $root = $part + '\'
        $total = [long]0
        foreach ($f in @($manifest.files)) {
            $entry = $zip.GetEntry($f.path)
            if (-not $entry) { throw "Listed file missing from bundle: $($f.path)" }
            $target = [IO.Path]::GetFullPath((Join-Path $root ($f.path -replace '/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Entry escapes destination: $($f.path)" }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $out = [IO.File]::Create($target)
            try { $res = Copy-ZipEntryChecked -Entry $entry -Out $out -MaxBytes ([Math]::Min([long]$f.size, $lim.MaxTotalBytes - $total)) -Limits $lim } finally { $out.Dispose() }
            if ($res.Size -ne $f.size) { throw "Size mismatch (declared $($f.size), entry $($res.Size)): $($f.path)" }
            if ($res.Sha256 -ne $f.sha256) { throw "sha256 mismatch: $($f.path)" }
            $total += $res.Size
        }
        if (Test-Path -LiteralPath $ExtractTo) {   # only an empty folder may be replaced; Delete never prompts
            if ((Test-Path -LiteralPath $ExtractTo -PathType Leaf) -or (Get-ChildItem -LiteralPath $ExtractTo -Force | Select-Object -First 1)) { throw "Extract target exists: $ExtractTo" }
            [IO.Directory]::Delete([IO.Path]::GetFullPath($ExtractTo))
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($ExtractTo))))
        if (-not (Test-Path -LiteralPath $part)) { New-Item -ItemType Directory -Path $part | Out-Null }   # a bundle with no files
        Move-Item -LiteralPath $part -Destination $ExtractTo
        return $manifest
    } catch {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally { $zip.Dispose() }
}

# --- Secret redaction and handoff transcript ------------------------------------

# Patterns from spec section 8. Order matters: whole blocks and specific tokens first, KEY=value lines last.
function Get-SecretPatterns {
    return @(
        @{ Regex = '(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----'; Replacement = '[REDACTED]' },
        @{ Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----'; Replacement = '[REDACTED]' },
        @{ Regex = 'sk-[A-Za-z0-9_\-]{20,}'; Replacement = '[REDACTED]' },
        @{ Regex = 'gh[po]_[A-Za-z0-9]{20,}'; Replacement = '[REDACTED]' },
        @{ Regex = 'github_pat_[A-Za-z0-9_]{20,}'; Replacement = '[REDACTED]' },
        @{ Regex = 'AKIA[0-9A-Z]{16}'; Replacement = '[REDACTED]' },
        @{ Regex = 'xox[abp]-[A-Za-z0-9\-]{10,}'; Replacement = '[REDACTED]' },
        @{ Regex = 'AIza[0-9A-Za-z_\-]{35}'; Replacement = '[REDACTED]' },
        @{ Regex = 'Bearer\s+[A-Za-z0-9._~+/=\-]{16,}'; Replacement = 'Bearer [REDACTED]' },
        @{ Regex = '(?im)^(?<pre>[ \t]*(?:export[ \t]+)?(?-i:[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*)[ \t]*=[ \t]*)(?!\[REDACTED\])\S[^\r\n]*'; Replacement = '${pre}[REDACTED]' },
        # NAME=value in the middle of a line (single token or quoted), "password": "x" in JSON, and --password=x flags.
        @{ Regex = '(?<![A-Za-z0-9_])(?<pre>(?-i:[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*)=)(?!\[REDACTED\])(?:"[^"\r\n]*"|''[^''\r\n]*''|[^\s"'']+)'; Replacement = '${pre}[REDACTED]' },
        @{ Regex = '(?<pre>"[A-Za-z0-9_\-]*(?:password|passwd|secret|token|api[_-]?key|apikey)"\s*:\s*)"(?!\[REDACTED\]")(?:[^"\\\r\n]|\\.)*"'; Replacement = '${pre}"[REDACTED]"' },
        @{ Regex = '(?<![A-Za-z0-9_])(?<pre>--?[A-Za-z0-9_\-]*(?:password|passwd|secret|token|api[_-]?key|apikey)=)(?!\[REDACTED\])(?:"[^"\r\n]*"|''[^''\r\n]*''|\S+)'; Replacement = '${pre}[REDACTED]' }
    )
}

function Invoke-SecretScan {
    param([AllowEmptyString()][string]$Text)
    $count = 0
    foreach ($p in Get-SecretPatterns) {
        $re = New-Object Text.RegularExpressions.Regex($p.Regex, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $count += $re.Matches($Text).Count
        $Text = $re.Replace($Text, $p.Replacement)
    }
    return @{ Text = $Text; Count = $count }
}

function Protect-TranscriptText {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    return (Invoke-SecretScan -Text $Text).Text
}

# Counts only; never changes the text or the file (native files must stay byte-identical).
function Measure-SecretFindings {
    param([string]$Text, [string]$Path)
    if ($Path) { $Text = [IO.File]::ReadAllText($Path) }
    if (-not $Text) { return 0 }
    return (Invoke-SecretScan -Text $Text).Count
}

# Returns redacted copies of normalized transcript entries (role, text, ts, tool{name,arg,output}).
function Protect-TranscriptEntries {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Entries)
    foreach ($e in $Entries) {
        $copy = @{ role = $e.role; text = (Protect-TranscriptText ([string]$e.text)); ts = $e.ts }
        if ($e.tool) {
            $copy.tool = @{ name = $e.tool.name; arg = (Protect-TranscriptText ([string]$e.tool.arg)); output = (Protect-TranscriptText ([string]$e.tool.output)) }
        }
        $copy
    }
}

function Get-FirstSentence {
    param([string]$Text, [int]$MaxLength = 160)
    $line = (($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return '' }
    $line = $line.Trim()
    $m = [regex]::Match($line, '^(.*?[.!?])(\s|$)')
    if ($m.Success) { $line = $m.Groups[1].Value }
    if ($line.Length -gt $MaxLength) { $line = $line.Substring(0, $MaxLength) + '...' }
    return $line
}

function Format-TranscriptTurn {
    param([Parameter(Mandatory)][array]$Turn, [int]$MaxOutput = 2048)
    $out = New-Object Text.StringBuilder
    foreach ($e in $Turn) {
        if ($e.role -eq 'tool') {
            $arg = ([string]$e.tool.arg -replace '\s+', ' ').Trim()
            if ($arg.Length -gt 200) { $arg = $arg.Substring(0, 200) + '...' }
            [void]$out.AppendLine(('- tool `{0}`: {1}' -f $e.tool.name, $arg))
            $o = [string]$e.tool.output
            if ($o) {
                if ($o.Length -gt $MaxOutput) { $o = $o.Substring(0, $MaxOutput) + "`n... [truncated $($o.Length - $MaxOutput) more chars]" }
                [void]$out.AppendLine('~~~'); [void]$out.AppendLine($o); [void]$out.AppendLine('~~~')
            }
        } else {
            [void]$out.AppendLine("### $($e.role)"); [void]$out.AppendLine([string]$e.text); [void]$out.AppendLine('')
        }
    }
    return $out.ToString()
}

# A turn starts at each user entry. The last KeepTurns turns are kept in full, earlier ones become one line
# (the first sentence of the user's message). The result is always redacted.
function ConvertTo-HandoffMarkdown {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Entries,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$Title,
        [string]$Cwd, [string]$Branch, [string[]]$Artifacts = @(), [int]$KeepTurns = 40
    )
    # Redact before any truncation: a token cut in half would no longer match its pattern.
    $Entries = @(Protect-TranscriptEntries -Entries $Entries)
    $turns = New-Object Collections.Generic.List[object]
    foreach ($e in $Entries) {
        if ($e.role -eq 'user' -or $turns.Count -eq 0) { $turns.Add((New-Object Collections.Generic.List[object])) }
        $turns[$turns.Count - 1].Add($e)
    }
    $md = New-Object Text.StringBuilder
    [void]$md.AppendLine("# Handoff: $Title"); [void]$md.AppendLine('')
    [void]$md.AppendLine("- Source harness: $Harness")
    if ($Cwd) { [void]$md.AppendLine("- Working directory: $Cwd") }
    if ($Branch) { [void]$md.AppendLine("- Git branch: $Branch") }
    if (@($Artifacts).Count) { [void]$md.AppendLine("- Artifacts: $($Artifacts -join ', ')") }
    [void]$md.AppendLine('')
    $split = [Math]::Max(0, $turns.Count - $KeepTurns)
    if ($split -gt 0) {
        [void]$md.AppendLine("## Earlier turns (mechanical summary of $split)"); [void]$md.AppendLine('')
        for ($i = 0; $i -lt $split; $i++) {
            $first = $turns[$i] | Where-Object { $_.role -eq 'user' } | Select-Object -First 1
            [void]$md.AppendLine(('{0}. {1}' -f ($i + 1), (Get-FirstSentence -Text ([string]$first.text))))
        }
        [void]$md.AppendLine('')
    }
    [void]$md.AppendLine("## Recent turns (last $($turns.Count - $split))"); [void]$md.AppendLine('')
    for ($i = $split; $i -lt $turns.Count; $i++) { [void]$md.Append((Format-TranscriptTurn -Turn $turns[$i].ToArray())) }
    return (Protect-TranscriptText $md.ToString().Replace("`r`n", "`n"))
}

# --- cwd mapping ----------------------------------------------------------------

function ConvertTo-CwdRef {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$PathRoots = @{}
    )
    if (-not $PathRoots -or $PathRoots.Count -eq 0) { $PathRoots = Get-HarnessPathRoots }
    $best = $null; $bestLen = -1
    foreach ($name in $PathRoots.Keys) {
        $root = ([string]$PathRoots[$name]).TrimEnd('\')
        if ($root.Length -le $bestLen) { continue }
        if ($Path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $best = $name; $bestLen = $root.Length
        }
    }
    if ($null -eq $best) { return @{ absolute = $Path; root = $null; relative = $null } }
    return @{ absolute = $Path; root = $best; relative = $Path.Substring($bestLen).TrimStart('\') }
}

# Returns the absolute path on this machine, or $null when the named root is unknown here (caller asks the user).
function Resolve-CwdRef {
    param(
        [Parameter(Mandatory)]$Ref,
        [hashtable]$PathRoots = @{}
    )
    # The ref may come from another machine, so it is validated before it becomes a path.
    if (-not $Ref.root) {
        $abs = [string]$Ref.absolute
        if ($abs -match '[\x00-\x1F\x7F]' -or $abs -notmatch '^(?:[A-Za-z]:\\|\\\\)[^\\]') { return $null }
        return $abs
    }
    if (-not $PathRoots.ContainsKey($Ref.root)) { return $null }
    $root = ([string]$PathRoots[$Ref.root]).TrimEnd('\')
    if (-not $Ref.relative) { return $root }
    $rel = [string]$Ref.relative
    if ($rel -match '[\x00-\x1F\x7F:]' -or $rel.StartsWith('\') -or $rel.StartsWith('/')) { return $null }
    foreach ($segment in ($rel -split '[\\/]')) { if ($segment -eq '..') { return $null } }
    return $root + '\' + $rel
}
