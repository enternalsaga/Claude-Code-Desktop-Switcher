# Storage.CliProcess.ps1 - the working folders of the Claude Code command line tools that are running (phase 6). The storage
# guard uses them: a session whose folder has a Claude CLI running in it must not be archived, trimmed or deleted. A CLI is a
# claude.exe that is not the Desktop app, or a node.exe whose command line names claude-code. The folder of a process is read
# from its PEB (read only, 64-bit). A CLI whose folder cannot be read adds the token '*', which blocks every Claude session.
# The process list and the reader are parameters, so tests never ask the real machine. ASCII only.

function Initialize-StorageProcessCwdType {
    if ('StorageProcCwd' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class StorageProcCwd {
    [StructLayout(LayoutKind.Sequential)]
    struct PBI { public IntPtr Exit; public IntPtr Peb; public IntPtr Affinity; public IntPtr Priority; public IntPtr Pid; public IntPtr ParentPid; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsWow64Process(IntPtr h, out bool wow64);
    static byte[] Mem(IntPtr h, long addr, int n) {
        byte[] b = new byte[n]; IntPtr got;
        if (!ReadProcessMemory(h, new IntPtr(addr), b, new IntPtr(n), out got) || got.ToInt64() != n) throw new InvalidOperationException("cannot read memory of the process");
        return b;
    }
    public static string Read(int pid) {
        if (IntPtr.Size != 8) throw new NotSupportedException("64-bit PowerShell is required to read the folder of a process");
        IntPtr h = OpenProcess(0x1010, false, pid);   // QUERY_LIMITED_INFORMATION | VM_READ
        if (h == IntPtr.Zero) throw new InvalidOperationException("cannot open process " + pid);
        try {
            bool wow; if (!IsWow64Process(h, out wow) || wow) throw new NotSupportedException("process " + pid + " is a 32-bit process");
            PBI pbi = new PBI(); int ret;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) throw new InvalidOperationException("cannot query process " + pid);
            long pp = BitConverter.ToInt64(Mem(h, pbi.Peb.ToInt64() + 0x20, 8), 0);       // PEB.ProcessParameters
            byte[] us = Mem(h, pp + 0x38, 16);                                              // CurrentDirectory.DosPath (UNICODE_STRING)
            int len = BitConverter.ToUInt16(us, 0); long buf = BitConverter.ToInt64(us, 8);
            if (len == 0 || len % 2 != 0 || len > 65534 || buf == 0) throw new InvalidOperationException("process " + pid + " has no current folder");
            return Encoding.Unicode.GetString(Mem(h, buf, len));
        } finally { CloseHandle(h); }
    }
}
'@
}

# The current folder of a process. Throws when it cannot be read.
function Read-StorageProcessCwd {
    param([Parameter(Mandatory)][int]$ProcessId)
    Initialize-StorageProcessCwdType
    return [StorageProcCwd]::Read($ProcessId)
}

# The folders of the running Claude Code CLIs (trailing backslash cut), and '*' once for any whose folder could not be read.
# -Processes lists Win32_Process-like objects (ProcessId, Name, ExecutablePath, CommandLine) with one query; -ReadCwd gets the
# process id. -DesktopPattern is the path pattern of the Desktop app (Get-DesktopExePattern when not given).
function Get-StorageClaudeCliCwds {
    param([scriptblock]$Processes = { Get-CimInstance Win32_Process -Filter "Name='claude.exe' OR Name='node.exe'" -ErrorAction Stop },
          [scriptblock]$ReadCwd = { param($ProcessId) Read-StorageProcessCwd -ProcessId $ProcessId }, [string]$DesktopPattern)
    if (-not $PSBoundParameters.ContainsKey('DesktopPattern')) { $DesktopPattern = Get-DesktopExePattern }
    $found = New-Object Collections.Generic.List[string]
    foreach ($p in @(& $Processes)) {
        $isCli = $false
        if ([string]$p.Name -ieq 'claude.exe') { $isCli = ([string]$p.CommandLine -notmatch '--type=' -and -not ($p.ExecutablePath -and [string]$p.ExecutablePath -match $DesktopPattern)) }
        elseif ([string]$p.Name -ieq 'node.exe') { $isCli = ([string]$p.CommandLine -match 'claude-code') }
        if (-not $isCli) { continue }
        try { $cwd = ([string](& $ReadCwd $p.ProcessId)).TrimEnd('\'); if (-not $cwd) { throw 'empty' } } catch { $cwd = '*' }
        if (-not $found.Contains($cwd)) { $found.Add($cwd) }
    }
    return $found.ToArray()
}
