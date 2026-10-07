#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$helper = Join-Path $root 'Arkuzo-Volt-Control.ps1'
function Assert([bool]$ok,[string]$message) { if (-not $ok) { throw "FAIL: $message" } }
Assert (Test-Path -LiteralPath $helper) 'Secret-free Volt adapter must exist'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Adapter must parse'
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:passed=0
function Case([string]$name,[scriptblock]$body) { & $body; $script:passed++; Write-Output "PASS: $name" }
$expectedPath='C:\Fixtures\Local\Volt\tauri-app.exe'
function Fixture {
    $inventory=[pscustomobject]@{available=$true;safeToRecycle=$true;autoEnabled=$true;relaunchDelayMs=10000;accounts=@(
        [pscustomobject]@{accountId='11111111-1111-4111-8111-111111111111';username='alpha';displayName='Alpha';trackerId='12345';autoRelaunch=$true;cookieAlive=$true;lastLaunchAtMs=100000}
        [pscustomobject]@{accountId='22222222-2222-4222-8222-222222222222';username='beta';displayName='Beta';trackerId='67890';autoRelaunch=$true;cookieAlive=$true;lastLaunchAtMs=100000}
    )}
    $manager=[pscustomobject]@{processId=10;startTicks=[long]100;path=$expectedPath;identityStable=$true;windowHandle=77}
    $nodes=@(
        [pscustomobject]@{name='Relaunch delay in seconds';kind='Edit';processId=10;enabled=$true;value='10';valueWritable=$true;invokable=$false}
        [pscustomobject]@{name='Select';kind='CheckBox';processId=10;enabled=$true}
        [pscustomobject]@{name='@alpha';kind='Text';processId=10;enabled=$true}
        [pscustomobject]@{name='Socket connected to Roblox process PID 20';kind='Group';processId=10;enabled=$true}
        [pscustomobject]@{name='Connected';kind='Text';processId=10;enabled=$true}
        [pscustomobject]@{name='Relaunch Alpha immediately';kind='Button';processId=10;enabled=$true;invokable=$true}
        [pscustomobject]@{name='Select';kind='CheckBox';processId=10;enabled=$true}
        [pscustomobject]@{name='@beta';kind='Text';processId=10;enabled=$true}
        [pscustomobject]@{name='No connected Roblox socket';kind='Group';processId=10;enabled=$true}
        [pscustomobject]@{name='Idle';kind='Text';processId=10;enabled=$true}
        [pscustomobject]@{name='Memory: No active process';kind='Text';processId=10;enabled=$true}
        [pscustomobject]@{name='Relaunch Beta immediately';kind='Button';processId=10;enabled=$true;invokable=$true}
    )
    $processes=@([pscustomobject]@{processId=20;startTicks=[long]200;trackerId='12345';parentProcessId=[uint32]10;parentStartTicks=[long]100;identityStable=$true;ownerStable=$true})
    return @{Inventory=$inventory;Managers=@($manager);Nodes=$nodes;Processes=$processes;ExpectedPath=$expectedPath}
}
Case 'Flattened UI rows bind by exact username, not ancestor or slot' {
    Assert ([bool](Get-Command New-VoltControlContext -ErrorAction SilentlyContinue)) 'Snapshot context API must exist'
    $f=Fixture; $c=New-VoltControlContext @f
    Assert $c.Status.available 'Unique verified manager and known editor make adapter available'
    Assert ($c.Status.accounts.Count -eq 2) 'Exactly two inventory accounts'
    Assert ($c.Status.accounts[0].accountId -eq $f.Inventory.accounts[0].accountId) 'Preserve stable ID'
    Assert ($c.Status.accounts[0].processId -eq 20) 'Connected socket exact process'
    Assert ($c.Status.accounts[0].uiStatus -eq 'Connected') 'Connected label is observed, not a health assertion'
    Assert $c.Status.accounts[0].controlReady 'Connected account is restorable'
    Assert ($c.Status.accounts[1].uiStatus -eq 'Idle') 'Other account remains idle'
    Assert $c.Status.accounts[1].controlReady 'Missing account has exact idle launch control'
}
Case 'Ambiguous account identity blocks the entire adapter' {
    foreach($field in @('accountId','username','displayName','trackerId')) {
        $f=Fixture; $f.Inventory.accounts[1].$field=$f.Inventory.accounts[0].$field
        $c=New-VoltControlContext @f
        Assert (-not $c.Status.available) "Duplicate $field must fail closed"
    }
    foreach($pair in @(@('accountId','bad'),@('trackerId','123bad'),@('trackerId',"123`n"))) {
        $f=Fixture; $f.Inventory.accounts[0].($pair[0])=$pair[1]
        Assert (-not (New-VoltControlContext @f).Status.available) 'Malformed identity cannot be normalized'
    }
}
Case 'Unknown, duplicated or foreign UI controls fail closed' {
    $f=Fixture; $f.Nodes[0].valueWritable=$false
    Assert (-not (New-VoltControlContext @f).Status.available) 'Unknown delay editor'
    $f=Fixture; $f.Nodes += $f.Nodes[5]
    Assert (-not (New-VoltControlContext @f).Status.available) 'Duplicate exact action'
    $f=Fixture; $f.Nodes[5].processId=999
    Assert (-not (New-VoltControlContext @f).Status.available) 'Wrong UI process must block'
    $f=Fixture; $f.Nodes[5].name='Launch Selected'
    Assert (-not (New-VoltControlContext @f).Status.available) 'Global launch is not a replacement control'
    $f=Fixture; $f.Nodes[5].name='Relaunch Beta immediately'; $f.Nodes[11].name='Relaunch Alpha immediately'
    Assert (-not (New-VoltControlContext @f).Status.available) 'Do not cross checkbox row boundary'
    $f=Fixture; $f.Managers += $f.Managers[0]
    Assert (-not (New-VoltControlContext @f).Status.available) 'Multiple managers'
    $f=Fixture; $f.Managers[0].path='C:\\Elsewhere\\tauri-app.exe'
    Assert (-not (New-VoltControlContext @f).Status.available) 'Wrong manager path'
    $f=Fixture; $f.Managers[0].identityStable=$false
    Assert (-not (New-VoltControlContext @f).Status.available) 'Unretained manager identity'
}
Case 'Tracker parser accepts only one strict nonsecret token' {
    Assert ([bool](Get-Command Get-VoltTrackerId -ErrorAction SilentlyContinue)) 'Strict tracker parser must exist'
    foreach($line in @('roblox-player:browsertrackerid:12345+other:value','browserTrackerId=12345&other=x','browsertrackerid%3A12345%2Bother:x',"browsertrackerid:12345`"")) {
        Assert ((Get-VoltTrackerId $line) -ceq '12345') 'Valid tracker token'
    }
    foreach($line in @('', 'browsertrackerid:123x', 'browsertrackerid:12345 browsertrackerid:67890', 'abrowsertrackerid:12345','browsertrackerid:-2','browsertrackerid:12345junk')) {
        Assert ($null -eq (Get-VoltTrackerId $line)) 'Ambiguous or malformed tracker cannot bind'
    }
}
Case 'Status facade is read-only and never requests a write' {
    Assert ([bool](Get-Command Invoke-VoltControlAction -ErrorAction SilentlyContinue)) 'Action dispatcher must exist'
    $f=Fixture; $script:sampleContext=New-VoltControlContext @f; $script:writes=0
    $facade=@{Read={ $script:sampleContext };Verify={ $true };SetDelay={ $script:writes++ };Invoke={ $script:writes++ };Wait={}}
    $result=Invoke-VoltControlAction -Action Status -Facade $facade
    Assert $result.available 'Read-only facade returns status'
    Assert ($script:writes -eq 0) 'Status cannot write'
    Assert (($result | ConvertTo-Json -Depth 10) -notmatch 'CommandLine|encryptedCookie|button|delayNode') 'Only status allowlist leaves the adapter'
}
Case 'Socket process generation and live owner are mandatory per account' {
    foreach($field in @('identityStable','ownerStable')) {
        $f=Fixture; $f.Processes[0].$field=$false; $c=New-VoltControlContext @f
        Assert (-not $c.Status.accounts[0].controlReady) 'Unstable live identity is not restorable'
        Assert $c.Status.accounts[1].controlReady 'Other account remains independently bound'
    }
    $f=Fixture; $f.Processes[0].parentStartTicks=101
    Assert (-not (New-VoltControlContext @f).Status.accounts[0].controlReady) 'Parent PID reuse'
    $f=Fixture; $f.Processes[0].processId=21
    Assert (-not (New-VoltControlContext @f).Status.accounts[0].controlReady) 'UI socket wrong PID'
    $f=Fixture; $f.Inventory.safeToRecycle=$false
    Assert (-not (New-VoltControlContext @f).Status.accounts[1].controlReady) 'Global conservative readiness is preserved'
}
Case 'Owned WebView renderer UI remains bound to the manager HWND' {
    $f=Fixture; foreach($n in $f.Nodes) { $n.processId=30 }; $f.UiProcessIds=@(10,30)
    $c=New-VoltControlContext @f
    Assert $c.Status.available 'Verified renderer descendant may provide UI nodes'
    $f.Nodes[5].processId=999
    Assert (-not (New-VoltControlContext @f).Status.available) 'An unverified renderer must still fail closed'
}
Case 'Configure raises delay through one editor and verifies UI plus DB' {
    $f=Fixture; $script:sampleContext=New-VoltControlContext @f; $script:writes=0
    $facade=@{Read={ $script:sampleContext };Verify={ $true };SetDelay={param($ctx,$seconds) $script:writes++; $script:sampleContext.Ui.delaySec=$seconds; $script:sampleContext.Inventory.relaunchDelayMs=$seconds*1000; $script:sampleContext.Status.relaunchDelayMs=$seconds*1000};Invoke={throw 'Never launch in Configure'};Wait={}}
    $result=Invoke-VoltControlAction -Action Configure -Facade $facade -RelaunchDelaySec 30
    Assert ([bool]$result.configured) 'Persisted setting is verified'
    Assert ($result.relaunchDelayMs -eq 30000) 'Exactly desired minimum'
    Assert ($script:writes -eq 1) 'Exactly one ValuePattern write'
    $script:sampleContext.Ui.delaySec=60; $script:sampleContext.Inventory.relaunchDelayMs=60000; $script:sampleContext.Status.relaunchDelayMs=60000; $script:writes=0
    $result=Invoke-VoltControlAction -Action Configure -Facade $facade -RelaunchDelaySec 30
    Assert ([bool]$result.configured) 'Greater user delay is already safe'
    Assert ($script:writes -eq 0 -and $result.relaunchDelayMs -eq 60000) 'Do not decrease user value'
    $script:sampleContext.Ui.delaySec=10; $script:sampleContext.Inventory.relaunchDelayMs=10000; $script:sampleContext.Status.relaunchDelayMs=10000
    $facade.SetDelay={param($ctx,$seconds) $script:sampleContext.Ui.delaySec=$seconds}
    $result=Invoke-VoltControlAction -Action Configure -Facade $facade -RelaunchDelaySec 30
    Assert (-not $result.configured) 'UI-only change without DB persistence is a failure'
}
Case 'LaunchMissing requests exactly one bound idle account, never a connected one' {
    $f=Fixture; $script:sampleContext=New-VoltControlContext @f; $script:writes=0
    $facade=@{Read={ $script:sampleContext };Verify={ $true };Now={ [double]1000000 };SetDelay={throw 'Never configure in LaunchMissing'};Invoke={param($ctx,$row) Assert ($row.button.name -ceq 'Relaunch Beta immediately') 'Only target bound button'; $script:writes++};Wait={}}
    $result=Invoke-VoltControlAction -Action LaunchMissing -AccountId $f.Inventory.accounts[1].accountId -ExpectedTrackerId '67890' -Facade $facade
    Assert ([bool]$result.requestAccepted) 'One idle request is accepted'
    Assert ($script:writes -eq 1) 'One invoke only'
    Assert ($result.accountId -ceq $f.Inventory.accounts[1].accountId) 'Outcome journals stable account ID'
    Assert ($null -eq $result.success) 'Request acceptance must not claim recovery success'
    $script:writes=0
    $result=Invoke-VoltControlAction -Action LaunchMissing -AccountId $f.Inventory.accounts[0].accountId -ExpectedTrackerId '12345' -Facade $facade
    Assert (-not $result.requestAccepted -and $script:writes -eq 0) 'Connected account is never launched'
}
Case 'Missing launch blocks any unambiguous-mapping gap or young attempt' {
    foreach($mutation in @('UnknownTracker','MalformedTracker','DuplicateTracker','UnstableProcess','ForeignOwner','MissingTicks','RecentTarget','FutureTarget','WrongExpectation','MinimumTooSmall')) {
        $f=Fixture; $expected='67890'; $minimum=90
        switch($mutation) {
            UnknownTracker { $f.Processes[0].trackerId='77777' }
            MalformedTracker { $f.Processes[0].trackerId='123bad' }
            DuplicateTracker { $f.Processes += $f.Processes[0] }
            UnstableProcess { $f.Processes[0].identityStable=$false }
            ForeignOwner { $f.Processes[0].ownerStable=$false }
            MissingTicks { $f.Processes[0].startTicks=0 }
            RecentTarget { $f.Inventory.accounts[1].lastLaunchAtMs=950000 }
            FutureTarget { $f.Inventory.accounts[1].lastLaunchAtMs=1000001 }
            WrongExpectation { $expected='67891' }
            MinimumTooSmall { $minimum=0 }
        }
        $c=New-VoltControlContext @f
        Assert (-not (Test-VoltMissingLaunch $c $f.Inventory.accounts[1].accountId $expected 1000000 $minimum)) "$mutation cannot launch"
    }
}
Case 'Action dispatcher passes the staging root to every read' {
    $f=Fixture; $script:sampleContext=New-VoltControlContext @f
    $facade=@{Root='STAGED-ROOT';Read={param($root) Assert ($root -ceq 'STAGED-ROOT') 'Read must receive probe root'; $script:sampleContext }}
    $result=Invoke-VoltControlAction -Action Status -Facade $facade
    Assert $result.available 'Root-aware snapshot works'
}
Case 'Bound native pattern writes accept only exact enabled controls' {
    Assert ([bool](Get-Command Invoke-VoltBoundPatternWrite -ErrorAction SilentlyContinue)) 'Native pattern boundary must exist'
    $script:nativeWrites=0
    $pattern=[pscustomobject]@{Current=[pscustomobject]@{IsReadOnly=$false}}
    $pattern | Add-Member ScriptMethod SetValue { param($text) $script:nativeWrites++; Assert ($text -ceq '30') 'Requested seconds only' }
    $pattern | Add-Member ScriptMethod Invoke { $script:nativeWrites++ }
    $node=[pscustomobject]@{name='Relaunch delay in seconds';Element=[pscustomobject]@{Current=[pscustomobject]@{Name='Relaunch delay in seconds';ProcessId=30;IsEnabled=$true;ControlType=[pscustomobject]@{ProgrammaticName='ControlType.Edit'}}}}
    Invoke-VoltBoundPatternWrite $node $pattern Configure 30 @(10,30)
    $node.name='Relaunch Beta immediately'; $node.Element.Current.Name=$node.name; $node.Element.Current.ControlType.ProgrammaticName='ControlType.Button'
    Invoke-VoltBoundPatternWrite $node $pattern LaunchMissing 30 @(10,30)
    Assert ($script:nativeWrites -eq 2) 'Two fixture native pattern writes'
    foreach($mutation in @('Global','Foreign','Disabled','WrongLabel')) {
        $node.name='Relaunch Beta immediately'; $node.Element.Current.Name=$node.name; $node.Element.Current.ProcessId=30; $node.Element.Current.IsEnabled=$true
        switch($mutation) { Global {$node.name='Launch Selected'; $node.Element.Current.Name=$node.name} Foreign {$node.Element.Current.ProcessId=999} Disabled {$node.Element.Current.IsEnabled=$false} WrongLabel {$node.Element.Current.Name='Relaunch Alpha immediately'} }
        $blocked=$false; try { Invoke-VoltBoundPatternWrite $node $pattern LaunchMissing 30 @(10,30) } catch { $blocked=$true }
        Assert $blocked 'Changed or global controls must be rejected'
    }
    Assert ($script:nativeWrites -eq 2) 'No negative fixture performed a write'
}
Case 'Immediate revalidation rejects any DB UI or process generation change' {
    Assert ([bool](Get-Command Test-VoltControlRevalidation -ErrorAction SilentlyContinue)) 'Revalidation boundary must exist'
    $f=Fixture; $original=New-VoltControlContext @f; $g=Fixture; $fresh=New-VoltControlContext @g
    Assert (Test-VoltControlRevalidation $original $fresh) 'Identical independent snapshots validate'
    foreach($mutation in @('ManagerGeneration','Tracker','Username','LaunchTimestamp','Delay','UiState','ClientGeneration')) {
        $g=Fixture
        switch($mutation) {
            ManagerGeneration {$g.Managers[0].startTicks=101}
            Tracker {$g.Inventory.accounts[1].trackerId='67891'}
            Username {$g.Inventory.accounts[1].username='gamma'}
            LaunchTimestamp {$g.Inventory.accounts[1].lastLaunchAtMs=100001}
            Delay {$g.Inventory.relaunchDelayMs=11000}
            UiState {$g.Nodes[9].name='Unknown'}
            ClientGeneration {$g.Processes[0].startTicks=201}
        }
        Assert (-not (Test-VoltControlRevalidation $original (New-VoltControlContext @g))) "$mutation invalidates observed identity"
    }
}
Case 'No write occurs when the second snapshot changes account identity' {
    $f=Fixture; $script:originalContext=New-VoltControlContext @f
    $g=Fixture; $g.Inventory.accounts[1].username='gamma'; $g.Nodes[7].name='@gamma'; $script:freshContext=New-VoltControlContext @g
    $script:reads=0; $script:writes=0
    $facade=@{Read={ $script:reads++; if($script:reads -eq 1){$script:originalContext}else{$script:freshContext} };Verify={$true};Now={[double]1000000};Invoke={$script:writes++};Wait={}}
    $result=Invoke-VoltControlAction -Action LaunchMissing -AccountId $f.Inventory.accounts[1].accountId -ExpectedTrackerId '67890' -Facade $facade
    Assert (-not $result.requestAccepted -and $script:writes -eq 0) 'Revalidate DB account identity immediately before any button request'
}
Case 'Live facade connects native verification and only supported pattern operations' {
    $facade=New-VoltLiveFacade 'STAGED-ROOT'
    Assert ($facade.Verify.ToString() -match 'Test-VoltLiveContext') 'Live verification cannot be a placeholder'
    Assert ($facade.SetDelay.ToString() -match 'ValuePattern' -and $facade.SetDelay.ToString() -match 'Invoke-VoltBoundPatternWrite') 'Configure uses exact ValuePattern boundary'
    Assert ($facade.Invoke.ToString() -match 'InvokePattern' -and $facade.Invoke.ToString() -match 'Invoke-VoltBoundPatternWrite') 'LaunchMissing uses exact InvokePattern boundary'
    $definition=$ast.Extent.Text
    Assert ($definition -notmatch 'SetForegroundWindow|SendKeys|Launch Selected|Stop-Process|sqlite3\.connect') 'No focus, global actions or SQLite writes in adapter'
}
Case 'CLI preserves exit code 0 and nonsecret single-document JSON on all failures' {
    $raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Action Status
    Assert ($LASTEXITCODE -eq 0) 'Status CLI returns 0 on success'
    $doc=$raw | ConvertFrom-Json
    Assert ($doc.available -is [bool]) 'JSON parses'
    $rawBad=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Action UnknownAction
    Assert ($LASTEXITCODE -eq 0) 'Bad action returns 0'
    $docBad=$rawBad | ConvertFrom-Json
    Assert (-not $docBad.available) 'Fails closed'
    Assert ($docBad.reason -ceq 'Unsupported Volt action') 'Safe nonsecret reason'
}
Write-Output "RESULT: $script:passed cases passed"
