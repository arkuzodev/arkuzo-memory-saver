#requires -Version 5.1
# Farm-wide freeze fast path: detection, latching and the three episode-scoped
# exceptions (mapping, handoff, cooldown) must stay exactly as narrow as designed.
# FarmFreezeReplay.Tests.ps1 drives the full recovery path; this file pins the gates.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
function Write-Diagnostic($kind, $data) { [void]$script:events.Add(@{ kind = $kind; data = $data }) }
function Warn-Throttled($key, $message) { [void]$script:warned.Add($key) }
function Get-ArkuzoAccountDisplayLabel { 'account' }
function Save-ArkuzoRecoveryJournal { }

$Start = [datetime]'2026-11-01T10:00:00Z'
function New-Proc([int]$Id) {
    $p = [pscustomobject]@{ Id = $Id; ProcessName = 'RobloxPlayerBeta'; StartTime = $Start.AddSeconds($Id); HasExited = $false; ExitCode = 0 }
    $p | Add-Member ScriptMethod Refresh {}; $p | Add-Member ScriptMethod Dispose {}
    return $p
}
function Account([int]$i) { '{0:x8}-0000-4000-8000-{1:x12}' -f (0xb0 + $i), (0xb0 + $i) }
function New-Farm([int]$Count = 6, [int]$Frozen = 6, [double[]]$Onsets = @(), [double]$Cpu = 0.0) {
    $script:events = New-Object Collections.ArrayList; $script:warned = New-Object Collections.ArrayList
    $script:clock = @{ Elapsed = @{ TotalSeconds = 1000.0 } }
    $script:MonitorOnly = $false; $script:ownsControllerMutex = $true; $script:recoveryJournalHealthy = $true; $script:recoveryJournalCorrupt = $false; $script:logFailed = $false
    $script:healthPolicy = Get-ArkuzoHealthPolicy @{ enabled = $true; hang_timeout_sec = 180; cooldown_sec = 45; max_recycles_per_hour = 50 }
    $script:restorePolicy = Get-ArkuzoRestorePolicy @{ enabled = $true }
    $script:recoveryAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
    $script:farmFreeze = $null; $script:lastFarmFreezeStartSec = $null; $script:lastClientStartUtc = $null
    $script:tracked = @{}; $rows = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $id = 101 + $i; $w = New-Proc $id
        $onset = $(if ($i -lt $Frozen) { $(if ($Onsets.Count -gt $i) { 900 + $Onsets[$i] } else { 900 + $i }) } else { -1.0 })
        $isFrozen = $i -lt $Frozen
        $script:tracked[$id] = @{ Watcher = $w; StartTicks = $w.StartTime.ToUniversalTime().Ticks; TrackerId = [string](800 + $i); ParentId = 7; RecoveryRequested = $false
            HangSince = $onset; FreezeSince = $onset; StartedSec = $null; EverResponded = $true; LastHealthSampleTime = 999.0; StartupErrorSince = -1.0; DisconnectSince = -1.0; PrivateLimitSince = -1.0; isDisconnected = $false
            HangCpuPercent = $(if ($isFrozen) { $Cpu } else { $null }); HangCpuBase = $null; HangCpuBaseAt = $null; FarmFreezeEpisode = $null; FarmFreezePid = $null; GameReady = $true; EverGameReady = $true
            LastSnapshot = @{ windowPresent = $true; responding = (-not $isFrozen); launchError = $false; privateMB = 2500 }; HealthDecision = $null; BoundAccountId = (Account $i) }
        $rows += [pscustomobject]@{ accountId = (Account $i); username = "farm$i"; trackerId = [string](800 + $i); processId = $id; uiStatus = 'Connected'; controlReady = $true; rowReady = $true
            autoRelaunch = $true; cookieAlive = $true; cookieStatus = 'alive'; suspensionSafe = $false; lastLaunchAtMs = 1 }
    }
    $script:voltControlStatus = [pscustomobject]@{ available = $true; globalMappingSafe = $true; processMappingSafe = $true; unmappedAccountIds = @(); managerId = 7; managerStartTicks = [long]70; relaunchDelayMs = 30000; accounts = $rows }
    $script:voltControlCheckedUtc = [datetime]::UtcNow
}
function Sample([bool]$Responding = $false) { @{ privateMB = 2500; ageSec = 6000; responding = $Responding; windowPresent = $true; launchError = $false; isDisconnected = $false; systemCommitPercent = 20; eligible = $true } }
# Volt starts relaunching the first member: its row is no longer mapped.
function Close-Member([int]$Id) {
    $s = $tracked[$Id]; Set-ArkuzoFarmFreezeMemberStatus $s 'Closed'
    $row = @($voltControlStatus.accounts | Where-Object { $_.processId -eq $Id })[0]
    $row.uiStatus = 'Unknown'; $row.processId = $null; $row.rowReady = $false
    foreach ($r in $voltControlStatus.accounts) { $r.controlReady = $false }
    $voltControlStatus.globalMappingSafe = $false; $voltControlStatus.unmappedAccountIds = @($row.accountId)
}

# ---- Policy -------------------------------------------------------------------------
$p = Get-ArkuzoHealthPolicy @{ enabled = $true }
Assert ($p.farm_freeze_enabled -and $p.farm_freeze_confirm_sec -eq 35 -and $p.farm_freeze_min_clients -eq 3 -and $p.farm_freeze_spacing_sec -eq 20 -and $p.farm_freeze_max_cpu_percent -eq 5) 'defaults: on, 35 s, 3 clients, 20 s spacing, 5% CPU'
foreach ($bad in @(@{ farm_freeze_enabled = 'yes' }, @{ farm_freeze_confirm_sec = 10 }, @{ farm_freeze_min_clients = 2 }, @{ farm_freeze_spacing_sec = 5 }, @{ farm_freeze_max_cpu_percent = 50 }, @{ farm_freeze_onset_window_sec = 600 })) {
    $threw = $false; try { [void](Get-ArkuzoHealthPolicy $bad) } catch { $threw = $true }
    Assert $threw ('invalid ' + (@($bad.Keys)[0]) + ' is refused')
}
Assert ((Get-ArkuzoHealthPolicy @{ farm_freeze_enabled = $false }).farm_freeze_enabled -eq $false) 'off switch'

# ---- CPU since onset ------------------------------------------------------------------
$s = @{ FreezeSince = 10.0; HangCpuBase = $null; HangCpuBaseAt = $null; HangCpuPercent = $null }
Update-ArkuzoHangCpu $s 50.0 10.0 16; Assert ($null -eq $s.HangCpuPercent -and $s.HangCpuBase -eq 50.0) 'first hung sample sets the baseline'
Update-ArkuzoHangCpu $s 50.08 20.0 16; Assert ([math]::Abs($s.HangCpuPercent - 0.05) -lt 0.001) 'average CPU since onset on the dashboard scale'
Update-ArkuzoHangCpu $s 70.0 30.0 16; Assert ($s.HangCpuPercent -gt 5) 'a busy client is not a frozen one'
$s.FreezeSince = -1.0; Update-ArkuzoHangCpu $s 61.0 31.0 16; Assert ($null -eq $s.HangCpuBase -and $null -eq $s.HangCpuPercent) 'responsive again clears the measurement'

# ---- Detection --------------------------------------------------------------------------
New-Farm 6 6 @(0,0,1,1,2,9)
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 943.9
Assert ($null -ne $c -and @($c.Members).Count -eq 6 -and -not $c.Confirmed) 'six clients frozen within 9 s: a candidate, not yet confirmed'
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 944.0
Assert ($c.Confirmed -and $c.FirstOnset -eq 900 -and $c.LastOnset -eq 909) 'confirmed 35 s after the LAST onset'
New-Farm 6 3; Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) '3 of 6 is not a majority'
New-Farm 4 3; Assert ($null -ne (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) '3 of 4 is a majority'
New-Farm 3 2; Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) 'two clients never make a farm freeze'
New-Farm 6 6 @(0,0,0,40,40,40); Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) 'two separate groups of three in a farm of six: no correlated majority'
New-Farm 6 6 @() 6.0; Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) 'clients still using CPU are not frozen'
New-Farm 6 6; foreach ($s in $tracked.Values) { $s.HangCpuPercent = $null }
Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) 'no CPU measurement yet, no farm freeze'
New-Farm 6 6; foreach ($s in @($tracked.Values)[0..3]) { $s.LastSnapshot.launchError = $true }
Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) 'startup notices are not freezes'
New-Farm 6 6; $healthPolicy.farm_freeze_enabled = $false
Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) 'disabled means never'

# ---- Latching ------------------------------------------------------------------------------
New-Farm 6 6
$script:recoveryPending[(Account 4)] = New-ArkuzoPendingEntry (Account 4) '804' 1 1
$script:quarantinedAccounts[(Account 5)] = @{ accountId = (Account 5); untilUtc = [datetime]::UtcNow.AddHours(1).ToString('o') }
$script:clock.Elapsed.TotalSeconds = 945.0
Update-ArkuzoFarmFreeze
Assert (Test-ArkuzoFarmFreezeActive) 'confirmed freeze latches an episode'
$planned = @($farmFreeze.Members.Values | ForEach-Object { $_.pid } | Sort-Object)
Assert (($planned -join ',') -eq '101,102,103,104') 'pending and quarantined accounts stay on the normal path'
$det = @($events | Where-Object { $_.kind -eq 'FARM_FREEZE_DETECTED' })
Assert ($det.Count -eq 1 -and @($det[0].data.skipped).Count -eq 2) 'detection is audited with the skipped members'
$d = Get-ArkuzoHealthDecision $tracked[101] (Sample) $healthPolicy 946.0
Assert ($d.Reason -ceq 'FARM_FREEZE' -and $d.Recycle -and $d.Status -ceq 'FARM FREEZE') 'a member is recyclable long before hang_timeout_sec'
$d = Get-ArkuzoHealthDecision $tracked[105] (Sample) $healthPolicy 946.0
Assert ($d.Reason -ceq '' -and -not $d.Recycle -and $d.Status -ceq 'HANG GRACE') 'a skipped client keeps the normal hang timeout'
$d = Get-ArkuzoHealthDecision $tracked[102] (Sample $true) $healthPolicy 946.0
Assert (-not $d.Recycle) 'a member that answers again is not recycled'
Update-ArkuzoFarmFreeze
Assert ($farmFreeze.Members['102'].status -ceq 'Recovered') 'and leaves the episode'
Assert ((Get-ArkuzoRecoveryCooldown 'FARM_FREEZE' $healthPolicy) -eq 20 -and (Get-ArkuzoRecoveryCooldown 'SUSTAINED_HANG' $healthPolicy) -eq 45 -and (Get-ArkuzoRecoveryCooldown 'VOLT_STARTUP_ERROR' $healthPolicy) -eq 5) 'cooldown: spacing only for the episode'
# Larger budget use trims the plan instead of overrunning it.
New-Farm 6 6; $script:healthPolicy.max_recycles_per_hour = 4; $script:recoveryAttempts = @([datetime]::UtcNow.AddMinutes(-5), [datetime]::UtcNow.AddMinutes(-4))
$script:clock.Elapsed.TotalSeconds = 945.0; Update-ArkuzoFarmFreeze
Assert (@($farmFreeze.Members.Values).Count -eq 2) 'the plan never exceeds the hourly recycle budget'
# Unsafe or stale authority at confirmation: nothing is latched.
New-Farm 6 6; $voltControlStatus.globalMappingSafe = $false; $script:clock.Elapsed.TotalSeconds = 945.0; Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive)) 'no episode without one globally mapped snapshot'
New-Farm 6 6; $script:voltControlCheckedUtc = [datetime]::UtcNow.AddSeconds(-40); $script:clock.Elapsed.TotalSeconds = 945.0; Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive) -or @($farmFreeze.Members.Values).Count -eq 0) 'no members from a stale snapshot'
foreach ($gate in @('monitor', 'journal', 'restore', 'log')) {
    New-Farm 6 6; $script:clock.Elapsed.TotalSeconds = 945.0
    switch ($gate) { 'monitor' { $script:MonitorOnly = $true } 'journal' { $script:recoveryJournalHealthy = $false } 'restore' { $script:restorePolicy.enabled = $false } 'log' { $script:logFailed = $true } }
    Update-ArkuzoFarmFreeze
    Assert (-not (Test-ArkuzoFarmFreezeActive)) "$gate blocks the fast path"
}

# ---- Mapping exception -----------------------------------------------------------------
New-Farm 6 6; $script:clock.Elapsed.TotalSeconds = 945.0; Update-ArkuzoFarmFreeze
Assert ($null -ne (Get-ArkuzoControlledAccount '801' 102)) 'globally mapped: the normal mapping applies'
Close-Member 101
$a = Get-ArkuzoControlledAccount '801' 102
Assert ($null -ne $a -and $a.accountId -ceq (Account 1)) 'only rows of members this episode already closed may be unmapped'
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 103)) 'tracker and process must still match exactly'
$tracked[106].FarmFreezeEpisode = $null
Assert ($null -eq (Get-ArkuzoControlledAccount '805' 106)) 'clients outside the episode get no exception'
$voltControlStatus.unmappedAccountIds = @((Account 0), (Account 2))
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'a planned member that is still alive may not be unmapped'
$voltControlStatus.unmappedAccountIds = @((Account 0), (Account 5))
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'an unmapped account outside the episode blocks'
$voltControlStatus.unmappedAccountIds = @((Account 0))
$voltControlStatus.processMappingSafe = $false; Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'process ownership must stay exact'
$voltControlStatus.processMappingSafe = $true; $voltControlStatus.managerStartTicks = [long]71
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'a restarted Volt ends the exception'
$voltControlStatus.managerStartTicks = [long]70; $voltControlStatus.accounts[1].rowReady = $false
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'the target row itself must be exact'
$voltControlStatus.accounts[1].rowReady = $true; $script:voltControlCheckedUtc = [datetime]::UtcNow.AddSeconds(-30)
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'stale snapshots never map'
$script:voltControlCheckedUtc = [datetime]::UtcNow; $script:suspendedAccounts[(Account 5)] = @{ accountId = (Account 5) }
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'a suspended account must still be an exact idle row'
$script:suspendedAccounts = @{}
Assert ($null -ne (Get-ArkuzoControlledAccount '801' 102)) 'restored conditions map again'

# ---- Handoff exception -----------------------------------------------------------------
$script:recoveryPending[(Account 0)] = New-ArkuzoPendingEntry (Account 0) '800' 101 $tracked[101].StartTicks
$script:recoveryPending[(Account 9)] = New-ArkuzoPendingEntry (Account 9) '809' 1 1
Assert (Test-ArkuzoRecoveryHandoff (Account 1) $tracked[102] 'FARM_FREEZE' $null) 'other open handoffs do not block a planned member'
Assert (-not (Test-ArkuzoRecoveryHandoff (Account 1) $tracked[102] 'SUSTAINED_HANG' $null)) 'any other reason keeps the normal handoff gate'
Assert (-not (Test-ArkuzoRecoveryHandoff (Account 2) $tracked[102] 'FARM_FREEZE' $null)) 'the account must be the member''s own'
Assert (-not (Test-ArkuzoRecoveryHandoff (Account 5) $tracked[106] 'FARM_FREEZE' $null)) 'a non-member gets no handoff exception'

# ---- Pacing from the last verified exit ------------------------------------------------
$script:clock.Elapsed.TotalSeconds = 1100.0
Assert (Test-ArkuzoFarmFreezeSlot) 'the slot is open long after the last member exit'
$farmFreeze.Members['101'].changedSec = 1090.0
Assert (-not (Test-ArkuzoFarmFreezeSlot)) 'no next close within 20 s of the previous member''s exit'
$farmFreeze.Members['101'].changedSec = 1079.0
Assert (Test-ArkuzoFarmFreezeSlot) 'the next close is allowed 20 s after it'
# A member that answered again and then quits still counts as gone.
$farmFreeze.Members['104'].status = 'Recovered'
Set-ArkuzoFarmFreezeMemberStatus $tracked[104] 'Closed'
Assert ($farmFreeze.Members['104'].status -ceq 'Recovered') 'a recovered member is never closed by the episode'
Set-ArkuzoFarmFreezeMemberStatus $tracked[104] 'Exited'
Assert ($farmFreeze.Members['104'].status -ceq 'Exited') 'but its exit is recorded'
Assert (-not (Test-ArkuzoFarmFreezeSlot)) 'and paces the next close like any other exit'
$farmFreeze.Members['104'].changedSec = 1000.0; $farmFreeze.Members['104'].status = 'Planned'

# ---- Exits, completion and re-freeze ---------------------------------------------------
$tracked[103].Watcher.HasExited = $true
Record-ClientExit 103 $tracked[103] 'HasExited reported'
Assert ($farmFreeze.Members['103'].status -ceq 'Exited') 'a member that quits by itself is gone: its row may count down too'
$tracked[106].FarmFreezeEpisode = $farmFreeze.Id   # Re-attach the member detached for the non-member checks.
foreach ($id in 102, 104, 105, 106) { Set-ArkuzoFarmFreezeMemberStatus $tracked[$id] 'Closed' }
Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive) -and $farmFreeze.State -ceq 'Completed') 'the episode completes'
Assert (@($tracked.Values | Where-Object { $_.FarmFreezeEpisode }).Count -eq 0) 'and releases every exception'
Assert ($null -eq (Get-ArkuzoControlledAccount '801' 102)) 'no mapping exception after the episode'
Assert (@($events | Where-Object { $_.kind -eq 'FARM_FREEZE_EPISODE_END' -and $_.data.outcome -ceq 'Completed' }).Count -eq 1) 'completion is audited'
$first = $script:lastFarmFreezeStartSec
New-Farm 6 6; $script:lastFarmFreezeStartSec = 500.0; $script:clock.Elapsed.TotalSeconds = 945.0
Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive) -and $warned -contains 'farm-freeze') 'a farm that freezes again within 15 min uses the normal hang timeout'
New-Farm 6 6; $script:clock.Elapsed.TotalSeconds = 945.0; Update-ArkuzoFarmFreeze
$script:healthPolicy.farm_freeze_enabled = $false; Update-ArkuzoFarmFreeze
Assert ($farmFreeze.State -ceq 'Disabled') 'turning the fast path off ends a running episode'
New-Farm 6 6; $script:clock.Elapsed.TotalSeconds = 945.0; Update-ArkuzoFarmFreeze
$script:clock.Elapsed.TotalSeconds = $farmFreeze.DeadlineSec; Update-ArkuzoFarmFreeze
Assert ($farmFreeze.State -ceq 'Expired' -and @($farmFreeze.Members.Values | Where-Object { $_.status -ceq 'Released' }).Count -eq 6) 'an episode that cannot finish expires and hands members back'

# ---- Freezes during startup (warm-up) ------------------------------------------------------
# A client that answered once and then froze counts; a window that never answered is loading.
$pol = Get-ArkuzoHealthPolicy @{ enabled = $true }
$w = @{ LastHealthSampleTime = 99.0 }
$ws = @{ privateMB = 1500; ageSec = 20; responding = $false; windowPresent = $true; launchError = $false; isDisconnected = $false; systemCommitPercent = 20; eligible = $true }
$d = Get-ArkuzoHealthDecision $w $ws $pol 100.0
Assert ([double]$w.FreezeSince -lt 0 -and -not $d.Recycle) 'a window that never answered yet is still loading, not frozen'
Assert ($w.StartedSec -eq 80.0) 'the start time is kept on the engine clock'
$ws.responding = $true; [void](Get-ArkuzoHealthDecision $w $ws $pol 101.0)
$ws.responding = $false; $d = Get-ArkuzoHealthDecision $w $ws $pol 102.0
Assert ($w.FreezeSince -eq 102.0 -and [double]$w.HangSince -lt 0 -and $d.Reason -ceq '' -and -not $d.Recycle) 'a starting client that answered and froze: onset tracked, hang timeout untouched'
$ws.responding = $true; [void](Get-ArkuzoHealthDecision $w $ws $pol 103.0)
Assert ([double]$w.FreezeSince -lt 0) 'answering again clears the onset'
# Ten clients, and Volt is still starting the farm (one every 12 s) when the first three freeze.
function Set-Starts { $i = 0; foreach ($id in 101..110) { $tracked[$id].StartedSec = 858.0 + 12 * $i; $i++ } }
New-Farm 10 3 @(0,1,1); Set-Starts
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000
Assert ($null -ne $c -and $c.Population -eq 4 -and @($c.Members).Count -eq 3) '3 of the 4 clients running at the freeze are a majority; later launches do not count'
foreach ($s in $tracked.Values) { $s.StartedSec = 0.0 }
Assert ($null -eq (Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 2000)) '3 of 10 clients that were all running is not'
New-Farm 10 3 @(0,1,1); Set-Starts; $script:clock.Elapsed.TotalSeconds = 945.0
$script:lastClientStartUtc = [datetime]::UtcNow.AddSeconds(-12); Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive)) 'no episode while Volt may still be starting the farm'
$script:lastClientStartUtc = [datetime]::UtcNow.AddSeconds(-31); Update-ArkuzoFarmFreeze
Assert ((Test-ArkuzoFarmFreezeActive) -and ((@($farmFreeze.Members.Keys) | Sort-Object) -join ',') -eq '101,102,103') '30 s after the last start the frozen starting clients are latched'
$ws = Sample; $ws.ageSec = 60
$tracked[101].HangSince = -1.0
$d = Get-ArkuzoHealthDecision $tracked[101] $ws $healthPolicy 946.0
Assert ($d.Reason -ceq 'FARM_FREEZE' -and $d.Recycle -and [double]$tracked[101].HangSince -lt 0) 'a latched member still in warm-up is recycled with the farm; its hang timeout never started'
Update-ArkuzoFarmFreeze
Assert ($farmFreeze.Members['101'].status -ceq 'Planned') 'a frozen warm-up member is not mistaken for one that answered again'
$d = Get-ArkuzoHealthDecision $tracked[104] $ws $healthPolicy 946.0
Assert (-not $d.Recycle -and $d.Reason -ceq '') 'a frozen client in warm-up outside the episode is never recycled'
$ws.responding = $true; [void](Get-ArkuzoHealthDecision $tracked[102] $ws $healthPolicy 947.0); Update-ArkuzoFarmFreeze
Assert ($farmFreeze.Members['102'].status -ceq 'Recovered') 'a warm-up member that answers again leaves the episode'

# ---- Launch pacing -----------------------------------------------------------------------
New-Farm 6 0; $now = [datetime]::UtcNow
Assert (Test-ArkuzoLaunchPacing $now) 'a quiet farm may launch'
$script:lastClientStartUtc = $now.AddSeconds(-5); Assert (-not (Test-ArkuzoLaunchPacing $now)) 'not within 20 s of another client start'
$script:lastClientStartUtc = $now.AddSeconds(-25); Assert (Test-ArkuzoLaunchPacing $now) 'after the spacing it may'
$entry = New-ArkuzoPendingEntry (Account 0) '800' 101 1; $entry.closedUtc = $now.AddSeconds(-20).ToString('o'); $script:recoveryPending[(Account 0)] = $entry
Assert (-not (Test-ArkuzoLaunchPacing $now)) 'not while Volt is about to relaunch a closed client'
$entry.closedUtc = $now.AddSeconds(-60).ToString('o'); Assert (Test-ArkuzoLaunchPacing $now) 'once that relaunch is past'
$script:farmFreeze = @{ State = 'Active'; Members = @{} }; Assert (-not (Test-ArkuzoLaunchPacing $now)) 'never during a farm-freeze episode'

Write-Host "PASS: farm-freeze detection, latching, scoped mapping/handoff/cooldown exceptions, completion, re-freeze fallback and launch pacing ($checks checks)"
