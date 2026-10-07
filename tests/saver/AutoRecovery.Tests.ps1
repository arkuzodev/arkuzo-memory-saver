#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $a.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
$found=Get-Command Get-ArkuzoRestorePolicy -ErrorAction SilentlyContinue
Assert ($null -ne $found) 'Automatic restore requires a validated independent policy, not a termination-budget increase'
$p=Get-ArkuzoRestorePolicy @{enabled=$true}
Assert ($p.restore_wait_sec -ge 90 -and $p.relaunch_delay_sec -ge 30 -and $p.ready_stable_sec -ge 30) 'Restore grace, relaunch delay and healthy confirmation must not be rapid-loop defaults'
Assert ((Get-ArkuzoRetryDelay 1 $p) -eq 90) 'First missing retry backoff'
Assert ((Get-ArkuzoRetryDelay 2 $p) -eq 180) 'Second retry doubles rather than repeating quickly'
Assert ((Get-ArkuzoRetryDelay 1000 $p) -eq 900) 'Exponential retry must cap before overflowing'
$blocked=$false;try{Get-ArkuzoRestorePolicy @{enabled='true'}|Out-Null}catch{$blocked=$true}
Assert $blocked 'Malformed boolean cannot enable recovery'
$h=Get-ArkuzoHealthPolicy @{enabled=$true}
Assert ($h.startup_error_timeout_sec -ge 40) 'Default startup Notice should get sustained grace before recycle'
$healthy=@{privateMB=6500;ageSec=600;responding=$true;windowPresent=$true;launchError=$false;systemCommitPercent=40;eligible=$true}
$s=@{}
Assert (-not (Get-ArkuzoHealthDecision $s $healthy $h 0).Recycle) 'Private-memory spike alone must not close a client'
foreach($n in 1..59){Assert (-not (Get-ArkuzoHealthDecision $s $healthy $h $n).Recycle) 'Private limit needs continuous confirmation'}
Assert ((Get-ArkuzoHealthDecision $s $healthy $h 60).Recycle) 'Confirmed growing private commit must remain actionable'
$pressure=$healthy.Clone();$pressure.privateMB=3000;$pressure.systemCommitPercent=95;$pressure.ageSec=20
Assert ((Get-ArkuzoHealthDecision @{} $pressure $h 0).Reason -eq 'SYSTEM_COMMIT_PRESSURE') 'Critical commit must not wait for loading grace or private-limit confirmation'
Write-Output 'PASS: conservative restore policy, bounded backoff, startup grace, sustained private memory, critical OS pressure'
