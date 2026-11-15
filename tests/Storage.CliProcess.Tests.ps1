$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Storage.CliProcess.ps1')

# The process list and the reader of a working folder are always fakes, except the two checks at the end that read this very
# test's own process and a child it starts in a temp folder.
$desk = '^C:\\Program Files\\WindowsApps\\Claude_[^\\]*__abc\\'
function New-Proc($id, $name, $exe, $cmd) { [pscustomobject]@{ ProcessId = $id; Name = $name; ExecutablePath = $exe; CommandLine = $cmd } }
$list = {
    @(
        (New-Proc 10 'claude.exe' 'C:\Users\u\.local\bin\claude.exe' 'claude --resume'),
        (New-Proc 11 'node.exe' 'C:\Program Files\nodejs\node.exe' 'node C:\npm\node_modules\@anthropic-ai\claude-code\cli.js'),
        (New-Proc 12 'claude.exe' 'C:\Program Files\WindowsApps\Claude_1.0_x64__abc\app\claude.exe' 'claude.exe --user-data-dir=X'),
        (New-Proc 13 'node.exe' 'C:\Program Files\nodejs\node.exe' 'node server.js'),
        (New-Proc 14 'Claude.exe' $null 'claude.exe --type=renderer'))
}
$cwds = @{ 10 = 'D:\Work\alpha\'; 11 = 'E:\Notes' }
$read = { param($ProcessId) if (-not $cwds.ContainsKey([int]$ProcessId)) { throw 'cannot read' }; $cwds[[int]$ProcessId] }
$r = @(Get-StorageClaudeCliCwds -Processes $list -ReadCwd $read -DesktopPattern $desk)
Assert ($r.Count -eq 2 -and $r -contains 'D:\Work\alpha' -and $r -contains 'E:\Notes') "two CLI processes give their two folders, trailing slash cut: $($r -join '|')"
Assert (-not ($r -contains '*')) 'the Desktop process, an unrelated node and an electron child are not CLIs'
# one that cannot be read
$cwds2 = @{ 10 = 'D:\Work\alpha' }
$read2 = { param($ProcessId) if (-not $cwds2.ContainsKey([int]$ProcessId)) { throw 'access denied' }; $cwds2[[int]$ProcessId] }
$r = @(Get-StorageClaudeCliCwds -Processes $list -ReadCwd $read2 -DesktopPattern $desk)
Assert ($r.Count -eq 2 -and $r -contains 'D:\Work\alpha' -and $r -contains '*') 'a CLI whose folder cannot be read adds the token *'
# nothing running
Assert (@(Get-StorageClaudeCliCwds -Processes { @() } -ReadCwd $read -DesktopPattern $desk).Count -eq 0) 'no CLI: an empty list'
# the process list itself fails: nothing is known, so the caller gets the error
$msg = ''; try { [void](Get-StorageClaudeCliCwds -Processes { throw 'wmi down' } -ReadCwd $read -DesktopPattern $desk) } catch { $msg = $_.Exception.Message }
Assert ($msg -like '*wmi down*') 'an error listing processes is not swallowed'
# the pattern is asked only when not given
function Get-DesktopExePattern { return $desk }
Assert (@(Get-StorageClaudeCliCwds -Processes $list -ReadCwd $read).Count -eq 2) 'without -DesktopPattern it uses Get-DesktopExePattern'

# the real reader, on this process and on a child in a temp folder (reading only)
if ([Environment]::Is64BitProcess) {
    $own = Read-StorageProcessCwd -ProcessId $PID
    Assert ($own.TrimEnd('\') -ieq [IO.Directory]::GetCurrentDirectory().TrimEnd('\')) "reads the folder of this process: $own"
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('storage-cli-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    $kid = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -WorkingDirectory $dir -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 800
        Assert ((Read-StorageProcessCwd -ProcessId $kid.Id).TrimEnd('\') -ieq $dir.TrimEnd('\')) 'reads the folder of another process'
    } finally { Stop-Process -Id $kid.Id -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    $gone = @(Get-StorageClaudeCliCwds -Processes { @([pscustomobject]@{ ProcessId = 2147480000; Name = 'claude.exe'; ExecutablePath = 'C:\x\claude.exe'; CommandLine = 'claude' }) } -DesktopPattern $desk)
    Assert ($gone.Count -eq 1 -and $gone[0] -eq '*') 'a process that is gone (or cannot be opened) gives *, not an error'
    $wow = "$env:SystemRoot\SysWOW64\cmd.exe"
    if (Test-Path $wow) {
        $k32 = Start-Process -FilePath $wow -ArgumentList '/c', 'ping -n 30 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Milliseconds 500
            $w = @(Get-StorageClaudeCliCwds -Processes { @([pscustomobject]@{ ProcessId = $k32.Id; Name = 'claude.exe'; ExecutablePath = 'C:\x\claude.exe'; CommandLine = 'claude' }) } -DesktopPattern $desk)
            Assert ($w.Count -eq 1 -and $w[0] -eq '*') 'a 32-bit (WOW64) process gives *'
        } finally { Stop-Process -Id $k32.Id -Force -ErrorAction SilentlyContinue }
    }
    $bad = ''; try { [void](Read-StorageProcessCwd -ProcessId 2147480000) } catch { $bad = $_.Exception.Message }
    Assert ($bad -like '*cannot open*') "a process that does not exist throws: $bad"
}
Write-Output 'PASS: Storage.CliProcess - CLI processes, folders, unreadable token, the real reader.'
