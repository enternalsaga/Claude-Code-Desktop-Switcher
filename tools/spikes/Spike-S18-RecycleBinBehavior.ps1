# Spike S18: what does Microsoft.VisualBasic FileSystem.DeleteFile(..., OnlyErrorDialogs, SendToRecycleBin) really do for
#   (a) a small file on the system drive, (b) a file larger than the drive's Recycle Bin quota, (c) a file on a Google Drive (DriveFS) drive.
# Only junk files this script creates (in %TEMP%\harness-spike\S18 and <My Drive>\HarnessSync-test\s18) are deleted, and the junk that
# lands in the Recycle Bin is removed again by its own $I/$R pair. Nothing is read from or written to real data. No volume ids or
# drive letters are printed. -DriveRoot is optional: the "My Drive" folder of a DriveFS drive.
param([string]$DriveRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class S18Native {
  [StructLayout(LayoutKind.Sequential)] public struct SHQUERYRBINFO { public int cbSize; public long i64Size; public long i64NumItems; }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SHQueryRecycleBin(string root, ref SHQUERYRBINFO info);
}
'@
function Get-Bin([string]$Root) { $i = New-Object S18Native+SHQUERYRBINFO; $i.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($i); $rc = [S18Native]::SHQueryRecycleBin($Root, [ref]$i); [pscustomobject]@{ Rc = $rc; Items = $i.i64NumItems; Bytes = $i.i64Size } }
function Get-Quota([string]$Letter) {
    $vol = (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue)
    if (-not $vol) { return $null }
    $guid = ($vol.UniqueId -replace '^.*(\{[^}]+\}).*$', '$1')
    $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$guid"
    if (-not (Test-Path $k)) { return [pscustomobject]@{ MaxMB = $null; Nuke = $null; Key = 'none' } }
    $p = Get-ItemProperty $k; return [pscustomobject]@{ MaxMB = $p.MaxCapacity; Nuke = $p.NukeOnDelete; Key = 'found' }
}
function Remove-OwnBinEntry([string]$Letter, [string]$OriginalPath) {   # removes only the $I/$R pair whose recorded original path is ours
    $bin = "${Letter}:\`$Recycle.Bin"; if (-not (Test-Path -LiteralPath $bin -ErrorAction SilentlyContinue)) { return 0 }
    $n = 0
    foreach ($i in (Get-ChildItem -LiteralPath $bin -Recurse -Force -File -Filter '$I*' -ErrorAction SilentlyContinue)) {
        $bytes = $null; try { $bytes = [IO.File]::ReadAllBytes($i.FullName) } catch { continue }; if ($bytes.Length -lt 28) { continue }
        # $I layout: version(8) size(8) deleted-at(8); version 2 then has a 4-byte character count before the path, version 1 does not
        $skip = $(if ([BitConverter]::ToInt64($bytes, 0) -eq 2) { 28 } else { 24 })
        $orig = [Text.Encoding]::Unicode.GetString($bytes, $skip, $bytes.Length - $skip).TrimEnd([char]0)
        if ($orig -ieq $OriginalPath) {
            $n++      # counted when found; removal is best effort (a Drive for desktop drive can drop the entry by itself)
            $r = Join-Path $i.DirectoryName ('$R' + $i.Name.Substring(2))
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $i.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $n
}
function Test-Recycle([string]$Label, [string]$Path, [scriptblock]$Make) {
    $letter = $Path.Substring(0, 1)
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    & $Make $Path
    $before = Get-Bin "${letter}:\"
    $err = $null
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { $err = $_.Exception.GetType().Name + ': ' + $_.Exception.Message }
    Start-Sleep -Milliseconds 500
    $after = Get-Bin "${letter}:\"
    $gone = -not (Test-Path -LiteralPath $Path)
    $own = Remove-OwnBinEntry $letter $Path
    "[$Label] exception=$([bool]$err) $(if ($err) { '(' + ($err -replace '[A-Za-z]:\\[^ '']*', '<path>') + ')' }); file gone from the folder: $gone; bin items before/after: $($before.Items)/$($after.Items) (rc $($before.Rc)/$($after.Rc)); own entry found in the bin and removed: $own"
}

$work = Join-Path $env:TEMP 'harness-spike\S18'
New-Item -ItemType Directory -Force $work | Out-Null
try {
    $sys = $env:SystemDrive.Substring(0, 1)
    $q = Get-Quota $sys
    "system drive: bin query rc=$((Get-Bin "${sys}:\").Rc); quota MaxMB=$($q.MaxMB) NukeOnDelete=$($q.Nuke) ($($q.Key))"
    Test-Recycle 'a: small file on the system drive' (Join-Path $work 'small.bin') { param($p) [IO.File]::WriteAllBytes($p, (New-Object byte[] 4096)) }
    if ($q.MaxMB) {
        $nominal = ([long]$q.MaxMB + 1024) * 1MB
        Test-Recycle "b: sparse file, nominal size = quota + 1 GB, on the system drive (no real disk use)" (Join-Path $work 'toobig.bin') {
            param($p)
            [IO.File]::WriteAllBytes($p, (New-Object byte[] 1)); & fsutil sparse setflag $p | Out-Null
            $fs = [IO.File]::Open($p, 'Open', 'Write'); try { $fs.SetLength($nominal) } finally { $fs.Dispose() }
        }
    }
    if ($DriveRoot) {
        if (-not (Test-Path -LiteralPath $DriveRoot -PathType Container)) { throw 'DriveRoot not found' }
        $dl = $DriveRoot.Substring(0, 1)
        $dq = Get-Quota $dl
        "drive-for-desktop drive: bin query rc=$((Get-Bin "${dl}:\").Rc); has a Recycle Bin folder: $(Test-Path -LiteralPath "${dl}:\`$Recycle.Bin" -ErrorAction SilentlyContinue); quota entry: $(if ($dq) { $dq.Key } else { 'no volume' })"
        Test-Recycle 'c: small file on a Drive for desktop drive' (Join-Path $DriveRoot 'HarnessSync-test\s18\junk.bin') { param($p) [IO.File]::WriteAllBytes($p, (New-Object byte[] 4096)) }
        $leftover = Join-Path $DriveRoot 'HarnessSync-test'
        Remove-Item -LiteralPath (Join-Path $leftover 's18') -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Get-ChildItem -LiteralPath $leftover -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
    } else { 'c: skipped (no -DriveRoot)' }
} finally {
    Remove-Item -LiteralPath (Split-Path $work) -Recurse -Force -ErrorAction SilentlyContinue
    "cleanup: scratch folder gone = $(-not (Test-Path -LiteralPath $work))"
}
