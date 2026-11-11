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
        if (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue) { & $fn }
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
    param([Parameter(Mandatory)][byte[]]$Bytes)
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

# Files: array of @{ Role; Path (entry name); SourcePath | Content }.
function New-HarnessBundle {
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][hashtable]$Source,
        [Parameter(Mandatory)][array]$Files,
        [hashtable]$Redaction = @{ scanned = $false; findings = 0; transcriptRedacted = $false },
        $PreviousBundleId = $null
    )
    Add-Type -AssemblyName System.IO.Compression
    $utf8 = New-Object Text.UTF8Encoding($false)
    $entries = @()
    foreach ($f in $Files) {
        if (-not (Test-BundleEntryName $f.Path)) { throw "Unsafe bundle entry name: $($f.Path)" }
        $bytes = if ($f.ContainsKey('Content')) { $utf8.GetBytes([string]$f.Content) } else { [IO.File]::ReadAllBytes($f.SourcePath) }
        $entries += [pscustomobject]@{ Role = $f.Role; Path = $f.Path; Bytes = $bytes }
    }
    $fileRows = @($entries | ForEach-Object { [ordered]@{ role = $_.Role; path = $_.Path; size = $_.Bytes.Length; sha256 = (Get-BytesSha256Hex $_.Bytes) } })
    $lines = @($fileRows | Sort-Object { $_.path } | ForEach-Object { '{0}:{1}' -f $_.path, $_.sha256 })
    $manifest = [ordered]@{
        format = 'harness-bundle'; version = 1; bundleId = [guid]::NewGuid().ToString()
        chatKey = ('{0}:{1}' -f $Source.harness, $Source.chatId)
        source = $Source; files = $fileRows
        lineage = [ordered]@{ previousBundleId = $PreviousBundleId; contentSha256 = (Get-BytesSha256Hex $utf8.GetBytes(($lines -join "`n"))) }
        redaction = $Redaction; encryption = $null
    }
    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $OutPath + '.tmp'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
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
    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }
    Move-Item -LiteralPath $tmp -Destination $OutPath
    return ($manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}

function Read-ZipEntryBytes {
    param([Parameter(Mandatory)]$Entry)
    $s = $Entry.Open()
    $ms = New-Object IO.MemoryStream
    try { $s.CopyTo($ms); return $ms.ToArray() } finally { $s.Dispose(); $ms.Dispose() }
}

# Validates everything (names, format, version, listing, sha256) before writing a single file.
function Read-HarnessBundle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExtractTo
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }
            if (-not (Test-BundleEntryName $e.FullName)) { throw "Unsafe entry in bundle: $($e.FullName)" }
        }
        $mEntry = $zip.GetEntry('manifest.json')
        if (-not $mEntry) { throw 'Bundle has no manifest.json' }
        $manifest = [Text.Encoding]::UTF8.GetString((Read-ZipEntryBytes $mEntry)) | ConvertFrom-Json
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
        $payload = @{}
        foreach ($f in @($manifest.files)) {
            $entry = $zip.GetEntry($f.path)
            if (-not $entry) { throw "Listed file missing from bundle: $($f.path)" }
            if ($entry.Length -ne $f.size) { throw "Size mismatch (declared $($f.size), entry $($entry.Length)): $($f.path)" }
            $bytes = Read-ZipEntryBytes $entry
            if ((Get-BytesSha256Hex $bytes) -ne $f.sha256) { throw "sha256 mismatch: $($f.path)" }
            $payload[$f.path] = $bytes
        }
        $root = [IO.Path]::GetFullPath($ExtractTo).TrimEnd('\') + '\'
        foreach ($name in $payload.Keys) {
            $target = [IO.Path]::GetFullPath((Join-Path $root ($name -replace '/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Entry escapes destination: $name" }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllBytes($target, $payload[$name])
        }
        return $manifest
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
        @{ Regex = '(?im)^(?<pre>[ \t]*(?:export[ \t]+)?(?-i:[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*)[ \t]*=[ \t]*)(?!\[REDACTED\])\S[^\r\n]*'; Replacement = '${pre}[REDACTED]' }
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
    param([Parameter(Mandatory)][array]$Entries)
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
        [Parameter(Mandatory)][array]$Entries,
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
    if (-not $Ref.root) { return $Ref.absolute }
    if (-not $PathRoots.ContainsKey($Ref.root)) { return $null }
    $root = ([string]$PathRoots[$Ref.root]).TrimEnd('\')
    if (-not $Ref.relative) { return $root }
    return $root + '\' + $Ref.relative
}
