# Spike S8b: can app-server `thread/items/list` return user/assistant text for a .jsonl.zst rollout (no zstd in PowerShell)?
# Scratch home under %TEMP%\harness-spike\S8 only; rollouts are COPIES from Default's sessions (read-only source).
param(
  [Parameter(Mandatory)][string]$ZstRollout,     # relative to ~\.codex\sessions, a .jsonl.zst
  [string]$JsonlRollout,                         # optional plain .jsonl for comparison
  [int]$WaitSec = 8,
  [switch]$Resume,                               # also call thread/resume (loads the thread, sends no turn) before listing
  [string]$CodexHome =(Join-Path $env:TEMP 'harness-spike\S8\home-transcript')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S8-CodexSpikeCommon.ps1')
Assert-SpikeHome $CodexHome
New-Item -ItemType Directory -Force $CodexHome | Out-Null
Set-Content (Join-Path $CodexHome 'config.toml') "model = `"gpt-6.1-sol`"`n" -Encoding ASCII
$src = Join-Path $env:USERPROFILE '.codex\sessions'
$ids = @()
foreach ($r in @($ZstRollout, $JsonlRollout) | Where-Object { $_ }) {
  $dst = Join-Path $CodexHome ('sessions\' + $r)
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  Copy-Item -LiteralPath (Join-Path $src $r) -Destination $dst -Force
  $ids += [regex]::Match($r, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl').Groups[1].Value
}
$srv = Start-AppServer $CodexHome
try {
  [void](Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } })
  Send-Notification $srv 'initialized'
  foreach ($id in $ids) {
    "=== thread $($id.Substring(0,8))"
    [void](Invoke-Rpc $srv 'thread/read' @{ threadId = $id; includeTurns = $false })
    Start-Sleep -Seconds $WaitSec
    if ($Resume) { $rs = Invoke-Rpc $srv 'thread/resume' @{ threadId = $id } 90; "thread/resume ok=$([bool]$rs.result) (no turn/start)"; Start-Sleep -Seconds $WaitSec }
    $items = New-Object Collections.ArrayList; $cursor = $null; $pages = 0
    do {
      $p = @{ threadId = $id; limit = 200 }; if ($cursor) { $p.cursor = $cursor }
      $r = Invoke-Rpc $srv 'thread/items/list' $p 90
      if (-not $r.result) { "thread/items/list error: " + ($r | ConvertTo-Json -Compress -Depth 4); break }
      foreach ($d in @($r.result.data)) { [void]$items.Add($d) }
      $cursor = $r.result.nextCursor; $pages++
    } while ($cursor -and $pages -lt 50)
    "items=$($items.Count) pages=$pages"
    if ($items.Count) {
      "entry keys: " + (($items[0].PSObject.Properties.Name) -join ',')
      "item types: " + ((@($items | ForEach-Object { $_.item.type }) | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
      $first = $items | Where-Object { $_.item.type -in 'userMessage', 'agentMessage' } | Select-Object -First 2
      foreach ($f in $first) { "sample $($f.item.type): " + (($f.item | ConvertTo-Json -Compress -Depth 5) -replace '\s+', ' ').Substring(0, [Math]::Min(260, ($f.item | ConvertTo-Json -Compress -Depth 5).Length)) }
    }
    $t = Invoke-Rpc $srv 'thread/turns/list' @{ threadId = $id; limit = 50; itemsView = 'full' } 90
    "turns/list: " + $(if ($t.result) { "turns=$(@($t.result.data).Count)" } else { ($t | ConvertTo-Json -Compress -Depth 4) })
  }
} finally { Stop-AppServer $srv }
