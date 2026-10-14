@echo off
rem Prepare and validate the project, build ARM64, then select the verified APK.
setlocal
set "ROOT=%~dp0.."
set "LOG=%~dp0claude-android.log"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\run-local-build.ps1" -Target Android -LogPath "%LOG%" %*
set "BUILD_EXIT=%ERRORLEVEL%"
if "%BUILD_EXIT%"=="0" goto finished
echo.
echo Build FAILED. See the error above. Log: "%LOG%"
:finished
if /I not "%PEPEHUB_BUILD_NO_PAUSE%"=="1" pause
exit /b %BUILD_EXIT%
