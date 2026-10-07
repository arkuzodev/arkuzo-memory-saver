#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach($file in @('src/saver/Arkuzo-Volt-Control.ps1','src/saver/Arkuzo-Memory-Saver.ps1','tests/saver/VoltControl.Tests.ps1')) {
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file),[ref]$t,[ref]$e)
 if($e.Count){throw 'Parse errors'}
 foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
}
$expectedPath='C:\Fixtures\Local\Volt\tauri-app.exe'
$script:restorePolicy=Get-ArkuzoRestorePolicy @{enabled=$true;restore_missing=$false}
$script:failures=@();$script:checks=0
function Check([bool]$ok,[string]$message){$script:checks++;if(-not $ok){$script:failures+=$message;Write-Output "FAIL: $message"}}
function Set-Status($context){$script:voltControlStatus=$context.Status;$script:voltControlCheckedUtc=[datetime]::UtcNow}
# Only external IO is replaced; actual production target authorization is exercised.
function Get-CimInstance { [pscustomobject]@{ProcessId=20;Name='RobloxPlayerBeta.exe';CommandLine='browsertrackerid:12345'} }
function Get-ArkuzoVoltRecoveryStatus { @{safeToRecycle=$true;targetReady=$true;matchedAccountCount=1} }
$watcher=[pscustomobject]@{Id=20;StartTime=[datetime]::new(200,[DateTimeKind]::Utc);HasExited=$false;ProcessName='RobloxPlayerBeta'}
$watcher | Add-Member ScriptMethod Refresh {}
foreach($case in @('Orphan','ForeignLoading','ConnectedMissing','SocketMismatch','IdleWithLive','DuplicateLive','ForeignUiRow')) {
 $f=Fixture;$f.Inventory.relaunchDelayMs=30000
 $f.Inventory.accounts[1].cookieStatus='dead';$f.Inventory.accounts[1].cookieAlive=$false
 switch($case){
 Orphan {$f.Processes += [pscustomobject]@{processId=99;startTicks=299;trackerId=$null;parentProcessId=999;parentStartTicks=1;identityStable=$true;ownerStable=$false}}
 ForeignLoading {$f.Nodes[9].name='Loading'}
 ConnectedMissing {$f.Processes=@()}
 SocketMismatch {$f.Nodes[3].name='Socket connected to Roblox process PID 99'}
 IdleWithLive {$f.Processes += [pscustomobject]@{processId=21;startTicks=201;trackerId='67890';parentProcessId=10;parentStartTicks=100;identityStable=$true;ownerStable=$true}}
 DuplicateLive {$f.Processes += $f.Processes[0]}
 ForeignUiRow {$f.Nodes += [pscustomobject]@{name='@foreign';kind='Text';processId=10};$f.Nodes += [pscustomobject]@{name='Loading';kind='Text';processId=10}}
 }
 $c=New-VoltControlContext @f;Set-Status $c;$script:recoveryPending=@{};$script:suspendedAccounts=@{}
 Check ($c.Status.globalMappingSafe -is [bool] -and -not $c.Status.globalMappingSafe) "$case explicit global unsafe"
 Check (@($c.Status.accounts|Where-Object controlReady).Count -eq 0) "$case no ready controls"
 Check (@($c.Status.accounts|Where-Object suspensionSafe).Count -eq 0) "$case no safe suspension"
 Check ($null -eq (Get-ArkuzoControlledAccount '12345' 20)) "$case exact healthy authorization denied"
 Check (-not (Test-ArkuzoTargetRecovery $watcher 20 200)) "$case production target closure denied"
 Check (-not (Test-ArkuzoRecoveryHandoff $f.Inventory.accounts[0].accountId)) "$case collateral handoff denied"
 Check (-not (Test-VoltMissingLaunch $c $f.Inventory.accounts[1].accountId '67890' 1000000)) "$case launch denied"
 # Otherwise healthy idle target must also be refused after a global change.
 $f.Inventory.accounts[1].cookieStatus='alive';$f.Inventory.accounts[1].cookieAlive=$true
 $script:unsafeContext=New-VoltControlContext @f
 $good=Fixture;$script:goodContext=New-VoltControlContext @good
 foreach($timing in @('Initial','Fresh')) {
  $script:reads=0;$script:writes=0;$script:timing=$timing
  $facade=@{Read={ $script:reads++;if($script:timing -eq 'Fresh' -and $script:reads -eq 1){$script:goodContext}else{$script:unsafeContext} };Verify={$true};Now={[double]1000000};Invoke={$script:writes++}}
  $result=Invoke-VoltControlAction -Action LaunchMissing -Facade $facade -AccountId $f.Inventory.accounts[1].accountId -ExpectedTrackerId '67890'
  Check (-not $result.requestAccepted -and $script:writes -eq 0) "$case $timing global gap never invokes healthy launcher"
 }
}
# A ledger entry is not perpetual safety evidence: reobserve using the real adapter.
foreach($case in @('Idle','Loading','Connected','UnknownCookie','Missing','Unavailable','GlobalMissing','GlobalString','Stale')) {
 $f=Fixture;$f.Inventory.relaunchDelayMs=30000;$id=$f.Inventory.accounts[1].accountId
 $f.Inventory.accounts[1].cookieStatus='dead';$f.Inventory.accounts[1].cookieAlive=$false
 if($case -eq 'Loading'){$f.Nodes[9].name='Loading'}
 if($case -eq 'Connected'){$f.Nodes[8].name='Socket connected to Roblox process PID 21';$f.Nodes[9].name='Connected';$f.Processes += [pscustomobject]@{processId=21;startTicks=201;trackerId='67890';parentProcessId=10;parentStartTicks=100;identityStable=$true;ownerStable=$true}}
 if($case -eq 'UnknownCookie'){$f.Inventory.accounts[1].cookieStatus='unknown'}
 $c=New-VoltControlContext @f;Set-Status $c
 if($case -eq 'Missing'){$script:voltControlStatus.accounts=@($c.Status.accounts[0])}
 if($case -eq 'Unavailable'){$script:voltControlStatus.available=$false}
 if($case -eq 'GlobalMissing'){$script:voltControlStatus.PSObject.Properties.Remove('globalMappingSafe')}
 if($case -eq 'GlobalString'){$script:voltControlStatus|Add-Member globalMappingSafe 'true' -Force}
 if($case -eq 'Stale'){$script:voltControlCheckedUtc=[datetime]::UtcNow.AddSeconds(-26)}
 $history=New-ArkuzoPendingEntry $id '67890';$history.retryCount=3
 $script:suspendedAccounts=@{};$script:suspendedAccounts[$id]=@{accountId=$id;reason='COOKIE_DEAD';pending=$history};$script:recoveryPending=@{}
 Check ((Test-ArkuzoRecoveryHandoff $f.Inventory.accounts[0].accountId) -eq ($case -eq 'Idle')) "$case suspended ledger freshly revalidated"
 Check ((Test-ArkuzoTargetRecovery $watcher 20 200) -eq ($case -eq 'Idle')) "$case exact production closure revalidates suspended ledger"
 Check ($script:suspendedAccounts.ContainsKey($id) -and $history.retryCount -eq 3 -and $script:recoveryPending.Count -eq 0) "$case ledger and history retained without dead retry"
}
$f=Fixture;$f.Inventory.relaunchDelayMs=30000;$c=New-VoltControlContext @f;Set-Status $c;$script:suspendedAccounts=@{};$script:recoveryPending=@{}
Check ($c.Status.globalMappingSafe -is [bool] -and $c.Status.globalMappingSafe -and $null -ne (Get-ArkuzoControlledAccount '12345' 20) -and (Test-ArkuzoTargetRecovery $watcher 20 200)) 'Globally healthy actual target authorized'
Write-Output "RESULT: $script:checks checks, $($script:failures.Count) failures"
if($script:failures.Count){throw 'Global mapping fail-closed regressions failed'}
