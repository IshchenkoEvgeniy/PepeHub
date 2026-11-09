<#
.SYNOPSIS
    Коммит и отправка исходников PepeHub одной командой.

.DESCRIPTION
      1. показывает ветку и незакоммиченные изменения;
      2. по запросу (-Test) прогоняет проверки scripts\test.ps1;
      3. добавляет все изменения и создаёт коммит с вашим сообщением;
      4. после подтверждения отправляет ветку в origin.

    Версию и заметки к выпуску не трогает — для выпуска есть release.ps1.
    Игнорируемые файлы (.local, .tools, dist, build) в коммит не попадают.
    Совместим с Windows PowerShell 5.1.

.EXAMPLE
    .\scripts\commit.ps1
    Показать изменения, спросить сообщение, закоммитить и предложить отправку.

.EXAMPLE
    .\scripts\commit.ps1 "Rename library classes" -Test
    Сначала анализ и тесты; коммит создаётся только если они прошли.

.EXAMPLE
    .\scripts\commit.ps1 "Fix cover cache" -NoPush
    Только локальный коммит.
#>
param(
    # Сообщение коммита. Если не указано — будет запрошено.
    [Parameter(Position = 0)][string]$Message,
    # Перед коммитом прогнать scripts\test.ps1 (анализ и все тесты).
    [switch]$Test,
    # Не отправлять ветку в origin.
    [switch]$NoPush,
    # Отвечать «да» на все вопросы (сообщение тогда обязательно).
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$commitRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$commitPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$commitStep = 0
$commitTotal = 4
$commitUtf8 = [Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Write-Step([string]$Title) {
    $script:commitStep++
    Write-Host ''
    Write-Host "[$script:commitStep/$commitTotal] $Title" -ForegroundColor Cyan
}

function Write-Note([string]$Text, [ConsoleColor]$Color = 'Gray') { Write-Host "    $Text" -ForegroundColor $Color }

function Confirm-Commit([string]$Question, [bool]$DefaultYes = $false) {
    if ($Yes) { return $true }
    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = (Read-Host "    $Question $hint").Trim().ToLowerInvariant()
    if ($answer -eq '') { return $DefaultYes }
    return $answer -in @('y', 'yes', 'д', 'да')
}

function Get-Git([string[]]$Arguments, [switch]$AllowFailure) {
    # Windows PowerShell 5.1 turns redirected native stderr into terminating
    # errors under 'Stop'; judge git by its exit code instead.
    $ErrorActionPreference = 'Continue'
    $output = @(& git -C $commitRoot @Arguments 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return @() }
        throw "git $($Arguments -join ' '): $($output -join ' ')"
    }
    return $output
}

$commitExit = 0
$commitMessageFile = $null
try {
    Push-Location -LiteralPath $commitRoot

    # ------------------------------------------------------------------
    Write-Step 'Изменения'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Команда git не найдена в PATH.' }
    $branch = (Get-Git @('branch', '--show-current')) -join ''
    if (-not $branch) { throw 'Не удалось определить ветку (detached HEAD?). Переключитесь на ветку и повторите.' }
    Write-Note "Ветка: $branch"
    $dirty = @(Get-Git @('status', '--porcelain') | Where-Object { $_ })
    if ($dirty.Count -eq 0) {
        Write-Note 'Незакоммиченных изменений нет.'
    } else {
        Write-Note "Изменённых файлов: $($dirty.Count)"
        $dirty | Select-Object -First 30 | ForEach-Object { Write-Note "  $_" DarkGray }
        if ($dirty.Count -gt 30) { Write-Note "  ... и ещё $($dirty.Count - 30)" DarkGray }
    }

    # ------------------------------------------------------------------
    Write-Step 'Проверки'
    if ($dirty.Count -eq 0) {
        Write-Note 'Пропущено: коммитить нечего.'
    } elseif (-not $Test) {
        Write-Note 'Пропущено (запустите с -Test, чтобы прогнать анализ и тесты перед коммитом).'
    } else {
        & $commitPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Проверки не пройдены — коммит не создан. Подробности выше и в .local\test.log.' }
    }

    # ------------------------------------------------------------------
    Write-Step 'Коммит'
    if ($dirty.Count -eq 0) {
        Write-Note 'Пропущено: коммитить нечего.'
    } else {
        if (-not $Message) {
            if ($Yes) { throw 'С -Yes сообщение коммита нужно передать параметром.' }
            $Message = Read-Host '    Сообщение коммита (пусто — отмена)'
        }
        $Message = "$Message".Trim()
        if (-not $Message) { throw 'Коммит отменён: пустое сообщение.' }

        Get-Git @('add', '--all') | Out-Null
        $staged = @(Get-Git @('diff', '--cached', '--name-only') | Where-Object { $_ })
        if ($staged.Count -eq 0) {
            Write-Note 'После git add изменений нет (различались только переводы строк).'
        } else {
            # A message file keeps quotes and Cyrillic intact under PowerShell 5.1.
            $commitMessageFile = Join-Path ([IO.Path]::GetTempPath()) ("pepehub-commit-" + [Guid]::NewGuid().ToString('N') + '.txt')
            [IO.File]::WriteAllText($commitMessageFile, $Message + "`n", $commitUtf8)
            Get-Git @('commit', '-q', '-F', $commitMessageFile) | Out-Null
            $hash = (Get-Git @('rev-parse', '--short', 'HEAD')) -join ''
            Write-Note "Коммит ${hash}: $Message ($($staged.Count) файлов)" Green
        }
    }

    # ------------------------------------------------------------------
    Write-Step 'Отправка'
    $upstream = (Get-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -AllowFailure) -join ''
    if ($upstream) {
        $ahead = [int]((Get-Git @('rev-list', '--count', '@{u}..HEAD')) -join '')
    } else {
        $ahead = [int]((Get-Git @('rev-list', '--count', 'HEAD')) -join '')
        Write-Note "У ветки $branch ещё нет ветки в origin." Yellow
    }
    if ($ahead -eq 0) {
        Write-Note 'Отправлять нечего: origin уже содержит все коммиты.'
    } elseif ($NoPush) {
        Write-Note "Пропущено (-NoPush). Неотправленных коммитов: $ahead." Yellow
    } else {
        Write-Note "Неотправленных коммитов: $ahead"
        Get-Git @('log', '--oneline', '-n', '10', $(if ($upstream) { '@{u}..HEAD' } else { 'HEAD' })) | ForEach-Object { Write-Note "  $_" DarkGray }
        if (Confirm-Commit "Отправить ветку $branch в origin?" $true) {
            & git -C $commitRoot push -u origin $branch
            if ($LASTEXITCODE -ne 0) { throw 'git push не удался. Коммит сохранён локально; отправьте его позже.' }
            Write-Note 'Отправлено.' Green
        } else {
            Write-Note 'Не отправлено. Коммит сохранён локально.' Yellow
        }
    }

    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "ОСТАНОВЛЕНО: $($_.Exception.Message)" -ForegroundColor Red
    $commitExit = 1
} finally {
    if ($commitMessageFile -and (Test-Path -LiteralPath $commitMessageFile)) { Remove-Item -LiteralPath $commitMessageFile -Force -ErrorAction SilentlyContinue }
    Pop-Location
}
exit $commitExit
