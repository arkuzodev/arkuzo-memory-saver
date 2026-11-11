# ---------------------------------------------------------------------------
# Arkuzo account provider: launching and relaunching without Volt.
# The Control Center keeps accounts in data/accounts.json (cookies encrypted
# with DPAPI for this Windows user). Here the engine builds the same control
# status the Volt adapter reports, so the recovery core (journal, outcomes,
# budgets, farm-freeze, handoff) is shared; only status, launch, ownership and
# the manager checks differ. Differences that matter:
#  - The engine itself is the launcher: a closed client is relaunched by the
#    engine after the vault's relaunchDelaySec, paced by launchDelaySec. There is
#    no exponential backoff for normal relaunches; only a launch that produces no
#    client within launchTimeoutSec counts as a failed attempt.
#  - Ownership is the account's unique browser tracker id in the client's
#    command line (we put it there). Clients with unknown trackers are ignored.
#  - Cookies, tickets and link codes stay in memory: never logged, never in the
#    heartbeat, never in an error message.
# ---------------------------------------------------------------------------
$script:accountProvider = 'volt'
$script:accountProviderSetting = 'auto'
$script:accountProviderNotice = $null
$script:nativeLaunches = @{}        # accountId -> launch [datetime] UTC, until its client appears or launchTimeoutSec passes
$script:nativeLastLaunchUtc = $null
$script:nativeSingletons = @()
# Launches run in two steps so the loop never waits on Roblox: the ticket request runs in its
# own runspace (Start-ArkuzoNativeTicketJob), and Complete-ArkuzoNativeLaunches starts the client
# on a later pass. The cookie and the ticket stay in memory; the ticket only goes on the
# client's command line.
$script:nativeTicketJobs = @{}      # accountId -> ticket request in flight
$script:nativeLaunchPids = @{}      # accountId -> pid of the client the engine started (direct method)
$script:nativeLaunchTrackers = @{}  # trackerId -> UTC the engine started a client with it
$script:nativeLaunchExits = @{}     # accountId -> UTC its launched client went away before it was in game
$script:NativeTicketDeadlineSec = 75
$script:nativeVaultFailed = $false
$script:nativeVoltConflict = @{ checkedUtc = [datetime]::MinValue; userIds = @(); usernames = $null }
$script:nativeVault = $null
$script:NativeVaultMutexName = 'Local\ArkuzoAccountVault'
$script:NativeVaultEntropy = [Text.Encoding]::ASCII.GetBytes('Arkuzo.AccountVault.v1')
$script:NativeUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
# Which Roblox build launches (docs/roblox-versions.md): heartbeat block robloxVersion, refreshed every 30 s and at each launch.
$script:robloxVersionStatus = $null
$script:robloxVersionCheckedUtc = $null
$script:robloxProtocolOverrideLogged = $false

function Test-ArkuzoNativeProvider { return $script:accountProvider -ceq 'arkuzo' }
function Get-ArkuzoVaultPath { return (Join-Path $DataDirectory 'accounts.json') }

function Invoke-ArkuzoVaultLocked([scriptblock]$Action) {
    # Shared with the Control Center. Never held across a network request.
    $mutex = New-Object Threading.Mutex($false, $script:NativeVaultMutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Account vault is busy' }
        return (& $Action)
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}
function Read-ArkuzoVaultFile {
    $path = Get-ArkuzoVaultPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function ConvertFrom-ArkuzoSecret([string]$Value) {
    if ([string]::IsNullOrEmpty($Value) -or -not $Value.StartsWith('dpapi:')) { throw 'Account secret missing' }
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Value.Substring(6)), $script:NativeVaultEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function ConvertTo-ArkuzoSecret([string]$Text) {
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), $script:NativeVaultEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return 'dpapi:' + [Convert]::ToBase64String($bytes)
}
function Update-ArkuzoVaultAccount([string]$AccountId, [hashtable]$Fields, [string]$OnlyIfCookie = $null) {
    # Read-modify-write one account. OnlyIfCookie: write only if the stored
    # (encrypted) cookie is still the one this change was based on.
    return (Invoke-ArkuzoVaultLocked {
        $vault = Read-ArkuzoVaultFile
        if ($null -eq $vault) { return $false }
        $rows = @($vault.accounts | Where-Object { [string]$_.id -eq $AccountId })
        if ($rows.Count -ne 1) { return $false }
        if ($OnlyIfCookie -and [string]$rows[0].cookie -cne $OnlyIfCookie) { return $false }
        foreach ($name in $Fields.Keys) {
            if ($rows[0].PSObject.Properties.Name -contains $name) { $rows[0].$name = $Fields[$name] }
            else { $rows[0] | Add-Member -NotePropertyName $name -NotePropertyValue $Fields[$name] }
        }
        Save-ArkuzoAtomicJson (Get-ArkuzoVaultPath) $vault
        return $true
    })
}
function Get-ArkuzoVaultSetting($Vault, [string]$Name, $Default, [double]$Min = [double]::NaN, [double]$Max = [double]::NaN) {
    $value = $null
    if ($null -ne $Vault -and $null -ne $Vault.settings) { $value = $Vault.settings.$Name }
    if ($null -eq $value) { return $Default }
    if (-not [double]::IsNaN($Min)) {
        try { $n = [double]$value } catch { return $Default }
        if ($n -lt $Min -or $n -gt $Max) { return $Default }
        if ([math]::Abs($n) -le [int]::MaxValue) { return [int]$n }
        return [long]$n # Millisecond timestamps (e.g. arrangeRequestedAtMs) don't fit an int.
    }
    return $value
}

function Test-ArkuzoVoltManagerRunning {
    $managers = @(Get-Process -Name tauri-app -ErrorAction SilentlyContinue)
    try { return (@($managers | Where-Object { try { [string]::Equals($_.Path, $voltPath, [StringComparison]::OrdinalIgnoreCase) } catch { $false } }).Count -gt 0) }
    finally { foreach ($m in $managers) { $m.Dispose() } }
}
function Test-ArkuzoVoltRelaunching {
    # Volt open as an executor is fine. Volt is the launcher only while it runs
    # clients of its own with auto-relaunch on (a Volt farm).
    if (@((Get-ArkuzoVoltRunningAccounts).usernames).Count -eq 0) { return $false }
    $status = Get-ArkuzoVoltRecoveryStatus -Root $PSScriptRoot
    return ($status.safeToRecycle -is [bool] -and $status.safeToRecycle)
}
function Resolve-ArkuzoAccountProvider {
    # auto: Arkuzo once the vault holds an account and Volt's manager is not
    # running. A Volt farm keeps Volt (its clients are not in the vault, so
    # switching would silently stop recovering them); once Arkuzo is active, a
    # Volt start does not flip it back (the conflict guard covers that).
    $setting = [string]$script:accountProviderSetting
    $next = 'volt'
    $hasAccounts = $false
    if ($setting -ceq 'arkuzo') { $next = 'arkuzo' }
    elseif ($setting -cne 'volt') {
        try { $vault = Read-ArkuzoVaultFile; $hasAccounts = $null -ne $vault -and @($vault.accounts).Count -gt 0 } catch { }
        if ($hasAccounts -and ((Test-ArkuzoNativeProvider) -or -not (Test-ArkuzoVoltRelaunching))) { $next = 'arkuzo' }
        elseif ($hasAccounts) { $script:accountProviderNotice = 'Volt is running its own clients with auto-relaunch on, so Volt still launches. Close Volt''s clients (Volt can stay open as your executor), or set "Who launches clients" to Arkuzo.' }
    }
    if ($next -ceq 'volt' -and -not $hasAccounts) { $script:accountProviderNotice = $null }
    if ($next -cne $script:accountProvider) {
        $script:accountProvider = $next
        Clear-VoltRecoveryCapability
        $script:voltControlStatus = [pscustomobject]@{ available = $false; accounts = @(); reason = 'Account provider changed' }
        $script:voltControlCheckedUtc = $null
        Write-Diagnostic 'ACCOUNT_PROVIDER' @{ provider = $next; setting = $setting; note = $(if ($next -ceq 'arkuzo') { 'Arkuzo launches and relaunches clients from data/accounts.json; Volt is not needed.' } else { 'Volt account manager launches and relaunches clients.' }) }
    }
    if (Test-ArkuzoNativeProvider) { Enable-ArkuzoMultiInstance }
}

function Enable-ArkuzoMultiInstance {
    # Roblox allows one client per session while it can own its singleton
    # objects. Holding them first lets several clients run (what Volt's
    # multi-instance option does). Created once and held until the engine exits.
    if ($script:nativeSingletons.Count -gt 0) { return }
    $vault = $script:nativeVault
    if ($null -ne $vault -and (Get-ArkuzoVaultSetting $vault 'multiInstance' $true) -eq $false) { return }
    foreach ($name in @('ROBLOX_singletonMutex', 'ROBLOX_singletonEvent')) {
        try { $created = $false; $script:nativeSingletons += @(New-Object Threading.Mutex($true, $name, [ref]$created)) }
        catch { } # Exists as another kind of object, e.g. a running client's event: nothing to hold.
    }
}

function Get-ArkuzoVoltRunningAccounts {
    # Accounts Volt is running a client for right now: live clients whose browser
    # tracker id is one of Volt's. Volt relaunches only clients it started itself,
    # so these are the only accounts where Volt and Arkuzo could both launch (and
    # kick each other, "signed in elsewhere"). Returns @{ userIds; usernames }.
    $utc = [datetime]::UtcNow
    if (($utc - $script:nativeVoltConflict.checkedUtc).TotalSeconds -lt 10 -and $null -ne $script:nativeVoltConflict.usernames) { return $script:nativeVoltConflict }
    $result = @{ checkedUtc = $utc; userIds = @(); usernames = @() }
    try {
        if (Test-ArkuzoVoltManagerRunning) {
            $map = Invoke-ArkuzoVoltProbe '--map'
            if ($null -ne $map -and $null -ne $map.byTracker) {
                $names = @()
                foreach ($c in @(Get-ArkuzoNativeClients)) {
                    if ($c.trackerId -and $map.byTracker.PSObject.Properties.Name -contains [string]$c.trackerId) { $names += ([string]$map.byTracker.([string]$c.trackerId)).ToLowerInvariant() }
                }
                $result.usernames = @($names | Select-Object -Unique)
                if ($null -ne $map.byUserId) {
                    $result.userIds = @($map.byUserId.PSObject.Properties | Where-Object { $result.usernames -contains ([string]$_.Value).ToLowerInvariant() } | ForEach-Object { [string]$_.Name })
                }
            }
        }
    } catch { }
    $script:nativeVoltConflict = $result
    return $result
}
function Get-ArkuzoVoltRelaunchConflict($Vault) {
    # Arkuzo leaves an account alone while Volt is running a client for it.
    $volt = Get-ArkuzoVoltRunningAccounts
    $ids = @($volt.userIds)
    $names = @($volt.usernames)
    return @($Vault.accounts | Where-Object { $ids -contains [string]$_.userId -or $names -contains ([string]$_.username).ToLowerInvariant() } | ForEach-Object { [string]$_.userId })
}
function Invoke-ArkuzoVoltProbe([string]$Mode) {
    $child = $null
    try {
        $probe = Join-Path $PSScriptRoot 'Arkuzo-Volt-Probe.py'
        if (-not (Test-Path -LiteralPath $probe)) { return $null }
        $python = Get-Command python3.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $python) { $python = Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $python.Source; $info.Arguments = '-B "' + $probe + '" ' + $Mode
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $child = [Diagnostics.Process]::Start($info)
        $out = $child.StandardOutput.ReadToEndAsync()
        if (-not (Wait-ArkuzoObservedProcess $child 3000)) { $child.Kill(); return $null }
        return ($out.Result | ConvertFrom-Json)
    } catch { return $null } finally { if ($null -ne $child) { $child.Dispose() } }
}

function Get-ArkuzoNativeClients {
    # Live clients and their tracker ids. Command lines stay inside this function.
    $result = @()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='RobloxPlayerBeta.exe'" -Property ProcessId, CommandLine, ExecutablePath -OperationTimeoutSec 5 -ErrorAction Stop)) {
        $result += [pscustomobject]@{ processId = [int]$p.ProcessId; trackerId = (Get-ArkuzoBrowserTrackerId ([string]$p.CommandLine)); path = [string]$p.ExecutablePath }
    }
    return ,$result
}

function Get-ArkuzoNativeStatus($Clients = $null) {
    $utc = [datetime]::UtcNow
    $unavailable = [pscustomobject]@{ available = $false; globalMappingSafe = $false; managerId = $null; managerStartTicks = $null; relaunchDelayMs = $null; accounts = @(); reason = 'Arkuzo account vault unavailable'; provider = 'arkuzo' }
    try {
        $vault = Invoke-ArkuzoVaultLocked { Read-ArkuzoVaultFile }
        if ($null -eq $vault) { $unavailable.reason = 'No Arkuzo accounts yet (add them in the Control Center)'; return $unavailable }
        $script:nativeVault = $vault
        if ($null -eq $Clients) { $Clients = Get-ArkuzoNativeClients }
    } catch { $script:nativeVaultFailed = $true; return $unavailable }
    $script:nativeVaultFailed = $false
    if ($null -eq $script:robloxVersionCheckedUtc -or ($utc - $script:robloxVersionCheckedUtc).TotalSeconds -ge 30) {
        # The Roblox tab shows which build the next launch would use, and a missing pin before any launch.
        $script:robloxVersionCheckedUtc = $utc
        try { $m = [string](Get-ArkuzoVaultSetting $vault 'launchMethod' 'direct'); Update-ArkuzoRobloxVersionStatus (Resolve-ArkuzoRobloxPlayer $Clients $vault $m) $m } catch { }
    }
    $launchTimeout = Get-ArkuzoVaultSetting $vault 'launchTimeoutSec' 120 30 600
    $autoEnabled = (Get-ArkuzoVaultSetting $vault 'autoRelaunchEnabled' $true) -eq $true
    $farmRunning = (Get-ArkuzoVaultSetting $vault 'farmRunning' $false) -eq $true
    $conflicts = @(Get-ArkuzoVoltRelaunchConflict $vault)
    $mappingSafe = $true
    $accounts = @()
    $seenTrackers = @{}
    foreach ($a in @($vault.accounts)) {
        $id = [string]$a.id; $tracker = [string]$a.browserTrackerId
        if ($id -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or $tracker -notmatch '\A[1-9][0-9]{9,15}\z' -or $seenTrackers.ContainsKey($tracker)) { continue }
        $seenTrackers[$tracker] = $true
        $live = @($Clients | Where-Object { $_.trackerId -ceq $tracker })
        if ($live.Count -gt 1) { $mappingSafe = $false } # Two clients for one account: never guess which one.
        $inFlight = $false
        if ($script:nativeLaunches.ContainsKey($id)) {
            $launchAge = ($utc - $script:nativeLaunches[$id]).TotalSeconds
            $launchedPid = if ($null -ne $script:nativeLaunchPids -and $script:nativeLaunchPids.ContainsKey($id)) { [int]$script:nativeLaunchPids[$id] } else { 0 }
            if ($live.Count -gt 0 -or $launchAge -ge $launchTimeout) { $script:nativeLaunches.Remove($id); if ($null -ne $script:nativeLaunchPids) { $script:nativeLaunchPids.Remove($id) } }
            elseif ($launchedPid -gt 0 -and $launchAge -ge 3 -and @($Clients | Where-Object { [int]$_.processId -eq $launchedPid }).Count -eq 0) {
                # The client the engine started is gone before it ever showed up for this account
                # (a launch error): relaunch after the relaunch delay, not after launchTimeoutSec.
                $script:nativeLaunches.Remove($id); $script:nativeLaunchPids.Remove($id)
                if ($null -ne $script:nativeLaunchExits) { $script:nativeLaunchExits[$id] = $utc }
            }
            else { $inFlight = $true }
        }
        if ($null -ne $script:nativeTicketJobs -and $script:nativeTicketJobs.ContainsKey($id)) { $inFlight = $true }
        $cookieStatus = if (@('alive', 'dead', 'moderated') -ccontains [string]$a.cookieStatus) { [string]$a.cookieStatus } else { 'unknown' }
        $uiStatus = if ($live.Count -eq 1) { 'Connected' } elseif ($live.Count -gt 1) { 'Unknown' } elseif ($inFlight) { 'Launching' } else { 'Idle' }
        $blocked = $conflicts -contains [string]$a.userId
        $ready = $cookieStatus -ceq 'alive' -and -not $blocked -and $live.Count -le 1
        $label = if ([string]$a.alias) { [string]$a.alias } elseif ([string]$a.displayName) { [string]$a.displayName } else { [string]$a.username }
        $accounts += [pscustomobject]@{ accountId = $id; username = [string]$a.username; displayName = $label; trackerId = $tracker; userId = [string]$a.userId
            autoRelaunch = [bool]($autoEnabled -and $a.autoRelaunch -eq $true); cookieAlive = ($cookieStatus -ceq 'alive'); cookieStatus = $cookieStatus
            suspensionSafe = [bool]($cookieStatus -ceq 'dead' -and $live.Count -eq 0); lastLaunchAtMs = [long]$a.lastLaunchAtMs; uiStatus = $uiStatus
            processId = $(if ($live.Count -eq 1) { $live[0].processId } else { $null }); controlReady = [bool]$ready; rowReady = [bool]$ready
            launchRequestedAtMs = [long]$a.launchRequestedAtMs; closeRequestedAtMs = [long]$a.closeRequestedAtMs; voltConflict = [bool]$blocked }
    }
    $script:accountProviderNotice = if ($conflicts.Count -gt 0) { 'Volt is running ' + $conflicts.Count + ' of these accounts, so Arkuzo leaves them to Volt (two launchers on one account kick each other). Close those clients in Volt to hand them over.' } else { $null }
    return [pscustomobject]@{ available = $true; globalMappingSafe = [bool]$mappingSafe; processMappingSafe = [bool]$mappingSafe; unmappedAccountIds = @()
        managerId = $PID; managerStartTicks = $script:controllerStartTicks; relaunchDelayMs = ([int]$restorePolicy.relaunch_delay_sec * 1000)
        accounts = $accounts; farmRunning = [bool]$farmRunning; provider = 'arkuzo'; reason = 'Arkuzo account vault' }
}

function Get-ArkuzoNativeOutcomePolicy {
    # The engine relaunches by itself: wait the vault's relaunch delay, not Volt's restore window.
    $policy = $restorePolicy.Clone()
    $policy.restore_wait_sec = Get-ArkuzoVaultSetting $script:nativeVault 'relaunchDelaySec' 8 0 600
    return $policy
}
function Test-ArkuzoOwnNativeLaunch([string]$TrackerId, [double]$WithinSec = 300) {
    # True when the engine itself started a client with this tracker in the last $WithinSec.
    if ([string]::IsNullOrEmpty($TrackerId) -or $null -eq $script:nativeLaunchTrackers) { return $false }
    foreach ($k in @($script:nativeLaunchTrackers.Keys)) { if (([datetime]::UtcNow - $script:nativeLaunchTrackers[$k]).TotalSeconds -gt 600) { $script:nativeLaunchTrackers.Remove($k) } }
    return ($script:nativeLaunchTrackers.ContainsKey($TrackerId) -and ([datetime]::UtcNow - $script:nativeLaunchTrackers[$TrackerId]).TotalSeconds -le $WithinSec)
}
function Test-ArkuzoNativeLaunchSlot([datetime]$NowUtc) {
    $jobs = if ($null -ne $script:nativeTicketJobs) { [int]$script:nativeTicketJobs.Count } else { 0 }
    $gap = [double](Get-ArkuzoVaultSetting $script:nativeVault 'launchDelaySec' 12 5 120)
    return (Test-ArkuzoLaunchSlotFree $NowUtc $jobs $gap $script:nativeLastLaunchUtc $script:lastClientStartUtc)
}
function Test-ArkuzoLaunchSlotFree([datetime]$NowUtc, [int]$TicketJobs, [double]$GapSec, $LastLaunchUtc, $LastClientStartUtc) {
    # Pure. One ticket request at a time: a slow answer never lets two clients start together.
    # Launches are GapSec apart, counted from the engine's last launch request and from the last
    # client that appeared by other means.
    if ($TicketJobs -gt 0) { return $false }
    if ($null -ne $LastLaunchUtc -and ($NowUtc - $LastLaunchUtc).TotalSeconds -lt $GapSec) { return $false }
    if ($null -ne $LastClientStartUtc -and ($NowUtc - $LastClientStartUtc).TotalSeconds -lt $GapSec) { return $false }
    return $true
}

function Invoke-ArkuzoRobloxPost([string]$Url, [string]$Cookie, [string]$Csrf = '') {
    # Returns status, ticket, csrf and a rotated cookie. Status 0 = network failure.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'POST'; $req.UserAgent = $script:NativeUserAgent; $req.Referer = 'https://www.roblox.com/'; $req.Accept = 'application/json'
    $req.ContentType = 'application/json'; $req.Timeout = 15000; $req.ReadWriteTimeout = 15000; $req.AllowAutoRedirect = $false
    $req.Headers.Add('Cookie', '.ROBLOSECURITY=' + $Cookie)
    if ($Csrf) { $req.Headers.Add('X-CSRF-TOKEN', $Csrf) }
    $body = [Text.Encoding]::ASCII.GetBytes('{}')
    $resp = $null
    try {
        $req.ContentLength = $body.Length
        $stream = $req.GetRequestStream(); try { $stream.Write($body, 0, $body.Length) } finally { $stream.Dispose() }
        try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response }
        if ($null -eq $resp) { return @{ status = 0 } }
        $rotated = $null
        $setCookie = [string]$resp.Headers['Set-Cookie']
        $m = [regex]::Match($setCookie, '(?:^|[,\s])\.ROBLOSECURITY=([^;,\s]+)')
        if ($m.Success) { $rotated = $m.Groups[1].Value }
        # A moderated (banned or warned) account answers 403 "User is moderated".
        $text = ''
        if ([int]$resp.StatusCode -eq 403) {
            try { $reader = New-Object IO.StreamReader($resp.GetResponseStream()); $buffer = New-Object char[] 4096; $text = New-Object string($buffer, 0, $reader.Read($buffer, 0, 4096)) } catch { }
        }
        return @{ status = [int]$resp.StatusCode; ticket = [string]$resp.Headers['rbx-authentication-ticket']; csrf = [string]$resp.Headers['x-csrf-token']; rotated = $rotated
            moderated = ($text -match 'User is moderated') }
    } catch { return @{ status = 0 } }
    finally { if ($null -ne $resp) { $resp.Dispose() } }
}
function Get-ArkuzoAuthTicket([string]$Cookie, [string]$Url = 'https://auth.roblox.com/v1/authentication-ticket') {
    # Roblox's CSRF handshake: the first POST answers 403 with a token.
    $url = $Url
    $first = Invoke-ArkuzoRobloxPost $url $Cookie
    $cookieInUse = if ($first.rotated) { $first.rotated } else { $Cookie }
    if ($first.status -eq 403 -and $first.csrf) {
        $second = Invoke-ArkuzoRobloxPost $url $cookieInUse $first.csrf
        if ($second.rotated) { $cookieInUse = $second.rotated }
        return @{ status = $second.status; ticket = $second.ticket; cookie = $cookieInUse; rotated = ($cookieInUse -cne $Cookie); moderated = [bool]$second.moderated }
    }
    return @{ status = $first.status; ticket = $first.ticket; cookie = $cookieInUse; rotated = ($cookieInUse -cne $Cookie); moderated = [bool]$first.moderated }
}

function Get-ArkuzoNativeJoinUrl($Vault, $Account) {
    # Public server of the account's place (or the default place), or a private server.
    $mode = [string](Get-ArkuzoVaultSetting $Vault 'privateServerMode' 'none')
    $serverId = $null
    if ($mode -ceq 'assigned' -and $Account.privateServerId) { $serverId = [string]$Account.privateServerId }
    elseif ($mode -ceq 'shared') { $serverId = [string](Get-ArkuzoVaultSetting $Vault 'sharedPrivateServerId' $null) }
    $tracker = [string]$Account.browserTrackerId
    $base = 'https://assetgame.roblox.com/game/PlaceLauncher.ashx?'
    if ($serverId) {
        $servers = @($Vault.privateServers | Where-Object { [string]$_.id -eq $serverId })
        if ($servers.Count -ne 1 -or [string]$servers[0].placeId -notmatch '\A[1-9][0-9]{0,18}\z') { throw 'Private server not found' }
        $code = ConvertFrom-ArkuzoSecret ([string]$servers[0].linkCode)
        if ($code -notmatch '\A[0-9A-Za-z_-]{6,80}\z') { throw 'Private server link code is invalid' }
        return $base + 'request=RequestPrivateGame&placeId=' + $servers[0].placeId + '&linkCode=' + $code + '&browserTrackerId=' + $tracker
    }
    $place = if ([string]$Account.placeId -match '\A[1-9][0-9]{0,18}\z') { [string]$Account.placeId } else { [string](Get-ArkuzoVaultSetting $Vault 'defaultPlaceId' '') }
    if ($place -notmatch '\A[1-9][0-9]{0,18}\z') { throw 'No place to join: set a default place in the Control Center' }
    return $base + 'request=RequestGame&browserTrackerId=' + $tracker + '&placeId=' + $place + '&isPlayTogetherGame=false'
}

function Get-ArkuzoManagedVersionsRoot($Vault = $script:nativeVault) {
    # Arkuzo's own Versions folder, where the Control Center's Roblox tab installs builds
    # (docs/roblox-versions.md). The vault's robloxVersionsDir moves it; empty = the default.
    $dir = [string](Get-ArkuzoVaultSetting $Vault 'robloxVersionsDir' '')
    if ($dir -match '\A[A-Za-z]:\\' -and $dir -notmatch '(\A|\\)\.\.(\\|\z)') { return [IO.Path]::Combine($dir, 'Versions') }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'Arkuzo\Roblox\Versions') }
    return $null
}
function Test-ArkuzoRobloxBuildComplete([string]$Exe) {
    # A version folder is complete when Roblox's AppSettings.xml sits next to the player: a
    # folder that was deleted while a client ran keeps only its locked files (the exe and a
    # few DLLs, 10 Nov), and every client launched from it exits within seconds.
    return [IO.File]::Exists([IO.Path]::Combine([IO.Path]::GetDirectoryName($Exe), 'AppSettings.xml'))
}
function Select-ArkuzoNewestRobloxBuild([string[]]$Exes) {
    # Complete builds first, then the newest player file. The exe's version resource is no help:
    # Roblox's 0.747 build still reports 0.746 (10 Nov). The Control Center's installs keep the
    # file times from Roblox's packages, so an old build installed today does not look newest.
    $list = @($Exes | Where-Object { $_ } | Select-Object -Unique)
    if ($list.Count -eq 0) { return $null }
    return @($list | Sort-Object @{ Expression = { Test-ArkuzoRobloxBuildComplete $_ }; Descending = $true }, @{ Expression = { (Get-Item -LiteralPath $_).LastWriteTimeUtc }; Descending = $true })[0]
}
function Get-ArkuzoRobloxInstalls([string]$ManagedRoot) {
    # Every installed player: Arkuzo's folder first (only version-<hash> folders count there, so a
    # folder an install is still filling is never picked), then Roblox's, Bloxstrap's and Fishstrap's.
    $roots = @()
    if ($ManagedRoot) { $roots += $ManagedRoot }
    if ($env:LOCALAPPDATA) { $roots += @('Roblox\Versions', 'Bloxstrap\Versions', 'Fishstrap\Versions') | ForEach-Object { Join-Path $env:LOCALAPPDATA $_ } }
    # The current Roblox installer installs for all users under Program Files.
    if ($env:ProgramFiles) { $roots += Join-Path $env:ProgramFiles 'Roblox\Versions' }
    if (${env:ProgramFiles(x86)}) { $roots += Join-Path ${env:ProgramFiles(x86)} 'Roblox\Versions' }
    $seen = @{}
    foreach ($root in $roots) {
        if ($seen.ContainsKey($root.ToLowerInvariant()) -or -not (Test-Path -LiteralPath $root)) { continue }
        $seen[$root.ToLowerInvariant()] = $true
        $managed = $ManagedRoot -and [string]::Equals($root, $ManagedRoot, [StringComparison]::OrdinalIgnoreCase)
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($managed -and $dir.Name -cnotmatch '\Aversion-[0-9a-f]{16}\z') { continue }
            $exe = Join-Path $dir.FullName 'RobloxPlayerBeta.exe'
            if (Test-Path -LiteralPath $exe) { $exe }
        }
    }
}
function Get-ArkuzoRobloxPlayerPath($Clients, $Vault = $null) {
    # Auto: prefer the build that is already running; otherwise the newest complete installed one.
    $running = @($Clients | Where-Object { $_.path -and (Test-Path -LiteralPath $_.path) } | ForEach-Object { $_.path } | Select-Object -Unique)
    if ($running.Count -gt 0) { return (Select-ArkuzoNewestRobloxBuild $running) }
    return (Select-ArkuzoNewestRobloxBuild @(Get-ArkuzoRobloxInstalls (Get-ArkuzoManagedVersionsRoot $Vault)))
}
function Resolve-ArkuzoRobloxPlayer($Clients, $Vault, [string]$Method = 'direct') {
    # Which player a launch starts (docs/roblox-versions.md). Auto keeps the launch method and the
    # running-build preference. A pinned build (vault robloxVersion) always launches directly: the
    # protocol method goes through Roblox's launcher, which updates Roblox and ignores the pin.
    # A pinned build that is missing or incomplete is never replaced silently: path stays $null with
    # a problem, unless robloxVersionFallback allows the Auto choice.
    $pin = [string](Get-ArkuzoVaultSetting $Vault 'robloxVersion' 'auto')
    if ($pin -cne 'auto' -and $pin -cnotmatch '\Aversion-[0-9a-f]{16}\z') { $pin = 'auto' }
    $allowFallback = (Get-ArkuzoVaultSetting $Vault 'robloxVersionFallback' $false) -eq $true
    $managed = Get-ArkuzoManagedVersionsRoot $Vault
    $r = @{ mode = 'auto'; pinned = $null; path = $null; method = $(if ($Method -ceq 'protocol') { 'protocol' } else { 'direct' }); problem = $null; fallback = $false; managedRoot = $managed }
    if ($pin -ceq 'auto') {
        if ($r.method -ceq 'direct') { $r.path = Get-ArkuzoRobloxPlayerPath $Clients $Vault }
        return $r
    }
    $r.mode = 'pinned'; $r.pinned = $pin; $r.method = 'direct'
    $r.path = @(Get-ArkuzoRobloxInstalls $managed | Where-Object { [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($_)) -ceq $pin -and (Test-ArkuzoRobloxBuildComplete $_) }) | Select-Object -First 1
    if ($r.path) { return $r }
    $r.problem = 'Pinned Roblox ' + $pin + ' is not installed (or incomplete): install it on the Roblox tab, or choose Auto'
    if ($allowFallback) { $r.fallback = $true; $r.path = Get-ArkuzoRobloxPlayerPath $Clients $Vault }
    return $r
}
function Update-ArkuzoRobloxVersionStatus($Player, [string]$RequestedMethod = 'direct') {
    # Heartbeat block robloxVersion, plus one event per change: a missing pin, the protocol override.
    if ($null -eq $Player) { return }
    $version = if ($Player.path) { [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$Player.path)) } else { $null }
    $previous = $script:robloxVersionStatus
    $script:robloxVersionStatus = [ordered]@{ mode = [string]$Player.mode; pinned = $Player.pinned; fallback = [bool]$Player.fallback
        selectedPath = $Player.path; selectedVersion = $version; method = [string]$Player.method; problem = $Player.problem; managedRoot = $Player.managedRoot
        checkedUtc = [datetime]::UtcNow.ToString('o') }
    if ($Player.problem -and ($null -eq $previous -or [string]$previous.problem -cne [string]$Player.problem -or [bool]$previous.fallback -ne [bool]$Player.fallback)) {
        Write-Diagnostic 'ROBLOX_VERSION_PIN_MISSING' @{ pinned = $Player.pinned; fallback = [bool]$Player.fallback; usedVersion = $version
            note = $(if ($Player.fallback) { 'The pinned build is missing; "fall back to newest" is on, so the newest installed build is launched.' } else { 'The pinned build is missing; launches wait until it is installed or Auto is chosen.' }) }
    }
    if ($Player.mode -ceq 'pinned' -and $RequestedMethod -ceq 'protocol' -and -not $script:robloxProtocolOverrideLogged) {
        $script:robloxProtocolOverrideLogged = $true
        Write-Diagnostic 'ROBLOX_VERSION_PROTOCOL_OVERRIDDEN' @{ pinned = $Player.pinned; note = 'A pinned Roblox build launches directly: the protocol method would let Roblox''s launcher update Roblox and ignore the pin.' }
    }
}
function Get-ArkuzoRobloxVersionPreflight($Vault) {
    # Step 1 of a launch: a pinned build that is missing (and no fallback) refuses before a ticket is
    # requested, so a missing pin never spends Roblox requests every relaunch cycle. Auto: nothing to check.
    $pin = [string](Get-ArkuzoVaultSetting $Vault 'robloxVersion' 'auto')
    if ($pin -ceq 'auto') { return '' }
    $player = Resolve-ArkuzoRobloxPlayer @() $Vault ([string](Get-ArkuzoVaultSetting $Vault 'launchMethod' 'direct'))
    Update-ArkuzoRobloxVersionStatus $player ([string](Get-ArkuzoVaultSetting $Vault 'launchMethod' 'direct'))
    if ($player.path) { return '' }
    return [string]$player.problem
}
function Clear-ArkuzoRobloxSavedLogin([string]$StorageDir = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Roblox\LocalStorage' } else { '' })) {
    # A login saved by the Roblox app itself (someone signed in to it on this PC)
    # makes every ticket launch fail: the client loads it and its web login answers
    # 403 (9 Nov, 21:48 on: every launch, every account). Clients launched with a
    # ticket never save one, so the file is moved aside only when it holds a
    # .ROBLOSECURITY cookie. Roblox writes a fresh file without it on the next start.
    # Returns $true when a saved login was moved aside. Never throws.
    try {
        if (-not $StorageDir) { return $false }
        $path = Join-Path $StorageDir 'RobloxCookies.dat'
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        $jar = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ([string]::IsNullOrEmpty([string]$jar.CookiesData)) { return $false }
        Add-Type -AssemblyName System.Security
        $plain = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$jar.CookiesData), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
        $hasLogin = @($plain -split "`n" | Where-Object { $f = $_ -split "`t"; $f.Count -ge 6 -and $f[5].Trim() -ceq '.ROBLOSECURITY' }).Count -gt 0
        $plain = $null
        if (-not $hasLogin) { return $false }
        # One backup, so signing in to the Roblox app again can be undone by renaming it back.
        Move-Item -LiteralPath $path -Destination ($path + '.arkuzo-saved-login') -Force
        return $true
    } catch { return $false }
}
function Start-ArkuzoRobloxClient([string]$Ticket, [string]$JoinUrl, [string]$TrackerId, [string]$Method, $Clients, $Player = $null) {
    # $Player (Resolve-ArkuzoRobloxPlayer) decides the exe and the method; without it, the Auto choice.
    $launchMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $exe = if ($null -ne $Player) { $(if ($Player.method -ceq 'protocol') { $null } else { $Player.path }) } elseif ($Method -ceq 'protocol') { $null } else { Get-ArkuzoRobloxPlayerPath $Clients }
    if ($null -ne $Player -and $Player.mode -ceq 'pinned' -and -not $exe) { throw 'Pinned Roblox build missing' } # Never Roblox's launcher instead of a pin.
    $info = New-Object Diagnostics.ProcessStartInfo
    if ($exe) {
        $info.FileName = $exe; $info.WorkingDirectory = Split-Path -Parent $exe; $info.UseShellExecute = $false
        $info.Arguments = '--app -t ' + $Ticket + ' -j "' + $JoinUrl + '" -b ' + $TrackerId + ' --launchtime=' + $launchMs + ' --rloc en_us --gloc en_us'
        $how = 'direct'
    } else {
        # The roblox-player: handler (Roblox's own launcher) updates Roblox first if needed.
        $info.FileName = 'roblox-player:1+launchmode:play+gameinfo:' + $Ticket + '+launchtime:' + $launchMs + '+placelauncherurl:' + [Uri]::EscapeDataString($JoinUrl) +
            '+browsertrackerid:' + $TrackerId + '+robloxLocale:en_us+gameLocale:en_us+channel:+LaunchExp:InApp'
        $info.UseShellExecute = $true
        $how = 'protocol'
    }
    $proc = [Diagnostics.Process]::Start($info)
    $id = $null
    if ($null -ne $proc) { try { if ($exe) { $id = $proc.Id } } catch { } finally { $proc.Dispose() } }
    return @{ method = $how; pid = $id }
}

function Initialize-ArkuzoNativeLaunchState {
    foreach ($name in @('nativeTicketJobs', 'nativeLaunchPids', 'nativeLaunchTrackers', 'nativeLaunchExits', 'nativeLaunches')) {
        if ($null -eq (Get-Variable -Scope Script -Name $name -ValueOnly -ErrorAction SilentlyContinue)) { Set-Variable -Scope Script -Name $name -Value @{} }
    }
}
function Start-ArkuzoNativeTicketJob([string]$Cookie, [string]$Url = 'https://auth.roblox.com/v1/authentication-ticket') {
    # The ticket request (up to two 15 s HTTP calls) runs in its own runspace so the loop
    # keeps running. The cookie is passed in memory, never on a command line or to a log.
    $ps = [powershell]::Create()
    try {
        $code = 'param($Cookie, $Url, $Agent)' + "`n" + '$script:NativeUserAgent = $Agent' + "`n" +
            'function Invoke-ArkuzoRobloxPost {' + ${function:Invoke-ArkuzoRobloxPost}.ToString() + "}`n" +
            'function Get-ArkuzoAuthTicket {' + ${function:Get-ArkuzoAuthTicket}.ToString() + "}`n" +
            'Get-ArkuzoAuthTicket $Cookie $Url'
        [void]$ps.AddScript($code).AddArgument($Cookie).AddArgument($Url).AddArgument([string]$script:NativeUserAgent)
        return @{ PowerShell = $ps; AsyncResult = $ps.BeginInvoke() }
    } catch { $ps.Dispose(); throw 'Ticket request could not start' }
}
function Receive-ArkuzoNativeTicketJob($Job) {
    # $null while the request runs; then its result (status 0 = no answer). Never throws and
    # never passes on error text: it could quote the request.
    if ($null -eq $Job -or -not $Job.AsyncResult.IsCompleted) { return $null }
    $result = @{ status = 0 }
    try {
        $out = $Job.PowerShell.EndInvoke($Job.AsyncResult)
        $last = @($out | Where-Object { $_ -is [hashtable] }) | Select-Object -Last 1
        if ($null -ne $last) { $result = $last }
    } catch { $result = @{ status = 0 } }
    finally { try { $Job.PowerShell.Dispose() } catch { } }
    return $result
}
function Stop-ArkuzoNativeTicketJob($Job) {
    # BeginStop: Stop() would wait for the HTTP call in flight. Disposal follows once it ends.
    if ($null -eq $Job) { return }
    try {
        $ps = $Job.PowerShell
        [void]$ps.BeginStop({ param($ar) try { $ar.AsyncState.Dispose() } catch { } }, $ps)
    } catch { try { $Job.PowerShell.Dispose() } catch { } }
}
function Set-ArkuzoNativeLaunchRetry([string]$AccountId, [string]$Why) {
    # A launch that Roblox refused or that produced no lasting client is retried after the
    # relaunch delay, like any relaunch: no waiting out launchTimeoutSec, no growing backoff.
    if ($null -eq $script:recoveryPending -or -not $script:recoveryPending.ContainsKey($AccountId)) { return }
    $delay = [double](Get-ArkuzoVaultSetting $script:nativeVault 'relaunchDelaySec' 8 0 600)
    $entry = $script:recoveryPending[$AccountId]
    $entry.nextRetryUtc = [datetime]::UtcNow.AddSeconds($delay).ToString('o')
    $entry.readySinceUtc = $null; $entry.lastObservedUtc = $null; $entry.replacementPid = 0; $entry.replacementStartTicks = 0
}

function Invoke-ArkuzoNativeLaunch([string]$AccountId, [string]$TrackerId, [switch]$Manual) {
    # Step 1 of a launch: every check, then the ticket request is started in the background.
    # Complete-ArkuzoNativeLaunches starts the client on a later pass.
    $result = [pscustomobject]@{ available = $true; requestAccepted = $false; accountId = $AccountId; reason = '' }
    try {
        if ($MonitorOnly -or -not $ownsControllerMutex) { throw 'Read-only controller' }
        Initialize-ArkuzoNativeLaunchState
        $vault = Invoke-ArkuzoVaultLocked { Read-ArkuzoVaultFile }
        $rows = @($vault.accounts | Where-Object { [string]$_.id -eq $AccountId -and [string]$_.browserTrackerId -eq $TrackerId })
        if ($rows.Count -ne 1) { throw 'Account not found in the Arkuzo vault' }
        $a = $rows[0]
        if ([string]$a.cookieStatus -cne 'alive') { throw 'Account cookie is not alive' }
        if ([long]$a.closeRequestedAtMs -gt 0) { throw 'Close requested' }
        if (@(Get-ArkuzoVoltRelaunchConflict $vault) -contains [string]$a.userId) { throw 'Volt auto-relaunch is on for this account' }
        if (-not $Manual -and (Get-ArkuzoVaultSetting $vault 'farmRunning' $false) -ne $true) { throw 'Farm is stopped' }
        $clients = Get-ArkuzoNativeClients
        if (@($clients | Where-Object { $_.trackerId -ceq $TrackerId }).Count -gt 0) { throw 'Account already has a client' }
        if ($script:nativeLaunches.ContainsKey($AccountId) -or $script:nativeTicketJobs.ContainsKey($AccountId)) { throw 'Launch already in flight' }
        $versionProblem = Get-ArkuzoRobloxVersionPreflight $vault
        if ($versionProblem) { Warn-Throttled 'roblox-version-pin' $versionProblem; throw $versionProblem }
        $joinUrl = Get-ArkuzoNativeJoinUrl $vault $a
        $secret = [string]$a.cookie
        $job = Start-ArkuzoNativeTicketJob (ConvertFrom-ArkuzoSecret $secret)
        $now = [datetime]::UtcNow
        $script:nativeTicketJobs[$AccountId] = @{ Job = $job; TrackerId = $TrackerId; JoinUrl = $joinUrl; Secret = $secret; Manual = [bool]$Manual
            Username = [string]$a.username; StartedUtc = $now; Method = [string](Get-ArkuzoVaultSetting $vault 'launchMethod' 'direct') }
        # In flight from now on: shown as Launching, never launched twice, and the next
        # account's launch is spaced from this one.
        $script:nativeLaunches[$AccountId] = $now
        $script:nativeLastLaunchUtc = $now
        $result.requestAccepted = $true
        $result.reason = 'Launch ticket requested; the client starts when Roblox answers'
    } catch {
        $result.reason = $_.Exception.Message
        if ($result.reason -match 'ROBLOSECURITY|WARNING:-DO-NOT|dpapi:') { $result.reason = 'Launch failed' } # Never let a secret into a message.
    }
    return $result
}

function Complete-ArkuzoNativeLaunch([string]$AccountId, $Pending, $Ticket) {
    # Step 2: Roblox answered. Re-check everything that could have changed while the ticket
    # was requested (farm stopped, Close pressed, cookie, a client appeared), then start the
    # client. Returns the reason it was not started, or '' when it was.
    $vault = Invoke-ArkuzoVaultLocked { Read-ArkuzoVaultFile }
    $rows = @($vault.accounts | Where-Object { [string]$_.id -eq $AccountId -and [string]$_.browserTrackerId -eq $Pending.TrackerId })
    if ($rows.Count -ne 1) { return 'Account not found in the Arkuzo vault' }
    $a = $rows[0]
    if ($Ticket.rotated -and $Ticket.cookie) {
        # Roblox re-issued the cookie; the old one stops working later. Only replace the stored one if it is unchanged.
        try { [void](Update-ArkuzoVaultAccount $AccountId @{ cookie = (ConvertTo-ArkuzoSecret $Ticket.cookie); updatedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } $Pending.Secret) } catch { }
    }
    if ($Ticket.status -eq 401) {
        [void](Update-ArkuzoVaultAccount $AccountId @{ cookieStatus = 'dead'; lastError = 'Roblox rejected the cookie at launch (signed out or expired)'; lastCheckAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() })
        Write-Diagnostic 'NATIVE_COOKIE_DEAD' @{ accountId = $AccountId; username = [string]$a.username; note = 'Roblox answered 401 to the launch ticket request; sign the account in again.' }
        return 'Cookie rejected by Roblox'
    }
    if ($Ticket.status -eq 403 -and $Ticket.moderated) {
        # Retrying cannot help (9 Nov: 93 refused launches, the recovery queue held for 2 h).
        # The account waits until a cookie check finds it alive again.
        [void](Update-ArkuzoVaultAccount $AccountId @{ cookieStatus = 'moderated'; lastError = 'Roblox has moderated this account: sign in on roblox.com to see why'; lastCheckAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() })
        Write-Diagnostic 'NATIVE_ACCOUNT_MODERATED' @{ accountId = $AccountId; username = [string]$a.username; note = 'Roblox answered "User is moderated" to the launch ticket request; not launched again until a cookie check finds it alive.' }
        return 'Account moderated by Roblox'
    }
    if ($Ticket.status -ne 200 -or [string]::IsNullOrEmpty([string]$Ticket.ticket)) { return $(if ($Ticket.status -eq 0) { 'Roblox unreachable' } else { 'Roblox refused a launch ticket (' + [int]$Ticket.status + ')' }) }
    if ([string]$a.cookieStatus -cne 'alive') { return 'Account cookie is not alive' }
    if ([long]$a.closeRequestedAtMs -gt 0) { return 'Close requested' }
    if (-not $Pending.Manual -and (Get-ArkuzoVaultSetting $vault 'farmRunning' $false) -ne $true) { return 'Farm is stopped' }
    if (@(Get-ArkuzoVoltRelaunchConflict $vault) -contains [string]$a.userId) { return 'Volt auto-relaunch is on for this account' }
    $clients = Get-ArkuzoNativeClients
    if (@($clients | Where-Object { $_.trackerId -ceq $Pending.TrackerId }).Count -gt 0) { return 'Account already has a client' }
    # The build to start: Auto, or the pinned one (re-checked: it may have been removed meanwhile).
    $player = Resolve-ArkuzoRobloxPlayer $clients $vault $Pending.Method
    Update-ArkuzoRobloxVersionStatus $player $Pending.Method
    if ($player.mode -ceq 'pinned' -and -not $player.path) { Warn-Throttled 'roblox-version-pin' $player.problem; return [string]$player.problem }
    if ($player.path) { Update-ArkuzoGraphicsForInstall ([IO.Path]::GetDirectoryName([string]$player.path)) }
    Enable-ArkuzoMultiInstance
    if (Clear-ArkuzoRobloxSavedLogin) {
        Write-Diagnostic 'ROBLOX_SAVED_LOGIN_SET_ASIDE' @{ note = 'The Roblox app had a saved login on this PC, which makes ticket launches fail with 403. Moved to RobloxCookies.dat.arkuzo-saved-login in Roblox''s LocalStorage folder.' }
    }
    $started = Start-ArkuzoRobloxClient ([string]$Ticket.ticket) $Pending.JoinUrl $Pending.TrackerId $Pending.Method $clients $player
    $now = [datetime]::UtcNow
    $script:nativeLaunches[$AccountId] = $now # launchTimeoutSec counts from the client start.
    # Launch spacing counts from the request (step 1), so launchDelaySec is the real gap.
    $script:nativeLaunchTrackers[[string]$Pending.TrackerId] = $now
    if ($started.pid) { $script:nativeLaunchPids[$AccountId] = [int]$started.pid } else { $script:nativeLaunchPids.Remove($AccountId) }
    try { [void](Update-ArkuzoVaultAccount $AccountId @{ lastLaunchAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); launchRequestedAtMs = 0; lastError = $null }) } catch { }
    $build = if ($started.method -ceq 'direct' -and $player.path) { [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$player.path)) } else { $null }
    Write-Diagnostic 'NATIVE_LAUNCH_STARTED' @{ accountId = $AccountId; username = [string]$a.username; method = [string]$started.method; pid = $started.pid; robloxVersion = $build; pinned = ($player.mode -ceq 'pinned'); note = 'Client started; game readiness is verified separately.' }
    return ''
}

function Complete-ArkuzoNativeLaunches {
    # Every pass: finish the launches whose ticket request has ended. Cheap while none has.
    if ($null -eq $script:nativeTicketJobs -or $script:nativeTicketJobs.Count -eq 0) { return }
    Initialize-ArkuzoNativeLaunchState
    foreach ($id in @($script:nativeTicketJobs.Keys)) {
        $pending = $script:nativeTicketJobs[$id]
        $ticket = Receive-ArkuzoNativeTicketJob $pending.Job
        if ($null -eq $ticket) {
            $deadline = if ([double]$script:NativeTicketDeadlineSec -gt 0) { [double]$script:NativeTicketDeadlineSec } else { 75 }
            if (([datetime]::UtcNow - $pending.StartedUtc).TotalSeconds -lt $deadline) { continue }
            Stop-ArkuzoNativeTicketJob $pending.Job
            $ticket = @{ status = 0 }
        }
        $script:nativeTicketJobs.Remove($id)
        $why = ''
        try { $why = Complete-ArkuzoNativeLaunch $id $pending $ticket }
        catch { $why = 'Launch failed: ' + $_.Exception.GetType().Name } # Never the message: it could quote the ticket.
        $ticket = $null
        if (-not $why) { continue }
        $script:nativeLaunches.Remove($id); $script:nativeLaunchPids.Remove($id)
        Write-Diagnostic 'NATIVE_LAUNCH_FAILED' @{ accountId = $id; username = $pending.Username; reason = $why; manual = [bool]$pending.Manual; note = 'Retried after the relaunch delay unless the account is dead, moderated, closed or the farm stopped.' }
        Warn-Throttled ('restore-' + $id) ((Get-ArkuzoAccountDisplayLabel -AccountId $id) + ' not launched: ' + $why)
        if ($pending.Manual) {
            $clear = @{ launchRequestedAtMs = 0 }
            if ($why -cne 'Cookie rejected by Roblox') { $clear.lastError = $why } # Keep the sign-out explanation.
            try { [void](Update-ArkuzoVaultAccount $id $clear) } catch { }
        }
        Set-ArkuzoNativeLaunchRetry $id $why
    }
}

function Stop-ArkuzoNativeTicketJobs {
    if ($null -eq $script:nativeTicketJobs) { return }
    foreach ($pending in @($script:nativeTicketJobs.Values)) { Stop-ArkuzoNativeTicketJob $pending.Job }
    $script:nativeTicketJobs = @{}
}

function Register-ArkuzoNativeLaunchExit([int]$ClientId, $State) {
    # A client of a queued account went away before it was verified in game (a launch error,
    # a crash while loading, or a stalled launch the engine closed). Its relaunch waits the
    # relaunch delay, not the rest of launchTimeoutSec. Closures by the engine are already queued.
    if (-not (Test-ArkuzoNativeProvider) -or $null -eq $State -or $State.RecoveryRequested -or [string]::IsNullOrEmpty([string]$State.TrackerId)) { return }
    if ($null -eq $script:recoveryPending -or $null -eq $voltControlStatus -or -not $voltControlStatus.available) { return }
    Initialize-ArkuzoNativeLaunchState
    $rows = @($voltControlStatus.accounts | Where-Object { [string]$_.trackerId -ceq [string]$State.TrackerId })
    if ($rows.Count -ne 1) { return }
    $key = [string]$rows[0].accountId
    if (-not $script:recoveryPending.ContainsKey($key)) { return }
    $entry = $script:recoveryPending[$key]
    if ([int]$entry.oldPid -eq $ClientId -and [long]$entry.oldStartTicks -eq [long]$State.StartTicks) { return }
    $script:nativeLaunchExits[$key] = [datetime]::UtcNow
}

function Invoke-ArkuzoNativeRequests {
    # Launch / close buttons and Stop farm in the Control Center set request
    # stamps on accounts; carry them out here and clear them.
    if (-not (Test-ArkuzoNativeProvider) -or $MonitorOnly -or -not $ownsControllerMutex -or -not $voltControlStatus.available) { return }
    Initialize-ArkuzoNativeLaunchState
    $utc = [datetime]::UtcNow
    $launched = $false
    foreach ($a in @($voltControlStatus.accounts)) {
        if ([long]$a.closeRequestedAtMs -gt 0) {
            $id = [string]$a.accountId
            $closed = 0
            foreach ($state in @($tracked.Values)) {
                if ([string]$state.TrackerId -cne [string]$a.trackerId -or $null -eq $state.Watcher) { continue }
                if (-not (Test-ArkuzoClientIdentity $state.Watcher $state.Watcher.Id $state.StartTicks)) { continue }
                $state.RecoveryRequested = $true # Not a recovery: keep the exit path from queuing a relaunch.
                try { $state.Watcher.Kill(); if ($state.Watcher.WaitForExit(3000)) { $closed++ } } catch { }
            }
            # A launch still waiting for its ticket is cancelled; it never starts a client.
            $cancelled = $false
            if ($script:nativeTicketJobs.ContainsKey($id)) {
                Stop-ArkuzoNativeTicketJob $script:nativeTicketJobs[$id].Job
                $script:nativeTicketJobs.Remove($id); $script:nativeLaunches.Remove($id); $script:nativeLaunchPids.Remove($id)
                $cancelled = $true
            }
            if ($recoveryPending.ContainsKey($id)) { $script:recoveryPending.Remove($id); try { Save-ArkuzoRecoveryJournal } catch { $script:recoveryJournalHealthy = $false } }
            # The stamp stays until the account's status (read at the start of this pass, from
            # the live process list) shows no client and no launch in flight. Clearing it while a
            # launch was in flight let that client appear afterwards and run unmanaged.
            $settled = -not $a.processId -and $a.uiStatus -ceq 'Idle' -and -not $cancelled
            if ($settled) { try { [void](Update-ArkuzoVaultAccount $id @{ closeRequestedAtMs = 0 }) } catch { } }
            if ($closed -gt 0 -or $cancelled -or $settled) {
                Write-Diagnostic 'NATIVE_CLIENT_CLOSED' @{ accountId = $a.accountId; username = $a.username; closed = $closed; launchCancelled = $cancelled; done = $settled; note = 'Closed from the Control Center.' }
            }
            continue
        }
        if ([long]$a.launchRequestedAtMs -gt 0 -and -not $launched) {
            if ($a.processId -or $a.uiStatus -ceq 'Launching') { try { [void](Update-ArkuzoVaultAccount ([string]$a.accountId) @{ launchRequestedAtMs = 0 }) } catch { }; continue }
            if (-not (Test-ArkuzoNativeLaunchSlot $utc)) { continue } # Next pass.
            Write-Diagnostic 'NATIVE_LAUNCH_REQUEST' @{ accountId = $a.accountId; username = $a.username; reason = 'Launch requested in the Control Center' }
            $r = Invoke-ArkuzoNativeLaunch ([string]$a.accountId) ([string]$a.trackerId) -Manual
            Write-Diagnostic 'NATIVE_LAUNCH_RESULT' @{ accountId = $a.accountId; username = $a.username; requestAccepted = [bool]$r.requestAccepted; reason = $r.reason }
            if (-not $r.requestAccepted) {
                $clear = @{ launchRequestedAtMs = 0 }
                if ($r.reason -cne 'Cookie rejected by Roblox') { $clear.lastError = $r.reason } # Keep the sign-out explanation.
                try { [void](Update-ArkuzoVaultAccount ([string]$a.accountId) $clear) } catch { }
            }
            $launched = $true # One launch per pass; close requests are still carried out.
        }
    }
}

