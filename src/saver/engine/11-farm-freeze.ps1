# ---------------------------------------------------------------------------
# Farm-wide freeze fast path.
# A display or remote-desktop event freezes every client at the same moment at
# 0% CPU. None of the 44 logged correlated freezes (3+ clients, majority, still
# frozen 30 s after the last onset) came back; every client quit by itself after
# 187-217 s and Volt then relaunched them all at once, which raises its
# "Roblox started before Volt could connect" notice for launches < 10 s apart.
# Clients that freeze together while still starting (warm-up) behave the same:
# none of the 15 logged groups came back. CPU does not tell them apart: the 13
# long single hangs that did come back also averaged 3% or less.
# An episode is latched once confirmed. Its members are closed one at a time,
# farm_freeze_spacing_sec apart, so Volt's relaunches arrive paced too. Every
# closure still goes through Invoke-ClientRecovery with all its gates; only three
# are scoped to the episode: cooldown (= spacing), handoff (other members'
# pending entries do not block) and global mapping (only rows of members whose
# old generation has verifiably exited may be unmapped; see Get-ArkuzoFarmFreezeAccount).
# ---------------------------------------------------------------------------
function Update-ArkuzoHangCpu($State, [double]$CpuSeconds, [double]$Now, [int]$Threads) {
    # Average CPU (dashboard scale: percent of all logical CPUs) since freeze onset.
    if ($null -eq $State) { return }
    if ($null -eq $State.FreezeSince -or [double]$State.FreezeSince -lt 0) {
        $State.HangCpuBase = $null; $State.HangCpuBaseAt = $null; $State.HangCpuPercent = $null; return
    }
    if ($null -eq $State.HangCpuBase -or $null -eq $State.HangCpuBaseAt -or $Now -lt [double]$State.HangCpuBaseAt -or $CpuSeconds -lt [double]$State.HangCpuBase) {
        $State.HangCpuBase = $CpuSeconds; $State.HangCpuBaseAt = $Now; $State.HangCpuPercent = $null; return
    }
    $elapsed = $Now - [double]$State.HangCpuBaseAt
    if ($elapsed -lt 1) { return }
    $State.HangCpuPercent = [math]::Round(100 * ($CpuSeconds - [double]$State.HangCpuBase) / ($elapsed * [math]::Max(1, [int]$Threads)), 3)
}
function Test-ArkuzoFrozenSample($State, $Policy) {
    # Unresponsive visible window that answered before (FreezeSince; see
    # Get-ArkuzoHealthDecision), no startup notice or disconnect, and measured
    # low CPU since onset.
    $snap = $State.LastSnapshot
    return ($null -ne $snap -and $null -ne $State.FreezeSince -and [double]$State.FreezeSince -ge 0 -and
        $snap.windowPresent -is [bool] -and $snap.windowPresent -and $snap.responding -is [bool] -and -not $snap.responding -and
        -not $snap.launchError -and -not $State.isDisconnected -and -not $State.RecoveryRequested -and
        $null -ne $State.HangCpuPercent -and [double]$State.HangCpuPercent -le [double]$Policy.farm_freeze_max_cpu_percent)
}
function Test-ArkuzoRemoteDisconnectOnset($FirstOnset, $DisconnectSec, $Policy) {
    # Pure. A Chrome Remote Desktop disconnect froze the clients within 0-13 s of
    # it on 12 of the 14 logged disconnects with clients running, and none of
    # those clients answered again (docs/remote-desktop.md).
    # Onsets are recorded up to ~10 s after the real hang and the disconnect time
    # comes from another clock, so allow 10 s before it.
    if ($null -eq $FirstOnset -or $null -eq $DisconnectSec -or $null -eq $Policy) { return $false }
    $offset = [double]$FirstOnset - [double]$DisconnectSec
    return ($offset -ge -10 -and $offset -le [double]$Policy.farm_freeze_remote_window_sec)
}
function Get-ArkuzoFarmFreezeCandidate($States, $Policy, [double]$Now, $RemoteDisconnectSec = $null) {
    # Pure. Finds the largest group of frozen clients whose onsets lie within
    # farm_freeze_onset_window_sec. It qualifies with at least
    # farm_freeze_min_clients members that are a strict majority of the clients
    # already running when its last member froze (clients Volt launched afterwards,
    # e.g. while it is still starting the farm, say nothing about that freeze),
    # and is confirmed once its LAST member has been frozen for farm_freeze_confirm_sec,
    # or farm_freeze_remote_confirm_sec when it began right after a remote disconnect.
    if ($null -eq $Policy -or -not $Policy.farm_freeze_enabled) { return $null }
    $population = @($States | Where-Object { $null -ne $_ -and $null -ne $_.LastSnapshot -and -not $_.RecoveryRequested })
    $frozen = @($population | Where-Object { Test-ArkuzoFrozenSample $_ $Policy } | Sort-Object { [double]$_.FreezeSince })
    if ($frozen.Count -lt [int]$Policy.farm_freeze_min_clients) { return $null }
    $best = @()
    for ($i = 0; $i -lt $frozen.Count; $i++) {
        $group = @($frozen | Where-Object { [double]$_.FreezeSince -ge [double]$frozen[$i].FreezeSince -and ([double]$_.FreezeSince - [double]$frozen[$i].FreezeSince) -le [double]$Policy.farm_freeze_onset_window_sec })
        if ($group.Count -gt $best.Count) { $best = $group }
    }
    if ($best.Count -lt [int]$Policy.farm_freeze_min_clients) { return $null }
    $onsets = @($best | ForEach-Object { [double]$_.FreezeSince })
    $first = ($onsets | Measure-Object -Minimum).Minimum; $last = ($onsets | Measure-Object -Maximum).Maximum
    $present = @($population | Where-Object { $null -eq $_.StartedSec -or [double]$_.StartedSec -le [double]$last })
    if ((2 * $best.Count) -le $present.Count) { return $null }
    $remote = Test-ArkuzoRemoteDisconnectOnset $first $RemoteDisconnectSec $Policy
    $confirm = [double]$Policy.farm_freeze_confirm_sec
    if ($remote -and $null -ne $Policy.farm_freeze_remote_confirm_sec) { $confirm = [math]::Min($confirm, [double]$Policy.farm_freeze_remote_confirm_sec) }
    return [pscustomobject]@{ Members = $best; Population = $present.Count; FirstOnset = [double]$first; LastOnset = [double]$last
        Confirmed = (($Now - [double]$last) -ge $confirm); RemoteDisconnect = $remote; ConfirmSec = $confirm
        RemoteDisconnectOffsetSec = $(if ($remote) { [math]::Round([double]$first - [double]$RemoteDisconnectSec, 1) } else { $null }) }
}
function Test-ArkuzoFarmFreezeActive {
    return ($null -ne $script:farmFreeze -and $script:farmFreeze.State -ceq 'Active')
}
function Get-ArkuzoFarmFreezeMemberRecord($State) {
    if (-not (Test-ArkuzoFarmFreezeActive) -or $null -eq $State -or $null -eq $State.FarmFreezePid -or
        $State.FarmFreezeEpisode -cne $script:farmFreeze.Id) { return $null }
    $member = $script:farmFreeze.Members[[string]$State.FarmFreezePid]
    if ($null -eq $member -or [long]$member.startTicks -ne [long]$State.StartTicks) { return $null }
    return $member
}
function Test-ArkuzoFarmFreezeMember($State) {
    # Latched per-state membership: decisions computed by the observation service
    # or inside Invoke-ClientRecovery reach the same reason without a farm view.
    $member = Get-ArkuzoFarmFreezeMemberRecord $State
    return ($null -ne $member -and $member.status -ceq 'Planned')
}
function Set-ArkuzoFarmFreezeMemberStatus($State, [string]$Status) {
    $member = Get-ArkuzoFarmFreezeMemberRecord $State
    # Planned members move on once; a member that answered again can still quit later.
    if ($null -eq $member -or -not ($member.status -ceq 'Planned' -or ($member.status -ceq 'Recovered' -and $Status -ceq 'Exited'))) { return }
    $member.status = $Status; $member.changedUtc = [datetime]::UtcNow.ToString('o')
    if ($null -ne $clock) { $member.changedSec = [double]$clock.Elapsed.TotalSeconds }
}
function Test-ArkuzoFarmFreezeSlot {
    # Volt counts its relaunch delay from each exit, so pace members from the last
    # verified exit of any member (closed by the saver or quit by itself), not
    # from when the previous attempt started.
    if (-not (Test-ArkuzoFarmFreezeActive) -or $null -eq $clock) { return $true }
    $now = [double]$clock.Elapsed.TotalSeconds
    foreach ($m in @($script:farmFreeze.Members.Values)) {
        if ($m.status -cin @('Closed','Exited') -and $null -ne $m.changedSec -and ($now - [double]$m.changedSec) -lt [double]$healthPolicy.farm_freeze_spacing_sec) { return $false }
    }
    return $true
}
function Get-ArkuzoRecoveryCooldown([string]$Reason, $Policy) {
    # Reason-specific spacing for Test-ArkuzoRecoveryBudget. A confirmed farm
    # freeze is paced at Volt's launch spacing instead of the generic cooldown.
    if ($Reason -ceq 'VOLT_STARTUP_ERROR') { return [math]::Min(5, [int]$Policy.cooldown_sec) }
    if ($Reason -ceq 'FARM_FREEZE' -and $null -ne $Policy.farm_freeze_spacing_sec) { return [int]$Policy.farm_freeze_spacing_sec }
    return [int]$Policy.cooldown_sec
}
function Get-ArkuzoFarmFreezeAccount([string]$TrackerId, [int]$ClientId) {
    # Episode-scoped exact mapping while Volt counts down the relaunch of members
    # this episode already closed. Everything else must still map exactly:
    # process ownership, every other row, the target's own row and socket.
    if (-not (Test-ArkuzoFarmFreezeActive) -or -not $script:tracked.ContainsKey($ClientId)) { return $null }
    $member = Get-ArkuzoFarmFreezeMemberRecord $script:tracked[$ClientId]
    if ($null -eq $member -or $member.status -cne 'Planned' -or [int]$member.pid -ne $ClientId -or $member.trackerId -cne $TrackerId) { return $null }
    $s = $voltControlStatus
    if (-not $s.available -or $s.processMappingSafe -isnot [bool] -or -not $s.processMappingSafe -or
        [int]$s.managerId -ne [int]$script:farmFreeze.managerId -or [long]$s.managerStartTicks -ne [long]$script:farmFreeze.managerStartTicks) { return $null }
    foreach ($id in @($s.unmappedAccountIds)) {
        if ($null -eq $id) { continue }
        $gone = @($script:farmFreeze.Members.Values | Where-Object { $_.accountId -ceq [string]$id -and $_.status -cin @('Closed','Exited') })
        if ($gone.Count -ne 1) { return $null }
    }
    if (-not (Test-ArkuzoSuspendedRowsSafe)) { return $null }
    $rows = @($s.accounts | Where-Object { $_.accountId -ceq $member.accountId })
    $sameTracker = @($s.accounts | Where-Object { $_.trackerId -ceq $TrackerId })
    $samePid = @($s.accounts | Where-Object { $_.processId -and [int]$_.processId -eq $ClientId })
    if ($rows.Count -ne 1 -or $sameTracker.Count -ne 1 -or $samePid.Count -ne 1) { return $null }
    $a = $rows[0]
    if ($a.trackerId -cne $TrackerId -or [int]$a.processId -ne $ClientId -or $a.uiStatus -cne 'Connected' -or
        $a.rowReady -isnot [bool] -or -not $a.rowReady -or $a.autoRelaunch -isnot [bool] -or -not $a.autoRelaunch -or
        $a.cookieStatus -cne 'alive' -or -not $a.cookieAlive -or
        ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey([string]$a.accountId)) -or
        $restorePolicy.excluded_account_ids -contains $a.accountId) { return $null }
    return $a
}
function Start-ArkuzoFarmFreezeEpisode($Candidate, [double]$Now) {
    # Latch members from ONE globally mapped, fresh Volt snapshot. Accounts that
    # are already pending, quarantined, excluded or unmapped stay on the normal path.
    $utc = [datetime]::UtcNow
    $room = [int]$healthPolicy.max_recycles_per_hour - @($recoveryAttempts | Where-Object { ($utc - ([datetime]$_).ToUniversalTime()).TotalSeconds -lt 3600 }).Count
    $members = @{}; $order = @(); $skipped = @()
    foreach ($state in @($Candidate.Members | Sort-Object { [double]$_.FreezeSince })) {
        $id = [int]$state.Watcher.Id
        $account = $null
        if (Test-ArkuzoClientIdentity $state.Watcher $id $state.StartTicks) { $account = Get-ArkuzoControlledAccount $state.TrackerId $id }
        $why = $null
        if ($null -eq $account) { $why = 'UNMAPPED' }
        elseif ($recoveryPending.ContainsKey([string]$account.accountId)) { $why = 'ALREADY_PENDING' }
        elseif (Test-ArkuzoAccountQuarantined ([string]$account.accountId) $utc) { $why = 'QUARANTINED' }
        elseif (-not ($account.autoRelaunch -is [bool] -and $account.autoRelaunch -and $account.cookieAlive -is [bool] -and $account.cookieAlive)) { $why = 'NOT_RELAUNCHABLE' }
        elseif ($order.Count -ge $room) { $why = 'HOURLY_BUDGET' }
        if ($why) { $skipped += @{ pid = $id; reason = $why }; continue }
        $members[[string]$id] = @{ pid = $id; startTicks = [long]$state.StartTicks; accountId = [string]$account.accountId; trackerId = [string]$account.trackerId
            onsetOffsetSec = [math]::Round([double]$state.FreezeSince - $Candidate.FirstOnset, 1); cpuPercent = $state.HangCpuPercent; status = 'Planned'; changedUtc = $null }
        $order += $id
    }
    if ($order.Count -eq 0) {
        Warn-Throttled 'farm-freeze' 'Farm-wide freeze confirmed, but no member can be mapped exactly now. Normal hang recovery continues.'
        return $false
    }
    $script:farmFreezeSequence = [int]$script:farmFreezeSequence + 1
    $script:farmFreeze = @{ Id = ('freeze-' + $utc.ToString('yyyyMMddHHmmss') + '-' + $script:farmFreezeSequence); State = 'Active'
        StartedSec = $Now; StartedUtc = $utc.ToString('o'); FirstOnset = $Candidate.FirstOnset
        managerId = [int]$voltControlStatus.managerId; managerStartTicks = [long]$voltControlStatus.managerStartTicks
        Members = $members; Order = $order
        DeadlineSec = $Now + ($order.Count * [double]$healthPolicy.farm_freeze_spacing_sec) + 120 }
    foreach ($id in $order) { $tracked[$id].FarmFreezeEpisode = $script:farmFreeze.Id; $tracked[$id].FarmFreezePid = $id }
    $script:lastFarmFreezeStartSec = $Now
    Write-Diagnostic 'FARM_FREEZE_DETECTED' @{ episode = $script:farmFreeze.Id; population = $Candidate.Population; frozen = @($Candidate.Members).Count
        planned = @($order | ForEach-Object { $m = $members[[string]$_]; @{ pid = $m.pid; accountId = $m.accountId; onsetOffsetSec = $m.onsetOffsetSec; cpuPercent = $m.cpuPercent } })
        skipped = $skipped; confirmSec = [math]::Round($Now - $Candidate.LastOnset, 1); spacingSec = $healthPolicy.farm_freeze_spacing_sec
        cause = $(if ($Candidate.RemoteDisconnect) { 'remote-disconnect' } else { 'unknown' }); remoteDisconnectOffsetSec = $Candidate.RemoteDisconnectOffsetSec
        note = 'Correlated freeze: members are closed one at a time at Volt launch spacing through the normal guarded recovery.' }
    return $true
}
function Stop-ArkuzoFarmFreezeEpisode([string]$Outcome) {
    if (-not (Test-ArkuzoFarmFreezeActive)) { return }
    $episode = $script:farmFreeze
    foreach ($m in @($episode.Members.Values)) { if ($m.status -ceq 'Planned') { $m.status = 'Released' } }
    $episode.State = $Outcome
    foreach ($state in @($tracked.Values)) { if ($state.FarmFreezeEpisode -ceq $episode.Id) { $state.FarmFreezeEpisode = $null; $state.FarmFreezePid = $null } }
    $counts = @{}; foreach ($m in @($episode.Members.Values)) { $counts[$m.status] = 1 + [int]$counts[$m.status] }
    Write-Diagnostic 'FARM_FREEZE_EPISODE_END' @{ episode = $episode.Id; outcome = $Outcome; members = $counts
        durationSec = $(if ($null -ne $clock) { [math]::Round($clock.Elapsed.TotalSeconds - [double]$episode.StartedSec, 1) } else { $null }) }
}
function Update-ArkuzoFarmFreeze {
    # Once per main-loop pass, after every client was sampled.
    if ($null -eq $clock) { return }
    $now = $clock.Elapsed.TotalSeconds
    if (Test-ArkuzoFarmFreezeActive) {
        if (-not $healthPolicy.farm_freeze_enabled -or -not $healthPolicy.enabled -or $MonitorOnly) { Stop-ArkuzoFarmFreezeEpisode 'Disabled'; return }
        foreach ($m in @($script:farmFreeze.Members.Values)) {
            if ($m.status -cne 'Planned') { continue }
            $state = $tracked[[int]$m.pid]
            # A member that answers again is never closed by this episode.
            if ($null -ne $state -and [long]$state.StartTicks -eq [long]$m.startTicks -and ($null -eq $state.FreezeSince -or [double]$state.FreezeSince -lt 0)) {
                Set-ArkuzoFarmFreezeMemberStatus $state 'Recovered'
            }
        }
        if (@($script:farmFreeze.Members.Values | Where-Object { $_.status -ceq 'Planned' }).Count -eq 0) { Stop-ArkuzoFarmFreezeEpisode 'Completed' }
        elseif ($now -ge [double]$script:farmFreeze.DeadlineSec) { Stop-ArkuzoFarmFreezeEpisode 'Expired' }
        return
    }
    if ($MonitorOnly -or -not $healthPolicy.enabled -or -not $healthPolicy.farm_freeze_enabled -or -not $restorePolicy.enabled -or
        -not $ownsControllerMutex -or -not $recoveryJournalHealthy -or $logFailed) { return }
    # A disconnected RDP session cannot render relaunched clients either.
    if (Test-ArkuzoRemoteHold $now) { return }
    $candidate = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy $now $script:lastRemoteDisconnectSec
    if ($null -eq $candidate -or -not $candidate.Confirmed) { return }
    # A farm that freezes again soon after an episode is not helped by fast
    # recycling (the display is likely still gone): use hang_timeout_sec instead.
    # A new remote disconnect since that episode is a new, discrete cause: the
    # replacement clients ran fine until the user disconnected again.
    $newDisconnect = ($candidate.RemoteDisconnect -and $null -ne $script:lastRemoteDisconnectSec -and
        ($null -eq $script:lastFarmFreezeStartSec -or [double]$script:lastRemoteDisconnectSec -gt [double]$script:lastFarmFreezeStartSec))
    if (-not $newDisconnect -and $null -ne $script:lastFarmFreezeStartSec -and ($now - [double]$script:lastFarmFreezeStartSec) -lt [double]$healthPolicy.farm_freeze_refreeze_sec) {
        Warn-Throttled 'farm-freeze' 'Farm froze again soon after the last fast recovery. Using the normal hang timeout this time.'
        return
    }
    # Volt starts a farm one client every 9-15 s. While that run may still be
    # going, paced closes could relaunch into it and raise its startup notice:
    # wait until no client has started for 30 s.
    if ($null -ne $script:lastClientStartUtc -and ([datetime]::UtcNow - $script:lastClientStartUtc).TotalSeconds -lt 30) { return }
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe) { return }
    [void](Start-ArkuzoFarmFreezeEpisode $candidate $now)
}
function Test-ArkuzoLaunchPacing([datetime]$NowUtc) {
    # A Volt launch request must not land within farm_freeze_spacing_sec of
    # another launch: closer launches raise Volt's startup notice.
    $spacing = if ($null -ne $healthPolicy.farm_freeze_spacing_sec) { [double]$healthPolicy.farm_freeze_spacing_sec } else { 20.0 }
    if (Test-ArkuzoFarmFreezeActive) { return $false }
    if ($null -ne $script:lastClientStartUtc -and ($NowUtc - $script:lastClientStartUtc).TotalSeconds -lt $spacing) { return $false }
    # Volt itself relaunches a closed client relaunch_delay_sec after its exit.
    $due = [double]$restorePolicy.relaunch_delay_sec + $spacing
    foreach ($entry in @($recoveryPending.Values)) {
        if (-not $entry.closedUtc -or [int]$entry.replacementPid -gt 0) { continue }
        try { $age = ($NowUtc - ([datetime]$entry.closedUtc).ToUniversalTime()).TotalSeconds } catch { continue }
        if ($age -ge 0 -and $age -lt $due) { return $false }
    }
    return $true
}
