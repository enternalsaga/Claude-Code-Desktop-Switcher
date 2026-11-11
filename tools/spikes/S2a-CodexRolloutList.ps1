# Spike S2a: copy Codex rollouts into a scratch CODEX_HOME (no auth.json, no model call) and see whether threads get listed.
param(
  [string]$SpikeHome = (Join-Path $env:TEMP 'harness-spike\S2\home'),
  [string[]]$Rollouts,        # paths relative to ~\.codex\sessions, e.g. 2026\11\08\rollout-<ts>-<threadId>.jsonl (or .jsonl.zst)
  [int]$PickLatest,           # alternative to -Rollouts: take the N most recently written rollouts
  [switch]$Fresh
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $env:USERPROFILE '.codex\sessions'
if (-not $Rollouts -and $PickLatest -gt 0) {
  $Rollouts = @(Get-ChildItem $src -Recurse -File -Filter 'rollout-*' | Sort-Object LastWriteTime -Descending |
    Select-Object -First $PickLatest | ForEach-Object { $_.FullName.Substring($src.Length + 1) })
}
if (-not $Rollouts) { throw 'Pass -Rollouts <relative path>[,<relative path>] or -PickLatest <N>.' }
$idRe = '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl(\.zst)?$'
$threadIds = @($Rollouts | ForEach-Object { if ($_ -match $idRe) { $Matches[1] } else { throw "Cannot read a thread id from rollout name: $_" } })
. (Join-Path $PSScriptRoot 'S2a-AppServerClient.ps1')
if ($Fresh -and (Test-Path $SpikeHome)) { Assert-SpikeHome $SpikeHome; Remove-Item $SpikeHome -Recurse -Force }
New-Item -ItemType Directory -Force $SpikeHome | Out-Null
Assert-SpikeHome $SpikeHome

# Minimal config.toml: model line only. The real one has notify/marketplaces/local provider that would act on startup.
Set-Content (Join-Path $SpikeHome 'config.toml') "model = `"gpt-6.1-sol`"`n" -Encoding ASCII

foreach ($r in $Rollouts) {
  $dst = Join-Path $SpikeHome ('sessions\' + $r)
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  Copy-Item (Join-Path $src $r) $dst
}
"home contents before start:"; Get-ChildItem $SpikeHome -Recurse -File | ForEach-Object { '  ' + $_.FullName.Substring($SpikeHome.Length) }

# Counts rows in the scratch home's state_5.sqlite using the machine's sqlite3.exe in read-only mode (scratch home only).
function Show-ThreadRows([string]$When) {
  $s = (Get-Command sqlite3.exe -ErrorAction Stop).Source
  $db = Join-Path $SpikeHome 'state_5.sqlite'
  if (-not (Test-Path $db)) { "threads rows $When : (no state_5.sqlite yet)"; return }
  "threads rows $When : " + ((& $s -readonly $db 'select count(*) from threads;') -join ',')
}

$srv = Start-AppServer $SpikeHome
try {
  $init = Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; title = 'spike'; version = '0.0.1' } }
  'initialize ->'; ($init | ConvertTo-Json -Depth 6 -Compress)
  Send-Notification $srv 'initialized'
  $list = Invoke-Rpc $srv 'thread/list' @{ limit = 50 }
  'thread/list ->'; ($list | ConvertTo-Json -Depth 8 -Compress)
  Show-ThreadRows 'after initialize + first list'
  Start-Sleep -Seconds 15
  Show-ThreadRows 'after 15s idle'
  $list2 = Invoke-Rpc $srv 'thread/list' @{ limit = 50 }
  'thread/list (after 15s) ->'; ($list2 | ConvertTo-Json -Depth 8 -Compress)
  foreach ($id in $threadIds) {
    $rd = Invoke-Rpc $srv 'thread/read' @{ threadId = $id; includeTurns = $false }
    "thread/read $id ->"; ($rd | ConvertTo-Json -Depth 6 -Compress)
  }
  Show-ThreadRows 'after thread/read'
  # Default filter hides threads whose modelProvider differs from the home's config (the scratch config has no model_provider).
  $list3 = Invoke-Rpc $srv 'thread/list' @{ limit = 50; modelProviders = @(); sourceKinds = @("cli","vscode","exec","appServer") }
  'thread/list (modelProviders=[] + sourceKinds incl. exec) ->'; ($list3 | ConvertTo-Json -Depth 8 -Compress)
  # includeTurns:true needs the history projection (thread_history_1.sqlite); does Codex rebuild it from the copied rollout?
  foreach ($id in $threadIds) {
    $rt = Invoke-Rpc $srv 'thread/read' @{ threadId = $id; includeTurns = $true } 90
    $r = if ($rt.result) { "turns=$(@($rt.result.thread.turns).Count)" } else { ($rt | ConvertTo-Json -Compress -Depth 4) }
    "thread/read includeTurns=true $id -> $r"
  }
} finally { Stop-AppServer $srv }
'stderr tail:'; ($srv.Err.ToString() -split "`n" | Select-Object -Last 15) -join "`n"
'home contents after:'; Get-ChildItem $SpikeHome -Recurse -File | ForEach-Object { '  ' + $_.FullName.Substring($SpikeHome.Length) + ' ' + $_.Length }


