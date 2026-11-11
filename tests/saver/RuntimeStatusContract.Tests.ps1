#requires -Version 5.1
# The writer side of contracts/runtime-status.json: the heartbeat the engine writes
# has exactly the documented keys, a schemaVersion, and one shape for every client
# row, whichever part of the engine sampled that client last.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$contract = [IO.File]::ReadAllText((Join-Path $root 'contracts/runtime-status.json')) | ConvertFrom-Json
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
$script:warned = New-Object Collections.ArrayList
function Write-Diagnostic($kind, $data) { }
function Warn-Throttled($key, $message) { [void]$script:warned.Add("$key|$message") }
function Same($actual, $expected) { return ((@($actual | Sort-Object) -join ',') -ceq (@($expected | Sort-Object) -join ',')) }
function Keys($object) { return @($object.PSObject.Properties | ForEach-Object { $_.Name }) }

$DataDirectory = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-contract-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
try {
    $ArkuzoRuntimeVersion = '9.9.9'; $MonitorOnly = $false; $ownsControllerMutex = $true
    $script:controllerStartTicks = 638000000000000000
    $script:accountProvider = 'arkuzo'; $script:accountProviderNotice = $null
    $healthPolicy = Get-ArkuzoHealthPolicy $null; $restorePolicy = Get-ArkuzoRestorePolicy $null
    $pagefilePolicy = @{ enabled = $false }; $systemMemory = @{ commitPercent = 41.5; availablePhysicalMB = 8000 }
    $recoveryPending = @{}; $script:recoveryPending = $recoveryPending; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
    $recoveryJournalHealthy = $true; $logFailed = $false
    $voltControlCheckedUtc = [datetime]::UtcNow
    $voltControlStatus = [pscustomobject]@{ available = $true; farmRunning = $true; accounts = @(
        [pscustomobject]@{ accountId = '11111111-1111-1111-1111-111111111111'; username = 'alpha'; displayName = 'alpha'; trackerId = '1000000001'; userId = '1'
            autoRelaunch = $true; cookieAlive = $true; cookieStatus = 'alive'; suspensionSafe = $false; lastLaunchAtMs = 1; uiStatus = 'Connected'; processId = 101; controlReady = $true }) }
    $script:Mode = 'agressive'; $script:MaxRamMB = 600; $script:EnableTrimming = $true; $script:TrimEverySec = 45; $script:AdaptiveTrim = $true
    $script:Priority = 'BelowNormal'; $script:MemoryPriority = 'Low'; $script:CoresPerInstance = 2; $script:SoftLimit = $true; $script:isConfigLocked = $true
    $script:trimCount = 3; $script:lastTotals = @{ detected = 3; managed = 3 }; $script:totalPhysicalMB = 32000
    $script:dashboardIssues = @{ 'restore-x' = @{ Message = 'note'; Time = 1.0 } }

    # 1: a full main-loop sample. 2: the same, then patched by the observation service
    # (raw values, UTC time, an extra key). 3: only ever seen by the observation service.
    $full = [ordered]@{ pid = 101; startTicks = [long]900; cpuPercent = 1.25; residentMB = 612.4; privateMB = 2100.7; responding = $true; windowPresent = $true; launchError = $false
        state = 'WINDOW OPEN'; sampleTime = (Get-Date).ToString('o'); eligible = $true; isDisconnected = $false; parentId = 7; account = 'alpha'; slot = 0; ageSec = 300.0
        nextTrim = '12s'; gameReady = $true; disconnectReason = $null; memoryPriority = 'Low' }
    $patched = [ordered]@{}; foreach ($key in $full.Keys) { $patched[$key] = $full[$key] }
    $patched.pid = 102; $patched.privateMB = 2100.123456789; $patched.ageSec = 301.987654; $patched.systemCommitPercent = 41.5
    $patched.sampleTime = [datetime]::UtcNow.ToString('o'); $patched.state = ''
    $partial = @{ pid = 103; privateMB = 1500.55555; ageSec = 12.3456; responding = $false; windowPresent = $false; launchError = $false; isDisconnected = $false
        systemCommitPercent = 41.5; eligible = $false; state = ''; sampleTime = [datetime]::UtcNow.ToString('o') }
    $tracked = @{
        101 = @{ StartTicks = [long]900; Slot = 0; ParentId = 7; GameReady = $true; DisconnectReason = $null; LastSnapshot = $full }
        102 = @{ StartTicks = [long]901; Slot = 1; ParentId = 7; GameReady = $true; DisconnectReason = $null; LastSnapshot = $patched }
        103 = @{ StartTicks = [long]902; Slot = 2; ParentId = 8; GameReady = $false; DisconnectReason = $null; LastSnapshot = $partial }
        104 = @{ StartTicks = [long]903; Slot = 3; ParentId = 8; GameReady = $false; DisconnectReason = $null; LastSnapshot = $null }
    }
    $script:tracked = $tracked

    Write-ArkuzoRuntimeStatus
    Assert ($script:warned.Count -eq 0) ('the heartbeat was written without a warning: ' + ($script:warned -join '; '))
    $raw = [IO.File]::ReadAllText((Join-Path $DataDirectory 'runtime-status.json'))
    $status = $raw | ConvertFrom-Json

    Assert ($status.schemaVersion -is [int] -and $status.schemaVersion -eq [int]$contract.schemaVersion) 'schemaVersion matches the contract'
    Assert (Same (Keys $status) $contract.topLevel) ('top-level keys match the contract; got: ' + ((Keys $status | Sort-Object) -join ','))
    Assert (Same (Keys $status.settings) $contract.settings) 'settings keys match the contract'
    Assert (@($status.accounts).Count -eq 1 -and (Same (Keys $status.accounts[0]) $contract.account)) 'account keys match the contract'
    Assert ($status.version -ceq '9.9.9' -and $status.pid -eq $PID -and $status.controller -eq $true -and $status.monitorOnly -eq $false) 'identity fields are kept'

    $clients = @($status.clients)
    Assert ($clients.Count -eq 3) 'a client without any sample is left out; the other three are listed'
    foreach ($c in $clients) { Assert (Same (Keys $c) $contract.client) ("client $($c.pid) has exactly the contract keys; got: " + ((Keys $c | Sort-Object) -join ',')) }
    foreach ($c in $clients) {
        Assert ($c.pid -is [int] -and $c.startTicks -gt 0 -and $c.slot -is [int]) "client $($c.pid): pid, start time and slot are always numbers"
        Assert ([string]$c.sampleTime -match '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z') "client $($c.pid): sampleTime is UTC"
        Assert ($c.responding -is [bool] -and $c.windowPresent -is [bool] -and $c.launchError -is [bool] -and $c.isDisconnected -is [bool] -and $c.gameReady -is [bool]) "client $($c.pid): flags are booleans"
    }
    $byPid = @{}; foreach ($c in $clients) { $byPid[[int]$c.pid] = $c }
    Assert ($byPid[101].cpuPercent -eq 1.25 -and $byPid[101].residentMB -eq 612.4 -and $byPid[101].privateMB -eq 2100.7 -and $byPid[101].account -ceq 'alpha' -and $byPid[101].nextTrim -ceq '12s') 'a full sample passes through unchanged'
    Assert ($byPid[102].privateMB -eq 2100.1 -and $byPid[102].ageSec -eq 302 -and $byPid[102].startTicks -eq 900) 'values patched by the observation service are rounded like the rest'
    Assert ($byPid[103].startTicks -eq 902 -and $byPid[103].slot -eq 2 -and $byPid[103].parentId -eq 8 -and $byPid[103].privateMB -eq 1500.6 -and
        $null -eq $byPid[103].cpuPercent -and $null -eq $byPid[103].account -and $byPid[103].gameReady -eq $false) 'a client only the observation service has seen still has every key (identity from its state, unknowns null)'
    Assert ($raw -notmatch 'systemCommitPercent"\s*:\s*41\.5\s*,\s*"eligible') 'the observation sample''s own keys do not leak into client rows'

    # The reader that must never misfire: instant close needs pid + startTicks per client and accountId + processId per account.
    foreach ($key in $contract.readers.instantClose.client) { Assert ($contract.client -contains $key) "instant close reads client.$key" }
    foreach ($key in $contract.readers.instantClose.account) { Assert ($contract.account -contains $key) "instant close reads account.$key" }
    foreach ($key in @($contract.readers.supervisor) + @($contract.readers.launcherTakeover) + @($contract.readers.controlCenterState) + @($contract.readers.instantClose.topLevel)) {
        Assert ($contract.topLevel -contains $key) "reader key $key is a documented top-level key"
    }

    # The main loop's own record is built from the same key list.
    $literal = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$state.LastSnapshot' -and $n.Right.Extent.Text -like '`[ordered`]@{*' }, $true))
    Assert ($literal.Count -eq 1) 'the main loop builds one client record'
    $hash = @($literal[0].Right.FindAll({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $false))[0]
    Assert (Same @($hash.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) $contract.client) 'the main-loop client record has exactly the contract keys'

    # Monitor-only never writes a heartbeat (it would look like a controller).
    Remove-Item -LiteralPath (Join-Path $DataDirectory 'runtime-status.json') -Force
    $MonitorOnly = $true; Write-ArkuzoRuntimeStatus; $MonitorOnly = $false
    Assert (-not (Test-Path -LiteralPath (Join-Path $DataDirectory 'runtime-status.json'))) 'monitor-only writes no heartbeat'
} finally { Remove-Item -LiteralPath $DataDirectory -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output "PASS: $script:checks heartbeat contract checks (schemaVersion, exact keys, one client shape)"
