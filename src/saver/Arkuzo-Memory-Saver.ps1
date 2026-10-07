#requires -Version 5.1
<#
Arkuzo Memory Saver - Windows x64, Windows PowerShell 5.1 / PowerShell 7.
Default: Normal, 850 MB advisory target, trimming ON, BelowNormal priority.
Config presets choose Normal/Agressive/Extreme. Explicit CLI values override config.
Soft targets are advisory only: no working-set quota is installed in soft mode.
Working set = resident physical memory, NOT allocated/private/committed memory.
Trimming causes page faults and can reduce performance; memory can be reloaded.
Ctrl+C restores captured process settings where possible. Force-closing the
console skips cleanup; restart Roblox to reset process settings in that case.
Examples:
  .\Arkuzo-Memory-Saver.ps1
  .\Arkuzo-Memory-Saver.ps1 -Minimize
  .\Arkuzo-Memory-Saver.ps1 -EnableTrimming -HardLimit -MaxRamMB 600 -TrimEverySec 90
  .\Arkuzo-Memory-Saver.ps1 -ApplyGraphicsFlags
Use ArkuzoMemorySaver.exe to choose a preset and start the controller.
Graphics settings persist, affect next launches, and have unique backups.
Diagnostics: Arkuzo-Logs under DataDirectory (unless LogDirectory is set), sampled every 5 seconds.
Each run keeps up to five 10 MB JSON-line .log files; previous sessions remain.
Use -MonitorOnly to log without changing priority, CPU affinity or memory limits.
Version 1.0.1: verified idle COOKIE DEAD accounts are paused separately, not banned.
Fresh verified alive control resumes prior recovery with retained budgets and a new game confirmation.
Unknown/missing account identities remain blocked; no account is guessed or silently discarded.
#>
[CmdletBinding()]
param(
    [ValidateSet('Normal','Agressive','Aggressive','Extreme','Balanced')][string]$Mode = 'Normal',
    [ValidateRange(128,32768)][int]$MaxRamMB = 850,
    [ValidateRange(1,120)][int]$TrimEverySec = 120,
    [ValidateRange(250,10000)][int]$PollMs = 500,
    [ValidateRange(1,64)][int]$CoresPerInstance = 4,
    [ValidateSet('Idle','BelowNormal','Normal')][string]$Priority = 'BelowNormal',
    [switch]$Minimize,
    [switch]$EnableTrimming = $true,
    [switch]$SoftLimit = $true,
    [switch]$HardLimit,
    [switch]$ApplyGraphicsFlags,
    [string]$LogDirectory,
    [string]$DataDirectory,
    [ValidateRange(2,300)][int]$LogEverySec = 5,
    [ValidateRange(1,100)][int]$MaxLogMB = 10,
    [switch]$MonitorOnly,
    [switch]$Headless,
    [ValidateRange(0,86400)][int]$RunForSec = 0,
    [string]$StopFile,
    [ValidateRange(0.25,300)][double]$StatusEverySec = 0.25
)

$ErrorActionPreference = 'Stop'
# Resolve persistent data independently of the versioned program files.
if ([string]::IsNullOrWhiteSpace($DataDirectory)) { $DataDirectory = $PSScriptRoot }
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path $DataDirectory 'Arkuzo-Logs'
}
if ($env:OS -ne 'Windows_NT' -or [IntPtr]::Size -ne 8) {
    throw 'Run Arkuzo Memory Saver in 64-bit PowerShell on Windows.'
}

# 1. Load or prompt config.json
# === EMBEDDED Arkuzo-Config.ps1 ===
<#
Arkuzo Config Management
Provides preset profiles (normal, agressive, extreme), JSON persistence,
interactive first-run preset selection, and free-form setting editing.
#>

function Get-ArkuzoPresets {
    return [ordered]@{
        'normal' = [ordered]@{
            target_ram_mb        = 850
            trim_enabled         = $true
            trim_every_sec       = 120
            priority             = 'BelowNormal'
            cores_per_instance   = 4
            hard_limit           = $false
            poll_ms              = 500
            minimize_on_launch   = $false
            apply_graphics_flags = $false
            description          = 'Higher advisory target (850 MB soft), trim every 120s, 4 cores. Lag and disconnects remain possible.'
        }
        'agressive' = [ordered]@{
            target_ram_mb        = 600
            trim_enabled         = $true
            trim_every_sec       = 60
            priority             = 'BelowNormal'
            cores_per_instance   = 2
            hard_limit           = $false
            poll_ms              = 350
            minimize_on_launch   = $false
            apply_graphics_flags = $false
            description          = 'Multi-account profile: 600 MB working-set target, trim every 60s, 2 cores. Trimming does not repair private-memory leaks.'
        }
        'extreme' = [ordered]@{
            target_ram_mb        = 450
            trim_enabled         = $true
            trim_every_sec       = 30
            priority             = 'BelowNormal'
            cores_per_instance   = 1
            hard_limit           = $false
            poll_ms              = 250
            minimize_on_launch   = $false
            apply_graphics_flags = $false
            description          = 'Maximum instances: Tight advisory target (450 MB soft), trim every 30s, 1 core. Maximum density on 16 GB RAM.'
        }
    }
}

function Save-ArkuzoConfigFile([string]$Path, [string]$Preset = 'normal', $CustomSettings = $null) {
    $presets = Get-ArkuzoPresets
    $cleanPreset = $Preset.ToLowerInvariant().Trim()
    if ($cleanPreset -eq 'aggressive') { $cleanPreset = 'agressive' }
    if (-not $presets.Contains($cleanPreset)) {
        $cleanPreset = 'normal'
    }

    $base = $presets[$cleanPreset]
    $settingsObj = [ordered]@{}
    foreach ($k in $base.Keys) {
        if ($k -eq 'description') { continue }
        $settingsObj[$k] = $base[$k]
    }

    if ($null -ne $CustomSettings) {
        if ($CustomSettings -is [System.Collections.IDictionary]) {
            foreach ($key in $CustomSettings.Keys) { $settingsObj[$key] = $CustomSettings[$key] }
        } elseif ($CustomSettings -is [pscustomobject]) {
            foreach ($prop in $CustomSettings.PSObject.Properties) { $settingsObj[$prop.Name] = $prop.Value }
        }
    }

    $configObj = [ordered]@{
        selected_preset = $cleanPreset
        settings        = $settingsObj
        notes           = 'Freely editable. Deleting this file will reopen the preset selection menu on next launch.'
    }

    $json = $configObj | ConvertTo-Json -Depth 10
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
    return $configObj
}

function Load-ArkuzoConfigFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
            return $null
        }
        return $parsed
    } catch {
        return $null
    }
}

function Select-ArkuzoPresetInteractive([string]$Path) {
    # Check if console is interactive
    $isInteractive = $false
    try {
        if (-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
            $isInteractive = $true
        }
    } catch { }

    if (-not $isInteractive) {
        Write-Host "Non-interactive console detected. Creating default configuration ('normal')..." -ForegroundColor Yellow
        return Save-ArkuzoConfigFile -Path $Path -Preset 'normal'
    }

    $oldColor = [Console]::ForegroundColor
    try {
        [Console]::Clear()
        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        Write-Host "    ___     ____    __ __   __  __   _____    ____"
        Write-Host "   /   |   / __ \  / //_/  / / / /  /__  /   / __ \"
        Write-Host "  / /| |  / /_/ / / ,<    / / / /     / /   / / / /"
        Write-Host " / ___ | / _, _/ / /| |  / /_/ /     / /__ / /_/ /"
        Write-Host "/_/  |_|/_/ |_| /_/ |_|  \____/     /____/ \____/"
        [Console]::ForegroundColor = [ConsoleColor]::White
        Write-Host "  ARKUZO // FIRST TIME SETUP - PRESET SELECTION`n"

        [Console]::ForegroundColor = [ConsoleColor]::Gray
        Write-Host "  No config.json found. Please select your startup profile:"
        Write-Host "  (All values can be freely edited later in config.json)`n"

        [Console]::ForegroundColor = [ConsoleColor]::Green
        Write-Host "  [1] NORMAL  (Recommended for maximum stability)"
        [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
        Write-Host "      - Target RAM: 850 MB soft limit | Trim every 120s | 4 cores | BelowNormal"
        Write-Host "      - Ideal for smooth gameplay & long AFK sessions without disconnects.`n"

        [Console]::ForegroundColor = [ConsoleColor]::Yellow
        Write-Host "  [2] AGRESSIVE  (For multi-account farming)"
        [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
        Write-Host "      - Target RAM: 600 MB soft limit | Trim every 60s | 2 cores | BelowNormal"
        Write-Host "      - High account density. Private commit requires the separate health guard.`n"

        [Console]::ForegroundColor = [ConsoleColor]::Magenta
        Write-Host "  [3] EXTREME  (Maximum instances on 16 GB)"
        [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
        Write-Host "      - Target RAM: 450 MB soft limit | Trim every 30s | 1 core | BelowNormal"
        Write-Host "      - Maximum account count. Aggressive background page trimming.`n"

        [Console]::ForegroundColor = [ConsoleColor]::White
        Write-Host "  Select [1], [2], or [3] (Enter = 1 Normal): " -NoNewline

        $chosen = 'normal'
        while ($true) {
            $keyInfo = [Console]::ReadKey($true)
            if ($keyInfo.Key -eq [ConsoleKey]::D1 -or $keyInfo.Key -eq [ConsoleKey]::NumPad1 -or $keyInfo.Key -eq [ConsoleKey]::Enter) {
                $chosen = 'normal'; Write-Host "1 (Normal)`n"; break
            }
            if ($keyInfo.Key -eq [ConsoleKey]::D2 -or $keyInfo.Key -eq [ConsoleKey]::NumPad2) {
                $chosen = 'agressive'; Write-Host "2 (Agressive)`n"; break
            }
            if ($keyInfo.Key -eq [ConsoleKey]::D3 -or $keyInfo.Key -eq [ConsoleKey]::NumPad3) {
                $chosen = 'extreme'; Write-Host "3 (Extreme)`n"; break
            }
        }

        $saved = Save-ArkuzoConfigFile -Path $Path -Preset $chosen
        [Console]::ForegroundColor = [ConsoleColor]::Green
        Write-Host "  [+] Config saved: $Path"
        Write-Host "  [+] Selected profile: $chosen"
        [Console]::ForegroundColor = [ConsoleColor]::Gray
        Write-Host "  Tip: Delete config.json at any time to reopen the preset selector.`n"
        Start-Sleep -Milliseconds 900
        return $saved
    } finally {
        [Console]::ForegroundColor = $oldColor
    }
}

# === END Arkuzo-Config.ps1 ===
# === EMBEDDED Arkuzo-Health.ps1 ===
# Pure health decisions. No process is modified by this module on import.
if (-not ('Arkuzo.HealthNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Arkuzo {
 public static class HealthNativeV1 {
  [StructLayout(LayoutKind.Sequential)]
  struct PerformanceInfo {
   public uint cb;
   public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable;
   public UIntPtr SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize;
   public uint HandleCount, ProcessCount, ThreadCount;
  }
  [DllImport("psapi.dll", SetLastError=true)]
  static extern bool GetPerformanceInfo(out PerformanceInfo info, uint size);
  [DllImport("user32.dll", SetLastError=true)]
  static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  static extern int GetWindowText(IntPtr h, StringBuilder text, int count);
  delegate bool ChildCallback(IntPtr window, IntPtr value);
  [DllImport("user32.dll")]
  static extern bool EnumChildWindows(IntPtr h, ChildCallback callback, IntPtr value);
  public static double[] MemoryMB() {
   PerformanceInfo i;
   if (!GetPerformanceInfo(out i, (uint)Marshal.SizeOf(typeof(PerformanceInfo)))) throw new Win32Exception(Marshal.GetLastWin32Error());
   double page = i.PageSize.ToUInt64() / 1048576.0;
   return new double[] { i.CommitTotal.ToUInt64()*page, i.CommitLimit.ToUInt64()*page, i.PhysicalAvailable.ToUInt64()*page };
  }
  // A 100ms bounded WM_NULL probe avoids .NET Responding's multi-second stalls.
  public static bool IsResponsive(IntPtr window) {
   if (window == IntPtr.Zero) return false;
   IntPtr result;
   return SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 0x22, 100, out result) != IntPtr.Zero;
  }
  public static bool HasVoltStartupNotice(IntPtr window) {
   if (window == IntPtr.Zero) return false;
   var title = new StringBuilder(256); GetWindowText(window, title, title.Capacity);
   if (!title.ToString().Equals("Notice", StringComparison.OrdinalIgnoreCase)) return false;
   bool found = false;
   EnumChildWindows(window, delegate(IntPtr child, IntPtr v) {
    var text = new StringBuilder(1024); GetWindowText(child, text, text.Capacity);
    if (text.ToString().IndexOf("Roblox started before Volt could connect", StringComparison.OrdinalIgnoreCase) >= 0) found = true;
    return !found;
   }, IntPtr.Zero);
   return found;
  }
 }
}
'@
}
function Get-ArkuzoSystemMemory {
    $v = [Arkuzo.HealthNativeV1]::MemoryMB()
    return [pscustomobject]@{
        commitUsedMB = [Math]::Round($v[0], 1); commitLimitMB = [Math]::Round($v[1], 1)
        freeCommitMB = [Math]::Round([Math]::Max(0, $v[1] - $v[0]), 1)
        commitPercent = [Math]::Round(100 * $v[0] / [Math]::Max(1, $v[1]), 2)
        availablePhysicalMB = [Math]::Round($v[2], 1)
    }
}
function Test-ArkuzoVoltOwnership([int]$ParentId, $Parent, [long]$ClientStartTicks, [string]$VoltPath) {
    if ($null -eq $Parent -or $ParentId -ne [int]$Parent.Id -or
        [long]$Parent.StartTicks -ge $ClientStartTicks -or [string]::IsNullOrWhiteSpace($VoltPath)) { return $false }
    return [string]::Equals([string]$Parent.Path, $VoltPath, [StringComparison]::OrdinalIgnoreCase)
}
function Test-ArkuzoRecoveryBudget($AttemptTimes, [datetime]$NowUtc, [int]$CooldownSec = 60, [int]$MaxPerHour = 20) {
    try {
        $recent = @($AttemptTimes | ForEach-Object { ([datetime]$_).ToUniversalTime() } | Where-Object { ($NowUtc.ToUniversalTime() - $_).TotalSeconds -lt 3600 })
        if ($recent.Count -ge $MaxPerHour) { return $false }
        if ($recent.Count -gt 0) {
            $last = $recent | Sort-Object -Descending | Select-Object -First 1
            if (($NowUtc.ToUniversalTime() - $last).TotalSeconds -lt $CooldownSec) { return $false }
        }
        return $true
    } catch { return $false }
}
function Find-RobloxProcessLog([int]$TargetProcessId, [string]$TrackerId = $null, [datetime]$StartTimeUtc = [datetime]::MinValue, [string]$LogsDir = $null) {
    try {
        if ($TrackerId -notmatch '\A[0-9]+\z' -or $StartTimeUtc -eq [datetime]::MinValue) { return $null }
        $dir = if ($LogsDir) { $LogsDir } else { Join-Path $env:LOCALAPPDATA 'Roblox\logs' }
        if (-not (Test-Path -LiteralPath $dir)) { return $null }
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*_Player_*_last.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*CrashHandler*' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 30)
        if ($TrackerId -and [regex]::IsMatch($TrackerId, '^\d+$')) {
            foreach ($f in $files) {
                try {
                    if ($f.Name -notmatch '_(\d{8}T\d{6}Z)_Player_') { continue }
                    $fTime = [DateTime]::ParseExact($matches[1], 'yyyyMMdd\THHmmss\Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
                    if ([Math]::Abs(($fTime - $StartTimeUtc.ToUniversalTime()).TotalSeconds) -gt 5) { continue }
                    $lines = Get-Content -LiteralPath $f.FullName -TotalCount 50 -ErrorAction SilentlyContinue
                    foreach ($l in $lines) {
                        if ($l -match "websiteBTId is\s*(\d+)" -or $l -match "BTID is overriden to\s*(\d+)") {
                            if ($matches[1] -eq $TrackerId) { return $f.FullName }
                        }
                    }
                } catch { }
            }
        }
        # Never bind a game log by launch-time proximity alone.
        return $null
    } catch { return $null }
}

$script:accountNameCache = @{}
$script:userIdCache = @{}

function Get-ArkuzoAccountByUserId([string]$UserId) {
    if (-not $UserId -or $UserId -notmatch '\A\d+\z') { return $null }
    if ($null -eq $script:userIdCache) { $script:userIdCache = @{} }
    if ($script:userIdCache.ContainsKey($UserId)) { return $script:userIdCache[$UserId] }
    try {
        $dir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { [AppDomain]::CurrentDomain.BaseDirectory }
        $probeScript = Join-Path $dir 'Arkuzo-Volt-Probe.py'
        if (-not (Test-Path -LiteralPath $probeScript)) {
            $probeScript = 'C:/Users/Philip/Desktop/arkuzo-memory-saver/src/saver/Arkuzo-Volt-Probe.py'
        }
        if (Test-Path -LiteralPath $probeScript) {
            $raw = & python $probeScript --user-id $UserId 2>$null
            if ($raw) {
                $parsed = $raw | ConvertFrom-Json
                if ($parsed -and $parsed.found -and $parsed.username) {
                    $script:userIdCache[$UserId] = [string]$parsed.username
                    return [string]$parsed.username
                }
            }
        }
    } catch { }
    $script:userIdCache[$UserId] = $null
    return $null
}

function Resolve-ArkuzoAccountName([int]$ProcessId, [string]$TrackerId = $null, [string]$LogPath = $null) {
    if ($null -eq $script:accountNameCache) { $script:accountNameCache = @{} }
    if ($script:accountNameCache.ContainsKey($ProcessId)) {
        return $script:accountNameCache[$ProcessId]
    }
    $resolved = $null

    # 1. Primary: Exact Volt Status match (trackerId + processId)
    if ($voltControlStatus.available -and $voltControlStatus.accounts) {
        $exact = @($voltControlStatus.accounts | Where-Object { $_.trackerId -and $_.trackerId -eq $TrackerId -and $_.processId -eq $ProcessId })
        if ($exact.Count -eq 1 -and $exact[0].username) {
            $resolved = [string]$exact[0].username
        }
    }

    # 2. Secondary: Volt Status match by TrackerId only (when processId is null in Volt UI automation)
    if (-not $resolved -and $TrackerId -and $voltControlStatus.available -and $voltControlStatus.accounts) {
        $byTracker = @($voltControlStatus.accounts | Where-Object { $_.trackerId -and $_.trackerId -eq $TrackerId })
        if ($byTracker.Count -eq 1 -and $byTracker[0].username) {
            $resolved = [string]$byTracker[0].username
        }
    }

    # 3. Tertiary: Parse Roblox Client Log for websiteBTId or userid
    if (-not $resolved -and $LogPath -and (Test-Path -LiteralPath $LogPath)) {
        try {
            $match = Select-String -Path $LogPath -Pattern 'userid:(\d+)' | Select-Object -First 1
            if ($match -and $match.Matches[0].Groups[1].Value) {
                $uid = $match.Matches[0].Groups[1].Value
                $mappedUser = Get-ArkuzoAccountByUserId $uid
                if ($mappedUser) {
                    $resolved = $mappedUser
                } else {
                    $resolved = "UID:$uid"
                }
            }
        } catch { }
    }

    # 4. Quaternary: Tracker ID indicator
    if (-not $resolved -and $TrackerId) {
        $shortId = if ($TrackerId.Length -gt 8) { $TrackerId.Substring(0, 8) + '..' } else { $TrackerId }
        $resolved = "ID:$shortId"
    }

    if (-not $resolved) { $resolved = 'Unmapped' }
    if ($resolved -ne 'Unmapped') { $script:accountNameCache[$ProcessId] = $resolved }
    return $resolved
}
function Read-RobloxLogTail([string]$Path, [ref]$CurrentOffset) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fs = $null
    try {
        $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -le 0) { return $null }
        if ($CurrentOffset.Value -le 0) {
            # Initial read: inspect up to 64KB tail to catch recent disconnects without reading massive files
            $start = [Math]::Max(0L, $len - 65536L)
            $fs.Seek($start, [IO.SeekOrigin]::Begin) | Out-Null
            $toRead = [int]($len - $start)
            $buf = New-Object byte[] $toRead
            $read = $fs.Read($buf, 0, $toRead)
            $CurrentOffset.Value = $len
            return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        }
        if ($len -lt $CurrentOffset.Value) { $CurrentOffset.Value = 0; return $null }
        if ($len -eq $CurrentOffset.Value) { return $null }
        if (($len - $CurrentOffset.Value) -gt 65536) { $CurrentOffset.Value = $len - 65536 }
        $fs.Seek($CurrentOffset.Value, [IO.SeekOrigin]::Begin) | Out-Null
        $toRead = [int]($len - $CurrentOffset.Value)
        $buf = New-Object byte[] $toRead
        $read = $fs.Read($buf, 0, $toRead)
        $CurrentOffset.Value += $read
        return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } catch { return $null }
    finally { if ($null -ne $fs) { $fs.Dispose() } }
}
function Get-RobloxLogDisconnectReason([string]$NewText) {
    if ([string]::IsNullOrWhiteSpace($NewText)) { return $null }
    $lines = $NewText -split "(\r?\n)"
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match "(?i)(?:Disconnection Notification\. Reason|Disconnect reason received|Disconnected from server for reason:\s*(?:Player:)?|Sending disconnect with reason):\s*([0-9]+)") {
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
function Get-ArkuzoVoltRecoveryStatus([string]$Root, [string]$TrackerId) {
    $child = $null
    try {
        $probe = Join-Path $Root 'Arkuzo-Volt-Probe.py'
        if (-not (Test-Path -LiteralPath $probe)) { throw 'Probe unavailable' }
        $python = Get-Command python3.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $python) { $python = Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $python.Source; $info.Arguments = '"' + $probe + '"'
        if ($PSBoundParameters.ContainsKey('TrackerId')) {
            if (-not [regex]::IsMatch($TrackerId, '\A[0-9]+\z')) { throw 'Invalid target metadata' }
            $info.Arguments += ' --tracker-id ' + $TrackerId # Only non-secret digits, never command lines/tickets.
        }
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $child = [Diagnostics.Process]::Start($info)
        if (-not $child.WaitForExit(3000)) { $child.Kill(); throw 'Probe timeout' }
        if ($child.ExitCode -ne 0) { throw 'Probe failed' }
        $result = $child.StandardOutput.ReadToEnd() | ConvertFrom-Json
        if ($null -eq $result.safeToRecycle) { throw 'Invalid probe result' }
        return $result
    } catch { return [pscustomobject]@{ safeToRecycle = $false; reason = 'Volt recovery probe unavailable' } }
    finally { if ($null -ne $child) { $child.Dispose() } }
}
function Get-ArkuzoHealthPolicy($Config) {
    $defaults = @{ enabled = $false; private_limit_mb = 4096; hang_timeout_sec = 120; warmup_sec = 180; pressure_percent = 85; pressure_min_private_mb = 2048; cooldown_sec = 60; max_recycles_per_hour = 20; trim_spacing_sec = 2; startup_error_timeout_sec = 40; disconnect_timeout_sec = 5; private_limit_sustain_sec = 60 }
    if ($null -ne $Config) {
        foreach ($key in @($defaults.Keys)) { if ($null -ne $Config.$key) { $defaults[$key] = $Config.$key } }
    }
    $ranges = @{ private_limit_mb = @(1024,16384); hang_timeout_sec = @(60,900); warmup_sec = @(60,900); pressure_percent = @(60,98); pressure_min_private_mb = @(1024,16384); cooldown_sec = @(30,300); max_recycles_per_hour = @(1,60); trim_spacing_sec = @(1,30); startup_error_timeout_sec = @(0,300); disconnect_timeout_sec = @(0,300); private_limit_sustain_sec = @(0,300) }
    foreach ($key in $ranges.Keys) {
        $value = [double]$defaults[$key]
        if ($value -lt $ranges[$key][0] -or $value -gt $ranges[$key][1] -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "Invalid health setting: $key" }
    }
    if ($defaults.enabled -isnot [bool]) { throw 'health.enabled must be a JSON boolean' }
    return $defaults
}
function Clear-VoltRecoveryCapability {
    foreach ($parent in @($script:voltParents.Values)) {
        if ($null -ne $parent.Process) { try { $parent.Process.Dispose() } catch { } }
    }
    $script:voltParents = @{}
}
function Update-VoltRecoveryCapability {
    Clear-VoltRecoveryCapability
    $script:voltStatus = Get-ArkuzoVoltRecoveryStatus -Root $PSScriptRoot
    Update-ArkuzoVoltControl
    foreach ($manager in @(Get-Process -Name tauri-app -ErrorAction SilentlyContinue)) {
        $retained = $false
        try {
            $handle = $manager.Handle # Open the exact process handle before verifying identity.
            $manager.Refresh()
            $exited = $manager.HasExited
            if ($handle -is [IntPtr] -and $handle -ne [IntPtr]::Zero -and $exited -is [bool] -and -not $exited -and [string]::Equals($manager.Path, $voltPath, [StringComparison]::OrdinalIgnoreCase)) {
                $script:voltParents[$manager.Id] = @{ Id = $manager.Id; Path = $manager.Path; StartTicks = $manager.StartTime.ToUniversalTime().Ticks; Process = $manager; Handle = $handle }
                $retained = $true
            }
        } catch { } finally { if (-not $retained) { try { $manager.Dispose() } catch { } } }
    }
    if ($healthPolicy.enabled -and (-not $voltStatus.safeToRecycle -or $voltParents.Count -eq 0)) {
        Warn-Throttled 'recovery-not-ready' 'Recovery blocked: Volt auto-relaunch/session/manager is not ready. Clients left untouched.'
    }
}
function Test-ArkuzoLiveVoltParent($Parent) {
    try {
        if ($null -eq $Parent -or $null -eq $Parent.Process -or $Parent.Handle -isnot [IntPtr] -or $Parent.Handle -eq [IntPtr]::Zero) { return $false }
        $manager = $Parent.Process
        $manager.Refresh()
        if ($manager.Id -ne $Parent.Id -or
            $manager.StartTime.ToUniversalTime().Ticks -ne $Parent.StartTicks -or
            -not [string]::Equals($manager.Path, $Parent.Path, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $exited = $manager.HasExited
        return ($exited -is [bool] -and -not $exited)
    } catch { return $false }
}
function Save-ArkuzoAtomicJson([string]$Path, $Value) {
    $temp = $Path + '.' + $PID + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
function Save-ArkuzoRecoveryJournal {
    if (-not $ownsControllerMutex -or -not $recoveryJournalHealthy) { throw 'Recovery journal not owned/healthy' }
    $utc = [datetime]::UtcNow
    $script:recoveryAttempts = @($recoveryAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 })
    $script:launchAttempts = @($launchAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 })
    Save-ArkuzoAtomicJson $recoveryStatePath @{
        schemaVersion = 2; attempts = @($recoveryAttempts | ForEach-Object { $_.ToString('o') })
        launchAttempts = @($launchAttempts | ForEach-Object { $_.ToString('o') })
        pending = @($recoveryPending.Values); suspendedAccounts = @($script:suspendedAccounts.Values); updatedUtc = $utc.ToString('o')
    }
}
function Initialize-ArkuzoRecoveryJournal {
    # Load only while holding the sole destructive-controller mutex.
    $script:recoveryJournalHealthy = $false; $script:recoveryAttempts = @(); $script:launchAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}
    if (-not $ownsControllerMutex) { return }
    try {
        if (Test-Path -LiteralPath $recoveryStatePath) {
            $journal = [IO.File]::ReadAllText($recoveryStatePath) | ConvertFrom-Json
            if ($null -eq $journal.attempts) { throw 'Invalid recovery journal' }
            $script:recoveryAttempts = @($journal.attempts | ForEach-Object { ([datetime]$_).ToUniversalTime() })
            $script:launchAttempts = @($journal.launchAttempts | ForEach-Object { if ($null -ne $_) { ([datetime]$_).ToUniversalTime() } })
            foreach ($value in @($journal.pending)) {
                if ($null -eq $value) { continue }
                if ($value.accountId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or
                    $value.oldTrackerId -notmatch '\A[0-9]+\z' -or $null -eq $value.createdUtc -or $null -eq $value.retryCount -or
                    $recoveryPending.ContainsKey([string]$value.accountId)) { throw 'Invalid pending recovery entry' }
                [datetime]$value.createdUtc | Out-Null
                if ($value.closedUtc) { [datetime]$value.closedUtc | Out-Null }
                if ($value.nextRetryUtc) { [datetime]$value.nextRetryUtc | Out-Null }
                if ([int]$value.retryCount -lt 0) { throw 'Invalid retry count' }
                $entry = @{}; foreach ($prop in $value.PSObject.Properties) { $entry[$prop.Name] = $prop.Value }
                # A monitor restart breaks continuity; never inherit a previous healthy timer.
                $entry.readySinceUtc = $null; $entry.lastObservedUtc = $null
                $script:recoveryPending[[string]$value.accountId] = $entry
            }
            foreach ($value in @($journal.suspendedAccounts)) {
                if ($null -eq $value) { continue }
                if ($value.accountId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or
                    $value.reason -ne 'COOKIE_DEAD' -or -not $value.suspendedUtc -or $suspendedAccounts.ContainsKey([string]$value.accountId) -or $recoveryPending.ContainsKey([string]$value.accountId)) { throw 'Invalid suspended account' }
                [datetime]$value.suspendedUtc | Out-Null
                $entry=@{}; foreach ($prop in $value.PSObject.Properties) { $entry[$prop.Name]=$prop.Value }
                if ($null -ne $value.pending) {
                    if ($value.pending.accountId -ne $value.accountId -or $value.pending.oldTrackerId -notmatch '\A[0-9]+\z' -or $null -eq $value.pending.retryCount -or [int]$value.pending.retryCount -lt 0 -or -not $value.pending.createdUtc) { throw 'Invalid suspended history' }
                    [datetime]$value.pending.createdUtc | Out-Null
                    if ($value.pending.nextRetryUtc) { [datetime]$value.pending.nextRetryUtc | Out-Null }
                    if ($value.pending.closedUtc) { [datetime]$value.pending.closedUtc | Out-Null }
                    $entry.pending=@{}; foreach ($prop in $value.pending.PSObject.Properties) { $entry.pending[$prop.Name]=$prop.Value }
                    $entry.pending.readySinceUtc=$null; $entry.pending.lastObservedUtc=$null
                }
                $script:suspendedAccounts[[string]$value.accountId]=$entry
            }
        }
        $script:recoveryJournalHealthy = $true
    } catch { $script:recoveryJournalHealthy = $false }
}
function Get-ArkuzoRecoveryHealthSample($Watcher, [string]$Reason, $CurrentState = $null) {
    $Watcher.Refresh()
    $window = $Watcher.MainWindowHandle
    # Native probes are bounded and do not send close/input messages.
    $responding = [Arkuzo.HealthNativeV1]::IsResponsive($window)
    $launchError = [Arkuzo.HealthNativeV1]::HasVoltStartupNotice($window)
    $isDisconnected = $false
    if ($Reason -eq 'IN_GAME_DISCONNECT' -and $null -ne $CurrentState -and $CurrentState.isDisconnected) {
        $isDisconnected = $true
    }
    $commitPercent = 0.0
    if ($Reason -eq 'SYSTEM_COMMIT_PRESSURE') { $commitPercent = (Get-ArkuzoSystemMemory).commitPercent }
    return @{
        privateMB = $Watcher.PrivateMemorySize64 / 1MB
        ageSec = ([DateTime]::UtcNow - $Watcher.StartTime.ToUniversalTime()).TotalSeconds
        responding = $responding; windowPresent = ($window -ne [IntPtr]::Zero); launchError = $launchError
        isDisconnected = $isDisconnected
        systemCommitPercent = $commitPercent; eligible = $true
    }
}
function Test-ArkuzoClientIdentity($Watcher, [int]$ClientId, [long]$StartTicks) {
    try {
        if ($null -eq $Watcher) { return $false }
        $Watcher.Refresh()
        $exited = $Watcher.HasExited
        # PowerShell can turn a failed .NET property getter into $null.
        return ($exited -is [bool] -and -not $exited -and $Watcher.Id -eq $ClientId -and
            $Watcher.StartTime.ToUniversalTime().Ticks -eq $StartTicks -and
            $Watcher.ProcessName -eq 'RobloxPlayerBeta')
    } catch { return $false }
}
function Get-ArkuzoBrowserTrackerId([string]$CommandLine) {
    if ([string]::IsNullOrEmpty($CommandLine)) { return $null }
    # Keep the command line in memory only: it also contains authentication tickets.
    $matches = [regex]::Matches($CommandLine, '(?i)(?<![a-z0-9_])browsertrackerid(?::|=|%3A)([0-9]+)(?=$|[\s+&"'']|%2b|%26|%20|%22)')
    if ($matches.Count -lt 1) { return $null }
    $unique = @($matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($unique.Count -ne 1) { return $null }
    return [string]$unique[0]
}
function Test-ArkuzoTargetRecovery($Watcher, [int]$ClientId, [long]$StartTicks) {
    try {
        if (-not (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks)) { return $false }
        $records = @(Get-CimInstance Win32_Process -Filter "ProcessId=$ClientId" -ErrorAction Stop)
        if ($records.Count -ne 1 -or $records[0].ProcessId -ne $ClientId -or $records[0].Name -ne 'RobloxPlayerBeta.exe' -or $records[0].CommandLine -isnot [string]) { return $false }
        $trackerId = Get-ArkuzoBrowserTrackerId $records[0].CommandLine
        # A retained exact process alive on both sides of the metadata query
        # binds the PID query to this generation, without timestamp/slot guesses.
        if ([string]::IsNullOrEmpty($trackerId) -or -not (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks)) { return $false }
        $target = Get-ArkuzoVoltRecoveryStatus -Root $PSScriptRoot -TrackerId $trackerId
        if ($null -eq (Get-ArkuzoControlledAccount $trackerId $ClientId)) { return $false }
        return ($target.safeToRecycle -is [bool] -and $target.safeToRecycle -and
            $target.targetReady -is [bool] -and $target.targetReady -and $target.matchedAccountCount -eq 1 -and
            (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks))
    } catch { return $false } # Never expose command lines, tickets, or account state in errors.
}
function Get-ArkuzoRestorePolicy($Config) {
    $p = @{ enabled=$false; restore_missing=$true; restore_wait_sec=90; relaunch_delay_sec=30; retry_base_sec=90; retry_max_sec=900; retry_max_per_hour=6; ready_stable_sec=30; excluded_account_ids=@() }
    if ($null -ne $Config) { foreach ($k in @($p.Keys)) { if ($null -ne $Config.$k) { $p[$k]=$Config.$k } } }
    foreach ($b in @('enabled','restore_missing')) { if ($p[$b] -isnot [bool]) { throw "recovery.$b must be a JSON boolean" } }
    $ranges=@{ restore_wait_sec=@(90,900); relaunch_delay_sec=@(30,120); retry_base_sec=@(90,900); retry_max_sec=@(180,3600); retry_max_per_hour=@(1,12); ready_stable_sec=@(30,300) }
    foreach ($k in $ranges.Keys) {
        $v=[double]$p[$k]
        if ([double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -lt $ranges[$k][0] -or $v -gt $ranges[$k][1] -or [math]::Floor($v) -ne $v) { throw "Invalid recovery setting: $k" }
    }
    if ($p.retry_max_sec -lt $p.retry_base_sec) { throw 'Retry maximum must cover base delay' }
    foreach ($id in @($p.excluded_account_ids)) { if ($id -notmatch '\A[0-9a-fA-F-]{36}\z') { throw 'Invalid excluded account identifier' } }
    return $p
}
function Get-ArkuzoRetryDelay([int]$Attempt, $Policy) {
    return [int][math]::Min([double]$Policy.retry_max_sec, [double]$Policy.retry_base_sec * [math]::Pow(2,[math]::Min(20,[math]::Max(0,$Attempt-1))))
}
function Invoke-ArkuzoVoltControl([ValidateSet('Status','Configure','LaunchMissing')][string]$Action='Status', [string]$AccountId='', [string]$TrackerId='') {
    $child=$null
    try {
        if ($Action -ne 'Status' -and ($MonitorOnly -or -not $ownsControllerMutex -or -not $restorePolicy.enabled)) { throw 'Read-only controller' }
        $file=Join-Path $PSScriptRoot 'Arkuzo-Volt-Control.ps1'
        if (-not (Test-Path -LiteralPath $file)) { throw 'Control adapter unavailable' }
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName='powershell.exe'
        $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $file + '" -Action ' + $Action + ' -RelaunchDelaySec ' + [int]$restorePolicy.relaunch_delay_sec + ' -MinLaunchAgeSec ' + [int]$restorePolicy.restore_wait_sec
        if ($Action -eq 'LaunchMissing') {
            if ($AccountId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or $TrackerId -notmatch '\A[0-9]+\z') { throw 'Invalid non-secret account metadata' }
            $info.Arguments+=' -AccountId ' + $AccountId + ' -ExpectedTrackerId ' + $TrackerId
        }
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $child=[Diagnostics.Process]::Start($info)
        $out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(15000)) { $child.Kill();throw 'Volt UI adapter timeout' }
        if ($child.ExitCode -ne 0) { throw 'Volt UI adapter refused request' }
        $result=$out.Result|ConvertFrom-Json
        if ($result.available -isnot [bool]) { throw 'Invalid control snapshot' }
        return $result
    } catch { return [pscustomobject]@{available=$false;requestAccepted=$false;reason='Volt background control unavailable/refused';accounts=@()} }
    finally { if ($child) { $child.Dispose() } }
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
function Get-ArkuzoControlledAccount([string]$TrackerId, [int]$ClientId) {
    if (-not $restorePolicy.enabled -or -not $voltControlStatus.available -or
            $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe -or
            $null -eq $voltControlCheckedUtc -or ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -lt 0 -or
            (([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -gt 25) -or
        [int]$voltControlStatus.relaunchDelayMs -lt ([int]$restorePolicy.relaunch_delay_sec*1000)) { return $null }
    foreach($key in @($script:suspendedAccounts.Keys)) {
        $rows=@($voltControlStatus.accounts | Where-Object { $_.accountId -ceq $key })
        if ($rows.Count -ne 1) { return $null }
        $a=$rows[0]
        if ($a.cookieStatus -cne 'dead' -or $a.suspensionSafe -isnot [bool] -or -not $a.suspensionSafe -or $a.uiStatus -cne 'Idle' -or $a.processId) { return $null }
    }
    $matches=@($voltControlStatus.accounts|Where-Object { $_.trackerId -eq $TrackerId -and $_.processId -eq $ClientId -and $_.controlReady -is [bool] -and $_.controlReady })
    if ($matches.Count -ne 1 -or $matches[0].cookieStatus -ceq 'dead' -or ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey([string]$matches[0].accountId)) -or $restorePolicy.excluded_account_ids -contains $matches[0].accountId) { return $null }
    return $matches[0]
}
function New-ArkuzoPendingEntry([string]$AccountId,[string]$TrackerId,[int]$OldId=0,[long]$OldTicks=0) {
    return @{accountId=$AccountId;oldTrackerId=$TrackerId;oldPid=$OldId;oldStartTicks=$OldTicks;createdUtc=[datetime]::UtcNow.ToString('o');closedUtc=$null;status='AwaitingReplacement';retryCount=0;nextRetryUtc=$null;readySinceUtc=$null;lastObservedUtc=$null;replacementPid=0;replacementStartTicks=0}
}
function Update-ArkuzoCookieSuspensions {
    # Caller must own a healthy journal and a fresh available adapter snapshot.
    if ($null -eq $script:suspendedAccounts) { $script:suspendedAccounts=@{} }
    $utc=[datetime]::UtcNow
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe -or ($utc-$voltControlCheckedUtc).TotalSeconds -lt 0 -or ($utc-$voltControlCheckedUtc).TotalSeconds -gt 25) { return }
    foreach ($a in @($voltControlStatus.accounts)) {
        $key=[string]$a.accountId
        if ($key -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or @($voltControlStatus.accounts|Where-Object { $_.accountId -eq $key }).Count -ne 1) { continue }
        $suspend=$a.cookieStatus -ceq 'dead' -and $a.suspensionSafe -is [bool] -and $a.suspensionSafe -and -not $a.processId -and $a.uiStatus -eq 'Idle'
        $resume=$suspendedAccounts.ContainsKey($key) -and $a.cookieStatus -ceq 'alive' -and $a.controlReady -is [bool] -and $a.controlReady -and $a.cookieAlive -is [bool] -and $a.cookieAlive -and $a.trackerId -match '\A[0-9]+\z'
        if ((-not $suspend -or $suspendedAccounts.ContainsKey($key)) -and -not $resume) { continue }
        $beforePending=$recoveryPending.Clone();$beforeSuspended=$suspendedAccounts.Clone()
        try {
            Write-Diagnostic $(if($resume){'COOKIE_ACCOUNT_RESUMED'}else{'COOKIE_ACCOUNT_SUSPENDED'}) @{accountId=$key;username=$a.username;reason='COOKIE_DEAD';note='Cookie/session validity only; not evidence of a ban.'}
            if ($logFailed) { throw 'Suspension requires audit logging' }
            if ($resume) {
                $history=$suspendedAccounts[$key].pending
                if ($null -ne $history -and [long]$a.lastLaunchAtMs -gt 0 -and $a.autoRelaunch -and $restorePolicy.excluded_account_ids -notcontains $key) {
                    $history=$history.Clone();$history.readySinceUtc=$null;$history.lastObservedUtc=$null;$history.replacementPid=0;$history.replacementStartTicks=0;$history.status='AwaitingReplacement'
                    $script:recoveryPending[$key]=$history
                }
                $script:suspendedAccounts.Remove($key)
            } else {
                $history=$null;if ($recoveryPending.ContainsKey($key)) { $history=$recoveryPending[$key].Clone();$history.readySinceUtc=$null;$history.lastObservedUtc=$null }
                $script:suspendedAccounts[$key]=@{accountId=$key;username=$a.username;reason='COOKIE_DEAD';suspendedUtc=$utc.ToString('o');pending=$history}
                $script:recoveryPending.Remove($key)
            }
            Save-ArkuzoRecoveryJournal
        } catch {
            $script:recoveryPending=$beforePending;$script:suspendedAccounts=$beforeSuspended;$script:recoveryJournalHealthy=$false
            throw
        }
    }
}
function Update-ArkuzoRecoveryOutcomes {
    if ($MonitorOnly -or -not $restorePolicy.enabled -or -not $ownsControllerMutex -or -not $recoveryJournalHealthy) { return }
    $utc=[datetime]::UtcNow
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe -or ($utc-$voltControlCheckedUtc).TotalSeconds -lt 0 -or ($utc-$voltControlCheckedUtc).TotalSeconds -gt 25) {
        foreach ($entry in $recoveryPending.Values) { $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null }
        Warn-Throttled 'volt-control' 'Volt account control unavailable. Clients left untouched; missing-account recovery is degraded.'
        return
    }
    try {
        Update-ArkuzoCookieSuspensions
        # Opted-in, previously launched accounts only. Never activate new/unconfigured accounts.
        foreach ($a in @($voltControlStatus.accounts)) {
            if ($script:suspendedAccounts.ContainsKey([string]$a.accountId) -or $a.cookieStatus -cne 'alive' -or -not $a.autoRelaunch -or -not $a.cookieAlive -or $restorePolicy.excluded_account_ids -contains $a.accountId) { continue }
            if ($restorePolicy.restore_missing -and -not $a.processId -and $a.uiStatus -eq 'Idle' -and [long]$a.lastLaunchAtMs -gt 0 -and
                $a.trackerId -match '\A[0-9]+\z' -and -not $recoveryPending.ContainsKey([string]$a.accountId)) {
                $script:recoveryPending[[string]$a.accountId]=New-ArkuzoPendingEntry $a.accountId $a.trackerId
                Write-Diagnostic 'MISSING_ACCOUNT_DETECTED' @{accountId=$a.accountId;username=$a.username;note='Wait for native Volt queue before a bounded missing-account request.'}
            }
        }
        foreach ($key in @($recoveryPending.Keys)) {
            $entry=$recoveryPending[$key]
            $candidates=@($voltControlStatus.accounts|Where-Object{$_.accountId -eq $key})
            if ($candidates.Count -ne 1) { $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';Warn-Throttled ('restore-'+$key) 'Pending account missing or ambiguous in Volt. No client closures.';continue }
            $a=$candidates[0]
            if ($a.cookieStatus -cne 'alive') { $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';continue }
            if (-not $a.autoRelaunch -or $restorePolicy.excluded_account_ids -contains $key) {
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account no longer opted in'}
                $script:recoveryPending.Remove($key);continue
            }
            $sample=@{available=$true;accountId=$key;controlReady=[bool]$a.controlReady;autoRelaunch=[bool]$a.autoRelaunch;cookieAlive=[bool]$a.cookieAlive;uiStatus=$a.uiStatus;processId=$a.processId;trackerId=$a.trackerId;startTicks=0;windowPresent=$false;responding=$false;launchError=$false;isDisconnected=$false;gameReady=$false}
            if ($a.processId -and $tracked.ContainsKey([int]$a.processId)) {
                $state=$tracked[[int]$a.processId]
                if ($state.TrackerId -eq $a.trackerId -and (Test-ArkuzoClientIdentity $state.Watcher ([int]$a.processId) $state.StartTicks) -and $state.LastSnapshot) {
                    $sample.sampleUtc=$state.HealthSnapshotUtc
                    $sample.startTicks=$state.StartTicks;$sample.windowPresent=$state.LastSnapshot.windowPresent;$sample.responding=$state.LastSnapshot.responding
                    $sample.launchError=$state.LastSnapshot.launchError;$sample.isDisconnected=[bool]$state.isDisconnected;$sample.gameReady=[bool]$state.GameReady
                }
            }
            $decision=Get-ArkuzoOutcomeDecision $entry $sample $utc $restorePolicy
            if ($decision -ne $entry.status) {
                Write-Diagnostic 'RECOVERY_OUTCOME_STATE' @{accountId=$key;previous=$entry.status;status=$decision;replacementPid=$sample.processId}
                $entry.status=$decision
            }
            if ($decision -eq 'Ready') {
                Write-Diagnostic 'ACCOUNT_RESTORED_VERIFIED' @{accountId=$key;username=$a.username;pid=$sample.processId;startTicks=$sample.startTicks;note='Exact account + new generation + connected socket + responsive window + server acceptance + stable confirmation. Not an endurance guarantee.'}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                $script:recoveryPending.Remove($key);continue
            }
            if ($decision -eq 'LaunchMissing') {
                if (-not (Test-ArkuzoRecoveryBudget $launchAttempts $utc ([int]$restorePolicy.retry_base_sec) ([int]$restorePolicy.retry_max_per_hour))) {
                    Warn-Throttled 'restore-budget' 'Missing-account launch budget/backoff active. Other clients remain protected; automatic retry will resume.';continue
                }
                if ($null -eq $systemMemory -or $systemMemory.commitPercent -ge $healthPolicy.pressure_percent) {
                    Warn-Throttled 'restore-pressure' 'New account launch delayed: OS commit headroom insufficient/unavailable.';continue
                }
                # Persist and audit before invoking Volt. Never burn a duplicate fast retry after a restart.
                $entry.retryCount=[int]$entry.retryCount+1
                $entry.nextRetryUtc=$utc.AddSeconds((Get-ArkuzoRetryDelay $entry.retryCount $restorePolicy)).ToString('o')
                $script:launchAttempts=@($launchAttempts)+@($utc)
                Save-ArkuzoRecoveryJournal
                Write-Diagnostic 'VOLT_MISSING_LAUNCH_REQUEST' @{accountId=$key;attempt=$entry.retryCount;nextRetryUtc=$entry.nextRetryUtc}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                $result=Invoke-ArkuzoVoltControl 'LaunchMissing' $key ([string]$a.trackerId)
                Write-Diagnostic 'VOLT_MISSING_LAUNCH_RESULT' @{accountId=$key;requestAccepted=($result.requestAccepted -is [bool] -and $result.requestAccepted);note='Request acceptance is not game readiness; continue outcome verification.'}
                if (-not $result.requestAccepted) { Warn-Throttled ('restore-'+$key) 'Volt missing-account request refused/unavailable. Backoff retained, no collateral closures.' }
                # Only one launch request per observation; refreshed snapshot next cycle.
                break
            }
            if ($decision -eq 'Blocked' -or ($utc-([datetime]$entry.createdUtc).ToUniversalTime()).TotalSeconds -ge 300) {
                Warn-Throttled ('restore-'+$key) ('Account '+$a.username+' not restored yet ('+$decision+'). Other accounts protected; retry is bounded and monitored.')
            }
        }
        Save-ArkuzoRecoveryJournal
    } catch { $script:recoveryJournalHealthy=$false;Warn-Throttled 'recovery-journal' 'Recovery outcome persistence/audit failed. Destructive recovery blocked.' }
}
function Update-ArkuzoLivePolicy {
    try {
        $raw=[IO.File]::ReadAllText($configFilePath)
        if ($raw -eq $script:lastConfigText) { return }
        $cfg=$raw|ConvertFrom-Json
        if ($null -eq $cfg.health) { throw 'Missing health policy' }
        $newHealth=Get-ArkuzoHealthPolicy $cfg.health
        $newRestore=Get-ArkuzoRestorePolicy $cfg.recovery
        if ($null -ne $cfg.config_lock -and [bool]$cfg.config_lock) {
            $newHealth.pressure_percent = [math]::Max($newHealth.pressure_percent, 88)
            $newHealth.pressure_min_private_mb = [math]::Max($newHealth.pressure_min_private_mb, 4000)
            $newHealth.startup_error_timeout_sec = [math]::Min($newHealth.startup_error_timeout_sec, 5)
            $newHealth.disconnect_timeout_sec = [math]::Min($newHealth.disconnect_timeout_sec, 5)
            $newHealth.cooldown_sec = [math]::Min($newHealth.cooldown_sec, 90)
            $newHealth.max_recycles_per_hour = [math]::Max($newHealth.max_recycles_per_hour, 20)
        }
        $script:healthPolicy=$newHealth;$script:restorePolicy=$newRestore;$script:lastConfigText=$raw
        Write-Diagnostic 'CONFIG_RELOADED' @{health=$newHealth;recovery=$newRestore;note='Validated health/recovery hot reload; resource settings apply on next ordinary start.'}
    } catch { Warn-Throttled 'config-reload' 'Invalid/unavailable config ignored; last validated health and recovery policy retained.' }
}
function Write-ArkuzoRuntimeStatus {
    if ($MonitorOnly -or -not $ownsControllerMutex) { return }
    try {
        $accounts=@($voltControlStatus.accounts|ForEach-Object{@{accountId=$_.accountId;username=$_.username;processId=$_.processId;uiStatus=$_.uiStatus;controlReady=$_.controlReady;cookieStatus=$_.cookieStatus;suspensionSafe=$_.suspensionSafe}})
        $expected=@($voltControlStatus.accounts|Where-Object{$_.autoRelaunch -and $_.cookieAlive -and $_.cookieStatus -ceq 'alive' -and [long]$_.lastLaunchAtMs -gt 0 -and $restorePolicy.excluded_account_ids -notcontains $_.accountId -and ($null -eq $script:suspendedAccounts -or -not $script:suspendedAccounts.ContainsKey([string]$_.accountId))})
        $missing=@($expected|Where-Object{-not $_.processId})
        $controlFresh=$voltControlStatus.available -and $null -ne $voltControlCheckedUtc -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -ge 0 -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -le 25
        Save-ArkuzoAtomicJson (Join-Path $DataDirectory 'runtime-status.json') @{
            version='1.0.1';pid=$PID;startTicks=$script:controllerStartTicks;updatedUtc=[datetime]::UtcNow.ToString('o');monitorOnly=$false;controller=$true
            clients=@($tracked.Values|ForEach-Object{$_.LastSnapshot}|Where-Object{$null -ne $_});accounts=$accounts;expectedAccounts=$expected.Count;missingAccounts=$missing.Count
            pending=@($recoveryPending.Values);pendingRecoveries=$recoveryPending.Count;suspendedAccounts=@($script:suspendedAccounts.Values);suspendedAccountCount=$script:suspendedAccounts.Count;missingRecoveryBlocked=(-not $controlFresh -or $missing.Count -gt 0 -or $recoveryPending.Count -gt 0)
            voltControlAvailable=[bool]$voltControlStatus.available;recoveryJournalHealthy=[bool]$recoveryJournalHealthy;systemMemory=$systemMemory;health=$healthPolicy;recovery=$restorePolicy;logFailed=$logFailed
        }
    } catch { Warn-Throttled 'runtime-heartbeat' 'Runtime heartbeat could not be persisted. Watchdog must report degraded status.' }
}
function Get-ArkuzoOutcomeDecision($Entry, $Account, [datetime]$NowUtc, $Policy) {
    if ($null -eq $Account -or -not $Account.available -or -not $Account.controlReady -or
        -not $Account.autoRelaunch -or -not $Account.cookieAlive -or $Account.accountId -ne $Entry.accountId) {
        $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
        return 'Blocked'
    }
    $now = $NowUtc.ToUniversalTime()
    if ($Account.processId) {
        if ([int]$Account.processId -eq [int]$Entry.oldPid -and [long]$Account.startTicks -eq [long]$Entry.oldStartTicks) {
            $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
            return 'Blocked'
        }
        # Only a fresh, successfully collected client sample is readiness evidence.
        $observed=[datetime]::MinValue
        if (-not $Account.sampleUtc -or -not [datetime]::TryParse([string]$Account.sampleUtc,[ref]$observed)) {
            $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
            return 'Observing'
        }
        $observed=$observed.ToUniversalTime()
        $age=($now-$observed).TotalSeconds
        if ($age -lt 0 -or $age -gt 10) {
            $Entry.readySinceUtc=$null; $Entry.lastObservedUtc=$null
            return 'Observing'
        }
        $healthy = $Account.uiStatus -eq 'Connected' -and $Account.windowPresent -and $Account.responding -and
            -not $Account.launchError -and -not $Account.isDisconnected -and $Account.gameReady -and $Account.startTicks -gt 0
        $same = ([int]$Entry.replacementPid -eq [int]$Account.processId -and [long]$Entry.replacementStartTicks -eq [long]$Account.startTicks)
        $continuous = $false
        if ($Entry.lastObservedUtc) {
            $gap = ($observed - ([datetime]$Entry.lastObservedUtc).ToUniversalTime()).TotalSeconds
            if ($healthy -and $same -and $Entry.readySinceUtc -and $gap -eq 0) { return 'Observing' } # Never extend from replay.
            $continuous = $gap -gt 0 -and $gap -le 15
        }
        if (-not $healthy -or -not $same -or -not $continuous) { $Entry.readySinceUtc = $null }
        $Entry.replacementPid = [int]$Account.processId; $Entry.replacementStartTicks = [long]$Account.startTicks
        $Entry.lastObservedUtc = $observed.ToString('o')
        if ($healthy) {
            if (-not $Entry.readySinceUtc) { $Entry.readySinceUtc = $observed.ToString('o') }
            if (($observed - ([datetime]$Entry.readySinceUtc).ToUniversalTime()).TotalSeconds -ge [double]$Policy.ready_stable_sec) { return 'Ready' }
        }
        return 'Observing'
    }
    $Entry.readySinceUtc = $null; $Entry.lastObservedUtc = $now.ToString('o')
    if ($Account.uiStatus -ne 'Idle') { return 'Wait' } # Volt still connecting/counting down: never duplicate.
    if ($Entry.nextRetryUtc -and $now -lt ([datetime]$Entry.nextRetryUtc).ToUniversalTime()) { return 'Wait' }
    $since = if ($Entry.closedUtc) { ([datetime]$Entry.closedUtc).ToUniversalTime() } else { ([datetime]$Entry.createdUtc).ToUniversalTime() }
    if (($now - $since).TotalSeconds -lt [double]$Policy.restore_wait_sec) { return 'Wait' }
    return 'LaunchMissing'
}
function Test-ArkuzoRecoveryHandoff([string]$AccountId) {
    # No collateral closures while an account is missing. A confirmed unhealthy
    # replacement of that same account can retry through the persisted backoff.
    $utc=[datetime]::UtcNow
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe -or $null -eq $voltControlCheckedUtc -or ($utc-$voltControlCheckedUtc).TotalSeconds -lt 0 -or ($utc-$voltControlCheckedUtc).TotalSeconds -gt 25) { return $false }
    foreach($key in @($script:suspendedAccounts.Keys)) {
        $rows=@($voltControlStatus.accounts | Where-Object { $_.accountId -ceq $key })
        if ($rows.Count -ne 1) { return $false }
        $a=$rows[0]
        if ($a.cookieStatus -cne 'dead' -or $a.suspensionSafe -isnot [bool] -or -not $a.suspensionSafe -or $a.uiStatus -cne 'Idle' -or $a.processId) { return $false }
    }
    if ($null -eq $script:recoveryPending) { return $false }
    if ($script:recoveryPending.Count -eq 0) { return $true }
    if (-not $AccountId -or $script:recoveryPending.Count -ne 1 -or -not $script:recoveryPending.ContainsKey($AccountId)) { return $false }
    $entry = $script:recoveryPending[$AccountId]
    if ($entry.nextRetryUtc -and [datetime]::UtcNow -lt ([datetime]$entry.nextRetryUtc).ToUniversalTime()) { return $false }
    return $true
}
function Invoke-ClientRecovery([int]$ClientId, $State) {
    if ($MonitorOnly -or -not $healthPolicy.enabled -or -not $ownsControllerMutex -or $State.RecoveryRequested -or -not $State.HealthDecision.Recycle) { return }
    if (-not $restorePolicy.enabled) { Warn-Throttled 'restore-disabled' 'Account outcome recovery disabled; destructive recovery blocked.'; return }
    if (-not $recoveryJournalHealthy) { Warn-Throttled 'recovery-journal' 'Recovery blocked: invalid recovery journal. Clients left untouched.'; return }
    # Re-read capability immediately before acting, not merely at startup.
    Update-VoltRecoveryCapability
    if (-not $voltStatus.safeToRecycle -or -not (Test-ArkuzoVoltOwnership $State.ParentId $voltParents[$State.ParentId] $State.StartTicks $voltPath)) { return }
    $utc = [DateTime]::UtcNow
    $boundAccount = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
    if ($null -eq $boundAccount -or $voltControlStatus.managerId -ne $State.ParentId -or $voltControlStatus.managerStartTicks -ne $voltParents[$State.ParentId].StartTicks) { return }
    if (-not (Test-ArkuzoRecoveryHandoff ([string]$boundAccount.accountId))) { Warn-Throttled 'recovery-handoff' 'Waiting for exact account restoration/backoff. Other accounts left untouched.'; return }
    $effectiveCooldown = if ($State.HealthDecision.Reason -eq 'VOLT_STARTUP_ERROR') { [math]::Min(5, $healthPolicy.cooldown_sec) } else { $healthPolicy.cooldown_sec }
    if (-not (Test-ArkuzoRecoveryBudget $recoveryAttempts $utc $effectiveCooldown $healthPolicy.max_recycles_per_hour)) {
        Warn-Throttled 'recovery-budget' 'Recovery cooldown/hourly budget reached. No restart storm.'; return
    }
    $watcher = $State.Watcher
    if (-not (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) { Reset-ArkuzoHealthSample $State; return }
    # An unmapped target is not a termination attempt. Do not charge its budget.
    if (-not (Test-ArkuzoTargetRecovery $watcher $ClientId $State.StartTicks)) { return }
    $handoffKey = [string]$boundAccount.accountId
    $reserved = $false; $previousPending = $null
    try {
        # Persist before closing: restarting ArkuzoSaver cannot reset the budget.
        $script:recoveryAttempts = @($recoveryAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 }) + @($utc)
        $entry = New-ArkuzoPendingEntry $handoffKey $State.TrackerId $ClientId $State.StartTicks
        if ($recoveryPending.ContainsKey($handoffKey)) {
            $previousPending = $recoveryPending[$handoffKey].Clone()
            $entry.retryCount = [int]$previousPending.retryCount + 1
        }
        $entry.nextRetryUtc = $utc.AddSeconds((Get-ArkuzoRetryDelay ([math]::Max(1,[int]$entry.retryCount)) $restorePolicy)).ToString('o')
        $script:recoveryPending[$handoffKey] = $entry
        $reserved = $true
        Save-ArkuzoRecoveryJournal
        Write-Diagnostic 'RECOVERY_REQUESTED' @{ accountId = $handoffKey; pid = $ClientId; startTicks = $State.StartTicks; reason = $State.HealthDecision.Reason; lastSample = $State.LastSnapshot; systemMemory = $systemMemory; relaunchOwner = 'Volt account manager' }
        if ($logFailed) { throw 'Recovery requires functioning audit logging' }
        if (-not (Test-ArkuzoTargetRecovery $watcher $ClientId $State.StartTicks)) { return }
        # The triggering condition may have cleared while probing/persisting/logging.
        $reason = $State.HealthDecision.Reason
        try { $freshSample = Get-ArkuzoRecoveryHealthSample $watcher $reason $State }
        catch { Reset-ArkuzoHealthSample $State; throw }
        $State.HealthDecision = Get-ArkuzoHealthDecision $State $freshSample $healthPolicy $clock.Elapsed.TotalSeconds
        if (-not $State.HealthDecision.Recycle -or $State.HealthDecision.Reason -ne $reason) { return }
        if (-not (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) { Reset-ArkuzoHealthSample $State; return }
        # Check the retained exact owner after IO, immediately before termination.
        # This narrows the race; it cannot make two processes' lifetimes atomic.
        if (-not (Test-ArkuzoLiveVoltParent $voltParents[$State.ParentId])) { return }
        $rebound = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
        if ($null -eq $rebound -or $rebound.accountId -ne $handoffKey) { return }
        $State.RecoveryRequested = $true
        $State.RecoveryStatus = 'Pending'
        # Retained handle prevents accidentally killing a reused PID.
        $watcher.Kill()
        if (-not $watcher.WaitForExit(2000)) { throw 'Client termination not confirmed' }
        $State.RecoveryStatus = 'ExitVerified'
        $entry.closedUtc = [datetime]::UtcNow.ToString('o')
        Save-ArkuzoRecoveryJournal
        Write-Diagnostic 'CLIENT_CLOSED_FOR_RECOVERY' @{ accountId = $handoffKey; pid = $ClientId; startTicks = $State.StartTicks; reason = $State.HealthDecision.Reason; note = 'Exit verified. Volt relaunch/game readiness is a separate observation, not guaranteed.' }
    } catch {
        $failure = $_.Exception.Message
        if ($State.RecoveryStatus -eq 'Pending') {
            $State.RecoveryStatus = 'Unknown' # Keep the latch unless exit or the original live identity is proven.
            $exited = $null
            try { $watcher.Refresh(); $exited = $watcher.HasExited } catch { }
            if ($exited -is [bool] -and $exited) {
                $State.RecoveryStatus = 'ExitVerified'
                Write-Diagnostic 'CLIENT_CLOSED_FOR_RECOVERY' @{ pid = $ClientId; startTicks = $State.StartTicks; reason = $State.HealthDecision.Reason; note = 'Exit verified after termination error. Volt relaunch/game readiness remains a separate observation.' }
            } elseif (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks) {
                $State.RecoveryStatus = 'Failed'
                $State.RecoveryRequested = $false # Retry still consumes the persistent cooldown/hourly budget.
            }
        }
        Warn-Throttled 'recovery-failed' "Recovery failed for PID ${ClientId}: $failure"
    } finally {
        if ($reserved -and -not $State.RecoveryRequested -and (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) {
            $State.LastRecoveryRefusalUtc = [datetime]::UtcNow
            $script:recoveryAttempts = @($script:recoveryAttempts | Where-Object { $_ -ne $utc })
            if ($null -ne $previousPending) { $script:recoveryPending[$handoffKey] = $previousPending }
            else { $script:recoveryPending.Remove($handoffKey) }
            try { Save-ArkuzoRecoveryJournal } catch { $script:recoveryJournalHealthy = $false }
        }
    }
}
function Reset-ArkuzoHealthSample($State) {
    if ($null -eq $State) { return }
    # Latch the observation break now: a successful sample may overwrite the
    # cleared snapshot before outcomes run. Only reset this tracked generation.
    if ($null -ne $script:recoveryPending -and $null -ne $script:tracked) {
        foreach ($pending in $script:recoveryPending.Values) {
            $replacementId = [int]$pending.replacementPid
            if ($replacementId -gt 0 -and $script:tracked.ContainsKey($replacementId) -and
                [object]::ReferenceEquals($script:tracked[$replacementId], $State) -and
                [long]$pending.replacementStartTicks -eq [long]$State.StartTicks) {
                $pending.readySinceUtc = $null
                $pending.lastObservedUtc = $null
            }
        }
    }
    $State.HealthDecision = $null
    $State.LastSnapshot = $null
    $State.HealthSnapshotUtc = $null
    $State.HangSince = -1.0
    $State.StartupErrorSince = -1.0
    $State.DisconnectSince = -1.0
    $State.DisconnectReason = $null
    $State.isDisconnected = $false
    $State.LastHealthSampleTime = $null
    $State.PrivateLimitSince = -1.0
}
function Get-ArkuzoHealthDecision($State, $Sample, $Policy, [double]$Now) {
    $reason = ''; $status = ''
    # Normal polling is sub-second. A >5s gap (or clock rollback) breaks
    # continuous observation, even when both endpoint samples succeeded.
    if ($null -eq $State.LastHealthSampleTime -or $Now -lt [double]$State.LastHealthSampleTime -or
        ($Now - [double]$State.LastHealthSampleTime) -gt 5) {
        $State.HangSince = -1.0
        $State.StartupErrorSince = -1.0
        $State.DisconnectSince = -1.0
        $State.PrivateLimitSince = -1.0
    }
    $State.LastHealthSampleTime = $Now
    if ($null -eq $State.HangSince) { $State.HangSince = -1.0 }
    if ($null -eq $State.StartupErrorSince) { $State.StartupErrorSince = -1.0 }
    if ($null -eq $State.DisconnectSince) { $State.DisconnectSince = -1.0 }
    if ($null -eq $State.PrivateLimitSince) { $State.PrivateLimitSince = -1.0 }
    if ([double]$Sample.privateMB -lt [double]$Policy.private_limit_mb) { $State.PrivateLimitSince = -1.0 }
    # Current critical OS pressure cannot wait through a startup grace.
    if ([double]$Sample.systemCommitPercent -ge 90 -and [double]$Sample.privateMB -ge [double]$Policy.pressure_min_private_mb) {
        return [pscustomobject]@{ Reason = 'SYSTEM_COMMIT_PRESSURE'; Recycle = [bool]$Sample.eligible; Status = 'CRITICAL COMMIT' }
    }
    # A responsive modal startup error is not a connected game. After a short
    # confirmation grace it is handed back to the verified Volt relaunch owner.
    if ($Sample.launchError) {
        $State.HangSince = -1.0
        $State.DisconnectSince = -1.0
        if ([double]$State.StartupErrorSince -lt 0) { $State.StartupErrorSince = $Now }
        $timeout = if ($null -ne $Policy.startup_error_timeout_sec) { [double]$Policy.startup_error_timeout_sec } else { 40.0 }
        $retry = [bool]$Sample.eligible -and [double]$State.StartupErrorSince -ge 0 -and ($Now - [double]$State.StartupErrorSince) -ge $timeout
        return [pscustomobject]@{ Reason = 'VOLT_STARTUP_ERROR'; Recycle = $retry; Status = 'VOLT STARTUP ERROR' }
    }
    $State.StartupErrorSince = -1.0
    # In-game disconnect or kick detected from client log.
    if ($Sample.isDisconnected) {
        $State.HangSince = -1.0
        if ([double]$State.DisconnectSince -lt 0) { $State.DisconnectSince = $Now }
        $timeout = if ($null -ne $Policy.disconnect_timeout_sec) { [double]$Policy.disconnect_timeout_sec } else { 5.0 }
        $retry = [bool]$Sample.eligible -and [double]$State.DisconnectSince -ge 0 -and ($Now - [double]$State.DisconnectSince) -ge $timeout
        return [pscustomobject]@{ Reason = 'IN_GAME_DISCONNECT'; Recycle = $retry; Status = 'DISCONNECTED' }
    }
    $State.DisconnectSince = -1.0
    if ([double]$Sample.ageSec -lt [double]$Policy.warmup_sec) {
        $State.HangSince = -1.0
        return [pscustomobject]@{ Reason = ''; Recycle = $false; Status = '' }
    }
    # Track responsiveness independently of the higher-priority memory branches.
    if ($Sample.windowPresent -and -not $Sample.responding) {
        if ([double]$State.HangSince -lt 0) { $State.HangSince = $Now }
    } else { $State.HangSince = -1.0 }
    if ([double]$Sample.privateMB -ge [double]$Policy.private_limit_mb) {
        $status = 'MEMORY GRACE'
        if ([double]$State.PrivateLimitSince -lt 0) { $State.PrivateLimitSince = $Now }
        $sustain = if ($null -ne $Policy.private_limit_sustain_sec) { [double]$Policy.private_limit_sustain_sec } else { 60.0 }
        if (($Now - [double]$State.PrivateLimitSince) -ge $sustain) { $reason = 'PRIVATE_COMMIT_LIMIT'; $status = 'LEAK GUARD' }
        if ([double]$Sample.systemCommitPercent -ge [double]$Policy.pressure_percent) { $reason = 'SYSTEM_COMMIT_PRESSURE'; $status = 'COMMIT PRESSURE' }
    } elseif ([double]$Sample.systemCommitPercent -ge [double]$Policy.pressure_percent -and
              [double]$Sample.privateMB -ge [double]$Policy.pressure_min_private_mb) {
        $reason = 'SYSTEM_COMMIT_PRESSURE'; $status = 'COMMIT PRESSURE'
    } elseif ($Sample.windowPresent -and -not $Sample.responding) {
        $status = 'HANG GRACE'
        if (($Now - [double]$State.HangSince) -ge [double]$Policy.hang_timeout_sec) {
            $reason = 'SUSTAINED_HANG'; $status = 'STUCK CLIENT'
        }
    } else { $State.HangSince = -1.0 }
    return [pscustomobject]@{ Reason = $reason; Recycle = ([bool]$Sample.eligible -and $reason -ne ''); Status = $status }
}

# === END Arkuzo-Health.ps1 ===
$configFilePath = Join-Path $DataDirectory 'config.json'
$loadedConfig = Load-ArkuzoConfigFile -Path $configFilePath
if ($null -eq $loadedConfig) {
    if (Test-Path -LiteralPath $configFilePath) { throw "Existing config.json is invalid. Fix it or restore your backup; it will not be overwritten." }
    $loadedConfig = Select-ArkuzoPresetInteractive -Path $configFilePath
}

if ($null -ne $loadedConfig -and $null -ne $loadedConfig.settings) {
    $cfg = $loadedConfig.settings
    if (-not $PSBoundParameters.ContainsKey('Mode') -and $loadedConfig.selected_preset) {
        $Mode = $loadedConfig.selected_preset
    }
    if (-not $PSBoundParameters.ContainsKey('MaxRamMB') -and $cfg.target_ram_mb) {
        $MaxRamMB = [int]$cfg.target_ram_mb
    }
    if (-not $PSBoundParameters.ContainsKey('TrimEverySec') -and $cfg.trim_every_sec) {
        $TrimEverySec = [int]$cfg.trim_every_sec
    }
    if (-not $PSBoundParameters.ContainsKey('Priority') -and $cfg.priority) {
        $Priority = [string]$cfg.priority
    }
    if (-not $PSBoundParameters.ContainsKey('CoresPerInstance') -and $cfg.cores_per_instance) {
        $CoresPerInstance = [int]$cfg.cores_per_instance
    }
    if (-not $PSBoundParameters.ContainsKey('PollMs') -and $cfg.poll_ms) {
        $PollMs = [int]$cfg.poll_ms
    }
    if (-not $PSBoundParameters.ContainsKey('EnableTrimming') -and $null -ne $cfg.trim_enabled) {
        $EnableTrimming = [bool]$cfg.trim_enabled
    }
    if (-not $PSBoundParameters.ContainsKey('HardLimit') -and -not $PSBoundParameters.ContainsKey('SoftLimit') -and $null -ne $cfg.hard_limit) {
        $HardLimit = [bool]$cfg.hard_limit
        $SoftLimit = -not $HardLimit
    }
    if (-not $PSBoundParameters.ContainsKey('Minimize') -and $null -ne $cfg.minimize_on_launch) {
        $Minimize = [bool]$cfg.minimize_on_launch
    }
    if (-not $PSBoundParameters.ContainsKey('ApplyGraphicsFlags') -and $null -ne $cfg.apply_graphics_flags) {
        $ApplyGraphicsFlags = [bool]$cfg.apply_graphics_flags
    }
}

$healthPolicy = Get-ArkuzoHealthPolicy $loadedConfig.health
$restorePolicy = Get-ArkuzoRestorePolicy $loadedConfig.recovery
$isConfigLocked = ($null -ne $loadedConfig.config_lock -and [bool]$loadedConfig.config_lock)
if ($isConfigLocked) {
    $ApplyGraphicsFlags = $true
    if ($null -ne $healthPolicy) {
        $healthPolicy.pressure_percent = [math]::Max($healthPolicy.pressure_percent, 88)
        $healthPolicy.pressure_min_private_mb = [math]::Max($healthPolicy.pressure_min_private_mb, 4000)
        $healthPolicy.startup_error_timeout_sec = [math]::Min($healthPolicy.startup_error_timeout_sec, 5)
        $healthPolicy.disconnect_timeout_sec = [math]::Min($healthPolicy.disconnect_timeout_sec, 5)
        $healthPolicy.cooldown_sec = [math]::Min($healthPolicy.cooldown_sec, 90)
        $healthPolicy.max_recycles_per_hour = [math]::Max($healthPolicy.max_recycles_per_hour, 20)
    }
}
$lastConfigText = [IO.File]::ReadAllText($configFilePath)
if ($HardLimit) { $SoftLimit = $false }
if ($HardLimit -and $PSBoundParameters.ContainsKey('SoftLimit') -and $PSBoundParameters['SoftLimit']) {
    throw 'Use either -HardLimit or -SoftLimit, not both.'
}

# 2. Preset rules when Mode is explicitly specified on CLI without granular flags
if ($PSBoundParameters.ContainsKey('Mode')) {
    $cleanMode = $Mode.ToLowerInvariant()
    if ($cleanMode -eq 'aggressive') { $cleanMode = 'agressive' }
    if ($cleanMode -eq 'normal' -or $cleanMode -eq 'balanced') {
        if (-not $PSBoundParameters.ContainsKey('MaxRamMB')) { $MaxRamMB = 850 }
        if (-not $PSBoundParameters.ContainsKey('TrimEverySec')) { $TrimEverySec = 120 }
        if (-not $PSBoundParameters.ContainsKey('CoresPerInstance')) { $CoresPerInstance = 4 }
        if (-not $PSBoundParameters.ContainsKey('Priority')) { $Priority = 'BelowNormal' }
        if (-not $PSBoundParameters.ContainsKey('SoftLimit') -and -not $HardLimit) { $SoftLimit = $true }
    }
    if ($cleanMode -eq 'agressive') {
        if (-not $PSBoundParameters.ContainsKey('MaxRamMB')) { $MaxRamMB = 600 }
        if (-not $PSBoundParameters.ContainsKey('TrimEverySec')) { $TrimEverySec = 60 }
        if (-not $PSBoundParameters.ContainsKey('CoresPerInstance')) { $CoresPerInstance = 2 }
        if (-not $PSBoundParameters.ContainsKey('Priority')) { $Priority = 'BelowNormal' }
        if (-not $PSBoundParameters.ContainsKey('SoftLimit') -and -not $HardLimit) { $SoftLimit = $true }
    }
    if ($cleanMode -eq 'extreme') {
        if (-not $PSBoundParameters.ContainsKey('MaxRamMB')) { $MaxRamMB = 450 }
        if (-not $PSBoundParameters.ContainsKey('TrimEverySec')) { $TrimEverySec = 30 }
        if (-not $PSBoundParameters.ContainsKey('CoresPerInstance')) { $CoresPerInstance = 1 }
        if (-not $PSBoundParameters.ContainsKey('Priority')) { $Priority = 'BelowNormal' }
        if (-not $PSBoundParameters.ContainsKey('PollMs')) { $PollMs = 250 }
        if (-not $PSBoundParameters.ContainsKey('SoftLimit') -and -not $HardLimit) { $SoftLimit = $true }
    }
}

if (-not ('Arkuzo.MemorySaverNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Arkuzo {
 public static class MemorySaverNativeV1 {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool SetProcessWorkingSetSizeEx(IntPtr h, UIntPtr min, UIntPtr max, uint flags);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool GetProcessWorkingSetSizeEx(IntPtr h, out UIntPtr min, out UIntPtr max, out uint flags);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool SetProcessInformation(IntPtr h, int cls, ref uint value, uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool GetProcessInformation(IntPtr h, int cls, out uint value, uint size);
  [DllImport("psapi.dll", SetLastError=true)]
  static extern bool EmptyWorkingSet(IntPtr h);
  [DllImport("user32.dll")]
  public static extern bool ShowWindowAsync(IntPtr h, int command);
  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr h);
  static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
  public static ulong[] ReadLimits(IntPtr h) {
   UIntPtr min, max; uint flags;
   Check(GetProcessWorkingSetSizeEx(h, out min, out max, out flags));
   return new ulong[] { min.ToUInt64(), max.ToUInt64(), flags };
  }
  public static void SetLimits(IntPtr h, ulong min, ulong max, uint flags) {
   Check(SetProcessWorkingSetSizeEx(h, new UIntPtr(min), new UIntPtr(max), flags));
  }
  public static uint ReadMemoryPriority(IntPtr h) {
   uint value; Check(GetProcessInformation(h, 0, out value, 4)); return value;
  }
  public static void SetMemoryPriority(IntPtr h, uint value) {
   Check(SetProcessInformation(h, 0, ref value, 4));
  }
  public static void Trim(IntPtr h) { Check(EmptyWorkingSet(h)); }
  public static IntPtr Affinity(long allowed, int slot, int count) {
   int[] bits = new int[64]; int n = 0; ulong available = unchecked((ulong)allowed);
   for (int b=0; b<64; b++) if ((available & (1UL << b)) != 0) bits[n++] = b;
   if (n == 0) throw new InvalidOperationException("Empty CPU affinity mask.");
   count = Math.Min(count, n); ulong mask = 0;
   for (int i=0; i<count; i++) mask |= 1UL << bits[(int)(((long)slot*count+i)%n)];
   return new IntPtr(unchecked((long)mask));
  }
 }
}
'@
}

# Only optional local graphics flags; merge rather than erase other settings.
if ($ApplyGraphicsFlags -and -not $MonitorOnly) {
    $searchRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Roblox/Versions'),
        'C:/ProgramData/roblox/roblox',
        (Join-Path $env:ProgramData 'roblox/roblox'),
        (Join-Path ${env:ProgramFiles(x86)} 'Roblox/Versions'),
        (Join-Path $env:ProgramFiles 'Roblox/Versions')
    )
    foreach ($proc in @(Get-Process -Name RobloxPlayerBeta -ErrorAction SilentlyContinue)) {
        try {
            if ($proc.Path) {
                $procDir = Split-Path -Parent $proc.Path
                if ($procDir -and -not ($searchRoots -contains $procDir)) { $searchRoots += $procDir }
            }
        } catch {}
    }
    $targetDirs = @()
    foreach ($root in $searchRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        if (Test-Path -LiteralPath (Join-Path $root 'RobloxPlayerBeta.exe')) {
            $targetDirs += $root
        } else {
            $sub = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'RobloxPlayerBeta.exe') } |
                ForEach-Object { $_.FullName })
            $targetDirs += $sub
        }
    }
    $targetDirs = @($targetDirs | Select-Object -Unique)
    if ($targetDirs.Count -gt 0) {
        foreach ($vDir in $targetDirs) {
            $settingsDir = Join-Path $vDir 'ClientSettings'
            $settingsFile = Join-Path $settingsDir 'ClientAppSettings.json'
            $settings = @{}
            if (Test-Path -LiteralPath $settingsFile) {
                try {
                    $parsed = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
                    if ($null -ne $parsed -and $parsed -is [pscustomobject]) {
                        foreach ($property in $parsed.PSObject.Properties) { $settings[$property.Name] = $property.Value }
                        Copy-Item -LiteralPath $settingsFile -Destination ($settingsFile + '.arkuzo-' + [guid]::NewGuid().ToString('N') + '.bak')
                    }
                } catch { throw 'ClientAppSettings.json must contain a JSON object. File left unchanged.' }
            }
            $settings['DFFlagTextureQualityOverrideEnabled'] = 'True'
            $settings['DFIntTextureQualityOverride'] = '0'
            $settings['FIntDebugForceMSAASamples'] = '1'
            New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
            $json = $settings | ConvertTo-Json -Depth 100
            [IO.File]::WriteAllText($settingsFile, $json, (New-Object Text.UTF8Encoding($false)))
        }
        Write-Host 'Low texture quality/MSAA settings merged. Restart Roblox to apply.'
    } else { Write-Warning 'Roblox installation not found; graphics settings skipped.' }
}

$tracked = @{}
$dashboardIssues = @{}
$trimCount = 0
$cpuThreads = [Math]::Max(1, [Environment]::ProcessorCount)
$warnings = @{}
$clock = [Diagnostics.Stopwatch]::StartNew()
$nextStatus = 0.0
$maxBytes = [uint64]$MaxRamMB * 1MB
# HARDWS_MIN_DISABLE (2), HARDWS_MAX_ENABLE (4) / DISABLE (8).
$limitFlags = [uint32]6
if ($SoftLimit) { $limitFlags = [uint32]10 }

$sessionStart = Get-Date
$sessionTag = $sessionStart.ToString('yyyyMMdd-HHmmss') + '-' + $PID
$logWriter = $null
$logPath = ''
$logPart = 0
$logFailed = $false
$nextLogSample = 0.0
$nextEventCheck = 0.0
$seenEventIds = @{}
$systemMemory = $null
$nextHealthSample = 0.0
$nextVoltCheck = 0.0
$voltStatus = [pscustomobject]@{ safeToRecycle = $false; reason = 'Not checked' }
$voltParents = @{}
$voltPath = Join-Path $env:LOCALAPPDATA 'Volt\tauri-app.exe'
$lastGlobalTrim = -1e6
$recoveryAttempts = @()
$recoveryStatePath = Join-Path $DataDirectory 'recovery-state.json'
$recoveryJournalHealthy = $false # Initialized only while owning the controller lock.
$recoveryPending = @{}; $suspendedAccounts = @{}; $launchAttempts = @()
$voltControlStatus = [pscustomobject]@{available=$false;accounts=@();relaunchDelayMs=0}
$voltControlCheckedUtc = [datetime]::MinValue
$nextOutcomeCheck = 0.0; $nextPolicyCheck = 0.0; $nextRuntimeHeartbeat = 0.0
$controllerStartTicks = ([Diagnostics.Process]::GetCurrentProcess()).StartTime.ToUniversalTime().Ticks
if (-not $StopFile -and -not $MonitorOnly) { $StopFile = Join-Path $DataDirectory 'controller.stop' }
$controllerMutex = $null
$ownsControllerMutex = $false

function Open-DiagnosticLog {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $script:logPath = Join-Path $LogDirectory ("Arkuzo-$sessionTag-part$($script:logPart).log")
    $script:logWriter = New-Object System.IO.StreamWriter($script:logPath, $false, (New-Object Text.UTF8Encoding($false)))
    $script:logWriter.AutoFlush = $true
}
function Write-Diagnostic([string]$Kind, $Data) {
    if ($script:logFailed) { return }
    try {
        if ($null -eq $script:logWriter) { Open-DiagnosticLog }
        if ($script:logWriter.BaseStream.Length -ge ([int64]$MaxLogMB * 1MB)) {
            $script:logWriter.Dispose(); $script:logWriter = $null
            $script:logPart++
            # Keep the current and four preceding parts for this session.
            if ($script:logPart -ge 5) {
                $expired = Join-Path $LogDirectory ("Arkuzo-$sessionTag-part$($script:logPart - 5).log")
                Remove-Item -LiteralPath $expired -Force -ErrorAction SilentlyContinue
            }
            Open-DiagnosticLog
        }
        $record = [ordered]@{ time = (Get-Date).ToString('o'); session = $sessionTag; event = $Kind; data = $Data }
        $script:logWriter.WriteLine(($record | ConvertTo-Json -Depth 12 -Compress))
    } catch {
        $script:logFailed = $true
        $script:dashboardIssues['log-write'] = @{ Message = "Logging failed: $($_.Exception.Message)"; Time = $clock.Elapsed.TotalSeconds }
        if ($null -ne $script:logWriter) { try { $script:logWriter.Dispose() } catch { }; $script:logWriter = $null }
    }
}
function Record-ClientExit([int]$ClientId, $State, [string]$Reason = 'No longer listed') {
    $exitCode = $null
    if ($null -ne $State.Watcher) {
        try { if ($State.Watcher.HasExited) { $exitCode = $State.Watcher.ExitCode } } catch { }
        finally { $State.Watcher.Dispose() }
    }
    Write-Diagnostic 'CLIENT_EXIT' @{
        pid = $ClientId; startTicks = $State.StartTicks; exitCode = $exitCode
        reason = $Reason; lastSample = $State.LastSnapshot; recoveryRequested = [bool]$State.RecoveryRequested
        note = 'An exit alone does not prove a crash; correlate with Windows events.'
    }
}
function Read-CrashEvents {
    try {
        $systemEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(2004); StartTime = (Get-Date).AddSeconds(-90) } -ErrorAction Stop)
        foreach ($event in $systemEvents) {
            $key = 'System-' + $event.RecordId
            if ($seenEventIds.ContainsKey($key)) { continue }
            $seenEventIds[$key] = $clock.Elapsed.TotalSeconds
            Write-Diagnostic 'SYSTEM_RESOURCE_EXHAUSTION' @{ id = 2004; created = $event.TimeCreated.ToString('o'); recordId = $event.RecordId; message = $event.Message }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { Warn-Throttled 'system-event-read' 'System memory event query unavailable.' }
    }
    try {
        # Overlap the window to catch delayed event delivery; deduplicate RecordId.
        $start = (Get-Date).AddSeconds(-90)
        if ($start -lt $sessionStart) { $start = $sessionStart }
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = @(1000,1001,1002); StartTime = $start } -ErrorAction Stop)
        foreach ($event in $events) {
            if ($seenEventIds.ContainsKey($event.RecordId)) { continue }
            $xml = $event.ToXml()
            if ($xml -notmatch '(?i)RobloxPlayerBeta|RobloxPlayer') { continue }
            $seenEventIds[$event.RecordId] = $clock.Elapsed.TotalSeconds
            Write-Diagnostic 'WINDOWS_APPLICATION_EVENT' @{
                id = $event.Id; recordId = $event.RecordId; provider = $event.ProviderName
                created = $event.TimeCreated.ToString('o'); message = $event.Message; xml = $xml
            }
        }
        foreach ($key in @($seenEventIds.Keys)) {
            if (($clock.Elapsed.TotalSeconds - $seenEventIds[$key]) -gt 180) { $seenEventIds.Remove($key) }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            Warn-Throttled 'event-read' "Windows event read failed: $($_.Exception.Message)"
        }
    }
}
Write-Diagnostic 'SESSION_START' @{
    version = '1.0.1'; health = $healthPolicy; recovery = $restorePolicy
    mode = $Mode; advisoryMB = $MaxRamMB; softLimit = [bool]$SoftLimit
    trimming = [bool]$EnableTrimming; trimSeconds = $TrimEverySec; priority = $Priority
    logicalCpuPerClient = $CoresPerInstance; monitorOnly = [bool]$MonitorOnly
    logicalCpuCount = $cpuThreads; powershell = $PSVersionTable.PSVersion.ToString()
    os = [Environment]::OSVersion.VersionString; sampleSeconds = $LogEverySec
}

function Warn-Throttled([string]$Key, [string]$Message) {
    if (-not $warnings.ContainsKey($Key) -or ($clock.Elapsed.TotalSeconds - $warnings[$Key]) -ge 30) {
        $dashboardIssues[$Key] = @{ Message = $Message; Time = $clock.Elapsed.TotalSeconds }
        $warnings[$Key] = $clock.Elapsed.TotalSeconds
        Write-Diagnostic 'WARNING' @{ key = $Key; message = $Message }
    }
}

function Restore-Client($Client, $State) {
    # Start time prevents restoring an unrelated process after PID reuse.
    if ($Client.StartTime.ToUniversalTime().Ticks -ne $State.StartTicks -or $MonitorOnly) { return }
    foreach ($operation in @('Priority','Affinity','Limits')) {
        try {
            switch ($operation) {
                'Priority' { $Client.PriorityClass = $State.Priority }
                'Affinity' { $Client.ProcessorAffinity = $State.Affinity }
                'Limits' {
                    if (-not $State.LimitsChanged) { continue }
                    # Explicitly clear introduced hard limits when originally absent.
                    $restoreFlags = [uint32]0
                    if (($State.Limits[2] -band 1) -ne 0) { $restoreFlags = $restoreFlags -bor 1 }
                    else { $restoreFlags = $restoreFlags -bor 2 }
                    if (($State.Limits[2] -band 4) -ne 0) { $restoreFlags = $restoreFlags -bor 4 }
                    else { $restoreFlags = $restoreFlags -bor 8 }
                    [Arkuzo.MemorySaverNativeV1]::SetLimits($Client.Handle, $State.Limits[0], $State.Limits[1], $restoreFlags)
                }
            }
            Write-Diagnostic 'SETTING_RESTORED' @{ pid = $Client.Id; setting = $operation }
        } catch {
            Write-Diagnostic 'RESTORE_ERROR' @{ pid = $Client.Id; setting = $operation; message = $_.Exception.Message }
            Write-Warning "PID $($Client.Id): could not restore $operation settings: $($_.Exception.Message)"
        }
    }
    if ($State.MinimizedByUs -and $Client.MainWindowHandle -ne [IntPtr]::Zero) {
        [Arkuzo.MemorySaverNativeV1]::ShowWindowAsync($Client.MainWindowHandle, 9) | Out-Null
    }
}

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
    $ratio = [Math]::Max(0, [Math]::Min(1, $Value / [Math]::Max(1, $Maximum)))
    $filled = [int][Math]::Floor($ratio * $Width)
    return '[' + ('#' * $filled) + ('.' * ($Width - $filled)) + ']'
}
function Get-ArkuzoSparkline($Values, [int]$Width = 18) {
    $glyphs = ' .:-=+*#%@'
    $points = @($Values | Select-Object -Last $Width)
    $output = ''
    foreach ($point in $points) {
        $index = [int][Math]::Floor([Math]::Max(0, [Math]::Min(100, [double]$point)) / 100 * ($glyphs.Length - 1))
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
    $stage = $stages[[Math]::Max(0, [Math]::Min(3, $Step))]
    $bar = Get-ArkuzoMeter ($Step + 1) 4 ([Math]::Max(1, [Math]::Min(22, $Width - 4)))
    $lines.Add((New-ArkuzoLine "  $bar" Green $Width))
    $lines.Add((New-ArkuzoLine "  [$($Step + 1)/4] $stage" White $Width))
    return @($lines | Select-Object -First $Height)
}
function Get-ArkuzoTrimCountdown([double]$AgeSec, [double]$WarmupSec, [double]$IntervalSec, [double]$NowSec, [double]$LastTrimSec, [bool]$Enabled, [bool]$ReadOnly) {
    if (-not $Enabled -or $ReadOnly) { return 'OFF' }
    $warmupLeft = [Math]::Ceiling([Math]::Max(0, $WarmupSec - [Math]::Max(0, $AgeSec)))
    if ($warmupLeft -gt 0) { return "WARMUP ${warmupLeft}s" }
    return ([Math]::Ceiling([Math]::Max(0, $IntervalSec - ($NowSec - $LastTrimSec)))).ToString() + 's'
}
function Get-ArkuzoSuspendedAccountDisplay {
    $fresh=$voltControlStatus.available -is [bool] -and $voltControlStatus.available -and $null -ne $voltControlCheckedUtc -and
        ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -ge 0 -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -le 25
    $display=@{}
    if ($fresh) {
        foreach ($a in @($voltControlStatus.accounts)) {
            if ($a.cookieStatus -ceq 'dead') { $display[[string]$a.accountId]=@{accountId=$a.accountId;username=$a.username;processId=$a.processId;unverified=$false} }
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
    $usable = [Math]::Max(0, $Height - 1) # The last row is always the exit hint.
    $wide = $Width -ge 64 -and $Height -ge 20
    if ($wide) {
        foreach ($text in (Get-ArkuzoLogoLines)) { $lines.Add((New-ArkuzoLine $text Cyan $Width)) }
        $lines.Add((New-ArkuzoLine '  ARKUZO // MEMORY SAVER' White $Width))
    } else {
        $lines.Add((New-ArkuzoLine '  /\  ARKUZO  // MEMORY SAVER' Cyan $Width))
    }
    $mode = ([string]$Model.Mode).ToUpperInvariant()
    if ($Model.MonitorOnly) { $mode = 'MONITOR ONLY' }
    $cap = 'HARD WS CAP'; if ($Model.SoftLimit) { $cap = 'ADVISORY' }
    $trim = 'OFF'; if ($Model.TrimEnabled -and -not $Model.MonitorOnly) { $trim = "TRIM $($Model.TrimSeconds)s" }
    $lockBadge = if ($Model.ConfigLocked) { '  [CONFIG LOCKED]' } else { '' }
    $lines.Add((New-ArkuzoLine "  $mode  |  $($Model.TargetMB) MB $cap  |  $trim$lockBadge" White $Width))
    if ($Height -ge 12) {
        $lines.Add((New-ArkuzoLine ('  ' + ('-' * [Math]::Max(0, [Math]::Min($Width - 4, 70)))) DarkCyan $Width))
        $lines.Add((New-ArkuzoLine "  [SYSTEM]  $($Model.Managed)/$($Model.Detected) clients   $($Model.Uptime.ToString('hh\:mm\:ss')) uptime   $($Model.Trims) trims" Cyan $Width))
        $guard = ''; if ($Model.HealthPolicy -and $Model.HealthPolicy.enabled) { $guard = "  |  GUARD $($Model.HealthPolicy.private_limit_mb) MB" }
        $lines.Add((New-ArkuzoLine "  [POLICY]  $($Model.Priority) priority   $($Model.CoresPerInstance) cores / client$guard" DarkGray $Width))
    }
    if ($Height -ge 18) {
        $cpuColor = [ConsoleColor]::Green
        if ($Model.Cpu -ge 50) { $cpuColor = [ConsoleColor]::Yellow }
        if ($Model.Cpu -ge 85) { $cpuColor = [ConsoleColor]::Red }
        $lines.Add((New-ArkuzoLine ('  CPU  {0}  {1,5:N1}%' -f (Get-ArkuzoMeter $Model.Cpu 100 18), $Model.Cpu) $cpuColor $Width))
        $lines.Add((New-ArkuzoLine ('  RAM  {0}  {1,5:N0} MB resident' -f (Get-ArkuzoMeter $Model.ResidentMB ([Math]::Max(1, $Model.Detected) * $Model.TargetMB) 18), $Model.ResidentMB) Cyan $Width))
        if ($Model.SystemMemory) {
            $commitColor = [ConsoleColor]::DarkGray; if ($Model.SystemMemory.commitPercent -ge 85) { $commitColor = [ConsoleColor]::Red }
            $memText = '  MEM  {0:N0} MB private  |  OS COMMIT {1:N1}% ({2:N0}/{3:N0} MB)' -f $Model.PrivateMB, $Model.SystemMemory.commitPercent, $Model.SystemMemory.commitUsedMB, $Model.SystemMemory.commitLimitMB
            $lines.Add((New-ArkuzoLine $memText $commitColor $Width))
        } else {
            $lines.Add((New-ArkuzoLine ('  MEM  {0:N0} MB private     CPU TRACE [{1}]' -f $Model.PrivateMB, (Get-ArkuzoSparkline $Model.History 16)) DarkGray $Width))
        }
    }
    $paused=@($Model.SuspendedAccounts | Where-Object { $null -ne $_ })
    $pauseReserve=if ($paused.Count -gt 0) { [Math]::Min($paused.Count + 1,[Math]::Max(0,$usable - 2)) } else { 0 }
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
        $maxRows = [Math]::Max(0, $usable - $lines.Count - $reserved)
        $rows = @($Model.Rows | Sort-Object Slot, Id)
        if ($rows.Count -eq 0 -and $maxRows -gt 0) {
            $lines.Add((New-ArkuzoLine '  > Waiting for Roblox clients...' Yellow $Width))
        } elseif ($maxRows -gt 0) {
            $shown = [Math]::Min($rows.Count, $maxRows)
            if ($rows.Count -gt $maxRows) { $shown = [Math]::Max(0, $maxRows - 1) }
            for ($i = 0; $i -lt $shown; $i++) {
                $row = $rows[$i]
                $acc = if ($row.Account) { [string]$row.Account } else { "Acc #$($row.Slot + 1)" }
                if ($acc.Length -gt 15) { $acc = $acc.Substring(0, 12) + '...' }
                $text = if ($tableWide) {
                    '  #{0,-4} {1,-16} {2,-8} {3,5:N1}   {4,6:N0}   {5,7:N0}   {6,-11}  {7}' -f `
                        ($row.Slot + 1), $acc, $row.Id, $row.Cpu, $row.Ram, $row.Private, $row.NextTrim, $row.Status
                } else {
                    '  #{0,-4} {1,-14} {2,-8} {3,6:N0}   {4,-11}  {5}' -f `
                        ($row.Slot + 1), $acc, $row.Id, $row.Ram, $row.NextTrim, $row.Status
                }
                $color = [ConsoleColor]::Green
                if ($row.Ram -ge $Model.TargetMB) { $color = [ConsoleColor]::Yellow }
                if ($row.Status -in @('NOT RESPONDING','CHECK NOTICE','LEAK GUARD','COMMIT PRESSURE','STUCK CLIENT','VOLT STARTUP ERROR','DISCONNECTED')) { $color = [ConsoleColor]::Red }
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
        $room=[Math]::Max(0,$usable-$lines.Count)
        $shown=[Math]::Min($paused.Count,$room)
        if ($paused.Count -gt $room -and $room -gt 1) { $shown=$room-1 }
        for ($i=0;$i -lt $shown;$i++) {
            $a=$paused[$i]
            $label=if ($a.unverified) { 'COOKIE DEAD / LAST KNOWN UNVERIFIED' } else { 'COOKIE DEAD' }
            $nameWidth=[Math]::Max(1,$Width-16)
            $name=Fit-ArkuzoText ([string]$a.username) $nameWidth
            $lines.Add((New-ArkuzoLine ("  $name  $label") Red $Width))
        }
        if ($paused.Count -gt $shown -and $lines.Count -lt $usable) { $lines.Add((New-ArkuzoLine "  + $($paused.Count-$shown) paused accounts" Red $Width)) }
    }
    if ($lines.Count -lt $usable -and $Height -ge 12) {
        $alertList = if ($Model.Issues) { @($Model.Issues) } elseif ($Model.Notice) { @(@{ Message = $Model.Notice }) } else { @() }
        if ($alertList.Count -gt 0) {
            $maxAlerts = [Math]::Min(2, [Math]::Max(1, $usable - $lines.Count - 1))
            for ($aIdx = 0; $aIdx -lt [Math]::Min($alertList.Count, $maxAlerts); $aIdx++) {
                $msg = [string]$alertList[$aIdx].Message
                $alertColor = if ($msg -match '(?i)DISCONNECTED|ERROR|STARTUP|PRESSURE|FAIL|CRITICAL') { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow }
                $lines.Add((New-ArkuzoLine "  [!] $msg" $alertColor $Width))
            }
        } else {
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
} catch { if (-not $Headless) { throw "Live dashboard requires an interactive console. $($_.Exception.Message)" } }

# Short, bounded boot sequence; the live view stays motionless between samples.
function Show-ArkuzoBoot {
    for ($step = 0; $step -lt 4; $step++) {
        $width = [Math]::Max(1, [Console]::WindowWidth - 1)
        $height = [Math]::Max(1, [Console]::WindowHeight - 1)
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
    try {
        $width = [Math]::Max(1, [Console]::WindowWidth - 1)
        $height = [Math]::Max(1, [Console]::WindowHeight - 1)
        $issues = @($dashboardIssues.Values | Sort-Object Time -Descending)
        $notice = ''
        if ($issues.Count -gt 0) { $notice = [string]$issues[0].Message }
        $model = @{
            Mode = $Mode; TargetMB = $MaxRamMB; SoftLimit = [bool]$SoftLimit
            TrimEnabled = [bool]$EnableTrimming; TrimSeconds = $TrimEverySec
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
        if ([Console]::WindowWidth - 1 -eq $width -and [Console]::WindowHeight - 1 -eq $height) {
            throw "Could not draw Arkuzo dashboard: $($_.Exception.Message)"
        }
    }
}

try {
    if (-not $MonitorOnly) {
        $controllerMutex = New-Object Threading.Mutex($false, 'Local\ArkuzoSaver-ProcessController')
        try { $ownsControllerMutex = $controllerMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsControllerMutex = $true }
        if (-not $ownsControllerMutex) { throw 'Another ArkuzoSaver controller is already running.' }
        Initialize-ArkuzoRecoveryJournal
    }
    while ($true) {
        if ($RunForSec -gt 0 -and $clock.Elapsed.TotalSeconds -ge $RunForSec) { break }
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
        if ($clock.Elapsed.TotalSeconds -ge $nextPolicyCheck) {
            Update-ArkuzoLivePolicy
            $nextPolicyCheck = $clock.Elapsed.TotalSeconds + 10
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextHealthSample) {
            try { $systemMemory = Get-ArkuzoSystemMemory } catch { $systemMemory = $null; Warn-Throttled 'memory-query' 'OS commit telemetry unavailable.' }
            $nextHealthSample = $clock.Elapsed.TotalSeconds + 5
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextVoltCheck) {
            Update-VoltRecoveryCapability
            $nextVoltCheck = $clock.Elapsed.TotalSeconds + 15
        }
        $clients = @(Get-Process -Name RobloxPlayerBeta -ErrorAction SilentlyContinue)
        $liveIds = @($clients | ForEach-Object { $_.Id })
        foreach ($id in @($tracked.Keys)) {
            if ($liveIds -notcontains $id) { Record-ClientExit $id $tracked[$id]; $tracked.Remove($id); $warnings.Remove([string]$id); if ($script:accountNameCache.ContainsKey($id)) { $script:accountNameCache.Remove($id) } }
        }
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $totalCpu = [double]0
        $totalResident = [int64]0
        $totalPrivate = [int64]0
        foreach ($client in $clients) {
            $id = $null
            try {
                $id = $client.Id
                $client.Refresh()
                if ($client.HasExited) {
                    if ($tracked.ContainsKey($client.Id)) {
                        Record-ClientExit $client.Id $tracked[$client.Id] 'HasExited reported'
                        $tracked.Remove($client.Id); if ($script:accountNameCache.ContainsKey($client.Id)) { $script:accountNameCache.Remove($client.Id) }
                    }
                    continue
                }
                $id = $client.Id
                $ticks = $client.StartTime.ToUniversalTime().Ticks
                $window = $client.MainWindowHandle
                $isResponding = [Arkuzo.HealthNativeV1]::IsResponsive($window)
                $launchError = [Arkuzo.HealthNativeV1]::HasVoltStartupNotice($window)
                if ($tracked.ContainsKey($id) -and $tracked[$id].StartTicks -ne $ticks) { Record-ClientExit $id $tracked[$id] 'PID reused'; $tracked.Remove($id); if ($script:accountNameCache.ContainsKey($id)) { $script:accountNameCache.Remove($id) } }
                # Manage clients even while loading or with no visible window.
                if (-not $tracked.ContainsKey($id)) {
                    $slot = 0
                    $taken = @($tracked.Values | ForEach-Object { $_.Slot })
                    while ($taken -contains $slot) { $slot++ }
                    # Capture everything BEFORE modifying anything.
                    $state = @{
                        StartTicks = $ticks; Slot = $slot
                        Priority = $client.PriorityClass; Affinity = $client.ProcessorAffinity
                        Limits = [Arkuzo.MemorySaverNativeV1]::ReadLimits($client.Handle)
                        Watcher = $null; LastSnapshot = $null; LastStatus = $null
                        LimitsChanged = $false; LastProgress = $clock.Elapsed.TotalSeconds
                        LastTrim = $clock.Elapsed.TotalSeconds; LastConfig = -1e6; MinimizedByUs = $false
                        LastCpu = $client.TotalProcessorTime.TotalSeconds; CpuTime = $clock.Elapsed.TotalSeconds
                        HangSince = -1.0; StartupErrorSince = -1.0; DisconnectSince = -1.0; ParentId = 0; HealthDecision = $null; RecoveryRequested = $false
                        GameReady = $false; GameLogScanned = $false; LogPath = $null; LogOffset = [int64]0; TrackerId = $null; isDisconnected = $false; DisconnectReason = $null
                    }
                    try {
                        $procRecord = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
                        $state.ParentId = [int]$procRecord.ParentProcessId
                        if ($procRecord.CommandLine) {
                            $state.TrackerId = Get-ArkuzoBrowserTrackerId $procRecord.CommandLine
                        }
                    } catch { }
                    $tracked[$id] = $state
                    $watcher = $null
                    try {
                        $watcher = [Diagnostics.Process]::GetProcessById($id)
                        $watcher.Handle | Out-Null # Retain a handle so exit code can survive process exit.
                        $state.Watcher = $watcher
                    } catch { if ($null -ne $watcher) { $watcher.Dispose() }; $watcher = $null }
                    Write-Diagnostic 'CLIENT_START' @{
                        pid = $id; startTicks = $ticks; slot = $slot
                        originalPriority = $state.Priority.ToString(); originalAffinity = $state.Affinity.ToInt64()
                        residentMB = $client.WorkingSet64 / 1MB; privateMB = $client.PrivateMemorySize64 / 1MB
                    }
                }
                $state = $tracked[$id]
                $now = $clock.Elapsed.TotalSeconds
                # Reapply periodically without hammering native setters on each poll.
                if (-not $MonitorOnly -and ($now - $state.LastConfig) -ge 10) {
                    foreach ($operation in @('Priority','Affinity','Limits')) {
                        try {
                            switch ($operation) {
                                'Priority' { $client.PriorityClass = $Priority }
                                'Affinity' { $client.ProcessorAffinity = [Arkuzo.MemorySaverNativeV1]::Affinity($state.Affinity.ToInt64(), $state.Slot, $CoresPerInstance) }
                                'Limits' {
                                    if (-not $SoftLimit) {
                                        [Arkuzo.MemorySaverNativeV1]::SetLimits($client.Handle, 1MB, $maxBytes, $limitFlags)
                                        $state.LimitsChanged = $true
                                    }
                                }
                            }
                        } catch { Warn-Throttled "$id-$operation" "PID ${id}: $operation failed: $($_.Exception.Message)" }
                    }
                    if ($state.LastConfig -lt 0) { Write-Diagnostic 'RESOURCE_CONFIGURATION_REQUESTED' @{ pid = $id; priority = $Priority; logicalCpu = $CoresPerInstance; hardCap = (-not [bool]$SoftLimit); targetMB = $MaxRamMB } }
                    $state.LastConfig = $now
                }
                if (-not $MonitorOnly -and $Minimize -and $client.MainWindowHandle -ne [IntPtr]::Zero) {
                    if (-not [Arkuzo.MemorySaverNativeV1]::IsIconic($client.MainWindowHandle)) {
                        if ([Arkuzo.MemorySaverNativeV1]::ShowWindowAsync($client.MainWindowHandle, 6)) {
                            $state.MinimizedByUs = $true
                        }
                    }
                }
                if (-not $MonitorOnly -and $EnableTrimming -and -not $launchError -and (([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds -ge $healthPolicy.warmup_sec) -and ($now - $state.LastTrim) -ge $TrimEverySec -and ($now - $lastGlobalTrim) -ge $healthPolicy.trim_spacing_sec) {
                    # Opt-in only, above target, skip loading/unresponsive clients.
                    if ($client.WorkingSet64 -gt $maxBytes -and $window -ne [IntPtr]::Zero -and $isResponding) {
                        try {
                            $beforeMB = $client.WorkingSet64 / 1MB
                            [Arkuzo.MemorySaverNativeV1]::Trim($client.Handle); $script:trimCount++; $lastGlobalTrim = $now
                            Write-Diagnostic 'WORKING_SET_TRIM' @{ pid = $id; beforeMB = $beforeMB }
                        }
                        catch { Warn-Throttled "$id-trim" "PID ${id}: trim failed: $($_.Exception.Message)" }
                    }
                    $state.LastTrim = $now
                }
                $client.Refresh()
                $totalResident += $client.WorkingSet64
                $totalPrivate += $client.PrivateMemorySize64
                $sampleTime = $clock.Elapsed.TotalSeconds
                $cpuTime = $client.TotalProcessorTime.TotalSeconds
                $cpu = 0.0
                $elapsed = $sampleTime - $state.CpuTime
                if ($elapsed -ge 0.05) {
                    $cpu = [Math]::Min(100, [Math]::Max(0, 100 * ($cpuTime - $state.LastCpu) / ($elapsed * $cpuThreads)))
                    if (($cpuTime - $state.LastCpu) -gt 0.001) { $state.LastProgress = $sampleTime }
                    $state.LastCpu = $cpuTime; $state.CpuTime = $sampleTime
                }
                $totalCpu += $cpu
                $status = 'WINDOW OPEN'
                if (($sampleTime - $state.LastProgress) -ge 10) { $status = 'NO CPU >10s' }
                if ($client.MainWindowHandle -eq [IntPtr]::Zero) { $status = 'LOADING' }
                elseif ([Arkuzo.MemorySaverNativeV1]::IsIconic($client.MainWindowHandle)) { $status = 'MINIMIZED' }
                if (-not $isResponding -and $window -ne [IntPtr]::Zero) { $status = 'NOT RESPONDING' }
                if ($null -eq $state.LogPath) {
                    $state.LogPath = Find-RobloxProcessLog -TargetProcessId $id -TrackerId $state.TrackerId -StartTimeUtc $client.StartTime.ToUniversalTime()
                }
                if ($null -ne $state.LogPath) {
                    $logOffsetRef = [ref]$state.LogOffset
                    $newLogText = Read-RobloxLogTail $state.LogPath $logOffsetRef
                    $state.LogOffset = $logOffsetRef.Value
                    if ($newLogText) {
                        if ($newLogText -match '(?i)\[DFLog::NetworkClient\] Connection accepted from') { $state.GameReady = $true }
                        $discResult = Get-RobloxLogDisconnectReason $newLogText
                        if ($null -ne $discResult -and $discResult.Disconnected) {
                            $state.isDisconnected = $true
                            $state.GameReady = $false
                            $state.DisconnectReason = $discResult.Reason
                            Write-Diagnostic 'CLIENT_LOG_DISCONNECT_DETECTED' @{ pid = $id; reason = $discResult.Reason; errorCode = $discResult.ErrorCode }
                        }
                    }
                }
                $healthSample = @{
                    privateMB = $client.PrivateMemorySize64 / 1MB; residentMB = $client.WorkingSet64 / 1MB
                    responding = $isResponding; windowPresent = ($window -ne [IntPtr]::Zero)
                    ageSec = ([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds
                    systemCommitPercent = $(if ($null -ne $systemMemory) { $systemMemory.commitPercent } else { 0 })
                    eligible = (-not $MonitorOnly -and $healthPolicy.enabled -and $voltStatus.safeToRecycle -and (Test-ArkuzoVoltOwnership $state.ParentId $voltParents[$state.ParentId] $state.StartTicks $voltPath))
                    launchError = $launchError
                    isDisconnected = [bool]$state.isDisconnected
                    disconnectReason = $state.DisconnectReason
                }
                $state.HealthDecision = Get-ArkuzoHealthDecision $state $healthSample $healthPolicy $sampleTime
                if ($state.HealthDecision.Status) { $status = $state.HealthDecision.Status }
                $clientAgeSec = ([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds
                $nextTrimText = Get-ArkuzoTrimCountdown $clientAgeSec $healthPolicy.warmup_sec $TrimEverySec $sampleTime $state.LastTrim ([bool]$EnableTrimming) ([bool]$MonitorOnly)
                $clientIssues = @($dashboardIssues.Keys | Where-Object { $_ -eq [string]$id -or $_ -like "$id-*" })
                if ($clientIssues.Count -gt 0 -and -not $state.HealthDecision.Status) { $status = 'CHECK NOTICE' }
                $state.LastSnapshot = [ordered]@{
                    pid = $id; cpuPercent = [Math]::Round($cpu, 2); residentMB = [Math]::Round($client.WorkingSet64 / 1MB, 1)
                    privateMB = [Math]::Round($client.PrivateMemorySize64 / 1MB, 1)
                    responding = $isResponding; windowPresent = ($window -ne [IntPtr]::Zero); launchError = $launchError
                    state = $status; sampleTime = (Get-Date).ToString('o')
                }
                $state.HealthSnapshotUtc=[datetime]::UtcNow.ToString('o')
                if ($state.LastStatus -ne $status) {
                    Write-Diagnostic 'CLIENT_STATE_CHANGED' @{ previous = $state.LastStatus; sample = $state.LastSnapshot }
                    $state.LastStatus = $status
                }
                $accountName = Resolve-ArkuzoAccountName -ProcessId $id -TrackerId $state.TrackerId -LogPath $state.LogPath
                $rows.Add([pscustomobject]@{
                    Id = $id; Slot = $state.Slot; Account = $accountName; Cpu = $cpu
                    Ram = $client.WorkingSet64 / 1MB; Private = $client.PrivateMemorySize64 / 1MB
                    NextTrim = $nextTrimText; Status = $status
                })
            } catch {
                if ($null -ne $id -and $tracked.ContainsKey($id)) { Reset-ArkuzoHealthSample $tracked[$id] }
                elseif ($null -eq $id) { foreach ($uncertainState in $tracked.Values) { Reset-ArkuzoHealthSample $uncertainState } }
                Warn-Throttled ([string]$id) "PID ${id}: $($_.Exception.Message)"
            } finally { try { $client.Dispose() } catch { } }
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextOutcomeCheck) {
            Update-ArkuzoRecoveryOutcomes
            $nextOutcomeCheck = $clock.Elapsed.TotalSeconds + 10
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextRuntimeHeartbeat) {
            Write-ArkuzoRuntimeStatus
            $nextRuntimeHeartbeat = $clock.Elapsed.TotalSeconds + 5
        }
        # Try largest first, skipping unready targets without charging a budget.
        foreach ($candidate in @($tracked.GetEnumerator() | Where-Object {
            $_.Value.HealthDecision.Recycle -and
            -not $_.Value.RecoveryRequested -and
            ($null -eq $_.Value.LastRecoveryRefusalUtc -or (([DateTime]::UtcNow) - $_.Value.LastRecoveryRefusalUtc).TotalSeconds -ge 30)
        } | Sort-Object { $_.Value.LastSnapshot.privateMB } -Descending)) {
            $effectiveCooldown = if ($candidate.Value.HealthDecision.Reason -eq 'VOLT_STARTUP_ERROR') { [math]::Min(5, $healthPolicy.cooldown_sec) } else { $healthPolicy.cooldown_sec }
            if (-not (Test-ArkuzoRecoveryBudget $recoveryAttempts ([DateTime]::UtcNow) $effectiveCooldown $healthPolicy.max_recycles_per_hour)) {
                Warn-Throttled 'recovery-budget' 'Recovery cooldown/hourly budget reached. No restart storm.'; break
            }
            Invoke-ClientRecovery $candidate.Key $candidate.Value
            if ($candidate.Value.RecoveryRequested) { break }
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextLogSample) {
            Write-Diagnostic 'RESOURCE_SAMPLE' @{
                detected = $clients.Count; managed = $tracked.Count; systemMemory = $systemMemory; voltRecoveryReady = [bool]$voltStatus.safeToRecycle
                cpuPercent = [Math]::Round($totalCpu, 2); residentMB = [Math]::Round($totalResident / 1MB, 1)
                privateMB = [Math]::Round($totalPrivate / 1MB, 1)
                clients = @($tracked.Values | ForEach-Object { $_.LastSnapshot } | Where-Object { $null -ne $_ })
            }
            $nextLogSample = $clock.Elapsed.TotalSeconds + $LogEverySec
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextEventCheck) {
            Read-CrashEvents
            try {
                $nowUtc = [DateTime]::UtcNow
                if (-not $MonitorOnly) {
                    foreach ($ch in @(Get-Process -Name 'RobloxCrashHandler' -ErrorAction SilentlyContinue)) {
                        try {
                            $record = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ch.Id) -ErrorAction Stop
                            $parentId = [int]$record.ParentProcessId
                            $owner = Get-Process -Id $parentId -ErrorAction SilentlyContinue
                            $orphan = ($null -eq $owner -or $owner.StartTime.ToUniversalTime() -gt $ch.StartTime.ToUniversalTime())
                            if ($orphan -and ($nowUtc - $ch.StartTime.ToUniversalTime()).TotalSeconds -gt 60) {
                                $ch.Kill(); Write-Diagnostic 'ORPHAN_CRASH_HANDLER_CLOSED' @{pid=$ch.Id}
                            }
                            if ($owner) { $owner.Dispose() }
                        } finally { $ch.Dispose() }
                    }
                }
            } catch { }
            $nextEventCheck = $clock.Elapsed.TotalSeconds + 15
        }
        if (($clock.Elapsed.TotalSeconds - $lastHistorySample) -ge 1) {
            $cpuHistory.Enqueue($totalCpu)
            while ($cpuHistory.Count -gt 60) { $cpuHistory.Dequeue() | Out-Null }
            $lastHistorySample = $clock.Elapsed.TotalSeconds
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextStatus) {
            Draw-Dashboard $rows $clients.Count $totalResident $totalPrivate $totalCpu
            $nextStatus = $clock.Elapsed.TotalSeconds + $StatusEverySec
            # Bound warning state during long sessions with many short-lived clients.
            foreach ($key in @($warnings.Keys)) {
                if (($clock.Elapsed.TotalSeconds - $warnings[$key]) -gt 300) { $warnings.Remove($key) }
            }
        }
        foreach ($key in @($dashboardIssues.Keys)) {
            if (($clock.Elapsed.TotalSeconds - $dashboardIssues[$key].Time) -gt 30) { $dashboardIssues.Remove($key) }
        }
        if (-not $Headless -and [Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Q) { break }
        }
        Start-Sleep -Milliseconds $PollMs
    }
} catch {
    Write-Diagnostic 'SAVER_FATAL_ERROR' @{ message = $_.Exception.Message; stack = $_.ScriptStackTrace }
    throw
} finally {
    if ($consoleReady) {
        try {
            [Console]::SetCursorPosition(0, [Console]::WindowTop)
            [Console]::Clear()
            [Console]::CursorVisible = $oldCursorVisible
            if ($null -ne $oldTitle) { [Console]::Title = $oldTitle }
        } catch { }
    }
    Write-Host 'Arkuzo Memory Saver stopped. Restoring Roblox settings...' -ForegroundColor Cyan
    foreach ($id in @($tracked.Keys)) {
        $client = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $client) { continue }
        try { Restore-Client $client $tracked[$id] }
        catch { Write-Warning "PID ${id}: restoration unavailable: $($_.Exception.Message)" }
        finally { $client.Dispose() }
    }
    foreach ($state in $tracked.Values) {
        if ($null -ne $state.Watcher) { try { $state.Watcher.Dispose() } catch { } }
    }
    Clear-VoltRecoveryCapability
    Write-Diagnostic 'SESSION_STOP' @{ uptimeSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); trims = $trimCount }
    if ($ownsControllerMutex -and $null -ne $controllerMutex) { $controllerMutex.ReleaseMutex() }
    if ($null -ne $controllerMutex) { $controllerMutex.Dispose() }
    if ($null -ne $logWriter) { try { $logWriter.Dispose() } catch { } }
    if (-not $logFailed) { Write-Host "Diagnostics saved: $logPath" -ForegroundColor Cyan }
    $clock.Stop()
}
