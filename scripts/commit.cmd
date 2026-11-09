@echo off
rem Commit all PepeHub source changes and push the branch to GitHub.
rem Options are passed through, e.g.: commit.cmd "Fix cover cache" -Test  or  commit.cmd -NoPush
setlocal
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0commit.ps1" %*
set "COMMIT_EXIT=%ERRORLEVEL%"
echo.
if /I not "%PEPEHUB_BUILD_NO_PAUSE%"=="1" pause
exit /b %COMMIT_EXIT%
