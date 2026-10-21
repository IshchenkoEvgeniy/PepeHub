param([Parameter(Mandatory=$true)][string]$PluginPath)
$ErrorActionPreference = 'Stop'
$bridgeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\integrations\obsidian\habit-timer'))
$bridgePlugin = [IO.Path]::GetFullPath($PluginPath)
if (-not (Test-Path -LiteralPath (Join-Path $bridgePlugin 'src\library\property-schema.ts'))) { throw 'Expected Habit Timer plugin source checkout' }
$encoding = [Text.UTF8Encoding]::new($false)
function Write-BridgeFile([string]$RelativePath, [string]$Content) {
    [IO.File]::WriteAllText((Join-Path $bridgePlugin $RelativePath), $Content, $encoding)
}
function Add-BridgeHook([string]$Content, [string]$Marker, [string]$Anchor, [string]$Replacement) {
    if ($Content.Contains($Marker)) { return $Content }
    if (-not $Content.Contains($Anchor)) { throw "Missing plugin hook: $Anchor" }
    return $Content.Replace($Anchor, $Replacement)
}
# Prepare hook edits first; preserve all existing changes in the plugin checkout.
$pluginMain = [IO.File]::ReadAllText((Join-Path $bridgePlugin 'src\main.ts'))
$pluginMain = Add-BridgeHook $pluginMain "import { PepeHubLibraryService }" "export default class HabitTimerPlugin" "import { PepeHubLibraryService } from './services/pepehub-library-service';`n`nexport default class HabitTimerPlugin"
$pluginMain = Add-BridgeHook $pluginMain 'pepehubLibrary: PepeHubLibraryService;' '    companion: CloudflareCompanionService;' "    companion: CloudflareCompanionService;`n    pepehubLibrary: PepeHubLibraryService;"
$pluginMain = Add-BridgeHook $pluginMain 'this.pepehubLibrary = new' '        this.companion = new CloudflareCompanionService(this);' "        this.companion = new CloudflareCompanionService(this);`n        this.pepehubLibrary = new PepeHubLibraryService(this);"
$pluginMain = Add-BridgeHook $pluginMain 'this.pepehubLibrary.start();' '            this.companion.start();' "            this.companion.start();`n            this.pepehubLibrary.start();"
$pluginMain = Add-BridgeHook $pluginMain 'this.pepehubLibrary.stop();' '        this.companion.stop();' "        this.companion.stop();`n        this.pepehubLibrary.stop();"
$workerMain = [IO.File]::ReadAllText((Join-Path $bridgePlugin 'cloudflare-companion\src\index.ts'))
$workerMain = Add-BridgeHook $workerMain 'import { handleMetadataApi }' 'export default {' "import { handleMetadataApi } from './pepehub-metadata-api';`n`nexport default {"
$workerAnchor = "    if (url.pathname === '/api/tasks') {"
$workerMain = Add-BridgeHook $workerMain 'return handleMetadataApi(request' $workerAnchor "    if (url.pathname === '/api/pepehub/library' || url.pathname.startsWith('/api/pepehub/library/')) return handleMetadataApi(request, env.DB, profile(env));`n$workerAnchor"
$metadata = [IO.File]::ReadAllText((Join-Path $bridgeRoot 'metadata.ts')).Replace("'./covers.ts'", "'./pepehub-covers'")
Write-BridgeFile 'src\services\pepehub-metadata.ts' $metadata
Write-BridgeFile 'src\services\pepehub-library-service.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-library-service.ts.template')))
Write-BridgeFile 'src\services\pepehub-activity-service.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-activity-service.ts.template')))
Write-BridgeFile 'src\services\pepehub-covers.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'covers.ts')))
Write-BridgeFile 'src\services\pepehub-cover-service.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-cover-service.ts.template')))
Write-BridgeFile 'cloudflare-companion\src\pepehub-covers.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'covers.ts')))
foreach ($bridgeActivityName in @('activity', 'activity-state', 'activity-markdown')) {
    $bridgeActivityCode = [IO.File]::ReadAllText((Join-Path $bridgeRoot "$bridgeActivityName.ts")).Replace("'./metadata.ts'", "'./pepehub-metadata'").Replace("'./activity.ts'", "'./pepehub-activity'")
    Write-BridgeFile "src\services\pepehub-$bridgeActivityName.ts" $bridgeActivityCode
}
foreach ($bridgeNoteName in @('notes', 'notes-state', 'notes-markdown')) {
    $bridgeNoteCode = [IO.File]::ReadAllText((Join-Path $bridgeRoot "$bridgeNoteName.ts")).Replace("'./metadata.ts'", "'./pepehub-metadata'").Replace("'./notes.ts'", "'./pepehub-notes'")
    Write-BridgeFile "src\services\pepehub-$bridgeNoteName.ts" $bridgeNoteCode
}
Write-BridgeFile 'src\services\pepehub-notes-service.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-notes-service.ts.template')))
Write-BridgeFile 'src\services\pepehub-durable-state.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'durable-state.ts')))
Write-BridgeFile 'cloudflare-companion\src\pepehub-notes.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'notes.ts')).Replace("'./metadata.ts'", "'./pepehub-metadata'"))
Write-BridgeFile 'cloudflare-companion\src\notes-api.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'notes-api.ts')).Replace("'./notes.ts'", "'./pepehub-notes'").Replace("'./metadata-api.ts'", "'./pepehub-metadata-api'"))
Write-BridgeFile 'cloudflare-companion\migrations\0013_pepehub_notes.sql' ([IO.File]::ReadAllText((Join-Path $bridgeRoot '003_pepehub_notes.sql')))
Write-BridgeFile 'tests\pepehub-library.test.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-library.test.ts.template')))
Write-BridgeFile 'tests\pepehub-notes.test.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-notes.test.ts.template')))
Write-BridgeFile 'tests\pepehub-activity.test.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-activity.test.ts.template')))
Write-BridgeFile 'cloudflare-companion\src\pepehub-metadata.ts' $metadata
Write-BridgeFile 'cloudflare-companion\src\pepehub-metadata-api.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'metadata-api.ts')).Replace("'./metadata.ts'", "'./pepehub-metadata'").Replace("'./covers.ts'", "'./pepehub-covers'").Replace("'./metadata-incremental.ts'", "'./pepehub-metadata-incremental'"))
Write-BridgeFile 'cloudflare-companion\src\pepehub-metadata-incremental.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'metadata-incremental.ts')).Replace("'./metadata.ts'", "'./pepehub-metadata'").Replace("'./covers.ts'", "'./pepehub-covers'").Replace("'./metadata-api.ts'", "'./pepehub-metadata-api'"))
Write-BridgeFile 'cloudflare-companion\migrations\0014_pepehub_library_changes.sql' ([IO.File]::ReadAllText((Join-Path $bridgeRoot '004_pepehub_library_changes.sql')))
Write-BridgeFile 'cloudflare-companion\src\pepehub-activity.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'activity.ts')).Replace("'./metadata.ts'", "'./pepehub-metadata'").Replace("'./covers.ts'", "'./pepehub-covers'"))
Write-BridgeFile 'cloudflare-companion\src\activity-api.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'activity-api.ts')).Replace("'./activity.ts'", "'./pepehub-activity'").Replace("'./metadata-api.ts'", "'./pepehub-metadata-api'"))
Write-BridgeFile 'cloudflare-companion\migrations\0012_pepehub_activity.sql' ([IO.File]::ReadAllText((Join-Path $bridgeRoot '002_pepehub_activity.sql')))
Write-BridgeFile 'cloudflare-companion\migrations\0011_pepehub_library.sql' ([IO.File]::ReadAllText((Join-Path $bridgeRoot '001_pepehub_library.sql')))
Write-BridgeFile 'src\main.ts' $pluginMain
$workerMain=$workerMain.Replace('handleMetadataApi(request, env.DB, profile(env));','handleMetadataApi(request, env.DB, profile(env), env.COVERS);')
Write-BridgeFile 'cloudflare-companion\src\index.ts' $workerMain
Write-Output 'PepeHub metadata bridge installed in plugin sources. Build the plugin and deploy Companion with the new D1 migration.'
