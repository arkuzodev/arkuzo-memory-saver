#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
function Assert([bool]$Ok, [string]$Message) { if (-not $Ok) { throw "FAIL: $Message" } }
$script:pagefileAssertions = 0
function Check([bool]$Ok, [string]$Message) { Assert $Ok $Message; $script:pagefileAssertions++ }
# Functions are extracted, never the saver loop; all future CIM writes use local fakes.
Check ([bool](Get-Command Get-ArkuzoPagefilePolicy -ErrorAction SilentlyContinue)) 'Pagefile policy helper must exist'
$p = Get-ArkuzoPagefilePolicy
Check ($p.valid -and $p.enabled -is [bool] -and -not $p.enabled) 'Missing policy is valid but explicitly disabled'
Check ($p.reserve_free_bytes -ge 15GB) 'Default growth must retain at least 15 GiB free disk reserve'
foreach ($bad in @('true', 'false', 1, 0, $null)) {
    $p = Get-ArkuzoPagefilePolicy -Input @{enabled=$bad}
    Check (-not $p.valid -and -not $p.enabled) 'Only a literal boolean can opt in'
}
$p = Get-ArkuzoPagefilePolicy -Input @{enabled=$true}
Check ($p.valid -and $p.enabled) 'Literal true opts in'
Check ($p.trigger_percent -lt $p.pressure_percent) 'Default trigger precedes pressure recycling'
foreach ($bad in @(
    @{enabled=$true;growth_step_mb=0}, @{enabled=$true;growth_step_mb=8193},
    @{enabled=$true;max_file_mb=1024;max_total_mb=512},
    @{enabled=$true;reserve_free_bytes=-1}, @{enabled=$true;reserve_free_percent=101},
    @{enabled=$true;trigger_percent=88}, @{enabled=$true;cooldown_sec=1},
    @{enabled=$true;max_requests_per_boot=5}, @{enabled=$true;max_boot_growth_mb=0},
    @{enabled=$true;growth_step_mb='4096'}, @{enabled=$true;typo=1}
)) {
    $p = Get-ArkuzoPagefilePolicy -Input $bad
    Check (-not $p.valid -and -not $p.enabled -and @($p.errors).Count -gt 0) 'Unsafe/unknown configuration fails closed with errors'
}
$p = Get-ArkuzoPagefilePolicy -Input @{enabled=$true;trigger_percent=75} -PressurePercent 78
Check ($p.valid -and $p.pressure_percent -eq 78) 'Parent pressure threshold participates in early-trigger validation'
# A read-only snapshot distinguishes settings from live allocation and supplies boot/drive identity.
$script:fakeCim = @{
    Win32_ComputerSystem = @([pscustomobject]@{Name='TESTHOST';AutomaticManagedPagefile=$false})
    Win32_OperatingSystem = @([pscustomobject]@{LastBootUpTime=[datetime]'2026-10-01T00:00:00Z'})
    Win32_PageFileSetting = @([pscustomobject]@{Name='C:\pagefile.sys';SettingID='fixed-C';InitialSize=4096;MaximumSize=4096})
    Win32_PageFileUsage = @([pscustomobject]@{Name='C:\pagefile.sys';AllocatedBaseSize=4096;TempPageFile=$false})
    Win32_LogicalDisk = @([pscustomobject]@{DeviceID='C:';DriveType=3;Size=[int64](200GB);FreeSpace=[int64](100GB);VolumeSerialNumber='TEST-0001';FileSystem='NTFS'})
}
$script:cimReads = @(); $script:cimWrites = 0
$deps = @{
    ReadCim = {param($ClassName) $script:cimReads += $ClassName; return $script:fakeCim[$ClassName]}
    IsAdministrator = {return $true}
    UtcNow = {return [datetime]'2026-10-07T12:00:00Z'}
    WriteCim = {param($Instance, $Properties) $script:cimWrites++; throw 'Unexpected fake write'}
    ReadMemory = {return [pscustomobject]@{commitUsedMB=8000;commitLimitMB=10000;commitPercent=80;freeCommitMB=2000;availablePhysicalMB=1024}}
}
Check ([bool](Get-Command Get-ArkuzoPagefileSnapshot -ErrorAction SilentlyContinue)) 'Read-only snapshot helper must exist'
$s = Get-ArkuzoPagefileSnapshot -Dependencies $deps
Check ($s.available -and $s.isAdministrator -and -not $s.automaticManagedPagefile) 'Snapshot retains literal admin and automatic-management states'
Check (@($s.settings).Count -eq 1 -and $s.settings[0].maximumSizeMB -eq 4096) 'Snapshot exposes configured ceiling separately'
Check ($s.usage[0].allocatedMB -eq 4096 -and $s.drives[0].freeBytes -eq 100GB) 'Snapshot exposes runtime allocation and free bytes'
Check ($s.bootId -and $script:cimWrites -eq 0 -and @($script:cimReads | Select-Object -Unique).Count -eq 5) 'Snapshot only reads five supported CIM classes with stable boot identity'
$badDeps = @{} + $deps; $badDeps.ReadCim = {param($ClassName) throw 'simulated CIM read failure'}
$s = Get-ArkuzoPagefileSnapshot -Dependencies $badDeps
Check (-not $s.available -and $s.error.message -match 'simulated CIM read failure' -and $script:cimWrites -eq 0) 'Read failure is a structured unavailable snapshot'
# The growth decision is pure: no writes, filesystem IO, clock reads, or changes to input.
Check ([bool](Get-Command Get-ArkuzoPagefileGrowthDecision -ErrorAction SilentlyContinue)) 'Pure growth decision helper must exist'
$p = Get-ArkuzoPagefilePolicy -Input @{enabled=$true}
$m = & $deps.ReadMemory
$s = Get-ArkuzoPagefileSnapshot -Dependencies $deps
$before = $s | ConvertTo-Json -Depth 8 -Compress
$d = Get-ArkuzoPagefileGrowthDecision -Snapshot $s -Policy $p -SystemMemory $m
Check ($d.eligible -and $d.status -eq 'Eligible' -and $d.growthMB -eq 4096 -and $d.newInitialSizeMB -eq 8192 -and $d.newMaximumSizeMB -eq 8192) 'Eligible fixed pagefile grows initial and maximum by one bounded step'
Check (($s | ConvertTo-Json -Depth 8 -Compress) -ceq $before -and $script:cimWrites -eq 0) 'Decision cannot mutate its snapshot or external state'
$script:fakeCim.Win32_ComputerSystem[0].AutomaticManagedPagefile = $true
$script:fakeCim.Win32_PageFileSetting = @()
$d = Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m
Check ($d.status -eq 'WindowsManaged' -and -not $d.eligible) 'Automatic Windows management with no settings must be preserved'
$script:fakeCim.Win32_ComputerSystem[0].AutomaticManagedPagefile = $false
$script:fakeCim.Win32_PageFileSetting = @([pscustomobject]@{Name='C:\pagefile.sys';SettingID='fixed-C';InitialSize=0;MaximumSize=0})
$d = Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m
Check ($d.status -eq 'WindowsManaged') 'A per-file system-managed setting also receives zero growth requests'
$script:fakeCim.Win32_PageFileSetting[0].InitialSize=4096; $script:fakeCim.Win32_PageFileSetting[0].MaximumSize=4096
$s = Get-ArkuzoPagefileSnapshot -Dependencies $deps
$quiet = [pscustomobject]@{commitUsedMB=7900;commitLimitMB=10000;commitPercent=79}
Check ((Get-ArkuzoPagefileGrowthDecision $s $p $quiet).status -eq 'BelowTrigger') 'Below the early commit trigger no growth is proposed'
$cap = Get-ArkuzoPagefilePolicy -Input @{enabled=$true;max_file_mb=5000;max_total_mb=5000}
$d = Get-ArkuzoPagefileGrowthDecision $s $cap $m
Check ($d.growthMB -eq 904 -and $d.newMaximumSizeMB -eq 5000) 'Per-file and total ceilings cap a partial final step'
$cap = Get-ArkuzoPagefilePolicy -Input @{enabled=$true;max_file_mb=4096;max_total_mb=4096}
Check ((Get-ArkuzoPagefileGrowthDecision $s $cap $m).status -eq 'AtCeiling') 'A ceiling is not exceeded or shrunk'
$script:fakeCim.Win32_LogicalDisk[0].FreeSpace=10GB
Check ((Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m).status -eq 'LowDiskSpace') 'Percent reserve dominates and blocks low disk space'
$script:fakeCim.Win32_LogicalDisk[0].Size=20GB; $script:fakeCim.Win32_LogicalDisk[0].FreeSpace=10GB
Check ((Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m).status -eq 'LowDiskSpace') 'Absolute byte reserve also blocks low disk space'
$script:fakeCim.Win32_LogicalDisk[0].Size=200GB; $script:fakeCim.Win32_LogicalDisk[0].FreeSpace=100GB
$script:fakeCim.Win32_LogicalDisk[0].DeviceID='D:'
Check ((Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m).status -eq 'UnknownDrive') 'An unknown target drive is never selected'
$script:fakeCim.Win32_LogicalDisk[0].DeviceID='C:'
$script:fakeCim.Win32_PageFileSetting[0].InitialSize=2048
Check ((Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m).status -eq 'UnsupportedLayout') 'Only existing fixed-size files are managed, not manual variable ranges'
$script:fakeCim.Win32_PageFileSetting[0].InitialSize=4096
$script:fakeCim.Win32_PageFileUsage[0].AllocatedBaseSize=2048
Check ((Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m).status -eq 'PendingReboot') 'Already configured but inactive capacity cannot trigger another request'
$script:fakeCim.Win32_PageFileUsage[0].AllocatedBaseSize=4096
$noAdmin = @{} + $deps; $noAdmin.IsAdministrator={return $false}
Check ((Get-ArkuzoPagefileGrowthDecision (Get-ArkuzoPagefileSnapshot -Dependencies $noAdmin) $p $m).status -eq 'NotAdministrator') 'Unprivileged callers cannot propose writes'
# All no-write gates must finish before any persistence or CIM setting update.
function Set-CimInstance { throw 'TEST SAFETY: real Set-CimInstance is forbidden' }
function New-CimInstance { throw 'TEST SAFETY: creating a pagefile is forbidden' }
function Remove-CimInstance { throw 'TEST SAFETY: deleting a pagefile is forbidden' }
Check ([bool](Get-Command Invoke-ArkuzoPagefileManagement -ErrorAction SilentlyContinue)) 'Management API must exist'
$s = Get-ArkuzoPagefileSnapshot -Dependencies $deps
$r = Invoke-ArkuzoPagefileManagement -Snapshot $s -Policy $p -SystemMemory $m -MonitorOnly -OwnsController $true -Dependencies $deps
Check ($r.status -eq 'MonitorOnly' -and -not $r.writeAttempted -and $script:cimWrites -eq 0) 'MonitorOnly is a hard no-write gate'
$r = Invoke-ArkuzoPagefileManagement -Snapshot $s -Policy $p -SystemMemory $m -OwnsController $false -Dependencies $deps
Check ($r.status -eq 'NotController' -and $script:cimWrites -eq 0) 'Nonowners may not request pagefile changes'
$r = Invoke-ArkuzoPagefileManagement -Snapshot (Get-ArkuzoPagefileSnapshot -Dependencies $noAdmin) -Policy $p -SystemMemory $m -OwnsController $true -Dependencies $noAdmin
Check ($r.status -eq 'NotAdministrator' -and $script:cimWrites -eq 0) 'Admin=false cannot request a change'
$r = Invoke-ArkuzoPagefileManagement -Snapshot $s -Policy (Get-ArkuzoPagefilePolicy) -SystemMemory $m -OwnsController $true -Dependencies $deps
Check ($r.status -eq 'Disabled' -and $script:cimWrites -eq 0) 'Disabled management cannot request a change'
$r = Invoke-ArkuzoPagefileManagement -Snapshot $s -Policy (Get-ArkuzoPagefilePolicy -Input @{enabled='true'}) -SystemMemory $m -OwnsController $true -Dependencies $deps
Check ($r.status -eq 'InvalidPolicy' -and $r.error.stage -eq 'PolicyValidation' -and $r.error.message -match 'enabled' -and $script:cimWrites -eq 0) 'Invalid policy cannot request a change and surfaces the exact validation error'
$script:fakeCim.Win32_ComputerSystem[0].AutomaticManagedPagefile=$true; $script:fakeCim.Win32_PageFileSetting=@()
$r = Invoke-ArkuzoPagefileManagement -Snapshot (Get-ArkuzoPagefileSnapshot -Dependencies $deps) -Policy $p -SystemMemory $m -OwnsController $true -Dependencies $deps
Check ($r.status -eq 'WindowsManaged' -and -not $r.changed -and $script:cimWrites -eq 0) 'System-managed operation makes zero settings/persistence writes'
Check (-not $r.canSuppressRecovery -and -not $r.rebootInitiated) 'Pagefile configuration cannot suppress recycling or initiate reboot'
$script:fakeCim.Win32_ComputerSystem[0].AutomaticManagedPagefile=$false
$script:fakeCim.Win32_PageFileSetting=@([pscustomobject]@{Name='C:\pagefile.sys';SettingID='fixed-C';InitialSize=4096;MaximumSize=4096})
# One fake write persists settings but MUST NOT imply live commit relief.
$baseScratch = Join-Path $env:LOCALAPPDATA 'hermes/cache/scratch'
$scratch = Join-Path $baseScratch ('pagefile-policy-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $script:transactionDirectory = Join-Path $scratch 'pending'
    $writeDeps = @{} + $deps
    $writeDeps.WriteCim = {
        param($Instance, $Properties)
        $script:cimWrites++
        Check ($Instance.Name -ceq 'C:\pagefile.sys' -and @($Properties.Keys).Count -eq 2 -and
            $Properties.ContainsKey('InitialSize') -and $Properties.ContainsKey('MaximumSize')) 'Only sizes on the exact existing setting are written'
        $prepared = [IO.File]::ReadAllText((Join-Path $script:transactionDirectory 'Arkuzo-Pagefile-Requests.json')) | ConvertFrom-Json
        Check ($prepared.requests[-1].status -eq 'Prepared') 'Crash-safe request reservation is persisted before writing CIM'
        $Instance.InitialSize = $Properties.InitialSize; $Instance.MaximumSize = $Properties.MaximumSize
    }
    $s = Get-ArkuzoPagefileSnapshot -Dependencies $writeDeps
    $r = Invoke-ArkuzoPagefileManagement -Snapshot $s -Policy $p -SystemMemory $m -OwnsController $true -DataDirectory $script:transactionDirectory -Dependencies $writeDeps
    Check ($r.status -eq 'PendingReboot' -and $r.writeAttempted -and $r.changed -and $r.configurationPersisted -and $r.pendingReboot) 'Persisted settings report PendingReboot when live allocation has not increased'
    Check (-not $r.runtimeGrowthVerified -and -not $r.canSuppressRecovery -and -not $r.rebootInitiated) 'A persisted setting is not an immediate OOM fix and never disables recycling'
    Check ($script:cimWrites -eq 1 -and $script:fakeCim.Win32_PageFileUsage[0].AllocatedBaseSize -eq 4096) 'Exactly one existing file was changed, never created or made active by the helper'
    $audit = [IO.File]::ReadAllText($r.auditPath) | ConvertFrom-Json
    Check ($audit.oldConfiguration.settings[0].initialSizeMB -eq 4096 -and $audit.oldConfiguration.settings[0].maximumSizeMB -eq 4096 -and -not $audit.oldConfiguration.automaticManagedPagefile) 'Audit backup preserves the old full pagefile configuration'
    $journal = [IO.File]::ReadAllText($r.journalPath) | ConvertFrom-Json
    Check ($journal.bootId -eq $s.bootId -and @($journal.requests).Count -eq 1 -and $journal.requests[0].status -eq 'PendingReboot') 'Bounded per-boot request journal records the actual outcome'
    $r = Invoke-ArkuzoPagefileManagement -Snapshot (Get-ArkuzoPagefileSnapshot -Dependencies $writeDeps) -Policy $p -SystemMemory $m -OwnsController $true -DataDirectory $script:transactionDirectory -Dependencies $writeDeps
    Check ($r.status -eq 'PendingReboot' -and $script:cimWrites -eq 1) 'Next sample/restart does not repeat inactive configured growth'

    function Reset-PagefileFake {
        $script:fakeCim.Win32_ComputerSystem[0].AutomaticManagedPagefile=$false
        $script:fakeCim.Win32_PageFileSetting=@([pscustomobject]@{Name='C:\pagefile.sys';SettingID='fixed-C';InitialSize=4096;MaximumSize=4096})
        $script:fakeCim.Win32_PageFileUsage=@([pscustomobject]@{Name='C:\pagefile.sys';AllocatedBaseSize=4096;TempPageFile=$false})
        $script:fakeCim.Win32_LogicalDisk=@([pscustomobject]@{DeviceID='C:';DriveType=3;Size=[int64](200GB);FreeSpace=[int64](100GB);VolumeSerialNumber='TEST-0001';FileSystem='NTFS'})
    }
    Reset-PagefileFake
    $s=Get-ArkuzoPagefileSnapshot -Dependencies $deps
    $r=Invoke-ArkuzoPagefileManagement $s $p $m -OwnsController 1 -DataDirectory (Join-Path $scratch 'owner') -Dependencies $deps
    Check ($r.status -eq 'NotController' -and -not $r.writeAttempted) 'Controller ownership also requires a literal boolean, not a numeric value'

    # Persisted readback must bind the same volume as well as the same WMI setting.
    Reset-PagefileFake
    $swapDeps=@{}+$deps
    $swapDeps.WriteCim={param($Instance,$Properties) $script:cimWrites++; $Instance.InitialSize=$Properties.InitialSize; $Instance.MaximumSize=$Properties.MaximumSize; $script:fakeCim.Win32_LogicalDisk[0].VolumeSerialNumber='REPLACED'}
    $s=Get-ArkuzoPagefileSnapshot -Dependencies $swapDeps
    $r=Invoke-ArkuzoPagefileManagement $s $p $m -OwnsController $true -DataDirectory (Join-Path $scratch 'readback-volume') -Dependencies $swapDeps
    Check ($r.status -eq 'ReadbackFailed' -and -not $r.configurationPersisted -and $r.error.stage -eq 'Readback') 'A changed volume identity after a write fails persisted readback verification'

    # Races between the supplied snapshot and the immediate pre-write read fail closed.
    $mutations = [ordered]@{
        setting_identity={ $script:fakeCim.Win32_PageFileSetting[0].SettingID='changed' }
        setting_size={ $script:fakeCim.Win32_PageFileSetting[0].InitialSize=5000; $script:fakeCim.Win32_PageFileSetting[0].MaximumSize=5000 }
        volume_identity={ $script:fakeCim.Win32_LogicalDisk[0].VolumeSerialNumber='changed' }
        free_space={ $script:fakeCim.Win32_LogicalDisk[0].FreeSpace=20GB }
        automatic_management={ $script:fakeCim.Win32_ComputerSystem[0].AutomaticManagedPagefile=$true }
        missing_target={ $script:fakeCim.Win32_PageFileSetting=@() }
    }
    foreach ($name in $mutations.Keys) {
        Reset-PagefileFake; $s=Get-ArkuzoPagefileSnapshot -Dependencies $deps; $beforeWrites=$script:cimWrites
        & $mutations[$name]
        $r=Invoke-ArkuzoPagefileManagement $s $p $m -OwnsController $true -DataDirectory (Join-Path $scratch ('race-'+$name)) -Dependencies $deps
        Check ($r.status -eq 'RaceDetected' -and -not $r.writeAttempted -and $script:cimWrites -eq $beforeWrites -and $r.error.stage -eq 'PreWrite') "Pre-write race ($name) makes zero CIM writes and exposes failure"
    }
    Reset-PagefileFake; $s=Get-ArkuzoPagefileSnapshot -Dependencies $deps; $beforeWrites=$script:cimWrites
    $r=Invoke-ArkuzoPagefileManagement $s $p $m -OwnsController $true -DataDirectory (Join-Path $scratch 'race-admin') -Dependencies $noAdmin
    Check ($r.status -eq 'RaceDetected' -and $script:cimWrites -eq $beforeWrites) 'Administrator status is rechecked immediately before writing'

    # Fresh free space may change safely, but must still pay for the full request.
    Reset-PagefileFake; $s=Get-ArkuzoPagefileSnapshot -Dependencies $deps
    $script:fakeCim.Win32_LogicalDisk[0].FreeSpace=90GB
    $okDeps=@{}+$deps
    $okDeps.WriteCim={param($Instance,$Properties) $script:cimWrites++; $Instance.InitialSize=$Properties.InitialSize; $Instance.MaximumSize=$Properties.MaximumSize}
    $r=Invoke-ArkuzoPagefileManagement $s $p $m -OwnsController $true -DataDirectory (Join-Path $scratch 'fresh-space') -Dependencies $okDeps
    Check ($r.status -eq 'PendingReboot') 'A safe fresh free-space decrease is validated rather than requiring stale byte equality'

    Reset-PagefileFake; $noopDeps=@{}+$deps
    $noopDeps.WriteCim={param($Instance,$Properties) $script:cimWrites++}
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $noopDeps) $p $m -OwnsController $true -DataDirectory (Join-Path $scratch 'readback-mismatch') -Dependencies $noopDeps
    Check ($r.status -eq 'ReadbackFailed' -and $r.writeAttempted -and -not $r.configurationPersisted -and $r.error.message -match 'did not match') 'Success from a CIM writer is not enough; persisted exact readback is required'

    Reset-PagefileFake; $failureDeps=@{}+$deps
    $failureDeps.WriteCim={param($Instance,$Properties) $script:cimWrites++; throw 'simulated access denied'}
    $retryPath=Join-Path $scratch 'write-failure'
    $retryPolicy=Get-ArkuzoPagefilePolicy -Input @{enabled=$true;max_requests_per_boot=2;max_boot_growth_mb=8192}
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $failureDeps) $retryPolicy $m -OwnsController $true -DataDirectory $retryPath -Dependencies $failureDeps
    Check ($r.status -eq 'WriteFailed' -and $r.error.message -match 'simulated access denied' -and $r.writeAttempted) 'CIM write failures are structured and not swallowed'
    $failedJournal=[IO.File]::ReadAllText($r.journalPath)|ConvertFrom-Json
    Check ($failedJournal.requests[0].status -eq 'WriteFailed') 'Failed writes retain the per-boot reservation and error in the journal'
    $beforeWrites=$script:cimWrites
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $failureDeps) $retryPolicy $m -OwnsController $true -DataDirectory $retryPath -Dependencies $failureDeps
    Check ($r.status -eq 'Cooldown' -and $script:cimWrites -eq $beforeWrites) 'A monitor restart cannot bypass persisted cooldown after a failure'
    $clockDeps=@{}+$failureDeps; $clockDeps.UtcNow={return [datetime]'2026-10-07T11:00:00Z'}
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $clockDeps) $retryPolicy $m -OwnsController $true -DataDirectory $retryPath -Dependencies $clockDeps
    Check ($r.status -eq 'Cooldown' -and $script:cimWrites -eq $beforeWrites) 'Clock reversal cannot reset persisted cooldown'
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $failureDeps) $p $m -OwnsController $true -DataDirectory $retryPath -Dependencies $failureDeps
    Check ($r.status -eq 'BootBudgetReached' -and $script:cimWrites -eq $beforeWrites) 'Per-boot request cap survives restart or a stricter policy'
    [IO.File]::WriteAllText((Join-Path $retryPath 'Arkuzo-Pagefile-Requests.json'),'{invalid')
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $failureDeps) $retryPolicy $m -OwnsController $true -DataDirectory $retryPath -Dependencies $failureDeps
    Check ($r.status -eq 'JournalFailed' -and $r.error.stage -eq 'JournalRead' -and $script:cimWrites -eq $beforeWrites) 'Corrupt persistence fails closed instead of clearing request history'

    # Only fresh runtime allocation AND native commit growth can claim Active.
    foreach ($confirmation in @('allocation-only','commit-only','both','telemetry-failure')) {
        Reset-PagefileFake; $confirmDeps=@{}+$okDeps; $script:confirmationMode=$confirmation
        $confirmDeps.WriteCim={
            param($Instance,$Properties)
            $script:cimWrites++; $Instance.InitialSize=$Properties.InitialSize; $Instance.MaximumSize=$Properties.MaximumSize
            if ($script:confirmationMode -in @('allocation-only','both')) {$script:fakeCim.Win32_PageFileUsage[0].AllocatedBaseSize=$Properties.MaximumSize}
        }
        $confirmDeps.ReadMemory={
            $limit=10000
            if ($script:fakeCim.Win32_PageFileSetting[0].MaximumSize -gt 4096) {
                if ($script:confirmationMode -eq 'telemetry-failure') {throw 'simulated native telemetry failure'}
                if ($script:confirmationMode -in @('commit-only','both')) {$limit=14096}
            }
            return [pscustomobject]@{commitUsedMB=($limit*0.8);commitLimitMB=$limit;commitPercent=80}
        }
        $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $confirmDeps) $p $m -OwnsController $true -DataDirectory (Join-Path $scratch $confirmation) -Dependencies $confirmDeps
        if ($confirmation -eq 'both') {Check ($r.status -eq 'Active' -and $r.runtimeGrowthVerified -and -not $r.pendingReboot) 'Both independent fresh confirmations establish active allocation growth'}
        elseif ($confirmation -eq 'telemetry-failure') {Check ($r.status -eq 'RuntimeVerificationFailed' -and $r.configurationPersisted -and $r.pendingReboot -and $r.error.message -match 'native telemetry failure') 'Telemetry errors cannot claim runtime relief and must be surfaced'}
        else {Check ($r.status -eq 'PendingReboot' -and -not $r.runtimeGrowthVerified) "$confirmation cannot establish active pagefile/commit growth"}
        Check (-not $r.canSuppressRecovery -and -not $r.rebootInitiated) 'Even verified allocation growth never promises OOM prevention or disables recovery'
    }
    Reset-PagefileFake
    $script:fakeCim.Win32_PageFileSetting += [pscustomobject]@{Name='D:\pagefile.sys';SettingID='fixed-D';InitialSize=4096;MaximumSize=4096}
    $script:fakeCim.Win32_PageFileUsage += [pscustomobject]@{Name='D:\pagefile.sys';AllocatedBaseSize=4096;TempPageFile=$false}
    $script:fakeCim.Win32_LogicalDisk += [pscustomobject]@{DeviceID='D:';DriveType=3;Size=[int64](200GB);FreeSpace=[int64](100GB);VolumeSerialNumber='TEST-0002';FileSystem='NTFS'}
    $totalPolicy=Get-ArkuzoPagefilePolicy -Input @{enabled=$true;max_file_mb=8192;max_total_mb=9000}
    $s=Get-ArkuzoPagefileSnapshot -Dependencies $okDeps
    $d=Get-ArkuzoPagefileGrowthDecision $s $totalPolicy $m
    Check ($d.eligible -and $d.growthMB -eq (9000-4096-4096)) 'Total ceiling includes every existing configured pagefile, not only the chosen file'
    $beforeWrites=$script:cimWrites
    $r=Invoke-ArkuzoPagefileManagement $s $totalPolicy $m -OwnsController $true -DataDirectory (Join-Path $scratch 'multi-file') -Dependencies $okDeps
    Check ($r.status -eq 'PendingReboot' -and $script:cimWrites -eq ($beforeWrites+1) -and $script:fakeCim.Win32_PageFileSetting[1].MaximumSize -eq 4096) 'A request touches only one existing file even when multiple fixed files are eligible'

    Reset-PagefileFake
    $blockedPath=Join-Path $scratch 'no-side-effects'
    $s=Get-ArkuzoPagefileSnapshot -Dependencies $deps; $beforeWrites=$script:cimWrites
    $r=Invoke-ArkuzoPagefileManagement $s $p $m -MonitorOnly -OwnsController $true -DataDirectory $blockedPath -Dependencies $deps
    Check (-not [IO.Directory]::Exists($blockedPath) -and $script:cimWrites -eq $beforeWrites) 'MonitorOnly does not even create a journal/data directory'
    $script:fakeCim.Win32_LogicalDisk[0].FreeSpace=10GB
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m -OwnsController $true -DataDirectory $blockedPath -Dependencies $deps
    Check ($r.status -eq 'LowDiskSpace' -and -not [IO.Directory]::Exists($blockedPath) -and $script:cimWrites -eq $beforeWrites) 'Low-space refusal does not write settings or persistence'
    Reset-PagefileFake
    $ceiling=Get-ArkuzoPagefilePolicy -Input @{enabled=$true;max_file_mb=4096;max_total_mb=4096}
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $ceiling $m -OwnsController $true -DataDirectory $blockedPath -Dependencies $deps
    Check ($r.status -eq 'AtCeiling' -and -not [IO.Directory]::Exists($blockedPath) -and $script:cimWrites -eq $beforeWrites) 'At-ceiling refusal does not write settings or persistence'
    $script:fakeCim.Win32_PageFileSetting=@(); $script:fakeCim.Win32_PageFileUsage=@()
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m -OwnsController $true -DataDirectory $blockedPath -Dependencies $deps
    Check ($r.status -eq 'UnsupportedLayout' -and $script:cimWrites -eq $beforeWrites) 'Absent files are never created'
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $badDeps) $p $m -OwnsController $true -DataDirectory $blockedPath -Dependencies $badDeps
    Check ($r.status -eq 'SnapshotUnavailable' -and $r.error.message -match 'simulated CIM read failure') 'Snapshot read failure reaches the structured management result'

    Reset-PagefileFake
    $auditFailPath=Join-Path $scratch 'audit-failure'
    [IO.Directory]::CreateDirectory((Join-Path $auditFailPath 'Arkuzo-Pagefile-Backup-1.json'))|Out-Null
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m -OwnsController $true -DataDirectory $auditFailPath -Dependencies $deps
    Check ($r.status -eq 'AuditFailed' -and $r.error.stage -eq 'AuditBackup' -and $script:cimWrites -eq $beforeWrites) 'An unavailable audit backup prohibits the settings write'
    $journalFailPath=Join-Path $scratch 'journal-failure'
    [IO.Directory]::CreateDirectory((Join-Path $journalFailPath 'Arkuzo-Pagefile-Requests.json'))|Out-Null
    $r=Invoke-ArkuzoPagefileManagement (Get-ArkuzoPagefileSnapshot -Dependencies $deps) $p $m -OwnsController $true -DataDirectory $journalFailPath -Dependencies $deps
    Check ($r.status -eq 'JournalFailed' -and -not $r.writeAttempted -and $script:cimWrites -eq $beforeWrites) 'Failure to persist the prepared journal prohibits the settings write'
} finally { [IO.Directory]::Delete($scratch, $true) }
Write-Output ("PASS: pagefile bounded management ({0} assertions)" -f $script:pagefileAssertions)
