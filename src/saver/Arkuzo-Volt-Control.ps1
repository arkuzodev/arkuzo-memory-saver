#requires -Version 5.1
<# Secret-free Volt UI Automation adapter. Status is read-only.
   Recovery orchestration, retry journals and budgets belong to the caller.
   Never infer an account from a slot, replay a command line, or expose cookies. #>
[CmdletBinding()]
param(
    [string]$Action = 'Status',
    [string]$AccountId,
    [string]$ExpectedTrackerId,
    [int]$RelaunchDelaySec = 30,
    [int]$MinLaunchAgeSec = 90
)

function Get-VoltTrackerId([string]$CommandLine) {
    # Local parsing only: the raw authenticated launch command never leaves this function.
    if ([string]::IsNullOrEmpty($CommandLine) -or [regex]::Matches($CommandLine,'(?i)browsertrackerid').Count -ne 1) { return $null }
    $tokens=[regex]::Matches($CommandLine,'(?i)(?<![a-z0-9_])browsertrackerid(?::|=|%3A)([0-9]+)(?=$|[\s+&"'']|%2b|%26|%20|%22)')
    if ($tokens.Count -ne 1) { return $null }
    return $tokens[0].Groups[1].Value
}

function New-VoltUnavailableStatus([string]$Reason) {
    return [pscustomobject]@{available=$false;globalMappingSafe=$false;managerId=$null;managerStartTicks=$null;relaunchDelayMs=$null;accounts=@();reason=$Reason}
}

function Get-VoltUiBinding($Accounts, $Nodes, [int]$ManagerId, [int[]]$UiProcessIds=@()) {
    $bad=[pscustomobject]@{valid=$false;reason='Volt Account Manager UI is unknown or ambiguous';rows=@();delayNode=$null;delaySec=$null}
    $allowed=@($ManagerId)+@($UiProcessIds)
    $labels=@($Nodes | Where-Object { $_.kind -ceq 'Text' -and $_.name.StartsWith('@') })
    if ($labels.Count -ne @($Accounts).Count -or @($labels | Where-Object { $_.name -cnotin @($Accounts | ForEach-Object { '@'+$_.username }) }).Count -gt 0) { return $bad }
    if (@($Nodes | Where-Object { [int]$_.processId -notin $allowed }).Count -gt 0) { return $bad }
    $editors=@($Nodes | Where-Object { $_.name -ceq 'Relaunch delay in seconds' -and $_.kind -eq 'Edit' })
    if ($editors.Count -ne 1 -or -not $editors[0].valueWritable -or $editors[0].value -notmatch '\A[0-9]+\z') { return $bad }
    $rows=@()
    foreach ($a in @($Accounts)) {
        $labels=@(for($i=0;$i -lt $Nodes.Count;$i++) { if ($Nodes[$i].name -ceq ('@'+$a.username) -and $Nodes[$i].kind -eq 'Text') { $i } })
        $actionName='Relaunch '+$a.displayName+' immediately'
        $buttons=@($Nodes | Where-Object { $_.name -ceq $actionName -and $_.kind -eq 'Button' })
        if ($labels.Count -ne 1 -or $buttons.Count -ne 1) { return $bad }
        $segment=@()
        for($i=$labels[0]+1;$i -lt $Nodes.Count;$i++) {
            $n=$Nodes[$i]
            if (($n.kind -eq 'Text' -and $n.name.StartsWith('@')) -or ($n.kind -eq 'CheckBox' -and $n.name -match '\ASelect(?:\s|\z)')) { break }
            $segment += $n
        }
        $scoped=@($segment | Where-Object { $_.name -ceq $actionName -and $_.kind -eq 'Button' })
        if ($scoped.Count -ne 1) { return $bad }
        $sockets=@($segment | Where-Object { $_.kind -eq 'Group' -and $_.name -match '\ASocket connected to Roblox process PID [0-9]+\z' })
        $connected=@($segment | Where-Object { $_.kind -eq 'Text' -and $_.name -ceq 'Connected' })
        $idle=@($segment | Where-Object { $_.kind -eq 'Text' -and $_.name -ceq 'Idle' })
        $noSocket=@($segment | Where-Object { $_.kind -eq 'Group' -and $_.name -ceq 'No connected Roblox socket' })
        $noMemory=@($segment | Where-Object { $_.name -ceq 'Memory: No active process' })
        $socketId=$null; $state='Unknown'
        if ($sockets.Count -eq 1 -and $connected.Count -eq 1 -and $idle.Count -eq 0 -and $noSocket.Count -eq 0) {
            $socketId=[int]([regex]::Match($sockets[0].name,'[0-9]+\z').Value); $state='Connected'
        } elseif ($sockets.Count -eq 0 -and $connected.Count -eq 0 -and $idle.Count -eq 1 -and $noSocket.Count -eq 1 -and $noMemory.Count -eq 1) { $state='Idle' }
        $rows += [pscustomobject]@{accountId=$a.accountId;uiStatus=$state;socketId=$socketId;button=$scoped[0]}
    }
    return [pscustomobject]@{valid=$true;reason='Exact Account Manager controls';rows=$rows;delayNode=$editors[0];delaySec=[long]$editors[0].value}
}

function New-VoltControlContext($Inventory, $Managers, $Nodes, $Processes, [string]$ExpectedPath, [int[]]$UiProcessIds=@()) {
    $status=New-VoltUnavailableStatus 'Volt manager or inventory unavailable'
    $context=[pscustomobject]@{Status=$status;Inventory=$Inventory;Manager=$null;Ui=$null;Processes=@($Processes)}
    $managers=@($Managers)
    if (-not $Inventory.available -or $managers.Count -ne 1) { return $context }
    $sourceAccounts=@($Inventory.accounts)
    if ($sourceAccounts.Count -eq 0) { $status.reason='Volt inventory is empty'; return $context }
    foreach($field in @('accountId','username','displayName','trackerId')) {
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($a in $sourceAccounts) {
            $value=$a.$field
            if ($field -eq 'trackerId' -and $null -eq $value) { continue }
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n\x00]' -or -not $seen.Add($value)) { $status.reason='Volt account identity is malformed or ambiguous'; return $context }
            if (($field -eq 'accountId' -and $value -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') -or ($field -eq 'trackerId' -and $value -notmatch '\A[0-9]+\z')) { return $context }
        }
    }
    foreach($a in $sourceAccounts) {
        $launch=$a.lastLaunchAtMs
        if ($null -ne $launch -and (($launch -isnot [int] -and $launch -isnot [long] -and $launch -isnot [double] -and $launch -isnot [decimal]) -or [double]::IsNaN([double]$launch) -or [double]::IsInfinity([double]$launch) -or $launch -lt 0)) { $status.reason='Volt launch history is malformed'; return $context }
    }
    $manager=$managers[0]
    if (-not $manager.identityStable -or -not [string]::Equals($manager.path,$ExpectedPath,[StringComparison]::OrdinalIgnoreCase) -or $manager.startTicks -le 0 -or $manager.windowHandle -eq 0) { return $context }
    $ui=Get-VoltUiBinding -Accounts $Inventory.accounts -Nodes @($Nodes) -ManagerId $manager.processId -UiProcessIds $UiProcessIds
    $context.Manager=$manager; $context.Ui=$ui
    if (-not $ui.valid) { $status.reason=$ui.reason; return $context }
    $globallyMapped=@($ui.rows | Where-Object { $_.uiStatus -ceq 'Unknown' }).Count -eq 0
    $seenLiveTrackers=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenLivePids=New-Object 'Collections.Generic.HashSet[int]'
    foreach($p in @($Processes)) {
        if ($p.trackerId -isnot [string] -or $p.trackerId -notmatch '\A[0-9]+\z' -or -not $seenLiveTrackers.Add($p.trackerId) -or -not $seenLivePids.Add([int]$p.processId) -or $p.processId -le 0 -or -not $p.identityStable -or -not $p.ownerStable -or $p.startTicks -le 0 -or [int]$p.parentProcessId -ne [int]$manager.processId -or $p.parentStartTicks -ne $manager.startTicks -or @($sourceAccounts | Where-Object { $_.trackerId -ceq $p.trackerId }).Count -ne 1) { $globallyMapped=$false }
    }
    # Validate both directions: every live client owns exactly one UI row,
    # and every connected row has that exact verified live socket process.
    foreach($a in $sourceAccounts) {
        $row=@($ui.rows | Where-Object { $_.accountId -ceq $a.accountId })
        $live=@($Processes | Where-Object { $null -ne $a.trackerId -and $_.trackerId -ceq $a.trackerId })
        if ($row.Count -ne 1) { $globallyMapped=$false; continue }
        if ($row[0].uiStatus -ceq 'Connected') {
            if ($live.Count -ne 1 -or $row[0].socketId -ne $live[0].processId) { $globallyMapped=$false }
        } elseif ($row[0].uiStatus -ceq 'Idle') {
            if ($live.Count -ne 0) { $globallyMapped=$false }
        } else { $globallyMapped=$false }
    }
    $accounts=@()
    foreach($a in @($Inventory.accounts)) {
        $row=@($ui.rows | Where-Object { $_.accountId -ceq $a.accountId })[0]
        $live=@($Processes | Where-Object { $null -ne $a.trackerId -and $_.trackerId -ceq $a.trackerId })
        $cookieStatus='unknown'
        if ($a.cookieStatus -ceq 'alive' -or $a.cookieStatus -ceq 'dead') { $cookieStatus=$a.cookieStatus }
        $lastLaunch=$a.lastLaunchAtMs
        if ($null -eq $lastLaunch) { $lastLaunch=0 }
        $ready=$globallyMapped -and $Inventory.autoEnabled -and $a.autoRelaunch -and $cookieStatus -ceq 'alive' -and $null -ne $a.trackerId -and $lastLaunch -gt 0 -and $row.button.enabled -and $row.button.invokable
        $processId=$null
        if ($row.uiStatus -eq 'Connected') {
            $ready=$ready -and $live.Count -eq 1
            if ($live.Count -eq 1) {
                $p=$live[0]; $processId=$p.processId
                $ready=$ready -and $row.socketId -eq $p.processId -and $p.identityStable -and $p.startTicks -gt 0 -and $p.ownerStable -and [int]$p.parentProcessId -eq [int]$manager.processId -and $p.parentStartTicks -eq $manager.startTicks
            }
        } elseif($row.uiStatus -eq 'Idle') { $ready=$ready -and $live.Count -eq 0 }
        else { $ready=$false }
        $suspensionSafe=$cookieStatus -ceq 'dead' -and $row.uiStatus -ceq 'Idle' -and $live.Count -eq 0 -and $globallyMapped
        $accounts += [pscustomobject]@{accountId=$a.accountId;username=$a.username;displayName=$a.displayName;trackerId=$a.trackerId;autoRelaunch=[bool]$a.autoRelaunch;cookieAlive=($cookieStatus -ceq 'alive');cookieStatus=$cookieStatus;suspensionSafe=[bool]$suspensionSafe;lastLaunchAtMs=$lastLaunch;uiStatus=$row.uiStatus;processId=$processId;controlReady=[bool]$ready}
    }
    $context.Status=[pscustomobject]@{available=$true;globalMappingSafe=[bool]$globallyMapped;managerId=[int]$manager.processId;managerStartTicks=[long]$manager.startTicks;relaunchDelayMs=$Inventory.relaunchDelayMs;accounts=$accounts;reason='Exact Volt manager and account controls observed'}
    return $context
}

function Test-VoltControlRevalidation($Original, $Fresh) {
    try {
        if (-not $Original.Status.available -or -not $Fresh.Status.available -or $Original.Status.managerId -ne $Fresh.Status.managerId -or $Original.Status.managerStartTicks -ne $Fresh.Status.managerStartTicks -or $Original.Manager.windowHandle -ne $Fresh.Manager.windowHandle -or $Original.Ui.delaySec -ne $Fresh.Ui.delaySec) { return $false }
        if (($Original.Inventory | ConvertTo-Json -Depth 10 -Compress) -cne ($Fresh.Inventory | ConvertTo-Json -Depth 10 -Compress) -or ($Original.Status.accounts | ConvertTo-Json -Depth 10 -Compress) -cne ($Fresh.Status.accounts | ConvertTo-Json -Depth 10 -Compress) -or (@($Original.Processes | Sort-Object processId) | ConvertTo-Json -Depth 10 -Compress) -cne (@($Fresh.Processes | Sort-Object processId) | ConvertTo-Json -Depth 10 -Compress)) { return $false }
        foreach($row in @($Original.Ui.rows)) {
            $match=@($Fresh.Ui.rows | Where-Object { $_.accountId -ceq $row.accountId })
            if ($match.Count -ne 1 -or $match[0].uiStatus -cne $row.uiStatus -or $match[0].socketId -ne $row.socketId -or $match[0].button.name -cne $row.button.name -or $match[0].button.processId -ne $row.button.processId -or $match[0].button.enabled -ne $row.button.enabled -or $match[0].button.invokable -ne $row.button.invokable) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-VoltMissingLaunch($Context, [string]$AccountId, [string]$ExpectedTrackerId, [double]$NowMs, [int]$MinLaunchAgeSec=90) {
    if (-not $Context.Status.available -or $Context.Status.globalMappingSafe -isnot [bool] -or -not $Context.Status.globalMappingSafe -or $AccountId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or $ExpectedTrackerId -notmatch '\A[0-9]+\z') { return $false }
    if ($MinLaunchAgeSec -lt 90 -or $MinLaunchAgeSec -gt 3600 -or [double]::IsNaN($NowMs) -or [double]::IsInfinity($NowMs)) { return $false }
    $seenTrackers=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenPids=New-Object 'Collections.Generic.HashSet[int]'
    foreach($p in @($Context.Processes)) {
        if ($p.trackerId -isnot [string] -or $p.trackerId -notmatch '\A[0-9]+\z' -or -not $seenTrackers.Add($p.trackerId) -or -not $seenPids.Add([int]$p.processId) -or -not $p.identityStable -or -not $p.ownerStable -or $p.startTicks -le 0 -or [int]$p.parentProcessId -ne $Context.Status.managerId -or $p.parentStartTicks -ne $Context.Status.managerStartTicks) { return $false }
        if (@($Context.Inventory.accounts | Where-Object { $_.trackerId -ceq $p.trackerId }).Count -ne 1) { return $false }
    }
    $target=@($Context.Status.accounts | Where-Object { $_.accountId -ceq $AccountId })
    if ($target.Count -ne 1) { return $false }
    if ($target[0].cookieStatus -ceq 'dead' -or $target[0].cookieStatus -cne 'alive' -or -not $target[0].cookieAlive) { return $false }
    return ($target[0].trackerId -ceq $ExpectedTrackerId -and $target[0].controlReady -and $target[0].uiStatus -ceq 'Idle' -and $target[0].lastLaunchAtMs -gt 0 -and $NowMs - $target[0].lastLaunchAtMs -ge ($MinLaunchAgeSec*1000))
}

function Invoke-VoltControlAction([string]$Action, [hashtable]$Facade, [string]$AccountId, [string]$ExpectedTrackerId, [int]$RelaunchDelaySec=30, [int]$MinLaunchAgeSec=90) {
    if ($Action -ceq 'CleanDeadCookies') {
        $probeScript = Join-Path $PSScriptRoot "Arkuzo-Volt-Probe.py"
        if (-not (Test-Path $probeScript)) {
            $probeScript = Join-Path (Split-Path -Parent $PSScriptRoot) "saver\Arkuzo-Volt-Probe.py"
        }
        $out = & python -B $probeScript --clean-dead-cookies 2>$null
        try {
            return ($out | ConvertFrom-Json)
        } catch {
            return [pscustomobject]@{ status = 'ERROR'; reason = 'Probe execution failed'; removedCount = 0; removed = @() }
        }
    }
    $context=& $Facade.Read $Facade.Root
    if ($Action -ceq 'Status') {
        if (-not $context.Status.available) { return $context.Status }
        $fresh=& $Facade.Read $Facade.Root
        if (-not (Test-VoltControlRevalidation $context $fresh)) { return New-VoltUnavailableStatus 'Volt read-only snapshots changed' }
        return $fresh.Status
    }
    if ($Action -ceq 'Configure') {
        $result=$context.Status; $result | Add-Member configured $false -Force
        if (-not $result.available -or $RelaunchDelaySec -lt 30 -or $RelaunchDelaySec -gt 3600) { $result.reason='Delay configuration blocked'; return $result }
        $fresh=& $Facade.Read $Facade.Root
        if (-not $fresh.Status.available -or $fresh.Status.managerId -ne $result.managerId -or $fresh.Status.managerStartTicks -ne $result.managerStartTicks -or -not (Test-VoltControlRevalidation $context $fresh) -or -not (& $Facade.Verify $fresh)) { $result.reason='Volt identity changed before configuration'; return $result }
        if ($fresh.Ui.delaySec -lt $RelaunchDelaySec) { $null=& $Facade.SetDelay $fresh $RelaunchDelaySec }
        for($i=0;$i -lt 5;$i++) {
            $observed=& $Facade.Read $Facade.Root
            if ($observed.Status.available -and $observed.Status.managerId -eq $result.managerId -and $observed.Status.managerStartTicks -eq $result.managerStartTicks -and $observed.Ui.delaySec -ge $RelaunchDelaySec -and $observed.Inventory.relaunchDelayMs -ge ($RelaunchDelaySec*1000) -and $observed.Ui.delaySec*1000 -eq $observed.Inventory.relaunchDelayMs) {
                $verified=$observed.Status; $verified | Add-Member configured $true -Force; $verified.reason='Delay verified in UI and read-only persisted state'; return $verified
            }
            if ($i -lt 4) { $null=& $Facade.Wait }
        }
        $result.reason='Delay persistence was not verified'; return $result
    }
    if ($Action -ceq 'LaunchMissing') {
        $result=$context.Status; $result | Add-Member requestAccepted $false -Force
        $targetAcct=@($context.Status.accounts | Where-Object { $_.accountId -ceq $AccountId })
        if ($targetAcct.Count -eq 1 -and ($targetAcct[0].cookieStatus -ceq 'dead' -or $targetAcct[0].cookieStatus -cne 'alive' -or -not $targetAcct[0].cookieAlive)) {
            $result.reason='Refused in any circumstance: account cookie is dead or not alive'
            return $result
        }
        if (-not (Test-VoltMissingLaunch $context $AccountId $ExpectedTrackerId (& $Facade.Now) $MinLaunchAgeSec)) { $result.reason='Missing account launch safety checks failed'; return $result }
        $fresh=& $Facade.Read $Facade.Root
        if ($fresh.Status.managerId -ne $result.managerId -or $fresh.Status.managerStartTicks -ne $result.managerStartTicks -or -not (Test-VoltMissingLaunch $fresh $AccountId $ExpectedTrackerId (& $Facade.Now) $MinLaunchAgeSec) -or -not (Test-VoltControlRevalidation $context $fresh) -or -not (& $Facade.Verify $fresh)) { $result.reason='Account or process identity changed before launch'; return $result }
        $row=@($fresh.Ui.rows | Where-Object { $_.accountId -ceq $AccountId })[0]
        $null=& $Facade.Invoke $fresh $row
        # InvokePattern acceptance is not proof of a new process or game readiness.
        $observed=& $Facade.Read $Facade.Root
        $result=$observed.Status; $result | Add-Member requestAccepted $true -Force; $result | Add-Member accountId $AccountId -Force
        $result.reason='Account launch requested; caller must verify replacement and game readiness'
        return $result
    }
    return New-VoltUnavailableStatus 'Unsupported Volt action'
}

function Get-VoltInventory([string]$Root) {
    $child=$null
    try {
        $probe=Join-Path $Root 'Arkuzo-Volt-Probe.py'
        if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw 'missing' }
        $python=Get-Command python3.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $python) { $python=Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$python.Source; $info.Arguments='-B "'+$probe+'" --inventory'
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
        $info.EnvironmentVariables['PYTHONUTF8']='1'
        $child=[Diagnostics.Process]::Start($info)
        $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(3000)) { $child.Kill(); throw 'timeout' }
        if ($child.ExitCode -ne 0 -or $stdout.Result.Length -gt 1048576 -or $stderr.Result.Length -gt 0) { throw 'failed' }
        $value=$stdout.Result | ConvertFrom-Json
        if ($value.available -isnot [bool] -or $value.safeToRecycle -isnot [bool] -or $value.autoEnabled -isnot [bool]) { throw 'invalid' }
        return $value
    } catch { return [pscustomobject]@{available=$false;accounts=@();reason='Volt inventory or Python unavailable'} }
    finally { if ($null -ne $child) { $child.Dispose() } }
}

function Close-VoltRetainedProcesses {
    if ($null -ne $script:VoltRetained) { foreach($record in @($script:VoltRetained.Values)) { try { $record.Process.Dispose() } catch {} } }
    $script:VoltRetained=@{}
}

function Test-VoltRetainedProcess($Record) {
    try {
        if ($null -eq $Record -or $Record.Handle -isnot [IntPtr] -or $Record.Handle -eq [IntPtr]::Zero) { return $false }
        $p=$Record.Process; $p.Refresh()
        return ($p.HasExited -is [bool] -and -not $p.HasExited -and $p.Id -eq $Record.processId -and $p.StartTime.ToUniversalTime().Ticks -eq $Record.startTicks -and [string]::Equals($p.Path,$Record.path,[StringComparison]::OrdinalIgnoreCase))
    } catch { return $false }
}

function Get-VoltRetainedProcess([int]$ProcessId, $CimRecord=$null) {
    if ($script:VoltRetained.ContainsKey($ProcessId)) {
        $retained=$script:VoltRetained[$ProcessId]
        if (-not (Test-VoltRetainedProcess $retained)) { throw 'identity changed' }
        return $retained
    }
    $p=$null
    try {
        $p=[Diagnostics.Process]::GetProcessById($ProcessId); $handle=$p.Handle; $p.Refresh()
        $record=[pscustomobject]@{processId=$p.Id;startTicks=$p.StartTime.ToUniversalTime().Ticks;path=$p.Path;Handle=$handle;Process=$p}
        if (-not (Test-VoltRetainedProcess $record)) { throw 'identity unavailable' }
        # CIM DMTF timestamps may truncate sub-microsecond FILETIME precision.
        if ($null -ne $CimRecord -and ($CimRecord.CreationDate -isnot [datetime] -or [math]::Abs($CimRecord.CreationDate.ToUniversalTime().Ticks-$record.startTicks) -gt 10)) { throw 'snapshot generation changed' }
        $script:VoltRetained[$ProcessId]=$record; return $record
    } catch { if ($null -ne $p) { $p.Dispose() }; throw 'Process identity unavailable' }
}

function Get-VoltProcessRecords {
    $records=@{}
    foreach($p in @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CreationDate -ErrorAction Stop)) { $records[[int]$p.ProcessId]=$p }
    return $records
}

function Get-VoltRobloxSnapshot($Records, $Manager) {
    $result=@()
    $clients=@(Get-CimInstance Win32_Process -Filter "Name='RobloxPlayerBeta.exe'" -Property ProcessId,ParentProcessId,CreationDate,CommandLine -ErrorAction Stop)
    $knownIds=@($Records.Values | Where-Object { $_.Name -ceq 'RobloxPlayerBeta.exe' } | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
    $nowIds=@($clients | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
    if (($knownIds -join ',') -cne ($nowIds -join ',')) { throw 'Client set changed' }
    foreach($client in $clients) {
        # Project immediately. Never return the CIM object or its CommandLine.
        $id=[int]$client.ProcessId; $parentId=[int]$client.ParentProcessId
        $tracker=Get-VoltTrackerId $client.CommandLine
        $stable=$false; $owner=$false; $ticks=[long]0; $parentTicks=[long]0
        try {
            $p=Get-VoltRetainedProcess $id $client; $ticks=$p.startTicks; $stable=$true
            if ($parentId -eq $Manager.processId -and $Records.ContainsKey($parentId)) {
                $parent=Get-VoltRetainedProcess $parentId $Records[$parentId]; $parentTicks=$parent.startTicks
                $owner=(Test-VoltRetainedProcess $parent) -and $parent.startTicks -eq $Manager.startTicks -and [string]::Equals($parent.path,$Manager.path,[StringComparison]::OrdinalIgnoreCase)
            }
        } catch {}
        $result += [pscustomobject]@{processId=$id;startTicks=$ticks;trackerId=$tracker;parentProcessId=$parentId;parentStartTicks=$parentTicks;identityStable=[bool]$stable;ownerStable=[bool]$owner}
    }
    return ,$result
}

function Get-VoltUiNodes($Manager, $Records) {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $root=[Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Manager.windowHandle)
    if ($root.Current.ProcessId -ne $Manager.processId) { throw 'Foreign UI root' }
    $elements=$root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    $nodes=@(); $uiIds=New-Object 'Collections.Generic.HashSet[int]'
    [void]$uiIds.Add([int]$Manager.processId)
    foreach($element in $elements) {
        $current=$element.Current; $provider=[int]$current.ProcessId
        if (-not $uiIds.Contains($provider)) {
            $walk=$provider; $seen=New-Object 'Collections.Generic.HashSet[int]'
            for($depth=0;$walk -ne $Manager.processId -and $depth -lt 16;$depth++) {
                if (-not $seen.Add($walk) -or -not $Records.ContainsKey($walk) -or $Records[$walk].Name -cne 'msedgewebview2.exe') { throw 'UI provider owner unavailable' }
                $child=Get-VoltRetainedProcess $walk $Records[$walk]
                $parentId=[int]$Records[$walk].ParentProcessId
                if (-not $Records.ContainsKey($parentId)) { throw 'UI provider parent unavailable' }
                $parent=Get-VoltRetainedProcess $parentId $Records[$parentId]
                if ($parent.startTicks -gt $child.startTicks) { throw 'UI provider parent generation changed' }
                $walk=$parentId
            }
            if ($walk -ne $Manager.processId) { throw 'UI provider ancestry unknown' }
            [void]$uiIds.Add($provider)
        }
        $value=$null; $writable=$false; $invokable=$false
        if ($current.Name -ceq 'Relaunch delay in seconds') {
            $pattern=$null
            if ($element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)) { $value=$pattern.Current.Value; $writable=$current.IsEnabled -and -not $pattern.Current.IsReadOnly }
        }
        if ($current.ControlType -eq [Windows.Automation.ControlType]::Button) {
            $pattern=$null; $invokable=$element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)
        }
        $nodes += [pscustomobject]@{name=$current.Name;kind=$current.ControlType.ProgrammaticName.Split('.')[1];processId=$provider;enabled=$current.IsEnabled;value=$value;valueWritable=[bool]$writable;invokable=[bool]$invokable;Element=$element}
    }
    return [pscustomobject]@{Nodes=$nodes;UiProcessIds=@($uiIds);Root=$root}
}

function Get-VoltNativeWindows([int]$ProcessId) {
    if ($null -eq ('ArkuzoVoltNativeWindows' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ArkuzoVoltNativeWindows {
    public sealed class Window { public long handle; public int processId; public string title; public string className; }
    private delegate bool Callback(IntPtr hwnd, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Callback callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
    public static Window[] Read(int processId) {
        var result = new List<Window>();
        Callback callback = (hwnd, state) => {
            uint owner; GetWindowThreadProcessId(hwnd, out owner);
            if (owner == processId) {
                var title = new StringBuilder(256); var kind = new StringBuilder(256);
                GetWindowText(hwnd, title, title.Capacity); GetClassName(hwnd, kind, kind.Capacity);
                result.Add(new Window { handle=hwnd.ToInt64(), processId=(int)owner, title=title.ToString(), className=kind.ToString() });
            }
            return true;
        };
        if (!EnumWindows(callback, IntPtr.Zero)) throw new InvalidOperationException("Native window enumeration unavailable");
        GC.KeepAlive(callback);
        return result.ToArray();
    }
}
'@ -ErrorAction Stop
    }
    return @([ArkuzoVoltNativeWindows]::Read($ProcessId))
}

function Get-VoltManagerWindow([int]$ProcessId) {
    # MainWindowHandle can identify Tao's event target (or zero), not the WebView.
    # Native ownership and the exact observed window contract select the root;
    # full account controls and renderer ancestry are still verified separately.
    $windows=@(Get-VoltNativeWindows $ProcessId | Where-Object {
        $_.processId -eq $ProcessId -and $_.handle -ne 0 -and $_.className -ceq 'Tauri Window' -and $_.title -ceq 'Volt'
    })
    if ($windows.Count -ne 1) { return [long]0 }
    return [long]$windows[0].handle
}

function Get-VoltLiveContext([string]$Root) {
    Close-VoltRetainedProcesses
    $context=[pscustomobject]@{Status=(New-VoltUnavailableStatus 'Volt manager, UI or process identity unavailable');Inventory=$null;Manager=$null;Ui=$null;Processes=@()}
    try {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'profile unavailable' }
        $expectedPath=Join-Path $env:LOCALAPPDATA 'Volt\tauri-app.exe'
        $inventory=Get-VoltInventory $Root; $context.Inventory=$inventory
        if (-not $inventory.available) { $context.Status.reason=$inventory.reason; return $context }
        $managers=@(Get-Process -Name tauri-app -ErrorAction SilentlyContinue)
        try {
            if ($managers.Count -ne 1 -or -not [string]::Equals($managers[0].Path,$expectedPath,[StringComparison]::OrdinalIgnoreCase)) { $context.Status.reason='Volt manager must be exactly one verified executable'; return $context }
            $id=$managers[0].Id
        } finally { foreach($p in $managers) { $p.Dispose() } }
        $records=Get-VoltProcessRecords
        if (-not $records.ContainsKey([int]$id)) { throw 'manager changed' }
        $retained=Get-VoltRetainedProcess $id $records[[int]$id]
        $retained.Process.Refresh()
        $manager=[pscustomobject]@{processId=$id;startTicks=$retained.startTicks;path=$retained.path;identityStable=$true;windowHandle=(Get-VoltManagerWindow $id)}
        if ($manager.windowHandle -eq 0) { $context.Status.reason='Volt Account Manager HWND unavailable; no navigation attempted'; return $context }
        $ui=Get-VoltUiNodes $manager $records
        $processes=Get-VoltRobloxSnapshot $records $manager
        $context=New-VoltControlContext -Inventory $inventory -Managers @($manager) -Nodes $ui.Nodes -Processes $processes -ExpectedPath $expectedPath -UiProcessIds $ui.UiProcessIds
        $context | Add-Member UiRoot $ui.Root
        $context | Add-Member ProbeRoot $Root
        $context | Add-Member UiProcessIds $ui.UiProcessIds
        foreach($held in @($script:VoltRetained.Values)) { if (-not (Test-VoltRetainedProcess $held)) { throw 'retained identity changed' } }
        return $context
    } catch { $context.Status=New-VoltUnavailableStatus 'Volt UI or process snapshot unavailable or changed'; return $context }
}

function Invoke-VoltBoundPatternWrite($Node, $Pattern, [string]$Action, [int]$DesiredSeconds=30, [int[]]$UiProcessIds=@()) {
    $current=$Node.Element.Current
    if ($current.Name -cne $Node.name -or -not $current.IsEnabled -or [int]$current.ProcessId -notin $UiProcessIds) { throw 'Bound UI control identity changed' }
    if ($Action -ceq 'Configure' -and $Node.name -ceq 'Relaunch delay in seconds' -and $current.ControlType.ProgrammaticName -ceq 'ControlType.Edit' -and $Pattern.Current.IsReadOnly -is [bool] -and -not $Pattern.Current.IsReadOnly -and $DesiredSeconds -ge 30 -and $DesiredSeconds -le 3600) {
        $null=$Pattern.SetValue($DesiredSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)); return
    }
    if ($Action -ceq 'LaunchMissing' -and $Node.name -match '\ARelaunch [^\r\n]+ immediately\z' -and $current.ControlType.ProgrammaticName -ceq 'ControlType.Button') { $null=$Pattern.Invoke(); return }
    throw 'Unsupported or read-only UI control'
}

function Test-VoltLiveContext($Context) {
    try {
        if (-not $Context.Status.available -or [string]::IsNullOrEmpty($Context.ProbeRoot) -or -not $script:VoltRetained.ContainsKey([int]$Context.Status.managerId)) { return $false }
        $manager=$Context.Manager; $held=$script:VoltRetained[[int]$manager.processId]
        if (-not (Test-VoltRetainedProcess $held) -or (Get-VoltManagerWindow $manager.processId) -ne $manager.windowHandle) { return $false }
        $managers=@(Get-Process -Name tauri-app -ErrorAction SilentlyContinue)
        try { if ($managers.Count -ne 1 -or $managers[0].Id -ne $manager.processId -or $managers[0].StartTime.ToUniversalTime().Ticks -ne $manager.startTicks) { return $false } }
        finally { foreach($p in $managers) { $p.Dispose() } }
        $inventory=Get-VoltInventory $Context.ProbeRoot
        $records=Get-VoltProcessRecords
        $ui=Get-VoltUiNodes $manager $records
        $processes=Get-VoltRobloxSnapshot $records $manager
        $fresh=New-VoltControlContext -Inventory $inventory -Managers @($manager) -Nodes $ui.Nodes -Processes $processes -ExpectedPath $manager.path -UiProcessIds $ui.UiProcessIds
        if (-not (Test-VoltControlRevalidation $Context $fresh)) { return $false }
        $oldNodes=@($Context.Ui.delayNode)+@($Context.Ui.rows | ForEach-Object { $_.button })
        $newNodes=@($fresh.Ui.delayNode)+@($fresh.Ui.rows | ForEach-Object { $_.button })
        for($i=0;$i -lt $oldNodes.Count;$i++) {
            if (($oldNodes[$i].Element.GetRuntimeId() -join ',') -cne ($newNodes[$i].Element.GetRuntimeId() -join ',')) { return $false }
        }
        foreach($held in @($script:VoltRetained.Values)) { if (-not (Test-VoltRetainedProcess $held)) { return $false } }
        return $true
    } catch { return $false }
}

function New-VoltLiveFacade([string]$Root) {
    return @{
        Root=$Root
        Read={param($root) Get-VoltLiveContext $root}
        Verify={param($ctx) Test-VoltLiveContext $ctx}
        SetDelay={
            param($ctx,$seconds)
            foreach($held in @($script:VoltRetained.Values)) { if (-not (Test-VoltRetainedProcess $held)) { throw 'Process identity changed before UI write' } }
            $node=$ctx.Ui.delayNode; $pattern=$null
            if (-not $node.Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)) { throw 'Editable value pattern unavailable' }
            Invoke-VoltBoundPatternWrite $node $pattern Configure $seconds $ctx.UiProcessIds
        }
        Invoke={
            param($ctx,$row)
            foreach($held in @($script:VoltRetained.Values)) { if (-not (Test-VoltRetainedProcess $held)) { throw 'Process identity changed before UI request' } }
            $node=$row.button; $pattern=$null
            if (-not $node.Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) { throw 'Invoke pattern unavailable' }
            Invoke-VoltBoundPatternWrite $node $pattern LaunchMissing 30 $ctx.UiProcessIds
        }
        Now={ [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        Wait={ Start-Sleep -Milliseconds 200 }
    }
}

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$script:VoltRetained=@{}
try {
    $facade=New-VoltLiveFacade $PSScriptRoot
    $result=Invoke-VoltControlAction -Action $Action -Facade $facade -AccountId $AccountId -ExpectedTrackerId $ExpectedTrackerId -RelaunchDelaySec $RelaunchDelaySec -MinLaunchAgeSec $MinLaunchAgeSec
} catch {
    $result=New-VoltUnavailableStatus 'Volt adapter failed closed'
    if ($Action -ceq 'LaunchMissing') { $result | Add-Member requestAccepted $false }
    if ($Action -ceq 'Configure') { $result | Add-Member configured $false }
} finally { Close-VoltRetainedProcesses }
$result | ConvertTo-Json -Depth 10 -Compress
