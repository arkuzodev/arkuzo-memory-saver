$cpuHistory = New-Object 'System.Collections.Generic.Queue[double]'
$lastHistorySample = -1.0
$frameCache = @{}
$frameSize = ''
$consoleReady = $false
$oldTitle = $null
$oldCursorVisible = $true
try {
    if ($Headless) { throw 'HEADLESS_REQUESTED' }
    if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) {
        throw 'Open this script in Windows Terminal or a regular PowerShell console, without output redirection.'
    }
    $oldTitle = [Console]::Title
    $oldCursorVisible = [Console]::CursorVisible
    [Console]::Title = 'ARKUZO | Memory Saver'
    [Console]::CursorVisible = $false
    [Console]::Clear()
    $consoleReady = $true
} catch {
    $consoleReady = $false
    if (-not $Headless -and [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
        throw "Live dashboard requires an interactive console. $($_.Exception.Message)"
    }
    $Headless = $true
}

# Short, bounded boot sequence; the live view stays motionless between samples.
function Show-ArkuzoBoot {
    for ($step = 0; $step -lt 4; $step++) {
        $width = [Math]::Max(1, [int]([Console]::WindowWidth - 1))
        $height = [Math]::Max(1, [int]([Console]::WindowHeight - 1))
        $frame = @(New-ArkuzoBootFrame -Width $width -Height $height -Step $step)
        [Console]::Clear()
        $oldColor = [Console]::ForegroundColor
        try {
            $top = [Console]::WindowTop; $left = [Console]::WindowLeft
            for ($row = 0; $row -lt $frame.Count; $row++) {
                [Console]::SetCursorPosition($left, $top + $row)
                [Console]::ForegroundColor = $frame[$row].Color
                [Console]::Write($frame[$row].Text)
            }
        } finally { [Console]::ForegroundColor = $oldColor }
        if ($step -lt 3) { Start-Sleep -Milliseconds 130 }
    }
    [Console]::Clear()
}
if (-not $Headless) { Show-ArkuzoBoot }

function Draw-Dashboard($Rows, [int]$Detected, [int64]$Resident, [int64]$Private, [double]$Cpu) {
    if ($Headless) { return }
    Set-ArkuzoConsoleQuickEditDisabled
    try {
        $width = [Math]::Max(1, [int]([Console]::WindowWidth - 1))
        $height = [Math]::Max(1, [int]([Console]::WindowHeight - 1))
        $issues = @($dashboardIssues.Values | Sort-Object Time -Descending)
        $notice = ''
        if ($issues.Count -gt 0) { $notice = [string]$issues[0].Message }
        $model = @{
            Mode = $Mode; TargetMB = $MaxRamMB; SoftLimit = [bool]$SoftLimit
            TrimEnabled = [bool]$EnableTrimming; TrimSeconds = $(if ($null -ne $trimPlan) { $trimPlan.IntervalSec } else { $TrimEverySec })
            TrimPressure = ($null -ne $trimPlan -and [bool]$trimPlan.Pressure)
            Priority = $Priority; CoresPerInstance = $CoresPerInstance
            MonitorOnly = [bool]$MonitorOnly; Detected = $Detected
            Managed = $tracked.Count; ResidentMB = $Resident / 1MB
            PrivateMB = $Private / 1MB; Cpu = $Cpu; Uptime = $clock.Elapsed
            Trims = $script:trimCount; History = @($cpuHistory.ToArray()); SystemMemory = $systemMemory; HealthPolicy = $healthPolicy
            Rows = @($Rows.ToArray()); SuspendedAccounts = @(Get-ArkuzoSuspendedAccountDisplay); Notice = $notice; Now = Get-Date
            Issues = @($issues | Select-Object -First 3)
            ConfigLocked = [bool]$isConfigLocked
        }
        $frame = @(New-ArkuzoFrame -Model $model -Width $width -Height $height)
        $oldColor = [Console]::ForegroundColor
        try {
            $top = [Console]::WindowTop; $left = [Console]::WindowLeft
            $sizeKey = "$width/$height/$top/$left"
            if ($script:frameSize -ne $sizeKey) { $script:frameCache.Clear(); $script:frameSize = $sizeKey }
            for ($row = 0; $row -lt $height; $row++) {
                if ($row -lt $frame.Count -and $frame[$row].PSObject.Properties['Segments'] -and $frame[$row].Segments) {
                    $segs = $frame[$row].Segments
                    $signature = ($segs | ForEach-Object { "$($_.Color):$($_.Text)" }) -join '|'
                    if ($script:frameCache[$row] -ne $signature) {
                        [Console]::SetCursorPosition($left, $top + $row)
                        $written = 0
                        foreach ($s in $segs) {
                            if ($written -ge $width) { break }
                            $stext = [string]$s.Text
                            if ($written + $stext.Length -gt $width) { $stext = $stext.Substring(0, $width - $written) }
                            [Console]::ForegroundColor = [ConsoleColor]$s.Color
                            [Console]::Write($stext)
                            $written += $stext.Length
                        }
                        if ($written -lt $width) { [Console]::Write(' ' * ($width - $written)) }
                        $script:frameCache[$row] = $signature
                    }
                    continue
                }
                $text = ''; $color = [ConsoleColor]::Gray
                if ($row -lt $frame.Count) { $text = $frame[$row].Text; $color = $frame[$row].Color }
                $text = (Fit-ArkuzoText $text $width).PadRight($width)
                $signature = "$color/$text"
                if ($script:frameCache[$row] -eq $signature) { continue }
                [Console]::SetCursorPosition($left, $top + $row)
                [Console]::ForegroundColor = $color
                [Console]::Write($text)
                $script:frameCache[$row] = $signature
            }
        } finally { [Console]::ForegroundColor = $oldColor }
    } catch {
        $script:frameCache.Clear()
        Warn-Throttled 'dashboard-draw' "Failed to render frame: $($_.Exception.Message)"
    }
}

