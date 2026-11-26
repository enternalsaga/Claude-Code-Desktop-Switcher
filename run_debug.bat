@echo off
rem run_debug.bat - starts the Profile Switcher from THIS folder with its console kept open.
rem SWITCHER_DEBUG=1 makes ClaudeSwitcher.ps1 leave this console visible and print every error of the
rem window here (with the PowerShell file, line and stack the "Unhandled exception" box leaves out).
rem A second window follows the error log live.
rem Only one switcher runs at a time: a copy already running (installed one, or a tray icon) is offered
rem to be stopped first, otherwise this copy would only bring that one forward and quit.
rem SWITCHER_DRY_RUN=1 prints what it found and stops before anything is stopped or started.
title Claude Profile Switcher - DEBUG
cd /d "%~dp0"
set "SWITCHER_DEBUG=1"
set "SWITCHER_LOG=%LOCALAPPDATA%\ClaudeProfiles\switcher-error.log"
set "SWITCHER_PROBE=Get-CimInstance Win32_Process -Filter 'Name=''powershell.exe'' OR Name=''pwsh.exe''' | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*ClaudeSwitcher.ps1*' -and $_.CommandLine -notmatch ' -(Launch|List|Shortcut|Install|AddAccount|RouteSignIns|Status|Revert|HandleLink|OpenLink|SyncPush|SyncPull)\b' }"

echo ================================================================
echo  Claude Profile Switcher - debug run
echo  Script : %~dp0ClaudeSwitcher.ps1
echo  Log    : %SWITCHER_LOG%
echo ================================================================

rem exit code = how many switchers are running now (0 = none)
powershell.exe -NoProfile -Command "$p = @(Invoke-Expression $env:SWITCHER_PROBE); foreach ($x in $p) { '  running: PID {0}  {1}' -f $x.ProcessId, $x.CommandLine }; exit $p.Count"
set "RUNNING=%errorlevel%"
if "%SWITCHER_DRY_RUN%"=="1" (
    echo DRY RUN: running=%RUNNING%
    exit /b 0
)
if not "%RUNNING%"=="0" (
    echo.
    echo A switcher is already running ^(listed above^). This copy cannot start next to it.
    choice /c YN /m "Stop it and start the copy from this folder"
    if errorlevel 2 (
        echo Nothing was stopped. Quit it from its tray icon, then run this again.
        pause
        exit /b 1
    )
    powershell.exe -NoProfile -Command "Invoke-Expression $env:SWITCHER_PROBE | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; '  stopped PID {0}' -f $_.ProcessId }"
)

rem the log window: created empty when missing so Get-Content -Wait has something to follow
powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Force -Path (Split-Path $env:SWITCHER_LOG) | Out-Null; if (-not (Test-Path -LiteralPath $env:SWITCHER_LOG)) { New-Item -ItemType File -Path $env:SWITCHER_LOG | Out-Null }"
start "Switcher log" powershell.exe -NoProfile -Command "$host.UI.RawUI.WindowTitle = 'Switcher log'; Get-Content -LiteralPath $env:SWITCHER_LOG -Tail 20 -Wait"

echo.
echo Starting... errors of the window show up below. Close the window or use Exit in the tray to end.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeSwitcher.ps1"
echo.
echo The switcher ended with exit code %errorlevel%.
pause