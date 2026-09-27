@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Monitor.ps1" -Diagnose
set "Result=%ERRORLEVEL%"
echo.
pause
exit /b %Result%
