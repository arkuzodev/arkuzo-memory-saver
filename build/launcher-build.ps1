[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'src/launcher/App/Launcher.csproj'
$tests = Join-Path $root 'tests/launcher/Launcher.Tests.csproj'
$publish = Join-Path $root 'src/launcher/artifacts/publish'
& dotnet run --project $tests --configuration Release
if ($LASTEXITCODE -ne 0) { throw "Launcher regression tests failed ($LASTEXITCODE)." }
& dotnet publish $project --configuration Release --runtime win-x64 --self-contained true --output $publish --source 'https://api.nuget.org/v3/index.json' '-p:PublishSingleFile=true' '-p:IncludeNativeLibrariesForSelfExtract=true' '-p:EnableCompressionInSingleFile=true' '-p:DebugType=None' '-p:DebugSymbols=false' '-p:Version=1.0.1' '-p:AssemblyVersion=1.0.1.0' '-p:FileVersion=1.0.1.0'
if ($LASTEXITCODE -ne 0) { throw "Launcher publish failed ($LASTEXITCODE)." }
Copy-Item -LiteralPath (Join-Path $publish 'Arkuzo Memory Saver.exe') -Destination (Join-Path $root 'Arkuzo Memory Saver.exe') -Force
Get-Item -LiteralPath (Join-Path $root 'Arkuzo Memory Saver.exe') | Select-Object FullName,Length
Get-FileHash -LiteralPath (Join-Path $root 'Arkuzo Memory Saver.exe') -Algorithm SHA256
Write-Output 'Unsigned self-contained .NET 10 win-x64 launcher built. No release was published.'
