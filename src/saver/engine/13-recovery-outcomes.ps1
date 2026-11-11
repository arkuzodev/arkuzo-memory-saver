function New-ArkuzoPendingEntry([string]$AccountId,[string]$TrackerId,[int]$OldId=0,[long]$OldTicks=0) {
    return @{accountId=$AccountId;oldTrackerId=$TrackerId;oldPid=$OldId;oldStartTicks=$OldTicks;createdUtc=[datetime]::UtcNow.ToString('o');closedUtc=$null;status='AwaitingReplacement';retryCount=0;nextRetryUtc=$null;readySinceUtc=$null;lastObservedUtc=$null;replacementPid=0;replacementStartTicks=0}
}
function Update-ArkuzoCookieSuspensions {
    # Caller must own a healthy journal and a fresh available adapter snapshot.
    if ($null -eq $script:suspendedAccounts) { $script:suspendedAccounts=@{} }
    $utc=[datetime]::UtcNow
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe -or ($utc-$voltControlCheckedUtc).TotalSeconds -lt 0 -or ($utc-$voltControlCheckedUtc).TotalSeconds -gt 25) { return }
    foreach ($a in @($voltControlStatus.accounts)) {
        $key=[string]$a.accountId
        if ($key -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or @($voltControlStatus.accounts|Where-Object { $_.accountId -eq $key }).Count -ne 1) { continue }
        $suspend=$a.cookieStatus -ceq 'dead' -and $a.suspensionSafe -is [bool] -and $a.suspensionSafe -and -not $a.processId -and $a.uiStatus -eq 'Idle'
        $resume=$suspendedAccounts.ContainsKey($key) -and $a.cookieStatus -ceq 'alive' -and $a.controlReady -is [bool] -and $a.controlReady -and $a.cookieAlive -is [bool] -and $a.cookieAlive -and $a.trackerId -match '\A[0-9]+\z'
        if ((-not $suspend -or $suspendedAccounts.ContainsKey($key)) -and -not $resume) { continue }
        $beforePending=$recoveryPending.Clone();$beforeSuspended=$suspendedAccounts.Clone()
        try {
            Write-Diagnostic $(if($resume){'COOKIE_ACCOUNT_RESUMED'}else{'COOKIE_ACCOUNT_SUSPENDED'}) @{accountId=$key;username=$a.username;reason='COOKIE_DEAD';note='Cookie/session validity only; not evidence of a ban.'}
            if ($logFailed) { throw 'Suspension requires audit logging' }
            if ($resume) {
                $history=$suspendedAccounts[$key].pending
                if ($null -ne $history -and [long]$a.lastLaunchAtMs -gt 0 -and $a.autoRelaunch -and $restorePolicy.excluded_account_ids -notcontains $key) {
                    $history=$history.Clone();$history.readySinceUtc=$null;$history.lastObservedUtc=$null;$history.replacementPid=0;$history.replacementStartTicks=0;$history.status='AwaitingReplacement'
                    $script:recoveryPending[$key]=$history
                }
                $script:suspendedAccounts.Remove($key)
            } else {
                $history=$null;if ($recoveryPending.ContainsKey($key)) { $history=$recoveryPending[$key].Clone();$history.readySinceUtc=$null;$history.lastObservedUtc=$null }
                $script:suspendedAccounts[$key]=@{accountId=$key;username=$a.username;reason='COOKIE_DEAD';suspendedUtc=$utc.ToString('o');pending=$history;provider=$script:accountProvider}
                $script:recoveryPending.Remove($key)
            }
            Save-ArkuzoRecoveryJournal
        } catch {
            $script:recoveryPending=$beforePending;$script:suspendedAccounts=$beforeSuspended;$script:recoveryJournalHealthy=$false
            throw
        }
    }
    $autoExcluded = $false
    foreach ($key in @($script:suspendedAccounts.Keys)) {
        if (-not (Test-ArkuzoSuspensionInScope $script:suspendedAccounts[$key])) { continue } # Never exclude the other launcher's accounts.
        if (@($voltControlStatus.accounts | Where-Object { $_.accountId -ceq $key }).Count -eq 0) {
            if ($restorePolicy.excluded_account_ids -notcontains $key) {
                $restorePolicy.excluded_account_ids += @($key)
                $autoExcluded = $true
                Write-Diagnostic 'DISAPPEARED_SUSPENDED_ACCOUNT_AUTO_EXCLUDED' @{ accountId = $key }
            }
        }
    }
    if ($autoExcluded -and $configFilePath -and (Test-Path -LiteralPath $configFilePath)) {
        try {
            $cfgJson = [IO.File]::ReadAllText($configFilePath) | ConvertFrom-Json
            if ($null -ne $cfgJson.recovery) {
                $cfgJson.recovery.excluded_account_ids = @($restorePolicy.excluded_account_ids)
                Save-ArkuzoAtomicJson $configFilePath $cfgJson
            }
        } catch { }
    }
}
function Get-ArkuzoOutcomeCheckDelay {
    # Seconds until the next outcome/launch step. Under the Arkuzo provider it runs on every
    # pass while anything is queued, so launchDelaySec is the real spacing between launches
    # (a 10 s cadence turned 12 s into 20 s). Otherwise every 3 s (Arkuzo: as often as the
    # account status is read) or 10 s (Volt, whose status arrives every 15 s).
    if (Test-ArkuzoNativeProvider) {
        if ($null -ne $script:recoveryPending -and $script:recoveryPending.Count -gt 0) { return 0 }
        return 3
    }
    return 10
}
function Get-ArkuzoPendingSignature {
    # What the journal must not lose; readiness timers are cleared on load anyway.
    if ($null -eq $script:recoveryPending) { return '' }
    return ((@($script:recoveryPending.Keys) | Sort-Object | ForEach-Object {
        $e = $script:recoveryPending[$_]; $_ + '|' + $e.status + '|' + $e.retryCount + '|' + $e.nextRetryUtc + '|' + $e.closedUtc + '|' + $e.oldPid + '|' + $e.lastLaunchUtc
    }) -join ';') + '#' + @($script:launchAttempts).Count + '#' + $(if ($null -ne $script:quarantinedAccounts) { $script:quarantinedAccounts.Count } else { 0 })
}
function Get-ArkuzoLaunchOrder($Pending) {
    # Pure. Pending account ids, least recently tried launch first (never tried first of all), then
    # oldest entry, then id, so the order is stable and one failing account can't take every slot.
    return ,@(@($Pending.Keys) | Sort-Object @{ Expression = { $e = $Pending[$_]; if ($e.lastLaunchUtc) { try { ([datetime]$e.lastLaunchUtc).ToUniversalTime() } catch { [datetime]::MinValue } } else { [datetime]::MinValue } } },
        @{ Expression = { try { ([datetime]$Pending[$_].createdUtc).ToUniversalTime() } catch { [datetime]::MinValue } } }, @{ Expression = { [string]$_ } })
}
function Update-ArkuzoRecoveryOutcomes {
    if ($MonitorOnly -or -not $restorePolicy.enabled -or -not $ownsControllerMutex -or $script:recoveryJournalCorrupt) { return }
    $utc=[datetime]::UtcNow
    $journalBefore = Get-ArkuzoPendingSignature
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe -or ($utc-$voltControlCheckedUtc).TotalSeconds -lt 0 -or ($utc-$voltControlCheckedUtc).TotalSeconds -gt 25) {
        foreach ($entry in $recoveryPending.Values) { $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null }
        return
    }
    $native = Test-ArkuzoNativeProvider
    # Arkuzo: every opted-in account of a running farm should be in game, launched before or not.
    $restoreMissing = if ($native) { [bool]$voltControlStatus.farmRunning } else { [bool]$restorePolicy.restore_missing }
    $outcomePolicy = if ($native) { Get-ArkuzoNativeOutcomePolicy } else { $restorePolicy }
    try {
        Update-ArkuzoCookieSuspensions
        if ($native -and $null -ne $script:quarantinedAccounts) {
            # The Arkuzo provider never parks an account (it keeps retrying at normal spacing),
            # so quarantines restored from the journal of an earlier version are dropped.
            foreach ($a in @($voltControlStatus.accounts)) {
                if ($script:quarantinedAccounts.ContainsKey([string]$a.accountId)) {
                    $script:quarantinedAccounts.Remove([string]$a.accountId)
                    Write-Diagnostic 'RECOVERY_QUARANTINE_CLEARED' @{accountId=$a.accountId;note='Arkuzo provider: no quarantine; the account is retried at normal spacing.'}
                }
            }
        }
        # Opted-in, previously launched accounts only. Never activate unlaunched accounts.
        if ($null -eq $script:sessionObservedAccounts) { $script:sessionObservedAccounts = @{} }
        if ($null -eq $script:saverSessionStartEpochMs) { $script:saverSessionStartEpochMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        foreach ($a in @($voltControlStatus.accounts)) {
            if ($a.cookieStatus -ceq 'dead' -or $a.cookieStatus -cne 'alive' -or -not $a.cookieAlive -or
                ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey([string]$a.accountId)) -or
                -not $a.autoRelaunch -or $restorePolicy.excluded_account_ids -contains $a.accountId) { continue }
            if ($a.processId -or ([long]$a.lastLaunchAtMs -ge $script:saverSessionStartEpochMs) -or ($native -and $restoreMissing)) {
                $script:sessionObservedAccounts[[string]$a.accountId] = $true
            }
            if (-not $script:sessionObservedAccounts.ContainsKey([string]$a.accountId)) {
                continue
            }
            if ($restoreMissing -and -not $a.processId -and $a.uiStatus -eq 'Idle' -and ($native -or [long]$a.lastLaunchAtMs -gt 0) -and
                $a.trackerId -match '\A[0-9]+\z' -and -not $recoveryPending.ContainsKey([string]$a.accountId) -and
                -not (Test-ArkuzoAccountQuarantined ([string]$a.accountId) $utc)) {
                $script:recoveryPending[[string]$a.accountId]=New-ArkuzoPendingEntry $a.accountId $a.trackerId
                Write-Diagnostic 'MISSING_ACCOUNT_DETECTED' @{accountId=$a.accountId;username=$a.username;note='Wait for native Volt queue before a bounded missing-account request.'}
            }
        }
        # Fair order: an account whose launch was tried least recently goes first (never tried
        # first of all), so one that keeps failing at the relaunch delay can't take every slot.
        # (Arkuzo only; Volt keeps its order.)
        $order = if (-not $native) { @($recoveryPending.Keys) } else { Get-ArkuzoLaunchOrder $recoveryPending }
        foreach ($key in $order) {
            $entry=$recoveryPending[$key]
            if ($native -and $null -ne $script:nativeLaunchExits -and $script:nativeLaunchExits.ContainsKey($key)) {
                # Its launched client went away before it was in game: relaunch after the relaunch delay.
                $script:nativeLaunchExits.Remove($key)
                Write-Diagnostic 'NATIVE_LAUNCH_EXITED' @{accountId=$key;pid=$entry.replacementPid;attempt=[int]$entry.retryCount;note='The launched client closed before it was verified in game; relaunching after the relaunch delay.'}
                $entry.closedUtc=$utc.ToString('o');$entry.nextRetryUtc=$null;$entry.replacementPid=0;$entry.replacementStartTicks=0;$entry.readySinceUtc=$null;$entry.lastObservedUtc=$null
            }
            if ($native -and -not $voltControlStatus.farmRunning) {
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Farm stopped in the Control Center'}
                $script:recoveryPending.Remove($key)
                continue
            }
            if ($restorePolicy.excluded_account_ids -contains $key) {
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account explicitly excluded by policy'}
                $script:recoveryPending.Remove($key)
                continue
            }
            # Arkuzo: no quarantine; a failing account keeps its place in the fair launch order.
            $abandon=if ($native) { $null } else { Test-ArkuzoPendingAbandon $entry $utc $restorePolicy }
            if ($abandon) {
                if ($null -eq $script:quarantinedAccounts) { $script:quarantinedAccounts=@{} }
                $until=$utc.AddSeconds([int]$restorePolicy.quarantine_sec).ToString('o')
                if ([int]$restorePolicy.quarantine_sec -gt 0) {
                    $script:quarantinedAccounts[$key]=@{accountId=$key;username=(Get-ArkuzoAccountDisplayLabel -AccountId $key);reason=$abandon;retryCount=[int]$entry.retryCount;sinceUtc=$utc.ToString('o');untilUtc=$until}
                }
                Write-Diagnostic 'RECOVERY_QUARANTINED' @{accountId=$key;reason=$abandon;retryCount=[int]$entry.retryCount;untilUtc=$until;note='Repeatedly failing account released from the shared handoff gate; other accounts recover normally.'}
                Warn-Throttled ('quarantine-'+$key) ((Get-ArkuzoAccountDisplayLabel -AccountId $key)+' quarantined after repeated failed recoveries ('+$abandon+'). Other accounts continue normally.')
                $script:recoveryPending.Remove($key)
                continue
            }
            $candidates=@($voltControlStatus.accounts|Where-Object{$_.accountId -eq $key})
            if ($candidates.Count -eq 0) {
                if (-not $entry.missingSinceUtc) {
                    $entry.missingSinceUtc = $utc.ToString('o')
                }
                $missingDuration = ($utc.ToUniversalTime() - ([datetime]$entry.missingSinceUtc).ToUniversalTime()).TotalSeconds
                if ($missingDuration -ge [double]$restorePolicy.restore_wait_sec) {
                    Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account no longer present in Volt inventory'}
                    $script:recoveryPending.Remove($key)
                    continue
                }
                $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';Warn-Throttled ('restore-'+$key) 'Pending account missing in Volt. No client closures.';continue
            }
            if ($candidates.Count -gt 1) {
                $entry.missingSinceUtc = $null
                $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';Warn-Throttled ('restore-'+$key) 'Pending account ambiguous in Volt. No client closures.';continue
            }
            $entry.missingSinceUtc = $null
            $a=$candidates[0]
            if ($a.cookieStatus -ceq 'moderated') {
                # Never hold the recovery queue for an account Roblox will not launch.
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account moderated by Roblox'}
                $script:recoveryPending.Remove($key);continue
            }
            if ($a.cookieStatus -cne 'alive') { $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';continue }
            if (-not $a.autoRelaunch) {
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account no longer opted in'}
                $script:recoveryPending.Remove($key);continue
            }
            $sample=@{available=$true;accountId=$key;controlReady=[bool]$a.controlReady;autoRelaunch=[bool]$a.autoRelaunch;cookieAlive=[bool]$a.cookieAlive;uiStatus=$a.uiStatus;processId=$a.processId;trackerId=$a.trackerId;startTicks=0;windowPresent=$false;responding=$false;launchError=$false;isDisconnected=$false;gameReady=$false}
            $replacementState=$null
            if ($a.processId -and $tracked.ContainsKey([int]$a.processId)) {
                $state=$tracked[[int]$a.processId]
                if ($state.TrackerId -eq $a.trackerId -and (Test-ArkuzoClientIdentity $state.Watcher ([int]$a.processId) $state.StartTicks) -and $state.LastSnapshot) {
                    $replacementState=$state
                    $sample.sampleUtc=$state.HealthSnapshotUtc
                    $sample.startTicks=$state.StartTicks;$sample.windowPresent=$state.LastSnapshot.windowPresent;$sample.responding=$state.LastSnapshot.responding
                    $sample.launchError=$state.LastSnapshot.launchError;$sample.isDisconnected=[bool]$state.isDisconnected;$sample.gameReady=[bool]$state.GameReady
                }
            }
            $decision=Get-ArkuzoOutcomeDecision $entry $sample $utc $outcomePolicy
            if ($decision -ne $entry.status) {
                Write-Diagnostic 'RECOVERY_OUTCOME_STATE' @{accountId=$key;previous=$entry.status;status=$decision;replacementPid=$sample.processId}
                $entry.status=$decision
            }
            if ($decision -eq 'Ready') {
                Write-Diagnostic 'ACCOUNT_RESTORED_VERIFIED' @{accountId=$key;username=$a.username;pid=$sample.processId;startTicks=$sample.startTicks;note='Exact account + new generation + connected socket + responsive window + server acceptance + stable confirmation. Not an endurance guarantee.'}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                $script:recoveryPending.Remove($key);continue
            }
            if ($native -and $decision -eq 'Observing' -and $null -ne $replacementState -and -not $sample.windowPresent -and
                [long]$replacementState.StartTicks -gt 0 -and
                (($utc.ToUniversalTime().Ticks - [long]$replacementState.StartTicks) / 1e7) -ge [double](Get-ArkuzoVaultSetting $script:nativeVault 'launchTimeoutSec' 120 30 600)) {
                # A client Arkuzo launched that never opened its window (9 Nov: 12 min,
                # 0% CPU, under memory pressure) is never healthy, and the hang check
                # only covers windows: close exactly that process so the next pass
                # launches the account again (retry count and quarantine still apply).
                $stalledPid=[int]$a.processId
                Write-Diagnostic 'NATIVE_LAUNCH_STALLED' @{accountId=$key;username=$a.username;pid=$stalledPid;startTicks=[long]$replacementState.StartTicks;note='No window after the launch timeout; closing it for a fresh launch.'}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                try {
                    if (Test-ArkuzoClientIdentity $replacementState.Watcher $stalledPid $replacementState.StartTicks) { $replacementState.Watcher.Kill() }
                } catch { Warn-Throttled ('stalled-'+$key) ((Get-ArkuzoAccountDisplayLabel -AccountId $key)+': a launch without a window could not be closed: '+$_.Exception.Message) }
                $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null
                continue
            }
            if ($decision -eq 'LaunchMissing') {
                if ($a.cookieStatus -ceq 'dead' -or $a.cookieStatus -cne 'alive' -or -not $a.cookieAlive -or
                    ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey($key))) {
                    Write-Diagnostic 'LAUNCH_REFUSED_DEAD_COOKIE' @{accountId=$key;username=$a.username;cookieStatus=$a.cookieStatus}
                    $script:recoveryPending.Remove($key)
                    continue
                }
                if ($native -and [long]$a.closeRequestedAtMs -gt 0) { continue } # Close pressed: wait until it is done, nothing charged.
                $launchGap = if ($native) { [int](Get-ArkuzoVaultSetting $script:nativeVault 'launchDelaySec' 12 5 120) } else { [int]$restorePolicy.retry_base_sec }
                # Arkuzo: launchDelaySec is the only limit. An hourly cap would park every account
                # for the rest of the hour after an outage, a hidden backoff.
                $launchCap = if ($native) { [int]::MaxValue } else { [int]$restorePolicy.retry_max_per_hour }
                if (-not (Test-ArkuzoRecoveryBudget $launchAttempts $utc $launchGap $launchCap)) {
                    if ($native) { continue } # Launch spacing: normal, not worth a warning.
                    Warn-Throttled 'restore-budget' 'Missing-account launch budget/backoff active. Other clients remain protected; automatic retry will resume.';continue
                }
                if ($null -eq $systemMemory -or $systemMemory.commitPercent -ge $healthPolicy.pressure_percent) {
                    Warn-Throttled 'restore-pressure' 'New account launch delayed: OS commit headroom insufficient/unavailable.';continue
                }
                if ($null -ne $clock -and (Test-ArkuzoRemoteHold ([double]$clock.Elapsed.TotalSeconds))) {
                    Warn-Throttled 'remote-hold' 'Remote Desktop session is disconnected: launches and recovery wait until it reconnects.';continue
                }
                if (-not $(if ($native) { Test-ArkuzoNativeLaunchSlot $utc } else { Test-ArkuzoLaunchPacing $utc })) {
                    # Not charged: the request simply waits for a quiet launch slot.
                    Warn-Throttled 'restore-pacing' 'Missing-account launch waits for a free Volt launch slot (launches are kept apart to avoid its startup notice).';continue
                }
                # Persist and audit before invoking Volt. Never burn a duplicate fast retry after a restart.
                $entry.retryCount=[int]$entry.retryCount+1
                if ($native) { $entry.lastLaunchUtc=$utc.ToString('o') }
                $entry.nextRetryUtc=$utc.AddSeconds((Get-ArkuzoRetryDelay $entry.retryCount $restorePolicy)).ToString('o')
                # Arkuzo: a launch that produces nothing is retried after launchTimeoutSec; a refused
                # one, or one whose client closes, after the relaunch delay (Set-ArkuzoNativeLaunchRetry).
                if ($native) { $entry.nextRetryUtc=$utc.AddSeconds((Get-ArkuzoVaultSetting $script:nativeVault 'launchTimeoutSec' 120 30 600)).ToString('o') }
                $script:launchAttempts=@($launchAttempts)+@($utc)
                Save-ArkuzoRecoveryJournal
                Write-Diagnostic $(if ($native) { 'NATIVE_LAUNCH_REQUEST' } else { 'VOLT_MISSING_LAUNCH_REQUEST' }) @{accountId=$key;username=$a.username;attempt=$entry.retryCount;nextRetryUtc=$entry.nextRetryUtc}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                $result=Invoke-ArkuzoVoltControl 'LaunchMissing' $key ([string]$a.trackerId)
                Write-Diagnostic $(if ($native) { 'NATIVE_LAUNCH_RESULT' } else { 'VOLT_MISSING_LAUNCH_RESULT' }) @{accountId=$key;username=$a.username;requestAccepted=($result.requestAccepted -is [bool] -and $result.requestAccepted);reason=$(if ($native) { [string]$result.reason } else { $null });note='Request acceptance is not game readiness; continue outcome verification.'}
                if (-not $result.requestAccepted) { Warn-Throttled ('restore-'+$key) $(if ($native) { (Get-ArkuzoAccountDisplayLabel -AccountId $key)+' not launched: '+$result.reason } else { 'Volt missing-account request refused/unavailable. Backoff retained, no collateral closures.' }) }
                if ($native -and -not $result.requestAccepted) { Set-ArkuzoNativeLaunchRetry $key ([string]$result.reason) }
                # Only one launch request per observation; refreshed snapshot next cycle.
                break
            }
            if ($decision -eq 'Blocked' -or ($utc-([datetime]$entry.createdUtc).ToUniversalTime()).TotalSeconds -ge 300) {
                Warn-Throttled ('restore-'+$key) ((Get-ArkuzoAccountDisplayLabel -AccountId $key)+' not restored yet ('+$decision+'). Other accounts protected; retry is bounded and monitored.')
            }
        }
        # This step can run on every pass: write the journal when something it keeps changed,
        # otherwise at most every 10 s.
        if ((Get-ArkuzoPendingSignature) -cne $journalBefore -or $null -eq $script:outcomeJournalSavedUtc -or ($utc - $script:outcomeJournalSavedUtc).TotalSeconds -ge 10 -or ($utc - $script:outcomeJournalSavedUtc).TotalSeconds -lt 0) {
            Save-ArkuzoRecoveryJournal
            $script:outcomeJournalSavedUtc = $utc
        }
    } catch { $script:recoveryJournalHealthy=$false;Warn-Throttled 'recovery-journal' 'Recovery outcome persistence/audit failed. Destructive recovery blocked.' }
}
