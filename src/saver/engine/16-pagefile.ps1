# Optional pagefile helpers. These functions never enable Windows pagefile management
# or reboot the host; the caller must explicitly opt in and retain recovery policy.
function Get-ArkuzoPagefileValue {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}
function Test-ArkuzoPagefileNumber {
    param($Value, [double]$Minimum, [double]$Maximum, [switch]$Integer)
    if ($Value -is [bool] -or $Value -is [string] -or $null -eq $Value) { return $false }
    if ($Value -isnot [ValueType]) { return $false }
    try {
        $n = [double]$Value
        return (-not [double]::IsNaN($n) -and -not [double]::IsInfinity($n) -and
            $n -ge $Minimum -and $n -le $Maximum -and (-not $Integer -or [math]::Floor($n) -eq $n))
    } catch { return $false }
}
function Get-ArkuzoPagefilePolicy {
    # Alias avoids PowerShell's automatic $input enumerator. Input is the pagefile subsection.
    param([Alias('Input')]$Configuration = $null, $PressurePercent = 88)
    $values = [ordered]@{
        enabled = $false; growth_step_mb = 4096; max_file_mb = 163840; max_total_mb = 163840
        reserve_free_bytes = [int64]16106127360; reserve_free_percent = 10
        trigger_percent = 80; cooldown_sec = 3600; max_requests_per_boot = 1; max_boot_growth_mb = 4096
    }
    $errors = New-Object 'Collections.Generic.List[string]'
    if ($null -ne $Configuration) {
        if ($Configuration -is [Collections.IDictionary]) { $keys = @($Configuration.Keys) }
        elseif ($Configuration -is [pscustomobject]) { $keys = @($Configuration.PSObject.Properties.Name) }
        else { $keys = @(); $errors.Add('Input must be a pagefile configuration object.') }
        foreach ($key in $keys) {
            if (-not $values.Contains([string]$key)) { $errors.Add("Unknown pagefile option: $key"); continue }
            $values[$key] = Get-ArkuzoPagefileValue $Configuration ([string]$key)
        }
    }
    if ($values.enabled -isnot [bool]) { $errors.Add('enabled must be a literal boolean.') }
    $bounds = @{
        growth_step_mb = @(1,8192); max_file_mb = @(1,163840); max_total_mb = @(1,262144)
        reserve_free_bytes = @([int64]1048576,[int64]1099511627776)
        cooldown_sec = @(60,86400); max_requests_per_boot = @(1,4); max_boot_growth_mb = @(1,32768)
    }
    foreach ($key in $bounds.Keys) {
        if (-not (Test-ArkuzoPagefileNumber $values[$key] $bounds[$key][0] $bounds[$key][1] -Integer)) {
            $errors.Add("$key must be an integer in [$($bounds[$key][0]), $($bounds[$key][1])].")
        }
    }
    if (-not (Test-ArkuzoPagefileNumber $values.reserve_free_percent 1 50)) { $errors.Add('reserve_free_percent must be in [1, 50].') }
    if (-not (Test-ArkuzoPagefileNumber $PressurePercent 2 99)) { $errors.Add('PressurePercent must be in [2, 99].') }
    if (-not (Test-ArkuzoPagefileNumber $values.trigger_percent 1 98)) { $errors.Add('trigger_percent must be in [1, 98].') }
    if ((Test-ArkuzoPagefileNumber $values.max_total_mb 1 262144 -Integer) -and
        (Test-ArkuzoPagefileNumber $values.max_file_mb 1 163840 -Integer) -and $values.max_total_mb -lt $values.max_file_mb) {
        $errors.Add('max_total_mb must be at least max_file_mb.')
    }
    if ((Test-ArkuzoPagefileNumber $values.trigger_percent 1 98) -and
        (Test-ArkuzoPagefileNumber $PressurePercent 2 99) -and $values.trigger_percent -ge $PressurePercent) {
        $errors.Add('trigger_percent must precede PressurePercent.')
    }
    $values.enabled = ($errors.Count -eq 0 -and $values.enabled -is [bool] -and $values.enabled)
    $values['pressure_percent'] = $PressurePercent
    $values['valid'] = ($errors.Count -eq 0); $values['errors'] = @($errors.ToArray())
    return [pscustomobject]$values
}

function Get-ArkuzoPagefileUtcNow {
    param([hashtable]$Dependencies = @{})
    $value = if ($Dependencies.ContainsKey('UtcNow')) { & $Dependencies.UtcNow } else { [datetime]::UtcNow }
    if ($value -isnot [datetime]) { throw 'UtcNow seam must return one DateTime.' }
    return $value.ToUniversalTime()
}
function Test-ArkuzoPagefileAdministrator {
    param([hashtable]$Dependencies = @{})
    if ($Dependencies.ContainsKey('IsAdministrator')) { $value = & $Dependencies.IsAdministrator }
    else {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            $value = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } finally { $identity.Dispose() }
    }
    if ($value -isnot [bool]) { throw 'Administrator check must return one literal boolean.' }
    return $value
}
function Read-ArkuzoPagefileCim {
    param([string]$ClassName, [hashtable]$Dependencies = @{})
    if ($Dependencies.ContainsKey('ReadCim')) { return (& $Dependencies.ReadCim $ClassName) }
    return (Get-CimInstance -Namespace 'root/cimv2' -ClassName $ClassName -ErrorAction Stop)
}
function Get-ArkuzoPagefileSnapshot {
    # Read only. Instance is retained solely for updating the exact freshly re-read setting.
    param([hashtable]$Dependencies = @{})
    $snapshot = [pscustomobject]@{
        available = $false; capturedUtc = $null; bootId = $null; computerName = $null
        automaticManagedPagefile = $null; isAdministrator = $false
        settings = @(); usage = @(); drives = @(); error = $null
    }
    try {
        $snapshot.capturedUtc = (Get-ArkuzoPagefileUtcNow $Dependencies).ToString('o')
        $computers = @(Read-ArkuzoPagefileCim 'Win32_ComputerSystem' $Dependencies)
        $systems = @(Read-ArkuzoPagefileCim 'Win32_OperatingSystem' $Dependencies)
        if ($computers.Count -ne 1 -or $systems.Count -ne 1 -or
            $computers[0].AutomaticManagedPagefile -isnot [bool] -or
            [string]::IsNullOrWhiteSpace([string]$computers[0].Name) -or
            $systems[0].LastBootUpTime -isnot [datetime]) { throw 'Missing or ambiguous computer/boot/automatic-management identity.' }
        $snapshot.computerName = [string]$computers[0].Name
        $snapshot.bootId = $snapshot.computerName + ':' + $systems[0].LastBootUpTime.ToUniversalTime().Ticks
        $snapshot.automaticManagedPagefile = $computers[0].AutomaticManagedPagefile
        $snapshot.isAdministrator = Test-ArkuzoPagefileAdministrator $Dependencies
        $snapshot.settings = @(foreach ($row in @(Read-ArkuzoPagefileCim 'Win32_PageFileSetting' $Dependencies)) {
            $class = 'Win32_PageFileSetting'; $namespace = 'root/cimv2'; $server = $snapshot.computerName
            if ($null -ne $row.CimSystemProperties) {
                $class = [string]$row.CimSystemProperties.ClassName
                $namespace = [string]$row.CimSystemProperties.Namespace
                $server = [string]$row.CimSystemProperties.ServerName
            }
            [pscustomobject]@{
                name = $row.Name; settingId = $row.SettingID; initialSizeMB = $row.InitialSize; maximumSizeMB = $row.MaximumSize
                cimClass = $class; cimNamespace = $namespace; cimServer = $server; instance = $row
            }
        })
        $snapshot.usage = @(foreach ($row in @(Read-ArkuzoPagefileCim 'Win32_PageFileUsage' $Dependencies)) {
            [pscustomobject]@{name=$row.Name; allocatedMB=$row.AllocatedBaseSize; temporary=$row.TempPageFile}
        })
        $snapshot.drives = @(foreach ($row in @(Read-ArkuzoPagefileCim 'Win32_LogicalDisk' $Dependencies)) {
            [pscustomobject]@{
                deviceId=$row.DeviceID; driveType=$row.DriveType; sizeBytes=$row.Size; freeBytes=$row.FreeSpace
                volumeSerial=$row.VolumeSerialNumber; fileSystem=$row.FileSystem
            }
        })
        if ($snapshot.settings.Count -gt 16 -or $snapshot.usage.Count -gt 16 -or $snapshot.drives.Count -gt 26) { throw 'Snapshot exceeds bounded local pagefile/drive inventory.' }
        $snapshot.available = $true
    } catch {
        $snapshot.error = [pscustomobject]@{stage='SnapshotRead';type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
    }
    return $snapshot
}

function Get-ArkuzoPagefileGrowthDecision {
    # Pure decision: only manually fixed, already active root pagefile.sys files qualify.
    param($Snapshot, $Policy, $SystemMemory)
    $decision = [pscustomobject]@{
        eligible=$false; status='InvalidPolicy'; reason='Pagefile policy is missing or invalid.'; validationErrors=@()
        targetName=$null; target=$null; drive=$null; oldInitialSizeMB=0; oldMaximumSizeMB=0
        oldAllocatedMB=0; newInitialSizeMB=0; newMaximumSizeMB=0; growthMB=0
        totalConfiguredMB=0; reserveBytes=[int64]0; diskChargeBytes=[int64]0
    }
    if ($null -eq $Policy -or $Policy.valid -isnot [bool] -or -not $Policy.valid) {
        $decision.validationErrors=@(Get-ArkuzoPagefileValue $Policy 'errors' @()); return $decision
    }
    # Revalidate numeric bounds even if a caller changed a previously validated object.
    $inputValues = @{}
    foreach ($key in @('enabled','growth_step_mb','max_file_mb','max_total_mb','reserve_free_bytes',
        'reserve_free_percent','trigger_percent','cooldown_sec','max_requests_per_boot','max_boot_growth_mb')) {
        $inputValues[$key] = Get-ArkuzoPagefileValue $Policy $key
    }
    $p = Get-ArkuzoPagefilePolicy -Input $inputValues -PressurePercent $Policy.pressure_percent
    if (-not $p.valid) { $decision.validationErrors=@($p.errors); return $decision }
    if (-not $p.enabled) { $decision.status='Disabled'; $decision.reason='Pagefile management is opt-in and disabled.'; return $decision }
    if ($null -eq $Snapshot -or $Snapshot.available -isnot [bool] -or -not $Snapshot.available -or
        $Snapshot.automaticManagedPagefile -isnot [bool] -or [string]::IsNullOrWhiteSpace([string]$Snapshot.bootId)) {
        $decision.status='SnapshotUnavailable'; $decision.reason='Pagefile/boot identity could not be read safely.'; return $decision
    }
    $settings = @($Snapshot.settings); $usage = @($Snapshot.usage)
    if ($Snapshot.automaticManagedPagefile -or @($settings | Where-Object {
        (Test-ArkuzoPagefileNumber $_.initialSizeMB 0 0 -Integer) -and
        (Test-ArkuzoPagefileNumber $_.maximumSizeMB 0 0 -Integer)
    }).Count -gt 0) {
        $decision.status='WindowsManaged'; $decision.reason='Windows manages pagefile growth; no configuration writes are permitted.'; return $decision
    }
    if ($Snapshot.isAdministrator -isnot [bool] -or -not $Snapshot.isAdministrator) {
        $decision.status='NotAdministrator'; $decision.reason='An elevated administrator token is required.'; return $decision
    }
    if (-not (Test-ArkuzoPagefileNumber $SystemMemory.commitUsedMB 0 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $SystemMemory.commitLimitMB 1 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $SystemMemory.commitPercent 0 100) -or
        [math]::Abs((100.0 * $SystemMemory.commitUsedMB / $SystemMemory.commitLimitMB) - $SystemMemory.commitPercent) -gt 0.2) {
        $decision.status='MemoryUnavailable'; $decision.reason='Fresh consistent OS commit telemetry is required.'; return $decision
    }
    if ($SystemMemory.commitPercent -lt $p.trigger_percent) {
        $decision.status='BelowTrigger'; $decision.reason='OS commit is below the early pagefile trigger.'; return $decision
    }
    $decision.status='UnsupportedLayout'; $decision.reason='Only unambiguous existing, active, fixed-size local pagefiles are supported.'
    if ($settings.Count -lt 1 -or $settings.Count -gt 16 -or $usage.Count -ne $settings.Count) { return $decision }
    $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total = [int64]0
    foreach ($file in $settings) {
        if ($file.name -isnot [string] -or $file.name -notmatch '^[A-Za-z]:\\pagefile\.sys$' -or -not $names.Add($file.name) -or
            $file.cimClass -ine 'Win32_PageFileSetting' -or ([string]$file.cimNamespace).Replace('\','/').Trim('/') -ine 'root/cimv2' -or
            -not (Test-ArkuzoPagefileNumber $file.initialSizeMB 1 4294967295 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $file.maximumSizeMB 1 4294967295 -Integer) -or $file.initialSizeMB -ne $file.maximumSizeMB) { return $decision }
        if ($file.cimServer -and $file.cimServer -ine $Snapshot.computerName -and $file.cimServer -ine 'localhost' -and $file.cimServer -ne '.') { return $decision }
        $active = @($usage | Where-Object { $_.name -ieq $file.name })
        if ($active.Count -ne 1 -or $active[0].temporary -isnot [bool] -or $active[0].temporary -or
            -not (Test-ArkuzoPagefileNumber $active[0].allocatedMB 1 4294967295 -Integer)) { return $decision }
        if ($active[0].allocatedMB -lt $file.initialSizeMB) {
            $decision.status='PendingReboot'; $decision.reason='Configured capacity is not active; another growth request is unsafe.'; return $decision
        }
        if ($active[0].allocatedMB -gt $file.maximumSizeMB) {
            $decision.status='RuntimeMismatch'; $decision.reason='Active allocation exceeds fixed configuration; never reduce it.'; return $decision
        }
        $total += [int64]$file.maximumSizeMB
    }
    $decision.totalConfiguredMB = $total
    $decision.status='AtCeiling'; $decision.reason='Per-file or total configured capacity is already at its ceiling.'
    foreach ($file in @($settings | Sort-Object name)) {
        $growth = [int64][math]::Min([int64]$p.growth_step_mb, [math]::Min([int64]$p.max_boot_growth_mb,
            [math]::Min([int64]($p.max_file_mb - $file.maximumSizeMB), [int64]($p.max_total_mb - $total))))
        if ($growth -lt 1) { continue }
        $drives = @($Snapshot.drives | Where-Object { $_.deviceId -ieq $file.name.Substring(0,2) })
        if ($drives.Count -ne 1 -or $drives[0].driveType -ne 3 -or
            [string]::IsNullOrWhiteSpace([string]$drives[0].volumeSerial) -or
            [string]::IsNullOrWhiteSpace([string]$drives[0].fileSystem) -or
            -not (Test-ArkuzoPagefileNumber $drives[0].sizeBytes 1 9007199254740991 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $drives[0].freeBytes 0 $drives[0].sizeBytes -Integer)) {
            $decision.status='UnknownDrive'; $decision.reason='Target must map to one known fixed local volume with capacity/free-space identity.'; return $decision
        }
        $drive = $drives[0]
        $reserve = [int64][math]::Max([int64]$p.reserve_free_bytes, [int64][math]::Ceiling($drive.sizeBytes * $p.reserve_free_percent / 100.0))
        $diskGrowthMB = [int64][math]::Floor(($drive.freeBytes - $reserve) / 1MB)
        $growth = [int64][math]::Min([int64]$growth, [int64]$diskGrowthMB)
        if ($growth -lt 1) { $decision.status='LowDiskSpace'; $decision.reason='Growth would breach absolute or percentage free-disk reserve.'; continue }
        $decision.eligible=$true; $decision.status='Eligible'; $decision.reason='One existing fixed pagefile can grow within all bounds.'
        $decision.targetName=$file.name; $decision.target=$file; $decision.drive=$drive
        $decision.oldInitialSizeMB=[int64]$file.initialSizeMB; $decision.oldMaximumSizeMB=[int64]$file.maximumSizeMB
        $decision.oldAllocatedMB=[int64]$file.maximumSizeMB; $decision.growthMB=$growth
        $decision.newInitialSizeMB=[int64]$file.initialSizeMB + $growth
        $decision.newMaximumSizeMB=[int64]$file.maximumSizeMB + $growth
        $decision.reserveBytes=$reserve; $decision.diskChargeBytes=[int64]$growth * 1MB
        return $decision
    }
    return $decision
}

function Get-ArkuzoPagefileProvisioningDecision {
    param($Snapshot, $Policy, [string]$TargetDriveLetter = 'C')
    $decision = [pscustomobject]@{
        eligible = $false; status = 'InvalidPolicy'; reason = $null
        targetDrive = $TargetDriveLetter; targetName = "$($TargetDriveLetter):\pagefile.sys"
        targetSizeMB = 0; diskGrowthMB = 0; freeSpaceAfterMB = 0; error = $null
    }
    if ($null -eq $Policy -or -not $Policy.valid) { $decision.reason = 'Valid pagefile policy is required.'; return $decision }
    if (-not $Policy.enabled) { $decision.status = 'Disabled'; $decision.reason = 'Pagefile management is opt-in and disabled.'; return $decision }
    if ($null -eq $Snapshot -or -not $Snapshot.available) { $decision.status = 'SnapshotUnavailable'; $decision.reason = 'Pagefile snapshot is unavailable.'; return $decision }
    if (-not $Snapshot.isAdministrator) { $decision.status = 'NotAdministrator'; $decision.reason = 'Elevated administrator token is required.'; return $decision }

    $targetSize = [int64]$Policy.max_file_mb
    if ($targetSize -lt 1024 -or $targetSize -gt 163840) { $decision.reason = 'Target size out of bounds.'; return $decision }
    $decision.targetSizeMB = $targetSize

    # Match target drive
    $driveId = "$($TargetDriveLetter):"
    $drive = @($Snapshot.drives | Where-Object { $_.deviceId -ceq $driveId }) | Select-Object -First 1
    if ($null -eq $drive -or $drive.driveType -ne 3 -or ($drive.fileSystem -cne 'NTFS' -and $drive.fileSystem -cne 'ReFS')) {
        $decision.status = 'UnsupportedDrive'; $decision.reason = 'Target drive must be a local fixed NTFS or ReFS volume.'; return $decision
    }

    # Check if already provisioned at or above target size
    $existing = @($Snapshot.settings | Where-Object { $_.name -like "$($TargetDriveLetter):\pagefile.sys" })
    if ($existing.Count -gt 0 -and -not $Snapshot.automaticManagedPagefile) {
        $currentMax = ($existing | Measure-Object -Property maximumSizeMB -Maximum).Maximum
        if ($currentMax -ge $targetSize) {
            $decision.status = 'AtOrAboveCeiling'; $decision.reason = 'Existing pagefile is already at or above target ceiling.'; return $decision
        }
    }

    # Calculate additional disk allocation needed
    $currentAllocatedMB = 0
    $usage = @($Snapshot.usage | Where-Object { $_.name -like "$($TargetDriveLetter):\pagefile.sys" })
    if ($usage.Count -gt 0) { $currentAllocatedMB = [int64]$usage[0].allocatedMB }
    elseif ($existing.Count -gt 0) { $currentAllocatedMB = [int64]$existing[0].maximumSizeMB }

    $additionalGrowthMB = [Math]::Max([int64]0, [int64]($targetSize - $currentAllocatedMB))
    $decision.diskGrowthMB = $additionalGrowthMB

    $reserveBytes = [int64][Math]::Max([int64]$Policy.reserve_free_bytes, [int64][Math]::Ceiling([double]$drive.sizeBytes * [double]$Policy.reserve_free_percent / 100.0))
    $freeAfterBytes = [int64]$drive.freeBytes - ($additionalGrowthMB * 1MB)
    $decision.freeSpaceAfterMB = [Math]::Round($freeAfterBytes / 1MB)

    if ($freeAfterBytes -lt $reserveBytes) {
        $decision.status = 'LowDiskSpace'
        $decision.reason = "Provisioning requires $additionalGrowthMB MB growth which would breach the $($Policy.reserve_free_percent)%/15GB disk reserve."
        return $decision
    }

    $decision.eligible = $true
    $decision.status = 'Eligible'
    $decision.reason = "Target drive has sufficient capacity to provision fixed $targetSize MB pagefile."
    return $decision
}

function Invoke-ArkuzoPagefileProvisioning {
    param($Snapshot, $Policy, [string]$TargetDriveLetter = 'C', [switch]$MonitorOnly, [hashtable]$Dependencies = @{})
    $decision = Get-ArkuzoPagefileProvisioningDecision -Snapshot $Snapshot -Policy $Policy -TargetDriveLetter $TargetDriveLetter
    $result = [pscustomobject]@{
        status = $decision.status; reason = $decision.reason; decision = $decision
        writeAttempted = $false; changed = $false; pendingReboot = $false
        rebootInitiated = $false; targetName = $decision.targetName; targetSizeMB = $decision.targetSizeMB
        error = $null
    }
    if (-not $decision.eligible) { return $result }
    if ($MonitorOnly) {
        $result.status = 'MonitorOnly'; $result.reason = 'Monitor-only mode prohibits pagefile provisioning writes.'; return $result
    }

    $result.writeAttempted = $true
    try {
        if ($Dependencies.ContainsKey('SetProvisionedPagefile')) {
            & $Dependencies.SetProvisionedPagefile $decision.targetName ([uint32]$decision.targetSizeMB) $false
        } else {
            # 1. Update Registry first: PagingFiles multi-string
            $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
            $settingStr = "$($decision.targetName) $($decision.targetSizeMB) $($decision.targetSizeMB)"
            Set-ItemProperty -Path $regPath -Name 'PagingFiles' -Value @($settingStr) -ErrorAction Stop

            # 2. Update WMI Win32_PageFileSetting if exists or create
            try {
                $cimSettings = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*pagefile.sys" })
                if ($cimSettings.Count -gt 0) {
                    Set-CimInstance -InputObject $cimSettings[0] -Property @{
                        InitialSize = [uint32]$decision.targetSizeMB
                        MaximumSize = [uint32]$decision.targetSizeMB
                    } -ErrorAction SilentlyContinue | Out-Null
                }
            } catch { }

            # 3. Disable AutomaticManagedPagefile in WMI and Registry
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
                if ($cs) {
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction SilentlyContinue | Out-Null
                }
            } catch { }
            Set-ItemProperty -Path $regPath -Name 'AutomaticManagedPagefile' -Value 0 -ErrorAction SilentlyContinue
        }
        $result.changed = $true
        $result.pendingReboot = $true
        $result.status = 'PendingReboot'
        $result.reason = "Fixed pagefile of $($decision.targetSizeMB) MB provisioned. Windows requires a reboot for the size to take physical effect."
    } catch {
        $result.status = 'WriteFailed'
        $result.reason = "Pagefile provisioning write failed: $($_.Exception.Message)"
        $result.error = $_
        # Failsafe rollback: ensure AutomaticManagedPagefile remains enabled if setting failed
        try {
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'AutomaticManagedPagefile' -Value 1 -ErrorAction SilentlyContinue
        } catch { }
    }
    return $result
}

function New-ArkuzoPagefileManagementResult {
    param($Decision)
    return [pscustomobject]@{
        status=$Decision.status; reason=$Decision.reason; decision=$Decision
        changed=$false; writeAttempted=$false; configurationPersisted=$false
        pendingReboot=($Decision.status -eq 'PendingReboot'); runtimeGrowthVerified=$false
        canSuppressRecovery=$false; rebootInitiated=$false; targetName=$Decision.targetName
        growthMB=$Decision.growthMB; auditPath=$null; journalPath=$null; requestId=$null; error=$null
    }
}
function Update-ArkuzoPagefileStatus {
    # Observation is separate from recovery; no pagefile result disables the health guard.
    $status = [pscustomobject]@{
        status='Disabled'; reason='Pagefile management is opt-in and disabled.'
        writeAttempted=$false; changed=$false; configurationPersisted=$false
        pendingReboot=$false; runtimeGrowthVerified=$false; canSuppressRecovery=$false
        rebootInitiated=$false; targetName=$null; growthMB=0; error=$null
    }
    try {
        if ($null -ne $pagefilePolicy -and (-not $pagefilePolicy.valid -or $pagefilePolicy.enabled)) {
            if ($script:logFailed) { throw 'Audit logging is unavailable; pagefile requests are blocked.' }
            $snapshot = Get-ArkuzoPagefileSnapshot
            $result = Invoke-ArkuzoPagefileManagement -Snapshot $snapshot -Policy $pagefilePolicy `
                -SystemMemory $systemMemory -MonitorOnly:$MonitorOnly `
                -OwnsController $ownsControllerMutex -DataDirectory $DataDirectory
            foreach ($key in @('status','reason','writeAttempted','changed','configurationPersisted',
                'pendingReboot','runtimeGrowthVerified','targetName','growthMB','error')) {
                $status.$key = Get-ArkuzoPagefileValue $result $key $status.$key
            }
        }
    } catch {
        $status.status='ObservationFailed'; $status.reason='Pagefile observation failed; normal recovery remains enabled.'
        $status.error=[pscustomobject]@{stage='Observation';message=$_.Exception.Message}
    }
    $script:pagefileStatus=$status
    Write-Diagnostic 'PAGEFILE_STATUS' $status
    if ($status.status -notin @('Disabled','WindowsManaged','BelowTrigger','Active','MonitorOnly','NotController','Cooldown')) {
        $details = if ($null -ne $status.error) { ' '+$status.error.message } else { '' }
        Warn-Throttled 'pagefile-management' ('Pagefile '+$status.status+': '+$status.reason+$details)
    }
}
function Read-ArkuzoPagefileSystemMemory {
    param([hashtable]$Dependencies = @{})
    $memory = if ($Dependencies.ContainsKey('ReadMemory')) { & $Dependencies.ReadMemory } else { Get-ArkuzoSystemMemory }
    if (-not (Test-ArkuzoPagefileNumber $memory.commitLimitMB 1 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $memory.commitUsedMB 0 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $memory.commitPercent 0 100) -or
        [math]::Abs((100.0 * $memory.commitUsedMB / $memory.commitLimitMB) - $memory.commitPercent) -gt 0.2) {
        throw 'OS commit telemetry is missing or inconsistent.'
    }
    return $memory
}
function Get-ArkuzoPagefileConfigurationRecord {
    param($Snapshot)
    return [pscustomobject]@{
        bootId=$Snapshot.bootId; computerName=$Snapshot.computerName; automaticManagedPagefile=$Snapshot.automaticManagedPagefile
        settings=@(foreach ($file in @($Snapshot.settings | Sort-Object name)) {
            [pscustomobject]@{name=$file.name;settingId=$file.settingId;initialSizeMB=$file.initialSizeMB;maximumSizeMB=$file.maximumSizeMB;
                cimClass=$file.cimClass;cimNamespace=$file.cimNamespace;cimServer=$file.cimServer}
        })
    }
}
function Assert-ArkuzoPagefileSafePath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Pagefile journal requires an absolute local data path.' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Pagefile persistence refuses reparse-point paths.' }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($null -ne $parent) { $parent.FullName } else { $null }
    }
}
function Save-ArkuzoPagefileJson {
    param([string]$Path, $Data)
    Assert-ArkuzoPagefileSafePath $Path
    $text = $Data | ConvertTo-Json -Depth 10 -Compress
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    if ($bytes.Length -gt 65536) { throw 'Pagefile audit/journal exceeds its 64 KiB bound.' }
    $temp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream=$null
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
        if ([IO.File]::ReadAllText($Path) -cne $text) { throw 'Pagefile persistence readback did not match.' }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}
function Read-ArkuzoPagefileJournal {
    param([string]$Path, [string]$BootId)
    Assert-ArkuzoPagefileSafePath $Path
    $empty = [pscustomobject]@{schemaVersion=1;bootId=$BootId;requests=@()}
    if (-not [IO.File]::Exists($Path)) { return $empty }
    if ((New-Object IO.FileInfo($Path)).Length -gt 65536) { throw 'Pagefile journal exceeds its 64 KiB bound.' }
    $journal = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    if ($journal.schemaVersion -ne 1 -or $journal.bootId -isnot [string] -or -not $journal.bootId -or
        $null -eq $journal.PSObject.Properties['requests'] -or @($journal.requests).Count -gt 4) { throw 'Invalid pagefile journal schema or bounds.' }
    $ids = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($request in @($journal.requests)) {
        $time = [datetimeoffset]::MinValue
        if ($request.id -notmatch '^[a-f0-9]{32}$' -or -not $ids.Add([string]$request.id) -or
            -not [datetimeoffset]::TryParse([string]$request.requestedUtc, [ref]$time) -or
            $request.targetName -notmatch '^[A-Za-z]:\\pagefile\.sys$' -or
            $request.status -notin @('Prepared','PendingReboot','Active','WriteFailed','ReadbackFailed','RaceDetected','RuntimeVerificationFailed') -or
            -not (Test-ArkuzoPagefileNumber $request.growthMB 1 8192 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $request.oldAllocatedMB 1 4294967295 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $request.oldCommitLimitMB 1 1073741824) -or
            -not (Test-ArkuzoPagefileNumber $request.newMaximumSizeMB 1 4294967295 -Integer)) { throw 'Invalid pagefile request record; refusing to reset a consumed budget.' }
    }
    if ($journal.bootId -cne $BootId) { return $empty }
    return $journal
}
function Invoke-ArkuzoPagefileManagement {
    param($Snapshot, $Policy, $SystemMemory, [switch]$MonitorOnly,
        $OwnsController = $false, [string]$DataDirectory, [hashtable]$Dependencies = @{})
    $decision = Get-ArkuzoPagefileGrowthDecision $Snapshot $Policy $SystemMemory
    $result = New-ArkuzoPagefileManagementResult $decision
    if (-not $decision.eligible) {
        if ($decision.status -eq 'SnapshotUnavailable') { $result.error=$Snapshot.error }
        if ($decision.status -eq 'InvalidPolicy') {
            $message = if ($decision.validationErrors.Count) { $decision.validationErrors -join '; ' } else { $decision.reason }
            $result.error=[pscustomobject]@{stage='PolicyValidation';type='PolicyValidationError';message=$message}
        }
        return $result
    }
    if ($MonitorOnly) { $result.status='MonitorOnly'; $result.reason='Monitor-only operation prohibits pagefile writes.'; return $result }
    if ($OwnsController -isnot [bool] -or -not $OwnsController) { $result.status='NotController'; $result.reason='Only the singleton controller may request pagefile growth.'; return $result }
    $lock = $null; $journal = $null; $request = $null; $reservationPersisted = $false; $stage = 'JournalOpen'
    try {
        Assert-ArkuzoPagefileSafePath $DataDirectory
        [IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
        $result.journalPath = Join-Path $DataDirectory 'Arkuzo-Pagefile-Requests.json'
        $lockPath = Join-Path $DataDirectory 'Arkuzo-Pagefile-Requests.lock'
        Assert-ArkuzoPagefileSafePath $lockPath
        $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $now = Get-ArkuzoPagefileUtcNow $Dependencies
        $stage='JournalRead'; $journal = Read-ArkuzoPagefileJournal $result.journalPath $Snapshot.bootId
        $consumedMB = [int64]0
        foreach ($entry in @($journal.requests)) { $consumedMB += [int64]$entry.growthMB }
        if (@($journal.requests).Count -ge $Policy.max_requests_per_boot -or $consumedMB + $decision.growthMB -gt $Policy.max_boot_growth_mb) {
            $result.status='BootBudgetReached'; $result.reason='Per-boot request/growth budget is consumed; no further request.'; return $result
        }
        if (@($journal.requests).Count -gt 0) {
            $latest = $journal.requests[-1]
            $age = ($now - ([datetimeoffset]$latest.requestedUtc).UtcDateTime).TotalSeconds
            if ($age -lt 0 -or $age -lt $Policy.cooldown_sec) {
                $result.status='Cooldown'; $result.reason='Persisted pagefile cooldown (including clock reversal) prevents another request.'; return $result
            }
            if (@($journal.requests | Where-Object {$_.status -in @('Prepared','PendingReboot','ReadbackFailed','RuntimeVerificationFailed')}).Count) {
                $result.status='PriorRequestUnverified'; $result.reason='An earlier request has unverified activation/outcome; no repeat write.'; return $result
            }
        }
        $index = @($journal.requests).Count + 1
        $result.requestId = [guid]::NewGuid().ToString('N')
        $result.auditPath = Join-Path $DataDirectory ("Arkuzo-Pagefile-Backup-$index.json")
        $oldConfiguration = Get-ArkuzoPagefileConfigurationRecord $Snapshot
        $request = [pscustomobject]@{
            id=$result.requestId; requestedUtc=$now.ToString('o'); targetName=$decision.targetName; status='Prepared'
            growthMB=$decision.growthMB; oldAllocatedMB=$decision.oldAllocatedMB; oldCommitLimitMB=$SystemMemory.commitLimitMB
            newInitialSizeMB=$decision.newInitialSizeMB; newMaximumSizeMB=$decision.newMaximumSizeMB; error=$null
        }
        $stage='AuditBackup'
        Save-ArkuzoPagefileJson $result.auditPath ([pscustomobject]@{
            schemaVersion=1;requestedUtc=$request.requestedUtc;requestId=$request.id;oldConfiguration=$oldConfiguration
            oldRuntime=@($Snapshot.usage);oldDrives=@($Snapshot.drives);oldCommitLimitMB=$SystemMemory.commitLimitMB
            requestedSetting=[pscustomobject]@{name=$decision.targetName;initialSizeMB=$decision.newInitialSizeMB;maximumSizeMB=$decision.newMaximumSizeMB}
        })
        $stage='JournalReserve'; $journal.requests = @($journal.requests) + @($request)
        Save-ArkuzoPagefileJson $result.journalPath $journal; $reservationPersisted=$true
        # All audit/reservation IO precedes the final read. No configuration is ever
        # written from the caller's cached CIM object; re-read exact local identity.
        $stage='PreWrite'
        $fresh = Get-ArkuzoPagefileSnapshot -Dependencies $Dependencies
        if (-not $fresh.available) { throw ('Pre-write snapshot failed: ' + $fresh.error.message) }
        $beforeMemory = Read-ArkuzoPagefileSystemMemory $Dependencies
        $freshDecision = Get-ArkuzoPagefileGrowthDecision $fresh $Policy $beforeMemory
        $freshConfiguration = Get-ArkuzoPagefileConfigurationRecord $fresh
        $oldText = $oldConfiguration | ConvertTo-Json -Depth 8 -Compress
        $freshText = $freshConfiguration | ConvertTo-Json -Depth 8 -Compress
        if (-not $freshDecision.eligible -or $oldText -cne $freshText -or
            $freshDecision.targetName -cne $decision.targetName -or
            $freshDecision.newInitialSizeMB -ne $decision.newInitialSizeMB -or $freshDecision.newMaximumSizeMB -ne $decision.newMaximumSizeMB -or
            $freshDecision.drive.deviceId -cne $decision.drive.deviceId -or $freshDecision.drive.volumeSerial -cne $decision.drive.volumeSerial -or
            $freshDecision.drive.fileSystem -cne $decision.drive.fileSystem -or $freshDecision.drive.sizeBytes -ne $decision.drive.sizeBytes -or
            $freshDecision.drive.freeBytes - $decision.diskChargeBytes -lt $freshDecision.reserveBytes -or
            $beforeMemory.commitLimitMB -ne $request.oldCommitLimitMB) {
            throw 'Pagefile identity/configuration/boot/privilege/commit/free-space changed before writing; request refused.'
        }
        $stage='Write'; $result.writeAttempted=$true; $result.pendingReboot=$true
        $properties = @{InitialSize=[uint32]$decision.newInitialSizeMB;MaximumSize=[uint32]$decision.newMaximumSizeMB}
        if ($Dependencies.ContainsKey('WriteCim')) { & $Dependencies.WriteCim $freshDecision.target.instance $properties | Out-Null }
        else {
            if ($freshDecision.target.instance -isnot [Microsoft.Management.Infrastructure.CimInstance]) { throw 'Exact local CIM setting instance is required.' }
            Set-CimInstance -InputObject $freshDecision.target.instance -Property $properties -OperationTimeoutSec 10 -Confirm:$false -ErrorAction Stop | Out-Null
        }
        $stage='Readback'
        $after = Get-ArkuzoPagefileSnapshot -Dependencies $Dependencies
        if (-not $after.available) { throw ('Persisted CIM readback failed: ' + $after.error.message) }
        $expected = Get-ArkuzoPagefileConfigurationRecord $fresh
        foreach ($file in $expected.settings) {
            if ($file.name -ceq $decision.targetName) { $file.initialSizeMB=$properties.InitialSize; $file.maximumSizeMB=$properties.MaximumSize }
        }
        $actualText = Get-ArkuzoPagefileConfigurationRecord $after | ConvertTo-Json -Depth 8 -Compress
        if (($expected | ConvertTo-Json -Depth 8 -Compress) -cne $actualText) { throw 'Persisted CIM configuration did not match the exact requested setting/identity.' }
        $afterDrives = @($after.drives | Where-Object {$_.deviceId -ceq $freshDecision.drive.deviceId})
        if ($afterDrives.Count -ne 1 -or $afterDrives[0].volumeSerial -cne $freshDecision.drive.volumeSerial -or
            $afterDrives[0].fileSystem -cne $freshDecision.drive.fileSystem -or $afterDrives[0].sizeBytes -ne $freshDecision.drive.sizeBytes -or
            $afterDrives[0].driveType -ne 3 -or -not (Test-ArkuzoPagefileNumber $afterDrives[0].freeBytes 0 $afterDrives[0].sizeBytes -Integer)) {
            throw 'Persisted readback target volume identity/capacity is no longer exact.'
        }
        $result.changed=$true; $result.configurationPersisted=$true
        $result.status='PendingReboot'; $result.reason='Growth is persisted for startup, not confirmed active. Recovery stays enabled; no reboot is initiated.'
        $stage='RuntimeVerification'; $afterMemory = Read-ArkuzoPagefileSystemMemory $Dependencies
        $active = @($after.usage | Where-Object {$_.name -ceq $decision.targetName})
        if ($active.Count -eq 1 -and $active[0].temporary -is [bool] -and -not $active[0].temporary -and
            (Test-ArkuzoPagefileNumber $active[0].allocatedMB 1 4294967295 -Integer) -and
            $active[0].allocatedMB -ge $decision.newMaximumSizeMB -and $active[0].allocatedMB -gt $decision.oldAllocatedMB -and
            $afterMemory.commitLimitMB -gt $beforeMemory.commitLimitMB) {
            $result.status='Active'; $result.reason='Fresh runtime pagefile allocation and OS commit limit both increased. Recovery remains enabled.'
            $result.runtimeGrowthVerified=$true; $result.pendingReboot=$false
        }
        $request.status=$result.status; $stage='JournalOutcome'
        Save-ArkuzoPagefileJson $result.journalPath $journal
        return $result
    } catch {
        $failure = $_.Exception
        $result.status = switch ($stage) {
            'PreWrite' {'RaceDetected'}; 'Write' {'WriteFailed'}; 'Readback' {'ReadbackFailed'}
            'RuntimeVerification' {'RuntimeVerificationFailed'}; 'AuditBackup' {'AuditFailed'}; default {'JournalFailed'}
        }
        $result.reason='Pagefile request failed closed; configuration may require operator review if a write was attempted.'
        $result.error=[pscustomobject]@{stage=$stage;type=$failure.GetType().FullName;message=$failure.Message;persistenceMessage=$null}
        if ($reservationPersisted -and $stage -ne 'JournalOutcome') {
            $request.status=$result.status; $request.error=$result.error
            try { Save-ArkuzoPagefileJson $result.journalPath $journal }
            catch { $result.status='JournalFailed'; $result.error.persistenceMessage=$_.Exception.Message }
        }
        return $result
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

