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
    if (-not (Test-Path -LiteralPath $linkPath)) {
        # Junctions do not require enabling Windows Developer Mode. Only generated build links are created.
        New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
    }
}
Write-Output 'Prepared generated Windows plugin links. Run flutter pub get again to finish native plugin registration, then build with --no-pub.'
