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
    $script:nativeVoltConflict = @{ checkedUtc = [datetime]::UtcNow; userIds = @(); usernames = @() }
    $script:lastClientStartUtc = $null; $script:farmFreeze = $null
    $script:clients = @(); $script:posts = New-Object Collections.ArrayList; $script:starts = New-Object Collections.ArrayList
    $script:roblox = @{}  # cookie -> @{ status; rotate }
    $script:nativeTicketJobs = @{}; $script:nativeLaunchPids = @{}; $script:nativeLaunchTrackers = @{}; $script:nativeLaunchExits = @{}
    $script:ticketHold = $false; $script:stoppedJobs = 0; $script:outcomeJournalSavedUtc = $null
}
# Fakes for the only parts that touch the machine or the network.
function Get-ArkuzoNativeClients { return ,@($script:clients) }
function Invoke-ArkuzoRobloxPost([string]$Url, [string]$Cookie, [string]$Csrf = '') {
    [void]$script:posts.Add(@{ url = $Url; csrf = $Csrf })
    $known = $script:roblox[$Cookie]
    $rotated = if ($null -ne $known -and $known.rotate) { $known.rotate } else { $null }
    if ($null -eq $known) { return @{ status = 401; rotated = $null } }
    if (-not $Csrf) { return @{ status = 403; csrf = 'tok-1'; rotated = $rotated } }
    if ($known.moderated) { return @{ status = 403; rotated = $rotated; moderated = $true } }  # "User is moderated"
    if ($known.refuse) { return @{ status = [int]$known.refuse; rotated = $rotated } }
    return @{ status = 200; ticket = 'TICKET-' + $Cookie.Length; rotated = $rotated }
}
# The ticket request normally runs in a runspace (NativeTicket.Tests.ps1 covers that against a
# local endpoint). Here it runs in-process against the fake above; $ticketHold keeps it "in flight".
function Start-ArkuzoNativeTicketJob([string]$Cookie, [string]$Url) { if ($script:ticketHold) { return @{ Cookie = $Cookie; Done = $false } }; return @{ Done = $true; Result = (Get-ArkuzoAuthTicket $Cookie) } }
function Receive-ArkuzoNativeTicketJob($Job) { if (-not $Job.Done) { if ($script:ticketHold) { return $null }; return (Get-ArkuzoAuthTicket $Job.Cookie) }; return $Job.Result }
function Stop-ArkuzoNativeTicketJob($Job) { $script:stoppedJobs++ }
function Clear-ArkuzoRobloxSavedLogin { return $false }  # Never touch this PC's real Roblox folder (RobloxSavedLogin.Tests.ps1 covers it).
function Start-ArkuzoRobloxClient([string]$Ticket, [string]$JoinUrl, [string]$TrackerId, [string]$Method, $Clients, $Player = $null) {
    [void]$script:starts.Add(@{ ticket = $Ticket; url = $JoinUrl; tracker = $TrackerId; method = $Method; player = $Player }); return @{ method = 'direct'; pid = 999 }
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
    $script:ticketHold = $true
    $r = Invoke-ArkuzoNativeLaunch $B $TB
    Assert ($r.requestAccepted -and $script:nativeTicketJobs.ContainsKey($B) -and $script:starts.Count -eq 0) ('step 1 only requests the ticket: ' + $r.reason)
    Assert ((@((Get-ArkuzoNativeStatus).accounts | Where-Object { $_.accountId -eq $B })[0]).uiStatus -eq 'Launching') 'while the ticket is requested the account shows Launching'
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted) 'no second launch while the ticket is requested'
    Complete-ArkuzoNativeLaunches
    Assert ($script:starts.Count -eq 0 -and $script:nativeTicketJobs.ContainsKey($B)) 'nothing starts before Roblox answers'
    Assert (-not (Test-ArkuzoNativeLaunchSlot ([datetime]::UtcNow.AddSeconds(60)))) 'one ticket request at a time: no launch slot while one is in flight'
    $script:ticketHold = $false
    Complete-ArkuzoNativeLaunches
    Assert (-not $script:nativeTicketJobs.ContainsKey($B)) 'step 2 ends the ticket request'
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
    $r = Invoke-ArkuzoNativeLaunch $A $TA; Complete-ArkuzoNativeLaunches
    Assert ((Row $A).cookieStatus -eq 'dead' -and $script:starts.Count -eq 0 -and -not $script:nativeLaunches.ContainsKey($A)) '401 at launch marks the cookie dead'
    Assert (@($script:events | Where-Object { $_.kind -eq 'NATIVE_COOKIE_DEAD' }).Count -eq 1) 'dead cookie reported'
    # --- A moderated account (9 Nov: 10 accounts, 93 refused launches): marked once, never retried.
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'b')] = @{ moderated = $true }
    $r = Invoke-ArkuzoNativeLaunch $B $TB; Complete-ArkuzoNativeLaunches
    Assert ((Row $B).cookieStatus -eq 'moderated' -and $script:starts.Count -eq 0) '"User is moderated" at launch marks the account moderated; nothing starts'
    Assert (@($script:events | Where-Object { $_.kind -eq 'NATIVE_ACCOUNT_MODERATED' }).Count -eq 1 -and (Row $B).lastError -match 'moderated') 'moderation reported with a reason'
    $sb = @((Get-ArkuzoNativeStatus).accounts | Where-Object { $_.accountId -eq $B })[0]
    Assert ($sb.cookieStatus -eq 'moderated' -and -not $sb.cookieAlive -and -not $sb.controlReady -and -not $sb.suspensionSafe) 'status shows it moderated, never launch-ready'
    Assert ((Invoke-Py "from pathlib import Path`nv=cc.load_vault(Path(r'$DataDirectory'))`nprint([a['cookieStatus'] for a in v['accounts'] if a['id']=='$B'][0])") -ceq 'moderated') 'Control Center keeps the moderated status'
    $postCount = $script:posts.Count
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted -and $script:posts.Count -eq $postCount)'a moderated account is not even asked for a ticket again'
    # A queued relaunch for it is dropped, so it never holds the recovery queue.
    $script:recoveryPending = @{ $B = (New-ArkuzoPendingEntry $B $TB) }; $script:sessionObservedAccounts = @{ $B = $true }
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert (-not $script:recoveryPending.ContainsKey($B) -and $script:recoveryPending.ContainsKey($A)) 'its queued relaunch is cancelled; the other accounts stay queued'
    Assert (@($script:events | Where-Object { $_.kind -eq 'RECOVERY_CANCELLED_BY_POLICY' -and $_.data.note -eq 'Account moderated by Roblox' }).Count -eq 1) 'cancellation logged'
    Update-ArkuzoRecoveryOutcomes
    Assert (-not $script:recoveryPending.ContainsKey($B)) 'and it is not queued again while moderated'
    # Once a cookie check finds it alive again it farms again.
    $vault = Vault; @($vault.accounts | Where-Object { $_.id -eq $B })[0].cookieStatus = 'alive'; Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.ContainsKey($B)) 'alive again: queued for launch'
    # Dead, stopped farm, Volt conflict and a running client all refuse.
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'c')] = @{ }
    Assert (-not (Invoke-ArkuzoNativeLaunch $C $TC).requestAccepted) 'dead account never launches'
    New-Vault @{ farmRunning = $false }; $script:roblox[(Fake-Cookie 'b')] = @{ }
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted) 'stopped farm: no automatic launch'
    Assert ((Invoke-ArkuzoNativeLaunch $B $TB -Manual).requestAccepted) 'stopped farm: the Launch button still works'
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:nativeVoltConflict = @{ checkedUtc = [datetime]::UtcNow; userIds = @('102'); usernames = @('farmbravo') }
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted -and $script:starts.Count -eq 0) 'Volt auto-relaunch on the same account blocks Arkuzo launches'
    Assert ((Get-ArkuzoNativeStatus).accounts[1].voltConflict -and $script:accountProviderNotice -match 'Volt is running 1') 'conflict is shown'
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:clients = @([pscustomobject]@{ processId = 600; trackerId = $TB; path = '' })
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted -and $script:starts.Count -eq 0) 'an account already in game is not launched again'

    # --- A pinned Roblox build (docs/roblox-versions.md): missing = refused before any ticket request;
    # present = that exe is started; removed while the ticket was requested = not started at all.
    $pinRoot = Join-Path $DataDirectory 'roblox'
    $pinned = @{ robloxVersion = 'version-0123456789abcdef'; robloxVersionsDir = $pinRoot }
    Reset-Engine; New-Vault $pinned; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $postCount = $script:posts.Count
    $r = Invoke-ArkuzoNativeLaunch $B $TB -Manual
    Assert (-not $r.requestAccepted -and $r.reason -match 'not installed' -and $script:posts.Count -eq $postCount) ('a missing pinned build refuses before a ticket is requested: ' + $r.reason)
    Assert (@($script:events | Where-Object { $_.kind -ceq 'ROBLOX_VERSION_PIN_MISSING' }).Count -eq 1) 'the missing pin is logged'
    $pinDir = [IO.Path]::Combine($pinRoot, 'Versions', 'version-0123456789abcdef')
    [void][IO.Directory]::CreateDirectory($pinDir)
    [IO.File]::WriteAllText((Join-Path $pinDir 'RobloxPlayerBeta.exe'), 'x'); [IO.File]::WriteAllText((Join-Path $pinDir 'AppSettings.xml'), '<Settings/>')
    Reset-Engine; New-Vault ($pinned + @{ launchMethod = 'protocol' }); $script:roblox[(Fake-Cookie 'b')] = @{ }
    $r = Invoke-ArkuzoNativeLaunch $B $TB -Manual; Complete-ArkuzoNativeLaunches
    Assert ($r.requestAccepted -and $script:starts.Count -eq 1 -and $script:starts[0].player.path -eq (Join-Path $pinDir 'RobloxPlayerBeta.exe') -and $script:starts[0].player.method -ceq 'direct') 'the pinned exe starts, directly even with the protocol method'
    Assert ($script:robloxVersionStatus.selectedVersion -ceq 'version-0123456789abcdef') 'the heartbeat block names the pinned build'
    Reset-Engine; New-Vault $pinned; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:ticketHold = $true
    Assert ((Invoke-ArkuzoNativeLaunch $B $TB -Manual).requestAccepted) 'pinned build present: ticket requested'
    Remove-Item -LiteralPath (Join-Path $pinDir 'AppSettings.xml')
    $script:ticketHold = $false; Complete-ArkuzoNativeLaunches
    Assert ($script:starts.Count -eq 0 -and @($script:events | Where-Object { $_.kind -ceq 'NATIVE_LAUNCH_FAILED' -and $_.data.reason -match 'not installed' }).Count -eq 1) 'a pin that disappears during the ticket request is not replaced by another build'
    Remove-Item -LiteralPath $pinRoot -Recurse -Force

    # --- Cadence: while launches are queued the outcome step runs on every pass, so
    # launchDelaySec (not a 10 s cadence) is the spacing between launches.
    Reset-Engine
    Assert ((Get-ArkuzoOutcomeCheckDelay) -eq 3) 'Arkuzo, nothing queued: every 3 s'
    $script:recoveryPending = @{ $A = (New-ArkuzoPendingEntry $A $TA) }
    Assert ((Get-ArkuzoOutcomeCheckDelay) -eq 0) 'Arkuzo, launches queued: every pass'
    $script:accountProvider = 'volt'
    Assert ((Get-ArkuzoOutcomeCheckDelay) -eq 10) 'Volt keeps its 10 s cadence'

    # --- Farm start: missing accounts are queued and launched one per launch slot, no backoff.
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'a')] = @{ }; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.ContainsKey($A) -and $script:recoveryPending.ContainsKey($B) -and -not $script:recoveryPending.ContainsKey($C)) 'farm start queues every alive opted-in account, never launched before or not'
    foreach ($k in @($script:recoveryPending.Keys)) { $script:recoveryPending[$k].createdUtc = [datetime]::UtcNow.AddSeconds(-9).ToString('o') }
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes; Complete-ArkuzoNativeLaunches
    Assert ($script:starts.Count -eq 1) 'first launch after relaunchDelaySec (8 s), not Volt''s 90 s window'
    $first = $script:starts[0].tracker
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes; Complete-ArkuzoNativeLaunches
    Assert ($script:starts.Count -eq 1) 'second launch waits for the launch slot'
    $script:nativeLastLaunchUtc = [datetime]::UtcNow.AddSeconds(-13); $script:launchAttempts = @([datetime]::UtcNow.AddSeconds(-13))
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes; Complete-ArkuzoNativeLaunches
    Assert ($script:starts.Count -eq 2 -and $script:starts[1].tracker -ne $first) 'second account launches after launchDelaySec (12 s), not after retry_base_sec (90 s)'
    $pendingB = $script:recoveryPending[$(if ($first -eq $TA) { $B } else { $A })]
    Assert ($pendingB.retryCount -eq 1 -and (([datetime]$pendingB.nextRetryUtc).ToUniversalTime() - [datetime]::UtcNow).TotalSeconds -gt 100) 'a launch that started a client is retried only after launchTimeoutSec if nothing shows up'
    # Farm stopped: queued relaunches are dropped.
    $vault = Vault; $vault.settings.farmRunning = $false; Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoRecoveryOutcomes
    Assert ($script:recoveryPending.Count -eq 0) 'stopping the farm cancels queued launches'

    # --- A launch Roblox refuses is retried after the relaunch delay, not after launchTimeoutSec;
    # an outage never parks an account (no quarantine, no hourly launch cap).
    function Step-Farm { $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow; Update-ArkuzoRecoveryOutcomes; Complete-ArkuzoNativeLaunches }
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'a')] = @{ refuse = 503 }; $script:roblox[(Fake-Cookie 'b')] = @{ refuse = 503 }
    Step-Farm
    foreach ($k in @($script:recoveryPending.Keys)) { $script:recoveryPending[$k].createdUtc = [datetime]::UtcNow.AddSeconds(-9).ToString('o') }
    Step-Farm
    $refused = @($script:recoveryPending.Values | Where-Object { $_.retryCount -eq 1 })
    Assert ($refused.Count -eq 1 -and $script:starts.Count -eq 0) 'one launch requested and refused by Roblox (503)'
    $wait = (([datetime]$refused[0].nextRetryUtc).ToUniversalTime() - [datetime]::UtcNow).TotalSeconds
    Assert ($wait -gt 5 -and $wait -le 8.5) ('a refused launch is retried after the relaunch delay (8 s), not launchTimeoutSec: ' + $wait)
    Assert (@($script:events | Where-Object { $_.kind -eq 'NATIVE_LAUNCH_FAILED' -and $_.data.reason -match '503' }).Count -eq 1) 'the refusal is logged with its status'
    Assert (-not $script:nativeLaunches.ContainsKey($refused[0].accountId)) 'a refused launch is not left "in flight"'
    # Thirty refusals later, three hours on: still queued, still retried (no quarantine, no hourly cap).
    foreach ($e in @($script:recoveryPending.Values)) { $e.retryCount = 30; $e.createdUtc = [datetime]::UtcNow.AddHours(-3).ToString('o'); $e.nextRetryUtc = $null; $e.lastLaunchUtc = [datetime]::UtcNow.AddSeconds(-30).ToString('o') }
    $script:launchAttempts = @(1..200 | ForEach-Object { [datetime]::UtcNow.AddSeconds(-15 - $_) })
    $script:quarantinedAccounts = @{ $A = @{ accountId = $A; untilUtc = [datetime]::UtcNow.AddMinutes(25).ToString('o') } }
    $script:nativeLastLaunchUtc = $null; $before = $script:posts.Count
    Step-Farm
    Assert ($script:recoveryPending.Count -eq 2 -and @($script:events | Where-Object { $_.kind -eq 'RECOVERY_QUARANTINED' }).Count -eq 0) 'Arkuzo never quarantines a failing account'
    Assert ($script:posts.Count -gt $before) 'an outage (200 launches in the last hour) does not stop launches: launchDelaySec is the only limit'
    Assert (-not $script:quarantinedAccounts.ContainsKey($A) -and -not (Test-ArkuzoAccountQuarantined $A ([datetime]::UtcNow))) 'a quarantine left in the journal by an earlier version is cleared for vault accounts'
    $script:accountProvider = 'volt'; $script:quarantinedAccounts = @{ $A = @{ accountId = $A; untilUtc = [datetime]::UtcNow.AddMinutes(25).ToString('o') } }
    Assert (Test-ArkuzoAccountQuarantined $A ([datetime]::UtcNow)) 'Volt keeps its quarantine'
    $script:accountProvider = 'arkuzo'

    # --- Fair order: the account tried least recently goes first, so one that keeps failing
    # at the relaunch delay can't take every launch slot.
    Reset-Engine; New-Vault
    $script:roblox[(Fake-Cookie 'a')] = @{ }; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $ea = New-ArkuzoPendingEntry $A $TA; $ea.createdUtc = [datetime]::UtcNow.AddMinutes(-10).ToString('o'); $ea.retryCount = 5; $ea.lastLaunchUtc = [datetime]::UtcNow.AddSeconds(-20).ToString('o')
    $eb = New-ArkuzoPendingEntry $B $TB; $eb.createdUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
    $script:recoveryPending = @{ $A = $ea; $B = $eb }; $script:sessionObservedAccounts = @{ $A = $true; $B = $true }
    Step-Farm
    Assert ($script:starts.Count -eq 1 -and $script:starts[0].tracker -eq $TB) 'an account never tried goes before one that just failed'
    $eb.lastLaunchUtc = [datetime]::UtcNow.AddSeconds(-5).ToString('o'); $script:nativeLaunches.Clear(); $script:nativeLastLaunchUtc = $null; $script:clients = @(); $script:launchAttempts = @()
    $eb.nextRetryUtc = $null; $ea.nextRetryUtc = $null
    Step-Farm
    Assert ($script:starts.Count -eq 2 -and $script:starts[1].tracker -eq $TA) 'then the one tried longest ago'

    # --- A launched client that closes before it is in game: relaunch after the relaunch delay.
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $eb = New-ArkuzoPendingEntry $B $TB; $eb.createdUtc = [datetime]::UtcNow.AddSeconds(-30).ToString('o')
    $script:recoveryPending = @{ $B = $eb }; $script:sessionObservedAccounts = @{ $B = $true }
    Step-Farm
    Assert ($script:starts.Count -eq 1 -and $script:nativeLaunchPids[$B] -eq 999) 'launched (direct, pid 999)'
    $script:nativeLaunches[$B] = [datetime]::UtcNow.AddSeconds(-5)   # pid 999 never shows up in the process list
    Step-Farm
    Assert (@($script:events | Where-Object { $_.kind -eq 'NATIVE_LAUNCH_EXITED' }).Count -eq 1 -and $eb.closedUtc -and -not $eb.nextRetryUtc) 'a client that died before showing up is noticed and its retry waits only the relaunch delay'
    Assert ($script:starts.Count -eq 1) 'not relaunched within the relaunch delay'
    $eb.closedUtc = [datetime]::UtcNow.AddSeconds(-9).ToString('o'); $script:nativeLastLaunchUtc = $null; $script:launchAttempts = @()
    Step-Farm
    Assert ($script:starts.Count -eq 2) 'relaunched after the relaunch delay (8 s), not launchTimeoutSec (120 s)'
    # A tracked client of the queued account exits (crash while loading): same.
    $script:clients = @([pscustomobject]@{ processId = 610; trackerId = $TB; path = '' }); $script:voltControlStatus = Get-ArkuzoNativeStatus
    Register-ArkuzoNativeLaunchExit 610 @{ TrackerId = $TB; StartTicks = 5; RecoveryRequested = $false }
    Assert ($script:nativeLaunchExits.ContainsKey($B)) 'a queued account''s client that exits is noted'
    $script:recoveryPending.Remove($A)
    Register-ArkuzoNativeLaunchExit 611 @{ TrackerId = $TA; StartTicks = 5; RecoveryRequested = $false }
    Assert (-not $script:nativeLaunchExits.ContainsKey($A)) 'an account that is not queued is left to the missing-account check'

    # --- Close while a launch is in flight (B2): the stamp stays until nothing is left, the
    # ticket request is cancelled, a late ticket never starts a client, and no relaunch races it.
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $script:ticketHold = $true
    Assert ((Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted) 'launch in flight'
    $vault = Vault; @($vault.accounts | Where-Object { $_.id -eq $B })[0].closeRequestedAtMs = 1234; Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
    $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
    Invoke-ArkuzoNativeRequests
    Assert ($script:stoppedJobs -eq 1 -and -not $script:nativeTicketJobs.ContainsKey($B) -and (Row $B).closeRequestedAtMs -eq 1234) 'Close cancels the ticket request and keeps the stamp this pass'
    $script:voltControlStatus = Get-ArkuzoNativeStatus
    Invoke-ArkuzoNativeRequests
    Assert ((Row $B).closeRequestedAtMs -eq 0) 'next pass: no client and no launch in flight, the stamp is cleared'
    # A client that appears after Close (it was started just before) keeps the stamp until it is closed.
    $vault = Vault; @($vault.accounts | Where-Object { $_.id -eq $B })[0].closeRequestedAtMs = 1234; Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
    $script:clients = @([pscustomobject]@{ processId = 620; trackerId = $TB; path = '' })   # not tracked yet: first contact comes later in the pass
    $script:voltControlStatus = Get-ArkuzoNativeStatus
    Invoke-ArkuzoNativeRequests
    Assert ((Row $B).closeRequestedAtMs -eq 1234) 'a live client that could not be closed yet keeps the stamp'
    $p620 = [pscustomobject]@{ Id = 620; StartTime = [datetime]::UtcNow.AddSeconds(-3); HasExited = $false; ProcessName = 'RobloxPlayerBeta' }
    $p620 | Add-Member ScriptMethod Refresh { }; $p620 | Add-Member ScriptMethod Kill { $this.HasExited = $true }; $p620 | Add-Member ScriptMethod WaitForExit { param($ms) $this.HasExited }
    $script:tracked = @{ 620 = @{ Watcher = $p620; TrackerId = $TB; StartTicks = $p620.StartTime.ToUniversalTime().Ticks; RecoveryRequested = $false } }
    Invoke-ArkuzoNativeRequests
    Assert ($p620.HasExited -and $script:tracked[620].RecoveryRequested -and (Row $B).closeRequestedAtMs -eq 1234) 'once tracked it is closed (exact pid and start time); the stamp stays this pass'
    $script:clients = @(); $script:tracked = @{}; $script:voltControlStatus = Get-ArkuzoNativeStatus
    Invoke-ArkuzoNativeRequests
    Assert ((Row $B).closeRequestedAtMs -eq 0) 'gone: stamp cleared'
    # A ticket that arrives after Close never starts a client; the farm does not relaunch it while the stamp is set.
    $script:ticketHold = $true; $script:starts.Clear()
    Assert ((Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted) 'another launch in flight'
    $vault = Vault; @($vault.accounts | Where-Object { $_.id -eq $B })[0].closeRequestedAtMs = 99; Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
    $script:ticketHold = $false
    Complete-ArkuzoNativeLaunches
    Assert ($script:starts.Count -eq 0 -and @($script:events | Where-Object { $_.kind -eq 'NATIVE_LAUNCH_FAILED' -and $_.data.reason -eq 'Close requested' }).Count -eq 1) 'a ticket that arrives after Close starts nothing'
    Assert (-not (Invoke-ArkuzoNativeLaunch $B $TB).requestAccepted) 'no launch while the close stamp is set'
    $eb = New-ArkuzoPendingEntry $B $TB; $eb.createdUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o'); $script:recoveryPending = @{ $B = $eb }; $script:sessionObservedAccounts = @{ $B = $true }
    $script:nativeLaunches.Clear(); $script:nativeLastLaunchUtc = $null; $before = $script:launchAttempts.Count
    Step-Farm
    Assert ($script:starts.Count -eq 0 -and $eb.retryCount -eq 0 -and $script:launchAttempts.Count -eq $before) 'the farm waits for the close to finish, nothing charged'

    # --- A launched client that never opens its window is closed for a fresh launch (9 Nov).
    function New-StalledClient([int]$AgeSec, [bool]$Window) {
        $p = [pscustomobject]@{ Id = 700; StartTime = [datetime]::UtcNow.AddSeconds(-$AgeSec); HasExited = $false; ProcessName = 'RobloxPlayerBeta'; Kills = 0 }
        $p | Add-Member ScriptMethod Refresh { }
        $p | Add-Member ScriptMethod Kill { $this.Kills++; $this.HasExited = $true }
        $script:clients = @([pscustomobject]@{ processId = 700; trackerId = $TB; path = '' })
        $script:tracked = @{ 700 = @{ Watcher = $p; TrackerId = $TB; StartTicks = $p.StartTime.ToUniversalTime().Ticks; GameReady = $false; isDisconnected = $false
            HealthSnapshotUtc = [datetime]::UtcNow.ToString('o'); LastSnapshot = @{ windowPresent = $Window; responding = $Window; launchError = $false } } }
        $entry = New-ArkuzoPendingEntry $B $TB; $entry.createdUtc = [datetime]::UtcNow.AddSeconds(-$AgeSec - 20).ToString('o')
        $script:recoveryPending = @{ $B = $entry }; $script:sessionObservedAccounts = @{ $B = $true }
        $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
        return $p
    }
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $p = New-StalledClient 600 $false; Update-ArkuzoRecoveryOutcomes
    Assert ($p.Kills -eq 1 -and @($script:events | Where-Object { $_.kind -eq 'NATIVE_LAUNCH_STALLED' }).Count -eq 1) 'a launch with no window after launchTimeoutSec is closed'
    Assert ($script:recoveryPending.ContainsKey($B)) 'the account stays queued for a fresh launch'
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $p = New-StalledClient 60 $false; Update-ArkuzoRecoveryOutcomes
    Assert ($p.Kills -eq 0) 'a launch still inside launchTimeoutSec is left loading'
    Reset-Engine; New-Vault; $script:roblox[(Fake-Cookie 'b')] = @{ }
    $p = New-StalledClient 600 $true; Update-ArkuzoRecoveryOutcomes
    Assert ($p.Kills -eq 0) 'a launch with a window is left to the health checks'

    # --- Nothing secret anywhere it could be shown or logged.
    $all = ($script:events | ConvertTo-Json -Depth 8) + ($script:warned -join "`n") + ((Get-ArkuzoNativeStatus) | ConvertTo-Json -Depth 8)
    Assert ($all -notmatch 'WARNING:-DO-NOT|LinkCode123|dpapi:|TICKET-') 'no cookie, ticket or link code in diagnostics, warnings or status'

    # --- Provider choice: auto follows the vault unless Volt runs the farm; explicit settings win.
    $script:accountProvider = 'volt'; $script:accountProviderSetting = 'auto'
    function Clear-VoltRecoveryCapability { }
    $script:voltRunning = $true
    function Test-ArkuzoVoltRelaunching { $script:voltRunning }
    Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'volt' -and $script:accountProviderNotice -match 'Volt is running its own clients') 'auto keeps a relaunching Volt farm on Volt (its clients are not in the vault)'
    $script:voltRunning = $false
    Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'arkuzo') 'auto picks Arkuzo once the vault has accounts and Volt is closed'
    $script:voltRunning = $true
    Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'arkuzo') 'starting Volt later does not flip an active Arkuzo farm back'
    # Suspensions belong to the launcher that made them: account ids differ between the two.
    $script:suspendedAccounts = @{ 'aaaaaaaa-0000-4000-8000-000000000009' = @{ accountId = 'aaaaaaaa-0000-4000-8000-000000000009'; reason = 'COOKIE_DEAD' } }
    $script:voltControlStatus = [pscustomobject]@{ available = $true; globalMappingSafe = $true; accounts = @() }
    Assert (Test-ArkuzoSuspendedRowsSafe) 'a Volt suspension does not block Arkuzo recovery'
    $script:configFilePath = $null
    $script:voltControlCheckedUtc = [datetime]::UtcNow
    Update-ArkuzoCookieSuspensions
    Assert (@($restorePolicy.excluded_account_ids).Count -eq 0) 'a Volt suspension is never auto-excluded after switching to Arkuzo'
    $script:accountProviderSetting = 'volt'; Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'volt') 'volt setting keeps Volt'
    Remove-Item -LiteralPath (Get-ArkuzoVaultPath)
    $script:accountProviderSetting = 'auto'; Resolve-ArkuzoAccountProvider
    Assert ($script:accountProvider -eq 'volt') 'auto without accounts stays on Volt'
    Assert ((Get-ArkuzoProviderSetting ([pscustomobject]@{ accounts = [pscustomobject]@{ provider = 'nonsense' } })) -eq 'auto') 'unknown provider setting falls back to auto'

    # --- Window layout. Roblox never makes its window smaller than 800 x 622 (visible, 100%),
    # so every layout plans with that size and keeps every window on screen (9 Nov: 384 px cells
    # left 800 px windows piled up and running off the right edge).
    $script:arrangeMinWindow = @{}
    $onScreen = { param($slots, $area) @($slots | Where-Object { $_[0] -lt $area[0] -or $_[1] -lt $area[1] -or $_[0] + $_[2] -gt $area[2] -or $_[1] + $_[3] -gt $area[3] }).Count -eq 0 }
    $screen = @(0, 0, 1920, 1032, 96)
    $set = @{ layout = 'grid'; perRow = 2; width = 900; height = 700; gap = 4; corner = 'top-left'; order = 'fixed' }
    $s = Get-ArkuzoWindowSlots 2 $screen $set
    Assert (($s[0] -join ',') -eq '0,0,900,700' -and ($s[1] -join ',') -eq '904,0,900,700' -and -not (Test-ArkuzoSlotsOverlap $s)) 'grid: a size Roblox accepts, side by side with the gap'
    $set.width = 320; $set.height = 240
    $s = Get-ArkuzoWindowSlots 2 $screen $set
    Assert (($s[0] -join ',') -eq '0,0,800,622' -and ($s[1] -join ',') -eq '804,0,800,622') 'grid: a size below Roblox''s minimum is raised to 800 x 622'
    $set.perRow = 12
    $s = Get-ArkuzoWindowSlots 10 $screen $set
    Assert ((& $onScreen $s $screen) -and (Test-ArkuzoSlotsOverlap $s) -and ($s[9] -join ',') -eq '1116,0,800,622' -and $s[1][0] -eq 124) 'grid: a row too wide for the screen overlaps evenly and stays on screen'
    $set.perRow = 3
    $s = Get-ArkuzoWindowSlots 10 $screen $set
    Assert ((& $onScreen $s $screen) -and ($s[3] -join ',') -eq '0,136,800,622' -and ($s[9] -join ',') -eq '0,408,800,622') 'grid: rows too tall for the screen overlap evenly, last row still on screen'
    $set.perRow = 2; $set.corner = 'bottom-right'
    $s = Get-ArkuzoWindowSlots 2 $screen $set
    Assert (($s[0] -join ',') -eq '1120,410,800,622' -and ($s[1] -join ',') -eq '316,410,800,622') 'bottom-right corner mirrors the grid'
    $set.corner = 'top-left'
    $s = Get-ArkuzoWindowSlots 1 @(1920, 0, 4480, 1400, 144) $set
    Assert (($s[0] -join ',') -eq '1920,0,1200,933') 'second monitor at 150%: the minimum scales to physical pixels'
    $script:arrangeMinWindow['96'] = @(820, 640)
    Assert (((Get-ArkuzoRobloxMinWindow 96) -join 'x') -eq '820x640' -and ((Get-ArkuzoWindowSlots 1 $screen $set)[0][2]) -eq 820) 'a larger minimum seen on screen is learned and used'
    $script:arrangeMinWindow = @{}
    $set.layout = 'cascade'
    $s = Get-ArkuzoWindowSlots 3 $screen $set
    Assert (($s[2] -join ',') -eq '64,64,800,622') 'cascade steps diagonally at Roblox''s minimum size'
    $s = Get-ArkuzoWindowSlots 20 $screen $set
    Assert (& $onScreen $s $screen) 'cascade wraps before running off the screen'
    $accts = @([pscustomobject]@{ accountId = 'b'; displayName = 'Bravo'; autoRelaunch = $false; cookieAlive = $true }, [pscustomobject]@{ accountId = 'a'; displayName = 'alpha'; autoRelaunch = $true; cookieAlive = $true },
        [pscustomobject]@{ accountId = 'c'; displayName = 'Charlie'; autoRelaunch = $true; cookieAlive = $true }, [pscustomobject]@{ accountId = 'd'; displayName = 'Delta'; autoRelaunch = $false; cookieAlive = $true })
    $live = @([pscustomobject]@{ accountId = 'c'; name = 'Charlie'; startTicks = 1 }, [pscustomobject]@{ accountId = 'b'; name = 'Bravo'; startTicks = 2 })
    $t = Get-ArkuzoArrangeTargets $live $accts @{ order = 'fixed' }
    Assert ($t['a'] -eq 0 -and $t['b'] -eq 1 -and $t['c'] -eq 2 -and -not $t.ContainsKey('d')) 'fixed order: farm accounts keep their spot while relaunching; switched-off offline accounts take none'
    # Auto: side by side as large as fits; with more windows than fit, an even overlap.
    $auto = @{ layout = 'auto'; perRow = 12; width = 160; height = 160; gap = 4; corner = 'top-left' }
    $s = Get-ArkuzoWindowSlots 2 $screen $auto
    Assert (($s[0] -join ',') -eq '0,0,958,744' -and ($s[1] -join ',') -eq '962,0,958,744' -and -not (Test-ArkuzoSlotsOverlap $s)) 'auto: 2 windows side by side, larger than the minimum, in Roblox''s shape'
    $s = Get-ArkuzoWindowSlots 10 $screen $auto
    Assert ((& $onScreen $s $screen) -and (($s | ForEach-Object { $_[0] }) -join ',') -eq '0,280,560,840,1120,0,280,560,840,1120' -and $s[5][1] -eq 410 -and $s[0][2] -eq 800) 'auto: 10 windows in 5 x 2 at 800 x 622, each keeping a 280 x 410 corner in view, all on screen'
    $s = Get-ArkuzoWindowSlots 13 $screen $auto
    Assert ((& $onScreen $s $screen) -and (Test-ArkuzoSlotsOverlap $s)) 'auto: 13 windows still all on screen'
    $s = Get-ArkuzoWindowSlots 1 $screen $auto
    Assert ($s[0][3] -le 1032 -and $s[0][2] -le 1920 -and $s[0][3] -ge 1000) 'auto: a single window fills the height'
    Assert ((Get-ArkuzoWindowSlots 0 $screen $auto).Count -eq 0) 'no windows, no slots'
    # A window counts as in place only at its slot and neither minimized nor maximized.
    Assert ((Test-ArkuzoWindowInPlace @(0, 0, 800, 622, 0, 0) @(1, 2, 800, 622)) -and -not (Test-ArkuzoWindowInPlace @(0, 0, 800, 622, 0, 1) @(0, 0, 800, 622)) -and
        -not (Test-ArkuzoWindowInPlace @(0, 0, 800, 622, 1, 0) @(0, 0, 800, 622)) -and -not (Test-ArkuzoWindowInPlace @(0, 0, 800, 622, 0, 0) @(0, 0, 384, 288))) 'in place: 2 px slack; a maximized or minimized window, or one of another size, is placed again'
    $t = Get-ArkuzoArrangeTargets $live $accts @{ order = 'name' }
    Assert ($t['b'] -eq 0 -and $t['c'] -eq 1 -and -not $t.ContainsKey('a')) 'by name: running clients only, no gaps'
    $t = Get-ArkuzoArrangeTargets $live $accts @{ order = 'launch' }
    Assert ($t['c'] -eq 0 -and $t['b'] -eq 1) 'by launch: oldest client first'
    $cfg = Get-ArkuzoArrangeSettings ([pscustomobject]@{ settings = [pscustomobject]@{ arrangePerRow = 99; arrangeLayout = 'spiral'; arrangeVisibility = 'background'; arrangeWidth = 400 } })
    Assert ($cfg.perRow -eq 2 -and $cfg.layout -eq 'auto' -and $cfg.visibility -eq 'background' -and $cfg.width -eq 400 -and $cfg.enabled) 'invalid layout settings fall back to defaults; valid ones are kept'
    # Arrange now stores a millisecond timestamp: it must read back, not overflow (crashed the saver).
    $cfg = Get-ArkuzoArrangeSettings ([pscustomobject]@{ settings = [pscustomobject]@{ arrangeRequestedAtMs = 1794149549000 } })
    Assert ($cfg.requestMs -eq 1794149549000) 'Arrange now timestamp reads back as a long'
    $script:nativeVault = [pscustomobject]@{ settings = [pscustomobject]@{ arrangeRequestedAtMs = 1794149549000; arrangeWindows = $true } }
    $script:accountProvider = 'arkuzo'; $script:voltControlStatus = [pscustomobject]@{ available = $true; accounts = @() }; $script:tracked = @{}
    Update-ArkuzoWindowArrangement
    Assert ($script:arrangeHandledRequestMs -eq 1794149549000) 'Arrange now request is handled without throwing'

    Write-Host "PASS: Arkuzo accounts: DPAPI interop, exact mapping, CSRF ticket, cookie rotation, paced launches without backoff, safety refusals, no secrets ($script:checks checks)"
} finally {
    Remove-Item -LiteralPath $DataDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
