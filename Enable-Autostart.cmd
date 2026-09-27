@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Autostart.ps1" -Action Enable
set "Result=%ERRORLEVEL%"
echo.
pause
exit /b %Result%
