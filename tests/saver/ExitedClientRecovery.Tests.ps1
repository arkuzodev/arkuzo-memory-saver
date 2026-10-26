#requires -Version 5.1
# A server kick disconnects the whole farm at once. Recovery is serialized, so most
# kicked clients close themselves before their turn; their accounts must still be
# relaunched through Volt, even with restore_missing off (26 Oct: 6 of 7 stayed down).
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
function Write-Diagnostic($kind,$data) { [void]$script:events.Add(@{kind=$kind;data=$data}) }
function Warn-Throttled($key,$message) {}
function Invoke-ArkuzoVoltControl($Action,$AccountId,$TrackerId) { [void]$script:launches.Add($AccountId); return @{requestAccepted=$true} }
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('exited-recovery-test-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($scratch)|Out-Null

function New-Farm {
  $script:events=New-Object Collections.ArrayList;$script:launches=New-Object Collections.ArrayList
  $script:ownsControllerMutex=$true;$script:MonitorOnly=$false;$script:recoveryStatePath=Join-Path $scratch 'state.json'
  if(Test-Path $script:recoveryStatePath){Remove-Item $script:recoveryStatePath}
  $script:restorePolicy=Get-ArkuzoRestorePolicy @{enabled=$true;restore_missing=$false}
  $script:healthPolicy=Get-ArkuzoHealthPolicy @{};$script:systemMemory=@{commitPercent=30}
  $script:logFailed=$false;$script:tracked=@{};$script:sessionObservedAccounts=@{};$script:saverSessionStartEpochMs=$null
  Initialize-ArkuzoRecoveryJournal
  $script:accounts=@(); $script:states=@()
  for($i=1;$i -le 7;$i++){
    $id=('{0}{0}{0}{0}{0}{0}{0}{0}-{0}{0}{0}{0}-4{0}{0}{0}-8{0}{0}{0}-{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}' -f $i)
    $script:accounts+=[pscustomobject]@{accountId=$id;username="Farm$i";trackerId="10$i";cookieStatus='alive';cookieAlive=$true;suspensionSafe=$false;processId=(5000+$i);uiStatus='Connected';controlReady=$true;autoRelaunch=$true;lastLaunchAtMs=1}
    $script:states+=@{StartTicks=[long](900+$i);TrackerId="10$i";isDisconnected=$false;DisconnectReason=$null;RecoveryRequested=$false;HealthDecision=$null;Watcher=$null;LastSnapshot=$null;BoundAccountId=$null;BoundTrackerId=$null}
  }
  $script:voltControlStatus=[pscustomobject]@{available=$true;globalMappingSafe=$true;accounts=$script:accounts;relaunchDelayMs=30000};$script:voltControlCheckedUtc=[datetime]::UtcNow
  # The main loop binds each client to its exact Volt account while it is alive.
  for($i=0;$i -lt 7;$i++){ $b=Get-ArkuzoControlledAccount $states[$i].TrackerId (5001+$i); $states[$i].BoundAccountId=[string]$b.accountId; $states[$i].BoundTrackerId=[string]$b.trackerId }
}
function Kick-All { foreach($s in $states){ $s.isDisconnected=$true; $s.DisconnectReason='Kicked: Lost connection to the game server, please reconnect'; $s.HealthDecision=@{Recycle=$true;Reason='IN_GAME_DISCONNECT'} } }
function Exit-Client([int]$i) { $accounts[$i].processId=$null; $accounts[$i].uiStatus='Idle'; Record-ClientExit (5001+$i) $states[$i] 'HasExited reported' }
function Queued { ,@($events | Where-Object { $_.kind -eq 'EXITED_CLIENT_RECOVERY_QUEUED' }) }

try {
  New-Farm
  Assert (@($states | Where-Object { $_.BoundAccountId }).Count -eq 7) 'every client is bound to its exact account'
  Kick-All
  $states[0].RecoveryRequested=$true   # The saver closed this one itself; its own handoff covers it.
  for($i=0;$i -lt 7;$i++){ Exit-Client $i }
  Assert ((Queued).Count -eq 6) 'the six clients that closed themselves are queued; the recovered one is not doubled'
  Assert ($recoveryPending.Count -eq 6 -and -not $recoveryPending.ContainsKey($accounts[0].accountId)) 'six pending handoffs'
  $e1=$recoveryPending[$accounts[1].accountId]
  Assert ($e1.oldPid -eq 5002 -and $e1.oldStartTicks -eq 902 -and $e1.oldTrackerId -eq '102' -and $e1.closedUtc) 'entry keeps the exact old generation and exit time'
  Initialize-ArkuzoRecoveryJournal
  Assert ($recoveryPending.Count -eq 6) 'the queue survives a saver restart'

  # Volt's own relaunch gets restore_wait_sec first; afterwards one bounded launch per pass.
  $script:voltControlCheckedUtc=[datetime]::UtcNow
  Update-ArkuzoRecoveryOutcomes
  Assert ($launches.Count -eq 0) 'no launch before restore_wait_sec, even with restore_missing off'
  foreach($k in @($recoveryPending.Keys)){ $recoveryPending[$k].closedUtc=[datetime]::UtcNow.AddSeconds(-120).ToString('o') }
  for($pass=0;$pass -lt 8;$pass++){
    $script:voltControlCheckedUtc=[datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    $script:launchAttempts=@()   # The launch backoff between passes elapsed.
  }
  Assert ($launches.Count -eq 6 -and @($launches | Select-Object -Unique).Count -eq 6) 'each kicked account gets exactly one Volt launch request'
  Assert ($launches -notcontains $accounts[0].accountId) 'the account recovered by the saver is not launched twice'

  # Exits that are not disconnects or pending recoveries stay ordinary exits.
  New-Farm
  Exit-Client 1
  Assert ((Queued).Count -eq 0 -and $recoveryPending.Count -eq 0) 'a healthy client closed normally is not relaunched'
  # A queued recovery (cooldown) that exits on its own is queued even without a log disconnect.
  New-Farm
  $states[2].HealthDecision=@{Recycle=$true;Reason='SUSTAINED_HANG'}
  Exit-Client 2
  Assert ((Queued).Count -eq 1 -and (Queued)[0].data.reason -eq 'SUSTAINED_HANG') 'a client waiting for its recovery turn is queued when it exits'

  # Safety: excluded, suspended, quarantined, unbound, monitor-only and unhealthy journal never queue.
  foreach($case in @('excluded','suspended','quarantined','unbound','monitor','journal','already')) {
    New-Farm; Kick-All
    $key=$accounts[3].accountId
    switch($case){
      'excluded'    { $restorePolicy.excluded_account_ids=@($key) }
      'suspended'   { $script:suspendedAccounts[$key]=@{accountId=$key} }
      'quarantined' { $script:quarantinedAccounts[$key]=@{accountId=$key;untilUtc=[datetime]::UtcNow.AddHours(1).ToString('o')} }
      'unbound'     { $states[3].BoundAccountId=$null }
      'monitor'     { $script:MonitorOnly=$true }
      'journal'     { $script:recoveryJournalHealthy=$false }
      'already'     { $script:recoveryPending[$key]=New-ArkuzoPendingEntry $key '104' 1 1 }
    }
    $before=$recoveryPending.Count
    Exit-Client 3
    Assert ((Queued).Count -eq 0 -and $recoveryPending.Count -eq $before) "$case account is never queued"
  }
  # A failed journal write rolls back and blocks destructive recovery.
  New-Farm; Kick-All
  $script:recoveryStatePath=Join-Path $scratch 'absent/state.json'
  Exit-Client 4
  Assert ($recoveryPending.Count -eq 0 -and -not $recoveryJournalHealthy) 'journal failure rolls back the entry and blocks recovery'
  Write-Host 'PASS: kicked clients that close themselves are queued for one bounded Volt relaunch each; safety gates hold'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
