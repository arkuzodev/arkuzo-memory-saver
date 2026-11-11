#requires -Version 5.1
# The recovery decisions with an explicit context object instead of script state:
# Get-ArkuzoControlledAccount, Test-ArkuzoSuspendedRowsSafe, Test-ArkuzoRecoveryHandoff, and the
# pure launch gates Test-ArkuzoLaunchSlotFree and Get-ArkuzoLaunchOrder. Every input is in the
# test; no script variable is set, so a decision that still reads one fails here.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
# Script state that would mislead a decision reading it instead of its context.
$restorePolicy = @{ enabled = $false }; $voltControlStatus = @{ available = $false }; $voltControlCheckedUtc = $null
$script:suspendedAccounts = $null; $script:recoveryPending = $null; $script:accountProvider = 'volt'

$now = [datetime]::new(2026, 11, 10, 12, 0, 0, [DateTimeKind]::Utc)
$a1 = '11111111-1111-4111-8111-111111111111'; $a2 = '22222222-2222-4222-8222-222222222222'
function Row([string]$Id, [string]$Tracker, [int]$ProcessId, [string]$Cookie = 'alive') {
    [pscustomobject]@{ accountId = $Id; trackerId = $Tracker; processId = $ProcessId; controlReady = $true; cookieStatus = $Cookie; cookieAlive = ($Cookie -ceq 'alive'); autoRelaunch = $true; uiStatus = 'Connected'; suspensionSafe = $false }
}
function Context([object[]]$Rows, [hashtable]$Pending = @{}, [bool]$Native = $true, [double]$AgeSec = 2) {
    [pscustomobject]@{
        NowUtc = $now
        RestorePolicy = @{ enabled = $true; relaunch_delay_sec = 30; excluded_account_ids = @() }
        ControlStatus = [pscustomobject]@{ available = $true; globalMappingSafe = $true; relaunchDelayMs = 30000; accounts = @($Rows) }
        ControlCheckedUtc = $now.AddSeconds(-$AgeSec)
        SuspendedAccounts = @{}
        RecoveryPending = $Pending
        AccountProvider = $(if ($Native) { 'arkuzo' } else { 'volt' })
        NativeProvider = $Native
    }
}
# A stand-in for the retained process handle (Test-ArkuzoClientIdentity reads these).
function Watcher([int]$ProcessId, [long]$Ticks) {
    $w = [pscustomobject]@{ Id = $ProcessId; HasExited = $false; StartTime = [datetime]::new($Ticks, [DateTimeKind]::Utc); ProcessName = 'RobloxPlayerBeta' }
    $w | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
    return $w
}

# Mapping: exactly one ready row for this tracker and process.
$ctx = Context @((Row $a1 '1001' 501), (Row $a2 '1002' 502))
Assert ((Get-ArkuzoControlledAccount '1001' 501 $ctx).accountId -ceq $a1) 'an exact row maps'
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 502 $ctx)) 'tracker and process must both match'
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 (Context @((Row $a1 '1001' 501), (Row $a2 '1001' 501))))) 'two matching rows map nothing'
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 (Context @((Row $a1 '1001' 501 'dead'))))) 'a dead cookie maps nothing'
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 (Context @((Row $a1 '1001' 501)) -AgeSec 26))) 'control status older than 25 s maps nothing'
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 (Context @((Row $a1 '1001' 501)) -AgeSec -1))) 'control status from the future maps nothing'
$ctx = Context @((Row $a1 '1001' 501)); $ctx.RestorePolicy.excluded_account_ids = @($a1)
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 $ctx)) 'an excluded account maps nothing'
$ctx = Context @((Row $a1 '1001' 501)); $ctx.RestorePolicy.enabled = $false
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 $ctx)) 'recovery off maps nothing'
$ctx = Context @((Row $a1 '1001' 501)); $ctx.ControlStatus.relaunchDelayMs = 1000
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 $ctx)) 'a relaunch delay below recovery.relaunch_delay_sec maps nothing'
$ctx = Context @((Row $a1 '1001' 501)); $ctx.SuspendedAccounts = @{ $a1 = @{ accountId = $a1 } }
Assert ($null -eq (Get-ArkuzoControlledAccount '1001' 501 $ctx)) 'a suspended account maps nothing'

# Suspended rows: a suspended account must still be an exact idle row.
$idle = Row $a2 '1002' 0 'dead'; $idle.uiStatus = 'Idle'; $idle.suspensionSafe = $true
$ctx = Context @((Row $a1 '1001' 501), $idle); $ctx.SuspendedAccounts = @{ $a2 = @{ accountId = $a2; provider = 'arkuzo' } }
Assert (Test-ArkuzoSuspendedRowsSafe $ctx) 'an idle suspended row is safe'
Assert ((Get-ArkuzoControlledAccount '1001' 501 $ctx).accountId -ceq $a1) 'and does not block other accounts'
$idle.processId = 777
Assert (-not (Test-ArkuzoSuspendedRowsSafe $ctx)) 'a suspended account with a process is not'

# Handoff, Arkuzo provider: an exactly mapped client, other accounts' recoveries never block it.
$state = @{ TrackerId = '1001'; StartTicks = 638000000000000000; Watcher = (Watcher 501 638000000000000000) }
$ctx = Context @((Row $a1 '1001' 501), (Row $a2 '1002' 502)) @{ $a2 = @{ accountId = $a2 } }
Assert (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx) 'Arkuzo: another account''s open recovery does not block'
Assert (-not (Test-ArkuzoRecoveryHandoff $a2 $state 'SUSTAINED_HANG' $null $ctx)) 'Arkuzo: the account must be the client''s own'
$moved = @{ TrackerId = '1001'; StartTicks = 638000000000000000; Watcher = (Watcher 501 638000000000000001) }
Assert (-not (Test-ArkuzoRecoveryHandoff $a1 $moved 'SUSTAINED_HANG' $null $ctx)) 'Arkuzo: a different process generation is refused'
$ctx.ControlStatus.globalMappingSafe = $false
Assert (-not (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx)) 'Arkuzo: not globally mapped, refused'
$ctx = Context @((Row $a1 '1001' 501)) @{} -AgeSec 30
Assert (-not (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx)) 'stale control status, refused'
$ctx = Context @((Row $a1 '1001' 501)); $ctx.RecoveryPending = $null
Assert (-not (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx)) 'no journal loaded, refused'

# Handoff, Volt provider: no collateral closures while another account is missing.
$ctx = Context @((Row $a1 '1001' 501), (Row $a2 '1002' 502)) @{} -Native $false
Assert (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx) 'Volt: nothing open, allowed'
$ctx.RecoveryPending = @{ $a2 = @{ accountId = $a2 } }
Assert (-not (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx)) 'Volt: another account''s open recovery blocks'
$ctx.RecoveryPending = @{ $a1 = @{ accountId = $a1; nextRetryUtc = $now.AddSeconds(30).ToString('o') } }
Assert (-not (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx)) 'Volt: a retry of the same account waits for its time'
$ctx.RecoveryPending = @{ $a1 = @{ accountId = $a1; nextRetryUtc = $now.AddSeconds(-1).ToString('o') } }
Assert (Test-ArkuzoRecoveryHandoff $a1 $state 'SUSTAINED_HANG' $null $ctx) 'Volt: then it may go'
Assert (-not (Test-ArkuzoRecoveryHandoff '' $state 'SUSTAINED_HANG' $null $ctx)) 'Volt: an unknown account never goes while anything is open'

# Launch slot: one ticket request at a time, launches GapSec apart from both kinds of start.
Assert (Test-ArkuzoLaunchSlotFree $now 0 12 $null $null) 'nothing launched yet'
Assert (-not (Test-ArkuzoLaunchSlotFree $now 1 12 $null $null)) 'a ticket request in flight holds the slot'
Assert (-not (Test-ArkuzoLaunchSlotFree $now 0 12 $now.AddSeconds(-11.5) $null)) '11.5 s after the last launch request is too soon for 12 s spacing'
Assert (Test-ArkuzoLaunchSlotFree $now 0 12 $now.AddSeconds(-12) $null) '12 s after it is not'
Assert (-not (Test-ArkuzoLaunchSlotFree $now 0 12 $null $now.AddSeconds(-3))) 'a client that just appeared by other means also spaces launches'

# Launch order: least recently tried first, never tried first of all, then oldest, then id.
$pending = [ordered]@{
    'c' = @{ lastLaunchUtc = $now.AddSeconds(-5).ToString('o'); createdUtc = $now.AddMinutes(-9).ToString('o') }
    'a' = @{ lastLaunchUtc = $now.AddSeconds(-60).ToString('o'); createdUtc = $now.AddMinutes(-1).ToString('o') }
    'b' = @{ createdUtc = $now.AddMinutes(-2).ToString('o') }
    'd' = @{ createdUtc = $now.AddMinutes(-3).ToString('o') }
    'e' = @{ createdUtc = $now.AddMinutes(-3).ToString('o') }
}
Assert ((Get-ArkuzoLaunchOrder $pending) -join ',' -ceq 'd,e,b,a,c') ('fair order, got ' + ((Get-ArkuzoLaunchOrder $pending) -join ','))
$single = Get-ArkuzoLaunchOrder @{ 'only' = @{} }
Assert ($single -is [array] -and $single.Count -eq 1 -and $single[0] -ceq 'only') 'one entry is still a list'
Assert ((Get-ArkuzoLaunchOrder @{}).Count -eq 0) 'no entries, empty list'

# Without -Context the decisions still read the script state, as before.
$restorePolicy = (Context @()).RestorePolicy; $voltControlStatus = (Context @((Row $a1 '1001' 501))).ControlStatus; $voltControlCheckedUtc = [datetime]::UtcNow
$script:suspendedAccounts = @{}; $script:recoveryPending = @{}; $script:accountProvider = 'arkuzo'
Assert ((Get-ArkuzoControlledAccount '1001' 501).accountId -ceq $a1) 'the script state is the default context'
$fresh = New-ArkuzoDecisionContext
Assert ($fresh.NativeProvider -and $fresh.ControlStatus -eq $voltControlStatus -and $fresh.RecoveryPending -eq $script:recoveryPending) 'New-ArkuzoDecisionContext takes the live objects, not copies'

Write-Output "PASS: $script:checks decision checks (context object, pure launch gates)"
