# Shared helpers for tests. Dot-source this file, then dot-source the scriptblock
# that Import-TestFunctions returns:
#
#   . (Join-Path $PSScriptRoot '_TestHelper.ps1')
#   . (Import-TestFunctions -Files @($a, $b) -Names @('Foo', 'Bar'))
#
# Returning a scriptblock (instead of defining the functions here) keeps them in the
# caller's scope, which is how the older tests load functions from ClaudeSwitcher.ps1.

function Import-TestFunctions {
    param(
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string[]]$Names
    )
    $found = @{}
    foreach ($file in $Files) {
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count) { throw ("Parse errors in {0}: {1}" -f $file, ($parseErrors | Out-String)) }
        $defs = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($def in $defs) {
            if (($Names -contains $def.Name) -and -not $found.ContainsKey($def.Name)) { $found[$def.Name] = $def.Extent.Text }
        }
    }
    foreach ($name in $Names) { if (-not $found.ContainsKey($name)) { throw "Missing function: $name" } }
    return [scriptblock]::Create((($Names | ForEach-Object { $found[$_] }) -join "`n`n"))
}

function Assert($condition, $message) { if (-not $condition) { throw $message } }

function Assert-Throws([scriptblock]$Block, [string]$Message) {
    $threw = $false
    try { & $Block } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

function New-TestTempDir {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('harness-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestTempDir([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92) + [char]92
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
