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
function Assert([bool]$Ok, [string]$Message) { if (-not $Ok) { throw "FAIL: $Message" } }

Assert ([bool](Get-Command Get-ArkuzoPagefileProvisioningDecision -ErrorAction SilentlyContinue)) 'Provisioning decision helper must exist'
Assert ([bool](Get-Command Invoke-ArkuzoPagefileProvisioning -ErrorAction SilentlyContinue)) 'Provisioning executor helper must exist'

$policy = Get-ArkuzoPagefilePolicy -Input @{
    enabled = $true
    max_file_mb = 163840
    max_total_mb = 163840
    reserve_free_bytes = [int64]16106127360
    reserve_free_percent = 10
}

# Fixture 1: Standard WindowsManaged host with plenty of disk space (300 GB free on 500 GB drive)
$snapshot1 = [pscustomobject]@{
    available = $true; isAdministrator = $true; automaticManagedPagefile = $true
    bootId = 'PROV-FIXTURE-1'; computerName = 'TESTHOST'
    settings = @()
    usage = @([pscustomobject]@{ name = 'C:\pagefile.sys'; allocatedMB = 49152; temporary = $false })
    drives = @([pscustomobject]@{
        deviceId = 'C:'; driveType = 3; sizeBytes = [int64](500GB); freeBytes = [int64](300GB)
        volumeSerial = 'TEST-VOL-1'; fileSystem = 'NTFS'
    })
}

$dec1 = Get-ArkuzoPagefileProvisioningDecision -Snapshot $snapshot1 -Policy $policy -TargetDriveLetter 'C'
Assert ($dec1.eligible -and $dec1.targetSizeMB -eq 163840 -and $dec1.targetName -eq 'C:\pagefile.sys') 'Eligible for provisioning 160 GiB pagefile on C:'

# Fixture 2: Non-admin fails closed
$snapshotNonAdmin = [pscustomobject]@{
    available = $true; isAdministrator = $false; automaticManagedPagefile = $true
    bootId = 'PROV-FIXTURE-2'; computerName = 'TESTHOST'
    settings = @()
    usage = @([pscustomobject]@{ name = 'C:\pagefile.sys'; allocatedMB = 49152; temporary = $false })
    drives = @($snapshot1.drives)
}
$decNonAdmin = Get-ArkuzoPagefileProvisioningDecision -Snapshot $snapshotNonAdmin -Policy $policy -TargetDriveLetter 'C'
Assert (-not $decNonAdmin.eligible -and $decNonAdmin.status -eq 'NotAdministrator') 'Non-admin cannot provision pagefile'

# Fixture 3: Low disk space (only 20 GB free, allocating +112 GB would violate disk reserve)
$snapshotLowDisk = [pscustomobject]@{
    available = $true; isAdministrator = $true; automaticManagedPagefile = $true
    bootId = 'PROV-FIXTURE-3'; computerName = 'TESTHOST'
    settings = @()
    usage = @([pscustomobject]@{ name = 'C:\pagefile.sys'; allocatedMB = 49152; temporary = $false })
    drives = @([pscustomobject]@{
        deviceId = 'C:'; driveType = 3; sizeBytes = [int64](500GB); freeBytes = [int64](20GB)
        volumeSerial = 'TEST-VOL-1'; fileSystem = 'NTFS'
    })
}
$decLowDisk = Get-ArkuzoPagefileProvisioningDecision -Snapshot $snapshotLowDisk -Policy $policy -TargetDriveLetter 'C'
Assert (-not $decLowDisk.eligible -and $decLowDisk.status -eq 'LowDiskSpace') 'Low disk space fails closed'

# Fixture 4: Already provisioned to >= 160 GiB
$snapshotAlready = [pscustomobject]@{
    available = $true; isAdministrator = $true; automaticManagedPagefile = $false
    bootId = 'PROV-FIXTURE-4'; computerName = 'TESTHOST'
    settings = @([pscustomobject]@{ name = 'C:\pagefile.sys'; initialSizeMB = 163840; maximumSizeMB = 163840 })
    usage = @([pscustomobject]@{ name = 'C:\pagefile.sys'; allocatedMB = 163840; temporary = $false })
    drives = @($snapshot1.drives)
}
$decAlready = Get-ArkuzoPagefileProvisioningDecision -Snapshot $snapshotAlready -Policy $policy -TargetDriveLetter 'C'
Assert (-not $decAlready.eligible -and $decAlready.status -eq 'AtOrAboveCeiling') 'Already provisioned pagefile does not write again'

# Fixture 5: MonitorOnly test in Invoke-ArkuzoPagefileProvisioning
$invMon = Invoke-ArkuzoPagefileProvisioning -Snapshot $snapshot1 -Policy $policy -TargetDriveLetter 'C' -MonitorOnly
Assert ($invMon.status -eq 'MonitorOnly' -and -not $invMon.writeAttempted) 'MonitorOnly does not attempt writes'

# Fixture 6: Execution test with dependency mock
$writtenSetting = $null
$writtenAutoManaged = $null
$deps = @{
    SetProvisionedPagefile = {
        param($TargetName, [uint32]$SizeMB, [bool]$AutoManaged)
        $script:writtenSetting = @{ TargetName = $TargetName; SizeMB = $SizeMB }
        $script:writtenAutoManaged = $AutoManaged
    }
}
$invExec = Invoke-ArkuzoPagefileProvisioning -Snapshot $snapshot1 -Policy $policy -TargetDriveLetter 'C' -Dependencies $deps
Assert ($invExec.status -eq 'PendingReboot' -and $invExec.writeAttempted -and -not $invExec.rebootInitiated) 'Provisioning succeeds with PendingReboot and no automatic reboot'
Assert ($script:writtenSetting.SizeMB -eq 163840 -and $script:writtenAutoManaged -eq $false) 'Mock received correct 163840 MB size and disabled automatic management'

Write-Output 'PASS: Pagefile provisioning decision, boundary safety, disk reserve, and execution mock passed.'
