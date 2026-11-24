# Spike S22: where does the first Storage scan spend its time? Runs the real Get-StorageInventory on the real roots with an
# empty in-memory cache (no scanner cache, the OS file cache is not flushed) and times each phase and each heavy helper.
# READ ONLY: writes nothing; the cache is never saved. Run: powershell -NoProfile -ExecutionPolicy Bypass -File <this>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

# The app's own functions without running the app: every top-level function of ClaudeSwitcher.ps1, then the src modules.
$script:ProfileRoot = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
$script:ProfileDirPrefix = 'ClaudeProfile-'
$script:SwitcherHome = Join-Path $script:ProfileRoot '.switcher'
$script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
$script:DefaultName = 'Default'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ClaudeSwitcher.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach ($f in Get-ChildItem (Join-Path $repo 'src') -Filter '*.ps1' | Where-Object { $_.Name -notlike 'Ui*' }) { . $f.FullName }
$ClaudePath = $null
Update-ClaudeInstall -AllowCache   # the app does this at start; Get-ProfileList needs $script:ClaudeApp

$sw = [Diagnostics.Stopwatch]::StartNew()
$roots = Get-StorageRootsFromConfig -Config $null
$rootsMs = $sw.ElapsedMilliseconds
"roots: {0} ms (Claude profiles {1}, Codex homes {2}, Antigravity dirs {3})" -f $rootsMs, @($roots.ClaudeProfiles).Count, @($roots.CodexHomes).Count, @($roots.AgyDirs).Count

# Inclusive time and call count per helper. Read-StorageClaudeJsonlMeta is not wrapped: the parallel pool copies its definition.
$global:S22 = @{}
$global:S22Measured = New-Object Collections.Generic.List[object]
$global:S22Record = $true
$global:S22OrigMeasure = $null
$wrap = 'Get-ClaudeProfileRefs', 'Get-ClaudeTranscripts', 'Read-StorageClaudeMetaParallel', 'Measure-StorageDir', 'Get-CodexStorageSessions',
        'Read-StorageCodexRows', 'Get-AgyStorageSessions', 'Read-StorageAgyRows', 'Get-StorageProfileFolder', 'Copy-SqliteSnapshot'
foreach ($n in $wrap) {
    $cmd = Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue
    if (-not $cmd) { "  (no function $n)"; continue }
    $orig = $cmd.ScriptBlock; $name = $n
    $global:S22[$name] = @{ Ms = [double]0; Calls = 0 }
    if ($n -eq 'Measure-StorageDir') {
        $global:S22OrigMeasure = $orig
        Set-Item -Path "Function:\script:$n" -Value ({
            param([Parameter(Mandatory)][string]$Path, $Cancel)
            $t = [Diagnostics.Stopwatch]::StartNew()
            try {
                $r = & $orig -Path $Path -Cancel $Cancel
                if ($global:S22Record) { $global:S22Measured.Add([pscustomobject]@{ Path = $Path; Result = $r }) }
                $r
            } finally { $global:S22[$name].Ms += $t.Elapsed.TotalMilliseconds; $global:S22[$name].Calls++ }
        }.GetNewClosure())
        continue
    }
    Set-Item -Path "Function:\script:$n" -Value ({
        $t = [Diagnostics.Stopwatch]::StartNew()
        try { & $orig @args } finally { $global:S22[$name].Ms += $t.Elapsed.TotalMilliseconds; $global:S22[$name].Calls++ }
    }.GetNewClosure())
}

$progress = [hashtable]::Synchronized(@{ Phase = 'starting'; Done = 0; Total = 0 })
$phases = New-Object Collections.Generic.List[object]
$origSet = (Get-Command Set-StorageProgress -CommandType Function).ScriptBlock
$global:S22Phase = @{ Name = 'starting'; At = [Diagnostics.Stopwatch]::StartNew(); List = $phases }
Set-Item -Path Function:\script:Set-StorageProgress -Value ({
    $i = [array]::IndexOf($args, '-Phase')
    if ($i -ge 0 -and $args[$i + 1] -and $args[$i + 1] -ne $global:S22Phase.Name) {
        $global:S22Phase.List.Add([pscustomobject]@{ Phase = $global:S22Phase.Name; Ms = $global:S22Phase.At.ElapsedMilliseconds })
        $global:S22Phase.Name = $args[$i + 1]; $global:S22Phase.At.Restart()
    }
    & $origSet @args
}.GetNewClosure())

$cache = New-StorageCache
$sw.Restart()
$inv = Get-StorageInventory -Roots $roots -Cache $cache -Progress $progress
$total = $sw.ElapsedMilliseconds
$phases.Add([pscustomobject]@{ Phase = $global:S22Phase.Name; Ms = $global:S22Phase.At.ElapsedMilliseconds })

""
"total Get-StorageInventory: {0:N1} s; sessions {1}; files {2}; reads {3}; warnings {4}" -f ($total / 1000), $inv.Totals.Sessions, $inv.Files, $inv.Reads, @($inv.Warnings).Count
"phases (wall clock, from the Progress phase changes):"
foreach ($p in $phases) { "  {0,-10} {1,9:N1} s" -f $p.Phase, ($p.Ms / 1000) }
"helpers (inclusive, nested calls counted in both):"
foreach ($k in ($global:S22.Keys | Sort-Object { -$global:S22[$_].Ms })) { "  {0,-32} {1,9:N1} s  {2,6} calls" -f $k, ($global:S22[$k].Ms / 1000), $global:S22[$k].Calls }

# Pass 2: the same scan again with the cache pass 1 filled (what every later scan in the app costs).
$global:S22Record = $false
foreach ($k in @($global:S22.Keys)) { $global:S22[$k] = @{ Ms = [double]0; Calls = 0 } }
$phases.Clear(); $global:S22Phase.Name = 'starting'; $global:S22Phase.At.Restart()
$sw.Restart()
$inv2 = Get-StorageInventory -Roots $roots -Cache $cache -Progress $progress
$total2 = $sw.ElapsedMilliseconds
$phases.Add([pscustomobject]@{ Phase = $global:S22Phase.Name; Ms = $global:S22Phase.At.ElapsedMilliseconds })
""
"PASS 2 (hot scanner cache): {0:N1} s; reads {1}" -f ($total2 / 1000), $inv2.Reads
foreach ($p in $phases) { "  {0,-10} {1,9:N1} s" -f $p.Phase, ($p.Ms / 1000) }
foreach ($k in ($global:S22.Keys | Sort-Object { -$global:S22[$_].Ms })) { "  {0,-32} {1,9:N1} s  {2,6} calls" -f $k, ($global:S22[$k].Ms / 1000), $global:S22[$k].Calls }
"sessions by harness:"
foreach ($h in 'claude', 'codex', 'antigravity') { "  {0,-12} {1,6} sessions {2,8:N2} GB" -f $h, $inv.Totals.ByHarness[$h].Sessions, ($inv.Totals.ByHarness[$h].Bytes / 1GB) }

# Parity check: compare every folder Measure-StorageDir measured in pass 1 with Measure-StorageDirPs.
$retried = 0
$mismatches = New-Object Collections.Generic.List[object]
foreach ($item in $global:S22Measured) {
    $cs = $item.Result
    $ps = Measure-StorageDirPs -Path $item.Path
    if ($cs.Bytes -ne $ps.Bytes -or $cs.Files -ne $ps.Files -or $cs.NewestTicks -ne $ps.NewestTicks) {
        $retried++
        $cs = & $global:S22OrigMeasure -Path $item.Path
        $ps = Measure-StorageDirPs -Path $item.Path
        if ($cs.Bytes -ne $ps.Bytes -or $cs.Files -ne $ps.Files -or $cs.NewestTicks -ne $ps.NewestTicks) {
            $mismatches.Add([pscustomobject]@{ Path = $item.Path; Cs = $cs; Ps = $ps })
        }
    }
}
$csLoaded = [bool]('HarnessStorage.DirMeasure' -as [type])
""
"PARITY (C# loaded={0}): checked {1}; retried {2}; mismatches {3}" -f $csLoaded, $global:S22Measured.Count, $retried, $mismatches.Count
foreach ($mm in $mismatches) {
    "  MISMATCH {0}: C#=({1}/{2}/{3}) PS=({4}/{5}/{6})" -f $mm.Path, $mm.Cs.Bytes, $mm.Cs.Files, $mm.Cs.NewestTicks, $mm.Ps.Bytes, $mm.Ps.Files, $mm.Ps.NewestTicks
}
