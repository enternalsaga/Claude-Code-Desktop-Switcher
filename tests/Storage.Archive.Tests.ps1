$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Import-TestFunctions -Files @((Join-Path $root 'ClaudeSwitcher.ps1')) -Names @('Get-Setting', 'Set-Setting', 'Set-JsonTopLevelString'))
. (Join-Path $root 'src\Harness.Core.ps1')
. (Join-Path $root 'src\Harness.Sqlite.ps1')
. (Join-Path $root 'src\Harness.Claude.ps1')
. (Join-Path $root 'src\Harness.Codex.Chats.ps1')
. (Join-Path $root 'src\Harness.Sync.Crypto.ps1')
. (Join-Path $root 'src\Harness.Sync.Config.ps1')
. (Join-Path $root 'src\Harness.Sync.Store.ps1')
. (Join-Path $root 'src\Storage.Scan.ps1')
. (Join-Path $root 'src\Storage.Inventory.ps1')
. (Join-Path $root 'src\Storage.DriveArchive.ps1')
. (Join-Path $root 'src\Storage.Guard.ps1')
. (Join-Path $root 'src\Storage.Archive.ps1')
. (Join-Path $root 'src\Storage.Harness.ps1')

# Fake trees under %TEMP%\storage-test-* only. No real profile, CODEX_HOME, Recycle Bin or app-server is touched: the Codex
# calls go to a fake -CodexRpc, the recycler is a fake, the volume is a fake.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('storage-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
function Write-Rand($path, [int]$n, [int]$seed = 1) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null; $b = New-Object byte[] $n; (New-Object Random $seed).NextBytes($b); [IO.File]::WriteAllBytes($path, $b) }
function Write-Text($path, $text) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null; [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }
function Get-TreeHash($dir) {
    $base = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\') + '\'
    (@(Get-ChildItem -LiteralPath $dir -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($base.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|')
}
function Set-Old($dir) { foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File) { $f.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40) } }
function Break-Zip($zip) {   # replaces the content of one listed entry with other bytes: a valid zip whose sha256 no longer matches
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::Open($zip, 'Update')
    try { $e = @($z.Entries | Where-Object { $_.FullName -like 'files/*' })[0]; $e.Delete(); $n = $z.CreateEntry('files/0001'); $w = $n.Open(); $w.WriteByte(65); $w.Dispose() } finally { $z.Dispose() }
}
function Edit-Manifest($zip, [scriptblock]$Edit) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::Open($zip, 'Update')
    try {
        $e = $z.GetEntry('archive.json'); $r = New-Object IO.StreamReader($e.Open()); $m = $r.ReadToEnd() | ConvertFrom-Json; $r.Dispose(); $e.Delete()
        & $Edit $m
        $n = $z.CreateEntry('archive.json'); $w = New-Object IO.StreamWriter($n.Open(), (New-Object Text.UTF8Encoding($false))); $w.Write(($m | ConvertTo-Json -Depth 12)); $w.Dispose()
    } finally { $z.Dispose() }
}
try {
    # ---------------------------------------------------------------- a fake Claude tree: one chat shared by two profiles
    $cli = 'aaaaaaaa-0000-4000-8000-000000000001'
    $cwd = 'C:\work\alpha'
    $proj = Join-Path $tmp 'claude\projects'; $slug = ConvertTo-ClaudeProjectSlug $cwd
    $p1 = Join-Path $tmp 'p1'; $p2 = Join-Path $tmp 'p2'
    Write-Text (Join-Path $proj "$slug\$cli.jsonl") ('{"type":"user","sessionId":"' + $cli + '","cwd":"C:\\work\\alpha","timestamp":"2026-10-01T08:00:00.000Z","message":{"role":"user","content":"hello"}}' + "`n")
    Write-Rand (Join-Path $proj "$slug\$cli\subagents\agent-1.jsonl") 5000 1
    Write-Rand (Join-Path $proj "$slug\$cli\tool-results\out.txt") 3000 2
    $localJson = '{"cliSessionId":"' + $cli + '","title":"Shared chat","cwd":"C:\\work\\alpha","createdAt":1759300000000,"lastActivityAt":1759300000000}'
    Write-Text (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x1.json') $localJson
    Write-Text (Join-Path $p2 'claude-code-sessions\acct2\org2\local_y1.json') $localJson
    foreach ($d in $proj, $p1, $p2) { Set-Old $d }
    $profiles = @(
        @{ Id = 'Default'; Name = 'Default'; SessionRoot = (Join-Path $p1 'claude-code-sessions'); DataDir = $p1; IsDefault = $true },
        @{ Id = 'Work'; Name = 'Work'; SessionRoot = (Join-Path $p2 'claude-code-sessions'); DataDir = $p2; IsDefault = $false })
    $roots = @{ ClaudeProjects = $proj; ClaudeProfiles = $profiles; CodexHomes = @(); AgyDirs = @() }
    $before = (Get-TreeHash (Join-Path $tmp 'claude')) + '||' + (Get-TreeHash $p1) + '||' + (Get-TreeHash $p2)
    $sess = @((Get-StorageInventory -Roots $roots).Sessions | Where-Object { $_.Key -eq "claude:$cli" })[0]
    Assert ($sess.Parts.Count -eq 4 -and $sess.Profiles.Count -eq 2) 'the fixture session has its transcript, folder files and both profile files'
    $out = Join-Path $tmp 'out'

    # ---------------------------------------------------------------- A1-2: build and verify an archive
    $a = New-StorageArchive -Session $sess -OutDir $out -MachineId 'aaaaaaaa-0000-4000-8000-0000000000aa'
    Assert ((Test-Path -LiteralPath $a.ZipPath) -and $a.Sha256 -match '\A[0-9a-f]{64}\z' -and $a.Manifest.key -eq "claude:$cli" -and $a.Manifest.format -eq 'harness-archive') 'the zip and its manifest'
    Assert ($a.Manifest.parts.Count -eq 5 -and (@($a.Manifest.parts | Where-Object { $_.sha256 -notmatch '\A[0-9a-f]{64}\z' }).Count -eq 0)) "every file has a sha256: $($a.Manifest.parts.Count) parts"
    Assert (@($a.Manifest.restore.claude.profiles | ForEach-Object { $_.profileId } | Sort-Object) -join ',' -eq 'Default,Work') 'the profiles that referred to it are recorded'
    Assert ((Get-TreeHash (Join-Path $tmp 'claude')) + '||' + (Get-TreeHash $p1) + '||' + (Get-TreeHash $p2) -eq $before) 'building an archive changes nothing it archives'
    Assert (@(Get-ChildItem -LiteralPath $out).Count -eq 1) 'no temp file is left next to the zip'
    $v = Read-StorageArchive -ZipPath $a.ZipPath
    Assert ($v.Verified -eq $true -and $v.Manifest.key -eq "claude:$cli") 'Read-StorageArchive verifies a good archive'
    # one byte of a stored file changed inside the compressed stream
    $bytes = [IO.File]::ReadAllBytes($a.ZipPath); $bad = Join-Path $tmp 'flip.zip'
    $bytes[[int]($bytes.Length / 3)] = $bytes[[int]($bytes.Length / 3)] -bxor 0xFF; [IO.File]::WriteAllBytes($bad, $bytes)
    Assert ((Read-StorageArchive -ZipPath $bad).Verified -eq $false) 'a flipped byte is caught (Verified false, no exception)'
    Copy-Item -LiteralPath $a.ZipPath -Destination (Join-Path $tmp 'swap.zip'); Break-Zip (Join-Path $tmp 'swap.zip')
    $r = Read-StorageArchive -ZipPath (Join-Path $tmp 'swap.zip')
    Assert ($r.Verified -eq $false -and $r.Reason) "a replaced entry: $($r.Reason)"
    Copy-Item -LiteralPath $a.ZipPath -Destination (Join-Path $tmp 'extra.zip')
    $z = [IO.Compression.ZipFile]::Open((Join-Path $tmp 'extra.zip'), 'Update'); $w = $z.CreateEntry('files/9999').Open(); $w.WriteByte(1); $w.Dispose(); $z.Dispose()
    Assert ((Read-StorageArchive -ZipPath (Join-Path $tmp 'extra.zip')).Verified -eq $false) 'an entry the manifest does not list'
    Assert ((Read-StorageArchive -ZipPath (Join-Path $tmp 'nothing.zip')).Verified -eq $false) 'a missing zip'
    Write-Text (Join-Path $tmp 'junk.zip') 'not a zip'
    Assert ((Read-StorageArchive -ZipPath (Join-Path $tmp 'junk.zip')).Verified -eq $false) 'a file that is not a zip'
    $threw = $false; try { New-StorageArchive -Session $sess -OutDir (Join-Path $tmp 'out2') -MaxBytes 1000 } catch { $threw = $_.Exception.Message -like 'archive-too-large*' }
    Assert ($threw -and -not (Test-Path (Join-Path $tmp 'out2\*'))) 'a session over the cap is refused with a clear error and leaves no file'
    $threw = $false; try { New-StorageArchive -Session $sess -OutDir (Join-Path $tmp 'out2') -MaxEntries 3 } catch { $threw = $_.Exception.Message -like 'archive-too-large*' }
    Assert $threw 'the entry count is limited too'

    # ---------------------------------------------------------------- A1-3: archive, remove, restore: the same bytes
    $rm = Remove-StorageSessionOriginal -Session $sess -Mode Delete -Roots $roots
    Assert ($rm.Removed.Count -eq 4 -and -not (Test-Path (Join-Path $proj "$slug\$cli.jsonl")) -and -not (Test-Path (Join-Path $proj "$slug\$cli")) -and -not (Test-Path (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x1.json'))) 'every part is gone'
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $a.ZipPath }) -Target @{ Kind = 'local'; Path = $out } -Roots $roots)
    Assert ($res[0].Ok -eq $true) "restore: $($res[0] | ConvertTo-Json -Compress)"
    Assert ((Get-TreeHash (Join-Path $tmp 'claude')) + '||' + (Get-TreeHash $p1) + '||' + (Get-TreeHash $p2) -eq $before) 'archive then restore gives back every byte of the tree'
    # restoring again over the same files changes nothing and makes no backup
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $a.ZipPath }) -Target @{ Kind = 'local'; Path = $out } -Roots $roots)
    Assert ($res[0].Ok -and @(Get-ChildItem -LiteralPath $proj -Recurse -Filter '*.bak-*').Count -eq 0) 'files with the same sha256 are left alone'

    # ---------------------------------------------------------------- A1-4: a different file in the way is kept as .bak, a missing profile goes to Default
    Write-Text (Join-Path $proj "$slug\$cli.jsonl") 'someone else wrote this'
    Remove-Item -LiteralPath (Join-Path $p2 'claude-code-sessions\acct2\org2\local_y1.json')
    $noWork = @{ ClaudeProjects = $proj; ClaudeProfiles = @($profiles[0]); CodexHomes = @(); AgyDirs = @() }
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $a.ZipPath }) -Target @{ Kind = 'local'; Path = $out } -Roots $noWork)
    Assert ($res[0].Ok -eq $true) "restore with a changed file and a missing profile: $($res[0] | ConvertTo-Json -Compress)"
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $proj $slug) -Filter "$cli.jsonl.bak-*").Count -eq 1) 'the file in the way was renamed to .bak-<time>'
    Assert ((Get-FileHash (Join-Path $proj "$slug\$cli.jsonl")).Hash -eq (Get-FileHash -LiteralPath $a.ZipPath).Hash -or [IO.File]::ReadAllText((Join-Path $proj "$slug\$cli.jsonl")).StartsWith('{"type":"user"')) 'and the archived transcript is back'
    Assert (@($res[0].Warnings | Where-Object { $_ -like '*Work*' -and $_ -like '*Default*' }).Count -eq 1) "a warning says the profile Work was gone and Default got the file: $($res[0].Warnings -join '|')"
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $p1 'claude-code-sessions') -Recurse -Filter 'local_y1.json').Count -eq 1) 'the missing profile file is under Default'

    # ---------------------------------------------------------------- restore refuses: app running, tampered manifest
    Remove-Item -LiteralPath (Join-Path $proj $slug) -Recurse -Force
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $a.ZipPath }) -Target @{ Kind = 'local'; Path = $out } -Roots $roots -Running @{ claude = @('Work') })
    Assert ($res[0].Ok -eq $false -and $res[0].Reason -like '*Work*' -and -not (Test-Path (Join-Path $proj $slug))) 'the app of a profile that gets files must be closed, and nothing is written'
    $evil = Join-Path $tmp 'evil.zip'; Copy-Item -LiteralPath $a.ZipPath -Destination $evil
    Edit-Manifest $evil { param($m) $m.parts[0].rel = '..\..\escaped.txt' }
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $evil }) -Target @{ Kind = 'local'; Path = $out } -Roots $roots)
    Assert ($res[0].Ok -eq $false -and -not (Test-Path (Join-Path $tmp 'escaped.txt')) -and -not (Test-Path (Join-Path $proj $slug))) "a path that climbs out is refused before anything is written: $($res[0].Reason)"
    Copy-Item -LiteralPath $a.ZipPath -Destination (Join-Path $tmp 'flip2.zip') -Force
    Break-Zip (Join-Path $tmp 'flip2.zip')
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = (Join-Path $tmp 'flip2.zip') }) -Target @{ Kind = 'local'; Path = $out } -Roots $roots)
    Assert ($res[0].Ok -eq $false -and -not (Test-Path (Join-Path $proj $slug))) 'an archive that does not verify writes nothing'

    # ---------------------------------------------------------------- PathMap: restore on another machine
    $map = @{ 'C:\work' = 'D:\code' }
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $a.ZipPath }) -Target @{ Kind = 'local'; Path = $out; PathMap = $map } -Roots $roots)
    $newSlug = ConvertTo-ClaudeProjectSlug 'D:\code\alpha'
    Assert ($res[0].Ok -and (Test-Path (Join-Path $proj "$newSlug\$cli.jsonl")) -and (Test-Path (Join-Path $proj "$newSlug\$cli\subagents\agent-1.jsonl")) -and -not (Test-Path (Join-Path $proj $slug))) "the transcript goes under the slug of the mapped folder ($newSlug): $($res[0] | ConvertTo-Json -Compress)"
    $meta = [IO.File]::ReadAllText((Join-Path $p1 'claude-code-sessions\acct1\org1\local_x1.json'))
    Assert ($meta.Contains('D:\\code\\alpha') -and -not $meta.Contains('C:\\work\\alpha')) 'the profile file points at the mapped folder'

    # ---------------------------------------------------------------- A1-8: the local index
    $idxTarget = @{ Kind = 'local'; Path = (Join-Path $tmp 'idx') }
    Assert ((Get-StorageArchiveIndex -Target $idxTarget).Count -eq 0) 'no index yet'
    Add-StorageArchiveIndex -Target $idxTarget -Row ([pscustomobject]@{ key = 'claude:one'; harness = 'claude'; title = 'T1'; bytes = 10; zipBytes = 5; archivedAt = '2026-11-15T10:00:00Z'; machineId = 'm'; entry = 'claude/2026-11/claude_one.harchive.zip' })
    Add-StorageArchiveIndex -Target $idxTarget -Row ([pscustomobject]@{ key = 'codex:two.1234abcd'; harness = 'codex'; title = 'T2'; bytes = 20; zipBytes = 8; archivedAt = '2026-11-15T11:00:00Z'; machineId = 'm'; entry = 'codex/2026-11/codex_two.1234abcd.harchive.zip' })
    $rows = @(Get-StorageArchiveIndex -Target $idxTarget)
    Assert ($rows.Count -eq 2 -and $rows[0].key -eq 'codex:two.1234abcd') 'two rows, newest first'
    Add-StorageArchiveIndex -Target $idxTarget -Row ([pscustomobject]@{ key = 'claude:one'; harness = 'claude'; title = 'T1b'; bytes = 11; zipBytes = 5; archivedAt = '2026-11-15T12:00:00Z'; machineId = 'm'; entry = 'x' })
    $rows = @(Get-StorageArchiveIndex -Target $idxTarget)
    Assert ($rows.Count -eq 2 -and (@($rows | Where-Object { $_.key -eq 'claude:one' })[0].title -eq 'T1b')) 'a newer archive of the same session replaces its row'
    $idxFile = Join-Path $idxTarget.Path 'archive-index.jsonl'
    [IO.File]::AppendAllText($idxFile, "this line is damaged`n")
    $warn = $null
    $rows = @(Get-StorageArchiveIndex -Target $idxTarget -WarningVariable warn -WarningAction SilentlyContinue)
    Assert ($rows.Count -eq 2 -and $warn) 'a damaged line is skipped with a warning'
    Remove-StorageArchiveIndex -Target $idxTarget -Key 'claude:one'
    Assert (@(Get-StorageArchiveIndex -Target $idxTarget -WarningAction SilentlyContinue).Count -eq 1 -and @(Get-ChildItem -LiteralPath $idxTarget.Path -Filter '*.tmp-*').Count -eq 0) 'a row is removed, no tmp file stays'
    Remove-StorageArchiveIndex -Target $idxTarget -Key 'nothing:here'

    # ---------------------------------------------------------------- A1-9 and the flow: Invoke-StorageArchive
    $target = @{ Kind = 'local'; Path = (Join-Path $tmp 'store') }
    $work = Join-Path $tmp 'work'
    $mid = 'aaaaaaaa-0000-4000-8000-0000000000aa'
    Remove-Item -LiteralPath (Join-Path $proj $newSlug) -Recurse -Force; Remove-Item -LiteralPath (Join-Path $p1 'claude-code-sessions') -Recurse -Force
    Write-Text (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x1.json') $localJson; Write-Text (Join-Path $p2 'claude-code-sessions\acct2\org2\local_y1.json') $localJson
    Write-Text (Join-Path $proj "$slug\$cli.jsonl") ('{"type":"user","cwd":"C:\\work\\alpha","timestamp":"2026-10-01T08:00:00.000Z","message":{"role":"user","content":"hello"}}' + "`n")
    Write-Rand (Join-Path $proj "$slug\$cli\subagents\agent-1.jsonl") 5000 1
    foreach ($d in $proj, $p1, $p2) { Set-Old $d }
    $before2 = (Get-TreeHash $proj) + '||' + (Get-TreeHash $p1)
    $sess = @((Get-StorageInventory -Roots $roots).Sessions | Where-Object { $_.Key -eq "claude:$cli" })[0]
    $noLock = { param($p) $false }
    $r = @(Invoke-StorageArchive -Sessions @($sess) -Target $target -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock)
    Assert ($r[0].Ok -eq $true -and (Test-Path -LiteralPath $r[0].ZipPath) -and $r[0].ZipPath -like (Join-Path $tmp 'store\claude\*')) "archived into <store>\claude\<yyyy-MM>\: $($r[0] | ConvertTo-Json -Compress)"
    Assert (-not (Test-Path (Join-Path $proj "$slug\$cli.jsonl")) -and -not (Test-Path (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x1.json'))) 'the originals are gone after a verified archive'
    $ix = @(Get-StorageArchiveIndex -Target $target)
    Assert ($ix.Count -eq 1 -and $ix[0].key -eq "claude:$cli" -and $ix[0].zipBytes -gt 0 -and $ix[0].bytes -eq $sess.Bytes -and $ix[0].entry -like 'claude/*') 'the index has the row'
    Assert (@(Get-ChildItem -LiteralPath $work -ErrorAction SilentlyContinue).Count -eq 0) 'the work folder is empty again'
    $back = @(Invoke-StorageRestore -Entries @($ix[0]) -Target $target -Roots $roots)
    Assert ($back[0].Ok -and (Get-TreeHash $proj) + '||' + (Get-TreeHash $p1) -eq $before2 -and @(Get-StorageArchiveIndex -Target $target).Count -eq 0) 'restoring from an index row brings the tree back and removes the row, keeps the zip'
    Assert (Test-Path -LiteralPath $r[0].ZipPath) 'the zip is kept after a restore'

    # a zip that goes wrong on its way to the store leaves the original alone (Q1: no delete before both checks pass)
    foreach ($d in $proj, $p1, $p2) { Set-Old $d }   # a restore writes the files now, so they would count as recent
    $sess = @((Get-StorageInventory -Roots $roots).Sessions | Where-Object { $_.Key -eq "claude:$cli" })[0]
    $r = @(Invoke-StorageArchive -Sessions @($sess) -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'store2') } -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock -OnZipBuilt { param($zip) $b = [IO.File]::ReadAllBytes($zip); $b[[int]($b.Length / 2)] = $b[[int]($b.Length / 2)] -bxor 1; [IO.File]::WriteAllBytes($zip, $b) })
    Assert ($r[0].Ok -eq $false -and (Test-Path (Join-Path $proj "$slug\$cli.jsonl")) -and (Get-TreeHash $proj) + '||' + (Get-TreeHash $p1) -eq $before2) "one byte changed in the zip before it is stored: the original is untouched ($($r[0].Reason))"
    Assert (@(Get-StorageArchiveIndex -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'store2') }).Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'store2\claude\*\*.zip'))) 'nothing was added to the store or its index'
    $r = @(Invoke-StorageArchive -Sessions @($sess) -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'store3') } -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock -OnPlaced { param($zip) $b = [IO.File]::ReadAllBytes($zip); $b[[int]($b.Length / 2)] = $b[[int]($b.Length / 2)] -bxor 1; [IO.File]::WriteAllBytes($zip, $b) })
    Assert ($r[0].Ok -eq $false -and (Get-TreeHash $proj) + '||' + (Get-TreeHash $p1) -eq $before2) 'a stored copy that does not verify: the original is untouched'
    Assert (@(Get-StorageArchiveIndex -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'store3') }).Count -eq 0) 'and no index row is written for it'

    # guard decisions inside a batch: recent is skipped with a reason, a failing session does not stop the next, Cancel stops between sessions
    $recent = $sess | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $recent.Key = 'claude:recent'; $recent.Id = 'recent'; $recent.LastActivity = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $r = @(Invoke-StorageArchive -Sessions @($recent) -Target $target -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock)
    Assert ($r[0].Ok -eq $false -and $r[0].Skipped -eq $true -and $r[0].Reason -like '*minutes*') 'a recent session is skipped with its reason'
    $locked = @(Invoke-StorageArchive -Sessions @($sess) -Target $target -Roots $roots -MachineId $mid -WorkDir $work -LockProbe { param($p) $true })
    Assert ($locked[0].Ok -eq $false -and (Test-Path (Join-Path $proj "$slug\$cli.jsonl"))) 'a locked session is not touched'
    $dbBad = $sess | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $dbBad.Flags | Add-Member -NotePropertyName DbUnreadable -NotePropertyValue $true -Force
    $r = @(Invoke-StorageArchive -Sessions @($dbBad) -Target $target -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock)
    Assert ($r[0].Ok -eq $false -and $r[0].Reason -like '*database*') 'DbUnreadable is refused'
    $ghost = $sess | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $ghost.Key = 'claude:ghost'; $ghost.Id = 'ghost'; foreach ($p in $ghost.Parts) { $p.Path = Join-Path $tmp 'does\not\exist.jsonl'; $p.Kind = 'file' }
    $r = @(Invoke-StorageArchive -Sessions @($ghost, $sess) -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'store4') } -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock)
    Assert ($r.Count -eq 2 -and $r[0].Ok -eq $false -and $r[1].Ok -eq $true) "a failing session does not stop the next one: $($r | ForEach-Object { '[' + $_.Ok + ' ' + $_.Reason + ']' })"
    Invoke-StorageRestore -Entries @(@(Get-StorageArchiveIndex -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'store4') })[0]) -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'store4') } -Roots $roots | Out-Null
    $cancel = @{ Cancel = $false }; $n = 0
    $r = @(Invoke-StorageArchive -Sessions @($ghost, $ghost, $ghost) -Target $target -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock -CancelToken $cancel -OnSession { $script:n++; if ($script:n -eq 1) { $cancel['Cancel'] = $true } })
    Assert ($r.Count -eq 1) "Cancel stops before the next session, not in the middle of one: $($r.Count) results"

    # ---------------------------------------------------------------- Antigravity (S17, plan A): .db/-wal/-shm and brain\<id> only; summaries and hub cache are never touched
    $agyData = Join-Path $tmp 'agy\antigravity'; $agyId = 'cccccccc-1111-4222-8333-444444444444'
    Write-Rand (Join-Path $agyData "conversations\$agyId.db") 4000 11
    Write-Rand (Join-Path $agyData "conversations\$agyId.db-wal") 1500 12
    Write-Rand (Join-Path $agyData "brain\$agyId\notes\plan.md") 700 13
    Write-Rand (Join-Path $agyData "brain\$agyId\shot.png") 900 14
    Set-Old (Join-Path $tmp 'agy')
    $agyRoots = @{ ClaudeProjects = $proj; ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @(@{ Id = 'agy1'; Name = 'Antigravity'; DataDir = $agyData; IsDefault = $false }) }
    $ags = @((Get-StorageInventory -Roots $agyRoots).Sessions | Where-Object { $_.Harness -eq 'antigravity' })[0]
    Write-Rand (Join-Path $agyData 'conversation_summaries.db') 600 15   # written after the scan: these two must come out of the run unchanged
    Write-Rand (Join-Path $agyData 'agyhub_summaries_proto.pb') 800 16
    Set-Old (Join-Path $tmp 'agy')
    $agyTree = Get-TreeHash (Join-Path $tmp 'agy')
    $ags.Parts += [pscustomobject]@{ Role = 'summary-row'; Path = (Join-Path $agyData 'conversation_summaries.db'); Bytes = 0; Kind = 'row'; Files = 0; MTimeTicks = 0; ProfileId = '' }
    $r = @(Invoke-StorageArchive -Sessions @($ags) -Target $target -Roots $agyRoots -MachineId $mid -WorkDir $work -LockProbe $noLock -Running @{ antigravity = @('agy1') })
    Assert ($r[0].Ok -eq $false -and $r[0].Skipped -and $r[0].Reason -like '*Close*' -and (Get-TreeHash (Join-Path $tmp 'agy')) -eq $agyTree) "the app of the data folder is running: nothing is touched ($($r[0].Reason))"
    $r = @(Invoke-StorageArchive -Sessions @($ags) -Target $target -Roots $agyRoots -MachineId $mid -WorkDir $work -LockProbe { param($p) $p -like '*-wal' })
    Assert ($r[0].Ok -eq $false -and (Get-TreeHash (Join-Path $tmp 'agy')) -eq $agyTree) 'a locked file (a helper process still holds it after the window closed): nothing is touched'
    $r = @(Invoke-StorageArchive -Sessions @($ags) -Target $target -Roots $agyRoots -MachineId $mid -WorkDir $work -LockProbe $noLock)
    Assert ($r[0].Ok -eq $true) "Antigravity archive: $($r[0] | ConvertTo-Json -Compress)"
    Assert (-not (Test-Path (Join-Path $agyData "conversations\$agyId.db")) -and -not (Test-Path (Join-Path $agyData "conversations\$agyId.db-wal")) -and -not (Test-Path (Join-Path $agyData "brain\$agyId"))) 'the .db, -wal and brain folder are gone'
    Assert ((Test-Path (Join-Path $agyData 'conversation_summaries.db')) -and (Test-Path (Join-Path $agyData 'agyhub_summaries_proto.pb'))) 'the summaries database and the hub cache are left alone'
    $agIx = @(Get-StorageArchiveIndex -Target $target | Where-Object { $_.harness -eq 'antigravity' })
    Assert ($agIx.Count -eq 1 -and $agIx[0].entry -like 'antigravity/*') 'indexed under antigravity/'
    $zm = (Read-StorageArchive -ZipPath (Join-Path $tmp ('store\' + $agIx[0].entry.Replace('/', '\')))).Manifest
    Assert ($zm.restore.antigravity.id -eq $agyId -and $zm.restore.antigravity.dataDir -eq $agyData) 'the manifest records dataDir and id'
    $res = @(Invoke-StorageRestore -Entries @($agIx[0]) -Target $target -Roots $agyRoots -Running @{ antigravity = @('agy1') })
    Assert ($res[0].Ok -eq $false -and $res[0].Reason -like '*Antigravity*' -and -not (Test-Path (Join-Path $agyData "conversations\$agyId.db"))) 'restore needs the app closed'
    $res = @(Invoke-StorageRestore -Entries @($agIx[0]) -Target $target -Roots $agyRoots)
    Assert ($res[0].Ok -eq $true -and (Get-TreeHash (Join-Path $tmp 'agy')) -eq $agyTree) "restore gives back every byte, nothing else changes: $($res[0].Reason)"
    $gone = @{ ClaudeProjects = $proj; ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @() }
    Remove-StorageSessionOriginal -Session $ags -Mode Delete -Roots $agyRoots | Out-Null
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = $ags.Key; ZipPath = (Join-Path $tmp ('store\' + $agIx[0].entry.Replace('/', '\'))) }) -Target $target -Roots $gone)
    Assert ($res[0].Ok -eq $false -and -not (Test-Path (Join-Path $agyData "conversations\$agyId.db"))) "an unknown data folder is refused, nothing written ($($res[0].Reason))"
    $bins = New-Object Collections.Generic.List[string]
    $threw = $null; try { Remove-StorageSessionOriginal -Session $ags -Mode Recycle -Roots $agyRoots -Recycler { param($p) $bins.Add($p) }.GetNewClosure() -VolumeInfo { param($p) @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 10000 } } } catch { $threw = $_ }
    Assert ($bins.Count -eq 0 -and $threw) 'Recycle of files that are already gone is reported (recycle-missing)'

    # ---------------------------------------------------------------- Drive: the stored copy is read back (Q1) before the original goes
    $script:ProfileRoot = Join-Path $tmp 'profile'; $script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'; $script:SwitcherHome = Join-Path $tmp 'profile\.switcher'; $script:SyncRetryDelayMs = 5
    Set-Setting 'Sync.MachineId' $mid
    $driveRoot = Join-Path $tmp 'drive\HarnessSync-test'; New-Item -ItemType Directory -Path $driveRoot -Force | Out-Null
    $kdf = New-SyncKdf -Passphrase 'test-only fake passphrase' -Iterations 1000
    $dKey = Get-SyncKey -Passphrase 'test-only fake passphrase' -Kdf $kdf
    $dTarget = @{ Kind = 'drive'; SyncRoot = $driveRoot; MachineId = $mid; Key = $dKey }
    foreach ($d in $proj, $p1, $p2) { Set-Old $d }
    $sess = @((Get-StorageInventory -Roots $roots).Sessions | Where-Object { $_.Key -eq "claude:$cli" })[0]
    $before3 = (Get-TreeHash $proj) + '||' + (Get-TreeHash $p1)
    $r = @(Invoke-StorageArchive -Sessions @($sess) -Target $dTarget -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock -OnPlaced { param($enc) $b = [IO.File]::ReadAllBytes($enc); $b[[int]($b.Length / 2)] = $b[[int]($b.Length / 2)] -bxor 1; [IO.File]::WriteAllBytes($enc, $b) })
    Assert ($r[0].Ok -eq $false -and (Get-TreeHash $proj) + '||' + (Get-TreeHash $p1) -eq $before3) "a damaged file on Drive: the original is untouched ($($r[0].Reason))"
    Assert (@(Get-ChildItem -LiteralPath $work -ErrorAction SilentlyContinue).Count -eq 0) 'the received copy and the work folder are cleaned up'
    $r = @(Invoke-StorageArchive -Sessions @($sess) -Target $dTarget -Roots $roots -MachineId $mid -WorkDir $work -LockProbe $noLock)
    Assert ($r[0].Ok -eq $true -and -not (Test-Path (Join-Path $proj "$slug\$cli.jsonl"))) "a good Drive archive is read back and then the original goes: $($r[0].Reason)"
    $dRows = @(Get-StorageArchiveIndex -Target $dTarget)
    $back = @(Invoke-StorageRestore -Entries @($dRows[0]) -Target $dTarget -Roots $roots)
    Assert ($back[0].Ok -and (Get-TreeHash $proj) + '||' + (Get-TreeHash $p1) -eq $before3) "restore from Drive gives back every byte: $($back[0].Reason)"

    # ---------------------------------------------------------------- restore puts the modified time back; an old archive without it still restores
    $mtOrig = (Get-Item -LiteralPath (Join-Path $proj "$slug\$cli.jsonl")).LastWriteTimeUtc
    Assert ([Math]::Abs(($mtOrig - [DateTime]::UtcNow.AddDays(-40)).TotalMinutes) -lt 5) 'restore from Drive kept the old modified time of the transcript'
    $sess = @((Get-StorageInventory -Roots $roots).Sessions | Where-Object { $_.Key -eq "claude:$cli" })[0]
    $a2 = New-StorageArchive -Session $sess -OutDir (Join-Path $tmp 'out3') -MachineId $mid
    Assert (@($a2.Manifest.parts | Where-Object { -not $_.mtimeUtcTicks }).Count -eq 0) 'every part of the manifest has mtimeUtcTicks'
    Remove-StorageSessionOriginal -Session $sess -Mode Delete -Roots $roots | Out-Null
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $a2.ZipPath }) -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'out3') } -Roots $roots)
    $mtNow = (Get-Item -LiteralPath (Join-Path $proj "$slug\$cli.jsonl")).LastWriteTimeUtc
    Assert ($res[0].Ok -and [Math]::Abs(($mtNow - $mtOrig).TotalSeconds) -le 2) "restored mtime equals the original within 2 s: $($mtNow.ToString('o')) vs $($mtOrig.ToString('o'))"
    $dir3 = Join-Path $proj "$slug\$cli\subagents\agent-1.jsonl"
    Assert ([Math]::Abs(((Get-Item -LiteralPath $dir3).LastWriteTimeUtc - $mtOrig).TotalMinutes) -lt 5) 'files inside a folder part get their time back too'
    $old = Join-Path $tmp 'oldformat.zip'; Copy-Item -LiteralPath $a2.ZipPath -Destination $old
    Edit-Manifest $old { param($m) foreach ($p in $m.parts) { $p.PSObject.Properties.Remove('mtimeUtcTicks') } }
    Remove-StorageSessionOriginal -Session $sess -Mode Delete -Roots $roots | Out-Null
    $res = @(Invoke-StorageRestore -Entries @(@{ Key = "claude:$cli"; ZipPath = $old }) -Target @{ Kind = 'local'; Path = (Join-Path $tmp 'out3') } -Roots $roots)
    Assert ($res[0].Ok -and (Test-Path (Join-Path $proj "$slug\$cli.jsonl"))) "an archive without mtimeUtcTicks restores: $($res[0].Reason)"
} finally {
    Remove-TestTempDir $tmp
}
Write-Output 'Storage.Archive.Tests: OK'
