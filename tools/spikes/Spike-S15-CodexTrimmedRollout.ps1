# Spike S15: does a Codex rollout whose big tool outputs were trimmed still open (thread/read, thread/turns/list, thread/items/list) and
# resume (thread/resume, no turn/start) in a scratch CODEX_HOME, and does resume send anything to the model?
# Scratch homes under %TEMP%\harness-spike\S15 only (Assert-SpikeHome); the source rollout is read-only; no auth.json; no turn/start.
# The trim here is a PROTOTYPE of what lane C1 will implement: tool outputs over 16 KB keep 2 KB head + marker + 1 KB tail.
param([Parameter(Mandatory)][string]$SourceRollout)    # a plain .jsonl rollout that has response_item custom_tool_call_output / function_call_output lines
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S2a-AppServerClient.ps1')
$base = Join-Path $env:TEMP 'harness-spike\S15'
if ($SourceRollout -notmatch '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$') { throw 'need rollout-...-<threadId>.jsonl' }
$oldId = $Matches[1]
$first = (Get-Content -LiteralPath $SourceRollout -TotalCount 1 | ConvertFrom-Json).payload
$esc = { param($p) ($p | ConvertTo-Json -Compress).Trim('"') }
$headBytes = 2048; $tailBytes = 1024; $threshold = 16384
$bigText = ((1..4000) | ForEach-Object { "line $_ of a long tool output: lorem ipsum dolor sit amet, consectetur adipiscing elit." }) -join "`n"    # ~ 330 KB

# 1) the "before" rollout: the first three tool outputs replaced by a big text (a real chat with big outputs)
$lines = [IO.File]::ReadAllLines($SourceRollout, [Text.Encoding]::UTF8)
$inflated = New-Object Collections.Generic.List[string]; $nBig = 0
foreach ($l in $lines) {
    if ($nBig -lt 3 -and $l -match '"type":"(custom_tool_call_output|function_call_output)"') {
        $o = $l | ConvertFrom-Json
        if ($o.type -eq 'response_item' -and $o.payload.output -is [string]) { $o.payload.output = "BIGOUTPUT-$nBig`n" + $bigText; $inflated.Add(($o | ConvertTo-Json -Depth 30 -Compress)); $nBig++; continue }
    }
    $inflated.Add($l)
}
if ($nBig -eq 0) { throw 'the source rollout has no tool output lines to inflate' }

# 2) the prototype trim: only lines with a big output change; every other line is passed through untouched
function Convert-Trim([string[]]$Lines) {
    $out = New-Object Collections.Generic.List[string]; $trimmed = 0; $kept = 0
    foreach ($l in $Lines) {
        if ($l -match '"type":"(custom_tool_call_output|function_call_output)"') {
            $o = $l | ConvertFrom-Json
            if ($o.type -eq 'response_item' -and $o.payload.output -is [string] -and $o.payload.output.Length -gt $threshold) {
                $s = $o.payload.output
                $o.payload.output = $s.Substring(0, $headBytes) + "`n[... $([int](($s.Length - $headBytes - $tailBytes) / 1024)) KB trimmed; full output in archive ...]`n" + $s.Substring($s.Length - $tailBytes)
                $out.Add(($o | ConvertTo-Json -Depth 30 -Compress)); $trimmed++; continue
            }
        }
        $out.Add($l); $kept++
    }
    return [pscustomobject]@{ Lines = $out.ToArray(); Trimmed = $trimmed; Kept = $kept }
}
$t = Convert-Trim $inflated.ToArray()
$sizeBefore = ($inflated | Measure-Object Length -Sum).Sum; $sizeAfter = ($t.Lines | Measure-Object Length -Sum).Sum
"rollout: $($lines.Count) lines; made $nBig big tool outputs: $([int]($sizeBefore / 1KB)) KB; after the trim: $([int]($sizeAfter / 1KB)) KB; trimmed $($t.Trimmed) lines, $($t.Kept) lines passed through untouched"

function Test-Variant([string]$Label, [string[]]$Content) {
    $H = Join-Path $base "$Label\home"; Assert-SpikeHome $H
    New-Item -ItemType Directory -Force $H | Out-Null
    $id = [guid]::NewGuid().ToString()
    $text = (($Content -join "`n") + "`n").Replace($oldId, $id).Replace((& $esc ([string]$first.cwd)), (& $esc ([IO.Path]::GetTempPath().TrimEnd('\'))))
    $text = [regex]::Replace($text, '"(model_provider(?:_id)?)":"[^"]*"', '"$1":"openai"')    # the scratch home only knows the built-in provider
    $dst = Join-Path $H "sessions\2026\11\15\rollout-2026-11-15T09-00-00-$id.jsonl"
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding($false)))
    $srv = Start-AppServer $H
    $res = [ordered]@{}
    try {
        [void](Invoke-Rpc $srv 'initialize' @{ clientInfo = @{ name = 'switcher-spike'; version = '0.0.1' } }); Send-Notification $srv 'initialized'
        Start-Sleep 8
        $rd = Invoke-Rpc $srv 'thread/read' @{ threadId = $id; includeTurns = $true }
        $res.readOk = [bool]$rd.result; $res.readTurns = if ($rd.result) { @($rd.result.thread.turns).Count } else { "error: $(($rd.error | ConvertTo-Json -Compress) -replace '[A-Za-z]:\\\\[^ ]*', '<path>')" }
        $rs = Invoke-Rpc $srv 'thread/resume' @{ threadId = $id } 90
        $res.resumeOk = [bool]$rs.result; $res.resumeStatus = if ($rs.result) { $rs.result.thread.status.type } else { ($rs.error | ConvertTo-Json -Compress) }
        Start-Sleep 5
        $items = New-Object Collections.ArrayList; $cursor = $null
        do {
            $pp = @{ threadId = $id; limit = 100 }; if ($cursor) { $pp.cursor = $cursor }
            $r = Invoke-Rpc $srv 'thread/items/list' $pp 60
            if (-not $r.result) { $res.itemsError = ($r.error | ConvertTo-Json -Compress); break }
            foreach ($d in @($r.result.data)) { [void]$items.Add($d) }
            $cursor = $r.result.nextCursor
        } while ($cursor)
        $res.items = $items.Count
        $json = if ($items.Count) { [string]($items | ConvertTo-Json -Depth 12 -Compress) } else { '' }
        if (-not $items.Count -and -not $res.Contains('itemsError')) { $res.itemsError = 'no items returned' }
        $res.hasTrimMarker = $json.Contains('trimmed; full output in archive')
        $res.hasBigMarkerHead = $json.Contains('BIGOUTPUT-0')
        $res.maxItemKB = [int](($items | ForEach-Object { ($_ | ConvertTo-Json -Depth 12 -Compress).Length } | Measure-Object -Maximum).Maximum / 1KB)
        # did resume produce any model traffic or error? (the model gateway on this machine may be unreachable, so a model call would show as errors)
        $methods = @($srv.Notes | ForEach-Object { $_.method } | Group-Object | ForEach-Object { "$($_.Name)x$($_.Count)" })
        $res.notifications = ($methods -join ', ')
        $res.errorNotes = @($srv.Notes | Where-Object { $_.method -match 'error|reconnect|retry' -or ($_.params.message -match 'Reconnecting|network') }).Count
        $res.stderrHasModelCall = ($srv.Err.ToString() -match 'Reconnecting|responses|chat/completions|turn/start')
        $res.stderrMatches = (($srv.Err.ToString() -split "`n" | Where-Object { $_ -match 'Reconnecting|responses|chat/completions|turn/start' } | Select-Object -First 2 | ForEach-Object { ($_ -replace '[A-Za-z]:\\[^ ]*', '<path>').Trim() }) -join ' || ')
        $res.itemTypes = (($items | ForEach-Object { $_.type } | Group-Object | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ',')
        $tl = Invoke-Rpc $srv 'thread/turns/list' @{ threadId = $id; limit = 50 } 60
        $res.turnsList = if ($tl.result) { @($tl.result.data).Count } else { "error: $(($tl.error | ConvertTo-Json -Compress))" }
        $big = @($items | Where-Object { ($_ | ConvertTo-Json -Depth 12 -Compress).Length -gt 20000 })
        $res.itemsOver20KB = $big.Count
    } finally { Stop-AppServer $srv }
    "[$Label] " + (($res.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
}
try {
    Test-Variant 'untrimmed' $inflated.ToArray()
    Test-Variant 'trimmed' $t.Lines
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    "cleanup: scratch folder gone = $(-not (Test-Path -LiteralPath $base))"
}
