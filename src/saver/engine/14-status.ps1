function Update-ArkuzoLivePolicy {
    try {
        $raw=[IO.File]::ReadAllText($configFilePath)
        if ($raw -eq $script:lastConfigText) { return }
        $cfg=$raw|ConvertFrom-Json
        if ($null -eq $cfg.health) { throw 'Missing health policy' }
        $newHealth=Get-ArkuzoHealthPolicy $cfg.health
        $newRestore=Get-ArkuzoRestorePolicy $cfg.recovery
        if ($null -ne $cfg.config_lock -and [bool]$cfg.config_lock) { Set-ArkuzoConfigLockLimits $newHealth }
        $newPagefile=Get-ArkuzoPagefilePolicy -Input $cfg.pagefile -PressurePercent $newHealth.pressure_percent
        if (-not $newPagefile.valid) { throw ('Invalid pagefile policy: '+($newPagefile.errors -join '; ')) }
        $script:healthPolicy=$newHealth;$script:restorePolicy=$newRestore;$script:pagefilePolicy=$newPagefile;$script:lastConfigText=$raw
        $script:accountProviderSetting=Get-ArkuzoProviderSetting $cfg
        # Resource settings are validated and applied separately by the main loop.
        $script:pendingLiveSettings=$cfg
        Write-Diagnostic 'CONFIG_RELOADED' @{health=$newHealth;recovery=$newRestore;pagefile=$newPagefile;note='Validated health/recovery/pagefile hot reload; resource settings are applied live except hard_limit.'}
    } catch { Warn-Throttled 'config-reload' 'Invalid/unavailable config ignored; last validated health, recovery and pagefile policy retained.' }
}
function Update-ArkuzoLiveSettings($Config) {
    $current = @{ MaxRamMB=$MaxRamMB; TrimEverySec=$TrimEverySec; CoresPerInstance=$CoresPerInstance; Priority=$Priority; EnableTrimming=[bool]$EnableTrimming
        MemoryPriority=$MemoryPriority; AdaptiveTrim=[bool]$AdaptiveTrim; PressureTrimAvailablePercent=$PressureTrimAvailablePercent; Minimize=[bool]$Minimize; PollMs=$PollMs }
    try { $next = Get-ArkuzoLiveResourceSettings $Config.settings $current }
    catch { Warn-Throttled 'settings-reload' ('Resource settings ignored: ' + $_.Exception.Message + '. Last applied values retained.'); return }
    $changed = @()
    foreach ($name in @($next.Keys)) {
        if ($script:cliBoundParameters -contains $name -or $next[$name] -eq $current[$name]) { continue }
        # Parameter validation attributes still guard each assignment.
        try { Set-Variable -Scope Script -Name $name -Value $next[$name]; $changed += $name }
        catch { Warn-Throttled 'settings-reload' ("Resource setting $name rejected: " + $_.Exception.Message) }
    }
    if ($Config.selected_preset -and $script:cliBoundParameters -notcontains 'Mode') { try { $script:Mode = [string]$Config.selected_preset } catch { } }
    if ($changed.Count -eq 0) { return }
    $script:maxBytes = [uint64]$script:MaxRamMB * 1MB
    # Reapply priority/affinity/memory priority on the next pass, not in 10s.
    foreach ($state in @($script:tracked.Values)) { $state.LastConfig = -1e6 }
    Write-Diagnostic 'SETTINGS_APPLIED_LIVE' @{changed=$changed;targetMB=$script:MaxRamMB;trimEverySec=$script:TrimEverySec;cores=$script:CoresPerInstance;priority=$script:Priority;memoryPriority=$script:MemoryPriority;adaptiveTrim=[bool]$script:AdaptiveTrim}
}
function ConvertTo-ArkuzoClientRecord($State) {
    # One shape for every row of clients[] in the heartbeat (contracts/runtime-status.json).
    # LastSnapshot is written by the full main-loop sample and patched in between by the
    # observation service with raw values (and is partial until the first full sample).
    # The heartbeat always gets the same keys, the same rounding and a UTC sample time;
    # what is not known yet is null. Identity comes from the client's own state.
    $s = $State.LastSnapshot
    if ($null -eq $s) { return $null }
    $number = { param($value, $digits) if ($null -eq $value) { $null } else { try { [math]::Round([double]$value, [int]$digits) } catch { $null } } }
    $flag = { param($value, $fallback) if ($value -is [bool]) { $value } else { $fallback } }
    $text = { param($value) if ($null -eq $value) { $null } else { [string]$value } }
    $whole = { param($value, $fallback) if ($null -ne $value) { try { [long]$value } catch { $fallback } } else { $fallback } }
    $sampleTime = $null
    if ($s['sampleTime']) { try { $sampleTime = ([datetime]$s['sampleTime']).ToUniversalTime().ToString('o') } catch { $sampleTime = $null } }
    return [ordered]@{
        pid = [int](& $whole $s['pid'] 0); startTicks = [long](& $whole $s['startTicks'] ([long]$State.StartTicks))
        cpuPercent = (& $number $s['cpuPercent'] 2); residentMB = (& $number $s['residentMB'] 1); privateMB = (& $number $s['privateMB'] 1)
        responding = (& $flag $s['responding'] $false); windowPresent = (& $flag $s['windowPresent'] $false); launchError = (& $flag $s['launchError'] $false)
        state = (& $text $s['state']); sampleTime = $sampleTime
        eligible = (& $flag $s['eligible'] $false); isDisconnected = (& $flag $s['isDisconnected'] ([bool]$State.isDisconnected))
        parentId = [int](& $whole $s['parentId'] ([int]$State.ParentId)); account = (& $text $s['account']); slot = [int](& $whole $s['slot'] ([int]$State.Slot))
        ageSec = (& $number $s['ageSec'] 0); nextTrim = (& $text $s['nextTrim'])
        gameReady = (& $flag $s['gameReady'] ([bool]$State.GameReady))
        disconnectReason = (& $text $(if ($null -ne $s['disconnectReason']) { $s['disconnectReason'] } else { $State.DisconnectReason }))
        memoryPriority = (& $text $s['memoryPriority'])
    }
}
function Write-ArkuzoRuntimeStatus {
    if ($MonitorOnly -or -not $ownsControllerMutex) { return }
    try {
        # Expired quarantines are otherwise only dropped when that account is next evaluated.
        if ($null -ne $script:quarantinedAccounts) { foreach ($key in @($script:quarantinedAccounts.Keys)) { [void](Test-ArkuzoAccountQuarantined $key ([datetime]::UtcNow)) } }
        $accounts=@($voltControlStatus.accounts|ForEach-Object{@{accountId=$_.accountId;username=$_.username;processId=$_.processId;uiStatus=$_.uiStatus;controlReady=$_.controlReady;cookieStatus=$_.cookieStatus;suspensionSafe=$_.suspensionSafe;autoRelaunch=[bool]$_.autoRelaunch}})
        $nativeFarm=(Test-ArkuzoNativeProvider) -and [bool]$voltControlStatus.farmRunning
        $expected=@($voltControlStatus.accounts|Where-Object{$_.autoRelaunch -and $_.cookieAlive -and $_.cookieStatus -ceq 'alive' -and ($nativeFarm -or [long]$_.lastLaunchAtMs -gt 0) -and $restorePolicy.excluded_account_ids -notcontains $_.accountId -and ($null -eq $script:suspendedAccounts -or -not $script:suspendedAccounts.ContainsKey([string]$_.accountId))})
        $missing=@($expected|Where-Object{-not $_.processId})
        $controlFresh=$voltControlStatus.available -and $null -ne $voltControlCheckedUtc -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -ge 0 -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -le 25
        Save-ArkuzoAtomicJson (Join-Path $DataDirectory 'runtime-status.json') @{
            # schemaVersion and every key below are a contract with the Control Center, its page and
            # the launcher: contracts/runtime-status.json. Adding a key is compatible; anything else needs a new version.
            schemaVersion=1;version=$ArkuzoRuntimeVersion;pid=$PID;startTicks=$script:controllerStartTicks;updatedUtc=[datetime]::UtcNow.ToString('o');monitorOnly=$false;controller=$true
            clients=@($tracked.Values|Where-Object{$null -ne $_ -and $null -ne $_.LastSnapshot}|ForEach-Object{ConvertTo-ArkuzoClientRecord $_});accounts=$accounts;expectedAccounts=$expected.Count;missingAccounts=$missing.Count
            pending=@($recoveryPending.Values);pendingRecoveries=$recoveryPending.Count;suspendedAccounts=@($script:suspendedAccounts.Values);suspendedAccountCount=$script:suspendedAccounts.Count;missingRecoveryBlocked=(-not $controlFresh -or $missing.Count -gt 0 -or $recoveryPending.Count -gt 0)
            voltControlAvailable=[bool]$voltControlStatus.available;recoveryJournalHealthy=[bool]$recoveryJournalHealthy;systemMemory=$systemMemory;health=$healthPolicy;recovery=$restorePolicy;logFailed=$logFailed
            pagefilePolicy=$pagefilePolicy;pagefile=$script:pagefileStatus;nativePrivileges=$script:nativePrivilegeInitialization;graphics=$script:graphicsStatus
            updateAvailable=$script:updateAvailableStatus;remoteSession=(Get-ArkuzoRemoteStatus)
            accountProvider=$script:accountProvider;accountProviderNotice=$script:accountProviderNotice;farmRunning=[bool]$voltControlStatus.farmRunning;robloxVersion=$script:robloxVersionStatus
            quarantined=@(if ($null -ne $script:quarantinedAccounts) { $script:quarantinedAccounts.Values })
            uptimeSec=$(if ($null -ne $script:clock) { [math]::Round($script:clock.Elapsed.TotalSeconds,1) } else { 0 })
            trims=[int]$script:trimCount;totals=$script:lastTotals;totalPhysicalMB=$script:totalPhysicalMB
            settings=@{mode=$script:Mode;targetMB=$script:MaxRamMB;trimEnabled=[bool]$script:EnableTrimming;trimEverySec=$script:TrimEverySec
                effectiveTrimSec=$(if ($null -ne $script:trimPlan) { $script:trimPlan.IntervalSec } else { $script:TrimEverySec })
                trimPressure=($null -ne $script:trimPlan -and [bool]$script:trimPlan.Pressure);availablePhysicalPercent=$(if ($null -ne $script:trimPlan) { $script:trimPlan.AvailablePercent } else { $null })
                adaptiveTrim=[bool]$script:AdaptiveTrim;priority=$script:Priority;memoryPriority=$script:MemoryPriority;coresPerInstance=$script:CoresPerInstance
                softLimit=[bool]$script:SoftLimit;configLocked=[bool]$script:isConfigLocked}
            alerts=@(if ($null -ne $script:dashboardIssues) { foreach ($issue in @($script:dashboardIssues.GetEnumerator())) {
                @{key=[string]$issue.Key;message=[string]$issue.Value.Message;ageSec=$(if ($null -ne $script:clock) { [math]::Round($script:clock.Elapsed.TotalSeconds - [double]$issue.Value.Time,1) } else { 0 })} } })
        }
    } catch { Warn-Throttled 'runtime-heartbeat' 'Runtime heartbeat could not be persisted. Watchdog must report degraded status.' }
}
