@echo off
rem Collect PepeHub logs and a screenshot from the connected Android phone.
setlocal
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0android-diagnostics.ps1" %*
echo.
pause
