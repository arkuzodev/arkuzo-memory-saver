function Get-ArkuzoOutcomeDecision($Entry, $Account, [datetime]$NowUtc, $Policy) {
    if ($null -eq $Account -or -not $Account.available -or -not $Account.controlReady -or
        -not $Account.autoRelaunch -or -not $Account.cookieAlive -or $Account.accountId -ne $Entry.accountId) {
        $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
        return 'Blocked'
    }
    $now = $NowUtc.ToUniversalTime()
    if ($Account.processId) {
        if ([int]$Account.processId -eq [int]$Entry.oldPid -and [long]$Account.startTicks -eq [long]$Entry.oldStartTicks) {
            $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
            return 'Blocked'
        }
        # Only a fresh, successfully collected client sample is readiness evidence.
        $observed=[datetime]::MinValue
        if (-not $Account.sampleUtc -or -not [datetime]::TryParse([string]$Account.sampleUtc,[ref]$observed)) {
            $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
            return 'Observing'
        }
        $observed=$observed.ToUniversalTime()
        $age=($now-$observed).TotalSeconds
        if ($age -lt 0 -or $age -gt 10) {
            $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
            return 'Observing'
        }
        $healthy = $Account.uiStatus -eq 'Connected' -and $Account.windowPresent -and $Account.responding -and
            -not $Account.launchError -and -not $Account.isDisconnected -and $Account.gameReady -and $Account.startTicks -gt 0
        $same = ([int]$Entry.replacementPid -eq [int]$Account.processId -and [long]$Entry.replacementStartTicks -eq [long]$Account.startTicks)
        $continuous = $false
        if ($Entry.lastObservedUtc) {
            $gap = ($observed - ([datetime]$Entry.lastObservedUtc).ToUniversalTime()).TotalSeconds
            if ($healthy -and $same -and $Entry.readySinceUtc -and $gap -eq 0) { return 'Observing' } # Never extend from replay.
            $continuous = $gap -gt 0 -and $gap -le 30
        }
        if (-not $healthy -or -not $same -or -not $continuous) { $Entry.readySinceUtc = $null }
        $Entry.replacementPid = [int]$Account.processId; $Entry.replacementStartTicks = [long]$Account.startTicks
        $Entry.lastObservedUtc = $observed.ToString('o')
        if ($healthy) {
            if (-not $Entry.readySinceUtc) { $Entry.readySinceUtc = $observed.ToString('o') }
            if (($observed - ([datetime]$Entry.readySinceUtc).ToUniversalTime()).TotalSeconds -ge [double]$Policy.ready_stable_sec) { return 'Ready' }
        }
        return 'Observing'
    }
    $Entry.readySinceUtc = $null; $Entry.lastObservedUtc = $now.ToString('o')
    if ($Account.uiStatus -ne 'Idle') { return 'Wait' } # Volt still connecting/counting down: never duplicate.
    if ($Entry.nextRetryUtc -and $now -lt ([datetime]$Entry.nextRetryUtc).ToUniversalTime()) { return 'Wait' }
    $since = if ($Entry.closedUtc) { ([datetime]$Entry.closedUtc).ToUniversalTime() } else { ([datetime]$Entry.createdUtc).ToUniversalTime() }
    if (($now - $since).TotalSeconds -lt [double]$Policy.restore_wait_sec) { return 'Wait' }
    return 'LaunchMissing'
}
function Test-ArkuzoStartupIsolation($State, [string]$Reason, $Sample) {
    if ($null -eq $State -or $Reason -cne 'VOLT_STARTUP_ERROR') { return $false }
    if ($null -eq $Sample -or $Sample.launchError -isnot [bool] -or -not $Sample.launchError) { return $false }
    if ($State.GameReady -or $State.EverGameReady) { return $false }
    $State.StartupGameHistory = 'MODAL_STARTUP_ERROR'
    return $true
}
function Test-ArkuzoRecoveryHandoff([string]$AccountId, $State = $null, [string]$Reason = '', $Sample = $null, $Context = $null) {
    # No collateral closures while an account is missing. A confirmed unhealthy
    # replacement of that same account can retry through the persisted backoff.
    if ($null -eq $Context) { $Context = New-ArkuzoDecisionContext }
    $status = $Context.ControlStatus; $pending = $Context.RecoveryPending
    # A latched farm-freeze member is independently confirmed frozen and exactly
    # mapped; the other members' open handoffs are this same episode, not
    # collateral. Its mapping is re-proven by Get-ArkuzoFarmFreezeAccount.
    $farmMember = $null
    if ($Reason -ceq 'FARM_FREEZE' -and $AccountId) {
        $farmMember = Get-ArkuzoFarmFreezeMemberRecord $State
        if ($null -eq $farmMember -or $farmMember.status -cne 'Planned' -or $farmMember.accountId -cne $AccountId) { $farmMember = $null }
    }
    if (-not (Test-ArkuzoControlStatusFresh $Context)) { return $false }
    if ($status.globalMappingSafe -isnot [bool] -or -not $status.globalMappingSafe) {
        if ($null -eq $farmMember) { return $false }
        $account = Get-ArkuzoFarmFreezeAccount $State.TrackerId $State.Watcher.Id
        if ($null -eq $account -or $account.accountId -cne $AccountId) { return $false }
    }
    if (-not (Test-ArkuzoSuspendedRowsSafe $Context)) { return $false }
    if ($null -eq $pending) { return $false }
    if ($Context.NativeProvider) {
        # Arkuzo launches every client itself and maps each one by its own account tracker, so
        # an exactly mapped client (one account, same pid and start time on the retained handle)
        # never needs another account's relaunch to finish first. A failing account is never
        # quarantined, so letting it hold this gate would block every other recovery for good.
        if (-not $AccountId -or $null -eq $State -or $null -eq $State.Watcher -or $status.globalMappingSafe -isnot [bool] -or -not $status.globalMappingSafe) { return $false }
        if (-not (Test-ArkuzoClientIdentity $State.Watcher $State.Watcher.Id $State.StartTicks)) { return $false }
        $account = Get-ArkuzoControlledAccount $State.TrackerId $State.Watcher.Id $Context
        return ($null -ne $account -and $account.accountId -ceq $AccountId)
    }
    if ($pending.Count -eq 0) { return $true }
    if (-not $AccountId) { return $false }
    if ($null -ne $farmMember -and -not $pending.ContainsKey($AccountId)) { return $true }
    if (-not $pending.ContainsKey($AccountId)) {
        if (-not (Test-ArkuzoStartupIsolation $State $Reason $Sample) -or
            -not (Test-ArkuzoClientIdentity $State.Watcher $State.Watcher.Id $State.StartTicks)) { return $false }
        $account = Get-ArkuzoControlledAccount $State.TrackerId $State.Watcher.Id $Context
        return ($null -ne $account -and $account.accountId -ceq $AccountId -and
            $account.autoRelaunch -is [bool] -and $account.autoRelaunch -and $account.cookieAlive -is [bool] -and $account.cookieAlive)
    }
    $entry = $pending[$AccountId]
    if ($entry.nextRetryUtc -and $Context.NowUtc -lt ([datetime]$entry.nextRetryUtc).ToUniversalTime()) { return $false }
    if ($pending.Count -gt 1) {
        # Multiple unresolved accounts do not authorize collateral recycling.
        # Only the exact independently unhealthy replacement may retry. The
        # caller still reobserves the bound reason and exact owner after IO.
        if ($null -eq $State -or -not $Reason -or -not $State.HealthDecision.Recycle -or $State.HealthDecision.Reason -ne $Reason -or
            -not (Test-ArkuzoClientIdentity $State.Watcher $State.Watcher.Id $State.StartTicks)) { return $false }
        $account = Get-ArkuzoControlledAccount $State.TrackerId $State.Watcher.Id $Context
        if ($null -eq $account -or $account.accountId -cne $AccountId -or $entry.accountId -cne $AccountId -or
            ([int]$entry.oldPid -eq $State.Watcher.Id -and [long]$entry.oldStartTicks -eq [long]$State.StartTicks) -or
            ([int]$entry.replacementPid -gt 0 -and ([int]$entry.replacementPid -ne $State.Watcher.Id -or [long]$entry.replacementStartTicks -ne [long]$State.StartTicks))) { return $false }
    }
    return $true
}
function Test-ArkuzoKickedClosure($State) {
    # Arkuzo provider, client verified kicked or disconnected (its log or the executor said so):
    # it is out of the game whatever happens, so closing it costs nothing. It skips the
    # cooldown and the hourly budget and does not count against them.
    # A bare "ClientReplicator removed" signal can also come from an ordinary teleport, so
    # it keeps the normal gates; kicks, error prompts and the Roblox log's own reasons
    # (which already skip code 285, a client-initiated leave) do not.
    return ((Test-ArkuzoNativeProvider) -and $null -ne $State -and $null -ne $State.HealthDecision -and
        [string]$State.HealthDecision.Reason -ceq 'IN_GAME_DISCONNECT' -and [bool]$State.isDisconnected -and
        [string]$State.DisconnectSource -cne 'NetworkClient.ChildRemoved')
}
function Invoke-ClientRecovery([int]$ClientId, $State) {
    if ($MonitorOnly -or -not $healthPolicy.enabled -or -not $ownsControllerMutex -or $State.RecoveryRequested -or -not $State.HealthDecision.Recycle) { return }
    if (-not $restorePolicy.enabled) { Warn-Throttled 'restore-disabled' 'Account outcome recovery disabled; destructive recovery blocked.'; return }
    if (-not $recoveryJournalHealthy) { Warn-Throttled 'recovery-journal' 'Recovery blocked: invalid recovery journal. Clients left untouched.'; return }
    if ((Test-ArkuzoNativeProvider) -and -not $voltControlStatus.farmRunning) { Warn-Throttled 'farm-stopped' 'Farm is stopped: unhealthy clients are left alone. Start the farm to recover them.'; return }
    # Observation service can update the decision during IO. Bind this attempt
    # to its original reason; a changed condition needs a new authorized attempt.
    $reason = $State.HealthDecision.Reason
    # Clients in a disconnected RDP session cannot render, and neither could their
    # replacements. Critical commit pressure still protects the host.
    if ($reason -cne 'SYSTEM_COMMIT_PRESSURE' -and $null -ne $clock -and (Test-ArkuzoRemoteHold ([double]$clock.Elapsed.TotalSeconds))) {
        Warn-Throttled 'remote-hold' 'Remote Desktop session is disconnected: launches and recovery wait until it reconnects.'; return
    }
    # Re-read capability immediately before acting, not merely at startup.
    Update-VoltRecoveryCapability -SyncControl
    if (-not $voltStatus.safeToRecycle -or -not (Test-ArkuzoClientOwnership $State)) { return }
    $utc = [DateTime]::UtcNow
    $boundAccount = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
    if ($null -eq $boundAccount) {
        # A mature health decision is not permission to bypass unknown or removed
        # suspended identities. Expose this pre-request refusal instead of leaving
        # the operator with a zero trim countdown and no recovery explanation.
        Warn-Throttled 'recovery-mapping' 'Recovery blocked: exact Volt account mapping or suspended-account safety cannot be verified. Clients left untouched.'
        return
    }
    # A quarantined account would only burn the shared budget again. Critical
    # commit pressure still protects the host.
    if ($reason -cne 'SYSTEM_COMMIT_PRESSURE' -and (Test-ArkuzoAccountQuarantined ([string]$boundAccount.accountId) $utc)) {
        Warn-Throttled ('quarantine-'+$boundAccount.accountId) ((Get-ArkuzoAccountDisplayLabel -AccountId ([string]$boundAccount.accountId))+' is quarantined after repeated failed recoveries; it is left untouched until the quarantine expires.')
        return
    }
    if (-not (Test-ArkuzoNativeProvider)) {
        if ($State.ParentId -le 0 -and $script:voltParents.Count -eq 1) {
            $singleId = [int](@($script:voltParents.Keys)[0])
            $State.ParentId = $singleId
        }
        if ($voltControlStatus.managerId -ne $State.ParentId -or $voltControlStatus.managerStartTicks -ne $script:voltParents[$State.ParentId].StartTicks) { return }
    }
    $handoffSample = $null
    if ($recoveryPending.Count -gt 0) {
        # Refreshing launcher authority temporarily clears retained parents.
        # Observations during that IO are valid failure evidence but ineligible
        # for closure. Recompute with actual evidence after authority returns;
        # never treat the transient eligible=false as a permanent deadlock.
        try { $handoffSample = Get-ArkuzoRecoveryHealthSample $State.Watcher $reason $State }
        catch { Reset-ArkuzoHealthSample $State; return }
        $State.HealthDecision = Get-ArkuzoHealthDecision $State $handoffSample $healthPolicy $clock.Elapsed.TotalSeconds
        if (-not $State.HealthDecision.Recycle -or $State.HealthDecision.Reason -ne $reason) { return }
    }
    if (-not (Test-ArkuzoRecoveryHandoff ([string]$boundAccount.accountId) $State $reason $handoffSample)) {
        $label = Get-ArkuzoAccountDisplayLabel -ProcessId $ClientId -TrackerId $State.TrackerId
        $detail = if ($reason -ceq 'VOLT_STARTUP_ERROR' -and -not $recoveryPending.ContainsKey([string]$boundAccount.accountId)) {
            'Startup game history is UNKNOWN: complete exact-generation history cannot be verified.'
        } else { 'Waiting for exact account restoration/backoff.' }
        Warn-Throttled 'recovery-handoff' ("${label}: $detail Other accounts left untouched.")
        return
    }
    $kicked = Test-ArkuzoKickedClosure $State
    $effectiveCooldown = Get-ArkuzoRecoveryCooldown $reason $healthPolicy
    if (-not $kicked -and -not (Test-ArkuzoRecoveryBudget $recoveryAttempts $utc $effectiveCooldown $healthPolicy.max_recycles_per_hour)) {
        Warn-Throttled 'recovery-budget' 'Recovery cooldown/hourly budget reached. No restart storm.'; return
    }
    $farmEpisode = $(if ($reason -ceq 'FARM_FREEZE' -and (Test-ArkuzoFarmFreezeMember $State)) { [string]$script:farmFreeze.Id } else { $null })
    if ($reason -ceq 'FARM_FREEZE' -and (-not $farmEpisode -or -not (Test-ArkuzoFarmFreezeSlot))) { return }
    $watcher = $State.Watcher
    if (-not (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) { Reset-ArkuzoHealthSample $State; return }
    # An unmapped target is not a termination attempt. Do not charge its budget.
    if (-not (Test-ArkuzoTargetRecovery $watcher $ClientId $State.StartTicks)) { return }
    $handoffKey = [string]$boundAccount.accountId
    $openHandoffs = ($recoveryPending.Count -gt 0)
    $verifyStartupIsolation = ($openHandoffs -and -not $recoveryPending.ContainsKey($handoffKey) -and $reason -ceq 'VOLT_STARTUP_ERROR')
    $reserved = $false; $previousPending = $null
    try {
        # Persist before closing: restarting ArkuzoSaver cannot reset the budget. A kicked client
        # (Arkuzo provider) is not charged.
        $script:recoveryAttempts = @($recoveryAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 }) + @(if (-not $kicked) { $utc })
        $entry = New-ArkuzoPendingEntry $handoffKey $State.TrackerId $ClientId $State.StartTicks
        if ($recoveryPending.ContainsKey($handoffKey)) {
            $previousPending = $recoveryPending[$handoffKey].Clone()
            $entry.retryCount = [int]$previousPending.retryCount + 1
        }
        $entry.nextRetryUtc = $utc.AddSeconds((Get-ArkuzoRetryDelay ([math]::Max(1,[int]$entry.retryCount)) $restorePolicy)).ToString('o')
        # Arkuzo relaunches by itself after relaunchDelaySec: no backoff for a normal relaunch.
        if (Test-ArkuzoNativeProvider) { $entry.nextRetryUtc = $null }
        if ($farmEpisode) { $entry.farmFreezeEpisode = $farmEpisode }
        $script:recoveryPending[$handoffKey] = $entry
        $reserved = $true
        Save-ArkuzoRecoveryJournal
        Write-Diagnostic 'RECOVERY_REQUESTED' @{ accountId = $handoffKey; pid = $ClientId; startTicks = $State.StartTicks; reason = $reason; lastSample = $State.LastSnapshot; systemMemory = $systemMemory; relaunchOwner = $(if (Test-ArkuzoNativeProvider) { 'Arkuzo' } else { 'Volt account manager' }); farmFreezeEpisode = $farmEpisode }
        if ($logFailed) { throw 'Recovery requires functioning audit logging' }
        if (-not (Test-ArkuzoTargetRecovery $watcher $ClientId $State.StartTicks)) { return }
        # Open handoffs require a new fully safe farm mapping after audit/probe
        # IO, followed by actual window evidence; never refresh evidence time
        # merely because the launcher observation succeeded.
        if ($openHandoffs) {
            Update-ArkuzoVoltControl
            $freshAccount = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
            if ($null -eq $freshAccount -or $freshAccount.accountId -cne $handoffKey -or
                (-not (Test-ArkuzoNativeProvider) -and ($voltControlStatus.managerId -ne $State.ParentId -or $voltControlStatus.managerStartTicks -ne $script:voltParents[$State.ParentId].StartTicks)) -or
                $freshAccount.autoRelaunch -isnot [bool] -or -not $freshAccount.autoRelaunch -or $freshAccount.cookieAlive -isnot [bool] -or -not $freshAccount.cookieAlive) { return }
        }
        # The triggering condition may have cleared while probing/persisting/logging.
        try { $freshSample = Get-ArkuzoRecoveryHealthSample $watcher $reason $State }
        catch { Reset-ArkuzoHealthSample $State; throw }
        $State.HealthDecision = Get-ArkuzoHealthDecision $State $freshSample $healthPolicy $clock.Elapsed.TotalSeconds
        if (-not $State.HealthDecision.Recycle -or $State.HealthDecision.Reason -ne $reason) { return }
        if ($reason -ceq 'VOLT_STARTUP_ERROR' -and ($State.GameReady -or $State.EverGameReady -or $State.isDisconnected -or $freshSample.isDisconnected)) { return }
        if ($verifyStartupIsolation -and -not (Test-ArkuzoStartupIsolation $State $reason $freshSample)) { return }
        if (-not (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) { Reset-ArkuzoHealthSample $State; return }
        # Check the retained exact owner after IO, immediately before termination.
        # This narrows the race; it cannot make two processes' lifetimes atomic.
        if (-not (Test-ArkuzoNativeProvider) -and -not (Test-ArkuzoLiveVoltParent $script:voltParents[$State.ParentId])) { return }
        $rebound = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
        if ($null -eq $rebound -or $rebound.accountId -ne $handoffKey) { return }
        if ($logFailed -or -not $recoveryJournalHealthy) { return }
        $State.RecoveryRequested = $true
        $State.RecoveryStatus = 'Pending'
        # Retained handle prevents accidentally killing a reused PID.
        $watcher.Kill()
        if (-not $watcher.WaitForExit(2000)) { throw 'Client termination not confirmed' }
        $State.RecoveryStatus = 'ExitVerified'
        # Only now may this member's Volt row be unmapped for the rest of the episode.
        if ($farmEpisode) { Set-ArkuzoFarmFreezeMemberStatus $State 'Closed' }
        $entry.closedUtc = [datetime]::UtcNow.ToString('o')
        Save-ArkuzoRecoveryJournal
        Write-Diagnostic 'CLIENT_CLOSED_FOR_RECOVERY' @{ accountId = $handoffKey; pid = $ClientId; startTicks = $State.StartTicks; reason = $State.HealthDecision.Reason; note = 'Exit verified. Volt relaunch/game readiness is a separate observation, not guaranteed.' }
    } catch {
        $failure = $_.Exception.Message
        if ($State.RecoveryStatus -eq 'Pending') {
            $State.RecoveryStatus = 'Unknown' # Keep the latch unless exit or the original live identity is proven.
            $exited = $null
            try { $watcher.Refresh(); $exited = $watcher.HasExited } catch { }
            if ($exited -is [bool] -and $exited) {
                $State.RecoveryStatus = 'ExitVerified'
                if ($farmEpisode) { Set-ArkuzoFarmFreezeMemberStatus $State 'Closed' }
                Write-Diagnostic 'CLIENT_CLOSED_FOR_RECOVERY' @{ pid = $ClientId; startTicks = $State.StartTicks; reason = $State.HealthDecision.Reason; note = 'Exit verified after termination error. Volt relaunch/game readiness remains a separate observation.' }
            } elseif (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks) {
                $State.RecoveryStatus = 'Failed'
                $State.RecoveryRequested = $false # Retry still consumes the persistent cooldown/hourly budget.
            }
        }
        $label = Get-ArkuzoAccountDisplayLabel -ProcessId $ClientId -TrackerId $State.TrackerId
        Warn-Throttled 'recovery-failed' ("Recovery failed for ${label}: $failure")
    } finally {
        if ($reserved -and -not $State.RecoveryRequested -and (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) {
            $State.LastRecoveryRefusalUtc = [datetime]::UtcNow
            $script:recoveryAttempts = @($script:recoveryAttempts | Where-Object { $_ -ne $utc })
            if ($null -ne $previousPending) { $script:recoveryPending[$handoffKey] = $previousPending }
            else { $script:recoveryPending.Remove($handoffKey) }
            try { Save-ArkuzoRecoveryJournal } catch { $script:recoveryJournalHealthy = $false }
        }
    }
}
function Invoke-ArkuzoRecoveryCandidates {
    # At most one recovery per main-loop pass. While a farm-freeze episode runs,
    # only its members are recycled, so Volt launches stay paced. Try largest
    # first, skipping unready targets without charging a budget.
    $farmFreezeActive = Test-ArkuzoFarmFreezeActive
    $eligible = @($tracked.GetEnumerator() | Where-Object {
        $_.Value.HealthDecision.Recycle -and
        -not $_.Value.RecoveryRequested -and
        (-not $farmFreezeActive -or (Test-ArkuzoFarmFreezeMember $_.Value)) -and
        ($null -eq $_.Value.LastRecoveryRefusalUtc -or (([DateTime]::UtcNow) - $_.Value.LastRecoveryRefusalUtc).TotalSeconds -ge 30)
    })
    # Episode members in the order they froze: the earliest also quits first.
    $ordered = if ($farmFreezeActive) { @($eligible | Sort-Object { [double]$_.Value.FreezeSince }) } else { @($eligible | Sort-Object { $_.Value.LastSnapshot.privateMB } -Descending) }
    # Arkuzo provider: verified kicked clients first, and all of them in this pass; anything
    # else stays one closure per pass behind the cooldown and hourly budget.
    if (Test-ArkuzoNativeProvider) { $ordered = @(@($ordered | Where-Object { Test-ArkuzoKickedClosure $_.Value }) + @($ordered | Where-Object { -not (Test-ArkuzoKickedClosure $_.Value) })) }
    foreach ($candidate in $ordered) {
        $kicked = Test-ArkuzoKickedClosure $candidate.Value
        $effectiveCooldown = Get-ArkuzoRecoveryCooldown ([string]$candidate.Value.HealthDecision.Reason) $healthPolicy
        if (-not $kicked -and -not (Test-ArkuzoRecoveryBudget $recoveryAttempts ([DateTime]::UtcNow) $effectiveCooldown $healthPolicy.max_recycles_per_hour)) {
            # Cooldown is reason-specific: a larger blocked hang/memory
            # target must not starve a startup error with its own safe budget.
            Warn-Throttled 'recovery-budget' 'Recovery cooldown/hourly budget reached. No restart storm.'; continue
        }
        if ($null -ne ('Arkuzo.LoopWatchdogV1' -as [type])) { [Arkuzo.LoopWatchdogV1]::Mark('recovering client ' + $candidate.Key) }
        Invoke-ClientRecovery $candidate.Key $candidate.Value
        if ($candidate.Value.RecoveryRequested -and -not $kicked) { break }
    }
}
function Clear-ArkuzoOutcomeObservation($State) {
    if ($null -eq $State) { return }
    # Latch the observation break now: a successful sample may overwrite the
    # cleared snapshot before outcomes run. Only reset this tracked generation.
    if ($null -ne $script:recoveryPending -and $null -ne $script:tracked) {
        foreach ($pending in $script:recoveryPending.Values) {
            $replacementId = [int]$pending.replacementPid
            if ($replacementId -gt 0 -and $script:tracked.ContainsKey($replacementId) -and
                [object]::ReferenceEquals($script:tracked[$replacementId], $State) -and
                [long]$pending.replacementStartTicks -eq [long]$State.StartTicks) {
                $pending.readySinceUtc = $null
                $pending.lastObservedUtc = $null
            }
        }
    }
}
function Reset-ArkuzoHealthSample($State) {
    if ($null -eq $State) { return }
    Clear-ArkuzoOutcomeObservation $State
    $State.HealthDecision = $null
    $State.LastSnapshot = $null
    $State.HealthSnapshotUtc = $null
    $State.HangSince = -1.0
    $State.FreezeSince = -1.0
    $State.StartupErrorSince = -1.0
    $State.DisconnectSince = -1.0
    $State.DisconnectReason = $null
    $State.isDisconnected = $false
    $State.LastHealthSampleTime = $null
    $State.PrivateLimitSince = -1.0
    $State.HangCpuBase = $null; $State.HangCpuBaseAt = $null; $State.HangCpuPercent = $null
}
function Get-ArkuzoHealthDecision($State, $Sample, $Policy, [double]$Now) {
    $reason = ''; $status = ''
    # A >30s gap (or clock rollback) breaks continuous observation, even when
    # both endpoint samples succeeded. Polling is sub-second on a quiet PC, but
    # a farm deep in the pagefile takes 2-8 s per pass. The old 5 s cut-off reset
    # every timer on those passes, so a frozen client (9 Nov 05:13-06:10) and one
    # over the memory limit were never recovered. A truly stuck loop is the
    # stall watchdog's job.
    if ($null -eq $State.LastHealthSampleTime -or $Now -lt [double]$State.LastHealthSampleTime) {
        $State.HangSince = -1.0
        $State.FreezeSince = -1.0
        $State.StartupErrorSince = -1.0
        $State.DisconnectSince = -1.0
        $State.PrivateLimitSince = -1.0
    } elseif (($Now - [double]$State.LastHealthSampleTime) -gt 30) {
        $State.HangSince = -1.0
        $State.FreezeSince = -1.0
        $State.PrivateLimitSince = -1.0
    }
    $State.LastHealthSampleTime = $Now
    if ($null -eq $State.HangSince) { $State.HangSince = -1.0 }
    if ($null -eq $State.FreezeSince) { $State.FreezeSince = -1.0 }
    # When this client started, on the same clock: a client launched after a
    # freeze began says nothing about that freeze (see Get-ArkuzoFarmFreezeCandidate).
    if ($null -eq $State.StartedSec -and $null -ne $Sample.ageSec) { $State.StartedSec = $Now - [double]$Sample.ageSec }
    if ($null -eq $State.StartupErrorSince) { $State.StartupErrorSince = -1.0 }
    if ($null -eq $State.DisconnectSince) { $State.DisconnectSince = -1.0 }
    if ($null -eq $State.PrivateLimitSince) { $State.PrivateLimitSince = -1.0 }
    if ([double]$Sample.privateMB -lt [double]$Policy.private_limit_mb) { $State.PrivateLimitSince = -1.0 }
    # Current critical OS pressure cannot wait through a startup grace.
    if ([double]$Sample.systemCommitPercent -ge 90 -and [double]$Sample.privateMB -ge [double]$Policy.pressure_min_private_mb) {
        return [pscustomobject]@{ Reason = 'SYSTEM_COMMIT_PRESSURE'; Recycle = [bool]$Sample.eligible; Status = 'CRITICAL COMMIT' }
    }
    # A responsive modal startup error is not a connected game. After a short
    # confirmation grace it is handed back to the verified Volt relaunch owner.
    if ($Sample.launchError) {
        $State.HangSince = -1.0
        $State.FreezeSince = -1.0
        $State.DisconnectSince = -1.0
        if ([double]$State.StartupErrorSince -lt 0) { $State.StartupErrorSince = $Now }
        $timeout = if ($null -ne $Policy.startup_error_timeout_sec) { [double]$Policy.startup_error_timeout_sec } else { 40.0 }
        $retry = [bool]$Sample.eligible -and [double]$State.StartupErrorSince -ge 0 -and ($Now - [double]$State.StartupErrorSince) -ge $timeout
        return [pscustomobject]@{ Reason = 'VOLT_STARTUP_ERROR'; Recycle = $retry; Status = 'VOLT STARTUP ERROR' }
    }
    $State.StartupErrorSince = -1.0
    # In-game disconnect or kick detected from client log.
    if ($Sample.isDisconnected) {
        $State.HangSince = -1.0
        $State.FreezeSince = -1.0
        if ([double]$State.DisconnectSince -lt 0) { $State.DisconnectSince = $Now }
        $timeout = if ($null -ne $Policy.disconnect_timeout_sec) { [double]$Policy.disconnect_timeout_sec } else { 5.0 }
        $retry = [bool]$Sample.eligible -and [double]$State.DisconnectSince -ge 0 -and ($Now - [double]$State.DisconnectSince) -ge $timeout
        return [pscustomobject]@{ Reason = 'IN_GAME_DISCONNECT'; Recycle = $retry; Status = 'DISCONNECTED' }
    }
    $State.DisconnectSince = -1.0
    # Freeze onset for the farm-freeze path only, tracked through warm-up too:
    # clients that freeze while starting quit by themselves ~197 s later like any
    # other frozen client. A window that never answered yet is still loading and
    # does not count; past warm-up this matches HangSince.
    $warm = [double]$Sample.ageSec -lt [double]$Policy.warmup_sec
    if ($Sample.windowPresent -and $Sample.responding) { $State.EverResponded = $true }
    if ($Sample.windowPresent -and -not $Sample.responding -and ($State.EverResponded -or -not $warm)) {
        if ([double]$State.FreezeSince -lt 0) { $State.FreezeSince = $Now }
    } else { $State.FreezeSince = -1.0 }
    if ($warm) {
        $State.HangSince = -1.0
        # A latched episode member is confirmed with the rest of the farm, even
        # while it is still in warm-up; nothing else is recycled during warm-up.
        if ([double]$State.FreezeSince -ge 0 -and $Policy.farm_freeze_enabled -and (Test-ArkuzoFarmFreezeMember $State) -and
            ($null -eq $State.HangCpuPercent -or [double]$State.HangCpuPercent -le [double]$Policy.farm_freeze_max_cpu_percent)) {
            return [pscustomobject]@{ Reason = 'FARM_FREEZE'; Recycle = [bool]$Sample.eligible; Status = 'FARM FREEZE' }
        }
        return [pscustomobject]@{ Reason = ''; Recycle = $false; Status = '' }
    }
    # Track responsiveness independently of the higher-priority memory branches.
    if ($Sample.windowPresent -and -not $Sample.responding) {
        if ([double]$State.HangSince -lt 0) { $State.HangSince = $Now }
    } else { $State.HangSince = -1.0 }
    if ([double]$Sample.privateMB -ge [double]$Policy.private_limit_mb) {
        $status = 'MEMORY GRACE'
        if ([double]$State.PrivateLimitSince -lt 0) { $State.PrivateLimitSince = $Now }
        $sustain = if ($null -ne $Policy.private_limit_sustain_sec) { [double]$Policy.private_limit_sustain_sec } else { 60.0 }
        if (($Now - [double]$State.PrivateLimitSince) -ge $sustain) { $reason = 'PRIVATE_COMMIT_LIMIT'; $status = 'LEAK GUARD' }
        if ([double]$Sample.systemCommitPercent -ge [double]$Policy.pressure_percent) { $reason = 'SYSTEM_COMMIT_PRESSURE'; $status = 'COMMIT PRESSURE' }
    } elseif ([double]$Sample.systemCommitPercent -ge [double]$Policy.pressure_percent -and
              [double]$Sample.privateMB -ge [double]$Policy.pressure_min_private_mb) {
        $reason = 'SYSTEM_COMMIT_PRESSURE'; $status = 'COMMIT PRESSURE'
    }
    # Memory grace is not a recovery reason: an independently mature hang
    # remains actionable. Confirmed memory/pressure retains its precedence.
    if (-not $reason -and $Sample.windowPresent -and -not $Sample.responding) {
        $status = 'HANG GRACE'
        if (($Now - [double]$State.HangSince) -ge [double]$Policy.hang_timeout_sec) {
            $reason = 'SUSTAINED_HANG'; $status = 'STUCK CLIENT'
        } elseif ($Policy.farm_freeze_enabled -and (Test-ArkuzoFarmFreezeMember $State) -and
                  ($null -eq $State.HangCpuPercent -or [double]$State.HangCpuPercent -le [double]$Policy.farm_freeze_max_cpu_percent)) {
            # Latched episode member: confirmed together with the rest of the farm.
            $reason = 'FARM_FREEZE'; $status = 'FARM FREEZE'
        }
    }
    return [pscustomobject]@{ Reason = $reason; Recycle = ([bool]$Sample.eligible -and $reason -ne ''); Status = $status }
}

