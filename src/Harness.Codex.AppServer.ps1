# Harness.Codex.AppServer.ps1 - minimal JSON-RPC-over-stdio client for `codex app-server` (spikes S2a, S8).
# PowerShell 5.1 specifics (spike S2a): the redirected stdin pipe corrupts the first message unless a blank line goes
# first, and stdin must be written through our own UTF-8 (no BOM) writer. Run codex.exe itself, never codex.cmd.
# The caller owns the CODEX_HOME it passes; this file never decides which home is safe to use.

function Start-CodexAppServer {
    param(
        [Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$CodexExe,
        [string]$Arguments = 'app-server'
    )
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $CodexExe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    [void]$psi.EnvironmentVariables.Remove('CODEX_ELECTRON_USER_DATA_PATH')
    $p = [Diagnostics.Process]::Start($psi)
    $writer = New-Object IO.StreamWriter($p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    $writer.WriteLine('')
    return [pscustomobject]@{
        Proc = $p; In = $writer; Id = 0; Notes = (New-Object Collections.ArrayList)
        Err = $p.StandardError.ReadToEndAsync(); PendingRead = $null
    }
}

# Reads the next stdout line, keeping an unfinished read across timeouts (a second read on the same stream would throw).
function Read-CodexLine {
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)][datetime]$Deadline)
    if ($null -eq $Server.PendingRead) { $Server.PendingRead = $Server.Proc.StandardOutput.ReadLineAsync() }
    $wait = [Math]::Max(1, [int]($Deadline - (Get-Date)).TotalMilliseconds)
    if (-not $Server.PendingRead.Wait($wait)) { return [pscustomobject]@{ Timeout = $true; Line = $null } }
    $line = $Server.PendingRead.Result
    $Server.PendingRead = $null
    return [pscustomobject]@{ Timeout = $false; Line = $line }
}

# Sends one request and returns its `result`. Replies with other ids are dropped; notifications go to $Server.Notes.
# -Notify sends a notification (no id, no reply). A JSON-RPC error, a timeout or a dead server throws.
function Invoke-CodexRpc {
    param(
        [Parameter(Mandatory)]$Server, [Parameter(Mandatory)][string]$Method, $Params = $null,
        [int]$TimeoutSec = 60, [switch]$Notify
    )
    $msg = [ordered]@{ method = $Method }
    if (-not $Notify) { $Server.Id++; $msg = [ordered]@{ id = $Server.Id; method = $Method } }
    if ($null -ne $Params) { $msg.params = $Params }
    $Server.In.WriteLine(($msg | ConvertTo-Json -Depth 20 -Compress))
    if ($Notify) { return }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $r = Read-CodexLine -Server $Server -Deadline $deadline
        if ($r.Timeout) { throw "codex app-server: $Method timed out after $TimeoutSec s" }
        if ($null -eq $r.Line) { throw "codex app-server closed its output during $Method. stderr: $(Get-CodexStderrTail $Server)" }
        $o = $null
        try { $o = $r.Line | ConvertFrom-Json } catch { continue }
        if ($o.PSObject.Properties['id'] -and $o.id -eq $Server.Id -and -not $o.PSObject.Properties['method']) {
            if ($o.PSObject.Properties['error']) { throw "codex app-server: $Method failed: $($o.error.message)" }
            return $o.result
        }
        if ($o.PSObject.Properties['method']) { [void]$Server.Notes.Add($o) }
    }
}

function Get-CodexStderrTail {
    param([Parameter(Mandatory)]$Server)
    if ($Server.Err.IsCompleted) { return (($Server.Err.Result -split "`n" | Select-Object -Last 5) -join ' | ') }
    return '(still running)'
}

# Returns the first notification with this method (already seen or arriving within the timeout), or $null.
function Wait-CodexNotification {
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)][string]$Method, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $hit = $Server.Notes | Where-Object { $_.method -eq $Method } | Select-Object -First 1
        if ($hit) { return $hit }
        if ((Get-Date) -ge $deadline) { return $null }
        $r = Read-CodexLine -Server $Server -Deadline $deadline
        if ($r.Timeout -or $null -eq $r.Line) { return $null }
        try { $o = $r.Line | ConvertFrom-Json } catch { continue }
        if ($o.PSObject.Properties['method']) { [void]$Server.Notes.Add($o) }
    }
}

# Ends the process this client started (closing stdin lets it exit; it is killed only if it does not).
function Stop-CodexAppServer {
    param([Parameter(Mandatory)]$Server)
    try { $Server.In.Close() } catch { Write-Verbose "stdin already closed: $($_.Exception.Message)" }
    if (-not $Server.Proc.WaitForExit(5000)) { $Server.Proc.Kill(); [void]$Server.Proc.WaitForExit(5000) }
}
