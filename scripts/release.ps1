<#
.SYNOPSIS
    Выпуск PepeHub для Windows x64 и Android ARM64 одной командой.

.DESCRIPTION
    Проходит весь процесс из docs/BUILD_AND_RELEASE.md:
      1. проверяет инструменты, ключи подписи и состояние git;
      2. поднимает версию в pubspec.yaml относительно последнего опубликованного выпуска;
      3. готовит заметки docs/releases/RELEASE_<версия>.md (черновик из коммитов) и даёт их отредактировать;
      4. собирает Windows и Android (с анализом и тестами, если не указан -SkipTests);
      5. упаковывает выпуск, создаёт дельты и подписывает update.json;
      6. после подтверждения публикует его в IshchenkoEvgeniy/PepeHub-Releases;
      7. скачивает опубликованные файлы и сверяет размеры и SHA-256;
      8. коммитит версию и заметки в репозиторий исходников и отправляет их.

    Ничего не публикуется без подтверждения (кроме запуска с -Yes).
    Совместим с Windows PowerShell 5.1.

.EXAMPLE
    .\scripts\release.ps1
    Следующая сборка: номер после «+» на единицу больше опубликованного, patch-версия +1.

.EXAMPLE
    .\scripts\release.ps1 -Version 0.31.0 -SkipTests
    Новая минорная версия, без повторного прогона Flutter- и Android-тестов.

.EXAMPLE
    .\scripts\release.ps1 -NoPublish
    Только собрать и подготовить пакеты в dist\online\, ничего не загружая.
#>
param(
    # Имя версии major.minor.patch. По умолчанию — patch + 1 (или текущее, если оно уже выше опубликованного).
    [string]$Version,
    # Номер сборки после «+». По умолчанию — следующий после опубликованного.
    [int]$Build = 0,
    # Не менять версию в pubspec.yaml: выпустить ту, что уже указана.
    [switch]$KeepVersion,
    # Файл заметок. По умолчанию docs\releases\RELEASE_<версия без точек>.md.
    [string]$NotesFile,
    # Не запускать Flutter-тесты и нативные Android-тесты (анализ остаётся).
    [switch]$SkipTests,
    # Собрать и подготовить пакеты, но не публиковать.
    [switch]$NoPublish,
    # Не проверять публичные файлы после публикации.
    [switch]$SkipVerify,
    # Не коммитить и не отправлять исходники после публикации.
    [switch]$NoSourcePush,
    # Отвечать «да» на все вопросы (без пауз, заметки не открываются для правки).
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseApp = Join-Path $releaseRoot 'apps\pepehub'
$releasePubspec = Join-Path $releaseApp 'pubspec.yaml'
$releasePowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$releaseOwner = 'IshchenkoEvgeniy'
$releaseRepo = 'PepeHub-Releases'
$releaseStep = 0
$releaseTotal = 8
$releaseUtf8 = [Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Write-Step([string]$Title) {
    $script:releaseStep++
    Write-Host ''
    Write-Host "[$script:releaseStep/$releaseTotal] $Title" -ForegroundColor Cyan
}

function Write-Note([string]$Text, [ConsoleColor]$Color = 'Gray') { Write-Host "    $Text" -ForegroundColor $Color }

function Confirm-Release([string]$Question, [bool]$DefaultYes = $false) {
    if ($Yes) { return $true }
    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = (Read-Host "    $Question $hint").Trim().ToLowerInvariant()
    if ($answer -eq '') { return $DefaultYes }
    return $answer -in @('y', 'yes', 'д', 'да')
}

function Invoke-Script([string]$Title, [string]$Script, [string[]]$Arguments) {
    Write-Note "$Title..."
    & $releasePowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Script) @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Title — ошибка (код $LASTEXITCODE). Подробности выше и в логе." }
}

function Invoke-Native([string]$Title, [string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Title — ошибка (код $LASTEXITCODE)." }
}

function Get-PubspecVersion {
    $text = [IO.File]::ReadAllText($releasePubspec)
    $match = [regex]::Match($text, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (-not $match.Success) { throw 'В pubspec.yaml ожидается version: major.minor.patch+build' }
    return [pscustomobject]@{ Version = $match.Groups[1].Value; Build = [int]$match.Groups[2].Value }
}

function Set-PubspecVersion([string]$NewVersion, [int]$NewBuild) {
    $text = [IO.File]::ReadAllText($releasePubspec)
    $updated = [regex]::Replace($text, '(?m)^version:\s*\d+\.\d+\.\d+\+\d+(\s*)$', "version: $NewVersion+$NewBuild`$1")
    [IO.File]::WriteAllText($releasePubspec, $updated, $releaseUtf8)
}

function Get-Git([string[]]$Arguments, [switch]$AllowFailure) {
    # Windows PowerShell 5.1 turns redirected native stderr into terminating
    # errors under 'Stop'; judge git by its exit code instead.
    $ErrorActionPreference = 'Continue'
    $output = @(& git -C $releaseRoot @Arguments 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return @() }
        throw "git $($Arguments -join ' '): $($output -join ' ')"
    }
    return $output
}

$releaseLog = $null
$releaseExit = 0
try {
    Push-Location -LiteralPath $releaseRoot

    # ------------------------------------------------------------------
    Write-Step 'Проверка окружения'
    foreach ($tool in @('.tools\flutter\bin\flutter.bat', '.tools\android-user\debug.keystore', '.local\update-signing\private.pem')) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot $tool) -PathType Leaf)) {
            throw "Не найден $tool. Восстановите его из резервной копии (см. docs/BUILD_AND_RELEASE.md)."
        }
    }
    foreach ($command in @('git', 'node', 'npm')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Команда $command не найдена в PATH." }
    }
    $nodeMajor = [int]((& node --version) -replace '^v(\d+).*', '$1')
    if ($nodeMajor -lt 24) { throw "Нужен Node.js 24+, установлен $(& node --version)." }
    if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot 'node_modules'))) {
        Write-Note 'Устанавливаю Node-зависимости (npm ci)...'
        Invoke-Native 'npm ci' 'npm.cmd' @('ci')
    }
    $runningApp = Get-Process -Name pepehub -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like (Join-Path $releaseApp 'build\*') }
    if ($runningApp) { throw 'Закройте PepeHub, запущенный из папки build, и запустите выпуск снова.' }

    $branch = (Get-Git @('branch', '--show-current')) -join ''
    Write-Note "Ветка исходников: $branch"
    if ($branch -ne 'main' -and -not (Confirm-Release "Выпуск собирается не из main, а из «$branch». Продолжить?")) {
        throw 'Выпуск отменён.'
    }
    $dirty = @(Get-Git @('status', '--porcelain') | Where-Object { $_ })
    $includeChanges = $false
    if ($dirty.Count -gt 0) {
        Write-Note "Незакоммиченных изменений: $($dirty.Count). Они попадут в сборку." Yellow
        $dirty | Select-Object -First 12 | ForEach-Object { Write-Note "  $_" DarkGray }
        if ($dirty.Count -gt 12) { Write-Note "  ... и ещё $($dirty.Count - 12)" DarkGray }
        if ($NoSourcePush) {
            if (-not (Confirm-Release 'Продолжить?' $true)) { throw 'Выпуск отменён.' }
        } else {
            $includeChanges = Confirm-Release 'Включить их в релизный коммит? (n — закоммитить только версию и заметки)' $true
        }
    }

    Write-Note 'Запрашиваю последний опубликованный выпуск...'
    $latestBuild = 0
    $latestVersion = '0.0.0'
    try {
        $latest = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$releaseOwner/$releaseRepo/releases/latest" -Headers @{ 'User-Agent' = 'PepeHub release script' }
        $tagMatch = [regex]::Match([string]$latest.tag_name, '^v(\d+\.\d+\.\d+)-(\d+)$')
        if ($tagMatch.Success) {
            $latestVersion = $tagMatch.Groups[1].Value
            $latestBuild = [int]$tagMatch.Groups[2].Value
        }
        Write-Note "Опубликован: $($latest.tag_name)"
    } catch {
        Write-Note "Не удалось узнать опубликованный выпуск: $($_.Exception.Message)" Yellow
        if (-not (Confirm-Release 'Продолжить без этой проверки? (издатель всё равно проверит номер перед загрузкой)')) { throw 'Выпуск отменён.' }
    }

    if (-not $NoPublish) {
        # The publisher reads the same Git Credential Manager entry. Check it now,
        # not after a long build. The token stays in memory and is not printed.
        $previousInteractive = $env:GCM_INTERACTIVE
        $previousPreference = $ErrorActionPreference
        $env:GCM_INTERACTIVE = 'never'
        $env:GIT_TERMINAL_PROMPT = '0'
        try {
            $ErrorActionPreference = 'Continue'
            $credential = "protocol=https`nhost=github.com`n`n" | & git credential fill 2>$null
            $hasToken = [bool]($credential | Where-Object { "$_" -like 'password=?*' })
        } finally {
            $credential = $null
            $ErrorActionPreference = $previousPreference
            $env:GCM_INTERACTIVE = $previousInteractive
            Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        }
        if (-not $hasToken) { throw 'Нет входа GitHub в Git Credential Manager. Войдите (например, git push в любом репозитории) и повторите.' }
        Write-Note 'Вход GitHub найден.'
    }

    # ------------------------------------------------------------------
    Write-Step 'Версия'
    $current = Get-PubspecVersion
    Write-Note "Сейчас в pubspec.yaml: $($current.Version)+$($current.Build)"
    if ($KeepVersion) {
        $newVersion = $current.Version
        $newBuild = $current.Build
    } else {
        $newBuild = if ($Build -gt 0) { $Build } else { [Math]::Max($current.Build, $latestBuild) + 1 }
        if ($Version) {
            $newVersion = $Version
        } elseif ($current.Build -gt $latestBuild -and [version]$current.Version -ge [version]$latestVersion) {
            # The version was already raised by hand after the last release.
            $newVersion = $current.Version
            if ($Build -le 0) { $newBuild = $current.Build }
        } else {
            $base = if ([version]$current.Version -ge [version]$latestVersion) { [version]$current.Version } else { [version]$latestVersion }
            $newVersion = "$($base.Major).$($base.Minor).$($base.Build + 1)"
        }
    }
    if ($newVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Версия должна иметь вид major.minor.patch, получено: $newVersion" }
    if ($newBuild -le $latestBuild) { throw "Номер сборки $newBuild должен быть больше опубликованного $latestBuild." }
    if ([version]$newVersion -lt [version]$latestVersion) { throw "Версия $newVersion ниже опубликованной $latestVersion." }
    $tag = "v$newVersion-$newBuild"
    Write-Note "Выпуск: $newVersion+$newBuild  (tag $tag, Android versionCode $($newBuild + 2000))" Green
    if (-not (Confirm-Release 'Собрать этот выпуск?' $true)) { throw 'Выпуск отменён.' }
    if ($newVersion -ne $current.Version -or $newBuild -ne $current.Build) {
        Set-PubspecVersion $newVersion $newBuild
        Write-Note 'pubspec.yaml обновлён.'
    }

    $releaseLog = Join-Path $releaseRoot ".local\release-$newVersion-$newBuild.log"
    New-Item -ItemType Directory -Path (Split-Path -Parent $releaseLog) -Force | Out-Null
    Start-Transcript -LiteralPath $releaseLog -Append | Out-Null

    # ------------------------------------------------------------------
    Write-Step 'Заметки к выпуску'
    if (-not $NotesFile) { $NotesFile = Join-Path $releaseRoot ("docs\releases\RELEASE_" + ($newVersion -replace '\.', '') + '.md') }
    $NotesFile = [IO.Path]::GetFullPath($NotesFile)
    if (-not (Test-Path -LiteralPath $NotesFile)) {
        $lastRelease = (Get-Git @('log', '--format=%H', '-n', '1', '--extended-regexp', '--grep=^Release ') -AllowFailure) -join ''
        $range = if ($lastRelease) { "$lastRelease..HEAD" } else { 'HEAD' }
        $subjects = @(Get-Git @('log', '--no-merges', '--format=%s', $range) -AllowFailure | Where-Object { $_ } | Select-Object -First 30)
        $lines = @("# PepeHub $newVersion", '')
        if ($subjects.Count -gt 0) { $lines += $subjects | ForEach-Object { "- $_" } }
        else { $lines += '- Опишите изменения для пользователя.' }
        $lines += @('', "Windows x64 и Android ARM64, сборка $newBuild. Android versionCode $($newBuild + 2000).")
        [IO.File]::WriteAllText($NotesFile, (($lines -join "`r`n") + "`r`n"), $releaseUtf8)
        Write-Note "Создан черновик из коммитов: $NotesFile" Yellow
        Write-Note 'Перепишите его по-человечески: эти заметки увидят пользователи в окне обновления.' Yellow
    }
    if (-not $Yes) {
        Write-Note 'Открываю заметки в Блокноте. Сохраните и закройте окно, чтобы продолжить.'
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$NotesFile`"" -Wait
    }
    $notes = [IO.File]::ReadAllText($NotesFile)
    if ($notes.Trim().Length -eq 0) { throw 'Заметки пустые.' }
    if ($notes.Length -gt 8000) { throw "Заметки длиннее 8000 символов ($($notes.Length)). Сократите их." }
    Write-Note "Заметки: $([IO.Path]::GetFileName($NotesFile)), $($notes.Length) символов."

    # ------------------------------------------------------------------
    Write-Step 'Сборка Windows x64'
    $windowsArgs = @('-Target', 'Windows', '-NoOpen', '-LogPath', ".local\release-$newVersion-$newBuild-windows.log")
    if ($SkipTests) { $windowsArgs += '-SkipTests' }
    Invoke-Script 'Сборка Windows' 'run-local-build.ps1' $windowsArgs

    # ------------------------------------------------------------------
    Write-Step 'Сборка Android ARM64'
    if (-not $SkipTests) {
        Write-Note 'Нативные Android-тесты (JVM/Robolectric)...'
        . (Join-Path $PSScriptRoot 'android-env.ps1')
        Push-Location -LiteralPath (Join-Path $releaseApp 'android')
        try { Invoke-Native 'Нативные Android-тесты' '.\gradlew.bat' @(':app:testDebugUnitTest', '--console=plain') }
        finally { Pop-Location }
    }
    # Flutter tests already ran in the Windows step; only the APK build remains.
    Invoke-Script 'Сборка Android' 'run-local-build.ps1' @('-Target', 'Android', '-NoOpen', '-SkipTests', '-LogPath', ".local\release-$newVersion-$newBuild-android.log")

    # ------------------------------------------------------------------
    Write-Step 'Упаковка и подпись'
    Invoke-Script 'Подготовка пакетов' 'prepare-update.ps1' @('-NotesFile', $NotesFile)
    $output = Join-Path $releaseRoot "dist\online\$newVersion-$newBuild"
    Invoke-Native 'Подпись манифеста' 'node' @((Join-Path $PSScriptRoot 'publish-update.ts'))
    $catalog = [IO.File]::ReadAllText((Join-Path $output 'artifacts.json')) | ConvertFrom-Json
    $assets = @()
    foreach ($platform in $catalog.artifacts.PSObject.Properties) {
        $assets += $platform.Value
        $assets += @($platform.Value.deltas | Where-Object { $_ })
    }
    foreach ($asset in $assets) {
        Write-Note ('{0,-44} {1,8:N1} МиБ' -f $asset.file, ($asset.bytes / 1MB))
    }
    Write-Note "Пакеты: $output"

    if ($NoPublish) {
        Write-Host ''
        Write-Host "Готово: выпуск $tag подготовлен, но не опубликован (-NoPublish)." -ForegroundColor Green
        Write-Host "Опубликовать позже: node .\scripts\publish-update.ts --publish"
        return
    }

    # ------------------------------------------------------------------
    Write-Step 'Публикация на GitHub'
    if (-not (Confirm-Release "Опубликовать $tag в $releaseOwner/${releaseRepo}? После публикации выпуск неизменяем.")) {
        Write-Note 'Публикация отменена. Пакеты остались в dist\online.' Yellow
        Write-Note 'Опубликовать позже: node .\scripts\publish-update.ts --publish'
        return
    }
    Invoke-Native 'Публикация' 'node' @((Join-Path $PSScriptRoot 'publish-update.ts'), '--publish')

    if (-not $SkipVerify) {
        Write-Note 'Проверяю публичные файлы (скачивание, размер, SHA-256)...'
        $checkDir = Join-Path $releaseRoot ".local\release-check-$newBuild"
        New-Item -ItemType Directory -Path $checkDir -Force | Out-Null
        # The release is already public and immutable: a GitHub outage (502/504)
        # must not stop the source commit. Only a content mismatch is fatal.
        $delays = @(10, 20, 40, 60, 90)
        $unverified = @()
        foreach ($asset in $assets) {
            $url = "https://github.com/$releaseOwner/$releaseRepo/releases/download/$tag/$($asset.file)"
            $file = Join-Path $checkDir $asset.file
            $downloaded = $false
            for ($attempt = 0; $attempt -le $delays.Count -and -not $downloaded; $attempt++) {
                try {
                    Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $url -OutFile $file
                    $downloaded = $true
                } catch {
                    if ($attempt -eq $delays.Count) {
                        Write-Note "НЕ ПРОВЕРЕН  $($asset.file): $($_.Exception.Message)" Yellow
                        $unverified += $asset.file
                    } else {
                        Write-Note "    $($asset.file): $($_.Exception.Message); повтор через $($delays[$attempt]) с" DarkGray
                        Start-Sleep -Seconds $delays[$attempt]
                    }
                }
            }
            if (-not $downloaded) { continue }
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
            if ((Get-Item -LiteralPath $file).Length -ne [long]$asset.bytes -or $hash -ne $asset.sha256) {
                throw "Опубликованный файл не совпал с подготовленным: $($asset.file)"
            }
            Write-Note "OK  $($asset.file)" Green
        }
        Remove-Item -LiteralPath $checkDir -Recurse -Force
        try {
            $feed = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 -Uri "https://github.com/$releaseOwner/$releaseRepo/releases/latest/download/update.json"
            $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($feed.payload)) | ConvertFrom-Json
            if ([int]$payload.build -ne $newBuild) { throw "latest/update.json указывает на сборку $($payload.build), ожидалась $newBuild." }
            Write-Note "latest/update.json указывает на сборку $newBuild." Green
        } catch [System.Net.WebException] {
            Write-Note "НЕ ПРОВЕРЕН  latest/update.json: $($_.Exception.Message)" Yellow
            $unverified += 'update.json'
        }
        if ($unverified.Count -gt 0) {
            Write-Note "GitHub не отдал файлы: $($unverified -join ', '). Выпуск опубликован; проверьте их позже на странице выпуска." Yellow
        }
    }

    # ------------------------------------------------------------------
    Write-Step 'Исходники'
    if ($NoSourcePush) {
        Write-Note 'Пропущено (-NoSourcePush). Не забудьте закоммитить pubspec.yaml и заметки.' Yellow
    } else {
        if ($includeChanges) {
            Get-Git @('add', '--all') | Out-Null
        } else {
            Get-Git @('add', '--', $releasePubspec, $NotesFile) | Out-Null
        }
        $staged = @(Get-Git @('diff', '--cached', '--name-only') | Where-Object { $_ })
        if ($staged.Count -eq 0) {
            Write-Note 'Нечего коммитить.'
        } else {
            Get-Git @('commit', '-q', '-m', "Release $newVersion+$newBuild") | Out-Null
            Write-Note "Коммит: Release $newVersion+$newBuild ($($staged.Count) файлов)"
        }
        Write-Note "Отправляю ветку $branch..."
        & git -C $releaseRoot push -u origin $branch
        if ($LASTEXITCODE -ne 0) { Write-Note 'git push не удался: выпуск опубликован, отправьте коммит вручную.' Yellow }
    }

    Write-Host ''
    Write-Host "Готово: https://github.com/$releaseOwner/$releaseRepo/releases/tag/$tag" -ForegroundColor Green
    Write-Host "Пользователи увидят обновление в «Настройки → Обновление приложения»."
} catch {
    Write-Host ''
    Write-Host "ВЫПУСК ОСТАНОВЛЕН: $($_.Exception.Message)" -ForegroundColor Red
    if ($releaseLog) { Write-Host "Лог: $releaseLog" }
    $releaseExit = 1
} finally {
    if ($releaseLog) { try { Stop-Transcript | Out-Null } catch { } }
    Pop-Location
}
exit $releaseExit
