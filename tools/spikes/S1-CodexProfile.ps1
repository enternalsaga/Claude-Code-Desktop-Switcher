<#
 Spike S1: launch a second Codex desktop instance with its own CODEX_HOME and Electron userData.
 Test profile lives only under %USERPROFILE%\.codex-profiles\<Name>. Never touches ~\.codex.
 Usage: S1-CodexProfile.ps1 -Name spike1            (launch)
        S1-CodexProfile.ps1 -Name spike1 -Check     (inspect after the user has signed in)
#>
param([Parameter(Mandatory)][ValidatePattern('^spike')][string]$Name, [switch]$Check)
$ErrorActionPreference = 'Stop'
$pkg = Get-AppxPackage OpenAI.Codex
$exe = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
$home_ = Join-Path $env:USERPROFILE ".codex-profiles\$Name"
$elec = Join-Path $home_ 'electron'
$pidFile = Join-Path $home_ 'spike.pid'
function Get-Sha($p) { if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0,12) } else { '<missing>' } }

if (-not $Check) {
  New-Item -ItemType Directory -Force $elec | Out-Null
  $old = @{ H = $env:CODEX_HOME; E = $env:CODEX_ELECTRON_USER_DATA_PATH }
  try {
    $env:CODEX_HOME = $home_; $env:CODEX_ELECTRON_USER_DATA_PATH = $elec
    $proc = Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$elec`"" -PassThru
  } finally { $env:CODEX_HOME = $old.H; $env:CODEX_ELECTRON_USER_DATA_PATH = $old.E }
  $proc.Id | Set-Content $pidFile
  "Launched PID $($proc.Id); CODEX_HOME=$home_"
  return
}

# --- Check phase (read-only; hashes only, never prints auth content) ---
$def = Join-Path $env:USERPROFILE '.codex\auth.json'
$mine = Join-Path $home_ 'auth.json'
"auth.json Default sha12 : $(Get-Sha $def)"
"auth.json $Name sha12   : $(Get-Sha $mine)"
"auth differs            : $((Get-Sha $def) -ne (Get-Sha $mine))"
"spike home files        : " + ((Get-ChildItem $home_ -Force | Select -Expand Name) -join ', ')
$lc = Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\LocalCache"
"LocalCache recent files (last 30 min):"
Get-ChildItem $lc -Recurse -File -ea 0 | ? { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } | Select -First 15 FullName,LastWriteTime | ft -auto | Out-String -Width 220
"Instances (main ChatGPT.exe, no --type=):"
Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" | ? { $_.CommandLine -notmatch '--type=' } |
  Select ProcessId, @{n='UserDataDir';e={ if ($_.CommandLine -match '--user-data-dir="?([^" ]+)') { $Matches[1] } else { '<none>' } }} | ft -auto
