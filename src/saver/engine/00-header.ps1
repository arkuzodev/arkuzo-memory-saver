#requires -Version 5.1
<#
Arkuzo Memory Saver engine - Windows x64, Windows PowerShell 5.1.
Normally started by the Control Center (or ArkuzoMemorySaver.exe --console), which
passes -DataDirectory. Settings come from config.json in the data directory
(see docs/configuration.md); explicit command-line values override it, also on
later hot reloads. Without a config.json the script's own fallbacks apply:
Normal preset, 850 MB advisory target, trimming on, BelowNormal priority.
Soft targets are advisory only: no working-set quota is installed in soft mode.
Working set = resident physical memory, NOT allocated/private/committed memory.
Trimming causes page faults and can reduce performance; memory can be reloaded.
Stopping (Ctrl+C, Q, a stop signal) restores captured process settings where
possible. Force-closing the process skips cleanup; restart Roblox to reset
process settings in that case.
Examples:
  .\Arkuzo-Memory-Saver.ps1
  .\Arkuzo-Memory-Saver.ps1 -Minimize
  .\Arkuzo-Memory-Saver.ps1 -EnableTrimming -HardLimit -MaxRamMB 600 -TrimEverySec 90
  .\Arkuzo-Memory-Saver.ps1 -ApplyGraphicsFlags
Graphics settings persist, affect next launches, and have unique backups.
Diagnostics: Arkuzo-Logs under DataDirectory (unless LogDirectory is set), sampled every 5 seconds.
Each session keeps up to five 10 MB JSON-line .log files. At start, older sessions are deleted
beyond the newest 200 or 300 MB in all (-MaxLogSessions, -MaxLogTotalMB); the current one never.
Use -MonitorOnly to log without changing priority, CPU affinity or memory limits.
Accounts: verified idle accounts with a dead cookie are paused separately, not treated as banned;
a fresh verified alive check resumes their recovery. Moderated accounts are never launched.
Unknown/missing account identities remain blocked; no account is guessed or silently discarded.
Architecture: docs/architecture.md.
#>
[CmdletBinding()]
param(
    [ValidateSet('Normal','Agressive','Aggressive','Extreme','Balanced')][string]$Mode = 'Normal',
    [ValidateRange(128,32768)][int]$MaxRamMB = 850,
    [ValidateRange(1,120)][int]$TrimEverySec = 120,
    [ValidateRange(250,10000)][int]$PollMs = 500,
    [ValidateRange(1,64)][int]$CoresPerInstance = 4,
    [ValidateSet('Idle','BelowNormal','Normal')][string]$Priority = 'BelowNormal',
    [ValidateSet('VeryLow','Low','Medium','BelowNormal','Normal')][string]$MemoryPriority = 'Normal',
    [switch]$Minimize,
    [switch]$EnableTrimming = $true,
    [switch]$SoftLimit = $true,
    [switch]$HardLimit,
    [switch]$ApplyGraphicsFlags,
    [string]$LogDirectory,
    [string]$DataDirectory,
    [ValidateRange(2,300)][int]$LogEverySec = 5,
    [ValidateRange(1,100)][int]$MaxLogMB = 10,
    # Across sessions (checked at start): the newest sessions are kept while both caps hold.
    [ValidateRange(10,100000)][int]$MaxLogSessions = 200,
    [ValidateRange(20,100000)][int]$MaxLogTotalMB = 300,
    [switch]$MonitorOnly,
    [switch]$Headless,
    [ValidateRange(0,86400)][int]$RunForSec = 0,
    [string]$StopFile,
    [ValidateRange(0.25,300)][double]$StatusEverySec = 0.25
)

$ErrorActionPreference = 'Stop'
$ArkuzoRuntimeVersion = '__ARKUZO_VERSION__'
# Explicit CLI values win over config, including later hot reloads.
$cliBoundParameters = @($PSBoundParameters.Keys)
# Resolve persistent data independently of the versioned program files.
if ([string]::IsNullOrWhiteSpace($DataDirectory)) { $DataDirectory = $PSScriptRoot }
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path $DataDirectory 'Arkuzo-Logs'
}
if ($env:OS -ne 'Windows_NT' -or [IntPtr]::Size -ne 8) {
    throw 'Run Arkuzo Memory Saver in 64-bit PowerShell on Windows.'
}

