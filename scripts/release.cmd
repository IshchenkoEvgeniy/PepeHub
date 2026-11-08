@echo off
rem Release PepeHub for Windows and Android and publish it to GitHub.
rem Options are passed through, e.g.: release.cmd -SkipTests  or  release.cmd -Version 0.31.0
setlocal
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0release.ps1" %*
set "RELEASE_EXIT=%ERRORLEVEL%"
echo.
if /I not "%PEPEHUB_BUILD_NO_PAUSE%"=="1" pause
exit /b %RELEASE_EXIT%
