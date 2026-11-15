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

# Fake trees under %TEMP%\storage-test-*. The Recycle Bin, the volume and the Codex app-server are all fakes: nothing here
# reaches the real bin, the registry or a real CODEX_HOME.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('storage-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
function Write-Text($path, $text) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null; [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }
function Set-Old($dir) { foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File) { $f.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40) } }
$okVolume = { param($p) @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 10000 } }
$nukeVolume = { param($p) @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 1; MaxCapacityMB = 10000 } }
try {
    # ---------------------------------------------------------------- Claude: Recycle only when the bin keeps the files
    $cli = 'bbbbbbbb-0000-4000-8000-000000000002'; $cwd = 'C:\work\beta'
    $proj = Join-Path $tmp 'claude\projects'; $slug = ConvertTo-ClaudeProjectSlug $cwd; $p1 = Join-Path $tmp 'p1'
    Write-Text (Join-Path $proj "$slug\$cli.jsonl") ('{"type":"user","sessionId":"' + $cli + '","cwd":"C:\\work\\beta","timestamp":"2026-10-01T08:00:00.000Z","message":{"role":"user","content":"hi"}}' + "`n")
    Write-Text (Join-Path $proj "$slug\$cli\tool-results\out.txt") 'out'
    Write-Text (Join-Path $p1 'claude-code-sessions\a\o\local_b1.json') ('{"cliSessionId":"' + $cli + '","title":"B","cwd":"C:\\work\\beta","createdAt":1759300000000,"lastActivityAt":1759300000000}')
    foreach ($d in $proj, $p1) { Set-Old $d }
    $roots = @{ ClaudeProjects = $proj; ClaudeProfiles = @(@{ Id = 'Default'; Name = 'Default'; SessionRoot = (Join-Path $p1 'claude-code-sessions'); DataDir = $p1; IsDefault = $true }); CodexHomes = @(); AgyDirs = @() }
    $sess = @((Get-StorageInventory -Roots $roots).Sessions | Where-Object { $_.Key -eq "claude:$cli" })[0]
    $bin = New-Object Collections.Generic.List[string]
    $recycler = { param($p) $bin.Add($p) }.GetNewClosure()

    $threw = $null; try { Remove-StorageSessionOriginal -Session $sess -Mode Recycle -Roots $roots -Recycler $recycler -VolumeInfo $nukeVolume } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'recycle-refused*' -and $threw -like '*archive it instead*' -and $bin.Count -eq 0 -and (Test-Path (Join-Path $proj "$slug\$cli.jsonl"))) "a bin that deletes for good: refused, nothing moved ($threw)"
    $threw = $null; try { Remove-StorageSessionOriginal -Session $sess -Mode Recycle -Roots $roots -Recycler $recycler -VolumeInfo { param($p) throw 'registry unreadable' } } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'recycle-refused*' -and $bin.Count -eq 0) 'a probe that throws counts as no'
    $rm = Remove-StorageSessionOriginal -Session $sess -Mode Recycle -Roots $roots -Recycler $recycler -VolumeInfo $okVolume
    Assert ($bin.Count -eq 3 -and $rm.Removed.Count -eq 3) "all three parts went through the fake recycler: $($bin.Count)"
    Assert ((Test-Path (Join-Path $proj "$slug\$cli.jsonl"))) 'the fake recycler moved nothing itself, so the files are still there'

    # a path outside the known folders is never removed
    $evil = $sess | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $evil.Parts[0].Path = (Join-Path $tmp 'elsewhere\x.jsonl'); Write-Text $evil.Parts[0].Path 'x'
    $threw = $null; try { Remove-StorageSessionOriginal -Session $evil -Mode Delete -Roots $roots } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'remove-refused*' -and (Test-Path $evil.Parts[0].Path)) 'a part outside the Claude folders is refused'
    $dbBad = $sess | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $dbBad.Flags | Add-Member -NotePropertyName DbUnreadable -NotePropertyValue $true -Force
    $threw = $null; try { Remove-StorageSessionOriginal -Session $dbBad -Mode Delete -Roots $roots } catch { $threw = $_.Exception.Message }
    Assert ($threw -like '*database*' -and (Test-Path (Join-Path $proj "$slug\$cli.jsonl"))) 'DbUnreadable is refused for removal'
    $threw = $null; try { Invoke-StorageRecycle -Session $dbBad -Paths @('x') -Recycler $recycler -VolumeInfo $okVolume } catch { $threw = $_.Exception.Message }
    Assert ($threw -like '*database*') 'and for the Recycle Bin'

    # ---------------------------------------------------------------- Codex: all of it goes through the app-server
    $codexHome = Join-Path $tmp 'codex'; $tid = '019aaaaa-0000-7000-8000-000000000003'
    $rel = "sessions\2026\10\01\rollout-2026-10-01T08-00-00-$tid.jsonl"
    $rollout = Join-Path $codexHome $rel
    Write-Text $rollout ('{"type":"session_meta","payload":{"id":"' + $tid + '"}}' + "`n")
    (Get-Item -LiteralPath $rollout).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
    $cxRoots = @{ ClaudeProjects = $proj; ClaudeProfiles = @(); CodexHomes = @(@{ Id = 'Default'; Name = 'Default'; Home = $codexHome }); AgyDirs = @() }
    $cx = [pscustomobject]@{ Harness = 'codex'; Key = "codex:$tid.12345678"; Id = $tid; Title = 'Codex chat'; Cwd = 'C:\work\beta'; LastActivity = ([DateTimeOffset]::UtcNow.AddDays(-40).ToUnixTimeMilliseconds()); Created = 1759300000000
        Profiles = @([pscustomobject]@{ Id = 'Default'; Name = 'Default' }); Bytes = 40; State = 'idle'; Flags = @{}
        Parts = @([pscustomobject]@{ Role = 'rollout'; Path = $rollout; Bytes = 40; Kind = 'file'; Files = 1; MTimeTicks = (Get-Item -LiteralPath $rollout).LastWriteTimeUtc.Ticks; ProfileId = 'Default' }) }
    $calls = New-Object Collections.Generic.List[string]
    $rpc = { param($CodexHome, $Method, $Params) $calls.Add("$Method $($Params.threadId)"); if ($Method -eq 'thread/archive') { $dst = Join-Path $CodexHome 'archived_sessions'; New-Item -ItemType Directory -Path $dst -Force | Out-Null; Move-Item -LiteralPath $rollout -Destination $dst } }.GetNewClosure()

    # Delete (after a verified archive) = thread/delete only; this fake does not move the file, so the test checks the call
    $rm = Remove-StorageSessionOriginal -Session $cx -Mode Delete -Roots $cxRoots -CodexRpc $rpc
    Assert ($calls.Count -eq 1 -and $calls[0] -eq "thread/delete $tid" -and $rm.Removed.Count -eq 1) "Delete is thread/delete: $($calls -join ',')"
    $threw = $null; try { Remove-StorageSessionOriginal -Session $cx -Mode Delete -Roots $cxRoots } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'codex-rpc-missing*') 'no app-server, no removal'

    # Recycle = refused first when the bin would not keep it (no thread/archive call), else archive then recycle the archived file
    $calls.Clear(); $bin.Clear()
    $threw = $null; try { Remove-StorageSessionOriginal -Session $cx -Mode Recycle -Roots $cxRoots -CodexRpc $rpc -Recycler $recycler -VolumeInfo $nukeVolume } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'recycle-refused*' -and $calls.Count -eq 0 -and (Test-Path $rollout)) 'the Recycle Bin is asked BEFORE Codex is told to archive: nothing moved'
    $rm = Remove-StorageSessionOriginal -Session $cx -Mode Recycle -Roots $cxRoots -CodexRpc $rpc -Recycler $recycler -VolumeInfo $okVolume
    $arch = Join-Path $codexHome "archived_sessions\rollout-2026-10-01T08-00-00-$tid.jsonl"
    Assert ($calls.Count -eq 1 -and $calls[0] -eq "thread/archive $tid" -and $bin.Count -eq 1 -and $bin[0] -eq $arch -and (Test-Path $arch)) "archive first, then the file in archived_sessions goes to the bin: $($calls -join ',') / $($bin -join ',')"

    # a full archive-and-restore of a Codex session with the fake app-server: delete via thread/delete, restore + thread/read
    Move-Item -LiteralPath $arch -Destination $rollout
    $store = @{ Kind = 'local'; Path = (Join-Path $tmp 'store') }; $calls.Clear()
    $delRpc = { param($CodexHome, $Method, $Params) $calls.Add("$Method $($Params.threadId)"); if ($Method -eq 'thread/delete') { Remove-Item -LiteralPath $rollout -Force } }.GetNewClosure()
    $r = @(Invoke-StorageArchive -Sessions @($cx) -Target $store -Roots $cxRoots -MachineId 'aaaaaaaa-0000-4000-8000-0000000000aa' -WorkDir (Join-Path $tmp 'work') -LockProbe { param($p) $false } -CodexRpc $delRpc)
    Assert ($r[0].Ok -and -not (Test-Path $rollout) -and $calls -contains "thread/delete $tid") "archive then thread/delete: $($r[0] | ConvertTo-Json -Compress)"
    $ix = @(Get-StorageArchiveIndex -Target $store)
    Assert ($ix.Count -eq 1 -and $ix[0].key -eq $cx.Key) 'indexed'
    $calls.Clear()
    $back = @(Invoke-StorageRestore -Entries @($ix[0]) -Target $store -Roots $cxRoots -CodexRpc $rpc)
    Assert ($back[0].Ok -and (Test-Path $rollout) -and $calls.Count -eq 1 -and $calls[0] -eq "thread/read $tid") "the rollout is back under sessions\yyyy\mm\dd and Codex is asked to read it: $($back[0] | ConvertTo-Json -Compress)"
    Assert ([IO.File]::ReadAllText($rollout).Contains($tid)) 'same content'

    # a recycle of a file that is not there is an error, not a silent success (the fake app-server moves nothing here)
    $calls.Clear(); $bin.Clear()
    $noMove = { param($CodexHome, $Method, $Params) $calls.Add("$Method $($Params.threadId)") }.GetNewClosure()
    $threw = $null; try { Remove-StorageSessionOriginal -Session $cx -Mode Recycle -Roots $cxRoots -CodexRpc $noMove -Recycler $recycler -VolumeInfo $okVolume } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'recycle-missing*' -and $bin.Count -eq 0) "a path that is not there is reported, not counted as removed ($threw)"

    # Codex cases (a) already archived: no second thread/archive, the file in archived_sessions is recycled
    $calls.Clear(); $bin.Clear()
    $archPath = Join-Path $codexHome "archived_sessions\rollout-2026-10-01T08-00-00-$tid.jsonl"; Write-Text $archPath 'archived'
    $cxA = $cx.PSObject.Copy(); $cxA.Flags = @{ CodexArchived = $true }; $cxA.Parts = @([pscustomobject]@{ Role = 'rollout'; Path = $archPath; Bytes = 8; Kind = 'file'; Files = 1; MTimeTicks = 1; ProfileId = 'Default' })
    $rm = Remove-StorageSessionOriginal -Session $cxA -Mode Recycle -Roots $cxRoots -CodexRpc $rpc -Recycler $recycler -VolumeInfo $okVolume
    Assert ($calls.Count -eq 0 -and $bin.Count -eq 1 -and $bin[0] -eq $archPath) "an archived thread: no thread/archive, its file goes to the bin ($($calls -join ','))"
    # (b) a rollout with no row: no RPC at all, the file is removed directly, inside CODEX_HOME only
    $calls.Clear(); $bin.Clear()
    $cxN = $cx.PSObject.Copy(); $cxN.Flags = @{ NoRow = $true }
    $rm = Remove-StorageSessionOriginal -Session $cxN -Mode Recycle -Roots $cxRoots -CodexRpc $rpc -Recycler $recycler -VolumeInfo $okVolume
    Assert ($calls.Count -eq 0 -and $bin.Count -eq 1 -and $bin[0] -eq $rollout) 'no row: Recycle sends the file to the bin without any RPC'
    $rm = Remove-StorageSessionOriginal -Session $cxN -Mode Delete -Roots $cxRoots -CodexRpc $rpc
    Assert ($calls.Count -eq 0 -and -not (Test-Path $rollout)) 'no row: Delete removes the file directly, no RPC'
    Write-Text $rollout 'x'
    $cxOut = $cxN.PSObject.Copy(); $cxOut.Parts = @([pscustomobject]@{ Role = 'rollout'; Path = (Join-Path $tmp 'elsewhere\r.jsonl'); Bytes = 1; Kind = 'file'; Files = 1; MTimeTicks = 1; ProfileId = 'Default' }); Write-Text $cxOut.Parts[0].Path 'x'
    $threw = $null; try { Remove-StorageSessionOriginal -Session $cxOut -Mode Delete -Roots $cxRoots } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'remove-refused*' -and (Test-Path $cxOut.Parts[0].Path)) 'no row: a file outside CODEX_HOME is refused'
    # (c) a row with no file: Delete still calls thread/delete, Recycle says there is nothing to recycle
    $calls.Clear(); $bin.Clear()
    $cxF = $cx.PSObject.Copy(); $cxF.Flags = @{ NoFile = $true }; $cxF.Parts = @()
    $rm = Remove-StorageSessionOriginal -Session $cxF -Mode Delete -Roots $cxRoots -CodexRpc $rpc
    Assert ($calls.Count -eq 1 -and $calls[0] -eq "thread/delete $tid") 'no file: Delete calls thread/delete'
    $calls.Clear()
    $threw = $null; try { Remove-StorageSessionOriginal -Session $cxF -Mode Recycle -Roots $cxRoots -CodexRpc $rpc -Recycler $recycler -VolumeInfo $okVolume } catch { $threw = $_.Exception.Message }
    Assert ($threw -like '*nothing to send to the Recycle Bin*' -and $calls.Count -eq 0 -and $bin.Count -eq 0) 'no file: Recycle is refused with a clear reason'
} finally {
    Remove-TestTempDir $tmp
}
Write-Output 'Storage.Harness.Tests: OK'
