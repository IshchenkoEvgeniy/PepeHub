$ErrorActionPreference = 'Stop'
$pepeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pepeJava = Get-ChildItem -LiteralPath (Join-Path $pepeRoot '.tools\jdk') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } | Select-Object -First 1
if (-not $pepeJava) { throw 'Local JDK is missing in .tools/jdk' }
$env:JAVA_HOME = $pepeJava.FullName
$env:ANDROID_HOME = Join-Path $pepeRoot '.tools\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_USER_HOME = Join-Path $pepeRoot '.tools\android-user'
$env:GRADLE_USER_HOME = Join-Path $pepeRoot '.tools\gradle-cache'
$env:PUB_CACHE = Join-Path $pepeRoot '.tools\pub-cache'
$env:CI = 'true'
$env:Path = "$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:ANDROID_HOME\cmdline-tools\latest\bin;$env:Path"
