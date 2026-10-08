#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
function Check-MemoryPolicy([bool]$Ok, [string]$Message) {
    if (-not $Ok) { throw "FAIL: $Message" }
}
$config = [IO.File]::ReadAllText((Join-Path $root 'config/defaults.json')) | ConvertFrom-Json
Check-MemoryPolicy ($config.health.private_limit_mb -eq 6500) "Production memory guard must be 6500 MB; got $($config.health.private_limit_mb)."
$health = Get-ArkuzoHealthPolicy $config.health
Check-MemoryPolicy ($health.private_limit_mb -eq 6500) 'The real health policy must retain the configured 6500 MB guard.'
Write-Output 'PASS: production memory guard loads as 6500 MB.'

# One 160-GiB ceiling must work on single-volume hosts as well as globally.
$ceilingMB = 160 * 1024
Check-MemoryPolicy ($config.pagefile.max_file_mb -eq $ceilingMB) "Production per-file ceiling must be 160 GiB ($ceilingMB MB); got $($config.pagefile.max_file_mb)."
Check-MemoryPolicy ($config.pagefile.max_total_mb -eq $ceilingMB) 'Production total pagefile ceiling must also be 160 GiB.'
Check-MemoryPolicy ($config.pagefile.enabled -is [bool] -and $config.pagefile.enabled) 'Production bounded pagefile management must be explicitly enabled.'
$pagefile = Get-ArkuzoPagefilePolicy -Input $config.pagefile -PressurePercent $health.pressure_percent
Check-MemoryPolicy ($pagefile.valid -and $pagefile.enabled) "The real validator must accept the production 160-GiB policy: $($pagefile.errors -join '; ')."
$fallback = Get-ArkuzoPagefilePolicy
Check-MemoryPolicy ($fallback.valid -and -not $fallback.enabled -and $fallback.max_file_mb -eq $ceilingMB -and $fallback.max_total_mb -eq $ceilingMB) 'Missing policy retains the same ceilings without silently enabling pagefile writes.'
foreach ($bad in @(
    @{enabled=$true;max_file_mb=163841;max_total_mb=262144},
    @{enabled=$true;max_file_mb=163840;max_total_mb=163839},
    @{enabled=$true;max_file_mb=163840;max_total_mb=262145},
    @{enabled=$true;max_file_mb='163840';max_total_mb=163840}
)) {
    $invalid = Get-ArkuzoPagefilePolicy -Input $bad
    Check-MemoryPolicy (-not $invalid.valid -and -not $invalid.enabled) 'Out-of-range, inconsistent, or nonnumeric pagefile ceilings must fail closed.'
}

# Exercise the real pure decision function above the previous 128-GiB limit.
# This is a fabricated local fixture, never a live CIM snapshot or OS write.
$snapshot = [pscustomobject]@{
    available=$true; automaticManagedPagefile=$false; isAdministrator=$true
    bootId='MEMORY-POLICY-FIXTURE:1'; computerName='MEMORY-POLICY-FIXTURE'
    settings=@([pscustomobject]@{
        name='C:\pagefile.sys'; settingId='fixture-C'
        initialSizeMB=(159*1024); maximumSizeMB=(159*1024)
        cimClass='Win32_PageFileSetting'; cimNamespace='root/cimv2'; cimServer='MEMORY-POLICY-FIXTURE'
    })
    usage=@([pscustomobject]@{name='C:\pagefile.sys'; allocatedMB=(159*1024); temporary=$false})
    drives=@([pscustomobject]@{
        deviceId='C:'; driveType=3; sizeBytes=[int64](1TB); freeBytes=[int64](200GB)
        volumeSerial='MEMORY-POLICY-FIXTURE-C'; fileSystem='NTFS'
    })
}
$memory = [pscustomobject]@{commitUsedMB=8000;commitLimitMB=10000;commitPercent=80}
$before = $snapshot | ConvertTo-Json -Depth 8 -Compress
$decision = Get-ArkuzoPagefileGrowthDecision -Snapshot $snapshot -Policy $pagefile -SystemMemory $memory
Check-MemoryPolicy ($decision.eligible -and $decision.growthMB -eq 1024 -and $decision.newInitialSizeMB -eq $ceilingMB -and $decision.newMaximumSizeMB -eq $ceilingMB) 'The final step above 128 GiB must stop exactly at 160 GiB, not add the full 4 GiB.'
Check-MemoryPolicy (($snapshot | ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'The growth decision must leave the input snapshot unchanged.'
$snapshot.settings[0].initialSizeMB=$ceilingMB; $snapshot.settings[0].maximumSizeMB=$ceilingMB; $snapshot.usage[0].allocatedMB=$ceilingMB
$decision = Get-ArkuzoPagefileGrowthDecision $snapshot $pagefile $memory
Check-MemoryPolicy (-not $decision.eligible -and $decision.status -eq 'AtCeiling') 'No growth may be proposed at the 160-GiB ceiling.'
$snapshot.settings[0].initialSizeMB=(164*1024); $snapshot.settings[0].maximumSizeMB=(164*1024); $snapshot.usage[0].allocatedMB=(164*1024)
$decision = Get-ArkuzoPagefileGrowthDecision $snapshot $pagefile $memory
Check-MemoryPolicy (-not $decision.eligible -and $decision.status -eq 'AtCeiling' -and $snapshot.settings[0].maximumSizeMB -eq (164*1024)) 'A previously larger pagefile must never be shrunk to the new default ceiling.'
$snapshot.settings[0].initialSizeMB=(159*1024); $snapshot.settings[0].maximumSizeMB=(159*1024); $snapshot.usage[0].allocatedMB=(159*1024)
$snapshot.drives[0].freeBytes=[int64](15GB)
$decision = Get-ArkuzoPagefileGrowthDecision $snapshot $pagefile $memory
Check-MemoryPolicy (-not $decision.eligible -and $decision.status -eq 'LowDiskSpace') 'Large-capacity growth must still preserve the absolute and percentage disk reserves.'
$snapshot.automaticManagedPagefile=$true
$decision = Get-ArkuzoPagefileGrowthDecision $snapshot $pagefile $memory
Check-MemoryPolicy (-not $decision.eligible -and $decision.status -eq 'WindowsManaged') 'Windows-managed pagefiles remain untouched by the enabled production policy.'
Write-Output 'PASS: 160-GiB defaults, validation, bounded large-file growth, no shrink, disk reserve, and Windows-managed safety.'
