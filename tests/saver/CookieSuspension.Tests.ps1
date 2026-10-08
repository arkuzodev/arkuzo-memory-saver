#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
function Write-Diagnostic($kind,$data) { if($script:failAudit){$script:logFailed=$true} }
function Warn-Throttled($key,$message) {}
function Invoke-ArkuzoVoltControl { $script:launchCalls++;throw 'Unexpected launch' }
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('suspension-test-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($scratch)|Out-Null
try {
 $script:ownsControllerMutex=$true;$script:MonitorOnly=$false;$script:recoveryStatePath=Join-Path $scratch 'state.json'
 $script:restorePolicy=Get-ArkuzoRestorePolicy @{enabled=$true};$script:tracked=@{};$script:logFailed=$false;$script:failAudit=$false;$script:launchCalls=0
 $script:systemMemory=@{commitPercent=30};$script:healthPolicy=Get-ArkuzoHealthPolicy @{}
 Initialize-ArkuzoRecoveryJournal
 Assert ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.Count -eq 0) 'Legacy journal initializes empty suspension ledger'
 $id='11111111-1111-4111-8111-111111111111'
 $dead=[pscustomobject]@{accountId=$id;username='DeadUser';trackerId='111';cookieStatus='dead';cookieAlive=$false;suspensionSafe=$true;processId=$null;uiStatus='Idle';controlReady=$false;autoRelaunch=$true;lastLaunchAtMs=10}
 $script:voltControlStatus=[pscustomobject]@{available=$true;globalMappingSafe=$true;accounts=@($dead);relaunchDelayMs=30000};$script:voltControlCheckedUtc=[datetime]::UtcNow
 $entry=New-ArkuzoPendingEntry $id '111';$entry.retryCount=3;$entry.nextRetryUtc=[datetime]::UtcNow.AddMinutes(8).ToString('o');$entry.readySinceUtc=[datetime]::UtcNow.ToString('o');$script:recoveryPending[$id]=$entry
 Update-ArkuzoRecoveryOutcomes
 Assert ($recoveryPending.Count -eq 0 -and $suspendedAccounts.Count -eq 1) 'Confirmed dead idle pending moves into separate ledger'
 Assert ($suspendedAccounts[$id].reason -eq 'COOKIE_DEAD' -and $suspendedAccounts[$id].pending.retryCount -eq 3) 'Suspension retains identity and retry history'
 Assert ($launchCalls -eq 0 -and (Test-ArkuzoRecoveryHandoff 'other')) 'Suspension alone does not block healthy accounts or launch dead account'
 $script:DataDirectory=$scratch
 $dead.controlReady=$true;$dead.processId=42
 Assert ($null -eq (Get-ArkuzoControlledAccount '111' 42)) 'Suspended identity cannot be recovered even when adapter claims control ready'
 $dead.controlReady=$false;$dead.processId=$null
 $healthy=[pscustomobject]@{accountId='22222222-2222-4222-8222-222222222222';username='HealthyUser';trackerId='222';cookieStatus='alive';cookieAlive=$true;processId=77;uiStatus='Connected';controlReady=$true;autoRelaunch=$true;lastLaunchAtMs=10}
 $script:voltControlStatus.accounts=@($dead,$healthy)
 Assert ($null -ne (Get-ArkuzoControlledAccount '222' 77) -and (Test-ArkuzoRecoveryHandoff $healthy.accountId)) 'Mixed healthy account remains independently recovery ready after dead idle suspension'
 Write-ArkuzoRuntimeStatus
 $runtime=[IO.File]::ReadAllText((Join-Path $scratch 'runtime-status.json'))|ConvertFrom-Json
 Assert ($runtime.suspendedAccountCount -eq 1 -and @($runtime.suspendedAccounts).Count -eq 1 -and $runtime.missingAccounts -eq 0 -and -not $runtime.missingRecoveryBlocked) 'Heartbeat separates suspension count from missing and active pending gates'
 $dead.cookieStatus='alive';$dead.cookieAlive=$true;$dead.controlReady=$true
 Update-ArkuzoRecoveryOutcomes
 Assert ($suspendedAccounts.Count -eq 0 -and $recoveryPending[$id].retryCount -eq 3 -and $null -eq $recoveryPending[$id].readySinceUtc) 'Precise alive reintegration retains backoff and resets complete game confirmation'
 # Suspended accounts disappear on restart and are not saved practically
 $dead.cookieStatus='dead';$dead.cookieAlive=$false;$dead.controlReady=$false
 Update-ArkuzoRecoveryOutcomes
 Assert ($suspendedAccounts.Count -eq 1) 'Suspended in session memory'
 Save-ArkuzoRecoveryJournal
 Initialize-ArkuzoRecoveryJournal
 Assert ($recoveryJournalHealthy -and $suspendedAccounts.Count -eq 0) 'Suspended accounts disappear on restart and are not saved practically'
 foreach($case in @('live','unknown','malformed','audit','save')) {
  $script:recoveryJournalHealthy=$true;$script:logFailed=$false;$script:failAudit=$false;$script:suspendedAccounts=@{};$script:recoveryPending=@{};$script:recoveryPending[$id]=New-ArkuzoPendingEntry $id '111'
  $dead.cookieStatus='dead';$dead.cookieAlive=$false;$dead.controlReady=$false;$dead.suspensionSafe=$true;$dead.processId=$null;$dead.accountId=$id;$dead.autoRelaunch=$true
  $script:recoveryStatePath=Join-Path $scratch 'state.json'
  if($case -eq 'live'){$dead.processId=42;$dead.suspensionSafe=$false}
  if($case -eq 'unknown'){$dead.cookieStatus='unknown';$dead.autoRelaunch=$false}
  if($case -eq 'malformed'){$dead.accountId='bad-id'}
  if($case -eq 'audit'){$script:failAudit=$true}
  if($case -eq 'save'){$script:recoveryStatePath=Join-Path $scratch 'absent/state.json'}
  $script:voltControlCheckedUtc=[datetime]::UtcNow
  Update-ArkuzoRecoveryOutcomes
  Assert ($recoveryPending.ContainsKey($id) -and $suspendedAccounts.Count -eq 0) "$case cannot release pending account"
  if($case -in @('audit','save')){Assert (-not $recoveryJournalHealthy) "$case blocks destructive recovery"}
 }
 $script:recoveryStatePath=Join-Path $scratch 'state.json';$script:recoveryJournalHealthy=$true;$script:logFailed=$false;$script:failAudit=$false;$script:recoveryPending=@{};$script:suspendedAccounts=@{}
 $dead.accountId=$id;$dead.cookieStatus='dead';$dead.cookieAlive=$false;$dead.suspensionSafe=$true;$dead.controlReady=$false;$dead.processId=$null;$dead.lastLaunchAtMs=$null
 $script:voltControlCheckedUtc=[datetime]::UtcNow
 Update-ArkuzoRecoveryOutcomes
 Assert ($suspendedAccounts.Count -eq 1 -and $null -eq $suspendedAccounts[$id].pending -and $launchCalls -eq 0) 'Dead never-launched account is suspended without inventing launch history'
 $script:voltControlStatus.accounts=@()
 Update-ArkuzoRecoveryOutcomes
 Assert ($suspendedAccounts.ContainsKey($id)) 'Disappeared suspended identity is retained, never guessed'
 $script:voltControlStatus.accounts=@($dead);$dead.cookieStatus='alive';$dead.cookieAlive=$true;$dead.controlReady=$true
 $script:voltControlCheckedUtc=[datetime]::UtcNow.AddMinutes(-1)
 Update-ArkuzoRecoveryOutcomes
 Assert ($suspendedAccounts.ContainsKey($id)) 'Stale alive cannot resume suspension'
 $script:voltControlCheckedUtc=[datetime]::UtcNow
 Update-ArkuzoRecoveryOutcomes
 Assert ($suspendedAccounts.Count -eq 0 -and $recoveryPending.Count -eq 0 -and $launchCalls -eq 0) 'Fresh alive import never becomes an automatic launch without prior history'
 Write-Output 'PASS: cookie suspension ledger, restart, reintegration, budgets, live/unknown/identity/audit/save fail-closed, unlaunched and disappeared identity safety'
} finally {[IO.Directory]::Delete($scratch,$true)}
