function Get-ArkuzoVersionNumber {
    param([string]$VersionString)
    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $null }
    if ($VersionString -match '(?i)^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        return [version]::new([int]$matches[1], [int]$matches[2], [int]$matches[3])
    }
    return $null
}

function Test-ArkuzoUpdateAvailable {
    param(
        [string]$CurrentVersion = $ArkuzoRuntimeVersion,
        [string]$ApiUrl = 'https://api.github.com/repos/arkuzodev/arkuzo-memory-saver/releases/latest',
        [scriptblock]$FetchDelegate = $null
    )
    $result = [pscustomobject]@{
        checkedUtc = [datetime]::UtcNow.ToString('o')
        available = $false
        currentVersion = $CurrentVersion
        latestVersion = $null
        message = $null
        error = $null
    }
    try {
        $raw = $null
        if ($null -ne $FetchDelegate) {
            $raw = & $FetchDelegate
        } else {
            $req = [System.Net.HttpWebRequest]::Create($ApiUrl)
            $req.UserAgent = 'ArkuzoMemorySaver-Watchdog/' + $CurrentVersion
            $req.Timeout = 8000
            $req.ReadWriteTimeout = 8000
            $resp = $req.GetResponse()
            try {
                $stream = $resp.GetResponseStream()
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                $raw = $reader.ReadToEnd()
            } finally {
                if ($null -ne $resp) { $resp.Dispose() }
            }
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
        $json = $raw | ConvertFrom-Json
        if ($null -eq $json -or $null -eq $json.tag_name) { return $result }
        if ($json.draft -or $json.prerelease) { return $result }

        $remoteTag = [string]$json.tag_name
        $remoteVer = Get-ArkuzoVersionNumber $remoteTag
        $currVer = Get-ArkuzoVersionNumber $CurrentVersion

        if ($null -ne $remoteVer -and $null -ne $currVer) {
            if ($remoteVer -gt $currVer) {
                $result.available = $true
                $result.latestVersion = $remoteTag
                $result.message = "UPDATE: $remoteTag available (restart to update)"
            }
        }
    } catch {
        $result.error = $_.Exception.Message
    }
    return $result
}

$script:versionCheckAsync = $null
$script:versionCheckStartSec = 0

function Poll-ArkuzoVersionCheckAsync {
    if ($null -ne $script:versionCheckAsync) {
        if ($script:versionCheckAsync.AsyncResult.IsCompleted) {
            try {
                $rawJson = $script:versionCheckAsync.PowerShell.EndInvoke($script:versionCheckAsync.AsyncResult)
                if ($rawJson -and $rawJson.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($rawJson[0])) {
                    $jsonStr = [string]$rawJson[0]
                    $res = Test-ArkuzoUpdateAvailable -CurrentVersion $ArkuzoRuntimeVersion -FetchDelegate { $jsonStr }
                    $script:updateAvailableStatus = $res
                    Write-Diagnostic 'VERSION_CHECK' $script:updateAvailableStatus
                }
            } catch { }
            finally {
                try { $script:versionCheckAsync.PowerShell.Dispose() } catch { }
                $script:versionCheckAsync = $null
            }
        } elseif ($script:clock -and ($script:clock.Elapsed.TotalSeconds - $script:versionCheckStartSec) -gt 15) {
            try { $script:versionCheckAsync.PowerShell.Stop() } catch { }
            try { $script:versionCheckAsync.PowerShell.Dispose() } catch { }
            $script:versionCheckAsync = $null
        }
    }
}

function Start-ArkuzoVersionCheckAsync {
    if ($null -ne $script:versionCheckAsync) { return }
    try {
        $curVer = $ArkuzoRuntimeVersion
        $apiUrl = 'https://api.github.com/repos/arkuzodev/arkuzo-memory-saver/releases/latest'
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($curVer, $apiUrl)
            try {
                $req = [System.Net.HttpWebRequest]::Create($apiUrl)
                $req.UserAgent = 'ArkuzoMemorySaver-Watchdog/' + $curVer
                $req.Timeout = 4000
                $req.ReadWriteTimeout = 4000
                $resp = $req.GetResponse()
                try {
                    $stream = $resp.GetResponseStream()
                    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                    return $reader.ReadToEnd()
                } finally { if ($null -ne $resp) { $resp.Dispose() } }
            } catch {
                return $null
            }
        }).AddParameter('curVer', $curVer).AddParameter('apiUrl', $apiUrl)
        $asyncResult = $ps.BeginInvoke()
        $script:versionCheckAsync = @{
            PowerShell = $ps
            AsyncResult = $asyncResult
        }
        $script:versionCheckStartSec = if ($script:clock) { $script:clock.Elapsed.TotalSeconds } else { 0 }
    } catch { }
}

function Update-ArkuzoVersionCheck {
    param(
        [string]$CurrentVersion = $ArkuzoRuntimeVersion,
        [scriptblock]$FetchDelegate = $null
    )
    if ($null -ne $FetchDelegate) {
        $res = Test-ArkuzoUpdateAvailable -CurrentVersion $CurrentVersion -FetchDelegate $FetchDelegate
        $script:updateAvailableStatus = $res
        Write-Diagnostic 'VERSION_CHECK' $res
        return
    }
    Start-ArkuzoVersionCheckAsync
}

# === END Arkuzo-Health.ps1 ===
