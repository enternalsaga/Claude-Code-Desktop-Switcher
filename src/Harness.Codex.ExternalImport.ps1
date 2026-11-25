# Harness.Codex.ExternalImport.ps1 - Claude Code -> Codex import via Codex's externalAgentConfig app-server RPC.
# Needs Harness.Core.ps1, Harness.Claude.ps1, Harness.Codex.AppServer.ps1 and Harness.Codex.Chats.ps1 (ConvertFrom-CodexPath, Resolve-CodexExePath).

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

# Imports one Claude Code session through Codex's own importer (spike S3), from a bundle or directly from a source
# jsonl file. Only that session is sent, never other item types.
# Returns @{Status = imported | exists | not-detected | skipped; ThreadId}.
function Import-CodexExternalClaude {
    param(
        [string]$BundlePath = '',
        [string]$SourceJsonl = '',
        [Parameter(Mandatory)]$Profile,
        [string]$ClaudeHome = (Get-ClaudeHomePath),
        [scriptblock]$StartServer = { param($p) Start-CodexAppServer -CodexHome $p.CodexHome -CodexExe (Resolve-CodexExePath) },
        [int]$TimeoutSec = 120
    )
    $hasBundle = -not [string]::IsNullOrWhiteSpace($BundlePath)
    $hasSource = -not [string]::IsNullOrWhiteSpace($SourceJsonl)
    if ($hasBundle -eq $hasSource) { throw 'bundle-or-source' }
    $work = $null
    try {
        $ageDays = 30
        if ($hasBundle) {
            $work = Join-Path ([IO.Path]::GetTempPath()) ('codex-ext-' + [guid]::NewGuid().ToString('N'))
            $m = Read-HarnessBundle -Path $BundlePath -ExtractTo $work
            if ($m.source.harness -ne 'claude') { throw "Not a Claude bundle: $($m.source.harness)" }
            $cli = [string]$m.source.claude.cliSessionId
            if ($cli -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') { return @{ Status = 'not-detected'; ThreadId = $null } }
            $cwd = Resolve-CwdRef -Ref $m.source.cwd
            $dir = Find-ClaudeProjectDir -ClaudeHome $ClaudeHome -Cwd ([string]$cwd) -Cli $cli
            $jsonl = Join-Path $dir "$cli.jsonl"
            if (-not (Test-Path -LiteralPath $jsonl -PathType Leaf)) { return @{ Status = 'not-detected'; ThreadId = $null } }
            if ($m.source.lastActivityAt) { $ageDays = [Math]::Max(30, [int][Math]::Ceiling(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [double]$m.source.lastActivityAt) / 86400000) + 2) }
        } else {
            $jsonl = $SourceJsonl
            if (-not (Test-Path -LiteralPath $jsonl -PathType Leaf)) { return @{ Status = 'not-detected'; ThreadId = $null } }
            $mtimeUtc = (Get-Item -LiteralPath $jsonl).LastWriteTimeUtc
            $ageDays = [Math]::Max(30, [int][Math]::Ceiling(([DateTime]::UtcNow - $mtimeUtc).TotalDays) + 2)
        }
        $rec = Get-CodexExternalImportRecord -CodexHome $Profile.CodexHome -Path $jsonl
        if ($rec) { return @{ Status = 'exists'; ThreadId = $rec.imported_thread_id } }

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
                if (-not $r) { continue }
                $ok = @($r.successes) | Select-Object -First 1
                if ($ok) { return @{ Status = 'imported'; ThreadId = [string]$ok.target } }
                $fail = @($r.failures) | Select-Object -First 1
                if ($fail -and $fail.subErrorType -eq 'session_not_detected') { return @{ Status = 'not-detected'; ThreadId = $null } }
                if ($fail) { throw "Codex import failed: $($fail.message)" }
            }
            return @{ Status = 'skipped'; ThreadId = $null }
        } finally { Stop-CodexAppServer -Server $srv }
    } finally {
        if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}
