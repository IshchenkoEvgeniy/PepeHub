@echo off
rem Run PepeHub checks without building: update scripts, analysis, application tests.
rem Options are passed through, e.g.: test.cmd -Android  or  test.cmd test\epub_test.dart
setlocal
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0test.ps1" %*
set "TEST_EXIT=%ERRORLEVEL%"
echo.
if /I not "%PEPEHUB_BUILD_NO_PAUSE%"=="1" pause
exit /b %TEST_EXIT%
