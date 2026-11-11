#requires -Version 5.1
# Remote sessions: a remote-desktop disconnect is recognised, attributed to the
# farm freeze that follows it (shorter confirmation, no refreeze fallback for a
# new disconnect), a disconnected RDP session holds recovery for a bounded time,
# and the read-only probes and keep-awake request work on this machine.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
# The native probe type, exactly as the engine declares it.
$native = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -like "if (-not ('Arkuzo.RemoteSessionNativeV1'*" }, $false))
if ($native.Count -ne 1) { throw 'RemoteSessionNativeV1 declaration not found' }
. ([scriptblock]::Create($native[0].Extent.Text))
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
function Account([int]$i) { '{0:x8}-0000-4000-8000-{1:x12}' -f (0xc0 + $i), (0xc0 + $i) }
function New-Farm([int]$Count = 6, [int]$Frozen = 6) {
    # Same fixture as FarmFreeze.Tests.ps1: members froze at 900..905 s.
    $script:events = New-Object Collections.ArrayList; $script:warned = New-Object Collections.ArrayList
    $script:clock = @{ Elapsed = @{ TotalSeconds = 1000.0 } }
    $script:MonitorOnly = $false; $script:ownsControllerMutex = $true; $script:recoveryJournalHealthy = $true; $script:logFailed = $false
    $script:healthPolicy = Get-ArkuzoHealthPolicy @{ enabled = $true; hang_timeout_sec = 180; cooldown_sec = 45; max_recycles_per_hour = 50 }
    $script:restorePolicy = Get-ArkuzoRestorePolicy @{ enabled = $true }
    $script:recoveryAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
    $script:farmFreeze = $null; $script:lastFarmFreezeStartSec = $null; $script:lastClientStartUtc = $null
    $script:remoteProbe = $null; $script:lastRemoteDisconnectSec = $null; $script:remoteHoldSinceSec = $null
    $script:tracked = @{}; $rows = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $id = 101 + $i; $w = New-Proc $id
        $isFrozen = $i -lt $Frozen
        $onset = $(if ($isFrozen) { 900.0 + $i } else { -1.0 })
        $script:tracked[$id] = @{ Watcher = $w; StartTicks = $w.StartTime.ToUniversalTime().Ticks; TrackerId = [string](800 + $i); ParentId = 7; RecoveryRequested = $false
            HangSince = $onset; FreezeSince = $onset; StartedSec = $null; EverResponded = $true; LastHealthSampleTime = 999.0; StartupErrorSince = -1.0; DisconnectSince = -1.0; PrivateLimitSince = -1.0; isDisconnected = $false
            HangCpuPercent = $(if ($isFrozen) { 0.0 } else { $null }); HangCpuBase = $null; HangCpuBaseAt = $null; FarmFreezeEpisode = $null; FarmFreezePid = $null; GameReady = $true; EverGameReady = $true
            LastSnapshot = @{ windowPresent = $true; responding = (-not $isFrozen); launchError = $false; privateMB = 2500 }; HealthDecision = $null; BoundAccountId = (Account $i) }
        $rows += [pscustomobject]@{ accountId = (Account $i); username = "farm$i"; trackerId = [string](800 + $i); processId = $id; uiStatus = 'Connected'; controlReady = $true; rowReady = $true
            autoRelaunch = $true; cookieAlive = $true; cookieStatus = 'alive'; suspensionSafe = $false; lastLaunchAtMs = 1 }
    }
    $script:voltControlStatus = [pscustomobject]@{ available = $true; globalMappingSafe = $true; processMappingSafe = $true; unmappedAccountIds = @(); managerId = 7; managerStartTicks = [long]70; relaunchDelayMs = 30000; accounts = $rows }
    $script:voltControlCheckedUtc = [datetime]::UtcNow
}
function Probe([int]$State = 0, [int]$Protocol = 0, $CrdId = $null, $CrdUtc = $null, [int]$Lock = 1, [string]$Desktop = 'Default', [string]$Display = '1920x1080x144x32', [int]$Session = 1, [int]$Console = 1) {
    @{ sessionId = $Session; consoleSessionId = $Console; connectState = $State; protocol = $Protocol; lockState = $Lock; inputDesktop = $Desktop; display = $Display; monitors = 1; crdEventId = $CrdId; crdEventUtc = $CrdUtc }
}

# ---- Policy -----------------------------------------------------------------------------
$p = Get-ArkuzoHealthPolicy @{ enabled = $true }
Assert ($p.farm_freeze_remote_confirm_sec -eq 20 -and $p.farm_freeze_remote_window_sec -eq 60 -and $p.remote_hold_max_sec -eq 600 -and $p.keep_display_awake -eq $true) 'defaults: 20 s, 60 s window, 10 min hold, display kept awake'
foreach ($bad in @(@{ farm_freeze_remote_confirm_sec = 5 }, @{ farm_freeze_remote_window_sec = 600 }, @{ remote_hold_max_sec = -1 }, @{ keep_display_awake = 'yes' })) {
    $threw = $false; try { [void](Get-ArkuzoHealthPolicy $bad) } catch { $threw = $true }
    Assert $threw ('rejects ' + (@($bad.Keys)[0]))
}
$shipped = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'config/defaults.json')) | ConvertFrom-Json
$fromFile = Get-ArkuzoHealthPolicy $shipped.health
Assert ($fromFile.farm_freeze_remote_confirm_sec -eq 20 -and $fromFile.keep_display_awake -eq $true -and $fromFile.remote_hold_max_sec -eq 600) 'shipped defaults carry the remote settings'
$lockText = [IO.File]::ReadAllText($source)
Assert (([regex]::Matches($lockText, 'Set-ArkuzoConfigLockLimits [$](?:healthPolicy|newHealth)')).Count -eq 2) 'config_lock limits are applied on load and on reload'
$locked = Get-ArkuzoHealthPolicy @{ farm_freeze_remote_confirm_sec = 10 }; Set-ArkuzoConfigLockLimits $locked
Assert ($locked.farm_freeze_remote_confirm_sec -eq 15) 'config_lock floors the remote confirmation at 15 s'
$kept = Get-ArkuzoHealthPolicy @{ farm_freeze_remote_confirm_sec = 40 }; Set-ArkuzoConfigLockLimits $kept
Assert ($kept.farm_freeze_remote_confirm_sec -eq 40) 'a longer remote confirmation is kept under config_lock'

# ---- Attribution --------------------------------------------------------------------------
Assert (Test-ArkuzoRemoteDisconnectOnset 905 900 $p) 'a freeze 5 s after a disconnect is attributed'
Assert (Test-ArkuzoRemoteDisconnectOnset 892 900 $p) 'onsets are recorded late: up to 10 s before still counts'
Assert (-not (Test-ArkuzoRemoteDisconnectOnset 880 900 $p)) 'a freeze well before the disconnect is not'
Assert (-not (Test-ArkuzoRemoteDisconnectOnset 961 900 $p)) 'nor one more than the window after it'
Assert (-not (Test-ArkuzoRemoteDisconnectOnset 905 $null $p)) 'no disconnect seen, no attribution'

New-Farm 6 6
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 925.0 895.0
Assert ($c.RemoteDisconnect -and $c.Confirmed -and $c.ConfirmSec -eq 20 -and $c.RemoteDisconnectOffsetSec -eq 5) 'after a disconnect the freeze is confirmed 20 s after the last member froze'
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 924.9 895.0
Assert (-not $c.Confirmed) 'not a moment earlier'
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 925.0
Assert (-not $c.RemoteDisconnect -and -not $c.Confirmed -and $c.ConfirmSec -eq 35) 'without a disconnect the usual 35 s applies'
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy 925.0 700.0
Assert (-not $c.RemoteDisconnect -and -not $c.Confirmed) 'an old disconnect does not shorten anything'
$slow = Get-ArkuzoHealthPolicy @{ enabled = $true; farm_freeze_confirm_sec = 20; farm_freeze_remote_confirm_sec = 60 }
$c = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $slow 925.0 895.0
Assert ($c.ConfirmSec -eq 20 -and $c.Confirmed) 'the remote confirmation never lengthens the normal one'

# The engine latches the episode early and records the cause.
New-Farm 6 6; $script:lastRemoteDisconnectSec = 895.0; $script:clock.Elapsed.TotalSeconds = 926.0
Update-ArkuzoFarmFreeze
Assert (Test-ArkuzoFarmFreezeActive) 'episode latched 21 s after the last member froze'
$det = @($events | Where-Object { $_.kind -eq 'FARM_FREEZE_DETECTED' })
Assert ($det.Count -eq 1 -and $det[0].data.cause -ceq 'remote-disconnect' -and $det[0].data.remoteDisconnectOffsetSec -eq 5) 'detection names the remote disconnect'

# Refreeze fallback: a NEW disconnect after the last episode is a new cause.
New-Farm 6 6; $script:lastFarmFreezeStartSec = 600.0; $script:lastRemoteDisconnectSec = 895.0; $script:clock.Elapsed.TotalSeconds = 926.0
Update-ArkuzoFarmFreeze
Assert (Test-ArkuzoFarmFreezeActive) 'a farm frozen again by a new disconnect is recycled fast again'
New-Farm 6 6; $script:lastFarmFreezeStartSec = 896.0; $script:lastRemoteDisconnectSec = 895.0; $script:clock.Elapsed.TotalSeconds = 945.0
Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive) -and $warned -contains 'farm-freeze') 'the same disconnect twice still falls back to the hang timeout'
New-Farm 6 6; $script:lastFarmFreezeStartSec = 600.0; $script:clock.Elapsed.TotalSeconds = 945.0
Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive)) 'and so does a refreeze with no disconnect at all'

# ---- Probe comparison ----------------------------------------------------------------------
$t0 = [datetime]'2026-11-08T15:19:00Z'
Assert (@(Compare-ArkuzoRemoteProbe $null (Probe)).Count -eq 0) 'first probe: nothing changed'
Assert ((@(Compare-ArkuzoRemoteProbe (Probe 0 0 1 $t0) (Probe 0 0 2 $t0.AddMinutes(4))) -join ',') -ceq 'CRD_DISCONNECTED') 'viewer left'
Assert ((@(Compare-ArkuzoRemoteProbe (Probe 0 0 2 $t0) (Probe 0 0 1 $t0.AddMinutes(1))) -join ',') -ceq 'CRD_CONNECTED') 'viewer joined'
Assert ((@(Compare-ArkuzoRemoteProbe (Probe 0 0 2 $t0) (Probe 0 0 2 $t0.AddMinutes(9))) -join ',') -ceq 'CRD_DISCONNECTED') 'a connect and disconnect between two probes still counts'
Assert ((@(Compare-ArkuzoRemoteProbe (Probe 0 2 -Session 3 -Console 1) (Probe 4 2 -Session 3 -Console 1)) -join ',') -ceq 'SESSION_DISCONNECTED') 'RDP session disconnected'
Assert ((@(Compare-ArkuzoRemoteProbe (Probe 4 2 -Session 3 -Console 1) (Probe 0 0 -Session 3 -Console 3)) -join ',') -ceq 'SESSION_RECONNECTED,SESSION_ON_CONSOLE,PROTOCOL_CHANGED') 'tscon to the console'
$all = @(Compare-ArkuzoRemoteProbe (Probe) (Probe 0 0 -Lock 0 -Desktop 'Winlogon' -Display '1280x720x60x32'))
Assert (($all -join ',') -ceq 'SESSION_LOCKED,INPUT_DESKTOP_CHANGED,DISPLAY_MODE_CHANGED') 'lock screen and display mode are logged'

# ---- Remote state: disconnect time and RDP hold --------------------------------------------
New-Farm 6 0
$now = [datetime]::UtcNow
[void](Update-ArkuzoRemoteState (Probe 0 0 2 $now.AddSeconds(-30)) $now 1000.0)
Assert ([math]::Abs([double]$script:lastRemoteDisconnectSec - 970.0) -lt 0.01) 'a Chrome Remote Desktop disconnect is placed on the saver clock'
[void](Update-ArkuzoRemoteState (Probe 0 0 1 $now.AddSeconds(5)) $now.AddSeconds(10) 1010.0)
Assert ([math]::Abs([double]$script:lastRemoteDisconnectSec - 970.0) -lt 0.01) 'a later connect keeps the last disconnect'
Assert (-not (Test-ArkuzoRemoteHold 1010.0)) 'Chrome Remote Desktop never holds recovery: its clients do not come back anyway'
[void](Update-ArkuzoRemoteState (Probe 4 2 -Session 3 -Console 1) $now.AddSeconds(20) 1020.0)
Assert ((Test-ArkuzoRemoteHold 1020.0) -and [double]$script:lastRemoteDisconnectSec -eq 1020.0) 'a disconnected RDP session holds recovery and counts as a disconnect'
[void](Update-ArkuzoRemoteState (Probe 4 2 -Session 3 -Console 1) $now.AddSeconds(30) 1030.0)
Assert ([double]$script:remoteHoldSinceSec -eq 1020.0) 'the hold runs from the first disconnected probe'
Assert ((Test-ArkuzoRemoteHold 1619.0) -and -not (Test-ArkuzoRemoteHold 1620.0)) 'for at most remote_hold_max_sec'
$script:healthPolicy.remote_hold_max_sec = 0
Assert (-not (Test-ArkuzoRemoteHold 1030.0)) '0 turns the hold off'
$script:healthPolicy.remote_hold_max_sec = 600
[void](Update-ArkuzoRemoteState (Probe 0 0 -Session 3 -Console 3) $now.AddSeconds(40) 1040.0)
Assert (-not (Test-ArkuzoRemoteHold 1040.0)) 'reconnecting or moving to the console ends the hold'

# The hold gates destructive recovery (except commit pressure) and the fast path.
New-Farm 6 6; $script:accountProvider = 'volt'; $script:remoteHoldSinceSec = 990.0
function Update-VoltRecoveryCapability { throw 'past-hold' }
$s = $tracked[101]; $s.HealthDecision = @{ Recycle = $true; Reason = 'SUSTAINED_HANG' }
Invoke-ClientRecovery 101 $s
Assert ($warned -contains 'remote-hold' -and -not $s.RecoveryRequested) 'a hang is left alone while the RDP session is disconnected'
$s.HealthDecision = @{ Recycle = $true; Reason = 'SYSTEM_COMMIT_PRESSURE' }
$reached = $false; try { Invoke-ClientRecovery 101 $s } catch { $reached = $_.Exception.Message -eq 'past-hold' }
Assert $reached 'commit pressure still protects the host during the hold'
$script:clock.Elapsed.TotalSeconds = 945.0; Update-ArkuzoFarmFreeze
Assert (-not (Test-ArkuzoFarmFreezeActive)) 'no farm-freeze episode while the session is disconnected'
$script:remoteHoldSinceSec = $null; Update-ArkuzoFarmFreeze
Assert (Test-ArkuzoFarmFreezeActive) 'and it starts once the session is back'

# ---- Status record carries no account names --------------------------------------------------
$script:remoteProbe = Probe 0 0 1 $t0
$status = Get-ArkuzoRemoteStatus
Assert ($status.chromeRemoteDesktop.connected -and $status.protocol -ceq 'console' -and $status.onConsole -and $status.locked -eq $false -and $status.display -ceq '1920x1080x144x32') 'status: Chrome Remote Desktop connected on the console'
$script:remoteProbe = Probe 4 2 -Session 3 -Console 1; $script:remoteHoldSinceSec = 900.0; $script:clock.Elapsed.TotalSeconds = 1000.0
$status = Get-ArkuzoRemoteStatus
Assert ($status.protocol -ceq 'rdp' -and $status.sessionState -ceq 'disconnected' -and -not $status.onConsole -and $status.hold -and $status.holdLeftSec -eq 500 -and $null -eq $status.chromeRemoteDesktop) 'status: disconnected RDP session with time left on the hold'

# A connect logged before the last boot is stale (a restart while connected logs no disconnect).
$boot = [datetime]'2026-11-08T14:19:00Z'
$stale = Probe 0 0 1 $boot.AddHours(-3); $stale.bootUtc = $boot
$fresh = Probe 0 0 1 $boot.AddMinutes(5); $fresh.bootUtc = $boot
Assert (-not (Test-ArkuzoCrdConnected $stale) -and (Test-ArkuzoCrdConnected $fresh)) 'only a connect since boot counts as connected'
$script:remoteProbe = $stale
Assert (-not (Get-ArkuzoRemoteStatus).chromeRemoteDesktop.connected) 'so a stale connect raises no notice'

# ---- Chrome Remote Desktop events: one search, then only new records ---------------------------
$script:crdServiceCheckSec = $null; $script:crdBookmark = $null; $script:crdLast = $null
$a = Read-ArkuzoChromotingEvent 0
$sw = [Diagnostics.Stopwatch]::StartNew(); $b = Read-ArkuzoChromotingEvent 2; $sw.Stop()
Assert (($null -eq $a -and $null -eq $b) -or ($a.id -eq $b.id -and $a.utc -eq $b.utc)) 'the incremental read keeps the newest connect/disconnect'
if ($script:crdInstalled) {
    Assert ($null -ne $script:crdBookmark -and $sw.ElapsedMilliseconds -lt 100) ("later reads only cover new records ($($sw.ElapsedMilliseconds) ms)")
}
function Get-Service { $null }
$script:crdServiceCheckSec = $null
Assert ($null -eq (Read-ArkuzoChromotingEvent 3) -and $null -eq $script:crdBookmark) 'without the Chrome Remote Desktop host nothing is read'
Remove-Item function:Get-Service

# ---- Live, read-only probes on this machine -----------------------------------------------------
$script:crdServiceCheckSec = $null; $script:crdBookmark = $null; $script:crdLast = $null
$live = Get-ArkuzoRemoteProbe
Assert ($live.bootUtc -is [datetime] -and $live.bootUtc -lt [datetime]::UtcNow) 'boot time comes from the uptime counter'
Assert ([int]$live.sessionId -ge 0 -and $live.display -match '^\d+x\d+x\d+x\d+$' -and [int]$live.monitors -ge 0) 'probe reads session and display'
Assert ($null -eq $live.crdEventId -or [int]$live.crdEventId -in 1, 2) 'Chrome Remote Desktop state comes from its own events, if installed'
$json = (ConvertTo-ArkuzoRemoteRecord $live) | ConvertTo-Json -Depth 4 -Compress
Assert ($json -notmatch '@') 'the logged record never carries the viewer account from the event message'
$script:events = New-Object Collections.ArrayList; $script:warned = New-Object Collections.ArrayList; $script:clock = @{ Elapsed = @{ TotalSeconds = 5.0 } }
$script:remoteProbe = $null; $script:remoteProbeSec = $null; $script:tracked = @{}
Update-ArkuzoRemoteSession
Assert (@($events | Where-Object { $_.kind -eq 'REMOTE_SESSION_STATE' }).Count -eq 1) 'the first probe logs the starting state once'
Update-ArkuzoRemoteSession
Assert (@($events).Count -eq 1) 'and is throttled to one probe per 2 s'
# Keep-awake: a process-scoped request, released again.
$script:keepAwakeOn = $false; $script:keepAwakeFailed = $false
Update-ArkuzoKeepAwake $true; Update-ArkuzoKeepAwake $true; Update-ArkuzoKeepAwake $false
$ka = @($events | Where-Object { $_.kind -eq 'KEEP_AWAKE' })
Assert ($ka.Count -eq 2 -and $ka[0].data.on -and -not $ka[1].data.on -and -not $script:keepAwakeOn) 'keep-awake turns on once and is released'

Write-Host "PASS: remote-session detection, freeze attribution, refreeze exception, RDP hold, status and keep-awake ($checks checks)"
