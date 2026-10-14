param(
    [Parameter(Mandatory = $true)][ValidateSet('Windows', 'Android')][string]$Target,
    [string]$LogPath,
    [switch]$NoOpen,
    [switch]$CheckOnly
)

# Shared by the double-click launchers; compatible with Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$pepeBuildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pepeBuildApp = Join-Path $pepeBuildRoot 'apps\pepehub'
$pepeBuildFlutter = Join-Path $pepeBuildRoot '.tools\flutter\bin\flutter.bat'
$pepeBuildPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pepeBuildExe = Join-Path $pepeBuildApp 'build\windows\x64\runner\Release\pepehub.exe'
if (-not $LogPath) { $LogPath = Join-Path $pepeBuildRoot ".local\build-$($Target.ToLowerInvariant()).log" }
$LogPath = [IO.Path]::GetFullPath($LogPath)
$script:pepeBuildLogReady = $false
$script:pepeBuildStep = 'Startup'
$pepeBuildExit = 0
$pepeBuildMutex = $null
$pepeBuildOwnsMutex = $false
$pepeBuildPushed = $false

function Write-PepeBuildLine([string]$Message, [ConsoleColor]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
    if ($script:pepeBuildLogReady) {
        [IO.File]::AppendAllText($LogPath, $Message + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
}

function Invoke-PepeBuildCommand {
    param([string]$Step, [string]$FilePath, [string[]]$Arguments, [switch]$AllowFailure)
    $script:pepeBuildStep = $Step
    Write-PepeBuildLine "`n== $Step ==" Cyan
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Required command is missing: $FilePath" }
    $pepeCommandOutput = [Text.StringBuilder]::new()
    $pepePreviousErrorAction = $ErrorActionPreference
    try {
        # PS 5.1 turns some native stderr warnings into terminating errors.
        # Use the process exit code while preserving stdout and stderr in the log.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $pepeCommandLine = $_.ToString()
            [void]$pepeCommandOutput.AppendLine($pepeCommandLine)
            Write-PepeBuildLine $pepeCommandLine
        }
        $pepeCommandExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $pepePreviousErrorAction }
    if ($pepeCommandExit -ne 0 -and -not $AllowFailure) { throw "$Step failed (exit code $pepeCommandExit)." }
    if ($AllowFailure) {
        return [pscustomobject]@{ ExitCode = $pepeCommandExit; Output = $pepeCommandOutput.ToString() }
    }
}

function Initialize-PepeBuildPackages {
    $pepePub = Invoke-PepeBuildCommand 'Update Flutter dependencies' $pepeBuildFlutter @('pub', 'get') -AllowFailure
    $pepePrepared = $false
    if ($pepePub.ExitCode -ne 0) {
        if ($pepePub.Output -notmatch 'Building with plugins requires symlink support|ERROR_PRIVILEGE_NOT_HELD' -or
            -not (Test-Path -LiteralPath (Join-Path $pepeBuildApp '.flutter-plugins-dependencies'))) {
            throw "Update Flutter dependencies failed (exit code $($pepePub.ExitCode))."
        }
        # Flutter writes package metadata before creating desktop links. Junctions
        # allow the project helper to finish that step without elevation.
        Write-PepeBuildLine 'Preparing junctions, then retrying dependency registration.' Yellow
        Invoke-PepeBuildCommand 'Prepare Windows plugins and video decoder' $pepeBuildPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'prepare-windows.ps1'))
        $pepePrepared = $true
        Invoke-PepeBuildCommand 'Finish Flutter dependency registration' $pepeBuildFlutter @('pub', 'get')
    }
    if ($Target -eq 'Windows' -and -not $pepePrepared) {
        Invoke-PepeBuildCommand 'Prepare Windows plugins and video decoder' $pepeBuildPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'prepare-windows.ps1'))
        Invoke-PepeBuildCommand 'Refresh Windows plugin registration' $pepeBuildFlutter @('pub', 'get')
    }
}

try {
    # Both targets share generated Flutter files; avoid overlapping launcher runs.
    $pepeHash = [Security.Cryptography.SHA256]::Create()
    try {
        $pepeLockId = ([BitConverter]::ToString($pepeHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($pepeBuildRoot.ToLowerInvariant())))).Replace('-', '').Substring(0, 16)
    } finally { $pepeHash.Dispose() }
    $pepeBuildMutex = [Threading.Mutex]::new($false, "Local\PepeHubBuild-$pepeLockId")
    try { $pepeBuildOwnsMutex = $pepeBuildMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $pepeBuildOwnsMutex = $true }
    if (-not $pepeBuildOwnsMutex) { throw 'Another PepeHub build is running. Wait for it to finish, then run this launcher again.' }

    $pepeLogDirectory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $pepeLogDirectory)) { New-Item -ItemType Directory -Path $pepeLogDirectory -Force | Out-Null }
    if (Test-Path -LiteralPath $LogPath) { Copy-Item -LiteralPath $LogPath -Destination "$LogPath.previous" -Force }
    [IO.File]::WriteAllText($LogPath, '', [Text.UTF8Encoding]::new($false))
    $script:pepeBuildLogReady = $true
    Write-PepeBuildLine "PepeHub $Target build - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" Cyan
    Write-PepeBuildLine "Log: $LogPath"
    $script:pepeBuildStep = 'Check local tools and assets'
    if (-not (Test-Path -LiteralPath $pepeBuildFlutter -PathType Leaf)) { throw "Local Flutter SDK is missing: $pepeBuildFlutter" }
    $pepeBuildPubspec = Get-Content -LiteralPath (Join-Path $pepeBuildApp 'pubspec.yaml') -Raw
    $pepeVersionMatch = [regex]::Match($pepeBuildPubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (-not $pepeVersionMatch.Success) { throw 'Expected version: major.minor.patch+build in pubspec.yaml.' }
    $pepeBuildVersion = $pepeVersionMatch.Groups[1].Value
    $pepeBuildNumber = $pepeVersionMatch.Groups[2].Value
    Write-PepeBuildLine "Version: $pepeBuildVersion+$pepeBuildNumber"
    foreach ($pepeAssetMatch in [regex]::Matches($pepeBuildPubspec, '(?m)^\s*-\s*(?:asset:\s*)?(assets/[^\r\n#]+)')) {
        $pepeAsset = $pepeAssetMatch.Groups[1].Value.Trim()
        $pepeAssetPath = Join-Path $pepeBuildApp $pepeAsset
        if (-not (Test-Path -LiteralPath $pepeAssetPath -PathType Leaf) -or (Get-Item -LiteralPath $pepeAssetPath).Length -eq 0) {
            throw "Required asset is missing or empty: $pepeAsset. Restore the project asset before building."
        }
    }
    Write-PepeBuildLine 'Required project fonts and assets are present.'
    $env:PUB_CACHE = Join-Path $pepeBuildRoot '.tools\pub-cache'
    $env:CI = 'true'
    if ($Target -eq 'Android') {
        . (Join-Path $PSScriptRoot 'android-env.ps1')
        foreach ($pepeAndroidTool in @('build-tools\36.0.0\apksigner.bat', 'build-tools\36.0.0\aapt.exe', 'build-tools\36.0.0\zipalign.exe', 'platforms\android-36\android.jar')) {
            if (-not (Test-Path -LiteralPath (Join-Path $env:ANDROID_HOME $pepeAndroidTool) -PathType Leaf)) { throw "Required Android tool is missing: $pepeAndroidTool" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $pepeBuildRoot '.tools\android-user\debug.keystore') -PathType Leaf)) {
            throw 'The project Android signing key is missing. Restore the existing key to keep updates compatible.'
        }
    }
    if ($Target -eq 'Windows' -and -not $CheckOnly) {
        $pepeRunningApp = Get-Process -Name pepehub -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $pepeBuildExe }
        if ($pepeRunningApp) { throw 'Close the running PepeHub application, then run the Windows launcher again.' }
    }
    if ($CheckOnly) {
        Write-PepeBuildLine "`nCHECK PASSED: local tools and assets are present. No build was started." Green
    } else {
        Push-Location -LiteralPath $pepeBuildApp
        $pepeBuildPushed = $true
        Initialize-PepeBuildPackages
        Invoke-PepeBuildCommand 'Analyze application' $pepeBuildFlutter @('analyze', '--no-pub')
        Invoke-PepeBuildCommand 'Run application tests' $pepeBuildFlutter @('test', '--no-pub')
        if ($Target -eq 'Windows') {
            Invoke-PepeBuildCommand 'Build Windows release' $pepeBuildFlutter @('build', 'windows', '--release', '--no-pub')
            $script:pepeBuildStep = 'Verify Windows result'
            if (-not (Test-Path -LiteralPath $pepeBuildExe -PathType Leaf)) { throw 'Windows build finished without pepehub.exe.' }
            $pepeExeVersion = (Get-Item -LiteralPath $pepeBuildExe).VersionInfo.FileVersion
            if ($pepeExeVersion -ne "$pepeBuildVersion+$pepeBuildNumber") { throw "Unexpected EXE version: $pepeExeVersion" }
            Write-PepeBuildLine "`nSUCCESS: Windows build and checks passed." Green
            Write-PepeBuildLine "EXE: $pepeBuildExe"
            if (-not $NoOpen) {
                try { Start-Process -FilePath $pepeBuildExe -WorkingDirectory (Split-Path -Parent $pepeBuildExe) -WindowStyle Normal | Out-Null }
                catch { Write-PepeBuildLine "Build is ready; could not open the application: $($_.Exception.Message)" Yellow }
            }
        } else {
            # Preserve the Android builder's dependency refresh and APK checks.
            Invoke-PepeBuildCommand 'Build and verify Android ARM64 APK' $pepeBuildPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'build-android.ps1'), '-Architecture', 'arm64')
            $script:pepeBuildStep = 'Verify Android result'
            $pepeBuildApk = Join-Path $pepeBuildRoot "dist\PepeHub-$pepeBuildVersion-android-arm64-test.apk"
            if (-not (Test-Path -LiteralPath $pepeBuildApk -PathType Leaf) -or (Get-Item -LiteralPath $pepeBuildApk).Length -eq 0) { throw 'Android builder finished without a packaged APK.' }
            Write-PepeBuildLine "`nSUCCESS: Android build and checks passed." Green
            Write-PepeBuildLine "APK: $pepeBuildApk"
            if (-not $NoOpen) {
                try { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "/select,`"$pepeBuildApk`"" | Out-Null }
                catch { Write-PepeBuildLine "APK is ready; could not open Explorer: $($_.Exception.Message)" Yellow }
            }
        }
    }
} catch {
    $pepeBuildExit = 1
    Write-PepeBuildLine "`nFAILED at '$script:pepeBuildStep': $($_.Exception.Message)" Red
} finally {
    if ($pepeBuildPushed) { Pop-Location }
    if ($pepeBuildOwnsMutex) { $pepeBuildMutex.ReleaseMutex() }
    if ($pepeBuildMutex) { $pepeBuildMutex.Dispose() }
    Write-PepeBuildLine "`nFinished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'). Log: $LogPath"
}
exit $pepeBuildExit
