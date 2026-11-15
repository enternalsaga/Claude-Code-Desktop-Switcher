# Storage.Summarize.ps1 - summarize a session with the claude or codex command line tool (phase 6, lane C1). It sends the redacted
# transcript to a provider and uses tokens, so it never runs without -Confirmed, and it makes a verified archive first. The
# tool runs headless in an empty temp folder (so it reads no CLAUDE.md or AGENTS.md), with a timeout that kills the whole
# process tree. No key or token is stored: only the sign-in of the CLI is used. The answer is <key>.summary.md beside the
# archives. Needs Storage.Compact.ps1 (the archive first, the transcript readers, the sidecar files), Storage.Guard.ps1,
# Storage.Scan.ps1 and Harness.Core.ps1 (Protect-TranscriptEntries, ConvertTo-HandoffMarkdown). ASCII only.

# The gate of the UI button. Closed until spike S19 has measured a real headless call; then one commit sets it to $true.
$script:StorageSummarizeReady = $false

function Test-StorageSummarizeReady { return [bool]$script:StorageSummarizeReady }

function Get-StorageSummaryLimits { return @{ MaxChars = 400000; TimeoutSec = 300 } }

function Get-StorageAvailableSummaryTools {
    return @(foreach ($t in 'claude', 'codex') { if (Get-Command $t -CommandType Application -ErrorAction SilentlyContinue) { $t } })
}

# The CLI of the session's own harness first; Antigravity takes claude first. $null when none of the two is on the machine.
function Get-StorageSummaryTool {
    param([string]$Harness, [string[]]$Available)
    $order = $(if ($Harness -eq 'codex') { @('codex', 'claude') } else { @('claude', 'codex') })
    foreach ($t in $order) { if ($Available -contains $t) { return $t } }
    return $null
}

# One row per session: @{ Key; Tool; InputChars; EstTokens } with tokens = characters / 4. The characters are an estimate (the
# size of the transcript files, at most 400000), so that building the plan reads nothing.
function Get-StorageSummaryPlan {
    param([Parameter(Mandatory)][array]$Sessions, [string[]]$Available = (Get-StorageAvailableSummaryTools))
    $max = (Get-StorageSummaryLimits).MaxChars
    foreach ($s in $Sessions) {
        $chars = [long]0
        foreach ($p in @($s.Parts | Where-Object { $_.Kind -eq 'file' -and ($_.Role -in 'transcript', 'rollout' -or $_.Role -like 'conversation-*') })) { $chars += [long]$p.Bytes }
        $chars = [Math]::Min($chars, $max)
        @{ Key = [string]$s.Key; Tool = (Get-StorageSummaryTool -Harness ([string]$s.Harness) -Available $Available); InputChars = $chars; EstTokens = [long][Math]::Ceiling($chars / 4) }
    }
}

# The command line of the headless call (flags from spike S19). The prompt always goes to stdin. claude prints the answer; codex
# writes it to -OutFile.
function Get-StorageSummaryCommand {
    param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Tool, [Parameter(Mandatory)][string]$WorkDir, [string]$OutFile)
    if ($Tool -eq 'claude') { return @{ Exe = 'claude'; Arguments = '-p --tools "" --output-format text --no-session-persistence --disable-slash-commands --max-turns 1'; OutFile = $null } }
    if (-not $OutFile) { $OutFile = Join-Path $WorkDir 'answer.txt' }
    return @{ Exe = 'codex'; Arguments = ('exec --skip-git-repo-check --ephemeral -s read-only --color never -C "{0}" -o "{1}" -' -f $WorkDir, $OutFile); OutFile = $OutFile }
}

# Runs a program with text on stdin and waits for it for at most -TimeoutSec. When the time is up the whole process tree is
# killed and this throws summarize-timeout. Returns @{ ExitCode; StdOut; StdErr }.
function Invoke-StorageProcessWithTimeout {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Arguments, [AllowEmptyString()][string]$StdIn = '', [Parameter(Mandatory)][string]$WorkDir, [int]$TimeoutSec = 300)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath; $psi.Arguments = $Arguments; $psi.WorkingDirectory = $WorkDir; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $left = { [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds) }
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($StdIn)
        $w = $p.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
        try { if ($w.Wait((& $left))) { $p.StandardInput.Close() } } catch { }   # the tool may stop reading early
        if (-not $p.WaitForExit((& $left))) {
            & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
            throw "summarize-timeout: the tool did not finish within $TimeoutSec seconds and was stopped."
        }
        [void]$outTask.Wait(10000); [void]$errTask.Wait(10000)
        return @{ ExitCode = $p.ExitCode; StdOut = $(if ($outTask.IsCompleted) { $outTask.Result } else { '' }); StdErr = $(if ($errTask.IsCompleted) { $errTask.Result } else { '' }) }
    } finally { $p.Dispose() }
}

# The real runner: { param($Tool, $Prompt, $WorkDir, $TimeoutSec) } returns the text of the answer. Tests give their own.
function Invoke-StorageSummaryCli {
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string]$WorkDir, [int]$TimeoutSec = 300)
    $cmd = Get-StorageSummaryCommand -Tool $Tool -WorkDir $WorkDir
    $exe = @(Get-Command $cmd.Exe -CommandType Application -ErrorAction SilentlyContinue)[0]
    if (-not $exe) { throw "summarize-failed: the $Tool command line tool was not found." }
    $r = Invoke-StorageProcessWithTimeout -FilePath $exe.Source -Arguments $cmd.Arguments -StdIn $Prompt -WorkDir $WorkDir -TimeoutSec $TimeoutSec
    if ($r.ExitCode -ne 0) {
        $why = (Protect-TranscriptText ([string]$r.StdErr)).Trim(); if ($why.Length -gt 300) { $why = $why.Substring(0, 300) }
        throw "summarize-failed: $Tool exited with code $($r.ExitCode). $why"
    }
    if ($cmd.OutFile -and [IO.File]::Exists($cmd.OutFile)) { return [IO.File]::ReadAllText($cmd.OutFile, [Text.Encoding]::UTF8) }
    return [string]$r.StdOut
}

# The transcript as the tool gets it: redacted entries, a handoff-style markdown, at most 400000 characters (the oldest part is cut).
function ConvertTo-StorageSummaryInput {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries, [Parameter(Mandatory)]$Session)
    $safe = @(Protect-TranscriptEntries -Entries $Entries)
    $md = ConvertTo-HandoffMarkdown -Entries $safe -Harness ([string]$Session.Harness) -Title ([string]$Session.Title) -Cwd ([string]$Session.Cwd)
    $max = (Get-StorageSummaryLimits).MaxChars
    if ($md.Length -gt $max) { $md = "[... the earlier part of the conversation was cut ...]`n" + $md.Substring($md.Length - $max) }
    return $md
}

function Get-StorageSummaryPrompt {
    param([Parameter(Mandatory)][string]$Markdown)
    return ("Summarize the coding assistant conversation below for someone who will continue the work in a new chat. Write Markdown with these sections: ## Summary, ## Decisions, ## Open work, ## Files touched. Use only the transcript. Do not use tools and do not ask questions.`n`n--- TRANSCRIPT ---`n" + $Markdown)
}

function Invoke-StorageSummarizeOne {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Target, [string]$Tool, [string]$MachineId, [Parameter(Mandatory)][string]$WorkDir, $Guard, [Parameter(Mandatory)][scriptblock]$Runner, [int]$TimeoutSec)
    $res = @{ Key = [string]$Session.Key; Ok = $false; Skipped = $false; Reason = ''; Warnings = @(); Path = $null; Tool = $Tool }
    $safe = Test-StorageSessionSafe -Session $Session @Guard
    if (-not $safe.Safe) { $res.Skipped = $true; $res.Reason = $safe.Reason; return $res }
    if (-not $Tool) { $res.Reason = 'No summary tool found: install the claude or codex command line tool.'; return $res }
    $run = Join-Path ([IO.Path]::GetTempPath()) ('harness-summary-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](Get-StorageSidecarDir -Session $Session -Target $Target)   # a store that cannot hold the summary is refused before anything is spent
        $arch = Save-StorageSafetyArchive -Session $Session -Target $Target -MachineId $MachineId -WorkDir $WorkDir
        $prompt = Get-StorageSummaryPrompt -Markdown (ConvertTo-StorageSummaryInput -Entries @(Get-StorageSessionEntries -Session $Session) -Session $Session)
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        $text = ([string](& $Runner $Tool $prompt $run $TimeoutSec)).Trim()
        if (-not $text) { throw 'summary-empty: the tool returned no text.' }
        $head = "# $($Session.Title)`n`n- Session: $($Session.Key)`n" + $(if ($Session.Cwd) { "- Working directory: $($Session.Cwd)`n" } else { '' }) + "- Summarized with: $Tool`n`n"
        Write-StorageSidecar -Dir $arch.Dir -Key $Session.Key -Suffix '.summary.md' -Text (Protect-TranscriptText ($head + $text + "`n"))
        $res.Path = Join-Path $arch.Dir ((Get-StorageKeySafe $Session.Key) + '.summary.md'); $res.Ok = $true
    } catch { $res.Reason = $_.Exception.Message }
    finally { if ([IO.Directory]::Exists($run)) { Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue } }
    return $res
}

# Summarizes sessions one after the other. Without -Confirmed it throws and does nothing. A session that fails or is skipped does
# not stop the rest; Cancel stops before the next session. Returns @{ Key; Ok; Skipped; Reason; Warnings; Path; Tool } per session.
function Invoke-StorageSummarize {
    param([Parameter(Mandatory)][array]$Sessions, [Parameter(Mandatory)]$Target, [switch]$Confirmed, [string]$MachineId = '', [string[]]$Available = (Get-StorageAvailableSummaryTools),
          [scriptblock]$Runner = { param($Tool, $Prompt, $WorkDir, $TimeoutSec) Invoke-StorageSummaryCli -Tool $Tool -Prompt $Prompt -WorkDir $WorkDir -TimeoutSec $TimeoutSec },
          [int]$TimeoutSec = (Get-StorageSummaryLimits).TimeoutSec, [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'harness-archive-work'),
          $Running = @{}, [string[]]$CliCwds = @(), [int]$RecentMinutes = 30, [string[]]$IncludeRecent = @(), [scriptblock]$LockProbe, $Progress, $CancelToken)
    if (-not $Confirmed) { throw 'confirmation-required: summarizing sends the redacted transcript to a provider and uses tokens; it needs -Confirmed.' }
    $results = New-Object Collections.Generic.List[object]
    foreach ($s in $Sessions) {
        if (Test-StorageCancel $CancelToken) { break }
        $guard = @{ RecentMinutes = $RecentMinutes; Running = $Running; CliCwds = $CliCwds }
        if ($LockProbe) { $guard['LockProbe'] = $LockProbe }
        if ($IncludeRecent -contains [string]$s.Key) { $guard['IncludeRecent'] = $true }
        $tool = Get-StorageSummaryTool -Harness ([string]$s.Harness) -Available $Available
        $results.Add((Invoke-StorageSummarizeOne -Session $s -Target $Target -Tool $tool -MachineId $MachineId -WorkDir $WorkDir -Guard $guard -Runner $Runner -TimeoutSec $TimeoutSec))
        if ($Progress) { $Progress['Done'] = [int]$Progress['Done'] + 1 }
    }
    if ([IO.Directory]::Exists($WorkDir) -and -not @(Get-ChildItem -LiteralPath $WorkDir -Force).Count) { Remove-Item -LiteralPath $WorkDir -Force -ErrorAction SilentlyContinue }
    return $results.ToArray()
}
