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
$metadata = [IO.File]::ReadAllText((Join-Path $bridgeRoot 'metadata.ts'))
Write-BridgeFile 'src\services\pepehub-metadata.ts' $metadata
Write-BridgeFile 'src\services\pepehub-library-service.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-library-service.ts.template')))
Write-BridgeFile 'tests\pepehub-library.test.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'pepehub-library.test.ts.template')))
Write-BridgeFile 'cloudflare-companion\src\pepehub-metadata.ts' $metadata
Write-BridgeFile 'cloudflare-companion\src\pepehub-metadata-api.ts' ([IO.File]::ReadAllText((Join-Path $bridgeRoot 'metadata-api.ts')).Replace("'./metadata.ts'", "'./pepehub-metadata'"))
Write-BridgeFile 'cloudflare-companion\migrations\0011_pepehub_library.sql' ([IO.File]::ReadAllText((Join-Path $bridgeRoot '001_pepehub_library.sql')))
Write-BridgeFile 'src\main.ts' $pluginMain
Write-BridgeFile 'cloudflare-companion\src\index.ts' $workerMain
Write-Output 'PepeHub metadata bridge installed in plugin sources. Build the plugin and deploy Companion with the new D1 migration.'
