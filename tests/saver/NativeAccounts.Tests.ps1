#requires -Version 5.1
# Arkuzo's own account provider: launching and relaunching without Volt.
# Roblox is never contacted (HTTP, process listing and process start are faked)
# and every cookie is synthetic with Roblox's warning prefix, so any leak of one
# into a status, diagnostic or message is caught by a plain text search.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
function Write-Diagnostic($kind, $data) { [void]$script:events.Add(@{ kind = $kind; data = $data }) }
function Warn-Throttled($key, $message) { [void]$script:warned.Add("$key|$message") }
function Get-ArkuzoAccountDisplayLabel { 'account' }
function Save-ArkuzoRecoveryJournal { }

$Prefix = '_|WARNING:-DO-NOT-SHARE-THIS.--Sharing-this-will-allow-someone-to-log-in-as-you-and-to-steal-your-ROBUX-and-items.|_'
function Fake-Cookie([string]$Tag) { $Prefix + 'FAKE' + ($Tag * 40) }
$script:NativeVaultMutexName = 'Local\ArkuzoAccountVault-Test-' + [guid]::NewGuid().ToString('N')
$script:NativeVaultEntropy = [Text.Encoding]::ASCII.GetBytes('Arkuzo.AccountVault.v1')
$script:NativeUserAgent = 'test'
$DataDirectory = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-native-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
$voltPath = Join-Path $DataDirectory 'no-volt\tauri-app.exe'
$script:controllerStartTicks = 42

$python = Get-Command python3.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $python) { $python = Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
$cc = Join-Path $root 'src/saver/Arkuzo-Control-Center.py'
function Invoke-Py([string]$Code) {
    $script = "import importlib.util,sys`nspec=importlib.util.spec_from_file_location('cc',r'$cc')`ncc=importlib.util.module_from_spec(spec);spec.loader.exec_module(cc)`n" + $Code
    $out = $script | & $python.Source -B -
    if ($LASTEXITCODE -ne 0) { throw 'python failed' }
    return ($out -join "`n").Trim()
}

$A = '11111111-1111-4111-8111-111111111111'; $B = '22222222-2222-4222-8222-222222222222'; $C = '33333333-3333-4333-8333-333333333333'
$TA = '123456789012'; $TB = '223456789012'; $TC = '323456789012'
function New-Vault([hashtable]$Settings = @{}) {
    $merged = @{ defaultPlaceId = '920587237'; launchDelaySec = 12; relaunchDelaySec = 8; launchTimeoutSec = 120; autoRelaunchEnabled = $true; farmRunning = $true
        privateServerMode = 'none'; sharedPrivateServerId = $null; multiInstance = $false; launchMethod = 'direct'; cookieCheckMinutes = 60 }
    foreach ($k in $Settings.Keys) { $merged[$k] = $Settings[$k] }
    $acct = { param($id, $uid, $name, $tracker, $tag, $status)
        [ordered]@{ id = $id; userId = $uid; username = $name; displayName = $name; alias = ''; group = ''; notes = ''; cookie = (ConvertTo-ArkuzoSecret (Fake-Cookie $tag))
            cookieStatus = $status; browserTrackerId = $tracker; autoRelaunch = $true; privateServerId = $null; placeId = ''; lastCheckAtMs = 0; lastLaunchAtMs = 0
            createdAtMs = 1; updatedAtMs = 1; launchRequestedAtMs = 0; closeRequestedAtMs = 0 } }
    $vault = [ordered]@{ schemaVersion = 1; settings = $merged; privateServers = @(@{ id = '44444444-4444-4444-8444-444444444444'; name = 'VIP'; placeId = '555'; linkCode = (ConvertTo-ArkuzoSecret 'LinkCode123'); createdAtMs = 1 })
        accounts = @((& $acct $A 101 'FarmAlpha' $TA 'a' 'alive'), (& $acct $B 102 'FarmBravo' $TB 'b' 'alive'), (& $acct $C 103 'FarmCharlie' $TC 'c' 'dead')) }
    Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
}
function Vault { [IO.File]::ReadAllText((Get-ArkuzoVaultPath)) | ConvertFrom-Json }
function Row([string]$Id) { @((Vault).accounts | Where-Object { $_.id -eq $Id })[0] }
function Reset-Engine {
    $script:events = New-Object Collections.ArrayList; $script:warned = New-Object Collections.ArrayList
    $script:MonitorOnly = $false; $script:ownsControllerMutex = $true; $script:recoveryJournalHealthy = $true; $script:recoveryJournalCorrupt = $false; $script:logFailed = $false
    $script:healthPolicy = Get-ArkuzoHealthPolicy @{ enabled = $true }
    $script:restorePolicy = Get-ArkuzoRestorePolicy @{ enabled = $true; retry_max_per_hour = 200 }
    $script:recoveryAttempts = @(); $script:launchAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
    $script:sessionObservedAccounts = @{}; $script:saverSessionStartEpochMs = $null; $script:tracked = @{}; $script:systemMemory = @{ commitPercent = 30 }
    $script:accountProvider = 'arkuzo'; $script:accountProviderSetting = 'auto'; $script:accountProviderNotice = $null
    $script:nativeLaunches = @{}; $script:nativeLastLaunchUtc = $null; $script:nativeSingletons = @(); $script:nativeVault = $null
    $script:nativeVoltConflict = @{ checkedUtc = [datetime]::UtcNow; userIds = @() }
    $script:lastClientStartUtc = $null; $script:farmFreeze = $null
    $script:clients = @(); $script:posts = New-Object Collections.ArrayList; $script:starts = New-Object Collections.ArrayList
    $script:roblox = @{}  # cookie -> @{ status; rotate }
}
# Fakes for the only parts that touch the machine or the network.
function Get-ArkuzoNativeClients { return ,@($script:clients) }
function Invoke-ArkuzoRobloxPost([string]$Url, [string]$Cookie, [string]$Csrf = '') {
    [void]$script:posts.Add(@{ url = $Url; csrf = $Csrf })
    $known = $script:roblox[$Cookie]
    $rotated = if ($null -ne $known -and $known.rotate) { $known.rotate } else { $null }
    if ($null -eq $known) { return @{ status = 401; rotated = $null } }
    if (-not $Csrf) { return @{ status = 403; csrf = 'tok-1'; rotated = $rotated } }
    return @{ status = 200; ticket = 'TICKET-' + $Cookie.Length; rotated = $rotated }
}
function Start-ArkuzoRobloxClient([string]$Ticket, [string]$JoinUrl, [string]$TrackerId, [string]$Method, $Clients) {
    [void]$script:starts.Add(@{ ticket = $Ticket; url = $JoinUrl; tracker = $TrackerId; method = $Method }); return @{ method = 'direct'; pid = 999 }
}

try {
    Reset-Engine
    # --- DPAPI interop: the Control Center (Python) and the engine read each other's secrets.
    $fromPy = Invoke-Py "print(cc.protect_secret('$(Fake-Cookie 'p')'))"
    Assert ((ConvertFrom-ArkuzoSecret $fromPy) -ceq (Fake-Cookie 'p')) 'engine decrypts a cookie the Control Center encrypted'
    $fromPs = ConvertTo-ArkuzoSecret (Fake-Cookie 'q')
    Assert ((Invoke-Py "print(cc.unprotect_secret('$fromPs'))") -ceq (Fake-Cookie 'q')) 'Control Center decrypts a cookie the engine encrypted'

    # --- The vault the engine writes stays readable by the Control Center.
    New-Vault
    Assert ((Invoke-Py "from pathlib import Path`nv=cc.load_vault(Path(r'$DataDirectory'))`nprint(len(v['accounts']),len(v['privateServers']),v['settings']['farmRunning'])") -ceq '3 1 True') 'Control Center loads the engine-written vault without dropping rows'

    # --- Status: exact tracker mapping, foreign clients ignored, duplicates refuse to guess.
    $script:clients = @([pscustomobject]@{ processId = 501; trackerId = $TA; path = '' }, [pscustomobject]@{ processId = 777; trackerId = '999999999999'; path = '' }, [pscustomobject]@{ processId = 778; trackerId = $null; path = '' })
    $status = Get-ArkuzoNativeStatus
    $script:voltControlStatus = $status; $script:voltControlCheckedUtc = [datetime]::UtcNow
    $sa = @($status.accounts | Where-Object { $_.accountId -eq $A })[0]; $sb = @($status.accounts | Where-Object { $_.accountId -eq $B })[0]; $sc = @($status.accounts | Where-Object { $_.accountId -eq $C })[0]
    Assert ($status.available -and $status.globalMappingSafe -and $status.provider -eq 'arkuzo' -and $status.farmRunning) 'vault status available and mapped'
    Assert ($sa.uiStatus -eq 'Connected' -and $sa.processId -eq 501 -and $sa.controlReady) 'client with the account tracker is Connected'
    Assert ($sb.uiStatus -eq 'Idle' -and $null -eq $sb.processId -and $sb.autoRelaunch) 'account without client is Idle'
    Assert (-not $sc.cookieAlive -and $sc.suspensionSafe -and -not $sc.controlReady) 'dead cookie: suspension-safe, never launch-ready'
    Assert ((Test-ArkuzoClientOwnership @{ TrackerId = $TA }) -and -not (Test-ArkuzoClientOwnership @{ TrackerId = '999999999999' }) -and -not (Test-ArkuzoClientOwnership @{ TrackerId = '' })) 'only vault trackers are owned'
    Assert ($null -ne (Get-ArkuzoControlledAccount $TA 501) -and $null -eq (Get-ArkuzoControlledAccount $TA 502)) 'controlled account needs exact tracker and pid'
    $script:clients += [pscustomobject]@{ processId = 502; trackerId = $TA; path = '' }
    Assert (-not (Get-ArkuzoNativeStatus).globalMappingSafe) 'two clients on one account: mapping unsafe'
    $json = $status | ConvertTo-Json -Depth 8
    Assert ($json -notmatch 'WARNING:-DO-NOT|dpapi:') 'status carries no secrets'

    # --- Launch arguments: each form maps to exactly one tracker.
    $join = Get-ArkuzoNativeJoinUrl (Vault) (Row $B)
    Assert ($join -ceq ('https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&browserTrackerId=' + $TB + '&placeId=920587237&isPlayTogetherGame=false')) 'public join uses the default place and tracker'
    $direct = '"C:\Roblox\RobloxPlayerBeta.exe" --app -t TICKET -j "' + $join + '" -b ' + $TB + ' --launchtime=1 --rloc en_us --gloc en_us'
    Assert ((Get-ArkuzoBrowserTrackerId $direct) -ceq $TB) 'direct command line maps to the account tracker'
    $protocol = 'roblox-player:1+launchmode:play+gameinfo:T+launchtime:1+placelauncherurl:' + [Uri]::EscapeDataString($join) + '+browsertrackerid:' + $TB + '+robloxLocale:en_us'
    Assert ((Get-ArkuzoBrowserTrackerId $protocol) -ceq $TB) 'protocol form maps to the account tracker'
    New-Vault @{ privateServerMode = 'shared'; sharedPrivateServerId = '44444444-4444-4444-8444-444444444444' }
    Assert ((Get-ArkuzoNativeJoinUrl (Vault) (Row $B)) -ceq ('https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestPrivateGame&placeId=555&linkCode=LinkCode123&browserTrackerId=' + $TB)) 'shared private server join'
    New-Vault @{ defaultPlaceId = '' }
    $failed = $false; try { Get-ArkuzoNativeJoinUrl (Vault) (Row $B) | Out-Null } catch { $failed = $true }
    Assert $failed 'no place: no launch'

    # --- Launch: CSRF handshake, rotated cookie stored, ticket used, vault stamped.
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'b')] = @{ rotate = (Fake-Cookie 'r') }
    $script:roblox[(Fake-Cookie 'r')] = @{ }
    $r = Invoke-ArkuzoNativeLaunch $B $TB
    Assert ($r.requestAccepted) ('launch accepted: ' + $r.reason)
    Assert ($script:posts.Count -eq 2 -and $script:posts[0].csrf -eq '' -and $script:posts[1].csrf -eq 'tok-1') 'ticket request uses the CSRF handshake'
    Assert ($script:starts.Count -eq 1 -and $script:starts[0].tracker -eq $TB -and $script:starts[0].url -match 'placeId=920587237') 'client started with the account tracker and place'
    Assert ((ConvertFrom-ArkuzoSecret (Row $B).cookie) -ceq (Fake-Cookie 'r')) 'rotated cookie replaces the old one in the vault'
    Assert ((Row $B).lastLaunchAtMs -gt 0 -and $script:nativeLaunches.ContainsKey($B)) 'launch recorded'
    $script:voltControlStatus = Get-ArkuzoNativeStatus
    Assert (@($script:voltControlStatus.accounts | Where-Object { $_.accountId -eq $B })[0].uiStatus -eq 'Launching') 'a launched account waits as Launching, never launched twice'
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted) 'no second launch while one is in flight'
    Assert (-not (Test-ArkuzoNativeLaunchSlot ([datetime]::UtcNow))) 'launch slot closed for launchDelaySec'
    Assert (Test-ArkuzoNativeLaunchSlot ([datetime]::UtcNow.AddSeconds(13))) 'launch slot opens after launchDelaySec'

    # --- A signed-out account: 401 marks the cookie dead; nothing starts.
    Reset-Engine; New-Vault
    $r = Invoke-ArkuzoNativeLaunch $A $TA
    Assert (-not $r.requestAccepted -and (Row $A).cookieStatus -eq 'dead' -and $script:starts.Count -eq 0) '401 at launch marks the cookie dead'
    Assert (@($script:events | Where-Object { $_.kind -eq 'NATIVE_COOKIE_DEAD' }).Count -eq 1) 'dead cookie reported'
    # Dead, stopped farm, Volt conflict and a running client all refuse.
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'c')] = @{ }
    Assert (-not (Invoke-ArkuzoNativeLaunch $C $TC).requestAccepted) 'dead account never launches'
    New-Vault @{ farmRunning = $false }; $script:roblox[(Fake-Cookie 'b')] = @{ }
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted) 'stopped farm: no automatic launch'
    Assert ((Invoke-ArkuzoNativeLaunch $B $TB -Manual).requestAccepted) 'stopped farm: the Launch button still works'
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:nativeVoltConflict = @{ checkedUtc = [datetime]::UtcNow; userIds = @('102') }
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted -and $script:starts.Count -eq 0) 'Volt auto-relaunch on the same account blocks Arkuzo launches'
    Assert ((Get-ArkuzoNativeStatus).accounts[1].voltConflict -and $script:accountProviderNotice -match 'Volt') 'conflict is shown'
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:clients = @([pscustomobject]@{ processId = 600; trackerId = $TB; path = '' })
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted -and $script:starts.Count -eq 0) 'an account already in game is not launched again'

    # --- Farm start: missing accounts are queued and launched one per launch slot, no backoff.
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'a')] = @{ }; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.ContainsKey($A) -and $script:recoveryPending.ContainsKey($B) -and -not $script:recoveryPending.ContainsKey($C)) 'farm start queues every alive opted-in account, never launched before or not'
    foreach ($k in @($script:recoveryPending.Keys)) { $script:recoveryPending[$k].createdUtc = [datetime]::UtcNow.AddSeconds(-9).ToString('o') }
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:starts.Count -eq 1) 'first launch after relaunchDelaySec (8 s), not Volt''s 90 s window'
    $first = $script:starts[0].tracker
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:starts.Count -eq 1) 'second launch waits for the launch slot'
    $script:nativeLastLaunchUtc = [datetime]::UtcNow.AddSeconds(-13); $script:launchAttempts = @([datetime]::UtcNow.AddSeconds(-13))
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:starts.Count -eq 2 -and $script:starts[1].tracker -ne $first) 'second account launches after launchDelaySec (12 s), not after retry_base_sec (90 s)'
    $pendingB = $script:recoveryPending[$(if ($first -eq $TA) { $B } else { $A })]
    Assert ($pendingB.retryCount -eq 1 -and ([datetime]$pendingB.nextRetryUtc - [datetime]::UtcNow).TotalSeconds -gt 100) 'a launch is only retried after launchTimeoutSec'
    # Farm stopped: queued relaunches are dropped.
    $vault = Vault; $vault.settings.farmRunning = $false; Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.Count -eq 0) 'stopping the farm cancels queued launches'

    # --- Nothing secret anywhere it could be shown or logged.
    $all = ($script:events | ConvertTo-Json -Depth 8) + ($script:warned -join "`n") + ((Get-ArkuzoNativeStatus) | ConvertTo-Json -Depth 8)
    Assert ($all -notmatch 'WARNING:-DO-NOT|LinkCode123|dpapi:|TICKET-') 'no cookie, ticket or link code in diagnostics, warnings or status'

    # --- Provider choice: auto follows the vault; explicit settings win.
    $script:accountProvider = 'volt'; $script:accountProviderSetting = 'auto'
    function Clear-VoltRecoveryCapability { }
    Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'arkuzo') 'auto picks Arkuzo once the vault has accounts'
    $script:accountProviderSetting = 'volt'; Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'volt') 'volt setting keeps Volt'
    Remove-Item -LiteralPath (Get-ArkuzoVaultPath)
    $script:accountProviderSetting = 'auto'; Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'volt') 'auto without accounts stays on Volt'
    Assert ((Get-ArkuzoProviderSetting ([pscustomobject]@{ accounts = [pscustomobject]@{ provider = 'nonsense' } })) -eq 'auto') 'unknown provider setting falls back to auto'

    Write-Host "PASS: Arkuzo accounts: DPAPI interop, exact mapping, CSRF ticket, cookie rotation, paced launches without backoff, safety refusals, no secrets ($script:checks checks)"
} finally {
    Remove-Item -LiteralPath $DataDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
