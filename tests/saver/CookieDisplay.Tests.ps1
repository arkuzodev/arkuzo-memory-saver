#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $a.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
$script:suspendedAccounts=@{};$script:voltControlCheckedUtc=[datetime]::UtcNow
$id='11111111-1111-4111-8111-111111111111'
$dead=[pscustomobject]@{accountId=$id;username='DeadUser';cookieStatus='dead';processId=$null;suspensionSafe=$true;lastLaunchAtMs=$null}
$script:voltControlStatus=[pscustomobject]@{available=$true;accounts=@($dead)}
$model=@{Mode='normal';TargetMB=1200;SoftLimit=$false;TrimEnabled=$true;TrimSeconds=60;Managed=0;Detected=0;Uptime=[timespan]::Zero;History=@();Rows=@();Now=Get-Date;SuspendedAccounts=@($dead)}
foreach($size in @(@(110,30),@(64,20),@(40,12),@(32,7))) {
 $frame=@(New-ArkuzoFrame $model $size[0] $size[1])
 Assert (@($frame|Where-Object{$_.Color -eq [ConsoleColor]::Red -and $_.Text -match '\[DEAD/INVALID COOKIE\] DeadUser'}).Count -eq 1) "Explicit dead unlaunched red row at $($size -join 'x')"
 Assert ($frame.Count -le $size[1] -and @($frame|Where-Object{$_.Text.Length -gt $size[0]}).Count -eq 0 -and $frame[-1].Text -match 'Q:') 'Bounded frame always reserves exit footer'
}
foreach($size in @(@(20,1),@(24,2),@(24,3),@(24,4))) {
 $frame=@(New-ArkuzoFrame $model $size[0] $size[1])
 Assert ($frame.Count -le $size[1] -and $frame[-1].Text -match 'Q:') 'Tiny frames must keep exit Q footer'
}
$model.Rows=@(@{Slot=0;Id=42;Account='HealthyUser';Ram=100;Cpu=0;Private=100;NextTrim='30s';Status='OK'});$model.Managed=1;$model.Detected=1
$frame=@(New-ArkuzoFrame $model 110 30)
Assert (@($frame|Where-Object{$_.Text -match 'HealthyUser' -and $_.Color -eq [ConsoleColor]::Green}).Count -eq 1) 'Healthy row remains independently green in mixed frame'
$script:suspendedAccounts[$id]=@{accountId=$id;username='DeadUser';reason='COOKIE_DEAD'}
$script:voltControlStatus.available=$false
$display=@(Get-ArkuzoSuspendedAccountDisplay)
Assert ($display.Count -eq 1 -and $display[0].unverified) 'Unavailable adapter shows last-known ledger explicitly unverified'
$model.SuspendedAccounts=$display
$frame=@(New-ArkuzoFrame $model 110 30)
Assert (@($frame|Where-Object{$_.Text -match 'DeadUser.*UNVERIFIED' -and $_.Color -eq [ConsoleColor]::Red}).Count -eq 1) 'Last-known red status is not presented as current cookie verdict'
$script:voltControlStatus.available=$true;$script:voltControlCheckedUtc=[datetime]::UtcNow.AddMinutes(-2)
Assert ((@(Get-ArkuzoSuspendedAccountDisplay))[0].unverified) 'Stale adapter does not present explicit dead as fresh'
Write-Output 'PASS: zero-client and mixed healthy/dead red account frames, narrow/short bounds, Q footer, stale/unavailable labels'
