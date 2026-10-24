#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Controller parse failure'}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
function Write-Diagnostic($kind,$data) { $script:events+=@(@{kind=$kind;data=$data}) }
function Warn-Throttled($key,$message) { $script:warned[$key]=$message }
function Invoke-ArkuzoVoltControl { $script:launchCalls++; throw 'Unexpected launch' }
$script:events=@();$script:warned=@{};$script:launchCalls=0

# Memory priority mapping follows MEMORY_PRIORITY_* and rejects unknown names.
Assert ((ConvertTo-ArkuzoMemoryPriorityValue 'VeryLow') -eq 1 -and (ConvertTo-ArkuzoMemoryPriorityValue 'Low') -eq 2 -and (ConvertTo-ArkuzoMemoryPriorityValue 'Normal') -eq 5) 'Memory priority values'
$threw=$false;try{ConvertTo-ArkuzoMemoryPriorityValue 'Lowest'|Out-Null}catch{$threw=$true}
Assert $threw 'Unknown memory priority must be rejected'
foreach($preset in (Get-ArkuzoPresets).Values){ ConvertTo-ArkuzoMemoryPriorityValue $preset.memory_priority | Out-Null; Assert ($preset.adaptive_trim -is [bool]) 'Every preset declares adaptive trimming' }
Write-Output 'PASS: memory priority mapping and preset coverage'

# Adaptive trimming shortens only under physical-RAM scarcity, never below 15s.
$plan=Get-ArkuzoTrimPlan $null 16384 60 $true 20
Assert ($plan.IntervalSec -eq 60 -and -not $plan.Pressure) 'Missing telemetry keeps the configured interval'
$plan=Get-ArkuzoTrimPlan @{availablePhysicalMB=8192} 16384 60 $true 20
Assert ($plan.IntervalSec -eq 60 -and -not $plan.Pressure -and $plan.AvailablePercent -eq 50) 'Ample RAM keeps the configured interval'
$plan=Get-ArkuzoTrimPlan @{availablePhysicalMB=1638} 16384 60 $true 20
Assert ($plan.IntervalSec -eq 20 -and $plan.Pressure) 'Scarce RAM shortens the interval to a third'
Assert ((Get-ArkuzoTrimPlan @{availablePhysicalMB=100} 16384 30 $true 20).IntervalSec -eq 15) 'Pressure interval floor is 15s'
Assert ((Get-ArkuzoTrimPlan @{availablePhysicalMB=100} 16384 10 $true 20).IntervalSec -eq 10) 'A configured interval below the floor is never lengthened'
Assert (-not (Get-ArkuzoTrimPlan @{availablePhysicalMB=100} 16384 60 $false 20).Pressure) 'Adaptive trimming can be disabled'
Assert ((Get-ArkuzoTrimPlan @{availablePhysicalMB=100} 0 60 $true 20).IntervalSec -eq 60) 'Unknown physical RAM keeps the configured interval'
Write-Output 'PASS: adaptive trim plan'

# Abandoning stuck recoveries.
$policy=Get-ArkuzoRestorePolicy @{enabled=$true}
Assert ($policy.abandon_after_retries -eq 8 -and $policy.abandon_after_sec -eq 5400 -and $policy.quarantine_sec -eq 1800) 'Abandon defaults'
$threw=$false;try{Get-ArkuzoRestorePolicy @{enabled=$true;abandon_after_sec=60}|Out-Null}catch{$threw=$true}
Assert $threw 'Abandon age below the floor is rejected'
$now=[datetime]::UtcNow
Assert ($null -eq (Test-ArkuzoPendingAbandon @{retryCount=2;createdUtc=$now.AddMinutes(-5).ToString('o')} $now $policy)) 'Fresh recovery keeps waiting'
Assert ((Test-ArkuzoPendingAbandon @{retryCount=8;createdUtc=$now.ToString('o')} $now $policy) -eq 'RETRY_LIMIT') 'Retry limit abandons'
Assert ((Test-ArkuzoPendingAbandon @{retryCount=0;createdUtc=$now.AddHours(-2).ToString('o')} $now $policy) -eq 'AGE_LIMIT') 'Age limit abandons'
Assert ($null -eq (Test-ArkuzoPendingAbandon @{retryCount=0;createdUtc='not a date'} $now $policy)) 'Unparseable timestamps never abandon by age'
Assert ($null -eq (Test-ArkuzoPendingAbandon @{retryCount=40;createdUtc=$now.AddDays(-2).ToString('o')} $now @{enabled=$true})) 'A policy without abandon limits never abandons'
Write-Output 'PASS: pending abandon policy'

# Live resource settings validation.
$current=@{MaxRamMB=600;TrimEverySec=60;CoresPerInstance=2;Priority='BelowNormal';EnableTrimming=$true;MemoryPriority='Low';AdaptiveTrim=$true;PressureTrimAvailablePercent=20;Minimize=$false}
$next=Get-ArkuzoLiveResourceSettings ([pscustomobject]@{target_ram_mb=450;trim_every_sec=30;memory_priority='VeryLow';adaptive_trim=$false;priority='Idle'}) $current
Assert ($next.MaxRamMB -eq 450 -and $next.TrimEverySec -eq 30 -and $next.MemoryPriority -eq 'VeryLow' -and -not $next.AdaptiveTrim -and $next.Priority -eq 'Idle' -and $next.CoresPerInstance -eq 2) 'Valid settings apply and unspecified keys are retained'
Assert ($current.MaxRamMB -eq 600) 'Validation never mutates the current values'
foreach($bad in @(@{target_ram_mb='600'},@{target_ram_mb=50},@{trim_every_sec=1.5},@{trim_enabled='true'},@{priority='High'},@{memory_priority='Turbo'},@{cores_per_instance=0})) {
    $threw=$false;try{Get-ArkuzoLiveResourceSettings ([pscustomobject]$bad) $current|Out-Null}catch{$threw=$true}
    Assert $threw ('Invalid live setting rejected: '+(($bad.Keys)-join ','))
}
Write-Output 'PASS: live resource settings validation'

$scratch=Join-Path ([IO.Path]::GetTempPath()) ('autopilot-test-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($scratch)|Out-Null
try {
    # Live apply respects CLI-bound parameters and makes clients reapply now.
    $script:MaxRamMB=600;$script:TrimEverySec=60;$script:CoresPerInstance=2;$script:Priority='BelowNormal';$script:EnableTrimming=$true
    $script:MemoryPriority='Low';$script:AdaptiveTrim=$true;$script:PressureTrimAvailablePercent=20;$script:Minimize=$false;$script:Mode='agressive'
    $script:cliBoundParameters=@('CoresPerInstance');$script:tracked=@{7=@{LastConfig=5.0}}
    Update-ArkuzoLiveSettings ([pscustomobject]@{selected_preset='extreme';settings=[pscustomobject]@{target_ram_mb=450;cores_per_instance=1;memory_priority='VeryLow'}})
    Assert ($script:MaxRamMB -eq 450 -and $script:maxBytes -eq 450MB -and $script:MemoryPriority -eq 'VeryLow' -and $script:Mode -eq 'extreme') 'Live settings apply'
    Assert ($script:CoresPerInstance -eq 2) 'CLI-bound parameters are never overridden by config'
    Assert ($script:tracked[7].LastConfig -lt 0) 'Changed settings are reapplied on the next pass'
    Assert (@($script:events|Where-Object kind -eq 'SETTINGS_APPLIED_LIVE').Count -eq 1) 'Live apply is audited'
    Update-ArkuzoLiveSettings ([pscustomobject]@{settings=[pscustomobject]@{target_ram_mb='bad'}})
    Assert ($script:MaxRamMB -eq 450 -and $script:warned.ContainsKey('settings-reload')) 'Invalid reload keeps the last applied values and warns'
    Write-Output 'PASS: live settings apply, CLI precedence, invalid reload retention'

    # A stuck pending recovery is quarantined, releasing the shared gate.
    $script:ownsControllerMutex=$true;$script:MonitorOnly=$false;$script:recoveryStatePath=Join-Path $scratch 'state.json';$script:DataDirectory=$scratch
    $script:restorePolicy=Get-ArkuzoRestorePolicy @{enabled=$true};$script:tracked=@{};$script:logFailed=$false
    $script:systemMemory=@{commitPercent=30};$script:healthPolicy=Get-ArkuzoHealthPolicy @{}
    Initialize-ArkuzoRecoveryJournal
    $stuck='33333333-3333-4333-8333-333333333333';$other='44444444-4444-4444-8444-444444444444'
    $acct=[pscustomobject]@{accountId=$stuck;username='StuckUser';trackerId='333';cookieStatus='alive';cookieAlive=$true;suspensionSafe=$false;processId=$null;uiStatus='Idle';controlReady=$true;autoRelaunch=$true;lastLaunchAtMs=10}
    $healthy=[pscustomobject]@{accountId=$other;username='HealthyUser';trackerId='444';cookieStatus='alive';cookieAlive=$true;processId=88;uiStatus='Connected';controlReady=$true;autoRelaunch=$true;lastLaunchAtMs=10}
    $script:voltControlStatus=[pscustomobject]@{available=$true;globalMappingSafe=$true;accounts=@($acct,$healthy);relaunchDelayMs=30000};$script:voltControlCheckedUtc=[datetime]::UtcNow
    $entry=New-ArkuzoPendingEntry $stuck '333' 4242 12345;$entry.retryCount=33;$entry.nextRetryUtc=[datetime]::UtcNow.AddMinutes(10).ToString('o');$script:recoveryPending[$stuck]=$entry
    Assert (-not (Test-ArkuzoRecoveryHandoff $other)) 'Precondition: the stuck entry blocks collateral recovery'
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.Count -eq 0 -and $script:quarantinedAccounts.ContainsKey($stuck)) 'Stuck recovery is released and quarantined'
    Assert ($script:quarantinedAccounts[$stuck].reason -eq 'RETRY_LIMIT' -and $script:quarantinedAccounts[$stuck].retryCount -eq 33) 'Quarantine keeps reason and retry history'
    Assert (Test-ArkuzoRecoveryHandoff $other) 'Releasing the stuck entry reopens recovery for other accounts'
    Assert (Test-ArkuzoAccountQuarantined $stuck ([datetime]::UtcNow)) 'Account is quarantined now'
    Assert ($launchCalls -eq 0) 'Quarantine never launches the account'
    Assert (@($script:events|Where-Object kind -eq 'RECOVERY_QUARANTINED').Count -eq 1) 'Quarantine is audited'
    $script:restorePolicy.restore_missing=$true
    Update-ArkuzoRecoveryOutcomes
    Assert (-not $script:recoveryPending.ContainsKey($stuck)) 'A quarantined idle account is not re-queued as missing'
    $saved=[IO.File]::ReadAllText($script:recoveryStatePath)|ConvertFrom-Json
    Assert (@($saved.quarantined).Count -eq 1 -and $saved.quarantined[0].accountId -eq $stuck) 'Quarantine is persisted in the journal'
    Initialize-ArkuzoRecoveryJournal
    Assert ($script:recoveryJournalHealthy -and $script:quarantinedAccounts.ContainsKey($stuck)) 'Quarantine survives a saver restart'
    $script:quarantinedAccounts[$stuck].untilUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o')
    Assert (-not (Test-ArkuzoAccountQuarantined $stuck ([datetime]::UtcNow)) -and -not $script:quarantinedAccounts.ContainsKey($stuck)) 'Expired quarantine resumes normal recovery'
    Write-Output 'PASS: stuck recovery quarantine releases the gate, persists, and expires'

    # Heartbeat carries what the Control Center needs, with minimal state.
    $script:dashboardIssues=@{ 'volt-delay'=@{Message='Volt relaunch delay could not be verified.';Time=1.0} }
    $script:clock=[Diagnostics.Stopwatch]::StartNew();$script:trimCount=3;$script:lastTotals=@{detected=1;managed=1;residentMB=500;privateMB=900;cpuPercent=2}
    $script:trimPlan=Get-ArkuzoTrimPlan @{availablePhysicalMB=1000} 16384 60 $true 20;$script:totalPhysicalMB=16384
    $script:quarantinedAccounts[$stuck]=@{accountId=$stuck;reason='RETRY_LIMIT';untilUtc=[datetime]::UtcNow.AddMinutes(5).ToString('o')}
    Write-ArkuzoRuntimeStatus
    $hb=[IO.File]::ReadAllText((Join-Path $scratch 'runtime-status.json'))|ConvertFrom-Json
    Assert ($hb.settings.targetMB -eq 450 -and $hb.settings.effectiveTrimSec -eq 20 -and $hb.settings.trimPressure -and $hb.settings.memoryPriority -eq 'VeryLow') 'Heartbeat publishes effective settings'
    Assert ($hb.trims -eq 3 -and $hb.totals.residentMB -eq 500 -and $hb.totalPhysicalMB -eq 16384) 'Heartbeat publishes totals'
    Assert (@($hb.alerts).Count -eq 1 -and $hb.alerts[0].message -match 'Volt' -and @($hb.quarantined).Count -eq 1) 'Heartbeat publishes alerts and quarantine'
    $script:quarantinedAccounts[$stuck].untilUtc=[datetime]::UtcNow.AddSeconds(-5).ToString('o')
    Write-ArkuzoRuntimeStatus
    $hb=[IO.File]::ReadAllText((Join-Path $scratch 'runtime-status.json'))|ConvertFrom-Json
    Assert (@($hb.quarantined).Count -eq 0 -and -not $script:quarantinedAccounts.ContainsKey($stuck)) 'Expired quarantine is dropped from the heartbeat'
    Write-Output 'PASS: heartbeat publishes settings, totals, alerts and quarantine'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }

# Stall watchdog: compiled from the production source, observed on its own timer thread.
$watchdogType=$ast.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' -and $n.Extent.Text -match 'LoopWatchdogV1'},$true)
Assert ($null -ne $watchdogType) 'Watchdog type definition exists'
. ([scriptblock]::Create($watchdogType.Extent.Text))
$stallFile=Join-Path ([IO.Path]::GetTempPath()) ('stall-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    [Arkuzo.LoopWatchdogV1]::Start($stallFile, 1)
    [Arkuzo.LoopWatchdogV1]::Mark('client 42: first contact')
    Start-Sleep -Milliseconds 6500  # The timer checks every 5 seconds.
    Assert (Test-Path -LiteralPath $stallFile) 'A blocked phase is written while the main thread is busy'
    $stall=[IO.File]::ReadAllText($stallFile)|ConvertFrom-Json
    Assert ($stall.phase -eq 'client 42: first contact' -and $stall.stalledSec -ge 1 -and $stall.pid -eq $PID) 'Stall file names the phase, duration and process'
    Assert ($null -eq [Arkuzo.LoopWatchdogV1]::TakeRecovered()) 'No recovery is reported while still stalled'
    [Arkuzo.LoopWatchdogV1]::Mark('idle')
    $recovered=[Arkuzo.LoopWatchdogV1]::TakeRecovered()
    Assert ($recovered -like 'client 42: first contact|*') 'The ended stall is reported once with its phase'
    Assert ($null -eq [Arkuzo.LoopWatchdogV1]::TakeRecovered()) 'A recovered stall is reported only once'
} finally { Remove-Item -LiteralPath $stallFile -Force -ErrorAction SilentlyContinue }
Write-Output 'PASS: stall watchdog reports blocked phase from its own thread, then recovery once'

# Production wiring.
$text=$ast.Extent.Text
Assert (([regex]::Matches($text,'Get-CimInstance Win32_Process[^\r\n]*')|Where-Object { $_.Value -notmatch '-OperationTimeoutSec' }).Count -eq 0) 'Every Win32_Process query is time-bounded'
Assert ($text -match "LoopWatchdogV1\]::Start\(\(Join-Path \`$DataDirectory 'saver-stall\.json'\), 60\)" -and ([regex]::Matches($text,'LoopWatchdogV1\]::Mark\(')).Count -ge 12) 'Watchdog is armed and the loop marks its phases'
Assert ($text -match "'MemoryPriority'\s*\{\s*#\s*Only change what can be restored" -and $text -match 'SetMemoryPriority\(\$Client\.Handle, \[uint32\]\$State\.MemoryPriority\)') 'Memory priority is applied and restored'
Assert ($text -match '\$trimPlan = Get-ArkuzoTrimPlan' -and $text -match '-ge \$trimPlan\.IntervalSec') 'Trim loop uses the adaptive plan'
Assert ($text -match 'Update-ArkuzoLiveSettings \$pendingLiveSettings') 'Main loop applies live settings'
Assert ($text -match 'trim-now\.signal') 'Trim-now signal is wired'
Write-Output 'PASS: production wiring'
