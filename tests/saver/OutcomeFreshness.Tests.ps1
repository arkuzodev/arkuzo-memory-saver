#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
$now=[datetime]::UtcNow
$policy=@{ready_stable_sec=30;restore_wait_sec=90}
function New-Entry {return @{accountId='test';oldPid=71;oldStartTicks=100;createdUtc=$now.ToString('o');readySinceUtc=$null;lastObservedUtc=$null;replacementPid=0;replacementStartTicks=0}}
$account=@{available=$true;accountId='test';controlReady=$true;autoRelaunch=$true;cookieAlive=$true;processId=72;startTicks=200;uiStatus='Connected';windowPresent=$true;responding=$true;launchError=$false;isDisconnected=$false;gameReady=$true;sampleUtc=$now.ToString('o')}
$entry=New-Entry
foreach($s in @(0,5,10,15,20,25,30,35,40)){
    Assert ((Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds($s) $policy) -ne 'Ready') 'Reevaluating one retained snapshot must never establish readiness'
}
Assert (-not $entry.readySinceUtc -and -not $entry.lastObservedUtc) 'Stale snapshot must invalidate continuity'
foreach($invalid in @($null,'not-a-date',$now.AddSeconds(1).ToString('o'),$now.AddSeconds(-11).ToString('o'))){
    $entry=New-Entry;$account.sampleUtc=$invalid
    Assert ((Get-ArkuzoOutcomeDecision $entry $account $now $policy) -ne 'Ready') 'Missing, malformed, future or stale evidence cannot restore'
    Assert (-not $entry.readySinceUtc -and -not $entry.lastObservedUtc) 'Invalid evidence cannot begin readiness'
}
$entry=New-Entry
foreach($s in @(0,10,20,30)){
    $account.sampleUtc=$now.AddSeconds($s).ToString('o')
    $d=Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds($s+4) $policy
    if($s -lt 30){Assert ($d -eq 'Observing') 'Readiness uses sample time, not later evaluation time'}
}
Assert ($d -eq 'Ready') 'Fresh contiguous snapshots establish readiness'
Assert (([datetime]$entry.readySinceUtc).ToUniversalTime() -eq $now) 'Confirmation starts at actual successful sample time'
# A failed sample between outcome evaluations must survive a successful overwrite.
$entry=New-Entry
$state=@{StartTicks=200;LastSnapshot=@{windowPresent=$true;responding=$true;launchError=$false};HealthSnapshotUtc=$now}
$script:tracked=@{72=$state;73=@{StartTicks=300}}
$other=New-Entry;$other.accountId='other';$other.replacementPid=73;$other.replacementStartTicks=300
$other.readySinceUtc=$now.ToString('o');$other.lastObservedUtc=$now.AddSeconds(20).ToString('o')
$previousGeneration=New-Entry;$previousGeneration.accountId='previous';$previousGeneration.replacementPid=72;$previousGeneration.replacementStartTicks=199
$previousGeneration.readySinceUtc=$other.readySinceUtc;$previousGeneration.lastObservedUtc=$other.lastObservedUtc
$script:recoveryPending=@{test=$entry;other=$other;previous=$previousGeneration}
foreach($s in @(0,10,20)){
    $state.HealthSnapshotUtc=$now.AddSeconds($s);$account.sampleUtc=$state.HealthSnapshotUtc.ToString('o')
    Assert ((Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds($s) $policy) -eq 'Observing') 'Initial healthy interval remains incomplete'
}
# t25: no outcome evaluation; t30: fresh health arrives before the next outcome.
Reset-ArkuzoHealthSample $state
$state.LastSnapshot=@{windowPresent=$true;responding=$true;launchError=$false};$state.HealthSnapshotUtc=$now.AddSeconds(30)
$account.sampleUtc=$state.HealthSnapshotUtc.ToString('o')
Assert ((Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds(30) $policy) -eq 'Observing') 'Transient sampling failure must prevent Ready at t30 after successful overwrite'
Assert (([datetime]$entry.readySinceUtc).ToUniversalTime() -eq $now.AddSeconds(30)) 'Healthy confirmation must restart at t30'
Assert ($other.readySinceUtc -eq $now.ToString('o') -and $other.lastObservedUtc -eq $now.AddSeconds(20).ToString('o')) 'Unrelated account continuity must remain intact'
Assert ($previousGeneration.readySinceUtc -eq $other.readySinceUtc -and $previousGeneration.lastObservedUtc -eq $other.lastObservedUtc) 'Same PID with different start ticks must remain unaffected'
foreach($s in @(40,50,60)){
    $account.sampleUtc=$now.AddSeconds($s).ToString('o')
    $d=Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds($s) $policy
    if($s -lt 60){Assert ($d -eq 'Observing') 'New complete healthy interval is required after sampling failure'}
}
Assert ($d -eq 'Ready') 'New contiguous healthy interval establishes readiness only at t60'
# Exercise actual outcome adapter with mocked external IO and exact identity only.
function Test-ArkuzoClientIdentity {return $true}
function Write-Diagnostic {}
function Warn-Throttled {}
function Save-ArkuzoRecoveryJournal {}
$script:MonitorOnly=$false;$script:ownsControllerMutex=$true;$script:recoveryJournalHealthy=$true;$script:logFailed=$false
$script:restorePolicy=@{enabled=$true;restore_missing=$false;excluded_account_ids=@();ready_stable_sec=30;restore_wait_sec=90}
$script:voltControlStatus=@{available=$true;accounts=@(@{accountId='test';processId=72;trackerId='222';controlReady=$true;autoRelaunch=$true;cookieAlive=$true;uiStatus='Connected'})}
$state=@{TrackerId='222';Watcher=@{};StartTicks=200;GameReady=$true;LastSnapshot=@{windowPresent=$true;responding=$true;launchError=$false};HealthSnapshotUtc=$now.AddSeconds(-30)}
$script:tracked=@{72=$state}
$entry=New-Entry;$entry.readySinceUtc=$now.AddSeconds(-40).ToString('o');$entry.lastObservedUtc=$now.AddSeconds(-5).ToString('o');$entry.replacementPid=72;$entry.replacementStartTicks=200
$script:recoveryPending=@{test=$entry};$script:voltControlCheckedUtc=[datetime]::UtcNow
Update-ArkuzoRecoveryOutcomes
Assert ($recoveryPending.ContainsKey('test')) 'Adapter must not consume a stale healthy snapshot'
Assert (-not $entry.readySinceUtc) 'Adapter must break stale continuity'
$state.HealthSnapshotUtc=[datetime]::UtcNow
Reset-ArkuzoHealthSample $state
Assert (-not $state.LastSnapshot -and -not $state.HealthSnapshotUtc) 'Failed client sampling must invalidate restoration snapshot and timestamp'
foreach($n in 1..5){
    $script:voltControlCheckedUtc=[datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($recoveryPending.ContainsKey('test') -and -not $entry.readySinceUtc) 'Repeated failed samples cannot release pending restoration'
}
Write-Output 'PASS: stale/replayed/malformed/future samples, actual sample clock, transient failure restarts t30-to-t60 confirmation, unrelated account/generation preserved, adapter freshness, repeated sampler failures'
