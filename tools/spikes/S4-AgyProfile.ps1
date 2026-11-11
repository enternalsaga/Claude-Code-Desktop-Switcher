<#
 Spike S4: launch a second Antigravity (or Antigravity IDE) instance with its own Electron userData and gemini dir.
 Test dirs only: %LOCALAPPDATA%\AgyProfile-<Name> and %USERPROFILE%\.gemini-profiles\<Name>. Never writes ~\.gemini.
 Usage: S4-AgyProfile.ps1 -Name spike1 [-App Antigravity|'Antigravity IDE'] [-FakeHome]   (launch; stores a marker with the launch time)
        -FakeHome: also give the child a different USERPROFILE/HOME. Needed: ANTIGRAVITY_GEMINI_DIR alone is ignored (see results S4).
        S4-AgyProfile.ps1 -Name spike1 -Check                                  (what changed where since launch; names only)
#>
param([Parameter(Mandatory)][ValidatePattern('^spike')][string]$Name,
      [ValidateSet('Antigravity','Antigravity IDE')][string]$App = 'Antigravity',
      [switch]$FakeHome,
      [switch]$Check)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $env:LOCALAPPDATA "Programs\$App\$App.exe"
$sfx = if ($App -eq 'Antigravity') { $Name } else { "$Name-ide" }
$ud = Join-Path $env:LOCALAPPDATA "AgyProfile-$sfx"
$gem = Join-Path $env:USERPROFILE ".gemini-profiles\$sfx"
$marker = Join-Path $gem 'spike.launch.txt'
$def = Join-Path $env:USERPROFILE '.gemini'

if (-not $Check) {
  New-Item -ItemType Directory -Force $ud, $gem | Out-Null
  (Get-Date).ToString('o') | Set-Content $marker
  $old = @{ G = $env:ANTIGRAVITY_GEMINI_DIR; A = $env:ANTIGRAVITY_APP_DATA_DIR; U = $env:USERPROFILE; H = $env:HOME }
  try {
    $env:ANTIGRAVITY_GEMINI_DIR = $gem; $env:ANTIGRAVITY_APP_DATA_DIR = $gem
    if ($FakeHome) {
      # S4 finding: ANTIGRAVITY_GEMINI_DIR alone is NOT honored (language_server still used the real ~\.gemini).
      # Variant: give the child a different home so <home>\.gemini resolves inside the spike dir.
      $fake = Join-Path $gem 'home'
      New-Item -ItemType Directory -Force (Join-Path $fake '.gemini') | Out-Null
      $env:USERPROFILE = $fake; $env:HOME = $fake
    }
    $proc = Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$ud`"" -PassThru
  } finally { $env:ANTIGRAVITY_GEMINI_DIR = $old.G; $env:ANTIGRAVITY_APP_DATA_DIR = $old.A; $env:USERPROFILE = $old.U; $env:HOME = $old.H }
  "Launched $App PID $($proc.Id); userData=$ud; gemini=$gem"
  return
}

$since = [datetime]::Parse((Get-Content $marker))
"since $since"
foreach ($root in @($gem, $ud, $def)) {
  "== $root (files changed since launch, names only, first 25)"
  Get-ChildItem $root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 25 |
    ForEach-Object { '{0}  {1,10}  {2}' -f $_.LastWriteTime.ToString('HH:mm:ss'), $_.Length, $_.FullName.Substring($root.Length) }
}
"== conversations in spike gemini dir"
Get-ChildItem (Join-Path $gem 'antigravity\conversations') -ErrorAction SilentlyContinue | Select-Object Name, Length
"== main processes"
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^Antigravity' -and $_.CommandLine -notmatch '--type=' } |
  Select-Object ProcessId, @{n='UserDataDir';e={ if ($_.CommandLine -match '--user-data-dir="?([^" ]+)') { $Matches[1] } else { '<default>' } }}
