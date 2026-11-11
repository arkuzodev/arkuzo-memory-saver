# Stationary live frame and separate, short boot sequence.
# === EMBEDDED Arkuzo-Ui.ps1 ===
# Pure frame builders: no console I/O and no changes to Roblox processes.
# Five-line monochrome ASCII wordmark. No animated dashboard chrome.
$script:arkuzoLogo = @(
    '    ___     ____    __ __   __  __   _____    ____',
    '   /   |   / __ \  / //_/  / / / /  /__  /   / __ \',
    '  / /| |  / /_/ / / ,<    / / / /     / /   / / / /',
    ' / ___ | / _, _/ / /| |  / /_/ /     / /__ / /_/ /',
    '/_/  |_|/_/ |_| /_/ |_|  \____/     /____/ \____/'
)

$script:cachedPrimaryAccount = $null
$script:cachedPrimaryAccountTime = [datetime]::MinValue

function Get-RobloxAccountName([string]$Title, [int]$Slot = 0, [int]$ProcessId = 0) {
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $clean = $Title.Trim()
        $clean = $clean -replace '^(?:Roblox\s*[-–—]\s*|\[Roblox\]\s*)', ''
        $clean = $clean -replace '\s*[-–—]\s*Roblox$', ''
        $clean = $clean.Trim()
        if ($clean -ne '' -and $clean -notmatch '^(?i)Roblox(?:PlayerBeta)?(?:\.exe)?$') {
            return $clean
        }
    }
    if ($Slot -eq 0) {
        $now = [DateTime]::UtcNow
        if ($null -eq $script:cachedPrimaryAccount -or ($now - $script:cachedPrimaryAccountTime).TotalSeconds -gt 15) {
            $script:cachedPrimaryAccountTime = $now
            try {
                $storagePath = Join-Path $env:LOCALAPPDATA 'Roblox\LocalStorage\appStorage.json'
                if (Test-Path -LiteralPath $storagePath) {
                    $jsonContent = [System.IO.File]::ReadAllText($storagePath, [System.Text.Encoding]::UTF8)
                    $data = $jsonContent | ConvertFrom-Json
                    if ($data.DisplayName -and $data.DisplayName.Trim() -ne '') {
                        $script:cachedPrimaryAccount = $data.DisplayName.Trim()
                    } elseif ($data.Username -and $data.Username.Trim() -ne '') {
                        $script:cachedPrimaryAccount = $data.Username.Trim()
                    }
                }
            } catch { }
        }
        if ($script:cachedPrimaryAccount) {
            return $script:cachedPrimaryAccount
        }
    }
    return "Acc #$($Slot + 1)"
}

function Fit-ArkuzoText([string]$Text, [int]$Width) {
    if ($Width -lt 1) { return '' }
    $Text = $Text -replace '[\r\n\t]', ' '
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width) }
    return $Text
}
function New-ArkuzoLine([string]$Text, [ConsoleColor]$Color, [int]$Width) {
    return [pscustomobject]@{ Text = (Fit-ArkuzoText $Text $Width); Color = $Color }
}
function Get-ArkuzoLogoLines {
    return $script:arkuzoLogo
}
function Get-ArkuzoMeter([double]$Value, [double]$Maximum, [int]$Width = 18) {
    $ratio = [Math]::Max([double]0, [Math]::Min([double]1, [double]($Value / [Math]::Max([double]1, $Maximum))))
    $filled = [int][Math]::Floor($ratio * $Width)
    return '[' + ('#' * $filled) + ('.' * ($Width - $filled)) + ']'
}
function Get-ArkuzoSparkline($Values, [int]$Width = 18) {
    $glyphs = ' .:-=+*#%@'
    $points = @($Values | Select-Object -Last $Width)
    $output = ''
    foreach ($point in $points) {
        $index = [int][Math]::Floor([Math]::Max([double]0, [Math]::Min([double]100, [double]$point)) / 100 * ($glyphs.Length - 1))
        $output += $glyphs[$index]
    }
    return $output.PadLeft($Width, '.')
}
function New-ArkuzoBootFrame([int]$Width, [int]$Height, [int]$Step) {
    $lines = New-Object 'System.Collections.Generic.List[object]'
    $wide = $Width -ge 64 -and $Height -ge 15
    if ($wide) {
        foreach ($text in (Get-ArkuzoLogoLines)) {
            $lines.Add((New-ArkuzoLine $text Cyan $Width))
        }
        $lines.Add((New-ArkuzoLine '  ARKUZO // MEMORY SAVER' White $Width))
    } else {
        $lines.Add((New-ArkuzoLine '  /\  ARKUZO  // MEMORY SAVER' Cyan $Width))
    }
    $lines.Add((New-ArkuzoLine '  +--------------------------------------------------+' DarkCyan $Width))
    $stages = @('INITIALIZING CONSOLE', 'CHECKING SYSTEM', 'LOADING TELEMETRY', 'MONITOR READY')
    $stage = $stages[[Math]::Max(0, [Math]::Min(3, [int]$Step))]
    $bar = Get-ArkuzoMeter ($Step + 1) 4 ([Math]::Max(1, [Math]::Min(22, [int]($Width - 4))))
    $lines.Add((New-ArkuzoLine "  $bar" Green $Width))
    $lines.Add((New-ArkuzoLine "  [$($Step + 1)/4] $stage" White $Width))
    return @($lines | Select-Object -First $Height)
}
function Get-ArkuzoTrimCountdown([double]$AgeSec, [double]$WarmupSec, [double]$IntervalSec, [double]$NowSec, [double]$LastTrimSec, [bool]$Enabled, [bool]$ReadOnly) {
    if (-not $Enabled -or $ReadOnly) { return 'OFF' }
    $warmupLeft = [Math]::Ceiling([Math]::Max([double]0, [double]($WarmupSec - [Math]::Max([double]0, $AgeSec))))
    if ($warmupLeft -gt 0) { return "WARMUP ${warmupLeft}s" }
    return ([Math]::Ceiling([Math]::Max([double]0, [double]($IntervalSec - ($NowSec - $LastTrimSec))))).ToString() + 's'
}
function Get-ArkuzoSuspendedAccountDisplay {
    $fresh=$voltControlStatus.available -is [bool] -and $voltControlStatus.available -and $null -ne $voltControlCheckedUtc -and
        ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -ge 0 -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -le 25
    $display=@{}
    if ($fresh) {
        foreach ($a in @($voltControlStatus.accounts)) {
            if ($a.cookieStatus -ceq 'dead') { $display[[string]$a.accountId]=@{accountId=$a.accountId;username=(Get-ArkuzoAccountDisplayLabel -AccountId $a.accountId);processId=$a.processId;unverified=$false} }
        }
    }
    foreach ($entry in @($script:suspendedAccounts.Values)) {
        if ($null -eq $entry -or $display.ContainsKey([string]$entry.accountId)) { continue }
        $display[[string]$entry.accountId]=@{accountId=$entry.accountId;username=$entry.username;unverified=$true;processId=$null}
    }
    return @($display.Values | Sort-Object username,accountId)
}
function New-ArkuzoFrame($Model, [int]$Width, [int]$Height) {
    $lines = New-Object 'System.Collections.Generic.List[object]'
    $usable = [Math]::Max(0, [int]($Height - 1)) # The last row is always the exit hint.
    $wide = $Width -ge 64 -and $Height -ge 20
    $updateBadge = if ($Model.UpdateAvailable -and $Model.UpdateVersion) { "[ UPDATE: v$($Model.UpdateVersion) ]" } else { $null }
    if ($wide) {
        foreach ($text in (Get-ArkuzoLogoLines)) { $lines.Add((New-ArkuzoLine $text Cyan $Width)) }
        if ($updateBadge) {
            $leftText = '  ARKUZO // MEMORY SAVER'
            $gap = [Math]::Max(1, [int]($Width - $leftText.Length - $updateBadge.Length - 1))
            $lines.Add([pscustomobject]@{
                Segments = @(
                    @{ Text = $leftText; Color = [ConsoleColor]::White },
                    @{ Text = (' ' * $gap); Color = [ConsoleColor]::Gray },
                    @{ Text = $updateBadge; Color = [ConsoleColor]::Red }
                )
                Text = $leftText + (' ' * $gap) + $updateBadge
                Color = [ConsoleColor]::White
            })
        } else {
            $lines.Add((New-ArkuzoLine '  ARKUZO // MEMORY SAVER' White $Width))
        }
    } else {
        if ($updateBadge) {
            $leftText = '  /\  ARKUZO  // MEMORY SAVER'
            $gap = [Math]::Max(1, [int]($Width - $leftText.Length - $updateBadge.Length - 1))
            $lines.Add([pscustomobject]@{
                Segments = @(
                    @{ Text = $leftText; Color = [ConsoleColor]::Cyan },
                    @{ Text = (' ' * $gap); Color = [ConsoleColor]::Gray },
                    @{ Text = $updateBadge; Color = [ConsoleColor]::Red }
                )
                Text = $leftText + (' ' * $gap) + $updateBadge
                Color = [ConsoleColor]::Cyan
            })
        } else {
            $lines.Add((New-ArkuzoLine '  /\  ARKUZO  // MEMORY SAVER' Cyan $Width))
        }
    }
    $mode = ([string]$Model.Mode).ToUpperInvariant()
    if ($Model.MonitorOnly) { $mode = 'MONITOR ONLY' }
    $cap = 'HARD WS CAP'; if ($Model.SoftLimit) { $cap = 'ADVISORY' }
    $trim = 'OFF'; if ($Model.TrimEnabled -and -not $Model.MonitorOnly) { $trim = "TRIM $($Model.TrimSeconds)s"; if ($Model.TrimPressure) { $trim += ' (LOW RAM)' } }
    $lockBadge = if ($Model.ConfigLocked) { '  [CONFIG LOCKED]' } else { '' }
    $lines.Add((New-ArkuzoLine "  $mode  |  $($Model.TargetMB) MB $cap  |  $trim$lockBadge" White $Width))
    if ($Height -ge 12) {
        $lines.Add((New-ArkuzoLine ('  ' + ('-' * [Math]::Max(0, [Math]::Min([int]($Width - 4), 70)))) DarkCyan $Width))
        $lines.Add((New-ArkuzoLine "  [SYSTEM]  $($Model.Managed)/$($Model.Detected) clients   $($Model.Uptime.ToString('hh\:mm\:ss')) uptime   $($Model.Trims) trims" Cyan $Width))
        $guard = ''; if ($Model.HealthPolicy -and $Model.HealthPolicy.enabled) { $guard = "  |  GUARD $($Model.HealthPolicy.private_limit_mb) MB" }
        $lines.Add((New-ArkuzoLine "  [POLICY]  $($Model.Priority) priority   $($Model.CoresPerInstance) cores / client$guard" DarkGray $Width))
    }
    if ($Height -ge 18) {
        $cpuColor = [ConsoleColor]::Green
        if ($Model.Cpu -ge 50) { $cpuColor = [ConsoleColor]::Yellow }
        if ($Model.Cpu -ge 85) { $cpuColor = [ConsoleColor]::Red }
        $lines.Add((New-ArkuzoLine ('  CPU  {0}  {1,5:N1}%' -f (Get-ArkuzoMeter $Model.Cpu 100 18), $Model.Cpu) $cpuColor $Width))
        $lines.Add((New-ArkuzoLine ('  RAM  {0}  {1,5:N0} MB resident' -f (Get-ArkuzoMeter $Model.ResidentMB ([Math]::Max(1, [int]$Model.Detected) * $Model.TargetMB) 18), $Model.ResidentMB) Cyan $Width))
        if ($Model.SystemMemory) {
            $commitColor = [ConsoleColor]::DarkGray; if ($Model.SystemMemory.commitPercent -ge 85) { $commitColor = [ConsoleColor]::Red }
            $memText = '  MEM  {0:N0} MB private  |  OS COMMIT {1:N1}% ({2:N0}/{3:N0} MB)' -f $Model.PrivateMB, $Model.SystemMemory.commitPercent, $Model.SystemMemory.commitUsedMB, $Model.SystemMemory.commitLimitMB
            $lines.Add((New-ArkuzoLine $memText $commitColor $Width))
        } else {
            $lines.Add((New-ArkuzoLine ('  MEM  {0:N0} MB private     CPU TRACE [{1}]' -f $Model.PrivateMB, (Get-ArkuzoSparkline $Model.History 16)) DarkGray $Width))
        }
    }
    $paused=@($Model.SuspendedAccounts | Where-Object { $null -ne $_ })
    $pauseReserve=if ($paused.Count -gt 0) { [Math]::Min([int]($paused.Count + 1),[Math]::Max(0,[int]($usable - 2))) } else { 0 }
    if ($Height -ge 12) {
        $lines.Add((New-ArkuzoLine '' Gray $Width))
        $lines.Add((New-ArkuzoLine '  CLIENTS  /  LIVE PROCESS TELEMETRY' White $Width))
        $tableWide = $Width -ge 96
        if ($tableWide) {
            $lines.Add((New-ArkuzoLine ('  {0,-5} {1,-16} {2,-8} {3,5}   {4,6}   {5,7}   {6,-11}  {7}' -f 'SLOT','ACCOUNT / NAME','PID','CPU%','RES MB','PRIV MB','TRIM/WARMUP','STATE') DarkCyan $Width))
        } else {
            $lines.Add((New-ArkuzoLine ('  {0,-5} {1,-14} {2,-8} {3,6}   {4,-11}  {5}' -f 'SLOT','ACCOUNT','PID','RES MB','TRIM/WARMUP','STATE') DarkCyan $Width))
        }
        $reserved = 1 + $pauseReserve # Reserve account status and exit footer.
        $maxRows = [Math]::Max(0, [int]($usable - $lines.Count - $reserved))
        $rows = @($Model.Rows | Sort-Object Slot, Id)
        if ($rows.Count -eq 0 -and $maxRows -gt 0) {
            $lines.Add((New-ArkuzoLine '  > Waiting for Roblox clients...' Yellow $Width))
        } elseif ($maxRows -gt 0) {
            $shown = [Math]::Min([int]$rows.Count, [int]$maxRows)
            if ($rows.Count -gt $maxRows) { $shown = [Math]::Max(0, [int]($maxRows - 1)) }
            for ($i = 0; $i -lt $shown; $i++) {
                $row = $rows[$i]
                $acc = Fit-ArkuzoText (ConvertTo-ArkuzoDisplayName ([string]$row.Account)) $(if ($tableWide) {16} else {14})
                $text = if ($tableWide) {
                    '  #{0,-4} {1,-16} {2,-8} {3,5:N1}   {4,6:N0}   {5,7:N0}   {6,-11}  {7}' -f `
                        ($row.Slot + 1), $acc, $row.Id, $row.Cpu, $row.Ram, $row.Private, $row.NextTrim, $row.Status
                } else {
                    '  #{0,-4} {1,-14} {2,-8} {3,6:N0}   {4,-11}  {5}' -f `
                        ($row.Slot + 1), $acc, $row.Id, $row.Ram, $row.NextTrim, $row.Status
                }
                $color = [ConsoleColor]::Green
                if ($row.Ram -ge $Model.TargetMB) { $color = [ConsoleColor]::Yellow }
                if ($row.Status -in @('NOT RESPONDING','CHECK NOTICE','LEAK GUARD','COMMIT PRESSURE','STUCK CLIENT','VOLT STARTUP ERROR','DISCONNECTED','FARM FREEZE')) { $color = [ConsoleColor]::Red }
                $lines.Add((New-ArkuzoLine $text $color $Width))
            }
            if ($rows.Count -gt $shown) { $lines.Add((New-ArkuzoLine "  + $($rows.Count - $shown) more clients (enlarge window)" DarkGray $Width)) }
        }
    } elseif ($Height -ge 5) {
        $lines.Add((New-ArkuzoLine "  CLIENTS $($Model.Managed)/$($Model.Detected)   RAM $([Math]::Round($Model.ResidentMB)) MB" Cyan $Width))
    }
    if ($paused.Count -gt 0 -and $usable -ge 3) {
        # Account/session rows take precedence over optional telemetry on short consoles.
        while ($lines.Count -gt $usable - $pauseReserve) { $lines.RemoveAt($lines.Count - 1) }
        $lines.Add((New-ArkuzoLine '  ACCOUNTS / SESSION STATUS' White $Width))
        $room=[Math]::Max(0,[int]($usable-$lines.Count))
        $shown=[Math]::Min([int]$paused.Count,[int]$room)
        if ($paused.Count -gt $room -and $room -gt 1) { $shown=$room-1 }
        for ($i=0;$i -lt $shown;$i++) {
            $a=$paused[$i]
            $name = ConvertTo-ArkuzoDisplayName ([string]$a.username)
            $rowText = if ($a.unverified) { "  [DEAD/INVALID COOKIE] $name (UNVERIFIED)" } else { "  [DEAD/INVALID COOKIE] $name" }
            $lines.Add((New-ArkuzoLine (Fit-ArkuzoText $rowText $Width) Red $Width))
        }
        if ($paused.Count -gt $shown -and $lines.Count -lt $usable) { $lines.Add((New-ArkuzoLine "  + $($paused.Count-$shown) paused accounts" Red $Width)) }
    }
    if ($lines.Count -lt $usable -and $Height -ge 12) {
        $alertList = if ($Model.Issues) { @($Model.Issues) } elseif ($Model.Notice) { @(@{ Message = $Model.Notice }) } else { @() }
        $validAlerts = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $alertList) {
            $rawMsg = if ($null -eq $item) { '' } elseif ($item -is [string]) { $item } elseif ($item.Message) { [string]$item.Message } else { '' }
            $trimmed = $rawMsg.Trim()
            if ($trimmed.Length -gt 0) {
                $isErr = ($trimmed -match '(?i)DISCONNECTED|ERROR|STARTUP|PRESSURE|FAIL|CRITICAL|DEAD')
                $validAlerts.Add(@{
                    Message = $trimmed
                    IsError = $isErr
                })
            }
        }
        if ($validAlerts.Count -gt 0) {
            $maxAlerts = [Math]::Min(2, [Math]::Max(1, [int]($usable - $lines.Count - 1)))
            for ($aIdx = 0; $aIdx -lt [Math]::Min([int]$validAlerts.Count, [int]$maxAlerts); $aIdx++) {
                $alert = $validAlerts[$aIdx]
                $tag = if ($alert.IsError) { '[ERROR]' } else { '[INFO]' }
                $alertColor = if ($alert.IsError) { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow }
                $lines.Add((New-ArkuzoLine "  $tag $($alert.Message)" $alertColor $Width))
            }
        } elseif ($lines.Count -lt $usable) {
            $lines.Add((New-ArkuzoLine '  NOTE  Working set != private RAM. Guard policy active.' DarkGray $Width))
        }
    }
    # No spinner or progress animation after boot. The frame changes only when measurements do.
    $footer = '  [LIVE]  Q: stop + restore   |   ' + $Model.Now.ToString('HH:mm:ss')
    if ($Height -le 10) { $footer = '  Q: exit / restore' }
    while ($lines.Count -gt $usable) { $lines.RemoveAt($lines.Count - 1) }
    $lines.Add((New-ArkuzoLine $footer Cyan $Width))
    return @($lines | Select-Object -First $Height)
}

# === END Arkuzo-Ui.ps1 ===
