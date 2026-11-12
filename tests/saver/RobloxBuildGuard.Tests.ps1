#requires -Version 5.1
# Dead-build guard (docs/roblox-versions.md): when clients launched on one Roblox build close before
# they reach the game 4 times in a row (any accounts, within 5 minutes), launches stop using that
# build. Pinned: the Auto build when "fall back" is on, else launches wait. Auto: another installed
# build, else wait. A client of that build reaching the game, or another pinned build, clears it.
# 10-11 Nov: a gutted install and two builds Roblox refused were relaunched 16+ times in a row.
# Installs are fake folders under a temp LOCALAPPDATA / Program Files; nothing is started.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
$script:events = New-Object Collections.ArrayList
function Write-Diagnostic($kind, $data) { [void]$script:events.Add(@{ kind = $kind; data = $data }) }
function Warn-Throttled($key, $message) { }
function Events([string]$Kind) { return ,@($script:events | Where-Object { $_.kind -ceq $Kind }) }
$script:RobloxBuildFailureLimit = 4; $script:RobloxBuildFailureWindowSec = 300
$script:robloxBuildGuard = $null; $script:robloxVersionStatus = $null; $script:robloxProtocolOverrideLogged = $false

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-buildguard-' + [guid]::NewGuid().ToString('N'))
$saved = @{ L = $env:LOCALAPPDATA; P = $env:ProgramFiles; X = ${env:ProgramFiles(x86)} }
$Bad = 'version-badbadbadbadbad0'; $Good = 'version-600d600d600d600d'; $Third = 'version-0123456789abcdef'
function New-Install([string]$Name, [datetime]$When) {
    $dir = Join-Path $script:managed $Name; [void][IO.Directory]::CreateDirectory($dir)
    $exe = Join-Path $dir 'RobloxPlayerBeta.exe'; [IO.File]::WriteAllText($exe, 'x'); [IO.File]::WriteAllText((Join-Path $dir 'AppSettings.xml'), '<Settings/>')
    (Get-Item -LiteralPath $exe).LastWriteTimeUtc = $When
    return $exe
}
function New-Vault([hashtable]$Settings) { return [pscustomobject]@{ settings = [pscustomobject]($Settings + @{ robloxVersionsDir = $script:farmDir }); accounts = @() } }
function Fail([string]$Version, [int]$Times, [datetime]$At = [datetime]::UtcNow) { $r = $false; for ($i = 0; $i -lt $Times; $i++) { $r = Register-ArkuzoRobloxBuildFailure $Version ('acct-' + $i) $At }; return $r }
try {
    $env:LOCALAPPDATA = Join-Path $tmp 'local'; $env:ProgramFiles = Join-Path $tmp 'pf'; ${env:ProgramFiles(x86)} = Join-Path $tmp 'pf86'
    $script:farmDir = 'C:\ArkuzoBuildGuardTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:managed = Join-Path $env:LOCALAPPDATA 'Roblox\Versions' # Roblox's own folder (robloxVersionsDir below never exists).
    $now = [datetime]::UtcNow
    $badExe = New-Install $Bad $now.AddMinutes(-1)        # newest: Auto picks it
    $goodExe = New-Install $Good $now.AddHours(-5)
    $pinBad = New-Vault @{ robloxVersion = $Bad }
    $pinBadFallback = New-Vault @{ robloxVersion = $Bad; robloxVersionFallback = $true }
    $auto = New-Vault @{ robloxVersion = 'auto' }
    $script:nativeVault = $pinBad

    # ---- counting ----
    Assert (-not (Fail $Bad 3)) 'three closes in a row: not yet'
    Assert ((Resolve-ArkuzoRobloxPlayer @() $pinBad 'direct').path -eq $badExe) 'the pin still launches'
    Assert (Register-ArkuzoRobloxBuildFailure $Bad 'acct-9' $now) 'the fourth marks the build failing'
    Assert ((Events 'ROBLOX_BUILD_FAILING').Count -eq 1 -and (Events 'ROBLOX_BUILD_FAILING')[0].data.version -ceq $Bad -and -not (Events 'ROBLOX_BUILD_FAILING')[0].data.fallback) 'ROBLOX_BUILD_FAILING logged once'
    Assert (-not (Register-ArkuzoRobloxBuildFailure $Bad 'acct-10' $now) -and (Events 'ROBLOX_BUILD_FAILING').Count -eq 1) 'not logged again'

    # ---- pinned, no fallback: launches wait ----
    $r = Resolve-ArkuzoRobloxPlayer @() $pinBad 'direct'
    Assert (-not $r.path -and $r.blocked -and $r.problem -match ('\ARoblox build ' + $Bad + ' keeps closing at start .{1,3} it may be outdated or refused by Roblox')) ('a failing pin is not launched: ' + $r.problem)
    Assert ((Get-ArkuzoRobloxVersionPreflight $pinBad) -match 'keeps closing at start') 'step 1 refuses before a ticket is requested'
    $threw = $false; try { [void](Start-ArkuzoRobloxClient 't' 'https://x' '1234567890' 'direct' @() $r) } catch { $threw = $true }
    Assert $threw 'the client start refuses too (never Roblox''s launcher instead)'
    Update-ArkuzoRobloxVersionStatus $r 'direct'
    Assert ($script:robloxVersionStatus.problem -match 'keeps closing at start' -and -not $script:robloxVersionStatus.selectedPath) 'the heartbeat block shows the problem (Roblox tab)'
    Assert ((Events 'ROBLOX_VERSION_PIN_MISSING').Count -eq 0) 'not reported as a missing pin'

    # ---- pinned with fallback: the Auto build, never the failing one ----
    $script:nativeVault = $pinBadFallback
    $r = Resolve-ArkuzoRobloxPlayer @([pscustomobject]@{ path = $badExe }) $pinBadFallback 'direct'
    Assert ($r.path -eq $goodExe -and $r.fallback -and $r.problem -match 'launching the Auto build') ('fallback launches another build, even though the failing one is running: ' + $r.path)
    Assert ((Get-ArkuzoRobloxVersionPreflight $pinBadFallback) -eq '') 'fallback: launches go ahead'

    # ---- a client of that build reaching the game clears it ----
    Register-ArkuzoRobloxBuildSuccess $Bad
    Assert ((Resolve-ArkuzoRobloxPlayer @() $pinBad 'direct').path -eq $badExe -and (Events 'ROBLOX_BUILD_GUARD_RESET').Count -eq 1) 'reset by a client in game'
    Assert (-not (Fail $Bad 3)) 'counting starts again'
    Register-ArkuzoRobloxBuildSuccess $Bad
    Assert (-not (Fail $Bad 3)) 'a success in between: never four in a row'

    # ---- old failures fall out of the window ----
    $script:robloxBuildGuard = $null; [void](Resolve-ArkuzoRobloxPlayer @() $pinBad 'direct')
    [void](Fail $Bad 3 $now.AddSeconds(-400))
    Assert (-not (Register-ArkuzoRobloxBuildFailure $Bad 'x' $now)) 'three closes 6+ minutes ago and one now: not four within 5 minutes'

    # ---- another pinned build clears the guard ----
    [void](Fail $Bad 4)
    Assert (@(Get-ArkuzoFailingRobloxBuilds) -ccontains $Bad) 'failing again'
    $script:events.Clear()
    $r = Resolve-ArkuzoRobloxPlayer @() (New-Vault @{ robloxVersion = $Good }) 'direct'
    Assert ($r.path -eq $goodExe -and @(Get-ArkuzoFailingRobloxBuilds).Count -eq 0 -and (Events 'ROBLOX_BUILD_GUARD_RESET').Count -eq 1) 'choosing another build resets the guard'
    Assert ((Resolve-ArkuzoRobloxPlayer @() $pinBad 'direct').path -eq $badExe) 'and the first build may be tried again when chosen again'

    # ---- Auto: skips a failing build; waits when nothing else is installed ----
    $script:robloxBuildGuard = $null; $script:nativeVault = $auto
    Assert ((Resolve-ArkuzoRobloxPlayer @() $auto 'direct').path -eq $badExe) 'Auto picks the newest build'
    Assert ((Get-ArkuzoRobloxVersionPreflight $auto) -eq '') 'Auto without failing builds: no preflight work'
    [void](Fail $Bad 4)
    Assert ((Events 'ROBLOX_BUILD_FAILING')[-1].data.fallback) 'Auto always falls back'
    $r = Resolve-ArkuzoRobloxPlayer @([pscustomobject]@{ path = $badExe }) $auto 'direct'
    Assert ($r.path -eq $goodExe -and -not $r.blocked -and $r.problem -match "launching $Good instead") ('Auto skips the failing build: ' + $r.problem)
    [void](Fail $Good 4)
    $r = Resolve-ArkuzoRobloxPlayer @() $auto 'direct'
    Assert (-not $r.path -and $r.blocked -and (Get-ArkuzoRobloxVersionPreflight $auto) -match 'launches wait') 'Auto with every build failing: launches wait'
    $third = New-Install $Third $now.AddHours(-9)
    Assert ((Resolve-ArkuzoRobloxPlayer @() $auto 'direct').path -eq $third) 'a newly installed build is launched'
    $r = Resolve-ArkuzoRobloxPlayer @() $auto 'protocol'
    Assert ($r.method -ceq 'protocol' -and -not $r.blocked) 'Auto + protocol: Roblox''s launcher picks the build, the guard cannot steer it'

    # ---- what counts as a failure (Register-ArkuzoNativeLaunchExit) ----
    $script:accountProvider = 'arkuzo'; $AccountB = '22222222-2222-4222-8222-222222222222'
    $script:voltControlStatus = [pscustomobject]@{ available = $true; accounts = @([pscustomobject]@{ accountId = $AccountB; trackerId = '223456789012' }) }
    $script:recoveryPending = @{ $AccountB = (New-ArkuzoPendingEntry $AccountB '223456789012') }
    $script:nativeLaunchExits = @{}; $script:nativeTicketJobs = @{}; $script:nativeLaunchPids = @{}; $script:nativeLaunchTrackers = @{}; $script:nativeLaunches = @{}
    foreach ($case in @(@{ Closing = $true; Counts = $false; Why = 'closed by the engine (stalled launch)' }, @{ EverGameReady = $true; Counts = $false; Why = 'reached the game first' }, @{ Counts = $true; Why = 'died at start' })) {
        $script:nativeLaunchBuilds = @{ $AccountB = $Bad }; $script:nativeLaunchExits = @{}
        $state = @{ TrackerId = '223456789012'; StartTicks = 7; RecoveryRequested = $false; Closing = [bool]$case.Closing; EverGameReady = [bool]$case.EverGameReady }
        Register-ArkuzoNativeLaunchExit 700 $state
        Assert ($script:nativeLaunchExits.ContainsKey($AccountB)) ('relaunch timing unchanged: ' + $case.Why)
        Assert ($script:nativeLaunchBuilds.ContainsKey($AccountB) -eq $case.Counts) ('counts against the build only when it ' + $case.Why)
    }
    Write-Host "RobloxBuildGuard: $script:checks checks passed"
} finally {
    $env:LOCALAPPDATA = $saved.L; $env:ProgramFiles = $saved.P; ${env:ProgramFiles(x86)} = $saved.X
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
