#requires -Version 5.1
param([string]$ScriptPath=(Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'))
$ErrorActionPreference='Stop'
$t=$null;$e=$null
$a=[Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$t,[ref]$e)
if($e.Count){throw 'Controller parse failure'}
foreach($f in $a.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
if(-not (Get-Command Get-ArkuzoTrimCountdown -ErrorAction SilentlyContinue)){throw 'FAIL: Warmup-aware trim countdown is missing'}
function AssertEqual($actual,$expected){if($actual -cne $expected){throw "FAIL: expected '$expected', got '$actual'"}}
AssertEqual (Get-ArkuzoTrimCountdown 0 300 45 100 0 $true $false) 'WARMUP 300s'
Write-Output 'PASS: per-client startup grace is visible'
AssertEqual (Get-ArkuzoTrimCountdown 299.1 300 45 100 0 $true $false) 'WARMUP 1s'
AssertEqual (Get-ArkuzoTrimCountdown 300 300 45 100 0 $true $false) '0s'
AssertEqual (Get-ArkuzoTrimCountdown 301 300 45 100 100 $true $false) '45s'
AssertEqual (Get-ArkuzoTrimCountdown 350 300 45 120.2 100 $true $false) '25s'
AssertEqual (Get-ArkuzoTrimCountdown 0 300 45 100 0 $false $false) 'OFF'
AssertEqual (Get-ArkuzoTrimCountdown 0 300 45 100 0 $true $true) 'OFF'
Write-Output 'PASS: rounding, grace boundary, post-trim interval, disabled and monitor-only'
$model=@{Mode='agressive';MonitorOnly=$false;SoftLimit=$true;TrimEnabled=$true;TrimSeconds=45;TargetMB=600;Managed=2;Detected=2;Uptime=[timespan]::FromSeconds(10);Trims=0;Priority='BelowNormal';CoresPerInstance=2;Cpu=1;ResidentMB=2000;PrivateMB=4000;History=@();HealthPolicy=@{enabled=$false};SystemMemory=$null;Notice='';Now=[datetime]'2026-10-07T16:00:00';Rows=@(
 [pscustomobject]@{Slot=0;Account='Client A';Id=1;Cpu=1;Ram=1000;Private=2000;NextTrim='WARMUP 300s';Status='WINDOW OPEN'},
 [pscustomobject]@{Slot=1;Account='Client B';Id=2;Cpu=0;Ram=1000;Private=2000;NextTrim='45s';Status='WINDOW OPEN'})}
foreach($width in @(120,80)) {
 $frame=@(New-ArkuzoFrame $model $width 30)
 $rows=@($frame|Where-Object{$_.Text -match '#[12]'})
 if($rows.Count -ne 2 -or $rows[0].Text.IndexOf('WINDOW OPEN') -ne $rows[1].Text.IndexOf('WINDOW OPEN')) {throw "FAIL: warmup and trim must keep STATE aligned at width $width"}
 if(-not ($rows[0].Text.Contains('WARMUP 300s'))) {throw 'FAIL: warmup text clipped'}
 $header=@($frame|Where-Object{$_.Text -match 'SLOT.*STATE'})[0]
 if($header.Text.IndexOf('STATE') -ne $rows[0].Text.IndexOf('WINDOW OPEN')) {throw 'FAIL: column header and values must align'}
 if(@($frame|Where-Object{$_.Text.Length -gt $width}).Count){throw 'FAIL: frame exceeds width'}
 if($frame[-1].Text -notmatch 'Q:'){throw 'FAIL: stop hint missing'}
}
Write-Output 'PASS: warmup countdown fits wide/narrow frames with stationary aligned STATE'
if($a.Extent.Text -notmatch '\$nextTrimText = Get-ArkuzoTrimCountdown'){throw 'FAIL: controller loop does not use warmup-aware countdown'}
Write-Output 'PASS: live dashboard integration'
