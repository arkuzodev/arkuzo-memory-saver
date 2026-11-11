function Open-DiagnosticLog {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $script:logPath = Join-Path $LogDirectory ("Arkuzo-$sessionTag-part$($script:logPart).log")
    $script:logWriter = New-Object System.IO.StreamWriter($script:logPath, $false, (New-Object Text.UTF8Encoding($false)))
    $script:logWriter.AutoFlush = $true
}
function Invoke-ArkuzoLogRetention([string]$Directory, [string]$CurrentSession, [int]$MaxSessions, [double]$MaxTotalMB) {
    # Across sessions: keep the newest sessions while both caps hold (count and total
    # size); everything older goes. The current session's files are never deleted and
    # count first. Only this engine's own part files are touched, matched exactly
    # (Arkuzo-Pagefile-Requests.json and the Control Center's logs share the folder).
    # A file that can't be deleted (open elsewhere) is skipped. Never throws.
    $result = [ordered]@{ deletedFiles = 0; deletedMB = 0.0; keptSessions = 0; keptMB = 0.0; failed = 0 }
    try {
        if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return $result }
        $pattern = '\AArkuzo-(\d{8}-\d{6})-(\d+)-part\d+\.log\z'
        $files = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop | Where-Object { $_.Name -match $pattern })
        $sessions = @($files | Group-Object { $null = $_.Name -match $pattern; $matches[1] + '-' + $matches[2] } | ForEach-Object {
            [pscustomobject]@{ Tag = $_.Name; Stamp = $_.Name.Substring(0, 15); Files = @($_.Group); Bytes = [double](($_.Group | Measure-Object Length -Sum).Sum)
                Newest = (@($_.Group | Sort-Object LastWriteTimeUtc -Descending)[0]).LastWriteTimeUtc }
        } | Sort-Object @{ Expression = 'Stamp'; Descending = $true }, @{ Expression = 'Newest'; Descending = $true })
        $limitBytes = [double]$MaxTotalMB * 1MB
        $keptBytes = [double]0; $kept = 0; $full = $false
        foreach ($s in @($sessions | Where-Object { $_.Tag -ceq $CurrentSession })) { $keptBytes += $s.Bytes; $kept++ }
        foreach ($s in @($sessions | Where-Object { $_.Tag -cne $CurrentSession })) {
            if (-not $full -and $kept -lt $MaxSessions -and ($keptBytes + $s.Bytes) -le $limitBytes) { $keptBytes += $s.Bytes; $kept++; continue }
            $full = $true # Once a session doesn't fit, it and every older one go.
            foreach ($f in $s.Files) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $result.deletedFiles++; $result.deletedMB += $f.Length / 1MB }
                catch { $result.failed++ }
            }
        }
        $result.keptSessions = $kept; $result.keptMB = [math]::Round($keptBytes / 1MB, 1); $result.deletedMB = [math]::Round([double]$result.deletedMB, 1)
    } catch { $result.failed++ }
    return $result
}
function Step-ArkuzoLoopPhase([string]$Name) {
    # Charges the time since the last call to the running phase and starts $Name ('' = none).
    if ($null -eq $script:phaseClock) { $script:phaseClock = [Diagnostics.Stopwatch]::StartNew() }
    if ($null -eq $script:passPhaseMs) { $script:passPhaseMs = @{} }
    $now = $script:phaseClock.Elapsed.TotalMilliseconds
    if ($script:phaseName) { $script:passPhaseMs[$script:phaseName] = [double]$script:passPhaseMs[$script:phaseName] + ($now - [double]$script:phaseStartMs) }
    $script:phaseName = $Name; $script:phaseStartMs = $now
}
function Complete-ArkuzoLoopPass {
    # Folds one pass into the totals reported by the next RESOURCE_SAMPLE.
    Step-ArkuzoLoopPhase ''
    if ($null -eq $script:phaseStats) { $script:phaseStats = @{ passes = 0; totalMs = 0.0; maxMs = 0.0; phases = @{} } }
    $passMs = [double]0
    foreach ($name in @($script:passPhaseMs.Keys)) {
        $ms = [double]$script:passPhaseMs[$name]; $passMs += $ms
        $p = $script:phaseStats.phases[$name]
        if ($null -eq $p) { $p = @{ totalMs = 0.0; maxMs = 0.0 }; $script:phaseStats.phases[$name] = $p }
        $p.totalMs += $ms; if ($ms -gt $p.maxMs) { $p.maxMs = $ms }
    }
    $script:phaseStats.passes++; $script:phaseStats.totalMs += $passMs; if ($passMs -gt $script:phaseStats.maxMs) { $script:phaseStats.maxMs = $passMs }
    $script:passPhaseMs = @{}
}
function Get-ArkuzoLoopTimings {
    # Per-phase cost since the last call (milliseconds per pass: average and worst), then reset.
    $st = $script:phaseStats
    $script:phaseStats = $null
    if ($null -eq $st -or $st.passes -le 0) { return $null }
    $phases = [ordered]@{}
    foreach ($name in @($st.phases.Keys | Sort-Object)) {
        $phases[$name] = [ordered]@{ avgMs = [math]::Round([double]$st.phases[$name].totalMs / $st.passes, 1); maxMs = [math]::Round([double]$st.phases[$name].maxMs, 1) }
    }
    return [ordered]@{ passes = [int]$st.passes; passAvgMs = [math]::Round([double]$st.totalMs / $st.passes, 1); passMaxMs = [math]::Round([double]$st.maxMs, 1); phases = $phases }
}
function Step-ArkuzoDiagnosticLogPart {
    # Next part of this session's log; keep the current and four preceding parts.
    $script:logPart++
    if ($script:logPart -ge 5) {
        $expired = Join-Path $LogDirectory ("Arkuzo-$sessionTag-part$($script:logPart - 5).log")
        Remove-Item -LiteralPath $expired -Force -ErrorAction SilentlyContinue
    }
}
function Write-Diagnostic([string]$Kind, $Data) {
    # $logFailed says whether the LAST write failed: every audited step writes first and
    # checks it afterwards, so a closure still needs a successful log write. A failure
    # pauses logging for $LogRetrySec, then a new part is opened (the failed file may be
    # damaged or locked). One failure no longer blocks recovery for the rest of the session.
    if ($script:logFailed) {
        if ($null -eq $script:logRetryUtc) { $script:logRetryUtc = [datetime]::UtcNow.AddSeconds($(if ([double]$script:LogRetrySec -gt 0) { [double]$script:LogRetrySec } else { 5 })) }
        if ([datetime]::UtcNow -lt $script:logRetryUtc) { return }
        if ($null -ne $script:logWriter) { try { $script:logWriter.Dispose() } catch { }; $script:logWriter = $null }
        try { Step-ArkuzoDiagnosticLogPart } catch { }
    }
    try {
        if ($null -eq $script:logWriter) { Open-DiagnosticLog }
        if ($script:logWriter.BaseStream.Length -ge ([int64]$MaxLogMB * 1MB)) {
            $script:logWriter.Dispose(); $script:logWriter = $null
            Step-ArkuzoDiagnosticLogPart
            Open-DiagnosticLog
        }
        $record = [ordered]@{ time = (Get-Date).ToString('o'); session = $sessionTag; event = $Kind; data = $Data }
        $line = $record | ConvertTo-Json -Depth 12 -Compress
        if ($script:logFailed) {
            # First record of the reopened part says what happened (no error text: it may hold anything).
            $note = [ordered]@{ time = (Get-Date).ToString('o'); session = $sessionTag; event = 'LOG_WRITE_RECOVERED'; data = @{ failures = [int]$script:logFailureCount; part = [int]$script:logPart } }
            $script:logWriter.WriteLine(($note | ConvertTo-Json -Depth 4 -Compress))
        }
        $script:logWriter.WriteLine($line)
        $script:logFailed = $false; $script:logRetryUtc = $null
    } catch {
        $script:logFailed = $true
        $script:logFailureCount = [int]$script:logFailureCount + 1
        $script:logRetryUtc = [datetime]::UtcNow.AddSeconds($(if ([double]$script:LogRetrySec -gt 0) { [double]$script:LogRetrySec } else { 5 }))
        try { $script:dashboardIssues['log-write'] = @{ Message = "Logging failed: $($_.Exception.Message). Retrying in a new log file; recovery waits until a write succeeds."; Time = $(if ($null -ne $clock) { $clock.Elapsed.TotalSeconds } else { 0 }) } } catch { }
        if ($null -ne $script:logWriter) { try { $script:logWriter.Dispose() } catch { }; $script:logWriter = $null }
    }
}
function Write-ArkuzoFailureDiagnostic([string]$Kind, [Management.Automation.ErrorRecord]$Failure) {
    # Error messages, source text and invocation arguments can contain launch
    # tickets/cookies. Retain only bounded structural metadata, never raw text.
    try {
        $type = [string]$Failure.Exception.GetType().FullName
        if ($type.Length -gt 256) { $type = $type.Substring(0, 256) }
        $data = [ordered]@{
            pid = $PID; startTicks = $controllerStartTicks
            exceptionType = $type; hresult = $Failure.Exception.HResult
            category = [int]$Failure.CategoryInfo.Category
            line = $Failure.InvocationInfo.ScriptLineNumber
            column = $Failure.InvocationInfo.OffsetInLine
        }
        try { Write-Diagnostic $Kind $data } catch { $script:logFailed = $true }
        if ($script:logFailed) {
            # Two fixed overwritten files bound storage independently of the
            # rotating writer and keep cleanup from replacing fatal evidence.
            # Failure here must never replace the original terminating error.
            $record = [ordered]@{time=(Get-Date).ToString('o');session=$sessionTag;event=$Kind;data=$data}
            $text = $record | ConvertTo-Json -Depth 4 -Compress
            $file = if ($Kind -eq 'SAVER_FATAL_ERROR') { 'controller-failure.json' } else { 'controller-cleanup-failure.json' }
            [IO.File]::WriteAllText((Join-Path $LogDirectory $file), $text, (New-Object Text.UTF8Encoding($false)))
        }
    } catch { }
}
function Record-ClientExit([int]$ClientId, $State, [string]$Reason = 'No longer listed') {
    $exitCode = $null
    if ($null -ne $State.Watcher) {
        try { if ($State.Watcher.HasExited) { $exitCode = $State.Watcher.ExitCode } } catch { }
        finally { $State.Watcher.Dispose() }
    }
    Write-Diagnostic 'CLIENT_EXIT' @{
        pid = $ClientId; startTicks = $State.StartTicks; exitCode = $exitCode
        reason = $Reason; lastSample = $State.LastSnapshot; recoveryRequested = [bool]$State.RecoveryRequested
        note = 'An exit alone does not prove a crash; correlate with Windows events.'
    }
    # A member that is gone (it quit by itself, or a close whose bookkeeping failed
    # completed after all) may now have its Volt row count down.
    Set-ArkuzoFarmFreezeMemberStatus $State 'Exited'
    try { Register-ArkuzoNativeLaunchExit $ClientId $State } catch { }
    Register-ArkuzoExitedClientRecovery $ClientId $State
}
function Register-ArkuzoExitedClientRecovery([int]$ClientId, $State) {
    # When a whole server kicks the farm, recovery is serialized and most kicked
    # clients close themselves before their turn. A display change (remote desktop
    # disconnect, driver reload) freezes every client at once and they quit after
    # about three minutes. Their accounts still need the bounded Volt relaunch,
    # independent of restore_missing: the exit becomes a pending handoff instead
    # of a silently missing account.
    if ($MonitorOnly -or -not $ownsControllerMutex -or -not $restorePolicy.enabled -or -not $recoveryJournalHealthy -or $script:recoveryJournalCorrupt) { return }
    if ($null -eq $State -or $State.RecoveryRequested) { return }
    $recycle = $null -ne $State.HealthDecision -and $State.HealthDecision.Recycle
    $frozen = $null -ne $State.HangSince -and [double]$State.HangSince -ge 0
    if (-not $State.isDisconnected -and -not $recycle -and -not $frozen) { return }
    $key = [string]$State.BoundAccountId
    if ($key -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or $recoveryPending.ContainsKey($key)) { return }
    if ($restorePolicy.excluded_account_ids -contains $key -or ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey($key))) { return }
    $utc = [datetime]::UtcNow
    if (Test-ArkuzoAccountQuarantined $key $utc) { return }
    $entry = New-ArkuzoPendingEntry $key ([string]$State.BoundTrackerId) $ClientId ([long]$State.StartTicks)
    # The client is already gone: Volt's own relaunch gets restore_wait_sec from now.
    $entry.closedUtc = $utc.ToString('o')
    $previous = $recoveryPending.Clone()
    try {
        $script:recoveryPending[$key] = $entry
        Save-ArkuzoRecoveryJournal
        $why = if ($State.isDisconnected) { 'IN_GAME_DISCONNECT' } elseif ($recycle) { [string]$State.HealthDecision.Reason } else { 'UNRESPONSIVE_EXIT' }
        Write-Diagnostic 'EXITED_CLIENT_RECOVERY_QUEUED' @{ accountId = $key; pid = $ClientId; startTicks = $State.StartTicks; reason = $why; disconnectReason = $State.DisconnectReason
            note = 'Client closed itself while disconnected, frozen or waiting for recovery; its account is queued for a bounded Volt relaunch.' }
    } catch {
        $script:recoveryPending = $previous; $script:recoveryJournalHealthy = $false
        Warn-Throttled 'recovery-journal' 'Recovery outcome persistence/audit failed. Destructive recovery blocked.'
    }
}
# Pure crash-handler authorization; snapshots contain no process operations.
function Test-ArkuzoCrashHandlerIdentity($Snapshot, [string[]]$TrustedRoots) {
    try {
        if ($null -eq $Snapshot -or $Snapshot.Id -isnot [int] -or $Snapshot.Id -le 0 -or
            $Snapshot.StartTicks -isnot [long] -or $Snapshot.StartTicks -le 0 -or
            $Snapshot.Handle -isnot [IntPtr] -or $Snapshot.Handle -eq [IntPtr]::Zero -or
            $Snapshot.HasExited -isnot [bool] -or $Snapshot.HasExited -or
            $Snapshot.ProcessName -ne 'RobloxCrashHandler' -or $Snapshot.CimName -ne 'RobloxCrashHandler.exe' -or
            $Snapshot.CimId -ne $Snapshot.Id -or $Snapshot.SignatureStatus -cne 'Valid' -or
            $Snapshot.SignerSubject -notmatch '(?i)(?:^|,\s*)O=(?:"Roblox Corporation"|Roblox Corporation)(?:,|$)') { return $false }
        $paths = @($Snapshot.Path, $Snapshot.CimPath, $Snapshot.SignaturePath)
        foreach ($path in $paths) {
            if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\)') { return $false }
        }
        $imagePath = [IO.Path]::GetFullPath($Snapshot.Path)
        if ([IO.Path]::GetFileName($imagePath) -ne 'RobloxCrashHandler.exe' -or
            -not [string]::Equals($imagePath, [IO.Path]::GetFullPath($Snapshot.CimPath), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($imagePath, [IO.Path]::GetFullPath($Snapshot.SignaturePath), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        foreach ($root in $TrustedRoots) {
            if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\)') { continue }
            $prefix = [IO.Path]::GetFullPath($root).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
            if ($imagePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    } catch { return $false }
}
function Get-ArkuzoOrphanHandlerDecision($Handler, $Parent, [datetime]$NowUtc, $Monitor, $OwnsMutex, [string[]]$TrustedRoots, $Expected) {
    $reason = 'ReadOnly'; $close = $false
    try {
        if ($Monitor -is [bool] -and -not $Monitor -and $OwnsMutex -is [bool] -and $OwnsMutex) {
            $reason = 'IdentityUnverified'
            if ((Test-ArkuzoCrashHandlerIdentity $Handler $TrustedRoots) -and $null -ne $Expected -and
                $Handler.Id -eq $Expected.Id -and $Handler.StartTicks -eq $Expected.StartTicks -and $Handler.Handle -eq $Expected.Handle -and
                [string]::Equals([string]$Handler.Path, [string]$Expected.Path, [StringComparison]::OrdinalIgnoreCase) -and
                $Handler.ParentId -is [int] -and $Handler.ParentId -gt 0 -and $Handler.ParentId -ne $Handler.Id -and
                ($null -eq $Expected.ParentId -or $Handler.ParentId -eq $Expected.ParentId)) {
                $reason = 'YoungHandler'
                if (($NowUtc.ToUniversalTime().Ticks - $Handler.StartTicks) -gt [TimeSpan]::FromSeconds(60).Ticks) {
                    $reason = 'ParentUnverified'
                    if ($null -ne $Parent -and $Parent.QuerySucceeded -is [bool] -and $Parent.QuerySucceeded -and
                        $Parent.Id -eq $Handler.ParentId -and $Parent.Count -is [int]) {
                        if ($Parent.Count -eq 0 -and $Parent.AbsenceConfirmed -is [bool] -and $Parent.AbsenceConfirmed) { $close = $true; $reason = 'ParentAbsent' }
                        elseif ($Parent.Count -eq 1 -and $Parent.HasExited -is [bool] -and
                            $Parent.Handle -is [IntPtr] -and $Parent.Handle -ne [IntPtr]::Zero -and
                            $Parent.CimId -eq $Parent.Id -and $Parent.StartTicks -is [long] -and $Parent.StartTicks -gt 0 -and
                            $Parent.CimStartTicks -is [long] -and $Parent.CimStartTicks -gt 0 -and
                            ($Parent.StartTicks - $Parent.CimStartTicks) -ge 0 -and ($Parent.StartTicks - $Parent.CimStartTicks) -lt 10) {
                            if ($Parent.HasExited) {
                                if ($Parent.StartTicks -le $Handler.StartTicks) {
                                    $close = $true; $reason = 'ParentAbsent'
                                }
                            } else {
                                # WMI timestamps have microsecond precision; retain/recheck the exact .NET generation too.
                                $close = $Parent.StartTicks -gt $Handler.StartTicks
                                $reason = if ($close) { 'ParentPidReused' } else { 'HealthyParent' }
                            }
                        }
                    }
                }
            }
        }
    } catch { $close = $false; $reason = 'ObservationInvalid' }
    return [pscustomobject]@{ Close = $close; Reason = $reason }
}
function Test-ArkuzoOrphanHandlerExit($Expected, $Readback) {
    return ($null -ne $Expected -and $null -ne $Readback -and
        $Expected.Id -is [int] -and $Expected.Id -gt 0 -and $Expected.StartTicks -is [long] -and $Expected.StartTicks -gt 0 -and
        $Expected.Handle -is [IntPtr] -and $Expected.Handle -ne [IntPtr]::Zero -and
        $Readback.Id -eq $Expected.Id -and $Readback.StartTicks -eq $Expected.StartTicks -and $Readback.Handle -eq $Expected.Handle -and
        $Readback.WaitConfirmed -is [bool] -and $Readback.WaitConfirmed -and $Readback.HasExited -is [bool] -and $Readback.HasExited)
}
function Read-CrashEvents {
    try {
        $systemEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(2004); StartTime = (Get-Date).AddSeconds(-90) } -ErrorAction Stop)
        foreach ($event in $systemEvents) {
            $key = 'System-' + $event.RecordId
            if ($seenEventIds.ContainsKey($key)) { continue }
            $seenEventIds[$key] = $clock.Elapsed.TotalSeconds
            Write-Diagnostic 'SYSTEM_RESOURCE_EXHAUSTION' @{ id = 2004; created = $event.TimeCreated.ToString('o'); recordId = $event.RecordId; message = $event.Message }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { Warn-Throttled 'system-event-read' 'System memory event query unavailable.' }
    }
    try {
        # Overlap the window to catch delayed event delivery; deduplicate RecordId.
        $start = (Get-Date).AddSeconds(-90)
        if ($start -lt $sessionStart) { $start = $sessionStart }
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = @(1000,1001,1002); StartTime = $start } -ErrorAction Stop)
        foreach ($event in $events) {
            if ($seenEventIds.ContainsKey($event.RecordId)) { continue }
            $xml = $event.ToXml()
            if ($xml -notmatch '(?i)RobloxPlayerBeta|RobloxPlayer') { continue }
            $seenEventIds[$event.RecordId] = $clock.Elapsed.TotalSeconds
            Write-Diagnostic 'WINDOWS_APPLICATION_EVENT' @{
                id = $event.Id; recordId = $event.RecordId; provider = $event.ProviderName
                created = $event.TimeCreated.ToString('o'); message = $event.Message; xml = $xml
            }
        }
        foreach ($key in @($seenEventIds.Keys)) {
            if (($clock.Elapsed.TotalSeconds - $seenEventIds[$key]) -gt 180) { $seenEventIds.Remove($key) }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            Warn-Throttled 'event-read' "Windows event read failed: $($_.Exception.Message)"
        }
    }
}
Write-Diagnostic 'SESSION_START' @{
    version = $ArkuzoRuntimeVersion; health = $healthPolicy; recovery = $restorePolicy; pagefile = $pagefilePolicy
    mode = $Mode; advisoryMB = $MaxRamMB; softLimit = [bool]$SoftLimit
    trimming = [bool]$EnableTrimming; trimSeconds = $TrimEverySec; priority = $Priority
    memoryPriority = $MemoryPriority; adaptiveTrim = [bool]$AdaptiveTrim; pressureTrimAvailablePercent = $PressureTrimAvailablePercent
    totalPhysicalMB = $totalPhysicalMB; settingsError = $startupSettingsError
    logicalCpuPerClient = $CoresPerInstance; monitorOnly = [bool]$MonitorOnly
    logicalCpuCount = $cpuThreads; powershell = $PSVersionTable.PSVersion.ToString()
    os = [Environment]::OSVersion.VersionString; sampleSeconds = $LogEverySec
}

