@echo off
setlocal
title MineMod Addon Merge
echo MineMod addon merge
echo Scanning and merging addons. Please wait...
echo.

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0merge_addons.ps1" -NoPause %*
set "mergeExitCode=%errorlevel%"

echo.
if "%mergeExitCode%"=="0" (
    echo Finished successfully.
) else (
    echo Merge failed with exit code %mergeExitCode%. See the error above.
)
pause
exit /b %mergeExitCode%
