try {
    if (-not $MonitorOnly) {
        $controllerMutex = New-Object Threading.Mutex($false, 'Local\ArkuzoSaver-ProcessController')
        try { $ownsControllerMutex = $controllerMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsControllerMutex = $true }
        if (-not $ownsControllerMutex) { throw 'Another ArkuzoSaver controller is already running.' }
        [Arkuzo.LoopWatchdogV1]::Start((Join-Path $DataDirectory 'saver-stall.json'), 60)
        Initialize-ArkuzoNativePrivileges | Out-Null
        [Arkuzo.LoopWatchdogV1]::Mark('log retention')
        $retention = Invoke-ArkuzoLogRetention $LogDirectory $sessionTag $MaxLogSessions $MaxLogTotalMB
        if ($retention.deletedFiles -gt 0 -or $retention.failed -gt 0) { Write-Diagnostic 'LOG_RETENTION' @{ maxSessions = $MaxLogSessions; maxTotalMB = $MaxLogTotalMB; deletedFiles = $retention.deletedFiles; deletedMB = $retention.deletedMB; keptSessions = $retention.keptSessions; keptMB = $retention.keptMB; failed = $retention.failed } }
        Initialize-ArkuzoGraphicsSettings
        Initialize-ArkuzoRecoveryJournal
        Resolve-ArkuzoAccountProvider
        Update-VoltRecoveryCapability -SyncControl
        Sync-ArkuzoAutoexecSignals
    }
    while ($true) {
        $script:loopPass = [long]$script:loopPass + 1
        Step-ArkuzoLoopPhase 'signals'
        [Arkuzo.LoopWatchdogV1]::Mark('loop: executor signals')
        $recoveredStall = [Arkuzo.LoopWatchdogV1]::TakeRecovered()
        if ($recoveredStall) {
            $stallParts = $recoveredStall.Split('|')
            Write-Diagnostic 'SAVER_STALL_RECOVERED' @{ phase = $stallParts[0]; stalledSec = [double]$stallParts[1] }
            Warn-Throttled 'saver-stall' ("Saver was blocked for $($stallParts[1])s during '$($stallParts[0])'.")
        }
        Process-ArkuzoExecutorSignals
        $swPhase = [Diagnostics.Stopwatch]::StartNew()
        Invoke-ArkuzoHealthObservation
        $swPhase.Stop()
        if ($swPhase.Elapsed.TotalSeconds -gt 5) {
            Warn-Throttled 'dashboard-stall-health' "Health observation stalled for $([math]::Round($swPhase.Elapsed.TotalSeconds,2))s"
            Write-Diagnostic 'DASHBOARD_STALL' @{ phase='HealthObservation'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
        }
        if ($RunForSec -gt 0 -and $clock.Elapsed.TotalSeconds -ge $RunForSec) { break }
        if (($StopFile -and (Test-Path -LiteralPath $StopFile)) -or (Test-Path -LiteralPath (Join-Path $DataDirectory 'stop.signal'))) { break }
        Step-ArkuzoLoopPhase 'policy'
        if ($clock.Elapsed.TotalSeconds -ge $nextPolicyCheck) {
            $swPhase = [Diagnostics.Stopwatch]::StartNew()
            [Arkuzo.LoopWatchdogV1]::Mark('policy reload')
            Update-ArkuzoLivePolicy
            if (-not $MonitorOnly) { Resolve-ArkuzoAccountProvider }
            if ($null -ne $pendingLiveSettings) { Update-ArkuzoLiveSettings $pendingLiveSettings; $pendingLiveSettings = $null }
            Sync-ArkuzoAutoexecSignals
            $swPhase.Stop()
            if ($swPhase.Elapsed.TotalSeconds -gt 5) {
                Write-Diagnostic 'DASHBOARD_STALL' @{ phase='PolicyCheck'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
            }
            $nextPolicyCheck = $clock.Elapsed.TotalSeconds + 10
        }
        Step-ArkuzoLoopPhase 'memory'
        if ($clock.Elapsed.TotalSeconds -ge $nextHealthSample) {
            $swPhase = [Diagnostics.Stopwatch]::StartNew()
            try { $systemMemory = Get-ArkuzoSystemMemory } catch { $systemMemory = $null; Warn-Throttled 'memory-query' 'OS commit telemetry unavailable.' }
            $swPhase.Stop()
            if ($swPhase.Elapsed.TotalSeconds -gt 5) {
                Write-Diagnostic 'DASHBOARD_STALL' @{ phase='MemoryQuery'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
            }
            $nextHealthSample = $clock.Elapsed.TotalSeconds + 5
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextPagefileCheck) {
            $swPhase = [Diagnostics.Stopwatch]::StartNew()
            [Arkuzo.LoopWatchdogV1]::Mark('pagefile check')
            Update-ArkuzoPagefileStatus
            if ($pagefilePolicy.enabled) {
                try { $systemMemory = Get-ArkuzoSystemMemory } catch { $systemMemory=$null; Warn-Throttled 'memory-query' 'OS commit telemetry unavailable after pagefile observation.' }
            }
            $swPhase.Stop()
            if ($swPhase.Elapsed.TotalSeconds -gt 5) {
                Write-Diagnostic 'DASHBOARD_STALL' @{ phase='PagefileCheck'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
            }
            $nextPagefileCheck = $clock.Elapsed.TotalSeconds + 30
        }
        Step-ArkuzoLoopPhase 'volt'
        Poll-ArkuzoVoltControlAsync
        if ($clock.Elapsed.TotalSeconds -ge $nextVoltCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('Volt status')
            Update-VoltRecoveryCapability
            Start-ArkuzoVoltControlStatusAsync
            $nextVoltCheck = $clock.Elapsed.TotalSeconds + 15
        }
        Step-ArkuzoLoopPhase 'accounts'
        if ((Test-ArkuzoNativeProvider) -and -not $MonitorOnly -and $clock.Elapsed.TotalSeconds -ge $nextNativeCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('Arkuzo accounts')
            $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
            Invoke-ArkuzoNativeRequests
            [Arkuzo.LoopWatchdogV1]::Mark('arrange windows')
            Update-ArkuzoWindowArrangement
            $nextNativeCheck = $clock.Elapsed.TotalSeconds + 3
        }
        Step-ArkuzoLoopPhase 'launches'
        if (-not $MonitorOnly) {
            [Arkuzo.LoopWatchdogV1]::Mark('launch completion')
            # Ticket requests run in the background; start the clients whose ticket arrived.
            if (Test-ArkuzoNativeProvider) { Complete-ArkuzoNativeLaunches } else { Stop-ArkuzoNativeTicketJobs }
        }
        Step-ArkuzoLoopPhase 'clients'
        Poll-ArkuzoVersionCheckAsync
        if ($clock.Elapsed.TotalSeconds -ge $nextUpdateCheck) {
            Start-ArkuzoVersionCheckAsync
            $nextUpdateCheck = $clock.Elapsed.TotalSeconds + $updateCheckInterval
        }
        $trimPlan = Get-ArkuzoTrimPlan $systemMemory $totalPhysicalMB $TrimEverySec ([bool]$AdaptiveTrim) $PressureTrimAvailablePercent
        if (-not $MonitorOnly -and (Test-Path -LiteralPath $trimNowSignalPath)) {
            # Operator request (Control Center): make every client due now. Warmup,
            # soft target, responsiveness and global spacing still apply.
            Remove-Item -LiteralPath $trimNowSignalPath -Force -ErrorAction SilentlyContinue
            foreach ($state in @($tracked.Values)) { $state.LastTrim = -1e6 }
            Write-Diagnostic 'TRIM_NOW_REQUESTED' @{ clients = $tracked.Count }
        }
        $clients = @(Get-Process -Name RobloxPlayerBeta -ErrorAction SilentlyContinue)
        $liveIds = @($clients | ForEach-Object { $_.Id })
        foreach ($id in @($tracked.Keys)) {
            if ($liveIds -notcontains $id) { Record-ClientExit $id $tracked[$id]; $tracked.Remove($id); $warnings.Remove([string]$id); if ($script:accountNameCache.ContainsKey($id)) { $script:accountNameCache.Remove($id) } }
        }
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $totalCpu = [double]0
        $totalResident = [int64]0
        $totalPrivate = [int64]0
        foreach ($client in $clients) {
            [Arkuzo.LoopWatchdogV1]::Mark('client ' + $client.Id + ': sample')
            Invoke-ArkuzoHealthObservation
            $id = $null
            try {
                $id = $client.Id
                $client.Refresh()
                if ($client.HasExited) {
                    if ($tracked.ContainsKey($client.Id)) {
                        Record-ClientExit $client.Id $tracked[$client.Id] 'HasExited reported'
                        $tracked.Remove($client.Id); if ($script:accountNameCache.ContainsKey($client.Id)) { $script:accountNameCache.Remove($client.Id) }
                    }
                    continue
                }
                $id = $client.Id
                $ticks = $client.StartTime.ToUniversalTime().Ticks
                $window = $client.MainWindowHandle
                # The window is probed once, after the log IO below (Get-ArkuzoRecoveryHealthSample);
                # until then the previous sample decides about trimming.
                $isResponding = $false; $launchError = $false
                if ($tracked.ContainsKey($id) -and $tracked[$id].StartTicks -ne $ticks) { Record-ClientExit $id $tracked[$id] 'PID reused'; $tracked.Remove($id); if ($script:accountNameCache.ContainsKey($id)) { $script:accountNameCache.Remove($id) } }
                # Manage clients even while loading or with no visible window.
                if (-not $tracked.ContainsKey($id)) {
                    [Arkuzo.LoopWatchdogV1]::Mark('client ' + $id + ': first contact')
                    $slot = 0
                    $taken = @($tracked.Values | ForEach-Object { $_.Slot })
                    while ($taken -contains $slot) { $slot++ }
                    # Capture everything BEFORE modifying anything.
                    $state = @{
                        StartTicks = $ticks; Slot = $slot
                        Priority = $client.PriorityClass; Affinity = $client.ProcessorAffinity
                        Limits = [Arkuzo.MemorySaverNativeV1]::ReadLimits($client.Handle)
                        MemoryPriority = $(try { [Arkuzo.MemorySaverNativeV1]::ReadMemoryPriority($client.Handle) } catch { $null }); MemoryPriorityChanged = $false
                        Watcher = $null; LastSnapshot = $null; LastStatus = $null
                        LimitsChanged = $false; LastProgress = $clock.Elapsed.TotalSeconds
                        LastTrim = $clock.Elapsed.TotalSeconds; LastConfig = -1e6; MinimizedByUs = $false
                        LastCpu = $client.TotalProcessorTime.TotalSeconds; CpuTime = $clock.Elapsed.TotalSeconds
                        HangSince = -1.0; StartupErrorSince = -1.0; DisconnectSince = -1.0; ParentId = 0; HealthDecision = $null; RecoveryRequested = $false
                        GameReady = $false; EverGameReady = $false; StartupGameHistory = 'UNKNOWN'; GameLogScanned = $false; LogPath = $null; LogOffset = [int64]0; TrackerId = $null; isDisconnected = $false; DisconnectReason = $null
                        BoundAccountId = $null; BoundTrackerId = $null
                        HangCpuBase = $null; HangCpuBaseAt = $null; HangCpuPercent = $null; FarmFreezeEpisode = $null; FarmFreezePid = $null; FreezeSince = -1.0; StartedSec = $null; EverResponded = $false
                    }
                    try {
                        $procRecord = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -OperationTimeoutSec 5 -ErrorAction Stop
                        $state.ParentId = [int]$procRecord.ParentProcessId
                        if ($procRecord.CommandLine) {
                            $state.TrackerId = Get-ArkuzoBrowserTrackerId $procRecord.CommandLine
                        }
                    } catch { }
                    # Launches are spaced from clients that start by other means (Volt, by hand).
                    # The engine's own launches are already spaced by launchDelaySec from their
                    # start; counting their appearance too would stretch every gap by the load time.
                    if (-not (Test-ArkuzoOwnNativeLaunch ([string]$state.TrackerId))) { $script:lastClientStartUtc = [datetime]::UtcNow }
                    if ($state.TrackerId) {
                        try {
                            $bound = Get-ArkuzoControlledAccount $state.TrackerId $id
                            if ($null -ne $bound) {
                                $script:sessionObservedAccounts[[string]$bound.accountId] = $true
                                $state.BoundAccountId = [string]$bound.accountId; $state.BoundTrackerId = [string]$bound.trackerId
                            }
                        } catch { }
                    }
                    $tracked[$id] = $state
                    $watcher = $null
                    try {
                        $watcher = [Diagnostics.Process]::GetProcessById($id)
                        $watcher.Handle | Out-Null # Retain a handle so exit code can survive process exit.
                        $state.Watcher = $watcher
                    } catch { if ($null -ne $watcher) { $watcher.Dispose() }; $watcher = $null }
                    Write-Diagnostic 'CLIENT_START' @{
                        pid = $id; startTicks = $ticks; slot = $slot
                        originalPriority = $state.Priority.ToString(); originalAffinity = $state.Affinity.ToInt64()
                        residentMB = $client.WorkingSet64 / 1MB; privateMB = $client.PrivateMemorySize64 / 1MB
                    }
                }
                $state = $tracked[$id]
                if ($null -ne $state.LastSnapshot) { $isResponding = ($state.LastSnapshot['responding'] -eq $true); $launchError = ($state.LastSnapshot['launchError'] -eq $true) }
                if ($state.ParentId -le 0 -or [string]::IsNullOrWhiteSpace($state.TrackerId)) {
                    if ($null -ne $voltControlStatus -and $voltControlStatus.available -and $null -ne $voltControlStatus.accounts) {
                        $matchedAcct = @($voltControlStatus.accounts | Where-Object { [int]$_.processId -eq $id })
                        if ($matchedAcct.Count -eq 1) {
                            if ($state.ParentId -le 0 -and $null -ne $voltControlStatus.managerId -and [int]$voltControlStatus.managerId -gt 0) {
                                $state.ParentId = [int]$voltControlStatus.managerId
                            }
                            if ([string]::IsNullOrWhiteSpace($state.TrackerId) -and -not [string]::IsNullOrWhiteSpace($matchedAcct[0].trackerId)) {
                                $state.TrackerId = [string]$matchedAcct[0].trackerId
                            }
                        }
                    }
                    if ($state.ParentId -le 0) {
                        try {
                            $procRecord = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -OperationTimeoutSec 5 -ErrorAction Stop
                            $state.ParentId = [int]$procRecord.ParentProcessId
                            if ($procRecord.CommandLine -and [string]::IsNullOrWhiteSpace($state.TrackerId)) {
                                $state.TrackerId = Get-ArkuzoBrowserTrackerId $procRecord.CommandLine
                            }
                        } catch { }
                    }
                    if ($state.ParentId -le 0 -and $null -ne $script:voltParents -and $script:voltParents.Count -eq 1) {
                        $singleParentId = [int](@($script:voltParents.Keys)[0])
                        if ($singleParentId -gt 0) { $state.ParentId = $singleParentId }
                    }
                    if ($state.TrackerId) {
                        try {
                            $bound = Get-ArkuzoControlledAccount $state.TrackerId $id
                            if ($null -ne $bound) {
                                $script:sessionObservedAccounts[[string]$bound.accountId] = $true
                                $state.BoundAccountId = [string]$bound.accountId; $state.BoundTrackerId = [string]$bound.trackerId
                            }
                        } catch { }
                    }
                }
                $now = $clock.Elapsed.TotalSeconds
                # Reapply periodically without hammering native setters on each poll.
                if (-not $MonitorOnly -and ($now - $state.LastConfig) -ge 10) {
                    foreach ($operation in @('Priority','Affinity','MemoryPriority','Limits')) {
                        try {
                            switch ($operation) {
                                'Priority' { $client.PriorityClass = $Priority }
                                'Affinity' { $client.ProcessorAffinity = [Arkuzo.MemorySaverNativeV1]::Affinity($state.Affinity.ToInt64(), $state.Slot, $CoresPerInstance) }
                                'MemoryPriority' {
                                    # Only change what can be restored on exit.
                                    if ($null -ne $state.MemoryPriority) {
                                        [Arkuzo.MemorySaverNativeV1]::SetMemoryPriority($client.Handle, (ConvertTo-ArkuzoMemoryPriorityValue $MemoryPriority))
                                        $state.MemoryPriorityChanged = $true
                                    }
                                }
                                'Limits' {
                                    if (-not $SoftLimit) {
                                        [Arkuzo.MemorySaverNativeV1]::SetLimits($client.Handle, 1MB, $maxBytes, $limitFlags)
                                        $state.LimitsChanged = $true
                                    }
                                }
                            }
                        } catch { Warn-Throttled "$id-$operation" "PID ${id}: $operation failed: $($_.Exception.Message)" }
                    }
                    if ($state.LastConfig -lt 0) { Write-Diagnostic 'RESOURCE_CONFIGURATION_REQUESTED' @{ pid = $id; priority = $Priority; logicalCpu = $CoresPerInstance; memoryPriority = $MemoryPriority; hardCap = (-not [bool]$SoftLimit); targetMB = $MaxRamMB } }
                    $state.LastConfig = $now
                }
                if (-not $MonitorOnly -and $Minimize -and $client.MainWindowHandle -ne [IntPtr]::Zero) {
                    if (-not [Arkuzo.MemorySaverNativeV1]::IsIconic($client.MainWindowHandle)) {
                        if ([Arkuzo.MemorySaverNativeV1]::ShowWindowAsync($client.MainWindowHandle, 6)) {
                            $state.MinimizedByUs = $true
                        }
                    }
                }
                if (-not $MonitorOnly -and $EnableTrimming -and -not $launchError -and (([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds -ge $healthPolicy.warmup_sec) -and ($now - $state.LastTrim) -ge $trimPlan.IntervalSec -and ($now - $lastGlobalTrim) -ge $healthPolicy.trim_spacing_sec) {
                    # Opt-in only, above target, skip loading/unresponsive clients.
                    if ($client.WorkingSet64 -gt $maxBytes -and $window -ne [IntPtr]::Zero -and $isResponding) {
                        try {
                            $beforeMB = $client.WorkingSet64 / 1MB
                            [Arkuzo.MemorySaverNativeV1]::Trim($client.Handle); $script:trimCount++; $lastGlobalTrim = $now
                            Write-Diagnostic 'WORKING_SET_TRIM' @{ pid = $id; beforeMB = $beforeMB }
                        }
                        catch { Warn-Throttled "$id-trim" "PID ${id}: trim failed: $($_.Exception.Message)" }
                    }
                    $state.LastTrim = $now
                }
                $client.Refresh()
                $totalResident += $client.WorkingSet64
                $totalPrivate += $client.PrivateMemorySize64
                $sampleTime = $clock.Elapsed.TotalSeconds
                $cpuTime = $client.TotalProcessorTime.TotalSeconds
                $cpu = 0.0
                $elapsed = $sampleTime - $state.CpuTime
                if ($elapsed -ge 0.05) {
                    $cpu = [Math]::Min([double]100, [Math]::Max([double]0, [double](100 * ($cpuTime - $state.LastCpu) / ($elapsed * $cpuThreads))))
                    if (($cpuTime - $state.LastCpu) -gt 0.001) { $state.LastProgress = $sampleTime }
                    $state.LastCpu = $cpuTime; $state.CpuTime = $sampleTime
                }
                $totalCpu += $cpu
                $status = 'WINDOW OPEN'
                if (($sampleTime - $state.LastProgress) -ge 10) { $status = 'NO CPU >10s' }
                if ($client.MainWindowHandle -eq [IntPtr]::Zero) { $status = 'LOADING' }
                elseif ([Arkuzo.MemorySaverNativeV1]::IsIconic($client.MainWindowHandle)) { $status = 'MINIMIZED' }
                [Arkuzo.LoopWatchdogV1]::Mark('client ' + $id + ': game log')
                if ($null -eq $state.LogPath) {
                    $state.LogPath = Find-RobloxProcessLog -TargetProcessId $id -TrackerId $state.TrackerId -StartTimeUtc $client.StartTime.ToUniversalTime()
                }
                # The head says whether an adopted client already joined. Under memory
                # pressure the read can time out (9 Nov restart: 8 of 11 clients stayed
                # "not in game"), so retry it every 15 s until it is read once.
                if ($null -ne $state.LogPath -and -not $state.LogHeadRead -and -not $state.GameReady -and
                    ($null -eq $state.LogHeadTriedSec -or ($sampleTime - [double]$state.LogHeadTriedSec) -ge 15)) {
                    $state.LogHeadTriedSec = $sampleTime
                    try {
                        $head = Read-ArkuzoBoundedFile $state.LogPath 0 262144
                        if ($head.Ok) {
                            $state.LogHeadRead = $true
                            $headText = (@($head.Text -split "`r?`n" | Select-Object -First 350)) -join "`n"
                            if ($headText -match '(?i)\[DFLog::NetworkClient\] Connection accepted from') {
                                $state.GameReady = $true; $state.EverGameReady = $true
                            }
                        }
                    } catch { }
                }
                if ($null -ne $state.LogPath) {
                    $logOffsetRef = [ref]$state.LogOffset
                    $newLogText = Read-RobloxLogTail $state.LogPath $logOffsetRef
                    $state.LogOffset = $logOffsetRef.Value
                    if ($newLogText) {
                        if ($newLogText -match '(?i)\[DFLog::NetworkClient\] Connection accepted from') { $state.GameReady = $true; $state.EverGameReady = $true }
                        $discResult = Get-RobloxLogDisconnectReason $newLogText
                        if ($null -ne $discResult -and $discResult.Disconnected) {
                            $state.isDisconnected = $true
                            $state.GameReady = $false
                            $state.DisconnectReason = $discResult.Reason; $state.DisconnectSource = 'log'
                            Write-Diagnostic 'CLIENT_LOG_DISCONNECT_DETECTED' @{ pid = $id; reason = $discResult.Reason; errorCode = $discResult.ErrorCode }
                        }
                    }
                }
                # Log discovery/tailing may have been slow. Recollect window/memory
                # evidence and timestamp it after IO, never reuse the earlier probe.
                [Arkuzo.LoopWatchdogV1]::Mark('client ' + $id + ': health probe')
                $healthSample = Get-ArkuzoRecoveryHealthSample $client $(if ($state.isDisconnected) { 'IN_GAME_DISCONNECT' } else { '' }) $state
                $healthSample.systemCommitPercent = if ($null -ne $systemMemory) { $systemMemory.commitPercent } else { 0 }
                $healthSample.eligible = (-not $MonitorOnly -and $healthPolicy.enabled -and $voltStatus.safeToRecycle -and (Test-ArkuzoClientOwnership $state))
                $sampleTime = $clock.Elapsed.TotalSeconds
                $isResponding = $healthSample.responding; $launchError = $healthSample.launchError
                $window = $client.MainWindowHandle
                if (-not $isResponding -and $window -ne [IntPtr]::Zero) { $status = 'NOT RESPONDING' }
                $state.HealthDecision = Get-ArkuzoHealthDecision $state $healthSample $healthPolicy $sampleTime
                Update-ArkuzoHangCpu $state $cpuTime $sampleTime $cpuThreads
                if ($state.HealthDecision.Status) { $status = $state.HealthDecision.Status }
                # Bind the exact Volt account while it is still verifiable: a kicked client
                # often closes itself before its turn in the serialized recovery queue.
                if (-not $state.BoundAccountId -and $state.TrackerId -and ($state.isDisconnected -or $state.HealthDecision.Recycle -or [double]$state.HangSince -ge 0)) {
                    try {
                        $bound = Get-ArkuzoControlledAccount $state.TrackerId $id
                        if ($null -ne $bound) { $state.BoundAccountId = [string]$bound.accountId; $state.BoundTrackerId = [string]$bound.trackerId }
                    } catch { }
                }
                $clientAgeSec = ([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds
                $nextTrimText = Get-ArkuzoTrimCountdown $clientAgeSec $healthPolicy.warmup_sec $trimPlan.IntervalSec $sampleTime $state.LastTrim ([bool]$EnableTrimming) ([bool]$MonitorOnly)
                $clientIssues = @($dashboardIssues.Keys | Where-Object { $_ -eq [string]$id -or $_ -like "$id-*" })
                if ($clientIssues.Count -gt 0 -and -not $state.HealthDecision.Status) { $status = 'CHECK NOTICE' }
                $accountName = Resolve-ArkuzoAccountName -ProcessId $id -TrackerId $state.TrackerId -LogPath $state.LogPath
                $state.LastSnapshot = [ordered]@{
                    pid = $id; startTicks = [long]$state.StartTicks; cpuPercent = [Math]::Round($cpu, 2); residentMB = [Math]::Round($client.WorkingSet64 / 1MB, 1)
                    privateMB = [Math]::Round($client.PrivateMemorySize64 / 1MB, 1)
                    responding = $isResponding; windowPresent = ($window -ne [IntPtr]::Zero); launchError = $launchError
                    state = $status; sampleTime = (Get-Date).ToString('o')
                    eligible = [bool]$healthSample.eligible; isDisconnected = [bool]$state.isDisconnected; parentId = [int]$state.ParentId
                    account = $accountName; slot = [int]$state.Slot; ageSec = [Math]::Round($clientAgeSec); nextTrim = $nextTrimText
                    gameReady = [bool]$state.GameReady; disconnectReason = $state.DisconnectReason
                    memoryPriority = $(if ($state.MemoryPriorityChanged) { $MemoryPriority } else { $null })
                }
                $state.HealthSnapshotUtc=[datetime]::UtcNow.ToString('o')
                if ($state.LastStatus -ne $status) {
                    Write-Diagnostic 'CLIENT_STATE_CHANGED' @{ previous = $state.LastStatus; sample = $state.LastSnapshot }
                    $state.LastStatus = $status
                }
                $rows.Add([pscustomobject]@{
                    Id = $id; Slot = $state.Slot; Account = $accountName; Cpu = $cpu
                    Ram = $client.WorkingSet64 / 1MB; Private = $client.PrivateMemorySize64 / 1MB
                    NextTrim = $nextTrimText; Status = $status
                })
            } catch {
                if ($null -ne $id -and $tracked.ContainsKey($id)) { Reset-ArkuzoHealthSample $tracked[$id] }
                elseif ($null -eq $id) { foreach ($uncertainState in $tracked.Values) { Reset-ArkuzoHealthSample $uncertainState } }
                Warn-Throttled ([string]$id) "PID ${id}: $($_.Exception.Message)"
            } finally { try { $client.Dispose() } catch { } }
        }
        $lastTotals = @{ detected = $clients.Count; managed = $tracked.Count; cpuPercent = [Math]::Round($totalCpu, 2)
            residentMB = [Math]::Round($totalResident / 1MB, 1); privateMB = [Math]::Round($totalPrivate / 1MB, 1) }
        Step-ArkuzoLoopPhase 'outcomes'
        if ($clock.Elapsed.TotalSeconds -ge $nextOutcomeCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('recovery outcomes')
            Update-ArkuzoRecoveryOutcomes
            $nextOutcomeCheck = $clock.Elapsed.TotalSeconds + (Get-ArkuzoOutcomeCheckDelay)
        }
        Step-ArkuzoLoopPhase 'heartbeat'
        if ($clock.Elapsed.TotalSeconds -ge $nextRuntimeHeartbeat) {
            [Arkuzo.LoopWatchdogV1]::Mark('heartbeat')
            Write-ArkuzoRuntimeStatus
            # Two seconds keeps the Control Center live; the file is small.
            $nextRuntimeHeartbeat = $clock.Elapsed.TotalSeconds + 2
        }
        Step-ArkuzoLoopPhase 'remote'
        [Arkuzo.LoopWatchdogV1]::Mark('remote session')
        Update-ArkuzoRemoteSession
        Update-ArkuzoKeepAwake ((-not $MonitorOnly) -and [bool]$healthPolicy.keep_display_awake -and $tracked.Count -gt 0)
        Step-ArkuzoLoopPhase 'farmFreeze'
        [Arkuzo.LoopWatchdogV1]::Mark('farm freeze')
        Update-ArkuzoFarmFreeze
        Step-ArkuzoLoopPhase 'closures'
        Invoke-ArkuzoRecoveryCandidates
        Step-ArkuzoLoopPhase 'logging'
        if ($clock.Elapsed.TotalSeconds -ge $nextLogSample) {
            Write-Diagnostic 'RESOURCE_SAMPLE' @{
                detected = $clients.Count; managed = $tracked.Count; systemMemory = $systemMemory; voltRecoveryReady = [bool]$voltStatus.safeToRecycle
                cpuPercent = [Math]::Round($totalCpu, 2); residentMB = [Math]::Round($totalResident / 1MB, 1)
                privateMB = [Math]::Round($totalPrivate / 1MB, 1)
                clients = @($tracked.Values | ForEach-Object { $_.LastSnapshot } | Where-Object { $null -ne $_ })
                # Where the loop spends its time: ms per pass since the previous sample, sleep excluded.
                timings = (Get-ArkuzoLoopTimings)
            }
            $nextLogSample = $clock.Elapsed.TotalSeconds + $LogEverySec
        }
        Step-ArkuzoLoopPhase 'crashEvents'
        if ($clock.Elapsed.TotalSeconds -ge $nextEventCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('crash events and handlers')
            Read-CrashEvents
            try {
                # WerFault is Windows-wide crash reporting and is deliberately never enumerated or modified.
                if (-not $MonitorOnly -and $ownsControllerMutex -and -not $logFailed) {
                    $trustedHandlerRoots = @()
                    foreach ($base in @(
                        @{Path=$env:LOCALAPPDATA;Child='Roblox/Versions'},
                        @{Path=$env:ProgramData;Child='Roblox/Roblox'},
                        @{Path=$env:ProgramFiles;Child='Roblox/Versions'},
                        @{Path=${env:ProgramFiles(x86)};Child='Roblox/Versions'}
                    )) {
                        if (-not [string]::IsNullOrWhiteSpace($base.Path)) { $trustedHandlerRoots += Join-Path $base.Path $base.Child }
                    }
                    # Builds installed by the Roblox tab; their handler must still be signed by Roblox.
                    $managedHandlerRoot = try { Get-ArkuzoManagedVersionsRoot } catch { $null }
                    if ($managedHandlerRoot) { $trustedHandlerRoots += $managedHandlerRoot }
                    foreach ($listedHandler in @(Get-CimInstance Win32_Process -Filter "Name='RobloxCrashHandler.exe'" -Property ProcessId -OperationTimeoutSec 5 -ErrorAction Stop)) {
                        $ch = $null; $owner = $null; $handlerId = $null; $phase = 'OpenHandle'
                        try {
                            $handlerId = [int]$listedHandler.ProcessId
                            if ($handlerId -le 0) { throw 'Crash handler PID unavailable' }
                            $ch = Get-Process -Id $handlerId -ErrorAction Stop
                            if ($null -eq $ch) { throw 'Crash handler no longer available' }
                            $handle = $ch.Handle # Retain the exact process, never terminate by PID/name.
                            $ch.Refresh()
                            $handlerId = [int]$ch.Id
                            $expected = @{Id=$handlerId;StartTicks=$ch.StartTime.ToUniversalTime().Ticks;Path=$ch.Path;Handle=$handle;ParentId=$null}
                            $decision = $null
                            foreach ($verification in 1..2) {
                                if ($null -ne $owner) { $owner.Dispose(); $owner = $null }
                                $phase = 'IdentityAndParentVerification'
                                $records = @(Get-CimInstance Win32_Process -Filter ("ProcessId=" + $handlerId) -Property ProcessId,Name,ExecutablePath,ParentProcessId -OperationTimeoutSec 5 -ErrorAction Stop)
                                if ($records.Count -ne 1) { throw 'Crash handler metadata unavailable/ambiguous' }
                                $record = $records[0]
                                $signature = Get-AuthenticodeSignature -LiteralPath $expected.Path -ErrorAction Stop
                                $ch.Refresh()
                                $handler = @{
                                    Id=[int]$ch.Id;StartTicks=$ch.StartTime.ToUniversalTime().Ticks;Handle=$ch.Handle;HasExited=$ch.HasExited
                                    ProcessName=$ch.ProcessName;Path=$ch.Path;CimId=$record.ProcessId;CimName=$record.Name;CimPath=$record.ExecutablePath
                                    SignatureStatus=[string]$signature.Status;SignerSubject=$signature.SignerCertificate.Subject;SignaturePath=$signature.Path
                                    ParentId=[int]$record.ParentProcessId
                                }
                                if (-not (Test-ArkuzoCrashHandlerIdentity $handler $trustedHandlerRoots)) { throw 'Crash handler executable identity/path unverified' }
                                $parentId = $handler.ParentId
                                if ($parentId -le 0 -or $parentId -eq $handlerId) { throw 'Crash handler parent identity unavailable' }
                                # Only a successful, empty CIM query proves absence. Access errors are unknown.
                                $parents = @(Get-CimInstance Win32_Process -Filter ("ProcessId=" + $parentId) -Property ProcessId,CreationDate -OperationTimeoutSec 5 -ErrorAction Stop)
                                $parent = @{QuerySucceeded=$true;Count=$parents.Count;Id=$parentId}
                                if ($parents.Count -eq 0) {
                                    # A missing WMI row alone cannot hide a live/inaccessible parent.
                                    $parent.AbsenceConfirmed = $false
                                    try {
                                        $owner = Get-Process -Id $parentId -ErrorAction Stop
                                        if (-not $owner.HasExited) {
                                            throw 'Parent absence contradicted/unconfirmed by process lookup'
                                        }
                                        $parent.AbsenceConfirmed = $true
                                    } catch {
                                        if ($_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId*') { throw }
                                        $parent.AbsenceConfirmed = $true
                                    }
                                }
                                if ($parents.Count -eq 1) {
                                    if ($parents[0].CreationDate -isnot [datetime]) { throw 'Crash handler parent creation time unavailable' }
                                    $owner = Get-Process -Id $parentId -ErrorAction Stop
                                    if ($null -eq $owner) { throw 'Crash handler parent could not be inspected' }
                                    $parent.Handle = $owner.Handle
                                    $owner.Refresh()
                                    $parent.Id = [int]$owner.Id; $parent.HasExited = $owner.HasExited
                                    $parent.StartTicks = $owner.StartTime.ToUniversalTime().Ticks
                                    $parent.CimId = $parents[0].ProcessId; $parent.CimStartTicks = $parents[0].CreationDate.ToUniversalTime().Ticks
                                }
                                $ch.Refresh()
                                $handler.Id = [int]$ch.Id; $handler.StartTicks = $ch.StartTime.ToUniversalTime().Ticks; $handler.HasExited = $ch.HasExited
                                $decision = Get-ArkuzoOrphanHandlerDecision $handler $parent ([datetime]::UtcNow) ([bool]$MonitorOnly) $ownsControllerMutex $trustedHandlerRoots $expected
                                if (-not $decision.Close) {
                                    if ($decision.Reason -in @('IdentityUnverified','ParentUnverified','ObservationInvalid')) { throw ('Crash handler cleanup refused: ' + $decision.Reason) }
                                    break
                                }
                                $expected.ParentId = $handler.ParentId
                                if ($verification -eq 1) {
                                    Write-Diagnostic 'ORPHAN_CRASH_HANDLER_CLOSE_REQUESTED' @{pid=$handlerId;startTicks=$expected.StartTicks;parentId=$parentId;reason=$decision.Reason}
                                    if ($logFailed) { throw 'Crash handler cleanup requires functioning audit logging' }
                                }
                            }
                            if ($null -eq $decision -or -not $decision.Close) { continue }
                            $phase = 'FinalIdentityVerification'
                            if ($null -ne $owner) {
                                $owner.Refresh()
                                $parent.Id = [int]$owner.Id; $parent.StartTicks = $owner.StartTime.ToUniversalTime().Ticks; $parent.HasExited = $owner.HasExited
                            }
                            $ch.Refresh()
                            $handler.Id = [int]$ch.Id; $handler.StartTicks = $ch.StartTime.ToUniversalTime().Ticks
                            $handler.Handle = $ch.Handle; $handler.HasExited = $ch.HasExited; $handler.ProcessName = $ch.ProcessName; $handler.Path = $ch.Path
                            # No logging/CIM IO between this generation/authority recheck and closure.
                            $decision = Get-ArkuzoOrphanHandlerDecision $handler $parent ([datetime]::UtcNow) ([bool]$MonitorOnly) $ownsControllerMutex $trustedHandlerRoots $expected
                            if (-not $decision.Close) { throw ('Crash handler cleanup refused: ' + $decision.Reason) }
                            if ($logFailed) { throw 'Crash handler cleanup requires functioning audit logging' }
                            $phase = 'CloseAndReadback'
                            $ch.Kill()
                            $waitConfirmed = $ch.WaitForExit(2000)
                            $ch.Refresh()
                            $readback = @{Id=[int]$ch.Id;StartTicks=$ch.StartTime.ToUniversalTime().Ticks;Handle=$ch.Handle;HasExited=$ch.HasExited;WaitConfirmed=$waitConfirmed}
                            if (-not (Test-ArkuzoOrphanHandlerExit $expected $readback)) { throw 'Crash handler exit not verified for the retained generation' }
                            Write-Diagnostic 'ORPHAN_CRASH_HANDLER_CLOSED' @{pid=$handlerId;startTicks=$expected.StartTicks;parentId=$expected.ParentId;reason=$decision.Reason;exitVerified=$true}
                        } catch {
                            Write-Diagnostic 'ORPHAN_CRASH_HANDLER_ERROR' @{pid=$handlerId;phase=$phase;message=$_.Exception.Message}
                            Warn-Throttled ('orphan-handler-' + $handlerId) ('Orphan crash-handler cleanup refused/failed for PID ' + $handlerId + ': ' + $_.Exception.Message)
                        } finally {
                            foreach ($resource in @($owner, $ch)) {
                                if ($null -eq $resource) { continue }
                                try { $resource.Dispose() } catch {
                                    Write-Diagnostic 'ORPHAN_CRASH_HANDLER_ERROR' @{pid=$handlerId;phase='HandleDispose';message=$_.Exception.Message}
                                }
                            }
                        }
                    }
                }
            } catch {
                Write-Diagnostic 'ORPHAN_CRASH_HANDLER_ERROR' @{phase='Enumeration';message=$_.Exception.Message}
                Warn-Throttled 'orphan-handler-enumeration' ('Orphan crash-handler query failed: ' + $_.Exception.Message)
            }
            $nextEventCheck = $clock.Elapsed.TotalSeconds + 15
        }
        if (($clock.Elapsed.TotalSeconds - $lastHistorySample) -ge 1) {
            $cpuHistory.Enqueue($totalCpu)
            while ($cpuHistory.Count -gt 60) { $cpuHistory.Dequeue() | Out-Null }
            $lastHistorySample = $clock.Elapsed.TotalSeconds
        }
        Step-ArkuzoLoopPhase 'dashboard'
        if ($clock.Elapsed.TotalSeconds -ge $nextStatus) {
            Draw-Dashboard $rows $clients.Count $totalResident $totalPrivate $totalCpu
            $nextStatus = $clock.Elapsed.TotalSeconds + $StatusEverySec
            # Bound warning state during long sessions with many short-lived clients.
            foreach ($key in @($warnings.Keys)) {
                if (($clock.Elapsed.TotalSeconds - $warnings[$key]) -gt 300) { $warnings.Remove($key) }
            }
        }
        foreach ($key in @($dashboardIssues.Keys)) {
            if (($clock.Elapsed.TotalSeconds - $dashboardIssues[$key].Time) -gt 30) { $dashboardIssues.Remove($key) }
        }
        if (-not $Headless -and [Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Q) { break }
        }
        Complete-ArkuzoLoopPass
        [Arkuzo.LoopWatchdogV1]::Mark('idle')
        Start-Sleep -Milliseconds $PollMs
    }
} catch {
    Write-ArkuzoFailureDiagnostic 'SAVER_FATAL_ERROR' $_
    throw
} finally {
    try {
        if ($consoleReady) {
            try {
                [Console]::SetCursorPosition(0, [Console]::WindowTop)
                [Console]::Clear()
                [Console]::CursorVisible = $oldCursorVisible
                if ($null -ne $oldTitle) { [Console]::Title = $oldTitle }
            } catch { }
        }
        Write-Host 'Arkuzo Memory Saver stopped. Restoring Roblox settings...' -ForegroundColor Cyan
        foreach ($id in @($tracked.Keys)) {
            $client = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($null -eq $client) { continue }
            try { Restore-Client $client $tracked[$id] }
            catch { Write-Warning "PID ${id}: restoration unavailable: $($_.Exception.Message)" }
            finally { $client.Dispose() }
        }
        foreach ($state in $tracked.Values) {
            if ($null -ne $state.Watcher) { try { $state.Watcher.Dispose() } catch { } }
        }
        Clear-VoltRecoveryCapability
        Stop-ArkuzoNativeTicketJobs
    } catch {
        Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_
    } finally {
        try { if ($script:keepAwakeOn) { [void][Arkuzo.RemoteSessionNativeV1]::KeepAwake($false) } } catch { }
        # Cleanup/console failures must not mask the fatal error or skip lock and
        # diagnostic finalization. These independent best-effort steps never throw.
        try { Write-Diagnostic 'SESSION_STOP' @{ uptimeSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); trims = $trimCount } } catch { Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_ }
        try { if ($ownsControllerMutex -and $null -ne $controllerMutex) { $controllerMutex.ReleaseMutex() } } catch { Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_ }
        try { if ($null -ne $controllerMutex) { $controllerMutex.Dispose() } } catch { Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_ }
        if ($null -ne $logWriter) { try { $logWriter.Dispose() } catch { } }
        try { if (-not $logFailed) { Write-Host "Diagnostics saved: $logPath" -ForegroundColor Cyan } } catch { }
        $clock.Stop()
    }
}
