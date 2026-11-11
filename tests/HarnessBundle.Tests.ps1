$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$core = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Harness.Core.ps1'
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-FileSha256Hex','Get-BytesSha256Hex','Test-BundleEntryName','New-HarnessBundle','Read-ZipEntryBytes','Read-HarnessBundle',
    'ConvertTo-CwdRef','Resolve-CwdRef'))
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fixture = New-TestTempDir
try {
    # --- entry name safety ---
    foreach ($ok in 'manifest.json','native/a.json','native/sub/dir/file.txt','transcript.md') {
        Assert (Test-BundleEntryName $ok) "should accept $ok"
    }
    foreach ($bad in '../evil','native/../../evil','/abs','C:/abs','native\..\evil','\\server\share','','native//x') {
        Assert (-not (Test-BundleEntryName $bad)) "should reject '$bad'"
    }

    # --- create ---
    $src = Join-Path $fixture 'src'
    New-Item -ItemType Directory -Path $src | Out-Null
    [IO.File]::WriteAllText((Join-Path $src 'chat.json'), '{"title":"Sample"}')
    $binPath = Join-Path $src 'blob.bin'
    [IO.File]::WriteAllBytes($binPath, [byte[]](0..255))
    $source = @{
        harness = 'claude'; harnessVersion = '1.0'; profileLabel = 'Work'; machineId = 'm-1'; machineName = 'PC'
        chatId = 'abc'; parentChatId = $null; title = 'Sample'
        cwd = @{ absolute = 'C:\proj'; root = $null; relative = $null }; createdAt = 1; lastActivityAt = 2
    }
    $files = @(
        @{ Role = 'native'; Path = 'native/chat.json'; SourcePath = (Join-Path $src 'chat.json') },
        @{ Role = 'native'; Path = 'native/sub/blob.bin'; SourcePath = $binPath },
        @{ Role = 'transcript'; Path = 'transcript.md'; Content = "# Hello`n" }
    )
    $zip = Join-Path $fixture 'out\x.hbundle.zip'
    $m = New-HarnessBundle -OutPath $zip -Source $source -Files $files -Redaction @{ scanned = $true; findings = 3; transcriptRedacted = $true }
    Assert (Test-Path -LiteralPath $zip) 'zip not created'
    Assert ($m.format -eq 'harness-bundle' -and $m.version -eq 1) 'manifest format/version'
    Assert ($m.chatKey -eq 'claude:abc') "chatKey: $($m.chatKey)"
    Assert ($m.bundleId -match '^[0-9a-f-]{36}$') 'bundleId guid'
    Assert (@($m.files).Count -eq 3) 'files count'
    $bin = @($m.files | Where-Object { $_.path -eq 'native/sub/blob.bin' })[0]
    Assert ($bin.size -eq 256 -and $bin.role -eq 'native' -and $bin.sha256 -eq (Get-FileSha256Hex $binPath)) 'file entry sha/size/role'
    Assert ($m.redaction.findings -eq 3 -and $m.encryption -eq $null) 'redaction/encryption fields'
    Assert ($m.lineage.contentSha256 -match '^[0-9a-f]{64}$' -and $null -eq $m.lineage.previousBundleId) 'lineage'
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $names = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
    Assert ($names -contains 'manifest.json' -and $names -contains 'native/sub/blob.bin') "zip entries: $names"
    Assert (-not (@($names | Where-Object { $_ -like '*\*' }).Count)) 'entry names must use forward slashes'
    $m2 = New-HarnessBundle -OutPath (Join-Path $fixture 'out\y.hbundle.zip') -Source $source -Files $files -PreviousBundleId $m.bundleId
    Assert ($m2.lineage.previousBundleId -eq $m.bundleId -and $m2.lineage.contentSha256 -eq $m.lineage.contentSha256) 'same content same sha, previous id kept'

    # --- read ---
    $dest = Join-Path $fixture 'extract'
    $read = Read-HarnessBundle -Path $zip -ExtractTo $dest
    Assert ($read.chatKey -eq 'claude:abc') 'read manifest'
    Assert ((Get-FileSha256Hex (Join-Path $dest 'native\sub\blob.bin')) -eq $bin.sha256) 'extracted bytes identical'
    Assert (([IO.File]::ReadAllText((Join-Path $dest 'transcript.md'))) -eq "# Hello`n") 'transcript content'

    # --- tamper: sha mismatch ---
    $tamper = Join-Path $fixture 'tamper.zip'
    Copy-Item -LiteralPath $zip -Destination $tamper
    $za = [IO.Compression.ZipFile]::Open($tamper, 'Update')
    try {
        $za.GetEntry('native/chat.json').Delete()
        $e = $za.CreateEntry('native/chat.json'); $w = New-Object IO.StreamWriter($e.Open()); $w.Write('{"title":"Evil"}'); $w.Dispose()
    } finally { $za.Dispose() }
    Assert-Throws { Read-HarnessBundle -Path $tamper -ExtractTo (Join-Path $fixture 'x1') } 'sha256 mismatch must be rejected'

    # --- helper to forge zips ---
    function New-ForgedZip($path, $entries) {
        $fs = [IO.File]::Create($path); $arc = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($k in $entries.Keys) { $en = $arc.CreateEntry($k); $sw = New-Object IO.StreamWriter($en.Open()); $sw.Write($entries[$k]); $sw.Dispose() }
        $arc.Dispose(); $fs.Dispose()
    }
    $goodManifest = '{"format":"harness-bundle","version":1,"bundleId":"b","chatKey":"claude:a","source":{},"files":[],"lineage":{},"redaction":{},"encryption":null}'
    $f1 = Join-Path $fixture 'badformat.zip'
    New-ForgedZip $f1 @{ 'manifest.json' = $goodManifest.Replace('harness-bundle', 'other') }
    Assert-Throws { Read-HarnessBundle -Path $f1 -ExtractTo (Join-Path $fixture 'x2') } 'unknown format must be rejected'
    $f2 = Join-Path $fixture 'badversion.zip'
    New-ForgedZip $f2 @{ 'manifest.json' = $goodManifest.Replace('"version":1', '"version":2') }
    Assert-Throws { Read-HarnessBundle -Path $f2 -ExtractTo (Join-Path $fixture 'x3') } 'unknown version must be rejected'
    $f3 = Join-Path $fixture 'slip.zip'
    New-ForgedZip $f3 @{ 'manifest.json' = $goodManifest; '../evil.txt' = 'x' }
    $slipDest = Join-Path $fixture 'x4'
    Assert-Throws { Read-HarnessBundle -Path $f3 -ExtractTo $slipDest } 'zip-slip entry must be rejected'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'evil.txt'))) 'nothing written outside destination'
    $f4 = Join-Path $fixture 'abs.zip'
    New-ForgedZip $f4 @{ 'manifest.json' = $goodManifest; 'C:/evil.txt' = 'x' }
    Assert-Throws { Read-HarnessBundle -Path $f4 -ExtractTo (Join-Path $fixture 'x5') } 'absolute entry must be rejected'
    $f5 = Join-Path $fixture 'unlisted.zip'
    New-ForgedZip $f5 @{ 'manifest.json' = $goodManifest; 'native/extra.txt' = 'x' }
    Assert-Throws { Read-HarnessBundle -Path $f5 -ExtractTo (Join-Path $fixture 'x6') } 'entry not listed in manifest must be rejected'
    $f6 = Join-Path $fixture 'nomanifest.zip'
    New-ForgedZip $f6 @{ 'native/a.txt' = 'x' }
    Assert-Throws { Read-HarnessBundle -Path $f6 -ExtractTo (Join-Path $fixture 'x7') } 'missing manifest must be rejected'

    $sha = Get-BytesSha256Hex ([Text.Encoding]::UTF8.GetBytes('x'))
    $f7 = Join-Path $fixture 'size.zip'
    New-ForgedZip $f7 @{ 'manifest.json' = $goodManifest.Replace('"files":[]', '"files":[{"role":"native","path":"native/a.txt","size":99,"sha256":"' + $sha + '"}]'); 'native/a.txt' = 'x' }
    Assert-Throws { Read-HarnessBundle -Path $f7 -ExtractTo (Join-Path $fixture 'x8') } 'size mismatch must be rejected'
    $f8 = Join-Path $fixture 'dup.zip'
    $fs = [IO.File]::Create($f8); $arc = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($i in 1, 2) { $en = $arc.CreateEntry('manifest.json'); $sw = New-Object IO.StreamWriter($en.Open()); $sw.Write($goodManifest); $sw.Dispose() }
    $arc.Dispose(); $fs.Dispose()
    Assert-Throws { Read-HarnessBundle -Path $f8 -ExtractTo (Join-Path $fixture 'x9') } 'duplicate entry name must be rejected'

    # --- cwd mapping ---
    $roots = @{ AI_Software = 'H:\AI_Software'; Proj = 'H:\AI_Software\Claude-Code-Desktop-Switcher'; Docs = 'C:\Users\x\Docs\' }
    $r = ConvertTo-CwdRef -Path 'H:\AI_Software\Claude-Code-Desktop-Switcher\src' -PathRoots $roots
    Assert ($r.root -eq 'Proj' -and $r.relative -eq 'src' -and $r.absolute -eq 'H:\AI_Software\Claude-Code-Desktop-Switcher\src') 'longest root wins'
    $r = ConvertTo-CwdRef -Path 'h:\ai_software\Other\deep\dir' -PathRoots $roots
    Assert ($r.root -eq 'AI_Software' -and $r.relative -eq 'Other\deep\dir') 'case-insensitive match'
    $r = ConvertTo-CwdRef -Path 'H:\AI_Software' -PathRoots $roots
    Assert ($r.root -eq 'AI_Software' -and $r.relative -eq '') 'exact root has empty relative'
    $r = ConvertTo-CwdRef -Path 'H:\AI_Software2\x' -PathRoots $roots
    Assert ($null -eq $r.root -and $r.absolute -eq 'H:\AI_Software2\x') 'directory boundary respected'
    $r = ConvertTo-CwdRef -Path 'C:\Users\x\Docs\a' -PathRoots $roots
    Assert ($r.root -eq 'Docs' -and $r.relative -eq 'a') 'trailing slash on root tolerated'
    $r = ConvertTo-CwdRef -Path 'D:\none' -PathRoots @{}
    Assert ($null -eq $r.root) 'no roots'

    $target = @{ AI_Software = 'E:\Work'; Docs = 'D:\Documents' }
    Assert ((Resolve-CwdRef -Ref @{ absolute = 'H:\AI_Software\x\y'; root = 'AI_Software'; relative = 'x\y' } -PathRoots $target) -eq 'E:\Work\x\y') 'resolve with root'
    Assert ((Resolve-CwdRef -Ref @{ absolute = 'H:\AI_Software'; root = 'AI_Software'; relative = '' } -PathRoots $target) -eq 'E:\Work') 'resolve exact root'
    Assert ($null -eq (Resolve-CwdRef -Ref @{ absolute = 'X:\a'; root = 'Unknown'; relative = 'a' } -PathRoots $target)) 'unknown root returns null for the caller to ask'
    Assert ((Resolve-CwdRef -Ref @{ absolute = 'C:\proj'; root = $null; relative = $null } -PathRoots $target) -eq 'C:\proj') 'unrooted keeps absolute'

    Write-Output 'PASS: bundle create/read, sha256, version/format, zip-slip, tamper, cwd mapping.'
} finally {
    Remove-TestTempDir $fixture
}
