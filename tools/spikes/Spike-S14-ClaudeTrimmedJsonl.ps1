# Spike S14 (US1): does a Claude Code chat whose big tool results were trimmed (per spec 5.3) still show, open and take a new message in Claude Desktop?
#   -Action Setup   : copies one small real chat of -SourceProfile (read only) twice into the TRIAL profile -ProfileName, with new ids and a new empty
#                     project folder each: "S14 CONTROL (untrimmed)" and "S14 TRIMMED". The trimmed copy has every tool_result text block (and the
#                     duplicate in toolUseResult) over -ThresholdKB cut to 2 KB head + marker + 1 KB tail; all other lines stay byte-identical.
#   -Action Cleanup : removes everything Setup created (manifest in %TEMP%\harness-spike\S14).
# Adds only new files (a local_*.json per chat in the trial profile, a <cli>.jsonl under ~\.claude\projects\<new slug>\, an empty folder).
# Refuses to run while the trial profile's app is open. Nothing existing is modified or deleted. The trial profile must be signed in
# (a new message has to be sent to prove the chat still works); it is the user's choice which one, so -ProfileName has no default.
param(
    [Parameter(Mandatory)][ValidateSet('Setup', 'Cleanup')][string]$Action,
    [Parameter(Mandatory)][string]$ProfileName,
    [string]$SourceProfile = 'Account 2',
    [int]$ThresholdKB = 4,                   # the spec says 16; the small real chat has no tool result that big, so the spike uses a lower limit
    [string]$ProjectRoot = (Join-Path $env:TEMP 'harness-spike\S14')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stateDir = Join-Path ([IO.Path]::GetTempPath()) 'harness-spike\S14'
$manifestPath = Join-Path $stateDir 'manifest.json'
$profileDir = Join-Path $env:LOCALAPPDATA ('ClaudeProfile-' + $ProfileName)
if (-not (Test-Path -LiteralPath $profileDir)) { throw "profile folder not found: $ProfileName" }
$esc = [regex]::Escape($profileDir)
if (@(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Where-Object { $_.CommandLine -match $esc -and $_.CommandLine -notmatch '--type=' }).Count -gt 0) {
    throw "The app of profile '$ProfileName' is running. Close it (not the other Claude windows), then run again."
}
function Get-FnText([string]$File, [string]$Name) {
    $ast = [Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
    return $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true).Extent.Text
}
Invoke-Expression (Get-FnText (Join-Path $root 'ClaudeSwitcher.ps1') 'Set-JsonTopLevelString')
Invoke-Expression (Get-FnText (Join-Path $root 'src\Harness.Claude.ps1') 'ConvertTo-ClaudeProjectSlug')
$projects = Join-Path $env:USERPROFILE '.claude\projects'
$utf8 = New-Object Text.UTF8Encoding($false)

if ($Action -eq 'Cleanup') {
    if (-not (Test-Path -LiteralPath $manifestPath)) { 'nothing to clean (no manifest)'; return }
    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($t in $m.tests) {
        foreach ($p in $t.localJson) { if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force; "removed $(Split-Path -Leaf $p)" } }
        if ($t.projectSlugDir -and (Test-Path -LiteralPath $t.projectSlugDir) -and $t.projectSlugDir.StartsWith($projects)) { Remove-Item -LiteralPath $t.projectSlugDir -Recurse -Force; "removed project slug folder $(Split-Path -Leaf $t.projectSlugDir)" }
        if ($t.projectFolder -and (Test-Path -LiteralPath $t.projectFolder) -and @(Get-ChildItem -LiteralPath $t.projectFolder -Force).Count -eq 0) { Remove-Item -LiteralPath $t.projectFolder -Force; "removed project folder" }
    }
    Remove-Item -LiteralPath $stateDir -Recurse -Force
    'cleanup done'
    return
}

# ---- trim (prototype of what lane C1 will do) ----
$threshold = $ThresholdKB * 1024
function Convert-TrimNode($Node) {
    # walks a parsed JSON node; returns the number of text values it shortened
    $n = 0
    if ($Node -is [array]) { foreach ($x in $Node) { $n += Convert-TrimNode $x }; return $n }
    if ($Node -isnot [pscustomobject]) { return 0 }
    # the three places a tool result keeps its text: a text block, a tool_result block with a plain string, a toolUseResult stdout string
    foreach ($key in @('text', 'content', 'stdout')) {
        if (($key -eq 'text' -and $Node.type -ne 'text') -or ($key -eq 'content' -and $Node.type -ne 'tool_result')) { continue }
        $s = $Node.$key
        if ($s -is [string] -and $s.Length -gt $threshold) {
            $Node.$key = $s.Substring(0, 2048) + "`n[... $([int](($s.Length - 3072) / 1024)) KB trimmed; full output in archive ...]`n" + $s.Substring($s.Length - 1024)
            $n++
        }
    }
    foreach ($p in $Node.PSObject.Properties) { $n += Convert-TrimNode $p.Value }
    return $n
}
function Convert-TrimJsonl([string]$Text) {
    $out = New-Object Collections.Generic.List[string]; $cut = 0
    foreach ($l in ($Text -split "`n")) {
        if ($l.Length -gt $threshold -and $l.Contains('"tool_result"')) {
            $o = $l | ConvertFrom-Json
            $k = 0
            if ($o.message.content) { $k += Convert-TrimNode $o.message.content }
            if ($o.toolUseResult) { $k += Convert-TrimNode $o.toolUseResult }
            if ($k) { $out.Add(($o | ConvertTo-Json -Depth 40 -Compress)); $cut += $k; continue }
        }
        $out.Add($l)
    }
    return [pscustomobject]@{ Text = ($out -join "`n"); Cut = $cut }
}

# ---- Setup ----
if (Test-Path -LiteralPath $manifestPath) { throw 'A previous Setup is still in place. Run -Action Cleanup first.' }
$store = Get-ChildItem -LiteralPath (Join-Path $profileDir 'claude-code-sessions') -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $store) { throw 'trial profile has no session store (not signed in?)' }
$srcDir = Join-Path $env:LOCALAPPDATA ('ClaudeProfile-' + $SourceProfile)
$srcStore = Get-ChildItem -LiteralPath (Join-Path $srcDir 'claude-code-sessions') -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $srcStore) { throw 'source profile has no session store' }
$pick = $null
foreach ($f in (Get-ChildItem -LiteralPath $srcStore.FullName -File -Filter 'local_*.json')) {
    try { $d = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    if (-not $d.cliSessionId -or -not $d.cwd) { continue }
    $jl = Join-Path $projects "$(ConvertTo-ClaudeProjectSlug $d.cwd)\$($d.cliSessionId).jsonl"
    if (-not (Test-Path -LiteralPath $jl)) { continue }
    $sz = (Get-Item -LiteralPath $jl).Length
    if ($sz -lt 20KB -or $sz -gt 600KB -or (Test-Path -LiteralPath ($jl -replace '\.jsonl$', ''))) { continue }
    $has = $false; foreach ($l in [IO.File]::ReadLines($jl)) { if ($l.Length -gt $threshold -and $l.Contains('"tool_result"')) { $has = $true; break } }
    if ($has -and (-not $pick -or $sz -lt $pick.Size)) { $pick = [pscustomobject]@{ Json = $f; Data = $d; Jsonl = $jl; Size = $sz } }
}
if (-not $pick) { throw 'no suitable small chat with a big tool result found' }
$origCli = [string]$pick.Data.cliSessionId
"source chat: jsonl $([int]($pick.Size / 1KB)) KB (content stays on this machine)"

New-Item -ItemType Directory -Force $stateDir | Out-Null
$tests = @()
foreach ($v in @(@{ Tag = 'CONTROL'; Title = 'S14 CONTROL (untrimmed)'; Trim = $false }, @{ Tag = 'TRIMMED'; Title = 'S14 TRIMMED'; Trim = $true })) {
    $newCwd = (Join-Path $ProjectRoot ('S14-' + $v.Tag)).TrimEnd('\')
    $newCli = [guid]::NewGuid().ToString(); $newLocal = 'local_' + [guid]::NewGuid().ToString()
    New-Item -ItemType Directory -Force $newCwd | Out-Null
    $slugDir = Join-Path $projects (ConvertTo-ClaudeProjectSlug $newCwd)
    if (Test-Path -LiteralPath $slugDir) { throw "slug folder already exists: $slugDir" }
    New-Item -ItemType Directory -Path $slugDir | Out-Null
    $text = [IO.File]::ReadAllText($pick.Jsonl, [Text.Encoding]::UTF8).Replace($origCli, $newCli)
    foreach ($c in @([regex]::Matches($text, '"cwd":"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
        $text = $text.Replace('"cwd":"' + $c + '"', '"cwd":"' + (($newCwd | ConvertTo-Json -Compress).Trim('"')) + '"')
    }
    $cut = 0; $before = $text.Length
    if ($v['Trim']) { $r = Convert-TrimJsonl $text; $text = $r.Text; $cut = $r.Cut }
    [IO.File]::WriteAllText((Join-Path $slugDir "$newCli.jsonl"), $text, $utf8)
    $j = [IO.File]::ReadAllText($pick.Json.FullName, [Text.Encoding]::UTF8)
    $j = $j.Replace('"' + (Split-Path $srcStore.Parent.FullName -Leaf) + '"', '"' + (Split-Path $store.Parent.FullName -Leaf) + '"').Replace('"' + $srcStore.Name + '"', '"' + $store.Name + '"')
    foreach ($kv in @(@('sessionId', $newLocal), @('cliSessionId', $newCli), @('cwd', $newCwd), @('originCwd', $newCwd), @('title', $v.Title))) {
        $r2 = Set-JsonTopLevelString -Json $j -Key $kv[0] -Value $kv[1]
        if ($r2) { $j = $r2 } else { "  note: top-level '$($kv[0])' not found in the local json" }
    }
    $localPath = Join-Path $store.FullName ($newLocal + '.json')
    [IO.File]::WriteAllText($localPath, $j, $utf8)
    $tests += [pscustomobject]@{ tag = $v.Tag; title = $v.Title; localJson = @($localPath); projectSlugDir = $slugDir; projectFolder = $newCwd }
    "$($v.Tag): '$($v.Title)'; jsonl $([int]($before / 1KB)) KB -> $([int]($text.Length / 1KB)) KB; text blocks trimmed: $cut"
}
[pscustomobject]@{ profile = $ProfileName; tests = $tests } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
'setup done: open the trial profile app, look for the two "S14" chats, open each, send one short message in each. Afterwards: -Action Cleanup (app closed).'
