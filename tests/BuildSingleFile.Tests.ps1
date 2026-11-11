$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root 'tools\Build-SingleFile.ps1'

$fixture = New-TestTempDir
try {
    $src = Join-Path $fixture 'src'
    New-Item -ItemType Directory -Path $src | Out-Null
    [IO.File]::WriteAllText((Join-Path $src 'Harness.Core.ps1'), "function Core-One { 'one' }`r`n")
    [IO.File]::WriteAllText((Join-Path $src 'Harness.Claude.ps1'), "function Claude-One { 'two' }`r`n")
    [IO.File]::WriteAllText((Join-Path $src 'Ui.Harness.ps1'), "function Ui-One { 'three' }`r`n")
    [IO.File]::WriteAllText((Join-Path $src 'Zzz.Extra.ps1'), "function Extra-One { 'four' }`r`n")
    $script = Join-Path $fixture 'ClaudeSwitcher.ps1'
    $text = @(
        'param()', 'function Before-Marker { 1 }',
        '# >>> harness-src',
        '$srcDir = Join-Path $PSScriptRoot ''src''',
        'foreach ($f in Get-ChildItem (Join-Path $srcDir ''*.ps1'')) { . $f.FullName }',
        '# <<< harness-src',
        'function After-Marker { 2 }'
    ) -join "`r`n"
    [IO.File]::WriteAllText($script, $text)
    $out = Join-Path $fixture 'dist\ClaudeSwitcher.ps1'

    & $build -Script $script -SrcDir $src -OutPath $out | Out-Null
    Assert (Test-Path -LiteralPath $out) 'dist file not written'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($out, [ref]$null, [ref]$errors)
    Assert (-not $errors.Count) "dist does not parse: $($errors | Out-String)"
    $names = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    foreach ($n in 'Before-Marker', 'Core-One', 'Claude-One', 'Ui-One', 'Extra-One', 'After-Marker') { Assert ($names -contains $n) "dist lacks function $n" }
    $built = [IO.File]::ReadAllText($out)
    Assert ($built -notmatch '(?m)^\s*\.\s.*src') 'dist still dot-sources src\'
    Assert ($built -notmatch 'Get-ChildItem \(Join-Path \$srcDir') 'dist still contains the hook body'
    Assert ($built.Contains('# >>> harness-src') -and $built.Contains('# <<< harness-src')) 'markers must survive (idempotent rebuild)'
    $order = @('Core-One', 'Claude-One', 'Ui-One', 'Extra-One') | ForEach-Object { $built.IndexOf($_) }
    Assert (($order -join ',') -eq (($order | Sort-Object) -join ',')) 'fixed order: core, claude, ui, then the rest'
    Assert ($built.IndexOf('Before-Marker') -lt $built.IndexOf('Core-One') -and $built.IndexOf('Core-One') -lt $built.IndexOf('After-Marker')) 'block is inserted at the markers'

    # a built file can be built again from the source script, with the same result
    & $build -Script $script -SrcDir $src -OutPath $out | Out-Null
    Assert ([IO.File]::ReadAllText($out) -eq $built) 'rebuild is deterministic'

    $bad = Join-Path $fixture 'nomarker.ps1'
    [IO.File]::WriteAllText($bad, 'param()')
    Assert-Throws { & $build -Script $bad -SrcDir $src -OutPath (Join-Path $fixture 'o2.ps1') } 'missing markers must fail'

    # the real script: its hook block is replaced and the result still parses with every adapter function
    $real = Join-Path $fixture 'real\ClaudeSwitcher.ps1'
    & $build -Script (Join-Path $root 'ClaudeSwitcher.ps1') -OutPath $real | Out-Null
    $errors = $null
    $realAst = [Management.Automation.Language.Parser]::ParseFile($real, [ref]$null, [ref]$errors)
    Assert (-not $errors.Count) "real dist does not parse: $($errors | Out-String)"
    $realNames = @($realAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    foreach ($n in 'Register-Harnesses', 'Register-ClaudeHarness', 'Show-HarnessExportDialog', 'Copy-CodeSession') { Assert ($realNames -contains $n) "real dist lacks $n" }
    $realText = [IO.File]::ReadAllText($real)
    Assert ($realText -notmatch 'Get-ChildItem -LiteralPath "\$PSScriptRoot\\src"') 'real dist still dot-sources src\'
    $src = [IO.File]::ReadAllText((Join-Path $root 'ClaudeSwitcher.ps1'))
    foreach ($tag in 'harness-src', 'harness-register', 'harness-install', 'harness-ui-menu', 'harness-ui-tray') {
        Assert ($src.Contains("# >>> $tag") -and $src.Contains("# <<< $tag")) "hook block $tag missing in ClaudeSwitcher.ps1"
    }

    Write-Output 'PASS: single-file build parses, has every function, drops the dot-source hook, keeps order.'
} finally {
    Remove-TestTempDir $fixture
}
