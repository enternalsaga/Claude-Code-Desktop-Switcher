$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-ScriptText','Update-InstalledScript')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
# Stands in for the message box: answers with $script:Answer and remembers the question.
function Read-InstallChoice { param([string]$Text) $script:Asked = $Text; return $script:Answer }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claude-install-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$installed = Join-Path $fixture 'ClaudeSwitcher.ps1'
$base      = Join-Path $fixture 'ClaudeSwitcher.base.ps1'
$new       = Join-Path $fixture 'download.ps1'
$conflict  = Join-Path $fixture 'ClaudeSwitcher.conflict.ps1'
function Write-Lines($path, [string[]]$lines) { [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n")) }
function Read-Clean($path) { (Get-ScriptText $path).TrimEnd("`n") -split "`n" }
function Reset-Case {
    Get-ChildItem -LiteralPath $fixture | Remove-Item -Force
    $script:Asked = $null; $script:Answer = 'Cancel'
}
$v1 = 'a', 'b', 'c', 'd', 'e', 'f', 'g'
try {
    # Fresh install: copied, base recorded, no question.
    Reset-Case; Write-Lines $new $v1
    Assert (Update-InstalledScript -New $new -Installed $installed) 'Fresh install refused'
    Assert ((Test-Path $installed) -and (Test-Path $base) -and -not $script:Asked) 'Fresh install incomplete'

    # Untouched install, newer version: replaced silently, backup kept.
    Reset-Case; Write-Lines $installed $v1; Write-Lines $base $v1
    Write-Lines $new ('a', 'B', 'c', 'd', 'e', 'f', 'g')
    Assert (Update-InstalledScript -New $new -Installed $installed) 'Plain update refused'
    Assert (-not $script:Asked) 'Plain update asked a question'
    Assert ((Read-Clean $installed)[1] -ceq 'B') 'Plain update not applied'
    Assert (@(Get-ChildItem $fixture -Filter 'ClaudeSwitcher.ps1.bak-*').Count -eq 1) 'No backup before plain update'

    # Same content, other line endings: nothing to ask.
    Reset-Case; Write-Lines $installed ('x', 'y'); [IO.File]::WriteAllText($new, "x`ny`n")
    Assert (Update-InstalledScript -New $new -Installed $installed) 'Identical copy refused'
    Assert (-not $script:Asked) 'Line endings alone caused a question'

    # Local edit and upstream edit in different places: clean merge, Yes keeps both.
    Reset-Case; Write-Lines $base $v1
    Write-Lines $installed ('a', 'b', 'c', 'd', 'e', 'f', 'LOCAL')
    Write-Lines $new ('UPSTREAM', 'b', 'c', 'd', 'e', 'f', 'g')
    $script:Answer = 'Yes'
    Assert (Update-InstalledScript -New $new -Installed $installed) 'Clean merge refused'
    Assert ($script:Asked -match 'merge cleanly') 'Clean merge not offered'
    $merged = Read-Clean $installed
    Assert ($merged[0] -ceq 'UPSTREAM' -and $merged[6] -ceq 'LOCAL') 'Merged copy lost a side'
    Assert ((Read-Clean $base)[0] -ceq 'UPSTREAM') 'Base not moved to the new version'

    # Clean merge, No: upstream wins, local copy only in the backup.
    Reset-Case; Write-Lines $base $v1
    Write-Lines $installed ('a', 'b', 'c', 'd', 'e', 'f', 'LOCAL')
    Write-Lines $new ('UPSTREAM', 'b', 'c', 'd', 'e', 'f', 'g')
    $script:Answer = 'No'
    Assert (Update-InstalledScript -New $new -Installed $installed) 'Take-new refused'
    Assert ((Read-Clean $installed)[6] -ceq 'g') 'Local edit survived take-new'
    $bak = Get-ChildItem $fixture -Filter 'ClaudeSwitcher.ps1.bak-*' | Select-Object -First 1
    Assert ($bak -and (Read-Clean $bak.FullName)[6] -ceq 'LOCAL') 'Backup missing the local edit'

    # Clean merge, Cancel: nothing changes.
    Reset-Case; Write-Lines $base $v1
    Write-Lines $installed ('a', 'b', 'c', 'd', 'e', 'f', 'LOCAL')
    Write-Lines $new ('UPSTREAM', 'b', 'c', 'd', 'e', 'f', 'g')
    Assert (-not (Update-InstalledScript -New $new -Installed $installed)) 'Cancel did not stop'
    Assert ((Read-Clean $installed)[0] -ceq 'a' -and (Read-Clean $base)[0] -ceq 'a') 'Cancel changed files'

    # Same line edited both ways: conflict file written, Yes keeps the installed copy.
    Reset-Case; Write-Lines $base $v1
    Write-Lines $installed ('a', 'b', 'c', 'MINE', 'e', 'f', 'g')
    Write-Lines $new ('a', 'b', 'c', 'THEIRS', 'e', 'f', 'g')
    $script:Answer = 'Yes'
    Assert (Update-InstalledScript -New $new -Installed $installed) 'Keep-installed refused'
    Assert ($script:Asked -match 'conflict with this version in 1 place') 'Conflict count not reported'
    Assert ((Read-Clean $installed)[3] -ceq 'MINE') 'Installed copy changed on keep'
    $marked = Get-ScriptText $conflict
    Assert ($marked -match '<<<<<<< installed' -and $marked -match 'MINE' -and $marked -match 'THEIRS' -and $marked -match '>>>>>>> this version') 'Conflict file missing markers'
    Assert ((Read-Clean $base)[3] -ceq 'd') 'Base moved although nothing was installed'

    # Edited copy with no record of the last install: asked, never merged.
    Reset-Case
    Write-Lines $installed ('a', 'MINE')
    Write-Lines $new ('a', 'THEIRS')
    $script:Answer = 'No'
    Assert (Update-InstalledScript -New $new -Installed $installed) 'No-base take-new refused'
    Assert ($script:Asked -match 'no record') 'Missing base not explained'
    Assert ((Read-Clean $installed)[1] -ceq 'THEIRS' -and (Test-Path $base)) 'No-base take-new not applied'

    'PASS: fresh install, plain update with backup, line endings ignored, clean merge (yes, no, cancel), conflict file and keep, missing base.'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
