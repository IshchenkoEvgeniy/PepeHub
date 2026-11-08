<#
.SYNOPSIS
    Мост между Claude и телефоном: выполняет adb-запросы из папки проекта.

.DESCRIPTION
    Запустите adb-bridge.cmd и оставьте окно открытым. Скрипт следит за папкой
    .local\adb-bridge\requests. Каждый запрос — JSON-файл со списком шагов:
        { "steps": [ ["shell","input","tap","540","1200"], ["sleep",800], ["screenshot"], ["logcat"] ] }
    Шаги:
        ["screenshot"]        — снимок экрана в results\<запрос>-<N>.png;
        ["logcat"]            — журнал PepeHub с прошлого запроса (затем журнал очищается);
        ["sleep", мс]         — пауза;
        ["install", "путь"]   — установить APK (путь относительно папки проекта);
        любой другой список   — аргументы adb (например ["shell","dumpsys","window"]).
    Результат пишется в .local\adb-bridge\results\<запрос>.txt, по окончании
    появляется <запрос>.done. Опасные команды (удаление приложения, очистка
    данных, удаление файлов, перезагрузка) не выполняются.
    Окно можно закрыть в любой момент — мост сразу перестаёт работать.
#>
param([int]$IntervalMs = 700)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$adb = Join-Path $root '.tools\android-sdk\platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $adb)) {
    $found = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $found) { throw 'Не найден adb: ни в .tools\android-sdk\platform-tools, ни в PATH.' }
    $adb = $found.Source
}
$package = 'app.pepehub.pepehub'
$base = Join-Path $root '.local\adb-bridge'
$requests = Join-Path $base 'requests'
$results = Join-Path $base 'results'
New-Item -ItemType Directory -Path $requests, $results -Force | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)

function Invoke-Adb([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $result = & $adb @Arguments 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $previous }
    return $result
}

function Get-Serial {
    $devices = @(Invoke-Adb @('devices') | Where-Object { $_ -match "`tdevice$" })
    if ($devices.Count -eq 0) { return $null }
    return ($devices[0] -split "`t")[0]
}

function Test-Denied([string[]]$Step) {
    $text = ($Step -join ' ').ToLowerInvariant()
    foreach ($word in @('uninstall', 'reboot', 'pm clear', 'rm ', 'rm	', 'rmdir', 'wipe', 'format', 'factory', 'root', 'remount', 'disable-verity', 'emu ')) {
        if ($text.Contains($word)) { return $true }
    }
    return $text -match '(^| )rm$'
}

Write-Host "adb-мост запущен. Папка запросов: $requests" -ForegroundColor Green
Write-Host 'Не закрывайте окно, пока Claude проверяет телефон. Ctrl+C — остановить.' -ForegroundColor Green
$heartbeat = Join-Path $base 'bridge-alive.txt'

while ($true) {
    [IO.File]::WriteAllText($heartbeat, (Get-Date).ToString('o'), $utf8)
    foreach ($file in @(Get-ChildItem -LiteralPath $requests -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $log = [Collections.Generic.List[string]]::new()
        try {
            $request = [IO.File]::ReadAllText($file.FullName, $utf8) | ConvertFrom-Json
            $serial = Get-Serial
            if (-not $serial) { throw 'Телефон не подключён (adb devices пуст). Включите «Отладку по Wi‑Fi» и выполните adb connect.' }
            $log.Add("device: $serial")
            $n = 0
            foreach ($raw in @($request.steps)) {
                $n++
                $step = @($raw | ForEach-Object { "$_" })
                $log.Add("## $n $($step -join ' ')")
                Write-Host "[$id] $($step -join ' ')"
                if ($step.Count -eq 0) { continue }
                switch ($step[0]) {
                    'sleep' { Start-Sleep -Milliseconds ([int]$step[1]); continue }
                    'screenshot' {
                        $png = Join-Path $results "$id-$n.png"
                        $remote = '/sdcard/pepehub-bridge.png'
                        Invoke-Adb @('-s', $serial, 'shell', 'screencap', '-p', $remote) | Out-Null
                        Invoke-Adb @('-s', $serial, 'pull', $remote, $png) | Out-Null
                        Invoke-Adb @('-s', $serial, 'shell', 'rm', '-f', $remote) | Out-Null
                        $log.Add("saved $id-$n.png")
                        continue
                    }
                    'logcat' {
                        $lines = Invoke-Adb @('-s', $serial, 'logcat', '-d', '-v', 'time')
                        $appPid = ((Invoke-Adb @('-s', $serial, 'shell', 'pidof', $package)) -join '').Trim()
                        $pattern = 'flutter|pepehub|AndroidRuntime|SecurityException|Exception'
                        if ($appPid -match '^\d+') { $pattern = "\(\s*$($appPid -split ' ' | Select-Object -First 1)\)|$pattern" }
                        $lines | Where-Object { $_ -match $pattern } | Select-Object -Last 400 | ForEach-Object { $log.Add($_) }
                        Invoke-Adb @('-s', $serial, 'logcat', '-c') | Out-Null
                        continue
                    }
                    'install' {
                        $apk = [IO.Path]::GetFullPath((Join-Path $root $step[1]))
                        if (-not $apk.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not $apk.EndsWith('.apk')) { throw "APK должен лежать в папке проекта: $apk" }
                        Invoke-Adb @('-s', $serial, 'install', '-r', $apk) | ForEach-Object { $log.Add($_) }
                        continue
                    }
                    default {
                        if (Test-Denied $step) { $log.Add('ОТКЛОНЕНО: опасная команда'); continue }
                        Invoke-Adb (@('-s', $serial) + $step) | Select-Object -First 2000 | ForEach-Object { $log.Add($_) }
                    }
                }
            }
        } catch {
            $log.Add("ОШИБКА: $($_.Exception.Message)")
            Write-Host "[$id] $($_.Exception.Message)" -ForegroundColor Red
        }
        [IO.File]::WriteAllLines((Join-Path $results "$id.txt"), [string[]]$log, $utf8)
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText((Join-Path $results "$id.done"), (Get-Date).ToString('o'), $utf8)
    }
    Start-Sleep -Milliseconds $IntervalMs
}
