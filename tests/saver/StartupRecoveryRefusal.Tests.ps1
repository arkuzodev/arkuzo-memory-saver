#requires -Version 5.1
$ErrorActionPreference='Stop'
# Reuse fixture IO only; reload the real production account/handoff functions.
. (Join-Path $PSScriptRoot 'RecoveryTiming.Tests.ps1') -Case ObservationInitialization
foreach ($name in @('Get-ArkuzoControlledAccount','Test-ArkuzoRecoveryHandoff')) {
    $f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($f.Extent.Text))
}
function Warn-Throttled {param($key,$message) $script:refusals[$key]=$message}
function Initialize-StartupRefusal {
    Initialize-Fixture
    $script:refusals=@{}
    $script:healthPolicy.startup_error_timeout_sec=40
    $script:healthPolicy.cooldown_sec=240
    $script:healthPolicy.max_recycles_per_hour=10
    $script:mode='changedReason'
    $state.StartupErrorSince=60.0
    # Continuous exact-generation modal observation, already at the 40s boundary.
    $sample=@{privateMB=122;ageSec=600;windowPresent=$true;responding=$true;eligible=$true;launchError=$true;systemCommitPercent=20}
    $state.HealthDecision=Get-ArkuzoHealthDecision $state $sample $healthPolicy 100
    $script:voltControlCheckedUtc=[datetime]::UtcNow
    $script:voltControlStatus=@{available=$true;globalMappingSafe=$true;managerId=7;managerStartTicks=1;relaunchDelayMs=30000;accounts=@(
        @{accountId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';trackerId='123';processId=101;controlReady=$true;cookieStatus='alive';cookieAlive=$true;autoRelaunch=$true;uiStatus='Connected'})}
    $script:suspendedAccounts=@{'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'=@{reason='COOKIE_DEAD'}}
    $script:recoveryAttempts=@([datetime]::UtcNow.AddMinutes(-10))
}
Initialize-StartupRefusal
Assert ($state.HealthDecision.Recycle -and $state.HealthDecision.Reason -eq 'VOLT_STARTUP_ERROR') 'Continuous modal evidence has matured independently of trim countdown'
Assert ((Get-ArkuzoTrimCountdown 600 90 45 100 0 $true $false) -eq '0s') 'Displayed trim countdown is zero'
Assert (Test-ArkuzoRecoveryBudget $recoveryAttempts ([datetime]::UtcNow) 5 10) 'Startup cooldown and hourly budget are available'
Assert ($null -eq (Get-ArkuzoControlledAccount '123' 101)) 'Removed suspended identity blocks even a fresh globally safe exact target'
Assert (-not (Test-ArkuzoRecoveryHandoff 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' $state 'VOLT_STARTUP_ERROR')) 'Handoff independently retains the same suspension safety gate'
Invoke-ClientRecovery 101 $state
Write-Output ("TRACE zero-trim/mature-modal: kills=$($watcher.Kills) requests=$($events.Contains('RECOVERY_REQUESTED')) warnings=$($refusals.Count) pending=$($recoveryPending.Count)")
Assert ($watcher.Kills -eq 0 -and -not $events.Contains('RECOVERY_REQUESTED') -and $recoveryPending.Count -eq 0 -and $recoveryAttempts.Count -eq 1) 'Earliest mapping refusal leaves client, ledger and budgets untouched'
Assert ($refusals.ContainsKey('recovery-mapping') -and $refusals['recovery-mapping'] -match 'suspended') 'Mature startup recovery must expose its mapping/suspension refusal instead of silently doing nothing'
Write-Output 'PASS: startup recovery mapping/suspension refusal is visible without bypassing missing identity safety'
Initialize-StartupRefusal
$state.HealthDecision.Recycle=$false
Invoke-ClientRecovery 101 $state
Assert ($refusals.Count -eq 0) 'No background/startup dependency warning without a mature recovery request'
Initialize-StartupRefusal
$voltControlStatus.accounts+=@{accountId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';cookieStatus='dead';suspensionSafe=$true;uiStatus='Idle';processId=$null}
Assert ($null -ne (Get-ArkuzoControlledAccount '123' 101)) 'Fresh exact safe idle suspension permits the unrelated target mapping'
Assert (Test-ArkuzoRecoveryHandoff 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' $state 'VOLT_STARTUP_ERROR') 'Verified idle dead account is not blanket collateral blockage'
$voltControlCheckedUtc=[datetime]::UtcNow.AddSeconds(-30)
Invoke-ClientRecovery 101 $state
Assert ($refusals.ContainsKey('recovery-mapping') -and $watcher.Kills -eq 0) 'Stale authority still refuses closure with an explicit explanation'
Write-Output 'PASS: no immature warning, exact idle suspension exception, stale-authority fail closed'
