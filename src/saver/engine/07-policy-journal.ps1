function Get-ArkuzoHealthPolicy($Config) {
    $defaults = @{ enabled = $false; private_limit_mb = 4096; hang_timeout_sec = 120; warmup_sec = 90; pressure_percent = 85; pressure_min_private_mb = 2048; cooldown_sec = 60; max_recycles_per_hour = 60; trim_spacing_sec = 2; startup_error_timeout_sec = 40; disconnect_timeout_sec = 5; private_limit_sustain_sec = 60
        # Farm-wide freeze fast path (see Get-ArkuzoFarmFreezeCandidate).
        farm_freeze_enabled = $true; farm_freeze_confirm_sec = 35; farm_freeze_min_clients = 3; farm_freeze_onset_window_sec = 15
        farm_freeze_max_cpu_percent = 5; farm_freeze_spacing_sec = 20; farm_freeze_refreeze_sec = 900
        # Remote sessions (see docs/remote-desktop.md): a freeze that starts within
        # farm_freeze_remote_window_sec after a remote-desktop disconnect is confirmed
        # after farm_freeze_remote_confirm_sec; a disconnected RDP session holds
        # recovery and launches for at most remote_hold_max_sec.
        farm_freeze_remote_confirm_sec = 20; farm_freeze_remote_window_sec = 60; remote_hold_max_sec = 600; keep_display_awake = $true }
    if ($null -ne $Config) {
        foreach ($key in @($defaults.Keys)) { if ($null -ne $Config.$key) { $defaults[$key] = $Config.$key } }
    }
    $ranges = @{ private_limit_mb = @(1024,16384); hang_timeout_sec = @(60,900); warmup_sec = @(60,900); pressure_percent = @(60,98); pressure_min_private_mb = @(1024,16384); cooldown_sec = @(30,300); max_recycles_per_hour = @(1,60); trim_spacing_sec = @(1,30); startup_error_timeout_sec = @(0,300); disconnect_timeout_sec = @(0,300); private_limit_sustain_sec = @(0,300)
        farm_freeze_confirm_sec = @(20,120); farm_freeze_min_clients = @(3,50); farm_freeze_onset_window_sec = @(5,60); farm_freeze_max_cpu_percent = @(1,10); farm_freeze_spacing_sec = @(10,60); farm_freeze_refreeze_sec = @(0,86400)
        farm_freeze_remote_confirm_sec = @(10,120); farm_freeze_remote_window_sec = @(10,300); remote_hold_max_sec = @(0,3600) }
    foreach ($key in $ranges.Keys) {
        $value = [double]$defaults[$key]
        if ($value -lt $ranges[$key][0] -or $value -gt $ranges[$key][1] -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "Invalid health setting: $key" }
    }
    if ($defaults.enabled -isnot [bool]) { throw 'health.enabled must be a JSON boolean' }
    if ($defaults.farm_freeze_enabled -isnot [bool]) { throw 'health.farm_freeze_enabled must be a JSON boolean' }
    if ($defaults.keep_display_awake -isnot [bool]) { throw 'health.keep_display_awake must be a JSON boolean' }
    return $defaults
}
function Set-ArkuzoConfigLockLimits($Policy) {
    # config_lock: production limits applied after validation, on load and on every
    # reload. A value already on the safe side is kept as it is.
    if ($null -eq $Policy) { return }
    $atLeast = [ordered]@{ pressure_percent = 88; pressure_min_private_mb = 4000; max_recycles_per_hour = 20
        # Farm-freeze fast path: no earlier than 30 s (some correlated stalls clear by
        # themselves within ~30 s) and Volt launches at least 15 s apart (closer
        # launches raise its startup notice).
        farm_freeze_confirm_sec = 30; farm_freeze_spacing_sec = 15
        # No multi-client freeze that followed a remote disconnect ever answered again.
        farm_freeze_remote_confirm_sec = 15 }
    $atMost = [ordered]@{ startup_error_timeout_sec = 5; disconnect_timeout_sec = 5; cooldown_sec = 90 }
    foreach ($key in $atLeast.Keys) { if ([double]$Policy[$key] -lt [double]$atLeast[$key]) { $Policy[$key] = $atLeast[$key] } }
    foreach ($key in $atMost.Keys) { if ([double]$Policy[$key] -gt [double]$atMost[$key]) { $Policy[$key] = $atMost[$key] } }
}
function Clear-VoltRecoveryCapability {
    foreach ($parent in @($script:voltParents.Values)) {
        if ($null -ne $parent.Process) { try { $parent.Process.Dispose() } catch { } }
    }
    $script:voltParents = @{}
}
function Update-VoltRecoveryCapability {
    param([switch]$SyncControl = $false)
    Clear-VoltRecoveryCapability
    if (Test-ArkuzoNativeProvider) {
        if ($SyncControl) { Update-ArkuzoVoltControl }
        $script:voltStatus = [pscustomobject]@{ safeToRecycle = [bool]($voltControlStatus.available -and $voltControlStatus.provider -ceq 'arkuzo'); reason = 'Arkuzo account vault' }
        return
    }
    $script:voltStatus = Get-ArkuzoVoltRecoveryStatus -Root $PSScriptRoot
    if ($SyncControl) {
        Update-ArkuzoVoltControl
    }
    foreach ($manager in @(Get-Process -Name tauri-app -ErrorAction SilentlyContinue)) {
        $retained = $false
        try {
            $handle = $manager.Handle # Open the exact process handle before verifying identity.
            $manager.Refresh()
            $exited = $manager.HasExited
            if ($handle -is [IntPtr] -and $handle -ne [IntPtr]::Zero -and $exited -is [bool] -and -not $exited -and [string]::Equals($manager.Path, $voltPath, [StringComparison]::OrdinalIgnoreCase)) {
                $script:voltParents[$manager.Id] = @{ Id = $manager.Id; Path = $manager.Path; StartTicks = $manager.StartTime.ToUniversalTime().Ticks; Process = $manager; Handle = $handle }
                $retained = $true
            }
        } catch { } finally { if (-not $retained) { try { $manager.Dispose() } catch { } } }
    }
}
function Test-ArkuzoLiveVoltParent($Parent) {
    try {
        if ($null -eq $Parent -or $null -eq $Parent.Process -or $Parent.Handle -isnot [IntPtr] -or $Parent.Handle -eq [IntPtr]::Zero) { return $false }
        $manager = $Parent.Process
        $manager.Refresh()
        if ($manager.Id -ne $Parent.Id -or
            $manager.StartTime.ToUniversalTime().Ticks -ne $Parent.StartTicks -or
            -not [string]::Equals($manager.Path, $Parent.Path, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $exited = $manager.HasExited
        return ($exited -is [bool] -and -not $exited)
    } catch { return $false }
}
function Save-ArkuzoAtomicJson([string]$Path, $Value) {
    $temp = $Path + '.' + $PID + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
        $saved = $false
        for ($attempt = 0; $attempt -lt 5 -and -not $saved; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($temp, $Path) }
                $saved = $true
            } catch {
                if ($attempt -ge 4) { throw }
                Start-Sleep -Milliseconds 60
            }
        }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
function Save-ArkuzoRecoveryJournal {
    if (-not $ownsControllerMutex -or $script:recoveryJournalCorrupt) { throw 'Recovery journal not owned/healthy' }
    $utc = [datetime]::UtcNow
    $script:recoveryAttempts = @($recoveryAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 })
    $script:launchAttempts = @($launchAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 })
    Save-ArkuzoAtomicJson $recoveryStatePath @{
        schemaVersion = 2; attempts = @($recoveryAttempts | ForEach-Object { $_.ToString('o') })
        launchAttempts = @($launchAttempts | ForEach-Object { $_.ToString('o') })
        pending = @($recoveryPending.Values); suspendedAccounts = @(); updatedUtc = $utc.ToString('o')
        quarantined = @(if ($null -ne $script:quarantinedAccounts) { $script:quarantinedAccounts.Values })
    }
    $script:recoveryJournalHealthy = $true
}
function Initialize-ArkuzoRecoveryJournal {
    # Load only while holding the sole destructive-controller mutex.
    $script:recoveryJournalHealthy = $false; $script:recoveryJournalCorrupt = $false; $script:recoveryAttempts = @(); $script:launchAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
    if (-not $ownsControllerMutex) { return }
    try {
        if (Test-Path -LiteralPath $recoveryStatePath) {
            $journal = [IO.File]::ReadAllText($recoveryStatePath) | ConvertFrom-Json
            if ($null -eq $journal.attempts) { throw 'Invalid recovery journal' }
            $script:recoveryAttempts = @($journal.attempts | ForEach-Object { ([datetime]$_).ToUniversalTime() })
            $script:launchAttempts = if ($journal.launchAttempts) { @($journal.launchAttempts | ForEach-Object { ([datetime]$_).ToUniversalTime() }) } else { @() }
            if ($null -ne $journal.pending) {
                foreach ($value in $journal.pending) {
                    if (-not $value.accountId -or -not $value.createdUtc) { throw 'Invalid pending journal entry' }
                    [datetime]$value.createdUtc | Out-Null
                    if ($value.closedUtc) { [datetime]$value.closedUtc | Out-Null }
                    if ($value.nextRetryUtc) { [datetime]$value.nextRetryUtc | Out-Null }
                    if ([int]$value.retryCount -lt 0) { throw 'Invalid retry count' }
                    $entry = @{}; foreach ($prop in $value.PSObject.Properties) { $entry[$prop.Name] = $prop.Value }
                    if ($value.missingSinceUtc) { [datetime]$value.missingSinceUtc | Out-Null }
                    # A monitor restart breaks continuity; never inherit a previous healthy timer.
                    $entry.readySinceUtc = $null; $entry.lastObservedUtc = $null
                    # Stale or synthetic missing entries without a verified prior process must not trigger auto-launch on startup.
                    if ([int]$value.oldPid -gt 0 -and [long]$value.oldStartTicks -gt 0) {
                        $script:recoveryPending[[string]$value.accountId] = $entry
                    }
                }
            }
            # Suspended accounts disappear on restart and are not saved practically; start clean
            $script:suspendedAccounts = @{}
            # Quarantine survives restarts so a crash loop cannot reset it. Malformed
            # rows are dropped: losing a quarantine only resumes normal recovery.
            foreach ($q in @($journal.quarantined)) {
                if ($null -eq $q -or [string]$q.accountId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') { continue }
                try { [datetime]$q.untilUtc | Out-Null } catch { continue }
                $row = @{}; foreach ($prop in $q.PSObject.Properties) { $row[$prop.Name] = $prop.Value }
                $script:quarantinedAccounts[[string]$q.accountId] = $row
            }
            $script:recoveryJournalHealthy = $true
        } else {
            $script:recoveryJournalHealthy = $true
            Save-ArkuzoRecoveryJournal
        }
    } catch {
        $script:recoveryAttempts = @(); $script:launchAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
        $script:recoveryJournalHealthy = $false; $script:recoveryJournalCorrupt = $true
    }
}
function Get-ArkuzoRecoveryHealthSample($Watcher, [string]$Reason, $CurrentState = $null) {
    if ($Reason -ceq 'VOLT_STARTUP_ERROR' -and $null -ne $CurrentState) {
        # Positive gameplay evidence must be refreshed during recovery, not only
        # in the main monitor loop. A tail is NEVER complete negative history.
        $CurrentState.StartupGameHistory = 'UNKNOWN'
        if (Test-ArkuzoClientIdentity $Watcher $Watcher.Id $CurrentState.StartTicks) {
            $boundLog = Find-RobloxProcessLog -TargetProcessId $Watcher.Id -TrackerId $CurrentState.TrackerId -StartTimeUtc $Watcher.StartTime.ToUniversalTime()
            if ($boundLog -and $CurrentState.LogPath -ceq $boundLog) {
                $offset = [ref]$CurrentState.LogOffset
                $text = Read-RobloxLogTail $boundLog $offset
                $CurrentState.LogOffset = $offset.Value
                if ($text -match '(?i)\[DFLog::NetworkClient\] Connection accepted from') {
                    $CurrentState.GameReady = $true; $CurrentState.EverGameReady = $true
                }
                $disconnect = Get-RobloxLogDisconnectReason $text
                if ($null -ne $disconnect -and $disconnect.Disconnected) {
                    $CurrentState.isDisconnected = $true; $CurrentState.GameReady = $false
                    $CurrentState.DisconnectReason = $disconnect.Reason; $CurrentState.DisconnectSource = 'log'
                }
            }
        }
    }
    $Watcher.Refresh()
    $window = $Watcher.MainWindowHandle
    # Native probes are bounded and do not send close/input messages.
    $responding = [Arkuzo.HealthNativeV1]::IsResponsive($window)
    $launchError = [Arkuzo.HealthNativeV1]::HasVoltStartupNotice($window)
    $isDisconnected = $false
    if ($null -ne $CurrentState -and $CurrentState.isDisconnected) {
        $isDisconnected = $true
    }
    $commitPercent = 0.0
    if ($Reason -eq 'SYSTEM_COMMIT_PRESSURE') { $commitPercent = (Get-ArkuzoSystemMemory).commitPercent }
    return @{
        privateMB = $Watcher.PrivateMemorySize64 / 1MB
        ageSec = ([DateTime]::UtcNow - $Watcher.StartTime.ToUniversalTime()).TotalSeconds
        responding = $responding; windowPresent = ($window -ne [IntPtr]::Zero); launchError = $launchError
        isDisconnected = $isDisconnected
        systemCommitPercent = $commitPercent; eligible = $true
    }
}
function Test-ArkuzoClientIdentity($Watcher, [int]$ClientId, [long]$StartTicks) {
    try {
        if ($null -eq $Watcher) { return $false }
        $Watcher.Refresh()
        $exited = $Watcher.HasExited
        # PowerShell can turn a failed .NET property getter into $null.
        return ($exited -is [bool] -and -not $exited -and $Watcher.Id -eq $ClientId -and
            $Watcher.StartTime.ToUniversalTime().Ticks -eq $StartTicks -and
            $Watcher.ProcessName -eq 'RobloxPlayerBeta')
    } catch { return $false }
}
function Get-ArkuzoBrowserTrackerId([string]$CommandLine) {
    if ([string]::IsNullOrEmpty($CommandLine)) { return $null }
    # Keep the command line in memory only: it also contains authentication tickets.
    $matches = [regex]::Matches($CommandLine, '(?i)(?<![a-z0-9_])browsertrackerid(?::|=|%3A)([0-9]+)(?=$|[\s+&"'']|%2b|%26|%20|%22)')
    if ($matches.Count -lt 1) { return $null }
    $unique = @($matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($unique.Count -ne 1) { return $null }
    return [string]$unique[0]
}
function Test-ArkuzoTargetRecovery($Watcher, [int]$ClientId, [long]$StartTicks) {
    try {
        if (-not (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks)) { return $false }
        $trackerId = $null
        try {
            $records = @(Get-CimInstance Win32_Process -Filter "ProcessId=$ClientId" -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($records.Count -eq 1 -and $records[0].ProcessId -eq $ClientId -and $records[0].Name -eq 'RobloxPlayerBeta.exe' -and $records[0].CommandLine -is [string]) {
                $trackerId = Get-ArkuzoBrowserTrackerId $records[0].CommandLine
            }
        } catch { }
        if ([string]::IsNullOrEmpty($trackerId) -and $null -ne $voltControlStatus -and $voltControlStatus.available -and $null -ne $voltControlStatus.accounts) {
            $m = @($voltControlStatus.accounts | Where-Object { [int]$_.processId -eq $ClientId })
            if ($m.Count -eq 1 -and -not [string]::IsNullOrEmpty($m[0].trackerId)) {
                $trackerId = [string]$m[0].trackerId
            }
        }
        # A retained exact process alive on both sides of the metadata query
        # binds the PID query to this generation, without timestamp/slot guesses.
        if ([string]::IsNullOrEmpty($trackerId) -or -not (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks)) { return $false }
        if (Test-ArkuzoNativeProvider) {
            return ($null -ne (Get-ArkuzoControlledAccount $trackerId $ClientId) -and (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks))
        }
        $target = Get-ArkuzoVoltRecoveryStatus -Root $PSScriptRoot -TrackerId $trackerId
        if ($null -eq (Get-ArkuzoControlledAccount $trackerId $ClientId)) { return $false }
        return ($target.safeToRecycle -is [bool] -and $target.safeToRecycle -and
            $target.targetReady -is [bool] -and $target.targetReady -and $target.matchedAccountCount -eq 1 -and
            (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks))
    } catch { return $false } # Never expose command lines, tickets, or account state in errors.
}
function Get-ArkuzoRestorePolicy($Config) {
    $p = @{ enabled=$false; restore_missing=$false; restore_wait_sec=90; relaunch_delay_sec=30; retry_base_sec=90; retry_max_sec=900; retry_max_per_hour=6; ready_stable_sec=30; excluded_account_ids=@()
        abandon_after_retries=8; abandon_after_sec=5400; quarantine_sec=1800 }
    if ($null -ne $Config) { foreach ($k in @($p.Keys)) { if ($null -ne $Config.$k) { $p[$k]=$Config.$k } } }
    foreach ($b in @('enabled','restore_missing')) { if ($p[$b] -isnot [bool]) { throw "recovery.$b must be a JSON boolean" } }
    $ranges=@{ restore_wait_sec=@(90,900); relaunch_delay_sec=@(30,120); retry_base_sec=@(90,900); retry_max_sec=@(180,3600); retry_max_per_hour=@(1,500); ready_stable_sec=@(30,300)
        abandon_after_retries=@(1,100); abandon_after_sec=@(900,86400); quarantine_sec=@(0,86400) }
    foreach ($k in $ranges.Keys) {
        $v=[double]$p[$k]
        if ([double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -lt $ranges[$k][0] -or $v -gt $ranges[$k][1] -or [math]::Floor($v) -ne $v) { throw "Invalid recovery setting: $k" }
    }
    if ($p.retry_max_sec -lt $p.retry_base_sec) { throw 'Retry maximum must cover base delay' }
    foreach ($id in @($p.excluded_account_ids)) { if ($id -notmatch '\A[0-9a-fA-F-]{36}\z') { throw 'Invalid excluded account identifier' } }
    return $p
}
function Get-ArkuzoProviderSetting($Config) {
    $value = $null
    if ($null -ne $Config -and $null -ne $Config.accounts) { $value = [string]$Config.accounts.provider }
    if ($value -cin @('auto', 'arkuzo', 'volt')) { return $value }
    return 'auto'
}
function Get-ArkuzoRetryDelay([int]$Attempt, $Policy) {
    return [int][math]::Min([double]$Policy.retry_max_sec, [double]$Policy.retry_base_sec * [math]::Pow(2,[math]::Min(20,[math]::Max(0,[int]($Attempt-1)))))
}
function ConvertTo-ArkuzoMemoryPriorityValue([string]$Name) {
    # Windows MEMORY_PRIORITY_* values. Lower priority pages are repurposed from
    # the standby list first under pressure; this neither caps nor frees memory.
    switch -Exact ($Name) {
        'VeryLow' { return [uint32]1 }
        'Low' { return [uint32]2 }
        'Medium' { return [uint32]3 }
        'BelowNormal' { return [uint32]4 }
        'Normal' { return [uint32]5 }
    }
    throw "Invalid memory priority: $Name"
}
function Get-ArkuzoTrimPlan($SystemMemory, [double]$TotalPhysicalMB, [int]$IntervalSec, [bool]$Adaptive, [double]$PressureAvailablePercent) {
    # Shorten the per-client interval only while physical RAM is scarce. The soft
    # target, per-client warmup and global spacing still apply; never below 15s.
    $plan = [pscustomobject]@{ IntervalSec = $IntervalSec; Pressure = $false; AvailablePercent = $null }
    if ($null -eq $SystemMemory -or $TotalPhysicalMB -le 0) { return $plan }
    $available = [double]$SystemMemory.availablePhysicalMB
    if ([double]::IsNaN($available) -or [double]::IsInfinity($available) -or $available -lt 0) { return $plan }
    $plan.AvailablePercent = [math]::Round([math]::Min([double]100, [double](100 * $available / $TotalPhysicalMB)), 1)
    if ($Adaptive -and $plan.AvailablePercent -lt $PressureAvailablePercent) {
        $plan.Pressure = $true
        $plan.IntervalSec = [int][math]::Min([double]$IntervalSec, [math]::Max([double]15, [math]::Ceiling($IntervalSec / 3)))
    }
    return $plan
}
function Test-ArkuzoPendingAbandon($Entry, [datetime]$NowUtc, $Policy) {
    # A recovery that keeps failing must not hold the shared handoff gate and
    # recycle budget forever. Returns the abandon reason, or $null to keep waiting.
    # An absent limit (an unvalidated or legacy policy object) disables that rule.
    if ($null -eq $Entry -or $null -eq $Policy) { return $null }
    if ([int]$Policy.abandon_after_retries -gt 0 -and [int]$Entry.retryCount -ge [int]$Policy.abandon_after_retries) { return 'RETRY_LIMIT' }
    if ([double]$Policy.abandon_after_sec -le 0) { return $null }
    try { $created = ([datetime]$Entry.createdUtc).ToUniversalTime() } catch { return $null }
    if (($NowUtc.ToUniversalTime() - $created).TotalSeconds -ge [double]$Policy.abandon_after_sec) { return 'AGE_LIMIT' }
    return $null
}
function Test-ArkuzoAccountQuarantined([string]$AccountId, [datetime]$NowUtc) {
    if (-not $AccountId -or $null -eq $script:quarantinedAccounts -or -not $script:quarantinedAccounts.ContainsKey($AccountId)) { return $false }
    try { $until = ([datetime]$script:quarantinedAccounts[$AccountId].untilUtc).ToUniversalTime() } catch { $until = [datetime]::MinValue }
    # The Arkuzo provider never parks an account; quarantine rows only apply to Volt.
    if ($NowUtc.ToUniversalTime() -lt $until) { return -not (Test-ArkuzoNativeProvider) }
    $script:quarantinedAccounts.Remove($AccountId)
    return $false
}
function Get-ArkuzoLiveResourceSettings($Settings, [hashtable]$Current) {
    # Validates the hot-reloadable resource settings. A hard working-set limit
    # still requires a restart. Invalid input throws; the caller keeps $Current.
    $next = @{} + $Current
    if ($null -eq $Settings) { return $next }
    $numbers = @{ target_ram_mb=@('MaxRamMB',128,32768); trim_every_sec=@('TrimEverySec',1,120); cores_per_instance=@('CoresPerInstance',1,64); pressure_trim_available_percent=@('PressureTrimAvailablePercent',5,60); poll_ms=@('PollMs',250,10000) }
    foreach ($key in $numbers.Keys) {
        $value = $Settings.$key
        if ($null -eq $value) { continue }
        if ($value -is [bool] -or $value -is [string] -or $value -isnot [ValueType]) { throw "settings.$key must be a number" }
        $n = [double]$value
        if ([double]::IsNaN($n) -or $n -lt $numbers[$key][1] -or $n -gt $numbers[$key][2] -or [math]::Floor($n) -ne $n) { throw "settings.$key is out of range" }
        $next[$numbers[$key][0]] = [int]$n
    }
    foreach ($pair in @(@('trim_enabled','EnableTrimming'), @('adaptive_trim','AdaptiveTrim'), @('minimize_on_launch','Minimize'))) {
        $value = $Settings.($pair[0])
        if ($null -eq $value) { continue }
        if ($value -isnot [bool]) { throw "settings.$($pair[0]) must be a JSON boolean" }
        $next[$pair[1]] = $value
    }
    if ($null -ne $Settings.priority) {
        if ([string]$Settings.priority -cnotin @('Idle','BelowNormal','Normal')) { throw 'settings.priority is invalid' }
        $next.Priority = [string]$Settings.priority
    }
    if ($null -ne $Settings.memory_priority) {
        ConvertTo-ArkuzoMemoryPriorityValue ([string]$Settings.memory_priority) | Out-Null
        $next.MemoryPriority = [string]$Settings.memory_priority
    }
    return $next
}
