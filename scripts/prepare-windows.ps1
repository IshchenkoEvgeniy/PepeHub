$ErrorActionPreference = 'Stop'
$repoPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$appPath = Join-Path $repoPath 'apps\pepehub'
$pluginInfo = Get-Content -LiteralPath (Join-Path $appPath '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
$linksPath = Join-Path $appPath 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Path $linksPath -Force | Out-Null
foreach ($pluginEntry in $pluginInfo.plugins.windows) {
    $linkPath = [IO.Path]::GetFullPath((Join-Path $linksPath $pluginEntry.name))
    $targetPath = [IO.Path]::GetFullPath($pluginEntry.path)
    if (-not $linkPath.StartsWith($linksPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid plugin name' }
    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) { throw 'Missing plugin package' }
    $existingLink = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
    if ($existingLink) {
        if (-not ($existingLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $existingLink.Target) {
            throw "Expected a generated plugin junction: $linkPath"
        }
        $existingTarget = [IO.Path]::GetFullPath([string](@($existingLink.Target)[0])).TrimEnd([char]92)
        if ($existingTarget -ne $targetPath.TrimEnd([char]92)) {
            # Remove only the junction itself, never its package directory.
            [IO.Directory]::Delete($linkPath)
            $existingLink = $null
        }
    }
    if (-not $existingLink) {
        # Junctions do not require enabling Windows Developer Mode. Only generated build links are created.
        New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
    }
}
# Audio and video media_kit packages use the same extracted directory/archive
# names. Their CMake scripts do not re-extract an already populated directory
# after changing package variants, so an old audio-only DLL can survive.
$pepeVariant = if ($pluginInfo.plugins.windows.name -contains 'media_kit_libs_windows_video') { 'video' } elseif ($pluginInfo.plugins.windows.name -contains 'media_kit_libs_windows_audio') { 'audio' } else { $null }
if ($pepeVariant) {
    $pepeBuildRoot = [IO.Path]::GetFullPath((Join-Path $appPath 'build\windows\x64'))
    $pepeNativeCache = [IO.Path]::GetFullPath((Join-Path $pepeBuildRoot 'libmpv'))
    $pepeVariantFile = Join-Path $pepeBuildRoot 'pepehub-libmpv-variant.txt'
    $pepePreviousVariant = if (Test-Path -LiteralPath $pepeVariantFile) { (Get-Content -LiteralPath $pepeVariantFile -Raw).Trim() } else { '' }
    if ($pepePreviousVariant -ne $pepeVariant) {
        if (-not $pepeNativeCache.StartsWith($pepeBuildRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid native build cache path' }
        if (Test-Path -LiteralPath $pepeNativeCache) {
            Remove-Item -LiteralPath $pepeNativeCache -Recurse -Force
        }
        New-Item -ItemType Directory -Path $pepeBuildRoot -Force | Out-Null
        Set-Content -LiteralPath $pepeVariantFile -Value $pepeVariant -Encoding ascii
        Write-Output "Reset generated media_kit cache for $pepeVariant playback."
    }
}
Write-Output 'Prepared generated Windows plugin links. Run flutter pub get again to finish native plugin registration, then build with --no-pub.'
