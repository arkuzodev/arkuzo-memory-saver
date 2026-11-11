
$script:accountNameCache = @{}

function ConvertTo-ArkuzoDisplayName([string]$Name) {
    # Strip terminal escape sequences and formatting/control characters from
    # presentation only; never modify stored or structured audit identities.
    $text = [regex]::Replace($Name, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    $text = [regex]::Replace($text, '[\p{Cc}\p{Cf}]', ' ')
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    if (-not $text -or $text -match '\A(?:ID:|UID:|Unmapped\z|Acc #)' -or
        $text -match '\A[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z') { return 'Unknown account' }
    if ($text.Length -gt 64) { $text = $text.Substring(0,61) + '...' }
    return $text
}
function Get-ArkuzoAccountDisplayLabel([string]$AccountId='', [int]$ProcessId=0, [string]$TrackerId='') {
    if ($ProcessId -gt 0) { return (Resolve-ArkuzoAccountName $ProcessId $TrackerId) + ' (PID ' + $ProcessId + ')' }
    if ($null -eq $script:accountLabelCache) { $script:accountLabelCache = @{} }
    if ($null -ne $voltControlStatus -and $null -ne $voltControlStatus.accounts) {
        $rows = @($voltControlStatus.accounts | Where-Object { $_.accountId -ceq $AccountId })
        if ($rows.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$rows[0].username)) {
            $name = ConvertTo-ArkuzoDisplayName ([string]$rows[0].username)
            if ($name -cne 'Unknown account') {
                $script:accountLabelCache[$AccountId] = $name
                return $name
            }
        }
    }
    if ($script:accountLabelCache.ContainsKey($AccountId)) {
        return $script:accountLabelCache[$AccountId]
    }
    return 'Unknown account'
}
function Resolve-ArkuzoAccountName([int]$ProcessId, [string]$TrackerId = $null, [string]$LogPath = $null) {
    if ($null -eq $script:accountNameCache) { $script:accountNameCache = @{} }
    if ($null -eq $script:trackerNameCache) { $script:trackerNameCache = @{} }
    $state = if ($null -ne $script:tracked -and $script:tracked.ContainsKey($ProcessId)) { $script:tracked[$ProcessId] } else { $null }

    if ($null -eq $state -or [string]::IsNullOrWhiteSpace($TrackerId) -or $TrackerId -notmatch '\A[0-9]+\z' -or
        $state.TrackerId -cne $TrackerId -or
        -not (Test-ArkuzoClientIdentity $state.Watcher $ProcessId $state.StartTicks)) {
        if ($ProcessId -gt 0) { $script:accountNameCache.Remove($ProcessId) }
        return 'Unknown account'
    }

    # Populate tracker cache from any available Volt status snapshot
    if ($null -ne $voltControlStatus -and $null -ne $voltControlStatus.accounts) {
        foreach ($acct in @($voltControlStatus.accounts)) {
            if ($acct.trackerId -match '\A[0-9]+\z' -and -not [string]::IsNullOrWhiteSpace([string]$acct.username)) {
                $displayName = ConvertTo-ArkuzoDisplayName ([string]$acct.username)
                if ($displayName -cne 'Unknown account') {
                    $script:trackerNameCache[[string]$acct.trackerId] = $displayName
                }
            }
        }
    }

    # 1. Use cached account name for this verified running process generation
    if ($script:accountNameCache.ContainsKey($ProcessId)) {
        $cached = $script:accountNameCache[$ProcessId]
        if ($cached.startTicks -eq $state.StartTicks -and $cached.trackerId -ceq $TrackerId -and
            -not [string]::IsNullOrWhiteSpace([string]$cached.username) -and $cached.username -cne 'Unknown account') {
            return [string]$cached.username
        }
    }

    # 2. Try resolving fresh exact match (trackerId + processId)
    if ($null -ne $voltControlStatus -and $null -ne $voltControlStatus.accounts) {
        $exact = @($voltControlStatus.accounts | Where-Object { $_.trackerId -ceq $TrackerId -and $_.processId -eq $ProcessId })
        if ($exact.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$exact[0].username)) {
            $name = ConvertTo-ArkuzoDisplayName ([string]$exact[0].username)
            if ($name -cne 'Unknown account') {
                $script:accountNameCache[$ProcessId] = @{username=$name;startTicks=$state.StartTicks;trackerId=$TrackerId;accountId=$exact[0].accountId}
                $script:trackerNameCache[$TrackerId] = $name
                return $name
            }
        }

        # 3. Match by unique trackerId
        $byTracker = @($voltControlStatus.accounts | Where-Object { $_.trackerId -ceq $TrackerId })
        if ($byTracker.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$byTracker[0].username)) {
            $name = ConvertTo-ArkuzoDisplayName ([string]$byTracker[0].username)
            if ($name -cne 'Unknown account') {
                $script:accountNameCache[$ProcessId] = @{username=$name;startTicks=$state.StartTicks;trackerId=$TrackerId;accountId=$byTracker[0].accountId}
                $script:trackerNameCache[$TrackerId] = $name
                return $name
            }
        }
    }

    # 4. Fallback to cached tracker name
    if ($script:trackerNameCache.ContainsKey($TrackerId)) {
        $cachedName = [string]$script:trackerNameCache[$TrackerId]
        if (-not [string]::IsNullOrWhiteSpace($cachedName) -and $cachedName -cne 'Unknown account') {
            $script:accountNameCache[$ProcessId] = @{username=$cachedName;startTicks=$state.StartTicks;trackerId=$TrackerId;accountId=$null}
            return $cachedName
        }
    }

    return 'Unknown account'
}
function Read-RobloxLogTail([string]$Path, [ref]$CurrentOffset) {
    # New text since $CurrentOffset (the last 64 KB on the first read or after a
    # larger gap). Bounded: a log that cannot be opened returns $null and keeps the offset.
    $offset = [long]$CurrentOffset.Value
    $r = Read-ArkuzoBoundedFile $Path $(if ($offset -le 0) { -1 } else { $offset }) 65536
    if (-not $r.Ok -or $r.Length -le 0) { return $null }
    if ($offset -le 0) { $CurrentOffset.Value = $r.Length; return $r.Text }
    if ($r.Length -lt $offset) { $CurrentOffset.Value = 0; return $null }
    if ($r.Count -le 0) { return $null }
    $CurrentOffset.Value = $r.Start + $r.Count
    return $r.Text
}
function Get-RobloxLogDisconnectReason([string]$NewText) {
    if ([string]::IsNullOrWhiteSpace($NewText)) { return $null }
    $lines = $NewText -split "(\r?\n)"
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match "(?i)(?:Disconnection Notification\. Reason|Disconnect reason received|Disconnected from server for reason:\s*(?:Player:)?|Sending disconnect with reason|Disconnect code):\s*([0-9]+)") {
            $code = [int]$matches[1]
            if ($code -ne 285 -and $code -ne 0) {
                return @{ Disconnected = $true; ErrorCode = $code; Reason = "Error Code $code" }
            }
        }
        if ($line -match "(?i)Lost connection with reason\s*:\s*(.+)") {
            return @{ Disconnected = $true; ErrorCode = 267; Reason = ("Kicked: " + $matches[1].Trim()) }
        }
        if ($line -match "(?i)Client has been disconnected with reason\s*:\s*(.+)") {
            return @{ Disconnected = $true; ErrorCode = 267; Reason = ("Disconnected: " + $matches[1].Trim()) }
        }
        if ($line -match "(?i)Error:\s*Server Kick Message\s*:\s*(.+)") {
            return @{ Disconnected = $true; ErrorCode = 267; Reason = ("Server Kick: " + $matches[1].Trim()) }
        }
        if ($line -match "(?i)You have been kicked from the game") {
            return @{ Disconnected = $true; ErrorCode = 267; Reason = "Kicked from game" }
        }
        if ($line -match "(?i)Disconnected from game, please reconnect") {
            return @{ Disconnected = $true; ErrorCode = 277; Reason = "Disconnected from game" }
        }
        if ($line -match "(?i)Error Code\s*[:=]?\s*(2\d\d|5\d\d|6\d\d|7\d\d)") {
            $code = [int]$matches[1]
            if ($code -ne 285) {
                return @{ Disconnected = $true; ErrorCode = $code; Reason = "Error Code $code" }
            }
        }
    }
    return $null
}

