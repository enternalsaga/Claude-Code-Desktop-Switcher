# Spike S7: read-only scan of app bundles for deep-link (protocol handler) routes. Opens nothing, launches nothing.
# For each asar: parse the asar header, scan the .js files (and for plain folders, the .js files) for protocol URLs,
# `searchParams.get("...")` parameter names and route-looking path strings near them.
param(
  [string[]]$Targets = @(
    'C:\Program Files\WindowsApps\Claude_5.1231.2.0_x64__pzs8sxrjxfjjc\app\resources\app.asar',
    'C:\Program Files\WindowsApps\OpenAI.Codex_26.1103.7773.0_x64__2p2nqsd0c76g0\app\resources\app.asar',
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\resources\app.asar'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE\resources\app\out\main.js')
  ),
  [string]$Schemes = 'claude|codex|antigravity-ide|antigravity|agy|gemini',
  [int]$MaxFileMB = 40,
  [string]$ContextPattern,        # when set: print +-ContextChars around each match instead of the summary (use with -Targets)
  [string]$PathFilter,            # regex on the file path inside the bundle (with -ContextPattern)
  [int]$ContextChars = 220,
  [int]$MaxContexts = 12
)
$ErrorActionPreference = 'Stop'
$schemeRe = [regex]("(?<![A-Za-z0-9_-])(?:$Schemes)(?::|%3A)(?://|%2F%2F)[A-Za-z0-9_\-\./\{\}\$\?=&%:#@]{0,120}")
$paramRe = [regex]'(?:searchParams|query|params)\.get\(\s*["'']([A-Za-z_][A-Za-z0-9_\-]{0,30})["'']\s*\)'

function Get-AsarJs([string]$Asar) {
  $fs = [IO.File]::OpenRead($Asar)
  try {
    $br = New-Object IO.BinaryReader($fs)
    [void]$br.ReadUInt32(); $headerPickle = $br.ReadUInt32(); [void]$br.ReadUInt32(); $jsonLen = $br.ReadUInt32()
    $json = [Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$jsonLen))
    $base = 8 + $headerPickle
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = [int]::MaxValue; $ser.RecursionLimit = 200
    $root = $ser.DeserializeObject($json)
    $stack = New-Object Collections.Stack; $stack.Push(@('', $root))
    while ($stack.Count) {
      $p = $stack.Pop(); $path = $p[0]; $node = $p[1]
      if ($node.ContainsKey('files')) { foreach ($k in $node['files'].Keys) { $stack.Push(@("$path/$k", $node['files'][$k])) } }
      elseif ($node.ContainsKey('offset') -and $path -match '\.(js|mjs|cjs)$' -and $path -notmatch '/node_modules/' -and [long]$node['size'] -gt 200 -and [long]$node['size'] -lt ($MaxFileMB * 1MB)) {
        $fs.Position = $base + [long]$node['offset']
        $buf = $br.ReadBytes([int]$node['size'])
        [pscustomobject]@{ Path = $path; Text = [Text.Encoding]::UTF8.GetString($buf) }
      }
    }
  } finally { $fs.Dispose() }
}

foreach ($t in $Targets) {
  "=================== $t"
  if (-not (Test-Path $t)) { 'MISSING'; continue }
  $files = if ($t -like '*.asar') { Get-AsarJs $t } else { Get-Item $t | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Text = [IO.File]::ReadAllText($_.FullName) } } }
  $hits = @()
  if ($ContextPattern) {
    $shown = 0
    foreach ($f in $files) {
      if ($PathFilter -and $f.Path -notmatch $PathFilter) { continue }
      foreach ($m in [regex]::Matches($f.Text, $ContextPattern)) {
        if ($shown -ge $MaxContexts) { break }
        $s = [Math]::Max(0, $m.Index - $ContextChars); $e = [Math]::Min($f.Text.Length, $m.Index + $m.Length + $ContextChars)
        $shown++
        "-- $($f.Path) @$($m.Index)"; $f.Text.Substring($s, $e - $s) -replace '\s+', ' '
      }
    }
    continue
  }
  foreach ($f in $files) {
    $m = $schemeRe.Matches($f.Text)
    if ($m.Count -eq 0) { continue }
    $urls = @($m | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $pars = @($paramRe.Matches($f.Text) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $hits += [pscustomobject]@{ File = $f.Path; Urls = $urls; Params = $pars; Text = $f.Text }
    "-- $($f.Path) ($($f.Text.Length) chars)"
    "   urls: " + (($urls | Select-Object -First 25) -join ' | ')
    "   searchParams.get names in file: " + (($pars | Select-Object -First 40) -join ', ')
  }
  if (-not $hits) { 'no protocol URL strings found in scanned js files' }
}
