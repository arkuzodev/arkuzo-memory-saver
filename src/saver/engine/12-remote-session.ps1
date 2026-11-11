# ---------------------------------------------------------------------------
# Remote sessions (docs/remote-desktop.md). Chrome Remote Desktop streams the
# console session, so Windows itself records nothing when its viewer leaves:
# the host's own Application-log events (source "chromoting", 1 connected,
# 2 disconnected) are the only signal. RDP shows up as this process's own WTS
# session state. Everything here is read-only except the process-scoped
# keep-awake request, which Windows drops when the saver exits.
# ---------------------------------------------------------------------------
$script:remoteProbe = $null; $script:remoteProbeSec = $null; $script:lastRemoteDisconnectSec = $null
$script:remoteHoldSinceSec = $null; $script:keepAwakeOn = $false; $script:keepAwakeFailed = $false
$script:crdBookmark = $null; $script:crdLast = $null; $script:crdServiceCheckSec = $null; $script:crdInstalled = $false
function Read-ArkuzoChromotingEvent([double]$NowSec) {
    # Newest Chrome Remote Desktop connect (1) or disconnect (2) as @{ id; utc }, or $null.
    # A filtered search of the Application log costs up to ~150 ms when the host
    # has logged nothing lately, so it runs once; afterwards only the records
    # written since are read, from a bookmark (~0 ms). Only provider, id and time
    # are read: the message names the viewer's account and is never touched.
    if ($null -eq $script:crdServiceCheckSec -or ($NowSec - [double]$script:crdServiceCheckSec) -ge 600) {
        $script:crdServiceCheckSec = $NowSec
        $script:crdInstalled = ($null -ne (Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue))
        if (-not $script:crdInstalled) { $script:crdBookmark = $null; $script:crdLast = $null }
    }
    if (-not $script:crdInstalled) { return $null }
    $logName = [Diagnostics.Eventing.Reader.PathType]::LogName
    try {
        if ($null -eq $script:crdBookmark) {
            # Bookmark first: an event written meanwhile is read again next time, never missed.
            $newest = New-Object Diagnostics.Eventing.Reader.EventLogQuery('Application', $logName, '*'); $newest.ReverseDirection = $true
            $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($newest)
            try { $top = $reader.ReadEvent() } finally { $reader.Dispose() }
            if ($null -ne $top) { try { $script:crdBookmark = $top.Bookmark } finally { $top.Dispose() } }
            $query = New-Object Diagnostics.Eventing.Reader.EventLogQuery('Application', $logName, "*[System[Provider[@Name='chromoting'] and (EventID=1 or EventID=2)]]")
            $query.ReverseDirection = $true
            $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($query)
            try { $record = $reader.ReadEvent() } finally { $reader.Dispose() }
            if ($null -ne $record) { try { $script:crdLast = @{ id = [int]$record.Id; utc = ([datetime]$record.TimeCreated).ToUniversalTime() } } finally { $record.Dispose() } }
        } else {
            $all = New-Object Diagnostics.Eventing.Reader.EventLogQuery('Application', $logName, '*')
            $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($all, $script:crdBookmark)
            try {
                for ($i = 0; $i -lt 5000; $i++) {
                    $record = $reader.ReadEvent()
                    if ($null -eq $record) { break }
                    try {
                        $script:crdBookmark = $record.Bookmark
                        if ($record.ProviderName -ceq 'chromoting' -and ($record.Id -eq 1 -or $record.Id -eq 2)) {
                            $script:crdLast = @{ id = [int]$record.Id; utc = ([datetime]$record.TimeCreated).ToUniversalTime() }
                        }
                    } finally { $record.Dispose() }
                }
            } finally { $reader.Dispose() }
        }
    } catch { $script:crdBookmark = $null } # Log cleared or unreadable: search again next time.
    return $script:crdLast
}
function Get-ArkuzoRemoteProbe {
    $n = [Arkuzo.RemoteSessionNativeV1]
    $session = $n::OwnSessionId()
    $crd = Read-ArkuzoChromotingEvent $(if ($null -ne $clock) { [double]$clock.Elapsed.TotalSeconds } else { 0 })
    return @{ sessionId = $session; consoleSessionId = $n::ConsoleSessionId(); connectState = $n::ConnectState($session); protocol = $n::ClientProtocol($session)
        lockState = $n::LockState($session); inputDesktop = $n::InputDesktopName(); display = ($n::DisplayMode() -join 'x'); monitors = $n::MonitorCount()
        crdEventId = $(if ($null -ne $crd) { $crd.id } else { $null }); crdEventUtc = $(if ($null -ne $crd) { $crd.utc } else { $null })
        bootUtc = [datetime]::UtcNow.AddMilliseconds(-[double]$n::UptimeMs()) }
}
function Test-ArkuzoCrdConnected($Probe) {
    # Pure. A connect logged before the last boot is stale: a restart while
    # connected leaves no disconnect event behind.
    if ($null -eq $Probe -or $null -eq $Probe.crdEventId -or [int]$Probe.crdEventId -ne 1) { return $false }
    return ($null -eq $Probe.bootUtc -or $null -eq $Probe.crdEventUtc -or [datetime]$Probe.crdEventUtc -gt [datetime]$Probe.bootUtc)
}
function ConvertTo-ArkuzoRemoteRecord($Probe) {
    if ($null -eq $Probe) { return $null }
    $states = @{ 0 = 'active'; 1 = 'connected'; 2 = 'connectQuery'; 3 = 'shadow'; 4 = 'disconnected'; 5 = 'idle'; 6 = 'listen'; 7 = 'reset'; 8 = 'down'; 9 = 'init' }
    $state = [int]$Probe.connectState
    return @{ sessionId = $Probe.sessionId; onConsole = ([int]$Probe.sessionId -ge 0 -and [int]$Probe.sessionId -eq [int]$Probe.consoleSessionId)
        sessionState = $(if ($states.ContainsKey($state)) { $states[$state] } else { 'unknown' })
        protocol = $(switch ([int]$Probe.protocol) { 0 { 'console' } 2 { 'rdp' } default { 'unknown' } })
        locked = $(switch ([int]$Probe.lockState) { 0 { $true } 1 { $false } default { $null } })
        inputDesktop = $Probe.inputDesktop; display = $Probe.display; monitors = $Probe.monitors
        chromeRemoteDesktop = $(if ($null -eq $Probe.crdEventId) { $null } else {
            @{ connected = (Test-ArkuzoCrdConnected $Probe); changedUtc = $(if ($Probe.crdEventUtc) { ([datetime]$Probe.crdEventUtc).ToString('o') } else { $null }) } }) }
}
function Compare-ArkuzoRemoteProbe($Previous, $Current) {
    # Pure. What changed between two probes, as stable codes for the log.
    if ($null -eq $Previous -or $null -eq $Current) { return @() }
    $changes = @()
    if ($Current.crdEventId -ne $Previous.crdEventId -or $Current.crdEventUtc -ne $Previous.crdEventUtc) {
        if ([int]$Current.crdEventId -eq 1) { $changes += 'CRD_CONNECTED' } elseif ([int]$Current.crdEventId -eq 2) { $changes += 'CRD_DISCONNECTED' }
    }
    if ([int]$Current.connectState -ne [int]$Previous.connectState) {
        if ([int]$Current.connectState -eq 4) { $changes += 'SESSION_DISCONNECTED' }
        elseif ([int]$Previous.connectState -eq 4) { $changes += 'SESSION_RECONNECTED' }
        else { $changes += 'SESSION_STATE_CHANGED' }
    }
    $wasConsole = ([int]$Previous.sessionId -eq [int]$Previous.consoleSessionId); $isConsole = ([int]$Current.sessionId -eq [int]$Current.consoleSessionId)
    if ($isConsole -ne $wasConsole) { $changes += $(if ($isConsole) { 'SESSION_ON_CONSOLE' } else { 'SESSION_LEFT_CONSOLE' }) }
    if ([int]$Current.protocol -ne [int]$Previous.protocol) { $changes += 'PROTOCOL_CHANGED' }
    if ([int]$Current.lockState -ne [int]$Previous.lockState) {
        if ([int]$Current.lockState -eq 0) { $changes += 'SESSION_LOCKED' } elseif ([int]$Current.lockState -eq 1) { $changes += 'SESSION_UNLOCKED' }
    }
    if ([string]$Current.inputDesktop -cne [string]$Previous.inputDesktop) { $changes += 'INPUT_DESKTOP_CHANGED' }
    if ([string]$Current.display -cne [string]$Previous.display) { $changes += 'DISPLAY_MODE_CHANGED' }
    if ([int]$Current.monitors -ne [int]$Previous.monitors) { $changes += 'MONITOR_COUNT_CHANGED' }
    return $changes
}
function Get-ArkuzoRemoteDisconnectSec($Probe, [datetime]$NowUtc, [double]$NowSec) {
    # Pure. The saver-clock time of the newest Chrome Remote Desktop disconnect, or $null.
    if ($null -eq $Probe -or $null -eq $Probe.crdEventId -or [int]$Probe.crdEventId -ne 2 -or $null -eq $Probe.crdEventUtc) { return $null }
    return $NowSec - [math]::Max([double]0, [double]($NowUtc - [datetime]$Probe.crdEventUtc).TotalSeconds)
}
function Test-ArkuzoRemoteHold([double]$NowSec) {
    # While this saver's own session is disconnected (RDP), clients cannot render
    # and replacements would land in the same session: hold launches and
    # recovery, for at most remote_hold_max_sec.
    if ($null -eq $script:remoteHoldSinceSec -or $null -eq $healthPolicy -or [double]$healthPolicy.remote_hold_max_sec -le 0) { return $false }
    return (($NowSec - [double]$script:remoteHoldSinceSec) -lt [double]$healthPolicy.remote_hold_max_sec)
}
function Update-ArkuzoRemoteState($Probe, [datetime]$NowUtc, [double]$NowSec) {
    # Applies one probe; returns the change codes. Separate from the probe so tests drive it.
    $previous = $script:remoteProbe; $script:remoteProbe = $Probe
    $changes = @(Compare-ArkuzoRemoteProbe $previous $Probe)
    $crdAt = Get-ArkuzoRemoteDisconnectSec $Probe $NowUtc $NowSec
    if ($null -ne $crdAt -and ($null -eq $script:lastRemoteDisconnectSec -or $crdAt -gt [double]$script:lastRemoteDisconnectSec + 1)) { $script:lastRemoteDisconnectSec = $crdAt }
    if ([int]$Probe.connectState -eq 4) {
        if ($null -eq $script:remoteHoldSinceSec) { $script:remoteHoldSinceSec = $NowSec; $script:lastRemoteDisconnectSec = $NowSec }
    } else { $script:remoteHoldSinceSec = $null }
    return $changes
}
function Update-ArkuzoRemoteSession {
    if ($null -eq $clock) { return }
    $now = [double]$clock.Elapsed.TotalSeconds
    if ($null -ne $script:remoteProbeSec -and ($now - [double]$script:remoteProbeSec) -lt 2) { return }
    $script:remoteProbeSec = $now
    try { $probe = Get-ArkuzoRemoteProbe } catch { Warn-Throttled 'remote-probe' 'Remote-session state is unavailable; remote disconnects are not recognised.'; return }
    $first = ($null -eq $script:remoteProbe)
    $changes = @(Update-ArkuzoRemoteState $probe ([datetime]::UtcNow) $now)
    if ($first -or $changes.Count -gt 0) {
        $states = @($tracked.Values)
        Write-Diagnostic $(if ($first) { 'REMOTE_SESSION_STATE' } else { 'REMOTE_SESSION_CHANGED' }) @{ changes = $changes; current = (ConvertTo-ArkuzoRemoteRecord $probe)
            clients = $states.Count; responding = @($states | Where-Object { $null -ne $_.LastSnapshot -and $_.LastSnapshot.responding -eq $true }).Count
            hold = (Test-ArkuzoRemoteHold $now)
            note = 'Chrome Remote Desktop runs in the console session; only its own events show when the viewer leaves. See docs/remote-desktop.md.' }
    }
}
function Update-ArkuzoKeepAwake([bool]$Wanted) {
    # Process-scoped SetThreadExecutionState from the main loop thread: keeps the
    # display (and so the clients' swap chains) on while clients run. Nothing is
    # changed in the power plan; Windows drops the request when the saver exits.
    if ($Wanted -eq [bool]$script:keepAwakeOn -or ($Wanted -and $script:keepAwakeFailed)) { return }
    $ok = $false
    try { $ok = [Arkuzo.RemoteSessionNativeV1]::KeepAwake($Wanted) } catch { $ok = $false }
    if ($Wanted -and -not $ok) { $script:keepAwakeFailed = $true; Warn-Throttled 'keep-awake' 'Could not ask Windows to keep the display on.'; return }
    $script:keepAwakeOn = $Wanted
    Write-Diagnostic 'KEEP_AWAKE' @{ on = $Wanted; clients = $tracked.Count; note = 'Display and system kept awake while clients run (process-scoped; the power plan is unchanged).' }
}
function Get-ArkuzoRemoteStatus {
    $record = ConvertTo-ArkuzoRemoteRecord $script:remoteProbe
    if ($null -eq $record) { return $null }
    $now = $(if ($null -ne $clock) { [double]$clock.Elapsed.TotalSeconds } else { 0 })
    $record.keepAwake = [bool]$script:keepAwakeOn
    $record.hold = (Test-ArkuzoRemoteHold $now)
    $record.holdLeftSec = $(if ($record.hold) { [math]::Round([double]$healthPolicy.remote_hold_max_sec - ($now - [double]$script:remoteHoldSinceSec)) } else { $null })
    $record.lastDisconnectAgoSec = $(if ($null -ne $script:lastRemoteDisconnectSec) { [math]::Round($now - [double]$script:lastRemoteDisconnectSec) } else { $null })
    return $record
}
