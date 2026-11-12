# S11 - Does a Claude Code chat imported with a different working folder (jsonl under the slug of the NEW cwd, cwd rewritten in the
# local json) show up and open in Claude Desktop? Do the per-line "cwd" fields inside the jsonl have to be rewritten too?
#
#   -Action Setup   : copies one small existing chat of the profile twice, as "S11 TEST A (jsonl cwd kept)" and
#                     "S11 TEST B (jsonl cwd rewritten)", each with its own new ids and its own new project folder.
#   -Action Cleanup : removes everything Setup created (reads %TEMP%\harness-spike\S11\manifest.json).
# Adds only new files: a local_*.json per test chat in the profile's session store, a <cli>.jsonl under ~\.claude\projects\<new slug>\,
# and an empty project folder. Refuses to run while the profile's app is open. Nothing existing is modified or deleted.
param(
    [Parameter(Mandatory)][ValidateSet('Setup', 'Cleanup')][string]$Action,
    [string]$ProfileName = 'S11test',        # the trial profile that receives the test chats
    [string]$SourceProfile = 'Account 2',    # where the small real chat is copied from (read only)
    [string]$ProjectRoot = (Join-Path $env:TEMP 'harness-spike\S11')   # where the two empty project folders are created (S11-test-A, S11-test-B)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stateDir = Join-Path ([IO.Path]::GetTempPath()) 'harness-spike\S11'
$manifestPath = Join-Path $stateDir 'manifest.json'
$profileDir = Join-Path $env:LOCALAPPDATA ('ClaudeProfile-' + $ProfileName)
if (-not (Test-Path -LiteralPath $profileDir)) { throw "profile folder not found: $ProfileName" }

function Test-ProfileRunning {
    $esc = [regex]::Escape($profileDir)
    return (@(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Where-Object { $_.CommandLine -match $esc -and $_.CommandLine -notmatch '--type=' }).Count -gt 0)
}
if (Test-ProfileRunning) { throw "The app of profile '$ProfileName' is running. Close it (not the other Claude windows), then run again." }

# Set-JsonTopLevelString and ConvertTo-ClaudeProjectSlug come from the repo, loaded by AST (no switcher start).
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
        if ($t.projectFolder -and (Test-Path -LiteralPath $t.projectFolder) -and @(Get-ChildItem -LiteralPath $t.projectFolder -Force).Count -eq 0) { Remove-Item -LiteralPath $t.projectFolder -Force; "removed project folder $($t.projectFolder)" }
    }
    Remove-Item -LiteralPath $stateDir -Recurse -Force
    'cleanup done'
    return
}

# ---- Setup ----
if (Test-Path -LiteralPath $manifestPath) { throw 'A previous Setup is still in place. Run -Action Cleanup first.' }
$store = Get-ChildItem -LiteralPath (Join-Path $profileDir 'claude-code-sessions') -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $store) { throw 'profile has no session store (not signed in?)' }

# a small real chat whose jsonl exists, is below 400 KB and has no <cli>\ folder
$srcDir = Join-Path $env:LOCALAPPDATA ('ClaudeProfile-' + $SourceProfile)
$srcStore = Get-ChildItem -LiteralPath (Join-Path $srcDir 'claude-code-sessions') -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1     # read only: nothing is written to the source profile
if (-not $srcStore) { throw 'source profile has no session store' }
$pick = $null
foreach ($f in (Get-ChildItem -LiteralPath $srcStore.FullName -File -Filter 'local_*.json')) {
    try { $d = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    if (-not $d.cliSessionId -or -not $d.cwd) { continue }
    $slug = ConvertTo-ClaudeProjectSlug $d.cwd
    $jl = Join-Path $projects "$slug\$($d.cliSessionId).jsonl"
    if (-not (Test-Path -LiteralPath $jl)) { continue }
    $sz = (Get-Item -LiteralPath $jl).Length
    if ($sz -lt 20KB -or $sz -gt 400KB -or (Test-Path -LiteralPath (Join-Path $projects "$slug\$($d.cliSessionId)"))) { continue }
    if (-not $pick -or $sz -lt $pick.Size) { $pick = [pscustomobject]@{ Json = $f; Data = $d; Jsonl = $jl; Size = $sz } }
}
if (-not $pick) { throw 'no suitable small chat found' }
$origCwd = [string]$pick.Data.cwd; $origCli = [string]$pick.Data.cliSessionId
"source chat: jsonl $([int]($pick.Size/1KB)) KB, local json $([int]($pick.Json.Length/1KB)) KB (content stays on this machine)"

New-Item -ItemType Directory -Force $stateDir | Out-Null
$tests = @()
foreach ($v in @(@{ Tag = 'A'; Title = 'S11 TEST A (jsonl cwd kept)'; Rewrite = $false }, @{ Tag = 'B'; Title = 'S11 TEST B (jsonl cwd rewritten)'; Rewrite = $true })) {
    $newCwd = (Join-Path $ProjectRoot ('S11-test-' + $v.Tag)).TrimEnd('\')
    $newCli = [guid]::NewGuid().ToString()
    $newLocal = 'local_' + [guid]::NewGuid().ToString()
    New-Item -ItemType Directory -Force $newCwd | Out-Null
    # jsonl under the slug of the new cwd
    $slugDir = Join-Path $projects (ConvertTo-ClaudeProjectSlug $newCwd)
    if (Test-Path -LiteralPath $slugDir) { throw "slug folder already exists: $slugDir" }
    New-Item -ItemType Directory -Path $slugDir | Out-Null
    $text = [IO.File]::ReadAllText($pick.Jsonl, [Text.Encoding]::UTF8).Replace($origCli, $newCli)
    # the cwd written on the jsonl lines can differ from the local json's cwd (the chat may have changed folder), so read them from the lines
    $lineCwds = @([regex]::Matches($text, '"cwd":"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $oldCounts = ([regex]::Matches($text, '"cwd":"')).Count
    if ($v.Rewrite) { foreach ($c in $lineCwds) { $text = $text.Replace('"cwd":"' + $c + '"', '"cwd":"' + (($newCwd | ConvertTo-Json -Compress).Trim('"')) + '"') } }
    [IO.File]::WriteAllText((Join-Path $slugDir "$newCli.jsonl"), $text, $utf8)
    # local json: new ids, new cwd (top-level cwd / originCwd only), new title; every other byte kept
    $j = [IO.File]::ReadAllText($pick.Json.FullName, [Text.Encoding]::UTF8)
    # the same account/org swap Copy-CodeSession does: whole JSON string values only
    $j = $j.Replace('"' + (Split-Path $srcStore.Parent.FullName -Leaf) + '"', '"' + (Split-Path $store.Parent.FullName -Leaf) + '"').Replace('"' + $srcStore.Name + '"', '"' + $store.Name + '"')
    foreach ($kv in @(@('sessionId', $newLocal), @('cliSessionId', $newCli), @('cwd', $newCwd), @('originCwd', $newCwd), @('title', $v.Title))) {
        $r = Set-JsonTopLevelString -Json $j -Key $kv[0] -Value $kv[1]
        if ($r) { $j = $r } else { "  note: top-level '$($kv[0])' not found in the local json" }
    }
    $localPath = Join-Path $store.FullName ($newLocal + '.json')
    [IO.File]::WriteAllText($localPath, $j, $utf8)
    $tests += [pscustomobject]@{ tag = $v.Tag; title = $v.Title; localJson = @($localPath); projectSlugDir = $slugDir; projectFolder = $newCwd; jsonlCwdFieldsInSource = $oldCounts; jsonlRewritten = $v.Rewrite }
    "test $($v.Tag): '$($v.Title)'; folder $newCwd; jsonl under $(Split-Path -Leaf $slugDir); cwd occurrences in the jsonl text: $oldCounts, rewritten: $($v.Rewrite)"
}
[pscustomobject]@{ profile = $ProfileName; tests = $tests } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
'setup done: open the profile app and look for the two "S11 TEST" chats. Afterwards: -Action Cleanup (with the app closed).'
