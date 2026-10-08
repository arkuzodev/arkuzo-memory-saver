#requires -Version 5.1
param([string]$Case='All')
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$t,[ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert($ok,$message) { if (-not $ok) { throw "FAIL: $message" } }
# Only IO/authority is faked: recovery, target identity checks and health decisions
# are complete production AST functions. No controller startup or live processes.
function New-FakeProcess {
    $p=[pscustomobject]@{Id=101;StartTime=[datetime]'2026-10-08T00:00:00Z';HasExited=$false;ProcessName='RobloxPlayerBeta';Kills=0}
    $p|Add-Member ScriptMethod Refresh {}
    $p|Add-Member ScriptMethod Kill { $this.Kills++;$this.HasExited=$true }
    $p|Add-Member ScriptMethod WaitForExit {param($ms) $this.HasExited}
    return $p
}
function Initialize-Fixture {
    $script:clock=@{Elapsed=@{TotalSeconds=100.0}}
    $script:MonitorOnly=$false;$script:ownsControllerMutex=$true;$script:recoveryJournalHealthy=$true;$script:logFailed=$false
    $script:healthPolicy=Get-ArkuzoHealthPolicy @{enabled=$true;warmup_sec=60;private_limit_sustain_sec=60;hang_timeout_sec=60}
    $script:restorePolicy=Get-ArkuzoRestorePolicy @{enabled=$true}
    $script:voltStatus=@{safeToRecycle=$true};$script:voltParents=@{7=@{StartTicks=1}}
    $script:voltControlStatus=@{managerId=7;managerStartTicks=1}
    $script:systemMemory=@{commitPercent=40};$script:recoveryAttempts=@();$script:recoveryPending=@{};$script:suspendedAccounts=@{}
    $script:events=New-Object 'System.Collections.Generic.List[string]'
    $script:delay=3.0;$script:checks=0;$script:mode='normal';$script:samples=0;$script:observationCursor=0;$script:observationBusy=$false
    $script:watcher=New-FakeProcess
    $script:state=@{Watcher=$watcher;StartTicks=$watcher.StartTime.ToUniversalTime().Ticks;ParentId=7;TrackerId='123';RecoveryRequested=$false;RecoveryStatus='';HangSince=-1.0;PrivateLimitSince=0.0;LastHealthSampleTime=100.0;LastSnapshot=@{privateMB=6000};HealthDecision=@{Recycle=$true;Reason='PRIVATE_COMMIT_LIMIT'}}
    $script:tracked=@{101=$state}
}
function Warn-Throttled {}
function Update-VoltRecoveryCapability {}
function Test-ArkuzoVoltOwnership {return $true}
function Test-ArkuzoLiveVoltParent {return ($script:mode -ne 'parent')}
function Test-ArkuzoRecoveryHandoff {return ($script:mode -ne 'collateral')}
function Get-ArkuzoControlledAccount {
    if ($script:mode -eq 'ownership' -and $script:checks -ge 2) {return $null}
    return @{accountId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}
}
function Get-CimInstance {return @{ProcessId=101;Name='RobloxPlayerBeta.exe';CommandLine='+browsertrackerid:123'}}
function Get-ArkuzoVoltRecoveryStatus {
    param($Root,$TrackerId)
    $script:checks++
    $child=[pscustomobject]@{Remaining=[double]$script:delay;Waits=0}
    $child|Add-Member ScriptMethod WaitForExit {
        param($ms)
        $this.Waits++;$dt=[math]::Min($this.Remaining,$ms/1000.0)
        $script:clock.Elapsed.TotalSeconds+=$dt;$this.Remaining-=$dt
        return ($this.Remaining -le 0.000001)
    }
    # IO seam uses the production observation-aware wait once available.
    if ($script:mode -ne 'silentIO' -and (Get-Command Wait-ArkuzoObservedProcess -ErrorAction SilentlyContinue)) {
        $null=Wait-ArkuzoObservedProcess $child 3000
    } else { $null=$child.WaitForExit(3000) }
    if ($script:mode -eq 'generation' -and $script:checks -eq 2) { $script:watcher.StartTime=$script:watcher.StartTime.AddSeconds(1) }
    return @{safeToRecycle=$true;targetReady=$true;matchedAccountCount=1}
}
function Save-ArkuzoRecoveryJournal { if ($script:mode -eq 'journal') {throw 'fixture journal failure'} }
function Write-Diagnostic {param($name,$payload) $script:events.Add($name);if ($script:mode -eq 'audit') {$script:logFailed=$true} }
function Get-ArkuzoRecoveryHealthSample {
    param($Watcher,$Reason,$CurrentState)
    $script:samples++
    if ($script:mode -eq 'sampleFailure' -and $Watcher.Id -eq 101) {throw 'fixture observation failure'}
    if ($script:mode -eq 'slowSample') {Start-Sleep -Milliseconds 120}
    $mb=if ($script:mode -eq 'healthy' -and $script:clock.Elapsed.TotalSeconds -ge 102) {1000} else {6000}
    $pressure=40
    return @{privateMB=$mb;ageSec=600;windowPresent=$true;responding=(-not ($script:mode -eq 'unresponsive' -and $Watcher.Id -eq 101));systemCommitPercent=$pressure;eligible=$true;launchError=($script:mode -eq 'changedReason' -and $script:clock.Elapsed.TotalSeconds -ge 102)}
}
Initialize-Fixture
if ($Case -in @('ObservationInitialization','All')) {
    $initializers=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst]})
    Assert (@($initializers | Where-Object {$_.Extent.Text -match '^\$script:observationBusy\s*=\s*\$false$'}).Count -eq 1) 'Production explicitly initializes observationBusy=false'
    Assert (@($initializers | Where-Object {$_.Extent.Text -match '^\$script:observationCursor\s*=\s*0$'}).Count -eq 1) 'Production explicitly initializes observationCursor=0'
    Write-Output 'PASS: production observation state explicitly initialized'
    if ($Case -eq 'ObservationInitialization') {return}
}
if ($Case -in @('WaitBeforeObservation','All')) {
    # Keep the AST-loaded production wait; only observation/process IO is local.
    $observer=${function:Invoke-ArkuzoHealthObservation}
    try {
        $script:observations=0
        function Invoke-ArkuzoHealthObservation {
            $script:observations++;Start-Sleep -Milliseconds 150
        }
        $child=[pscustomobject]@{ExitChecks=0;MaxWait=0}
        $child|Add-Member ScriptMethod WaitForExit {
            param($ms) $this.ExitChecks++;$this.MaxWait=[math]::Max($this.MaxWait,$ms);return $true
        }
        $exited=Wait-ArkuzoObservedProcess $child 100
        Write-Output ("TRACE exit-before-observation: exited=$exited checks=$($child.ExitChecks) observations=$observations")
        Assert $exited 'Already-exited child must not be discarded when observation would exhaust the deadline'
        Assert ($observations -eq 0 -and $child.ExitChecks -eq 1 -and $child.MaxWait -eq 0) 'Already-exited child is checked without waiting or expensive observation'
        Write-Output 'PASS: exit before observation avoids false probe timeout'
    } finally { ${function:Invoke-ArkuzoHealthObservation}=$observer }
    if ($Case -eq 'WaitBeforeObservation') {return}
}
if ($Case -in @('WaitDuringObservation','All')) {
    $observer=${function:Invoke-ArkuzoHealthObservation}
    try {
        foreach($exitDuringObservation in @($true,$false)) {
            $script:observations=0
            $script:waitChild=[pscustomobject]@{HasExited=$false;ExitChecks=0;MaxWait=0}
            $waitChild|Add-Member ScriptMethod WaitForExit {
                param($ms) $this.ExitChecks++;$this.MaxWait=[math]::Max($this.MaxWait,$ms)
                Start-Sleep -Milliseconds $ms;return $this.HasExited
            }
            function Invoke-ArkuzoHealthObservation {
                $script:observations++
                # Exit occurs within the timeout; indivisible IO returns after it.
                $script:waitChild.HasExited=$exitDuringObservation
                Start-Sleep -Milliseconds 150
            }
            $timer=[Diagnostics.Stopwatch]::StartNew()
            $exited=Wait-ArkuzoObservedProcess $waitChild 100
            $timer.Stop()
            Write-Output ("TRACE final-observation: expected=$exitDuringObservation exited=$exited checks=$($waitChild.ExitChecks) observations=$observations elapsedMs=$($timer.Elapsed.TotalMilliseconds)")
            Assert ($exited -eq $exitDuringObservation) 'Final observation must retain an exited child but never accept a never-exiting child'
            Assert ($observations -eq 1 -and $waitChild.ExitChecks -eq 2 -and $waitChild.MaxWait -eq 0) 'Exhausted deadline is rechecked without additional observation or positive wait'
            Assert ($timer.Elapsed.TotalMilliseconds -lt 1500) 'Final observation must not restart the timeout deadline'
        }
        Write-Output 'PASS: exit during final observation is retained; never-exit still times out without extending deadline'
    } finally { ${function:Invoke-ArkuzoHealthObservation}=$observer }
    if ($Case -eq 'WaitDuringObservation') {return}
}
if ($Case -in @('Transient','All')) {
    $state.GameReady=$true
    $entry=New-ArkuzoPendingEntry 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' '123'
    $entry.replacementPid=101;$entry.replacementStartTicks=$state.StartTicks
    $entry.readySinceUtc='2026-10-08T00:00:00Z';$entry.lastObservedUtc=$entry.readySinceUtc
    $recoveryPending[$entry.accountId]=$entry
    $script:mode='unresponsive';$clock.Elapsed.TotalSeconds=101;Invoke-ArkuzoHealthObservation
    Assert ($null -eq $entry.readySinceUtc -and $state.HangSince -eq 101 -and $state.PrivateLimitSince -eq 0) 'Intermediate unhealthy observation invalidates outcome only, not hang/memory sustain'
    $script:mode='normal';$clock.Elapsed.TotalSeconds=102;Invoke-ArkuzoHealthObservation
    Assert ($null -eq $entry.readySinceUtc) 'Healthy sample before outcome evaluation cannot bridge the unhealthy observation'
    Write-Output 'PASS: transient unhealthy service observations latch outcome invalidation without resetting failure sustain'
    if ($Case -eq 'Transient') {return}
    Initialize-Fixture
}
if ($Case -in @('Snapshot','All')) {
    $state.LastSnapshot=@{pid=101;cpuPercent=7;residentMB=123;privateMB=6000;state='LEAK GUARD'}
    $state.HealthSnapshotUtc='2026-10-08T00:00:00Z'
    $clock.Elapsed.TotalSeconds=101
    Invoke-ArkuzoHealthObservation
    Assert ($state.LastSnapshot.pid -eq 101 -and $state.LastSnapshot.cpuPercent -eq 7 -and $state.LastSnapshot.residentMB -eq 123) 'Observation service must preserve diagnostic client identity/CPU/resident fields'
    Assert ($state.HealthSnapshotUtc -eq '2026-10-08T00:00:00Z') 'Window/memory service must not refresh game-readiness evidence without the main log observation'
    Write-Output 'PASS: observation keeps diagnostic identity/metadata and does not refresh stale game-readiness evidence'
    if ($Case -eq 'Snapshot') {return}
    Initialize-Fixture
}
if ($Case -in @('Reason','All')) {
    $script:mode='changedReason';$healthPolicy.startup_error_timeout_sec=0
    Invoke-ClientRecovery 101 $state
    Write-Output ("TRACE changed-reason: checks=$checks samples=$samples kills=$($watcher.Kills) decision=$($state.HealthDecision.Reason) events=$($events -join ',')")
    Assert ($watcher.Kills -eq 0) 'Serviced observations must not silently substitute a different recovery reason after audit'
    Write-Output 'PASS: original recovery reason stays bound through observation servicing'
    if ($Case -eq 'Reason') {return}
    Initialize-Fixture
}
if ($Case -in @('Hang','All')) {
    $s=@{};$sample=@{privateMB=6000;ageSec=600;windowPresent=$true;responding=$false;eligible=$true;systemCommitPercent=40}
    $healthPolicy.private_limit_sustain_sec=120
    foreach($n in 0..60) {$decision=Get-ArkuzoHealthDecision $s $sample $healthPolicy $n}
    Assert ($decision.Recycle -and $decision.Reason -eq 'SUSTAINED_HANG') 'Mature hang must not be masked by oversized memory grace'
    foreach($step in @(0.35,0.5,1.1,5.0,5.5)) {
        $s=@{}
        foreach($n in 0..([int][math]::Ceiling(60/$step))) {$decision=Get-ArkuzoHealthDecision $s $sample $healthPolicy ($n*$step)}
        if ($step -le 5) {Assert ($decision.Recycle -and $decision.Reason -eq 'SUSTAINED_HANG') ("Mature oversized hang at interval $step")}
        else {Assert (-not $decision.Recycle) '5.5-second hang samples never bridge missing observation'}
    }
    $critical=$sample.Clone();$critical.systemCommitPercent=95
    Assert ((Get-ArkuzoHealthDecision @{} $critical $healthPolicy 0).Reason -eq 'SYSTEM_COMMIT_PRESSURE') 'Critical pressure keeps priority over hang'
    Write-Output 'PASS: oversized memory grace does not starve sustained hang'
    if ($Case -eq 'Hang') {return}
    Initialize-Fixture
}
if ($Case -in @('Scheduling','All')) {
    foreach($name in @('Get-ArkuzoVoltRecoveryStatus','Invoke-ArkuzoVoltControl')) {
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
        $calls=@($fn.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-ArkuzoObservedProcess'},$true))
        Assert ($calls.Count -eq 1) ("Production $name must service observations during its existing timeout")
    }
    $loop=$ast.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'client'},$false)
    Assert ($loop.Extent.Text -match 'Invoke-ArkuzoHealthObservation') 'Production per-client loop must service other clients between serial log/name IO'
    Write-Output 'PASS: production waits and per-client loop wire observation scheduling'
    if ($Case -eq 'Scheduling') {return}
}
Invoke-ClientRecovery 101 $state
Write-Output ("TRACE delayed-probes: checks={0} samples={1} kills={2} events={3} attempts={4} pending={5}" -f $checks,$samples,$watcher.Kills,($events -join ','),$recoveryAttempts.Count,$recoveryPending.Count)
Assert ($watcher.Kills -eq 1) 'Two 3-second probes must preserve sustain through real intervening same-generation observations'
Assert ($events.Contains('RECOVERY_REQUESTED') -and $events.Contains('CLIENT_CLOSED_FOR_RECOVERY')) 'Request and verified closure are distinct events'
Assert ($recoveryAttempts.Count -eq 1 -and $recoveryPending.Count -eq 1) 'Verified closure retains budget and handoff'
foreach($m in @('healthy','generation','ownership','parent','sampleFailure','audit','journal','collateral','silentIO')) {
    Initialize-Fixture;$script:mode=$m
    Invoke-ClientRecovery 101 $state
    Assert ($watcher.Kills -eq 0 -and -not $events.Contains('CLIENT_CLOSED_FOR_RECOVERY')) ("Fail closed: $m")
    if ($m -eq 'silentIO') {Write-Output ("TRACE unobserved-6s: samples=$samples kills=$($watcher.Kills) attempts=$($recoveryAttempts.Count) pending=$($recoveryPending.Count)")}
    if ($m -notin @('generation','journal')) {Assert ($recoveryAttempts.Count -eq 0 -and $recoveryPending.Count -eq 0) ("Reservation rollback: $m")}
}
# Endpoint-only silence is never bridged, including fractional >5s and rollback.
foreach($gap in @(5.5,6.0,-1.0)) {
    Initialize-Fixture;$clock.Elapsed.TotalSeconds+= $gap
    $fresh=Get-ArkuzoRecoveryHealthSample $watcher '' $state
    $d=Get-ArkuzoHealthDecision $state $fresh $healthPolicy $clock.Elapsed.TotalSeconds
    Assert (-not $d.Recycle) ("Actual missing interval/rollback resets sustain: $gap")
}
Write-Output 'PASS: delayed production recovery, healthy rebound, generation/ownership/parent, failure/audit/journal/collateral, rollback, real gaps'
# Exercise the scheduling service itself with nine retained fixture generations:
# 9 serial 0.8s IO operations would otherwise starve a complete monitor pass.
Initialize-Fixture
foreach($id in 102..109) {
    $p=New-FakeProcess;$p.Id=$id
    $s=$state.Clone();$s.Watcher=$p;$s.LastSnapshot=@{pid=$id;privateMB=6000};$tracked[$id]=$s
}
foreach($n in 1..18) {
    $clock.Elapsed.TotalSeconds+=0.8
    Invoke-ArkuzoHealthObservation
    foreach($s in $tracked.Values) {
        Assert (($clock.Elapsed.TotalSeconds-$s.LastHealthSampleTime) -le 1.6) 'Nine clients retain actual timely samples through serial monitor work'
        Assert ($s.HealthDecision.Recycle) 'Intervening observation preserves existing mature memory sustain'
    }
}
$before=$samples;Invoke-ArkuzoHealthObservation
Assert ($samples -eq $before) 'Replayed timestamp does not collect or advance evidence'
# An observation failure is latched even when a later successful sample arrives
# before the slower outcome/recovery evaluator. Other generations are unaffected.
$entry=New-ArkuzoPendingEntry 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' '123'
$entry.replacementPid=101;$entry.replacementStartTicks=$state.StartTicks;$entry.readySinceUtc=[datetime]::UtcNow.ToString('o');$entry.lastObservedUtc=$entry.readySinceUtc
$recoveryPending[$entry.accountId]=$entry
$script:mode='sampleFailure';$clock.Elapsed.TotalSeconds+=1.1;Invoke-ArkuzoHealthObservation
Assert ($null -eq $entry.readySinceUtc -and $null -eq $state.LastHealthSampleTime) 'Failed sample invalidates matching pending readiness immediately'
$script:mode='normal';$clock.Elapsed.TotalSeconds+=1.1;Invoke-ArkuzoHealthObservation
Assert (-not $state.HealthDecision.Recycle -and $null -eq $entry.readySinceUtc) 'Later success cannot bridge the failed interval'
# Timeout stays a real elapsed deadline, not poll-count time or synthetic clock.
Initialize-Fixture
$never=[pscustomobject]@{Waits=0;MaxWait=0}
$never|Add-Member ScriptMethod WaitForExit {param($ms) $this.Waits++;$this.MaxWait=[math]::Max($this.MaxWait,$ms);Start-Sleep -Milliseconds $ms;return $false}
$timer=[Diagnostics.Stopwatch]::StartNew();$exited=Wait-ArkuzoObservedProcess $never 120;$timer.Stop()
Assert (-not $exited -and $timer.Elapsed.TotalMilliseconds -lt 1500 -and $never.MaxWait -le 100) 'Wait timeout bounded and split into at most 100ms slices'
# Slice budget includes observation work and rotates rather than restarting at
# the first process. A single indivisible native sample can overrun one slice.
Initialize-Fixture
foreach($id in 102..109) {$p=New-FakeProcess;$p.Id=$id;$s=$state.Clone();$s.Watcher=$p;$s.LastHealthSampleTime=$null;$tracked[$id]=$s}
$state.LastHealthSampleTime=$null;$script:mode='slowSample'
$timer=[Diagnostics.Stopwatch]::StartNew();Invoke-ArkuzoHealthObservation;$timer.Stop()
Assert ($samples -gt 0 -and $samples -lt 9 -and $timer.Elapsed.TotalMilliseconds -lt 1500) 'Observation work is sliced, not an unbounded all-client sweep'
$first=$samples;Invoke-ArkuzoHealthObservation
Assert ($samples -gt $first) 'Round-robin resumes work for other generations'
# Budget gates remain in the production recovery entry point.
foreach($b in @('cooldown','hourly')) {
    Initialize-Fixture
    if($b -eq 'cooldown') {$recoveryAttempts=@([datetime]::UtcNow)}
    else {$recoveryAttempts=@(1..20|ForEach-Object {[datetime]::UtcNow.AddMinutes(-2)})}
    Invoke-ClientRecovery 101 $state
    Assert ($watcher.Kills -eq 0 -and $checks -eq 0) ("Production budget remains fail closed: $b")
}
Write-Output 'PASS: nine-client serial IO, replay rejection, failure latching, bounded timeout/work slices, round-robin, cooldown/hourly gates'
