# Spike S8a: register a dropped rollout as a thread in a home that ALREADY has state_5.sqlite, without calling the model.
# Only on a spike profile (spike1) or a scratch home. Closes the profile's app first (refuses if it runs).
param(
  [Parameter(Mandatory)][string]$CodexHome,    # e.g. %USERPROFILE%\.codex-profiles\spike1
  [Parameter(Mandatory)][string]$Rollout,      # relative to ~\.codex\sessions of Default (read-only source), e.g. 2026\10\28\rollout-...jsonl.zst
  [string]$SourceRoot = (Join-Path $env:USERPROFILE '.codex\sessions'),   # read-only source of the rollout
  [switch]$SkipResume                          # only drop the file and list (control run)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S8-CodexSpikeCommon.ps1')
Assert-SpikeHome $CodexHome
$name = Split-Path $CodexHome -Leaf
if (Test-SpikeAppRunning $name) { throw "App for $name is running; close it first." }
if ($Rollout -notmatch '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl(\.zst)?$') { throw 'cannot read thread id from rollout name' }
$id = $Matches[1]
if ((Get-SpikeThreadIds $CodexHome) -contains $id) { throw "thread $id is already registered in $CodexHome; pick another rollout" }
$dst = Join-Path $CodexHome ('sessions\' + $Rollout)
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceRoot $Rollout) -Destination $dst -Force
$all = @{ limit = 100; modelProviders = @(); sourceKinds = @('cli', 'vscode', 'exec', 'appServer', 'unknown') }
$exe = Get-SpikeCodexExe

function Show-State([string]$When, $srv) {
  $ids = Get-SpikeThreadIds $CodexHome
  $list = if ($srv) { @((Invoke-Rpc $srv 'thread/list' $all).result.data | ForEach-Object id) } else { @() }
  "[$When] db has thread: $($ids -contains $id) (rows=$($ids.Count)); thread/list has thread: $($list -contains $id) (listed=$($list.Count))"
}

"file dropped: $($dst.Substring($CodexHome.Length))"
$srv = Start-AppServer $CodexHome
try {
  [void](Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } })
  Send-Notification $srv 'initialized'
  Show-State 'after initialize' $srv
  Start-Sleep -Seconds 10
  Show-State 'after 10s idle' $srv
  $rd = Invoke-Rpc $srv 'thread/read' @{ threadId = $id; includeTurns = $false }
  "thread/read ok=$([bool]$rd.result) " + $(if ($rd.error) { ($rd.error | ConvertTo-Json -Compress) })
  Show-State 'after thread/read' $srv
  if (-not $SkipResume) {
    $rs = Invoke-Rpc $srv 'thread/resume' @{ threadId = $id } 90
    $r = if ($rs.result) { "ok status=$($rs.result.thread.status.type) provider=$($rs.result.thread.modelProvider)" } else { ($rs | ConvertTo-Json -Compress -Depth 4) }
    "thread/resume -> $r   (no turn/start was sent)"
    Show-State 'after thread/resume' $srv
  }
} finally { Stop-AppServer $srv }
"--- second app-server start (does a restart rescan?)"
$srv = Start-AppServer $CodexHome
try {
  [void](Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } })
  Send-Notification $srv 'initialized'
  Start-Sleep -Seconds 5
  Show-State 'after restart' $srv
} finally { Stop-AppServer $srv }
