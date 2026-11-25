# Ui.Mirror.ps1 - live mirror service, chat menu/status, Reflect to, Sync to Codex, and MCP bridge dialog.
# Uses Harness.Mirror.ps1, Harness.McpRegister.ps1, Harness.Codex.ExternalImport.ps1, and Ui.Main.ps1. ASCII only.

function Get-MirrorField {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Format-MirrorTimeHHmm {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $(if ($Value.Kind -eq [DateTimeKind]::Utc) { $Value.ToLocalTime() } else { $Value }).ToString('HH:mm') }
    $dto = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dto)) { return $dto.ToLocalTime().ToString('HH:mm') }
    return ''
}

function Get-MirrorStatusText {
    param($Pin)
    if ($null -eq $Pin) { return '' }
    $state = [string](Get-MirrorField $Pin 'state' 'ok')
    if ($state -eq 'missing') { return 'Source missing' }
    if ($state -eq 'error') { $e = [string](Get-MirrorField $Pin 'error' ''); return $(if ($e) { $e } else { 'Mirror error' }) }
    $syncOn = [bool](Get-MirrorField $Pin 'codexSync' $false)
    $syncStatus = [string](Get-MirrorField $Pin 'codexSyncStatus' '')
    if ($syncOn -and $syncStatus) {
        switch ($syncStatus) {
            { $_ -in 'imported', 'exists' } { $t = Format-MirrorTimeHHmm (Get-MirrorField $Pin 'codexSyncAt'); return $(if ($t) { "Synced to Codex $t" } else { 'Synced to Codex' }) }
            'skipped'      { return 'Codex skipped: close the thread in Codex or stop chatting there, then retry' }
            'not-detected' { return 'Codex did not detect the session (folder gone?)' }
            'error'        { $se = [string](Get-MirrorField $Pin 'codexSyncError' ''); return $(if ($se) { $se } else { 'Codex sync error' }) }
        }
    }
    $u = Format-MirrorTimeHHmm (Get-MirrorField $Pin 'updatedAt')
    return $(if ($u) { "Live, updated $u" } else { 'Live' })
}

function Get-ReflectTargets {
    param([Parameter(Mandatory)][string]$SourceHarness, [AllowNull()][AllowEmptyCollection()][array]$Targets = @())
    return @($Targets | Where-Object { $_ -and ([string]$_.Harness -ine $SourceHarness) })
}

function Test-CodexSyncDue {
    param($Pin, $LastEventAt = $null, $LastErrorAt = $null, [datetime]$Now = [datetime]::UtcNow, [int]$QuietSec = 60, [int]$ErrorBackoffSec = 300, [bool]$Busy = $false)
    if ($Busy -or $null -eq $Pin -or $null -eq $LastEventAt) { return $false }
    if ([string](Get-MirrorField $Pin 'harness' '') -ine 'claude') { return $false }
    if (-not [bool](Get-MirrorField $Pin 'codexSync' $false)) { return $false }
    if ([string](Get-MirrorField $Pin 'state' 'ok') -ne 'ok') { return $false }
    $utcNow = $Now.ToUniversalTime()
    $ev = $(if ($LastEventAt -is [datetime]) { $LastEventAt.ToUniversalTime() } else { ([datetime]$LastEventAt).ToUniversalTime() })
    if (($utcNow - $ev).TotalSeconds -lt $QuietSec) { return $false }
    if ($null -ne $LastErrorAt) {
        $er = $(if ($LastErrorAt -is [datetime]) { $LastErrorAt.ToUniversalTime() } else { ([datetime]$LastErrorAt).ToUniversalTime() })
        if (($utcNow - $er).TotalSeconds -lt $ErrorBackoffSec) { return $false }
    }
    return $true
}

function Test-McpCodexPathSafe {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path -notmatch '[&%\^!"<>|]')
}

function Get-McpDialogRows {
    param([AllowNull()][AllowEmptyCollection()][array]$States = @(), $NodeCheck = $null, [AllowNull()][string]$ServerPath = '')
    $nodeOk = [bool]($NodeCheck -and (Get-MirrorField $NodeCheck 'Ok' $false))
    $nodeReason = $(if ($NodeCheck) { [string](Get-MirrorField $NodeCheck 'Reason' '') } else { '' })
    $hasServer = -not [string]::IsNullOrWhiteSpace($ServerPath)
    $codexSafe = $(if ($hasServer) { Test-McpCodexPathSafe -Path $ServerPath } else { $false })
    $rows = New-Object Collections.Generic.List[object]
    foreach ($s in @($States)) {
        if ($null -eq $s) { continue }
        $harness = ([string](Get-MirrorField $s 'Harness' '')).ToLowerInvariant()
        $state = [string](Get-MirrorField $s 'State' 'missing')
        $targetDesc = [string](Get-MirrorField $s 'TargetDesc' '')
        $reason = [string](Get-MirrorField $s 'Reason' '')
        $canReg = $true; $canRem = ($state -in 'registered', 'stale'); $disabled = ''
        if ($state -eq 'no-cli') { $canReg = $false; $canRem = $false; $disabled = "$harness CLI was not found on PATH." }
        elseif ($state -eq 'bad-json') { $canReg = $false; $canRem = $false; $disabled = 'mcp_config.json has invalid JSON.' }
        elseif (-not $hasServer) { $canReg = $false; $disabled = 'mcp\harness-transcripts\server.mjs was not found.' }
        elseif (-not $nodeOk) { $canReg = $false; $disabled = $(if ($nodeReason) { $nodeReason } else { 'Node.js (>= 22.15) is required.' }) }
        elseif ($harness -eq 'codex' -and -not $codexSafe) { $canReg = $false; $disabled = 'Server path contains unsafe cmd.exe characters (& % ^ ! " < > |).' }
        $regAction = $(if ($state -eq 'stale') { 're-register' } else { 'register' })
        $changes = $(if ($state -eq 'stale') { "$targetDesc (remove stale, then add)" } else { $targetDesc })
        $note = $(if ($harness -in 'claude', 'codex', 'antigravity') { Get-McpRegisterNote -Target $harness } else { '' })
        if (-not $reason -and $disabled) { $reason = $disabled }
        $rows.Add([pscustomobject]@{
            Key = [string](Get-MirrorField $s 'Key' ''); Harness = $harness; Name = [string](Get-MirrorField $s 'Name' '')
            State = $state; TargetDesc = $targetDesc; Profile = (Get-MirrorField $s 'Profile'); Changes = $changes; Note = $note
            Checked = ($canReg -and ($state -in 'missing', 'stale')); CanRegister = $canReg; CanRemove = $canRem
            RegisterAction = $regAction; DisabledReason = $disabled; Reason = $reason
        })
    }
    return $rows.ToArray()
}

function Invoke-McpTargetAction {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][ValidateSet('register', 'remove')][string]$Action,
          [Parameter(Mandatory)][System.Collections.IDictionary]$Spec, [scriptblock]$Run, [string]$ConfigPath, [datetime]$Now = (Get-Date))
    $runArg = $(if ($PSBoundParameters.ContainsKey('Run') -and $Run) { @{ Run = $Run } } else { @{} })
    $cfgArg = $(if ($PSBoundParameters.ContainsKey('ConfigPath') -and $ConfigPath) { @{ ConfigPath = $ConfigPath } } else { @{} })
    $srvArg = $(if ($Spec['args'] -and @($Spec['args']).Count) { [string]$Spec['args'][0] } else { '' })
    if ($Action -eq 'register') {
        if ($Row.Harness -eq 'codex' -and -not (Test-McpCodexPathSafe -Path $srvArg)) { throw 'Server path contains unsafe cmd.exe characters (& % ^ ! " < > |).' }
        switch ($Row.Harness) {
            'claude'      { if ($Row.State -eq 'stale') { Unregister-McpClaude @runArg }; Register-McpClaude -Spec $Spec @runArg }
            'codex'       { if ($Row.State -eq 'stale') { Unregister-McpCodex -Profile $Row.Profile @runArg }; Register-McpCodex -Profile $Row.Profile -Spec $Spec @runArg }
            'antigravity' { Register-McpAgy -Spec $Spec -Now $Now @cfgArg }
        }
    } else {
        switch ($Row.Harness) {
            'claude'      { Unregister-McpClaude @runArg }
            'codex'       { Unregister-McpCodex -Profile $Row.Profile @runArg }
            'antigravity' { Unregister-McpAgy -Now $Now @cfgArg }
        }
    }
}

function Invoke-MirrorReflect {
    param([Parameter(Mandatory)]$Pin, [Parameter(Mandatory)]$Target,
          [scriptblock]$StartProcess = { param($u) Start-Process $u },
          [scriptblock]$SetClipboard = { param($t) [System.Windows.Forms.Clipboard]::SetText($t) }, [scriptblock]$Launch)
    $prompt = New-MirrorHandoffPrompt -Pin $Pin
    $th = ([string]$Target.Harness).ToLowerInvariant()
    if ($th -eq 'codex' -and [bool](Get-MirrorField $Target 'IsDefault' $false)) {
        $cwd = [string](Get-MirrorField $Pin 'cwd' '')
        $url = New-CodexDeepLink -Prompt $prompt -Path $(if ($cwd -and (Test-Path -LiteralPath $cwd -PathType Container)) { $cwd } else { '' })
        if ($url.Length -le 2000) { & $StartProcess $url; return [pscustomobject]@{ Mode = 'deeplink'; Prompt = $prompt; Url = $url } }
    }
    if ($th -eq 'antigravity' -and ([string](Get-MirrorField $Target 'Kind' '')) -eq 'ide') {
        $cwd = [string](Get-MirrorField $Pin 'cwd' '')
        if ($cwd -and $cwd -match '\A(?:[A-Za-z]:\\|\\\\[^\\])' -and $cwd -notmatch '[\x00-\x1F\x7F]') {
            $prompt = '{0} The work was done in the folder {1}; open that folder first.' -f $prompt, $cwd
        }
    }
    & $SetClipboard $prompt
    if ($Launch) { & $Launch $Target } else { $h = Get-Harness -Name $th; if ($h -and $h.Adapter['Launch']) { [void](& $h.Adapter.Launch $Target) } }
    return [pscustomobject]@{ Mode = 'clipboard'; Prompt = $prompt; Url = $null }
}

# ---- mirror service, watchers, and background Codex sync --------------------------------------------------------

function Get-MirrorServiceState {
    if (-not $script:MirrorService) {
        $script:MirrorService = @{ Started = $false; Form = $null; Dir = $null; Pins = @(); Runtime = @{}; Queue = (New-MirrorQueue)
            Watchers = @(); Timer = $null; SyncLock = (New-Object object); ErrorFlag = $false; CodexJobs = @{}; Exporting = $false
            CodexProfiles = @(); CodexProfilesAt = $null; GetCodexProfiles = $null }
    }
    return $script:MirrorService
}

function Get-MirrorKey { param([string]$Harness, [string]$Id) return ('{0}:{1}' -f $Harness, $Id).ToLowerInvariant() }

function Get-MirrorRuntime {
    param([hashtable]$Svc, [string]$Key)
    if (-not $Svc.Runtime.ContainsKey($Key)) {
        $Svc.Runtime[$Key] = @{ updatedAt = $null; error = ''; lastEventAt = $null; codexSyncStatus = ''; codexSyncAt = $null; codexSyncError = ''; lastErrorAt = $null; needsCodexSync = $false }
    }
    return $Svc.Runtime[$Key]
}

function Get-MirrorChatStatusText {
    param([Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)]$Chat)
    $svc = Get-MirrorServiceState; $id = [string](Get-MirrorField $Chat 'ChatId' '')
    if (-not $id) { return '' }
    $k = Get-MirrorKey -Harness $Harness -Id $id
    $pin = $svc.Pins | Where-Object { (Get-MirrorKey $_.harness $_.id) -eq $k } | Select-Object -First 1
    if (-not $pin) { return '' }
    $rt = Get-MirrorRuntime -Svc $svc -Key $k
    return (Get-MirrorStatusText -Pin ([pscustomobject]@{ state = $pin.state; updatedAt = $rt.updatedAt; error = $rt.error; codexSync = $pin.codexSync
        codexSyncStatus = $rt.codexSyncStatus; codexSyncAt = $rt.codexSyncAt; codexSyncError = $rt.codexSyncError }))
}

function New-MirrorRunspace {
    param([string[]]$FunctionNames = @())
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in @($FunctionNames)) {
        $cmd = Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
        if ($cmd) { $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($cmd.Name, $cmd.Definition))) }
    }
    foreach ($vn in 'SwitcherHome', 'LogPath') {
        $v = Get-Variable -Name $vn -Scope Script -ErrorAction SilentlyContinue
        if ($v -and $null -ne $v.Value) { $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry($vn, $v.Value, $null))) }
    }
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open(); return $rs
}

function Get-MirrorSyncFunctionNames {
    return @('Get-SecretPatterns', 'Invoke-SecretScan', 'Protect-TranscriptText', 'Get-FileSha256Hex', 'Get-BytesSha256Hex', 'Get-FirstValue',
        'Read-ChatJson', 'ConvertTo-ClaudeProjectSlug', 'Get-ClaudeHomePath', 'Find-ClaudeProjectDir', 'ConvertFrom-CodexPath', 'Get-CodexNormalPath',
        'Get-CodexExternalImportRecord', 'Select-CodexDetectedSession', 'Resolve-CodexExePath', 'Find-CodexInstall', 'Start-CodexAppServer',
        'Read-CodexLine', 'Invoke-CodexRpc', 'Get-CodexStderrTail', 'Wait-CodexNotification', 'Stop-CodexAppServer', 'Import-CodexExternalClaude')
}

function Start-MirrorCodexSyncJob {
    param([Parameter(Mandatory)]$Svc, [Parameter(Mandatory)]$Pin, [Parameter(Mandatory)]$CodexProfile)
    $pk = [string]$CodexProfile.Id; $rs = New-MirrorRunspace -FunctionNames (Get-MirrorSyncFunctionNames)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript('param($Src, $Prof) Import-CodexExternalClaude -SourceJsonl $Src -Profile $Prof').AddArgument([string]$Pin.sourcePath).AddArgument($CodexProfile)
    $Svc.CodexJobs[$pk] = [pscustomobject]@{ PinKey = (Get-MirrorKey $Pin.harness $Pin.id); ProfileId = $pk; PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
}

function Complete-MirrorCodexJobs {
    param([Parameter(Mandatory)]$Svc)
    foreach ($pk in @($Svc.CodexJobs.Keys)) {
        $job = $Svc.CodexJobs[$pk]; if (-not $job.Handle.IsCompleted) { continue }
        $Svc.CodexJobs.Remove($pk); $rt = Get-MirrorRuntime -Svc $Svc -Key $job.PinKey
        try {
            $res = @($job.PowerShell.EndInvoke($job.Handle)) | Select-Object -Last 1
            $rt.codexSyncStatus = [string](Get-MirrorField $res 'Status' 'error')
            $rt.codexSyncAt = [datetime]::UtcNow; $rt.codexSyncError = ''
        } catch {
            $rt.codexSyncStatus = 'error'; $rt.codexSyncError = $_.Exception.Message; $rt.lastErrorAt = [datetime]::UtcNow; $rt.needsCodexSync = $true
        } finally { try { if ($job.PowerShell) { $job.PowerShell.Dispose() } } catch { }; try { if ($job.Runspace) { $job.Runspace.Dispose() } } catch { } }
    }
}

function Stop-MirrorWatchers { param($Svc) foreach ($w in @($Svc.Watchers)) { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch { } }; $Svc.Watchers = @() }

function Update-MirrorWatchers {
    param([string]$Dir)
    $svc = Get-MirrorServiceState
    if ($Dir) { $svc.Dir = $Dir } elseif (-not $svc.Dir) { $svc.Dir = Get-MirrorDir }
    Stop-MirrorWatchers -Svc $svc; $svc.Pins = @(Read-MirrorPins -Dir $svc.Dir)
    $list = New-Object Collections.Generic.List[object]
    foreach ($pin in $svc.Pins) {
        if (-not $pin.sourcePath) { continue }
        $parent = Split-Path -Parent $pin.sourcePath; $leaf = Split-Path -Leaf $pin.sourcePath
        if (-not $parent -or -not $leaf -or -not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        $w = New-Object IO.FileSystemWatcher($parent, $leaf); $w.NotifyFilter = [IO.NotifyFilters]'LastWrite, Size'; $w.InternalBufferSize = 65536
        if ($svc.Form) { $w.SynchronizingObject = $svc.Form }
        $key = Get-MirrorKey $pin.harness $pin.id
        $onChange = {
            $s = Get-MirrorServiceState; [Threading.Monitor]::Enter($s.SyncLock)
            try { Add-MirrorEvent -Queue $s.Queue -Key $key } finally { [Threading.Monitor]::Exit($s.SyncLock) }
            (Get-MirrorRuntime -Svc $s -Key $key).lastEventAt = [datetime]::UtcNow
        }.GetNewClosure()
        $w.add_Changed($onChange); $w.add_Created($onChange); $w.add_Renamed($onChange); $w.add_Error({ (Get-MirrorServiceState).ErrorFlag = $true })
        $w.EnableRaisingEvents = $true; $list.Add($w)
    }
    $svc.Watchers = $list.ToArray()
}

function Export-MirrorAllPins {
    param([Parameter(Mandatory)]$Svc)
    $changed = $false
    foreach ($pin in $Svc.Pins) {
        $k = Get-MirrorKey $pin.harness $pin.id; $rt = Get-MirrorRuntime -Svc $Svc -Key $k
        try {
            $r = Export-MirrorPin -Pin $pin
            if ($r -eq 'written') { $nowUtc = [datetime]::UtcNow; $rt.updatedAt = $nowUtc; $rt.error = ''; $changed = $true; if ($pin.codexSync) { $rt.needsCodexSync = $true; $rt.lastEventAt = $nowUtc } }
            elseif ($r -eq 'missing') { $changed = $true }
        } catch { $pin.state = 'error'; $rt.error = $_.Exception.Message; $changed = $true }
    }
    if ($changed -and $Svc.Dir) { Write-MirrorPins -Pins $Svc.Pins -Dir $Svc.Dir }
}

function Invoke-MirrorServiceTick {
    $svc = Get-MirrorServiceState
    if (-not $svc.Started -or $svc.Exporting) { return }
    $svc.Exporting = $true
    try {
        Complete-MirrorCodexJobs -Svc $svc
        if ($svc.ErrorFlag) { $svc.ErrorFlag = $false; Export-MirrorAllPins -Svc $svc }
        $due = @(); [Threading.Monitor]::Enter($svc.SyncLock)
        try { $due = @(Invoke-MirrorDue -Queue $svc.Queue -Pins $svc.Pins) } finally { [Threading.Monitor]::Exit($svc.SyncLock) }
        $dirty = $false
        foreach ($d in $due) {
            $rt = Get-MirrorRuntime -Svc $svc -Key ([string]$d.Key).ToLowerInvariant()
            if ($d.Result -eq 'written') { $rt.updatedAt = [datetime]::UtcNow; $rt.error = ''; $rt.needsCodexSync = $true; $dirty = $true }
            elseif ($d.Result -eq 'missing') { $dirty = $true }
            elseif ($d.Result -eq 'error') { $rt.error = [string]$d.Error; $dirty = $true }
        }
        if ($dirty -and $svc.Dir) { Write-MirrorPins -Pins $svc.Pins -Dir $svc.Dir }
        $needSync = @($svc.Pins | Where-Object { (Get-MirrorRuntime -Svc $svc -Key (Get-MirrorKey $_.harness $_.id)).needsCodexSync })
        if ($needSync.Count -gt 0) {
            $nowUtc = [datetime]::UtcNow
            if ($null -eq $svc.CodexProfilesAt -or ($nowUtc - $svc.CodexProfilesAt).TotalSeconds -ge 30) {
                $getter = $(if ($svc.GetCodexProfiles) { $svc.GetCodexProfiles } elseif (Get-Command Get-CodexProfiles -ErrorAction SilentlyContinue) { { Get-CodexProfiles } } else { $null })
                $svc.CodexProfiles = $(if ($getter) { @(& $getter) } else { @() }); $svc.CodexProfilesAt = $nowUtc
            }
            foreach ($pin in $needSync) {
                $rt = Get-MirrorRuntime -Svc $svc -Key (Get-MirrorKey $pin.harness $pin.id)
                $cp = $svc.CodexProfiles | Where-Object { $_.Id -eq $pin.codexProfileId } | Select-Object -First 1
                if (-not $cp) { $cp = $svc.CodexProfiles | Where-Object { $_.IsDefault } | Select-Object -First 1 }
                if ($cp -and (Test-CodexSyncDue -Pin $pin -LastEventAt $rt.lastEventAt -LastErrorAt $rt.lastErrorAt -Busy ($svc.CodexJobs.ContainsKey([string]$cp.Id)))) {
                    Start-MirrorCodexSyncJob -Svc $svc -Pin $pin -CodexProfile $cp; $rt.needsCodexSync = $false
                }
            }
        }
        Update-MirrorPanelColumns
    } finally { $svc.Exporting = $false }
}

function Start-MirrorService {
    param([Parameter(Mandatory)]$Form, [string]$Dir = (Get-MirrorDir), [int]$IntervalMs = 500, [scriptblock]$GetCodexProfiles = $null)
    Stop-MirrorService; $svc = Get-MirrorServiceState
    $svc.Form = $Form; $svc.Dir = $Dir; $svc.Queue = New-MirrorQueue; $svc.Started = $true
    $svc.GetCodexProfiles = $GetCodexProfiles; $svc.CodexProfiles = @(); $svc.CodexProfilesAt = $null
    Update-MirrorWatchers -Dir $Dir; Export-MirrorAllPins -Svc $svc
    $t = New-Object System.Windows.Forms.Timer; $t.Interval = $IntervalMs
    $t.Add_Tick({ try { Invoke-MirrorServiceTick } catch { Write-HarnessLog "Live mirror tick failed: $($_.Exception.Message)" } })
    $t.Start(); $svc.Timer = $t; $Form.Add_FormClosed({ Stop-MirrorService })
}

function Stop-MirrorService {
    $svc = Get-MirrorServiceState; $svc.Started = $false
    if ($svc.Timer) { try { $svc.Timer.Stop(); $svc.Timer.Dispose() } catch { }; $svc.Timer = $null }
    Stop-MirrorWatchers -Svc $svc
    foreach ($pk in @($svc.CodexJobs.Keys)) {
        $j = $svc.CodexJobs[$pk]; $svc.CodexJobs.Remove($pk)
        try { $j.PowerShell.Stop() } catch { }; try { $j.PowerShell.Dispose() } catch { }; try { $j.Runspace.Dispose() } catch { }
    }
}

# ---- chat list columns & context menu ---------------------------------------------------------------------------

function Update-MirrorPanelColumns {
    if (-not (Get-Command Get-MainState -ErrorAction SilentlyContinue)) { return }
    foreach ($panel in @((Get-MainState).Panels.Values)) {
        if (-not $panel -or -not $panel.List -or $panel.List.IsDisposed) { continue }
        foreach ($it in $panel.List.Items) { if ($it.Tag -and $it.SubItems.Count -ge 5) { $txt = Get-MirrorChatStatusText -Harness $panel.Harness.Name -Chat $it.Tag.Chat; if ($it.SubItems[4].Text -cne $txt) { $it.SubItems[4].Text = $txt } } }
    }
}

function Show-CodexProfilePicker {
    param([Parameter(Mandatory)][array]$Profiles, $Owner = $null)
    $s = Get-MainUiStyle; $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Sync to Codex profile'; $dlg.Size = New-Object System.Drawing.Size(360, 170)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.BackColor = $s.Bg
    $cb = New-Object System.Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'; $cb.Location = New-Object System.Drawing.Point(16, 20); $cb.Size = New-Object System.Drawing.Size(310, 24)
    $defIdx = 0; for ($i = 0; $i -lt $Profiles.Count; $i++) { [void]$cb.Items.Add([string]$Profiles[$i].Name); if ($Profiles[$i].IsDefault) { $defIdx = $i } }
    if ($cb.Items.Count) { $cb.SelectedIndex = $defIdx }
    $ok = New-MainButton -Text 'OK' -X 130 -Width 90; $ok.Location = New-Object System.Drawing.Point(130, 76); $ok.DialogResult = 'OK'
    $cancel = New-MainButton -Text 'Cancel' -X 236 -Width 90; $cancel.Location = New-Object System.Drawing.Point(236, 76); $cancel.DialogResult = 'Cancel'
    foreach ($c in $cb, $ok, $cancel) { $dlg.Controls.Add($c) }; $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    try { if ($dlg.ShowDialog($Owner) -ne 'OK' -or $cb.SelectedIndex -lt 0) { return $null }; return $Profiles[$cb.SelectedIndex] } finally { $dlg.Dispose() }
}

function Add-MirrorChatContextMenu {
    param([Parameter(Mandatory)]$Ctx)
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miPin = New-Object System.Windows.Forms.ToolStripMenuItem('Pin for live mirror')
    $miReflect = New-Object System.Windows.Forms.ToolStripMenuItem(('Reflect to ' + [char]0x25B8))
    $miCodex = New-Object System.Windows.Forms.ToolStripMenuItem('Sync to Codex'); $miCodex.CheckOnClick = $false
    $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem('Open mirror file')
    [void]$menu.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($miPin, $miReflect, $miCodex, $miOpen))
    $Ctx.List.ContextMenuStrip = $menu
    $getPin = { param($chat) $k = Get-MirrorKey $Ctx.Harness.Name $chat.ChatId; (Get-MirrorServiceState).Pins | Where-Object { (Get-MirrorKey $_.harness $_.id) -eq $k } | Select-Object -First 1 }.GetNewClosure()

    $menu.Add_Opening({
        param($sender, $e)
        $v = Get-ChatPanelSelection -Ctx $Ctx; if (-not $v) { $e.Cancel = $true; return }
        $pin = & $getPin $v.Chat
        $miPin.Text = $(if ($pin) { 'Unpin' } else { 'Pin for live mirror' })
        $miPin.Enabled = ($null -ne $pin) -or ($null -ne (Resolve-MirrorSource -Harness $Ctx.Harness.Name -Chat $v.Chat))
        $miCodex.Visible = ($Ctx.Harness.Name -eq 'claude' -and $null -ne $pin); $miCodex.Checked = [bool]($pin -and $pin.codexSync)
        $miOpen.Enabled = [bool]($pin -and $pin.mirrorPath -and (Test-Path -LiteralPath $pin.mirrorPath -PathType Leaf))
        $miReflect.DropDownItems.Clear(); $miReflect.Enabled = [bool]$pin
        if ($pin) {
            foreach ($t in @(Get-ReflectTargets -SourceHarness $Ctx.Harness.Name -Targets @(Get-HarnessTransferTargets))) {
                $item = New-Object System.Windows.Forms.ToolStripMenuItem(('{0} / {1}' -f $t.Harness, $t.Name)); $item.Tag = @{ Pin = $pin; Target = $t }
                $item.Add_Click({
                    $tag = $this.Tag; try {
                        if ((Export-MirrorPin -Pin $tag.Pin) -eq 'written') { (Get-MirrorRuntime -Svc (Get-MirrorServiceState) -Key (Get-MirrorKey $tag.Pin.harness $tag.Pin.id)).updatedAt = [datetime]::UtcNow; Update-MirrorPanelColumns }
                        $r = Invoke-MirrorReflect -Pin $tag.Pin -Target $tag.Target
                        Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'message'; Text = "Reflected via $($r.Mode) to $($tag.Target.Harness) / $($tag.Target.Name)." }
                    } catch { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'error'; Text = $_.Exception.Message } }
                }.GetNewClosure())
                [void]$miReflect.DropDownItems.Add($item)
            }
        }
    }.GetNewClosure())
    $miPin.Add_Click({
        $v = Get-ChatPanelSelection -Ctx $Ctx; if (-not $v) { return }
        $svc = Get-MirrorServiceState; $dir = $(if ($svc.Dir) { $svc.Dir } else { Get-MirrorDir }); $k = Get-MirrorKey $Ctx.Harness.Name $v.Chat.ChatId
        try {
            if (& $getPin $v.Chat) { Remove-MirrorPin -Harness $Ctx.Harness.Name -Id $v.Chat.ChatId -Dir $dir }
            else { $np = Add-MirrorPin -Harness $Ctx.Harness.Name -Chat $v.Chat -Dir $dir; [void](Export-MirrorPin -Pin $np); (Get-MirrorRuntime -Svc $svc -Key $k).updatedAt = [datetime]::UtcNow; Write-MirrorPins -Pins (@(Read-MirrorPins -Dir $dir) | ForEach-Object { if ((Get-MirrorKey $_.harness $_.id) -eq $k) { $np } else { $_ } }) -Dir $dir }
            Update-MirrorWatchers -Dir $dir; Update-MirrorPanelColumns
        } catch { Show-ChatPanelResult -Ctx $Ctx -Result @{ Kind = 'error'; Text = $_.Exception.Message } }
    }.GetNewClosure())
    $miCodex.Add_Click({
        $v = Get-ChatPanelSelection -Ctx $Ctx; if (-not $v) { return }
        $svc = Get-MirrorServiceState; $dir = $(if ($svc.Dir) { $svc.Dir } else { Get-MirrorDir }); $pins = @(Read-MirrorPins -Dir $dir); $k = Get-MirrorKey $Ctx.Harness.Name $v.Chat.ChatId
        $pin = $pins | Where-Object { (Get-MirrorKey $_.harness $_.id) -eq $k } | Select-Object -First 1; if (-not $pin) { return }
        if (-not $pin.codexSync) {
            $profs = @(Get-CodexProfiles); $picked = $(if ($profs.Count -gt 1) { Show-CodexProfilePicker -Profiles $profs -Owner (Get-MainState).Form } else { $profs | Select-Object -First 1 })
            if (-not $picked) { return }; $pin.codexSync = $true; $pin.codexProfileId = [string]$picked.Id
            $rt = Get-MirrorRuntime -Svc $svc -Key $k; $rt.needsCodexSync = $true; if (-not $rt.lastEventAt) { $rt.lastEventAt = [datetime]::UtcNow }
        } else { $pin.codexSync = $false; $pin.codexProfileId = $null }
        Write-MirrorPins -Pins $pins -Dir $dir; Update-MirrorWatchers -Dir $dir; Update-MirrorPanelColumns
    }.GetNewClosure())
    $miOpen.Add_Click({ $v = Get-ChatPanelSelection -Ctx $Ctx; if ($v) { $p = & $getPin $v.Chat; if ($p -and $p.mirrorPath -and (Test-Path -LiteralPath $p.mirrorPath -PathType Leaf)) { Start-Process -FilePath $p.mirrorPath } } }.GetNewClosure())
}

# ---- MCP bridge dialog (background runspace + 60s timeout) ------------------------------------------------------

function Get-McpBackgroundFunctionNames {
    return @('Protect-TranscriptText', 'Get-SecretPatterns', 'Invoke-SecretScan', 'Write-HarnessLog', 'Get-McpServerName', 'Get-McpServerPath',
        'Get-McpServerSpec', 'Get-McpRegisterNote', 'Protect-McpErrorText', 'Write-McpLog', 'Format-McpProcessArguments', 'Invoke-McpDefaultRun',
        'Test-McpNode', 'ConvertTo-McpClaudeJson', 'Test-McpOutputMatchesPath', 'Resolve-McpCliState', 'Register-McpClaude', 'Unregister-McpClaude',
        'Get-McpClaudeState', 'Invoke-WithCodexEnv', 'Get-CodexProfiles', 'Get-CodexProfilesRoot', 'Get-CodexRunningMap', 'Get-CodexLabels',
        'Find-CodexInstall', 'Register-McpCodex', 'Unregister-McpCodex', 'Get-McpCodexState', 'Get-McpAgyDefaultConfigPath', 'Read-McpAgyConfig',
        'Write-McpJsonAtomic', 'Register-McpAgy', 'Unregister-McpAgy', 'Get-McpAgyState', 'Test-McpCodexPathSafe', 'Get-McpDialogRows',
        'Invoke-McpTargetAction', 'Get-MirrorField', 'New-MirrorRunspace', 'Invoke-McpStepWithTimeout', 'Get-McpBackgroundFunctionNames')
}

function Invoke-McpStepWithTimeout {
    param([Parameter(Mandatory)][scriptblock]$Script, [hashtable]$Arguments = @{}, [string[]]$FunctionNames = @(), [int]$TimeoutMs = 60000)
    $rs = New-MirrorRunspace -FunctionNames $FunctionNames; $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString()).AddArgument($Arguments)
    $handle = $ps.BeginInvoke()
    if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        try { $ps.Stop() } catch { }
        try { $ps.Dispose() } catch { }; try { $rs.Dispose() } catch { }
        return @{ TimedOut = $true; Result = $null; Error = 'Timed out' }
    }
    try { return @{ TimedOut = $false; Result = (@($ps.EndInvoke($handle)) | Select-Object -Last 1); Error = $null } }
    catch {
        if ($_.Exception.Message -like 'timeout:*') { return @{ TimedOut = $true; Result = $null; Error = 'Timed out' } }
        return @{ TimedOut = $false; Result = $null; Error = $_.Exception.Message }
    }
    finally { try { $ps.Dispose() } catch { }; try { $rs.Dispose() } catch { } }
}

function Start-McpDialogJob {
    param([Parameter(Mandatory)][ValidateSet('probe', 'register', 'remove')][string]$Mode, [array]$Targets = @(), $Spec = $null, [string]$ServerPath = '', [int]$TimeoutMs = 60000)
    $rs = New-MirrorRunspace -FunctionNames (Get-McpBackgroundFunctionNames); $ps = [powershell]::Create(); $ps.Runspace = $rs
    $script = {
        param($Mode, $Targets, $Spec, $ServerPath, $TimeoutMs)
        $fn = Get-McpBackgroundFunctionNames
        if ($Mode -eq 'probe') {
            $nc = Test-McpNode; $states = New-Object Collections.Generic.List[object]
            $cr = Invoke-McpStepWithTimeout -Script { param($a) Get-McpClaudeState -ServerPath $a.S } -Arguments @{ S = $ServerPath } -FunctionNames $fn -TimeoutMs $TimeoutMs
            $states.Add(@{ Key = 'claude'; Harness = 'claude'; Name = 'Claude Code'; TargetDesc = '~/.claude.json (via claude mcp)'; Profile = $null
                State = $(if ($cr.TimedOut) { 'timeout' } elseif ($cr.Error) { 'no-cli' } else { [string]$cr.Result }); Reason = $(if ($cr.TimedOut) { 'Timed out' } elseif ($cr.Error) { $cr.Error } else { '' }) })
            foreach ($p in @(Get-CodexProfiles)) {
                $xr = Invoke-McpStepWithTimeout -Script { param($a) Get-McpCodexState -Profile $a.P -ServerPath $a.S } -Arguments @{ P = $p; S = $ServerPath } -FunctionNames $fn -TimeoutMs $TimeoutMs
                $states.Add(@{ Key = "codex:$($p.Id)"; Harness = 'codex'; Name = "Codex / $($p.Name)"; TargetDesc = "$($p.Name) config.toml (via codex mcp)"; Profile = $p
                    State = $(if ($xr.TimedOut) { 'timeout' } elseif ($xr.Error) { 'no-cli' } else { [string]$xr.Result }); Reason = $(if ($xr.TimedOut) { 'Timed out' } elseif ($xr.Error) { $xr.Error } else { '' }) })
            }
            $states.Add(@{ Key = 'antigravity'; Harness = 'antigravity'; Name = 'Antigravity'; TargetDesc = (Get-McpAgyDefaultConfigPath); Profile = $null; State = (Get-McpAgyState -ServerPath $ServerPath); Reason = '' })
            return @{ NodeCheck = $nc; Rows = @(Get-McpDialogRows -States $states.ToArray() -NodeCheck $nc -ServerPath $ServerPath) }
        }
        $outcomes = @{}
        foreach ($row in @($Targets)) {
            $st = Invoke-McpStepWithTimeout -Script { param($a) Invoke-McpTargetAction -Row $a.R -Action $a.A -Spec $a.S } -Arguments @{ R = $row; A = $Mode; S = $Spec } -FunctionNames $fn -TimeoutMs $TimeoutMs
            $outcomes[$row.Key] = $(if ($st.TimedOut) { @{ State = 'timeout'; Reason = 'Timed out' } } elseif ($st.Error) { @{ State = 'error'; Reason = $st.Error } } else { @{ State = 'ok'; Reason = '' } })
        }
        return @{ Outcomes = $outcomes }
    }
    [void]$ps.AddScript($script.ToString()).AddArgument($Mode).AddArgument($Targets).AddArgument($Spec).AddArgument($ServerPath).AddArgument($TimeoutMs)
    return [pscustomobject]@{ Mode = $Mode; PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
}

function New-McpBridgeForm {
    param($Owner = $null, [scriptblock]$ProbeRunner = $null)
    $s = Get-MainUiStyle; $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'MCP bridge (harness-transcripts)'; $dlg.Size = New-Object System.Drawing.Size(780, 420)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.BackColor = $s.Bg
    $list = New-Object System.Windows.Forms.ListView; $list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true
    $list.Location = New-Object System.Drawing.Point(12, 12); $list.Size = New-Object System.Drawing.Size(740, 270)
    foreach ($c in @(@('Target', 140), @('State', 90), @('Changes', 210), @('Note', 160), @('Reason', 130))) { [void]$list.Columns.Add($c[0], $c[1]) }
    $status = New-Object System.Windows.Forms.Label; $status.Location = New-Object System.Drawing.Point(12, 290); $status.Size = New-Object System.Drawing.Size(740, 24); $status.ForeColor = $s.Muted; $status.Text = 'Working...'
    $btnReg = New-MainButton -Text 'Register selected' -X 12 -Width 140; $btnReg.Location = New-Object System.Drawing.Point(12, 326); $btnReg.Enabled = $false
    $btnRem = New-MainButton -Text 'Remove selected' -X 162 -Width 140; $btnRem.Location = New-Object System.Drawing.Point(162, 326); $btnRem.Enabled = $false
    $btnClose = New-MainButton -Text 'Close' -X 642 -Width 110; $btnClose.Location = New-Object System.Drawing.Point(642, 326); $btnClose.DialogResult = 'Cancel'
    foreach ($c in $list, $status, $btnReg, $btnRem, $btnClose) { $dlg.Controls.Add($c) }; $dlg.CancelButton = $btnClose
    $ctx = @{ Form = $dlg; List = $list; Status = $status; RegisterButton = $btnReg; RemoveButton = $btnRem; Job = $null; Rows = @(); Spec = $null; ServerPath = (Get-McpServerPath); Timer = $null; LastOutcomes = $null }
    $fill = {
        param($rows, $outcomes)
        $list.BeginUpdate(); $list.Items.Clear()
        foreach ($r in @($rows)) {
            if ($outcomes -and $outcomes.ContainsKey($r.Key) -and $outcomes[$r.Key].State -eq 'timeout') { $r.State = 'timeout'; $r.Reason = 'Timed out' }
            elseif ($outcomes -and $outcomes.ContainsKey($r.Key) -and $outcomes[$r.Key].Reason) { $r.Reason = $outcomes[$r.Key].Reason }
            $it = New-Object System.Windows.Forms.ListViewItem([string]$r.Name); $it.Tag = $r; $it.Checked = [bool]$r.Checked
            foreach ($v in $r.State, $r.Changes, $r.Note, $r.Reason) { [void]$it.SubItems.Add([string]$v) }; [void]$list.Items.Add($it)
        }
        $list.EndUpdate(); $btnReg.Enabled = [bool](@($rows | Where-Object { $_.CanRegister }).Count); $btnRem.Enabled = [bool](@($rows | Where-Object { $_.CanRemove }).Count)
    }.GetNewClosure()
    $startProbe = {
        if ($ProbeRunner) { $ctx.Rows = @(& $ProbeRunner $ctx.ServerPath); & $fill $ctx.Rows $ctx.LastOutcomes; $status.Text = 'Ready.'; return }
        $status.Text = 'Working...'; $btnReg.Enabled = $false; $btnRem.Enabled = $false
        $ctx.Job = Start-McpDialogJob -Mode 'probe' -ServerPath ([string]$ctx.ServerPath)
    }.GetNewClosure()
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 200; $ctx.Timer = $timer
    $timer.Add_Tick({
        if (-not $ctx.Job -or -not $ctx.Job.Handle.IsCompleted) { return }; $j = $ctx.Job; $ctx.Job = $null
        try {
            $res = @($j.PowerShell.EndInvoke($j.Handle)) | Select-Object -Last 1
            if ($j.Mode -eq 'probe') {
                $ctx.Rows = @($res.Rows); if ($res.NodeCheck -and $res.NodeCheck.Ok -and $ctx.ServerPath) { $ctx.Spec = Get-McpServerSpec -ServerPath $ctx.ServerPath -NodePath 'node' }
                $out = $ctx.LastOutcomes; $ctx.LastOutcomes = $null; & $fill $ctx.Rows $out; $status.Text = 'Ready.'
            } else { $ctx.LastOutcomes = $res.Outcomes; & $startProbe }
        } catch { $status.Text = $_.Exception.Message } finally { try { $j.PowerShell.Dispose() } catch { }; try { $j.Runspace.Dispose() } catch { } }
    }.GetNewClosure())
    $runAction = {
        param($mode)
        $picked = @($list.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Tag } | Where-Object { if ($mode -eq 'register') { $_.CanRegister } else { $_.CanRemove } })
        if (-not $picked.Count -or ($mode -eq 'register' -and -not $ctx.Spec)) { return }
        $specArg = $(if ($ctx.Spec) { $ctx.Spec } else { @{ command = 'node'; args = @() } })
        $ctx.LastOutcomes = $null; $status.Text = 'Working...'; $btnReg.Enabled = $false; $btnRem.Enabled = $false
        $ctx.Job = Start-McpDialogJob -Mode $mode -Targets $picked -Spec $specArg -ServerPath ([string]$ctx.ServerPath)
    }.GetNewClosure()
    $btnReg.Add_Click({ & $runAction 'register' }.GetNewClosure()); $btnRem.Add_Click({ & $runAction 'remove' }.GetNewClosure())
    $dlg.Add_Shown({ $timer.Start(); & $startProbe }.GetNewClosure())
    $dlg.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); if ($ctx.Job) { try { $ctx.Job.PowerShell.Stop(); $ctx.Job.PowerShell.Dispose(); $ctx.Job.Runspace.Dispose() } catch { } } }.GetNewClosure())
    return [pscustomobject]$ctx
}

function Show-McpBridgeDialog { param($Owner = $null) $f = New-McpBridgeForm -Owner $Owner; try { [void]$f.Form.ShowDialog($Owner) } finally { $f.Form.Dispose() } }
