#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false))
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw ('FAIL: '+$Message) } }
foreach ($name in @('Get-ArkuzoPagefileValue','Test-ArkuzoPagefileNumber','Get-ArkuzoPagefilePolicy','Update-ArkuzoPagefileStatus','Get-ArkuzoHealthPolicy','Get-ArkuzoRestorePolicy','Update-ArkuzoLivePolicy')) {
    $definition=@($definitions | Where-Object {$_.Name -ceq $name})
    Assert ($definition.Count -eq 1) ($name+' observation integration is missing')
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
# Load helper ASTs only, never bootstrap/controller. Real CIM writes are forbidden.
function Set-CimInstance { throw 'TEST SAFETY: real pagefile writes are forbidden' }
function Get-ArkuzoPagefileSnapshot { $script:integrationReads++; throw 'Unexpected pagefile inventory read' }
function Invoke-ArkuzoPagefileManagement { $script:integrationRequests++; throw 'Unexpected management call' }
function Write-Diagnostic($Kind,$Data) { $script:integrationDiagnostics+=@(@{kind=$Kind;data=$Data}) }
function Warn-Throttled($Key,$Message) { $script:integrationWarnings[$Key]=$Message }
$script:integrationReads=0; $script:integrationRequests=0
$script:integrationDiagnostics=@(); $script:integrationWarnings=@{}
$script:pagefilePolicy=Get-ArkuzoPagefilePolicy
$script:pagefileStatus=$null; $script:systemMemory=$null
$script:MonitorOnly=$false; $script:ownsControllerMutex=$true
Update-ArkuzoPagefileStatus
Assert ($script:pagefileStatus.status -ceq 'Disabled') 'Default disabled management must publish Disabled status'
Assert ($script:integrationReads -eq 0 -and $script:integrationRequests -eq 0) 'Disabled management must not inventory or change pagefiles'
Assert (-not $script:pagefileStatus.canSuppressRecovery -and -not $script:pagefileStatus.rebootInitiated) 'Pagefile observation must never suppress recovery or reboot'
Write-Output 'PASS: disabled pagefile observation publishes status with no inventory/settings calls.'

function Get-ArkuzoPagefileSnapshot { $script:integrationReads++; return [pscustomobject]@{available=$true} }
function Invoke-ArkuzoPagefileManagement {
    param($Snapshot,$Policy,$SystemMemory,[switch]$MonitorOnly,$OwnsController,[string]$DataDirectory)
    $script:integrationRequests++
    $script:integrationForwarded=@{monitor=[bool]$MonitorOnly;owns=$OwnsController;memory=$SystemMemory;policy=$Policy;directory=$DataDirectory}
    return [pscustomobject]@{status=$script:integrationOutcome;reason='fixture outcome';pendingReboot=($script:integrationOutcome -eq 'PendingReboot');runtimeGrowthVerified=$false;writeAttempted=$false;changed=$false;configurationPersisted=$false;canSuppressRecovery=$false;rebootInitiated=$false;decision=@{privateCimMarker='DO_NOT_PUBLISH'};error=$null}
}
$script:pagefilePolicy=Get-ArkuzoPagefilePolicy -Input @{enabled=$true}
$script:systemMemory=[pscustomobject]@{commitPercent=80;commitLimitMB=10000;commitUsedMB=8000}
$script:DataDirectory='C:\FixtureData'
$script:integrationOutcome='WindowsManaged';$script:MonitorOnly=$true;$script:ownsControllerMutex=$false
Update-ArkuzoPagefileStatus
Assert ($script:pagefileStatus.status -ceq 'WindowsManaged') 'Enabled read-only observations must publish the manager outcome'
Assert ($script:integrationReads -eq 1 -and $script:integrationRequests -eq 1) 'Enabled observations must collect one snapshot and invoke the guarded manager'
Assert ($script:integrationForwarded.monitor -and -not $script:integrationForwarded.owns) 'Monitor-only and exact controller ownership must reach the manager'
Assert ([object]::ReferenceEquals($script:integrationForwarded.memory,$script:systemMemory)) 'Fresh loop memory must reach the growth decision'
Assert ($null -eq $script:pagefileStatus.PSObject.Properties['decision']) 'Public pagefile status must omit raw CIM/decision objects'
$script:integrationOutcome='PendingReboot'
Update-ArkuzoPagefileStatus
Assert ($script:pagefileStatus.pendingReboot -and -not $script:pagefileStatus.runtimeGrowthVerified) 'Persisted configuration must remain pending, not claim active growth'
Assert ($script:integrationWarnings['pagefile-management'] -match 'PendingReboot') 'Pending growth must be visible to the operator'
Assert (-not $script:pagefileStatus.canSuppressRecovery -and -not $script:pagefileStatus.rebootInitiated) 'Pending growth must never disable recovery or request reboot'
Write-Output 'PASS: guarded manager outcomes are flattened, forwarded, and PendingReboot is visible.'

$loopCalls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Update-ArkuzoPagefileStatus'},$true))
Assert ($loopCalls.Count -eq 1) 'The real engine loop must perform bounded pagefile observations'
$fixture=Join-Path $env:TMPDIR ('pagefile-integration-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    $script:configFilePath=Join-Path $fixture 'config.json';$script:lastConfigText=''
    $script:healthPolicy=Get-ArkuzoHealthPolicy @{};$script:restorePolicy=Get-ArkuzoRestorePolicy @{}
    $script:pagefilePolicy=Get-ArkuzoPagefilePolicy
    $configuration=@{health=@{pressure_percent=88};recovery=@{};pagefile=@{enabled=$true};config_lock=$false}
    [IO.File]::WriteAllText($script:configFilePath,($configuration|ConvertTo-Json -Depth 5))
    Update-ArkuzoLivePolicy
    Assert ($script:pagefilePolicy.valid -and $script:pagefilePolicy.enabled) 'Validated pagefile configuration must participate in real hot reload'
    $retained=$script:pagefilePolicy;$retainedHealth=$script:healthPolicy;$retainedText=$script:lastConfigText
    $configuration.pagefile.enabled='true';$configuration.health.pressure_percent=86
    [IO.File]::WriteAllText($script:configFilePath,($configuration|ConvertTo-Json -Depth 5))
    Update-ArkuzoLivePolicy
    Assert ([object]::ReferenceEquals($retained,$script:pagefilePolicy) -and [object]::ReferenceEquals($retainedHealth,$script:healthPolicy)) 'Invalid pagefile reload must retain all last validated policies atomically'
    Assert ($retainedText -ceq $script:lastConfigText -and $script:integrationWarnings.ContainsKey('config-reload')) 'Invalid reload must remain observable and must not be marked applied'
} finally {Remove-Item -LiteralPath $fixture -Recurse -Force}
Write-Output 'PASS: pagefile loop is bounded and hot reload validates all policy sections atomically.'
