#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $repo 'src/saver/Arkuzo-Memory-Saver.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Saver parse errors' }
$helperNames = @('Test-ArkuzoCrashHandlerIdentity','Get-ArkuzoOrphanHandlerDecision','Test-ArkuzoOrphanHandlerExit')
$helpers = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false) | Where-Object { $helperNames -contains $_.Name })
foreach ($f in $helpers) {
    . ([scriptblock]::Create($f.Extent.Text))
}
# Execute only the cleanup statement, never the saver bootstrap or live loop.
$eventBlocks = @($ast.FindAll({param($n)
    $n -is [Management.Automation.Language.IfStatementAst] -and
    $n.Clauses[0].Item1.Extent.Text -eq '$clock.Elapsed.TotalSeconds -ge $nextEventCheck'
}, $true))
if ($eventBlocks.Count -ne 1) { throw 'Expected one event cleanup block' }
$cleanupStatements = @($eventBlocks[0].Clauses[0].Item2.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($cleanupStatements.Count -ne 1) { throw 'Expected one cleanup try statement' }
$script:cleanup = [scriptblock]::Create($cleanupStatements[0].Extent.Text)
$script:checks = 0; $script:failures = @()
function Check([bool]$Ok, [string]$Message) {
    $script:checks++
    if (-not $Ok) { $script:failures += $Message; Write-Output "FAIL: $Message" }
}
$script:fixtureRoot = Join-Path $PSScriptRoot 'fixtures/local/Roblox/Versions'
$script:fixturePath = Join-Path $script:fixtureRoot 'version-fixture/RobloxCrashHandler.exe'
function New-HandlerFixture {
    $start = [datetime]::UtcNow.AddSeconds(-90)
    $p = [pscustomobject]@{ Id = 4242; Handle = [IntPtr]77; StartTime = $start; Path = $script:fixturePath; ProcessName = 'RobloxCrashHandler'; HasExited = $false }
    $p | Add-Member ScriptMethod Refresh {
        $script:fixture.Refreshes++
        if ($script:fixture.ReuseOnFinalRefresh -and $script:fixture.Refreshes -eq 6) { $this.StartTime = $this.StartTime.AddSeconds(1) }
    }
    $p | Add-Member ScriptMethod Kill {
        $script:fixture.Kills++
        if ($script:fixture.KillThrows) { throw 'Fixture termination refused' }
        $this.HasExited = -not [bool]$script:fixture.ExitUnconfirmed
        if ($script:fixture.ExitGetterUnknown) { $this.HasExited = $null }
        if ($script:fixture.ReadbackIdentityMismatch) { $this.StartTime = $this.StartTime.AddSeconds(1) }
    }
    $p | Add-Member ScriptMethod WaitForExit { param($Timeout) -not [bool]$script:fixture.ExitUnconfirmed }
    $p | Add-Member ScriptMethod Dispose { $script:fixture.Disposals++ }
    return @{ Process = $p; Kills = 0; Refreshes = 0; Disposals = 0; Events = @(); ParentId = 4343; ParentReads = 0; Queries = 0; SignatureStatus = 'Valid' }
}
# All process/CIM/signature/logging IO is replaced. Kill operates on a fake only.
function Get-Process {
    param($Name, $Id, $ErrorAction)
    if ($Name -and $script:fixture.EnumerationError) {
        if ($ErrorAction -eq 'Stop') { throw 'Fixture enumeration failed' }
        return @()
    }
    if ($Name -eq 'RobloxCrashHandler' -or $Id -eq 4242) { return $script:fixture.Process }
    if ($script:fixture.ParentAccessDenied -and $ErrorAction -eq 'Stop') { throw 'Fixture parent access denied' }
    if ($script:fixture.ParentLookupDenied) { throw 'Fixture process lookup access denied' }
    if ($Id -eq 4343 -and $script:fixture.Owner -and (-not $script:fixture.ParentAppearsLate -or $script:fixture.ParentReads -ge 2)) { return $script:fixture.Owner }
    $missing = [Management.Automation.ErrorRecord]::new([ArgumentException]::new('Fixture process absent'), 'NoProcessFoundForGivenId', [Management.Automation.ErrorCategory]::ObjectNotFound, $Id)
    throw $missing
}
function Get-CimInstance {
    param($ClassName, $Filter, $Property, $ErrorAction)
    $script:fixture.Queries++
    if ($Filter -like '*RobloxCrashHandler*' -and $script:fixture.MultipleCandidates) {
        return @([pscustomobject]@{ProcessId=[uint32]4141},[pscustomobject]@{ProcessId=[uint32]4242})
    }
    if ($Filter -like '*RobloxCrashHandler*' -and $script:fixture.EnumerationError) { throw 'Fixture enumeration failed' }
    if ($Filter -like '*4242*' -or $Filter -like '*RobloxCrashHandler*') {
        return [pscustomobject]@{ ProcessId = [uint32]4242; Name = ($script:fixture.Process.ProcessName + '.exe'); ExecutablePath = $script:fixture.Process.Path; ParentProcessId = [uint32]$script:fixture.ParentId; CreationDate = $script:fixture.Process.StartTime }
    }
    $script:fixture.ParentReads++
    if ($script:fixture.ParentAccessDenied) { throw 'Fixture parent access denied' }
    if ($script:fixture.ReuseOnParentRead) { $script:fixture.Process.StartTime = $script:fixture.Process.StartTime.AddSeconds(1) }
    if ($script:fixture.Owner -and -not $script:fixture.ParentCimOmission -and (-not $script:fixture.ParentAppearsLate -or $script:fixture.ParentReads -ge 2)) {
        $created = $script:fixture.Owner.StartTime
        if ($script:fixture.ParentGenerationMismatch) { $created = $created.AddSeconds(-1) }
        return [pscustomobject]@{ ProcessId = [uint32]4343; CreationDate = $created }
    }
    return @()
}
function Get-AuthenticodeSignature {
    param($LiteralPath, $FilePath, $ErrorAction)
    return [pscustomobject]@{ Status = $script:fixture.SignatureStatus; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Roblox Corporation, O=Roblox Corporation, C=US' }; Path = $script:fixture.Process.Path }
}
function Write-Diagnostic {
    param($Kind, $Data)
    $script:fixture.Events += [pscustomobject]@{ Kind = $Kind; Data = $Data }
    if ($Kind -eq 'ORPHAN_CRASH_HANDLER_CLOSE_REQUESTED') {
        if ($script:fixture.AuditFails) { $script:logFailed = $true }
        if ($script:fixture.LoseMutexOnAudit) { $script:ownsControllerMutex = $false }
        if ($script:fixture.BecomeMonitorOnAudit) { $script:MonitorOnly = $true }
    }
}
function Warn-Throttled { param($Key, $Message) Write-Diagnostic 'WARNING' @{ key = $Key; message = $Message } }
function Set-FixtureParent($F, [int]$SecondsAfterHandler) {
    $p = [pscustomobject]@{ Id = 4343; StartTime = $F.Process.StartTime.AddSeconds($SecondsAfterHandler); Handle = [IntPtr]88; HasExited = $false }
    $p | Add-Member ScriptMethod Refresh {}
    $p | Add-Member ScriptMethod Dispose { $script:fixture.OwnerDisposals++ }
    $F.Owner = $p; $F.OwnerDisposals = 0
}
function Invoke-CleanupFixture([bool]$Monitor = $false, [bool]$Owns = $true, [scriptblock]$Configure = {}) {
    $script:fixture = New-HandlerFixture
    & $Configure $script:fixture
    $script:MonitorOnly = $Monitor; $script:ownsControllerMutex = $Owns; $script:logFailed = [bool]$script:fixture.InitialAuditFailed
    & $script:cleanup
    return $script:fixture
}
$oldLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $PSScriptRoot 'fixtures/local'
    $f = Invoke-CleanupFixture -Owns $false
    Check ($f.Kills -eq 0) 'An unowned controller must never close an orphan crash handler'
    Check ($f.Queries -eq 0) 'Unowned controller does not enter cleanup enumeration'
    $f = Invoke-CleanupFixture -Monitor $true
    Check ($f.Kills -eq 0 -and $f.Queries -eq 0) 'MonitorOnly never even enters cleanup enumeration'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.ParentAccessDenied = $true }
    Check ($f.Kills -eq 0) 'Inaccessible parent is unknown, never verified absence'
    Check (@($f.Events | Where-Object Kind -eq 'ORPHAN_CRASH_HANDLER_ERROR').Count -eq 1) 'Parent query error is logged instead of swallowed'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.SignatureStatus = 'NotSigned' }
    Check ($f.Kills -eq 0) 'Unsigned same-name executable is not a verified Roblox handler'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.Process.Path = Join-Path $PSScriptRoot 'fixtures/foreign/RobloxCrashHandler.exe' }
    Check ($f.Kills -eq 0) 'Even signed handlers outside known Roblox install roots remain untouched'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.Process.ProcessName = 'WerFault' }
    Check ($f.Kills -eq 0) 'Windows error reporting is never a cleanup target'
    $f = Invoke-CleanupFixture
    Check ($f.Kills -eq 1) 'Verified old orphan handler still closes through its fake process object'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.ReuseOnParentRead = $true }
    Check ($f.Kills -eq 0) 'Handler start ticks changing during metadata IO must block closure'
    $f = Invoke-CleanupFixture -Configure { param($f) Set-FixtureParent $f -20; $f.ParentAppearsLate = $true }
    Check ($f.Kills -eq 0) 'Parent absence must be reobserved after audit IO before closure'
    $f = Invoke-CleanupFixture -Configure { param($f) Set-FixtureParent $f 20; $f.ParentGenerationMismatch = $true }
    Check ($f.Kills -eq 0) 'Parent metadata from a different generation is unknown, not proof of PID reuse'
    $f = Invoke-CleanupFixture -Configure { param($f) Set-FixtureParent $f -20 }
    Check ($f.Kills -eq 0) 'Handlers with healthy live parents survive'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.Process.StartTime = [datetime]::UtcNow.AddSeconds(-20) }
    Check ($f.Kills -eq 0) 'Young orphan handlers survive'
    $f = Invoke-CleanupFixture -Configure { param($f) Set-FixtureParent $f 20 }
    Check ($f.Kills -eq 1) 'Verified newer parent generation is eligible only for an old handler'
    foreach ($case in @('ExitUnconfirmed','ExitGetterUnknown','ReadbackIdentityMismatch','KillThrows')) {
        $f = Invoke-CleanupFixture -Configure { param($f) $f[$case] = $true }
        Check (@($f.Events | Where-Object Kind -eq 'ORPHAN_CRASH_HANDLER_CLOSED').Count -eq 0) "$case cannot report verified closure"
        Check (@($f.Events | Where-Object Kind -eq 'ORPHAN_CRASH_HANDLER_ERROR').Count -eq 1) "$case reports a cleanup error"
    }
    $f = Invoke-CleanupFixture
    Check (@($f.Events | Where-Object Kind -eq 'ORPHAN_CRASH_HANDLER_CLOSED').Count -eq 1) 'Verified exact retained-process exit reports closure once'
    foreach ($case in @('InitialAuditFailed','AuditFails','LoseMutexOnAudit','BecomeMonitorOnAudit')) {
        $f = Invoke-CleanupFixture -Configure { param($f) $f[$case] = $true }
        Check ($f.Kills -eq 0) "$case prevents cleanup closure"
    }
    $f = Invoke-CleanupFixture -Configure { param($f) $f.EnumerationError = $true }
    Check (@($f.Events | Where-Object Kind -eq 'ORPHAN_CRASH_HANDLER_ERROR').Count -eq 1) 'Enumeration failure is visible instead of swallowed'
    $f = Invoke-CleanupFixture -Configure { param($f) Set-FixtureParent $f -20; $f.ParentCimOmission = $true }
    Check ($f.Kills -eq 0) 'A CIM omission contradicted by a live parent is not verified absence'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.ParentLookupDenied = $true }
    Check ($f.Kills -eq 0) 'An empty parent CIM query cannot override inaccessible process lookup'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.ReuseOnFinalRefresh = $true }
    Check ($f.Kills -eq 0) 'A changed generation at the final immediate recheck prevents closure'
    Check ($f.Disposals -eq 1) 'Refused candidate still releases the retained fake handle'
    $f = Invoke-CleanupFixture -Configure { param($f) $f.MultipleCandidates = $true }
    Check ($f.Kills -eq 1) 'One unavailable candidate does not abort independent verified orphan cleanup'
    Check (@($f.Events | Where-Object Kind -eq 'ORPHAN_CRASH_HANDLER_ERROR').Count -eq 1) 'Per-candidate failure remains visible while iteration continues'
    Check ($f.ParentReads -eq 2 -and $f.Disposals -eq 1) 'Successful orphan rechecks its parent and disposes its retained fake handle'

    # Deterministic pure policy snapshots: no IO, no real handles, no destructive calls.
    $now = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $handler = @{
        Id=4242;StartTicks=$now.AddSeconds(-61).Ticks;Handle=[IntPtr]77;HasExited=$false;ProcessName='RobloxCrashHandler';Path=$script:fixturePath
        CimId=[uint32]4242;CimName='RobloxCrashHandler.exe';CimPath=$script:fixturePath;SignatureStatus='Valid'
        SignerSubject='CN=Roblox Corporation, O=Roblox Corporation, C=US';SignaturePath=$script:fixturePath;ParentId=4343
    }
    $expected = $handler.Clone()
    $parent = @{QuerySucceeded=$true;Count=0;Id=4343;AbsenceConfirmed=$true}
    Check ((Get-ArkuzoOrphanHandlerDecision $handler $parent $now $false $true @($script:fixtureRoot) $expected).Close) 'Pure verified old orphan is eligible'
    $uncertainParent = $parent.Clone(); $uncertainParent.AbsenceConfirmed = $false
    Check (-not (Get-ArkuzoOrphanHandlerDecision $handler $uncertainParent $now $false $true @($script:fixtureRoot) $expected).Close) 'Pure absence decision requires independent missing-PID confirmation'
    foreach ($age in @(-1, 0, 59, 60)) {
        $h = $handler.Clone(); $h.StartTicks = $now.AddSeconds(-$age).Ticks
        Check (-not (Get-ArkuzoOrphanHandlerDecision $h $parent $now $false $true @($script:fixtureRoot) $h).Close) "Pure handler age $age seconds survives"
    }
    foreach ($authority in @(@{Monitor=$true;Owns=$true},@{Monitor=$false;Owns=$false},@{Monitor='false';Owns=$true},@{Monitor=$false;Owns='true'})) {
        Check (-not (Get-ArkuzoOrphanHandlerDecision $handler $parent $now $authority.Monitor $authority.Owns @($script:fixtureRoot) $expected).Close) 'Only actual monitor-false and mutex-true booleans authorize cleanup'
    }
    foreach ($mutation in @(
        @{Id=4243},@{StartTicks=$handler.StartTicks + 1L},@{Handle=[IntPtr]78},@{Handle=[IntPtr]::Zero},@{HasExited=$true},@{HasExited=$null},
        @{CimId=[uint32]4243},@{CimName='WerFault.exe'},@{ProcessName='RobloxPlayerBeta'},@{Path='RobloxCrashHandler.exe'},
        @{CimPath=(Join-Path $script:fixtureRoot 'other/RobloxCrashHandler.exe')},@{SignatureStatus='UnknownError'},@{SignerSubject='O=Not Roblox Corporation'},
        @{SignerSubject='O=Roblox Corporation Spoof'},@{ParentId=0},@{ParentId=4242},@{ParentId=4344}
    )) {
        $h = $handler.Clone(); foreach ($k in $mutation.Keys) { $h[$k] = $mutation[$k] }
        Check (-not (Get-ArkuzoOrphanHandlerDecision $h $parent $now $false $true @($script:fixtureRoot) $expected).Close) ('Unverified pure identity rejected: ' + ($mutation.Keys -join ','))
    }
    $readback = @{Id=4242;StartTicks=$handler.StartTicks;Handle=[IntPtr]77;WaitConfirmed=$true;HasExited=$true}
    Check (Test-ArkuzoOrphanHandlerExit $expected $readback) 'Pure exit readback verifies the exact retained generation'
    foreach ($mutation in @(@{Id=4243},@{StartTicks=$handler.StartTicks + 1L},@{Handle=[IntPtr]78},@{WaitConfirmed=$false},@{WaitConfirmed='true'},@{HasExited=$false},@{HasExited=$null})) {
        $r = $readback.Clone(); foreach ($k in $mutation.Keys) { $r[$k] = $mutation[$k] }
        Check (-not (Test-ArkuzoOrphanHandlerExit $expected $r)) ('Unverified pure exit rejected: ' + ($mutation.Keys -join ','))
    }
    $present = @{QuerySucceeded=$true;Count=1;Id=4343;CimId=[uint32]4343;StartTicks=$handler.StartTicks + [TimeSpan]::FromSeconds(20).Ticks;HasExited=$false;Handle=[IntPtr]88}
    $present.CimStartTicks = $present.StartTicks - 9L
    Check ((Get-ArkuzoOrphanHandlerDecision $handler $present $now $false $true @($script:fixtureRoot) $expected).Close) 'Microsecond-truncated CIM date still binds the retained newer parent generation'
    foreach ($mutation in @(
        @{QuerySucceeded=$false},@{QuerySucceeded='true'},@{Count=2},@{Id=4344},@{HasExited=$null},@{HasExited=$true},@{Handle=[IntPtr]::Zero},
        @{CimId=[uint32]4344},@{CimStartTicks=$present.StartTicks - 10L},@{CimStartTicks=$present.StartTicks + 1L},@{StartTicks=0L}
    )) {
        $p = $present.Clone(); foreach ($k in $mutation.Keys) { $p[$k] = $mutation[$k] }
        Check (-not (Get-ArkuzoOrphanHandlerDecision $handler $p $now $false $true @($script:fixtureRoot) $expected).Close) ('Unverified parent snapshot rejected: ' + ($mutation.Keys -join ','))
    }
    $edge = $handler.Clone(); $edge.StartTicks = $now.AddSeconds(-60).Ticks - 1L
    Check ((Get-ArkuzoOrphanHandlerDecision $edge $parent $now $false $true @($script:fixtureRoot) $edge).Close) 'Age must be strictly greater than 60 seconds, including one tick over the boundary'
    Check (Test-ArkuzoCrashHandlerIdentity $handler @($script:fixtureRoot)) 'Pure executable identity verifies exact names, matching paths and Roblox publisher'
    Check (-not (Test-ArkuzoCrashHandlerIdentity $handler @($script:fixtureRoot + '-peer'))) 'Trusted install root prefix requires a directory boundary'
    Check ($helpers.Count -eq $helperNames.Count) 'Only cleanup pure helpers are imported into this suite'
    $dangerous = @($cleanupStatements[0].FindAll({param($n)
        ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Stop-Process','taskkill','Set-ItemProperty','Stop-Service')) -or
        ($n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Kill' -and $n.Expression.Extent.Text -ne '$ch')
    }, $true))
    Check ($dangerous.Count -eq 0) 'Cleanup contains no global termination, service/registry changes or non-retained Kill target'
} finally { $env:LOCALAPPDATA = $oldLocal }
Write-Output "RESULT: $script:checks checks, $($script:failures.Count) failures"
if ($script:failures.Count) { throw 'Scoped orphan handler regressions failed' }
