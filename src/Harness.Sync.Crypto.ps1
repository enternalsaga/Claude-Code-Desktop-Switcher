# Harness.Sync.Crypto.ps1 - passphrase key derivation and the .enc file format for Drive sync (phase 4, lane K).
# Everything that goes to Drive is encrypted with a key derived from the user's passphrase:
#   key   = PBKDF2-SHA256(passphrase, salt, iterations) -> 64 bytes: AES-256 key (first 32) | HMAC key (last 32)
#   .enc  = 'HSE1' | version 1 | iv (16) | AES-256-CBC PKCS7 ciphertext | HMAC-SHA256 over every byte before it
# The MAC is checked before anything is decrypted or written. A passphrase or a key is never logged or printed.
# Needs .NET Framework 4.7.2 or later (PBKDF2 with SHA-256 and CryptoStream's leaveOpen). ASCII only.

$script:SyncMagic = [byte[]](0x48, 0x53, 0x45, 0x31)   # 'HSE1'
$script:SyncKeyCheckLabel = 'harness-sync-keycheck-v1'
$script:SyncMaxIterations = 10000000

function Test-SyncBytesEqual {
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }   # no early exit
    return ($diff -eq 0)
}

function ConvertTo-SyncHex {
    param([byte[]]$Bytes)
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Assert-SyncKey {
    param($Key)
    if ($Key -isnot [byte[]] -or $Key.Length -ne 64) { throw 'The sync key must be 64 bytes.' }
}

function Get-SyncKeyCheck {
    param([Parameter(Mandatory)][byte[]]$Key)
    $h = New-Object Security.Cryptography.HMACSHA256 (, $Key[32..63])
    try { return (ConvertTo-SyncHex $h.ComputeHash([Text.Encoding]::ASCII.GetBytes($script:SyncKeyCheckLabel))) } finally { $h.Dispose() }
}

function Get-SyncKdfValues {
    param([Parameter(Mandatory)]$Kdf)
    $salt = $null
    try { $salt = [Convert]::FromBase64String([string]$Kdf.salt) } catch { }
    if (-not $salt -or $salt.Length -ne 32) { throw 'The sync settings hold an invalid salt.' }
    $iter = 0
    if (-not [int]::TryParse([string]$Kdf.iterations, [ref]$iter) -or $iter -lt 1 -or $iter -gt $script:SyncMaxIterations) { throw 'The sync settings hold an invalid iteration count.' }
    return @{ Salt = $salt; Iterations = $iter }
}

function Invoke-SyncPbkdf2 {
    param([Parameter(Mandatory)][string]$Passphrase, [Parameter(Mandatory)][byte[]]$Salt, [Parameter(Mandatory)][int]$Iterations)
    if (-not $Passphrase) { throw 'The passphrase is empty.' }
    $ctor = $null
    try { $ctor = [Security.Cryptography.Rfc2898DeriveBytes].GetConstructor(@([byte[]], [byte[]], [int], [Security.Cryptography.HashAlgorithmName])) } catch { }
    if (-not $ctor) { throw 'Drive sync needs .NET Framework 4.7.2 or later (PBKDF2 with SHA-256).' }
    $pw = [Text.Encoding]::UTF8.GetBytes($Passphrase)
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes ($pw, $Salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return , $kdf.GetBytes(64) } finally { $kdf.Dispose(); [Array]::Clear($pw, 0, $pw.Length) }
}

# A new key-derivation record for sync.json. Iterations is only lowered by tests.
function New-SyncKdf {
    param([Parameter(Mandatory)][string]$Passphrase, [int]$Iterations = 600000)
    $salt = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $key = Invoke-SyncPbkdf2 -Passphrase $Passphrase -Salt $salt -Iterations $Iterations
    return @{ salt = [Convert]::ToBase64String($salt); iterations = $Iterations; keyCheck = (Get-SyncKeyCheck -Key $key) }
}

# The 64-byte key for a passphrase, or throws 'wrong-passphrase' when it does not match the record's keyCheck.
function Get-SyncKey {
    param([Parameter(Mandatory)][string]$Passphrase, [Parameter(Mandatory)]$Kdf)
    $v = Get-SyncKdfValues -Kdf $Kdf
    $key = Invoke-SyncPbkdf2 -Passphrase $Passphrase -Salt $v.Salt -Iterations $v.Iterations
    if (-not (Test-SyncBytesEqual ([Text.Encoding]::ASCII.GetBytes((Get-SyncKeyCheck -Key $key))) ([Text.Encoding]::ASCII.GetBytes(([string]$Kdf.keyCheck).ToLowerInvariant())))) { throw 'wrong-passphrase' }
    return , $key
}

# ---- DPAPI cache of the derived key (decision D2): saves the PBKDF2 run on every push and pull -------------------

function Get-SyncKeyCachePath {
    return (Join-Path $script:SwitcherHome 'sync-key.bin')
}

function Save-SyncKeyCache {
    param([Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)]$Kdf, [string]$Path = (Get-SyncKeyCachePath))
    Assert-SyncKey $Key
    Add-Type -AssemblyName System.Security
    $v = Get-SyncKdfValues -Kdf $Kdf
    $blob = [Security.Cryptography.ProtectedData]::Protect($Key, $v.Salt, [Security.Cryptography.DataProtectionScope]::CurrentUser)   # the salt is the entropy
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $tmp = "$Path.tmp-" + [guid]::NewGuid().ToString('N')
    try { [IO.File]::WriteAllBytes($tmp, $blob); Move-Item -LiteralPath $tmp -Destination $Path -Force } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

# The cached key, or $null: no file, another salt, a damaged file, or a key that fails the record's keyCheck.
function Get-SyncKeyCache {
    param([Parameter(Mandatory)]$Kdf, [string]$Path = (Get-SyncKeyCachePath))
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        Add-Type -AssemblyName System.Security
        $v = Get-SyncKdfValues -Kdf $Kdf
        $key = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $v.Salt, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        if ($key.Length -ne 64) { return $null }
        if (-not (Test-SyncBytesEqual ([Text.Encoding]::ASCII.GetBytes((Get-SyncKeyCheck -Key $key))) ([Text.Encoding]::ASCII.GetBytes(([string]$Kdf.keyCheck).ToLowerInvariant())))) { return $null }
        return , $key
    } catch { return $null }
}

# ---- the .enc format, on streams ------------------------------------------------------------------------------------

# Writes the format to $Out, which must be seekable and readable (the MAC is a second pass over what was written).
function Protect-SyncStream {
    param([Parameter(Mandatory)][IO.Stream]$In, [Parameter(Mandatory)][IO.Stream]$Out, [Parameter(Mandatory)][byte[]]$Key)
    Assert-SyncKey $Key
    $aes = [Security.Cryptography.Aes]::Create()
    $mac = New-Object Security.Cryptography.HMACSHA256 (, $Key[32..63])
    try {
        $aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = [byte[]]$Key[0..31]; $aes.GenerateIV()
        $start = $Out.Position
        $Out.Write($script:SyncMagic, 0, 4); $Out.WriteByte(1); $Out.Write($aes.IV, 0, 16)
        $enc = $aes.CreateEncryptor()
        $cs = New-Object Security.Cryptography.CryptoStream ($Out, $enc, [Security.Cryptography.CryptoStreamMode]::Write, $true)
        try {
            $buf = New-Object byte[] 65536
            while (($n = $In.Read($buf, 0, $buf.Length)) -gt 0) { $cs.Write($buf, 0, $n) }
            $cs.FlushFinalBlock()
        } finally { $cs.Dispose(); $enc.Dispose() }
        $end = $Out.Position
        $Out.Position = $start
        $left = $end - $start
        $buf = New-Object byte[] 65536
        while ($left -gt 0) {
            $n = $Out.Read($buf, 0, [int][Math]::Min($buf.Length, $left))
            if ($n -le 0) { throw 'Could not read back the encrypted data.' }
            [void]$mac.TransformBlock($buf, 0, $n, $null, 0); $left -= $n
        }
        [void]$mac.TransformFinalBlock($buf, 0, 0)
        $Out.Position = $end
        $Out.Write($mac.Hash, 0, 32)
    } finally { $aes.Dispose(); $mac.Dispose() }
}

# Reads the format from $In (seekable). Throws 'mac-mismatch' before writing a byte when anything is off.
function Unprotect-SyncStream {
    param([Parameter(Mandatory)][IO.Stream]$In, [Parameter(Mandatory)][IO.Stream]$Out, [Parameter(Mandatory)][byte[]]$Key)
    Assert-SyncKey $Key
    $start = $In.Position
    $total = $In.Length - $start
    $bodyLen = $total - 32
    if ($total -lt (4 + 1 + 16 + 16 + 32) -or (($bodyLen - 21) % 16) -ne 0) { throw 'mac-mismatch' }
    $mac = New-Object Security.Cryptography.HMACSHA256 (, $Key[32..63])
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $buf = New-Object byte[] 65536
        $left = $bodyLen
        while ($left -gt 0) {
            $n = $In.Read($buf, 0, [int][Math]::Min($buf.Length, $left))
            if ($n -le 0) { throw 'mac-mismatch' }
            [void]$mac.TransformBlock($buf, 0, $n, $null, 0); $left -= $n
        }
        [void]$mac.TransformFinalBlock($buf, 0, 0)
        $stored = New-Object byte[] 32
        if ($In.Read($stored, 0, 32) -ne 32 -or -not (Test-SyncBytesEqual $mac.Hash $stored)) { throw 'mac-mismatch' }
        $In.Position = $start
        $head = New-Object byte[] 21
        [void]$In.Read($head, 0, 21)
        if (-not (Test-SyncBytesEqual ([byte[]]$head[0..3]) $script:SyncMagic) -or $head[4] -ne 1) { throw 'mac-mismatch' }
        $aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = [byte[]]$Key[0..31]; $aes.IV = [byte[]]$head[5..20]
        $dec = $aes.CreateDecryptor()
        $cs = New-Object Security.Cryptography.CryptoStream ($Out, $dec, [Security.Cryptography.CryptoStreamMode]::Write, $true)
        try {
            $left = $bodyLen - 21
            while ($left -gt 0) {
                $n = $In.Read($buf, 0, [int][Math]::Min($buf.Length, $left))
                if ($n -le 0) { throw 'mac-mismatch' }
                $cs.Write($buf, 0, $n); $left -= $n
            }
            $cs.FlushFinalBlock()
        } catch [Security.Cryptography.CryptographicException] {
            throw 'mac-mismatch'   # the MAC held, so only a key whose AES half is wrong ends here; same answer as a wrong key
        } finally {
            try { $cs.Dispose() } catch [Security.Cryptography.CryptographicException] { }   # Dispose re-runs the failed final block
            $dec.Dispose()
        }
    } finally { $aes.Dispose(); $mac.Dispose() }
}

# Both file functions write to <Out>.tmp-<guid> and rename on success, so a failure never leaves a partial Out.
function Invoke-SyncFileTransform {
    param([Parameter(Mandatory)][string]$In, [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)][scriptblock]$Core)
    Assert-SyncKey $Key
    $tmp = "$Out.tmp-" + [guid]::NewGuid().ToString('N')
    $src = [IO.File]::Open($In, 'Open', 'Read', 'Read')
    try {
        $dst = [IO.File]::Open($tmp, 'CreateNew', 'ReadWrite', 'None')
        try { & $Core $src $dst $Key } finally { $dst.Dispose() }
        Move-Item -LiteralPath $tmp -Destination $Out -Force
    } finally {
        $src.Dispose()
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Protect-SyncFile {
    param([Parameter(Mandatory)][string]$In, [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][byte[]]$Key)
    Invoke-SyncFileTransform -In $In -Out $Out -Key $Key -Core { param($s, $d, $k) Protect-SyncStream -In $s -Out $d -Key $k }
}

function Unprotect-SyncFile {
    param([Parameter(Mandatory)][string]$In, [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][byte[]]$Key)
    Invoke-SyncFileTransform -In $In -Out $Out -Key $Key -Core { param($s, $d, $k) Unprotect-SyncStream -In $s -Out $d -Key $k }
}

# ---- strings (titleEnc in the index): the same format, base64-encoded ------------------------------------------------

function Protect-SyncString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][byte[]]$Key)
    $in = New-Object IO.MemoryStream (, [Text.Encoding]::UTF8.GetBytes($Text))
    $out = New-Object IO.MemoryStream
    try { Protect-SyncStream -In $in -Out $out -Key $Key; return [Convert]::ToBase64String($out.ToArray()) } finally { $in.Dispose(); $out.Dispose() }
}

function Unprotect-SyncString {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][byte[]]$Key)
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String($Text) } catch { throw 'mac-mismatch' }
    $in = New-Object IO.MemoryStream (, $bytes)
    $out = New-Object IO.MemoryStream
    try { Unprotect-SyncStream -In $in -Out $out -Key $Key; return [Text.Encoding]::UTF8.GetString($out.ToArray()) } finally { $in.Dispose(); $out.Dispose() }
}
