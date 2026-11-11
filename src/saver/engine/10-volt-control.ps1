$script:voltStatusChild = $null
$script:voltStatusOut = $null
$script:voltStatusStartSec = 0
# Farm-freeze episode state lives only in memory: after a saver restart, any
# remaining frozen client falls back to the normal hang timeout.
$script:farmFreeze = $null
$script:farmFreezeSequence = 0
$script:lastFarmFreezeStartSec = $null
$script:lastClientStartUtc = $null

function Poll-ArkuzoVoltControlAsync {
    if ($null -ne $script:voltStatusChild) {
        if ($script:voltStatusChild.HasExited) {
            try {
                if ($script:voltStatusChild.ExitCode -eq 0 -and $null -ne $script:voltStatusOut) {
                    if (-not $script:voltStatusOut.IsCompleted) {
                        [void]$script:voltStatusOut.AsyncWaitHandle.WaitOne(2000)
                    }
                    if ($script:voltStatusOut.IsCompleted) {
                        $raw = $script:voltStatusOut.Result
                        $res = $raw | ConvertFrom-Json
                        if ($res.available -is [bool]) {
                            $script:voltControlStatus = $res
                            $script:voltControlCheckedUtc = [datetime]::UtcNow
                        }
                    }
                }
            } catch { }
            finally {
                try { $script:voltStatusChild.Dispose() } catch { }
                $script:voltStatusChild = $null
                $script:voltStatusOut = $null
            }
        } elseif ($script:clock -and ($script:clock.Elapsed.TotalSeconds - $script:voltStatusStartSec) -gt 16) {
            try { $script:voltStatusChild.Kill() } catch { }
            finally {
                try { $script:voltStatusChild.Dispose() } catch { }
                $script:voltStatusChild = $null
                $script:voltStatusOut = $null
            }
        }
    }
}

function Start-ArkuzoVoltControlStatusAsync {
    if (Test-ArkuzoNativeProvider) {
        $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
        return
    }
    if ($null -ne $script:voltStatusChild) { return }
    try {
        $file = Join-Path $PSScriptRoot 'Arkuzo-Volt-Control.ps1'
        if (-not (Test-Path -LiteralPath $file)) { return }
        $delaySec = if ($restorePolicy -and $restorePolicy.relaunch_delay_sec) { [int]$restorePolicy.relaunch_delay_sec } else { 30 }
        $waitSec = if ($restorePolicy -and $restorePolicy.restore_wait_sec) { [int]$restorePolicy.restore_wait_sec } else { 120 }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = 'powershell.exe'
        $info.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$file`" -Action Status -RelaunchDelaySec $delaySec -MinLaunchAgeSec $waitSec"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $false
        $child = [Diagnostics.Process]::Start($info)
        $script:voltStatusOut = $child.StandardOutput.ReadToEndAsync()
        $script:voltStatusChild = $child
        $script:voltStatusStartSec = if ($script:clock) { $script:clock.Elapsed.TotalSeconds } else { 0 }
    } catch { }
}

function Update-ArkuzoVoltControl {
    $script:voltControlStatus=Invoke-ArkuzoVoltControl 'Status'
    $script:voltControlCheckedUtc=[datetime]::UtcNow
    if (-not $MonitorOnly -and $restorePolicy.enabled -and $voltControlStatus.available -and
        $null -ne $voltControlStatus.relaunchDelayMs -and [int]$voltControlStatus.relaunchDelayMs -lt ([int]$restorePolicy.relaunch_delay_sec*1000)) {
        $configured=Invoke-ArkuzoVoltControl 'Configure'
        if ($configured.available -and [int]$configured.relaunchDelayMs -ge ([int]$restorePolicy.relaunch_delay_sec*1000)) {
            Write-Diagnostic 'VOLT_RELAUNCH_DELAY_VERIFIED' @{delayMs=$configured.relaunchDelayMs}
            $script:voltControlStatus=$configured
        } else { Warn-Throttled 'volt-delay' 'Volt relaunch delay could not be verified. Destructive recovery remains blocked.' }
        $script:voltControlCheckedUtc=[datetime]::UtcNow
    }
}
# The state the recovery decisions read, in one object with neutral names. Without -Context a
# decision builds it from the script state, as before; unit tests build it by hand
# (tests/saver/DecisionContext.Tests.ps1). ControlStatus is the control status of either account
# provider ($voltControlStatus), ControlCheckedUtc when it was read.
function New-ArkuzoDecisionContext {
    return [pscustomobject]@{
        NowUtc            = [datetime]::UtcNow
        RestorePolicy     = $restorePolicy
        ControlStatus     = $voltControlStatus
        ControlCheckedUtc = $voltControlCheckedUtc
        SuspendedAccounts = $script:suspendedAccounts
        RecoveryPending   = $script:recoveryPending
        AccountProvider   = $script:accountProvider
        NativeProvider    = [bool](Test-ArkuzoNativeProvider)
    }
}
function Test-ArkuzoControlStatusFresh($Context) {
    # Control status is used for at most 25 s, and never from the future.
    if (-not $Context.ControlStatus.available -or $null -eq $Context.ControlCheckedUtc) { return $false }
    $age = ($Context.NowUtc - $Context.ControlCheckedUtc).TotalSeconds
    return ($age -ge 0 -and $age -le 25)
}
function Get-ArkuzoControlledAccount([string]$TrackerId, [int]$ClientId, $Context = $null) {
    if ($null -eq $Context) { $Context = New-ArkuzoDecisionContext }
    $status = $Context.ControlStatus; $policy = $Context.RestorePolicy
    if (-not $policy.enabled -or -not (Test-ArkuzoControlStatusFresh $Context) -or
        [int]$status.relaunchDelayMs -lt ([int]$policy.relaunch_delay_sec*1000)) { return $null }
    if ($status.globalMappingSafe -isnot [bool] -or -not $status.globalMappingSafe) {
        # Only a latched farm-freeze episode may map a client while the farm is
        # not globally mapped, and only its own planned members (see below).
        return (Get-ArkuzoFarmFreezeAccount $TrackerId $ClientId)
    }
    if (-not (Test-ArkuzoSuspendedRowsSafe $Context)) { return $null }
    $matchedAccounts = @($status.accounts | Where-Object {
        ( [string]::IsNullOrWhiteSpace($TrackerId) -or $_.trackerId -eq $TrackerId ) -and
        $_.processId -eq $ClientId -and
        $_.controlReady -is [bool] -and $_.controlReady
    })
    if ($matchedAccounts.Count -ne 1 -or $matchedAccounts[0].cookieStatus -ceq 'dead' -or ($null -ne $Context.SuspendedAccounts -and $Context.SuspendedAccounts.ContainsKey([string]$matchedAccounts[0].accountId)) -or $policy.excluded_account_ids -contains $matchedAccounts[0].accountId) { return $null }
    return $matchedAccounts[0]
}
function Test-ArkuzoSuspensionInScope($Entry, $Provider = $script:accountProvider) {
    # Entries without a provider were made by Volt (before Arkuzo accounts existed).
    $owner = if ($null -ne $Entry -and $Entry.provider) { [string]$Entry.provider } else { 'volt' }
    $current = if ($Provider) { [string]$Provider } else { 'volt' }
    return ($owner -ceq $current)
}
function Test-ArkuzoSuspendedRowsSafe($Context = $null) {
    # A suspended (dead-cookie) account must still be an exact idle row.
    if ($null -eq $Context) { $Context = New-ArkuzoDecisionContext }
    foreach($key in @($Context.SuspendedAccounts.Keys)) {
        if ($Context.RestorePolicy.excluded_account_ids -contains $key) { continue }
        if (-not (Test-ArkuzoSuspensionInScope $Context.SuspendedAccounts[$key] $Context.AccountProvider)) { continue } # The other launcher's account.
        $rows=@($Context.ControlStatus.accounts | Where-Object { $_.accountId -ceq $key })
        if ($rows.Count -ne 1) { return $false }
        $a=$rows[0]
        if ($a.cookieStatus -cne 'dead' -or $a.suspensionSafe -isnot [bool] -or -not $a.suspensionSafe -or $a.uiStatus -cne 'Idle' -or $a.processId) { return $false }
    }
    return $true
}
