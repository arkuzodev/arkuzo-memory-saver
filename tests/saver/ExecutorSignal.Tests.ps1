#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t = $null; $e = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'), [ref]$t, [ref]$e)
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}

function Assert([bool]$ok, [string]$msg) { if (-not $ok) { throw "FAIL: $msg" } }
function Write-Diagnostic($kind, $data) { $script:lastDiagnostic = @{ kind = $kind; data = $data } }
function Warn-Throttled($key, $message) { }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('signal-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$fakeVoltWs = Join-Path $scratch 'Volt\workspace'
$fakePotWs = Join-Path $scratch 'Potassium\workspace'
[IO.Directory]::CreateDirectory($fakeVoltWs) | Out-Null
[IO.Directory]::CreateDirectory($fakePotWs) | Out-Null

try {
    # Test 1: Signal File Parsing & Cleanup in Read-ArkuzoExecutorSignals
    $signalDir = Join-Path $fakeVoltWs "arkuzo_signals"
    [IO.Directory]::CreateDirectory($signalDir) | Out-Null
    $sigFile = Join-Path $signalDir "12345.json"
    $payload = @{
        username = "TestFarmer"
        userId = 12345
        reason = "You have been kicked from this experience (Error Code: 267)"
        errorCode = 267
        source = "GuiService.ErrorMessageChanged"
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } | ConvertTo-Json
    [IO.File]::WriteAllText($sigFile, $payload, [Text.Encoding]::UTF8)

    # Mock Get-ArkuzoExecutorSignalDirectories to return scratch workspaces
    function script:Get-ArkuzoExecutorSignalDirectories { return @($fakeVoltWs, $fakePotWs) }

    $signals = @(Read-ArkuzoExecutorSignals)
    Assert ($signals.Count -eq 1) "Should read exactly 1 signal file"
    Assert ($signals[0].Username -eq "TestFarmer") "Signal username should match"
    Assert ($signals[0].ErrorCode -eq 267) "Signal error code should be 267"
    Assert (-not (Test-Path $sigFile)) "Signal file should be consumed and deleted"

    # Test 2: Process-ArkuzoExecutorSignals updates tracked client
    $script:tracked = @{}
    $dummyState = [pscustomobject]@{
        isDisconnected = $false
        GameReady = $true
        DisconnectReason = $null
        TrackerId = "99999"
        StartTicks = 123456
        Watcher = $null
        LogPath = $null
    }
    $script:tracked[5555] = $dummyState

    # Re-mock account name resolver to return TestFarmer
    function script:Resolve-ArkuzoAccountName { param($ProcessId, $TrackerId, $LogPath) return 'TestFarmer' }

    # Write a new signal in root workspace
    $rootSig = Join-Path $fakePotWs "arkuzo_signals_TestFarmer.json"
    [IO.File]::WriteAllText($rootSig, $payload, [Text.Encoding]::UTF8)

    Process-ArkuzoExecutorSignals

    Assert ($dummyState.isDisconnected -eq $true) "Tracked state must be marked isDisconnected"
    Assert ($dummyState.GameReady -eq $false) "GameReady must be false after kick"
    Assert ($dummyState.DisconnectReason -match "Executor Signal") "DisconnectReason must indicate Executor Signal"
    Assert ($script:lastDiagnostic.kind -eq "EXECUTOR_KICK_SIGNAL_TRIGGERED") "Diagnostic event must fire"
    Assert (-not (Test-Path $rootSig)) "Signal file in root workspace must be deleted after consumption"

    # Test 3: Stale signals are ignored and cleaned up
    $staleFile = Join-Path $fakeVoltWs "arkuzo_signals_old.json"
    $stalePayload = @{
        username = "OldFarmer"
        userId = 8888
        reason = "Disconnected"
        errorCode = 277
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 300 # 5 minutes old
    } | ConvertTo-Json
    [IO.File]::WriteAllText($staleFile, $stalePayload, [Text.Encoding]::UTF8)

    $staleSignals = Read-ArkuzoExecutorSignals
    Assert ($staleSignals.Count -eq 0) "Stale signals (>180s) must not be returned"
    Assert (-not (Test-Path $staleFile)) "Stale signal file should still be cleaned up"

    # Test 4: Dead cookie cleanup mock integration
    function script:Invoke-ArkuzoVoltControl {
        param($Action)
        if ($Action -eq 'CleanDeadCookies') {
            return [pscustomobject]@{
                status = 'OK'
                cleaned = $true
                removedCount = 1
                removed = @([pscustomobject]@{ id = 'dead-1111'; username = 'DeadAccount' })
                remainingCount = 2
            }
        }
        if ($Action -eq 'Status') {
            return [pscustomobject]@{ available = $true; accounts = @() }
        }
    }
    $script:suspendedAccounts = @{ 'dead-1111' = @{ reason = 'COOKIE_DEAD' } }
    $script:recoveryPending = @{ 'dead-1111' = @{ status = 'AwaitingReplacement' } }

    $cleaned = Invoke-ArkuzoDeadCookieCleanup
    Assert ($cleaned -eq $true) "Invoke-ArkuzoDeadCookieCleanup should return true when accounts cleaned"
    Assert (-not $script:suspendedAccounts.ContainsKey('dead-1111')) "Cleaned account must be removed from suspendedAccounts"
    Assert (-not $script:recoveryPending.ContainsKey('dead-1111')) "Cleaned account must be removed from recoveryPending"

    Write-Host "PASS: ExecutorSignal and DeadCookieCleanup tests passed."
}
finally {
    if (Test-Path $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
