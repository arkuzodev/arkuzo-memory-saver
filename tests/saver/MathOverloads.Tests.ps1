#requires -Version 5.1
# [Math]::Min / [Math]::Max with an integer first and an uncast fraction second
# bind the Int32 overload in PowerShell and round the fraction away. These are the
# places that did (CPU %, meters, the adaptive-trim threshold, countdowns), plus
# the checker that keeps new ones out.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }

# The pitfall itself, so a PowerShell that changes this is noticed.
Assert ([Math]::Max(0, [double]7.4 * 1) -eq 7) 'PowerShell still rounds an uncast fraction (the reason for the casts)'
Assert ([Math]::Max([double]0, [double]7.4 * 1) -eq 7.4) 'a [double] cast selects the Double overload'

# Meter: was empty below 50 % and full above.
Assert ((Get-ArkuzoMeter 4 10 10) -ceq '[####......]') '40 % fills 4 of 10 cells'
Assert ((Get-ArkuzoMeter 7.5 10 10) -ceq '[#######...]') '75 % fills 7 of 10 cells'
Assert ((Get-ArkuzoMeter 0 10 10) -ceq '[..........]' -and (Get-ArkuzoMeter 25 10 10) -ceq '[##########]') 'the meter stays within 0-100 %'

# Adaptive trim: 19.6 % free was rounded to 20 and missed a "below 20 %" threshold.
$plan = Get-ArkuzoTrimPlan ([pscustomobject]@{ availablePhysicalMB = 1960 }) 10000 45 $true 20
Assert ($plan.AvailablePercent -eq 19.6 -and $plan.Pressure -and $plan.IntervalSec -eq 15) '19.6 % free is below a 20 % threshold'
$plan = Get-ArkuzoTrimPlan ([pscustomobject]@{ availablePhysicalMB = 2040 }) 10000 45 $true 20
Assert ($plan.AvailablePercent -eq 20.4 -and -not $plan.Pressure -and $plan.IntervalSec -eq 45) '20.4 % free is not'
$plan = Get-ArkuzoTrimPlan ([pscustomobject]@{ availablePhysicalMB = 20000 }) 10000 45 $true 20
Assert ($plan.AvailablePercent -eq 100) 'free RAM is capped at 100 %'

# Countdowns round up, never to the nearest second first.
Assert ((Get-ArkuzoTrimCountdown 299.6 300 45 100 0 $true $false) -ceq 'WARMUP 1s') '0.4 s of warm-up left still shows 1 s'
Assert ((Get-ArkuzoTrimCountdown 400 300 45 120.6 100 $true $false) -ceq '25s') '24.4 s left shows 25 s'

# Remote disconnect age keeps its fraction.
$now = [datetime]'2026-11-01T10:00:10Z'
$at = Get-ArkuzoRemoteDisconnectSec @{ crdEventId = 2; crdEventUtc = $now.AddSeconds(-2.4) } $now 100.0
Assert ([math]::Abs($at - 97.6) -lt 0.001) 'a disconnect 2.4 s ago is 2.4 s ago, not 2 s'

# System memory: free commit keeps its fraction.
if ('Arkuzo.HealthNativeV1' -as [type]) {
    $memory = Get-ArkuzoSystemMemory
    Assert ($memory.commitPercent -gt 0 -and $memory.commitPercent -le 100 -and $memory.freeCommitMB -ge 0) 'system memory reads sane values'
}

# Per-client CPU in the main loop (inline there): the expression, as written in the engine.
$loopText = $ast.Extent.Text
Assert ($loopText.Contains('$cpu = [Math]::Min([double]100, [Math]::Max([double]0, [double](100 * ($cpuTime - $state.LastCpu) / ($elapsed * $cpuThreads))))')) 'the loop computes CPU % on doubles'
$cpuTime = 10.337; $state = @{ LastCpu = 10.0 }; $elapsed = 0.5; $cpuThreads = 8
$cpu = [Math]::Min([double]100, [Math]::Max([double]0, [double](100 * ($cpuTime - $state.LastCpu) / ($elapsed * $cpuThreads))))
Assert ([math]::Abs($cpu - 8.425) -lt 0.001) 'CPU % keeps its fraction (was 8)'

# The checker: clean on the sources, and it catches the mistake.
$checker = Join-Path $root 'build/lint-math.ps1'
$powershell = Join-Path $PSHOME 'powershell.exe'
& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $checker | Out-Null
Assert ($LASTEXITCODE -eq 0) 'no ambiguous [Math]::Min/Max call in src/saver or build'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-lint-math-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $bad = Join-Path $scratch 'bad.ps1'; $good = Join-Path $scratch 'good.ps1'
    [IO.File]::WriteAllText($bad, "`$a = [Math]::Max(0, `$x / 3)`n`$b = [math]::Min(`$count, `$limit)`n")
    [IO.File]::WriteAllText($good, "`$a = [Math]::Max([double]0, `$x / 3)`n`$b = [math]::Min([int]`$count, 5)`n`$c = [Math]::Max(1.5, `$x)`n`$d = [Math]::Max(0, [Math]::Min(3, [int]`$step))`n")
    $output = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $checker -Path $bad
    Assert ($LASTEXITCODE -eq 1 -and @($output | Where-Object { $_ -like 'FAIL: 2 of 2*' }).Count -eq 1) 'the checker reports both ambiguous calls'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $checker -Path $good | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'casts, a double first argument and whole numbers pass'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

# config_lock limits keep a value's type and only move it to the safe side.
$policy = @{ pressure_percent = 80; pressure_min_private_mb = 5000; max_recycles_per_hour = 30; farm_freeze_confirm_sec = 20; farm_freeze_spacing_sec = 10
    farm_freeze_remote_confirm_sec = 10; startup_error_timeout_sec = 40; disconnect_timeout_sec = 3; cooldown_sec = 120 }
Set-ArkuzoConfigLockLimits $policy
Assert ($policy.pressure_percent -eq 88 -and $policy.pressure_min_private_mb -eq 5000 -and $policy.max_recycles_per_hour -eq 30 -and
    $policy.farm_freeze_confirm_sec -eq 30 -and $policy.farm_freeze_spacing_sec -eq 15 -and $policy.farm_freeze_remote_confirm_sec -eq 15 -and
    $policy.startup_error_timeout_sec -eq 5 -and $policy.disconnect_timeout_sec -eq 3 -and $policy.cooldown_sec -eq 90) 'config_lock limits: floors and ceilings'
Assert ($policy.pressure_percent -is [int] -and $policy.pressure_min_private_mb -is [int]) 'whole numbers stay whole numbers'
Set-ArkuzoConfigLockLimits $null

Write-Output "PASS: $script:checks overload checks ([Math]::Min/Max keep fractions; checker catches ambiguous calls)"
