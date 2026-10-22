#requires -Version 5.1
<#
.SYNOPSIS
Preview or remove disposable files identified by the October 2026 disk audit.
.EXAMPLE
.\scripts\clean-project.ps1
.EXAMPLE
.\scripts\clean-project.ps1 -Apply -WhatIf
.EXAMPLE
.\scripts\clean-project.ps1 -Apply
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$cleanupRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$cleanupPrefix = $cleanupRoot + '\'
if (-not (Test-Path -LiteralPath (Join-Path $cleanupRoot 'apps\pepehub\pubspec.yaml') -PathType Leaf)) {
    throw 'Run this script from the scripts directory of the PepeHub checkout.'
}

# This is a fixed audit allowlist. Releases created later are left alone.
$cleanupOldVersions = @(
    '0.2.0', '0.5.0', '0.10.0', '0.18.2', '0.19.0', '0.20.0',
    '1.13', '1.13.3', '1.13.4', '1.13.5', '1.13.6', '1.13.11', '1.14.0',
    '0.21.0', '0.21.1', '0.21.2', '0.21.3', '0.21.4', '0.21.5', '0.21.6', '0.21.7'
)
$cleanupProtected = @(
    '.git', '.local', '.tools\android-user', '.tools\android-sdk',
    '.tools\flutter', '.tools\jdk', '.tools\pub-cache', '.tools\gradle-cache',
    'apps\pepehub\lib', 'apps\pepehub\test',
    'dist\online\0.21.8-60', 'dist\online\0.21.9-61'
) | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $cleanupRoot $_)).TrimEnd('\') }

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
foreach ($relative in @('apps\pepehub\.dart_tool', 'apps\pepehub\build', '.tools\android-downloads', 'build')) {
    $cleanupCandidates.Add((Join-Path $cleanupRoot $relative))
}
foreach ($entry in Get-ChildItem -LiteralPath (Join-Path $cleanupRoot 'dist') -Force) {
    if ($entry.Name -match '^PepeHub-(?<Release>[0-9]+\.[0-9]+(?:\.[0-9]+)?)(?:-|\.|$)' -and
        $Matches['Release'] -in $cleanupOldVersions) {
        $cleanupCandidates.Add($entry.FullName)
    }
}
foreach ($entry in Get-ChildItem -LiteralPath (Join-Path $cleanupRoot 'dist\online') -Force) {
    if ($entry.Name -match '^(?<Release>[0-9]+\.[0-9]+\.[0-9]+)-[0-9]+$' -and
        $Matches['Release'] -in $cleanupOldVersions) {
        $cleanupCandidates.Add($entry.FullName)
    }
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
        'dist\online\0.21.8-60\PepeHub-windows-x64.zip',
        'dist\online\0.21.8-60\PepeHub-android-arm64.apk',
        'dist\online\0.21.9-61\PepeHub-windows-x64.zip',
        'dist\online\0.21.9-61\PepeHub-android-arm64.apk'
    )
    $cleanupSnapshot = @($cleanupKeepFiles | ForEach-Object {
        Get-FileHash -LiteralPath (Join-Path $cleanupRoot $_) -Algorithm SHA256 -ErrorAction Stop
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
            $current = Get-FileHash -LiteralPath $saved.Path -Algorithm SHA256 -ErrorAction Stop
            if ($current.Hash -ne $saved.Hash) { throw "A protected file changed: $($saved.Path)" }
        }
    } finally {
        if ($cleanupOwnsMutex) { $cleanupMutex.ReleaseMutex() }
        if ($null -ne $cleanupMutex) { $cleanupMutex.Dispose() }
    }
}
