#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t = $null; $e = $null; $a = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'), [ref]$t, [ref]$e)
foreach ($f in $a.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }

function Assert($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

Write-Output 'Testing Get-ArkuzoVersionNumber...'
Assert ((Get-ArkuzoVersionNumber 'v1.0.7') -eq [version]'1.0.7') 'v1.0.7 parsed'
Assert ((Get-ArkuzoVersionNumber '1.1.0') -eq [version]'1.1.0') '1.1.0 parsed'
Assert ((Get-ArkuzoVersionNumber '') -eq $null) 'empty string returns null'

Write-Output 'Testing Test-ArkuzoUpdateAvailable version comparison...'

# Case 1: Running 1.1.0, remote is v1.0.7 -> available should be FALSE
$res1 = Test-ArkuzoUpdateAvailable -CurrentVersion '1.1.0' -FetchDelegate {
    '{"tag_name": "v1.0.7", "draft": false, "prerelease": false}'
}
Assert (-not $res1.available) 'Running 1.1.0 with remote v1.0.7 must not trigger update notice'

# Case 2: Running 1.0.7, remote is v1.0.7 -> available should be FALSE
$res2 = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.7' -FetchDelegate {
    '{"tag_name": "v1.0.7", "draft": false, "prerelease": false}'
}
Assert (-not $res2.available) 'Running 1.0.7 with remote v1.0.7 must not trigger update notice'

# Case 3: Running 1.0.6, remote is v1.0.7 -> available should be TRUE
$res3 = Test-ArkuzoUpdateAvailable -CurrentVersion '1.0.6' -FetchDelegate {
    '{"tag_name": "v1.0.7", "draft": false, "prerelease": false}'
}
Assert ($res3.available) 'Running 1.0.6 with remote v1.0.7 must trigger update notice'
Assert ($res3.latestVersion -eq 'v1.0.7') 'Latest version tag preserved'

# Case 4: Running 1.1.0, remote is v1.1.1 -> available should be TRUE
$res4 = Test-ArkuzoUpdateAvailable -CurrentVersion '1.1.0' -FetchDelegate {
    '{"tag_name": "v1.1.1", "draft": false, "prerelease": false}'
}
Assert ($res4.available) 'Running 1.1.0 with remote v1.1.1 must trigger update notice'

Write-Output 'Testing New-ArkuzoFrame top-right update badge...'
$modelWithUpdate = @{
    Mode = 'normal'; TargetMB = 1200; SoftLimit = $false; TrimEnabled = $false; TrimSeconds = 60
    Priority = 'normal'; CoresPerInstance = 2; MonitorOnly = $false; Detected = 0; Managed = 0
    ResidentMB = 0; PrivateMB = 0; Cpu = 0; Uptime = [timespan]::Zero; Trims = 0; History = @()
    SystemMemory = $null; HealthPolicy = $null; Rows = @(); SuspendedAccounts = @(); Notice = ''
    Issues = @(); ConfigLocked = $false; UpdateAvailable = $true; UpdateVersion = '1.0.9'; Now = (Get-Date)
}

$frameWide = @(New-ArkuzoFrame -Model $modelWithUpdate -Width 80 -Height 20)
$headerWide = @($frameWide | Where-Object { $_.PSObject.Properties['Segments'] -and $_.Segments })
Assert ($headerWide.Count -eq 1) 'Wide frame must contain segments row for top-right update badge'
$badgeSeg = @($headerWide[0].Segments | Where-Object { $_.Color -eq [ConsoleColor]::Red })
Assert ($badgeSeg.Count -eq 1 -and $badgeSeg[0].Text -like '*UPDATE: v1.0.9*') 'Update badge must be in Red and contain version'

$modelWithoutUpdate = @{
    Mode = 'normal'; TargetMB = 1200; SoftLimit = $false; TrimEnabled = $false; TrimSeconds = 60
    Priority = 'normal'; CoresPerInstance = 2; MonitorOnly = $false; Detected = 0; Managed = 0
    ResidentMB = 0; PrivateMB = 0; Cpu = 0; Uptime = [timespan]::Zero; Trims = 0; History = @()
    SystemMemory = $null; HealthPolicy = $null; Rows = @(); SuspendedAccounts = @(); Notice = ''
    Issues = @(); ConfigLocked = $false; UpdateAvailable = $false; UpdateVersion = $null; Now = (Get-Date)
}

$frameClean = @(New-ArkuzoFrame -Model $modelWithoutUpdate -Width 80 -Height 20)
$headerClean = @($frameClean | Where-Object { $_.PSObject.Properties['Segments'] -and $_.Segments })
Assert ($headerClean.Count -eq 0) 'Clean frame must not contain segments row when update is not available'

Write-Output 'ALL VERSION CHECK & HEADER BADGE TESTS PASSED.'
