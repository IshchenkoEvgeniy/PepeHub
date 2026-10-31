# Как собрать и выпустить PepeHub

Инструкция для Windows-компьютера с проектом в `L:\project\PepeHub` и подготовленной локальной средой `.tools`. Команды выполняются в PowerShell. Приложение выпускается для Windows x64 и Android ARM64.

Сборка создаёт приложение на компьютере. Публикация загружает готовые пакеты и подписанный манифест в отдельный репозиторий `IshchenkoEvgeniy/PepeHub-Releases`, после чего выпуск становится доступен через настройки PepeHub.

## 1. Подготовить среду

Откройте PowerShell в корне проекта:

```powershell
Set-Location L:\project\PepeHub
```

Для работы нужны:

- Flutter и Dart в `.tools\flutter`; зависимости приложения указаны в `apps\pepehub\pubspec.yaml` и `pubspec.lock`.
- Visual Studio с компонентами разработки классических приложений на C++, Windows SDK и CMake для Windows-сборки.
- JDK в `.tools\jdk`, Android SDK/NDK в `.tools\android-sdk`. Скрипты используют Android Build Tools `36.0.0` и платформу `android-36`; дополнительные компоненты должны соответствовать Flutter и плагинам проекта.
- Node.js 24+ и npm; Git for Windows с Git Credential Manager для публикации.
- Исходные шрифты и остальные файлы `apps\pepehub\assets`.

Проверить локальные инструменты и ресурсы без сборки:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-local-build.ps1 -Target Windows -CheckOnly
if ($LASTEXITCODE -ne 0) { throw 'Проверка Windows-среды не прошла' }

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-local-build.ps1 -Target Android -CheckOnly
if ($LASTEXITCODE -ne 0) { throw 'Проверка Android-среды не прошла' }

.\.tools\flutter\bin\flutter.bat doctor -v
```

`CheckOnly` проверяет предусмотренные скриптом пути и ресурсы, но не заменяет проверку toolchain через `flutter doctor` и настоящую сборку. `ExecutionPolicy Bypass` в этих командах относится только к запускаемому процессу.

На другом компьютере одной копии Git-репозитория недостаточно: `.tools` и `.local` не хранятся в Git. Инструменты нужно установить/восстановить отдельно, а ключи — перенести из защищённой резервной копии.

### Сохранить совместимость обновлений

Нужны **прежние** ключи:

| Файл | Для чего нужен |
|---|---|
| `.tools\android-user\debug.keystore` | Подпись APK, совместимая с уже установленными PepeHub |
| `.local\update-signing\private.pem` | Подпись `update.json`, которому доверяют установленные приложения |
| `apps\pepehub\lib\updates\update_trust.dart` | Встроенный публичный ключ проверки манифеста |

Приватные ключи не включайте в Git, архив приложения или GitHub Release. Если ключ отсутствует либо не совпадает с прежним, восстановите его из резервной копии. Замена ключа новым нарушит совместимость; скрипты проверяют это и останавливаются.

## 2. Выбрать версию и написать изменения

Сначала посмотрите уже опубликованный номер:

```powershell
(Invoke-RestMethod -Uri 'https://api.github.com/repos/IshchenkoEvgeniy/PepeHub-Releases/releases/latest').tag_name
```

Измените `version` в `apps\pepehub\pubspec.yaml`. Например, **после `0.30.0+80`** можно использовать:

```yaml
version: 0.30.1+81
```

Это пример, а не зарезервированный номер: число после `+` должно быть больше всех уже опубликованных сборок. Имя версии не должно уменьшаться. Версия корневого `package.json` не управляет версией приложения.

Для этого примера:

| Значение | Результат |
|---|---|
| Имя версии | `0.30.1` |
| Windows / общий номер сборки | `81` |
| Android ARM64 `versionCode` | `2081` — Flutter добавляет `2000` для этого ABI |
| GitHub tag | `v0.30.1-81` |
| Каталог пакетов | `dist\online\0.30.1-81` |

Создайте `docs\RELEASE_0301.md` с изменениями для пользователя и результатами проверок. Уже использованный пример оформления — `docs\RELEASE_0300.md`. Длина заметок для текущего издателя ограничена 8000 символами.

После изменения версии нужно собрать **обе платформы заново**. После изменения исходников после сборки также пересоберите затронутые пакеты перед упаковкой.

## 3. Проверить Node.js-часть

Из корня проекта:

```powershell
npm ci
if ($LASTEXITCODE -ne 0) { throw 'Не удалось установить Node-зависимости' }
npm test
if ($LASTEXITCODE -ne 0) { throw 'Node-тесты не прошли' }
npm run typecheck
if ($LASTEXITCODE -ne 0) { throw 'Проверка TypeScript не прошла' }
```

Эти проверки включают серверный протокол, издатель обновлений и Windows-помощник установки. Для обычной работы готового приложения запуск локального API не требуется.

## 4. Собрать Windows

Закройте экземпляр PepeHub, запущенный из каталога сборки. Выполните:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-local-build.ps1 -Target Windows -NoOpen -LogPath .local\release-windows.log
if ($LASTEXITCODE -ne 0) { throw 'Windows-сборка не прошла; см. .local\release-windows.log' }
```

Скрипт последовательно проверяет ресурсы, получает Flutter-зависимости, подготавливает Windows-плагины, запускает анализ и полный набор Flutter-тестов, затем собирает release и проверяет версию EXE. `-NoOpen` оставляет готовое приложение закрытым.

Результат:

```text
apps\pepehub\build\windows\x64\runner\Release\
  pepehub.exe
  *.dll
  data\
```

Для запуска и распространения нужна вся папка, включая DLL и `data`, а не один EXE.

## 5. Проверить нативный Android-код

После подготовки Flutter-зависимостей предыдущим шагом:

```powershell
. .\scripts\android-env.ps1
Push-Location .\apps\pepehub\android
try {
    .\gradlew.bat :app:testDebugUnitTest --console=plain
    if ($LASTEXITCODE -ne 0) { throw 'Нативные Android-тесты не прошли' }
} finally {
    Pop-Location
}
```

Это JVM/Robolectric-тесты, в том числе доступа к файлам и установщика обновлений. Они не устанавливают приложение на телефон. Итоговый HTML-отчёт находится в `apps\pepehub\build\app\reports\tests\testDebugUnitTest\index.html`.

## 6. Собрать Android ARM64

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-android.ps1 -Architecture arm64
if ($LASTEXITCODE -ne 0) { throw 'Android-сборка не прошла' }
```

Этот вариант подходит после успешных Flutter-проверок шага 4. Скрипт обновляет зависимости/регистрацию плагинов, собирает release APK, проверяет прежний сертификат, версию, ARM64 ABI, выравнивание и ресурсы медиакнопок.

Для отдельной Android-сборки с собственным полным прогоном анализа и Flutter-тестов используйте общий запускатель:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-local-build.ps1 -Target Android -NoOpen -LogPath .local\release-android.log
if ($LASTEXITCODE -ne 0) { throw 'Android-сборка и проверки не прошли' }
```

Для примера `0.30.1+81` готовые файлы:

```text
dist\PepeHub-0.30.1-android-arm64-test.apk
dist\PepeHub-0.30.1-android-arm64-test.apk.sha256
```

Суффикс `-test.apk` — историческое имя локального файла. Сборка выполняется с `--release`; в публичном выпуске APK получает имя `PepeHub-android-arm64.apk`.

**Windows и Android собирайте последовательно:** они используют общие генерируемые Flutter-файлы. Общий запускатель содержит блокировку одновременных запусков; при прямом вызове Flutter/Gradle следите за этим самостоятельно.

## 7. Подготовить пакеты без публикации

Из корня проекта:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish-update.ps1 -NotesFile .\docs\RELEASE_0301.md
if ($LASTEXITCODE -ne 0) { throw 'Не удалось подготовить выпуск' }
```

**Без `-Publish` эта команда ничего не загружает в GitHub.** Она проверяет версии обеих сборок и сертификат APK, упаковывает Windows, копирует APK, создаёт и проверяет дельты, сохраняет заметки и подписывает манифест.

Результат примера:

```text
dist\online\0.30.1-81\
  PepeHub-windows-x64.zip
  PepeHub-android-arm64.apk
  PepeHub-*-from-<номер>.pdelta   # если есть подходящие основы
  artifacts.json
  notes.md
  update.json
```

`artifacts.json` содержит локальные имена файлов, размеры и SHA-256. `update.json` содержит подписанное описание версии, ссылок и контрольных сумм. В Windows ZIP попадают EXE, DLL и `data`; исходники, PDB и ключи не упаковываются.

Дельты создаются максимум с двух последних локальных предыдущих сборок в `dist\online`. Если локальных основ вообще нет, скрипт пытается получить последний опубликованный пакет. Отсутствующие/неподходящие основы пропускаются; дельты размером не меньше 90% полного пакета не сохраняются. Поэтому количество `.pdelta` может различаться. Полные пакеты остаются обязательными для обеих платформ.

Для следующих выпусков полезно сохранять проверенные пакеты двух предыдущих версий. Не редактируйте ZIP/APK/дельты после подготовки: подпись и контрольные суммы относятся к точным байтам.

Просмотрите `notes.md` и метаданные:

```powershell
Get-Content .\dist\online\0.30.1-81\artifacts.json
Get-ChildItem .\dist\online\0.30.1-81
```

## 8. Опубликовать в стабильном канале

Издатель использует вход GitHub из **Git Credential Manager**. Нужна учётная запись `IshchenkoEvgeniy` с правами записи в `IshchenkoEvgeniy/PepeHub-Releases`: владелец закреплён в текущем скрипте. Восстановите вход через Git Credential Manager, если издатель сообщает об отсутствии учётных данных. Не выводите содержимое `git credential fill` в консоль — там может быть токен.

Чтобы опубликовать уже подготовленные и просмотренные пакеты, выполните:

```powershell
node .\scripts\publish-update.ts --publish
if ($LASTEXITCODE -ne 0) { throw 'Публикация не завершена; проверьте сообщение издателя' }
```

Скрипт берёт версию из `pubspec.yaml`, повторно проверяет хеши файлов, подписывает манифест, создаёт черновик GitHub Release, загружает оба полных пакета, дельты и `update.json`. После завершения загрузок он публикует выпуск и отмечает его как latest. Успешный вывод заканчивается строкой:

```text
Published: https://github.com/IshchenkoEvgeniy/PepeHub-Releases/releases/tag/v0.30.1-81
```

Если хотите заново выполнить и упаковку, и публикацию одной командой:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish-update.ps1 -NotesFile .\docs\RELEASE_0301.md -Publish
if ($LASTEXITCODE -ne 0) { throw 'Подготовка или публикация не завершена' }
```

Если загрузка прервалась и остался **черновик**, повторите `node .\scripts\publish-update.ts --publish` с теми же подготовленными файлами. Уже опубликованные сборки неизменяемы: для исправления опубликованного выпуска нужен новый номер после `+` и новый релиз.

Эти команды публикуют бинарные пакеты. Коммит и отправка исходников в основной репозиторий — отдельный шаг.

## 9. Проверить публичный выпуск

Проверьте не только наличие страницы GitHub, но и работу канала обновлений.

### Проверка настоящим клиентским кодом

Пример: опубликована сборка 81, обновление проверяется со сборки 80.

```powershell
$env:PEPEHUB_VERIFY_UPDATE_FEED = 'https://github.com/IshchenkoEvgeniy/PepeHub-Releases/releases/latest/download/update.json'
$env:PEPEHUB_VERIFY_UPDATE_BUILD = '81'
$env:PEPEHUB_VERIFY_UPDATE_FROM_BUILD = '80'
$env:PEPEHUB_VERIFY_UPDATE_FROM_VERSION = '0.30.0'
Push-Location .\apps\pepehub
try {
    & ..\..\.tools\flutter\bin\flutter.bat test --no-pub test/update_public_acceptance_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Публичная проверка обновления не прошла' }
} finally {
    Pop-Location
    Remove-Item Env:\PEPEHUB_VERIFY_UPDATE_FEED, Env:\PEPEHUB_VERIFY_UPDATE_BUILD, Env:\PEPEHUB_VERIFY_UPDATE_FROM_BUILD, Env:\PEPEHUB_VERIFY_UPDATE_FROM_VERSION -ErrorAction SilentlyContinue
}
```

Тест проверяет встроенный ключ подписи, ожидаемый номер выпуска и обнаружение обновления для Windows/Android. Затем скачивает полный Windows ZIP, проверяет его и распаковывает во временную папку. При поддержке сервером Range проверяется докачка. Приложение не устанавливается, личная библиотека не открывается. Полный пакет запрашивается явно: в изолированном тесте нет установленной основы для дельты.

### Проверка скачивания APK и остальных файлов

Следующий блок скачивает оба полных пакета и все подготовленные дельты по публичным ссылкам, сравнивая размеры и SHA-256 с локальным каталогом. Используйте свои версию и сборку:

```powershell
$releaseVersion = '0.30.1'
$releaseBuild = 81
$releaseCatalog = Get-Content -Raw -LiteralPath ".\dist\online\$releaseVersion-$releaseBuild\artifacts.json" -ErrorAction Stop | ConvertFrom-Json
$releaseCheckDir = ".\.local\release-check-$releaseBuild"
New-Item -ItemType Directory -Path $releaseCheckDir -Force -ErrorAction Stop | Out-Null
$releaseFiles = @()
foreach ($releasePlatform in $releaseCatalog.artifacts.PSObject.Properties) {
    $releaseFiles += $releasePlatform.Value
    $releaseFiles += @($releasePlatform.Value.deltas)
}
foreach ($releaseAsset in $releaseFiles) {
    if ($null -eq $releaseAsset) { continue }
    $releaseUrl = "https://github.com/IshchenkoEvgeniy/PepeHub-Releases/releases/download/v$releaseVersion-$releaseBuild/$($releaseAsset.file)"
    $releaseFile = Join-Path $releaseCheckDir $releaseAsset.file
    Invoke-WebRequest -UseBasicParsing -Uri $releaseUrl -OutFile $releaseFile -ErrorAction Stop
    $releaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseFile -ErrorAction Stop).Hash.ToLowerInvariant()
    if ((Get-Item -LiteralPath $releaseFile -ErrorAction Stop).Length -ne [long]$releaseAsset.bytes -or $releaseHash -ne $releaseAsset.sha256) {
        throw "Не совпали размер или SHA-256: $($releaseAsset.file)"
    }
    Write-Output "Проверено: $($releaseAsset.file)"
}
```

Эта проверка скачивания дополняет проверку подписи манифеста клиентским тестом выше. Для проверки установки на конкретном устройстве установите APK поверх прежнего PepeHub и проверьте сохранение данных; на Windows проверьте обновление из меню настроек. Не удаляйте прежнее приложение ради обновления.

## Если что-то пошло не так

| Сообщение или ситуация | Что сделать |
|---|---|
| `Another PepeHub build is running` | Дождаться завершения другой сборки. Не запускать платформы одновременно. |
| `Close the running PepeHub application` | Закрыть приложение из каталога `build`, затем повторить сборку. |
| CMake: `Does not match the generator used previously` | Кэш Windows создан другой установкой Visual Studio. Сохраните генерируемые `CMakeCache.txt` и `CMakeFiles` из `apps/pepehub/build/windows/x64` под резервными именами и используйте одну выбранную установку Visual Studio для генерации и сборки. Не удаляйте исходники или `.tools`. |
| C++: не найден `atlstr.h` | В выбранной установке Visual Studio отсутствует компонент ATL для C++ x64/x86. Добавьте его через Visual Studio Installer или используйте прежнюю подготовленную установку. При нескольких установках Flutter предпочитает стабильную перед предварительной; `flutter doctor` не проверяет наличие ATL. |
| Ошибка symlink / `ERROR_PRIVILEGE_NOT_HELD` | Использовать общий запускатель: он умеет подготовить junction-ссылки через `prepare-windows.ps1` и повторить `pub get`. |
| Анализ или тесты завершились ошибкой | Прочитать лог и устранить причину перед публикацией. |
| Версия EXE/APK не соответствует `pubspec` | Пересобрать нужную платформу после изменения версии. Не переименовывать старый APK вместо сборки. |
| Отличается сертификат APK / отсутствует приватный ключ манифеста | Восстановить прежний ключ из резервной копии. |
| `Increase the pubspec build number` / опубликованный tag уже существует | Выбрать следующий номер сборки и пересобрать обе платформы. |
| `GitHub credentials are unavailable` | Восстановить вход нужной учётной записи в Git Credential Manager. |
| Обрыв загрузки GitHub | Повторить публикацию того же черновика с теми же проверенными пакетами. |
| Дельт нет | Проверить доступность прежних пакетов и их метаданных. Выпуск с двумя полными пакетами допустим. |
| В приложении не виден выпуск | Проверить latest, публичный `update.json`, номер сборки и подпись; затем нажать ручную проверку в настройках. |

Лог общей Windows-сборки в командах выше: `.local\release-windows.log`. Для общего Android-запускателя: `.local\release-android.log`. Выбранный `-LogPath` выводится при старте; предыдущий лог сохраняется с суффиксом `.previous`.

Исходники используемых команд: `scripts/run-local-build.ps1`, `scripts/build-android.ps1`, `scripts/prepare-update.ps1`, `scripts/prepare-update-deltas.ts`, `scripts/publish-update.ps1`, `scripts/publish-update.ts`. Подробности обновлятора: [APP_UPDATES.md](APP_UPDATES.md); обычных локальных сборок: [LOCAL_BUILDS.md](LOCAL_BUILDS.md).
