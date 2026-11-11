# S10 - Google Drive for desktop (DriveFS) semantics the sync store relies on. Writes only under <DriveRoot>\HarnessSync-test\s10\
# and deletes it when done. Windows PowerShell 5.1. -DriveRoot is the "My Drive" folder.
#   (a) tmp + rename: does a reader on the same machine ever see a partial file?
#   (b) opening a freshly written file while DriveFS uploads it: locks? partial data?
#   (c) copy of a 50 MB file to %TEMP%: time and sha
#   (d) writing the same name twice: does a "name (1).ext" appear?
param([Parameter(Mandatory)][string]$DriveRoot, [int]$Renames = 40, [int]$FileMB = 50, [string[]]$Variants = @('MoveItemForce', 'FileReplace', 'MoveFileEx'))
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $DriveRoot -PathType Container)) { throw 'DriveRoot not found' }
$base = Join-Path $DriveRoot 'HarnessSync-test'
$dir = Join-Path $base 's10'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('s10-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir | Out-Null

function Get-Sha([string]$p) {
    $sha = [Security.Cryptography.SHA256]::Create(); $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') } finally { $fs.Dispose(); $sha.Dispose() }
}
try {
    # ---------- (a) tmp + rename, writer in a second process, reader here ----------
    $final = Join-Path $dir 'a-final.bin'
    $size = 2MB
    foreach ($variant in $Variants) { foreach ($withReader in $true, $false) {
    Get-ChildItem $dir -Filter 'a-final.bin*' | Remove-Item -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $tmpDir 'writer.log') -ErrorAction SilentlyContinue
    $writerFile = Join-Path $tmpDir 'writer.ps1'
    [IO.File]::WriteAllText($writerFile, @"
`$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class S10Native { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool MoveFileEx(string a, string b, int f); }'
`$dir = '$($dir -replace "'", "''")'; `$final = Join-Path `$dir 'a-final.bin'; `$ok = 0; `$bad = 0
for (`$i = 1; `$i -le $Renames; `$i++) {
    `$tmp = Join-Path `$dir ('a-final.bin.tmp-' + [guid]::NewGuid().ToString('N'))
    `$bytes = New-Object byte[] $size
    [Array]::Copy([BitConverter]::GetBytes([int]`$i), `$bytes, 4)
    for (`$k = 4; `$k -lt $size - 4; `$k += 4096) { `$bytes[`$k] = [byte](`$i % 251) }
    [Array]::Copy([BitConverter]::GetBytes([int]`$i), 0, `$bytes, $size - 4, 4)     # trailer = same counter as header
    [IO.File]::WriteAllBytes(`$tmp, `$bytes)
    try {
        if ('$variant' -eq 'MoveItemForce') { Move-Item -LiteralPath `$tmp -Destination `$final -Force }
        elseif ('$variant' -eq 'FileReplace') { if (Test-Path -LiteralPath `$final) { [IO.File]::Replace(`$tmp, `$final, [NullString]::Value) } else { [IO.File]::Move(`$tmp, `$final) } }
        else { if (-not [S10Native]::MoveFileEx(`$tmp, `$final, 1)) { throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())) } }
        `$ok++
    }
    catch { `$err = `$_.Exception.GetType().Name + ': ' + (`$_.Exception.Message -replace '[A-Za-z]:\\[^ ]*', '<path>'); Add-Content -LiteralPath '$($tmpDir -replace "'", "''")\writer.log' -Value ('rename ' + `$i + ' failed: ' + `$err); `$bad++ }
    Start-Sleep -Milliseconds 150
}
Add-Content -LiteralPath '$($tmpDir -replace "'", "''")\writer.log' -Value ('renames ok=' + `$ok + ' failed=' + `$bad)
"@)
    $wp = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $writerFile -PassThru -WindowStyle Hidden
    $reads = 0; $partial = 0; $missing = 0; $openErr = 0; $versions = @{}; $errMsgs = @{}
    if (-not $withReader) { [void]$wp.WaitForExit() }
    while ($withReader -and (-not $wp.HasExited -or $reads -lt 5)) {
        $len = -1
        try {
            $fs = [IO.File]::Open($final, 'Open', 'Read', 'ReadWrite')
            try {
                $len = $fs.Length; $buf = New-Object byte[] $len; $n = 0
                while ($n -lt $len) { $r = $fs.Read($buf, $n, $len - $n); if ($r -le 0) { break }; $n += $r }
            } finally { $fs.Dispose() }
            $reads++
            if ($n -ne $size) { $partial++ }
            else {
                $h = [BitConverter]::ToInt32($buf, 0); $t = [BitConverter]::ToInt32($buf, $size - 4)
                if ($h -ne $t) { $partial++ } else { $versions[$h] = 1 }
            }
        } catch [IO.FileNotFoundException] { $missing++ }
        catch { $openErr++; $errMsgs['len=' + $len + ' ' + $_.Exception.GetType().Name + ': ' +($_.Exception.Message -replace '[A-Za-z]:\\[^ ]*', '<path>')] = 1 }
        if ($wp.HasExited -and $reads -ge 5) { break }
    }
    "(a) $variant, reader=$withReader, $Renames renames of a $([int]($size/1MB)) MB file: reads=$reads partial=$partial missing=$missing openErrors=$openErr distinctVersionsSeen=$($versions.Count)"
    $errMsgs.Keys | ForEach-Object { "    open error: $_" }
    if (Test-Path (Join-Path $tmpDir 'writer.log')) { Get-Content (Join-Path $tmpDir 'writer.log') | Where-Object { $_ } | Select-Object -Last 2 | ForEach-Object { "    writer: $_" } }
    "    tmp files left: $(@(Get-ChildItem $dir -Filter 'a-final.bin.tmp-*').Count)"
    } }

    # ---------- (b) open right after write, while DriveFS uploads ----------
    $bFile = Join-Path $dir 'b-fresh.bin'
    $payload = New-Object byte[] ($FileMB * 1MB); (New-Object Random 7).NextBytes($payload)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [IO.File]::WriteAllBytes($bFile, $payload)
    $wMs = $sw.ElapsedMilliseconds
    $rows = @()
    foreach ($mode in 'read-share-none', 'read-share-readwrite', 'write-open') {
        try {
            $access = if ($mode -eq 'write-open') { 'ReadWrite' } else { 'Read' }; $share = if ($mode -eq 'read-share-none') { 'None' } else { 'ReadWrite' }
            $fs = [IO.File]::Open($bFile, 'Open', $access, $share); $len = $fs.Length; $fs.Dispose(); $rows += "$mode=ok(len=$len)"
        } catch { $rows += "$mode=FAIL(" + $_.Exception.GetType().Name + ')' }
    }
    $shaOrig = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload)) -replace '-', '')
    $shaNow = Get-Sha $bFile
    "(b) $FileMB MB write took ${wMs} ms; immediately after: $($rows -join ' ')"
    "    sha of the file read right after the write matches what was written: $($shaNow -eq $shaOrig)"
    try { Move-Item -LiteralPath $bFile -Destination ($bFile + '.renamed') -Force; "    rename right after write: ok" } catch { "    rename right after write: FAIL $($_.Exception.GetType().Name)" }

    # ---------- (c) copy to %TEMP% ----------
    $cFile = Join-Path $dir 'c-50mb.bin'
    [IO.File]::WriteAllBytes($cFile, $payload)
    $copyTimes = @(); $shaOk = 0
    foreach ($try in 1..3) {
        $dst = Join-Path $tmpDir "c-copy-$try.bin"
        $sw = [Diagnostics.Stopwatch]::StartNew(); Copy-Item -LiteralPath $cFile -Destination $dst; $sw.Stop()
        $copyTimes += $sw.ElapsedMilliseconds
        if ((Get-Sha $dst) -eq $shaOrig) { $shaOk++ }
    }
    "(c) copy $FileMB MB from Drive to %TEMP%: ms per try = $($copyTimes -join ', '); sha matches $shaOk/3"
    Start-Sleep -Seconds 15
    $dst = Join-Path $tmpDir 'c-copy-later.bin'
    $sw = [Diagnostics.Stopwatch]::StartNew(); Copy-Item -LiteralPath $cFile -Destination $dst; $sw.Stop()
    "    copy 15 s later (after DriveFS had time to upload): $($sw.ElapsedMilliseconds) ms, sha ok = $((Get-Sha $dst) -eq $shaOrig)"

    # ---------- (d) same name written twice ----------
    $dFile = Join-Path $dir 'd-dup.txt'
    [IO.File]::WriteAllText($dFile, 'first')
    [IO.File]::WriteAllText($dFile, 'second')                                    # overwrite in place
    $tmpA = Join-Path $dir 'd-dup.txt.tmp-1'; [IO.File]::WriteAllText($tmpA, 'third'); Move-Item -LiteralPath $tmpA -Destination $dFile -Force   # replace by rename
    $createdTwice = $true; try { $fs = [IO.File]::Open($dFile, 'CreateNew'); $fs.Dispose() } catch { $createdTwice = $false }
    Start-Sleep -Seconds 20
    $dups = @(Get-ChildItem $dir | Where-Object { $_.Name -match ' \(\d+\)\.' })
    "(d) overwrite twice + replace by rename, waited 20 s: files named 'x (n).ext' = $($dups.Count); content now = '$([IO.File]::ReadAllText($dFile))'; CreateNew on an existing name allowed = $createdTwice"
    "    NOTE: a real duplicate-name conflict needs two machines writing the same name; not testable here."
} finally {
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem -LiteralPath $base -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    "cleanup: test folder gone = $(-not (Test-Path -LiteralPath $dir))"
}
