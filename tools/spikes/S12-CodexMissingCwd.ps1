# Spike S12: does a rollout whose cwd does not exist on this machine still get registered as a thread (thread/read), and what does
# the threads.cwd column hold? Scratch home under %TEMP%\harness-spike\S12 only; the rollout source is read-only. No model call.
param(
  [Parameter(Mandatory)][string]$SourceRollout,                                   # plain .jsonl rollout (read-only source)
  [string]$MissingCwd = 'Z:\NoSuchRoot\SomeProject',                              # a path that does not exist here
  [string]$Home_ = (Join-Path $env:TEMP 'harness-spike\S12\home')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S8-CodexSpikeCommon.ps1')
. (Join-Path $PSScriptRoot '..\..\src\Harness.Sqlite.ps1')
Assert-SpikeHome $Home_
if (Test-Path -LiteralPath $MissingCwd) { throw 'MissingCwd exists on this machine; pick another' }
if ($SourceRollout -notmatch '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$') { throw 'need rollout-...-<threadId>.jsonl' }
$oldId = $Matches[1]
$first = (Get-Content -LiteralPath $SourceRollout -TotalCount 1 | ConvertFrom-Json).payload
$origCwd = [string]$first.cwd
New-Item -ItemType Directory -Force $Home_ | Out-Null
$exe = Get-SpikeCodexExe
$allQ = @{ limit = 100; modelProviders = @(); sourceKinds = @('cli', 'vscode', 'exec', 'appServer', 'unknown') }

function New-Synth([string]$Cwd, [string]$Tag) {
    $id = [guid]::NewGuid().ToString()
    $text = [IO.File]::ReadAllText($SourceRollout, [Text.Encoding]::UTF8).Replace($oldId, $id)
    $esc = { param($p) ($p | ConvertTo-Json -Compress).Trim('"') }
    $text = $text.Replace((& $esc $origCwd), (& $esc $Cwd))
    $rel = "2026\11\11\rollout-2026-11-11T09-00-00-$id.jsonl"
    $dst = Join-Path $Home_ ('sessions\' + $rel)
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{ Id = $id; Tag = $Tag; Cwd = $Cwd }
}
function Get-DbRows {
    $db = Join-Path $Home_ 'state_5.sqlite'
    if (-not (Test-Path -LiteralPath $db)) { return @() }
    $snap = Copy-SqliteSnapshot $db
    try {
        $h = Open-SqliteReadOnly $snap
        try { return @(Invoke-SqliteQuery $h 'select id, cwd, rollout_path, archived from threads') } finally { Close-Sqlite $h }
    } finally { Remove-Item -LiteralPath (Split-Path $snap) -Recurse -Force -ErrorAction SilentlyContinue }
}
function Invoke-Session([scriptblock]$Body) {
    $srv = Start-AppServer $Home_
    try {
        [void](Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } })
        Send-Notification $srv 'initialized'
        & $Body $srv
    } finally { Stop-AppServer $srv }
}

try {
    "original rollout cwd length: $($origCwd.Length); exists here: $(Test-Path -LiteralPath $origCwd)"
    # 1) let the app-server create the database in an empty scratch home
    Invoke-Session { param($s) Start-Sleep -Seconds 3 }
    "database created by an empty start: $(Test-Path (Join-Path $Home_ 'state_5.sqlite'))"
    # 2) drop two rollouts: one whose cwd is missing, one whose cwd exists (control)
    $existing = [IO.Path]::GetTempPath().TrimEnd('\')
    $missing = New-Synth $MissingCwd 'missing-cwd'
    $control = New-Synth $existing 'existing-cwd'
    Invoke-Session {
        param($s)
        Start-Sleep -Seconds 12
        foreach ($t in $missing, $control) {
            $rd = Invoke-Rpc $s 'thread/read' @{ threadId = $t.Id; includeTurns = $false }
            $err = if ($rd.error) { ($rd.error | ConvertTo-Json -Compress) } else { '' }
            $cw = if ($rd.result) { $rd.result.thread.cwd } else { $null }
            "[$($t.Tag)] thread/read ok=$([bool]$rd.result) cwd-in-result=[$cw] $err"
        }
        $list = @((Invoke-Rpc $s 'thread/list' $allQ).result.data)
        foreach ($t in $missing, $control) { "[$($t.Tag)] listed by thread/list: $(@($list | Where-Object { $_.id -eq $t.Id }).Count -gt 0)" }
    }
    $rows = Get-DbRows
    foreach ($t in $missing, $control) {
        $r = @($rows | Where-Object { $_.id -eq $t.Id })
        "[$($t.Tag)] row in threads: $($r.Count -gt 0) cwd-column=[$(if ($r.Count) { $r[0].cwd })] archived=$(if ($r.Count) { $r[0].archived })"
    }
} finally {
    Remove-Item -LiteralPath (Split-Path (Split-Path $Home_)) -Recurse -Force -ErrorAction SilentlyContinue
    "cleanup: scratch folder gone = $(-not (Test-Path -LiteralPath $Home_))"
}
