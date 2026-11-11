function Invoke-ArkuzoHealthObservation {
    # Cooperative, read-only service: never perform launcher/log/name IO here.
    # Round-robin and a half-second work slice prevent a large client set from
    # monopolizing a probe wait. Oversized sets still fail closed on real gaps.
    if ($script:observationBusy -or $null -eq $script:tracked -or $null -eq $clock) { return }
    $script:observationBusy = $true
    $work = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ids = @($script:tracked.Keys | Sort-Object)
        if ($ids.Count -eq 0) { return }
        for ($i=0; $i -lt $ids.Count -and $work.Elapsed.TotalMilliseconds -lt 500; $i++) {
            $index = [int]$script:observationCursor % $ids.Count
            $script:observationCursor = ($index + 1) % $ids.Count
            $id = [int]$ids[$index]; $state = $script:tracked[$id]
            if ($state.ParentId -le 0 -and $null -ne $script:voltParents -and $script:voltParents.Count -eq 1) {
                $state.ParentId = [int](@($script:voltParents.Keys)[0])
            }
            $now = $clock.Elapsed.TotalSeconds
            # A frozen window costs a 100 ms probe and the main loop probes every client once
            # per pass; the slice re-probes a frozen one only when its last sample is 10 s old
            # (a long wait), which keeps its timers well inside the 30 s gap they tolerate.
            $minGap = if ($null -ne $state.LastSnapshot -and $state.LastSnapshot['windowPresent'] -eq $true -and $state.LastSnapshot['responding'] -eq $false) { 10 } else { 1 }
            if ($state.RecoveryRequested -or ($null -ne $state.LastHealthSampleTime -and
                $now -ge [double]$state.LastHealthSampleTime -and ($now - [double]$state.LastHealthSampleTime) -lt $minGap)) { continue }
            try {
                if (-not (Test-ArkuzoClientIdentity $state.Watcher $id $state.StartTicks)) { Reset-ArkuzoHealthSample $state; continue }
                $reason = if ($state.isDisconnected) { 'IN_GAME_DISCONNECT' } else { '' }
                $sample = Get-ArkuzoRecoveryHealthSample $state.Watcher $reason $state
                if (-not (Test-ArkuzoClientIdentity $state.Watcher $id $state.StartTicks)) { Reset-ArkuzoHealthSample $state; continue }
                $sample.systemCommitPercent = if ($null -ne $systemMemory) { $systemMemory.commitPercent } else { 0 }
                $sample.eligible = (-not $MonitorOnly -and $healthPolicy.enabled -and $voltStatus.safeToRecycle -and
                    (Test-ArkuzoClientOwnership $state))
                # Timestamp after collecting; never replay or synthesize missed samples.
                $state.HealthDecision = Get-ArkuzoHealthDecision $state $sample $healthPolicy $clock.Elapsed.TotalSeconds
                if (-not $sample.windowPresent -or -not $sample.responding -or $sample.launchError -or
                    $sample.isDisconnected -or -not $state.GameReady) { Clear-ArkuzoOutcomeObservation $state }
                if ($null -eq $state.LastSnapshot) { $state.LastSnapshot = @{pid=$id} }
                foreach ($key in $sample.Keys) { $state.LastSnapshot[$key] = $sample[$key] }
                $state.LastSnapshot.state = $state.HealthDecision.Status
                $state.LastSnapshot.sampleTime = [datetime]::UtcNow.ToString('o')
                # Do not advance outcome freshness: this service has not tailed
                # the game log. Only the complete main-loop sample can do that.
            } catch { Reset-ArkuzoHealthSample $state }
        }
    } finally { $work.Stop(); $script:observationBusy = $false }
}
function Wait-ArkuzoObservedProcess($Process, [int]$TimeoutMs) {
    # Keep the original total timeout, including observation work. No asynchronous
    # runspace owns client handles and disposal never waits for a background task.
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($deadline.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
            if ($Process.WaitForExit(0)) { return $true }
            Invoke-ArkuzoHealthObservation
            $remaining = $TimeoutMs - [int][math]::Ceiling($deadline.Elapsed.TotalMilliseconds)
            if ($remaining -le 0) { return $Process.WaitForExit(0) }
            if ($Process.WaitForExit([math]::Min(100, [int]$remaining))) { return $true }
        }
        return $Process.WaitForExit(0)
    } finally { $deadline.Stop() }
}
function Get-ArkuzoVoltRecoveryStatus([string]$Root, [string]$TrackerId) {
    $child = $null
    try {
        $probe = Join-Path $Root 'Arkuzo-Volt-Probe.py'
        if (-not (Test-Path -LiteralPath $probe)) { throw 'Probe unavailable' }
        $python = Get-Command python3.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $python) { $python = Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $python.Source; $info.Arguments = '"' + $probe + '"'
        if ($PSBoundParameters.ContainsKey('TrackerId')) {
            if (-not [regex]::IsMatch($TrackerId, '\A[0-9]+\z')) { throw 'Invalid target metadata' }
            $info.Arguments += ' --tracker-id ' + $TrackerId # Only non-secret digits, never command lines/tickets.
        }
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $child = [Diagnostics.Process]::Start($info)
        if (-not (Wait-ArkuzoObservedProcess $child 3000)) { $child.Kill(); throw 'Probe timeout' }
        if ($child.ExitCode -ne 0) { throw 'Probe failed' }
        $result = $child.StandardOutput.ReadToEnd() | ConvertFrom-Json
        if ($null -eq $result.safeToRecycle) { throw 'Invalid probe result' }
        return $result
    } catch { return [pscustomobject]@{ safeToRecycle = $false; reason = 'Volt recovery probe unavailable' } }
    finally { if ($null -ne $child) { $child.Dispose() } }
}
