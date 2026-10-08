#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t = $null; $e = $null; $a = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'), [ref]$t, [ref]$e)
foreach ($f in $a.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }

function Assert([bool]$ok, [string]$msg) { if (-not $ok) { throw "FAIL: $msg" } }

$script:warnings = @{}
$script:dashboardIssues = @{}
$script:clock = [Diagnostics.Stopwatch]::StartNew()
function Write-Diagnostic($kind, $data) { }

# ---------------------------------------------------------
# Test Group 1: Dashboard Alert Formatting ([INFO] [ERROR]) and suppressing empty (!)
# ---------------------------------------------------------

$baseModel = [pscustomobject]@{
    Mode = 'AGGRESSIVE'
    TargetMB = 600
    SoftLimit = $false
    TrimEverySec = 45
    Managed = 2
    Detected = 2
    Uptime = [TimeSpan]::FromMinutes(2)
    Trims = 1
    Priority = 'BelowNormal'
    CoresPerInstance = 2
    GuardMB = 6000
    Cpu = 5.0
    ResidentMB = 1800
    PrivateMB = 4000
    CommitLimitMB = 100000
    CommitUsedMB = 15000
    CommitPercent = 15.0
    Rows = @()
    PausedAccounts = @()
    Issues = @()
    Notice = $null
    Now = [datetime]::Now
}

# Test 1.1: No issues, no notice -> No (!) lines, no [ERROR], no [INFO]
$linesEmpty = New-ArkuzoFrame -Model $baseModel -Width 80 -Height 25
$exclamationLines = @($linesEmpty | Where-Object { $_.Text -match '\s*\[!\]' })
$infoLines = @($linesEmpty | Where-Object { $_.Text -match '\s*\[INFO\]' })
$errorLines = @($linesEmpty | Where-Object { $_.Text -match '\s*\[ERROR\]' })
Assert ($exclamationLines.Count -eq 0) "Must not render any [!] when there are no issues"
Assert ($infoLines.Count -eq 0) "Must not render [INFO] when there are no issues"
Assert ($errorLines.Count -eq 0) "Must not render [ERROR] when there are no issues"

# Test 1.2: Issues with empty/whitespace or missing Message -> must NOT render (!) or phantom lines
$emptyIssuesModel = [pscustomobject]@{
    Mode = 'AGGRESSIVE'; TargetMB = 600; SoftLimit = $false; TrimEverySec = 45; Managed = 2; Detected = 2
    Uptime = [TimeSpan]::FromMinutes(2); Trims = 1; Priority = 'BelowNormal'; CoresPerInstance = 2; GuardMB = 6000
    Cpu = 5.0; ResidentMB = 1800; PrivateMB = 4000; CommitLimitMB = 100000; CommitUsedMB = 15000; CommitPercent = 15.0
    Rows = @(); PausedAccounts = @()
    Issues = @(
        @{ Message = '' },
        @{ Message = '   ' },
        @{ SomethingElse = 123 },
        ''
    )
    Notice = $null
    Now = [datetime]::Now
}
$linesEmptyIssues = New-ArkuzoFrame -Model $emptyIssuesModel -Width 80 -Height 25
$exclamationEmpty = @($linesEmptyIssues | Where-Object { $_.Text -match '\s*\[!\]' })
$infoEmpty = @($linesEmptyIssues | Where-Object { $_.Text -match '\s*\[INFO\]' })
$errorEmpty = @($linesEmptyIssues | Where-Object { $_.Text -match '\s*\[ERROR\]' })
Assert ($exclamationEmpty.Count -eq 0) "Must not render [!] for empty issues"
Assert ($infoEmpty.Count -eq 0) "Must not render [INFO] for empty issues"
Assert ($errorEmpty.Count -eq 0) "Must not render [ERROR] for empty issues"

# Test 1.3: Real issues must render as [INFO] or [ERROR] format, NEVER [!]
$realIssuesModel = [pscustomobject]@{
    Mode = 'AGGRESSIVE'; TargetMB = 600; SoftLimit = $false; TrimEverySec = 45; Managed = 2; Detected = 2
    Uptime = [TimeSpan]::FromMinutes(2); Trims = 1; Priority = 'BelowNormal'; CoresPerInstance = 2; GuardMB = 6000
    Cpu = 5.0; ResidentMB = 1800; PrivateMB = 4000; CommitLimitMB = 100000; CommitUsedMB = 15000; CommitPercent = 15.0
    Rows = @(); PausedAccounts = @()
    Issues = @(
        @{ Message = 'CRITICAL memory limit exceeded on client 1' },
        @{ Message = 'Periodic memory trim completed' }
    )
    Notice = $null
    Now = [datetime]::Now
}
$linesReal = New-ArkuzoFrame -Model $realIssuesModel -Width 80 -Height 25
$exclamationReal = @($linesReal | Where-Object { $_.Text -match '\s*\[!\]' })
$errorReal = @($linesReal | Where-Object { $_.Text -match '\[ERROR\]\s+CRITICAL memory limit' })
$infoReal = @($linesReal | Where-Object { $_.Text -match '\[INFO\]\s+Periodic memory trim' })

Assert ($exclamationReal.Count -eq 0) "Must NEVER render legacy [!] format"
Assert ($errorReal.Count -eq 1) "Error message must be tagged with [ERROR]"
Assert ($errorReal[0].Color -eq [ConsoleColor]::Red) "Error line must have Red color"
Assert ($infoReal.Count -eq 1) "Info/warning message must be tagged with [INFO]"
Assert ($infoReal[0].Color -eq [ConsoleColor]::Yellow) "Info line must have Yellow color"

# ---------------------------------------------------------
# Test Group 2: Roblox instances must NOT auto-launch on startup
# ---------------------------------------------------------

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('recovery-launch-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null

try {
    $script:ownsControllerMutex = $true
    $script:MonitorOnly = $false
    $script:recoveryStatePath = Join-Path $scratch 'state.json'
    $script:recoveryJournalHealthy = $true
    $script:recoveryAttempts = @()
    $script:launchAttempts = @()
    $script:recoveryPending = @{}
    $script:suspendedAccounts = @{}
    $script:restorePolicy = @{
        enabled = $true
        restore_missing = $true
        excluded_account_ids = @()
        restore_wait_sec = 90
        relaunch_delay_sec = 30
        retry_base_sec = 90
        retry_max_sec = 900
        retry_max_per_hour = 6
        ready_stable_sec = 30
    }

    # Case 2.1: Journal entries with oldPid=0 (synthetic/unverified) must NOT be loaded on startup
    $syntheticEntry = @{
        accountId = '22222222-2222-4222-8222-222222222222'
        oldPid = 0
        oldStartTicks = 0
        oldTrackerId = '222'
        createdUtc = [datetime]::UtcNow.ToString('o')
        retryCount = 0
    }
    $legitEntry = @{
        accountId = '33333333-3333-4333-8333-333333333333'
        oldPid = 1234
        oldStartTicks = 56789
        oldTrackerId = '333'
        createdUtc = [datetime]::UtcNow.ToString('o')
        retryCount = 0
    }
    [IO.File]::WriteAllText($recoveryStatePath, (@{
        attempts = @()
        pending = @($syntheticEntry, $legitEntry)
        launchAttempts = @()
    } | ConvertTo-Json -Depth 6))

    Initialize-ArkuzoRecoveryJournal
    Assert ($script:recoveryPending.ContainsKey($legitEntry.accountId)) "Legitimate entry with real process history must load"
    Assert (-not $script:recoveryPending.ContainsKey($syntheticEntry.accountId)) "Synthetic entry with oldPid=0 must NOT load into pending recoveries"

    # Case 2.2: Idle accounts from Volt that were launched days ago (lastLaunchAtMs > 0)
    # but NOT in current session must NOT be added to recoveryPending by Update-ArkuzoRecoveryOutcomes!
    $script:recoveryPending = @{}
    $script:sessionObservedAccounts = @{}
    # Session started just now:
    $script:saverSessionStartEpochMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $idleOldAccount = [pscustomobject]@{
        accountId = '44444444-4444-4444-8444-444444444444'
        username = 'OldIdleUser'
        trackerId = '444'
        cookieStatus = 'alive'
        cookieAlive = $true
        suspensionSafe = $true
        processId = $null
        uiStatus = 'Idle'
        controlReady = $true
        autoRelaunch = $true
        lastLaunchAtMs = 1000 # very old timestamp from previous days
    }
    $script:voltControlStatus = [pscustomobject]@{
        available = $true
        globalMappingSafe = $true
        accounts = @($idleOldAccount)
        relaunchDelayMs = 30000
    }
    $script:voltControlCheckedUtc = [datetime]::UtcNow

    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.Count -eq 0) "Old idle account must NOT be enqueued for recovery on startup"

    # Case 2.3: When an account is started in Volt during this session (lastLaunchAtMs >= sessionStart)
    $nowMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 500
    $userStartedAccount = [pscustomobject]@{
        accountId = '55555555-5555-4555-8555-555555555555'
        username = 'UserLaunchedUser'
        trackerId = '555'
        cookieStatus = 'alive'
        cookieAlive = $true
        suspensionSafe = $true
        processId = $null
        uiStatus = 'Idle'
        controlReady = $true
        autoRelaunch = $true
        lastLaunchAtMs = $nowMs # launched during this session!
    }
    $script:voltControlStatus = [pscustomobject]@{
        available = $true
        globalMappingSafe = $true
        accounts = @($userStartedAccount)
        relaunchDelayMs = 30000
    }
    $script:voltControlCheckedUtc = [datetime]::UtcNow

    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.ContainsKey($userStartedAccount.accountId)) "Account started by user in Volt during session MUST be tracked for recovery"

    # ---------------------------------------------------------
    # Test Group 3: COOKIE DEAD disappearance on restart & launch prevention
    # ---------------------------------------------------------
    # Case 3.1: Save-ArkuzoRecoveryJournal does NOT save suspendedAccounts practically
    $script:suspendedAccounts = @{
        '44a2bfd0-e5ad-439c-9ab1-ef95f7ae56b3' = @{
            accountId = '44a2bfd0-e5ad-439c-9ab1-ef95f7ae56b3'
            username = 'DeadUser'
            reason = 'COOKIE_DEAD'
            suspendedUtc = [datetime]::UtcNow.ToString('o')
        }
    }
    Save-ArkuzoRecoveryJournal
    $rawSaved = [IO.File]::ReadAllText($recoveryStatePath) | ConvertFrom-Json
    Assert (@($rawSaved.suspendedAccounts).Count -eq 0) "suspendedAccounts must NOT be saved practically in recovery-state.json"

    # Case 3.2: Initialize-ArkuzoRecoveryJournal clears suspendedAccounts on restart
    Initialize-ArkuzoRecoveryJournal
    Assert ($script:suspendedAccounts.Count -eq 0) "COOKIE DEAD accounts must disappear on restart"

    # Case 3.3: Dead cookie accounts must NEVER be launched under any circumstance
    $deadAccount = [pscustomobject]@{
        accountId = '66666666-6666-4666-8666-666666666666'
        username = 'DeadAccountUser'
        trackerId = '666'
        cookieStatus = 'dead'
        cookieAlive = $false
        suspensionSafe = $true
        processId = $null
        uiStatus = 'Idle'
        controlReady = $false
        autoRelaunch = $true
        lastLaunchAtMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    $script:voltControlStatus = [pscustomobject]@{
        available = $true
        globalMappingSafe = $true
        accounts = @($deadAccount)
        relaunchDelayMs = 30000
    }
    $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert (-not $script:recoveryPending.ContainsKey($deadAccount.accountId)) "Dead cookie account must NEVER be enqueued in recoveryPending"

    # Direct invoke check
    $res = Invoke-ArkuzoVoltControl 'LaunchMissing' $deadAccount.accountId $deadAccount.trackerId
    Assert ($res.requestAccepted -eq $false) "Direct launch attempt of dead cookie account must be refused"

    # ---------------------------------------------------------
    # Test Group 4: Account name caching & no "volt control unavailable" warning
    # ---------------------------------------------------------
    # Case 4.1: No "volt control unavailable" warning emitted when voltControlStatus is not available
    $script:voltControlStatus = [pscustomobject]@{
        available = $false
        globalMappingSafe = $false
        accounts = @()
    }
    $script:warnings = @{}
    Update-ArkuzoRecoveryOutcomes
    Assert (-not $script:warnings.ContainsKey('volt-control')) "Must never emit 'volt-control' warning"

    # Case 4.1b: No "recovery-not-ready" warning emitted by Update-VoltRecoveryCapability at startup
    $script:healthPolicy = @{ enabled = $true }
    $script:voltParents = @{}
    $script:warnings = @{}
    Update-VoltRecoveryCapability
    Assert (-not $script:warnings.ContainsKey('recovery-not-ready')) "Must never emit 'recovery-not-ready' warning at startup"

    # Case 4.2: Resolve-ArkuzoAccountName retains cached name across poll pauses / non-fresh states
    $fakeWatcher = [pscustomobject]@{
        Id = 9999
        StartTime = [datetime]::UtcNow.AddMinutes(-5)
        HasExited = $false
        ProcessName = 'RobloxPlayerBeta'
    }
    $fakeWatcher | Add-Member -MemberType ScriptMethod -Name Refresh -Value { } -Force
    $fakeStartTicks = $fakeWatcher.StartTime.ToUniversalTime().Ticks
    $script:tracked = @{
        9999 = [pscustomobject]@{
            Slot = 0
            Watcher = $fakeWatcher
            StartTicks = $fakeStartTicks
            TrackerId = '12345'
            LogPath = 'fake.log'
        }
    }
    # Populate Volt snapshot with account info
    $script:voltControlStatus = [pscustomobject]@{
        available = $true
        globalMappingSafe = $true
        accounts = @(
            [pscustomobject]@{
                accountId = 'aaaa1111-bb22-cc33-dd44-eeee55556666'
                username = 'CachedHero123'
                trackerId = '12345'
                processId = 9999
                cookieStatus = 'alive'
                cookieAlive = $true
            }
        )
    }
    $script:voltControlCheckedUtc = [datetime]::UtcNow

    # First resolve should fetch and cache the name
    $name1 = Resolve-ArkuzoAccountName -ProcessId 9999 -TrackerId '12345'
    Assert ($name1 -eq 'CachedHero123') "First resolution must resolve account name from Volt snapshot"

    # Now simulate Volt becoming temporarily not fresh (e.g. during a background poll 30 seconds later)
    $script:voltControlStatus = [pscustomobject]@{ available = $false; accounts = @() }
    $script:voltControlCheckedUtc = [datetime]::UtcNow.AddSeconds(-45) # stale snapshot

    $name2 = Resolve-ArkuzoAccountName -ProcessId 9999 -TrackerId '12345'
    Assert ($name2 -eq 'CachedHero123') "Account name must remain cached and NEVER flicker to Unknown account when Volt is not fresh"

    # Case 4.3: Tracker name cache resolves name even before exact processId is bound
    $fakeWatcher2 = [pscustomobject]@{
        Id = 8888
        StartTime = [datetime]::UtcNow.AddMinutes(-1)
        HasExited = $false
        ProcessName = 'RobloxPlayerBeta'
    }
    $fakeWatcher2 | Add-Member -MemberType ScriptMethod -Name Refresh -Value { } -Force
    $script:tracked[8888] = [pscustomobject]@{
        Slot = 1
        Watcher = $fakeWatcher2
        StartTicks = $fakeWatcher2.StartTime.ToUniversalTime().Ticks
        TrackerId = '12345'
        LogPath = 'fake2.log'
    }
    $name3 = Resolve-ArkuzoAccountName -ProcessId 8888 -TrackerId '12345'
    Assert ($name3 -eq 'CachedHero123') "Tracker cache must resolve username even for newly started process with known trackerId"
} finally {
    try { [IO.Directory]::Delete($scratch, $true) } catch { }
}

Write-Output "ALL DASHBOARD ALERTS AND RECOVERY TESTS PASSED."
