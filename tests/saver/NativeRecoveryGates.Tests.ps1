#requires -Version 5.1
# Arkuzo provider closure gates. A failing account is never quarantined, so it must not hold
# the handoff gate for the others; a verified kicked client is closed without cooldown or
# hourly budget (and is not charged); a still-running hung client keeps both; Volt keeps the
# serial handoff gate. Clients are fake process objects: nothing real is ever closed.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
# Only IO is faked.
function Write-Diagnostic($kind, $data) { [void]$script:events.Add($kind) }
function Warn-Throttled($key, $message) { [void]$script:warned.Add($key) }
function Get-ArkuzoAccountDisplayLabel { 'account' }
function Save-ArkuzoRecoveryJournal { }
function Update-VoltRecoveryCapability { $script:voltStatus = [pscustomobject]@{ safeToRecycle = $true } }
function Update-ArkuzoVoltControl { $script:voltControlCheckedUtc = [datetime]::UtcNow }
function Test-ArkuzoRemoteHold { $false }
function Get-ArkuzoHealthDecision($State) { return $State.Fixed }
function Get-ArkuzoRecoveryHealthSample($Watcher, $Reason, $State) { return @{ responding = $false; windowPresent = $true; launchError = $false; isDisconnected = [bool]$State.isDisconnected; privateMB = 1000; ageSec = 600; systemCommitPercent = 0; eligible = $true } }
function Get-CimInstance { param($ClassName, $Filter) $id = [int]($Filter -replace '\D', ''); $c = @($script:fakeClients | Where-Object { $_.Pid -eq $id }); if ($c.Count -eq 1) { return [pscustomobject]@{ ProcessId = $id; Name = 'RobloxPlayerBeta.exe'; CommandLine = '--app -t T -b ' + $c[0].Tracker } } }

$A = '11111111-1111-4111-8111-111111111111'; $B = '22222222-2222-4222-8222-222222222222'; $C = '33333333-3333-4333-8333-333333333333'
function New-FakeClient([int]$ProcessId, [string]$Tracker, [string]$Reason, [bool]$Kicked) {
    $p = [pscustomobject]@{ Id = $ProcessId; StartTime = [datetime]::UtcNow.AddMinutes(-20); HasExited = $false; ProcessName = 'RobloxPlayerBeta'; Kills = 0 }
    $p | Add-Member ScriptMethod Refresh { }
    $p | Add-Member ScriptMethod Kill { $this.Kills++; $this.HasExited = $true }
    $p | Add-Member ScriptMethod WaitForExit { param($ms) $this.HasExited }
    $script:fakeClients += @{ Pid = $ProcessId; Tracker = $Tracker }
    return @{ Watcher = $p; StartTicks = $p.StartTime.ToUniversalTime().Ticks; TrackerId = $Tracker; ParentId = 0; RecoveryRequested = $false; RecoveryStatus = ''
        isDisconnected = $Kicked; GameReady = -not $Kicked; EverGameReady = $true; HangSince = -1.0; FreezeSince = -1.0; LastSnapshot = @{ privateMB = 1000 }
        Fixed = @{ Recycle = $true; Reason = $Reason; Status = $Reason } ; HealthDecision = @{ Recycle = $true; Reason = $Reason; Status = $Reason } }
}
function Reset-Fixture([string]$Provider = 'arkuzo') {
    $script:events = New-Object Collections.ArrayList; $script:warned = New-Object Collections.ArrayList
    $script:MonitorOnly = $false; $script:ownsControllerMutex = $true; $script:recoveryJournalHealthy = $true; $script:recoveryJournalCorrupt = $false; $script:logFailed = $false
    $script:healthPolicy = Get-ArkuzoHealthPolicy @{ enabled = $true; cooldown_sec = 90; max_recycles_per_hour = 20 }
    $script:restorePolicy = Get-ArkuzoRestorePolicy @{ enabled = $true }
    $script:accountProvider = $Provider; $script:clock = @{ Elapsed = @{ TotalSeconds = 1000.0 } }
    $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}; $script:farmFreeze = $null; $script:fakeClients = @()
    $script:voltStatus = [pscustomobject]@{ safeToRecycle = $true }; $script:voltParents = @{}
    # A has been failing for hours (never quarantined) and holds a pending entry.
    $failing = New-ArkuzoPendingEntry $A '100000000001'; $failing.retryCount = 40; $failing.createdUtc = [datetime]::UtcNow.AddHours(-3).ToString('o')
    $script:recoveryPending = @{ $A = $failing }
    # The hourly budget is used up and the last closure was a minute ago.
    $script:recoveryAttempts = @(1..20 | ForEach-Object { [datetime]::UtcNow.AddSeconds(-60 - $_) })
}
function Set-Status($Rows, [bool]$MappingSafe = $true) {
    $script:voltControlStatus = [pscustomobject]@{ available = $true; globalMappingSafe = $MappingSafe; processMappingSafe = $MappingSafe; provider = $script:accountProvider; farmRunning = $true
        managerId = $PID; managerStartTicks = 1; relaunchDelayMs = 30000; accounts = @($Rows | ForEach-Object {
            [pscustomobject]@{ accountId = $_[0]; trackerId = $_[1]; processId = $_[2]; controlReady = $true; cookieStatus = 'alive'; cookieAlive = $true; autoRelaunch = $true; uiStatus = $(if ($_[2]) { 'Connected' } else { 'Idle' }); suspensionSafe = $false; username = 'u' } }) }
    $script:voltControlCheckedUtc = [datetime]::UtcNow
}

# --- Handoff gate, Arkuzo: an exactly mapped client is not held by another account's open relaunch.
Reset-Fixture
$kickB = New-FakeClient 201 '100000000002' 'IN_GAME_DISCONNECT' $true
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201))
Assert (Test-ArkuzoRecoveryHandoff $B $kickB 'IN_GAME_DISCONNECT') 'Arkuzo: another account''s failing relaunch does not hold an exactly mapped client'
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201)) $false
Assert (-not (Test-ArkuzoRecoveryHandoff $B $kickB 'IN_GAME_DISCONNECT')) 'Arkuzo: not when the farm is not exactly mapped (two clients on one account)'
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201))
Assert (-not (Test-ArkuzoRecoveryHandoff $A $kickB 'IN_GAME_DISCONNECT')) 'Arkuzo: not for a client that maps to a different account'
$kickB.Watcher.StartTime = $kickB.Watcher.StartTime.AddSeconds(1)
Assert (-not (Test-ArkuzoRecoveryHandoff $B $kickB 'IN_GAME_DISCONNECT')) 'Arkuzo: not when the process start time differs (pid reused)'
$kickB.Watcher.StartTime = $kickB.Watcher.StartTime.AddSeconds(-1)
Reset-Fixture 'volt'
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201))
$hangB = New-FakeClient 201 '100000000002' 'SUSTAINED_HANG' $false
Assert (-not (Test-ArkuzoRecoveryHandoff $B $hangB 'SUSTAINED_HANG')) 'Volt keeps the serial handoff gate'

# --- Closures: a kicked client goes at once, uncharged; a hung one still waits for the budget.
Reset-Fixture
$kickB = New-FakeClient 201 '100000000002' 'IN_GAME_DISCONNECT' $true
$kickC = New-FakeClient 301 '100000000003' 'IN_GAME_DISCONNECT' $true
$script:tracked = @{ 201 = $kickB; 301 = $kickC }
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201), @($C, '100000000003', 301))
Invoke-ArkuzoRecoveryCandidates
Assert ($kickB.Watcher.Kills -eq 1 -and $kickC.Watcher.Kills -eq 1) 'both kicked clients are closed in one pass, despite a failing account, the cooldown and a full hourly budget'
Assert ($script:recoveryAttempts.Count -eq 20) 'kicked closures are not charged to the hourly budget'
Assert ($script:recoveryPending.ContainsKey($B) -and $script:recoveryPending.ContainsKey($C) -and $null -eq $script:recoveryPending[$B].nextRetryUtc -and $script:recoveryPending[$B].closedUtc) 'they go straight to the relaunch queue'
Assert (@($script:events | Where-Object { $_ -eq 'CLIENT_CLOSED_FOR_RECOVERY' }).Count -eq 2) 'each closure is audited'

Reset-Fixture
$hangB = New-FakeClient 201 '100000000002' 'SUSTAINED_HANG' $false
$script:tracked = @{ 201 = $hangB }
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201))
Invoke-ArkuzoRecoveryCandidates
Assert ($hangB.Watcher.Kills -eq 0 -and $script:warned -contains 'recovery-budget') 'a still-running hung client keeps the cooldown and the hourly budget'
$script:recoveryAttempts = @()
$hangB.LastRecoveryRefusalUtc = $null
Invoke-ArkuzoRecoveryCandidates
Assert ($hangB.Watcher.Kills -eq 1 -and $script:recoveryAttempts.Count -eq 1) 'with budget it is closed despite the failing account (no handoff deadlock) and charged'

# --- A bare "ClientReplicator removed" executor signal can be an ordinary teleport: it keeps the gates.
Reset-Fixture
$teleB = New-FakeClient 201 '100000000002' 'IN_GAME_DISCONNECT' $true
$teleB.DisconnectSource = 'NetworkClient.ChildRemoved'
$script:tracked = @{ 201 = $teleB }
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201))
Invoke-ArkuzoRecoveryCandidates
Assert ($teleB.Watcher.Kills -eq 0 -and $script:warned -contains 'recovery-budget') 'a ClientReplicator-only signal stays behind the cooldown and hourly budget'
$teleB.DisconnectSource = 'log'
$teleB.LastRecoveryRefusalUtc = $null
Invoke-ArkuzoRecoveryCandidates
Assert ($teleB.Watcher.Kills -eq 1 -and $script:recoveryAttempts.Count -eq 20) 'a kick reason from the Roblox log is closed at once, uncharged'

# --- An audit failure still blocks a kicked closure (a closure needs a successful log write).
Reset-Fixture
$kickB = New-FakeClient 201 '100000000002' 'IN_GAME_DISCONNECT' $true
$script:tracked = @{ 201 = $kickB }
Set-Status @(@($A, '100000000001', $null), @($B, '100000000002', 201))
function Write-Diagnostic($kind, $data) { [void]$script:events.Add($kind); if ($kind -eq 'RECOVERY_REQUESTED') { $script:logFailed = $true } }
Invoke-ArkuzoRecoveryCandidates
Assert ($kickB.Watcher.Kills -eq 0 -and -not $script:recoveryPending.ContainsKey($B)) 'no closure without a successful audit write; the reservation is rolled back'

Write-Host "PASS: Arkuzo closure gates: exact mapping instead of the serial handoff, kicked clients uncharged and immediate, hung clients budgeted, Volt unchanged ($script:checks checks)"
