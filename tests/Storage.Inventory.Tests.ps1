$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Harness.Sqlite.ps1')
. (Join-Path $root 'src\Harness.Codex.Chats.ps1')
. (Join-Path $root 'src\Storage.Scan.ps1')
. (Join-Path $root 'src\Storage.Inventory.ps1')
. (Join-Path $root 'src\Storage.Inventory.Antigravity.ps1')

# Only a fake tree under %TEMP%\storage-test-*; nothing of ~\.claude, CODEX_HOME or Antigravity is ever touched.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('storage-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$cli1 = 'aaaaaaaa-0000-4000-8000-000000000001'   # in both profiles, has a <cli>\subagents folder
$cli2 = 'aaaaaaaa-0000-4000-8000-000000000002'   # in profile P1 only
$cli3 = 'aaaaaaaa-0000-4000-8000-000000000003'   # CLI only
function Write-Bytes($path, [int]$n) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null; [IO.File]::WriteAllBytes($path, (New-Object byte[] $n)) }
function Write-Text($path, $text) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null; [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }
function Get-Session($inv, $key) { @($inv.Sessions | Where-Object { $_.Key -eq $key })[0] }
try {
    # ---------------------------------------------------------------- I1-1: Claude sessions, shared transcripts, CLI-only
    $proj = Join-Path $tmp 'claude\projects'
    $slugA = Join-Path $proj 'C--work-alpha'; $slugB = Join-Path $proj 'C--work-beta'
    $line = { param($cli, $ts, $extra = '') '{"type":"user","sessionId":"' + $cli + '","cwd":"C:\\work\\alpha","timestamp":"' + $ts + '"' + $extra + ',"message":{"role":"user","content":"first words of ' + $cli.Substring(30) + '"}}' }
    Write-Text (Join-Path $slugA "$cli1.jsonl") ((& $line $cli1 '2026-11-10T08:00:00.000Z') + "`n" + (& $line $cli1 '2026-11-10T09:30:00.000Z') + "`n")
    Write-Bytes (Join-Path $slugA "$cli1\subagents\agent-1.jsonl") 1000
    Write-Text (Join-Path $slugA "$cli2.jsonl") ((& $line $cli2 '2026-11-11T08:00:00.000Z') + "`n")
    Write-Text (Join-Path $slugB "$cli3.jsonl") ((& $line $cli3 '2026-11-12T08:00:00.000Z') + "`n" + '{"type":"custom-title","customTitle":"Renamed in the CLI","sessionId":"' + $cli3 + '"}' + "`n" + (& $line $cli3 '2026-11-12T11:45:00.000Z') + "`n")
    Write-Bytes (Join-Path $slugB 'memory\notes.md') 50          # not a session
    $p1 = Join-Path $tmp 'p1'; $p2 = Join-Path $tmp 'p2'
    $localJson = { param($cli, $title, $act) '{"cliSessionId":"' + $cli + '","title":"' + $title + '","cwd":"C:\\work\\alpha","createdAt":1762761600000,"lastActivityAt":' + $act + '}' }
    Write-Text (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x1.json') (& $localJson $cli1 'Shared chat' 1762800000000)
    Write-Text (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x2.json') (& $localJson $cli2 'Only in P1' 1762850000000)
    Write-Text (Join-Path $p2 'claude-code-sessions\acct2\org2\local_y1.json') (& $localJson $cli1 'Shared chat' 1762810000000)
    Write-Bytes (Join-Path $p1 'Cache\blob.bin') 4000
    Write-Bytes (Join-Path $p2 'Cache\blob.bin') 2000
    $profiles = @(
        @{ Id = 'Default'; Name = 'Default'; SessionRoot = (Join-Path $p1 'claude-code-sessions'); DataDir = $p1; IsDefault = $true },
        @{ Id = 'Work'; Name = 'Work'; SessionRoot = (Join-Path $p2 'claude-code-sessions'); DataDir = $p2; IsDefault = $false }
    )
    $roots = @{ ClaudeProjects = $proj; ClaudeProfiles = $profiles; CodexHomes = @(); AgyDirs = @() }
    $inv = Get-StorageInventory -Roots $roots
    $claude = @($inv.Sessions | Where-Object { $_.Harness -eq 'claude' })
    Assert ($claude.Count -eq 3) "three Claude sessions, got $($claude.Count)"
    $s1 = Get-Session $inv "claude:$cli1"
    Assert ($s1.Profiles.Count -eq 2 -and (@($s1.Profiles.Id | Sort-Object) -join ',') -eq 'Default,Work') 'a transcript shared by two profiles is one session that lists both'
    $roles = @($s1.Parts | ForEach-Object { $_.Role } | Sort-Object)
    Assert (($roles -join ',') -eq 'cli-dir,profile-meta,profile-meta,transcript') "parts: jsonl, <cli> folder and both local files, got $($roles -join ',')"
    $dirPart = @($s1.Parts | Where-Object { $_.Role -eq 'cli-dir' })[0]
    Assert ($dirPart.Kind -eq 'dir' -and $dirPart.Bytes -eq 1000) 'the <cli> folder is summed'
    Assert ($s1.Bytes -eq (($s1.Parts | Measure-Object Bytes -Sum).Sum) -and $s1.Bytes -gt 1000) 'Bytes is the sum of the parts'
    Assert ($s1.Title -eq 'Shared chat' -and $s1.Cwd -eq 'C:\work\alpha') 'title and folder come from the profile file'
    Assert ($s1.Flags.IsCliOnly -eq $false -and $s1.Flags.Trimmable -eq $true -and $s1.Harness -eq 'claude') 'a Desktop chat is not CLI-only and can be trimmed'
    $tx1 = [DateTimeOffset]::Parse('2026-11-10T09:30:00Z').ToUnixTimeMilliseconds()
    Assert ($s1.LastActivity -eq $tx1) "last activity: the newest of the profile files (2025) and the transcript tail (2026), got $($s1.LastActivity)"
    Assert ((Get-Session $inv "claude:$cli2").LastActivity -eq [DateTimeOffset]::Parse('2026-11-11T08:00:00Z').ToUnixTimeMilliseconds()) 'a transcript newer than its profile file wins'
    Assert ($s1.Created -eq 1762761600000) 'created comes from the profile file'
    $s3 = Get-Session $inv "claude:$cli3"
    Assert ($s3.Flags.IsCliOnly -eq $true -and $s3.Profiles.Count -eq 0 -and $s3.Parts.Count -eq 1) 'a transcript with no profile file is CLI-only'
    Assert ($s3.Title -eq 'Renamed in the CLI') "CLI-only title comes from the transcript: $($s3.Title)"
    Assert ($s3.LastActivity -eq [DateTimeOffset]::Parse('2026-11-12T11:45:00.000Z').ToUnixTimeMilliseconds()) 'CLI-only last activity is the last timestamp in the tail'
    Assert ($s3.Cwd -eq 'C:\work\alpha') 'CLI-only folder comes from the head'
    $s2 = Get-Session $inv "claude:$cli2"
    Assert ($s2.Title -eq 'Only in P1' -and $s2.Profiles.Count -eq 1) 'a chat of one profile'
    Assert ($inv.Totals.Sessions -eq 3 -and $inv.Totals.Bytes -eq (($inv.Sessions | Measure-Object Bytes -Sum).Sum)) 'totals count every session once'
    Assert ($inv.Totals.ByHarness.claude.Sessions -eq 3 -and $null -ne $inv.ScannedAt -and $inv.Files -gt 0) 'totals, time and file count'
    $pd = @($inv.Profiles | Where-Object { $_.Id -eq 'Work' })[0]
    Assert ($pd.Harness -eq 'claude' -and $pd.DataBytes -ge 2000 -and $pd.DataDir -eq $p2) 'the profile folder is measured'
    # a session whose files are older than the recent window is idle, a fresh one is recent
    $now = [DateTime]::UtcNow
    Assert ($s1.State -eq 'idle' -or $s1.State -eq 'recent') 'state is idle or recent (live and protected are the guard''s call)'
    (Get-Item (Join-Path $slugB "$cli3.jsonl")).LastWriteTimeUtc = $now.AddMinutes(-5)
    (Get-Item (Join-Path $slugA "$cli2.jsonl")).LastWriteTimeUtc = $now.AddDays(-40)
    $inv = Get-StorageInventory -Roots $roots -RecentMinutes 30
    Assert ((Get-Session $inv "claude:$cli3").State -eq 'recent') 'a transcript written 5 minutes ago is recent'
    Assert ((Get-Session $inv "claude:$cli2").State -eq 'recent') 'a local file written just now keeps the chat recent'
    (Get-Item (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x2.json')).LastWriteTimeUtc = $now.AddDays(-40)
    $inv = Get-StorageInventory -Roots $roots -RecentMinutes 30
    Assert ((Get-Session $inv "claude:$cli2").State -eq 'idle') 'old files: idle'

    # ---------------------------------------------------------------- I1-6: the cache
    $cache = New-StorageCache
    $inv1 = Get-StorageInventory -Roots $roots -Cache $cache
    $firstReads = $cache.Reads
    Assert ($firstReads -ge 6) "the first scan reads the files (3 transcripts, 3 profile files): $firstReads"
    $inv2 = Get-StorageInventory -Roots $roots -Cache $cache
    Assert ($cache.Reads -eq $firstReads) "the second scan opens nothing: $($cache.Reads - $firstReads) reads"
    Assert (($inv2.Sessions | ForEach-Object { $_.Key + $_.Title + $_.Bytes } | Sort-Object) -join '|' -eq (($inv1.Sessions | ForEach-Object { $_.Key + $_.Title + $_.Bytes } | Sort-Object) -join '|')) 'the cached scan gives the same sessions'
    (Get-Item (Join-Path $slugB "$cli3.jsonl")).LastWriteTimeUtc = $now.AddHours(-3)
    $before = $cache.Reads
    [void](Get-StorageInventory -Roots $roots -Cache $cache)
    Assert ($cache.Reads -eq $before + 1) "one changed file is read again, only that one: $($cache.Reads - $before)"
    $cachePath = Join-Path $tmp 'cache\storage-cache.json'
    Write-StorageCache -Cache $cache -Path $cachePath
    $reloaded = Read-StorageCache -Path $cachePath
    [void](Get-StorageInventory -Roots $roots -Cache $reloaded)
    Assert ($reloaded.Reads -eq 0) "a cache loaded from disk is as good as the one in memory: $($reloaded.Reads) reads"
    Remove-Item -LiteralPath (Join-Path $p1 'claude-code-sessions\acct1\org1\local_x2.json')
    [void](Get-StorageInventory -Roots $roots -Cache $cache)
    Assert (-not $cache.Entries.ContainsKey((Join-Path $p1 'claude-code-sessions\acct1\org1\local_x2.json'))) 'a file that is gone leaves the cache'

    # ---------------------------------------------------------------- I1-8: junctions and unreadable folders do not stop the scan
    $elsewhere = Join-Path $tmp 'elsewhere'
    Write-Text (Join-Path $elsewhere 'aaaaaaaa-0000-4000-8000-0000000000ff.jsonl') ((& $line 'aaaaaaaa-0000-4000-8000-0000000000ff' '2026-11-01T00:00:00.000Z') + "`n")
    $link = Join-Path $proj 'C--linked'
    New-Item -ItemType Junction -Path $link -Target $elsewhere | Out-Null
    try {
        $invJ = Get-StorageInventory -Roots $roots
        Assert (@($invJ.Sessions | Where-Object { $_.Key -like '*0000000000ff' }).Count -eq 0) 'a junction under projects is not followed'
        Assert (@($invJ.Sessions | Where-Object { $_.Harness -eq 'claude' }).Count -eq 3) 'the rest is listed as before'
    } finally { [IO.Directory]::Delete($link) }
    $missing = @{ ClaudeProjects = (Join-Path $tmp 'no\projects'); ClaudeProfiles = @(@{ Id = 'X'; Name = 'X'; SessionRoot = (Join-Path $tmp 'no\sessions'); DataDir = (Join-Path $tmp 'no\data'); IsDefault = $false }); CodexHomes = @(); AgyDirs = @() }
    $invM = Get-StorageInventory -Roots $missing
    Assert ($invM.Sessions.Count -eq 0 -and $invM.Profiles.Count -eq 1) 'roots that do not exist give an empty inventory, not an error'

    # ---------------------------------------------------------------- I1-3: Codex
    function New-CodexStateFixture {
        param([string]$Path, [string[]]$InsertSql)
        Initialize-WinSqlite
        $h = [IntPtr]::Zero
        Assert (([HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 $Path), [ref]$h, 6, [IntPtr]::Zero)) -eq 0) 'fixture open'
        $ddl = 'create table threads (id text primary key, rollout_path text not null, created_at integer not null default 0, updated_at integer not null default 0, source text not null default '''', model_provider text not null default ''openai'', cwd text not null default '''', title text not null default '''', archived integer not null default 0, cli_version text not null default '''', thread_source text, preview text not null default '''', name text, updated_at_ms integer, first_user_message text not null default '''');' + ($InsertSql -join ';') + ';'
        $rc = [HarnessWinSqlite]::sqlite3_exec($h, (ConvertTo-SqliteUtf8 $ddl), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
        $err = [HarnessWinSqlite]::Err($h)
        [void][HarnessWinSqlite]::sqlite3_close($h)
        Assert ($rc -eq 0) "fixture ddl: $err"
    }
    $cxHome = Join-Path $tmp 'codex\home'
    $tA = '019a0000-0000-7000-8000-00000000000a'; $tB = '019a0000-0000-7000-8000-00000000000b'
    $rolloutA = Join-Path $cxHome "sessions\2026\11\14\rollout-2026-11-14T10-00-00-$tA.jsonl"
    $rolloutB = Join-Path $cxHome "archived_sessions\rollout-2026-11-01T10-00-00-$tB.jsonl.zst"
    Write-Text $rolloutA ('{"type":"session_meta","payload":{"id":"' + $tA + '"}}' + "`n")
    Write-Bytes $rolloutB 3000
    Write-Bytes (Join-Path $cxHome 'auth.json') 500
    Write-Bytes (Join-Path $cxHome 'logs\log.bin') 700
    New-CodexStateFixture -Path (Join-Path $cxHome 'state_5.sqlite') -InsertSql @(
        "insert into threads(id,rollout_path,source,cwd,title,archived,created_at,updated_at,updated_at_ms) values('$tA','$($rolloutA.Replace('\','\\'))','vscode','C:\work\alpha','Codex active',0,1762700000,1762800000,1762800000123)",
        "insert into threads(id,rollout_path,source,cwd,title,archived,created_at,updated_at) values('$tB','x','cli','C:\work\beta','Codex old',1,1762000000,1762100000)")
    $cxRoots = @{ ClaudeProjects = ''; ClaudeProfiles = @(); CodexHomes = @(@{ Id = 'Default'; Name = 'Default'; Home = $cxHome }); AgyDirs = @() }
    $tagD = Get-StorageProfileTag "Default"
    $invC = Get-StorageInventory -Roots $cxRoots
    $codex = @($invC.Sessions | Where-Object { $_.Harness -eq 'codex' })
    Assert ($codex.Count -eq 2) "both Codex threads are listed, archived ones too: $($codex.Count)"
    $cA = Get-Session $invC "codex:$tA.$tagD"; $cB = Get-Session $invC "codex:$tB.$tagD"
    Assert ($cA.Title -eq 'Codex active' -and $cA.Cwd -eq 'C:\work\alpha' -and $cA.LastActivity -eq 1762800000123 -and $cA.Flags.Trimmable -eq $true -and $cA.Flags.HasZst -eq $false) 'the live Codex thread'
    Assert ($cA.Flags.CodexArchived -eq $false -and $cB.Flags.CodexArchived -eq $true) 'an archived thread is flagged'
    Assert ($cB.Flags.HasZst -eq $true -and $cB.Flags.Trimmable -eq $false) 'a .zst rollout cannot be trimmed'
    Assert ($cB.LastActivity -eq 1762100000000) 'seconds become milliseconds when there is no updated_at_ms'
    Assert (@($cA.Parts | Where-Object { $_.Role -eq 'rollout' }).Count -eq 1 -and $cB.Bytes -eq 3000) 'rollout bytes are counted'
    Assert ($cA.Profiles.Count -eq 1 -and $cA.Profiles[0].Id -eq 'Default') 'a Codex thread belongs to its CODEX_HOME'
    $cp = @($invC.Profiles | Where-Object { $_.Harness -eq 'codex' })[0]
    Assert ($cp.DataBytes -ge 500 + 700 + 3000) "CODEX_HOME is measured whole: $($cp.DataBytes)"
    $cache = New-StorageCache
    [void](Get-StorageInventory -Roots $cxRoots -Cache $cache); $r0 = $cache.Reads
    [void](Get-StorageInventory -Roots $cxRoots -Cache $cache)
    Assert ($cache.Reads -eq $r0 -and $r0 -ge 1) 'the database is read once and then served from the cache'
    Assert (-not (Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'sqlite-snap-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) })) 'no database snapshot left in %TEMP%'

    # ---------------------------------------------------------------- I1-4: Antigravity
    $agy = Join-Path $tmp 'agy\antigravity'
    $conv = '0b7e0000-0000-4000-8000-00000000c0de'
    Write-Bytes (Join-Path $agy "conversations\$conv.db") 4000
    Write-Bytes (Join-Path $agy "conversations\$conv.db-wal") 800
    Write-Bytes (Join-Path $agy "brain\$conv\notes\plan.md") 1200
    Write-Bytes (Join-Path $agy 'brain\no-conversation\x.md') 10
    $sumDb = Join-Path $agy 'conversation_summaries.db'
    Initialize-WinSqlite
    $h = [IntPtr]::Zero
    Assert (([HarnessWinSqlite]::sqlite3_open_v2((ConvertTo-SqliteUtf8 $sumDb), [ref]$h, 6, [IntPtr]::Zero)) -eq 0) 'summaries fixture open'
    $sql = "create table conversation_summaries (conversation_id text, title text, preview text, last_modified_time text, workspace_uris text, parent_conversation_id text, status text); insert into conversation_summaries values('$conv','Agy chat','',' 2026-11-13 07:08:46.2135894+00:00','[""file:///C:/work/alpha""]',null,'idle');"
    Assert (([HarnessWinSqlite]::sqlite3_exec($h, (ConvertTo-SqliteUtf8 $sql), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)) -eq 0) 'summaries fixture rows'
    [void][HarnessWinSqlite]::sqlite3_close($h)
    $agyRoots = @{ ClaudeProjects = ''; ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @(@{ Id = 'app'; Name = 'Antigravity'; DataDir = $agy }) }
    $invA = Get-StorageInventory -Roots $agyRoots
    $ag = @($invA.Sessions | Where-Object { $_.Harness -eq 'antigravity' })
    Assert ($ag.Count -eq 1 -and $ag[0].Key -eq ("antigravity:$conv." + (Get-StorageProfileTag "app"))) "one conversation (a brain folder with no conversation file is not a session): $($ag.Count)"
    $aroles = @($ag[0].Parts | ForEach-Object { $_.Role } | Sort-Object)
    Assert (($aroles -join ',') -eq 'brain,conversation-db,conversation-wal,summary-row') "parts: db, wal, brain, summaries row; got $($aroles -join ',')"
    Assert ($ag[0].Bytes -eq 4000 + 800 + 1200 -and $ag[0].Title -eq 'Agy chat' -and $ag[0].Cwd -eq 'C:\work\alpha' -and $ag[0].Flags.Trimmable -eq $false) "bytes, title, folder, not trimmable: $($ag[0].Bytes) $($ag[0].Title) $($ag[0].Cwd)"
    Assert ($ag[0].LastActivity -eq [DateTimeOffset]::Parse('2026-11-13T07:08:46Z').ToUnixTimeMilliseconds() + 0 -or [math]::Abs($ag[0].LastActivity - [DateTimeOffset]::Parse('2026-11-13T07:08:46Z').ToUnixTimeMilliseconds()) -lt 1000) 'activity comes from the summaries row'

    # ---------------------------------------------------------------- keys stay unique when a chat id sits in two profiles
    $keyOk = '\A[a-z][a-z0-9]{0,31}:[A-Za-z0-9_.-]{1,128}\z'
    Assert ((Get-StorageProfileTag 'Default') -eq (Get-StorageProfileTag 'DEFAULT') -and (Get-StorageProfileTag 'Default') -match '\A[0-9a-f]{8}\z' -and (Get-StorageProfileTag 'a') -ne (Get-StorageProfileTag 'b')) 'the tag is 8 hex characters of the lower-cased profile id'
    $agy2 = Join-Path $tmp 'agy\ide'
    Copy-Item -LiteralPath $agy -Destination $agy2 -Recurse
    $cxHome2 = Join-Path $tmp 'codex\home2'
    Copy-Item -LiteralPath $cxHome -Destination $cxHome2 -Recurse
    $two = @{ ClaudeProjects = $proj; ClaudeProfiles = $profiles; AgyDirs = @(@{ Id = 'app'; Name = 'Antigravity'; DataDir = $agy }, @{ Id = 'ide'; Name = 'Antigravity IDE'; DataDir = $agy2 })
        CodexHomes = @(@{ Id = 'Default'; Name = 'Default'; Home = $cxHome }, @{ Id = 'Work'; Name = 'Work'; Home = $cxHome2 }) }
    $invT = Get-StorageInventory -Roots $two
    $cx2 = @($invT.Sessions | Where-Object { $_.Harness -eq 'codex' -and $_.Id -eq $tA })
    Assert ($cx2.Count -eq 2 -and $cx2[0].Key -ne $cx2[1].Key -and $cx2[0].Id -eq $tA -and $cx2[1].Id -eq $tA) 'the same thread id in two CODEX_HOMEs is two sessions with different keys'
    $ag2 = @($invT.Sessions | Where-Object { $_.Harness -eq 'antigravity' -and $_.Id -eq $conv })
    Assert ($ag2.Count -eq 2 -and $ag2[0].Key -ne $ag2[1].Key) 'the same conversation in Antigravity and the IDE is two sessions'
    $keys = @($invT.Sessions | ForEach-Object { $_.Key })
    Assert ($keys.Count -eq @($keys | Sort-Object -Unique).Count) 'every key in the inventory is unique'
    Assert (@($keys | Where-Object { $_ -notmatch $keyOk }).Count -eq 0) "every key matches the Drive pattern: $(@($keys | Where-Object { $_ -notmatch $keyOk }) -join ',')"
    Assert (@($keys | Where-Object { ($_ -split ':', 2)[1] -match 'Work|Antigravity|Default|ide' }).Count -eq 0) 'no profile name inside a key'
    Assert ((Get-Session $invT "claude:$cli1") -and $keys -contains "claude:$cli1") 'Claude keys stay claude:<cliSessionId>'
    $weird = New-StorageSessionBuilder -Harness 'claude' -Id ('x y/' + ('z' * 200))
    Assert ($weird.Key -match $keyOk -and $weird.Id.StartsWith('x y/')) 'odd characters and a long id still give a valid key; Id is kept'

    # ---------------------------------------------------------------- an unreadable database is not remembered
    $good = [IO.File]::ReadAllBytes((Join-Path $cxHome2 'state_5.sqlite'))
    [IO.File]::WriteAllText((Join-Path $cxHome2 'state_5.sqlite'), ('this is not a database ' * 20))
    $cacheD = New-StorageCache
    $one = @{ ClaudeProjects = ''; ClaudeProfiles = @(); AgyDirs = @(); CodexHomes = @(@{ Id = 'Work'; Name = 'Work'; Home = $cxHome2 }) }
    $invD = Get-StorageInventory -Roots $one -Cache $cacheD
    $dbKey = Join-Path $cxHome2 'state_5.sqlite'
    Assert (-not $cacheD.Entries.ContainsKey($dbKey)) 'a failed database read leaves no cache entry'
    Assert ($invD.Warnings.Count -eq 1 -and $invD.Warnings[0] -like "*'Work'*") "one warning names the profile: $($invD.Warnings -join '|')"
    Assert (@($invD.Sessions | Where-Object { -not $_.Flags.DbUnreadable }).Count -eq 0 -and $invD.Sessions.Count -ge 1) 'its sessions are flagged DbUnreadable'
    [IO.File]::WriteAllBytes($dbKey, $good)
    $invD = Get-StorageInventory -Roots $one -Cache $cacheD
    Assert ($cacheD.Entries.ContainsKey($dbKey) -and $invD.Warnings.Count -eq 0) 'the next scan reads the database again and caches it'
    $sd = @($invD.Sessions | Where-Object { $_.Id -eq $tA })[0]
    Assert ($sd.Title -eq 'Codex active' -and -not $sd.Flags.DbUnreadable) 'titles are back, no flag'
    $badAgy = Join-Path $tmp 'agy\bad'; Copy-Item -LiteralPath $agy -Destination $badAgy -Recurse
    [IO.File]::WriteAllText((Join-Path $badAgy 'conversation_summaries.db'), ('garbage ' * 30))
    $invB = Get-StorageInventory -Roots @{ ClaudeProjects = ''; ClaudeProfiles = @(); CodexHomes = @(); AgyDirs = @(@{ Id = 'x'; Name = 'Broken'; DataDir = $badAgy }) } -Cache (New-StorageCache)
    Assert ($invB.Sessions[0].Flags.DbUnreadable -eq $true -and $invB.Warnings.Count -eq 1 -and $invB.Sessions[0].Title -eq $conv) 'an unreadable Antigravity summaries db is flagged too'

    # ---------------------------------------------------------------- I1-5: statistics without double counting
    function New-StatSession($harness, $id, $bytes, $profiles, [bool]$cliOnly = $false, $parts = $null) {
        [pscustomobject]@{ Harness = $harness; Key = "${harness}:$id"; Bytes = $bytes; Profiles = @($profiles); Parts = $(if ($parts) { $parts } else { @(@{ Role = 'transcript'; Path = "C:\store\$id.jsonl"; Bytes = $bytes; Kind = 'file' }) }); Flags = @{ IsCliOnly = $cliOnly } }
    }
    $mb = 1MB
    $shared = New-StatSession 'claude' 'shared' (10 * $mb) @(@{ Id = 'A'; Name = 'A' }, @{ Id = 'B'; Name = 'B' })
    $cliOnly = New-StatSession 'claude' 'cli' (5 * $mb) @() $true
    $own = New-StatSession 'claude' 'ownA' (2 * $mb) @(@{ Id = 'A'; Name = 'A' })
    $cxs = New-StatSession 'codex' 'c1' (3 * $mb) @(@{ Id = 'Default'; Name = 'Default' })
    $fake = [pscustomobject]@{
        Sessions = @($shared, $cliOnly, $own, $cxs)
        Profiles = @(
            [pscustomobject]@{ Harness = 'claude'; Id = 'A'; Name = 'A'; DataDir = 'C:\pa'; DataBytes = 7 * $mb; DataFiles = 10 },
            [pscustomobject]@{ Harness = 'claude'; Id = 'B'; Name = 'B'; DataDir = 'C:\pb'; DataBytes = 1 * $mb; DataFiles = 1 },
            [pscustomobject]@{ Harness = 'codex'; Id = 'Default'; Name = 'Default'; DataDir = 'C:\cx'; DataBytes = 4 * $mb; DataFiles = 5 })
    }
    $fake.Sessions[0].Parts = @(@{ Role = 'transcript'; Path = 'C:\store\shared.jsonl'; Bytes = 10 * $mb - 100; Kind = 'file' }, @{ Role = 'profile-meta'; Path = 'C:\pa\claude-code-sessions\x\y\local_a.json'; Bytes = 50; Kind = 'file'; ProfileId = 'A' }, @{ Role = 'profile-meta'; Path = 'C:\pb\claude-code-sessions\x\y\local_b.json'; Bytes = 50; Kind = 'file'; ProfileId = 'B' })
    $st = Get-StorageStats -Inventory $fake
    Assert ($st.ByHarness.claude.Bytes -eq 17 * $mb -and $st.ByHarness.claude.Sessions -eq 3) "Claude total counts every session once: $($st.ByHarness.claude.Bytes / $mb) MB"
    Assert ($st.ByHarness.codex.Bytes -eq 3 * $mb) 'Codex total'
    $pa = @($st.ByProfile | Where-Object { $_.Id -eq 'A' -and $_.Harness -eq 'claude' })[0]
    $pb = @($st.ByProfile | Where-Object { $_.Id -eq 'B' })[0]
    Assert ($pa.Sessions -eq 2 -and $pa.SessionBytes -eq 12 * $mb -and $pa.SharedBytes -eq 10 * $mb) "profile A: 2 sessions, 12 MB, 10 MB shared: $($pa | ConvertTo-Json -Compress)"
    Assert ($pb.Sessions -eq 1 -and $pb.SessionBytes -eq 10 * $mb -and $pb.SharedBytes -eq 10 * $mb) 'profile B holds only the shared session'
    Assert (($pa.SessionBytes + $pb.SessionBytes) -gt $st.ByHarness.claude.Bytes) 'profiles add up to more than the harness total (shared counted once at harness level)'
    Assert ($st.CliOnly.Sessions -eq 1 -and $st.CliOnly.Bytes -eq 5 * $mb) 'the "CLI / no profile" group'
    Assert ($pa.AppDataBytes -eq 7 * $mb - 50 -and $pb.AppDataBytes -eq 1 * $mb - 50) "app data is the profile folder minus the session parts inside it: $($pa.AppDataBytes) $($pb.AppDataBytes)"
    $pc = @($st.ByProfile | Where-Object { $_.Harness -eq 'codex' })[0]
    Assert ($pc.AppDataBytes -eq 4 * $mb -and $pc.SharedBytes -eq 0) 'a Codex profile has nothing shared'
    Assert ($st.Archive.Sessions -eq 0 -and $st.Archive.Bytes -eq 0) 'the archive block is there, empty until A1 fills it'
    $both = Get-StorageStats -Inventory ([pscustomobject]@{ Sessions = @(); Profiles = @() })
    Assert ($both.ByProfile.Count -eq 0 -and $both.CliOnly.Bytes -eq 0 -and $both.ByHarness.claude.Bytes -eq 0) 'stats of an empty inventory'

    # ---------------------------------------------------------------- R3-5: the newest title wins; R3-6: a line longer than the window
    $rt = Join-Path $tmp 'r3'
    $tl = { param($kind, $key, $text) '{"type":"' + $kind + '","' + $key + '":"' + $text + '","sessionId":"s"}' }
    Write-Text (Join-Path $rt 't1.jsonl') ((& $line $cli1 '2026-11-10T08:00:00.000Z') + "`n" + (& $tl 'custom-title' 'customTitle' 'First name') + "`n" + (& $line $cli1 '2026-11-10T09:00:00.000Z') + "`n" + (& $tl 'custom-title' 'customTitle' 'Second name') + "`n" + (& $line $cli1 '2026-11-10T10:00:00.000Z') + "`n")
    Assert ((Read-StorageClaudeJsonlMeta -Path (Join-Path $rt 't1.jsonl')).title -eq 'Second name') 'R3-5: a session renamed twice shows the newest name'
    $filler = '{"type":"assistant","message":{"content":"' + ('f' * 100000) + '"}}'
    Write-Text (Join-Path $rt 'big-last.jsonl') ((& $line $cli1 '2026-11-10T08:00:00.000Z') + "`n" + $filler + "`n" + '{"type":"assistant","timestamp":"2026-11-12T10:00:00.000Z","message":{"content":"' + ('z' * 200000) + '"}}' + "`n")
    $bl = Read-StorageClaudeJsonlMeta -Path (Join-Path $rt 'big-last.jsonl')
    Assert ($bl.last -eq (ConvertTo-StorageMs '2026-11-12T10:00:00.000Z') -and $bl.first -and $bl.cwd) "R3-6: a last line of 200 KB still gives the last time: $($bl.last)"
    Write-Text (Join-Path $rt 'big-first.jsonl') ('{"type":"user","cwd":"C:\\work\\first","timestamp":"2026-11-10T08:00:00.000Z","message":{"role":"user","content":"' + ('y' * 200000) + '"}}' + "`n" + $filler + "`n" + (& $line $cli1 '2026-11-10T09:00:00.000Z') + "`n")
    $bf = Read-StorageClaudeJsonlMeta -Path (Join-Path $rt 'big-first.jsonl')
    Assert ($bf.cwd -eq 'C:\work\first' -and $bf.first) 'R3-6: a first line of 200 KB still gives the folder and the first time'
    # ---------------------------------------------------------------- R3-4: a local_*.json that cannot be read is not cached as empty
    $rp = Join-Path $rt 'proj'; $cliR = 'aaaaaaaa-0000-4000-8000-0000000000r1'.Replace('r1', 'f1')
    Write-Text (Join-Path $rp "C--w\$cliR.jsonl") ((& $line $cliR '2026-11-10T08:00:00.000Z') + "`n")
    $rprof = Join-Path $rt 'prof'; $lj = Join-Path $rprof 'claude-code-sessions\a\b\local_r.json'
    Write-Text $lj (& $localJson $cliR 'Locked title' 1762800000000)
    $rroots = @{ ClaudeProjects = $rp; ClaudeProfiles = @(@{ Id = 'R'; Name = 'R'; SessionRoot = (Join-Path $rprof 'claude-code-sessions'); DataDir = $rprof; IsDefault = $false }); CodexHomes = @(); AgyDirs = @() }
    $rcache = New-StorageCache
    $fs = [IO.File]::Open($lj, 'Open', 'ReadWrite', 'None')
    try { $ri = Get-StorageInventory -Roots $rroots -Cache $rcache } finally { $fs.Dispose() }
    Assert (-not $rcache.Entries.ContainsKey($lj)) 'R3-4: the unreadable file has no cache entry'
    Assert (@($ri.Warnings | Where-Object { $_ -like '*local_r.json*' }).Count -eq 1) "R3-4: and a warning names it: $($ri.Warnings -join '|')"
    Assert (@($ri.Sessions | Where-Object { $_.Flags.DbUnreadable }).Count -ge 1 -and (Get-Session $ri "claude:$cliR").Flags.DbUnreadable) 'R3-4: the sessions that cannot be told apart are marked unreadable, so they cannot be archived or deleted'
    $ri2 = Get-StorageInventory -Roots $rroots -Cache $rcache
    $s2 = Get-Session $ri2 "claude:$cliR"
    Assert ($s2.Profiles.Count -eq 1 -and -not $s2.Flags.DbUnreadable -and -not $s2.Flags.IsCliOnly -and $s2.Title -eq 'Locked title' -and @($ri2.Warnings).Count -eq 0) 'R3-4: the next scan reads it and the session is whole'
    Write-Text $lj '{ not json'
    $ri3 = Get-StorageInventory -Roots $rroots -Cache (New-StorageCache)
    Assert (@($ri3.Warnings | Where-Object { $_ -like '*local_r.json*' }).Count -eq 1 -and (Get-Session $ri3 "claude:$cliR").Flags.DbUnreadable) 'R3-4: a file that is not JSON counts as unreadable too'
    # ---------------------------------------------------------------- R3-11: a session root outside the data folder is measured as well
    $dd = Join-Path $rt 'data'; $sr = Join-Path $rt 'sess-root'
    Write-Bytes (Join-Path $dd 'Cache\a.bin') 1000; Write-Bytes (Join-Path $sr 'acct\org\local_q.json') 500
    $pf = Get-StorageProfileFolder -Harness 'claude' -P @{ Id = 'D'; Name = 'D'; IsDefault = $true; SessionRoot = $sr } -DataDir $dd
    Assert ($pf.DataBytes -eq 1500 -and $pf.DataFiles -eq 2 -and $pf.SessionRoot -eq $sr) "R3-11: data folder + session root outside it: $($pf.DataBytes)"
    $inner = Join-Path $dd 'claude-code-sessions'; Write-Bytes (Join-Path $inner 'x\y\local_i.json') 200
    $pf2 = Get-StorageProfileFolder -Harness 'claude' -P @{ Id = 'D'; Name = 'D'; IsDefault = $true; SessionRoot = $inner } -DataDir $dd
    Assert ($pf2.DataBytes -eq 1200) "R3-11: a session root inside the data folder is not counted twice: $($pf2.DataBytes)"
    $fk = [pscustomobject]@{ Sessions = @([pscustomobject]@{ Harness = 'claude'; Key = 'claude:q'; Bytes = 500; Flags = @{ IsCliOnly = $false }; Profiles = @([pscustomobject]@{ Id = 'D'; Name = 'D' })
            Parts = @(@{ Role = 'profile-meta'; Path = (Join-Path $sr 'acct\org\local_q.json'); Bytes = 500; Kind = 'file' }) })
        Profiles = @([pscustomobject]@{ Harness = 'claude'; Id = 'D'; Name = 'D'; DataDir = $dd; SessionRoot = $sr; DataBytes = 1500 }) }
    Assert ((Get-StorageStats -Inventory $fk).ByProfile[0].AppDataBytes -eq 1000) 'R3-11: app data is data + session root minus the session parts in either'

    # ---------------------------------------------------------------- R3-7: a failed fallback copy leaves no snapshot folder behind
    $snapTmp = Join-Path $rt 'snaptemp'; New-Item -ItemType Directory -Path $snapTmp -Force | Out-Null
    Write-Text (Join-Path $rt 'notadb.db') 'this is not a database'
    $oldTmp = $env:TEMP; $oldTmp2 = $env:TMP; $threw = $false
    try {
        $env:TEMP = $snapTmp; $env:TMP = $snapTmp
        try { & { function Copy-Item { throw 'disk full' }; [void](Copy-SqliteSnapshot -Path (Join-Path $rt 'notadb.db')) } } catch { $threw = ($_.Exception.Message -like '*disk full*') }
    } finally { $env:TEMP = $oldTmp; $env:TMP = $oldTmp2 }
    Assert ($threw -and @(Get-ChildItem -LiteralPath $snapTmp -Filter 'sqlite-snap-*').Count -eq 0) 'R3-7: when the backup copy fails the error is thrown and no sqlite-snap folder is left'

    # roots built from a config: only the shape is checked here, never real paths
    Assert ($null -ne (Get-Command Get-StorageRootsFromConfig -CommandType Function)) 'the real-roots builder exists'
} finally {
    foreach ($j in (Join-Path $tmp 'claude\projects\C--linked')) { if (Test-Path -LiteralPath $j) { try { [IO.Directory]::Delete($j) } catch { } } }
    Remove-TestTempDir $tmp
}
Write-Output 'Storage.Inventory.Tests: OK'
