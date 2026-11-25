$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $root 'src\Harness.Core.ps1')
. (Join-Path $root 'src\Harness.Claude.ps1')
. (Join-Path $root 'src\Harness.Codex.Profiles.ps1')
. (Join-Path $root 'src\Harness.Codex.Chats.ps1')
. (Join-Path $root 'src\Harness.Antigravity.Chats.ps1')
. (Join-Path $root 'src\Harness.Mirror.ps1')
. (Join-Path $root 'src\Harness.McpRegister.ps1')
. (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.Main.ps1')) -Names @('Get-MainUiStyle'))
. (Import-TestFunctions -Files @((Join-Path $root 'src\Ui.MainChats.ps1')) -Names @('New-MainButton'))
. (Join-Path $root 'src\Ui.Mirror.ps1')

$fixture = New-TestTempDir
try {
    $script:SwitcherHome = Join-Path $fixture 'switcher'

    # ---- Get-MirrorStatusText ----
    Assert ((Get-MirrorStatusText -Pin $null) -eq '') 'null pin -> empty status'
    $t1405 = ([datetime]::new(2026, 11, 25, 14, 5, 0, [DateTimeKind]::Local)).ToUniversalTime()
    $t1410 = ([datetime]::new(2026, 11, 25, 14, 10, 0, [DateTimeKind]::Local)).ToUniversalTime()
    $t1412 = ([datetime]::new(2026, 11, 25, 14, 12, 0, [DateTimeKind]::Local)).ToUniversalTime()

    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'ok'; updatedAt = $t1405 })) -eq 'Live, updated 14:05') 'live updated status'
    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'missing' })) -eq 'Source missing') 'missing status'
    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'error'; error = 'Sharing violation' })) -eq 'Sharing violation') 'mirror error status'
    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'ok'; updatedAt = $t1405; codexSync = $true; codexSyncStatus = 'imported'; codexSyncAt = $t1410 })) -eq 'Synced to Codex 14:10') 'codex imported status'
    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'ok'; updatedAt = $t1405; codexSync = $true; codexSyncStatus = 'exists'; codexSyncAt = $t1412 })) -eq 'Synced to Codex 14:12') 'codex exists status'
    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'ok'; updatedAt = $t1405; codexSync = $true; codexSyncStatus = 'skipped' })) -eq 'Codex skipped: close the thread in Codex or stop chatting there, then retry') 'codex skipped status'
    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'ok'; updatedAt = $t1405; codexSync = $true; codexSyncStatus = 'not-detected' })) -eq 'Codex did not detect the session (folder gone?)') 'codex not-detected status'
    Assert ((Get-MirrorStatusText -Pin ([pscustomobject]@{ state = 'ok'; updatedAt = $t1405; codexSync = $true; codexSyncStatus = 'error'; codexSyncError = 'App-server failed' })) -eq 'App-server failed') 'codex error status'

    # ---- Get-ReflectTargets ----
    $targets = @(
        [pscustomobject]@{ Harness = 'claude'; Id = 'Default'; Name = 'Default'; IsDefault = $true },
        [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default'; IsDefault = $true },
        [pscustomobject]@{ Harness = 'codex'; Id = 'Work'; Name = 'Work'; IsDefault = $false },
        [pscustomobject]@{ Harness = 'antigravity'; Id = 'app'; Name = 'Antigravity'; Kind = 'app'; IsDefault = $true }
    )
    $refTargets = @(Get-ReflectTargets -SourceHarness 'Claude' -Targets $targets)
    Assert ($refTargets.Count -eq 3 -and -not ($refTargets | Where-Object { $_.Harness -eq 'claude' })) 'reflect targets exclude source harness'

    # ---- Test-CodexSyncDue (59s / 60s quiet and 4:59 / 5:00 error backoff) ----
    $claudeSyncPin = [pscustomobject]@{ harness = 'claude'; id = 'c1'; codexSync = $true; state = 'ok' }
    $now = [datetime]::new(2026, 11, 25, 15, 0, 0, [DateTimeKind]::Utc)
    Assert (-not (Test-CodexSyncDue -Pin $claudeSyncPin -LastEventAt ($now.AddSeconds(-59)) -LastErrorAt $null -Now $now)) '59s quiet -> false'
    Assert (Test-CodexSyncDue -Pin $claudeSyncPin -LastEventAt ($now.AddSeconds(-60)) -LastErrorAt $null -Now $now) '60s quiet -> true'
    Assert (-not (Test-CodexSyncDue -Pin $claudeSyncPin -LastEventAt ($now.AddSeconds(-65)) -LastErrorAt ($now.AddSeconds(-299)) -Now $now)) '4:59 after error -> false'
    Assert (Test-CodexSyncDue -Pin $claudeSyncPin -LastEventAt ($now.AddSeconds(-65)) -LastErrorAt ($now.AddSeconds(-300)) -Now $now) '5:00 after error -> true'
    Assert (-not (Test-CodexSyncDue -Pin $claudeSyncPin -LastEventAt ($now.AddSeconds(-120)) -LastErrorAt $null -Now $now -Busy $true)) 'busy -> false'
    Assert (-not (Test-CodexSyncDue -Pin ([pscustomobject]@{ harness = 'codex'; id = 'x'; codexSync = $true; state = 'ok' }) -LastEventAt ($now.AddSeconds(-120)) -Now $now)) 'non-claude -> false'
    Assert (-not (Test-CodexSyncDue -Pin ([pscustomobject]@{ harness = 'claude'; id = 'c1'; codexSync = $false; state = 'ok' }) -LastEventAt ($now.AddSeconds(-120)) -Now $now)) 'codexSync disabled -> false'
    Assert (-not (Test-CodexSyncDue -Pin ([pscustomobject]@{ harness = 'claude'; id = 'c1'; codexSync = $true; state = 'missing' }) -LastEventAt ($now.AddSeconds(-120)) -Now $now)) 'missing source -> false'

    # ---- Test-McpCodexPathSafe, Get-McpDialogRows, stale re-register & cmd metachar rejection ----
    Assert (Test-McpCodexPathSafe -Path 'C:\my repo\mcp\harness-transcripts\server.mjs') 'spaces and backslash are safe'
    foreach ($badCh in '&', '%', '^', '!', '"', '<', '>', '|') {
        Assert (-not (Test-McpCodexPathSafe -Path ("C:\a${badCh}b\server.mjs"))) "unsafe char '$badCh' rejected"
    }

    $nodeOk = @{ Ok = $true; Version = '22.15.0'; Path = 'node'; Reason = '' }
    $nodeBad = @{ Ok = $false; Version = '22.14.0'; Path = 'node'; Reason = 'Node.js 22.14.0 is too old; >= 22.15 is required.' }
    $safeServer = 'C:\work\demo\mcp\harness-transcripts\server.mjs'
    $codexDefault = [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default'; IsDefault = $true; CodexHome = (Join-Path $fixture 'codex-def') }
    $states = @(
        @{ Key = 'claude'; Harness = 'claude'; Name = 'Claude Code'; State = 'stale'; TargetDesc = '~/.claude.json (via claude mcp)'; Profile = $null },
        @{ Key = 'codex:Default'; Harness = 'codex'; Name = 'Codex / Default'; State = 'stale'; TargetDesc = 'Default config.toml (via codex mcp)'; Profile = $codexDefault },
        @{ Key = 'antigravity'; Harness = 'antigravity'; Name = 'Antigravity'; State = 'missing'; TargetDesc = 'mcp_config.json'; Profile = $null },
        @{ Key = 'codex:nocli'; Harness = 'codex'; Name = 'Codex / NoCli'; State = 'no-cli'; TargetDesc = 'config.toml'; Profile = $codexDefault },
        @{ Key = 'antigravity:bad'; Harness = 'antigravity'; Name = 'Antigravity'; State = 'bad-json'; TargetDesc = 'mcp_config.json'; Profile = $null }
    )
    $rows = @(Get-McpDialogRows -States $states -NodeCheck $nodeOk -ServerPath $safeServer)
    Assert ($rows.Count -eq 5) 'five dialog rows'
    Assert ($rows[0].State -eq 'stale' -and $rows[0].CanRegister -and $rows[0].CanRemove -and $rows[0].RegisterAction -eq 're-register') 'stale claude row -> re-register'
    Assert ($rows[0].Note -eq (Get-McpRegisterNote -Target 'claude')) 'row carries Get-McpRegisterNote'
    Assert (-not $rows[3].CanRegister -and -not $rows[3].CanRemove -and $rows[3].DisabledReason) 'no-cli disabled'
    Assert (-not $rows[4].CanRegister -and -not $rows[4].CanRemove -and $rows[4].DisabledReason) 'bad-json disabled'

    $ampServer = 'C:\a&b\mcp\harness-transcripts\server.mjs'
    $ampRows = @(Get-McpDialogRows -States $states -NodeCheck $nodeOk -ServerPath $ampServer)
    Assert ($ampRows[0].CanRegister) 'claude allows &'
    Assert (-not $ampRows[1].CanRegister -and $ampRows[1].DisabledReason -like '*cmd*') 'codex row disabled when server path has &'
    Assert ($ampRows[2].CanRegister) 'antigravity allows &'

    $oldNodeRows = @(Get-McpDialogRows -States $states -NodeCheck $nodeBad -ServerPath $safeServer)
    Assert (@($oldNodeRows | Where-Object { $_.CanRegister }).Count -eq 0 -and $oldNodeRows[0].DisabledReason -like '*22.14.0*') 'old node disables register with reason'
    $noServerRows = @(Get-McpDialogRows -States $states -NodeCheck $nodeOk -ServerPath $null)
    Assert (@($noServerRows | Where-Object { $_.CanRegister }).Count -eq 0 -and $noServerRows[0].DisabledReason) 'missing server.mjs disables register'

    # Stale register runs Unregister before Register (verified via -Run double)
    $cliCalls = New-Object Collections.Generic.List[string]
    $fakeRun = {
        param([string]$Exe, [string[]]$ArgList)
        $cliCalls.Add(($Exe + ' ' + ($ArgList -join ' ')))
        return @{ ExitCode = 0; StdOut = 'ok'; StdErr = '' }
    }
    $spec = Get-McpServerSpec -ServerPath $safeServer -NodePath 'node'
    Invoke-McpTargetAction -Row $rows[0] -Action 'register' -Spec $spec -Run $fakeRun
    Assert ($cliCalls.Count -eq 2 -and $cliCalls[0] -like 'claude mcp remove*' -and $cliCalls[1] -like 'claude mcp add-json*') "stale claude unregisters then registers: $($cliCalls -join ' | ')"

    $cliCalls.Clear()
    Invoke-McpTargetAction -Row $rows[1] -Action 'register' -Spec $spec -Run $fakeRun
    Assert ($cliCalls.Count -eq 2 -and $cliCalls[0] -like 'codex mcp remove*' -and $cliCalls[1] -like 'codex mcp add*') "stale codex unregisters then registers: $($cliCalls -join ' | ')"

    # Unsafe Codex path rejected even if Invoke-McpTargetAction called directly
    $badCodexRow = $rows[1].PSObject.Copy()
    $badCodexRow.CanRegister = $true
    Assert-Throws { Invoke-McpTargetAction -Row $badCodexRow -Action 'register' -Spec (Get-McpServerSpec -ServerPath $ampServer -NodePath 'node') -Run $fakeRun } 'direct unsafe codex path throws'

    # ---- Invoke-MirrorReflect ----
    $pinForReflect = [pscustomobject]@{ harness = 'claude'; id = 'c1'; title = 'Demo'; cwd = $fixture; mirrorPath = (Join-Path $fixture 'm.md') }
    $launched = New-Object Collections.Generic.List[string]
    $clipped = New-Object Collections.Generic.List[string]
    $links = New-Object Collections.Generic.List[string]
    $rDef = Invoke-MirrorReflect -Pin $pinForReflect -Target $targets[1] `
        -StartProcess { param($u) $links.Add($u) } `
        -SetClipboard { param($t) $clipped.Add($t) } `
        -Launch { param($p) $launched.Add($p.Id) }
    Assert ($rDef.Mode -eq 'deeplink' -and $links.Count -eq 1 -and $links[0] -like 'codex://threads/new?prompt=*') 'codex default uses deeplink'

    $rWork = Invoke-MirrorReflect -Pin $pinForReflect -Target $targets[2] `
        -StartProcess { param($u) $links.Add($u) } `
        -SetClipboard { param($t) $clipped.Add($t) } `
        -Launch { param($p) $launched.Add($p.Id) }
    Assert ($rWork.Mode -eq 'clipboard' -and $clipped.Count -eq 1 -and $launched[0] -eq 'Work') 'codex extra profile uses clipboard + launch'

    $agyIde = [pscustomobject]@{ Harness = 'antigravity'; Id = 'ide'; Name = 'Antigravity IDE'; Kind = 'ide'; IsDefault = $false }
    $rIde = Invoke-MirrorReflect -Pin $pinForReflect -Target $agyIde `
        -StartProcess { param($u) $links.Add($u) } `
        -SetClipboard { param($t) $clipped.Add($t) } `
        -Launch { param($p) $launched.Add($p.Id) }
    Assert ($rIde.Mode -eq 'clipboard' -and $rIde.Prompt -like "*open that folder first*") 'antigravity IDE adds folder note'

    # ---- Background timeout helper (never hangs UI) ----
    $stepRes = Invoke-McpStepWithTimeout -Script { param($a) Start-Sleep -Seconds 5; 'late' } -Arguments @{} -FunctionNames @() -TimeoutMs 250
    Assert ($stepRes.TimedOut -eq $true) 'timeout helper returns TimedOut on slow call'

    # ---- Hidden WinForms + temp watcher start/stop (no ShowDialog, no Application.Run) ----
    $srcFile = Join-Path $fixture 'claude-src.jsonl'
    [IO.File]::WriteAllText($srcFile, '{"type":"user","timestamp":"t1","message":{"role":"user","content":"Hello"}}' + "`n")
    $mDir = Get-MirrorDir
    $tempPin = ConvertTo-MirrorPinObject -Raw @{
        harness = 'claude'; id = 'c-temp'; profileId = 'Default'; title = 'Temp'; cwd = $fixture
        sourcePath = $srcFile; mirrorPath = (Join-Path $mDir 'claude-c-temp.md')
    }
    Write-MirrorPins -Pins @($tempPin) -Dir $mDir
    $hiddenForm = New-Object System.Windows.Forms.Form
    [void]$hiddenForm.Handle
    try {
        Start-MirrorService -Form $hiddenForm -Dir $mDir
        $svc = Get-MirrorServiceState
        Assert ($svc.Started -and $svc.Watchers.Count -eq 1 -and $null -ne $svc.Timer) 'mirror service starts watcher on temp dir and timer'
        Assert (Test-Path -LiteralPath $tempPin.mirrorPath -PathType Leaf) 'initial mirror md exported on startup'
    } finally {
        Stop-MirrorService
        $hiddenForm.Dispose()
    }
    Assert (-not (Get-MirrorServiceState).Started -and (Get-MirrorServiceState).Watchers.Count -eq 0) 'Stop-MirrorService disposes watcher and timer'

    # Hidden MCP bridge form builds without showing
    $mcpForm = New-McpBridgeForm -Owner $null -ProbeRunner { param($t) @() }
    try {
        Assert ($mcpForm.Form -is [System.Windows.Forms.Form] -and $mcpForm.List -is [System.Windows.Forms.ListView]) 'MCP bridge form constructed'
        Assert ($mcpForm.RegisterButton -is [System.Windows.Forms.Button] -and $mcpForm.RemoveButton -is [System.Windows.Forms.Button]) 'MCP bridge buttons exist'
    } finally {
        $mcpForm.Form.Dispose()
    }

    # ---- tick skips codex profiles when nothing needs sync (and caches 30s) ----
    $script:profCalls = 0
    $tickForm = New-Object System.Windows.Forms.Form
    [void]$tickForm.Handle
    try {
        $syncPin = ConvertTo-MirrorPinObject -Raw @{
            harness = 'claude'; id = 'c-sync'; profileId = 'Default'; title = 'Sync'; cwd = $fixture
            sourcePath = $srcFile; mirrorPath = (Join-Path $mDir 'claude-c-sync.md'); codexSync = $true
        }
        Write-MirrorPins -Pins @($syncPin) -Dir $mDir
        Start-MirrorService -Form $tickForm -Dir $mDir -GetCodexProfiles { $script:profCalls++; @() }
        $svc = Get-MirrorServiceState
        $rtSync = Get-MirrorRuntime -Svc $svc -Key 'claude:c-sync'
        Assert ($rtSync.needsCodexSync -eq $true -and $null -ne $rtSync.lastEventAt) 'startup Export-MirrorAllPins sets needsCodexSync and lastEventAt'
        $rtSync.needsCodexSync = $false
        $script:profCalls = 0
        for ($i = 0; $i -lt 5; $i++) { Invoke-MirrorServiceTick }
        Assert ($script:profCalls -eq 0) "tick queried codex profiles $($script:profCalls) times with nothing needing sync"
        $rtSync.needsCodexSync = $true
        $rtSync.lastEventAt = [datetime]::UtcNow
        Invoke-MirrorServiceTick
        Invoke-MirrorServiceTick
        Assert ($script:profCalls -eq 1) "codex profiles should be cached for 30s, got $($script:profCalls)"
    } finally {
        Stop-MirrorService
        $tickForm.Dispose()
    }

    # ---- write during a running sync re-arms ----
    $svc = Get-MirrorServiceState
    $rtArm = Get-MirrorRuntime -Svc $svc -Key 'claude:c-arm'
    $psOk = [powershell]::Create(); [void]$psOk.AddScript('@{ Status = "imported"; ThreadId = "t1" }')
    $hOk = $psOk.BeginInvoke(); [void]$hOk.AsyncWaitHandle.WaitOne(5000)
    $svc.CodexJobs['Default'] = [pscustomobject]@{ PinKey = 'claude:c-arm'; ProfileId = 'Default'; PowerShell = $psOk; Runspace = $null; Handle = $hOk }
    $rtArm.needsCodexSync = $true
    Complete-MirrorCodexJobs -Svc $svc
    Assert ($rtArm.codexSyncStatus -eq 'imported' -and $rtArm.needsCodexSync -eq $true) 'write during running sync keeps needsCodexSync armed'

    $psErr = [powershell]::Create(); [void]$psErr.AddScript('throw "sync boom"')
    $hErr = $psErr.BeginInvoke(); [void]$hErr.AsyncWaitHandle.WaitOne(5000)
    $svc.CodexJobs['Default'] = [pscustomobject]@{ PinKey = 'claude:c-arm'; ProfileId = 'Default'; PowerShell = $psErr; Runspace = $null; Handle = $hErr }
    $rtArm.needsCodexSync = $false
    Complete-MirrorCodexJobs -Svc $svc
    Assert ($rtArm.codexSyncStatus -eq 'error' -and $null -ne $rtArm.lastErrorAt -and $rtArm.needsCodexSync -eq $true) 'sync error re-arms needsCodexSync for backoff retry'

    # ---- background function lists are closed ----
    $allDefs = @{}
    foreach ($sf in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1')) {
        $sAst = [Management.Automation.Language.Parser]::ParseFile($sf.FullName, [ref]$null, [ref]$null)
        foreach ($d in $sAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $allDefs[$d.Name] = $d
        }
    }
    # sync job only uses -SourceJsonl, never the -BundlePath branch of Import-CodexExternalClaude
    $syncAllow = @('Read-HarnessBundle', 'Resolve-CwdRef')
    foreach ($specList in @(@{ Name = 'Mcp'; Fn = 'Get-McpBackgroundFunctionNames'; Allow = @() }, @{ Name = 'Sync'; Fn = 'Get-MirrorSyncFunctionNames'; Allow = $syncAllow })) {
        $fnList = @(& $specList.Fn)
        $fnSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $fnList) { [void]$fnSet.Add($n) }
        foreach ($n in $fnList) {
            if (-not $allDefs.ContainsKey($n)) { continue }
            foreach ($cmd in $allDefs[$n].FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] }, $true)) {
                $cname = $cmd.GetCommandName()
                if ($cname -and $allDefs.ContainsKey($cname) -and ($specList.Allow -notcontains $cname)) {
                    Assert ($fnSet.Contains($cname)) "$($specList.Name) background list missing '$cname' called by '$n'"
                }
            }
        }
    }

    Write-Output 'HarnessUiMirror: OK'
} finally {
    Stop-MirrorService
    Remove-TestTempDir $fixture
}
