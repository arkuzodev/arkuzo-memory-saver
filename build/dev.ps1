#requires -Version 5.1
<#
Runs the Control Center and the engine from the sources, next to (never instead of) an
installed copy: its own data folder, its own port, and a monitor-only engine.

  build/dev.ps1                          bundle the sources, start the Control Center on a free port
                                         with a new temp data folder, and a monitor-only engine for 10 min
  build/dev.ps1 -Engine None             the Control Center only
  build/dev.ps1 -DataDirectory <dir>     reuse a dev data folder (never the real data folder)
  build/dev.ps1 -Port 48700 -NoWindow    fixed port, no app window (open the printed URL yourself)
  build/dev.ps1 -ForSec 60               stop everything after 60 s instead of waiting for Enter

What keeps it apart from the installed copy:
  - Port: any free port, never 48650. The installed Control Center is never asked to quit
    (a Control Center only takes over another one on its own port and data folder).
  - Data: a new folder under %TEMP% unless -DataDirectory names one, which must be new, empty,
    or a folder build/dev.ps1 made before (marked by a .arkuzo-dev file). Anything else, the
    repository's own data folder and any folder with accounts.json are refused.
  - Engine: -MonitorOnly. It writes no heartbeat, takes no controller lock, and never changes,
    closes or launches a client. The dev copy also never writes the executor autoexec script
    (Sync-ArkuzoAutoexecSignals is switched off in the copy), because those folders are shared
    with a farm running on the same PC.
  - The dev Control Center starts with autopilot and "start saver with the Control Center" off.
    Its Start button would run a full (controlling) engine from the dev copy: it refuses to run
    while another controller holds the lock, but never press it on a PC where clients run
    without one.
Everything runs from a copy under %TEMP%\arkuzo-dev-<id>\runtime, rebuilt by build/bundle.ps1 on every start.
#>
[CmdletBinding()]
param(
    [ValidateSet('MonitorOnly', 'None')][string]$Engine = 'MonitorOnly',
    [string]$DataDirectory,
    [ValidateRange(0, 65535)][int]$Port = 0,
    [ValidateRange(10, 86400)][int]$RunForSec = 600,
    [ValidateRange(0, 86400)][int]$ForSec = 0,
    [switch]$NoWindow
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installedPort = 48650

if ($Port -eq $installedPort) { throw 'Port 48650 belongs to the installed Control Center. Pick another one, or leave -Port out.' }
if ($Port -eq 0) {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $Port = $listener.LocalEndpoint.Port; $listener.Stop()
}
# The program copy always goes to a fresh temp folder; the data folder too unless -DataDirectory
# names one, which must be new, empty or one this script made (it holds the .arkuzo-dev marker).
# Anything else could be a real install's data folder (a Volt farm's has no accounts.json).
$session = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-dev-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
if (-not $DataDirectory) { $DataDirectory = Join-Path $session 'data' }
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
$marker = Join-Path $DataDirectory '.arkuzo-dev'
$realData = [IO.Path]::GetFullPath((Join-Path $root 'data'))
if ($DataDirectory.TrimEnd('\') -ieq $realData.TrimEnd('\')) { throw 'That is the real data folder. build/dev.ps1 only runs with a separate one.' }
if ((Test-Path -LiteralPath $DataDirectory) -and @(Get-ChildItem -LiteralPath $DataDirectory -Force).Count -gt 0 -and -not (Test-Path -LiteralPath $marker)) {
    throw 'That folder is not empty and was not made by build/dev.ps1. Use a new or empty folder (or leave -DataDirectory out).'
}
if (Test-Path -LiteralPath (Join-Path $DataDirectory 'accounts.json')) { throw 'That folder holds accounts.json (an account vault). Use a new dev data folder.' }
$runtime = Join-Path $session 'runtime'
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
[IO.File]::WriteAllText($marker, 'Data folder of build/dev.ps1. Safe to delete.', (New-Object Text.UTF8Encoding($false)))

# 1. A fresh copy of the sources: the bundles plus the files that ship as they are.
& (Join-Path $PSScriptRoot 'bundle.ps1') -OutDirectory $runtime | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'build/bundle.ps1 failed.' }
foreach ($name in @('Arkuzo-Volt-Control.ps1', 'Arkuzo-Volt-Probe.py')) { Copy-Item -LiteralPath (Join-Path $root ('src/saver/' + $name)) -Destination (Join-Path $runtime $name) -Force }
$enginePath = Join-Path $runtime 'Arkuzo-Memory-Saver.ps1'
$text = [IO.File]::ReadAllText($enginePath)
$hook = 'function Sync-ArkuzoAutoexecSignals {'
if (([regex]::Matches($text, [regex]::Escape($hook))).Count -ne 1) { throw 'Sync-ArkuzoAutoexecSignals not found once in the engine; update build/dev.ps1.' }
$text = $text.Replace($hook, $hook + ' return  # build/dev.ps1: a dev engine never writes executor folders')
[IO.File]::WriteAllText($enginePath, $text, (New-Object Text.UTF8Encoding($true)))
if (-not (Test-Path -LiteralPath (Join-Path $DataDirectory 'config.json'))) {
    Copy-Item -LiteralPath (Join-Path $root 'config/defaults.json') -Destination (Join-Path $DataDirectory 'config.json')
}
[IO.File]::WriteAllText((Join-Path $DataDirectory 'control-center.json'), '{"autopilot": false, "startSaverOnLaunch": false}', (New-Object Text.UTF8Encoding($false)))

# 2. Start them.
$python = @('python.exe', 'python3.exe') | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1
if ($null -eq $python) { throw 'Python 3 was not found on PATH.' }
# Parentheses matter: in PowerShell the comma binds tighter than +.
$ccArgs = @('-I', ('"' + (Join-Path $runtime 'Arkuzo-Control-Center.py') + '"'), '--data', ('"' + $DataDirectory + '"'), '--port', [string]$Port)
if ($NoWindow) { $ccArgs += '--background' }
$started = New-Object 'System.Collections.Generic.List[object]'
$cc = Start-Process -FilePath $python.Source -ArgumentList $ccArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $session 'control-center.out.txt') -RedirectStandardError (Join-Path $session 'control-center.err.txt')
$started.Add($cc)
if ($Engine -eq 'MonitorOnly') {
    $powershell = Join-Path $PSHOME 'powershell.exe'
    $engineArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $enginePath + '"'), '-MonitorOnly', '-Headless', '-DataDirectory', ('"' + $DataDirectory + '"'), '-RunForSec', [string]$RunForSec)
    $started.Add((Start-Process -FilePath $powershell -ArgumentList $engineArgs -WindowStyle Hidden -PassThru))
}
$url = 'http://127.0.0.1:' + $Port + '/'
$answered = $false
for ($i = 0; $i -lt 120 -and -not $answered; $i++) {
    Start-Sleep -Milliseconds 250
    try { $answered = ((Invoke-RestMethod -Uri ($url + 'api/ping') -TimeoutSec 2).app -eq 'arkuzo-control-center') } catch { }
    if ($cc.HasExited) { break }
}
Write-Host ('Control Center (dev): ' + $url + $(if ($answered) { '' } else { '  (not answering yet)' }))
Write-Host ('Data folder:          ' + $DataDirectory)
Write-Host ('Engine:               ' + $(if ($Engine -eq 'MonitorOnly') { 'monitor-only, stops after ' + $RunForSec + ' s; log in ' + (Join-Path $DataDirectory 'Arkuzo-Logs') } else { 'not started' }))
try {
    if ($ForSec -gt 0) { Start-Sleep -Seconds $ForSec } else { [void](Read-Host 'Press Enter to stop the dev Control Center and engine') }
} finally {
    foreach ($process in $started) {
        try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch { }
    }
    Write-Host 'Stopped. The data folder is kept; delete it when you are done.'
}
if (-not $answered) { exit 1 }
exit 0
