param([Parameter(Mandatory=$true)][string]$ConfigPath, [switch]$NoLaunch, [switch]$Rollback)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$pepeTxn = $null
$pepeTouched = [Collections.Generic.List[string]]::new()
$pepeBefore = @{}
$pepeParentClosed = $false

function Get-PepeHash([string]$Path) {
    $pepeHasher = [Security.Cryptography.SHA256]::Create()
    $pepeInput = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($pepeHasher.ComputeHash($pepeInput))).Replace('-', '').ToLowerInvariant() }
    finally { $pepeInput.Dispose(); $pepeHasher.Dispose() }
}

function Assert-PepeNoLinks([string]$Value) {
    $pepeCursor = [IO.Path]::GetFullPath($Value)
    while ($pepeCursor) {
        if (Test-Path -LiteralPath $pepeCursor) {
            if (((Get-Item -LiteralPath $pepeCursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Links and junctions are not supported in update paths.' }
        }
        $pepeNext = [IO.Path]::GetDirectoryName($pepeCursor.TrimEnd('\'))
        if ($pepeNext -eq $pepeCursor) { break }
        $pepeCursor = $pepeNext
    }
}
function Assert-PepeRelative([string]$Value) {
    if (-not $Value -or $Value.Length -gt 200 -or $Value.Contains('\') -or $Value.Contains(':') -or $Value -match '[\x00-\x1f<>"|?*]') { throw 'Invalid package path.' }
    foreach ($pepePart in $Value.Split('/')) {
        if (-not $pepePart -or $pepePart -eq '.' -or $pepePart -eq '..' -or $pepePart -match '[. ]$' -or $pepePart -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)') { throw 'Invalid package component.' }
    }
    if ($Value -ne 'pepehub.exe' -and $Value -notmatch '^[^/]+\.dll$' -and $Value -notmatch '^data/.+') { throw 'Unexpected package file.' }
}
function Get-PepePath([string]$Root, [string]$Relative) {
    Assert-PepeRelative $Relative
    $pepeResult = [IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/', '\')))
    if (-not $pepeResult.StartsWith($Root.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Package path escaped its root.' }
    Assert-PepeNoLinks $pepeResult
    return $pepeResult
}
function Write-PepeStatus([string]$State) {
    [IO.File]::WriteAllText((Join-Path $pepeTxn 'status.json'), (@{state=$State;time=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress))
}
function Restore-PepeFiles {
    $pepeErrors = [Collections.Generic.List[string]]::new()
    for ($pepeIndex = $pepeTouched.Count - 1; $pepeIndex -ge 0; $pepeIndex--) {
        $pepeRelative = $pepeTouched[$pepeIndex]
        if (-not $pepeRelative) { continue }
        try {
            $pepeDestination = if ($pepeRelative -eq '.pepehub-update-receipt.json') { Join-Path $pepeInstall $pepeRelative } else { Get-PepePath $pepeInstall $pepeRelative }
            $pepeOriginal = Join-Path $pepeBackup $pepeRelative.Replace('/', '\')
            Assert-PepeNoLinks $pepeDestination
            if ($pepeBefore[$pepeRelative]) {
                if ([IO.File]::Exists($pepeDestination) -and (Get-PepeHash $pepeDestination) -eq (Get-PepeHash $pepeOriginal)) { continue }
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pepeDestination)) | Out-Null
                [IO.File]::Copy($pepeOriginal, $pepeDestination, $true)
            } elseif ([IO.File]::Exists($pepeDestination)) { [IO.File]::Delete($pepeDestination) }
        } catch { $pepeErrors.Add($pepeRelative) }
    }
    if ($pepeErrors.Count -gt 0) { throw "Recovery needs attention: $($pepeErrors -join ', '). Backup is preserved." }
}

try {
    $pepeConfigFile = [IO.Path]::GetFullPath($ConfigPath)
    $pepeConfig = [IO.File]::ReadAllText($pepeConfigFile) | ConvertFrom-Json
    $pepeTxn = [IO.Path]::GetFullPath($pepeConfig.transactionDir).TrimEnd('\')
    $pepeInstall = [IO.Path]::GetFullPath($pepeConfig.installDir).TrimEnd('\')
    $pepeStage = [IO.Path]::GetFullPath($pepeConfig.stageDir).TrimEnd('\')
    $pepeBackup = Join-Path $pepeTxn 'backup'
    if ($pepeConfigFile -ne (Join-Path $pepeTxn 'transaction.json') -or $pepeStage -ne (Join-Path $pepeTxn 'stage') -or
        $pepeInstall -eq [IO.Path]::GetPathRoot($pepeInstall).TrimEnd('\') -or
        $pepeTxn.StartsWith($pepeInstall+'\', [StringComparison]::OrdinalIgnoreCase) -or
        $pepeInstall.StartsWith($pepeTxn+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid update directories.' }
    Assert-PepeNoLinks $pepeTxn
    Assert-PepeNoLinks $pepeStage
    Assert-PepeNoLinks $pepeInstall
    $pepeExe = Join-Path $pepeInstall 'pepehub.exe'
    if (-not [IO.File]::Exists($pepeExe)) { throw 'Installed PepeHub executable is missing.' }
    $pepeFiles = @($pepeConfig.files)
    if ($pepeFiles.Count -lt 3 -or $pepeFiles.Count -gt 10000) { throw 'Invalid package file count.' }
    $pepeNames = @{}
    foreach ($pepeFile in $pepeFiles) {
        Assert-PepeRelative $pepeFile.path
        if ($pepeNames.ContainsKey($pepeFile.path.ToLowerInvariant())) { throw 'Duplicate package file.' }
        $pepeNames[$pepeFile.path.ToLowerInvariant()] = $true
        if ($pepeFile.sha256 -notmatch '^[a-f0-9]{64}$' -or $pepeFile.bytes -lt 0 -or $pepeFile.bytes -gt 536870912) { throw 'Invalid package hash/size.' }
    }
    if (-not $pepeNames.ContainsKey('pepehub.exe') -or -not $pepeNames.ContainsKey('flutter_windows.dll')) { throw 'Incomplete application package.' }
    $pepeOther = @(Get-Process -Name pepehub -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $pepeExe -and $_.Id -ne [int]$pepeConfig.parentPid })
    if ($pepeOther.Count -gt 0) { throw 'Close all other PepeHub windows before updating.' }
    if ($Rollback) {
        if (Get-Process -Name pepehub -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $pepeExe }) { throw 'Close PepeHub before restoring its files.' }
        $pepeSaved = [IO.File]::ReadAllText((Join-Path $pepeTxn 'before.json')) | ConvertFrom-Json
        foreach ($pepeProperty in $pepeSaved.PSObject.Properties) {
            if ($pepeProperty.Name -ne '.pepehub-update-receipt.json') { Assert-PepeRelative $pepeProperty.Name }
            $pepeBefore[$pepeProperty.Name] = [bool]$pepeProperty.Value
            $pepeTouched.Add($pepeProperty.Name)
        }
        Restore-PepeFiles
        Write-PepeStatus 'restored'
    } else {
        foreach ($pepeFile in $pepeFiles) {
            $pepeSource = Get-PepePath $pepeStage $pepeFile.path
            $null = Get-PepePath $pepeInstall $pepeFile.path
            if (-not [IO.File]::Exists($pepeSource) -or (Get-Item -LiteralPath $pepeSource).Length -ne $pepeFile.bytes -or
                (Get-PepeHash $pepeSource) -ne $pepeFile.sha256) { throw 'Staged update verification failed.' }
        }
        if ((Get-Item -LiteralPath (Join-Path $pepeStage 'pepehub.exe')).VersionInfo.ProductVersion -ne $pepeConfig.expectedVersion) { throw 'Staged executable version mismatch.' }
        $pepeProbe = Join-Path $pepeInstall ('.pepehub-write-test-'+[Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($pepeProbe, 'update')
        [IO.File]::Delete($pepeProbe)
        $pepeParent = if ([int]$pepeConfig.parentPid -gt 0) { Get-Process -Id ([int]$pepeConfig.parentPid) -ErrorAction SilentlyContinue } else { $null }
        if ($pepeParent -and $pepeParent.Path -ne $pepeExe) { throw 'The update parent is not this application.' }
        if ([int]$pepeConfig.parentPid -le 0 -and -not $NoLaunch) { throw 'Missing update parent.' }
        [IO.File]::WriteAllText((Join-Path $pepeTxn 'ready'), 'ready')
        Write-PepeStatus 'waiting'
        $pepeWait = [Diagnostics.Stopwatch]::StartNew()
        while ($pepeParent -and -not $pepeParent.WaitForExit(100)) {
            if ([IO.File]::Exists((Join-Path $pepeTxn 'cancel'))) { throw 'Update cancelled by the application.' }
            if ($pepeWait.Elapsed.TotalSeconds -ge 90) { throw 'Application did not close; update was cancelled.' }
        }
        if ([IO.File]::Exists((Join-Path $pepeTxn 'cancel'))) { throw 'Update cancelled by the application.' }
        if (Get-Process -Name pepehub -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $pepeExe }) { throw 'Another application instance is still running.' }
        $pepeParentClosed = $true
        [IO.Directory]::CreateDirectory($pepeBackup) | Out-Null
        $pepeReceipt = Join-Path $pepeInstall '.pepehub-update-receipt.json'
        Assert-PepeNoLinks $pepeReceipt
        $pepeManaged = [Collections.Generic.List[string]]::new()
        foreach ($pepeFile in $pepeFiles) { $pepeManaged.Add($pepeFile.path) }
        if ([IO.File]::Exists($pepeReceipt)) {
            $pepePrevious = [IO.File]::ReadAllText($pepeReceipt) | ConvertFrom-Json
            foreach ($pepeOld in @($pepePrevious.files)) {
                Assert-PepeRelative $pepeOld
                if (-not $pepeManaged.Contains($pepeOld)) { $pepeManaged.Add($pepeOld) }
            }
        }
        $pepeManaged.Add('.pepehub-update-receipt.json')
        foreach ($pepeRelative in $pepeManaged) {
            $pepeOriginal = if ($pepeRelative -eq '.pepehub-update-receipt.json') { $pepeReceipt } else { Get-PepePath $pepeInstall $pepeRelative }
            $pepeBefore[$pepeRelative] = [IO.File]::Exists($pepeOriginal)
            if ($pepeBefore[$pepeRelative]) {
                $pepeCopy = Join-Path $pepeBackup $pepeRelative.Replace('/', '\')
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pepeCopy)) | Out-Null
                [IO.File]::Copy($pepeOriginal, $pepeCopy, $false)
            }
        }
        [IO.File]::WriteAllText((Join-Path $pepeTxn 'before.json'), ($pepeBefore | ConvertTo-Json -Compress))
        Write-PepeStatus 'applying'
        foreach ($pepeFile in $pepeFiles) {
            $pepeDestination = Get-PepePath $pepeInstall $pepeFile.path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pepeDestination)) | Out-Null
            $pepeTouched.Add($pepeFile.path)
            [IO.File]::Copy((Get-PepePath $pepeStage $pepeFile.path), $pepeDestination, $true)
        }
        foreach ($pepeRelative in $pepeManaged) {
            if ($pepeRelative -eq '.pepehub-update-receipt.json' -or $pepeNames.ContainsKey($pepeRelative.ToLowerInvariant())) { continue }
            $pepeTouched.Add($pepeRelative)
            [IO.File]::Delete((Get-PepePath $pepeInstall $pepeRelative))
        }
        $pepeTouched.Add('.pepehub-update-receipt.json')
        [IO.File]::WriteAllText($pepeReceipt, (@{version=$pepeConfig.expectedVersion;files=@($pepeFiles | ForEach-Object { $_.path })} | ConvertTo-Json -Compress))
        Write-PepeStatus 'complete'
    }
    if (-not $NoLaunch) { Start-Process -FilePath $pepeExe -WorkingDirectory $pepeInstall -WindowStyle Normal | Out-Null }
    exit 0
} catch {
    $pepeFailure = $_.Exception.Message
    $pepeRestored = $true
    if ($pepeTouched.Count -gt 0) {
        try { Restore-PepeFiles; Write-PepeStatus 'rolledBack' }
        catch { $pepeRestored = $false; $pepeFailure += [Environment]::NewLine + $_.Exception.Message }
    }
    if ($pepeTxn -and [IO.Directory]::Exists($pepeTxn)) { [IO.File]::WriteAllText((Join-Path $pepeTxn 'failure.txt'), $pepeFailure) }
    if ($pepeParentClosed -and $pepeRestored -and -not $NoLaunch -and [IO.File]::Exists($pepeExe)) {
        try { Start-Process -FilePath $pepeExe -WorkingDirectory $pepeInstall -WindowStyle Normal | Out-Null } catch {}
    }
    Write-Error $pepeFailure -ErrorAction Continue
    exit 1
}
