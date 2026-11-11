# Spike S8c: is a second `codex app-server` on the SAME CODEX_HOME as a running desktop app safe (locks, listing, registration)?
# Launches the spike profile's app (S1 script), runs a probe app-server against the same home, then closes ONLY the app it launched.
param(
  [Parameter(Mandatory)][ValidatePattern('^spike')][string]$Name,            # spike1
  [Parameter(Mandatory)][string]$SyntheticRel, [Parameter(Mandatory)][string]$SyntheticRoot,   # from S8-MakeSyntheticRollout.ps1
  [int]$WarmupSec = 25
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S8-CodexSpikeCommon.ps1')
$ch = Join-Path $env:USERPROFILE ".codex-profiles\$Name"
Assert-SpikeHome $ch
if (Test-SpikeAppRunning $Name) { throw "$Name app already running; close it first." }
$id = [regex]::Match($SyntheticRel, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$').Groups[1].Value
$launch = & (Join-Path $PSScriptRoot 'S1-CodexProfile.ps1') -Name $Name
$launch
$appPid = [int]((Get-Content (Join-Path $ch 'spike.pid')) | Select-Object -First 1)
try {
  Start-Sleep -Seconds $WarmupSec
  "app main process alive: $(-not (Get-Process -Id $appPid -ErrorAction SilentlyContinue) -eq $false)"
  $dst = Join-Path $ch ('sessions\' + $SyntheticRel)
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  Copy-Item -LiteralPath (Join-Path $SyntheticRoot $SyntheticRel) -Destination $dst -Force
  $all = @{ limit = 100; modelProviders = @(); sourceKinds = @('cli', 'vscode', 'exec', 'appServer', 'unknown') }
  $srv = Start-AppServer $ch
  try {
    $t0 = Get-Date
    $init = Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } }
    "initialize with app running: ok=$([bool]$init.result) in $([int]((Get-Date) - $t0).TotalMilliseconds) ms"
    Send-Notification $srv 'initialized'
    for ($i = 0; $i -lt 4; $i++) {
      $l = Invoke-Rpc $srv 'thread/list' $all
      $ids = @($l.result.data | ForEach-Object id)
      "list #$i : listed=$($ids.Count) hasSynthetic=$($ids -contains $id) error=$($l.error | ConvertTo-Json -Compress)"
      Start-Sleep -Seconds 4
    }
    $rd = Invoke-Rpc $srv 'thread/read' @{ threadId = $id; includeTurns = $false }
    "thread/read ok=$([bool]$rd.result) error=$($rd.error | ConvertTo-Json -Compress)"
  } finally { Stop-AppServer $srv }
  "probe stderr mentions lock: $([bool]($srv.Err.ToString() -match 'locked|busy|SQLITE_BUSY'))"
  "db has synthetic: $((Get-SpikeThreadIds $ch) -contains $id)"
} finally {
  # close only the process tree this script launched
  & taskkill.exe /T /F /PID $appPid | Out-Null
  Start-Sleep -Seconds 2
  "spike app still running: $(Test-SpikeAppRunning $Name)"
}
