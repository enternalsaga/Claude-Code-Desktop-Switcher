$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Harness.Sync.Crypto.ps1')

# All passphrases and keys below are made up for the tests. Iterations stay low except in the one timing check.
$fakePass = 'test-only fake passphrase'
$fixedSalt = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='   # bytes 0..31
$expectedKey = '4024b1c76bb70a5216a1a81b6015f0ff85288c68b3b4a25a3730d04b171da204914a9d3cfa5776e73d3825a8e66370b7ca4f9e3d3932f88cd31911fd715cb4cd'
$expectedCheck = '2d68b4b33ad19a5ba9f6773e095bbdc0d849f1fd657d22869a57598a040ffcec'   # both made with Python hashlib, 1000 rounds

function ConvertTo-Hex([byte[]]$b) { (($b | ForEach-Object { $_.ToString('x2') }) -join '') }

# ---------------------------------------------------------------- K1: key derivation
$kdf = @{ salt = $fixedSalt; iterations = 1000; keyCheck = $expectedCheck }
$key = Get-SyncKey -Passphrase $fakePass -Kdf $kdf
Assert ($key.Length -eq 64) 'key is 64 bytes (32 AES | 32 HMAC)'
Assert ((ConvertTo-Hex $key) -eq $expectedKey) 'PBKDF2-SHA256 matches the independently computed vector'
Assert-Throws { Get-SyncKey -Passphrase 'another fake passphrase' -Kdf $kdf } 'a wrong passphrase must throw'
try { Get-SyncKey -Passphrase 'another fake passphrase' -Kdf $kdf } catch { Assert ($_.Exception.Message -eq 'wrong-passphrase') "message is wrong-passphrase, got $($_.Exception.Message)" }
Assert-Throws { Get-SyncKey -Passphrase '' -Kdf $kdf } 'an empty passphrase must throw'

$new = New-SyncKdf -Passphrase $fakePass -Iterations 1000
Assert ($new.iterations -eq 1000 -and [Convert]::FromBase64String($new.salt).Length -eq 32 -and $new.keyCheck -match '\A[0-9a-f]{64}\z') 'New-SyncKdf: random 32-byte salt, iterations, hex keyCheck'
$new2 = New-SyncKdf -Passphrase $fakePass -Iterations 1000
Assert ($new.salt -ne $new2.salt) 'every KDF gets its own salt'
$k1 = Get-SyncKey -Passphrase $fakePass -Kdf $new
Assert ($k1.Length -eq 64) 'a fresh KDF round-trips through Get-SyncKey'
# the KDF comes back from sync.json as an object, not a hashtable
$asObject = ($new | ConvertTo-Json | ConvertFrom-Json)
Assert ((ConvertTo-Hex (Get-SyncKey -Passphrase $fakePass -Kdf $asObject)) -eq (ConvertTo-Hex $k1)) 'a KDF read back from JSON works'
Assert-Throws { Get-SyncKey -Passphrase $fakePass -Kdf @{ salt = $fixedSalt; iterations = 999999999; keyCheck = $expectedCheck } } 'an absurd iteration count from sync.json is refused'
Assert-Throws { Get-SyncKey -Passphrase $fakePass -Kdf @{ salt = 'AAAA'; iterations = 1000; keyCheck = $expectedCheck } } 'a short salt is refused'

$sw = [Diagnostics.Stopwatch]::StartNew()
$real = New-SyncKdf -Passphrase $fakePass
$sw.Stop()
Assert ($real.iterations -eq 600000) 'the default is 600000 iterations'
Write-Host ("600000 iterations took {0} ms" -f $sw.ElapsedMilliseconds)

# ---------------------------------------------------------------- K2: .enc files
$tmp = New-TestTempDir
try {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    function New-TestFile([string]$Path, [int]$Size) { $b = New-Object byte[] $Size; if ($Size) { $rng.GetBytes($b) }; [IO.File]::WriteAllBytes($Path, $b) }
    function Test-SameFile($a, $b) { (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash }

    foreach ($size in 0, 1, 15, 16, 17, 5MB) {
        $in = Join-Path $tmp "in-$size.bin"; $enc = Join-Path $tmp "e-$size.enc"; $out = Join-Path $tmp "o-$size.bin"
        New-TestFile $in $size
        Protect-SyncFile -In $in -Out $enc -Key $key
        $encLen = (Get-Item -LiteralPath $enc).Length
        $expectLen = 4 + 1 + 16 + ([Math]::Floor($size / 16) + 1) * 16 + 32
        Assert ($encLen -eq $expectLen) "size $size : format length $encLen, expected $expectLen"
        $head = [IO.File]::ReadAllBytes($enc)[0..4]
        Assert ([Text.Encoding]::ASCII.GetString($head[0..3]) -eq 'HSE1' -and $head[4] -eq 1) 'magic HSE1 and version 1'
        Unprotect-SyncFile -In $enc -Out $out -Key $key
        Assert (Test-SameFile $in $out) "round trip of $size bytes"
    }

    # the same plaintext never gives the same file twice (fresh iv)
    $in = Join-Path $tmp 'in-1.bin'
    Protect-SyncFile -In $in -Out (Join-Path $tmp 'a.enc') -Key $key
    Protect-SyncFile -In $in -Out (Join-Path $tmp 'b.enc') -Key $key
    Assert (-not (Test-SameFile (Join-Path $tmp 'a.enc') (Join-Path $tmp 'b.enc'))) 'a fresh iv per file'

    # tampering: a flipped bit anywhere, or a cut file, is mac-mismatch and writes nothing
    $good = Join-Path $tmp 'e-17.enc'
    $bytes = [IO.File]::ReadAllBytes($good)
    $spots = @{ magic = 1; version = 4; iv = 10; ciphertext = 30; mac = ($bytes.Length - 3) }
    foreach ($name in $spots.Keys) {
        $bad = [byte[]]$bytes.Clone(); $bad[$spots[$name]] = $bad[$spots[$name]] -bxor 1
        $badPath = Join-Path $tmp "bad-$name.enc"; [IO.File]::WriteAllBytes($badPath, $bad)
        $outPath = Join-Path $tmp "bad-$name.out"
        $msg = $null; try { Unprotect-SyncFile -In $badPath -Out $outPath -Key $key } catch { $msg = $_.Exception.Message }
        Assert ($msg -eq 'mac-mismatch') "flipped bit in $name : got [$msg]"
        Assert (-not (Test-Path -LiteralPath $outPath)) "nothing is written for a bad $name"
    }
    foreach ($cut in 0, 10, 52, 53, ($bytes.Length - 1)) {
        $cutPath = Join-Path $tmp "cut-$cut.enc"; [IO.File]::WriteAllBytes($cutPath, [byte[]]($bytes[0..($cut - 1)] | Where-Object { $true }))
        if ($cut -eq 0) { [IO.File]::WriteAllBytes($cutPath, [byte[]]@()) }
        $outPath = Join-Path $tmp "cut-$cut.out"
        $msg = $null; try { Unprotect-SyncFile -In $cutPath -Out $outPath -Key $key } catch { $msg = $_.Exception.Message }
        Assert ($msg -eq 'mac-mismatch') "file cut to $cut bytes : got [$msg]"
        Assert (-not (Test-Path -LiteralPath $outPath)) "nothing is written for a file cut to $cut"
    }
    # a different key is also a mac-mismatch
    $otherKey = [byte[]]$key.Clone(); $otherKey[40] = $otherKey[40] -bxor 255
    $msg = $null; try { Unprotect-SyncFile -In $good -Out (Join-Path $tmp 'otherkey.out') -Key $otherKey } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'mac-mismatch' -and -not (Test-Path -LiteralPath (Join-Path $tmp 'otherkey.out'))) 'wrong key: mac-mismatch and no output'
    Assert-Throws { Protect-SyncFile -In $in -Out (Join-Path $tmp 'shortkey.enc') -Key ([byte[]](1..10)) } 'a key that is not 64 bytes is refused'
    Assert (-not (Test-Path -LiteralPath (Join-Path $tmp 'shortkey.enc'))) 'no file for a refused key'
    Assert-Throws { Protect-SyncFile -In (Join-Path $tmp 'missing.bin') -Out (Join-Path $tmp 'missing.enc') -Key $key } 'a missing input throws'
    Assert (@(Get-ChildItem -LiteralPath $tmp -Filter 'missing*').Count -eq 0) 'a failed encrypt leaves no file and no tmp'

    # overwriting an existing Out works and leaves no tmp behind
    Protect-SyncFile -In $in -Out (Join-Path $tmp 'a.enc') -Key $key
    Assert (@(Get-ChildItem -LiteralPath $tmp -Filter '*.tmp*').Count -eq 0) 'no tmp files left behind'

    # ------------------------------------------------------------ K3: DPAPI cache of the derived key
    $cache = Join-Path $tmp 'sync-key.bin'
    Assert ($null -eq (Get-SyncKeyCache -Kdf $kdf -Path $cache)) 'no cache file gives $null'
    Save-SyncKeyCache -Key $key -Kdf $kdf -Path $cache
    Assert (Test-Path -LiteralPath $cache) 'cache written'
    $raw = [IO.File]::ReadAllBytes($cache)
    Assert ((ConvertTo-Hex $raw) -notlike "*$($expectedKey.Substring(0, 32))*") 'the cache does not hold the key in the clear'
    $back = Get-SyncKeyCache -Kdf $kdf -Path $cache
    Assert ($null -ne $back -and (ConvertTo-Hex $back) -eq $expectedKey) 'cache round trip'
    $otherSalt = @{ salt = [Convert]::ToBase64String((1..32 | ForEach-Object { [byte](200 + $_ % 50) })); iterations = 1000; keyCheck = $expectedCheck }
    Assert ($null -eq (Get-SyncKeyCache -Kdf $otherSalt -Path $cache)) 'another salt: the cache is void'
    $otherCheck = @{ salt = $fixedSalt; iterations = 1000; keyCheck = ('0' * 64) }
    Assert ($null -eq (Get-SyncKeyCache -Kdf $otherCheck -Path $cache)) 'a key that fails keyCheck is not returned'
    [IO.File]::WriteAllBytes($cache, [byte[]](1, 2, 3, 4, 5))
    Assert ($null -eq (Get-SyncKeyCache -Kdf $kdf -Path $cache)) 'a damaged cache gives $null'
    [IO.File]::WriteAllBytes($cache, [byte[]]@())
    Assert ($null -eq (Get-SyncKeyCache -Kdf $kdf -Path $cache)) 'an empty cache gives $null'
    Assert-Throws { Save-SyncKeyCache -Key ([byte[]](1..5)) -Kdf $kdf -Path $cache } 'a key of the wrong size is not cached'
    Assert (@(Get-ChildItem -LiteralPath $tmp -Filter 'sync-key*.tmp*').Count -eq 0) 'no tmp left by the cache'

    # ------------------------------------------------------------ K4: strings for titleEnc
    $title = "Chat tieng Viet " + [char]0x0111 + [char]0x00E9 + " " + [char]0x4E2D + [char]0x6587 + " emoji " + [char]::ConvertFromUtf32(0x1F600)
    $enc = Protect-SyncString -Text $title -Key $key
    Assert ($enc -is [string] -and $enc -match '\A[A-Za-z0-9+/]+=*\z') 'a base64 string'
    Assert ((Unprotect-SyncString -Text $enc -Key $key) -ceq $title) 'Unicode round trip'
    Assert ((Unprotect-SyncString -Text (Protect-SyncString -Text '' -Key $key) -Key $key) -ceq '') 'empty string round trip'
    Assert ($enc -ne (Protect-SyncString -Text $title -Key $key)) 'a fresh iv per string'
    $raw = [Convert]::FromBase64String($enc); $raw[30] = $raw[30] -bxor 1
    Assert-Throws { Unprotect-SyncString -Text ([Convert]::ToBase64String($raw)) -Key $key } 'a changed string throws'
    $msg = $null; try { Unprotect-SyncString -Text ([Convert]::ToBase64String($raw)) -Key $key } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'mac-mismatch') "a changed string is mac-mismatch, got [$msg]"
    $msg = $null; try { Unprotect-SyncString -Text 'not base64 !!' -Key $key } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'mac-mismatch') "text that is not base64 is mac-mismatch, got [$msg]"
} finally {
    Remove-TestTempDir $tmp
}

Write-Host 'HarnessSyncCrypto.Tests: OK'
