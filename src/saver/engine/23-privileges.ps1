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

function Restore-Client($Client, $State) {
    # Start time prevents restoring an unrelated process after PID reuse.
    if ($Client.StartTime.ToUniversalTime().Ticks -ne $State.StartTicks -or $MonitorOnly) { return }
    foreach ($operation in @('Priority','Affinity','MemoryPriority','Limits')) {
        try {
            switch ($operation) {
                'Priority' { $Client.PriorityClass = $State.Priority }
                'Affinity' { $Client.ProcessorAffinity = $State.Affinity }
                'MemoryPriority' {
                    if (-not $State.MemoryPriorityChanged -or $null -eq $State.MemoryPriority) { continue }
                    [Arkuzo.MemorySaverNativeV1]::SetMemoryPriority($Client.Handle, [uint32]$State.MemoryPriority)
                }
                'Limits' {
                    if (-not $State.LimitsChanged) { continue }
                    # Explicitly clear introduced hard limits when originally absent.
                    $restoreFlags = [uint32]0
                    if (($State.Limits[2] -band 1) -ne 0) { $restoreFlags = $restoreFlags -bor 1 }
                    else { $restoreFlags = $restoreFlags -bor 2 }
                    if (($State.Limits[2] -band 4) -ne 0) { $restoreFlags = $restoreFlags -bor 4 }
                    else { $restoreFlags = $restoreFlags -bor 8 }
                    [Arkuzo.MemorySaverNativeV1]::SetLimits($Client.Handle, $State.Limits[0], $State.Limits[1], $restoreFlags)
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

