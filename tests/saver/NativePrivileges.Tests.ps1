#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Source parse failed: ' + ($parseErrors.Message -join '; ')) }
$native = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -match 'public static class MemorySaverNativeV1'
}, $true))
if ($native.Count -ne 1) { throw 'Expected exactly one embedded MemorySaverNativeV1 definition.' }
if (-not ('Arkuzo.MemorySaverNativeV1' -as [type])) { Add-Type -TypeDefinition $native[0].Value }
function Assert([bool]$ok, [string]$message) { if (-not $ok) { throw ('FAIL: ' + $message) } }

# Real failure, not a mocked Win32 response. Zero cannot name another process.
$failure = $null
try { [Arkuzo.MemorySaverNativeV1]::ReadLimits([IntPtr]::Zero) | Out-Null }
catch {
    $failure = $_.Exception
    while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
}
Assert ($failure -is [ComponentModel.Win32Exception]) 'Invalid handle must preserve Win32Exception.'
Assert ($failure.NativeErrorCode -eq 6) 'Invalid handle must preserve ERROR_INVALID_HANDLE (6).'
Assert ($failure.Message -match 'GetProcessWorkingSetSizeEx.*Win32 6') 'Invalid-handle diagnostic must name GetProcessWorkingSetSizeEx and Win32 6.'
Write-Output 'PASS: invalid-handle diagnostic preserves API name and Win32 6.'

function Assert-NativeFailure([scriptblock]$action, [string]$operation, [string]$requiredRight) {
    $failure = $null
    try { & $action | Out-Null }
    catch {
        $failure = $_.Exception
        while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
    }
    Assert ($failure -is [ComponentModel.Win32Exception]) ($operation + ' must preserve Win32Exception.')
    Assert ($failure.NativeErrorCode -eq 6) ($operation + ' must preserve Win32 6 for a zero handle.')
    Assert ($failure.Message -match ([regex]::Escape($operation) + '.*Win32 6')) ($operation + ' must name its API and error code.')
    Assert ($failure.Message.Contains($requiredRight)) ($operation + ' must explain the required handle access right.')
}
Assert-NativeFailure { [Arkuzo.MemorySaverNativeV1]::SetLimits([IntPtr]::Zero, 1MB, 600MB, 10) } 'SetProcessWorkingSetSizeEx' 'PROCESS_SET_QUOTA'
Assert-NativeFailure { [Arkuzo.MemorySaverNativeV1]::ReadMemoryPriority([IntPtr]::Zero) } 'GetProcessInformation' 'PROCESS_QUERY_LIMITED_INFORMATION'
Assert-NativeFailure { [Arkuzo.MemorySaverNativeV1]::SetMemoryPriority([IntPtr]::Zero, 3) } 'SetProcessInformation' 'PROCESS_SET_INFORMATION'
Assert-NativeFailure { [Arkuzo.MemorySaverNativeV1]::Trim([IntPtr]::Zero) } 'EmptyWorkingSet' 'PROCESS_SET_QUOTA'
Write-Output 'PASS: resource native calls include Win32 codes and required access rights; no valid process handles used.'

Assert ($null -ne [Arkuzo.MemorySaverNativeV1].GetMethod('QueryCurrentProcessPrivilege')) 'Read-only own-token privilege query API is missing.'
foreach ($name in @('SeDebugPrivilege', 'SeIncreaseWorkingSetPrivilege')) {
    $result = [Arkuzo.MemorySaverNativeV1]::QueryCurrentProcessPrivilege($name)
    Assert ($result.Name -ceq $name) 'Query must preserve the requested privilege name.'
    Assert ($result.Status -in @('Enabled', 'Disabled', 'NotAssigned', 'Failed')) 'Query must distinguish enabled, disabled, missing and failed states.'
    if ($result.Status -eq 'Failed') {
        Assert ($result.Win32Error -gt 0 -and -not $result.Succeeded) 'Failed query must return a real nonzero Win32 code, not success.'
        Assert ($result.Message.Contains(('Win32 ' + $result.Win32Error))) 'Failed query must include its Win32 code in diagnostics.'
    } else {
        Assert ($result.Win32Error -eq 0 -and $result.Succeeded) 'Completed read-only query must not invent a Win32 failure.'
        Assert ($result.Present -eq ($result.Status -ne 'NotAssigned')) 'Query presence must match returned status.'
        Assert ($result.Enabled -eq ($result.Status -eq 'Enabled')) 'Query enabled flag must match returned status.'
    }
    Write-Output ('TOKEN QUERY: ' + $result.Name + '=' + $result.Status + '; Win32=' + $result.Win32Error)
}
Write-Output 'PASS: real read-only own-token queries return structured privilege status.'

Assert ($null -ne [Arkuzo.MemorySaverNativeV1].GetMethod('EnableCurrentProcessPrivilege')) 'Best-effort own-token privilege enable API is missing.'
foreach ($name in @('SeDebugPrivilege', 'SeIncreaseWorkingSetPrivilege')) {
    $result = [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege($name)
    Assert ($result.Status -in @('Enabled', 'NotAssigned', 'Failed')) 'Enable must distinguish usable, unavailable and failed privileges.'
    if ($result.Succeeded) {
        Assert ($result.Enabled -and $result.Present -and $result.Win32Error -eq 0) 'Enable success must represent an actually enabled privilege.'
        Assert ($result.AdjustmentReturnedSuccess -eq $true) 'Successful enable must have called AdjustTokenPrivileges.'
        $verified = [Arkuzo.MemorySaverNativeV1]::QueryCurrentProcessPrivilege($name)
        Assert ($verified.Enabled) 'Successful enable must be observable in the real current token.'
    } else {
        Assert (-not $result.Enabled) 'Unavailable privilege must not claim enabled.'
        Assert ($result.Message.Contains(('Win32 ' + $result.Win32Error))) 'Enable failure must report its Win32 code.'
        if ($result.Status -eq 'NotAssigned') {
            Assert ($result.Win32Error -eq 1300 -and $result.Present -eq $false) 'Missing privilege must report ERROR_NOT_ALL_ASSIGNED (1300).'
        }
    }
    Write-Output ('TOKEN ENABLE: ' + $result.Name + '=' + $result.Status + '; nativeBool=' + $result.AdjustmentReturnedSuccess + '; Win32=' + $result.Win32Error)
}
# Request only an already-absent privilege: Windows cannot add it. Never remove a privilege to create a fixture.
$absent = $null
foreach ($name in @('SeTcbPrivilege', 'SeCreateTokenPrivilege', 'SeTrustedCredManAccessPrivilege', 'SeRelabelPrivilege')) {
    $query = [Arkuzo.MemorySaverNativeV1]::QueryCurrentProcessPrivilege($name)
    if ($query.Status -eq 'NotAssigned') { $absent = $name; break }
}
if ($null -ne $absent) {
    $missing = [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege($absent)
    Assert ($missing.AdjustmentReturnedSuccess -eq $true) 'Real absent-privilege adjustment should return native BOOL success.'
    Assert (-not $missing.Succeeded -and -not $missing.Enabled -and $missing.Status -eq 'NotAssigned' -and $missing.Win32Error -eq 1300) 'BOOL success plus ERROR_NOT_ALL_ASSIGNED must be returned as unavailable, not enabled.'
    Assert ($missing.Message -match 'cannot add') 'Unavailable privilege must explain that enabling cannot add it.'
    Write-Output ('TOKEN ABSENT: ' + $absent + '; nativeBool=True; Win32=1300; Succeeded=False')
} else { Write-Output 'SKIP: no absent privilege candidate in this token; no privilege was removed to force 1300.' }
Write-Output 'PASS: real own-token enable/readback and ERROR_NOT_ALL_ASSIGNED handling.'

$loadedFunctions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($name in @('Open-DiagnosticLog', 'Write-Diagnostic', 'Warn-Throttled', 'Write-ArkuzoNativePrivilegeStatus', 'Initialize-ArkuzoNativePrivileges')) {
    $definition = @($loadedFunctions | Where-Object { $_.Name -ceq $name })
    Assert ($definition.Count -eq 1) ($name + ' helper must exist exactly once.')
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$scratchRoot = $env:TMPDIR
if ([string]::IsNullOrWhiteSpace($scratchRoot)) { $scratchRoot = [IO.Path]::GetTempPath() }
$scratch = Join-Path $scratchRoot ('native-privileges-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $script:LogDirectory = $scratch; $script:MaxLogMB = 10; $script:sessionTag = 'native-privileges-test'
    $script:logWriter = $null; $script:logPath = ''; $script:logPart = 0; $script:logFailed = $false
    $script:warnings = @{}; $script:dashboardIssues = @{}; $script:clock = [Diagnostics.Stopwatch]::StartNew()
    if ($null -ne $absent) {
        # Use the real result above, not a fabricated unavailable-privilege response.
        $status = [pscustomobject]@{ attempted=$true; available=$false; reason='Completed'; privileges=@($missing) }
        Write-ArkuzoNativePrivilegeStatus $status
        $records = @(Get-Content -LiteralPath $script:logPath | ForEach-Object { $_ | ConvertFrom-Json })
        $diagnostic = @($records | Where-Object { $_.event -eq 'NATIVE_PRIVILEGES' })
        Assert ($diagnostic.Count -eq 1) 'Initialization status must reach the real JSON-line diagnostic log.'
        Assert ($diagnostic[0].data.privileges[0].Win32Error -eq 1300) 'Diagnostic must preserve the real unavailable privilege code.'
        $key = 'native-privilege-' + $absent
        Assert ($script:dashboardIssues.ContainsKey($key)) 'Unavailable privilege must reach the real Warn-Throttled dashboard issue map.'
        Assert ($script:dashboardIssues[$key].Message.Contains($absent) -and $script:dashboardIssues[$key].Message.Contains('Win32 1300')) 'Dashboard warning must name the unavailable privilege and error code.'
        Write-ArkuzoNativePrivilegeStatus $status
        $records = @(Get-Content -LiteralPath $script:logPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert (@($records | Where-Object { $_.event -eq 'WARNING' }).Count -eq 1) 'Unavailable-privilege warning must use existing 30-second throttling.'
        Write-Output 'PASS: real unavailable result reaches JSON diagnostics and throttled dashboard warning.'
    }
    $script:warnings = @{}; $script:dashboardIssues = @{}
    foreach ($gate in @(
        @{ monitor=$true; owns=$false; reason='MonitorOnly' },
        @{ monitor=$true; owns=$true; reason='MonitorOnly' },
        @{ monitor=$false; owns=$false; reason='ControllerMutexNotOwned' }
    )) {
        $script:MonitorOnly = $gate.monitor; $script:ownsControllerMutex = $gate.owns
        $status = Initialize-ArkuzoNativePrivileges
        Assert (-not $status.attempted -and $null -eq $status.available -and @($status.privileges).Count -eq 0) 'Monitor-only or non-owner initialization must not attempt native adjustment or claim privilege availability.'
        Assert ($status.reason -ceq $gate.reason) 'Skipped initialization must distinguish MonitorOnly from missing controller ownership.'
        Assert ($script:dashboardIssues.Count -eq 0) 'Intentionally skipped privileges must not produce unavailable-privilege warnings.'
    }
    # Exercise only this test process token. The production controller mutex is never opened/acquired by this suite.
    $script:MonitorOnly = $false; $script:ownsControllerMutex = $true
    $status = Initialize-ArkuzoNativePrivileges
    Assert ($status.attempted -and $status.reason -ceq 'Completed') 'Owned non-monitor controller must initialize privileges best-effort.'
    Assert (@($status.privileges).Count -eq 2) 'Initialization must return exactly two requested privilege results.'
    Assert (($status.privileges.Name -join ',') -ceq 'SeDebugPrivilege,SeIncreaseWorkingSetPrivilege') 'Initialization must request only the two intended privileges in a stable order.'
    Assert ($status.available -eq (@($status.privileges | Where-Object { -not $_.Succeeded -or -not $_.Enabled }).Count -eq 0)) 'Aggregate availability must reflect the real individual results.'
    Assert ([object]::ReferenceEquals($script:nativePrivilegeInitialization, $status)) 'Initialization result must be retained for diagnostics, not discarded.'
    $records = @(Get-Content -LiteralPath $script:logPath | ForEach-Object { $_ | ConvertFrom-Json })
    $latest = @($records | Where-Object { $_.event -eq 'NATIVE_PRIVILEGES' })[-1]
    Assert ($latest.data.attempted -and @($latest.data.privileges).Count -eq 2) 'Actual initialization result must reach JSON diagnostics.'
    Write-Output 'PASS: monitor-only/non-owner gates, owned-controller initialization, retained result and JSON diagnostics.'
} finally {
    if ($null -ne $script:logWriter) { $script:logWriter.Dispose(); $script:logWriter = $null }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}

$startup = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Initialize-ArkuzoNativePrivileges'
}, $true))
Assert ($startup.Count -eq 1) 'Engine startup must call native privilege initialization exactly once.'
$ancestor = $startup[0].Parent
while ($null -ne $ancestor -and $ancestor -isnot [Management.Automation.Language.IfStatementAst]) { $ancestor = $ancestor.Parent }
Assert ($null -ne $ancestor -and $ancestor.Clauses[0].Item1.Extent.Text -match '^\s*-not\s+\$MonitorOnly\s*$') 'Startup privilege initialization must be inside the non-monitor controller block.'
$wait = @($ancestor.FindAll({ param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -ceq 'WaitOne'
}, $true))
Assert ($wait.Count -eq 1 -and $wait[0].Extent.EndOffset -lt $startup[0].Extent.StartOffset) 'Startup must acquire the controller mutex before privilege initialization.'
$ownershipGate = @($ancestor.Clauses[0].Item2.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -match '^\s*-not\s+\$ownsControllerMutex\s*$' -and
    @($_.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true)).Count -gt 0
})
Assert ($ownershipGate.Count -eq 1 -and $ownershipGate[0].Extent.EndOffset -lt $startup[0].Extent.StartOffset) 'Startup must refuse non-ownership before enabling any privilege.'
Write-Output 'PASS: AST verifies startup initialization occurs only after mutex acquisition and ownership refusal in non-monitor mode.'

# Pure message formatting: do not access a protected/foreign process just to induce Access Denied.
$formatter = [Arkuzo.MemorySaverNativeV1].GetMethod('DescribeFailure', [Reflection.BindingFlags]'Static,NonPublic')
$denied = [string]$formatter.Invoke($null, @('EmptyWorkingSet', [int]5, 'Requires PROCESS_SET_QUOTA.'))
Assert ($denied -match 'EmptyWorkingSet.*Win32 5') 'Access Denied formatting must preserve the API name and numeric code.'
Assert ($denied -match 'Access denied' -and $denied -match 'protections.*still apply' -and $denied -match 'no automatic elevation') 'Access Denied diagnostic must explain rights/protections without requiring or promising elevation.'
Write-Output ('WIN32 FORMAT ONLY: ' + $denied)
Write-Output 'PASS: Access Denied 5 message is actionable without targeting another process.'

# Warm up interop before checking for a per-call token-handle leak, including the 1300 path.
foreach ($iteration in 1..8) {
    [Arkuzo.MemorySaverNativeV1]::QueryCurrentProcessPrivilege('SeDebugPrivilege') | Out-Null
    [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege('SeIncreaseWorkingSetPrivilege') | Out-Null
    if ($null -ne $absent) { [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege($absent) | Out-Null }
}
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
    $self.Handle | Out-Null
    $self.Refresh(); $before = $self.HandleCount
    foreach ($iteration in 1..64) {
        [Arkuzo.MemorySaverNativeV1]::QueryCurrentProcessPrivilege('SeDebugPrivilege') | Out-Null
        [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege('SeIncreaseWorkingSetPrivilege') | Out-Null
        if ($null -ne $absent) { [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege($absent) | Out-Null }
    }
    $self.Refresh(); $after = $self.HandleCount
    Assert ($after -le ($before + 2)) 'Repeated successful queries/enables and 1300 failures must not leak a token handle per call.'
    Write-Output ('PASS: token-handle disposal after repeated real calls; own process handles before=' + $before + ', after=' + $after + '.')
} finally { $self.Dispose() }

$definition = @($loadedFunctions | Where-Object { $_.Name -ceq 'Get-ArkuzoPresets' })
Assert ($definition.Count -eq 1) 'Preset defaults must remain discoverable.'
. ([scriptblock]::Create($definition[0].Extent.Text))
foreach ($preset in (Get-ArkuzoPresets).Values) {
    Assert ($preset.hard_limit -is [bool] -and -not $preset.hard_limit) 'Native privilege initialization must not enable hard limits in any default preset.'
}
$soft = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'SoftLimit' })
$hard = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'HardLimit' })
Assert ($soft.Count -eq 1 -and $soft[0].DefaultValue.SafeGetValue() -eq $true) 'SoftLimit must remain the CLI default.'
Assert ($hard.Count -eq 1 -and $null -eq $hard[0].DefaultValue) 'HardLimit must remain opt-in.'
Write-Output 'PASS: all presets and CLI retain advisory soft targets; hard working-set limits remain opt-in.'

foreach ($windowOperation in @('ShowWindowAsync', 'IsIconic')) {
    $failure = $null
    try {
        if ($windowOperation -eq 'ShowWindowAsync') { [Arkuzo.MemorySaverNativeV1]::ShowWindowAsync([IntPtr]::Zero, 6) | Out-Null }
        else { [Arkuzo.MemorySaverNativeV1]::IsIconic([IntPtr]::Zero) | Out-Null }
    } catch {
        $failure = $_.Exception
        while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
    }
    Assert ($failure -is [ComponentModel.Win32Exception] -and $failure.NativeErrorCode -eq 1400) ($windowOperation + ' must report real ERROR_INVALID_WINDOW_HANDLE (1400), not silently fail or use a stale token error.')
    Assert ($failure.Message.Contains($windowOperation) -and $failure.Message.Contains('Win32 1400')) ($windowOperation + ' failure must include its API name and reported numeric code.')
}
Write-Output 'PASS: invalid HWND calls report API names and Win32 1400; no valid windows touched.'
