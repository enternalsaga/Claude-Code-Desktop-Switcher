$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-SessionActivity','Get-SessionActivityAt','Read-ChatJson','Test-TitleNeedsSync','Set-JsonTopLevelString','Copy-CodeSession')) {
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

    Write-Chat $to 'Newer' 3000 'target-account' 'target-org'
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'exists') 'Newer target overwritten'
    Assert ((Read-Target).lastActivityAt -eq 3000) 'Newer target changed'

    Write-Chat $to 'Newer' 2000 'target-account' 'target-org'
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'exists') 'Equal copy overwritten'

    # Renamed in the source only: a current target copy takes the new title, nothing else.
    $nested = '{"title":"Old name","spawnedFrom":{"title":"Parent"},"account":"target-account","lastActivityAt":3000,"note":"a \"quoted\" title"}'
    [IO.File]::WriteAllText((Join-Path $to 'local_chat.json'), $nested)
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'renamed') 'Rename not detected'
    $t = Read-Target
    Assert ($t.title -ceq 'Newer' -and $t.spawnedFrom.title -ceq 'Parent' -and $t.lastActivityAt -eq 3000 -and $t.note -ceq 'a "quoted" title') 'Rename touched more than the top-level title'
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'exists') 'Rename repeated'

    # Renamed in the target after the source's name: previousTitles holds it, so keep.
    [IO.File]::WriteAllText((Join-Path $to 'local_chat.json'), '{"title":"Target name","previousTitles":["Newer"],"lastActivityAt":3000}')
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'exists') 'Later target rename overwritten'
    Assert ((Read-Target).title -ceq 'Target name') 'Later target rename changed'

    # Unicode titles survive the rewrite.
    Write-Chat $from ('T' + [char]0x00EA + 'n m' + [char]0x1EDB + 'i') 2000 'source-account' 'source-org'
    [IO.File]::WriteAllText((Join-Path $to 'local_chat.json'), '{"title":"Old","lastActivityAt":3000}')
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'renamed') 'Unicode rename not applied'
    Assert ((Read-Target).title -ceq ('T' + [char]0x00EA + 'n m' + [char]0x1EDB + 'i')) 'Unicode title mangled'

    Assert (Test-TitleNeedsSync 'A' 'B' $null) 'Plain rename not flagged'
    Assert (-not (Test-TitleNeedsSync 'A' 'A' $null)) 'Same title flagged'
    Assert (-not (Test-TitleNeedsSync '' 'B' $null)) 'Empty source title flagged'
    Write-Chat $from 'Newer' 2000 'source-account' 'source-org'

    # No lastActivityAt on either side: the file times decide.
    Write-Chat $from 'NoStampNew' $null 'source-account' 'source-org'
    Write-Chat $to 'NoStampOld' $null 'target-account' 'target-org'
    (Get-Item -LiteralPath (Join-Path $to 'local_chat.json')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)
    $src = Get-Item -LiteralPath (Join-Path $from 'local_chat.json')
    $session = [pscustomobject]@{ File = $src; Account = 'source-account'; Org = 'source-org'; Activity = (Get-SessionActivity $null $src) }
    Assert ((Copy-CodeSession -Session $session -Store $store) -eq 'updated') 'File time fallback did not update'

    Remove-Item -LiteralPath (Join-Path $to 'local_chat.json')
    Assert ((Copy-CodeSession -Session (Get-Source 2000) -Store $store) -eq 'copied') 'Missing target not copied'

    'PASS: newer source updates with identity rewritten, newer or equal target kept, rename synced (top-level only, unicode), later target rename kept, file time fallback, plain copy.'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
