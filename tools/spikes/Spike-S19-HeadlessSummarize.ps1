# Spike S19: one headless summarize call through `claude -p` or `codex exec` on a synthetic transcript, in an empty temp folder.
# Costs tokens on the user's own CLI sign-in, so it only calls the model with -Run (without it the command is printed and nothing runs).
# The transcript is made up here (no real chat data). Reports the exact flags, elapsed time, exit code and output size; prints no transcript text.
param(
    [Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Tool,
    [int]$Chars = 20000,
    [int]$TimeoutSec = 600,
    [string]$Model,                      # optional: a cheaper model for the measurement (recorded in the result)
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:TEMP 'harness-spike\S19'
$empty = Join-Path $work 'empty'
New-Item -ItemType Directory -Force $empty | Out-Null

# ---- synthetic transcript, about $Chars characters, with the markers a summary should pick up ----
$sb = New-Object Text.StringBuilder
$topics = 'the login form', 'the export button', 'the build script', 'the database migration', 'the settings page', 'the cache layer'
$i = 0
while ($sb.Length -lt $Chars) {
    $t = $topics[$i % $topics.Count]; $i++
    [void]$sb.AppendLine("USER: please look at $t and tell me what is wrong (turn $i).")
    [void]$sb.AppendLine("ASSISTANT: I read the files for $t. The problem is a missing null check in step $i; I changed it and ran the tests, 12 passed.")
    [void]$sb.AppendLine("TOOL run_command: npm test -- --filter t$i  =>  all green")
}
[void]$sb.AppendLine('USER: finally, rename the export button to "Download" and leave the cache layer for tomorrow.')
$transcript = $sb.ToString()
$instruction = 'Summarize the following conversation transcript in at most 8 bullet points: decisions made, work left, files or areas touched. Output only the summary as plain text.'
$stdinText = $instruction + "`n`n" + $transcript

if ($Tool -eq 'claude') {
    $exe = (Get-Command claude -CommandType Application | Select-Object -First 1).Source
    # no tools, one turn, no session file, no slash commands/skills; text out; prompt on stdin (-p with no argument reads stdin)
    $argList = @('-p', '--tools', '""', '--output-format', 'text', '--no-session-persistence', '--disable-slash-commands', '--max-turns', '1')
    if ($Model) { $argList += @('--model', $Model) }
    $outFile = $null
} else {
    $exe = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    $outFile = Join-Path $work 'codex-last.txt'
    # read-only sandbox, no session persisted, not a git repo needed, last message to a file; prompt on stdin ("-")
    $argList = @('exec', '--skip-git-repo-check', '--ephemeral', '-s', 'read-only', '--color', 'never', '-C', $empty, '-o', $outFile)
    if ($Model) { $argList += @('-m', $Model) }
    $argList += '-'
}
"tool=$Tool chars=$($transcript.Length) (~$([int]($transcript.Length / 4)) tokens) model=$(if ($Model) { $Model } else { '<default>' })"
"command: $(Split-Path -Leaf $exe) $($argList -join ' ')   [cwd: empty temp folder; stdin: instruction + transcript]"
if (-not $Run) { 'dry run: nothing executed. Add -Run to call the model.'; return }

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = ($argList -join ' ')
$psi.WorkingDirectory = $empty
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = [Diagnostics.Process]::Start($psi)
$outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($stdinText)
try { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush() } catch { }
$p.StandardInput.Close()
$timedOut = $false
if (-not $p.WaitForExit($TimeoutSec * 1000)) { $timedOut = $true; & taskkill /PID $p.Id /T /F | Out-Null }   # kills only the process tree this script started
$sw.Stop()
$out = $outTask.Result; $err = $errTask.Result
if ($outFile -and (Test-Path -LiteralPath $outFile)) { $out = [IO.File]::ReadAllText($outFile) }
$errShort = ($err -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3 | ForEach-Object { ($_ -replace '[A-Za-z]:\\[^ ]*', '<path>').Trim() }) -join ' | '
"elapsed: $([int]$sw.Elapsed.TotalSeconds) s; exit code: $(if ($timedOut) { 'TIMEOUT (tree killed)' } else { $p.ExitCode }); output chars: $($out.Length); stderr first lines: [$errShort]"
if ($timedOut -or $p.ExitCode -ne 0 -or $out.Length -lt 200) { "output (short or failed run, first 300 chars): [$(($out.Substring(0, [Math]::Min(300, $out.Length))) -replace '\s+', ' ')]" }
"the summary mentions the last user request (rename to Download): $($out -match 'Download')"
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
