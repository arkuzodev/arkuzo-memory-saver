#requires -Version 5.1
[CmdletBinding()]
param([string]$Version = 'v1.0.2', [switch]$SkipLauncherBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Version -notmatch '^v\d+\.\d+\.\d+$') { throw 'Use a stable semantic version, for example v1.0.0.' }
if (-not $SkipLauncherBuild) {
    & (Join-Path $PSScriptRoot 'launcher-build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed.' }
}
$exe = Join-Path $root 'ArkuzoMemorySaver.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Build ArkuzoMemorySaver.exe before packaging.' }
$dist = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$staging = Join-Path $dist ('runtime-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($staging) | Out-Null
try {
    foreach ($name in @('Arkuzo-Memory-Saver.ps1', 'Arkuzo-Volt-Control.ps1', 'Arkuzo-Volt-Probe.py')) {
        Copy-Item -LiteralPath (Join-Path $root ('src/saver/' + $name)) -Destination (Join-Path $staging $name)
    }
    Copy-Item -LiteralPath (Join-Path $root 'config/defaults.json') -Destination (Join-Path $staging 'defaults.json')
    # Launchers in the field reject any runtime ZIP that is not exactly these four files.
    if (@(Get-ChildItem -LiteralPath $staging).Count -ne 4) { throw 'The runtime ZIP must contain exactly four files.' }
    $runtime = Join-Path $dist 'ArkuzoMemorySaver-runtime.zip'
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $runtime -Force
    $runtimeHash = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $dist 'ArkuzoMemorySaver-runtime.sha256'), ($runtimeHash + '  ArkuzoMemorySaver-runtime.zip' + "`n"), [Text.Encoding]::ASCII)
    # The Control Center is a separate add-on asset; only launchers that know it download it.
    $ccStaging = Join-Path $staging 'control-center'
    [IO.Directory]::CreateDirectory($ccStaging) | Out-Null
    foreach ($name in @('Arkuzo-Control-Center.py', 'Arkuzo-Control-Center.html')) {
        Copy-Item -LiteralPath (Join-Path $root ('src/saver/' + $name)) -Destination (Join-Path $ccStaging $name)
    }
    $controlCenter = Join-Path $dist 'ArkuzoMemorySaver-controlcenter.zip'
    Compress-Archive -Path (Join-Path $ccStaging '*') -DestinationPath $controlCenter -Force
    $ccHash = (Get-FileHash -LiteralPath $controlCenter -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $dist 'ArkuzoMemorySaver-controlcenter.sha256'), ($ccHash + '  ArkuzoMemorySaver-controlcenter.zip' + "`n"), [Text.Encoding]::ASCII)
    Copy-Item -LiteralPath $exe -Destination (Join-Path $dist 'ArkuzoMemorySaver.exe') -Force
    $portable = Join-Path $dist ('ArkuzoMemorySaver-' + $Version + '-win-x64.zip')
    Compress-Archive -LiteralPath $exe -DestinationPath $portable -Force
    $sums = foreach ($name in @('ArkuzoMemorySaver.exe', 'ArkuzoMemorySaver-runtime.zip', 'ArkuzoMemorySaver-controlcenter.zip', ('ArkuzoMemorySaver-' + $Version + '-win-x64.zip'))) {
        (Get-FileHash -LiteralPath (Join-Path $dist $name) -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
    }
    [IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), [Text.Encoding]::ASCII)
    Write-Host ('Release artifacts ready: ' + $dist)
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
