#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $a.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
# Ordinary successful observations carry their actual collection time.
$decisionBody=${function:Get-ArkuzoOutcomeDecision}
function Get-ArkuzoOutcomeDecision($Entry,$Account,[datetime]$NowUtc,$Policy) {
    if($null -ne $Account){$Account.sampleUtc=$NowUtc.ToString('o')}
    & $decisionBody $Entry $Account $NowUtc $Policy
}
$now=[datetime]::UtcNow
$entry=@{accountId='test';oldPid=71;oldStartTicks=100;oldTrackerId='111';createdUtc=$now.AddSeconds(-300).ToString('o');closedUtc=$now.AddSeconds(-300).ToString('o');retryCount=0;readySinceUtc=$null;lastObservedUtc=$null;replacementPid=0;replacementStartTicks=0;nextRetryUtc=$null}
$account=@{available=$true;accountId='test';controlReady=$true;autoRelaunch=$true;cookieAlive=$true;processId=$null;startTicks=0;trackerId='111';uiStatus='Idle';windowPresent=$false;responding=$false;launchError=$false;gameReady=$false}
$policy=@{restore_wait_sec=90;retry_base_sec=90;retry_max_sec=900;ready_stable_sec=30;retry_max_per_hour=6}
$decision='Wait'
if(Get-Command Get-ArkuzoOutcomeDecision -ErrorAction SilentlyContinue){$decision=Get-ArkuzoOutcomeDecision $entry $account $now $policy}
Assert ($decision -eq 'LaunchMissing') 'Persistent missing exact account must be retried through Volt after grace'
$entry.retryCount=2;$entry.nextRetryUtc=$now.AddSeconds(360).ToString('o')
Assert ((Get-ArkuzoOutcomeDecision $entry $account $now $policy) -eq 'Wait') 'Retry backoff must survive reloads and prevent tight retry loops'
$entry.nextRetryUtc=$null;$account.processId=72;$account.startTicks=200;$account.trackerId='222';$account.uiStatus='Connected';$account.windowPresent=$true;$account.responding=$true
Assert ((Get-ArkuzoOutcomeDecision $entry $account $now $policy) -eq 'Observing') 'A connected responsive process alone is not proven game readiness'
$account.gameReady=$true
Assert ((Get-ArkuzoOutcomeDecision $entry $account $now $policy) -eq 'Observing') 'New replacement must first satisfy a stable healthy confirmation interval'
foreach($s in 1..30){$d=Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds($s) $policy}
Assert ($d -eq 'Ready') 'Exact replacement with continuously confirmed game-ready evidence releases handoff'
$entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$account.launchError=$true
Assert ((Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds(40) $policy) -eq 'Observing') 'A Volt Notice replacement must never count as recovered'
$account.launchError=$false;$account.processId=71;$account.startTicks=100;$account.trackerId='111'
Assert ((Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds(41) $policy) -eq 'Blocked') 'Original process generation cannot be acknowledged as replacement'
# Every blocked observation must break the confirmation interval.
foreach($failure in @('controlReady','available','cookieAlive','autoRelaunch','wrongAccount','original','null')) {
    $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null
    $account.processId=72;$account.startTicks=200;$account.accountId='test'
    foreach($s in @(0,10)){Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds($s) $policy|Out-Null}
    $bad=$account.Clone()
    if($failure -eq 'wrongAccount'){$bad.accountId='other'}
    elseif($failure -eq 'original'){$bad.processId=71;$bad.startTicks=100}
    elseif($failure -eq 'null'){$bad=$null}
    else{$bad[$failure]=$false}
    Assert ((Get-ArkuzoOutcomeDecision $entry $bad $now.AddSeconds(20) $policy) -eq 'Blocked') "Blocked observation: $failure"
    Assert (-not $entry.readySinceUtc -and -not $entry.lastObservedUtc) "Blocked $failure must clear readiness and continuity"
    foreach($s in @(30,40,50)){Assert ((Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds($s) $policy) -eq 'Observing') "Recovery after $failure needs a fresh complete interval"}
    Assert ((Get-ArkuzoOutcomeDecision $entry $account $now.AddSeconds(60) $policy) -eq 'Ready') "Recovery after $failure needs 30 fresh contiguous seconds"
}
Write-Output 'PASS: missing retry, persistent backoff, exact-generation readiness, startup Notice, seven blocked continuity regressions'
