<#
.SYNOPSIS
    Снимает с подключённого Android-телефона логи PepeHub и скриншот.

.DESCRIPTION
    Телефон должен быть подключён через USB или «Отладку по Wi‑Fi» (adb connect).
    Скрипт очищает журнал, ждёт, пока вы повторите проблему в приложении,
    затем сохраняет в .local\android-diagnostics\:
      - pepehub-logcat.txt — сообщения приложения (Flutter, ошибки, доступ к файлам);
      - full-logcat.txt    — весь журнал за это время;
      - screen.png         — снимок экрана телефона;
      - device.txt         — модель, версия Android и версия PepeHub.
    Личные файлы и база приложения не копируются.
#>
param([switch]$NoWait)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$adb = Join-Path $root '.tools\android-sdk\platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $adb)) {
    $found = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $found) { throw 'Не найден adb: ни в .tools\android-sdk\platform-tools, ни в PATH.' }
    $adb = $found.Source
}
$package = 'app.pepehub.pepehub'
$out = Join-Path $root '.local\android-diagnostics'
New-Item -ItemType Directory -Path $out -Force | Out-Null

function Invoke-Adb([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $result = & $adb @Arguments 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $previous }
    return $result
}

$devices = @(Invoke-Adb @('devices') | Where-Object { $_ -match "`tdevice$" })
if ($devices.Count -eq 0) {
    throw 'Телефон не подключён. Включите «Отладку по Wi‑Fi» и выполните adb pair / adb connect.'
}
if ($devices.Count -gt 1) { Write-Host "Подключено устройств: $($devices.Count), использую первое." -ForegroundColor Yellow }
$serial = ($devices[0] -split "`t")[0]
Write-Host "Телефон: $serial" -ForegroundColor Cyan

$info = @(
    "Модель: $((Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.product.model')) -join '')"
    "Android: $((Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.build.version.release')) -join '') (API $((Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.build.version.sdk')) -join ''))"
    ((Invoke-Adb @('-s', $serial, 'shell', 'dumpsys', 'package', $package)) | Where-Object { $_ -match 'versionName|versionCode|firstInstallTime|lastUpdateTime' } | ForEach-Object { $_.Trim() })
)
[IO.File]::WriteAllLines((Join-Path $out 'device.txt'), [string[]]$info, [Text.UTF8Encoding]::new($false))
$info | ForEach-Object { Write-Host "  $_" }

Invoke-Adb @('-s', $serial, 'logcat', '-c') | Out-Null
if (-not $NoWait) {
    Write-Host ''
    Write-Host 'Журнал очищен. Повторите проблему в PepeHub на телефоне,' -ForegroundColor Green
    Write-Host 'затем вернитесь сюда и нажмите Enter.' -ForegroundColor Green
    [void](Read-Host)
}

$full = Invoke-Adb @('-s', $serial, 'logcat', '-d', '-v', 'threadtime')
[IO.File]::WriteAllLines((Join-Path $out 'full-logcat.txt'), [string[]]$full, [Text.UTF8Encoding]::new($false))
$appPid = ((Invoke-Adb @('-s', $serial, 'shell', 'pidof', $package)) -join '').Trim()
$pattern = 'flutter|pepehub|AndroidRuntime|DocumentsContract|SecurityException|FileNotFound|Exception'
if ($appPid -match '^\d+') { $pattern = "\b$($appPid -split ' ' | Select-Object -First 1)\b|$pattern" }
$app = $full | Where-Object { $_ -match $pattern }
[IO.File]::WriteAllLines((Join-Path $out 'pepehub-logcat.txt'), [string[]]$app, [Text.UTF8Encoding]::new($false))

$screen = Join-Path $out 'screen.png'
$remote = '/sdcard/pepehub-diagnostics.png'
Invoke-Adb @('-s', $serial, 'shell', 'screencap', '-p', $remote) | Out-Null
Invoke-Adb @('-s', $serial, 'pull', $remote, $screen) | Out-Null
Invoke-Adb @('-s', $serial, 'shell', 'rm', $remote) | Out-Null

Write-Host ''
Write-Host "Готово: $out" -ForegroundColor Green
Write-Host "  строк журнала приложения: $($app.Count), всего: $($full.Count)"
