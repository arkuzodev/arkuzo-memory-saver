#requires -Version 5.1
# Main-loop cost: per-phase timings in RESOURCE_SAMPLE, the Roblox log folder listed once per
# pass (and a log's tracker id read once), frozen clients probed once per pass.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }

# --- Per-phase timings.
$script:phaseStats = $null; $script:passPhaseMs = $null; $script:phaseName = $null; $script:phaseClock = $null
Assert ($null -eq (Get-ArkuzoLoopTimings)) 'no passes yet: no timings'
foreach ($pass in 1..3) {
    Step-ArkuzoLoopPhase 'clients'; Start-Sleep -Milliseconds (20 * $pass)
    Step-ArkuzoLoopPhase 'outcomes'; Start-Sleep -Milliseconds 5
    Complete-ArkuzoLoopPass
    Start-Sleep -Milliseconds 400  # the sleep between passes is not charged to any phase
}
$timings = Get-ArkuzoLoopTimings
Assert ($timings.passes -eq 3 -and $timings.phases.Contains('clients') -and $timings.phases.Contains('outcomes')) 'three passes, both phases reported'
Assert ($timings.phases['clients'].maxMs -ge 55 -and $timings.phases['clients'].avgMs -ge 35 -and $timings.phases['clients'].avgMs -lt $timings.phases['clients'].maxMs) ('average and worst per phase: ' + ($timings | ConvertTo-Json -Compress -Depth 4))
Assert ($timings.passMaxMs -lt 380 -and [math]::Abs([double]$timings.passMaxMs - [double]$timings.phases['clients'].maxMs - [double]$timings.phases['outcomes'].maxMs) -lt 60) ('the sleep between passes is excluded: ' + $timings.passMaxMs)
Assert ($null -eq (Get-ArkuzoLoopTimings)) 'reading the timings resets them'
$json = @{ timings = $timings } | ConvertTo-Json -Depth 6 -Compress
Assert ($json -match '"passAvgMs"' -and $json -match '"clients":\{"avgMs"') 'timings serialise into the RESOURCE_SAMPLE record'

# --- The Roblox log folder is listed once per pass; a log's tracker id is read once.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('loop-cost-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $time = [datetime]::SpecifyKind([datetime]'2026-11-10T12:00:00', [DateTimeKind]::Utc)
    $fileA = Join-Path $scratch '0.1_20261110T120000Z_Player_AAAA_last.log'; [IO.File]::WriteAllText($fileA, 'websiteBTId is 111111111')
    $fileB = Join-Path $scratch '0.1_20261110T120005Z_Player_BBBB_last.log'; [IO.File]::WriteAllText($fileB, 'websiteBTId is 222222222')
    $script:listings = 0; $script:heads = 0
    function Get-ChildItem { $script:listings++; Microsoft.PowerShell.Management\Get-ChildItem @args }
    $readHead = ${function:Read-ArkuzoLogHeadLines}
    function Read-ArkuzoLogHeadLines { $script:heads++; & $readHead @args }
    $script:loopPass = 1; $script:robloxLogTrackers = @{}
    Assert ((Find-RobloxProcessLog -TargetProcessId 1 -TrackerId '111111111' -StartTimeUtc $time -LogsDir $scratch) -eq $fileA) 'client A finds its log'
    Assert ((Find-RobloxProcessLog -TargetProcessId 2 -TrackerId '222222222' -StartTimeUtc $time -LogsDir $scratch) -eq $fileB) 'client B finds its log'
    Assert ((Find-RobloxProcessLog -TargetProcessId 3 -TrackerId '333333333' -StartTimeUtc $time -LogsDir $scratch) -eq $null) 'client C has no log yet'
    Assert ($script:listings -eq 1) ('three clients, one pass: the folder is listed once (' + $script:listings + ')')
    Assert ($script:heads -eq 2) ('each log head is read once and its tracker remembered (' + $script:heads + ')')
    $script:loopPass = 2
    $fileC = Join-Path $scratch '0.1_20261110T120010Z_Player_CCCC_last.log'; [IO.File]::WriteAllText($fileC, 'websiteBTId is 333333333')
    Assert ((Find-RobloxProcessLog -TargetProcessId 3 -TrackerId '333333333' -StartTimeUtc $time -LogsDir $scratch) -eq $fileC) 'next pass: a new log is found'
    Assert ($script:listings -eq 2 -and $script:heads -eq 3) 'the next pass lists again; only the new head is read'
    $script:loopPass = $null
    [void](Find-RobloxProcessLog -TargetProcessId 3 -TrackerId '333333333' -StartTimeUtc $time -LogsDir $scratch)
    [void](Find-RobloxProcessLog -TargetProcessId 3 -TrackerId '333333333' -StartTimeUtc $time -LogsDir $scratch)
    Assert ($script:listings -eq 4) 'outside the loop (no pass number) nothing is cached'
    Remove-Item function:Get-ChildItem
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

# --- Frozen clients: the observation slice leaves them to the main loop's one probe per pass.
$script:probes = New-Object Collections.ArrayList
function Get-ArkuzoRecoveryHealthSample($Watcher, $Reason, $State) { [void]$script:probes.Add($Watcher.Id); return @{ responding = $false; windowPresent = $true; launchError = $false; isDisconnected = $false; privateMB = 1; ageSec = 600; systemCommitPercent = 0; eligible = $true } }
function Test-ArkuzoClientIdentity { $true }
function Test-ArkuzoClientOwnership { $true }
function Get-ArkuzoHealthDecision($State, $Sample, $Policy, $Now) { $State.LastHealthSampleTime = $Now; return @{ Recycle = $false; Reason = ''; Status = '' } }
$script:clock = @{ Elapsed = @{ TotalSeconds = 1000.0 } }
$script:MonitorOnly = $false; $script:healthPolicy = @{ enabled = $true }; $script:voltStatus = @{ safeToRecycle = $true }; $script:voltParents = @{}; $script:systemMemory = $null
$script:observationBusy = $false; $script:observationCursor = 0; $script:recoveryPending = @{}
function New-State([int]$Id, [bool]$Frozen, [double]$Age) { @{ Watcher = [pscustomobject]@{ Id = $Id }; StartTicks = 1; ParentId = 1; RecoveryRequested = $false; isDisconnected = $false; GameReady = $true; LastHealthSampleTime = 1000.0 - $Age; LastSnapshot = @{ windowPresent = $true; responding = -not $Frozen } } }
$script:tracked = @{ 1 = (New-State 1 $true 3); 2 = (New-State 2 $true 11); 3 = (New-State 3 $false 3) }
Invoke-ArkuzoHealthObservation
Assert ($script:probes -notcontains 1) 'a frozen client sampled 3 s ago is not probed again by the slice'
Assert ($script:probes -contains 2) 'a frozen client last sampled 11 s ago is (timers keep moving during long waits)'
Assert ($script:probes -contains 3) 'a responsive client keeps the 1 s slice'

Write-Host "PASS: loop cost: per-phase timings, one log listing per pass, frozen clients probed once ($script:checks checks)"
