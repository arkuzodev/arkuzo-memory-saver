function Warn-Throttled([string]$Key, [string]$Message) {
    if (-not $warnings.ContainsKey($Key) -or ($clock.Elapsed.TotalSeconds - $warnings[$Key]) -ge 30) {
        $dashboardIssues[$Key] = @{ Message = $Message; Time = $clock.Elapsed.TotalSeconds }
        $warnings[$Key] = $clock.Elapsed.TotalSeconds
        Write-Diagnostic 'WARNING' @{ key = $Key; message = $Message }
    }
}

function Initialize-ArkuzoNativePrivileges {
    $status = [pscustomobject][ordered]@{
        attempted = $false; available = $null; reason = 'ControllerMutexNotOwned'; privileges = @()
        note = 'Only privileges already assigned to the current process token can be enabled. No elevation is requested; target protections still apply. Hard working-set limits remain opt-in.'
    }
    if ($MonitorOnly) { $status.reason = 'MonitorOnly' }
    elseif ($ownsControllerMutex) {
        $status.attempted = $true; $status.reason = 'Completed'
        foreach ($name in @('SeDebugPrivilege', 'SeIncreaseWorkingSetPrivilege')) {
            try { $status.privileges += [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege($name) }
            catch {
                # Unexpected managed/PInvoke failures must also remain visible and best-effort.
                $failure = $_.Exception
                while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
                $code = $null; $message = $failure.Message
                if ($failure -is [ComponentModel.Win32Exception]) {
                    $code = $failure.NativeErrorCode
                    $message = 'Win32 ' + $code + ': ' + $message
                }
                $status.privileges += [pscustomobject]@{
                    Name=$name; Status='Failed'; Succeeded=$false; Present=$null; Enabled=$false
                    Win32Error=$code; Operation='EnableCurrentProcessPrivilege'; Message=$message; AdjustmentReturnedSuccess=$null
                }
            }
        }
        $status.available = @($status.privileges | Where-Object { -not $_.Succeeded -or -not $_.Enabled }).Count -eq 0
    }
    $script:nativePrivilegeInitialization = $status
    Write-ArkuzoNativePrivilegeStatus $status
    return $status
}

function Write-ArkuzoNativePrivilegeStatus($Status) {
    Write-Diagnostic 'NATIVE_PRIVILEGES' $Status
    if (-not $Status.attempted) { return }
    foreach ($privilege in @($Status.privileges)) {
        # Normal (non-administrator) accounts don't hold SeDebugPrivilege at all; the saver
        # works without it. Only a privilege that is held but can't be enabled is worth a notice.
        if ($privilege.Status -ceq 'NotAssigned' -or $privilege.Present -eq $false) { continue }
        if (-not $privilege.Succeeded -or -not $privilege.Enabled) {
            Warn-Throttled ('native-privilege-' + $privilege.Name) ($privilege.Name + ' unavailable: ' + $privilege.Message + ' Native operations remain best-effort; process protections still apply.')
        }
    }
}

# ---------------------------------------------------------------------------
# Resource settings of a client (priority, CPU affinity, memory priority, working-set limits).
# Three blue screens (10-11 Nov, bugcheck 0x1E, STATUS_PROCESS_IS_TERMINATING inside ntoskrnl)
# each hit while a RobloxPlayerBeta.exe the saver had started 2-5 s earlier was exiting during
# startup and another process was working on it. A client is therefore left alone until it has
# lived health.config_grace_sec and has a window (or answered once); every native call is
# skipped for a client that has exited or that the saver is closing.
# ---------------------------------------------------------------------------
function Test-ArkuzoClientClosing($State) {
    return ($null -ne $State -and ([bool]$State.RecoveryRequested -or [bool]$State.Closing))
}
function Test-ArkuzoClientLive($Client) {
    # Refresh, then HasExited (WaitForSingleObject on the process handle, timeout 0).
    try { $Client.Refresh(); $exited = $Client.HasExited; return ($exited -is [bool] -and -not $exited) } catch { return $false }
}
function Test-ArkuzoClientConfigReady($State, [double]$AgeSec, [bool]$WindowPresent, [double]$GraceSec) {
    # Pure apart from the latch on $State. Ready once the client is $GraceSec old and has a window
    # or has answered; it stays ready (a later missing window does not undo the settings).
    if ($null -eq $State) { return $false }
    if (Test-ArkuzoClientClosing $State) { return $false }
    if ($State.ConfigReady) { return $true }
    if ($AgeSec -lt $GraceSec -or -not ($WindowPresent -or [bool]$State.EverResponded)) { return $false }
    $State.ConfigReady = $true
    return $true
}
# One small function per native call, so tests can stand in for them.
function Read-ArkuzoClientLimits($Client) { return [Arkuzo.MemorySaverNativeV1]::ReadLimits($Client.Handle) }
function Read-ArkuzoClientMemoryPriority($Client) { return [Arkuzo.MemorySaverNativeV1]::ReadMemoryPriority($Client.Handle) }
function Set-ArkuzoClientMemoryPriority($Client, [uint32]$Value) { [Arkuzo.MemorySaverNativeV1]::SetMemoryPriority($Client.Handle, $Value) }
function Set-ArkuzoClientLimits($Client, [uint64]$Min, [uint64]$Max, [uint32]$Flags) { [Arkuzo.MemorySaverNativeV1]::SetLimits($Client.Handle, $Min, $Max, $Flags) }
function Get-ArkuzoClientAffinityMask($Original, [int]$Slot, [int]$Cores) { return [Arkuzo.MemorySaverNativeV1]::Affinity(([IntPtr]$Original).ToInt64(), $Slot, $Cores) }
function Invoke-ArkuzoClientTrim($Client) { [Arkuzo.MemorySaverNativeV1]::Trim($Client.Handle) }
function Invoke-ArkuzoClientConfiguration($Client, $State, [double]$Now) {
    # Caller: Test-ArkuzoClientConfigReady. The first time, the original values are read (the
    # moment before anything changes, so restoring on exit puts back what Roblox had). Then
    # priority, affinity, memory priority and the opt-in hard limit are applied; each step first
    # checks that the client still runs and is not being closed. Returns $false when nothing ran.
    if ((Test-ArkuzoClientClosing $State) -or -not (Test-ArkuzoClientLive $Client)) { return $false }
    if (-not $State.Configured) {
        $State.Priority = $Client.PriorityClass; $State.Affinity = $Client.ProcessorAffinity
        $State.Limits = $(try { Read-ArkuzoClientLimits $Client } catch { $null })
        $State.MemoryPriority = $(try { Read-ArkuzoClientMemoryPriority $Client } catch { $null })
        $State.Configured = $true
        Write-Diagnostic 'RESOURCE_CONFIGURATION_REQUESTED' @{ pid = $Client.Id; priority = $Priority; logicalCpu = $CoresPerInstance; memoryPriority = $MemoryPriority; hardCap = (-not [bool]$SoftLimit); targetMB = $MaxRamMB
            originalPriority = [string]$State.Priority; originalAffinity = $(try { ([IntPtr]$State.Affinity).ToInt64() } catch { $null }); graceSec = $healthPolicy.config_grace_sec }
    }
    foreach ($operation in @('Priority','Affinity','MemoryPriority','Limits')) {
        if ((Test-ArkuzoClientClosing $State) -or -not (Test-ArkuzoClientLive $Client)) { break }
        try {
            switch ($operation) {
                'Priority' { $Client.PriorityClass = $Priority }
                'Affinity' { if ($null -ne $State.Affinity) { $Client.ProcessorAffinity = Get-ArkuzoClientAffinityMask $State.Affinity $State.Slot $CoresPerInstance } }
                'MemoryPriority' {
                    # Only change what can be restored on exit.
                    if ($null -ne $State.MemoryPriority) {
                        Set-ArkuzoClientMemoryPriority $Client (ConvertTo-ArkuzoMemoryPriorityValue $MemoryPriority)
                        $State.MemoryPriorityChanged = $true
                    }
                }
                'Limits' {
                    if (-not $SoftLimit -and $null -ne $State.Limits) {
                        Set-ArkuzoClientLimits $Client 1MB $maxBytes $limitFlags
                        $State.LimitsChanged = $true
                    }
                }
            }
        } catch { Warn-Throttled "$($Client.Id)-$operation" "PID $($Client.Id): $operation failed: $($_.Exception.Message)" }
    }
    $State.LastConfig = $Now
    return $true
}

function Restore-Client($Client, $State) {
    # Start time prevents restoring an unrelated process after PID reuse.
    if ($Client.StartTime.ToUniversalTime().Ticks -ne $State.StartTicks -or $MonitorOnly) { return }
    # A client still inside its startup grace was never configured: nothing to put back.
    $operations = if ($State.Configured) { @('Priority','Affinity','MemoryPriority','Limits') } else { @() }
    foreach ($operation in $operations) {
        if (-not (Test-ArkuzoClientLive $Client)) { break }
        try {
            switch ($operation) {
                'Priority' { if ($null -eq $State.Priority) { continue }; $Client.PriorityClass = $State.Priority }
                'Affinity' { if ($null -eq $State.Affinity) { continue }; $Client.ProcessorAffinity = $State.Affinity }
                'MemoryPriority' {
                    if (-not $State.MemoryPriorityChanged -or $null -eq $State.MemoryPriority) { continue }
                    Set-ArkuzoClientMemoryPriority $Client ([uint32]$State.MemoryPriority)
                }
                'Limits' {
                    if (-not $State.LimitsChanged -or $null -eq $State.Limits) { continue }
                    # Explicitly clear introduced hard limits when originally absent.
                    $restoreFlags = [uint32]0
                    if (($State.Limits[2] -band 1) -ne 0) { $restoreFlags = $restoreFlags -bor 1 }
                    else { $restoreFlags = $restoreFlags -bor 2 }
                    if (($State.Limits[2] -band 4) -ne 0) { $restoreFlags = $restoreFlags -bor 4 }
                    else { $restoreFlags = $restoreFlags -bor 8 }
                    Set-ArkuzoClientLimits $Client $State.Limits[0] $State.Limits[1] $restoreFlags
                }
            }
            Write-Diagnostic 'SETTING_RESTORED' @{ pid = $Client.Id; setting = $operation }
        } catch {
            Write-Diagnostic 'RESTORE_ERROR' @{ pid = $Client.Id; setting = $operation; message = $_.Exception.Message }
            Write-Warning "PID $($Client.Id): could not restore $operation settings: $($_.Exception.Message)"
        }
    }
    if ($State.MinimizedByUs -and $Client.MainWindowHandle -ne [IntPtr]::Zero) {
        [Arkuzo.MemorySaverNativeV1]::ShowWindowAsync($Client.MainWindowHandle, 9) | Out-Null
    }
}

