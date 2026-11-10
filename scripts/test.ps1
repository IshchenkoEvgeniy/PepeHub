<#
.SYNOPSIS
    Проверки PepeHub одной командой, без сборки.

.DESCRIPTION
    Те же проверки, что выполняет CI (.github/workflows/tests.yml):
      1. проверяет инструменты;
      2. тесты и типы скриптов обновления (npm test, npm run typecheck);
      3. форматирование кода (dart format; с -Format — исправляет, иначе только проверяет);
      4. анализ приложения (flutter analyze);
      5. тесты приложения (flutter test);
      6. по запросу — нативные Android-тесты (JVM/Robolectric).

    Останавливается на первой ошибке. Ничего не собирает и не меняет в git.
    Лог: .local\test.log (предыдущий — test.log.previous).
    Совместим с Windows PowerShell 5.1.

.EXAMPLE
    .\scripts\test.ps1
    Скрипты обновления, анализ и все тесты приложения.

.EXAMPLE
    .\scripts\test.ps1 test\library_archive_test.dart test\database_schema_test.dart
    Анализ и только указанные тесты (пути относительно apps\pepehub).

.EXAMPLE
    .\scripts\test.ps1 -Format
    Отформатировать код (dart format) и затем выполнить остальные проверки.

.EXAMPLE
    .\scripts\test.ps1 -Android
    Дополнительно прогнать нативные Android-тесты.
#>
param(
    # Не запускать тесты и проверку типов скриптов обновления (Node).
    [switch]$SkipNode,
    # Отформатировать код вместо проверки форматирования.
    [switch]$Format,
    # Не проверять форматирование.
    [switch]$SkipFormat,
    # Не запускать flutter analyze.
    [switch]$SkipAnalyze,
    # Только анализ: не запускать тесты приложения.
    [switch]$AnalyzeOnly,
    # Дополнительно прогнать нативные Android-тесты (JVM/Robolectric).
    [switch]$Android,
    # Файлы или папки тестов относительно apps\pepehub. По умолчанию — все.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Tests
)

$ErrorActionPreference = 'Stop'
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testApp = Join-Path $testRoot 'apps\pepehub'
$testFlutter = Join-Path $testRoot '.tools\flutter\bin\flutter.bat'
$testStep = 0
$testTotal = 6
$testDart = Join-Path $testRoot '.tools\flutter\bin\dart.bat'
$testFormatPaths = @('lib', 'test', 'integration_test', 'tool')
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Write-Step([string]$Title) {
    $script:testStep++
    Write-Host ''
    Write-Host "[$script:testStep/$testTotal] $Title" -ForegroundColor Cyan
}

function Write-Note([string]$Text, [ConsoleColor]$Color = 'Gray') { Write-Host "    $Text" -ForegroundColor $Color }

function Invoke-Native([string]$Title, [string]$File, [string[]]$Arguments) {
    # Pipe the output so the transcript (.local\test.log) records it. Windows
    # PowerShell 5.1 turns redirected stderr into errors under 'Stop'; judge
    # the command by its exit code instead.
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        & $File @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "$Title — ошибка (код $code)." }
}

$testLog = $null
$testExit = 0
$testStarted = Get-Date
try {
    Push-Location -LiteralPath $testRoot

    $testLogPath = Join-Path $testRoot '.local\test.log'
    New-Item -ItemType Directory -Path (Split-Path -Parent $testLogPath) -Force | Out-Null
    if (Test-Path -LiteralPath $testLogPath) { Move-Item -LiteralPath $testLogPath -Destination "$testLogPath.previous" -Force }
    Start-Transcript -LiteralPath $testLogPath | Out-Null
    $testLog = $testLogPath

    # ------------------------------------------------------------------
    Write-Step 'Проверка окружения'
    if (-not (Test-Path -LiteralPath $testFlutter -PathType Leaf)) {
        $found = Get-Command flutter -ErrorAction SilentlyContinue
        if (-not $found) { throw 'Не найден .tools\flutter\bin\flutter.bat, и команды flutter нет в PATH.' }
        $testFlutter = $found.Source
        $foundDart = Get-Command dart -ErrorAction SilentlyContinue
        if ($foundDart) { $testDart = $foundDart.Source } else { $testDart = $null }
        Write-Note "Локального Flutter нет, используется $testFlutter" Yellow
    } else {
        $env:PUB_CACHE = Join-Path $testRoot '.tools\pub-cache'
    }
    if (-not $SkipNode) {
        foreach ($command in @('node', 'npm')) {
            if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Команда $command не найдена в PATH (или запустите с -SkipNode)." }
        }
        $nodeMajor = [int]((& node --version) -replace '^v(\d+).*', '$1')
        if ($nodeMajor -lt 24) { throw "Нужен Node.js 24+, установлен $(& node --version)." }
    }
    Write-Note "Flutter: $testFlutter"

    # ------------------------------------------------------------------
    Write-Step 'Скрипты обновления (Node)'
    if ($SkipNode) {
        Write-Note 'Пропущено (-SkipNode).' Yellow
    } else {
        if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'node_modules'))) {
            Write-Note 'Устанавливаю Node-зависимости (npm ci)...'
            Invoke-Native 'npm ci' 'npm.cmd' @('ci')
        }
        Invoke-Native 'npm test' 'npm.cmd' @('test')
        Invoke-Native 'npm run typecheck' 'npm.cmd' @('run', 'typecheck')
    }

    Push-Location -LiteralPath $testApp
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $testApp '.dart_tool\package_config.json'))) {
            Write-Note 'Получаю зависимости Flutter (flutter pub get)...'
            Invoke-Native 'flutter pub get' $testFlutter @('pub', 'get')
        }

        # --------------------------------------------------------------
        Write-Step 'Форматирование кода'
        if ($SkipFormat) {
            Write-Note 'Пропущено (-SkipFormat).' Yellow
        } elseif (-not $testDart) {
            Write-Note 'Пропущено: команда dart не найдена.' Yellow
        } elseif ($Format) {
            Invoke-Native 'dart format' $testDart (@('format') + $testFormatPaths)
        } else {
            try {
                Invoke-Native 'dart format' $testDart (@('format', '--output=none', '--set-exit-if-changed') + $testFormatPaths)
            } catch {
                throw 'Код не отформатирован (файлы перечислены выше). Запустите scripts\test.cmd -Format и повторите.'
            }
        }

        # --------------------------------------------------------------
        Write-Step 'Анализ приложения'
        if ($SkipAnalyze) {
            Write-Note 'Пропущено (-SkipAnalyze).' Yellow
        } else {
            Invoke-Native 'flutter analyze' $testFlutter @('analyze', '--no-pub')
        }

        # --------------------------------------------------------------
        Write-Step 'Тесты приложения'
        if ($AnalyzeOnly) {
            Write-Note 'Пропущено (-AnalyzeOnly).' Yellow
        } else {
            $flutterArgs = @('test', '--no-pub')
            if ($Tests -and $Tests.Count -gt 0) {
                Write-Note "Только: $($Tests -join ', ')"
                $flutterArgs += $Tests
            }
            Invoke-Native 'flutter test' $testFlutter $flutterArgs
        }
    } finally { Pop-Location }

    # ------------------------------------------------------------------
    Write-Step 'Нативные Android-тесты'
    if (-not $Android) {
        Write-Note 'Пропущено (запустите с -Android, чтобы включить).'
    } else {
        . (Join-Path $PSScriptRoot 'android-env.ps1')
        Push-Location -LiteralPath (Join-Path $testApp 'android')
        try { Invoke-Native 'Нативные Android-тесты' '.\gradlew.bat' @(':app:testDebugUnitTest', '--console=plain') }
        finally { Pop-Location }
    }

    $elapsed = (Get-Date) - $testStarted
    Write-Host ''
    Write-Host "ПРОВЕРКИ ПРОЙДЕНЫ за $([int][Math]::Floor($elapsed.TotalMinutes)) мин $($elapsed.Seconds) с" -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "ПРОВЕРКИ НЕ ПРОЙДЕНЫ: $($_.Exception.Message)" -ForegroundColor Red
    $testExit = 1
} finally {
    if ($testLog) {
        try { Stop-Transcript | Out-Null } catch { }
        Write-Host "Лог: $testLog"
    }
    Pop-Location
}
exit $testExit
