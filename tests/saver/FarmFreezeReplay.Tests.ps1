#requires -Version 5.1
# Replays the four logged farm-wide freezes (23 Oct 23:16, 26 Oct 13:19 and 18:10,
# 27 Oct 07:38) through the production recovery code, against a fake Volt that is
# fitted to the same logs. Only timings are kept: no real names, PIDs or account IDs.
#
# What the logs show, and what the fake Volt therefore models:
# - Every client stops responding within a few seconds at 0% CPU and never comes back
#   by itself; each quits on its own 195-201 s after its onset (exit code 0).
# - Volt relaunches an account a measured 31-42 s after its client exits.
# - While Volt counts down or connects a relaunch, that account's row is neither
#   Connected nor Idle, so the adapter reports the farm as not globally mapped.
#   The engine logged 'recovery-mapping' (never 'recovery-handoff') between every
#   closure, and the next closure followed the previous replacement by 4-6 s.
# - A launch that lands < 10 s from another launch gets Volt's "Roblox started
#   before Volt could connect" notice (18 of 26 such launches in the logs; 0 of 56
#   launches that were 10 s or more apart).
#
# Downtime is measured per account from the farm's first hang onset until a
# replacement client of that account is in game: window open, responsive, no notice.
#
# Run with -Report to print the table used in docs/farm-freeze-recovery.md.
param([switch]$Report, [switch]$Trace)
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
function Assert([bool]$ok, [string]$msg) { if (-not $ok) { throw "FAIL: $msg" } }

# ---- Logged incidents (offsets in seconds from the first hang onset) -------------
# selfExit is when that client quit by itself; for the one client the saver closed at
# ~190 s, the median of its farm is used. observed* are measured from the same logs
# (onset -> replacement in game; a few replacements were adopted after a saver restart).
# reproduce: the replay of today's behaviour must match the log. 23 Oct ran the old
# v1.2.0 engine, and Volt relaunched that burst in two waves 64-90 s after the exits
# (3 of them without a notice), which this single-latency model does not capture;
# it is replayed and reported, but not used to validate the model.
$Incidents = @(
    @{ name = '23 Oct 23:16'; onsets = @(0,0,1,2,3,4,4,5); selfExit = @(199,198,198,199,199,198,198,199); observedMean = 339; observedMax = 480; observedNotices = 4; reproduce = $false }
    @{ name = '26 Oct 13:19'; onsets = @(0,0,0,1,2,2,2);   selfExit = @(198,199,198,196,197,195,197);     observedMean = 384; observedMax = 513; observedNotices = 5; reproduce = $true }
    @{ name = '26 Oct 18:10'; onsets = @(0,0,0,1,1,2);     selfExit = @(198,197,198,197,197,197);         observedMean = 330; observedMax = 457; observedNotices = 4; reproduce = $true }
    @{ name = '27 Oct 07:38'; onsets = @(0,1,1,8,8,9);     selfExit = @(200,201,200,198,201,200);         observedMean = 338; observedMax = 436; observedNotices = 4; reproduce = $true }
)
# 8 Nov 00:35: a freeze while Volt was still starting a 10-client farm (one launch every
# 9-15 s). The first three clients had answered and froze within 1 s of each other at
# ages 18-43 s, inside the 90 s warm-up; one kept 3-4% CPU (dashboard scale) while frozen.
# They quit by themselves 196-198 s later and Volt relaunched them within 1 s: three
# notices and a fourth on a retry. starts/onsets are seconds from the first onset; $null
# marks the healthy clients. observed* cover the three frozen accounts (in game again
# at +335, +386 and +442 s). One more client quit at +190 s without freezing; Volt
# relaunched it first, so that burst's first launch was not a frozen account's (quits).
# reproduce: the replay of today gives 341 s / 388 s / 3 notices. The log has one more
# notice, on a lone relaunch 43 s from any other launch, which the burst rule does not
# model; that retry cost one account about 50 s. The replay of today is therefore
# kinder than the log, and the improvement is measured against it.
$StartupIncident = @{ name = '8 Nov 00:35 (startup)'
    starts = @(-42,-30,-17,-5,10,24,33,47,60,74)
    onsets = @(1,0,1,$null,$null,$null,$null,$null,$null,$null)
    selfExit = @(198,198,196,$null,$null,$null,$null,$null,$null,$null)
    frozenCpu = @(0.8,3.7,0.3,0,0,0,0,0,0,0)
    quits = @($null,$null,$null,$null,$null,$null,$null,$null,$null,190)
    observedMean = 388; observedMax = 442; observedNotices = 4; reproduce = $false }
# Measured Volt relaunch latencies (client exit -> new client) for single exits, in log order.
$RelaunchLatency = @(37,35,32,37,33,34,39,42,40,33,38,32,31,34,34,32,37,32)
$ConnectSec = 5      # new client -> Volt socket connected (row Connected again)
$InGameSec = 12      # new client -> window open and responsive
$NoticeGapSec = 10   # launches closer than this raise Volt's startup notice
$IoSec = 5           # RECOVERY_REQUESTED -> CLIENT_CLOSED_FOR_RECOVERY in the logs (4-8 s)

# ---- Fakes: only process, Volt and diagnostics IO ----------------------------------
function Write-Diagnostic($kind, $data) { [void]$script:events.Add(@{ t = $script:simNow; kind = $kind; data = $data }) }
function Warn-Throttled($key, $message) { [void]$script:warned.Add(@{ t = $script:simNow; key = $key }) }
function Get-ArkuzoAccountDisplayLabel { return 'account' }
function Update-VoltRecoveryCapability { param([switch]$SyncControl)
    $script:voltStatus = @{ safeToRecycle = $true }; $script:voltParents = @{ 7 = @{ Id = 7; StartTicks = [long]70 } }
    if ($SyncControl) { Update-ArkuzoVoltControl } }
function Invoke-ArkuzoVoltControl($Action, $AccountId, $TrackerId) { return (Get-SimVoltStatus) }
function Test-ArkuzoVoltOwnership { return $true }
function Test-ArkuzoLiveVoltParent { return $true }
function Test-ArkuzoClientIdentity($Watcher, [int]$ClientId, [long]$StartTicks) {
    $c = $script:world.clients[$ClientId]
    return ($null -ne $c -and $null -ne $Watcher -and [int]$Watcher.Id -eq $ClientId -and -not $c.killed -and -not $c.exited -and [long]$c.startTicks -eq $StartTicks)
}
function Get-ArkuzoRecoveryHealthSample($Watcher, [string]$Reason, $CurrentState) { return (Get-SimSample $script:world.clients[[int]$Watcher.Id]) }
# Production also re-reads the command-line tracker and the Volt database probe; the
# simulated tracker never changes, so the exact-account mapping is what remains.
function Test-ArkuzoTargetRecovery($Watcher, [int]$ClientId, [long]$StartTicks) {
    return ((Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks) -and $null -ne (Get-ArkuzoControlledAccount $script:tracked[$ClientId].TrackerId $ClientId))
}

# ---- Fake world and Volt -----------------------------------------------------------
function New-SimProcess([int]$ClientId) {
    $p = [pscustomobject]@{ Id = $ClientId; ProcessName = 'RobloxPlayerBeta'; StartTime = [datetime]::UtcNow; ExitCode = 0 }
    $p | Add-Member ScriptProperty HasExited { $c = $script:world.clients[[int]$this.Id]; return ($c.killed -or $c.exited) }
    $p | Add-Member ScriptMethod Refresh {}
    $p | Add-Member ScriptMethod Dispose {}
    $p | Add-Member ScriptMethod Kill { $c = $script:world.clients[[int]$this.Id]; $c.killed = $true; $c.exitAt = $script:simNow + $script:IoSec; $script:killedThisPass = $true; [void]$script:kills.Add(@{ t = $script:simNow; pid = $this.Id; account = $c.account }) }
    $p | Add-Member ScriptMethod WaitForExit { param($ms) return $true }
    return $p
}
function New-SimClient([int]$Account, [double]$At, [bool]$Initial) {
    $id = $script:world.nextPid; $script:world.nextPid++
    $script:world.clients[$id] = @{ pid = $id; account = $Account; startTicks = [long](1000 + $id); launchedAt = $At; initial = $Initial; first = $Initial
        frozen = $false; frozenAt = $null; selfExitAt = $null; quitAt = $null; frozenCpu = 0.0; noticeAt = $null; noticeDecided = $Initial; goodAt = $null
        killed = $false; exited = $false; exitAt = $null }
    $script:world.accounts[$Account].live = $id
    if (-not $Initial) { [void]$script:world.launches.Add(@{ t = $At; account = $Account; pid = $id }) }
    return $id
}
function Get-SimSample($c) {
    $now = $script:simNow
    return @{ privateMB = 2500.0; ageSec = $(if ($c.initial) { 6000 + $now } else { $now - $c.launchedAt })
        responding = (-not $c.frozen -or $now -lt $c.frozenAt); windowPresent = ($c.initial -or ($now - $c.launchedAt) -ge 2)
        launchError = ($null -ne $c.noticeAt -and $now -ge $c.noticeAt); isDisconnected = $false; systemCommitPercent = 30.0; eligible = $true }
}
function Get-SimVoltStatus {
    $now = $script:simNow; $rows = @(); $unmapped = @()
    for ($i = 0; $i -lt $script:world.accounts.Count; $i++) {
        $a = $script:world.accounts[$i]; $ui = 'Unknown'; $procId = $null
        # An account Volt has not started yet is an Idle row (mapped).
        if ($null -ne $a.firstLaunchAt -and -not $a.firstLaunched) { $ui = 'Idle' }
        elseif ($null -ne $a.live) {
            $c = $script:world.clients[[int]$a.live]
            if ($c.initial -or ($now - $c.launchedAt) -ge $script:ConnectSec) { $ui = 'Connected'; $procId = $c.pid }
        }
        if ($ui -cne 'Connected' -and $ui -cne 'Idle') { $unmapped += $a.accountId }
        $rows += [pscustomobject]@{ accountId = $a.accountId; username = "farm$i"; trackerId = $a.trackerId; autoRelaunch = $true; cookieAlive = $true; cookieStatus = 'alive'
            suspensionSafe = $false; lastLaunchAtMs = 1; uiStatus = $ui; processId = $procId; rowReady = ($ui -ceq 'Connected' -or $ui -ceq 'Idle'); controlReady = $false }
    }
    $global = ($unmapped.Count -eq 0)
    # Degraded: the adapter cannot bind a row Volt is relaunching and fails closed.
    if ($script:DegradedVolt -and -not $global) { return [pscustomobject]@{ available = $false; globalMappingSafe = $false; processMappingSafe = $false; unmappedAccountIds = @(); accounts = @(); reason = 'Volt UI or process snapshot unavailable or changed' } }
    foreach ($r in $rows) { $r.controlReady = ($global -and $r.rowReady) }
    return [pscustomobject]@{ available = $true; globalMappingSafe = $global; processMappingSafe = $true; unmappedAccountIds = $unmapped
        managerId = 7; managerStartTicks = [long]70; relaunchDelayMs = 30000; accounts = $rows }
}
function Step-World([double]$Now) {
    foreach ($c in @($script:world.clients.Values)) {
        if ($c.exited) { continue }
        $exitAt = $null
        if ($c.killed) { $exitAt = $c.exitAt } elseif ($c.frozen -and $null -ne $c.selfExitAt) { $exitAt = $c.selfExitAt } elseif ($null -ne $c.quitAt) { $exitAt = $c.quitAt }
        if ($null -ne $exitAt -and $Now -ge $exitAt) {
            $c.exited = $true; $a = $script:world.accounts[$c.account]
            if ($a.live -eq $c.pid) { $a.live = $null }
            $lat = $script:RelaunchLatency[$script:world.latencyIndex % $script:RelaunchLatency.Count]; $script:world.latencyIndex++
            $a.relaunchAt = $exitAt + $lat
        }
    }
    for ($i = 0; $i -lt $script:world.accounts.Count; $i++) {
        $a = $script:world.accounts[$i]
        # Volt's own start of the farm: these connect (no notice in the log).
        if ($null -ne $a.firstLaunchAt -and -not $a.firstLaunched -and $Now -ge $a.firstLaunchAt) {
            $a.firstLaunched = $true; $c = $script:world.clients[(New-SimClient $i $Now $false)]
            $c.first = $true; $c.noticeDecided = $true; $c.goodAt = $Now + $script:InGameSec
            if ($null -ne $a.freeze) { $c.frozen = $true; $c.frozenAt = $a.freeze.at; $c.selfExitAt = $a.freeze.exit; $c.frozenCpu = $a.freeze.cpu }
            $c.quitAt = $a.quitAt
        }
        if ($null -eq $a.live -and $null -ne $a.relaunchAt -and $Now -ge $a.relaunchAt) { $a.relaunchAt = $null; [void](New-SimClient $i $Now $false) }
    }
    foreach ($c in @($script:world.clients.Values)) {
        if ($c.noticeDecided -or ($Now - $c.launchedAt) -lt $script:NoticeGapSec) { continue }
        $c.noticeDecided = $true
        # The first launch of a burst connects; every launch that follows another one
        # within NoticeGapSec gets the notice (19 predicted vs 17 logged notices).
        $near = @($script:world.launches | Where-Object { $_.pid -ne $c.pid -and ($c.launchedAt - $_.t) -ge 0 -and ($c.launchedAt - $_.t) -lt $script:NoticeGapSec -and ($_.t -lt $c.launchedAt -or $_.pid -lt $c.pid) })
        if ($near.Count -gt 0) { $c.noticeAt = $c.launchedAt + $script:NoticeGapSec } else { $c.goodAt = $c.launchedAt + $script:InGameSec }
    }
}
function Step-JournalClock([double]$Dt) {
    # Production budgets, backoffs and freshness use wall-clock UTC; age every stored
    # timestamp instead, so one simulated second is one second to those checks.
    $script:recoveryAttempts = @($script:recoveryAttempts | ForEach-Object { ([datetime]$_).AddSeconds(-$Dt) })
    foreach ($entry in @($script:recoveryPending.Values)) {
        foreach ($k in @('createdUtc', 'closedUtc', 'nextRetryUtc')) { if ($entry[$k]) { $entry[$k] = ([datetime]$entry[$k]).ToUniversalTime().AddSeconds(-$Dt).ToString('o') } }
    }
    foreach ($s in @($script:tracked.Values)) { if ($null -ne $s.LastRecoveryRefusalUtc) { $s.LastRecoveryRefusalUtc = $s.LastRecoveryRefusalUtc.AddSeconds(-$Dt) } }
    if ($null -ne $script:voltControlCheckedUtc) { $script:voltControlCheckedUtc = $script:voltControlCheckedUtc.AddSeconds(-$Dt) }
    if ($null -ne $script:lastClientStartUtc) { $script:lastClientStartUtc = $script:lastClientStartUtc.AddSeconds(-$Dt) }
}
function Invoke-EnginePass([double]$Now) {
    # Mirrors one main-loop pass: exits, first contact, sampling, freeze latch, recovery.
    foreach ($id in @($script:tracked.Keys)) {
        $c = $script:world.clients[[int]$id]
        if ($c.exited -or ($c.killed -and $Now -ge $c.exitAt)) { Record-ClientExit $id $script:tracked[$id] 'HasExited reported'; $script:tracked.Remove($id) }
    }
    if (($Now % 15) -eq 0) { $script:voltControlStatus = Get-SimVoltStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow }
    foreach ($c in @($script:world.clients.Values | Where-Object { -not $_.exited -and -not $_.killed })) {
        $id = [int]$c.pid
        if (-not $script:tracked.ContainsKey($id)) {
            $script:tracked[$id] = @{ StartTicks = [long]$c.startTicks; Slot = 0; Watcher = (New-SimProcess $id); ParentId = 7; TrackerId = $script:world.accounts[$c.account].trackerId
                LastSnapshot = $null; HangSince = -1.0; StartupErrorSince = -1.0; DisconnectSince = -1.0; PrivateLimitSince = -1.0; HealthDecision = $null; RecoveryRequested = $false
                GameReady = $true; EverGameReady = $c.initial; StartupGameHistory = 'UNKNOWN'; isDisconnected = $false; DisconnectReason = $null; BoundAccountId = $null; BoundTrackerId = $null
                HangCpuBase = $null; HangCpuBaseAt = $null; HangCpuPercent = $null; FarmFreezeEpisode = $null; FarmFreezePid = $null; LastHealthSampleTime = $null }
            if (-not $c.initial) { $script:tracked[$id].GameReady = $false; $script:lastClientStartUtc = [datetime]::UtcNow }
        }
        $state = $script:tracked[$id]
        $sample = Get-SimSample $c
        $state.HealthDecision = Get-ArkuzoHealthDecision $state $sample $script:healthPolicy $Now
        $cpuSeconds = $(if ($sample.responding) { $Now * 0.4 } else { [double]$c.frozenAt * 0.4 + ($Now - [double]$c.frozenAt) * [double]$c.frozenCpu * 16 / 100 })
        Update-ArkuzoHangCpu $state $cpuSeconds $Now 16
        $state.LastSnapshot = @{ pid = $id; windowPresent = $sample.windowPresent; responding = $sample.responding; launchError = $sample.launchError; privateMB = 2500.0; state = $state.HealthDecision.Status }
        $state.HealthSnapshotUtc = [datetime]::UtcNow.ToString('o')
        if (-not $state.BoundAccountId -and ($state.HealthDecision.Recycle -or [double]$state.HangSince -ge 0 -or $c.initial)) {
            $b = Get-ArkuzoControlledAccount $state.TrackerId $id
            if ($null -ne $b) { $state.BoundAccountId = [string]$b.accountId; $state.BoundTrackerId = [string]$b.trackerId }
        }
    }
    Update-ArkuzoFarmFreeze
    Invoke-ArkuzoRecoveryCandidates
}
function Invoke-Replay($Incident, [bool]$FastPath, [int]$SpacingSec = 20, [int]$ConfirmSec = 35, [int]$LatencyOffset = 0, [bool]$Degraded = $false, [int]$MaxCpu = 5) {
    $script:DegradedVolt = $Degraded
    $script:events = New-Object Collections.ArrayList; $script:warned = New-Object Collections.ArrayList; $script:kills = New-Object Collections.ArrayList
    $script:clock = @{ Elapsed = @{ TotalSeconds = 0.0 } }; $script:simNow = 0.0
    $script:MonitorOnly = $false; $script:ownsControllerMutex = $true; $script:logFailed = $false
    $script:recoveryStatePath = Join-Path $script:scratch ('journal-' + [guid]::NewGuid().ToString('N') + '.json')
    # The user's configuration during the incidents (hang_timeout_sec 180, cooldown 45 s).
    $script:healthPolicy = Get-ArkuzoHealthPolicy @{ enabled = $true; private_limit_mb = 6500; pressure_percent = 88; pressure_min_private_mb = 4000; warmup_sec = 90
        hang_timeout_sec = 180; startup_error_timeout_sec = 5; disconnect_timeout_sec = 5; cooldown_sec = 45; max_recycles_per_hour = 50; trim_spacing_sec = 4
        farm_freeze_enabled = $FastPath; farm_freeze_spacing_sec = $SpacingSec; farm_freeze_confirm_sec = $ConfirmSec; farm_freeze_max_cpu_percent = $MaxCpu }
    $script:restorePolicy = Get-ArkuzoRestorePolicy @{ enabled = $true; restore_missing = $true; restore_wait_sec = 90; relaunch_delay_sec = 30; retry_base_sec = 90; retry_max_sec = 900; retry_max_per_hour = 200; ready_stable_sec = 30 }
    $script:systemMemory = @{ commitPercent = 20 }
    Initialize-ArkuzoRecoveryJournal
    $script:tracked = @{}; $script:sessionObservedAccounts = @{}; $script:farmFreeze = $null; $script:lastFarmFreezeStartSec = $null; $script:lastClientStartUtc = $null
    $script:voltStatus = @{ safeToRecycle = $true }; $script:voltParents = @{ 7 = @{ Id = 7; StartTicks = [long]70 } }
    $n = $Incident.onsets.Count
    $script:world = @{ clients = @{}; accounts = @(); launches = New-Object Collections.ArrayList; nextPid = 5001; latencyIndex = $LatencyOffset }
    for ($i = 0; $i -lt $n; $i++) {
        $script:world.accounts += @{ accountId = ('{0:x8}-0000-4000-8000-{1:x12}' -f (0xa0 + $i), (0xa0 + $i)); trackerId = [string](7000 + $i); live = $null; relaunchAt = $null }
    }
    # The farm runs healthy before the freeze; the freeze starts at T0 = 120 s.
    # A startup incident instead has Volt start each client at T0 + starts[i].
    $t0 = 120
    $measured = @(for ($i = 0; $i -lt $n; $i++) { if ($null -ne $Incident.onsets[$i]) { $i } })
    for ($i = 0; $i -lt $n; $i++) {
        $freeze = $(if ($null -ne $Incident.onsets[$i]) { @{ at = $t0 + $Incident.onsets[$i]; exit = $t0 + $Incident.selfExit[$i]; cpu = $(if ($Incident.frozenCpu) { [double]$Incident.frozenCpu[$i] } else { 0.0 }) } } else { $null })
        if ($Incident.starts) { $a = $script:world.accounts[$i]; $a.firstLaunchAt = $t0 + $Incident.starts[$i]; $a.firstLaunched = $false; $a.freeze = $freeze; $a.quitAt = $(if ($Incident.quits -and $null -ne $Incident.quits[$i]) { $t0 + $Incident.quits[$i] } else { $null }); continue }
        $id = New-SimClient $i 0 $true
        $c = $script:world.clients[$id]; $c.frozen = $true; $c.frozenAt = $freeze.at; $c.selfExitAt = $freeze.exit; $c.frozenCpu = $freeze.cpu
    }
    $script:voltControlStatus = Get-SimVoltStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    $script:engineBusyUntil = 0
    for ($now = 1; $now -le $t0 + 900; $now++) {
        $script:simNow = [double]$now; $script:clock.Elapsed.TotalSeconds = [double]$now
        Step-World $now
        if ($now -ge $script:engineBusyUntil) {
            $script:killedThisPass = $false
            Invoke-EnginePass $now
            if ($script:killedThisPass) { $script:engineBusyUntil = $now + $IoSec }
        }
        Step-JournalClock 1
        $back = @(foreach ($i in $measured) { @($script:world.clients.Values | Where-Object { $_.account -eq $i -and -not $_.first -and $null -ne $_.goodAt -and $_.goodAt -le $now }).Count -gt 0 })
        if (@($back | Where-Object { -not $_ }).Count -eq 0) { break }
    }
    $perAccount = @(foreach ($i in $measured) {
        $good = @($script:world.clients.Values | Where-Object { $_.account -eq $i -and -not $_.first -and $null -ne $_.goodAt } | ForEach-Object { $_.goodAt } | Sort-Object)
        if ($good.Count) { $good[0] - $t0 } else { [double]::PositiveInfinity }
    })
    if ($Trace) {
        Write-Host ("--- $($Incident.name) fastPath=$FastPath")
        foreach ($k in $script:kills) { Write-Host ('  close  +{0,4}  account {1}  ({2})' -f ($k.t - $t0), $k.account, (@($script:events | Where-Object { $_.kind -eq 'RECOVERY_REQUESTED' -and $_.data.pid -eq $k.pid })[-1].data.reason)) }
        foreach ($l in $script:world.launches) { $c = $script:world.clients[[int]$l.pid]; Write-Host ('  launch +{0,4}  account {1}  {2}' -f ($l.t - $t0), $l.account, $(if ($null -ne $c.noticeAt) { 'NOTICE' } else { 'in game +' + ($c.goodAt - $t0) })) }
        foreach ($c in @($script:world.clients.Values | Where-Object { $_.first -and $_.exited -and -not $_.killed })) { Write-Host ('  self-exit +{0,4} account {1}' -f ($(if ($null -ne $c.selfExitAt) { $c.selfExitAt } else { $c.quitAt }) - $t0), $c.account) }
    }
    # Closest launch to any relaunch (Volt's own start of the farm is spaced by Volt).
    $gaps = @(foreach ($l in @($script:world.launches)) {
        if ($script:world.clients[[int]$l.pid].first) { continue }
        $o = @($script:world.launches | Where-Object { $_.pid -ne $l.pid } | ForEach-Object { [math]::Abs($_.t - $l.t) } | Sort-Object)
        if ($o.Count) { $o[0] }
    })
    return [pscustomobject]@{
        Mean = [math]::Round((($perAccount | Measure-Object -Average).Average), 0); Max = ($perAccount | Measure-Object -Maximum).Maximum
        First = ($perAccount | Measure-Object -Minimum).Minimum
        Notices = @($script:world.clients.Values | Where-Object { $null -ne $_.noticeAt }).Count
        Kills = @($script:kills); Events = @($script:events); Warned = @($script:warned)
        MinLaunchGap = $(if ($gaps.Count) { ($gaps | Measure-Object -Minimum).Minimum } else { $null })
        SelfExits = @($script:world.clients.Values | Where-Object { $_.first -and $_.exited -and -not $_.killed }).Count
        T0 = $t0
    }
}

$script:scratch = Join-Path ([IO.Path]::GetTempPath()) ('farm-freeze-replay-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:scratch) | Out-Null
try {
    $rows = @()
    foreach ($incident in $Incidents) {
        $before = Invoke-Replay $incident $false
        $after = Invoke-Replay $incident $true
        $rows += [pscustomobject]@{ Incident = $incident.name; Clients = $incident.onsets.Count
            LoggedMean = $incident.observedMean; LoggedMax = $incident.observedMax; LoggedNotices = $incident.observedNotices
            BeforeMean = $before.Mean; BeforeMax = $before.Max; BeforeNotices = $before.Notices
            AfterFirst = $after.First; AfterMean = $after.Mean; AfterMax = $after.Max; AfterNotices = $after.Notices; AfterMinLaunchGap = $after.MinLaunchGap; AfterSelfExits = $after.SelfExits }

        if ($Trace) { continue }
        # The replay of today's behaviour must reproduce the logs, or the "after" numbers mean nothing.
        if ($incident.reproduce) {
            Assert ([math]::Abs($before.Mean - $incident.observedMean) -le 45) "$($incident.name): replayed per-account mean $($before.Mean) s is within 45 s of the logged $($incident.observedMean) s"
            Assert ([math]::Abs($before.Max - $incident.observedMax) -le 60) "$($incident.name): replayed farm maximum $($before.Max) s is within 60 s of the logged $($incident.observedMax) s"
            Assert ([math]::Abs($before.Notices - $incident.observedNotices) -le 1) "$($incident.name): replayed $($before.Notices) startup notices vs $($incident.observedNotices) logged"
        }
        Assert ($before.Notices -ge 2) "$($incident.name): today's simultaneous relaunch reproduces Volt's startup notices"
        Assert (@($before.Warned | Where-Object { $_.key -eq 'recovery-mapping' }).Count -gt 0) "$($incident.name): today's serialization comes from the mapping gate"
        Assert (@($before.Events | Where-Object { $_.kind -eq 'FARM_FREEZE_DETECTED' }).Count -eq 0) 'the fast path stays off when disabled'

        # With the fast path.
        $detected = @($after.Events | Where-Object { $_.kind -eq 'FARM_FREEZE_DETECTED' })
        Assert ($detected.Count -eq 1) "$($incident.name): one farm-freeze episode"
        $lastOnset = ($incident.onsets | Measure-Object -Maximum).Maximum
        Assert ($detected[0].t -ge $after.T0 + $lastOnset + 35 -and $detected[0].t -le $after.T0 + $lastOnset + 37) "$($incident.name): confirmed 35 s after the last onset, not after hang_timeout_sec"
        $farmKills = @($after.Kills | Where-Object { $_.t -lt $after.T0 + 190 })
        Assert ($farmKills.Count -eq $incident.onsets.Count) "$($incident.name): every frozen client is closed by the saver before it would quit by itself"
        for ($i = 1; $i -lt $farmKills.Count; $i++) { Assert (($farmKills[$i].t - $farmKills[$i - 1].t) -ge 20) "$($incident.name): closures are at least farm_freeze_spacing_sec (20 s) apart" }
        Assert ($after.SelfExits -eq 0) "$($incident.name): no client was left to quit by itself"
        foreach ($k in $farmKills) {
            $req = @($after.Events | Where-Object { $_.kind -eq 'RECOVERY_REQUESTED' -and $_.data.pid -eq $k.pid -and $_.t -le $k.t })
            Assert ($req.Count -ge 1 -and $req[-1].data.reason -ceq 'FARM_FREEZE' -and $req[-1].data.farmFreezeEpisode) "$($incident.name): each closure was journaled and audited as FARM_FREEZE first"
        }
        Assert ($after.Notices -eq 0) "$($incident.name): paced relaunches raise no Volt startup notice"
        $n = $incident.onsets.Count
        $ceiling = $lastOnset + 36 + ($n - 1) * 20 + $IoSec + ($RelaunchLatency | Measure-Object -Maximum).Maximum + $InGameSec + 5
        Assert ($after.Mean -le 180) "$($incident.name): per-account mean $($after.Mean) s <= 3 min"
        Assert ($after.Max -le $ceiling) "$($incident.name): farm maximum $($after.Max) s within the paced ceiling $ceiling s (last close, slowest relaunch, in game)"
        Assert ($after.Mean -lt $before.Mean / 2) "$($incident.name): downtime at least halved"
        # If the adapter cannot read a row Volt is relaunching, the episode stalls after
        # each close until that relaunch connects. That must never be worse than today.
        $degraded = Invoke-Replay $incident $true 20 35 0 $true
        Assert ($degraded.Mean -le $before.Mean -and $degraded.Max -le $before.Max -and $degraded.Notices -le $before.Notices) "$($incident.name): with an unreadable countdown row the fast path is no worse than today ($($degraded.Mean) s vs $($before.Mean) s)"
        foreach ($k in @($degraded.Kills)) {
            $req = @($degraded.Events | Where-Object { $_.kind -eq 'RECOVERY_REQUESTED' -and $_.data.pid -eq $k.pid -and $_.t -le $k.t })
            Assert ($req.Count -ge 1) "$($incident.name): degraded closures are journaled and audited first"
        }
        Assert (@($degraded.Events | Where-Object { $_.kind -eq 'FARM_FREEZE_EPISODE_END' }).Count -eq 1) "$($incident.name): a stalled episode still ends and hands members back"
        $rows[-1] | Add-Member DegradedMean $degraded.Mean; $rows[-1] | Add-Member DegradedMax $degraded.Max; $rows[-1] | Add-Member DegradedNotices $degraded.Notices
        $end = @($after.Events | Where-Object { $_.kind -eq 'FARM_FREEZE_EPISODE_END' })
        Assert ($end.Count -eq 1 -and $end[0].data.outcome -ceq 'Completed') "$($incident.name): the episode completes and releases its exceptions"
    }
    # A freeze while Volt is still starting the farm (8 Nov 00:35).
    $si = $StartupIncident
    $before = Invoke-Replay $si $false
    $after = Invoke-Replay $si $true
    $oldCap = Invoke-Replay $si $true -MaxCpu 2
    $degraded = Invoke-Replay $si $true 20 35 0 $true
    $rows += [pscustomobject]@{ Incident = $si.name; Clients = @($si.onsets | Where-Object { $null -ne $_ }).Count
        LoggedMean = $si.observedMean; LoggedMax = $si.observedMax; LoggedNotices = $si.observedNotices
        BeforeMean = $before.Mean; BeforeMax = $before.Max; BeforeNotices = $before.Notices
        AfterFirst = $after.First; AfterMean = $after.Mean; AfterMax = $after.Max; AfterNotices = $after.Notices; AfterMinLaunchGap = $after.MinLaunchGap; AfterSelfExits = $after.SelfExits
        DegradedMean = $degraded.Mean; DegradedMax = $degraded.Max; DegradedNotices = $degraded.Notices }
    if (-not $Trace) {
        # Today's behaviour: nothing acts before the clients quit, then a burst of notices.
        Assert ($before.SelfExits -eq 4 -and $before.Notices -ge 2 -and $before.Mean -le $si.observedMean) "$($si.name): replayed today ($($before.Mean) s, $($before.Notices) notices) is no worse than the log"
        $detected = @($after.Events | Where-Object { $_.kind -eq 'FARM_FREEZE_DETECTED' })
        Assert ($detected.Count -eq 1 -and $detected[0].data.population -eq 4 -and @($detected[0].data.planned).Count -eq 3) "$($si.name): one episode, 3 of the 4 clients running at the freeze"
        $lastStart = $after.T0 + ($si.starts | Measure-Object -Maximum).Maximum
        Assert ($detected[0].t -ge $lastStart + 30 -and $detected[0].t -le $lastStart + 32) "$($si.name): latched once Volt's own launch run was 30 s quiet"
        Assert ($after.Kills.Count -eq 3 -and $after.SelfExits -eq 1) "$($si.name): all three closed before they would quit by themselves (only the client that never froze quits)"
        foreach ($k in $after.Kills) {
            $req = @($after.Events | Where-Object { $_.kind -eq 'RECOVERY_REQUESTED' -and $_.data.pid -eq $k.pid -and $_.t -le $k.t })
            Assert ($req.Count -ge 1 -and $req[-1].data.reason -ceq 'FARM_FREEZE') "$($si.name): each closure was journaled and audited as FARM_FREEZE first"
        }
        for ($i = 1; $i -lt $after.Kills.Count; $i++) { Assert (($after.Kills[$i].t - $after.Kills[$i - 1].t) -ge 20) "$($si.name): closures at least 20 s apart" }
        Assert ($after.Notices -eq 0 -and $after.MinLaunchGap -ge 10) "$($si.name): no relaunch within 10 s of any other launch (closest $($after.MinLaunchGap) s)"
        # Volt's own launch run (until +74 s, then 30 s quiet) delays the latch, so the gain is smaller than mid-farm.
        Assert ($after.Mean -le $before.Mean - 120 -and $after.Max -lt $before.Max) "$($si.name): at least 2 min less downtime per account ($($before.Mean) s -> $($after.Mean) s)"
        Assert ($degraded.Mean -le $before.Mean -and $degraded.Notices -le $before.Notices) "$($si.name): with an unreadable countdown row no worse than today ($($degraded.Mean) s)"
        Assert (@($oldCap.Events | Where-Object { $_.kind -eq 'FARM_FREEZE_DETECTED' }).Count -eq 0) "$($si.name): with the old 2% CPU limit the client at 3.7% hid this freeze"
    }
    # Robustness: Volt's relaunch latency varies by up to 11 s. With the default
    # 20 s spacing no ordering of the measured latencies brings two launches within
    # 10 s of each other on the largest farm (8 clients).
    foreach ($offset in 0..($RelaunchLatency.Count - 1)) {
        $r = Invoke-Replay $Incidents[0] $true 20 35 $offset
        Assert ($r.Notices -eq 0 -and $r.MinLaunchGap -ge 10) "latency order $offset raises no startup notice (closest launches $($r.MinLaunchGap) s apart)"
        Assert ($r.SelfExits -eq 0) "latency order ${offset}: every member closed before it would quit by itself"
    }
    if ($Report) {
        Write-Host '| Incident | Clients | Logged mean / max / notices | Replayed today mean / max / notices | Fast path first / mean / max / notices | Closest launches | Countdown row unreadable mean / max / notices |'
        Write-Host '| --- | --- | --- | --- | --- | --- | --- |'
        foreach ($r in $rows) {
            Write-Host ('| {0} | {1} | {2} s / {3} s / {4} | {5} s / {6} s / {7} | {8} s / {9} s / {10} s / {11} | {12} s | {13} s / {14} s / {15} |' -f $r.Incident, $r.Clients, $r.LoggedMean, $r.LoggedMax, $r.LoggedNotices,
                $r.BeforeMean, $r.BeforeMax, $r.BeforeNotices, $r.AfterFirst, $r.AfterMean, $r.AfterMax, $r.AfterNotices, $r.AfterMinLaunchGap, $r.DegradedMean, $r.DegradedMax, $r.DegradedNotices)
        }
        # Sensitivity: every rotation of the measured relaunch latencies, per spacing.
        foreach ($spacing in @(12, 15, 20)) {
            $runs = foreach ($incident in $Incidents[0..1]) { foreach ($offset in 0..($RelaunchLatency.Count - 1)) { Invoke-Replay $incident $true $spacing 35 $offset } }
            Write-Host ('spacing {0,2} s over {1} runs: per-account mean {2:N0} s, farm max {3:N0} s (worst {4:N0} s), runs with a notice {5}, notices {6}, min launch gap {7} s' -f $spacing, @($runs).Count,
                ($runs | Measure-Object Mean -Average).Average, ($runs | Measure-Object Max -Average).Average, ($runs | Measure-Object Max -Maximum).Maximum,
                @($runs | Where-Object { $_.Notices -gt 0 }).Count, ($runs | Measure-Object Notices -Sum).Sum, ($runs | Measure-Object MinLaunchGap -Minimum).Minimum)
        }
    }
    $farm = @($rows | Select-Object -First $Incidents.Count); $st = $rows[-1]
    $b = ($farm | Measure-Object BeforeMean -Average).Average; $a = ($farm | Measure-Object AfterMean -Average).Average
    Write-Host ('PASS: farm-freeze replay of 4 logged incidents: per-account downtime {0:N0} s -> {1:N0} s, farm maximum {2:N0} s -> {3:N0} s, Volt startup notices {4} -> {5}' -f $b, $a,
        ($farm | Measure-Object BeforeMax -Average).Average, ($farm | Measure-Object AfterMax -Average).Average, ($farm | Measure-Object BeforeNotices -Sum).Sum, ($farm | Measure-Object AfterNotices -Sum).Sum)
    Write-Host ('PASS: freeze during startup ({0}): per-account downtime {1} s -> {2} s, last account {3} s -> {4} s, notices {5} -> {6}' -f $st.Incident, $st.BeforeMean, $st.AfterMean, $st.BeforeMax, $st.AfterMax, $st.BeforeNotices, $st.AfterNotices)
} finally { Remove-Item -LiteralPath $script:scratch -Recurse -Force -ErrorAction SilentlyContinue }
