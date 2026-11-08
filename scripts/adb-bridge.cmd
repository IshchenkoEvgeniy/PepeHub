@echo off
rem Let Claude check the connected Android phone: runs adb requests from .local\adb-bridge.
setlocal
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0adb-bridge.ps1" %*
echo.
pause
