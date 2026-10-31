#requires -Version 5.1
<#
.SYNOPSIS
Preview or remove generated build caches and old local release packages.
.EXAMPLE
.\scripts\clean-project.ps1
.EXAMPLE
.\scripts\clean-project.ps1 -Apply -WhatIf
.EXAMPLE
.\scripts\clean-project.ps1 -Apply
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$Apply, [ValidateRange(3, 10)][int]$KeepReleases = 3)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$cleanupRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$cleanupPrefix = $cleanupRoot + '\'
if (-not (Test-Path -LiteralPath (Join-Path $cleanupRoot 'apps\pepehub\pubspec.yaml') -PathType Leaf)) {
    throw 'Run this script from the scripts directory of the PepeHub checkout.'
}

# Preserve the newest known releases, even if pubspec has already been bumped.
$cleanupVersionText = [IO.File]::ReadAllText((Join-Path $cleanupRoot 'apps\pepehub\pubspec.yaml'))
$cleanupVersion = [regex]::Match($cleanupVersionText, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $cleanupVersion.Success) { throw 'Cannot determine the application version.' }
$cleanupCurrentVersion = $cleanupVersion.Groups[1].Value
$cleanupCurrentBuild = [int]$cleanupVersion.Groups[2].Value
$cleanupReleases = @(
    $online = Join-Path $cleanupRoot 'dist\online'
    if (Test-Path -LiteralPath $online -PathType Container) {
        foreach ($entry in Get-ChildItem -LiteralPath $online -Directory -Force) {
            if ($entry.Name -notmatch '^(?<Version>\d+\.\d+\.\d+)-(?<Build>\d+)$') { continue }
            $version = $Matches['Version']; $buildNumber = [int]$Matches['Build']
            if ($buildNumber -gt $cleanupCurrentBuild -or [version]$version -gt [version]$cleanupCurrentVersion) { continue }
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $catalogPath = Join-Path $entry.FullName 'artifacts.json'
            if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) { continue }
            $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
            if ($catalog.version -ne $version -or $catalog.build -ne $buildNumber) { throw "Mismatched release catalog: $($entry.FullName)" }
            [pscustomobject]@{ Path = $entry.FullName; Version = $version; Build = $buildNumber; Catalog = $catalog }
        }
    }
)
$cleanupReleases = @($cleanupReleases | Sort-Object Build -Descending)
$cleanupRetained = @($cleanupReleases | Select-Object -First $KeepReleases)
if ($cleanupRetained.Count -lt $KeepReleases) { throw "Need at least $KeepReleases verified release catalogs before pruning packages." }
$cleanupRetainedPaths = @($cleanupRetained | ForEach-Object Path)
$cleanupNewestVersion = $cleanupRetained[0].Version
$cleanupProtected = @(
    '.git', '.local', '.tools\android-user', '.tools\android-sdk',
    '.tools\flutter', '.tools\jdk', '.tools\pub-cache', '.tools\gradle-cache',
    'apps\pepehub\lib', 'apps\pepehub\test',
    'apps\pepehub\assets', 'apps\pepehub\integration_test', 'node_modules'
) | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $cleanupRoot $_)).TrimEnd('\') }
$cleanupProtected += $cleanupRetainedPaths

function Assert-CleanupTarget([string]$LiteralPath) {
    $full = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
    if (-not $full.StartsWith($cleanupPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Target is outside this checkout: $full"
    }
    foreach ($protected in $cleanupProtected) {
        if ([string]::Equals($full, $protected, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith(($protected + '\'), [StringComparison]::OrdinalIgnoreCase) -or
            $protected.StartsWith(($full + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Target overlaps a protected directory: $full"
        }
    }
    $ancestor = $full
    while ($true) {
        $info = Get-Item -LiteralPath $ancestor -Force
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Target or its parent is a symbolic link or junction: $ancestor"
        }
        if ([string]::Equals($ancestor, $cleanupRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
        $ancestor = [IO.Directory]::GetParent($ancestor).FullName
    }
}

function Get-CleanupHash([string]$LiteralPath) {
    $stream = [IO.File]::OpenRead($LiteralPath)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        [pscustomobject]@{ Path = [IO.Path]::GetFullPath($LiteralPath); Hash = ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    } finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Measure-CleanupTarget([string]$LiteralPath) {
    $bytes = 0L
    $links = 0
    $stack = [Collections.Generic.Stack[IO.FileSystemInfo]]::new()
    $stack.Push((Get-Item -LiteralPath $LiteralPath -Force))
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $links++
        } elseif ($entry -is [IO.DirectoryInfo]) {
            foreach ($child in $entry.GetFileSystemInfos()) { $stack.Push($child) }
        } else {
            $bytes += $entry.Length
        }
    }
    [pscustomobject]@{ Bytes = $bytes; Links = $links }
}

function Remove-CleanupEntry([string]$LiteralPath, [string]$TargetRoot) {
    $full = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
    if (-not [string]::Equals($full, $TargetRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith(($TargetRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Entry escaped its validated target: $full"
    }
    $entry = Get-Item -LiteralPath $full -Force
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        # Delete the link itself, without walking into its destination (also on PS 5.1).
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            [IO.Directory]::Delete($full, $false)
        } else {
            [IO.File]::Delete($full)
        }
    } elseif ($entry -is [IO.DirectoryInfo]) {
        foreach ($child in $entry.GetFileSystemInfos()) {
            Remove-CleanupEntry -LiteralPath $child.FullName -TargetRoot $TargetRoot
        }
        # No recursive delete: only an empty directory can be removed here.
        [IO.Directory]::Delete($full, $false)
    } else {
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
    }
}

$cleanupCandidates = [Collections.Generic.List[string]]::new()
foreach ($relative in @('apps\pepehub\.dart_tool\flutter_build', 'apps\pepehub\.dart_tool\hooks_runner', 'apps\pepehub\build', '.tools\android-downloads', 'build')) {
    $cleanupCandidates.Add((Join-Path $cleanupRoot $relative))
}
$dist = Join-Path $cleanupRoot 'dist'
if (Test-Path -LiteralPath $dist -PathType Container) {
    foreach ($entry in Get-ChildItem -LiteralPath $dist -File -Force) {
        if ($entry.Name -match '^PepeHub-(?<Release>\d+\.\d+\.\d+)-android-(arm64|universal)-test\.apk(\.sha256)?$') {
            $release = $Matches['Release']
            if ($release -ne $cleanupCurrentVersion -and $release -ne $cleanupNewestVersion -and [version]$release -lt [version]$cleanupCurrentVersion) {
                $cleanupCandidates.Add($entry.FullName)
            }
        }
    }
}
foreach ($release in $cleanupReleases) {
    if ($release.Path -notin $cleanupRetainedPaths) { $cleanupCandidates.Add($release.Path) }
}

$cleanupPlan = @(
    foreach ($candidate in $cleanupCandidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        Assert-CleanupTarget $candidate
        $size = Measure-CleanupTarget $candidate
        [pscustomobject]@{
            Path = $candidate
            Relative = $candidate.Substring($cleanupPrefix.Length)
            Bytes = $size.Bytes
            GiB = [math]::Round($size.Bytes / 1GB, 3)
            Links = $size.Links
        }
    }
)
if ($cleanupPlan.Count -eq 0) { Write-Host 'Nothing to clean.'; return }

# Never delete tracked source files, including files added to these paths later.
$cleanupGit = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$cleanupTracked = @(& $cleanupGit --no-optional-locks --literal-pathspecs -C $cleanupRoot ls-files -- @($cleanupPlan.Relative))
if ($LASTEXITCODE -ne 0) { throw 'Cannot verify tracked files; cleanup was cancelled.' }
if ($cleanupTracked.Count -gt 0) { throw "Cleanup targets contain tracked files: $($cleanupTracked -join ', ')" }

Write-Host ('Retained releases: ' + (($cleanupRetained | ForEach-Object { $_.Version + '-' + $_.Build }) -join ', '))
$cleanupPlan | Format-Table Relative, GiB, Links -AutoSize | Out-Host
$cleanupTotal = ($cleanupPlan | Measure-Object Bytes -Sum).Sum
Write-Host ('Selected file sizes: {0:N2} GiB. Link destinations are excluded.' -f ($cleanupTotal / 1GB))
if (-not $Apply) {
    Write-Host 'Preview only. To remove these files, run this script with -Apply.'
    return
}

$cleanupMutex = $null
$cleanupOwnsMutex = $false
$cleanupSnapshot = @()
try {
    # Direct Flutter invocations may not use the launcher mutex.
    $cleanupOriginalWhatIf = $WhatIfPreference
    try {
    $WhatIfPreference = $false
    $cleanupBusy = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(dart|dartvm|dartaotruntime|gen_snapshot|cmake|MSBuild|ninja|pepehub)\.exe$' -and
        $_.CommandLine -and $_.CommandLine.IndexOf($cleanupRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        ($_.Name -match '^(gen_snapshot|cmake|MSBuild|ninja|pepehub)\.exe$' -or
         $_.CommandLine -match 'flutter_tools\.snapshot.*\b(build|run|test|assemble|analyze)\b|tool_backend\.dart|frontend_server')
    })
    } finally { $WhatIfPreference = $cleanupOriginalWhatIf }
    if ($cleanupBusy.Count -gt 0) { throw 'An application or Flutter build is using this checkout. Close it before cleanup.' }
    # Same mutex as run-local-build.ps1: do not clean during a launcher build.
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $lockId = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($cleanupRoot.ToLowerInvariant())))).Replace('-', '').Substring(0, 16)
    } finally { $hash.Dispose() }
    $cleanupMutex = [Threading.Mutex]::new($false, "Local\PepeHubBuild-$lockId")
    try { $cleanupOwnsMutex = $cleanupMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $cleanupOwnsMutex = $true }
    if (-not $cleanupOwnsMutex) { throw 'A PepeHub build is running. Wait for it to finish.' }

    # Require the retained artifacts and signing keys before deleting build outputs.
    $cleanupKeepFiles = @(
        '.tools\android-user\debug.keystore', '.local\update-signing\private.pem',
        'apps\pepehub\.dart_tool\package_config.json'
    )
    foreach ($release in $cleanupRetained) {
        foreach ($platform in @('windows-x64', 'android-arm64')) {
            $artifact = $release.Catalog.artifacts.$platform
            $expectedName = if ($platform -eq 'windows-x64') { 'PepeHub-windows-x64.zip' } else { 'PepeHub-android-arm64.apk' }
            if ($artifact.file -ne $expectedName) { throw 'Unexpected retained package path.' }
            $file = Join-Path $release.Path $expectedName
            $info = Get-Item -LiteralPath $file -Force
            if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $info.Length -ne $artifact.bytes -or
                (Get-CleanupHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $artifact.sha256) {
                throw "Retained package verification failed: $file"
            }
        }
        foreach ($file in Get-ChildItem -LiteralPath $release.Path -File -Force) {
            $cleanupKeepFiles += $file.FullName.Substring($cleanupPrefix.Length)
        }
    }
    $cleanupSnapshot = @($cleanupKeepFiles | ForEach-Object {
        Get-CleanupHash -LiteralPath (Join-Path $cleanupRoot $_)
    })
    $cleanupRemoved = 0L
    foreach ($target in $cleanupPlan) {
        Assert-CleanupTarget $target.Path
        if ($PSCmdlet.ShouldProcess($target.Path, 'Remove audited disposable files')) {
            Remove-CleanupEntry -LiteralPath $target.Path -TargetRoot $target.Path
            $cleanupRemoved += $target.Bytes
            Write-Host ('Removed: ' + $target.Relative)
        }
    }
    Write-Host ('Removed file sizes: {0:N2} GiB.' -f ($cleanupRemoved / 1GB))
} finally {
    try {
        foreach ($saved in $cleanupSnapshot) {
            $current = Get-CleanupHash -LiteralPath $saved.Path
            if ($current.Hash -ne $saved.Hash) { throw "A protected file changed: $($saved.Path)" }
        }
    } finally {
        if ($cleanupOwnsMutex) { $cleanupMutex.ReleaseMutex() }
        if ($null -ne $cleanupMutex) { $cleanupMutex.Dispose() }
    }
}
