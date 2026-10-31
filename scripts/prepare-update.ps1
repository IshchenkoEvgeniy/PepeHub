param([string]$NotesFile)
$ErrorActionPreference = 'Stop'
$pepeUpdateRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pepeApp = Join-Path $pepeUpdateRoot 'apps\pepehub'
$pepeVersionText = [IO.File]::ReadAllText((Join-Path $pepeApp 'pubspec.yaml'))
$pepeVersionMatch = [regex]::Match($pepeVersionText, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $pepeVersionMatch.Success) { throw 'Invalid pubspec version.' }
$pepeVersion = $pepeVersionMatch.Groups[1].Value
$pepeBuild = [int]$pepeVersionMatch.Groups[2].Value
$pepeBundle = Join-Path $pepeApp 'build\windows\x64\runner\Release'
$pepeExe = Join-Path $pepeBundle 'pepehub.exe'
if (-not [IO.File]::Exists($pepeExe) -or (Get-Item -LiteralPath $pepeExe).VersionInfo.ProductVersion -ne "$pepeVersion+$pepeBuild") { throw 'Build the current Windows release before packaging an update.' }
$pepeApk = Join-Path $pepeUpdateRoot "dist\PepeHub-$pepeVersion-android-arm64-test.apk"
if (-not [IO.File]::Exists($pepeApk)) { throw 'Build the current Android ARM64 release before packaging an update.' }
. (Join-Path $PSScriptRoot 'android-env.ps1')
$pepeBadging = (& (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\aapt.exe') dump badging $pepeApk) -join "`n"
if ($LASTEXITCODE -ne 0 -or $pepeBadging -notmatch "(?m)^package: name='app\.pepehub\.pepehub'" -or $pepeBadging -notmatch "versionName='$([regex]::Escape($pepeVersion))'" -or $pepeBadging -notmatch "versionCode='$($pepeBuild+2000)'" -or $pepeBadging -notmatch "(?m)^native-code: 'arm64-v8a'\s*$") { throw 'Android package identity/version/architecture does not match pubspec.' }
$pepeSigner = (& (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\apksigner.bat') verify --print-certs $pepeApk) -join "`n"
if ($LASTEXITCODE -ne 0 -or $pepeSigner -notmatch 'certificate SHA-256 digest: efeaed93980f9275749f27ec3b663b2f477984375ad3014e44d07c7a0048a620') { throw 'Android signing key changed; refusing to publish incompatible updates.' }
$pepeOutput = Join-Path $pepeUpdateRoot "dist\online\$pepeVersion-$pepeBuild"
[IO.Directory]::CreateDirectory($pepeOutput) | Out-Null
$pepeZip = Join-Path $pepeOutput 'PepeHub-windows-x64.zip'
if ([IO.File]::Exists($pepeZip)) { [IO.File]::Delete($pepeZip) }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$pepeStream = [IO.File]::Open($pepeZip, [IO.FileMode]::CreateNew)
$pepeArchive = [IO.Compression.ZipArchive]::new($pepeStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    $pepeSources = @(Get-ChildItem -LiteralPath $pepeBundle -File | Where-Object { $_.Name -eq 'pepehub.exe' -or $_.Extension -eq '.dll' })
    $pepeSources += @(Get-ChildItem -LiteralPath (Join-Path $pepeBundle 'data') -File -Recurse -Force)
    if ($pepeSources.Count -gt 10000) { throw 'Unexpected Windows bundle size.' }
    foreach ($pepeSource in $pepeSources) {
        $pepeCursor = $pepeSource
        while ($pepeCursor -and $pepeCursor.FullName.Length -ge $pepeBundle.Length) {
            if (($pepeCursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A Windows bundle contains a link/junction.' }
            $pepeCursor = if ($pepeCursor -is [IO.FileInfo]) { $pepeCursor.Directory } else { $pepeCursor.Parent }
        }
        if (-not $pepeSource.FullName.StartsWith($pepeBundle+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Bundle escaped its root.' }
        $pepeRelative = $pepeSource.FullName.Substring($pepeBundle.Length+1).Replace('\','/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($pepeArchive, $pepeSource.FullName, $pepeRelative, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $pepeArchive.Dispose(); $pepeStream.Dispose() }
$pepePackagedApk = Join-Path $pepeOutput 'PepeHub-android-arm64.apk'
[IO.File]::Copy($pepeApk, $pepePackagedApk, $true)
$pepeArtifacts = @{
    version=$pepeVersion;build=$pepeBuild;
    artifacts=@{
        'windows-x64'=@{file='PepeHub-windows-x64.zip';sha256=(Get-FileHash -LiteralPath $pepeZip).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $pepeZip).Length;versionCode=$pepeBuild;format='zip'}
        'android-arm64'=@{file='PepeHub-android-arm64.apk';sha256=(Get-FileHash -LiteralPath $pepePackagedApk).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $pepePackagedApk).Length;versionCode=$pepeBuild+2000;format='apk'}
    }
}
[IO.File]::WriteAllText((Join-Path $pepeOutput 'artifacts.json'), ($pepeArtifacts | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
& node (Join-Path $PSScriptRoot 'prepare-update-deltas.ts') $pepeOutput
if ($LASTEXITCODE -ne 0) { throw 'Delta package generation/verification failed.' }
if ($NotesFile) { [IO.File]::Copy([IO.Path]::GetFullPath($NotesFile), (Join-Path $pepeOutput 'notes.md'), $true) }
Write-Output "Verified update packages: $pepeOutput"
