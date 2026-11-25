# Harness.McpRegister.ps1 - register, unregister and inspect the harness-transcripts MCP server
# in Claude Code (user scope via claude CLI), Codex (per-profile via codex CLI + CODEX_HOME) and
# Antigravity (mcp_config.json with backup and atomic replace). ASCII only.

function Get-McpServerName {
    return 'harness-transcripts'
}

# Absolute path to mcp\harness-transcripts\server.mjs beside the app root (or $Root in tests), or $null.
function Get-McpServerPath {
    param([string]$Root)
    $rel = 'mcp\harness-transcripts\server.mjs'
    if ($PSBoundParameters.ContainsKey('Root')) {
        if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
        $candidate = [IO.Path]::GetFullPath((Join-Path $Root $rel))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        return $null
    }
    if (-not $PSScriptRoot) { return $null }
    $roots = @($PSScriptRoot)
    if ((Split-Path -Leaf $PSScriptRoot) -ieq 'src') {
        $parent = Split-Path -Parent $PSScriptRoot
        if ($parent) { $roots += $parent }
    }
    foreach ($r in $roots) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $r $rel))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# Single place for NodePath choice (updated after spike R-S3 if needed).
function Get-McpServerSpec {
    param(
        [Parameter(Mandatory)][string]$ServerPath,
        [string]$NodePath = 'node'
    )
    if ([string]::IsNullOrWhiteSpace($NodePath)) { $NodePath = 'node' }
    return @{ command = $NodePath; args = @($ServerPath) }
}

# Single place for per-app user guidance (updated after spike R-S1 if needed).
function Get-McpRegisterNote {
    param([Parameter(Mandatory)][ValidateSet('claude', 'codex', 'antigravity')][string]$Target)
    $notes = @{
        claude      = 'Open a new chat in Claude to use it.'
        codex       = 'Open a new chat in Codex to use it.'
        antigravity = 'Open a new chat in Antigravity to use it.'
    }
    return $notes[$Target]
}

function Protect-McpErrorText {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return '' }
    if (Get-Command 'Protect-TranscriptText' -CommandType Function -ErrorAction SilentlyContinue) {
        return (Protect-TranscriptText $Text)
    }
    return $Text
}

function Write-McpLog {
    param([Parameter(Mandatory)][string]$Message)
    $safe = Protect-McpErrorText $Message
    if (Get-Command 'Write-HarnessLog' -CommandType Function -ErrorAction SilentlyContinue) {
        Write-HarnessLog $safe
    } else {
        Write-Warning $safe
    }
}

# Win32 CommandLineToArgvW quoting for PowerShell 5.1 (.NET Framework 4.8 lacks ProcessStartInfo.ArgumentList).
function Format-McpProcessArguments {
    param([string[]]$ArgList = @())
    $parts = New-Object Collections.Generic.List[string]
    foreach ($item in @($ArgList)) {
        $s = [string]$item
        if ($s.Length -gt 0 -and $s -notmatch '[\s"]') {
            $parts.Add($s)
            continue
        }
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        for ($i = 0; $i -lt $s.Length; $i++) {
            $ch = $s[$i]
            if ($ch -eq '\') {
                $slashes++
            } elseif ($ch -eq '"') {
                if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
                $slashes = 0
                [void]$sb.Append('\"')
            } else {
                if ($slashes -gt 0) { [void]$sb.Append(('\' * $slashes)) }
                $slashes = 0
                [void]$sb.Append($ch)
            }
        }
        if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
        [void]$sb.Append('"')
        $parts.Add($sb.ToString())
    }
    return ($parts -join ' ')
}

function Invoke-McpDefaultRun {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$ArgList = @()
    )
    $resolved = $null
    if ([IO.Path]::IsPathRooted($Exe) -and (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        $resolved = $Exe
    } else {
        $cmd = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $resolved = $cmd.Source }
    }
    if (-not $resolved -and $Exe -ieq 'codex' -and (Get-Command 'Find-CodexInstall' -CommandType Function -ErrorAction SilentlyContinue)) {
        $install = Find-CodexInstall
        if ($install -and $install.CodexExe) { $resolved = $install.CodexExe }
    }
    if (-not $resolved) { throw "Command not found: $Exe" }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $resolved
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($item in @($ArgList)) { [void]$psi.ArgumentList.Add([string]$item) }
    } else {
        $psi.Arguments = Format-McpProcessArguments -ArgList $ArgList
    }
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        [Threading.Tasks.Task]::WaitAll(@([Threading.Tasks.Task]$outTask, [Threading.Tasks.Task]$errTask))
        return @{ ExitCode = [int]$proc.ExitCode; StdOut = [string]$outTask.Result; StdErr = [string]$errTask.Result }
    } finally {
        $proc.Dispose()
    }
}

function Test-McpNode {
    param([scriptblock]$NodeVersion)
    $rawVersion = ''
    $nodePath = ''
    try {
        if ($NodeVersion) {
            $res = & $NodeVersion
            if ($res -is [System.Collections.IDictionary]) {
                $rawVersion = [string]$res['Version']
                $nodePath = [string]$res['Path']
            } elseif ($res -and $res.PSObject.Properties['Version']) {
                $rawVersion = [string]$res.Version
                if ($res.PSObject.Properties['Path']) { $nodePath = [string]$res.Path }
            } else {
                $rawVersion = [string]$res
            }
        } else {
            $cmd = Get-Command 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cmd) {
                return @{ Ok = $false; Version = ''; Path = ''; Reason = 'Node.js (>= 22.15) was not found on PATH.' }
            }
            $nodePath = [string]$cmd.Source
            $runRes = Invoke-McpDefaultRun -Exe $nodePath -ArgList @('--version')
            if ($runRes.ExitCode -ne 0) {
                $err = Protect-McpErrorText $runRes.StdErr.Trim()
                return @{ Ok = $false; Version = ''; Path = $nodePath; Reason = "node --version failed ($($runRes.ExitCode)): $err" }
            }
            $rawVersion = [string]$runRes.StdOut
        }
    } catch {
        return @{ Ok = $false; Version = ''; Path = $nodePath; Reason = (Protect-McpErrorText $_.Exception.Message) }
    }

    $trimmed = $rawVersion.Trim()
    if ($trimmed -notmatch '^v?(\d+)\.(\d+)(?:\.(\d+))?') {
        return @{ Ok = $false; Version = $trimmed; Path = $nodePath; Reason = "Could not parse Node.js version: '$trimmed'. Requires >= 22.15." }
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $patch = $(if ($Matches[3]) { [int]$Matches[3] } else { 0 })
    $cleanVer = "$major.$minor.$patch"
    $ok = ($major -gt 22) -or ($major -eq 22 -and $minor -ge 15)
    $reason = $(if ($ok) { '' } else { "Node.js $cleanVer is too old; >= 22.15 is required." })
    return @{ Ok = $ok; Version = $cleanVer; Path = $nodePath; Reason = $reason }
}

function ConvertTo-McpClaudeJson {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Spec)
    $payload = [ordered]@{
        type    = 'stdio'
        command = [string]$Spec['command']
        args    = @($Spec['args'] | ForEach-Object { [string]$_ })
    }
    return ($payload | ConvertTo-Json -Depth 10 -Compress)
}

function Test-McpOutputMatchesPath {
    param([string]$Text, [string]$ServerPath)
    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($ServerPath)) { return $false }
    $full = [IO.Path]::GetFullPath($ServerPath)
    $variants = @(
        $full,
        $full.Replace('\', '/'),
        $full.Replace('\', '\\')
    )
    foreach ($v in $variants) {
        $pattern = '(?im)(?:^|[\s"''\[,=:])' + [regex]::Escape($v) + '(?:$|[\s"''\],;])'
        if ([regex]::IsMatch($Text, $pattern)) { return $true }
    }
    return $false
}

function Resolve-McpCliState {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$ArgList,
        [string]$ServerPath,
        [Parameter(Mandatory)][scriptblock]$Run
    )
    try {
        $res = & $Run $Exe $ArgList
    } catch {
        return 'no-cli'
    }
    if ($null -eq $res -or [int]$res.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$res.StdOut)) {
        return 'missing'
    }
    if (Test-McpOutputMatchesPath -Text ([string]$res.StdOut) -ServerPath $ServerPath) {
        return 'registered'
    }
    return 'stale'
}

# --- Claude Code (user scope via claude CLI; never parse or write ~\.claude.json) ---

function Register-McpClaude {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Spec,
        [scriptblock]$Run = { param([string]$Exe, [string[]]$ArgList) Invoke-McpDefaultRun -Exe $Exe -ArgList $ArgList }
    )
    $json = ConvertTo-McpClaudeJson -Spec $Spec
    $argList = @('mcp', 'add-json', (Get-McpServerName), $json, '--scope', 'user')
    $res = & $Run 'claude' $argList
    if ($null -eq $res -or [int]$res.ExitCode -ne 0) {
        $err = Protect-McpErrorText ([string]$res.StdErr).Trim()
        Write-McpLog "Register-McpClaude failed: $err"
        throw "claude mcp add-json failed (exit $($res.ExitCode)): $err"
    }
}

function Unregister-McpClaude {
    param(
        [scriptblock]$Run = { param([string]$Exe, [string[]]$ArgList) Invoke-McpDefaultRun -Exe $Exe -ArgList $ArgList }
    )
    $argList = @('mcp', 'remove', (Get-McpServerName), '--scope', 'user')
    $res = & $Run 'claude' $argList
    if ($null -eq $res -or [int]$res.ExitCode -ne 0) {
        $err = Protect-McpErrorText ([string]$res.StdErr).Trim()
        Write-McpLog "Unregister-McpClaude failed: $err"
        throw "claude mcp remove failed (exit $($res.ExitCode)): $err"
    }
}

function Get-McpClaudeState {
    param(
        [string]$ServerPath,
        [scriptblock]$Run = { param([string]$Exe, [string[]]$ArgList) Invoke-McpDefaultRun -Exe $Exe -ArgList $ArgList }
    )
    if (-not $PSBoundParameters.ContainsKey('ServerPath')) { $ServerPath = Get-McpServerPath }
    return (Resolve-McpCliState -Exe 'claude' -ArgList @('mcp', 'get', (Get-McpServerName)) -ServerPath $ServerPath -Run $Run)
}

# --- Codex (per-profile via codex CLI inside Invoke-WithCodexEnv) ---

function Register-McpCodex {
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Spec,
        [scriptblock]$Run = { param([string]$Exe, [string[]]$ArgList) Invoke-McpDefaultRun -Exe $Exe -ArgList $ArgList }
    )
    if (-not $Profile -or [string]::IsNullOrWhiteSpace([string]$Profile.CodexHome)) {
        throw 'Codex profile is missing CodexHome.'
    }
    $argList = @('mcp', 'add', (Get-McpServerName), '--', [string]$Spec['command']) + @($Spec['args'] | ForEach-Object { [string]$_ })
    $res = Invoke-WithCodexEnv -Profile $Profile -Action { & $Run 'codex' $argList }
    if ($null -eq $res -or [int]$res.ExitCode -ne 0) {
        $err = Protect-McpErrorText ([string]$res.StdErr).Trim()
        Write-McpLog "Register-McpCodex failed: $err"
        throw "codex mcp add failed (exit $($res.ExitCode)): $err"
    }
}

function Unregister-McpCodex {
    param(
        [Parameter(Mandatory)]$Profile,
        [scriptblock]$Run = { param([string]$Exe, [string[]]$ArgList) Invoke-McpDefaultRun -Exe $Exe -ArgList $ArgList }
    )
    if (-not $Profile -or [string]::IsNullOrWhiteSpace([string]$Profile.CodexHome)) {
        throw 'Codex profile is missing CodexHome.'
    }
    $argList = @('mcp', 'remove', (Get-McpServerName))
    $res = Invoke-WithCodexEnv -Profile $Profile -Action { & $Run 'codex' $argList }
    if ($null -eq $res -or [int]$res.ExitCode -ne 0) {
        $err = Protect-McpErrorText ([string]$res.StdErr).Trim()
        Write-McpLog "Unregister-McpCodex failed: $err"
        throw "codex mcp remove failed (exit $($res.ExitCode)): $err"
    }
}

function Get-McpCodexState {
    param(
        [Parameter(Mandatory)]$Profile,
        [string]$ServerPath,
        [scriptblock]$Run = { param([string]$Exe, [string[]]$ArgList) Invoke-McpDefaultRun -Exe $Exe -ArgList $ArgList }
    )
    if (-not $Profile -or [string]::IsNullOrWhiteSpace([string]$Profile.CodexHome)) {
        throw 'Codex profile is missing CodexHome.'
    }
    if (-not $PSBoundParameters.ContainsKey('ServerPath')) { $ServerPath = Get-McpServerPath }
    $argList = @('mcp', 'get', (Get-McpServerName))
    return (Invoke-WithCodexEnv -Profile $Profile -Action {
        Resolve-McpCliState -Exe 'codex' -ArgList $argList -ServerPath $ServerPath -Run $Run
    })
}

# --- Antigravity (mcp_config.json with backup and atomic replace) ---

function Get-McpAgyDefaultConfigPath {
    return (Join-Path $env:USERPROFILE '.gemini\antigravity\mcp_config.json')
}

function Read-McpAgyConfig {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $raw = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "bad-json: $ConfigPath" }
    try {
        $doc = $raw | ConvertFrom-Json
    } catch {
        throw "bad-json: $ConfigPath"
    }
    if ($doc -isnot [pscustomobject]) { throw "bad-json: $ConfigPath" }
    $serversProp = $doc.PSObject.Properties['mcpServers']
    if ($serversProp -and $null -ne $serversProp.Value -and $serversProp.Value -isnot [pscustomobject]) {
        throw "bad-json: $ConfigPath"
    }
    return $doc
}

function Write-McpJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $fullPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = '{0}.tmp-{1}' -f $fullPath, [guid]::NewGuid().ToString('N')
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($tmp, $Content, $utf8NoBom)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [IO.File]::Replace($tmp, $fullPath, [NullString]::Value)
        } else {
            [IO.File]::Move($tmp, $fullPath)
        }
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Register-McpAgy {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Spec,
        [string]$ConfigPath = (Get-McpAgyDefaultConfigPath),
        [datetime]$Now = (Get-Date)
    )
    $serverName = Get-McpServerName
    $entry = [pscustomobject]@{
        command = [string]$Spec['command']
        args    = @($Spec['args'] | ForEach-Object { [string]$_ })
    }
    $exists = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    if ($exists) {
        $doc = Read-McpAgyConfig -ConfigPath $ConfigPath
        $serversProp = $doc.PSObject.Properties['mcpServers']
        if (-not $serversProp -or $null -eq $serversProp.Value) {
            $doc | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $doc.mcpServers | Add-Member -NotePropertyName $serverName -NotePropertyValue $entry -Force
        $bak = '{0}.bak-{1}' -f $ConfigPath, $Now.ToString('yyMMdd-HHmmss')
        Copy-Item -LiteralPath $ConfigPath -Destination $bak -Force
    } else {
        $servers = [pscustomobject]@{}
        $servers | Add-Member -NotePropertyName $serverName -NotePropertyValue $entry -Force
        $doc = [pscustomobject]@{ mcpServers = $servers }
    }
    $json = $doc | ConvertTo-Json -Depth 20
    Write-McpJsonAtomic -Path $ConfigPath -Content $json
}

function Unregister-McpAgy {
    param(
        [string]$ConfigPath = (Get-McpAgyDefaultConfigPath),
        [datetime]$Now = (Get-Date)
    )
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }
    $doc = Read-McpAgyConfig -ConfigPath $ConfigPath
    $serversProp = $doc.PSObject.Properties['mcpServers']
    if (-not $serversProp -or $null -eq $serversProp.Value) { return }
    $serverName = Get-McpServerName
    if (-not $doc.mcpServers.PSObject.Properties[$serverName]) { return }
    $bak = '{0}.bak-{1}' -f $ConfigPath, $Now.ToString('yyMMdd-HHmmss')
    Copy-Item -LiteralPath $ConfigPath -Destination $bak -Force
    $doc.mcpServers.PSObject.Properties.Remove($serverName)
    $json = $doc | ConvertTo-Json -Depth 20
    Write-McpJsonAtomic -Path $ConfigPath -Content $json
}

function Get-McpAgyState {
    param(
        [string]$ConfigPath = (Get-McpAgyDefaultConfigPath),
        [string]$ServerPath
    )
    if (-not $PSBoundParameters.ContainsKey('ServerPath')) { $ServerPath = Get-McpServerPath }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return 'missing' }
    try {
        $doc = Read-McpAgyConfig -ConfigPath $ConfigPath
    } catch {
        return 'bad-json'
    }
    $serversProp = $doc.PSObject.Properties['mcpServers']
    if (-not $serversProp -or $null -eq $serversProp.Value) { return 'missing' }
    $entryProp = $doc.mcpServers.PSObject.Properties[(Get-McpServerName)]
    if (-not $entryProp -or $null -eq $entryProp.Value) { return 'missing' }
    if ([string]::IsNullOrWhiteSpace($ServerPath)) { return 'stale' }
    $expected = [IO.Path]::GetFullPath($ServerPath)
    foreach ($a in @($entryProp.Value.args)) {
        try {
            if ([IO.Path]::GetFullPath([string]$a) -ieq $expected) { return 'registered' }
        } catch {
            if ([string]$a -ieq $expected) { return 'registered' }
        }
    }
    return 'stale'
}
