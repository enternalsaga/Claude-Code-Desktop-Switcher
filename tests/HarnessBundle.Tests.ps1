$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$core = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Harness.Core.ps1'
. (Import-TestFunctions -Files @($core) -Names @(
    'Get-SecretPatterns','Invoke-SecretScan','Protect-TranscriptText','Get-FileSha256Hex','Get-BytesSha256Hex','Test-BundleEntryName','New-HarnessBundle','Read-ZipEntryBytes','Read-HarnessBundle','Get-HarnessBundleLimits','Copy-ZipEntryChecked',
    'ConvertTo-CwdRef','Resolve-CwdRef','Get-HarnessMachineInfo','Get-HarnessPathRoots'))
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

    # --- H1a: limits, streaming, all-or-nothing extraction ---
    function Assert-NoExtract($dest, $why) {
        Assert (-not (Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath ($dest + '.part'))) "nothing left behind: $why"
    }
    function Assert-BundleLimit($zipPath, $dest, $why, $limits = @{}) {
        $msg = $null
        try { [void](Read-HarnessBundle -Path $zipPath -ExtractTo $dest -Limits $limits) } catch { $msg = $_.Exception.Message }
        Assert ($msg -like '*bundle-limit*') "$why must throw bundle-limit, got: $msg"
        Assert-NoExtract $dest $why
    }
    $bombBytes = New-Object byte[] (10MB)
    $bombSha = Get-BytesSha256Hex $bombBytes
    $bombManifest = $goodManifest.Replace('"files":[]', '"files":[{"role":"native","path":"native/zeros.bin","size":10485760,"sha256":"' + $bombSha + '"}]')
    $bomb = Join-Path $fixture 'bomb.zip'
    $fs = [IO.File]::Create($bomb); $arc = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    $en = $arc.CreateEntry('manifest.json'); $sw = New-Object IO.StreamWriter($en.Open()); $sw.Write($bombManifest); $sw.Dispose()
    $en = $arc.CreateEntry('native/zeros.bin', [IO.Compression.CompressionLevel]::Optimal); $es = $en.Open(); $es.Write($bombBytes, 0, $bombBytes.Length); $es.Dispose()
    $arc.Dispose(); $fs.Dispose()
    Assert-BundleLimit $bomb (Join-Path $fixture 'xb1') 'zip bomb (ratio)'

    $many = Join-Path $fixture 'many.zip'
    $fs = [IO.File]::Create($many); $arc = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    $en = $arc.CreateEntry('manifest.json'); $sw = New-Object IO.StreamWriter($en.Open()); $sw.Write($goodManifest); $sw.Dispose()
    foreach ($i in 1..20000) { [void]$arc.CreateEntry("native/f$i.txt") }
    $arc.Dispose(); $fs.Dispose()
    Assert-BundleLimit $many (Join-Path $fixture 'xb2') '20,001 entries'

    $fatManifest = Join-Path $fixture 'fatmanifest.zip'
    New-ForgedZip $fatManifest @{ 'manifest.json' = $goodManifest.Replace('"encryption":null', '"encryption":null,"pad":"' + ('a' * 2MB) + '"') }
    Assert-BundleLimit $fatManifest (Join-Path $fixture 'xb3') 'manifest over 1 MiB'

    # the declared size in the manifest is a ceiling for what is read, whatever the zip header says
    $lie = Join-Path $fixture 'lie.zip'
    $liar = $goodManifest.Replace('"files":[]', '"files":[{"role":"native","path":"native/a.txt","size":10,"sha256":"' + $sha + '"}]')
    New-ForgedZip $lie @{ 'manifest.json' = $liar; 'native/a.txt' = ('x' * 5000) }
    Assert-BundleLimit $lie (Join-Path $fixture 'xb4') 'entry larger than the manifest says'

    # total uncompressed cap (limit lowered through -Limits)
    Assert-BundleLimit $zip (Join-Path $fixture 'xb5') 'total size over the cap' @{ MaxTotalBytes = 100 }

    # a bad entry late in the bundle must not leave earlier entries behind
    $late = Join-Path $fixture 'late.zip'
    $shaA = Get-BytesSha256Hex ([Text.Encoding]::UTF8.GetBytes('aaa'))
    $lateManifest = $goodManifest.Replace('"files":[]', '"files":[{"role":"native","path":"native/a.txt","size":3,"sha256":"' + $shaA + '"},{"role":"native","path":"native/b.txt","size":3,"sha256":"' + $shaA + '"}]')
    New-ForgedZip $late @{ 'manifest.json' = $lateManifest; 'native/a.txt' = 'aaa'; 'native/b.txt' = 'bbb' }
    $lateDest = Join-Path $fixture 'xb6'
    Assert-Throws { Read-HarnessBundle -Path $late -ExtractTo $lateDest } 'sha mismatch on the second file'
    Assert-NoExtract $lateDest 'late sha mismatch'
    [void](Read-HarnessBundle -Path $zip -ExtractTo (Join-Path $fixture 'xb7'))
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'xb7.part'))) 'no .part folder after a good extract'

    # ExtractTo that already exists: a non-empty folder or a file is refused (no prompt), an empty folder is used
    $full = Join-Path $fixture 'xc1'
    New-Item -ItemType Directory -Path $full | Out-Null
    [IO.File]::WriteAllText((Join-Path $full 'keep.txt'), 'x')
    $msg = $null; try { [void](Read-HarnessBundle -Path $zip -ExtractTo $full) } catch { $msg = $_.Exception.Message }
    Assert ($msg -like 'Extract target exists*') "non-empty ExtractTo must throw: $msg"
    Assert ((Test-Path -LiteralPath (Join-Path $full 'keep.txt')) -and -not (Test-Path -LiteralPath ($full + '.part'))) 'non-empty ExtractTo untouched, no .part'
    $asFile = Join-Path $fixture 'xc2'
    [IO.File]::WriteAllText($asFile, 'x')
    $msg = $null; try { [void](Read-HarnessBundle -Path $zip -ExtractTo $asFile) } catch { $msg = $_.Exception.Message }
    Assert ($msg -like 'Extract target exists*' -and (Test-Path -LiteralPath $asFile -PathType Leaf) -and -not (Test-Path -LiteralPath ($asFile + '.part'))) 'file as ExtractTo must throw'
    $empty = Join-Path $fixture 'xc3'
    New-Item -ItemType Directory -Path $empty | Out-Null
    [void](Read-HarnessBundle -Path $zip -ExtractTo $empty)
    Assert (Test-Path -LiteralPath (Join-Path $empty 'transcript.md')) 'empty ExtractTo folder is filled'

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

    # --- H1b: all-or-nothing write, size cap ---
    $outB = Join-Path $fixture 'outb'
    $bad2 = @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'ok' }, @{ Role = 'native'; Path = 'native/missing.bin'; SourcePath = (Join-Path $fixture 'no-such-file') })
    Assert-Throws { New-HarnessBundle -OutPath (Join-Path $outB 'a.zip') -Source $source -Files $bad2 } 'missing second source must fail'
    Assert (-not (Test-Path -LiteralPath (Join-Path $outB 'a.zip')) -and -not (Test-Path -LiteralPath (Join-Path $outB 'a.zip.tmp'))) 'failed build leaves no OutPath and no tmp'

    # the final move fails (OutPath is a non-empty folder): the tmp file must not stay behind
    $blocked = Join-Path $outB 'blocked.zip'
    New-Item -ItemType Directory -Path $blocked -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $blocked 'keep.txt'), 'x')
    Assert-Throws { New-HarnessBundle -OutPath $blocked -Source $source -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' }) } 'blocked OutPath must fail'
    Assert (-not (Test-Path -LiteralPath ($blocked + '.tmp'))) 'tmp removed after a failed final move'
    Assert (Test-Path -LiteralPath (Join-Path $blocked 'keep.txt')) 'the blocking folder is untouched'

    # an existing bundle is replaced, and the cap is checked before anything is written
    $rep = Join-Path $outB 'rep.zip'
    [IO.File]::WriteAllText($rep, 'old')
    [void](New-HarnessBundle -OutPath $rep -Source $source -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' }))
    Assert ((Read-HarnessBundle -Path $rep -ExtractTo (Join-Path $fixture 'xrep')).chatKey -eq 'claude:abc') 'existing OutPath replaced by a valid bundle'
    $big = Join-Path $fixture 'big.bin'
    [IO.File]::WriteAllBytes($big, (New-Object byte[] 4096))
    $capOut = Join-Path $outB 'cap.zip'
    $thrown = $null
    try { [void](New-HarnessBundle -OutPath $capOut -Source $source -Files @(@{ Role = 'native'; Path = 'native/big.bin'; SourcePath = $big }) -MaxBytes 1000) } catch { $thrown = $_.Exception.Message }
    Assert ($thrown -like '*bundle-too-large*') "over the cap must throw bundle-too-large: $thrown"
    Assert (-not (Test-Path -LiteralPath $capOut) -and -not (Test-Path -LiteralPath ($capOut + '.tmp'))) 'nothing written when over the cap'
    $thrown = $null
    try { [void](New-HarnessBundle -OutPath $capOut -Source $source -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = ('z' * 2000) }) -MaxBytes 1000) } catch { $thrown = $_.Exception.Message }
    Assert ($thrown -like '*bundle-too-large*') 'inline content counts toward the cap too'

    # --- H1e: machine info and default path roots come from the Sync functions when they exist ---
    $mi = Get-HarnessMachineInfo
    Assert ($null -eq $mi.Id -and $null -eq $mi.Name -and (Get-HarnessPathRoots).Count -eq 0) 'no Sync functions: empty values'
    $blank = @{ harness = 'claude'; chatId = 'zz'; title = 't'; cwd = @{ absolute = 'C:\proj'; root = $null; relative = $null }; machineId = $null; machineName = '' }
    $mm = New-HarnessBundle -OutPath (Join-Path $fixture 'out\nosync.zip') -Source $blank -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' })
    Assert (-not $mm.source.machineId -and -not $mm.source.machineName) 'no Sync functions: manifest machine fields stay empty'
    Assert ($null -eq (ConvertTo-CwdRef -Path 'H:\Fake\a\b').root) 'no Sync functions: no default roots'

    function Get-SyncMachine { [pscustomobject]@{ Id = 'fake-machine-id'; Name = 'FAKEPC' } }
    function Get-SyncPathRoots { @{ Fake = 'H:\Fake' } }
    try {
        $mm = New-HarnessBundle -OutPath (Join-Path $fixture 'out\sync.zip') -Source $blank -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' })
        Assert ($mm.source.machineId -eq 'fake-machine-id' -and $mm.source.machineName -eq 'FAKEPC') 'blank machine fields are filled from Get-SyncMachine'
        Assert ($null -eq $blank.machineId) 'the caller hashtable is not modified'
        $kept = New-HarnessBundle -OutPath (Join-Path $fixture 'out\kept.zip') -Source $source -Files @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = 'x' })
        Assert ($kept.source.machineId -eq 'm-1' -and $kept.source.machineName -eq 'PC') 'values given by the caller win'
        $dr = ConvertTo-CwdRef -Path 'H:\Fake\a\b'
        Assert ($dr.root -eq 'Fake' -and $dr.relative -eq 'a\b') 'default roots used when PathRoots is not given'
        Assert ($null -eq (ConvertTo-CwdRef -Path 'H:\Fake\a' -PathRoots @{ Other = 'D:\o' }).root) 'explicit PathRoots are not mixed with the defaults'
    } finally { Remove-Item Function:\Get-SyncMachine, Function:\Get-SyncPathRoots }

    # --- H1c: a ref that came from another machine is never trusted ---
    foreach ($badRel in '..\..\Windows', 'a\..\..\b', 'C:\x', "a`nb", '\x', 'a:b', '..', "a`0b") {
        Assert ($null -eq (Resolve-CwdRef -Ref @{ absolute = 'H:\AI_Software\x'; root = 'AI_Software'; relative = $badRel } -PathRoots $target)) "relative '$badRel' must be refused"
    }
    foreach ($badAbs in 'rel\path', '', "C:\a`nb", "C:\a`tb", '\\', 'C:') {
        Assert ($null -eq (Resolve-CwdRef -Ref @{ absolute = $badAbs; root = $null; relative = $null } -PathRoots $target)) "absolute '$badAbs' must be refused"
    }
    Assert ((Resolve-CwdRef -Ref @{ absolute = '\\srv\share\p'; root = $null; relative = $null } -PathRoots $target) -eq '\\srv\share\p') 'UNC absolute accepted'
    Assert ((Resolve-CwdRef -Ref @{ absolute = 'H:\a'; root = 'AI_Software'; relative = 'x.y\z w' } -PathRoots $target) -eq 'E:\Work\x.y\z w') 'dots and spaces inside a segment are fine'

    Write-Output 'PASS: bundle create/read, sha256, version/format, zip-slip, tamper, cwd mapping.'
} finally {
    Remove-TestTempDir $fixture
}
