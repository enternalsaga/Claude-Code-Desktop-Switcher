$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
$coreFile = Join-Path $repoRoot 'src\Harness.Core.ps1'
$codexProfilesFile = Join-Path $repoRoot 'src\Harness.Codex.Profiles.ps1'
$mcpRegFile = Join-Path $repoRoot 'src\Harness.McpRegister.ps1'

. (Import-TestFunctions -Files @($coreFile) -Names @(
    'Get-SecretPatterns', 'Invoke-SecretScan', 'Protect-TranscriptText', 'Write-HarnessLog'
))
. (Import-TestFunctions -Files @($codexProfilesFile) -Names @(
    'Invoke-WithCodexEnv'
))
. (Import-TestFunctions -Files @($mcpRegFile) -Names @(
    'Get-McpServerName', 'Get-McpServerPath', 'Test-McpNode', 'Get-McpServerSpec',
    'Get-McpRegisterNote', 'Format-McpProcessArguments', 'Invoke-McpDefaultRun',
    'Protect-McpErrorText', 'Write-McpLog', 'ConvertTo-McpClaudeJson',
    'Test-McpOutputMatchesPath', 'Resolve-McpCliState',
    'Register-McpClaude', 'Unregister-McpClaude', 'Get-McpClaudeState',
    'Register-McpCodex', 'Unregister-McpCodex', 'Get-McpCodexState',
    'Get-McpAgyDefaultConfigPath', 'Read-McpAgyConfig', 'Write-McpJsonAtomic',
    'Register-McpAgy', 'Unregister-McpAgy', 'Get-McpAgyState'
))

$temp = New-TestTempDir
try {
    # --- 1. Server path ---
    Assert ((Get-McpServerName) -ceq 'harness-transcripts') 'server name'
    $root1 = Join-Path $temp 'plain-root'
    New-Item -ItemType Directory -Path $root1 -Force | Out-Null
    Assert ($null -eq (Get-McpServerPath -Root $root1)) 'missing server.mjs returns null'

    $spacedRoot = Join-Path $temp 'root with spaces'
    $serverDir = Join-Path $spacedRoot 'mcp\harness-transcripts'
    New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    $fakeServer = Join-Path $serverDir 'server.mjs'
    [IO.File]::WriteAllText($fakeServer, "// fake`n")
    $resolvedServer = Get-McpServerPath -Root $spacedRoot
    Assert ($resolvedServer -ceq [IO.Path]::GetFullPath($fakeServer)) "Get-McpServerPath with spaces: $resolvedServer"

    # Also check default $PSScriptRoot resolution from both src\ and root (single-file layout)
    $srcCopyDir = Join-Path $spacedRoot 'src'
    New-Item -ItemType Directory -Path $srcCopyDir -Force | Out-Null
    $srcCopyFile = Join-Path $srcCopyDir 'Harness.McpRegister.ps1'
    Copy-Item -LiteralPath $mcpRegFile -Destination $srcCopyFile -Force
    $fromSrc = & powershell -NoProfile -Command ". '$($srcCopyFile.Replace("'", "''"))'; Get-McpServerPath"
    Assert ($fromSrc -ceq [IO.Path]::GetFullPath($fakeServer)) "dot-sourced from src finds parent mcp folder: $fromSrc"

    $singleCopyFile = Join-Path $spacedRoot 'ClaudeSwitcher.ps1'
    Copy-Item -LiteralPath $mcpRegFile -Destination $singleCopyFile -Force
    $fromRoot = & powershell -NoProfile -Command ". '$($singleCopyFile.Replace("'", "''"))'; Get-McpServerPath"
    Assert ($fromRoot -ceq [IO.Path]::GetFullPath($fakeServer)) "dot-sourced from root finds mcp folder: $fromRoot"

    # --- 2. Node check ---
    $n14 = Test-McpNode -NodeVersion { 'v22.14.0' }
    Assert (-not $n14.Ok -and $n14.Reason) 'v22.14.0 must fail'
    $n15 = Test-McpNode -NodeVersion { 'v22.15.0' }
    Assert ($n15.Ok -and $n15.Version -eq '22.15.0') "v22.15.0 must pass: $($n15.Reason)"
    $n24 = Test-McpNode -NodeVersion { 'v24.22.1' }
    Assert ($n24.Ok -and $n24.Version -eq '24.22.1') 'v24.22.1 must pass'
    $n21 = Test-McpNode -NodeVersion { 'v21.9.0' }
    Assert (-not $n21.Ok) 'v21.9.0 must fail'
    $nThrow = Test-McpNode -NodeVersion { throw 'node not found' }
    Assert (-not $nThrow.Ok -and $nThrow.Reason -like '*not found*') 'throwing NodeVersion must fail cleanly'
    $nGarbage = Test-McpNode -NodeVersion { 'not-a-version' }
    Assert (-not $nGarbage.Ok -and $nGarbage.Reason) 'unparseable version must fail'

    # --- 3. Server spec and register notes ---
    $spacedPath = 'C:\x y\mcp\harness-transcripts\server.mjs'
    $specNode = Get-McpServerSpec -ServerPath $spacedPath -NodePath 'node'
    Assert ($specNode -is [hashtable]) 'spec must be hashtable'
    Assert ($specNode.command -ceq 'node') 'spec command uses node'
    Assert (@($specNode.args).Count -eq 1 -and $specNode.args[0] -ceq $spacedPath) 'spec args holds path'

    $absNode = 'C:\Program Files\nodejs\node.exe'
    $specAbs = Get-McpServerSpec -ServerPath $spacedPath -NodePath $absNode
    Assert ($specAbs.command -ceq $absNode) 'spec uses NodePath as given'

    Assert ((Get-McpRegisterNote -Target 'claude') -ceq 'Open a new chat in Claude to use it.') 'claude note'
    Assert ((Get-McpRegisterNote -Target 'codex') -ceq 'Open a new chat in Codex to use it.') 'codex note'
    Assert ((Get-McpRegisterNote -Target 'antigravity') -ceq 'Open a new chat in Antigravity to use it.') 'agy note'

    # --- 4. claude add-json argv & unregister & stderr redaction ---
    $calls = New-Object Collections.ArrayList
    $okRun = {
        param([string]$Exe, [string[]]$ArgList)
        [void]$calls.Add([pscustomobject]@{ Exe = $Exe; ArgList = $ArgList; CodexHome = $env:CODEX_HOME })
        return @{ ExitCode = 0; StdOut = 'ok'; StdErr = '' }
    }

    Register-McpClaude -Spec $specNode -Run $okRun
    Assert ($calls.Count -eq 1) 'claude add recorded 1 call'
    $cAdd = $calls[0]
    Assert ($cAdd.Exe -ceq 'claude') 'claude exe'
    Assert ($cAdd.ArgList.Count -eq 6) "claude add arg count: $($cAdd.ArgList.Count)"
    Assert ($cAdd.ArgList[0] -ceq 'mcp' -and $cAdd.ArgList[1] -ceq 'add-json' -and $cAdd.ArgList[2] -ceq 'harness-transcripts' -and $cAdd.ArgList[4] -ceq '--scope' -and $cAdd.ArgList[5] -ceq 'user') 'claude add-json fixed argv'
    $parsedClaude = $cAdd.ArgList[3] | ConvertFrom-Json
    Assert ($parsedClaude.type -ceq 'stdio') 'claude json type stdio'
    Assert ($parsedClaude.command -ceq 'node') 'claude json command'
    Assert (@($parsedClaude.args).Count -eq 1 -and $parsedClaude.args[0] -ceq $spacedPath) 'claude json preserves path with spaces'

    $calls.Clear()
    Unregister-McpClaude -Run $okRun
    Assert ($calls.Count -eq 1 -and $calls[0].Exe -ceq 'claude') 'claude remove exe'
    Assert (($calls[0].ArgList -join '|') -ceq 'mcp|remove|harness-transcripts|--scope|user') 'claude remove argv'

    $fakeSecret = 'sk-' + 'ant-TEST' + ('A' * 30)
    $errRun = {
        param([string]$Exe, [string[]]$ArgList)
        return @{ ExitCode = 1; StdOut = ''; StdErr = "auth failed token=$fakeSecret" }
    }
    $script:LogPath = Join-Path $temp 'mcp-test.log'
    try {
        $errMsg = ''
        try { Register-McpClaude -Spec $specNode -Run $errRun } catch { $errMsg = $_.Exception.Message }
        Assert ($errMsg.Contains('[REDACTED]') -and -not $errMsg.Contains('ant-TEST')) "claude error stderr must be redacted: $errMsg"
        $logText = [IO.File]::ReadAllText($script:LogPath)
        Assert ($logText.Contains('[REDACTED]') -and -not $logText.Contains('ant-TEST')) 'log file must also redact stderr'

        # --- 5. Argument escaping helper + path with spaces across all three ---
        $escaped = Format-McpProcessArguments -ArgList @('mcp', 'add-json', 'harness-transcripts', '{"command":"node","args":["C:\\x y\\"]}', '--scope', 'user')
        Assert ($escaped -ceq 'mcp add-json harness-transcripts "{\"command\":\"node\",\"args\":[\"C:\\x y\\\\\"]}" --scope user') "Format-McpProcessArguments escapes quotes and trailing slash: $escaped"

        # --- 6. codex add uses profile env & path with spaces & unregister ---
        $prevCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
        $prevElectron = [Environment]::GetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', 'C:\work\original-codex', 'Process')
            $prof = [pscustomobject]@{
                Id          = 'Work'
                CodexHome   = 'C:\work\codex-work'
                UserDataDir = 'C:\work\codex-work\electron'
            }
            $calls.Clear()
            Register-McpCodex -Profile $prof -Spec $specNode -Run $okRun
            Assert ($calls.Count -eq 1 -and $calls[0].Exe -ceq 'codex') 'codex add exe'
            Assert ($calls[0].CodexHome -ceq 'C:\work\codex-work') 'codex add uses profile CODEX_HOME'
            Assert ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process') -ceq 'C:\work\original-codex') 'CODEX_HOME restored after register'
            Assert ($calls[0].ArgList.Count -eq 6) 'codex add arg count'
            Assert ($calls[0].ArgList[0] -ceq 'mcp' -and $calls[0].ArgList[1] -ceq 'add' -and $calls[0].ArgList[2] -ceq 'harness-transcripts' -and $calls[0].ArgList[3] -ceq '--' -and $calls[0].ArgList[4] -ceq 'node' -and $calls[0].ArgList[5] -ceq $spacedPath) 'codex add argv and path with spaces'

            $calls.Clear()
            Unregister-McpCodex -Profile $prof -Run $okRun
            Assert ($calls.Count -eq 1 -and $calls[0].CodexHome -ceq 'C:\work\codex-work') 'codex remove uses profile CODEX_HOME'
            Assert (($calls[0].ArgList -join '|') -ceq 'mcp|remove|harness-transcripts') 'codex remove argv'
            Assert ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process') -ceq 'C:\work\original-codex') 'CODEX_HOME restored after unregister'

            $codexErrMsg = ''
            try { Register-McpCodex -Profile $prof -Spec $specNode -Run $errRun } catch { $codexErrMsg = $_.Exception.Message }
            Assert ($codexErrMsg.Contains('[REDACTED]') -and -not $codexErrMsg.Contains('ant-TEST')) 'codex error stderr redacted'
            Assert ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process') -ceq 'C:\work\original-codex') 'CODEX_HOME restored even on failure'
        } finally {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $prevCodexHome, 'Process')
            [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH', $prevElectron, 'Process')
        }
    } finally {
        $script:LogPath = $null
    }

    # --- 7. agy keeps other servers, missing file, UTF-8 no BOM ---
    $agyDir = Join-Path $temp 'agy'
    New-Item -ItemType Directory -Path $agyDir -Force | Out-Null
    $t1 = [datetime]::new(2026, 11, 25, 14, 5, 9)
    $t2 = [datetime]::new(2026, 11, 25, 14, 6, 10)

    # Missing config file -> creates new without backup and without UTF-8 BOM
    $missingCfg = Join-Path $agyDir 'new-sub\mcp_config.json'
    Register-McpAgy -Spec $specNode -ConfigPath $missingCfg -Now $t1
    Assert (Test-Path -LiteralPath $missingCfg -PathType Leaf) 'missing mcp_config.json created'
    $missingBaks = @(Get-ChildItem -LiteralPath (Split-Path -Parent $missingCfg) -Filter 'mcp_config.json.bak-*')
    Assert ($missingBaks.Count -eq 0) 'no backup when file did not exist'
    $rawBytes = [IO.File]::ReadAllBytes($missingCfg)
    Assert (-not ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)) 'UTF-8 without BOM'
    $parsedNew = [IO.File]::ReadAllText($missingCfg, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($parsedNew.mcpServers.'harness-transcripts'.args[0] -ceq $spacedPath) 'new config holds path with spaces'

    # Unregister on missing file is a no-op
    Unregister-McpAgy -ConfigPath (Join-Path $agyDir 'does-not-exist.json') -Now $t1

    # Existing config with two other servers and extra top-level key
    $cfgPath = Join-Path $agyDir 'mcp_config.json'
    $initialObj = [ordered]@{
        version    = 2
        mcpServers = [ordered]@{
            alpha = [ordered]@{
                command = 'python'
                args    = @('-m', 'alpha.server', '--port', '9000')
                env     = [ordered]@{ MODE = 'dev'; FLAG = '1' }
            }
            beta  = [ordered]@{
                command  = 'npx'
                args     = @('-y', '@example/beta')
                disabled = $true
            }
        }
    }
    $initialJson = $initialObj | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($cfgPath, $initialJson, $utf8NoBom)

    Register-McpAgy -Spec $specNode -ConfigPath $cfgPath -Now $t1
    $bak1 = Join-Path $agyDir 'mcp_config.json.bak-261125-140509'
    Assert (Test-Path -LiteralPath $bak1 -PathType Leaf) 'backup 1 created with -Now stamp'
    Assert (([IO.File]::ReadAllText($bak1, $utf8NoBom)) -ceq $initialJson) 'backup 1 equals original file'

    $afterReg = [IO.File]::ReadAllText($cfgPath, $utf8NoBom) | ConvertFrom-Json
    Assert ($afterReg.version -eq 2) 'top-level property preserved'
    Assert ($afterReg.mcpServers.alpha.command -ceq 'python') 'alpha command kept'
    Assert ((@($afterReg.mcpServers.alpha.args) -join '|') -ceq '-m|alpha.server|--port|9000') 'alpha args kept'
    Assert ($afterReg.mcpServers.alpha.env.MODE -ceq 'dev' -and $afterReg.mcpServers.alpha.env.FLAG -ceq '1') 'alpha env kept'
    Assert ($afterReg.mcpServers.beta.command -ceq 'npx' -and $afterReg.mcpServers.beta.disabled -eq $true) 'beta kept'
    Assert ($afterReg.mcpServers.'harness-transcripts'.command -ceq 'node') 'ht command set'
    Assert (@($afterReg.mcpServers.'harness-transcripts'.args)[0] -ceq $spacedPath) 'ht args holds path with spaces'

    Unregister-McpAgy -ConfigPath $cfgPath -Now $t2
    $bak2 = Join-Path $agyDir 'mcp_config.json.bak-261125-140610'
    Assert (Test-Path -LiteralPath $bak2 -PathType Leaf) 'backup 2 created with -Now stamp'
    $allBaks = @(Get-ChildItem -LiteralPath $agyDir -Filter 'mcp_config.json.bak-*')
    Assert ($allBaks.Count -eq 2) "one backup per write: $($allBaks.Count)"

    $afterUnreg = [IO.File]::ReadAllText($cfgPath, $utf8NoBom) | ConvertFrom-Json
    Assert ($null -eq $afterUnreg.mcpServers.PSObject.Properties['harness-transcripts']) 'ht removed'
    Assert ($afterUnreg.version -eq 2) 'top-level property preserved after unregister'
    Assert ($afterUnreg.mcpServers.alpha.command -ceq 'python' -and (@($afterUnreg.mcpServers.alpha.args) -join '|') -ceq '-m|alpha.server|--port|9000') 'alpha preserved after unregister'
    Assert ($afterUnreg.mcpServers.alpha.env.MODE -ceq 'dev' -and $afterUnreg.mcpServers.alpha.env.FLAG -ceq '1') 'alpha env preserved after unregister'
    Assert ($afterUnreg.mcpServers.beta.command -ceq 'npx' -and $afterUnreg.mcpServers.beta.disabled -eq $true) 'beta preserved after unregister'

    # --- 8. agy bad json ---
    $badDir = Join-Path $temp 'agy-bad'
    New-Item -ItemType Directory -Path $badDir -Force | Out-Null
    $badPath = Join-Path $badDir 'mcp_config.json'
    $badRaw = '{ not valid json'
    [IO.File]::WriteAllText($badPath, $badRaw, $utf8NoBom)

    $badRegMsg = ''
    try { Register-McpAgy -Spec $specNode -ConfigPath $badPath -Now $t1 } catch { $badRegMsg = $_.Exception.Message }
    Assert ($badRegMsg -like 'bad-json:*') "Register bad json must throw bad-json: $badRegMsg"

    $badUnregMsg = ''
    try { Unregister-McpAgy -ConfigPath $badPath -Now $t1 } catch { $badUnregMsg = $_.Exception.Message }
    Assert ($badUnregMsg -like 'bad-json:*') "Unregister bad json must throw bad-json: $badUnregMsg"

    Assert (([IO.File]::ReadAllText($badPath, $utf8NoBom)) -ceq $badRaw) 'bad json file untouched'
    Assert (@(Get-ChildItem -LiteralPath $badDir -Filter '*.bak-*').Count -eq 0) 'no backup created on bad json'

    # --- 9. states (Claude, Codex, Antigravity) ---
    $runReg = { param($Exe, $ArgList) @{ ExitCode = 0; StdOut = "args: [`"$spacedPath`"]"; StdErr = '' } }
    $runRegEscaped = { param($Exe, $ArgList) @{ ExitCode = 0; StdOut = ('"args": ["' + $spacedPath.Replace('\', '\\') + '"]'); StdErr = '' } }
    $runStale = { param($Exe, $ArgList) @{ ExitCode = 0; StdOut = 'args: ["C:\old\mcp\harness-transcripts\server.mjs"]'; StdErr = '' } }
    $runMiss = { param($Exe, $ArgList) @{ ExitCode = 1; StdOut = ''; StdErr = 'not found' } }
    $runNoCli = { param($Exe, $ArgList) throw 'The system cannot find the file specified (not found)' }

    Assert ((Get-McpClaudeState -ServerPath $spacedPath -Run $runReg) -ceq 'registered') 'claude state registered'
    Assert ((Get-McpClaudeState -ServerPath $spacedPath -Run $runRegEscaped) -ceq 'registered') 'claude state registered json escaped'
    Assert ((Get-McpClaudeState -ServerPath $spacedPath -Run $runStale) -ceq 'stale') 'claude state stale'
    Assert ((Get-McpClaudeState -ServerPath $spacedPath -Run $runMiss) -ceq 'missing') 'claude state missing'
    Assert ((Get-McpClaudeState -ServerPath $spacedPath -Run $runNoCli) -ceq 'no-cli') 'claude state no-cli'

    [Environment]::SetEnvironmentVariable('CODEX_HOME', 'C:\work\original-codex', 'Process')
    try {
        $seenHome = $null
        $codexRegRun = {
            param($Exe, $ArgList)
            $script:seenHomeForTest = $env:CODEX_HOME
            return @{ ExitCode = 0; StdOut = "args = [`"$spacedPath`"]"; StdErr = '' }
        }
        $profState = [pscustomobject]@{ Id = 'Work'; CodexHome = 'C:\work\codex-state'; UserDataDir = 'C:\work\codex-state\electron' }
        Assert ((Get-McpCodexState -Profile $profState -ServerPath $spacedPath -Run $codexRegRun) -ceq 'registered') 'codex state registered'
        Assert ($script:seenHomeForTest -ceq 'C:\work\codex-state') 'codex state checks inside profile CODEX_HOME'
        Assert ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process') -ceq 'C:\work\original-codex') 'CODEX_HOME restored after state'
        Assert ((Get-McpCodexState -Profile $profState -ServerPath $spacedPath -Run $runStale) -ceq 'stale') 'codex state stale'
        Assert ((Get-McpCodexState -Profile $profState -ServerPath $spacedPath -Run $runMiss) -ceq 'missing') 'codex state missing'
        Assert ((Get-McpCodexState -Profile $profState -ServerPath $spacedPath -Run $runNoCli) -ceq 'no-cli') 'codex state no-cli'
    } finally {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $prevCodexHome, 'Process')
    }

    Assert ((Get-McpAgyState -ConfigPath (Join-Path $agyDir 'nope.json') -ServerPath $spacedPath) -ceq 'missing') 'agy state missing file'
    Assert ((Get-McpAgyState -ConfigPath $cfgPath -ServerPath $spacedPath) -ceq 'missing') 'agy state missing key'
    Assert ((Get-McpAgyState -ConfigPath $badPath -ServerPath $spacedPath) -ceq 'bad-json') 'agy state bad-json'
    Register-McpAgy -Spec $specNode -ConfigPath $cfgPath -Now $t1
    Assert ((Get-McpAgyState -ConfigPath $cfgPath -ServerPath $spacedPath) -ceq 'registered') 'agy state registered'
    Assert ((Get-McpAgyState -ConfigPath $cfgPath -ServerPath 'C:\moved\mcp\harness-transcripts\server.mjs') -ceq 'stale') 'agy state stale'
} finally {
    Remove-TestTempDir $temp
}

Write-Output 'HarnessMcpRegister: OK'
