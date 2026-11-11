<#
 Spike S4 helper: print only the target name and LastWritten of a Windows Credential Manager entry.
 Never reads or prints the secret blob.
 Usage: S4-CredStamp.ps1 [-Target gemini:antigravity]
#>
param([string]$Target = 'gemini:antigravity')
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class CredStamp {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct CREDENTIAL { public int Flags; public int Type; public string TargetName; public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
    public int Persist; public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName; }
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredReadW(string t, int type, int f, out IntPtr p);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr p);
  public static string Stamp(string target) {
    IntPtr p; if (!CredReadW(target, 1, 0, out p)) return "<not found>";
    try { var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
      long ft = ((long)c.LastWritten.dwHighDateTime << 32) | (uint)c.LastWritten.dwLowDateTime;
      return DateTime.FromFileTime(ft).ToString("yyyy-MM-dd HH:mm:ss"); } finally { CredFree(p); }
  }
}
'@
"$Target LastWritten: " + [CredStamp]::Stamp($Target)
