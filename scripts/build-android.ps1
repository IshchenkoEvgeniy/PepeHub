param([ValidateSet('arm64','universal')][string]$Architecture = 'arm64', [switch]$NoPub)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-env.ps1')
$pepeFlutter = Join-Path $pepeRoot '.tools\flutter\bin\flutter.bat'
Push-Location (Join-Path $pepeRoot 'apps\pepehub')
try {
    # Flutter must refresh generated plugin registration after integration-test runs.
    $pepeArguments = @('build','apk','--release')
    if ($Architecture -eq 'arm64') { $pepeArguments += @('--target-platform=android-arm64','--split-per-abi') }
    if ($NoPub) { $pepeArguments += '--no-pub' }
    & $pepeFlutter @pepeArguments
    if ($LASTEXITCODE -ne 0) { throw "Android build failed: $LASTEXITCODE" }
    $pepeVersionLine = Get-Content -LiteralPath 'pubspec.yaml' | Where-Object { $_ -match '^version:' } | Select-Object -First 1
    $pepeVersion = (($pepeVersionLine -replace '^version:\s*', '') -split '\+')[0].Trim()
    if ($pepeVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Unexpected application version' }
    $pepeBuildNumber = [int]((($pepeVersionLine -replace '^version:\s*', '') -split '\+')[1].Trim())
    $pepeExpectedCode = if ($Architecture -eq 'arm64') { 2000 + $pepeBuildNumber } else { $pepeBuildNumber }
    $pepeDist = Join-Path $pepeRoot 'dist'
    New-Item -ItemType Directory -Path $pepeDist -Force | Out-Null
    $pepeApk = Join-Path $pepeDist "PepeHub-$pepeVersion-android-$Architecture-test.apk"
    $pepeSource = if ($Architecture -eq 'arm64') { 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk' } else { 'build\app\outputs\flutter-apk\app-release.apk' }
    $pepeSignature = (& (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\apksigner.bat') verify --print-certs $pepeSource) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed' }
    # Existing installations use the project-local test key, not the user's global debug key.
    if ($pepeSignature -notmatch 'certificate SHA-256 digest: efeaed93980f9275749f27ec3b663b2f477984375ad3014e44d07c7a0048a620') {
        throw 'APK signer differs from the previously distributed PepeHub builds'
    }
    $pepeBadging = (& (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\aapt.exe') dump badging $pepeSource) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'APK manifest inspection failed' }
    if ($pepeBadging -notmatch "versionName='$([regex]::Escape($pepeVersion))'" -or $pepeBadging -notmatch "versionCode='$pepeExpectedCode'") {
        throw 'APK contains an unexpected version; refusing to package a stale or downgraded build'
    }
    if ($Architecture -eq 'arm64' -and $pepeBadging -notmatch "(?m)^native-code: 'arm64-v8a'\s*$") {
        throw 'Unexpected APK architecture'
    }
    & (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\zipalign.exe') -c -P 16 4 $pepeSource
    if ($LASTEXITCODE -ne 0) { throw 'APK alignment verification failed' }
    # Media controls are referenced by Dart strings: the shrinker must retain them.
    $pepeResources = (& (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\aapt.exe') dump resources $pepeSource) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'APK resource inspection failed' }
    foreach ($pepeIcon in @('ic_audio_notification', 'audio_service_play_arrow', 'audio_service_pause', 'audio_service_stop', 'audio_service_fast_rewind', 'audio_service_fast_forward')) {
        if ($pepeResources -notmatch "drawable/$pepeIcon(?:[:\s])") { throw "Media notification resource missing from release APK: $pepeIcon" }
    }
    Copy-Item -LiteralPath $pepeSource -Destination $pepeApk -Force
    (Get-FileHash -LiteralPath $pepeApk -Algorithm SHA256).Hash.ToLowerInvariant() | Set-Content -LiteralPath "$pepeApk.sha256"
    Write-Output "APK: $pepeApk"
} finally { Pop-Location }
