$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-SessionActivity','Get-SessionActivityAt','Copy-CodeSession')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claude-update-test-' + [guid]::NewGuid().ToString('N'))
$from = Join-Path $fixture 'src\source-account\source-org'
$to   = Join-Path $fixture 'dst\target-account\target-org'
New-Item -ItemType Directory -Path $from, $to -Force | Out-Null
$store = Get-Item -LiteralPath $to
function Write-Chat($dir, $title, $at, $account, $org) {
    $json = '{"title":"' + $title + '","account":"' + $account + '","org":"' + $org + '"' + $(if ($null -ne $at) { ',"lastActivityAt":' + $at }) + '}'
    [IO.File]::WriteAllText((Join-Path $dir 'local_chat.json'), $json)
}
function Get-Source($at) {
    $file = Get-Item -LiteralPath (Join-Path $from 'local_chat.json')
    [pscustomobject]@{ File = $file; Account = 'source-account'; Org = 'source-org'; Activity = $at }
}
function Read-Target { Get-Content -LiteralPath (Join-Path $to 'local_chat.json') -Raw | ConvertFrom-Json }
try {
    Write-Chat $from 'Newer' 2000 'source-account' 'source-org'
    Write-Chat $to 'Older' 1000 'target-account' 'target-org'
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'updated') 'Newer source not reported as updated'
    $t = Read-Target
    Assert ($t.title -eq 'Newer' -and $t.account -eq 'target-account' -and $t.org -eq 'target-org') 'Update did not rewrite identity'

    Write-Chat $to 'Ahead' 3000 'target-account' 'target-org'
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'exists') 'Newer target overwritten'
    Assert ((Read-Target).title -eq 'Ahead') 'Newer target changed'

    Write-Chat $to 'Same' 2000 'target-account' 'target-org'
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'exists') 'Equal copy overwritten'

    # No lastActivityAt on either side: the file times decide.
    Write-Chat $from 'NoStampNew' $null 'source-account' 'source-org'
    Write-Chat $to 'NoStampOld' $null 'target-account' 'target-org'
    (Get-Item -LiteralPath (Join-Path $to 'local_chat.json')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)
    $src = Get-Item -LiteralPath (Join-Path $from 'local_chat.json')
    $session = [pscustomobject]@{ File = $src; Account = 'source-account'; Org = 'source-org'; Activity = (Get-SessionActivity $null $src) }
    Assert ((Copy-CodeSession -Session $session -Store $store) -eq 'updated') 'File time fallback did not update'

    Remove-Item -LiteralPath (Join-Path $to 'local_chat.json')
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'copied') 'Missing target not copied'

    'PASS: newer source updates with identity rewritten, newer or equal target kept, file time fallback, plain copy.'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
