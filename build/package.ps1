#requires -Version 5.1
[CmdletBinding()]
param([string]$Version = 'v1.0.1', [switch]$SkipLauncherBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Version -notmatch '^v\d+\.\d+\.\d+$') { throw 'Use a stable semantic version, for example v1.0.0.' }
if (-not $SkipLauncherBuild) {
    & (Join-Path $PSScriptRoot 'launcher-build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed.' }
}
$exe = Join-Path $root 'Arkuzo Memory Saver.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Build Arkuzo Memory Saver.exe before packaging.' }
$dist = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$staging = Join-Path $dist ('runtime-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($staging) | Out-Null
try {
    foreach ($name in @('Arkuzo-Memory-Saver.ps1', 'Arkuzo-Volt-Control.ps1', 'Arkuzo-Volt-Probe.py')) {
        Copy-Item -LiteralPath (Join-Path $root ('src/saver/' + $name)) -Destination (Join-Path $staging $name)
    }
    Copy-Item -LiteralPath (Join-Path $root 'config/defaults.json') -Destination (Join-Path $staging 'defaults.json')
    $runtime = Join-Path $dist 'ArkuzoMemorySaver-runtime.zip'
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $runtime -Force
    $runtimeHash = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $dist 'ArkuzoMemorySaver-runtime.sha256'), ($runtimeHash + '  ArkuzoMemorySaver-runtime.zip' + "`n"), [Text.Encoding]::ASCII)
    Copy-Item -LiteralPath $exe -Destination (Join-Path $dist 'Arkuzo Memory Saver.exe') -Force
    $portable = Join-Path $dist ('ArkuzoMemorySaver-' + $Version + '-win-x64.zip')
    Compress-Archive -LiteralPath $exe -DestinationPath $portable -Force
    $sums = foreach ($name in @('Arkuzo Memory Saver.exe', 'ArkuzoMemorySaver-runtime.zip', ('ArkuzoMemorySaver-' + $Version + '-win-x64.zip'))) {
        (Get-FileHash -LiteralPath (Join-Path $dist $name) -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
    }
    [IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), [Text.Encoding]::ASCII)
    Write-Host ('Release artifacts ready: ' + $dist)
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
