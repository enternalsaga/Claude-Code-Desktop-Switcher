$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Storage.Guard.ps1')

# Fake sessions and fake probes only: nothing here asks the machine which apps are running or what its Recycle Bin allows.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('storage-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$now = [DateTime]::UtcNow
function New-Sess($harness, [string[]]$profileIds, $parts, $flags = @{}, [double]$activityDaysAgo = 10) {
    $f = @{ IsCliOnly = $false; DbUnreadable = $false }; foreach ($k in $flags.Keys) { $f[$k] = $flags[$k] }
    [pscustomobject]@{ Harness = $harness; Key = "${harness}:x"; Id = 'x'; Title = 't'; Cwd = 'C:\work'; LastActivity = [DateTimeOffset]::UtcNow.AddDays(-$activityDaysAgo).ToUnixTimeMilliseconds()
        Profiles = @($profileIds | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }); Parts = @($parts); Bytes = 1000; State = 'idle'; Flags = $f }
}
function New-FilePart($path, $ageDays = 10) { [pscustomobject]@{ Role = 'transcript'; Path = $path; Bytes = 100; Kind = 'file'; Files = 1; MTimeTicks = $now.AddDays(-$ageDays).Ticks; ProfileId = '' } }
try {
    $f1 = Join-Path $tmp 'a.jsonl'; [IO.File]::WriteAllText($f1, 'x')
    $idle = New-Sess 'claude' @('Default') @((New-FilePart $f1))
    $r = Test-StorageSessionSafe -Session $idle -Now $now
    Assert ($r.Safe -eq $true -and $r.State -eq 'idle') "an old, closed session is safe: $($r | ConvertTo-Json -Compress)"

    # live: a file somebody holds open without sharing
    $fs = [IO.File]::Open($f1, 'Open', 'ReadWrite', 'None')
    try { $r = Test-StorageSessionSafe -Session $idle -Now $now } finally { $fs.Dispose() }
    Assert ($r.Safe -eq $false -and $r.State -eq 'live' -and $r.Reason) "a locked file means live: $($r | ConvertTo-Json -Compress)"
    $r = Test-StorageSessionSafe -Session $idle -Now $now -LockProbe { param($p) $true }
    Assert ($r.State -eq 'live') 'the probe can be replaced'
    $r = Test-StorageSessionSafe -Session $idle -Now $now -LockProbe { param($p) $false }
    Assert ($r.Safe) 'probe says not locked'
    $gone = New-Sess 'claude' @('Default') @((New-FilePart (Join-Path $tmp 'missing.jsonl')))
    Assert ((Test-StorageSessionSafe -Session $gone -Now $now).Safe) 'a part that is already gone is not a lock'

    # CLI running in the same folder
    $r = Test-StorageSessionSafe -Session $idle -Now $now -CliCwds @('c:\WORK\')
    Assert ($r.State -eq 'live' -and $r.Reason -like '*claude*') 'a running Claude CLI in the same folder is live (case and trailing slash ignored)'
    Assert ((Test-StorageSessionSafe -Session $idle -Now $now -CliCwds @('C:\other')).Safe) 'another folder does not matter'

    # protected: the profile's app is running
    $r = Test-StorageSessionSafe -Session $idle -Now $now -Running @{ claude = @('Default') }
    Assert ($r.Safe -eq $false -and $r.State -eq 'protected' -and $r.Reason -like '*Default*') "running Claude profile: $($r | ConvertTo-Json -Compress)"
    Assert ((Test-StorageSessionSafe -Session $idle -Now $now -Running @{ claude = @('Other') }).Safe) 'a different running profile does not block'
    $shared = New-Sess 'claude' @('Default', 'Work') @((New-FilePart $f1))
    Assert ((Test-StorageSessionSafe -Session $shared -Now $now -Running @{ claude = @('Work') }).State -eq 'protected') 'any profile that refers to the session counts'
    $cx = New-Sess 'codex' @('Default') @((New-FilePart $f1))
    Assert ((Test-StorageSessionSafe -Session $cx -Now $now -Running @{ codex = @('Default') }).Safe) 'Codex goes through its app-server, so a running app does not block'
    $ag = New-Sess 'antigravity' @('app') @((New-FilePart $f1))
    Assert ((Test-StorageSessionSafe -Session $ag -Now $now -Running @{ antigravity = @('app') }).State -eq 'protected') 'a running Antigravity blocks'

    # recent: activity or any file newer than the window
    $recentFile = New-Sess 'claude' @('Default') @((New-FilePart $f1 0))
    $recentFile.Parts[0].MTimeTicks = $now.AddMinutes(-5).Ticks
    $r = Test-StorageSessionSafe -Session $recentFile -Now $now
    Assert ($r.Safe -eq $false -and $r.State -eq 'recent') 'a file written 5 minutes ago is recent'
    $r = Test-StorageSessionSafe -Session $recentFile -Now $now -RecentMinutes 3
    Assert ($r.Safe) 'the window can be changed'
    $r = Test-StorageSessionSafe -Session $recentFile -Now $now -IncludeRecent
    Assert ($r.Safe -eq $true -and $r.State -eq 'recent' -and $r.Reason -like '*anyway*') 'Include anyway lets a recent session through, and still says recent'
    $recentAct = New-Sess 'claude' @('Default') @((New-FilePart $f1)) @{} 0
    Assert ((Test-StorageSessionSafe -Session $recentAct -Now $now).State -eq 'recent') 'activity just now is recent even when the files are old'
    $liveAndRecent = Test-StorageSessionSafe -Session $recentFile -Now $now -IncludeRecent -LockProbe { param($p) $true }
    Assert ($liveAndRecent.Safe -eq $false -and $liveAndRecent.State -eq 'live') 'Include anyway never overrides live'
    $prot = Test-StorageSessionSafe -Session $recentFile -Now $now -IncludeRecent -Running @{ claude = @('Default') }
    Assert ($prot.Safe -eq $false -and $prot.State -eq 'protected') 'nor protected'

    # a database that could not be read
    $bad = New-Sess 'codex' @('Default') @((New-FilePart $f1)) @{ DbUnreadable = $true }
    $r = Test-StorageSessionSafe -Session $bad -Now $now
    Assert ($r.Safe -eq $false -and $r.Reason -like '*database*') 'DbUnreadable is refused'
    Assert ((Test-StorageSessionSafe -Session $bad -Now $now -IncludeRecent).Safe -eq $false) 'and Include anyway does not change that'

    # ---------------------------------------------------------------- paths
    $roots = @('C:\data\projects', 'D:\codex home')
    Assert (Test-StoragePathAllowed -Path 'C:\data\projects\slug\a.jsonl' -Roots $roots) 'under a root'
    Assert (Test-StoragePathAllowed -Path 'c:\DATA\Projects\slug\a.jsonl' -Roots $roots) 'case does not matter'
    Assert (Test-StoragePathAllowed -Path 'D:\codex home\sessions\2026\11\15\r.jsonl' -Roots $roots) 'a root with a space'
    Assert (-not (Test-StoragePathAllowed -Path 'C:\data\projects\..\secrets\a.jsonl' -Roots $roots)) 'a .. segment is refused even when it stays inside'
    Assert (-not (Test-StoragePathAllowed -Path 'C:\data\projects\slug\..\..\x' -Roots $roots)) 'escaping with ..'
    Assert (-not (Test-StoragePathAllowed -Path 'C:\data\projectsX\a.jsonl' -Roots $roots)) 'a sibling with the same prefix is not under the root'
    Assert (-not (Test-StoragePathAllowed -Path 'C:\data\projects' -Roots $roots)) 'the root itself is not a file under it'
    Assert (-not (Test-StoragePathAllowed -Path 'E:\elsewhere\a.jsonl' -Roots $roots)) 'outside every root'
    Assert (-not (Test-StoragePathAllowed -Path 'relative\a.jsonl' -Roots $roots)) 'a relative path'
    Assert (-not (Test-StoragePathAllowed -Path '' -Roots $roots) -and -not (Test-StoragePathAllowed -Path 'C:\data\projects\a' -Roots @())) 'empty path or no roots'
    Assert (-not (Test-StoragePathAllowed -Path "C:\data\projects\a`0b" -Roots $roots)) 'a NUL character'

    # ---------------------------------------------------------------- Recycle Bin: all four conditions, per volume
    $vol = { param($p) @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 1000 } }
    $one = New-Sess 'claude' @('Default') @([pscustomobject]@{ Role = 'transcript'; Path = 'C:\a\b.jsonl'; Bytes = 5MB; Kind = 'file'; Files = 1; MTimeTicks = 0; ProfileId = '' })
    $one.Bytes = 5MB
    $r = Test-StorageRecyclable -Session $one -VolumeInfo $vol
    Assert ($r.Ok -eq $true) "all four conditions hold: $($r | ConvertTo-Json -Compress)"
    $try = { param($info) Test-StorageRecyclable -Session $one -VolumeInfo ({ param($p) $info }.GetNewClosure()) }
    $r = & $try @{ DriveType = 'Network'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 1000 }
    Assert ($r.Ok -eq $false -and $r.Reason -like '*Recycle Bin*archive it instead*') "a network drive: $($r.Reason)"
    Assert ((& $try @{ DriveType = 'Removable'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 1000 }).Ok -eq $false) 'a removable drive'
    Assert ((& $try @{ DriveType = 'Fixed'; IsDriveFs = $true; NukeOnDelete = 0; MaxCapacityMB = 1000 }).Ok -eq $false) 'a Google Drive drive'
    Assert ((& $try @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 1; MaxCapacityMB = 1000 }).Ok -eq $false) 'NukeOnDelete=1 deletes for good'
    Assert ((& $try @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = $null; MaxCapacityMB = 1000 }).Ok -eq $false) 'NukeOnDelete missing: unknown, so refused'
    Assert ((& $try @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = $null }).Ok -eq $false) 'no MaxCapacity: unknown, so refused'
    Assert ((& $try @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 5 }).Ok -eq $false) 'exactly the capacity is not smaller than it'
    Assert ((& $try @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 6 }).Ok -eq $true) 'just under the capacity'
    Assert ((Test-StorageRecyclable -Session $one -VolumeInfo { param($p) $null }).Ok -eq $false) 'no information about the volume: refused'
    Assert ((Test-StorageRecyclable -Session $one -VolumeInfo { param($p) throw 'registry unreadable' }).Ok -eq $false) 'a probe that throws: refused'
    # parts are added up per volume, not judged one by one
    $two = New-Sess 'claude' @('Default') @(
        [pscustomobject]@{ Role = 'transcript'; Path = 'C:\a\1.jsonl'; Bytes = 600MB; Kind = 'file'; Files = 1; MTimeTicks = 0; ProfileId = '' },
        [pscustomobject]@{ Role = 'cli-dir'; Path = 'C:\a\1'; Bytes = 600MB; Kind = 'dir'; Files = 3; MTimeTicks = 0; ProfileId = '' })
    Assert ((Test-StorageRecyclable -Session $two -VolumeInfo $vol).Ok -eq $false) 'two parts of 600 MB on a 1000 MB bin: refused as one deletion'
    # two volumes: each is judged on its own
    $split = New-Sess 'claude' @('Default') @(
        [pscustomobject]@{ Role = 'transcript'; Path = 'C:\a\1.jsonl'; Bytes = 600MB; Kind = 'file'; Files = 1; MTimeTicks = 0; ProfileId = '' },
        [pscustomobject]@{ Role = 'profile-meta'; Path = 'D:\p\local_a.json'; Bytes = 1KB; Kind = 'file'; Files = 1; MTimeTicks = 0; ProfileId = 'Default' })
    $mixed = { param($p) if ($p -like 'D:*') { @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 1000 } } else { @{ DriveType = 'Fixed'; IsDriveFs = $false; NukeOnDelete = 0; MaxCapacityMB = 100 } } }
    $r = Test-StorageRecyclable -Session $split -VolumeInfo $mixed
    Assert ($r.Ok -eq $false) 'one volume too small is enough to refuse'
    $rows = Test-StorageRecyclable -Session ([pscustomobject]@{ Parts = @([pscustomobject]@{ Role = 'row'; Path = 'C:\state.sqlite'; Bytes = 0; Kind = 'row'; Files = 0 }); Bytes = 0 }) -VolumeInfo $vol
    Assert ($rows.Ok -eq $true) 'a database row is not a file and is not judged'
} finally {
    Remove-TestTempDir $tmp
}
Write-Output 'Storage.Guard.Tests: OK'
