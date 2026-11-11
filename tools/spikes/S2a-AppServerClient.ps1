# Spike helper (S2a, S3): minimal JSON-RPC-over-stdio client for `codex app-server`.
# Safety: refuses to run unless CODEX_HOME is a spike home under %TEMP%\harness-spike (never ~\.codex), and never copies auth.json.
function Get-SpikeCodexExe {
  Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
}

function Assert-SpikeHome([string]$Home_) {
  $full = [IO.Path]::GetFullPath($Home_)
  $root = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'harness-spike'))
  if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "CODEX_HOME not under $root : $full" }
  if ($full.StartsWith((Join-Path $env:USERPROFILE '.codex'), [StringComparison]::OrdinalIgnoreCase)) { throw 'refusing real ~\.codex' }
  if (Test-Path (Join-Path $full 'auth.json')) { throw 'spike home must not contain auth.json' }
}

function Start-AppServer([string]$CodexHome) {
  Assert-SpikeHome $CodexHome
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Get-SpikeCodexExe
  $psi.Arguments = 'app-server'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome
  $psi.EnvironmentVariables.Remove('CODEX_ELECTRON_USER_DATA_PATH')
  $p = [Diagnostics.Process]::Start($psi)
  $err = New-Object Text.StringBuilder
  Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action { [void]$Event.MessageData.AppendLine($EventArgs.Data) } -MessageData $err | Out-Null
  $p.BeginErrorReadLine()
  # Own writer: the default stdin encoding may prepend a UTF-8 BOM, which the server rejects as invalid JSON.
  $w = New-Object IO.StreamWriter($p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
  $w.AutoFlush = $true
  # Finding: on PS 5.1 the first bytes on the redirected stdin pipe corrupt the first message (server logs
  # "Failed to deserialize JSONRPCMessage ... column 1" and never answers it). A sacrificial blank line absorbs that.
  $w.WriteLine('')
  [pscustomobject]@{ Proc = $p; Err = $err; Id = 0; In = $w; Notes = (New-Object Collections.ArrayList) }
}

# Reads messages until a notification with the given method shows up (or timeout). Returns it or $null.
function Wait-Notification($srv, [string]$Method, [int]$TimeoutSec = 60) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $hit = $srv.Notes | Where-Object { $_.method -eq $Method } | Select-Object -First 1
    if ($hit) { return $hit }
    $task = $srv.Proc.StandardOutput.ReadLineAsync()
    if (-not $task.Wait([Math]::Max(1, [int](($deadline - (Get-Date)).TotalMilliseconds)))) { return $null }
    if ($null -eq $task.Result) { return $null }
    [void]$srv.Notes.Add(($task.Result | ConvertFrom-Json))
  }
  $null
}

function Send-Notification($srv, [string]$Method) {
  $srv.In.WriteLine((@{ method = $Method } | ConvertTo-Json -Compress))
}

# Sends one request and reads lines until the matching response id (notifications are collected in .Notes).
function Invoke-Rpc($srv, [string]$Method, $Params, [int]$TimeoutSec = 60) {
  $srv.Id++
  $msg = [ordered]@{ jsonrpc = '2.0'; id = $srv.Id; method = $Method }
  if ($null -ne $Params) { $msg.params = $Params }
  $srv.In.WriteLine(($msg | ConvertTo-Json -Depth 20 -Compress))
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $task = $srv.Proc.StandardOutput.ReadLineAsync()
    if (-not $task.Wait([Math]::Max(1, [int](($deadline - (Get-Date)).TotalMilliseconds)))) { break }
    $line = $task.Result
    if ($null -eq $line) { return [pscustomobject]@{ error = 'EOF'; stderr = $srv.Err.ToString() } }
    $o = $line | ConvertFrom-Json
    if ($o.PSObject.Properties.Name -contains 'id' -and $o.id -eq $srv.Id) { return $o }
    [void]$srv.Notes.Add($o)   # notifications and server requests, kept for Wait-Notification
  }
  [pscustomobject]@{ error = 'timeout'; stderr = $srv.Err.ToString() }
}

function Stop-AppServer($srv) {
  try { $srv.In.Close() } catch {}
  if (-not $srv.Proc.WaitForExit(5000)) { $srv.Proc.Kill() }
}
