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
. (Join-Path $root 'src\Storage.Compact.ps1')
. (Join-Path $root 'src\Storage.Summarize.ps1')

# Fake files under %TEMP%\storage-summarize-* only. The runner is always a fake: no claude or codex is started, no token is spent.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('storage-summarize-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Text($path, $text) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null; [IO.File]::WriteAllText($path, $text, $utf8) }
function Get-Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
$secret = 'sk-' + ('abcdefghij' * 3)
try {
    # ---- the gate -----------------------------------------------------------------------------------------------------------------------------
    Assert ($script:StorageSummarizeReady.claude -eq $true -and $script:StorageSummarizeReady.codex -eq $false) 'S19: claude is ready, codex is still blocked'
    Assert ((Test-StorageSummarizeReady -Installed @('claude', 'codex')) -eq $true -and (Test-StorageSummarizeReady -Installed @('claude')) -eq $true) 'the gate is open when claude is on the machine'
    Assert ((Test-StorageSummarizeReady -Installed @('codex')) -eq $false -and (Test-StorageSummarizeReady -Installed @()) -eq $false) 'a codex-only machine, or no CLI at all: closed'
    Assert ((@(Get-StorageAvailableSummaryTools -Installed @('claude', 'codex')) -join ',') -eq 'claude' -and @(Get-StorageAvailableSummaryTools -Installed @('codex')).Count -eq 0) 'only tools that are ready and installed are available'
    $saved = $script:StorageSummarizeReady; $script:StorageSummarizeReady = @{ claude = $false; codex = $false }
    Assert ((Test-StorageSummarizeReady -Installed @('claude', 'codex')) -eq $false) 'no tool ready: closed even with both installed'
    $script:StorageSummarizeReady = $saved

    # ---- C1-4: the plan -----------------------------------------------------------------------------------------------------------------------
    function New-Bare($harness, $key, $bytes, $role, $roleExt = '.jsonl') {
        [pscustomobject]@{ Harness = $harness; Key = $key; Id = $key.Split(':')[1]; Title = "T $key"; Cwd = 'C:\work'; Profiles = @(); Bytes = [long]$bytes; Flags = @{}
            Parts = @(@{ Role = $role; Path = "C:\none\x$roleExt"; Kind = 'file'; Bytes = [long]$bytes; MTimeTicks = 1; ProfileId = '' }) }
    }
    $sc = New-Bare 'claude' 'claude:c1' 40000 'transcript'; $sx = New-Bare 'codex' 'codex:x1.11223344' 8000 'rollout'; $sa = New-Bare 'antigravity' 'antigravity:g1.aabbccdd' 4000 'conversation-db' '.db'
    $plan = @(Get-StorageSummaryPlan -Sessions @($sc, $sx, $sa) -Available @('claude', 'codex'))
    Assert ($plan.Count -eq 3 -and $plan[0].Key -eq 'claude:c1' -and $plan[0].Tool -eq 'claude' -and $plan[1].Tool -eq 'claude' -and $plan[2].Tool -eq 'claude') 'while codex is not ready a Codex session is summarized with claude too; Antigravity takes claude'
    Assert ($plan[0].InputChars -eq 40000 -and $plan[0].EstTokens -eq 10000 -and $plan[1].EstTokens -eq 2000) 'tokens are characters divided by 4'
    $plan = @(Get-StorageSummaryPlan -Sessions @($sc, $sx, $sa) -Available @('codex'))
    Assert ($null -eq $plan[0].Tool -and $null -eq $plan[1].Tool -and $null -eq $plan[2].Tool) 'codex is never chosen while it is not ready, even when it is the only CLI on the machine'
    $plan = @(Get-StorageSummaryPlan -Sessions @($sc) -Available @())
    Assert ($null -eq $plan[0].Tool) 'no CLI: no tool'
    $plan = @(Get-StorageSummaryPlan -Sessions @((New-Bare 'claude' 'claude:big' 3MB 'transcript')) -Available @('claude'))
    Assert ($plan[0].InputChars -eq 400000 -and $plan[0].EstTokens -eq 100000) 'the input is capped at 400000 characters'

    # ---- the commands of the real runner (S19 flags), and the process helper ---------------------------------------------------------
    $c = Get-StorageSummaryCommand -Tool 'claude' -WorkDir 'D:\empty'
    Assert ($c.Exe -eq 'claude' -and $c.Arguments -eq '-p --tools "" --output-format text --no-session-persistence --disable-slash-commands --max-turns 1' -and -not $c.OutFile) 'claude -p with no tools, text output, no session file, one turn; the prompt goes to stdin'
    $c = Get-StorageSummaryCommand -Tool 'codex' -WorkDir 'D:\empty' -OutFile 'D:\empty\out.txt'
    Assert ($c.Exe -eq 'codex' -and $c.Arguments -eq 'exec --skip-git-repo-check --ephemeral -s read-only --color never -C "D:\empty" -o "D:\empty\out.txt" -' -and $c.OutFile -eq 'D:\empty\out.txt') 'codex exec: ephemeral, read-only, an empty folder, the answer in a file'
    $ps = (Get-Command powershell.exe).Source
    $r = Invoke-StorageProcessWithTimeout -FilePath $ps -Arguments '-NoProfile -Command "[Console]::In.ReadToEnd()"' -StdIn 'hello caf+ stdin' -WorkDir $tmp -TimeoutSec 60
    Assert ($r.ExitCode -eq 0 -and $r.StdOut -like '*hello caf+ stdin*') 'the helper sends stdin and returns stdout'
    $r2 = Invoke-StorageProcessWithTimeout -FilePath $ps -Arguments '-NoProfile -Command "exit 3"' -StdIn '' -WorkDir $tmp -TimeoutSec 60
    Assert ($r2.ExitCode -eq 3) 'and the exit code'
    $marker = Join-Path $tmp 'child.pid'
    $slow = "-NoProfile -Command ""Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 60' -PassThru | ForEach-Object { `$_.Id | Set-Content '$marker' }; Start-Sleep 60"""
    $msg = ''; $t0 = Get-Date
    try { [void](Invoke-StorageProcessWithTimeout -FilePath $ps -Arguments $slow -StdIn '' -WorkDir $tmp -TimeoutSec 4) } catch { $msg = $_.Exception.Message }
    Assert ($msg -like 'summarize-timeout*' -and ((Get-Date) - $t0).TotalSeconds -lt 30) "a process that does not finish is stopped after the timeout: $msg"
    Start-Sleep -Milliseconds 500
    if (Test-Path $marker) { $kid = [int](Get-Content $marker); Assert (-not (Get-Process -Id $kid -ErrorAction SilentlyContinue)) 'and its child process is killed too' }

    # ---- C1-5: Invoke-StorageSummarize ------------------------------------------------------------------------------------------------
    $old = [DateTime]::UtcNow.AddDays(-40); $oldMs = ([DateTimeOffset]$old).ToUnixTimeMilliseconds()
    function New-Chat($name) {
        $jsonl = Join-Path $tmp "w-$name\projects\C--work-alpha\$name.jsonl"
        Write-Text $jsonl (('{"type":"user","uuid":"u1","timestamp":"2026-10-01T08:00:00.000Z","message":{"role":"user","content":"Please fix the login. My key is ' + $secret + ' ok"}}'), ('{"type":"assistant","uuid":"u2","timestamp":"2026-10-01T08:01:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Done. I changed auth.ps1."}]}}') -join "`n")
        (Get-Item $jsonl).LastWriteTimeUtc = $old
        return [pscustomobject]@{ Harness = 'claude'; Key = "claude:$name"; Id = $name; Title = "Chat $name"; Cwd = 'C:\work\alpha'; Profiles = @([pscustomobject]@{ Id = 'Default'; Name = 'Default' })
            Parts = @(@{ Role = 'transcript'; Path = $jsonl; Kind = 'file'; Bytes = (Get-Item $jsonl).Length; MTimeTicks = $old.Ticks; ProfileId = ''; Files = 1 }); Bytes = (Get-Item $jsonl).Length; State = 'idle'; LastActivity = $oldMs; Created = $null
            Flags = @{ Trimmable = $true; HasZst = $false; Subagent = $false } }
    }
    $store = Join-Path $tmp 'store'; $target = @{ Kind = 'local'; Path = $store; PathMap = @{} }; $machine = 'aaaaaaaa-0000-4000-8000-000000000001'
    $script:Calls = @(); $script:Seen = @()
    $runner = { param($Tool, $Prompt, $WorkDir, $TimeoutSec)
        $script:Calls += 1
        $script:Seen += , @{ Tool = $Tool; Prompt = $Prompt; WorkDir = $WorkDir; Timeout = $TimeoutSec; Empty = (@(Get-ChildItem -LiteralPath $WorkDir -Force).Count -eq 0); Existed = (Test-Path $WorkDir) }
        return "## Decisions`nThe login was fixed in auth.ps1. A leaked token: $secret"
    }
    $a = New-Chat 'c1'; $before = Get-Sha $a.Parts[0].Path
    $threw = ''; try { [void](Invoke-StorageSummarize -Sessions @($a) -Target $target -MachineId $machine -Runner $runner -Available @('claude')) } catch { $threw = $_.Exception.Message }
    Assert ($threw -like 'confirmation-required*' -and $script:Calls.Count -eq 0) 'without -Confirmed it throws and never calls the runner'
    Assert (-not (Test-Path $store)) 'and nothing was archived either'
    $res = @(Invoke-StorageSummarize -Sessions @($a) -Target $target -MachineId $machine -Confirmed -Runner $runner -Available @('claude'))
    Assert ($res.Count -eq 1 -and $res[0].Ok -and $script:Calls.Count -eq 1) "with -Confirmed the runner is called once: $($res[0].Reason)"
    $obs = $script:Seen[0]
    Assert ($obs.Tool -eq 'claude' -and $obs.Prompt -like '*Please fix the login*' -and $obs.Prompt -like '*[[]REDACTED]*') 'the runner gets the transcript, redacted'
    Assert ($obs.Prompt -notlike "*$secret*" -and $obs.Prompt -notlike '*abcdefghijabcdefghij*') 'a string that looks like a secret never reaches the runner'
    Assert ($obs.Existed -and $obs.Empty -and $obs.WorkDir -like (Join-Path ([IO.Path]::GetTempPath()) 'harness-summary-*') -and -not (Test-Path $obs.WorkDir)) 'the runner works in an empty temp folder that is removed afterwards'
    Assert ($obs.Timeout -eq (Get-StorageSummaryLimits).TimeoutSec -and $obs.Timeout -gt 0) 'with a timeout'
    $zip = @(Get-ChildItem (Join-Path $store 'claude') -Recurse -Filter 'claude_c1.*.harchive.zip')[0].FullName   # R1-1: the file name has an archiveId
    Assert ((Read-StorageArchive -ZipPath $zip).Verified -and (Get-Sha $a.Parts[0].Path) -eq $before) 'the original was archived first and is untouched'
    $sum = [IO.File]::ReadAllText((Join-Path (Split-Path $zip) 'claude_c1.summary.md'))
    Assert ($sum -like '*# Chat c1*' -and $sum -like '*C:\work\alpha*' -and $sum -like '*The login was fixed in auth.ps1*' -and $sum -notlike "*$secret*" -and $res[0].Path -like '*claude_c1.summary.md') '<key>.summary.md has the title, the folder, the summary, redacted'
    # no tool, a Drive store, a session in use, an empty answer
    $script:Calls = @()
    $n = @(Invoke-StorageSummarize -Sessions @((New-Chat 'c2')) -Target $target -MachineId $machine -Confirmed -Runner $runner -Available @())
    Assert (-not $n[0].Ok -and $n[0].Reason -like '*claude*codex*' -and $script:Calls.Count -eq 0 -and -not (Test-Path (Join-Path $store 'claude\*\claude_c2.*.harchive.zip'))) 'no CLI on the machine: a reason, no runner, no archive'
    $d = @(Invoke-StorageSummarize -Sessions @((New-Chat 'c3')) -Target @{ Kind = 'drive'; SyncRoot = $tmp; MachineId = $machine; Key = [byte[]](1..32); PathMap = @{} } -MachineId $machine -Confirmed -Runner $runner -Available @('claude'))
    Assert (-not $d[0].Ok -and $d[0].Reason -like 'store-unsupported*' -and $script:Calls.Count -eq 0) 'a Drive store is refused before anything is spent'
    $rc = New-Chat 'c4'; $rc.Parts[0].MTimeTicks = [DateTime]::UtcNow.Ticks; $rc.LastActivity = ([DateTimeOffset][DateTime]::UtcNow).ToUnixTimeMilliseconds()
    $g = @(Invoke-StorageSummarize -Sessions @($rc) -Target $target -MachineId $machine -Confirmed -Runner $runner -Available @('claude'))
    Assert ($g[0].Skipped -and $g[0].Reason -like 'Used in the last*' -and $script:Calls.Count -eq 0) 'the guard skips a session in use'
    $e = @(Invoke-StorageSummarize -Sessions @((New-Chat 'c5')) -Target $target -MachineId $machine -Confirmed -Runner { param($Tool, $Prompt, $WorkDir, $TimeoutSec) '   ' } -Available @('claude'))
    Assert (-not $e[0].Ok -and $e[0].Reason -like 'summary-empty*' -and -not (Test-Path (Join-Path $store ('claude\' + (Get-Date -Format 'yyyy-MM') + '\claude_c5.summary.md')))) 'an empty answer is a failure and writes no file'

    # ---- C1-6: a batch --------------------------------------------------------------------------------------------------------------------------
    $script:N = 0
    $flaky = { param($Tool, $Prompt, $WorkDir, $TimeoutSec) $script:N++; if ($script:N -eq 2) { throw 'summarize-failed: the CLI is not signed in' }; "## ok $script:N" }
    $prog = [hashtable]::Synchronized(@{ Done = 0; Total = 3 })
    $b = @(Invoke-StorageSummarize -Sessions @((New-Chat 'b1'), (New-Chat 'b2'), (New-Chat 'b3')) -Target $target -MachineId $machine -Confirmed -Runner $flaky -Available @('claude') -Progress $prog)
    Assert ($b.Count -eq 3 -and $b[0].Ok -and -not $b[1].Ok -and $b[1].Reason -like '*not signed in*' -and $b[2].Ok -and $prog.Done -eq 3) 'one failed session does not stop the others'
    $cancel = @{ Cancel = $false }; $script:M = 0
    $stopper = { param($Tool, $Prompt, $WorkDir, $TimeoutSec) $script:M++; $cancel.Cancel = $true; '## ok' }
    $c2 = @(Invoke-StorageSummarize -Sessions @((New-Chat 'd1'), (New-Chat 'd2')) -Target $target -MachineId $machine -Confirmed -Runner $stopper -Available @('claude') -CancelToken $cancel)
    Assert ($c2.Count -eq 1 -and $script:M -eq 1) 'Cancel stops before the next session, not in the middle of one'

    # ---- R2-3: the PID of the CLI child goes to Progress.ChildPids, so Stop can kill it ------------------------------------------------
    $seenProg = @(); $spy = { param($Tool, $Prompt, $WorkDir, $TimeoutSec, $Progress) $script:SeenProg = $Progress; '## ok' }
    $progR = [hashtable]::Synchronized(@{ Done = 0; Total = 1 })
    $rr = @(Invoke-StorageSummarize -Sessions @((New-Chat 'p1')) -Target $target -MachineId $machine -Confirmed -Runner $spy -Available @('claude') -Progress $progR)
    Assert ($rr[0].Ok -and [object]::ReferenceEquals($script:SeenProg, $progR)) 'the runner is given the same Progress'
    $prog2 = [hashtable]::Synchronized(@{ Done = 0 })
    $helperText = ${function:Invoke-StorageProcessWithTimeout}.ToString()
    $rsp = [powershell]::Create(); $rsp.Runspace.SessionStateProxy.SetVariable('prog', $prog2); $rsp.Runspace.SessionStateProxy.SetVariable('ps', $ps); $rsp.Runspace.SessionStateProxy.SetVariable('wd', $tmp)
    [void]$rsp.AddScript("function Invoke-StorageProcessWithTimeout { $helperText }; Invoke-StorageProcessWithTimeout -FilePath `$ps -Arguments '-NoProfile -Command ""Start-Sleep 60""' -StdIn '' -WorkDir `$wd -TimeoutSec 120 -Progress `$prog")
    $async = $rsp.BeginInvoke()
    $pidSeen = $null; $until = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $until -and -not $pidSeen) { $l = $prog2['ChildPids']; if ($l -and @($l).Count) { $pidSeen = [int]@($l)[0] } else { Start-Sleep -Milliseconds 100 } }
    Assert ($pidSeen -and (Get-Process -Id $pidSeen -ErrorAction SilentlyContinue)) 'while the tool runs its PID is in Progress.ChildPids and the process is alive'
    & taskkill.exe /PID $pidSeen /T /F 2>&1 | Out-Null    # what the Stop button of the UI lane does
    [void]$async.AsyncWaitHandle.WaitOne(30000)
    Assert (-not (Get-Process -Id $pidSeen -ErrorAction SilentlyContinue) -and $async.IsCompleted) 'taskkill /T /F on that PID stops the tool and the call returns'
    Assert (@($prog2['ChildPids']).Count -eq 0) 'and the PID is taken out of the list once the call is over'
    $rsp.Dispose()

    Write-Output 'PASS: Storage.Summarize - gate, plan, commands, process helper, confirmation, redaction, batch.'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
