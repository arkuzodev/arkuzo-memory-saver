#requires -Version 5.1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "RecoveryTiming.Tests.ps1") -Case ObservationInitialization
foreach ($name in @("Get-ArkuzoControlledAccount","Test-ArkuzoStartupIsolation","Test-ArkuzoRecoveryHandoff")) {
    $f = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $false)
    if ($f) { . ([scriptblock]::Create($f.Extent.Text)) }
}

Initialize-Fixture
$script:voltControlCheckedUtc = [datetime]::UtcNow
$script:voltControlStatus = @{
    available = $true; globalMappingSafe = $true; managerId = 7; managerStartTicks = 1; relaunchDelayMs = 30000;
    accounts = @(
        @{ accountId = "target-account-id"; trackerId = "123"; processId = 101; controlReady = $true; cookieStatus = "alive"; cookieAlive = $true; autoRelaunch = $true; uiStatus = "Connected" }
    )
}
$script:suspendedAccounts = @{}
$script:recoveryAttempts = @()
$fake = New-FakeProcess
$state.StartTicks = $fake.StartTime.ToUniversalTime().Ticks
$state.Watcher = $fake
$state.TrackerId = "123"

# Case 1: recoveryPending has another missing account
$script:recoveryPending = @{
    "other-missing-account" = @{ status = "LaunchMissing"; createdUtc = [datetime]::UtcNow.ToString("o") }
}

# If the target is an established game session, it must NOT be collaterally closed
$state.GameReady = $true
$state.EverGameReady = $true
$sample = @{ launchError = $false }
$allowed = Test-ArkuzoRecoveryHandoff "target-account-id" $state "SUSTAINED_HANG" $sample
Assert (-not $allowed) "Active game session must NEVER be collaterally closed when another account is pending"

# If the target is a verified startup modal error, it MUST be allowed to close and recover
$state.GameReady = $false
$state.EverGameReady = $false
$sample = @{ launchError = $true }
$allowed = Test-ArkuzoRecoveryHandoff "target-account-id" $state "VOLT_STARTUP_ERROR" $sample
Assert ($allowed) "Verified modal startup error MUST be allowed to close even if another account is pending"

Write-Output "PASS: StartupIsolation tests passed"
