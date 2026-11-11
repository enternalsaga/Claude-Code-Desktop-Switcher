# Spike S3: Claude Code session -> Codex via app-server `externalAgentConfig/detect` + `externalAgentConfig/import`.
# Runs against the S2 scratch CODEX_HOME (no auth.json, no model call). The source jsonl is a COPY under %TEMP%.
param(
  [string]$SpikeHome = (Join-Path $env:TEMP 'harness-spike\S2\home'),
  [Parameter(Mandatory)][string]$SourceJsonl,   # a Claude session jsonl under ~\.claude\projects\<slug>\<id>.jsonl
  [Parameter(Mandatory)][string]$SessionCwd,    # that session's working directory
  [switch]$DetectHome      # also run detect with includeHome:true to see whether it reads the real ~\.claude
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S2a-AppServerClient.ps1')
Assert-SpikeHome $SpikeHome
$work = Join-Path $env:TEMP 'harness-spike\S3\claude-src'
New-Item -ItemType Directory -Force $work | Out-Null
$copy = Join-Path $work (Split-Path $SourceJsonl -Leaf)
Copy-Item $SourceJsonl $copy -Force
$realImports = Join-Path $env:USERPROFILE '.codex\external_agent_session_imports.json'
$hashBefore = (Get-FileHash $realImports -Algorithm SHA256).Hash   # real file must stay untouched

$srv = Start-AppServer $SpikeHome
try {
  [void](Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } })
  Send-Notification $srv 'initialized'

  $d1 = Invoke-Rpc $srv 'externalAgentConfig/detect' @{ includeHome = $false; cwds = @($work) }
  "detect(includeHome=false, cwds=[$work]) -> " + ($d1 | ConvertTo-Json -Depth 8 -Compress)

  if ($DetectHome) {
    $d2 = Invoke-Rpc $srv 'externalAgentConfig/detect' @{ includeHome = $true; maxSessions = 3 } 120
    $items = @($d2.result.items)
    "detect(includeHome=true, maxSessions=3): items=$($items.Count); types=" + (($items | ForEach-Object itemType | Sort-Object -Unique) -join ',')
    foreach ($s in @($items | ForEach-Object { $_.details.sessions } | Where-Object { $_ })) { "  session path: $($s.path)" }
  }

  $item = @{
    itemType = 'SESSIONS'; description = 'spike import'; cwd = $null
    details = @{ sessions = @(@{ cwd = $SessionCwd; path = $copy; title = 'S3 spike import' }) }
  }
  $imp = Invoke-Rpc $srv 'externalAgentConfig/import' @{ migrationItems = @($item) } 120
  "import -> " + ($imp | ConvertTo-Json -Depth 8 -Compress)
  $done = Wait-Notification $srv 'externalAgentConfig/import/completed' 90
  "completed notification -> " + ($done | ConvertTo-Json -Depth 8 -Compress)
  "all notifications: " + (($srv.Notes | ForEach-Object method) -join ', ')

  # Positive path: import only what `detect` itself reports (sessions are home-scoped, so includeHome:true is required).
  $srv.Notes.Clear()
  $d3 = Invoke-Rpc $srv 'externalAgentConfig/detect' @{ includeHome = $true; maxSessions = 5000; maxSessionAgeDays = 3650 } 120
  $its = @($d3.result.items)
  "detect(includeHome=true, maxSessions=5000): items=$($its.Count) types=" + (($its | ForEach-Object itemType | Sort-Object -Unique) -join ',')
  $sess = @($its | Where-Object itemType -eq 'SESSIONS' | ForEach-Object { $_.details.sessions } | Where-Object { $_ })
  "  detected sessions: $($sess.Count); under real ~\.claude: $(@($sess | Where-Object { $_.path -like (Join-Path $env:USERPROFILE '.claude\*') }).Count)"
  $pick = $sess | Where-Object { $_.path -eq $SourceJsonl } | Select-Object -First 1
  if (-not $pick) { $pick = $sess | Sort-Object { (Get-Item $_.path).Length } | Select-Object -First 1 }
  if ($pick) {
    "  picked: $($pick.path) cwd=$($pick.cwd) title=$($pick.title)"
    $srcHash = (Get-FileHash $pick.path -Algorithm SHA256).Hash
    $item2 = @{ itemType = 'SESSIONS'; description = 'spike import (detected item)'; cwd = $SessionCwd; details = @{ sessions = @($pick) } }
    $imp2 = Invoke-Rpc $srv 'externalAgentConfig/import' @{ migrationItems = @($item2) } 120
    "import(detected) -> " + ($imp2 | ConvertTo-Json -Depth 8 -Compress)
    $done2 = Wait-Notification $srv 'externalAgentConfig/import/completed' 120
    "completed -> " + ($done2 | ConvertTo-Json -Depth 8 -Compress)
    "source jsonl unchanged: " + ((Get-FileHash $pick.path -Algorithm SHA256).Hash -eq $srcHash)
  }

  $list = Invoke-Rpc $srv 'thread/list' @{ limit = 50; modelProviders = @(); sourceKinds = @('cli', 'vscode', 'exec', 'appServer') }
  "thread/list: " + ((@($list.result.data) | ForEach-Object { "$($_.id) [$($_.source)] $($_.preview)" }) -join ' | ')
} finally { Stop-AppServer $srv }

$ei = Join-Path $SpikeHome 'external_agent_session_imports.json'
if (Test-Path $ei) { "external_agent_session_imports.json (scratch home):"; Get-Content $ei -Raw } else { 'external_agent_session_imports.json: not created in scratch home' }
"real ~\.codex\external_agent_session_imports.json unchanged: " + ((Get-FileHash $realImports -Algorithm SHA256).Hash -eq $hashBefore)
'stderr tail:'; ($srv.Err.ToString() -split "`n" | Select-Object -Last 8) -join "`n"

