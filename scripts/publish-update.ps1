param([switch]$Publish, [string]$NotesFile)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'prepare-update.ps1') -NotesFile $NotesFile
$pepeArguments = @((Join-Path $PSScriptRoot 'publish-update.ts'))
if ($Publish) { $pepeArguments += '--publish' }
& node @pepeArguments
if ($LASTEXITCODE -ne 0) { throw 'Update publishing failed. The previous public release remains available.' }
