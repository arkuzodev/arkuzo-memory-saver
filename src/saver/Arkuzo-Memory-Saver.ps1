#requires -Version 5.1
# GENERATED FILE: built by build/bundle.ps1 from src/saver/engine/*.ps1. Edit the modules, then run build/bundle.ps1.
<#
Arkuzo Memory Saver engine - Windows x64, Windows PowerShell 5.1.
Normally started by the Control Center (or ArkuzoMemorySaver.exe --console), which
passes -DataDirectory. Settings come from config.json in the data directory
(see docs/configuration.md); explicit command-line values override it, also on
later hot reloads. Without a config.json the script's own fallbacks apply:
Normal preset, 850 MB advisory target, trimming on, BelowNormal priority.
Soft targets are advisory only: no working-set quota is installed in soft mode.
Working set = resident physical memory, NOT allocated/private/committed memory.
Trimming causes page faults and can reduce performance; memory can be reloaded.
Stopping (Ctrl+C, Q, a stop signal) restores captured process settings where
possible. Force-closing the process skips cleanup; restart Roblox to reset
process settings in that case.
Examples:
  .\Arkuzo-Memory-Saver.ps1
  .\Arkuzo-Memory-Saver.ps1 -Minimize
  .\Arkuzo-Memory-Saver.ps1 -EnableTrimming -HardLimit -MaxRamMB 600 -TrimEverySec 90
  .\Arkuzo-Memory-Saver.ps1 -ApplyGraphicsFlags
Graphics settings persist, affect next launches, and have unique backups.
Diagnostics: Arkuzo-Logs under DataDirectory (unless LogDirectory is set), sampled every 5 seconds.
Each session keeps up to five 10 MB JSON-line .log files. At start, older sessions are deleted
beyond the newest 200 or 300 MB in all (-MaxLogSessions, -MaxLogTotalMB); the current one never.
Use -MonitorOnly to log without changing priority, CPU affinity or memory limits.
Accounts: verified idle accounts with a dead cookie are paused separately, not treated as banned;
a fresh verified alive check resumes their recovery. Moderated accounts are never launched.
Unknown/missing account identities remain blocked; no account is guessed or silently discarded.
Architecture: docs/architecture.md.
#>
[CmdletBinding()]
param(
    [ValidateSet('Normal','Agressive','Aggressive','Extreme','Balanced')][string]$Mode = 'Normal',
    [ValidateRange(128,32768)][int]$MaxRamMB = 850,
    [ValidateRange(1,120)][int]$TrimEverySec = 120,
    [ValidateRange(250,10000)][int]$PollMs = 500,
    [ValidateRange(1,64)][int]$CoresPerInstance = 4,
    [ValidateSet('Idle','BelowNormal','Normal')][string]$Priority = 'BelowNormal',
    [ValidateSet('VeryLow','Low','Medium','BelowNormal','Normal')][string]$MemoryPriority = 'Normal',
    [switch]$Minimize,
    [switch]$EnableTrimming = $true,
    [switch]$SoftLimit = $true,
    [switch]$HardLimit,
    [switch]$ApplyGraphicsFlags,
    [string]$LogDirectory,
    [string]$DataDirectory,
    [ValidateRange(2,300)][int]$LogEverySec = 5,
    [ValidateRange(1,100)][int]$MaxLogMB = 10,
    # Across sessions (checked at start): the newest sessions are kept while both caps hold.
    [ValidateRange(10,100000)][int]$MaxLogSessions = 200,
    [ValidateRange(20,100000)][int]$MaxLogTotalMB = 300,
    [switch]$MonitorOnly,
    [switch]$Headless,
    [ValidateRange(0,86400)][int]$RunForSec = 0,
    [string]$StopFile,
    [ValidateRange(0.25,300)][double]$StatusEverySec = 0.25
)

$ErrorActionPreference = 'Stop'
$ArkuzoRuntimeVersion = '2.4.1'
# Explicit CLI values win over config, including later hot reloads.
$cliBoundParameters = @($PSBoundParameters.Keys)
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
            memory_priority      = 'BelowNormal'
            adaptive_trim        = $true
            pressure_trim_available_percent = 15
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
            memory_priority      = 'Low'
            adaptive_trim        = $true
            pressure_trim_available_percent = 20
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
            memory_priority      = 'VeryLow'
            adaptive_trim        = $true
            pressure_trim_available_percent = 25
            description          = 'Maximum instances:Tight advisory target (450 MB soft), trim every 30s, 1 core. Maximum density on 16 GB RAM.'
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
    Save-ArkuzoAtomicText $Path $json # Flushed to the disk, then renamed into place.
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
        freeCommitMB = [Math]::Round([Math]::Max([double]0, [double]($v[1] - $v[0])), 1)
        commitPercent = [Math]::Round(100 * $v[0] / [Math]::Max([double]1, [double]$v[1]), 2)
        availablePhysicalMB = [Math]::Round($v[2], 1)
    }
}
function Test-ArkuzoVoltOwnership([int]$ParentId, $Parent, [long]$ClientStartTicks, [string]$VoltPath) {
    if ($null -eq $Parent) {
        if ($ParentId -gt 0 -and $null -ne $script:voltParents -and $script:voltParents.ContainsKey($ParentId)) {
            $Parent = $script:voltParents[$ParentId]
        } elseif ($ParentId -le 0 -and $null -ne $script:voltParents -and $script:voltParents.Count -eq 1) {
            $singleId = [int](@($script:voltParents.Keys)[0])
            $Parent = $script:voltParents[$singleId]
            $ParentId = $singleId
        }
    }
    if ($null -eq $Parent -or $ParentId -ne [int]$Parent.Id -or
        [long]$Parent.StartTicks -ge $ClientStartTicks -or [string]::IsNullOrWhiteSpace($VoltPath)) { return $false }
    return [string]::Equals([string]$Parent.Path, $VoltPath, [StringComparison]::OrdinalIgnoreCase)
}
function Test-ArkuzoClientOwnership($State) {
    if (Test-ArkuzoNativeProvider) {
        if ($null -eq $State -or [string]::IsNullOrWhiteSpace([string]$State.TrackerId) -or -not $voltControlStatus.available) { return $false }
        return (@($voltControlStatus.accounts | Where-Object { $_.trackerId -ceq [string]$State.TrackerId }).Count -eq 1)
    }
    return (Test-ArkuzoVoltOwnership $State.ParentId $script:voltParents[$State.ParentId] $State.StartTicks $voltPath)
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
function Read-ArkuzoBoundedFile([string]$Path, [long]$Offset, [int]$MaxBytes, [int]$TimeoutMs = 2000) {
    # Every read of a Roblox log goes through here. The log of a client that froze
    # at a remote-desktop disconnect could not even be opened: CreateFile blocked
    # until the client was gone, and the saver hung on it at every start
    # (8 Nov 16:28-17:21). The open and read run on a worker thread; a read that
    # outlasts TimeoutMs reports TimedOut, and until it finishes that file is
    # skipped at once, so at most one worker per file can be stuck.
    # Offset < 0 reads the last MaxBytes, 0 the first MaxBytes; from Offset > 0 a gap
    # larger than MaxBytes is skipped. (V1 skipped from 0 too, so a log over 128 KB
    # was read from its end: no client adopted after a restart was ever matched.)
    if (-not ('Arkuzo.BoundedReadV2' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading.Tasks;
namespace Arkuzo {
 public sealed class BoundedReadResult { public bool Ok; public bool TimedOut; public long Length; public long Start; public int Count; public string Text = ""; }
 public static class BoundedReadV2 {
  static readonly object Gate = new object();
  static readonly Dictionary<string, Task<BoundedReadResult>> Pending = new Dictionary<string, Task<BoundedReadResult>>(StringComparer.OrdinalIgnoreCase);
  public static BoundedReadResult Read(string path, long offset, int maxBytes, int timeoutMs) {
   Task<BoundedReadResult> task;
   lock (Gate) {
    if (Pending.TryGetValue(path, out task) && !task.IsCompleted) return new BoundedReadResult { TimedOut = true };
    task = Task.Run(() => ReadNow(path, offset, maxBytes));
    Pending[path] = task;
   }
   if (!task.Wait(timeoutMs)) return new BoundedReadResult { TimedOut = true };
   lock (Gate) { Task<BoundedReadResult> current; if (Pending.TryGetValue(path, out current) && current == task) Pending.Remove(path); }
   return task.Result;
  }
  public static int Stuck() { lock (Gate) { int n = 0; foreach (var t in Pending.Values) if (!t.IsCompleted) n++; return n; } }
  static BoundedReadResult ReadNow(string path, long offset, int maxBytes) {
   try {
    if (!File.Exists(path)) return new BoundedReadResult();
    using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
     long len = fs.Length;
     long start = offset < 0 ? Math.Max(0L, len - maxBytes) : offset;
     if (start > len) return new BoundedReadResult { Ok = true, Length = len, Start = start };
     // Only a continuing tail read (offset > 0) skips a gap; offset 0 is a head read.
     if (offset > 0 && len - start > maxBytes) start = len - maxBytes;
     int want = (int)Math.Min((long)maxBytes, len - start);
     var buffer = new byte[want];
     fs.Seek(start, SeekOrigin.Begin);
     int got = 0;
     while (got < want) { int n = fs.Read(buffer, got, want - got); if (n <= 0) break; got += n; }
     return new BoundedReadResult { Ok = true, Length = len, Start = start, Count = got, Text = Encoding.UTF8.GetString(buffer, 0, got) };
    }
   } catch (Exception) { return new BoundedReadResult(); }
  }
 }
}
'@
    }
    $result = [Arkuzo.BoundedReadV2]::Read($Path, $Offset, $MaxBytes, $TimeoutMs)
    if ($result.TimedOut) {
        Warn-Throttled 'roblox-log-blocked' 'A Roblox log file did not open within 2 s (a frozen client can hold it); it is skipped until it opens again.'
    }
    return $result
}
function Read-ArkuzoLogHeadLines([string]$Path, [int]$Lines, [int]$MaxBytes = 262144) {
    # The first $Lines lines of a log, read through Read-ArkuzoBoundedFile.
    $r = Read-ArkuzoBoundedFile $Path 0 $MaxBytes
    if (-not $r.Ok -or [string]::IsNullOrEmpty($r.Text)) { return @() }
    return @($r.Text -split "`r?`n" | Select-Object -First $Lines)
}
function Get-ArkuzoRobloxLogListing([string]$Dir) {
    # The newest 30 player logs. Listed once per main-loop pass and shared by every client
    # whose log is not bound yet (it was listed once per client, on every pass).
    $pass = $script:loopPass
    if ($null -ne $pass -and $script:robloxLogListingPass -eq $pass -and $script:robloxLogListingDir -ceq $Dir -and $null -ne $script:robloxLogListing) { return ,$script:robloxLogListing }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*_Player_*_last.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*CrashHandler*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 30)
    if ($null -ne $pass) { $script:robloxLogListing = $files; $script:robloxLogListingPass = $pass; $script:robloxLogListingDir = $Dir }
    return ,$files
}
function Find-RobloxProcessLog([int]$TargetProcessId, [string]$TrackerId = $null, [datetime]$StartTimeUtc = [datetime]::MinValue, [string]$LogsDir = $null) {
    try {
        if ($TrackerId -notmatch '\A[0-9]+\z' -or $StartTimeUtc -eq [datetime]::MinValue) { return $null }
        $dir = if ($LogsDir) { $LogsDir } else { Join-Path $env:LOCALAPPDATA 'Roblox\logs' }
        if (-not (Test-Path -LiteralPath $dir)) { return $null }
        $files = Get-ArkuzoRobloxLogListing $dir
        # A log's tracker id never changes once written: remember it instead of re-reading the head.
        if ($null -eq $script:robloxLogTrackers -or $script:robloxLogTrackers.Count -gt 400) { $script:robloxLogTrackers = @{} }
        if ($TrackerId -and [regex]::IsMatch($TrackerId, '^\d+$')) {
            foreach ($f in $files) {
                try {
                    if ($f.Name -notmatch '_(\d{8}T\d{6}Z)_Player_') { continue }
                    $fTime = [DateTime]::ParseExact($matches[1], 'yyyyMMdd\THHmmss\Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
                    if ([Math]::Abs(($fTime - $StartTimeUtc.ToUniversalTime()).TotalSeconds) -gt 30) { continue }
                    $known = $script:robloxLogTrackers[$f.FullName]
                    if ($null -eq $known) {
                        $lines = Read-ArkuzoLogHeadLines $f.FullName 100 131072
                        $content = $lines -join "`n"
                        if ($content -match "websiteBTId is\s*(\d+)" -or $content -match "BTID is overriden to\s*(\d+)") {
                            $known = [string]$matches[1]; $script:robloxLogTrackers[$f.FullName] = $known
                        }
                    }
                    if ($null -ne $known -and $known -eq $TrackerId) { return $f.FullName }
                } catch { }
            }
        }
        # Never bind a game log by launch-time proximity alone.
        return $null
    } catch { return $null }
}

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

function Get-ArkuzoExecutorRoots {
    $roots = New-Object System.Collections.Generic.HashSet[string]
    if ($env:LOCALAPPDATA) {
        $roots.Add((Join-Path $env:LOCALAPPDATA 'Volt')) | Out-Null
        $roots.Add((Join-Path $env:LOCALAPPDATA 'Potassium')) | Out-Null
        $roots.Add((Join-Path $env:LOCALAPPDATA 'com.volt.editor')) | Out-Null
        $roots.Add((Join-Path $env:LOCALAPPDATA 'com.pot.potassium-tauri')) | Out-Null
    }
    if ($env:APPDATA) {
        $roots.Add((Join-Path $env:APPDATA 'Volt')) | Out-Null
        $roots.Add((Join-Path $env:APPDATA 'Potassium')) | Out-Null
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $progFiles = [Environment]::GetFolderPath('ProgramFiles')
    $progFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    foreach ($base in @($desktop, $userProfile, $progFiles, $progFilesX86)) {
        if ($base -and (Test-Path -LiteralPath $base)) {
            foreach ($sub in @('Volt', 'VoltX', 'Potassium', 'Tools & Mods\Volt', 'Tools & Mods\VoltX', 'Tools & Mods\potass', 'Tools & Mods\potae')) {
                $cand = Join-Path $base $sub
                if (Test-Path -LiteralPath $cand) { $roots.Add($cand) | Out-Null }
            }
        }
    }
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { [AppDomain]::CurrentDomain.BaseDirectory }
    if ($baseDir) {
        foreach ($cand in @((Join-Path $baseDir 'Volt'), (Join-Path $baseDir 'VoltX'), (Join-Path $baseDir 'Potassium'),
                            (Join-Path (Split-Path -Parent $baseDir) 'Volt'), (Join-Path (Split-Path -Parent $baseDir) 'VoltX'), (Join-Path (Split-Path -Parent $baseDir) 'Potassium'))) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $roots.Add($cand) | Out-Null }
        }
    }
    try {
        Get-Process | Where-Object { $_.ProcessName -match '(?i)\A(volt|potassium|tauri-app)' } | ForEach-Object {
            try {
                $pPath = $_.Path
                if (-not $pPath -and $_.MainModule) { $pPath = $_.MainModule.FileName }
                if ($pPath) {
                    $pDir = Split-Path -Parent $pPath
                    $roots.Add($pDir) | Out-Null
                    $parentDir = Split-Path -Parent $pDir
                    if ($parentDir) { $roots.Add($parentDir) | Out-Null }
                }
            } catch { }
        }
    } catch { }
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Get-ArkuzoExecutorSignalDirectories {
    $dirs = New-Object System.Collections.Generic.HashSet[string]
    $roots = Get-ArkuzoExecutorRoots
    foreach ($r in $roots) {
        if ((Split-Path -Leaf $r) -ieq 'workspace') {
            $dirs.Add($r) | Out-Null
        } else {
            $ws = Join-Path $r 'workspace'
            if (Test-Path -LiteralPath $ws) { $dirs.Add($ws) | Out-Null }
        }
    }
    return @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Read-ArkuzoExecutorSignals {
    $signals = @()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $workspaces = Get-ArkuzoExecutorSignalDirectories
    foreach ($ws in $workspaces) {
        $candidateFiles = @()
        $sub = Join-Path $ws "arkuzo_signals"
        if (Test-Path $sub) {
            $candidateFiles += @(Get-ChildItem -Path $sub -Filter "*.json" -ErrorAction SilentlyContinue)
        }
        $candidateFiles += @(Get-ChildItem -Path $ws -Filter "arkuzo_signals_*.json" -ErrorAction SilentlyContinue)
        $candidateFiles += @(Get-ChildItem -Path $ws -Filter "arkuzo_signals_latest.json" -ErrorAction SilentlyContinue)
        foreach ($f in $candidateFiles) {
            try {
                $raw = [IO.File]::ReadAllText($f.FullName)
                $sig = $raw | ConvertFrom-Json
                if ($null -ne $sig -and $sig.username) {
                    $sigAge = if ($sig.timestamp) { $now - [long]$sig.timestamp } else { 0 }
                    if ($sigAge -ge -15 -and $sigAge -le 180) {
                        $signals += [pscustomobject]@{
                            Username = [string]$sig.username
                            UserId = [string]$sig.userId
                            Reason = [string]$sig.reason
                            ErrorCode = [int]$sig.errorCode
                            Source = [string]$sig.source
                            FilePath = $f.FullName
                        }
                    }
                }
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    }
    return $signals
}

$script:ArkuzoAutoexecLuauContent = @'
--[[
    Arkuzo Saver - Autonomous Ingame Kick & Disconnect Signal Transmitter
    Automatically installed into executor autoexec by Arkuzo Saver.
    Catches kicks, bans, error prompts, disconnects, and teleports, writing instant signals to workspace.
]]--

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local fired = false

local function sendSignal(reason, errorCode, source)
    if fired then return end
    fired = true

    local username = "Unknown"
    local userId = 0
    pcall(function()
        if Players.LocalPlayer then
            username = Players.LocalPlayer.Name
            userId = Players.LocalPlayer.UserId
        end
    end)

    local payload = {
        username = username,
        userId = userId,
        placeId = game.PlaceId,
        jobId = game.JobId,
        reason = tostring(reason or "Unknown Kick/Disconnect"),
        errorCode = tonumber(errorCode) or 0,
        source = source or "ArkuzoAutoexecSignal",
        timestamp = os.time()
    }

    local jsonStr = nil
    pcall(function()
        jsonStr = HttpService:JSONEncode(payload)
    end)
    if not jsonStr then return end

    -- Write signal files into executor workspace
    pcall(function()
        if writefile then
            pcall(function()
                if makefolder and not isfolder("arkuzo_signals") then
                    makefolder("arkuzo_signals")
                end
                writefile("arkuzo_signals/" .. tostring(userId) .. ".json", jsonStr)
            end)
            pcall(function()
                writefile("arkuzo_signals_" .. tostring(username) .. ".json", jsonStr)
            end)
            pcall(function()
                writefile("arkuzo_signals_latest.json", jsonStr)
            end)
        end
    end)
end

-- 1. GuiService Error Message Changed (Standard Roblox Disconnect / Kick Code 267, 277, etc.)
pcall(function()
    GuiService.ErrorMessageChanged:Connect(function(errorMessage)
        if errorMessage and errorMessage ~= "" then
            local code = 0
            pcall(function()
                code = GuiService:GetErrorCode().Value
            end)
            sendSignal(errorMessage, code, "GuiService.ErrorMessageChanged")
        end
    end)
end)

-- 2. CoreGui Error Prompt Overlay (Catches custom kick UIs and error modals)
pcall(function()
    local promptGui = CoreGui:WaitForChild("RobloxPromptGui", 5)
    if promptGui then
        local promptOverlay = promptGui:WaitForChild("promptOverlay", 5)
        if promptOverlay then
            promptOverlay.ChildAdded:Connect(function(child)
                if child.Name == "ErrorPrompt" then
                    local code = 0
                    pcall(function() code = GuiService:GetErrorCode().Value end)
                    local msg = ""
                    pcall(function()
                        local msgArea = child:FindFirstChild("MessageArea")
                        if msgArea then
                            local errorFrame = msgArea:FindFirstChild("ErrorFrame")
                            local errorMsg = errorFrame and errorFrame:FindFirstChild("ErrorMessage")
                            if errorMsg and errorMsg:IsA("TextLabel") then
                                msg = errorMsg.Text
                            end
                        end
                    end)
                    sendSignal(msg ~= "" and msg or "ErrorPrompt displayed", code, "RobloxPromptGui.ErrorPrompt")
                end
            end)
        end
    end
end)

-- 3. NetworkClient Disconnection (ClientReplicator dropped)
pcall(function()
    local nc = game:GetService("NetworkClient")
    nc.ChildRemoved:Connect(function(child)
        if child:IsA("ClientReplicator") then
            sendSignal("ClientReplicator disconnected", 277, "NetworkClient.ChildRemoved")
        end
    end)
end)

-- 4. Teleport Init Failed (Teleport Disconnect)
pcall(function()
    TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
        sendSignal("TeleportInitFailed: " .. tostring(errorMessage), 279, "TeleportService.TeleportInitFailed")
    end)
end)

-- 5. Fallback periodic check
task.spawn(function()
    while not fired do
        task.wait(1.5)
        pcall(function()
            local code = 0
            pcall(function() code = GuiService:GetErrorCode().Value end)
            if code ~= 0 then
                local msg = ""
                pcall(function() msg = GuiService:GetErrorMessage() end)
                sendSignal(msg ~= "" and msg or ("Error code " .. tostring(code)), code, "PeriodicWatchdog")
            end
        end)
    end
end)
'@

function Sync-ArkuzoAutoexecSignals {
    $scriptContent = $script:ArkuzoAutoexecLuauContent
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
        $scriptSource = Join-Path $PSScriptRoot "00-arkuzo-signal.luau"
        if (Test-Path $scriptSource) {
            try { $scriptContent = [IO.File]::ReadAllText($scriptSource) } catch { }
        }
    }
    # ONLY direct autoexec directories, NEVER subfolders
    $executorRoots = Get-ArkuzoExecutorRoots
    foreach ($root in $executorRoots) {
        $autoexecDir = if ((Split-Path -Leaf $root) -ieq 'autoexec') { $root } else { Join-Path $root 'autoexec' }
        if (-not (Test-Path -LiteralPath $autoexecDir) -and (Split-Path -Leaf $root) -imatch '(?i)\A(Volt|VoltX|Potassium|com\.volt\.editor)\z') {
            try { [IO.Directory]::CreateDirectory($autoexecDir) | Out-Null } catch { }
        }
        if (Test-Path -LiteralPath $autoexecDir) {
            # Clean up any accidental subfolder duplicates
            Get-ChildItem -LiteralPath $autoexecDir -Recurse -Depth 3 -Filter "00-arkuzo-signal.luau" -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.DirectoryName -ne $autoexecDir) {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
            # Write only to the root autoexec folder
            $dest = Join-Path $autoexecDir "00-arkuzo-signal.luau"
            $needWrite = $true
            if (Test-Path -LiteralPath $dest) {
                try {
                    $existing = [IO.File]::ReadAllText($dest)
                    if ($existing.Trim() -eq $scriptContent.Trim()) { $needWrite = $false }
                } catch { }
            }
            if ($needWrite) {
                try {
                    [IO.File]::WriteAllText($dest, $scriptContent, [Text.Encoding]::UTF8)
                    Write-Diagnostic 'AUTOEXEC_SIGNAL_SCRIPT_SYNCED' @{ destination = $dest }
                } catch { }
            }
        }
    }
}

function Process-ArkuzoExecutorSignals {
    try {
        $signals = Read-ArkuzoExecutorSignals
        foreach ($sig in $signals) {
            $matchedPid = $null
            foreach ($kv in $script:tracked.GetEnumerator()) {
                $checkPid = $kv.Key
                $st = $kv.Value
                $name = Resolve-ArkuzoAccountName -ProcessId $checkPid -TrackerId $st.TrackerId -LogPath $st.LogPath
                if ($name -and ($name.TrimStart('@') -ieq $sig.Username -or $name -ieq $sig.Username)) {
                    $matchedPid = $checkPid; break
                }
            }
            # Only an exact account name binds a signal. A signal names its account; one that
            # matches no tracked client is dropped, never attributed by guess (a single tracked
            # client is not proof: the signal may be up to 180 s old and from another account).
            if ($null -ne $matchedPid -and $script:tracked.ContainsKey($matchedPid)) {
                $targetState = $script:tracked[$matchedPid]
                $targetState.isDisconnected = $true
                $targetState.GameReady = $false
                $targetState.DisconnectReason = "Executor Signal: $($sig.Reason) (Code $($sig.ErrorCode))"
                if ($targetState -is [Collections.IDictionary]) { $targetState['DisconnectSource'] = [string]$sig.Source } else { $targetState | Add-Member -NotePropertyName DisconnectSource -NotePropertyValue ([string]$sig.Source) -Force }
                Write-Diagnostic 'EXECUTOR_KICK_SIGNAL_TRIGGERED' @{
                    pid = $matchedPid
                    username = $sig.Username
                    reason = $sig.Reason
                    errorCode = $sig.ErrorCode
                    source = $sig.Source
                }
            }
        }
    } catch { }
}

function Invoke-ArkuzoHealthObservation {
    # Cooperative, read-only service: never perform launcher/log/name IO here.
    # Round-robin and a half-second work slice prevent a large client set from
    # monopolizing a probe wait. Oversized sets still fail closed on real gaps.
    if ($script:observationBusy -or $null -eq $script:tracked -or $null -eq $clock) { return }
    $script:observationBusy = $true
    $work = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ids = @($script:tracked.Keys | Sort-Object)
        if ($ids.Count -eq 0) { return }
        for ($i=0; $i -lt $ids.Count -and $work.Elapsed.TotalMilliseconds -lt 500; $i++) {
            $index = [int]$script:observationCursor % $ids.Count
            $script:observationCursor = ($index + 1) % $ids.Count
            $id = [int]$ids[$index]; $state = $script:tracked[$id]
            if ($state.ParentId -le 0 -and $null -ne $script:voltParents -and $script:voltParents.Count -eq 1) {
                $state.ParentId = [int](@($script:voltParents.Keys)[0])
            }
            $now = $clock.Elapsed.TotalSeconds
            # A frozen window costs a 100 ms probe and the main loop probes every client once
            # per pass; the slice re-probes a frozen one only when its last sample is 10 s old
            # (a long wait), which keeps its timers well inside the 30 s gap they tolerate.
            $minGap = if ($null -ne $state.LastSnapshot -and $state.LastSnapshot['windowPresent'] -eq $true -and $state.LastSnapshot['responding'] -eq $false) { 10 } else { 1 }
            if ($state.RecoveryRequested -or ($null -ne $state.LastHealthSampleTime -and
                $now -ge [double]$state.LastHealthSampleTime -and ($now - [double]$state.LastHealthSampleTime) -lt $minGap)) { continue }
            try {
                if (-not (Test-ArkuzoClientIdentity $state.Watcher $id $state.StartTicks)) { Reset-ArkuzoHealthSample $state; continue }
                $reason = if ($state.isDisconnected) { 'IN_GAME_DISCONNECT' } else { '' }
                $sample = Get-ArkuzoRecoveryHealthSample $state.Watcher $reason $state
                if (-not (Test-ArkuzoClientIdentity $state.Watcher $id $state.StartTicks)) { Reset-ArkuzoHealthSample $state; continue }
                $sample.systemCommitPercent = if ($null -ne $systemMemory) { $systemMemory.commitPercent } else { 0 }
                $sample.eligible = (-not $MonitorOnly -and $healthPolicy.enabled -and $voltStatus.safeToRecycle -and
                    (Test-ArkuzoClientOwnership $state))
                # Timestamp after collecting; never replay or synthesize missed samples.
                $state.HealthDecision = Get-ArkuzoHealthDecision $state $sample $healthPolicy $clock.Elapsed.TotalSeconds
                if (-not $sample.windowPresent -or -not $sample.responding -or $sample.launchError -or
                    $sample.isDisconnected -or -not $state.GameReady) { Clear-ArkuzoOutcomeObservation $state }
                if ($null -eq $state.LastSnapshot) { $state.LastSnapshot = @{pid=$id} }
                foreach ($key in $sample.Keys) { $state.LastSnapshot[$key] = $sample[$key] }
                $state.LastSnapshot.state = $state.HealthDecision.Status
                $state.LastSnapshot.sampleTime = [datetime]::UtcNow.ToString('o')
                # Do not advance outcome freshness: this service has not tailed
                # the game log. Only the complete main-loop sample can do that.
            } catch { Reset-ArkuzoHealthSample $state }
        }
    } finally { $work.Stop(); $script:observationBusy = $false }
}
function Wait-ArkuzoObservedProcess($Process, [int]$TimeoutMs) {
    # Keep the original total timeout, including observation work. No asynchronous
    # runspace owns client handles and disposal never waits for a background task.
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($deadline.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
            if ($Process.WaitForExit(0)) { return $true }
            Invoke-ArkuzoHealthObservation
            $remaining = $TimeoutMs - [int][math]::Ceiling($deadline.Elapsed.TotalMilliseconds)
            if ($remaining -le 0) { return $Process.WaitForExit(0) }
            if ($Process.WaitForExit([math]::Min(100, [int]$remaining))) { return $true }
        }
        return $Process.WaitForExit(0)
    } finally { $deadline.Stop() }
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
        if (-not (Wait-ArkuzoObservedProcess $child 3000)) { $child.Kill(); throw 'Probe timeout' }
        if ($child.ExitCode -ne 0) { throw 'Probe failed' }
        $result = $child.StandardOutput.ReadToEnd() | ConvertFrom-Json
        if ($null -eq $result.safeToRecycle) { throw 'Invalid probe result' }
        return $result
    } catch { return [pscustomobject]@{ safeToRecycle = $false; reason = 'Volt recovery probe unavailable' } }
    finally { if ($null -ne $child) { $child.Dispose() } }
}
function Get-ArkuzoHealthPolicy($Config) {
    $defaults = @{ enabled = $false; private_limit_mb = 4096; hang_timeout_sec = 120; warmup_sec = 90; pressure_percent = 85; pressure_min_private_mb = 2048; cooldown_sec = 60; max_recycles_per_hour = 60; trim_spacing_sec = 2; startup_error_timeout_sec = 40; disconnect_timeout_sec = 5; private_limit_sustain_sec = 60
        # A new client is not touched (priority, affinity, memory priority, limits) before this age
        # and a window: see Test-ArkuzoClientConfigReady.
        config_grace_sec = 20
        # Farm-wide freeze fast path (see Get-ArkuzoFarmFreezeCandidate).
        farm_freeze_enabled = $true; farm_freeze_confirm_sec = 35; farm_freeze_min_clients = 3; farm_freeze_onset_window_sec = 15
        farm_freeze_max_cpu_percent = 5; farm_freeze_spacing_sec = 20; farm_freeze_refreeze_sec = 900
        # Remote sessions (see docs/remote-desktop.md): a freeze that starts within
        # farm_freeze_remote_window_sec after a remote-desktop disconnect is confirmed
        # after farm_freeze_remote_confirm_sec; a disconnected RDP session holds
        # recovery and launches for at most remote_hold_max_sec.
        farm_freeze_remote_confirm_sec = 20; farm_freeze_remote_window_sec = 60; remote_hold_max_sec = 600; keep_display_awake = $true }
    if ($null -ne $Config) {
        foreach ($key in @($defaults.Keys)) { if ($null -ne $Config.$key) { $defaults[$key] = $Config.$key } }
    }
    $ranges = @{ private_limit_mb = @(1024,16384); hang_timeout_sec = @(60,900); warmup_sec = @(60,900); pressure_percent = @(60,98); pressure_min_private_mb = @(1024,16384); cooldown_sec = @(30,300); max_recycles_per_hour = @(1,60); trim_spacing_sec = @(1,30); startup_error_timeout_sec = @(0,300); disconnect_timeout_sec = @(0,300); private_limit_sustain_sec = @(0,300); config_grace_sec = @(10,300)
        farm_freeze_confirm_sec = @(20,120); farm_freeze_min_clients = @(3,50); farm_freeze_onset_window_sec = @(5,60); farm_freeze_max_cpu_percent = @(1,10); farm_freeze_spacing_sec = @(10,60); farm_freeze_refreeze_sec = @(0,86400)
        farm_freeze_remote_confirm_sec = @(10,120); farm_freeze_remote_window_sec = @(10,300); remote_hold_max_sec = @(0,3600) }
    foreach ($key in $ranges.Keys) {
        $value = [double]$defaults[$key]
        if ($value -lt $ranges[$key][0] -or $value -gt $ranges[$key][1] -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "Invalid health setting: $key" }
    }
    if ($defaults.enabled -isnot [bool]) { throw 'health.enabled must be a JSON boolean' }
    if ($defaults.farm_freeze_enabled -isnot [bool]) { throw 'health.farm_freeze_enabled must be a JSON boolean' }
    if ($defaults.keep_display_awake -isnot [bool]) { throw 'health.keep_display_awake must be a JSON boolean' }
    return $defaults
}
function Set-ArkuzoConfigLockLimits($Policy) {
    # config_lock: production limits applied after validation, on load and on every
    # reload. A value already on the safe side is kept as it is.
    if ($null -eq $Policy) { return }
    $atLeast = [ordered]@{ pressure_percent = 88; pressure_min_private_mb = 4000; max_recycles_per_hour = 20
        # Farm-freeze fast path: no earlier than 30 s (some correlated stalls clear by
        # themselves within ~30 s) and Volt launches at least 15 s apart (closer
        # launches raise its startup notice).
        farm_freeze_confirm_sec = 30; farm_freeze_spacing_sec = 15
        # No multi-client freeze that followed a remote disconnect ever answered again.
        farm_freeze_remote_confirm_sec = 15 }
    $atMost = [ordered]@{ startup_error_timeout_sec = 5; disconnect_timeout_sec = 5; cooldown_sec = 90 }
    foreach ($key in $atLeast.Keys) { if ([double]$Policy[$key] -lt [double]$atLeast[$key]) { $Policy[$key] = $atLeast[$key] } }
    foreach ($key in $atMost.Keys) { if ([double]$Policy[$key] -gt [double]$atMost[$key]) { $Policy[$key] = $atMost[$key] } }
}
function Clear-VoltRecoveryCapability {
    foreach ($parent in @($script:voltParents.Values)) {
        if ($null -ne $parent.Process) { try { $parent.Process.Dispose() } catch { } }
    }
    $script:voltParents = @{}
}
function Update-VoltRecoveryCapability {
    param([switch]$SyncControl = $false)
    Clear-VoltRecoveryCapability
    if (Test-ArkuzoNativeProvider) {
        if ($SyncControl) { Update-ArkuzoVoltControl }
        $script:voltStatus = [pscustomobject]@{ safeToRecycle = [bool]($voltControlStatus.available -and $voltControlStatus.provider -ceq 'arkuzo'); reason = 'Arkuzo account vault' }
        return
    }
    $script:voltStatus = Get-ArkuzoVoltRecoveryStatus -Root $PSScriptRoot
    if ($SyncControl) {
        Update-ArkuzoVoltControl
    }
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
function Write-ArkuzoDurableBytes([string]$Path, [byte[]]$Bytes, [switch]$Volatile, [switch]$CreateNew) {
    # Writes and, unless -Volatile, flushes the bytes to the disk (FlushFileBuffers) before
    # returning. A rename that reaches the NTFS journal while the data is still in the cache
    # leaves a zero-filled file after a crash (11 Nov: accounts.json, 28 KB of NUL).
    $mode = if ($CreateNew) { [IO.FileMode]::CreateNew } else { [IO.FileMode]::Create }
    $options = if ($Volatile) { [IO.FileOptions]::None } else { [IO.FileOptions]::WriteThrough }
    $stream = New-Object IO.FileStream($Path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, $options)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        if ($Volatile) { $stream.Flush() } else { $stream.Flush($true) }
    } finally { $stream.Dispose() }
}
function Save-ArkuzoAtomicText([string]$Path, [string]$Text, [switch]$Volatile) {
    Save-ArkuzoAtomicBytes $Path ((New-Object Text.UTF8Encoding($false)).GetBytes($Text)) -Volatile:$Volatile
}
function Save-ArkuzoAtomicBytes([string]$Path, [byte[]]$Bytes, [switch]$Volatile) {
    # Temp file, flushed to the disk (unless -Volatile), then an atomic replace.
    $temp = $Path + '.' + $PID + '.tmp'
    try {
        Write-ArkuzoDurableBytes $temp $Bytes -Volatile:$Volatile
        $saved = $false
        for ($attempt = 0; $attempt -lt 5 -and -not $saved; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($temp, $Path) }
                $saved = $true
            } catch {
                if ($attempt -ge 4) { throw }
                Start-Sleep -Milliseconds 60
            }
        }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
function Save-ArkuzoAtomicJson([string]$Path, $Value, [switch]$Volatile) {
    # Durable by default (journal, vault, config.json). Only the heartbeat, rewritten every
    # 2 s and regenerated after any restart, is written -Volatile.
    Save-ArkuzoAtomicText $Path ($Value | ConvertTo-Json -Depth 12) -Volatile:$Volatile
}
function Save-ArkuzoRecoveryJournal {
    if (-not $ownsControllerMutex -or $script:recoveryJournalCorrupt) { throw 'Recovery journal not owned/healthy' }
    $utc = [datetime]::UtcNow
    $script:recoveryAttempts = @($recoveryAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 })
    $script:launchAttempts = @($launchAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 })
    Save-ArkuzoAtomicJson $recoveryStatePath @{
        schemaVersion = 2; attempts = @($recoveryAttempts | ForEach-Object { $_.ToString('o') })
        launchAttempts = @($launchAttempts | ForEach-Object { $_.ToString('o') })
        pending = @($recoveryPending.Values); suspendedAccounts = @(); updatedUtc = $utc.ToString('o')
        quarantined = @(if ($null -ne $script:quarantinedAccounts) { $script:quarantinedAccounts.Values })
    }
    $script:recoveryJournalHealthy = $true
}
function Initialize-ArkuzoRecoveryJournal {
    # Load only while holding the sole destructive-controller mutex.
    $script:recoveryJournalHealthy = $false; $script:recoveryJournalCorrupt = $false; $script:recoveryAttempts = @(); $script:launchAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
    if (-not $ownsControllerMutex) { return }
    try {
        if (Test-Path -LiteralPath $recoveryStatePath) {
            $journal = [IO.File]::ReadAllText($recoveryStatePath) | ConvertFrom-Json
            if ($null -eq $journal.attempts) { throw 'Invalid recovery journal' }
            $script:recoveryAttempts = @($journal.attempts | ForEach-Object { ([datetime]$_).ToUniversalTime() })
            $script:launchAttempts = if ($journal.launchAttempts) { @($journal.launchAttempts | ForEach-Object { ([datetime]$_).ToUniversalTime() }) } else { @() }
            if ($null -ne $journal.pending) {
                foreach ($value in $journal.pending) {
                    if (-not $value.accountId -or -not $value.createdUtc) { throw 'Invalid pending journal entry' }
                    [datetime]$value.createdUtc | Out-Null
                    if ($value.closedUtc) { [datetime]$value.closedUtc | Out-Null }
                    if ($value.nextRetryUtc) { [datetime]$value.nextRetryUtc | Out-Null }
                    if ([int]$value.retryCount -lt 0) { throw 'Invalid retry count' }
                    $entry = @{}; foreach ($prop in $value.PSObject.Properties) { $entry[$prop.Name] = $prop.Value }
                    if ($value.missingSinceUtc) { [datetime]$value.missingSinceUtc | Out-Null }
                    # A monitor restart breaks continuity; never inherit a previous healthy timer.
                    $entry.readySinceUtc = $null; $entry.lastObservedUtc = $null
                    # Stale or synthetic missing entries without a verified prior process must not trigger auto-launch on startup.
                    if ([int]$value.oldPid -gt 0 -and [long]$value.oldStartTicks -gt 0) {
                        $script:recoveryPending[[string]$value.accountId] = $entry
                    }
                }
            }
            # Suspended accounts disappear on restart and are not saved practically; start clean
            $script:suspendedAccounts = @{}
            # Quarantine survives restarts so a crash loop cannot reset it. Malformed
            # rows are dropped: losing a quarantine only resumes normal recovery.
            foreach ($q in @($journal.quarantined)) {
                if ($null -eq $q -or [string]$q.accountId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') { continue }
                try { [datetime]$q.untilUtc | Out-Null } catch { continue }
                $row = @{}; foreach ($prop in $q.PSObject.Properties) { $row[$prop.Name] = $prop.Value }
                $script:quarantinedAccounts[[string]$q.accountId] = $row
            }
            $script:recoveryJournalHealthy = $true
        } else {
            $script:recoveryJournalHealthy = $true
            Save-ArkuzoRecoveryJournal
        }
    } catch {
        $script:recoveryAttempts = @(); $script:launchAttempts = @(); $script:recoveryPending = @{}; $script:suspendedAccounts = @{}; $script:quarantinedAccounts = @{}
        $script:recoveryJournalHealthy = $false; $script:recoveryJournalCorrupt = $true
    }
}
function Get-ArkuzoRecoveryHealthSample($Watcher, [string]$Reason, $CurrentState = $null) {
    if ($Reason -ceq 'VOLT_STARTUP_ERROR' -and $null -ne $CurrentState) {
        # Positive gameplay evidence must be refreshed during recovery, not only
        # in the main monitor loop. A tail is NEVER complete negative history.
        $CurrentState.StartupGameHistory = 'UNKNOWN'
        if (Test-ArkuzoClientIdentity $Watcher $Watcher.Id $CurrentState.StartTicks) {
            $boundLog = Find-RobloxProcessLog -TargetProcessId $Watcher.Id -TrackerId $CurrentState.TrackerId -StartTimeUtc $Watcher.StartTime.ToUniversalTime()
            if ($boundLog -and $CurrentState.LogPath -ceq $boundLog) {
                $offset = [ref]$CurrentState.LogOffset
                $text = Read-RobloxLogTail $boundLog $offset
                $CurrentState.LogOffset = $offset.Value
                if ($text -match '(?i)\[DFLog::NetworkClient\] Connection accepted from') {
                    $CurrentState.GameReady = $true; $CurrentState.EverGameReady = $true
                }
                $disconnect = Get-RobloxLogDisconnectReason $text
                if ($null -ne $disconnect -and $disconnect.Disconnected) {
                    $CurrentState.isDisconnected = $true; $CurrentState.GameReady = $false
                    $CurrentState.DisconnectReason = $disconnect.Reason; $CurrentState.DisconnectSource = 'log'
                }
            }
        }
    }
    $Watcher.Refresh()
    $window = $Watcher.MainWindowHandle
    # Native probes are bounded and do not send close/input messages.
    $responding = [Arkuzo.HealthNativeV1]::IsResponsive($window)
    $launchError = [Arkuzo.HealthNativeV1]::HasVoltStartupNotice($window)
    $isDisconnected = $false
    if ($null -ne $CurrentState -and $CurrentState.isDisconnected) {
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
        $trackerId = $null
        try {
            $records = @(Get-CimInstance Win32_Process -Filter "ProcessId=$ClientId" -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($records.Count -eq 1 -and $records[0].ProcessId -eq $ClientId -and $records[0].Name -eq 'RobloxPlayerBeta.exe' -and $records[0].CommandLine -is [string]) {
                $trackerId = Get-ArkuzoBrowserTrackerId $records[0].CommandLine
            }
        } catch { }
        if ([string]::IsNullOrEmpty($trackerId) -and $null -ne $voltControlStatus -and $voltControlStatus.available -and $null -ne $voltControlStatus.accounts) {
            $m = @($voltControlStatus.accounts | Where-Object { [int]$_.processId -eq $ClientId })
            if ($m.Count -eq 1 -and -not [string]::IsNullOrEmpty($m[0].trackerId)) {
                $trackerId = [string]$m[0].trackerId
            }
        }
        # A retained exact process alive on both sides of the metadata query
        # binds the PID query to this generation, without timestamp/slot guesses.
        if ([string]::IsNullOrEmpty($trackerId) -or -not (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks)) { return $false }
        if (Test-ArkuzoNativeProvider) {
            return ($null -ne (Get-ArkuzoControlledAccount $trackerId $ClientId) -and (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks))
        }
        $target = Get-ArkuzoVoltRecoveryStatus -Root $PSScriptRoot -TrackerId $trackerId
        if ($null -eq (Get-ArkuzoControlledAccount $trackerId $ClientId)) { return $false }
        return ($target.safeToRecycle -is [bool] -and $target.safeToRecycle -and
            $target.targetReady -is [bool] -and $target.targetReady -and $target.matchedAccountCount -eq 1 -and
            (Test-ArkuzoClientIdentity $Watcher $ClientId $StartTicks))
    } catch { return $false } # Never expose command lines, tickets, or account state in errors.
}
function Get-ArkuzoRestorePolicy($Config) {
    $p = @{ enabled=$false; restore_missing=$false; restore_wait_sec=90; relaunch_delay_sec=30; retry_base_sec=90; retry_max_sec=900; retry_max_per_hour=6; ready_stable_sec=30; excluded_account_ids=@()
        abandon_after_retries=8; abandon_after_sec=5400; quarantine_sec=1800 }
    if ($null -ne $Config) { foreach ($k in @($p.Keys)) { if ($null -ne $Config.$k) { $p[$k]=$Config.$k } } }
    foreach ($b in @('enabled','restore_missing')) { if ($p[$b] -isnot [bool]) { throw "recovery.$b must be a JSON boolean" } }
    $ranges=@{ restore_wait_sec=@(90,900); relaunch_delay_sec=@(30,120); retry_base_sec=@(90,900); retry_max_sec=@(180,3600); retry_max_per_hour=@(1,500); ready_stable_sec=@(30,300)
        abandon_after_retries=@(1,100); abandon_after_sec=@(900,86400); quarantine_sec=@(0,86400) }
    foreach ($k in $ranges.Keys) {
        $v=[double]$p[$k]
        if ([double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -lt $ranges[$k][0] -or $v -gt $ranges[$k][1] -or [math]::Floor($v) -ne $v) { throw "Invalid recovery setting: $k" }
    }
    if ($p.retry_max_sec -lt $p.retry_base_sec) { throw 'Retry maximum must cover base delay' }
    foreach ($id in @($p.excluded_account_ids)) { if ($id -notmatch '\A[0-9a-fA-F-]{36}\z') { throw 'Invalid excluded account identifier' } }
    return $p
}
function Get-ArkuzoProviderSetting($Config) {
    $value = $null
    if ($null -ne $Config -and $null -ne $Config.accounts) { $value = [string]$Config.accounts.provider }
    if ($value -cin @('auto', 'arkuzo', 'volt')) { return $value }
    return 'auto'
}
function Get-ArkuzoRetryDelay([int]$Attempt, $Policy) {
    return [int][math]::Min([double]$Policy.retry_max_sec, [double]$Policy.retry_base_sec * [math]::Pow(2,[math]::Min(20,[math]::Max(0,[int]($Attempt-1)))))
}
function ConvertTo-ArkuzoMemoryPriorityValue([string]$Name) {
    # Windows MEMORY_PRIORITY_* values. Lower priority pages are repurposed from
    # the standby list first under pressure; this neither caps nor frees memory.
    switch -Exact ($Name) {
        'VeryLow' { return [uint32]1 }
        'Low' { return [uint32]2 }
        'Medium' { return [uint32]3 }
        'BelowNormal' { return [uint32]4 }
        'Normal' { return [uint32]5 }
    }
    throw "Invalid memory priority: $Name"
}
function Get-ArkuzoTrimPlan($SystemMemory, [double]$TotalPhysicalMB, [int]$IntervalSec, [bool]$Adaptive, [double]$PressureAvailablePercent) {
    # Shorten the per-client interval only while physical RAM is scarce. The soft
    # target, per-client warmup and global spacing still apply; never below 15s.
    $plan = [pscustomobject]@{ IntervalSec = $IntervalSec; Pressure = $false; AvailablePercent = $null }
    if ($null -eq $SystemMemory -or $TotalPhysicalMB -le 0) { return $plan }
    $available = [double]$SystemMemory.availablePhysicalMB
    if ([double]::IsNaN($available) -or [double]::IsInfinity($available) -or $available -lt 0) { return $plan }
    $plan.AvailablePercent = [math]::Round([math]::Min([double]100, [double](100 * $available / $TotalPhysicalMB)), 1)
    if ($Adaptive -and $plan.AvailablePercent -lt $PressureAvailablePercent) {
        $plan.Pressure = $true
        $plan.IntervalSec = [int][math]::Min([double]$IntervalSec, [math]::Max([double]15, [math]::Ceiling($IntervalSec / 3)))
    }
    return $plan
}
function Test-ArkuzoPendingAbandon($Entry, [datetime]$NowUtc, $Policy) {
    # A recovery that keeps failing must not hold the shared handoff gate and
    # recycle budget forever. Returns the abandon reason, or $null to keep waiting.
    # An absent limit (an unvalidated or legacy policy object) disables that rule.
    if ($null -eq $Entry -or $null -eq $Policy) { return $null }
    if ([int]$Policy.abandon_after_retries -gt 0 -and [int]$Entry.retryCount -ge [int]$Policy.abandon_after_retries) { return 'RETRY_LIMIT' }
    if ([double]$Policy.abandon_after_sec -le 0) { return $null }
    try { $created = ([datetime]$Entry.createdUtc).ToUniversalTime() } catch { return $null }
    if (($NowUtc.ToUniversalTime() - $created).TotalSeconds -ge [double]$Policy.abandon_after_sec) { return 'AGE_LIMIT' }
    return $null
}
function Test-ArkuzoAccountQuarantined([string]$AccountId, [datetime]$NowUtc) {
    if (-not $AccountId -or $null -eq $script:quarantinedAccounts -or -not $script:quarantinedAccounts.ContainsKey($AccountId)) { return $false }
    try { $until = ([datetime]$script:quarantinedAccounts[$AccountId].untilUtc).ToUniversalTime() } catch { $until = [datetime]::MinValue }
    # The Arkuzo provider never parks an account; quarantine rows only apply to Volt.
    if ($NowUtc.ToUniversalTime() -lt $until) { return -not (Test-ArkuzoNativeProvider) }
    $script:quarantinedAccounts.Remove($AccountId)
    return $false
}
function Get-ArkuzoLiveResourceSettings($Settings, [hashtable]$Current) {
    # Validates the hot-reloadable resource settings. A hard working-set limit
    # still requires a restart. Invalid input throws; the caller keeps $Current.
    $next = @{} + $Current
    if ($null -eq $Settings) { return $next }
    $numbers = @{ target_ram_mb=@('MaxRamMB',128,32768); trim_every_sec=@('TrimEverySec',1,120); cores_per_instance=@('CoresPerInstance',1,64); pressure_trim_available_percent=@('PressureTrimAvailablePercent',5,60); poll_ms=@('PollMs',250,10000) }
    foreach ($key in $numbers.Keys) {
        $value = $Settings.$key
        if ($null -eq $value) { continue }
        if ($value -is [bool] -or $value -is [string] -or $value -isnot [ValueType]) { throw "settings.$key must be a number" }
        $n = [double]$value
        if ([double]::IsNaN($n) -or $n -lt $numbers[$key][1] -or $n -gt $numbers[$key][2] -or [math]::Floor($n) -ne $n) { throw "settings.$key is out of range" }
        $next[$numbers[$key][0]] = [int]$n
    }
    foreach ($pair in @(@('trim_enabled','EnableTrimming'), @('adaptive_trim','AdaptiveTrim'), @('minimize_on_launch','Minimize'))) {
        $value = $Settings.($pair[0])
        if ($null -eq $value) { continue }
        if ($value -isnot [bool]) { throw "settings.$($pair[0]) must be a JSON boolean" }
        $next[$pair[1]] = $value
    }
    if ($null -ne $Settings.priority) {
        if ([string]$Settings.priority -cnotin @('Idle','BelowNormal','Normal')) { throw 'settings.priority is invalid' }
        $next.Priority = [string]$Settings.priority
    }
    if ($null -ne $Settings.memory_priority) {
        ConvertTo-ArkuzoMemoryPriorityValue ([string]$Settings.memory_priority) | Out-Null
        $next.MemoryPriority = [string]$Settings.memory_priority
    }
    return $next
}
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
# Backups of the vault (docs/accounts.md): accounts.json.bak holds the content before the last
# save, vault-backups\accounts-<UTC yyyyMMdd-HH>.json one copy per hour. Both writers keep them.
$script:VaultSnapshotKeep = 72
$script:VaultSnapshotDays = 7
$script:vaultFallbackSource = $null # The backup read while accounts.json is damaged, else $null.
function ConvertFrom-ArkuzoVaultText([string]$Text) {
    # The vault as an object, or $null when the text is not a vault: empty, all NUL (a crash
    # before the data reached the disk), truncated, not JSON, or not an object with an accounts list.
    if ($null -eq $Text -or [string]::IsNullOrWhiteSpace($Text.Trim([char]0, [char]0xFEFF))) { return $null }
    try { $value = $Text.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { return $null }
    if ($null -eq $value -or $value -is [array] -or $value.GetType().FullName -cne 'System.Management.Automation.PSCustomObject') { return $null }
    if (@($value.PSObject.Properties.Name) -notcontains 'accounts' -or $value.accounts -isnot [array]) { return $null }
    return $value
}
function Get-ArkuzoVaultSnapshotDirectory { return (Join-Path $DataDirectory 'vault-backups') }
function Get-ArkuzoVaultBackupPaths {
    # Where a damaged vault is read from, best first: accounts.json.bak, then the snapshots, newest first.
    $paths = @((Get-ArkuzoVaultPath) + '.bak')
    $dir = Get-ArkuzoVaultSnapshotDirectory
    if ([IO.Directory]::Exists($dir)) {
        $paths += @([IO.Directory]::GetFiles($dir, 'accounts-*.json') | Where-Object { [IO.Path]::GetFileName($_) -cmatch '\Aaccounts-\d{8}-\d{2}\.json\z' } |
            Sort-Object { [IO.Path]::GetFileName($_) } -Descending)
    }
    return $paths
}
function Get-ArkuzoVaultSnapshotsToRemove([string[]]$Names, [datetime]$NowUtc) {
    # Pure. Keeps the newest $VaultSnapshotKeep snapshots (names sort by time) and, beyond those,
    # the newest of each UTC day of the last $VaultSnapshotDays days. The same rule as the
    # Control Center's vault_snapshots_to_remove. Names that are not snapshots are never touched.
    $valid = @($Names | Where-Object { $_ -cmatch '\Aaccounts-\d{8}-\d{2}\.json\z' } | Sort-Object -Descending)
    $keep = if ([int]$script:VaultSnapshotKeep -gt 0) { [int]$script:VaultSnapshotKeep } else { 72 }
    $days = if ([int]$script:VaultSnapshotDays -gt 0) { [double]$script:VaultSnapshotDays } else { 7.0 }
    $keepDays = @{}
    $remove = @()
    for ($i = 0; $i -lt $valid.Count; $i++) {
        $day = $valid[$i].Substring(9, 8)
        if ($i -lt $keep) { $keepDays[$day] = $true; continue }
        $date = [datetime]::MinValue
        $recent = [datetime]::TryParseExact($day, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$date) -and
            ($NowUtc.Date - $date.Date).TotalDays -le $days
        if ($recent -and -not $keepDays.ContainsKey($day)) { $keepDays[$day] = $true; continue }
        $remove += $valid[$i]
    }
    return ,$remove
}
function Save-ArkuzoVaultSnapshot([byte[]]$Bytes, [datetime]$NowUtc = [datetime]::UtcNow) {
    # At most one snapshot per UTC hour: the first save of the hour writes it. Returns $true when written.
    $dir = Get-ArkuzoVaultSnapshotDirectory
    [void][IO.Directory]::CreateDirectory($dir)
    $file = Join-Path $dir ('accounts-' + $NowUtc.ToString('yyyyMMdd-HH', [Globalization.CultureInfo]::InvariantCulture) + '.json')
    if ([IO.File]::Exists($file)) { return $false }
    Save-ArkuzoAtomicBytes $file $Bytes
    foreach ($name in (Get-ArkuzoVaultSnapshotsToRemove @([IO.Directory]::GetFiles($dir, 'accounts-*.json') | ForEach-Object { [IO.Path]::GetFileName($_) }) $NowUtc)) {
        try { [IO.File]::Delete((Join-Path $dir $name)) } catch { }
    }
    return $true
}
function Read-ArkuzoVaultFile([switch]$Strict) {
    # The vault, or $null when there is none yet. A damaged accounts.json is never written by
    # the engine: -Strict (every read-modify-write) throws. Other reads fall back, read-only, to
    # the newest valid backup until the Control Center restores the file; launches wait meanwhile
    # (a rotated cookie could not be saved). Logged once per backup used.
    $path = Get-ArkuzoVaultPath
    if (-not [IO.File]::Exists($path)) { $script:vaultFallbackSource = $null; return $null }
    $vault = ConvertFrom-ArkuzoVaultText ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
    if ($null -ne $vault) { $script:vaultFallbackSource = $null; return $vault }
    if ($Strict) { throw 'Account vault is damaged' }
    foreach ($candidate in @(Get-ArkuzoVaultBackupPaths)) {
        $backup = $null
        try { if ([IO.File]::Exists($candidate)) { $backup = ConvertFrom-ArkuzoVaultText ([IO.File]::ReadAllText($candidate, [Text.Encoding]::UTF8)) } } catch { $backup = $null }
        if ($null -eq $backup) { continue }
        if ($script:vaultFallbackSource -cne $candidate) {
            $script:vaultFallbackSource = $candidate
            $ageMin = try { [math]::Round(([datetime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($candidate)).TotalMinutes) } catch { $null }
            Write-Diagnostic 'VAULT_READ_FROM_BACKUP' @{ backup = [IO.Path]::GetFileName($candidate); ageMinutes = $ageMin
                note = 'data/accounts.json is damaged; the engine reads this backup (read-only) and launches wait until the Control Center restores the file.' }
        }
        Warn-Throttled 'vault-damaged' 'data/accounts.json is damaged: reading a backup; launches wait until the Control Center restores it.'
        return $backup
    }
    if ($script:vaultFallbackSource -cne '-') {
        $script:vaultFallbackSource = '-'
        Write-Diagnostic 'VAULT_READ_FROM_BACKUP' @{ backup = $null; note = 'data/accounts.json is damaged and no valid backup was found; nothing is launched. Start a new account list on the Accounts page.' }
    }
    throw 'Account vault is damaged and no valid backup was found'
}
function Save-ArkuzoVaultFile($Vault) {
    # Caller holds the vault lock and read the vault with -Strict. The content replaced is kept
    # as accounts.json.bak (only when it is a valid vault), then the new vault is written; both
    # flushed to the disk. The first save of each hour also writes a snapshot.
    $path = Get-ArkuzoVaultPath
    try {
        if ([IO.File]::Exists($path)) {
            $current = [IO.File]::ReadAllBytes($path)
            if ($null -ne (ConvertFrom-ArkuzoVaultText ([Text.Encoding]::UTF8.GetString($current)))) { Save-ArkuzoAtomicBytes ($path + '.bak') $current }
        }
    } catch { Warn-Throttled 'vault-backup' 'accounts.json.bak could not be written; the account list itself is saved.' }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Vault | ConvertTo-Json -Depth 12))
    Save-ArkuzoAtomicBytes $path $bytes
    try { [void](Save-ArkuzoVaultSnapshot $bytes) } catch { }
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
        $vault = Read-ArkuzoVaultFile -Strict # Never a backup: a damaged vault is not written.
        if ($null -eq $vault) { return $false }
        $rows = @($vault.accounts | Where-Object { [string]$_.id -eq $AccountId })
        if ($rows.Count -ne 1) { return $false }
        if ($OnlyIfCookie -and [string]$rows[0].cookie -cne $OnlyIfCookie) { return $false }
        foreach ($name in $Fields.Keys) {
            if ($rows[0].PSObject.Properties.Name -contains $name) { $rows[0].$name = $Fields[$name] }
            else { $rows[0] | Add-Member -NotePropertyName $name -NotePropertyValue $Fields[$name] }
        }
        Save-ArkuzoVaultFile $vault
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
# Dead-build guard (docs/roblox-versions.md). Clients launched on one Roblox build that close
# before they reach the game RobloxBuildFailureLimit times in a row (any accounts, each failure
# within RobloxBuildFailureWindowSec of now) mark that build as failing: launches stop using it
# (Resolve-ArkuzoRobloxPlayer). Pinned: the Auto build instead when robloxVersionFallback is on,
# otherwise launches wait for another build. Auto: the newest other build, or wait. A client of
# that build reaching the game, or another pinned selection, clears it. Not a per-account
# back-off: healthy builds relaunch at once. Memory only (an engine restart starts counting again).
# 10-11 Nov: a gutted install and two builds Roblox refused ran 16+ failed launches in a row, and
# each client dying at start was one more chance for the kernel bug behind three blue screens.
$script:RobloxBuildFailureLimit = 4
$script:RobloxBuildFailureWindowSec = 300
$script:robloxBuildGuard = @{ selection = $null; builds = @{} }
$script:nativeLaunchBuilds = @{}    # accountId -> build version its latest launch started (when known)
function Sync-ArkuzoRobloxBuildGuardSelection([string]$Selection) {
    # The user picked another build (or Auto): every failing mark is cleared.
    if ($null -eq $script:robloxBuildGuard) { $script:robloxBuildGuard = @{ selection = $null; builds = @{} } }
    if ($script:robloxBuildGuard.selection -ceq $Selection) { return }
    if ($null -eq $script:robloxBuildGuard.selection) { $script:robloxBuildGuard.selection = $Selection; return } # First look: nothing changed.
    $had = @(Get-ArkuzoFailingRobloxBuilds)
    $script:robloxBuildGuard = @{ selection = $Selection; builds = @{} }
    if ($had.Count -gt 0) { Write-Diagnostic 'ROBLOX_BUILD_GUARD_RESET' @{ builds = $had; selection = $Selection; note = 'Another Roblox build was chosen: launches are tried again.' } }
}
function Get-ArkuzoFailingRobloxBuilds {
    if ($null -eq $script:robloxBuildGuard) { return @() }
    return @($script:robloxBuildGuard.builds.Keys | Where-Object { $script:robloxBuildGuard.builds[$_].failing } | Sort-Object)
}
function Register-ArkuzoRobloxBuildFailure([string]$Version, [string]$AccountId, [datetime]$NowUtc = [datetime]::UtcNow) {
    # One client of $Version closed before it reached the game. Returns $true when this marks the build failing.
    if ([string]::IsNullOrEmpty($Version)) { return $false }
    if ($null -eq $script:robloxBuildGuard) { $script:robloxBuildGuard = @{ selection = $null; builds = @{} } }
    $builds = $script:robloxBuildGuard.builds
    if (-not $builds.ContainsKey($Version)) { $builds[$Version] = @{ failures = @(); accounts = @{}; failing = $false; sinceUtc = $null } }
    $entry = $builds[$Version]
    $window = if ([double]$script:RobloxBuildFailureWindowSec -gt 0) { [double]$script:RobloxBuildFailureWindowSec } else { 300.0 }
    $limit = if ([int]$script:RobloxBuildFailureLimit -gt 0) { [int]$script:RobloxBuildFailureLimit } else { 4 }
    $entry.failures = @(@($entry.failures | Where-Object { ($NowUtc - $_).TotalSeconds -le $window }) + @($NowUtc))
    if ($AccountId) { $entry.accounts[$AccountId] = $true }
    if ($entry.failing -or $entry.failures.Count -lt $limit) { return $false }
    $entry.failing = $true; $entry.sinceUtc = $NowUtc
    $pin = [string](Get-ArkuzoVaultSetting $script:nativeVault 'robloxVersion' 'auto')
    $fallback = $pin -ceq 'auto' -or (Get-ArkuzoVaultSetting $script:nativeVault 'robloxVersionFallback' $false) -eq $true
    Write-Diagnostic 'ROBLOX_BUILD_FAILING' @{ version = $Version; failures = $entry.failures.Count; accounts = $entry.accounts.Count; windowSec = $window; pinned = ($pin -ceq $Version); fallback = [bool]$fallback
        note = $(if ($fallback) { 'Clients of this build keep closing at start; launches use another installed build.' } else { 'Clients of this build keep closing at start; launches wait until another build is chosen on the Roblox tab or fall back is turned on.' }) }
    Warn-Throttled 'roblox-build-failing' ('Roblox build ' + $Version + ' keeps closing at start - it may be outdated or refused by Roblox.')
    $script:robloxVersionCheckedUtc = $null # Show it on the Roblox tab with the next status read.
    return $true
}
function Register-ArkuzoRobloxBuildSuccess([string]$Version) {
    # A client of $Version reached the game: the build works, the count starts again.
    if ([string]::IsNullOrEmpty($Version) -or $null -eq $script:robloxBuildGuard -or -not $script:robloxBuildGuard.builds.ContainsKey($Version)) { return }
    $wasFailing = [bool]$script:robloxBuildGuard.builds[$Version].failing
    $script:robloxBuildGuard.builds.Remove($Version)
    if ($wasFailing) {
        Write-Diagnostic 'ROBLOX_BUILD_GUARD_RESET' @{ builds = @($Version); note = 'A client of this build reached the game: launches use it again.' }
        $script:robloxVersionCheckedUtc = $null
    }
}
function Get-ArkuzoRobloxBuildProblem([string]$Version) {
    return 'Roblox build ' + $Version + ' keeps closing at start ' + [char]0x2014 + ' it may be outdated or refused by Roblox'
}

function Get-ArkuzoRobloxPlayerPath($Clients, $Vault = $null, [string[]]$Exclude = @()) {
    # Auto: prefer the build that is already running; otherwise the newest complete installed one.
    # Builds in $Exclude (failing, see the dead-build guard) are never chosen.
    $ok = { param($exe) @($Exclude) -cnotcontains [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$exe)) }
    $running = @($Clients | Where-Object { $_.path -and (Test-Path -LiteralPath $_.path) -and (& $ok $_.path) } | ForEach-Object { $_.path } | Select-Object -Unique)
    if ($running.Count -gt 0) { return (Select-ArkuzoNewestRobloxBuild $running) }
    return (Select-ArkuzoNewestRobloxBuild @(Get-ArkuzoRobloxInstalls (Get-ArkuzoManagedVersionsRoot $Vault) | Where-Object { & $ok $_ }))
}
function Get-ArkuzoProtocolPlayerPath([string]$Key = 'Registry::HKEY_CLASSES_ROOT\roblox-player\shell\open\command') {
    # The exe a roblox-player: link starts (HKCU wins over HKLM in HKEY_CLASSES_ROOT). The Control
    # Center's Roblox tab can point it at the pinned build ("Roblox links use this build").
    try {
        $command = [string](Get-Item -LiteralPath $Key -ErrorAction Stop).GetValue('')
        if ($command -match '\A\s*"([^"]+)"') { return $Matches[1] }
        if ($command -match '\A\s*(\S+)') { return $Matches[1] }
    } catch { }
    return $null
}
function Resolve-ArkuzoRobloxPlayer($Clients, $Vault, [string]$Method = 'direct', [string]$ProtocolKey = 'Registry::HKEY_CLASSES_ROOT\roblox-player\shell\open\command') {
    # Which player a launch starts (docs/roblox-versions.md). Auto keeps the launch method and the
    # running-build preference. A pinned build (vault robloxVersion) launches with the protocol
    # method only while roblox-player: starts exactly that build (the Roblox tab's "Roblox links use
    # this build"); otherwise it launches directly, because Roblox's own launcher would update Roblox
    # and ignore the pin.
    # A pinned build that is missing or incomplete is never replaced silently: path stays $null with
    # a problem, unless robloxVersionFallback allows the Auto choice.
    $pin = [string](Get-ArkuzoVaultSetting $Vault 'robloxVersion' 'auto')
    if ($pin -cne 'auto' -and $pin -cnotmatch '\Aversion-[0-9a-f]{16}\z') { $pin = 'auto' }
    $allowFallback = (Get-ArkuzoVaultSetting $Vault 'robloxVersionFallback' $false) -eq $true
    $managed = Get-ArkuzoManagedVersionsRoot $Vault
    Sync-ArkuzoRobloxBuildGuardSelection $pin
    $failing = @(Get-ArkuzoFailingRobloxBuilds)
    $r = @{ mode = 'auto'; pinned = $null; path = $null; method = $(if ($Method -ceq 'protocol') { 'protocol' } else { 'direct' }); problem = $null; fallback = $false; managedRoot = $managed; blocked = $false }
    if ($pin -ceq 'auto') {
        if ($r.method -ceq 'direct') {
            $r.path = Get-ArkuzoRobloxPlayerPath $Clients $Vault $failing
            if ($failing.Count -gt 0) {
                # Auto skips a failing build; with nothing else installed, launches wait.
                $r.problem = (Get-ArkuzoRobloxBuildProblem ($failing -join ', ')) + $(if ($r.path) { '; launching ' + [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$r.path)) + ' instead' } else { '; launches wait until another build is installed (Roblox tab)' })
                $r.blocked = -not $r.path
            }
        }
        return $r
    }
    $r.mode = 'pinned'; $r.pinned = $pin; $wantProtocol = $r.method -ceq 'protocol'; $r.method = 'direct'
    $r.path = @(Get-ArkuzoRobloxInstalls $managed | Where-Object { [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($_)) -ceq $pin -and (Test-ArkuzoRobloxBuildComplete $_) }) | Select-Object -First 1
    if ($r.path -and $failing -ccontains $pin) {
        # The pinned build keeps closing at start: the Auto build when allowed, else wait.
        $r.problem = Get-ArkuzoRobloxBuildProblem $pin
        $r.blocked = $true
        $r.path = $null
        if ($allowFallback) {
            $r.fallback = $true; $r.path = Get-ArkuzoRobloxPlayerPath $Clients $Vault $failing
            $r.problem += $(if ($r.path) { '; launching the Auto build ' + [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$r.path)) + ' instead' } else { '; no other build is installed, so launches wait' })
        } else { $r.problem += '; launches wait until another build is chosen on the Roblox tab (or "Fall back if missing" is on)' }
        return $r
    }
    if ($r.path) {
        if ($wantProtocol) {
            $handler = Get-ArkuzoProtocolPlayerPath $ProtocolKey
            if ($handler -and [string]::Equals([IO.Path]::GetFullPath($handler), [IO.Path]::GetFullPath([string]$r.path), [StringComparison]::OrdinalIgnoreCase)) { $r.method = 'protocol' }
        }
        return $r
    }
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
    $pinMissing = $Player.problem -and $Player.mode -ceq 'pinned' -and -not $Player.blocked # A failing build logs ROBLOX_BUILD_FAILING.
    if ($pinMissing -and ($null -eq $previous -or [string]$previous.problem -cne [string]$Player.problem -or [bool]$previous.fallback -ne [bool]$Player.fallback)) {
        Write-Diagnostic 'ROBLOX_VERSION_PIN_MISSING' @{ pinned = $Player.pinned; fallback = [bool]$Player.fallback; usedVersion = $version
            note = $(if ($Player.fallback) { 'The pinned build is missing; "fall back to newest" is on, so the newest installed build is launched.' } else { 'The pinned build is missing; launches wait until it is installed or Auto is chosen.' }) }
    }
    if ($Player.mode -ceq 'pinned' -and $RequestedMethod -ceq 'protocol' -and $Player.method -ceq 'direct' -and -not $script:robloxProtocolOverrideLogged) {
        $script:robloxProtocolOverrideLogged = $true
        Write-Diagnostic 'ROBLOX_VERSION_PROTOCOL_OVERRIDDEN' @{ pinned = $Player.pinned; note = 'A pinned Roblox build launches directly while roblox-player: links start another build (turn on "Roblox links use this build" on the Roblox tab): the protocol method would let Roblox''s launcher update Roblox and ignore the pin.' }
    }
}
function Get-ArkuzoRobloxVersionPreflight($Vault) {
    # Step 1 of a launch: a pinned build that is missing (and no fallback) refuses before a ticket is
    # requested, so a missing pin never spends Roblox requests every relaunch cycle. Auto: nothing to check.
    # Also refuses when the dead-build guard leaves no build to launch.
    $pin = [string](Get-ArkuzoVaultSetting $Vault 'robloxVersion' 'auto')
    if ($pin -ceq 'auto' -and @(Get-ArkuzoFailingRobloxBuilds).Count -eq 0) { return '' }
    $player = Resolve-ArkuzoRobloxPlayer @() $Vault ([string](Get-ArkuzoVaultSetting $Vault 'launchMethod' 'direct'))
    Update-ArkuzoRobloxVersionStatus $player ([string](Get-ArkuzoVaultSetting $Vault 'launchMethod' 'direct'))
    if ($player.path -or -not $player.problem) { return '' }
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
        # Roblox also writes multiple cookie records on one line, separated only by tabs.
        # Match an exact cookie-name field, never a substring inside another cookie.
        $hasLogin = $plain -cmatch '(?:^|[\t\r\n])\.ROBLOSECURITY\t'
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
    if ($null -ne $Player -and -not $Player.path -and ($Player.mode -ceq 'pinned' -or $Player.blocked)) { throw $(if ($Player.mode -ceq 'pinned') { 'Pinned Roblox build missing or failing' } else { 'No Roblox build to launch' }) } # Never Roblox's launcher instead of a pin or around a failing build.
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
        if ($script:vaultFallbackSource) { throw 'Account list is damaged: launches wait until the Control Center restores it' }
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
    if ($script:vaultFallbackSource) { return 'Account list is damaged: launches wait until the Control Center restores it' }
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
    if (-not $player.path -and ($player.mode -ceq 'pinned' -or $player.blocked)) { Warn-Throttled 'roblox-version-pin' $player.problem; return [string]$player.problem }
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
    # The build this client starts, for the dead-build guard: known for direct launches and pins.
    if ($null -eq $script:nativeLaunchBuilds) { $script:nativeLaunchBuilds = @{} }
    if ($player.path -and ($started.method -ceq 'direct' -or $player.mode -ceq 'pinned')) { $script:nativeLaunchBuilds[$AccountId] = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$player.path)) }
    else { $script:nativeLaunchBuilds.Remove($AccountId) }
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
    # Not the build's fault: the engine closed it (stalled launch), or it reached the game first.
    if (($State.Closing -or $State.EverGameReady) -and $null -ne $script:nativeLaunchBuilds) { $script:nativeLaunchBuilds.Remove($key) }
    $script:nativeLaunchExits[$key] = [datetime]::UtcNow
}

function Invoke-ArkuzoNativeRequests {
    # Launch / close buttons and Stop farm in the Control Center set request
    # stamps on accounts; carry them out here and clear them.
    if (-not (Test-ArkuzoNativeProvider) -or $MonitorOnly -or -not $ownsControllerMutex -or -not $voltControlStatus.available) { return }
    # A vault read from a backup is read-only: its request stamps may be stale (a Close carried out
    # and cleared after that copy was made would close the client again).
    if ($script:vaultFallbackSource) { return }
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

# ---------------------------------------------------------------------------
# Window arrangement for Arkuzo-launched clients (what Volt's window
# arrangement did): every client gets its own small window in an orderly grid
# on the chosen monitor. Settings live in the vault (Accounts page, Window
# layout). Windows are moved without ever being activated, so arranging never
# steals focus. Only clients that map to a vault account are touched.
# ---------------------------------------------------------------------------
$script:arrangeHandledRequestMs = 0
$script:arrangeLastSignature = ''

function Initialize-ArkuzoWindowNative {
    if ($null -ne ('Arkuzo.WindowArrangeV3' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace Arkuzo {
 public static class WindowArrangeV3 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  delegate bool MonitorProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
  delegate bool WindowProc(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc proc, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
  [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern bool EnumWindows(WindowProc proc, IntPtr data);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr hwnd, int command);
  [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
  const uint NOSIZE = 0x0001, NOMOVE = 0x0002, NOZORDER = 0x0004, NOACTIVATE = 0x0010, NOOWNERZORDER = 0x0200, ASYNC = 0x4000;

  // Windows 10/11 frames carry invisible resize borders: work with the visible edges.
  static RECT Visible(IntPtr h, RECT outer) {
   RECT v; if (DwmGetWindowAttribute(h, 9, out v, Marshal.SizeOf(typeof(RECT))) == 0 && v.Right > v.Left) return v; // DWMWA_EXTENDED_FRAME_BOUNDS
   return outer;
  }

  // Coordinates in physical pixels: the calls run per-monitor DPI aware.
  static IntPtr Aware() { try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { return IntPtr.Zero; } }
  static void Restore(IntPtr previous) { if (previous != IntPtr.Zero) { try { SetThreadDpiAwarenessContext(previous); } catch { } } }

  // Left, Top, Right, Bottom, Dpi, Primary(1/0) of every monitor's work area (without the taskbar).
  public static int[][] Monitors() {
   var previous = Aware();
   try {
    var list = new List<int[]>();
    MonitorProc proc = (m, dc, r, d) => {
     var info = new MONITORINFO(); info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
     if (GetMonitorInfo(m, ref info)) {
      uint dx = 96, dy = 96;
      try { if (GetDpiForMonitor(m, 0, out dx, out dy) != 0) dx = 96; } catch { dx = 96; }
      list.Add(new[] { info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom, (int)dx, (info.dwFlags & 1) != 0 ? 1 : 0 });
     }
     return true;
    };
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
    GC.KeepAlive(proc);
    return list.ToArray();
   } finally { Restore(previous); }
  }

  // The visible Roblox game window (class WINDOWSCLIENT) of each process.
  public static Dictionary<int, long> ClientWindows(int[] pids) {
   var wanted = new HashSet<int>(pids); var found = new Dictionary<int, long>();
   WindowProc proc = (h, d) => {
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (wanted.Contains((int)pid) && IsWindowVisible(h)) {
     var name = new StringBuilder(64); GetClassName(h, name, 64);
     if (name.ToString() == "WINDOWSCLIENT" && !found.ContainsKey((int)pid)) found[(int)pid] = h.ToInt64();
    }
    return true;
   };
   EnumWindows(proc, IntPtr.Zero);
   GC.KeepAlive(proc);
   return found;
  }

  // The window that has the keyboard focus (0 when none): it is never minimized.
  public static long Foreground() { return GetForegroundWindow().ToInt64(); }

  // Visible Left, Top, Width, Height, Minimized(1/0), Maximized(1/0).
  public static int[] Rect(long hwnd) {
   var previous = Aware();
   try { RECT o; var h = new IntPtr(hwnd); if (!GetWindowRect(h, out o)) return null; var r = Visible(h, o); return new[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, IsIconic(h) ? 1 : 0, IsZoomed(h) ? 1 : 0 }; }
   finally { Restore(previous); }
  }

  // visibility: normal (z-order untouched), background (kept behind other windows), minimized.
  // Never activates a window; asynchronous, so a frozen client cannot stall the saver.
  public static bool Place(long hwnd, int x, int y, int w, int h, string visibility) {
   var previous = Aware();
   try {
    var handle = new IntPtr(hwnd);
    // Roblox starts maximized; a maximized (or minimized) window is restored first, without focus.
    if (IsIconic(handle) || IsZoomed(handle)) ShowWindowAsync(handle, 4); // SW_SHOWNOACTIVATE
    bool background = visibility == "background";
    RECT o; int l = 0, t = 0, r = 0, b = 0;
    if (GetWindowRect(handle, out o)) { var v = Visible(handle, o); l = v.Left - o.Left; t = v.Top - o.Top; r = o.Right - v.Right; b = o.Bottom - v.Bottom; }
    bool ok = SetWindowPos(handle, background ? new IntPtr(1) : IntPtr.Zero, x - l, y - t, w + l + r, h + t + b, NOACTIVATE | NOOWNERZORDER | ASYNC | (background ? 0 : NOZORDER));
    if (visibility == "minimized") ShowWindowAsync(handle, 7); // SW_SHOWMINNOACTIVE
    return ok;
   } finally { Restore(previous); }
  }

  // Overlapping layouts: each later window directly above the one before it, so
  // every window keeps its corner in view. background: the whole stack at the bottom.
  public static void Stack(long[] ordered, bool background) {
   if (ordered == null || ordered.Length == 0) return;
   const uint FLAGS = NOMOVE | NOSIZE | NOACTIVATE | NOOWNERZORDER | ASYNC;
   if (background) { for (int i = ordered.Length - 1; i >= 0; i--) SetWindowPos(new IntPtr(ordered[i]), new IntPtr(1), 0, 0, 0, 0, FLAGS); return; }
   for (int i = ordered.Length - 2; i >= 0; i--) SetWindowPos(new IntPtr(ordered[i]), new IntPtr(ordered[i + 1]), 0, 0, 0, 0, FLAGS);
  }
 }
}
'@ -ErrorAction Stop
}

function Get-ArkuzoArrangeSettings($Vault) {
    $enum = { param($name, $default, $allowed) $v = [string](Get-ArkuzoVaultSetting $Vault $name $default); if ($allowed -ccontains $v) { $v } else { $default } }
    return @{
        enabled    = ((Get-ArkuzoVaultSetting $Vault 'arrangeWindows' $true) -eq $true)
        layout     = (& $enum 'arrangeLayout' 'auto' @('auto', 'grid', 'cascade'))
        perRow     = [int](Get-ArkuzoVaultSetting $Vault 'arrangePerRow' 2 1 12)
        width      = [int](Get-ArkuzoVaultSetting $Vault 'arrangeWidth' 800 160 1920)
        height     = [int](Get-ArkuzoVaultSetting $Vault 'arrangeHeight' 622 120 1440)
        gap        = [int](Get-ArkuzoVaultSetting $Vault 'arrangeGap' 4 0 40)
        corner     = (& $enum 'arrangeCorner' 'top-left' @('top-left', 'top-right', 'bottom-left', 'bottom-right'))
        monitor    = [int](Get-ArkuzoVaultSetting $Vault 'arrangeMonitor' 0 0 8)
        order      = (& $enum 'arrangeOrder' 'fixed' @('fixed', 'name', 'launch'))
        mode       = (& $enum 'arrangeMode' 'keep' @('keep', 'once'))
        visibility = (& $enum 'arrangeVisibility' 'normal' @('normal', 'background', 'minimized'))
        overflow   = (& $enum 'arrangeOverflow' 'minimize' @('minimize', 'overlap'))
        requestMs  = [long](Get-ArkuzoVaultSetting $Vault 'arrangeRequestedAtMs' 0 0 9007199254740991)
    }
}

# Roblox never lets its window get smaller than 800 x 600 (client area), 800 x 622
# with the title bar at 100% scaling. On 9 Nov every smaller size was ignored, so
# a grid of 384 px cells left 800 px windows piled up and running off the screen.
# A size seen on screen that is still larger is learned per DPI.
$script:arrangeMinWindow = @{}
function Get-ArkuzoRobloxMinWindow([int]$Dpi) {
    $scale = [math]::Max(1.0, [double]$Dpi / 96.0)
    $w = [int][math]::Round(800 * $scale); $h = [int][math]::Round(622 * $scale)
    $learned = $script:arrangeMinWindow[[string]$Dpi]
    if ($null -ne $learned) { $w = [math]::Max([int]$w, [int]$learned[0]); $h = [math]::Max([int]$h, [int]$learned[1]) }
    return ,@([int]$w, [int]$h)
}

function Get-ArkuzoWindowSlots([int]$Count, [int[]]$Area, $Settings, [int[]]$MinSize = $null) {
    # Area: Left, Top, Right, Bottom, Dpi (physical pixels). Sizes are logical
    # pixels, scaled to the monitor, and never below Roblox's minimum window.
    # Every window stays fully inside the work area. Each slot is x, y, width,
    # height; a fifth element 1 marks a minimized slot.
    # Overflow "minimize" (the default): as many windows as fit side by side are
    # tiled without overlap, the rest are minimized (placed on a tile first, so a
    # restored one appears there). Roblox can't be made smaller than its minimum:
    # on 11 Nov every way of forcing it (SWP_NOSENDCHANGING, also framed or with
    # only the height below) made Roblox resize its own swap chain to 65535 px
    # high and crash within 3 s; MoveWindow, SetWindowPos and removing the resize
    # frame are all clamped to 800 x 600 (docs/accounts.md).
    # Overflow "overlap": the windows overlap evenly; later windows go on top
    # (see Stack), so each one keeps its corner in view.
    if ($Count -le 0) { return ,@() }
    $scale = [math]::Max(1.0, [double]$Area[4] / 96.0)
    if ($null -eq $MinSize -or $MinSize.Count -lt 2) { $MinSize = Get-ArkuzoRobloxMinWindow $Area[4] }
    $minW = [int]$MinSize[0]; $minH = [int]$MinSize[1]
    $gap = [int][math]::Round($Settings.gap * $scale)
    $areaW = $Area[2] - $Area[0]; $areaH = $Area[3] - $Area[1]
    $right = $Settings.corner -like '*right'; $bottom = $Settings.corner -like 'bottom*'
    $minimizeRest = $Settings.overflow -ceq 'minimize'
    # Even spacing that keeps the last window on screen, never wider than size + gap.
    $stride = { param($size, $space, $n) if ($n -le 1) { 0 } else { [int][math]::Floor([math]::Max([double]0, [math]::Min([double]($size + $gap), [double]($space - $size) / ($n - 1)))) } }
    # How many windows of this size fit side by side and above each other without overlap.
    $capacity = { param($w, $h) [math]::Max(1, [int][math]::Floor([double]($areaW + $gap) / ($w + $gap))) * [math]::Max(1, [int][math]::Floor([double]($areaH + $gap) / ($h + $gap))) }
    $slots = @()
    if ($Settings.layout -ceq 'cascade') {
        $w = [math]::Max([int][math]::Round($Settings.width * $scale), [int]$minW); $h = [math]::Max([int][math]::Round($Settings.height * $scale), [int]$minH)
        $step = [int][math]::Round(32 * $scale)
        $fit = [math]::Max(1, [int][math]::Floor([double][math]::Max(0, [math]::Min([int]($areaW - $w), [int]($areaH - $h))) / $step) + 1)
        for ($i = 0; $i -lt $Count; $i++) {
            $d = ($i % $fit) * $step
            $slots += ,@([int]$(if ($right) { $Area[2] - $d - $w } else { $Area[0] + $d }), [int]$(if ($bottom) { $Area[3] - $d - $h } else { $Area[1] + $d }), [int]$w, [int]$h)
        }
        return ,$slots
    }
    $shown = $Count
    if ($Settings.layout -ceq 'auto') {
        # Side by side, as large as fits, in Roblox's own shape.
        $aspect = [double]$minW / [double]$minH
        $fitBest = { param($n) $b = 0.0; $bc = 1
            for ($c = 1; $c -le $n; $c++) {
                $r = [int][math]::Ceiling($n / $c)
                $fitW = [math]::Min([double]($areaW - $gap * ($c - 1)) / $c, ([double]($areaH - $gap * ($r - 1)) / $r) * $aspect)
                if ($fitW -gt $b) { $b = $fitW; $bc = $c }
            }
            ,@($b, $bc) }
        $fb = & $fitBest $Count; $best = $fb[0]; $cols = $fb[1]
        if ($best -lt $minW -and $minimizeRest) {
            # Too many for side by side: tile as many as fit, as large as they fit, minimize the rest.
            $shown = [math]::Min([int]$Count, [int](& $capacity $minW $minH))
            $fb = & $fitBest $shown; $best = $fb[0]; $cols = $fb[1]
        }
        if ($best -ge $minW) {
            $w = [int][math]::Floor($best); $h = [int][math]::Floor($w / $aspect)
        } elseif ($minimizeRest) {
            # The screen is smaller than one Roblox window.
            $w = $minW; $h = $minH; $cols = 1
        } else {
            # Too many for side by side: the smallest windows Roblox allows, spread so the
            # part of each that stays visible is as large (and as even) as possible.
            $w = $minW; $h = $minH; $bestScore = -1.0; $bestArea = -1.0
            for ($c = 1; $c -le $Count; $c++) {
                $r = [int][math]::Ceiling($Count / $c)
                $visX = if ($c -gt 1) { [math]::Min([int]$w, [int](& $stride $w $areaW $c)) } else { $w }
                $visY = if ($r -gt 1) { [math]::Min([int]$h, [int](& $stride $h $areaH $r)) } else { $h }
                $score = [math]::Min([double]$visX, [double]$visY * $aspect)
                if ($score -gt $bestScore -or ($score -eq $bestScore -and $visX * $visY -gt $bestArea)) { $bestScore = $score; $bestArea = $visX * $visY; $cols = $c }
            }
        }
    } else {
        $w = [math]::Max([int][math]::Round($Settings.width * $scale), [int]$minW); $h = [math]::Max([int][math]::Round($Settings.height * $scale), [int]$minH)
        $cols = [math]::Max(1, [math]::Min([int]$Settings.perRow, [int]$Count))
        if ($minimizeRest) {
            $cols = [math]::Max(1, [math]::Min([int]$cols, [int][math]::Floor([double]($areaW + $gap) / ($w + $gap))))
            $shown = [math]::Min([int]$Count, [int]($cols * [math]::Max(1, [int][math]::Floor([double]($areaH + $gap) / ($h + $gap)))))
        }
    }
    $rows = [int][math]::Ceiling($shown / $cols)
    $sx = & $stride $w $areaW $cols; $sy = & $stride $h $areaH $rows
    for ($i = 0; $i -lt $shown; $i++) {
        $dx = ($i % $cols) * $sx; $dy = [int][math]::Floor($i / $cols) * $sy
        $slots += ,@([int]$(if ($right) { $Area[2] - $dx - $w } else { $Area[0] + $dx }), [int]$(if ($bottom) { $Area[3] - $dy - $h } else { $Area[1] + $dy }), [int]$w, [int]$h)
    }
    for ($i = $shown; $i -lt $Count; $i++) { $t = $slots[$i % $shown]; $slots += ,@([int]$t[0], [int]$t[1], [int]$t[2], [int]$t[3], 1) }
    return ,$slots
}

function Test-ArkuzoSlotMinimized($Slot) { return (@($Slot).Count -ge 5 -and [int]$Slot[4] -eq 1) }

function Test-ArkuzoSlotsOverlap($Slots) {
    # Minimized slots take no room on screen.
    $list = @(@($Slots) | Where-Object { -not (Test-ArkuzoSlotMinimized $_) })
    for ($i = 0; $i -lt $list.Count; $i++) {
        for ($j = $i + 1; $j -lt $list.Count; $j++) {
            $a = $list[$i]; $b = $list[$j]
            if ($a[0] -lt $b[0] + $b[2] -and $b[0] -lt $a[0] + $a[2] -and $a[1] -lt $b[1] + $b[3] -and $b[1] -lt $a[1] + $a[3]) { return $true }
        }
    }
    return $false
}

function Get-ArkuzoArrangeTargets($Clients, $Accounts, $Settings) {
    # Clients: accountId, processId, startTicks. Returns accountId -> slot index.
    $ids = @{}
    if ($Settings.order -ceq 'fixed') {
        # Every account the farm keeps in game (or that is running) has its own slot,
        # so windows don't move when another account closes or relaunches.
        $running = @($Clients | ForEach-Object { [string]$_.accountId })
        $farm = @($Accounts | Where-Object { $running -contains [string]$_.accountId -or ($_.autoRelaunch -eq $true -and $_.cookieAlive -eq $true) })
        $i = 0
        foreach ($a in @($farm | Sort-Object { ([string]$_.displayName).ToLowerInvariant() }, { [string]$_.accountId })) { $ids[[string]$a.accountId] = $i; $i++ }
        return $ids
    }
    $sorted = if ($Settings.order -ceq 'launch') { @($Clients | Sort-Object { [long]$_.startTicks }) }
              else { @($Clients | Sort-Object { ([string]$_.name).ToLowerInvariant() }, { [string]$_.accountId }) }
    $i = 0
    foreach ($c in $sorted) { $ids[[string]$c.accountId] = $i; $i++ }
    return $ids
}

function Test-ArkuzoWindowInPlace($Now, $Slot) {
    # Now: Rect (left, top, width, height, minimized, maximized). 2 px of slack.
    if ($null -eq $Now -or $Now[4] -eq 1 -or $Now[5] -eq 1) { return $false }
    for ($k = 0; $k -lt 4; $k++) { if ([math]::Abs([int]$Now[$k] - [int]$Slot[$k]) -gt 2) { return $false } }
    return $true
}

function Update-ArkuzoWindowArrangement {
    if (-not (Test-ArkuzoNativeProvider) -or $MonitorOnly -or -not $ownsControllerMutex -or -not $voltControlStatus.available) { return }
    # Arranging windows is cosmetic: nothing in it may ever stop the saver.
    try {
        $settings = Get-ArkuzoArrangeSettings $script:nativeVault
        $forced = $settings.requestMs -gt $script:arrangeHandledRequestMs
        if ($forced) { $script:arrangeHandledRequestMs = $settings.requestMs }
        if (-not $settings.enabled -and -not $forced) { return }
        Initialize-ArkuzoWindowNative
        $clients = @()
        foreach ($state in @($tracked.Values)) {
            if ($null -eq $state.Watcher -or [string]::IsNullOrWhiteSpace([string]$state.TrackerId)) { continue }
            $acct = @($voltControlStatus.accounts | Where-Object { $_.trackerId -ceq [string]$state.TrackerId })
            if ($acct.Count -ne 1) { continue } # Only Arkuzo's own accounts.
            $clients += [pscustomobject]@{ accountId = [string]$acct[0].accountId; name = [string]$acct[0].displayName; processId = [int]$state.Watcher.Id; startTicks = [long]$state.StartTicks; state = $state }
        }
        if ($clients.Count -eq 0) { return }
        $monitors = @([Arkuzo.WindowArrangeV3]::Monitors())
        if ($monitors.Count -eq 0) { return }
        $area = if ($settings.monitor -ge 1 -and $settings.monitor -le $monitors.Count) { $monitors[$settings.monitor - 1] } else { @($monitors | Where-Object { $_[5] -eq 1 })[0] }
        if ($null -eq $area) { $area = $monitors[0] }
        $targets = Get-ArkuzoArrangeTargets $clients @($voltControlStatus.accounts) $settings
        $count = 1 + [int](@($targets.Values) | Measure-Object -Maximum).Maximum
        $minSize = Get-ArkuzoRobloxMinWindow $area[4]
        $slots = Get-ArkuzoWindowSlots $count ([int[]]$area) $settings $minSize
        $overlap = Test-ArkuzoSlotsOverlap $slots
        $windows = [Arkuzo.WindowArrangeV3]::ClientWindows([int[]]@($clients | ForEach-Object { $_.processId }))
        # A changed layout (or screen, or learned minimum size) re-places every window once, even in "place once" mode.
        $signature = ($settings.layout, $settings.overflow, $settings.perRow, $settings.width, $settings.height, $settings.gap, $settings.corner, $settings.monitor, $settings.order, $settings.visibility, ($area -join ','), ($minSize -join 'x')) -join '|'
        $changed = $signature -cne $script:arrangeLastSignature
        $script:arrangeLastSignature = $signature
        $visibility = if ($Minimize) { 'minimized' } else { $settings.visibility } # "Minimize clients" in Settings wins.
        # Minimizing the window you are using would move the focus: it waits until you switch away.
        $foreground = [Arkuzo.WindowArrangeV3]::Foreground()
        $placed = 0; $ordered = @()
        foreach ($c in @($clients | Sort-Object { if ($targets.ContainsKey($_.accountId)) { [int]$targets[$_.accountId] } else { [int]::MaxValue } })) {
            if (-not $windows.ContainsKey($c.processId) -or -not $targets.ContainsKey($c.accountId)) { continue }
            $hwnd = [long]$windows[$c.processId]
            $slot = $slots[$targets[$c.accountId]]
            $overflow = Test-ArkuzoSlotMinimized $slot
            $slotVisibility = if ($overflow) { 'minimized' } else { $visibility }
            $placedFor = [long]$c.state.ArrangedStartTicks
            $now = [Arkuzo.WindowArrangeV3]::Rect($hwnd)
            if ($null -eq $now) { continue }
            if (-not $overflow) { $ordered += $hwnd }
            # Roblox kept the window larger than asked: learn its real minimum (re-planned next pass).
            $asked = $c.state.ArrangedRequest
            if ($null -ne $asked -and @($asked).Count -eq 4 -and $now[4] -eq 0 -and $now[5] -eq 0 -and [math]::Abs($now[0] - $asked[0]) -le 2 -and [math]::Abs($now[1] - $asked[1]) -le 2 -and
                ($now[2] -gt $asked[2] + 2 -or $now[3] -gt $asked[3] + 2) -and $now[2] -le 4 * $minSize[0] -and $now[3] -le 4 * $minSize[1]) {
                $known = $script:arrangeMinWindow[[string]$area[4]]
                $script:arrangeMinWindow[[string]$area[4]] = @([math]::Max([int]$now[2], [int]$(if ($known) { [int]$known[0] } else { 0 })), [math]::Max([int]$now[3], [int]$(if ($known) { [int]$known[1] } else { 0 })))
                $c.state.ArrangedRequest = $null
            }
            $request = if ($overflow) { @([int]$slot[0], [int]$slot[1], [int]$slot[2], [int]$slot[3], 1) } else { @([int]$slot[0], [int]$slot[1], [int]$slot[2], [int]$slot[3]) }
            $sameSlot = $null -ne $c.state.ArrangedSlot -and ((@($c.state.ArrangedSlot) -join ',') -ceq ($request -join ','))
            $settled = $placedFor -eq $c.startTicks -and $sameSlot -and -not $forced -and -not $changed
            if ($settled -and $settings.mode -ceq 'once') { continue }
            # An overflow window is minimized once per client and layout: one you restore to look at stays up
            # until the layout changes or Arrange now.
            if ($settled -and $overflow) { continue }
            if ($slotVisibility -ceq 'minimized' -and $hwnd -eq $foreground) { continue }
            $iconic = $now[4] -eq 1
            if ($slotVisibility -ceq 'minimized' -and $iconic -and $settled) { continue }
            if ((Test-ArkuzoWindowInPlace $now $slot) -and $settled) { continue }
            [void][Arkuzo.WindowArrangeV3]::Place($hwnd, $slot[0], $slot[1], $slot[2], $slot[3], $slotVisibility)
            $c.state.ArrangedStartTicks = $c.startTicks
            $c.state.ArrangedSlot = $request
            $c.state.ArrangedRequest = if ($overflow) { $null } else { @($slot[0], $slot[1], $slot[2], $slot[3]) }
            $placed++
        }
        # Stacking order only when something moved, so a client you bring forward stays forward.
        if ($overlap -and $placed -gt 0 -and $visibility -cne 'minimized' -and $ordered.Count -gt 1) {
            [Arkuzo.WindowArrangeV3]::Stack([long[]]$ordered, $visibility -ceq 'background')
        }
    } catch { Warn-Throttled 'arrange-windows' ('Window arrangement skipped: ' + $_.Exception.Message) }
}

function Invoke-ArkuzoVoltControl([ValidateSet('Status','Configure','LaunchMissing')][string]$Action='Status', [string]$AccountId='', [string]$TrackerId='') {
    $child=$null
    try {
        if ($Action -ne 'Status' -and ($MonitorOnly -or -not $ownsControllerMutex -or -not $restorePolicy.enabled)) { throw 'Read-only controller' }
        if (Test-ArkuzoNativeProvider) {
            if ($Action -ne 'LaunchMissing') { return (Get-ArkuzoNativeStatus) }
            if ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey($AccountId)) { throw 'Account suspended' }
            return (Invoke-ArkuzoNativeLaunch $AccountId $TrackerId)
        }
        $file=Join-Path $PSScriptRoot 'Arkuzo-Volt-Control.ps1'
        if (-not (Test-Path -LiteralPath $file)) { throw 'Control adapter unavailable' }
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName='powershell.exe'
        $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $file + '" -Action ' + $Action + ' -RelaunchDelaySec ' + [int]$restorePolicy.relaunch_delay_sec + ' -MinLaunchAgeSec ' + [int]$restorePolicy.restore_wait_sec
        if ($Action -eq 'LaunchMissing') {
            if ($AccountId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or $TrackerId -notmatch '\A[0-9]+\z') { throw 'Invalid non-secret account metadata' }
            # Prevent launch in any circumstance if cookie is dead or not alive
            $targetAcct = @($voltControlStatus.accounts | Where-Object { $_.accountId -ceq $AccountId })
            if ($targetAcct.Count -gt 0) {
                if ($targetAcct[0].cookieStatus -ceq 'dead' -or $targetAcct[0].cookieStatus -cne 'alive' -or -not $targetAcct[0].cookieAlive) {
                    throw "Launch blocked in any circumstance: account $AccountId has dead/invalid cookie ($($targetAcct[0].cookieStatus))"
                }
            }
            if ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey($AccountId)) {
                throw "Launch blocked in any circumstance: account $AccountId is suspended ($($script:suspendedAccounts[$AccountId].reason))"
            }
            $info.Arguments+=' -AccountId ' + $AccountId + ' -ExpectedTrackerId ' + $TrackerId
        }
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $child=[Diagnostics.Process]::Start($info)
        $out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
        if (-not (Wait-ArkuzoObservedProcess $child 15000)) { $child.Kill();throw 'Volt UI adapter timeout' }
        if ($child.ExitCode -ne 0) { throw 'Volt UI adapter refused request' }
        $result=$out.Result|ConvertFrom-Json
        if ($result.available -isnot [bool]) { throw 'Invalid control snapshot' }
        return $result
    } catch { return [pscustomobject]@{available=$false;requestAccepted=$false;reason='Volt background control unavailable/refused';accounts=@()} }
    finally { if ($child) { $child.Dispose() } }
}
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
# ---------------------------------------------------------------------------
# Farm-wide freeze fast path.
# A display or remote-desktop event freezes every client at the same moment at
# 0% CPU. None of the 44 logged correlated freezes (3+ clients, majority, still
# frozen 30 s after the last onset) came back; every client quit by itself after
# 187-217 s and Volt then relaunched them all at once, which raises its
# "Roblox started before Volt could connect" notice for launches < 10 s apart.
# Clients that freeze together while still starting (warm-up) behave the same:
# none of the 15 logged groups came back. CPU does not tell them apart: the 13
# long single hangs that did come back also averaged 3% or less.
# An episode is latched once confirmed. Its members are closed one at a time,
# farm_freeze_spacing_sec apart, so Volt's relaunches arrive paced too. Every
# closure still goes through Invoke-ClientRecovery with all its gates; only three
# are scoped to the episode: cooldown (= spacing), handoff (other members'
# pending entries do not block) and global mapping (only rows of members whose
# old generation has verifiably exited may be unmapped; see Get-ArkuzoFarmFreezeAccount).
# ---------------------------------------------------------------------------
function Update-ArkuzoHangCpu($State, [double]$CpuSeconds, [double]$Now, [int]$Threads) {
    # Average CPU (dashboard scale: percent of all logical CPUs) since freeze onset.
    if ($null -eq $State) { return }
    if ($null -eq $State.FreezeSince -or [double]$State.FreezeSince -lt 0) {
        $State.HangCpuBase = $null; $State.HangCpuBaseAt = $null; $State.HangCpuPercent = $null; return
    }
    if ($null -eq $State.HangCpuBase -or $null -eq $State.HangCpuBaseAt -or $Now -lt [double]$State.HangCpuBaseAt -or $CpuSeconds -lt [double]$State.HangCpuBase) {
        $State.HangCpuBase = $CpuSeconds; $State.HangCpuBaseAt = $Now; $State.HangCpuPercent = $null; return
    }
    $elapsed = $Now - [double]$State.HangCpuBaseAt
    if ($elapsed -lt 1) { return }
    $State.HangCpuPercent = [math]::Round(100 * ($CpuSeconds - [double]$State.HangCpuBase) / ($elapsed * [math]::Max(1, [int]$Threads)), 3)
}
function Test-ArkuzoFrozenSample($State, $Policy) {
    # Unresponsive visible window that answered before (FreezeSince; see
    # Get-ArkuzoHealthDecision), no startup notice or disconnect, and measured
    # low CPU since onset.
    $snap = $State.LastSnapshot
    return ($null -ne $snap -and $null -ne $State.FreezeSince -and [double]$State.FreezeSince -ge 0 -and
        $snap.windowPresent -is [bool] -and $snap.windowPresent -and $snap.responding -is [bool] -and -not $snap.responding -and
        -not $snap.launchError -and -not $State.isDisconnected -and -not $State.RecoveryRequested -and
        $null -ne $State.HangCpuPercent -and [double]$State.HangCpuPercent -le [double]$Policy.farm_freeze_max_cpu_percent)
}
function Test-ArkuzoRemoteDisconnectOnset($FirstOnset, $DisconnectSec, $Policy) {
    # Pure. A Chrome Remote Desktop disconnect froze the clients within 0-13 s of
    # it on 12 of the 14 logged disconnects with clients running, and none of
    # those clients answered again (docs/remote-desktop.md).
    # Onsets are recorded up to ~10 s after the real hang and the disconnect time
    # comes from another clock, so allow 10 s before it.
    if ($null -eq $FirstOnset -or $null -eq $DisconnectSec -or $null -eq $Policy) { return $false }
    $offset = [double]$FirstOnset - [double]$DisconnectSec
    return ($offset -ge -10 -and $offset -le [double]$Policy.farm_freeze_remote_window_sec)
}
function Get-ArkuzoFarmFreezeCandidate($States, $Policy, [double]$Now, $RemoteDisconnectSec = $null) {
    # Pure. Finds the largest group of frozen clients whose onsets lie within
    # farm_freeze_onset_window_sec. It qualifies with at least
    # farm_freeze_min_clients members that are a strict majority of the clients
    # already running when its last member froze (clients Volt launched afterwards,
    # e.g. while it is still starting the farm, say nothing about that freeze),
    # and is confirmed once its LAST member has been frozen for farm_freeze_confirm_sec,
    # or farm_freeze_remote_confirm_sec when it began right after a remote disconnect.
    if ($null -eq $Policy -or -not $Policy.farm_freeze_enabled) { return $null }
    $population = @($States | Where-Object { $null -ne $_ -and $null -ne $_.LastSnapshot -and -not $_.RecoveryRequested })
    $frozen = @($population | Where-Object { Test-ArkuzoFrozenSample $_ $Policy } | Sort-Object { [double]$_.FreezeSince })
    if ($frozen.Count -lt [int]$Policy.farm_freeze_min_clients) { return $null }
    $best = @()
    for ($i = 0; $i -lt $frozen.Count; $i++) {
        $group = @($frozen | Where-Object { [double]$_.FreezeSince -ge [double]$frozen[$i].FreezeSince -and ([double]$_.FreezeSince - [double]$frozen[$i].FreezeSince) -le [double]$Policy.farm_freeze_onset_window_sec })
        if ($group.Count -gt $best.Count) { $best = $group }
    }
    if ($best.Count -lt [int]$Policy.farm_freeze_min_clients) { return $null }
    $onsets = @($best | ForEach-Object { [double]$_.FreezeSince })
    $first = ($onsets | Measure-Object -Minimum).Minimum; $last = ($onsets | Measure-Object -Maximum).Maximum
    $present = @($population | Where-Object { $null -eq $_.StartedSec -or [double]$_.StartedSec -le [double]$last })
    if ((2 * $best.Count) -le $present.Count) { return $null }
    $remote = Test-ArkuzoRemoteDisconnectOnset $first $RemoteDisconnectSec $Policy
    $confirm = [double]$Policy.farm_freeze_confirm_sec
    if ($remote -and $null -ne $Policy.farm_freeze_remote_confirm_sec) { $confirm = [math]::Min($confirm, [double]$Policy.farm_freeze_remote_confirm_sec) }
    return [pscustomobject]@{ Members = $best; Population = $present.Count; FirstOnset = [double]$first; LastOnset = [double]$last
        Confirmed = (($Now - [double]$last) -ge $confirm); RemoteDisconnect = $remote; ConfirmSec = $confirm
        RemoteDisconnectOffsetSec = $(if ($remote) { [math]::Round([double]$first - [double]$RemoteDisconnectSec, 1) } else { $null }) }
}
function Test-ArkuzoFarmFreezeActive {
    return ($null -ne $script:farmFreeze -and $script:farmFreeze.State -ceq 'Active')
}
function Get-ArkuzoFarmFreezeMemberRecord($State) {
    if (-not (Test-ArkuzoFarmFreezeActive) -or $null -eq $State -or $null -eq $State.FarmFreezePid -or
        $State.FarmFreezeEpisode -cne $script:farmFreeze.Id) { return $null }
    $member = $script:farmFreeze.Members[[string]$State.FarmFreezePid]
    if ($null -eq $member -or [long]$member.startTicks -ne [long]$State.StartTicks) { return $null }
    return $member
}
function Test-ArkuzoFarmFreezeMember($State) {
    # Latched per-state membership: decisions computed by the observation service
    # or inside Invoke-ClientRecovery reach the same reason without a farm view.
    $member = Get-ArkuzoFarmFreezeMemberRecord $State
    return ($null -ne $member -and $member.status -ceq 'Planned')
}
function Set-ArkuzoFarmFreezeMemberStatus($State, [string]$Status) {
    $member = Get-ArkuzoFarmFreezeMemberRecord $State
    # Planned members move on once; a member that answered again can still quit later.
    if ($null -eq $member -or -not ($member.status -ceq 'Planned' -or ($member.status -ceq 'Recovered' -and $Status -ceq 'Exited'))) { return }
    $member.status = $Status; $member.changedUtc = [datetime]::UtcNow.ToString('o')
    if ($null -ne $clock) { $member.changedSec = [double]$clock.Elapsed.TotalSeconds }
}
function Test-ArkuzoFarmFreezeSlot {
    # Volt counts its relaunch delay from each exit, so pace members from the last
    # verified exit of any member (closed by the saver or quit by itself), not
    # from when the previous attempt started.
    if (-not (Test-ArkuzoFarmFreezeActive) -or $null -eq $clock) { return $true }
    $now = [double]$clock.Elapsed.TotalSeconds
    foreach ($m in @($script:farmFreeze.Members.Values)) {
        if ($m.status -cin @('Closed','Exited') -and $null -ne $m.changedSec -and ($now - [double]$m.changedSec) -lt [double]$healthPolicy.farm_freeze_spacing_sec) { return $false }
    }
    return $true
}
function Get-ArkuzoRecoveryCooldown([string]$Reason, $Policy) {
    # Reason-specific spacing for Test-ArkuzoRecoveryBudget. A confirmed farm
    # freeze is paced at Volt's launch spacing instead of the generic cooldown.
    if ($Reason -ceq 'VOLT_STARTUP_ERROR') { return [math]::Min(5, [int]$Policy.cooldown_sec) }
    if ($Reason -ceq 'FARM_FREEZE' -and $null -ne $Policy.farm_freeze_spacing_sec) { return [int]$Policy.farm_freeze_spacing_sec }
    return [int]$Policy.cooldown_sec
}
function Get-ArkuzoFarmFreezeAccount([string]$TrackerId, [int]$ClientId) {
    # Episode-scoped exact mapping while Volt counts down the relaunch of members
    # this episode already closed. Everything else must still map exactly:
    # process ownership, every other row, the target's own row and socket.
    if (-not (Test-ArkuzoFarmFreezeActive) -or -not $script:tracked.ContainsKey($ClientId)) { return $null }
    $member = Get-ArkuzoFarmFreezeMemberRecord $script:tracked[$ClientId]
    if ($null -eq $member -or $member.status -cne 'Planned' -or [int]$member.pid -ne $ClientId -or $member.trackerId -cne $TrackerId) { return $null }
    $s = $voltControlStatus
    if (-not $s.available -or $s.processMappingSafe -isnot [bool] -or -not $s.processMappingSafe -or
        [int]$s.managerId -ne [int]$script:farmFreeze.managerId -or [long]$s.managerStartTicks -ne [long]$script:farmFreeze.managerStartTicks) { return $null }
    foreach ($id in @($s.unmappedAccountIds)) {
        if ($null -eq $id) { continue }
        $gone = @($script:farmFreeze.Members.Values | Where-Object { $_.accountId -ceq [string]$id -and $_.status -cin @('Closed','Exited') })
        if ($gone.Count -ne 1) { return $null }
    }
    if (-not (Test-ArkuzoSuspendedRowsSafe)) { return $null }
    $rows = @($s.accounts | Where-Object { $_.accountId -ceq $member.accountId })
    $sameTracker = @($s.accounts | Where-Object { $_.trackerId -ceq $TrackerId })
    $samePid = @($s.accounts | Where-Object { $_.processId -and [int]$_.processId -eq $ClientId })
    if ($rows.Count -ne 1 -or $sameTracker.Count -ne 1 -or $samePid.Count -ne 1) { return $null }
    $a = $rows[0]
    if ($a.trackerId -cne $TrackerId -or [int]$a.processId -ne $ClientId -or $a.uiStatus -cne 'Connected' -or
        $a.rowReady -isnot [bool] -or -not $a.rowReady -or $a.autoRelaunch -isnot [bool] -or -not $a.autoRelaunch -or
        $a.cookieStatus -cne 'alive' -or -not $a.cookieAlive -or
        ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey([string]$a.accountId)) -or
        $restorePolicy.excluded_account_ids -contains $a.accountId) { return $null }
    return $a
}
function Start-ArkuzoFarmFreezeEpisode($Candidate, [double]$Now) {
    # Latch members from ONE globally mapped, fresh Volt snapshot. Accounts that
    # are already pending, quarantined, excluded or unmapped stay on the normal path.
    $utc = [datetime]::UtcNow
    $room = [int]$healthPolicy.max_recycles_per_hour - @($recoveryAttempts | Where-Object { ($utc - ([datetime]$_).ToUniversalTime()).TotalSeconds -lt 3600 }).Count
    $members = @{}; $order = @(); $skipped = @()
    foreach ($state in @($Candidate.Members | Sort-Object { [double]$_.FreezeSince })) {
        $id = [int]$state.Watcher.Id
        $account = $null
        if (Test-ArkuzoClientIdentity $state.Watcher $id $state.StartTicks) { $account = Get-ArkuzoControlledAccount $state.TrackerId $id }
        $why = $null
        if ($null -eq $account) { $why = 'UNMAPPED' }
        elseif ($recoveryPending.ContainsKey([string]$account.accountId)) { $why = 'ALREADY_PENDING' }
        elseif (Test-ArkuzoAccountQuarantined ([string]$account.accountId) $utc) { $why = 'QUARANTINED' }
        elseif (-not ($account.autoRelaunch -is [bool] -and $account.autoRelaunch -and $account.cookieAlive -is [bool] -and $account.cookieAlive)) { $why = 'NOT_RELAUNCHABLE' }
        elseif ($order.Count -ge $room) { $why = 'HOURLY_BUDGET' }
        if ($why) { $skipped += @{ pid = $id; reason = $why }; continue }
        $members[[string]$id] = @{ pid = $id; startTicks = [long]$state.StartTicks; accountId = [string]$account.accountId; trackerId = [string]$account.trackerId
            onsetOffsetSec = [math]::Round([double]$state.FreezeSince - $Candidate.FirstOnset, 1); cpuPercent = $state.HangCpuPercent; status = 'Planned'; changedUtc = $null }
        $order += $id
    }
    if ($order.Count -eq 0) {
        Warn-Throttled 'farm-freeze' 'Farm-wide freeze confirmed, but no member can be mapped exactly now. Normal hang recovery continues.'
        return $false
    }
    $script:farmFreezeSequence = [int]$script:farmFreezeSequence + 1
    $script:farmFreeze = @{ Id = ('freeze-' + $utc.ToString('yyyyMMddHHmmss') + '-' + $script:farmFreezeSequence); State = 'Active'
        StartedSec = $Now; StartedUtc = $utc.ToString('o'); FirstOnset = $Candidate.FirstOnset
        managerId = [int]$voltControlStatus.managerId; managerStartTicks = [long]$voltControlStatus.managerStartTicks
        Members = $members; Order = $order
        DeadlineSec = $Now + ($order.Count * [double]$healthPolicy.farm_freeze_spacing_sec) + 120 }
    foreach ($id in $order) { $tracked[$id].FarmFreezeEpisode = $script:farmFreeze.Id; $tracked[$id].FarmFreezePid = $id }
    $script:lastFarmFreezeStartSec = $Now
    Write-Diagnostic 'FARM_FREEZE_DETECTED' @{ episode = $script:farmFreeze.Id; population = $Candidate.Population; frozen = @($Candidate.Members).Count
        planned = @($order | ForEach-Object { $m = $members[[string]$_]; @{ pid = $m.pid; accountId = $m.accountId; onsetOffsetSec = $m.onsetOffsetSec; cpuPercent = $m.cpuPercent } })
        skipped = $skipped; confirmSec = [math]::Round($Now - $Candidate.LastOnset, 1); spacingSec = $healthPolicy.farm_freeze_spacing_sec
        cause = $(if ($Candidate.RemoteDisconnect) { 'remote-disconnect' } else { 'unknown' }); remoteDisconnectOffsetSec = $Candidate.RemoteDisconnectOffsetSec
        note = 'Correlated freeze: members are closed one at a time at Volt launch spacing through the normal guarded recovery.' }
    return $true
}
function Stop-ArkuzoFarmFreezeEpisode([string]$Outcome) {
    if (-not (Test-ArkuzoFarmFreezeActive)) { return }
    $episode = $script:farmFreeze
    foreach ($m in @($episode.Members.Values)) { if ($m.status -ceq 'Planned') { $m.status = 'Released' } }
    $episode.State = $Outcome
    foreach ($state in @($tracked.Values)) { if ($state.FarmFreezeEpisode -ceq $episode.Id) { $state.FarmFreezeEpisode = $null; $state.FarmFreezePid = $null } }
    $counts = @{}; foreach ($m in @($episode.Members.Values)) { $counts[$m.status] = 1 + [int]$counts[$m.status] }
    Write-Diagnostic 'FARM_FREEZE_EPISODE_END' @{ episode = $episode.Id; outcome = $Outcome; members = $counts
        durationSec = $(if ($null -ne $clock) { [math]::Round($clock.Elapsed.TotalSeconds - [double]$episode.StartedSec, 1) } else { $null }) }
}
function Update-ArkuzoFarmFreeze {
    # Once per main-loop pass, after every client was sampled.
    if ($null -eq $clock) { return }
    $now = $clock.Elapsed.TotalSeconds
    if (Test-ArkuzoFarmFreezeActive) {
        if (-not $healthPolicy.farm_freeze_enabled -or -not $healthPolicy.enabled -or $MonitorOnly) { Stop-ArkuzoFarmFreezeEpisode 'Disabled'; return }
        foreach ($m in @($script:farmFreeze.Members.Values)) {
            if ($m.status -cne 'Planned') { continue }
            $state = $tracked[[int]$m.pid]
            # A member that answers again is never closed by this episode.
            if ($null -ne $state -and [long]$state.StartTicks -eq [long]$m.startTicks -and ($null -eq $state.FreezeSince -or [double]$state.FreezeSince -lt 0)) {
                Set-ArkuzoFarmFreezeMemberStatus $state 'Recovered'
            }
        }
        if (@($script:farmFreeze.Members.Values | Where-Object { $_.status -ceq 'Planned' }).Count -eq 0) { Stop-ArkuzoFarmFreezeEpisode 'Completed' }
        elseif ($now -ge [double]$script:farmFreeze.DeadlineSec) { Stop-ArkuzoFarmFreezeEpisode 'Expired' }
        return
    }
    if ($MonitorOnly -or -not $healthPolicy.enabled -or -not $healthPolicy.farm_freeze_enabled -or -not $restorePolicy.enabled -or
        -not $ownsControllerMutex -or -not $recoveryJournalHealthy -or $logFailed) { return }
    # A disconnected RDP session cannot render relaunched clients either.
    if (Test-ArkuzoRemoteHold $now) { return }
    $candidate = Get-ArkuzoFarmFreezeCandidate @($tracked.Values) $healthPolicy $now $script:lastRemoteDisconnectSec
    if ($null -eq $candidate -or -not $candidate.Confirmed) { return }
    # A farm that freezes again soon after an episode is not helped by fast
    # recycling (the display is likely still gone): use hang_timeout_sec instead.
    # A new remote disconnect since that episode is a new, discrete cause: the
    # replacement clients ran fine until the user disconnected again.
    $newDisconnect = ($candidate.RemoteDisconnect -and $null -ne $script:lastRemoteDisconnectSec -and
        ($null -eq $script:lastFarmFreezeStartSec -or [double]$script:lastRemoteDisconnectSec -gt [double]$script:lastFarmFreezeStartSec))
    if (-not $newDisconnect -and $null -ne $script:lastFarmFreezeStartSec -and ($now - [double]$script:lastFarmFreezeStartSec) -lt [double]$healthPolicy.farm_freeze_refreeze_sec) {
        Warn-Throttled 'farm-freeze' 'Farm froze again soon after the last fast recovery. Using the normal hang timeout this time.'
        return
    }
    # Volt starts a farm one client every 9-15 s. While that run may still be
    # going, paced closes could relaunch into it and raise its startup notice:
    # wait until no client has started for 30 s.
    if ($null -ne $script:lastClientStartUtc -and ([datetime]::UtcNow - $script:lastClientStartUtc).TotalSeconds -lt 30) { return }
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe) { return }
    [void](Start-ArkuzoFarmFreezeEpisode $candidate $now)
}
function Test-ArkuzoLaunchPacing([datetime]$NowUtc) {
    # A Volt launch request must not land within farm_freeze_spacing_sec of
    # another launch: closer launches raise Volt's startup notice.
    $spacing = if ($null -ne $healthPolicy.farm_freeze_spacing_sec) { [double]$healthPolicy.farm_freeze_spacing_sec } else { 20.0 }
    if (Test-ArkuzoFarmFreezeActive) { return $false }
    if ($null -ne $script:lastClientStartUtc -and ($NowUtc - $script:lastClientStartUtc).TotalSeconds -lt $spacing) { return $false }
    # Volt itself relaunches a closed client relaunch_delay_sec after its exit.
    $due = [double]$restorePolicy.relaunch_delay_sec + $spacing
    foreach ($entry in @($recoveryPending.Values)) {
        if (-not $entry.closedUtc -or [int]$entry.replacementPid -gt 0) { continue }
        try { $age = ($NowUtc - ([datetime]$entry.closedUtc).ToUniversalTime()).TotalSeconds } catch { continue }
        if ($age -ge 0 -and $age -lt $due) { return $false }
    }
    return $true
}
# ---------------------------------------------------------------------------
# Remote sessions (docs/remote-desktop.md). Chrome Remote Desktop streams the
# console session, so Windows itself records nothing when its viewer leaves:
# the host's own Application-log events (source "chromoting", 1 connected,
# 2 disconnected) are the only signal. RDP shows up as this process's own WTS
# session state. Everything here is read-only except the process-scoped
# keep-awake request, which Windows drops when the saver exits.
# ---------------------------------------------------------------------------
$script:remoteProbe = $null; $script:remoteProbeSec = $null; $script:lastRemoteDisconnectSec = $null
$script:remoteHoldSinceSec = $null; $script:keepAwakeOn = $false; $script:keepAwakeFailed = $false
$script:crdBookmark = $null; $script:crdLast = $null; $script:crdServiceCheckSec = $null; $script:crdInstalled = $false
function Read-ArkuzoChromotingEvent([double]$NowSec) {
    # Newest Chrome Remote Desktop connect (1) or disconnect (2) as @{ id; utc }, or $null.
    # A filtered search of the Application log costs up to ~150 ms when the host
    # has logged nothing lately, so it runs once; afterwards only the records
    # written since are read, from a bookmark (~0 ms). Only provider, id and time
    # are read: the message names the viewer's account and is never touched.
    if ($null -eq $script:crdServiceCheckSec -or ($NowSec - [double]$script:crdServiceCheckSec) -ge 600) {
        $script:crdServiceCheckSec = $NowSec
        $script:crdInstalled = ($null -ne (Get-Service -Name 'chromoting' -ErrorAction SilentlyContinue))
        if (-not $script:crdInstalled) { $script:crdBookmark = $null; $script:crdLast = $null }
    }
    if (-not $script:crdInstalled) { return $null }
    $logName = [Diagnostics.Eventing.Reader.PathType]::LogName
    try {
        if ($null -eq $script:crdBookmark) {
            # Bookmark first: an event written meanwhile is read again next time, never missed.
            $newest = New-Object Diagnostics.Eventing.Reader.EventLogQuery('Application', $logName, '*'); $newest.ReverseDirection = $true
            $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($newest)
            try { $top = $reader.ReadEvent() } finally { $reader.Dispose() }
            if ($null -ne $top) { try { $script:crdBookmark = $top.Bookmark } finally { $top.Dispose() } }
            $query = New-Object Diagnostics.Eventing.Reader.EventLogQuery('Application', $logName, "*[System[Provider[@Name='chromoting'] and (EventID=1 or EventID=2)]]")
            $query.ReverseDirection = $true
            $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($query)
            try { $record = $reader.ReadEvent() } finally { $reader.Dispose() }
            if ($null -ne $record) { try { $script:crdLast = @{ id = [int]$record.Id; utc = ([datetime]$record.TimeCreated).ToUniversalTime() } } finally { $record.Dispose() } }
        } else {
            $all = New-Object Diagnostics.Eventing.Reader.EventLogQuery('Application', $logName, '*')
            $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($all, $script:crdBookmark)
            try {
                for ($i = 0; $i -lt 5000; $i++) {
                    $record = $reader.ReadEvent()
                    if ($null -eq $record) { break }
                    try {
                        $script:crdBookmark = $record.Bookmark
                        if ($record.ProviderName -ceq 'chromoting' -and ($record.Id -eq 1 -or $record.Id -eq 2)) {
                            $script:crdLast = @{ id = [int]$record.Id; utc = ([datetime]$record.TimeCreated).ToUniversalTime() }
                        }
                    } finally { $record.Dispose() }
                }
            } finally { $reader.Dispose() }
        }
    } catch { $script:crdBookmark = $null } # Log cleared or unreadable: search again next time.
    return $script:crdLast
}
function Get-ArkuzoRemoteProbe {
    $n = [Arkuzo.RemoteSessionNativeV1]
    $session = $n::OwnSessionId()
    $crd = Read-ArkuzoChromotingEvent $(if ($null -ne $clock) { [double]$clock.Elapsed.TotalSeconds } else { 0 })
    return @{ sessionId = $session; consoleSessionId = $n::ConsoleSessionId(); connectState = $n::ConnectState($session); protocol = $n::ClientProtocol($session)
        lockState = $n::LockState($session); inputDesktop = $n::InputDesktopName(); display = ($n::DisplayMode() -join 'x'); monitors = $n::MonitorCount()
        crdEventId = $(if ($null -ne $crd) { $crd.id } else { $null }); crdEventUtc = $(if ($null -ne $crd) { $crd.utc } else { $null })
        bootUtc = [datetime]::UtcNow.AddMilliseconds(-[double]$n::UptimeMs()) }
}
function Test-ArkuzoCrdConnected($Probe) {
    # Pure. A connect logged before the last boot is stale: a restart while
    # connected leaves no disconnect event behind.
    if ($null -eq $Probe -or $null -eq $Probe.crdEventId -or [int]$Probe.crdEventId -ne 1) { return $false }
    return ($null -eq $Probe.bootUtc -or $null -eq $Probe.crdEventUtc -or [datetime]$Probe.crdEventUtc -gt [datetime]$Probe.bootUtc)
}
function ConvertTo-ArkuzoRemoteRecord($Probe) {
    if ($null -eq $Probe) { return $null }
    $states = @{ 0 = 'active'; 1 = 'connected'; 2 = 'connectQuery'; 3 = 'shadow'; 4 = 'disconnected'; 5 = 'idle'; 6 = 'listen'; 7 = 'reset'; 8 = 'down'; 9 = 'init' }
    $state = [int]$Probe.connectState
    return @{ sessionId = $Probe.sessionId; onConsole = ([int]$Probe.sessionId -ge 0 -and [int]$Probe.sessionId -eq [int]$Probe.consoleSessionId)
        sessionState = $(if ($states.ContainsKey($state)) { $states[$state] } else { 'unknown' })
        protocol = $(switch ([int]$Probe.protocol) { 0 { 'console' } 2 { 'rdp' } default { 'unknown' } })
        locked = $(switch ([int]$Probe.lockState) { 0 { $true } 1 { $false } default { $null } })
        inputDesktop = $Probe.inputDesktop; display = $Probe.display; monitors = $Probe.monitors
        chromeRemoteDesktop = $(if ($null -eq $Probe.crdEventId) { $null } else {
            @{ connected = (Test-ArkuzoCrdConnected $Probe); changedUtc = $(if ($Probe.crdEventUtc) { ([datetime]$Probe.crdEventUtc).ToString('o') } else { $null }) } }) }
}
function Compare-ArkuzoRemoteProbe($Previous, $Current) {
    # Pure. What changed between two probes, as stable codes for the log.
    if ($null -eq $Previous -or $null -eq $Current) { return @() }
    $changes = @()
    if ($Current.crdEventId -ne $Previous.crdEventId -or $Current.crdEventUtc -ne $Previous.crdEventUtc) {
        if ([int]$Current.crdEventId -eq 1) { $changes += 'CRD_CONNECTED' } elseif ([int]$Current.crdEventId -eq 2) { $changes += 'CRD_DISCONNECTED' }
    }
    if ([int]$Current.connectState -ne [int]$Previous.connectState) {
        if ([int]$Current.connectState -eq 4) { $changes += 'SESSION_DISCONNECTED' }
        elseif ([int]$Previous.connectState -eq 4) { $changes += 'SESSION_RECONNECTED' }
        else { $changes += 'SESSION_STATE_CHANGED' }
    }
    $wasConsole = ([int]$Previous.sessionId -eq [int]$Previous.consoleSessionId); $isConsole = ([int]$Current.sessionId -eq [int]$Current.consoleSessionId)
    if ($isConsole -ne $wasConsole) { $changes += $(if ($isConsole) { 'SESSION_ON_CONSOLE' } else { 'SESSION_LEFT_CONSOLE' }) }
    if ([int]$Current.protocol -ne [int]$Previous.protocol) { $changes += 'PROTOCOL_CHANGED' }
    if ([int]$Current.lockState -ne [int]$Previous.lockState) {
        if ([int]$Current.lockState -eq 0) { $changes += 'SESSION_LOCKED' } elseif ([int]$Current.lockState -eq 1) { $changes += 'SESSION_UNLOCKED' }
    }
    if ([string]$Current.inputDesktop -cne [string]$Previous.inputDesktop) { $changes += 'INPUT_DESKTOP_CHANGED' }
    if ([string]$Current.display -cne [string]$Previous.display) { $changes += 'DISPLAY_MODE_CHANGED' }
    if ([int]$Current.monitors -ne [int]$Previous.monitors) { $changes += 'MONITOR_COUNT_CHANGED' }
    return $changes
}
function Get-ArkuzoRemoteDisconnectSec($Probe, [datetime]$NowUtc, [double]$NowSec) {
    # Pure. The saver-clock time of the newest Chrome Remote Desktop disconnect, or $null.
    if ($null -eq $Probe -or $null -eq $Probe.crdEventId -or [int]$Probe.crdEventId -ne 2 -or $null -eq $Probe.crdEventUtc) { return $null }
    return $NowSec - [math]::Max([double]0, [double]($NowUtc - [datetime]$Probe.crdEventUtc).TotalSeconds)
}
function Test-ArkuzoRemoteHold([double]$NowSec) {
    # While this saver's own session is disconnected (RDP), clients cannot render
    # and replacements would land in the same session: hold launches and
    # recovery, for at most remote_hold_max_sec.
    if ($null -eq $script:remoteHoldSinceSec -or $null -eq $healthPolicy -or [double]$healthPolicy.remote_hold_max_sec -le 0) { return $false }
    return (($NowSec - [double]$script:remoteHoldSinceSec) -lt [double]$healthPolicy.remote_hold_max_sec)
}
function Update-ArkuzoRemoteState($Probe, [datetime]$NowUtc, [double]$NowSec) {
    # Applies one probe; returns the change codes. Separate from the probe so tests drive it.
    $previous = $script:remoteProbe; $script:remoteProbe = $Probe
    $changes = @(Compare-ArkuzoRemoteProbe $previous $Probe)
    $crdAt = Get-ArkuzoRemoteDisconnectSec $Probe $NowUtc $NowSec
    if ($null -ne $crdAt -and ($null -eq $script:lastRemoteDisconnectSec -or $crdAt -gt [double]$script:lastRemoteDisconnectSec + 1)) { $script:lastRemoteDisconnectSec = $crdAt }
    if ([int]$Probe.connectState -eq 4) {
        if ($null -eq $script:remoteHoldSinceSec) { $script:remoteHoldSinceSec = $NowSec; $script:lastRemoteDisconnectSec = $NowSec }
    } else { $script:remoteHoldSinceSec = $null }
    return $changes
}
function Update-ArkuzoRemoteSession {
    if ($null -eq $clock) { return }
    $now = [double]$clock.Elapsed.TotalSeconds
    if ($null -ne $script:remoteProbeSec -and ($now - [double]$script:remoteProbeSec) -lt 2) { return }
    $script:remoteProbeSec = $now
    try { $probe = Get-ArkuzoRemoteProbe } catch { Warn-Throttled 'remote-probe' 'Remote-session state is unavailable; remote disconnects are not recognised.'; return }
    $first = ($null -eq $script:remoteProbe)
    $changes = @(Update-ArkuzoRemoteState $probe ([datetime]::UtcNow) $now)
    if ($first -or $changes.Count -gt 0) {
        $states = @($tracked.Values)
        Write-Diagnostic $(if ($first) { 'REMOTE_SESSION_STATE' } else { 'REMOTE_SESSION_CHANGED' }) @{ changes = $changes; current = (ConvertTo-ArkuzoRemoteRecord $probe)
            clients = $states.Count; responding = @($states | Where-Object { $null -ne $_.LastSnapshot -and $_.LastSnapshot.responding -eq $true }).Count
            hold = (Test-ArkuzoRemoteHold $now)
            note = 'Chrome Remote Desktop runs in the console session; only its own events show when the viewer leaves. See docs/remote-desktop.md.' }
    }
}
function Update-ArkuzoKeepAwake([bool]$Wanted) {
    # Process-scoped SetThreadExecutionState from the main loop thread: keeps the
    # display (and so the clients' swap chains) on while clients run. Nothing is
    # changed in the power plan; Windows drops the request when the saver exits.
    if ($Wanted -eq [bool]$script:keepAwakeOn -or ($Wanted -and $script:keepAwakeFailed)) { return }
    $ok = $false
    try { $ok = [Arkuzo.RemoteSessionNativeV1]::KeepAwake($Wanted) } catch { $ok = $false }
    if ($Wanted -and -not $ok) { $script:keepAwakeFailed = $true; Warn-Throttled 'keep-awake' 'Could not ask Windows to keep the display on.'; return }
    $script:keepAwakeOn = $Wanted
    Write-Diagnostic 'KEEP_AWAKE' @{ on = $Wanted; clients = $tracked.Count; note = 'Display and system kept awake while clients run (process-scoped; the power plan is unchanged).' }
}
function Get-ArkuzoRemoteStatus {
    $record = ConvertTo-ArkuzoRemoteRecord $script:remoteProbe
    if ($null -eq $record) { return $null }
    $now = $(if ($null -ne $clock) { [double]$clock.Elapsed.TotalSeconds } else { 0 })
    $record.keepAwake = [bool]$script:keepAwakeOn
    $record.hold = (Test-ArkuzoRemoteHold $now)
    $record.holdLeftSec = $(if ($record.hold) { [math]::Round([double]$healthPolicy.remote_hold_max_sec - ($now - [double]$script:remoteHoldSinceSec)) } else { $null })
    $record.lastDisconnectAgoSec = $(if ($null -ne $script:lastRemoteDisconnectSec) { [math]::Round($now - [double]$script:lastRemoteDisconnectSec) } else { $null })
    return $record
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
                $script:suspendedAccounts[$key]=@{accountId=$key;username=$a.username;reason='COOKIE_DEAD';suspendedUtc=$utc.ToString('o');pending=$history;provider=$script:accountProvider}
                $script:recoveryPending.Remove($key)
            }
            Save-ArkuzoRecoveryJournal
        } catch {
            $script:recoveryPending=$beforePending;$script:suspendedAccounts=$beforeSuspended;$script:recoveryJournalHealthy=$false
            throw
        }
    }
    $autoExcluded = $false
    foreach ($key in @($script:suspendedAccounts.Keys)) {
        if (-not (Test-ArkuzoSuspensionInScope $script:suspendedAccounts[$key])) { continue } # Never exclude the other launcher's accounts.
        if (@($voltControlStatus.accounts | Where-Object { $_.accountId -ceq $key }).Count -eq 0) {
            if ($restorePolicy.excluded_account_ids -notcontains $key) {
                $restorePolicy.excluded_account_ids += @($key)
                $autoExcluded = $true
                Write-Diagnostic 'DISAPPEARED_SUSPENDED_ACCOUNT_AUTO_EXCLUDED' @{ accountId = $key }
            }
        }
    }
    if ($autoExcluded -and $configFilePath -and (Test-Path -LiteralPath $configFilePath)) {
        try {
            $cfgJson = [IO.File]::ReadAllText($configFilePath) | ConvertFrom-Json
            if ($null -ne $cfgJson.recovery) {
                $cfgJson.recovery.excluded_account_ids = @($restorePolicy.excluded_account_ids)
                Save-ArkuzoAtomicJson $configFilePath $cfgJson
            }
        } catch { }
    }
}
function Get-ArkuzoOutcomeCheckDelay {
    # Seconds until the next outcome/launch step. Under the Arkuzo provider it runs on every
    # pass while anything is queued, so launchDelaySec is the real spacing between launches
    # (a 10 s cadence turned 12 s into 20 s). Otherwise every 3 s (Arkuzo: as often as the
    # account status is read) or 10 s (Volt, whose status arrives every 15 s).
    if (Test-ArkuzoNativeProvider) {
        if ($null -ne $script:recoveryPending -and $script:recoveryPending.Count -gt 0) { return 0 }
        return 3
    }
    return 10
}
function Get-ArkuzoPendingSignature {
    # What the journal must not lose; readiness timers are cleared on load anyway.
    if ($null -eq $script:recoveryPending) { return '' }
    return ((@($script:recoveryPending.Keys) | Sort-Object | ForEach-Object {
        $e = $script:recoveryPending[$_]; $_ + '|' + $e.status + '|' + $e.retryCount + '|' + $e.nextRetryUtc + '|' + $e.closedUtc + '|' + $e.oldPid + '|' + $e.lastLaunchUtc
    }) -join ';') + '#' + @($script:launchAttempts).Count + '#' + $(if ($null -ne $script:quarantinedAccounts) { $script:quarantinedAccounts.Count } else { 0 })
}
function Get-ArkuzoLaunchOrder($Pending) {
    # Pure. Pending account ids, least recently tried launch first (never tried first of all), then
    # oldest entry, then id, so the order is stable and one failing account can't take every slot.
    return ,@(@($Pending.Keys) | Sort-Object @{ Expression = { $e = $Pending[$_]; if ($e.lastLaunchUtc) { try { ([datetime]$e.lastLaunchUtc).ToUniversalTime() } catch { [datetime]::MinValue } } else { [datetime]::MinValue } } },
        @{ Expression = { try { ([datetime]$Pending[$_].createdUtc).ToUniversalTime() } catch { [datetime]::MinValue } } }, @{ Expression = { [string]$_ } })
}
function Update-ArkuzoRecoveryOutcomes {
    if ($MonitorOnly -or -not $restorePolicy.enabled -or -not $ownsControllerMutex -or $script:recoveryJournalCorrupt) { return }
    $utc=[datetime]::UtcNow
    $journalBefore = Get-ArkuzoPendingSignature
    if (-not $voltControlStatus.available -or $voltControlStatus.globalMappingSafe -isnot [bool] -or -not $voltControlStatus.globalMappingSafe -or ($utc-$voltControlCheckedUtc).TotalSeconds -lt 0 -or ($utc-$voltControlCheckedUtc).TotalSeconds -gt 25) {
        foreach ($entry in $recoveryPending.Values) { $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null }
        return
    }
    $native = Test-ArkuzoNativeProvider
    # Arkuzo: every opted-in account of a running farm should be in game, launched before or not.
    $restoreMissing = if ($native) { [bool]$voltControlStatus.farmRunning } else { [bool]$restorePolicy.restore_missing }
    $outcomePolicy = if ($native) { Get-ArkuzoNativeOutcomePolicy } else { $restorePolicy }
    try {
        Update-ArkuzoCookieSuspensions
        if ($native -and $null -ne $script:quarantinedAccounts) {
            # The Arkuzo provider never parks an account (it keeps retrying at normal spacing),
            # so quarantines restored from the journal of an earlier version are dropped.
            foreach ($a in @($voltControlStatus.accounts)) {
                if ($script:quarantinedAccounts.ContainsKey([string]$a.accountId)) {
                    $script:quarantinedAccounts.Remove([string]$a.accountId)
                    Write-Diagnostic 'RECOVERY_QUARANTINE_CLEARED' @{accountId=$a.accountId;note='Arkuzo provider: no quarantine; the account is retried at normal spacing.'}
                }
            }
        }
        # Opted-in, previously launched accounts only. Never activate unlaunched accounts.
        if ($null -eq $script:sessionObservedAccounts) { $script:sessionObservedAccounts = @{} }
        if ($null -eq $script:saverSessionStartEpochMs) { $script:saverSessionStartEpochMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        foreach ($a in @($voltControlStatus.accounts)) {
            if ($a.cookieStatus -ceq 'dead' -or $a.cookieStatus -cne 'alive' -or -not $a.cookieAlive -or
                ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey([string]$a.accountId)) -or
                -not $a.autoRelaunch -or $restorePolicy.excluded_account_ids -contains $a.accountId) { continue }
            if ($a.processId -or ([long]$a.lastLaunchAtMs -ge $script:saverSessionStartEpochMs) -or ($native -and $restoreMissing)) {
                $script:sessionObservedAccounts[[string]$a.accountId] = $true
            }
            if (-not $script:sessionObservedAccounts.ContainsKey([string]$a.accountId)) {
                continue
            }
            if ($restoreMissing -and -not $a.processId -and $a.uiStatus -eq 'Idle' -and ($native -or [long]$a.lastLaunchAtMs -gt 0) -and
                $a.trackerId -match '\A[0-9]+\z' -and -not $recoveryPending.ContainsKey([string]$a.accountId) -and
                -not (Test-ArkuzoAccountQuarantined ([string]$a.accountId) $utc)) {
                $script:recoveryPending[[string]$a.accountId]=New-ArkuzoPendingEntry $a.accountId $a.trackerId
                Write-Diagnostic 'MISSING_ACCOUNT_DETECTED' @{accountId=$a.accountId;username=$a.username;note='Wait for native Volt queue before a bounded missing-account request.'}
            }
        }
        # Fair order: an account whose launch was tried least recently goes first (never tried
        # first of all), so one that keeps failing at the relaunch delay can't take every slot.
        # (Arkuzo only; Volt keeps its order.)
        $order = if (-not $native) { @($recoveryPending.Keys) } else { Get-ArkuzoLaunchOrder $recoveryPending }
        foreach ($key in $order) {
            $entry=$recoveryPending[$key]
            if ($native -and $null -ne $script:nativeLaunchExits -and $script:nativeLaunchExits.ContainsKey($key)) {
                # Its launched client went away before it was in game: relaunch after the relaunch delay.
                $script:nativeLaunchExits.Remove($key)
                $exitBuild = if ($null -ne $script:nativeLaunchBuilds -and $script:nativeLaunchBuilds.ContainsKey($key)) { [string]$script:nativeLaunchBuilds[$key] } else { $null }
                if ($null -ne $script:nativeLaunchBuilds) { $script:nativeLaunchBuilds.Remove($key) }
                Write-Diagnostic 'NATIVE_LAUNCH_EXITED' @{accountId=$key;pid=$entry.replacementPid;attempt=[int]$entry.retryCount;robloxVersion=$exitBuild;note='The launched client closed before it was verified in game; relaunching after the relaunch delay.'}
                # Dead-build guard: a build whose clients keep closing at start stops getting launches.
                if ($exitBuild) { [void](Register-ArkuzoRobloxBuildFailure $exitBuild $key $utc) }
                $entry.closedUtc=$utc.ToString('o');$entry.nextRetryUtc=$null;$entry.replacementPid=0;$entry.replacementStartTicks=0;$entry.readySinceUtc=$null;$entry.lastObservedUtc=$null
            }
            if ($native -and -not $voltControlStatus.farmRunning) {
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Farm stopped in the Control Center'}
                $script:recoveryPending.Remove($key)
                continue
            }
            if ($restorePolicy.excluded_account_ids -contains $key) {
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account explicitly excluded by policy'}
                $script:recoveryPending.Remove($key)
                continue
            }
            # Arkuzo: no quarantine; a failing account keeps its place in the fair launch order.
            $abandon=if ($native) { $null } else { Test-ArkuzoPendingAbandon $entry $utc $restorePolicy }
            if ($abandon) {
                if ($null -eq $script:quarantinedAccounts) { $script:quarantinedAccounts=@{} }
                $until=$utc.AddSeconds([int]$restorePolicy.quarantine_sec).ToString('o')
                if ([int]$restorePolicy.quarantine_sec -gt 0) {
                    $script:quarantinedAccounts[$key]=@{accountId=$key;username=(Get-ArkuzoAccountDisplayLabel -AccountId $key);reason=$abandon;retryCount=[int]$entry.retryCount;sinceUtc=$utc.ToString('o');untilUtc=$until}
                }
                Write-Diagnostic 'RECOVERY_QUARANTINED' @{accountId=$key;reason=$abandon;retryCount=[int]$entry.retryCount;untilUtc=$until;note='Repeatedly failing account released from the shared handoff gate; other accounts recover normally.'}
                Warn-Throttled ('quarantine-'+$key) ((Get-ArkuzoAccountDisplayLabel -AccountId $key)+' quarantined after repeated failed recoveries ('+$abandon+'). Other accounts continue normally.')
                $script:recoveryPending.Remove($key)
                continue
            }
            $candidates=@($voltControlStatus.accounts|Where-Object{$_.accountId -eq $key})
            if ($candidates.Count -eq 0) {
                if (-not $entry.missingSinceUtc) {
                    $entry.missingSinceUtc = $utc.ToString('o')
                }
                $missingDuration = ($utc.ToUniversalTime() - ([datetime]$entry.missingSinceUtc).ToUniversalTime()).TotalSeconds
                if ($missingDuration -ge [double]$restorePolicy.restore_wait_sec) {
                    Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account no longer present in Volt inventory'}
                    $script:recoveryPending.Remove($key)
                    continue
                }
                $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';Warn-Throttled ('restore-'+$key) 'Pending account missing in Volt. No client closures.';continue
            }
            if ($candidates.Count -gt 1) {
                $entry.missingSinceUtc = $null
                $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';Warn-Throttled ('restore-'+$key) 'Pending account ambiguous in Volt. No client closures.';continue
            }
            $entry.missingSinceUtc = $null
            $a=$candidates[0]
            if ($a.cookieStatus -ceq 'moderated') {
                # Never hold the recovery queue for an account Roblox will not launch.
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account moderated by Roblox'}
                $script:recoveryPending.Remove($key);continue
            }
            if ($a.cookieStatus -cne 'alive') { $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null;$entry.status='Blocked';continue }
            if (-not $a.autoRelaunch) {
                Write-Diagnostic 'RECOVERY_CANCELLED_BY_POLICY' @{accountId=$key;note='Account no longer opted in'}
                $script:recoveryPending.Remove($key);continue
            }
            $sample=@{available=$true;accountId=$key;controlReady=[bool]$a.controlReady;autoRelaunch=[bool]$a.autoRelaunch;cookieAlive=[bool]$a.cookieAlive;uiStatus=$a.uiStatus;processId=$a.processId;trackerId=$a.trackerId;startTicks=0;windowPresent=$false;responding=$false;launchError=$false;isDisconnected=$false;gameReady=$false}
            $replacementState=$null
            if ($a.processId -and $tracked.ContainsKey([int]$a.processId)) {
                $state=$tracked[[int]$a.processId]
                if ($state.TrackerId -eq $a.trackerId -and (Test-ArkuzoClientIdentity $state.Watcher ([int]$a.processId) $state.StartTicks) -and $state.LastSnapshot) {
                    $replacementState=$state
                    $sample.sampleUtc=$state.HealthSnapshotUtc
                    $sample.startTicks=$state.StartTicks;$sample.windowPresent=$state.LastSnapshot.windowPresent;$sample.responding=$state.LastSnapshot.responding
                    $sample.launchError=$state.LastSnapshot.launchError;$sample.isDisconnected=[bool]$state.isDisconnected;$sample.gameReady=[bool]$state.GameReady
                }
            }
            $decision=Get-ArkuzoOutcomeDecision $entry $sample $utc $outcomePolicy
            if ($decision -ne $entry.status) {
                Write-Diagnostic 'RECOVERY_OUTCOME_STATE' @{accountId=$key;previous=$entry.status;status=$decision;replacementPid=$sample.processId}
                $entry.status=$decision
            }
            if ($decision -eq 'Ready') {
                Write-Diagnostic 'ACCOUNT_RESTORED_VERIFIED' @{accountId=$key;username=$a.username;pid=$sample.processId;startTicks=$sample.startTicks;note='Exact account + new generation + connected socket + responsive window + server acceptance + stable confirmation. Not an endurance guarantee.'}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                $script:recoveryPending.Remove($key);continue
            }
            if ($native -and $decision -eq 'Observing' -and $null -ne $replacementState -and -not $sample.windowPresent -and
                [long]$replacementState.StartTicks -gt 0 -and
                (($utc.ToUniversalTime().Ticks - [long]$replacementState.StartTicks) / 1e7) -ge [double](Get-ArkuzoVaultSetting $script:nativeVault 'launchTimeoutSec' 120 30 600)) {
                # A client Arkuzo launched that never opened its window (9 Nov: 12 min,
                # 0% CPU, under memory pressure) is never healthy, and the hang check
                # only covers windows: close exactly that process so the next pass
                # launches the account again (retry count and quarantine still apply).
                $stalledPid=[int]$a.processId
                Write-Diagnostic 'NATIVE_LAUNCH_STALLED' @{accountId=$key;username=$a.username;pid=$stalledPid;startTicks=[long]$replacementState.StartTicks;note='No window after the launch timeout; closing it for a fresh launch.'}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                try {
                    $replacementState.Closing = $true # Nothing else touches it from here on.
                    if (Test-ArkuzoClientIdentity $replacementState.Watcher $stalledPid $replacementState.StartTicks) { $replacementState.Watcher.Kill() }
                } catch { Warn-Throttled ('stalled-'+$key) ((Get-ArkuzoAccountDisplayLabel -AccountId $key)+': a launch without a window could not be closed: '+$_.Exception.Message) }
                $entry.readySinceUtc=$null;$entry.lastObservedUtc=$null
                continue
            }
            if ($decision -eq 'LaunchMissing') {
                if ($a.cookieStatus -ceq 'dead' -or $a.cookieStatus -cne 'alive' -or -not $a.cookieAlive -or
                    ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey($key))) {
                    Write-Diagnostic 'LAUNCH_REFUSED_DEAD_COOKIE' @{accountId=$key;username=$a.username;cookieStatus=$a.cookieStatus}
                    $script:recoveryPending.Remove($key)
                    continue
                }
                if ($native -and [long]$a.closeRequestedAtMs -gt 0) { continue } # Close pressed: wait until it is done, nothing charged.
                $launchGap = if ($native) { [int](Get-ArkuzoVaultSetting $script:nativeVault 'launchDelaySec' 12 5 120) } else { [int]$restorePolicy.retry_base_sec }
                # Arkuzo: launchDelaySec is the only limit. An hourly cap would park every account
                # for the rest of the hour after an outage, a hidden backoff.
                $launchCap = if ($native) { [int]::MaxValue } else { [int]$restorePolicy.retry_max_per_hour }
                if (-not (Test-ArkuzoRecoveryBudget $launchAttempts $utc $launchGap $launchCap)) {
                    if ($native) { continue } # Launch spacing: normal, not worth a warning.
                    Warn-Throttled 'restore-budget' 'Missing-account launch budget/backoff active. Other clients remain protected; automatic retry will resume.';continue
                }
                if ($null -eq $systemMemory -or $systemMemory.commitPercent -ge $healthPolicy.pressure_percent) {
                    Warn-Throttled 'restore-pressure' 'New account launch delayed: OS commit headroom insufficient/unavailable.';continue
                }
                if ($null -ne $clock -and (Test-ArkuzoRemoteHold ([double]$clock.Elapsed.TotalSeconds))) {
                    Warn-Throttled 'remote-hold' 'Remote Desktop session is disconnected: launches and recovery wait until it reconnects.';continue
                }
                if (-not $(if ($native) { Test-ArkuzoNativeLaunchSlot $utc } else { Test-ArkuzoLaunchPacing $utc })) {
                    # Not charged: the request simply waits for a quiet launch slot.
                    Warn-Throttled 'restore-pacing' 'Missing-account launch waits for a free Volt launch slot (launches are kept apart to avoid its startup notice).';continue
                }
                # Persist and audit before invoking Volt. Never burn a duplicate fast retry after a restart.
                $entry.retryCount=[int]$entry.retryCount+1
                if ($native) { $entry.lastLaunchUtc=$utc.ToString('o') }
                $entry.nextRetryUtc=$utc.AddSeconds((Get-ArkuzoRetryDelay $entry.retryCount $restorePolicy)).ToString('o')
                # Arkuzo: a launch that produces nothing is retried after launchTimeoutSec; a refused
                # one, or one whose client closes, after the relaunch delay (Set-ArkuzoNativeLaunchRetry).
                if ($native) { $entry.nextRetryUtc=$utc.AddSeconds((Get-ArkuzoVaultSetting $script:nativeVault 'launchTimeoutSec' 120 30 600)).ToString('o') }
                $script:launchAttempts=@($launchAttempts)+@($utc)
                Save-ArkuzoRecoveryJournal
                Write-Diagnostic $(if ($native) { 'NATIVE_LAUNCH_REQUEST' } else { 'VOLT_MISSING_LAUNCH_REQUEST' }) @{accountId=$key;username=$a.username;attempt=$entry.retryCount;nextRetryUtc=$entry.nextRetryUtc}
                if ($logFailed) { throw 'Recovery requires audit logging' }
                $result=Invoke-ArkuzoVoltControl 'LaunchMissing' $key ([string]$a.trackerId)
                Write-Diagnostic $(if ($native) { 'NATIVE_LAUNCH_RESULT' } else { 'VOLT_MISSING_LAUNCH_RESULT' }) @{accountId=$key;username=$a.username;requestAccepted=($result.requestAccepted -is [bool] -and $result.requestAccepted);reason=$(if ($native) { [string]$result.reason } else { $null });note='Request acceptance is not game readiness; continue outcome verification.'}
                if (-not $result.requestAccepted) { Warn-Throttled ('restore-'+$key) $(if ($native) { (Get-ArkuzoAccountDisplayLabel -AccountId $key)+' not launched: '+$result.reason } else { 'Volt missing-account request refused/unavailable. Backoff retained, no collateral closures.' }) }
                if ($native -and -not $result.requestAccepted) { Set-ArkuzoNativeLaunchRetry $key ([string]$result.reason) }
                # Only one launch request per observation; refreshed snapshot next cycle.
                break
            }
            if ($decision -eq 'Blocked' -or ($utc-([datetime]$entry.createdUtc).ToUniversalTime()).TotalSeconds -ge 300) {
                Warn-Throttled ('restore-'+$key) ((Get-ArkuzoAccountDisplayLabel -AccountId $key)+' not restored yet ('+$decision+'). Other accounts protected; retry is bounded and monitored.')
            }
        }
        # This step can run on every pass: write the journal when something it keeps changed,
        # otherwise at most every 10 s.
        if ((Get-ArkuzoPendingSignature) -cne $journalBefore -or $null -eq $script:outcomeJournalSavedUtc -or ($utc - $script:outcomeJournalSavedUtc).TotalSeconds -ge 10 -or ($utc - $script:outcomeJournalSavedUtc).TotalSeconds -lt 0) {
            Save-ArkuzoRecoveryJournal
            $script:outcomeJournalSavedUtc = $utc
        }
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
        if ($null -ne $cfg.config_lock -and [bool]$cfg.config_lock) { Set-ArkuzoConfigLockLimits $newHealth }
        $newPagefile=Get-ArkuzoPagefilePolicy -Input $cfg.pagefile -PressurePercent $newHealth.pressure_percent
        if (-not $newPagefile.valid) { throw ('Invalid pagefile policy: '+($newPagefile.errors -join '; ')) }
        $script:healthPolicy=$newHealth;$script:restorePolicy=$newRestore;$script:pagefilePolicy=$newPagefile;$script:lastConfigText=$raw
        $script:accountProviderSetting=Get-ArkuzoProviderSetting $cfg
        # Resource settings are validated and applied separately by the main loop.
        $script:pendingLiveSettings=$cfg
        Write-Diagnostic 'CONFIG_RELOADED' @{health=$newHealth;recovery=$newRestore;pagefile=$newPagefile;note='Validated health/recovery/pagefile hot reload; resource settings are applied live except hard_limit.'}
    } catch { Warn-Throttled 'config-reload' 'Invalid/unavailable config ignored; last validated health, recovery and pagefile policy retained.' }
}
function Update-ArkuzoLiveSettings($Config) {
    $current = @{ MaxRamMB=$MaxRamMB; TrimEverySec=$TrimEverySec; CoresPerInstance=$CoresPerInstance; Priority=$Priority; EnableTrimming=[bool]$EnableTrimming
        MemoryPriority=$MemoryPriority; AdaptiveTrim=[bool]$AdaptiveTrim; PressureTrimAvailablePercent=$PressureTrimAvailablePercent; Minimize=[bool]$Minimize; PollMs=$PollMs }
    try { $next = Get-ArkuzoLiveResourceSettings $Config.settings $current }
    catch { Warn-Throttled 'settings-reload' ('Resource settings ignored: ' + $_.Exception.Message + '. Last applied values retained.'); return }
    $changed = @()
    foreach ($name in @($next.Keys)) {
        if ($script:cliBoundParameters -contains $name -or $next[$name] -eq $current[$name]) { continue }
        # Parameter validation attributes still guard each assignment.
        try { Set-Variable -Scope Script -Name $name -Value $next[$name]; $changed += $name }
        catch { Warn-Throttled 'settings-reload' ("Resource setting $name rejected: " + $_.Exception.Message) }
    }
    if ($Config.selected_preset -and $script:cliBoundParameters -notcontains 'Mode') { try { $script:Mode = [string]$Config.selected_preset } catch { } }
    if ($changed.Count -eq 0) { return }
    $script:maxBytes = [uint64]$script:MaxRamMB * 1MB
    # Reapply priority/affinity/memory priority on the next pass, not in 10s.
    foreach ($state in @($script:tracked.Values)) { $state.LastConfig = -1e6 }
    Write-Diagnostic 'SETTINGS_APPLIED_LIVE' @{changed=$changed;targetMB=$script:MaxRamMB;trimEverySec=$script:TrimEverySec;cores=$script:CoresPerInstance;priority=$script:Priority;memoryPriority=$script:MemoryPriority;adaptiveTrim=[bool]$script:AdaptiveTrim}
}
function ConvertTo-ArkuzoClientRecord($State) {
    # One shape for every row of clients[] in the heartbeat (contracts/runtime-status.json).
    # LastSnapshot is written by the full main-loop sample and patched in between by the
    # observation service with raw values (and is partial until the first full sample).
    # The heartbeat always gets the same keys, the same rounding and a UTC sample time;
    # what is not known yet is null. Identity comes from the client's own state.
    $s = $State.LastSnapshot
    if ($null -eq $s) { return $null }
    $number = { param($value, $digits) if ($null -eq $value) { $null } else { try { [math]::Round([double]$value, [int]$digits) } catch { $null } } }
    $flag = { param($value, $fallback) if ($value -is [bool]) { $value } else { $fallback } }
    $text = { param($value) if ($null -eq $value) { $null } else { [string]$value } }
    $whole = { param($value, $fallback) if ($null -ne $value) { try { [long]$value } catch { $fallback } } else { $fallback } }
    $sampleTime = $null
    if ($s['sampleTime']) { try { $sampleTime = ([datetime]$s['sampleTime']).ToUniversalTime().ToString('o') } catch { $sampleTime = $null } }
    return [ordered]@{
        pid = [int](& $whole $s['pid'] 0); startTicks = [long](& $whole $s['startTicks'] ([long]$State.StartTicks))
        cpuPercent = (& $number $s['cpuPercent'] 2); residentMB = (& $number $s['residentMB'] 1); privateMB = (& $number $s['privateMB'] 1)
        responding = (& $flag $s['responding'] $false); windowPresent = (& $flag $s['windowPresent'] $false); launchError = (& $flag $s['launchError'] $false)
        state = (& $text $s['state']); sampleTime = $sampleTime
        eligible = (& $flag $s['eligible'] $false); isDisconnected = (& $flag $s['isDisconnected'] ([bool]$State.isDisconnected))
        parentId = [int](& $whole $s['parentId'] ([int]$State.ParentId)); account = (& $text $s['account']); slot = [int](& $whole $s['slot'] ([int]$State.Slot))
        ageSec = (& $number $s['ageSec'] 0); nextTrim = (& $text $s['nextTrim'])
        gameReady = (& $flag $s['gameReady'] ([bool]$State.GameReady))
        disconnectReason = (& $text $(if ($null -ne $s['disconnectReason']) { $s['disconnectReason'] } else { $State.DisconnectReason }))
        memoryPriority = (& $text $s['memoryPriority'])
    }
}
function Write-ArkuzoRuntimeStatus {
    if ($MonitorOnly -or -not $ownsControllerMutex) { return }
    try {
        # Expired quarantines are otherwise only dropped when that account is next evaluated.
        if ($null -ne $script:quarantinedAccounts) { foreach ($key in @($script:quarantinedAccounts.Keys)) { [void](Test-ArkuzoAccountQuarantined $key ([datetime]::UtcNow)) } }
        $accounts=@($voltControlStatus.accounts|ForEach-Object{@{accountId=$_.accountId;username=$_.username;processId=$_.processId;uiStatus=$_.uiStatus;controlReady=$_.controlReady;cookieStatus=$_.cookieStatus;suspensionSafe=$_.suspensionSafe;autoRelaunch=[bool]$_.autoRelaunch}})
        $nativeFarm=(Test-ArkuzoNativeProvider) -and [bool]$voltControlStatus.farmRunning
        $expected=@($voltControlStatus.accounts|Where-Object{$_.autoRelaunch -and $_.cookieAlive -and $_.cookieStatus -ceq 'alive' -and ($nativeFarm -or [long]$_.lastLaunchAtMs -gt 0) -and $restorePolicy.excluded_account_ids -notcontains $_.accountId -and ($null -eq $script:suspendedAccounts -or -not $script:suspendedAccounts.ContainsKey([string]$_.accountId))})
        $missing=@($expected|Where-Object{-not $_.processId})
        $controlFresh=$voltControlStatus.available -and $null -ne $voltControlCheckedUtc -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -ge 0 -and ([datetime]::UtcNow-$voltControlCheckedUtc).TotalSeconds -le 25
        Save-ArkuzoAtomicJson (Join-Path $DataDirectory 'runtime-status.json') @{
            # schemaVersion and every key below are a contract with the Control Center, its page and
            # the launcher: contracts/runtime-status.json. Adding a key is compatible; anything else needs a new version.
            schemaVersion=1;version=$ArkuzoRuntimeVersion;pid=$PID;startTicks=$script:controllerStartTicks;updatedUtc=[datetime]::UtcNow.ToString('o');monitorOnly=$false;controller=$true
            clients=@($tracked.Values|Where-Object{$null -ne $_ -and $null -ne $_.LastSnapshot}|ForEach-Object{ConvertTo-ArkuzoClientRecord $_});accounts=$accounts;expectedAccounts=$expected.Count;missingAccounts=$missing.Count
            pending=@($recoveryPending.Values);pendingRecoveries=$recoveryPending.Count;suspendedAccounts=@($script:suspendedAccounts.Values);suspendedAccountCount=$script:suspendedAccounts.Count;missingRecoveryBlocked=(-not $controlFresh -or $missing.Count -gt 0 -or $recoveryPending.Count -gt 0)
            voltControlAvailable=[bool]$voltControlStatus.available;recoveryJournalHealthy=[bool]$recoveryJournalHealthy;systemMemory=$systemMemory;health=$healthPolicy;recovery=$restorePolicy;logFailed=$logFailed
            pagefilePolicy=$pagefilePolicy;pagefile=$script:pagefileStatus;nativePrivileges=$script:nativePrivilegeInitialization;graphics=$script:graphicsStatus
            updateAvailable=$script:updateAvailableStatus;remoteSession=(Get-ArkuzoRemoteStatus)
            accountProvider=$script:accountProvider;accountProviderNotice=$script:accountProviderNotice;farmRunning=[bool]$voltControlStatus.farmRunning;robloxVersion=$script:robloxVersionStatus
            quarantined=@(if ($null -ne $script:quarantinedAccounts) { $script:quarantinedAccounts.Values })
            uptimeSec=$(if ($null -ne $script:clock) { [math]::Round($script:clock.Elapsed.TotalSeconds,1) } else { 0 })
            trims=[int]$script:trimCount;totals=$script:lastTotals;totalPhysicalMB=$script:totalPhysicalMB
            settings=@{mode=$script:Mode;targetMB=$script:MaxRamMB;trimEnabled=[bool]$script:EnableTrimming;trimEverySec=$script:TrimEverySec
                effectiveTrimSec=$(if ($null -ne $script:trimPlan) { $script:trimPlan.IntervalSec } else { $script:TrimEverySec })
                trimPressure=($null -ne $script:trimPlan -and [bool]$script:trimPlan.Pressure);availablePhysicalPercent=$(if ($null -ne $script:trimPlan) { $script:trimPlan.AvailablePercent } else { $null })
                adaptiveTrim=[bool]$script:AdaptiveTrim;priority=$script:Priority;memoryPriority=$script:MemoryPriority;coresPerInstance=$script:CoresPerInstance
                softLimit=[bool]$script:SoftLimit;configLocked=[bool]$script:isConfigLocked}
            alerts=@(if ($null -ne $script:dashboardIssues) { foreach ($issue in @($script:dashboardIssues.GetEnumerator())) {
                @{key=[string]$issue.Key;message=[string]$issue.Value.Message;ageSec=$(if ($null -ne $script:clock) { [math]::Round($script:clock.Elapsed.TotalSeconds - [double]$issue.Value.Time,1) } else { 0 })} } })
        } -Volatile # Rewritten every 2 s: no flush to the disk (docs/architecture.md, 6).
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
            $continuous = $gap -gt 0 -and $gap -le 30
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
function Test-ArkuzoStartupIsolation($State, [string]$Reason, $Sample) {
    if ($null -eq $State -or $Reason -cne 'VOLT_STARTUP_ERROR') { return $false }
    if ($null -eq $Sample -or $Sample.launchError -isnot [bool] -or -not $Sample.launchError) { return $false }
    if ($State.GameReady -or $State.EverGameReady) { return $false }
    $State.StartupGameHistory = 'MODAL_STARTUP_ERROR'
    return $true
}
function Test-ArkuzoRecoveryHandoff([string]$AccountId, $State = $null, [string]$Reason = '', $Sample = $null, $Context = $null) {
    # No collateral closures while an account is missing. A confirmed unhealthy
    # replacement of that same account can retry through the persisted backoff.
    if ($null -eq $Context) { $Context = New-ArkuzoDecisionContext }
    $status = $Context.ControlStatus; $pending = $Context.RecoveryPending
    # A latched farm-freeze member is independently confirmed frozen and exactly
    # mapped; the other members' open handoffs are this same episode, not
    # collateral. Its mapping is re-proven by Get-ArkuzoFarmFreezeAccount.
    $farmMember = $null
    if ($Reason -ceq 'FARM_FREEZE' -and $AccountId) {
        $farmMember = Get-ArkuzoFarmFreezeMemberRecord $State
        if ($null -eq $farmMember -or $farmMember.status -cne 'Planned' -or $farmMember.accountId -cne $AccountId) { $farmMember = $null }
    }
    if (-not (Test-ArkuzoControlStatusFresh $Context)) { return $false }
    if ($status.globalMappingSafe -isnot [bool] -or -not $status.globalMappingSafe) {
        if ($null -eq $farmMember) { return $false }
        $account = Get-ArkuzoFarmFreezeAccount $State.TrackerId $State.Watcher.Id
        if ($null -eq $account -or $account.accountId -cne $AccountId) { return $false }
    }
    if (-not (Test-ArkuzoSuspendedRowsSafe $Context)) { return $false }
    if ($null -eq $pending) { return $false }
    if ($Context.NativeProvider) {
        # Arkuzo launches every client itself and maps each one by its own account tracker, so
        # an exactly mapped client (one account, same pid and start time on the retained handle)
        # never needs another account's relaunch to finish first. A failing account is never
        # quarantined, so letting it hold this gate would block every other recovery for good.
        if (-not $AccountId -or $null -eq $State -or $null -eq $State.Watcher -or $status.globalMappingSafe -isnot [bool] -or -not $status.globalMappingSafe) { return $false }
        if (-not (Test-ArkuzoClientIdentity $State.Watcher $State.Watcher.Id $State.StartTicks)) { return $false }
        $account = Get-ArkuzoControlledAccount $State.TrackerId $State.Watcher.Id $Context
        return ($null -ne $account -and $account.accountId -ceq $AccountId)
    }
    if ($pending.Count -eq 0) { return $true }
    if (-not $AccountId) { return $false }
    if ($null -ne $farmMember -and -not $pending.ContainsKey($AccountId)) { return $true }
    if (-not $pending.ContainsKey($AccountId)) {
        if (-not (Test-ArkuzoStartupIsolation $State $Reason $Sample) -or
            -not (Test-ArkuzoClientIdentity $State.Watcher $State.Watcher.Id $State.StartTicks)) { return $false }
        $account = Get-ArkuzoControlledAccount $State.TrackerId $State.Watcher.Id $Context
        return ($null -ne $account -and $account.accountId -ceq $AccountId -and
            $account.autoRelaunch -is [bool] -and $account.autoRelaunch -and $account.cookieAlive -is [bool] -and $account.cookieAlive)
    }
    $entry = $pending[$AccountId]
    if ($entry.nextRetryUtc -and $Context.NowUtc -lt ([datetime]$entry.nextRetryUtc).ToUniversalTime()) { return $false }
    if ($pending.Count -gt 1) {
        # Multiple unresolved accounts do not authorize collateral recycling.
        # Only the exact independently unhealthy replacement may retry. The
        # caller still reobserves the bound reason and exact owner after IO.
        if ($null -eq $State -or -not $Reason -or -not $State.HealthDecision.Recycle -or $State.HealthDecision.Reason -ne $Reason -or
            -not (Test-ArkuzoClientIdentity $State.Watcher $State.Watcher.Id $State.StartTicks)) { return $false }
        $account = Get-ArkuzoControlledAccount $State.TrackerId $State.Watcher.Id $Context
        if ($null -eq $account -or $account.accountId -cne $AccountId -or $entry.accountId -cne $AccountId -or
            ([int]$entry.oldPid -eq $State.Watcher.Id -and [long]$entry.oldStartTicks -eq [long]$State.StartTicks) -or
            ([int]$entry.replacementPid -gt 0 -and ([int]$entry.replacementPid -ne $State.Watcher.Id -or [long]$entry.replacementStartTicks -ne [long]$State.StartTicks))) { return $false }
    }
    return $true
}
function Test-ArkuzoKickedClosure($State) {
    # Arkuzo provider, client verified kicked or disconnected (its log or the executor said so):
    # it is out of the game whatever happens, so closing it costs nothing. It skips the
    # cooldown and the hourly budget and does not count against them.
    # A bare "ClientReplicator removed" signal can also come from an ordinary teleport, so
    # it keeps the normal gates; kicks, error prompts and the Roblox log's own reasons
    # (which already skip code 285, a client-initiated leave) do not.
    return ((Test-ArkuzoNativeProvider) -and $null -ne $State -and $null -ne $State.HealthDecision -and
        [string]$State.HealthDecision.Reason -ceq 'IN_GAME_DISCONNECT' -and [bool]$State.isDisconnected -and
        [string]$State.DisconnectSource -cne 'NetworkClient.ChildRemoved')
}
function Invoke-ClientRecovery([int]$ClientId, $State) {
    if ($MonitorOnly -or -not $healthPolicy.enabled -or -not $ownsControllerMutex -or $State.RecoveryRequested -or -not $State.HealthDecision.Recycle) { return }
    if (-not $restorePolicy.enabled) { Warn-Throttled 'restore-disabled' 'Account outcome recovery disabled; destructive recovery blocked.'; return }
    if (-not $recoveryJournalHealthy) { Warn-Throttled 'recovery-journal' 'Recovery blocked: invalid recovery journal. Clients left untouched.'; return }
    if ((Test-ArkuzoNativeProvider) -and -not $voltControlStatus.farmRunning) { Warn-Throttled 'farm-stopped' 'Farm is stopped: unhealthy clients are left alone. Start the farm to recover them.'; return }
    # Observation service can update the decision during IO. Bind this attempt
    # to its original reason; a changed condition needs a new authorized attempt.
    $reason = $State.HealthDecision.Reason
    # Clients in a disconnected RDP session cannot render, and neither could their
    # replacements. Critical commit pressure still protects the host.
    if ($reason -cne 'SYSTEM_COMMIT_PRESSURE' -and $null -ne $clock -and (Test-ArkuzoRemoteHold ([double]$clock.Elapsed.TotalSeconds))) {
        Warn-Throttled 'remote-hold' 'Remote Desktop session is disconnected: launches and recovery wait until it reconnects.'; return
    }
    # Re-read capability immediately before acting, not merely at startup.
    Update-VoltRecoveryCapability -SyncControl
    if (-not $voltStatus.safeToRecycle -or -not (Test-ArkuzoClientOwnership $State)) { return }
    $utc = [DateTime]::UtcNow
    $boundAccount = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
    if ($null -eq $boundAccount) {
        # A mature health decision is not permission to bypass unknown or removed
        # suspended identities. Expose this pre-request refusal instead of leaving
        # the operator with a zero trim countdown and no recovery explanation.
        Warn-Throttled 'recovery-mapping' 'Recovery blocked: exact Volt account mapping or suspended-account safety cannot be verified. Clients left untouched.'
        return
    }
    # A quarantined account would only burn the shared budget again. Critical
    # commit pressure still protects the host.
    if ($reason -cne 'SYSTEM_COMMIT_PRESSURE' -and (Test-ArkuzoAccountQuarantined ([string]$boundAccount.accountId) $utc)) {
        Warn-Throttled ('quarantine-'+$boundAccount.accountId) ((Get-ArkuzoAccountDisplayLabel -AccountId ([string]$boundAccount.accountId))+' is quarantined after repeated failed recoveries; it is left untouched until the quarantine expires.')
        return
    }
    if (-not (Test-ArkuzoNativeProvider)) {
        if ($State.ParentId -le 0 -and $script:voltParents.Count -eq 1) {
            $singleId = [int](@($script:voltParents.Keys)[0])
            $State.ParentId = $singleId
        }
        if ($voltControlStatus.managerId -ne $State.ParentId -or $voltControlStatus.managerStartTicks -ne $script:voltParents[$State.ParentId].StartTicks) { return }
    }
    $handoffSample = $null
    if ($recoveryPending.Count -gt 0) {
        # Refreshing launcher authority temporarily clears retained parents.
        # Observations during that IO are valid failure evidence but ineligible
        # for closure. Recompute with actual evidence after authority returns;
        # never treat the transient eligible=false as a permanent deadlock.
        try { $handoffSample = Get-ArkuzoRecoveryHealthSample $State.Watcher $reason $State }
        catch { Reset-ArkuzoHealthSample $State; return }
        $State.HealthDecision = Get-ArkuzoHealthDecision $State $handoffSample $healthPolicy $clock.Elapsed.TotalSeconds
        if (-not $State.HealthDecision.Recycle -or $State.HealthDecision.Reason -ne $reason) { return }
    }
    if (-not (Test-ArkuzoRecoveryHandoff ([string]$boundAccount.accountId) $State $reason $handoffSample)) {
        $label = Get-ArkuzoAccountDisplayLabel -ProcessId $ClientId -TrackerId $State.TrackerId
        $detail = if ($reason -ceq 'VOLT_STARTUP_ERROR' -and -not $recoveryPending.ContainsKey([string]$boundAccount.accountId)) {
            'Startup game history is UNKNOWN: complete exact-generation history cannot be verified.'
        } else { 'Waiting for exact account restoration/backoff.' }
        Warn-Throttled 'recovery-handoff' ("${label}: $detail Other accounts left untouched.")
        return
    }
    $kicked = Test-ArkuzoKickedClosure $State
    $effectiveCooldown = Get-ArkuzoRecoveryCooldown $reason $healthPolicy
    if (-not $kicked -and -not (Test-ArkuzoRecoveryBudget $recoveryAttempts $utc $effectiveCooldown $healthPolicy.max_recycles_per_hour)) {
        Warn-Throttled 'recovery-budget' 'Recovery cooldown/hourly budget reached. No restart storm.'; return
    }
    $farmEpisode = $(if ($reason -ceq 'FARM_FREEZE' -and (Test-ArkuzoFarmFreezeMember $State)) { [string]$script:farmFreeze.Id } else { $null })
    if ($reason -ceq 'FARM_FREEZE' -and (-not $farmEpisode -or -not (Test-ArkuzoFarmFreezeSlot))) { return }
    $watcher = $State.Watcher
    if (-not (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) { Reset-ArkuzoHealthSample $State; return }
    # An unmapped target is not a termination attempt. Do not charge its budget.
    if (-not (Test-ArkuzoTargetRecovery $watcher $ClientId $State.StartTicks)) { return }
    $handoffKey = [string]$boundAccount.accountId
    $openHandoffs = ($recoveryPending.Count -gt 0)
    $verifyStartupIsolation = ($openHandoffs -and -not $recoveryPending.ContainsKey($handoffKey) -and $reason -ceq 'VOLT_STARTUP_ERROR')
    $reserved = $false; $previousPending = $null
    try {
        # Persist before closing: restarting ArkuzoSaver cannot reset the budget. A kicked client
        # (Arkuzo provider) is not charged.
        $script:recoveryAttempts = @($recoveryAttempts | Where-Object { ($utc - $_).TotalSeconds -lt 3600 }) + @(if (-not $kicked) { $utc })
        $entry = New-ArkuzoPendingEntry $handoffKey $State.TrackerId $ClientId $State.StartTicks
        if ($recoveryPending.ContainsKey($handoffKey)) {
            $previousPending = $recoveryPending[$handoffKey].Clone()
            $entry.retryCount = [int]$previousPending.retryCount + 1
        }
        $entry.nextRetryUtc = $utc.AddSeconds((Get-ArkuzoRetryDelay ([math]::Max(1,[int]$entry.retryCount)) $restorePolicy)).ToString('o')
        # Arkuzo relaunches by itself after relaunchDelaySec: no backoff for a normal relaunch.
        if (Test-ArkuzoNativeProvider) { $entry.nextRetryUtc = $null }
        if ($farmEpisode) { $entry.farmFreezeEpisode = $farmEpisode }
        $script:recoveryPending[$handoffKey] = $entry
        $reserved = $true
        Save-ArkuzoRecoveryJournal
        Write-Diagnostic 'RECOVERY_REQUESTED' @{ accountId = $handoffKey; pid = $ClientId; startTicks = $State.StartTicks; reason = $reason; lastSample = $State.LastSnapshot; systemMemory = $systemMemory; relaunchOwner = $(if (Test-ArkuzoNativeProvider) { 'Arkuzo' } else { 'Volt account manager' }); farmFreezeEpisode = $farmEpisode }
        if ($logFailed) { throw 'Recovery requires functioning audit logging' }
        if (-not (Test-ArkuzoTargetRecovery $watcher $ClientId $State.StartTicks)) { return }
        # Open handoffs require a new fully safe farm mapping after audit/probe
        # IO, followed by actual window evidence; never refresh evidence time
        # merely because the launcher observation succeeded.
        if ($openHandoffs) {
            Update-ArkuzoVoltControl
            $freshAccount = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
            if ($null -eq $freshAccount -or $freshAccount.accountId -cne $handoffKey -or
                (-not (Test-ArkuzoNativeProvider) -and ($voltControlStatus.managerId -ne $State.ParentId -or $voltControlStatus.managerStartTicks -ne $script:voltParents[$State.ParentId].StartTicks)) -or
                $freshAccount.autoRelaunch -isnot [bool] -or -not $freshAccount.autoRelaunch -or $freshAccount.cookieAlive -isnot [bool] -or -not $freshAccount.cookieAlive) { return }
        }
        # The triggering condition may have cleared while probing/persisting/logging.
        try { $freshSample = Get-ArkuzoRecoveryHealthSample $watcher $reason $State }
        catch { Reset-ArkuzoHealthSample $State; throw }
        $State.HealthDecision = Get-ArkuzoHealthDecision $State $freshSample $healthPolicy $clock.Elapsed.TotalSeconds
        if (-not $State.HealthDecision.Recycle -or $State.HealthDecision.Reason -ne $reason) { return }
        if ($reason -ceq 'VOLT_STARTUP_ERROR' -and ($State.GameReady -or $State.EverGameReady -or $State.isDisconnected -or $freshSample.isDisconnected)) { return }
        if ($verifyStartupIsolation -and -not (Test-ArkuzoStartupIsolation $State $reason $freshSample)) { return }
        if (-not (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks)) { Reset-ArkuzoHealthSample $State; return }
        # Check the retained exact owner after IO, immediately before termination.
        # This narrows the race; it cannot make two processes' lifetimes atomic.
        if (-not (Test-ArkuzoNativeProvider) -and -not (Test-ArkuzoLiveVoltParent $script:voltParents[$State.ParentId])) { return }
        $rebound = Get-ArkuzoControlledAccount $State.TrackerId $ClientId
        if ($null -eq $rebound -or $rebound.accountId -ne $handoffKey) { return }
        if ($logFailed -or -not $recoveryJournalHealthy) { return }
        $State.RecoveryRequested = $true
        $State.RecoveryStatus = 'Pending'
        # Retained handle prevents accidentally killing a reused PID.
        $watcher.Kill()
        if (-not $watcher.WaitForExit(2000)) { throw 'Client termination not confirmed' }
        $State.RecoveryStatus = 'ExitVerified'
        # Only now may this member's Volt row be unmapped for the rest of the episode.
        if ($farmEpisode) { Set-ArkuzoFarmFreezeMemberStatus $State 'Closed' }
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
                if ($farmEpisode) { Set-ArkuzoFarmFreezeMemberStatus $State 'Closed' }
                Write-Diagnostic 'CLIENT_CLOSED_FOR_RECOVERY' @{ pid = $ClientId; startTicks = $State.StartTicks; reason = $State.HealthDecision.Reason; note = 'Exit verified after termination error. Volt relaunch/game readiness remains a separate observation.' }
            } elseif (Test-ArkuzoClientIdentity $watcher $ClientId $State.StartTicks) {
                $State.RecoveryStatus = 'Failed'
                $State.RecoveryRequested = $false # Retry still consumes the persistent cooldown/hourly budget.
            }
        }
        $label = Get-ArkuzoAccountDisplayLabel -ProcessId $ClientId -TrackerId $State.TrackerId
        Warn-Throttled 'recovery-failed' ("Recovery failed for ${label}: $failure")
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
function Invoke-ArkuzoRecoveryCandidates {
    # At most one recovery per main-loop pass. While a farm-freeze episode runs,
    # only its members are recycled, so Volt launches stay paced. Try largest
    # first, skipping unready targets without charging a budget.
    $farmFreezeActive = Test-ArkuzoFarmFreezeActive
    $eligible = @($tracked.GetEnumerator() | Where-Object {
        $_.Value.HealthDecision.Recycle -and
        -not $_.Value.RecoveryRequested -and
        (-not $farmFreezeActive -or (Test-ArkuzoFarmFreezeMember $_.Value)) -and
        ($null -eq $_.Value.LastRecoveryRefusalUtc -or (([DateTime]::UtcNow) - $_.Value.LastRecoveryRefusalUtc).TotalSeconds -ge 30)
    })
    # Episode members in the order they froze: the earliest also quits first.
    $ordered = if ($farmFreezeActive) { @($eligible | Sort-Object { [double]$_.Value.FreezeSince }) } else { @($eligible | Sort-Object { $_.Value.LastSnapshot.privateMB } -Descending) }
    # Arkuzo provider: verified kicked clients first, and all of them in this pass; anything
    # else stays one closure per pass behind the cooldown and hourly budget.
    if (Test-ArkuzoNativeProvider) { $ordered = @(@($ordered | Where-Object { Test-ArkuzoKickedClosure $_.Value }) + @($ordered | Where-Object { -not (Test-ArkuzoKickedClosure $_.Value) })) }
    foreach ($candidate in $ordered) {
        $kicked = Test-ArkuzoKickedClosure $candidate.Value
        $effectiveCooldown = Get-ArkuzoRecoveryCooldown ([string]$candidate.Value.HealthDecision.Reason) $healthPolicy
        if (-not $kicked -and -not (Test-ArkuzoRecoveryBudget $recoveryAttempts ([DateTime]::UtcNow) $effectiveCooldown $healthPolicy.max_recycles_per_hour)) {
            # Cooldown is reason-specific: a larger blocked hang/memory
            # target must not starve a startup error with its own safe budget.
            Warn-Throttled 'recovery-budget' 'Recovery cooldown/hourly budget reached. No restart storm.'; continue
        }
        if ($null -ne ('Arkuzo.LoopWatchdogV1' -as [type])) { [Arkuzo.LoopWatchdogV1]::Mark('recovering client ' + $candidate.Key) }
        Invoke-ClientRecovery $candidate.Key $candidate.Value
        if ($candidate.Value.RecoveryRequested -and -not $kicked) { break }
    }
}
function Clear-ArkuzoOutcomeObservation($State) {
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
}
function Reset-ArkuzoHealthSample($State) {
    if ($null -eq $State) { return }
    Clear-ArkuzoOutcomeObservation $State
    $State.HealthDecision = $null
    $State.LastSnapshot = $null
    $State.HealthSnapshotUtc = $null
    $State.HangSince = -1.0
    $State.FreezeSince = -1.0
    $State.StartupErrorSince = -1.0
    $State.DisconnectSince = -1.0
    $State.DisconnectReason = $null
    $State.isDisconnected = $false
    $State.LastHealthSampleTime = $null
    $State.PrivateLimitSince = -1.0
    $State.HangCpuBase = $null; $State.HangCpuBaseAt = $null; $State.HangCpuPercent = $null
}
function Get-ArkuzoHealthDecision($State, $Sample, $Policy, [double]$Now) {
    $reason = ''; $status = ''
    # A >30s gap (or clock rollback) breaks continuous observation, even when
    # both endpoint samples succeeded. Polling is sub-second on a quiet PC, but
    # a farm deep in the pagefile takes 2-8 s per pass. The old 5 s cut-off reset
    # every timer on those passes, so a frozen client (9 Nov 05:13-06:10) and one
    # over the memory limit were never recovered. A truly stuck loop is the
    # stall watchdog's job.
    if ($null -eq $State.LastHealthSampleTime -or $Now -lt [double]$State.LastHealthSampleTime) {
        $State.HangSince = -1.0
        $State.FreezeSince = -1.0
        $State.StartupErrorSince = -1.0
        $State.DisconnectSince = -1.0
        $State.PrivateLimitSince = -1.0
    } elseif (($Now - [double]$State.LastHealthSampleTime) -gt 30) {
        $State.HangSince = -1.0
        $State.FreezeSince = -1.0
        $State.PrivateLimitSince = -1.0
    }
    $State.LastHealthSampleTime = $Now
    if ($null -eq $State.HangSince) { $State.HangSince = -1.0 }
    if ($null -eq $State.FreezeSince) { $State.FreezeSince = -1.0 }
    # When this client started, on the same clock: a client launched after a
    # freeze began says nothing about that freeze (see Get-ArkuzoFarmFreezeCandidate).
    if ($null -eq $State.StartedSec -and $null -ne $Sample.ageSec) { $State.StartedSec = $Now - [double]$Sample.ageSec }
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
        $State.FreezeSince = -1.0
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
        $State.FreezeSince = -1.0
        if ([double]$State.DisconnectSince -lt 0) { $State.DisconnectSince = $Now }
        $timeout = if ($null -ne $Policy.disconnect_timeout_sec) { [double]$Policy.disconnect_timeout_sec } else { 5.0 }
        $retry = [bool]$Sample.eligible -and [double]$State.DisconnectSince -ge 0 -and ($Now - [double]$State.DisconnectSince) -ge $timeout
        return [pscustomobject]@{ Reason = 'IN_GAME_DISCONNECT'; Recycle = $retry; Status = 'DISCONNECTED' }
    }
    $State.DisconnectSince = -1.0
    # Freeze onset for the farm-freeze path only, tracked through warm-up too:
    # clients that freeze while starting quit by themselves ~197 s later like any
    # other frozen client. A window that never answered yet is still loading and
    # does not count; past warm-up this matches HangSince.
    $warm = [double]$Sample.ageSec -lt [double]$Policy.warmup_sec
    if ($Sample.windowPresent -and $Sample.responding) { $State.EverResponded = $true }
    if ($Sample.windowPresent -and -not $Sample.responding -and ($State.EverResponded -or -not $warm)) {
        if ([double]$State.FreezeSince -lt 0) { $State.FreezeSince = $Now }
    } else { $State.FreezeSince = -1.0 }
    if ($warm) {
        $State.HangSince = -1.0
        # A latched episode member is confirmed with the rest of the farm, even
        # while it is still in warm-up; nothing else is recycled during warm-up.
        if ([double]$State.FreezeSince -ge 0 -and $Policy.farm_freeze_enabled -and (Test-ArkuzoFarmFreezeMember $State) -and
            ($null -eq $State.HangCpuPercent -or [double]$State.HangCpuPercent -le [double]$Policy.farm_freeze_max_cpu_percent)) {
            return [pscustomobject]@{ Reason = 'FARM_FREEZE'; Recycle = [bool]$Sample.eligible; Status = 'FARM FREEZE' }
        }
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
    }
    # Memory grace is not a recovery reason: an independently mature hang
    # remains actionable. Confirmed memory/pressure retains its precedence.
    if (-not $reason -and $Sample.windowPresent -and -not $Sample.responding) {
        $status = 'HANG GRACE'
        if (($Now - [double]$State.HangSince) -ge [double]$Policy.hang_timeout_sec) {
            $reason = 'SUSTAINED_HANG'; $status = 'STUCK CLIENT'
        } elseif ($Policy.farm_freeze_enabled -and (Test-ArkuzoFarmFreezeMember $State) -and
                  ($null -eq $State.HangCpuPercent -or [double]$State.HangCpuPercent -le [double]$Policy.farm_freeze_max_cpu_percent)) {
            # Latched episode member: confirmed together with the rest of the farm.
            $reason = 'FARM_FREEZE'; $status = 'FARM FREEZE'
        }
    }
    return [pscustomobject]@{ Reason = $reason; Recycle = ([bool]$Sample.eligible -and $reason -ne ''); Status = $status }
}

# Optional pagefile helpers. These functions never enable Windows pagefile management
# or reboot the host; the caller must explicitly opt in and retain recovery policy.
function Get-ArkuzoPagefileValue {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}
function Test-ArkuzoPagefileNumber {
    param($Value, [double]$Minimum, [double]$Maximum, [switch]$Integer)
    if ($Value -is [bool] -or $Value -is [string] -or $null -eq $Value) { return $false }
    if ($Value -isnot [ValueType]) { return $false }
    try {
        $n = [double]$Value
        return (-not [double]::IsNaN($n) -and -not [double]::IsInfinity($n) -and
            $n -ge $Minimum -and $n -le $Maximum -and (-not $Integer -or [math]::Floor($n) -eq $n))
    } catch { return $false }
}
function Get-ArkuzoPagefilePolicy {
    # Alias avoids PowerShell's automatic $input enumerator. Input is the pagefile subsection.
    param([Alias('Input')]$Configuration = $null, $PressurePercent = 88)
    $values = [ordered]@{
        enabled = $false; growth_step_mb = 4096; max_file_mb = 163840; max_total_mb = 163840
        reserve_free_bytes = [int64]16106127360; reserve_free_percent = 10
        trigger_percent = 80; cooldown_sec = 3600; max_requests_per_boot = 1; max_boot_growth_mb = 4096
    }
    $errors = New-Object 'Collections.Generic.List[string]'
    if ($null -ne $Configuration) {
        if ($Configuration -is [Collections.IDictionary]) { $keys = @($Configuration.Keys) }
        elseif ($Configuration -is [pscustomobject]) { $keys = @($Configuration.PSObject.Properties.Name) }
        else { $keys = @(); $errors.Add('Input must be a pagefile configuration object.') }
        foreach ($key in $keys) {
            if (-not $values.Contains([string]$key)) { $errors.Add("Unknown pagefile option: $key"); continue }
            $values[$key] = Get-ArkuzoPagefileValue $Configuration ([string]$key)
        }
    }
    if ($values.enabled -isnot [bool]) { $errors.Add('enabled must be a literal boolean.') }
    $bounds = @{
        growth_step_mb = @(1,8192); max_file_mb = @(1,163840); max_total_mb = @(1,262144)
        reserve_free_bytes = @([int64]1048576,[int64]1099511627776)
        cooldown_sec = @(60,86400); max_requests_per_boot = @(1,4); max_boot_growth_mb = @(1,32768)
    }
    foreach ($key in $bounds.Keys) {
        if (-not (Test-ArkuzoPagefileNumber $values[$key] $bounds[$key][0] $bounds[$key][1] -Integer)) {
            $errors.Add("$key must be an integer in [$($bounds[$key][0]), $($bounds[$key][1])].")
        }
    }
    if (-not (Test-ArkuzoPagefileNumber $values.reserve_free_percent 1 50)) { $errors.Add('reserve_free_percent must be in [1, 50].') }
    if (-not (Test-ArkuzoPagefileNumber $PressurePercent 2 99)) { $errors.Add('PressurePercent must be in [2, 99].') }
    if (-not (Test-ArkuzoPagefileNumber $values.trigger_percent 1 98)) { $errors.Add('trigger_percent must be in [1, 98].') }
    if ((Test-ArkuzoPagefileNumber $values.max_total_mb 1 262144 -Integer) -and
        (Test-ArkuzoPagefileNumber $values.max_file_mb 1 163840 -Integer) -and $values.max_total_mb -lt $values.max_file_mb) {
        $errors.Add('max_total_mb must be at least max_file_mb.')
    }
    if ((Test-ArkuzoPagefileNumber $values.trigger_percent 1 98) -and
        (Test-ArkuzoPagefileNumber $PressurePercent 2 99) -and $values.trigger_percent -ge $PressurePercent) {
        $errors.Add('trigger_percent must precede PressurePercent.')
    }
    $values.enabled = ($errors.Count -eq 0 -and $values.enabled -is [bool] -and $values.enabled)
    $values['pressure_percent'] = $PressurePercent
    $values['valid'] = ($errors.Count -eq 0); $values['errors'] = @($errors.ToArray())
    return [pscustomobject]$values
}

function Get-ArkuzoPagefileUtcNow {
    param([hashtable]$Dependencies = @{})
    $value = if ($Dependencies.ContainsKey('UtcNow')) { & $Dependencies.UtcNow } else { [datetime]::UtcNow }
    if ($value -isnot [datetime]) { throw 'UtcNow seam must return one DateTime.' }
    return $value.ToUniversalTime()
}
function Test-ArkuzoPagefileAdministrator {
    param([hashtable]$Dependencies = @{})
    if ($Dependencies.ContainsKey('IsAdministrator')) { $value = & $Dependencies.IsAdministrator }
    else {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            $value = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } finally { $identity.Dispose() }
    }
    if ($value -isnot [bool]) { throw 'Administrator check must return one literal boolean.' }
    return $value
}
function Read-ArkuzoPagefileCim {
    param([string]$ClassName, [hashtable]$Dependencies = @{})
    if ($Dependencies.ContainsKey('ReadCim')) { return (& $Dependencies.ReadCim $ClassName) }
    return (Get-CimInstance -Namespace 'root/cimv2' -ClassName $ClassName -ErrorAction Stop)
}
function Get-ArkuzoPagefileSnapshot {
    # Read only. Instance is retained solely for updating the exact freshly re-read setting.
    param([hashtable]$Dependencies = @{})
    $snapshot = [pscustomobject]@{
        available = $false; capturedUtc = $null; bootId = $null; computerName = $null
        automaticManagedPagefile = $null; isAdministrator = $false
        settings = @(); usage = @(); drives = @(); error = $null
    }
    try {
        $snapshot.capturedUtc = (Get-ArkuzoPagefileUtcNow $Dependencies).ToString('o')
        $computers = @(Read-ArkuzoPagefileCim 'Win32_ComputerSystem' $Dependencies)
        $systems = @(Read-ArkuzoPagefileCim 'Win32_OperatingSystem' $Dependencies)
        if ($computers.Count -ne 1 -or $systems.Count -ne 1 -or
            $computers[0].AutomaticManagedPagefile -isnot [bool] -or
            [string]::IsNullOrWhiteSpace([string]$computers[0].Name) -or
            $systems[0].LastBootUpTime -isnot [datetime]) { throw 'Missing or ambiguous computer/boot/automatic-management identity.' }
        $snapshot.computerName = [string]$computers[0].Name
        $snapshot.bootId = $snapshot.computerName + ':' + $systems[0].LastBootUpTime.ToUniversalTime().Ticks
        $snapshot.automaticManagedPagefile = $computers[0].AutomaticManagedPagefile
        $snapshot.isAdministrator = Test-ArkuzoPagefileAdministrator $Dependencies
        $snapshot.settings = @(foreach ($row in @(Read-ArkuzoPagefileCim 'Win32_PageFileSetting' $Dependencies)) {
            $class = 'Win32_PageFileSetting'; $namespace = 'root/cimv2'; $server = $snapshot.computerName
            if ($null -ne $row.CimSystemProperties) {
                $class = [string]$row.CimSystemProperties.ClassName
                $namespace = [string]$row.CimSystemProperties.Namespace
                $server = [string]$row.CimSystemProperties.ServerName
            }
            [pscustomobject]@{
                name = $row.Name; settingId = $row.SettingID; initialSizeMB = $row.InitialSize; maximumSizeMB = $row.MaximumSize
                cimClass = $class; cimNamespace = $namespace; cimServer = $server; instance = $row
            }
        })
        $snapshot.usage = @(foreach ($row in @(Read-ArkuzoPagefileCim 'Win32_PageFileUsage' $Dependencies)) {
            [pscustomobject]@{name=$row.Name; allocatedMB=$row.AllocatedBaseSize; temporary=$row.TempPageFile}
        })
        $snapshot.drives = @(foreach ($row in @(Read-ArkuzoPagefileCim 'Win32_LogicalDisk' $Dependencies)) {
            [pscustomobject]@{
                deviceId=$row.DeviceID; driveType=$row.DriveType; sizeBytes=$row.Size; freeBytes=$row.FreeSpace
                volumeSerial=$row.VolumeSerialNumber; fileSystem=$row.FileSystem
            }
        })
        if ($snapshot.settings.Count -gt 16 -or $snapshot.usage.Count -gt 16 -or $snapshot.drives.Count -gt 26) { throw 'Snapshot exceeds bounded local pagefile/drive inventory.' }
        $snapshot.available = $true
    } catch {
        $snapshot.error = [pscustomobject]@{stage='SnapshotRead';type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
    }
    return $snapshot
}

function Get-ArkuzoPagefileGrowthDecision {
    # Pure decision: only manually fixed, already active root pagefile.sys files qualify.
    param($Snapshot, $Policy, $SystemMemory)
    $decision = [pscustomobject]@{
        eligible=$false; status='InvalidPolicy'; reason='Pagefile policy is missing or invalid.'; validationErrors=@()
        targetName=$null; target=$null; drive=$null; oldInitialSizeMB=0; oldMaximumSizeMB=0
        oldAllocatedMB=0; newInitialSizeMB=0; newMaximumSizeMB=0; growthMB=0
        totalConfiguredMB=0; reserveBytes=[int64]0; diskChargeBytes=[int64]0
    }
    if ($null -eq $Policy -or $Policy.valid -isnot [bool] -or -not $Policy.valid) {
        $decision.validationErrors=@(Get-ArkuzoPagefileValue $Policy 'errors' @()); return $decision
    }
    # Revalidate numeric bounds even if a caller changed a previously validated object.
    $inputValues = @{}
    foreach ($key in @('enabled','growth_step_mb','max_file_mb','max_total_mb','reserve_free_bytes',
        'reserve_free_percent','trigger_percent','cooldown_sec','max_requests_per_boot','max_boot_growth_mb')) {
        $inputValues[$key] = Get-ArkuzoPagefileValue $Policy $key
    }
    $p = Get-ArkuzoPagefilePolicy -Input $inputValues -PressurePercent $Policy.pressure_percent
    if (-not $p.valid) { $decision.validationErrors=@($p.errors); return $decision }
    if (-not $p.enabled) { $decision.status='Disabled'; $decision.reason='Pagefile management is opt-in and disabled.'; return $decision }
    if ($null -eq $Snapshot -or $Snapshot.available -isnot [bool] -or -not $Snapshot.available -or
        $Snapshot.automaticManagedPagefile -isnot [bool] -or [string]::IsNullOrWhiteSpace([string]$Snapshot.bootId)) {
        $decision.status='SnapshotUnavailable'; $decision.reason='Pagefile/boot identity could not be read safely.'; return $decision
    }
    $settings = @($Snapshot.settings); $usage = @($Snapshot.usage)
    if ($Snapshot.automaticManagedPagefile -or @($settings | Where-Object {
        (Test-ArkuzoPagefileNumber $_.initialSizeMB 0 0 -Integer) -and
        (Test-ArkuzoPagefileNumber $_.maximumSizeMB 0 0 -Integer)
    }).Count -gt 0) {
        $decision.status='WindowsManaged'; $decision.reason='Windows manages pagefile growth; no configuration writes are permitted.'; return $decision
    }
    if ($Snapshot.isAdministrator -isnot [bool] -or -not $Snapshot.isAdministrator) {
        $decision.status='NotAdministrator'; $decision.reason='An elevated administrator token is required.'; return $decision
    }
    if (-not (Test-ArkuzoPagefileNumber $SystemMemory.commitUsedMB 0 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $SystemMemory.commitLimitMB 1 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $SystemMemory.commitPercent 0 100) -or
        [math]::Abs((100.0 * $SystemMemory.commitUsedMB / $SystemMemory.commitLimitMB) - $SystemMemory.commitPercent) -gt 0.2) {
        $decision.status='MemoryUnavailable'; $decision.reason='Fresh consistent OS commit telemetry is required.'; return $decision
    }
    if ($SystemMemory.commitPercent -lt $p.trigger_percent) {
        $decision.status='BelowTrigger'; $decision.reason='OS commit is below the early pagefile trigger.'; return $decision
    }
    $decision.status='UnsupportedLayout'; $decision.reason='Only unambiguous existing, active, fixed-size local pagefiles are supported.'
    if ($settings.Count -lt 1 -or $settings.Count -gt 16 -or $usage.Count -ne $settings.Count) { return $decision }
    $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total = [int64]0
    foreach ($file in $settings) {
        if ($file.name -isnot [string] -or $file.name -notmatch '^[A-Za-z]:\\pagefile\.sys$' -or -not $names.Add($file.name) -or
            $file.cimClass -ine 'Win32_PageFileSetting' -or ([string]$file.cimNamespace).Replace('\','/').Trim('/') -ine 'root/cimv2' -or
            -not (Test-ArkuzoPagefileNumber $file.initialSizeMB 1 4294967295 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $file.maximumSizeMB 1 4294967295 -Integer) -or $file.initialSizeMB -ne $file.maximumSizeMB) { return $decision }
        if ($file.cimServer -and $file.cimServer -ine $Snapshot.computerName -and $file.cimServer -ine 'localhost' -and $file.cimServer -ne '.') { return $decision }
        $active = @($usage | Where-Object { $_.name -ieq $file.name })
        if ($active.Count -ne 1 -or $active[0].temporary -isnot [bool] -or $active[0].temporary -or
            -not (Test-ArkuzoPagefileNumber $active[0].allocatedMB 1 4294967295 -Integer)) { return $decision }
        if ($active[0].allocatedMB -lt $file.initialSizeMB) {
            $decision.status='PendingReboot'; $decision.reason='Configured capacity is not active; another growth request is unsafe.'; return $decision
        }
        if ($active[0].allocatedMB -gt $file.maximumSizeMB) {
            $decision.status='RuntimeMismatch'; $decision.reason='Active allocation exceeds fixed configuration; never reduce it.'; return $decision
        }
        $total += [int64]$file.maximumSizeMB
    }
    $decision.totalConfiguredMB = $total
    $decision.status='AtCeiling'; $decision.reason='Per-file or total configured capacity is already at its ceiling.'
    foreach ($file in @($settings | Sort-Object name)) {
        $growth = [int64][math]::Min([int64]$p.growth_step_mb, [math]::Min([int64]$p.max_boot_growth_mb,
            [math]::Min([int64]($p.max_file_mb - $file.maximumSizeMB), [int64]($p.max_total_mb - $total))))
        if ($growth -lt 1) { continue }
        $drives = @($Snapshot.drives | Where-Object { $_.deviceId -ieq $file.name.Substring(0,2) })
        if ($drives.Count -ne 1 -or $drives[0].driveType -ne 3 -or
            [string]::IsNullOrWhiteSpace([string]$drives[0].volumeSerial) -or
            [string]::IsNullOrWhiteSpace([string]$drives[0].fileSystem) -or
            -not (Test-ArkuzoPagefileNumber $drives[0].sizeBytes 1 9007199254740991 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $drives[0].freeBytes 0 $drives[0].sizeBytes -Integer)) {
            $decision.status='UnknownDrive'; $decision.reason='Target must map to one known fixed local volume with capacity/free-space identity.'; return $decision
        }
        $drive = $drives[0]
        $reserve = [int64][math]::Max([int64]$p.reserve_free_bytes, [int64][math]::Ceiling($drive.sizeBytes * $p.reserve_free_percent / 100.0))
        $diskGrowthMB = [int64][math]::Floor(($drive.freeBytes - $reserve) / 1MB)
        $growth = [int64][math]::Min([int64]$growth, [int64]$diskGrowthMB)
        if ($growth -lt 1) { $decision.status='LowDiskSpace'; $decision.reason='Growth would breach absolute or percentage free-disk reserve.'; continue }
        $decision.eligible=$true; $decision.status='Eligible'; $decision.reason='One existing fixed pagefile can grow within all bounds.'
        $decision.targetName=$file.name; $decision.target=$file; $decision.drive=$drive
        $decision.oldInitialSizeMB=[int64]$file.initialSizeMB; $decision.oldMaximumSizeMB=[int64]$file.maximumSizeMB
        $decision.oldAllocatedMB=[int64]$file.maximumSizeMB; $decision.growthMB=$growth
        $decision.newInitialSizeMB=[int64]$file.initialSizeMB + $growth
        $decision.newMaximumSizeMB=[int64]$file.maximumSizeMB + $growth
        $decision.reserveBytes=$reserve; $decision.diskChargeBytes=[int64]$growth * 1MB
        return $decision
    }
    return $decision
}

function Get-ArkuzoPagefileProvisioningDecision {
    param($Snapshot, $Policy, [string]$TargetDriveLetter = 'C')
    $decision = [pscustomobject]@{
        eligible = $false; status = 'InvalidPolicy'; reason = $null
        targetDrive = $TargetDriveLetter; targetName = "$($TargetDriveLetter):\pagefile.sys"
        targetSizeMB = 0; diskGrowthMB = 0; freeSpaceAfterMB = 0; error = $null
    }
    if ($null -eq $Policy -or -not $Policy.valid) { $decision.reason = 'Valid pagefile policy is required.'; return $decision }
    if (-not $Policy.enabled) { $decision.status = 'Disabled'; $decision.reason = 'Pagefile management is opt-in and disabled.'; return $decision }
    if ($null -eq $Snapshot -or -not $Snapshot.available) { $decision.status = 'SnapshotUnavailable'; $decision.reason = 'Pagefile snapshot is unavailable.'; return $decision }
    if (-not $Snapshot.isAdministrator) { $decision.status = 'NotAdministrator'; $decision.reason = 'Elevated administrator token is required.'; return $decision }

    $targetSize = [int64]$Policy.max_file_mb
    if ($targetSize -lt 1024 -or $targetSize -gt 163840) { $decision.reason = 'Target size out of bounds.'; return $decision }
    $decision.targetSizeMB = $targetSize

    # Match target drive
    $driveId = "$($TargetDriveLetter):"
    $drive = @($Snapshot.drives | Where-Object { $_.deviceId -ceq $driveId }) | Select-Object -First 1
    if ($null -eq $drive -or $drive.driveType -ne 3 -or ($drive.fileSystem -cne 'NTFS' -and $drive.fileSystem -cne 'ReFS')) {
        $decision.status = 'UnsupportedDrive'; $decision.reason = 'Target drive must be a local fixed NTFS or ReFS volume.'; return $decision
    }

    # Check if already provisioned at or above target size
    $existing = @($Snapshot.settings | Where-Object { $_.name -like "$($TargetDriveLetter):\pagefile.sys" })
    if ($existing.Count -gt 0 -and -not $Snapshot.automaticManagedPagefile) {
        $currentMax = ($existing | Measure-Object -Property maximumSizeMB -Maximum).Maximum
        if ($currentMax -ge $targetSize) {
            $decision.status = 'AtOrAboveCeiling'; $decision.reason = 'Existing pagefile is already at or above target ceiling.'; return $decision
        }
    }

    # Calculate additional disk allocation needed
    $currentAllocatedMB = 0
    $usage = @($Snapshot.usage | Where-Object { $_.name -like "$($TargetDriveLetter):\pagefile.sys" })
    if ($usage.Count -gt 0) { $currentAllocatedMB = [int64]$usage[0].allocatedMB }
    elseif ($existing.Count -gt 0) { $currentAllocatedMB = [int64]$existing[0].maximumSizeMB }

    $additionalGrowthMB = [Math]::Max([int64]0, [int64]($targetSize - $currentAllocatedMB))
    $decision.diskGrowthMB = $additionalGrowthMB

    $reserveBytes = [int64][Math]::Max([int64]$Policy.reserve_free_bytes, [int64][Math]::Ceiling([double]$drive.sizeBytes * [double]$Policy.reserve_free_percent / 100.0))
    $freeAfterBytes = [int64]$drive.freeBytes - ($additionalGrowthMB * 1MB)
    $decision.freeSpaceAfterMB = [Math]::Round($freeAfterBytes / 1MB)

    if ($freeAfterBytes -lt $reserveBytes) {
        $decision.status = 'LowDiskSpace'
        $decision.reason = "Provisioning requires $additionalGrowthMB MB growth which would breach the $($Policy.reserve_free_percent)%/15GB disk reserve."
        return $decision
    }

    $decision.eligible = $true
    $decision.status = 'Eligible'
    $decision.reason = "Target drive has sufficient capacity to provision fixed $targetSize MB pagefile."
    return $decision
}

function Invoke-ArkuzoPagefileProvisioning {
    param($Snapshot, $Policy, [string]$TargetDriveLetter = 'C', [switch]$MonitorOnly, [hashtable]$Dependencies = @{})
    $decision = Get-ArkuzoPagefileProvisioningDecision -Snapshot $Snapshot -Policy $Policy -TargetDriveLetter $TargetDriveLetter
    $result = [pscustomobject]@{
        status = $decision.status; reason = $decision.reason; decision = $decision
        writeAttempted = $false; changed = $false; pendingReboot = $false
        rebootInitiated = $false; targetName = $decision.targetName; targetSizeMB = $decision.targetSizeMB
        error = $null
    }
    if (-not $decision.eligible) { return $result }
    if ($MonitorOnly) {
        $result.status = 'MonitorOnly'; $result.reason = 'Monitor-only mode prohibits pagefile provisioning writes.'; return $result
    }

    $result.writeAttempted = $true
    try {
        if ($Dependencies.ContainsKey('SetProvisionedPagefile')) {
            & $Dependencies.SetProvisionedPagefile $decision.targetName ([uint32]$decision.targetSizeMB) $false
        } else {
            # 1. Update Registry first: PagingFiles multi-string
            $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
            $settingStr = "$($decision.targetName) $($decision.targetSizeMB) $($decision.targetSizeMB)"
            Set-ItemProperty -Path $regPath -Name 'PagingFiles' -Value @($settingStr) -ErrorAction Stop

            # 2. Update WMI Win32_PageFileSetting if exists or create
            try {
                $cimSettings = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*pagefile.sys" })
                if ($cimSettings.Count -gt 0) {
                    Set-CimInstance -InputObject $cimSettings[0] -Property @{
                        InitialSize = [uint32]$decision.targetSizeMB
                        MaximumSize = [uint32]$decision.targetSizeMB
                    } -ErrorAction SilentlyContinue | Out-Null
                }
            } catch { }

            # 3. Disable AutomaticManagedPagefile in WMI and Registry
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
                if ($cs) {
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction SilentlyContinue | Out-Null
                }
            } catch { }
            Set-ItemProperty -Path $regPath -Name 'AutomaticManagedPagefile' -Value 0 -ErrorAction SilentlyContinue
        }
        $result.changed = $true
        $result.pendingReboot = $true
        $result.status = 'PendingReboot'
        $result.reason = "Fixed pagefile of $($decision.targetSizeMB) MB provisioned. Windows requires a reboot for the size to take physical effect."
    } catch {
        $result.status = 'WriteFailed'
        $result.reason = "Pagefile provisioning write failed: $($_.Exception.Message)"
        $result.error = $_
        # Failsafe rollback: ensure AutomaticManagedPagefile remains enabled if setting failed
        try {
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'AutomaticManagedPagefile' -Value 1 -ErrorAction SilentlyContinue
        } catch { }
    }
    return $result
}

function New-ArkuzoPagefileManagementResult {
    param($Decision)
    return [pscustomobject]@{
        status=$Decision.status; reason=$Decision.reason; decision=$Decision
        changed=$false; writeAttempted=$false; configurationPersisted=$false
        pendingReboot=($Decision.status -eq 'PendingReboot'); runtimeGrowthVerified=$false
        canSuppressRecovery=$false; rebootInitiated=$false; targetName=$Decision.targetName
        growthMB=$Decision.growthMB; auditPath=$null; journalPath=$null; requestId=$null; error=$null
    }
}
function Update-ArkuzoPagefileStatus {
    # Observation is separate from recovery; no pagefile result disables the health guard.
    $status = [pscustomobject]@{
        status='Disabled'; reason='Pagefile management is opt-in and disabled.'
        writeAttempted=$false; changed=$false; configurationPersisted=$false
        pendingReboot=$false; runtimeGrowthVerified=$false; canSuppressRecovery=$false
        rebootInitiated=$false; targetName=$null; growthMB=0; error=$null
    }
    try {
        if ($null -ne $pagefilePolicy -and (-not $pagefilePolicy.valid -or $pagefilePolicy.enabled)) {
            if ($script:logFailed) { throw 'Audit logging is unavailable; pagefile requests are blocked.' }
            $snapshot = Get-ArkuzoPagefileSnapshot
            $result = Invoke-ArkuzoPagefileManagement -Snapshot $snapshot -Policy $pagefilePolicy `
                -SystemMemory $systemMemory -MonitorOnly:$MonitorOnly `
                -OwnsController $ownsControllerMutex -DataDirectory $DataDirectory
            foreach ($key in @('status','reason','writeAttempted','changed','configurationPersisted',
                'pendingReboot','runtimeGrowthVerified','targetName','growthMB','error')) {
                $status.$key = Get-ArkuzoPagefileValue $result $key $status.$key
            }
        }
    } catch {
        $status.status='ObservationFailed'; $status.reason='Pagefile observation failed; normal recovery remains enabled.'
        $status.error=[pscustomobject]@{stage='Observation';message=$_.Exception.Message}
    }
    $script:pagefileStatus=$status
    Write-Diagnostic 'PAGEFILE_STATUS' $status
    if ($status.status -notin @('Disabled','WindowsManaged','BelowTrigger','Active','MonitorOnly','NotController','Cooldown')) {
        $details = if ($null -ne $status.error) { ' '+$status.error.message } else { '' }
        Warn-Throttled 'pagefile-management' ('Pagefile '+$status.status+': '+$status.reason+$details)
    }
}
function Read-ArkuzoPagefileSystemMemory {
    param([hashtable]$Dependencies = @{})
    $memory = if ($Dependencies.ContainsKey('ReadMemory')) { & $Dependencies.ReadMemory } else { Get-ArkuzoSystemMemory }
    if (-not (Test-ArkuzoPagefileNumber $memory.commitLimitMB 1 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $memory.commitUsedMB 0 1073741824) -or
        -not (Test-ArkuzoPagefileNumber $memory.commitPercent 0 100) -or
        [math]::Abs((100.0 * $memory.commitUsedMB / $memory.commitLimitMB) - $memory.commitPercent) -gt 0.2) {
        throw 'OS commit telemetry is missing or inconsistent.'
    }
    return $memory
}
function Get-ArkuzoPagefileConfigurationRecord {
    param($Snapshot)
    return [pscustomobject]@{
        bootId=$Snapshot.bootId; computerName=$Snapshot.computerName; automaticManagedPagefile=$Snapshot.automaticManagedPagefile
        settings=@(foreach ($file in @($Snapshot.settings | Sort-Object name)) {
            [pscustomobject]@{name=$file.name;settingId=$file.settingId;initialSizeMB=$file.initialSizeMB;maximumSizeMB=$file.maximumSizeMB;
                cimClass=$file.cimClass;cimNamespace=$file.cimNamespace;cimServer=$file.cimServer}
        })
    }
}
function Assert-ArkuzoPagefileSafePath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Pagefile journal requires an absolute local data path.' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Pagefile persistence refuses reparse-point paths.' }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($null -ne $parent) { $parent.FullName } else { $null }
    }
}
function Save-ArkuzoPagefileJson {
    param([string]$Path, $Data)
    Assert-ArkuzoPagefileSafePath $Path
    $text = $Data | ConvertTo-Json -Depth 10 -Compress
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    if ($bytes.Length -gt 65536) { throw 'Pagefile audit/journal exceeds its 64 KiB bound.' }
    $temp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream=$null
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
        if ([IO.File]::ReadAllText($Path) -cne $text) { throw 'Pagefile persistence readback did not match.' }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}
function Read-ArkuzoPagefileJournal {
    param([string]$Path, [string]$BootId)
    Assert-ArkuzoPagefileSafePath $Path
    $empty = [pscustomobject]@{schemaVersion=1;bootId=$BootId;requests=@()}
    if (-not [IO.File]::Exists($Path)) { return $empty }
    if ((New-Object IO.FileInfo($Path)).Length -gt 65536) { throw 'Pagefile journal exceeds its 64 KiB bound.' }
    $journal = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    if ($journal.schemaVersion -ne 1 -or $journal.bootId -isnot [string] -or -not $journal.bootId -or
        $null -eq $journal.PSObject.Properties['requests'] -or @($journal.requests).Count -gt 4) { throw 'Invalid pagefile journal schema or bounds.' }
    $ids = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($request in @($journal.requests)) {
        $time = [datetimeoffset]::MinValue
        if ($request.id -notmatch '^[a-f0-9]{32}$' -or -not $ids.Add([string]$request.id) -or
            -not [datetimeoffset]::TryParse([string]$request.requestedUtc, [ref]$time) -or
            $request.targetName -notmatch '^[A-Za-z]:\\pagefile\.sys$' -or
            $request.status -notin @('Prepared','PendingReboot','Active','WriteFailed','ReadbackFailed','RaceDetected','RuntimeVerificationFailed') -or
            -not (Test-ArkuzoPagefileNumber $request.growthMB 1 8192 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $request.oldAllocatedMB 1 4294967295 -Integer) -or
            -not (Test-ArkuzoPagefileNumber $request.oldCommitLimitMB 1 1073741824) -or
            -not (Test-ArkuzoPagefileNumber $request.newMaximumSizeMB 1 4294967295 -Integer)) { throw 'Invalid pagefile request record; refusing to reset a consumed budget.' }
    }
    if ($journal.bootId -cne $BootId) { return $empty }
    return $journal
}
function Invoke-ArkuzoPagefileManagement {
    param($Snapshot, $Policy, $SystemMemory, [switch]$MonitorOnly,
        $OwnsController = $false, [string]$DataDirectory, [hashtable]$Dependencies = @{})
    $decision = Get-ArkuzoPagefileGrowthDecision $Snapshot $Policy $SystemMemory
    $result = New-ArkuzoPagefileManagementResult $decision
    if (-not $decision.eligible) {
        if ($decision.status -eq 'SnapshotUnavailable') { $result.error=$Snapshot.error }
        if ($decision.status -eq 'InvalidPolicy') {
            $message = if ($decision.validationErrors.Count) { $decision.validationErrors -join '; ' } else { $decision.reason }
            $result.error=[pscustomobject]@{stage='PolicyValidation';type='PolicyValidationError';message=$message}
        }
        return $result
    }
    if ($MonitorOnly) { $result.status='MonitorOnly'; $result.reason='Monitor-only operation prohibits pagefile writes.'; return $result }
    if ($OwnsController -isnot [bool] -or -not $OwnsController) { $result.status='NotController'; $result.reason='Only the singleton controller may request pagefile growth.'; return $result }
    $lock = $null; $journal = $null; $request = $null; $reservationPersisted = $false; $stage = 'JournalOpen'
    try {
        Assert-ArkuzoPagefileSafePath $DataDirectory
        [IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
        $result.journalPath = Join-Path $DataDirectory 'Arkuzo-Pagefile-Requests.json'
        $lockPath = Join-Path $DataDirectory 'Arkuzo-Pagefile-Requests.lock'
        Assert-ArkuzoPagefileSafePath $lockPath
        $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $now = Get-ArkuzoPagefileUtcNow $Dependencies
        $stage='JournalRead'; $journal = Read-ArkuzoPagefileJournal $result.journalPath $Snapshot.bootId
        $consumedMB = [int64]0
        foreach ($entry in @($journal.requests)) { $consumedMB += [int64]$entry.growthMB }
        if (@($journal.requests).Count -ge $Policy.max_requests_per_boot -or $consumedMB + $decision.growthMB -gt $Policy.max_boot_growth_mb) {
            $result.status='BootBudgetReached'; $result.reason='Per-boot request/growth budget is consumed; no further request.'; return $result
        }
        if (@($journal.requests).Count -gt 0) {
            $latest = $journal.requests[-1]
            $age = ($now - ([datetimeoffset]$latest.requestedUtc).UtcDateTime).TotalSeconds
            if ($age -lt 0 -or $age -lt $Policy.cooldown_sec) {
                $result.status='Cooldown'; $result.reason='Persisted pagefile cooldown (including clock reversal) prevents another request.'; return $result
            }
            if (@($journal.requests | Where-Object {$_.status -in @('Prepared','PendingReboot','ReadbackFailed','RuntimeVerificationFailed')}).Count) {
                $result.status='PriorRequestUnverified'; $result.reason='An earlier request has unverified activation/outcome; no repeat write.'; return $result
            }
        }
        $index = @($journal.requests).Count + 1
        $result.requestId = [guid]::NewGuid().ToString('N')
        $result.auditPath = Join-Path $DataDirectory ("Arkuzo-Pagefile-Backup-$index.json")
        $oldConfiguration = Get-ArkuzoPagefileConfigurationRecord $Snapshot
        $request = [pscustomobject]@{
            id=$result.requestId; requestedUtc=$now.ToString('o'); targetName=$decision.targetName; status='Prepared'
            growthMB=$decision.growthMB; oldAllocatedMB=$decision.oldAllocatedMB; oldCommitLimitMB=$SystemMemory.commitLimitMB
            newInitialSizeMB=$decision.newInitialSizeMB; newMaximumSizeMB=$decision.newMaximumSizeMB; error=$null
        }
        $stage='AuditBackup'
        Save-ArkuzoPagefileJson $result.auditPath ([pscustomobject]@{
            schemaVersion=1;requestedUtc=$request.requestedUtc;requestId=$request.id;oldConfiguration=$oldConfiguration
            oldRuntime=@($Snapshot.usage);oldDrives=@($Snapshot.drives);oldCommitLimitMB=$SystemMemory.commitLimitMB
            requestedSetting=[pscustomobject]@{name=$decision.targetName;initialSizeMB=$decision.newInitialSizeMB;maximumSizeMB=$decision.newMaximumSizeMB}
        })
        $stage='JournalReserve'; $journal.requests = @($journal.requests) + @($request)
        Save-ArkuzoPagefileJson $result.journalPath $journal; $reservationPersisted=$true
        # All audit/reservation IO precedes the final read. No configuration is ever
        # written from the caller's cached CIM object; re-read exact local identity.
        $stage='PreWrite'
        $fresh = Get-ArkuzoPagefileSnapshot -Dependencies $Dependencies
        if (-not $fresh.available) { throw ('Pre-write snapshot failed: ' + $fresh.error.message) }
        $beforeMemory = Read-ArkuzoPagefileSystemMemory $Dependencies
        $freshDecision = Get-ArkuzoPagefileGrowthDecision $fresh $Policy $beforeMemory
        $freshConfiguration = Get-ArkuzoPagefileConfigurationRecord $fresh
        $oldText = $oldConfiguration | ConvertTo-Json -Depth 8 -Compress
        $freshText = $freshConfiguration | ConvertTo-Json -Depth 8 -Compress
        if (-not $freshDecision.eligible -or $oldText -cne $freshText -or
            $freshDecision.targetName -cne $decision.targetName -or
            $freshDecision.newInitialSizeMB -ne $decision.newInitialSizeMB -or $freshDecision.newMaximumSizeMB -ne $decision.newMaximumSizeMB -or
            $freshDecision.drive.deviceId -cne $decision.drive.deviceId -or $freshDecision.drive.volumeSerial -cne $decision.drive.volumeSerial -or
            $freshDecision.drive.fileSystem -cne $decision.drive.fileSystem -or $freshDecision.drive.sizeBytes -ne $decision.drive.sizeBytes -or
            $freshDecision.drive.freeBytes - $decision.diskChargeBytes -lt $freshDecision.reserveBytes -or
            $beforeMemory.commitLimitMB -ne $request.oldCommitLimitMB) {
            throw 'Pagefile identity/configuration/boot/privilege/commit/free-space changed before writing; request refused.'
        }
        $stage='Write'; $result.writeAttempted=$true; $result.pendingReboot=$true
        $properties = @{InitialSize=[uint32]$decision.newInitialSizeMB;MaximumSize=[uint32]$decision.newMaximumSizeMB}
        if ($Dependencies.ContainsKey('WriteCim')) { & $Dependencies.WriteCim $freshDecision.target.instance $properties | Out-Null }
        else {
            if ($freshDecision.target.instance -isnot [Microsoft.Management.Infrastructure.CimInstance]) { throw 'Exact local CIM setting instance is required.' }
            Set-CimInstance -InputObject $freshDecision.target.instance -Property $properties -OperationTimeoutSec 10 -Confirm:$false -ErrorAction Stop | Out-Null
        }
        $stage='Readback'
        $after = Get-ArkuzoPagefileSnapshot -Dependencies $Dependencies
        if (-not $after.available) { throw ('Persisted CIM readback failed: ' + $after.error.message) }
        $expected = Get-ArkuzoPagefileConfigurationRecord $fresh
        foreach ($file in $expected.settings) {
            if ($file.name -ceq $decision.targetName) { $file.initialSizeMB=$properties.InitialSize; $file.maximumSizeMB=$properties.MaximumSize }
        }
        $actualText = Get-ArkuzoPagefileConfigurationRecord $after | ConvertTo-Json -Depth 8 -Compress
        if (($expected | ConvertTo-Json -Depth 8 -Compress) -cne $actualText) { throw 'Persisted CIM configuration did not match the exact requested setting/identity.' }
        $afterDrives = @($after.drives | Where-Object {$_.deviceId -ceq $freshDecision.drive.deviceId})
        if ($afterDrives.Count -ne 1 -or $afterDrives[0].volumeSerial -cne $freshDecision.drive.volumeSerial -or
            $afterDrives[0].fileSystem -cne $freshDecision.drive.fileSystem -or $afterDrives[0].sizeBytes -ne $freshDecision.drive.sizeBytes -or
            $afterDrives[0].driveType -ne 3 -or -not (Test-ArkuzoPagefileNumber $afterDrives[0].freeBytes 0 $afterDrives[0].sizeBytes -Integer)) {
            throw 'Persisted readback target volume identity/capacity is no longer exact.'
        }
        $result.changed=$true; $result.configurationPersisted=$true
        $result.status='PendingReboot'; $result.reason='Growth is persisted for startup, not confirmed active. Recovery stays enabled; no reboot is initiated.'
        $stage='RuntimeVerification'; $afterMemory = Read-ArkuzoPagefileSystemMemory $Dependencies
        $active = @($after.usage | Where-Object {$_.name -ceq $decision.targetName})
        if ($active.Count -eq 1 -and $active[0].temporary -is [bool] -and -not $active[0].temporary -and
            (Test-ArkuzoPagefileNumber $active[0].allocatedMB 1 4294967295 -Integer) -and
            $active[0].allocatedMB -ge $decision.newMaximumSizeMB -and $active[0].allocatedMB -gt $decision.oldAllocatedMB -and
            $afterMemory.commitLimitMB -gt $beforeMemory.commitLimitMB) {
            $result.status='Active'; $result.reason='Fresh runtime pagefile allocation and OS commit limit both increased. Recovery remains enabled.'
            $result.runtimeGrowthVerified=$true; $result.pendingReboot=$false
        }
        $request.status=$result.status; $stage='JournalOutcome'
        Save-ArkuzoPagefileJson $result.journalPath $journal
        return $result
    } catch {
        $failure = $_.Exception
        $result.status = switch ($stage) {
            'PreWrite' {'RaceDetected'}; 'Write' {'WriteFailed'}; 'Readback' {'ReadbackFailed'}
            'RuntimeVerification' {'RuntimeVerificationFailed'}; 'AuditBackup' {'AuditFailed'}; default {'JournalFailed'}
        }
        $result.reason='Pagefile request failed closed; configuration may require operator review if a write was attempted.'
        $result.error=[pscustomobject]@{stage=$stage;type=$failure.GetType().FullName;message=$failure.Message;persistenceMessage=$null}
        if ($reservationPersisted -and $stage -ne 'JournalOutcome') {
            $request.status=$result.status; $request.error=$result.error
            try { Save-ArkuzoPagefileJson $result.journalPath $journal }
            catch { $result.status='JournalFailed'; $result.error.persistenceMessage=$_.Exception.Message }
        }
        return $result
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

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
# Keys added after a configuration was written fall back to its preset, not to
# a no-op, so existing installations gain memory priority and adaptive trimming.
$presetName = ([string]$loadedConfig.selected_preset).ToLowerInvariant()
if ($presetName -eq 'aggressive') { $presetName = 'agressive' }
$presetDefaults = (Get-ArkuzoPresets)[$(if ((Get-ArkuzoPresets).Contains($presetName)) { $presetName } else { 'normal' })]
$AdaptiveTrim = [bool]$presetDefaults.adaptive_trim
$PressureTrimAvailablePercent = [int]$presetDefaults.pressure_trim_available_percent
if (-not $PSBoundParameters.ContainsKey('MemoryPriority')) { $MemoryPriority = [string]$presetDefaults.memory_priority }
$startupSettingsError = $null
try {
    $startupSettings = Get-ArkuzoLiveResourceSettings $loadedConfig.settings @{ MemoryPriority=$MemoryPriority; AdaptiveTrim=$AdaptiveTrim; PressureTrimAvailablePercent=$PressureTrimAvailablePercent }
    if (-not $PSBoundParameters.ContainsKey('MemoryPriority')) { $MemoryPriority = $startupSettings.MemoryPriority }
    $AdaptiveTrim = [bool]$startupSettings.AdaptiveTrim
    $PressureTrimAvailablePercent = [int]$startupSettings.PressureTrimAvailablePercent
} catch { $startupSettingsError = $_.Exception.Message } # Reported once logging is ready; preset values stay.

$healthPolicy = Get-ArkuzoHealthPolicy $loadedConfig.health
$restorePolicy = Get-ArkuzoRestorePolicy $loadedConfig.recovery
$script:accountProviderSetting = Get-ArkuzoProviderSetting $loadedConfig
$isConfigLocked = ($null -ne $loadedConfig.config_lock -and [bool]$loadedConfig.config_lock)
if ($isConfigLocked) {
    $ApplyGraphicsFlags = $true
    Set-ArkuzoConfigLockLimits $healthPolicy
}
$lastConfigText = [IO.File]::ReadAllText($configFilePath)
$pagefilePolicy = Get-ArkuzoPagefilePolicy -Input $loadedConfig.pagefile -PressurePercent $healthPolicy.pressure_percent
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

if (-not ('Arkuzo.RemoteSessionNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Arkuzo {
 // Read-only remote-session and display probes, plus the process-scoped
 // keep-awake request. Nothing here changes system configuration.
 public static class RemoteSessionNativeV1 {
  [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
  [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);
  [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
  [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
  [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSQuerySessionInformationW(IntPtr server, uint session, int infoClass, out IntPtr buffer, out uint bytes);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr obj, int index, System.Text.StringBuilder info, int length, out int needed);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DevMode {
   [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
   public short SpecVersion, DriverVersion, Size, DriverExtra; public int Fields;
   public int PositionX, PositionY, DisplayOrientation, DisplayFixedOutput;
   public short Color, Duplex, YResolution, TTOption, Collate;
   [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
   public short LogPixels; public int BitsPerPel, PelsWidth, PelsHeight, DisplayFlags, DisplayFrequency;
   public int IcmMethod, IcmIntent, MediaType, DitherType, Reserved1, Reserved2, PanningWidth, PanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettingsW(string device, int mode, ref DevMode devMode);

  public static int OwnSessionId() { uint s; return ProcessIdToSessionId(GetCurrentProcessId(), out s) ? (int)s : -1; }
  public static int ConsoleSessionId() { uint s = WTSGetActiveConsoleSessionId(); return s == 0xFFFFFFFF ? -1 : (int)s; }
  static int QueryInt(int session, int infoClass, int size) {
   IntPtr buffer; uint bytes;
   if (session < 0 || !WTSQuerySessionInformationW(IntPtr.Zero, (uint)session, infoClass, out buffer, out bytes)) return -1;
   try { if (bytes < size) return -1; return size == 2 ? Marshal.ReadInt16(buffer) : Marshal.ReadInt32(buffer); } finally { WTSFreeMemory(buffer); }
  }
  // WTS_CONNECTSTATE_CLASS: 0 Active, 1 Connected, 4 Disconnected, ...
  public static int ConnectState(int session) { return QueryInt(session, 8, 4); }
  // 0 console, 1 legacy ICA, 2 RDP.
  public static int ClientProtocol(int session) { return QueryInt(session, 16, 2); }
  // WTSSessionInfoEx (25) -> WTSINFOEX_LEVEL1_W.SessionFlags: 0 locked, 1 unlocked, -1 unknown.
  public static int LockState(int session) {
   IntPtr buffer; uint bytes;
   if (session < 0 || !WTSQuerySessionInformationW(IntPtr.Zero, (uint)session, 25, out buffer, out bytes)) return -1;
   try { if (bytes < 20) return -1; return Marshal.ReadInt32(buffer, 16); } finally { WTSFreeMemory(buffer); }
  }
  public static int MonitorCount() { return GetSystemMetrics(80); }
  [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
  public static long UptimeMs() { return (long)GetTickCount64(); }
  // "Default" while the user's desktop takes input; "Winlogon" on the lock or sign-in screen; "" when it cannot be opened.
  public static string InputDesktopName() {
   IntPtr desktop = OpenInputDesktop(0, false, 0x0001);
   if (desktop == IntPtr.Zero) return "";
   try { var name = new System.Text.StringBuilder(256); int needed; return GetUserObjectInformationW(desktop, 2, name, name.Capacity * 2, out needed) ? name.ToString() : ""; }
   finally { CloseDesktop(desktop); }
  }
  // Primary display mode: width, height, refresh rate, bits per pixel (zeros when unavailable).
  public static int[] DisplayMode() {
   var mode = new DevMode(); mode.Size = (short)Marshal.SizeOf(typeof(DevMode));
   if (!EnumDisplaySettingsW(null, -1, ref mode)) return new int[] { 0, 0, 0, 0 };
   return new int[] { mode.PelsWidth, mode.PelsHeight, mode.DisplayFrequency, mode.BitsPerPel };
  }
  // ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED for the calling thread, or ES_CONTINUOUS alone to release.
  public static bool KeepAwake(bool on) { return SetThreadExecutionState(on ? 0x80000003u : 0x80000000u) != 0; }
 }
}
'@
}

if (-not ('Arkuzo.MemorySaverNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Arkuzo {
 public static class MemorySaverNativeV1 {
  const uint TOKEN_QUERY = 0x0008;
  const uint SE_PRIVILEGE_ENABLED = 0x0002;
  const int TokenPrivilegesClass = 3;
  const int ERROR_INSUFFICIENT_BUFFER = 122;
  [StructLayout(LayoutKind.Sequential)]
  struct Luid { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)]
  struct LuidAndAttributes { public Luid Luid; public uint Attributes; }
  [StructLayout(LayoutKind.Sequential)]
  struct TokenPrivileges { public uint Count; public LuidAndAttributes Privilege; }
  sealed class SafeTokenHandle : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid {
   public SafeTokenHandle() : base(true) { }
   protected override bool ReleaseHandle() { return CloseHandle(handle); }
  }
  public sealed class PrivilegeResult {
   public string Name { get; private set; }
   public string Status { get; private set; }
   public bool Succeeded { get; private set; }
   public bool? Present { get; private set; }
   public bool Enabled { get; private set; }
   public int Win32Error { get; private set; }
   public string Operation { get; private set; }
   public string Message { get; private set; }
   public bool? AdjustmentReturnedSuccess { get; private set; }
   internal PrivilegeResult(string name, string status, bool succeeded, bool? present, bool enabled,
      int error, string operation, string message, bool? adjustmentReturnedSuccess = null) {
    Name = name; Status = status; Succeeded = succeeded; Present = present; Enabled = enabled;
    Win32Error = error; Operation = operation; Message = message; AdjustmentReturnedSuccess = adjustmentReturnedSuccess;
   }
  }
  [DllImport("kernel32.dll")]
  static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool CloseHandle(IntPtr handle);
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool OpenProcessToken(IntPtr process, uint access, out SafeTokenHandle token);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool GetTokenInformation(SafeTokenHandle token, int cls, IntPtr data, uint length, out uint needed);
  static string DescribeFailure(string operation, int error, string guidance) {
   if (error == 5)
    guidance += " Access denied (ERROR_ACCESS_DENIED): check the handle's required access rights and verified target ownership. Protected-process and security protections still apply; no automatic elevation is attempted.";
   return operation + " failed (Win32 " + error + ": " + new Win32Exception(error).Message + "). " + guidance;
  }
  static PrivilegeResult PrivilegeFailure(string name, string operation, int error, string guidance) {
   return new PrivilegeResult(name, "Failed", false, null, false, error, operation, DescribeFailure(operation, error, guidance));
  }
  static PrivilegeResult QueryPrivilege(SafeTokenHandle token, string name, Luid luid) {
   uint needed;
   bool sized = GetTokenInformation(token, TokenPrivilegesClass, IntPtr.Zero, 0, out needed);
   int error = Marshal.GetLastWin32Error();
   if (!sized && error != ERROR_INSUFFICIENT_BUFFER)
    return PrivilegeFailure(name, "GetTokenInformation", error, "Requires TOKEN_QUERY on the current process token.");
   int offset = Marshal.OffsetOf(typeof(TokenPrivileges), "Privilege").ToInt32();
   if (needed < offset || needed > int.MaxValue)
    return PrivilegeFailure(name, "GetTokenInformation", 13, "Invalid TOKEN_PRIVILEGES buffer length returned.");
   IntPtr data = Marshal.AllocHGlobal((int)needed);
   try {
    uint returned;
    if (!GetTokenInformation(token, TokenPrivilegesClass, data, needed, out returned)) {
     error = Marshal.GetLastWin32Error();
     return PrivilegeFailure(name, "GetTokenInformation", error, "Requires TOKEN_QUERY on the current process token.");
    }
    uint count = unchecked((uint)Marshal.ReadInt32(data));
    int stride = Marshal.SizeOf(typeof(LuidAndAttributes));
    if (returned < offset || returned > needed || count > (returned - offset) / stride)
     return PrivilegeFailure(name, "GetTokenInformation", 13, "Invalid TOKEN_PRIVILEGES entry count returned.");
    for (uint i = 0; i < count; i++) {
     IntPtr entry = IntPtr.Add(data, offset + checked((int)i * stride));
     LuidAndAttributes privilege = (LuidAndAttributes)Marshal.PtrToStructure(entry, typeof(LuidAndAttributes));
     if (privilege.Luid.LowPart == luid.LowPart && privilege.Luid.HighPart == luid.HighPart) {
      bool enabled = (privilege.Attributes & SE_PRIVILEGE_ENABLED) != 0;
      return new PrivilegeResult(name, enabled ? "Enabled" : "Disabled", true, true, enabled, 0,
       "GetTokenInformation", name + (enabled ? " is enabled in the current process token." : " is present but disabled in the current process token."));
     }
    }
    return new PrivilegeResult(name, "NotAssigned", true, false, false, 0, "GetTokenInformation",
     name + " is absent or removed from the current process token. Enabling cannot add a missing privilege.");
   } finally { Marshal.FreeHGlobal(data); }
  }
  const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
  const int ERROR_NOT_ALL_ASSIGNED = 1300;
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool AdjustTokenPrivileges(SafeTokenHandle token, bool disableAll, ref TokenPrivileges state,
   uint length, IntPtr previous, IntPtr returned);
  public static PrivilegeResult EnableCurrentProcessPrivilege(string name) {
   Luid luid;
   if (!LookupPrivilegeValue(null, name, out luid)) {
    int error = Marshal.GetLastWin32Error();
    return PrivilegeFailure(name, "LookupPrivilegeValue", error, "Use an existing Windows privilege name.");
   }
   SafeTokenHandle token;
   bool opened = OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES, out token);
   int openError = Marshal.GetLastWin32Error();
   using (token) {
    if (!opened) return PrivilegeFailure(name, "OpenProcessToken", openError,
     "Best-effort enabling requires TOKEN_QUERY and TOKEN_ADJUST_PRIVILEGES on the current process token. No elevation is requested.");
    TokenPrivileges state = new TokenPrivileges();
    state.Count = 1; state.Privilege.Luid = luid; state.Privilege.Attributes = SE_PRIVILEGE_ENABLED;
    bool adjusted = AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero);
    // A nonzero BOOL can still mean ERROR_NOT_ALL_ASSIGNED. Capture before any other native call.
    int adjustmentError = Marshal.GetLastWin32Error();
    if (adjustmentError == ERROR_NOT_ALL_ASSIGNED)
     return new PrivilegeResult(name, "NotAssigned", false, false, false, adjustmentError, "AdjustTokenPrivileges",
      DescribeFailure("AdjustTokenPrivileges", adjustmentError, name + " is absent or removed from this token; enabling cannot add a missing privilege. Continuing best-effort without elevation."), adjusted);
    if (!adjusted || adjustmentError != 0)
     return new PrivilegeResult(name, "Failed", false, null, false, adjustmentError, "AdjustTokenPrivileges",
      DescribeFailure("AdjustTokenPrivileges", adjustmentError, "Requires TOKEN_ADJUST_PRIVILEGES on the current process token; no elevation is requested."), adjusted);
    PrivilegeResult verified = QueryPrivilege(token, name, luid);
    if (!verified.Succeeded || !verified.Enabled)
     return new PrivilegeResult(name, "Failed", false, verified.Present, false, verified.Win32Error, verified.Operation,
      "AdjustTokenPrivileges returned success (Win32 0), but own-token readback did not verify " + name + " enabled. " + verified.Message, adjusted);
    return new PrivilegeResult(name, "Enabled", true, true, true, 0, "AdjustTokenPrivileges",
     name + " is enabled and verified in the current process token. Protected-process and security restrictions still apply.", adjusted);
   }
  }
  public static PrivilegeResult QueryCurrentProcessPrivilege(string name) {
   Luid luid;
   if (!LookupPrivilegeValue(null, name, out luid)) {
    int error = Marshal.GetLastWin32Error();
    return PrivilegeFailure(name, "LookupPrivilegeValue", error, "Use an existing Windows privilege name.");
   }
   SafeTokenHandle token;
   bool opened = OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out token);
   int openError = Marshal.GetLastWin32Error();
   using (token) {
    if (!opened) return PrivilegeFailure(name, "OpenProcessToken", openError, "Read-only query requires TOKEN_QUERY on the current process token.");
    return QueryPrivilege(token, name, luid);
   }
  }
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
  [DllImport("kernel32.dll", EntryPoint="SetLastError", SetLastError=true)]
  static extern void ClearNativeLastError(uint error);
  [DllImport("user32.dll", EntryPoint="ShowWindowAsync", SetLastError=true)]
  static extern bool NativeShowWindowAsync(IntPtr h, int command);
  [DllImport("user32.dll", EntryPoint="IsIconic", SetLastError=true)]
  static extern bool NativeIsIconic(IntPtr h);
  public static bool ShowWindowAsync(IntPtr h, int command) {
   // User32 does not guarantee extended errors here; never reuse a previous token/process error.
   ClearNativeLastError(0);
   bool started = NativeShowWindowAsync(h, command);
   int error = Marshal.GetLastWin32Error();
   if (!started) {
    if (error != 0) throw new Win32Exception(error, DescribeFailure("ShowWindowAsync", error, "Check the live HWND and its owning window thread. Request acceptance is not confirmation of the visible window state."));
    throw new InvalidOperationException("ShowWindowAsync did not start the request (Win32 error not supplied). Check the live HWND and owning window thread; no successful state change is claimed.");
   }
   return started;
  }
  public static bool IsIconic(IntPtr h) {
   ClearNativeLastError(0);
   bool minimized = NativeIsIconic(h);
   int error = Marshal.GetLastWin32Error();
   if (!minimized && error != 0)
    throw new Win32Exception(error, DescribeFailure("IsIconic", error, "Check the live HWND; it may have been destroyed. A non-minimized valid window normally returns false without an error."));
   return minimized;
  }
  static void Check(bool ok, string operation, string guidance) {
   if (!ok) {
    int error = Marshal.GetLastWin32Error();
    throw new Win32Exception(error, DescribeFailure(operation, error, guidance));
   }
  }
  public static ulong[] ReadLimits(IntPtr h) {
   UIntPtr min, max; uint flags;
   Check(GetProcessWorkingSetSizeEx(h, out min, out max, out flags), "GetProcessWorkingSetSizeEx", "Requires PROCESS_QUERY_INFORMATION or PROCESS_QUERY_LIMITED_INFORMATION on a live process handle.");
   return new ulong[] { min.ToUInt64(), max.ToUInt64(), flags };
  }
  public static void SetLimits(IntPtr h, ulong min, ulong max, uint flags) {
   Check(SetProcessWorkingSetSizeEx(h, new UIntPtr(min), new UIntPtr(max), flags), "SetProcessWorkingSetSizeEx", "Requires PROCESS_SET_QUOTA; increasing a working-set bound can require SeIncreaseWorkingSetPrivilege. Hard working-set limits are opt-in, not a private-commit cap.");
  }
  public static uint ReadMemoryPriority(IntPtr h) {
   uint value; Check(GetProcessInformation(h, 0, out value, 4), "GetProcessInformation", "Requires PROCESS_QUERY_LIMITED_INFORMATION on a live process handle."); return value;
  }
  public static void SetMemoryPriority(IntPtr h, uint value) {
   Check(SetProcessInformation(h, 0, ref value, 4), "SetProcessInformation", "Requires PROCESS_SET_INFORMATION on a live process handle.");
  }
  public static void Trim(IntPtr h) {
   Check(EmptyWorkingSet(h), "EmptyWorkingSet", "Requires PROCESS_SET_QUOTA and PROCESS_QUERY_INFORMATION or PROCESS_QUERY_LIMITED_INFORMATION. Trimming does not reduce private commit and can cause page faults.");
  }
  public static IntPtr Affinity(long allowed, int slot, int count) {
   int[] bits = new int[64]; int n = 0; ulong available = unchecked((ulong)allowed);
   for (int b=0; b<64; b++) if ((available & (1UL << b)) != 0) bits[n++] = b;
   if (n == 0) throw new InvalidOperationException("Empty CPU affinity mask.");
   count = Math.Min(count, n); ulong mask = 0;
   for (int i=0; i<count; i++) mask |= 1UL << bits[(int)(((long)slot*count+i)%n)];
   return new IntPtr(unchecked((long)mask));
  }
  const int STD_INPUT_HANDLE = -10;
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern IntPtr GetStdHandle(int nStdHandle);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
  public static uint? ReadConsoleInputMode() {
   IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
   if (h == IntPtr.Zero || h == new IntPtr(-1)) return null;
   uint mode;
   if (!GetConsoleMode(h, out mode)) return null;
   return mode;
  }
  public static bool SetConsoleInputMode(uint mode) {
   IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
   if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
   return SetConsoleMode(h, mode);
  }
 }
}
'@
}

if (-not ('Arkuzo.LoopWatchdogV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
namespace Arkuzo {
 // Runs on a thread-pool timer, so it can still report while the main loop is
 // blocked. The loop marks each phase; a phase older than the threshold is
 // written to the stall file for the supervisor and the next session.
 public static class LoopWatchdogV1 {
  static Timer timer;
  static string path;
  static int threshold = 60;
  static string phase = "starting";
  static long markTicks = DateTime.UtcNow.Ticks;
  static string stalledPhase;
  static double stalledSec;
  static string recovered;
  static readonly object gate = new object();
  public static void Start(string stallPath, int thresholdSec) {
   lock (gate) { path = stallPath; threshold = thresholdSec; }
   Mark("starting");
   if (timer == null) timer = new Timer(Check, null, 5000, 5000);
  }
  public static void Mark(string next) {
   lock (gate) {
    if (stalledPhase != null) { recovered = stalledPhase + "|" + Math.Round(stalledSec); stalledPhase = null; }
    phase = next; markTicks = DateTime.UtcNow.Ticks;
   }
  }
  // "phase|seconds" of a stall that has ended since the last call, else null.
  public static string TakeRecovered() { lock (gate) { var r = recovered; recovered = null; return r; } }
  static void Check(object state) {
   string current, target; double age;
   lock (gate) {
    age = (DateTime.UtcNow.Ticks - markTicks) / (double)TimeSpan.TicksPerSecond;
    if (age < threshold || path == null) return;
    stalledPhase = phase; stalledSec = age; current = phase; target = path;
   }
   try {
    var now = DateTime.UtcNow;
    var json = "{\"pid\":" + System.Diagnostics.Process.GetCurrentProcess().Id +
     ",\"phase\":\"" + current.Replace("\\", "\\\\").Replace("\"", "'") + "\"" +
     ",\"stalledSec\":" + Math.Round(age) +
     ",\"sinceUtc\":\"" + now.AddSeconds(-age).ToString("o") + "\",\"updatedUtc\":\"" + now.ToString("o") + "\"}";
    File.WriteAllText(target, json);
   } catch { }
  }
 }
}
'@
}

function Get-ArkuzoConsoleInputModeMask([int]$CurrentMode) {
    # Clear ENABLE_QUICK_EDIT_MODE (0x0040) and ENABLE_INSERT_MODE (0x0020)
    # Set ENABLE_EXTENDED_FLAGS (0x0080) so changes take effect
    $mode = ($CurrentMode -band (-bnot 0x0040)) -band (-bnot 0x0020)
    $mode = $mode -bor 0x0080
    return [int]$mode
}

function Set-ArkuzoConsoleQuickEditDisabled {
    if ($Headless) { return }
    try {
        if ('Arkuzo.MemorySaverNativeV1' -as [type]) {
            $current = [Arkuzo.MemorySaverNativeV1]::ReadConsoleInputMode()
            if ($null -ne $current) {
                $masked = Get-ArkuzoConsoleInputModeMask ([int]$current)
                if ($masked -ne [int]$current) {
                    [Arkuzo.MemorySaverNativeV1]::SetConsoleInputMode([uint32]$masked) | Out-Null
                }
            }
        }
    } catch { }
}

# Only optional local graphics flags; merge rather than erase other settings.
function Get-ArkuzoGraphicsInstallDirectories {
    [CmdletBinding()]
    param([string[]]$SearchRoots=@(), [string[]]$ProcessImagePaths=@())
    $candidates = New-Object 'Collections.Generic.List[string]'
    foreach ($imagePath in $ProcessImagePaths) {
        if ([string]::IsNullOrWhiteSpace($imagePath)) { continue }
        try {
            if ([IO.Path]::GetFileName($imagePath) -ieq 'RobloxPlayerBeta.exe') {
                [void]$candidates.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($imagePath)))
            }
        } catch { continue }
    }
    foreach ($root in $SearchRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try {
            if (-not [IO.Directory]::Exists($root)) { continue }
            [void]$candidates.Add([IO.Path]::GetFullPath($root))
            foreach ($child in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
                [void]$candidates.Add($child.FullName)
            }
        } catch { continue }
    }
    $directories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists([IO.Path]::Combine($candidate, 'RobloxPlayerBeta.exe'))) { [void]$directories.Add($candidate) }
    }
    return @($directories | Sort-Object)
}
function Merge-ArkuzoGraphicsFlags {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SettingsFile)
    $SettingsFile = [IO.Path]::GetFullPath($SettingsFile)
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $settings = [ordered]@{}
    $originalBytes = $null
    $existed = [IO.File]::Exists($SettingsFile)
    if ($existed) {
        try {
            $originalBytes = [IO.File]::ReadAllBytes($SettingsFile)
            $text = $encoding.GetString($originalBytes).TrimStart([char]0xFEFF)
            # ConvertFrom-Json unwraps a one-element array in PS 5.1; check the root token too.
            if ([string]::IsNullOrWhiteSpace($text) -or -not $text.TrimStart().StartsWith('{')) { throw 'Not an object' }
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) { throw 'Not an object' }
        } catch { throw 'ClientAppSettings.json must contain a valid UTF-8 JSON object and be readable. File left unchanged.' }
        foreach ($property in $parsed.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    }
    $settings['DFFlagTextureQualityOverrideEnabled'] = 'True'
    $settings['DFIntTextureQualityOverride'] = '0'
    $settings['FIntDebugForceMSAASamples'] = '1'
    $settings['DFIntTaskSchedulerTargetFps'] = [int]15
    $json = $settings | ConvertTo-Json -Depth 100 -ErrorAction Stop
    $directory = [IO.Path]::GetDirectoryName($SettingsFile)
    [void][IO.Directory]::CreateDirectory($directory)
    $uniqueTag = [guid]::NewGuid().ToString('N')
    $temporaryFile = $SettingsFile + '.arkuzo-' + $uniqueTag + '.tmp'
    $backupPath = $null
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($temporaryFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        if ($existed) {
            # Refuse an observed concurrent edit instead of clobbering newly added user settings.
            if (-not [IO.File]::Exists($SettingsFile) -or
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($SettingsFile)) -cne [Convert]::ToBase64String($originalBytes)) {
                throw 'ClientAppSettings.json changed during the merge. No replacement performed.'
            }
            $backupPath = $SettingsFile + '.arkuzo-' + $uniqueTag + '.bak'
            # Same-directory atomic replacement creates an exact-byte backup. Never fall back to truncation.
            [IO.File]::Replace($temporaryFile, $SettingsFile, $backupPath)
        } else {
            # Move refuses to overwrite a file created by another writer after discovery.
            [IO.File]::Move($temporaryFile, $SettingsFile)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temporaryFile)) { [IO.File]::Delete($temporaryFile) }
    }
    return [pscustomobject]@{ SettingsFile=$SettingsFile; BackupPath=$backupPath; Changed=$true; RequestedFps=15; FpsStatus='REQUESTED_ONLY' }
}
function Invoke-ArkuzoGraphicsSettings {
    [CmdletBinding()]
    param([string[]]$InstallDirectories=@(), [switch]$ApplyGraphicsFlags, [switch]$MonitorOnly)
    if ($MonitorOnly) { return [pscustomobject]@{ Status='SKIPPED_MONITOR_ONLY'; Files=@(); Message='Graphics settings skipped: monitor-only.' } }
    if (-not $ApplyGraphicsFlags) { return [pscustomobject]@{ Status='SKIPPED_DISABLED'; Files=@(); Message='Graphics settings disabled.' } }
    if ($InstallDirectories.Count -eq 0) {
        return [pscustomobject]@{ Status='SKIPPED_NO_INSTALLATIONS'; Files=@(); Message='Roblox installation not found; graphics settings skipped.' }
    }
    $files = @()
    foreach ($directory in @($InstallDirectories | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.File]::Exists([IO.Path]::Combine($directory, 'RobloxPlayerBeta.exe'))) {
            throw 'Roblox Player installation changed or is unavailable; graphics settings refused.'
        }
        $settingsFile = Join-Path (Join-Path $directory 'ClientSettings') 'ClientAppSettings.json'
        $files += Merge-ArkuzoGraphicsFlags -SettingsFile $settingsFile
    }
    return [pscustomobject]@{
        Status='REQUESTED'; Files=@($files)
        Message='Graphics flags REQUESTED (texture quality 0 / MSAA 1 / 15 FPS). DFIntTaskSchedulerTargetFps is not on the Roblox Player allowlist and is ignored there; actual FPS and rendering are not verified. Restart compatible clients to read requested settings.'
    }
}
function Initialize-ArkuzoGraphicsSettings {
    if ($MonitorOnly -or -not $ownsControllerMutex -or -not $ApplyGraphicsFlags) { return }
    try {
    $graphicsRoots = @()
    foreach ($graphicsBase in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($graphicsBase)) { continue }
        $graphicsRoots += Join-Path $graphicsBase 'Roblox/Versions'
        $graphicsRoots += Join-Path $graphicsBase 'Roblox'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $graphicsRoots += Join-Path $env:ProgramData 'roblox/roblox'
        $graphicsRoots += Join-Path $env:ProgramData 'Roblox/Versions'
    }
    # Builds the Control Center's Roblox tab installed (docs/roblox-versions.md). The vault may not be
    # read yet at start-up, so it is read here for robloxVersionsDir.
    $managedVault = $script:nativeVault
    if ($null -eq $managedVault) { try { $managedVault = Invoke-ArkuzoVaultLocked { Read-ArkuzoVaultFile } } catch { $managedVault = $null } }
    $managedRoot = Get-ArkuzoManagedVersionsRoot $managedVault
    if ($managedRoot) { $graphicsRoots += $managedRoot }
    $graphicsImagePaths = @()
    foreach ($graphicsProcess in @(Get-Process -Name RobloxPlayerBeta -ErrorAction SilentlyContinue)) {
        try { if ($graphicsProcess.Path) { $graphicsImagePaths += $graphicsProcess.Path } }
        catch {} finally { $graphicsProcess.Dispose() }
    }
    $graphicsDirectories = @(Get-ArkuzoGraphicsInstallDirectories -SearchRoots $graphicsRoots -ProcessImagePaths $graphicsImagePaths)
    $graphicsReport = Invoke-ArkuzoGraphicsSettings -InstallDirectories $graphicsDirectories -ApplyGraphicsFlags:$ApplyGraphicsFlags -MonitorOnly:$MonitorOnly
    $script:graphicsStatus=$graphicsReport
    $script:graphicsAppliedDirectories = @{}
    foreach ($graphicsDirectory in $graphicsDirectories) { $script:graphicsAppliedDirectories[([string]$graphicsDirectory).ToLowerInvariant()] = $true }
    Write-Diagnostic 'GRAPHICS_STATUS' $graphicsReport
    if ($graphicsReport.Status -cne 'REQUESTED') { Warn-Throttled 'graphics-settings' $graphicsReport.Message }
    } catch {
        $script:graphicsStatus=[pscustomobject]@{Status='FAILED';Files=@();Message=('Graphics settings failed: '+$_.Exception.Message)}
        Write-Diagnostic 'GRAPHICS_STATUS' $script:graphicsStatus
        Warn-Throttled 'graphics-settings' $script:graphicsStatus.Message
    }
}
function Update-ArkuzoGraphicsForInstall([string]$Directory) {
    # A build installed after start-up (the Roblox tab) gets the same flags before its first launch.
    # Once per folder per engine run; a failure is reported and never blocks the launch.
    if ($MonitorOnly -or -not $ownsControllerMutex -or -not $ApplyGraphicsFlags -or [string]::IsNullOrWhiteSpace($Directory)) { return }
    if ($null -eq $script:graphicsAppliedDirectories) { $script:graphicsAppliedDirectories = @{} }
    $key = $Directory.ToLowerInvariant()
    if ($script:graphicsAppliedDirectories.ContainsKey($key)) { return }
    $script:graphicsAppliedDirectories[$key] = $true
    try {
        $report = Invoke-ArkuzoGraphicsSettings -InstallDirectories @($Directory) -ApplyGraphicsFlags:$true
        Write-Diagnostic 'GRAPHICS_STATUS' @{ Status = $report.Status; Files = $report.Files; Message = $report.Message; directory = $Directory; note = 'Applied before the first launch of a build installed after the saver started.' }
    } catch {
        Write-Diagnostic 'GRAPHICS_STATUS' @{ Status = 'FAILED'; Files = @(); Message = ('Graphics settings failed: ' + $_.Exception.Message); directory = $Directory }
        Warn-Throttled 'graphics-settings' ('Graphics settings failed for ' + $Directory + ': ' + $_.Exception.Message)
    }
}

$tracked = @{}
$script:observationBusy = $false
$script:observationCursor = 0
$dashboardIssues = @{}
$trimCount = 0
$cpuThreads = [Math]::Max(1, [int][Environment]::ProcessorCount)
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
# A failed log write pauses logging this long, then a new part is opened (see Write-Diagnostic).
$LogRetrySec = 5; $logRetryUtc = $null; $logFailureCount = 0
$nextLogSample = 0.0
$nextEventCheck = 0.0
$seenEventIds = @{}
$systemMemory = $null
$pagefileStatus = $null
$nextPagefileCheck = 0.0
$updateAvailableStatus = $null
$nextUpdateCheck = 15.0
$updateCheckInterval = 1800.0
$nextHealthSample = 0.0
$nextVoltCheck = 0.0
$nextNativeCheck = 0.0
$voltStatus = [pscustomobject]@{ safeToRecycle = $false; reason = 'Not checked' }
$voltParents = @{}
$voltPath = Join-Path $env:LOCALAPPDATA 'Volt\tauri-app.exe'
$lastGlobalTrim = -1e6
$recoveryAttempts = @()
$recoveryStatePath = Join-Path $DataDirectory 'recovery-state.json'
$recoveryJournalHealthy = $false # Initialized only while owning the controller lock.
$recoveryJournalCorrupt = $false
$recoveryPending = @{}; $suspendedAccounts = @{}; $launchAttempts = @()
$sessionObservedAccounts = @{}
$saverSessionStartEpochMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$voltControlStatus = [pscustomobject]@{available=$false;accounts=@();relaunchDelayMs=0}
$voltControlCheckedUtc = [datetime]::MinValue
$nextOutcomeCheck = 0.0; $nextPolicyCheck = 0.0; $nextRuntimeHeartbeat = 0.0
$quarantinedAccounts = @{}; $pendingLiveSettings = $null; $lastTotals = $null; $trimPlan = $null
$trimNowSignalPath = Join-Path $DataDirectory 'trim-now.signal'
try { $totalPhysicalMB = [math]::Round([double](Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory -OperationTimeoutSec 5 -ErrorAction Stop).TotalPhysicalMemory / 1MB, 1) }
catch { $totalPhysicalMB = 0 } # Adaptive trimming then keeps the configured interval.
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
function Invoke-ArkuzoLogRetention([string]$Directory, [string]$CurrentSession, [int]$MaxSessions, [double]$MaxTotalMB) {
    # Across sessions: keep the newest sessions while both caps hold (count and total
    # size); everything older goes. The current session's files are never deleted and
    # count first. Only this engine's own part files are touched, matched exactly
    # (Arkuzo-Pagefile-Requests.json and the Control Center's logs share the folder).
    # A file that can't be deleted (open elsewhere) is skipped. Never throws.
    $result = [ordered]@{ deletedFiles = 0; deletedMB = 0.0; keptSessions = 0; keptMB = 0.0; failed = 0 }
    try {
        if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return $result }
        $pattern = '\AArkuzo-(\d{8}-\d{6})-(\d+)-part\d+\.log\z'
        $files = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop | Where-Object { $_.Name -match $pattern })
        $sessions = @($files | Group-Object { $null = $_.Name -match $pattern; $matches[1] + '-' + $matches[2] } | ForEach-Object {
            [pscustomobject]@{ Tag = $_.Name; Stamp = $_.Name.Substring(0, 15); Files = @($_.Group); Bytes = [double](($_.Group | Measure-Object Length -Sum).Sum)
                Newest = (@($_.Group | Sort-Object LastWriteTimeUtc -Descending)[0]).LastWriteTimeUtc }
        } | Sort-Object @{ Expression = 'Stamp'; Descending = $true }, @{ Expression = 'Newest'; Descending = $true })
        $limitBytes = [double]$MaxTotalMB * 1MB
        $keptBytes = [double]0; $kept = 0; $full = $false
        foreach ($s in @($sessions | Where-Object { $_.Tag -ceq $CurrentSession })) { $keptBytes += $s.Bytes; $kept++ }
        foreach ($s in @($sessions | Where-Object { $_.Tag -cne $CurrentSession })) {
            if (-not $full -and $kept -lt $MaxSessions -and ($keptBytes + $s.Bytes) -le $limitBytes) { $keptBytes += $s.Bytes; $kept++; continue }
            $full = $true # Once a session doesn't fit, it and every older one go.
            foreach ($f in $s.Files) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $result.deletedFiles++; $result.deletedMB += $f.Length / 1MB }
                catch { $result.failed++ }
            }
        }
        $result.keptSessions = $kept; $result.keptMB = [math]::Round($keptBytes / 1MB, 1); $result.deletedMB = [math]::Round([double]$result.deletedMB, 1)
    } catch { $result.failed++ }
    return $result
}
function Step-ArkuzoLoopPhase([string]$Name) {
    # Charges the time since the last call to the running phase and starts $Name ('' = none).
    if ($null -eq $script:phaseClock) { $script:phaseClock = [Diagnostics.Stopwatch]::StartNew() }
    if ($null -eq $script:passPhaseMs) { $script:passPhaseMs = @{} }
    $now = $script:phaseClock.Elapsed.TotalMilliseconds
    if ($script:phaseName) { $script:passPhaseMs[$script:phaseName] = [double]$script:passPhaseMs[$script:phaseName] + ($now - [double]$script:phaseStartMs) }
    $script:phaseName = $Name; $script:phaseStartMs = $now
}
function Complete-ArkuzoLoopPass {
    # Folds one pass into the totals reported by the next RESOURCE_SAMPLE.
    Step-ArkuzoLoopPhase ''
    if ($null -eq $script:phaseStats) { $script:phaseStats = @{ passes = 0; totalMs = 0.0; maxMs = 0.0; phases = @{} } }
    $passMs = [double]0
    foreach ($name in @($script:passPhaseMs.Keys)) {
        $ms = [double]$script:passPhaseMs[$name]; $passMs += $ms
        $p = $script:phaseStats.phases[$name]
        if ($null -eq $p) { $p = @{ totalMs = 0.0; maxMs = 0.0 }; $script:phaseStats.phases[$name] = $p }
        $p.totalMs += $ms; if ($ms -gt $p.maxMs) { $p.maxMs = $ms }
    }
    $script:phaseStats.passes++; $script:phaseStats.totalMs += $passMs; if ($passMs -gt $script:phaseStats.maxMs) { $script:phaseStats.maxMs = $passMs }
    $script:passPhaseMs = @{}
}
function Get-ArkuzoLoopTimings {
    # Per-phase cost since the last call (milliseconds per pass: average and worst), then reset.
    $st = $script:phaseStats
    $script:phaseStats = $null
    if ($null -eq $st -or $st.passes -le 0) { return $null }
    $phases = [ordered]@{}
    foreach ($name in @($st.phases.Keys | Sort-Object)) {
        $phases[$name] = [ordered]@{ avgMs = [math]::Round([double]$st.phases[$name].totalMs / $st.passes, 1); maxMs = [math]::Round([double]$st.phases[$name].maxMs, 1) }
    }
    return [ordered]@{ passes = [int]$st.passes; passAvgMs = [math]::Round([double]$st.totalMs / $st.passes, 1); passMaxMs = [math]::Round([double]$st.maxMs, 1); phases = $phases }
}
function Step-ArkuzoDiagnosticLogPart {
    # Next part of this session's log; keep the current and four preceding parts.
    $script:logPart++
    if ($script:logPart -ge 5) {
        $expired = Join-Path $LogDirectory ("Arkuzo-$sessionTag-part$($script:logPart - 5).log")
        Remove-Item -LiteralPath $expired -Force -ErrorAction SilentlyContinue
    }
}
function Write-Diagnostic([string]$Kind, $Data) {
    # $logFailed says whether the LAST write failed: every audited step writes first and
    # checks it afterwards, so a closure still needs a successful log write. A failure
    # pauses logging for $LogRetrySec, then a new part is opened (the failed file may be
    # damaged or locked). One failure no longer blocks recovery for the rest of the session.
    if ($script:logFailed) {
        if ($null -eq $script:logRetryUtc) { $script:logRetryUtc = [datetime]::UtcNow.AddSeconds($(if ([double]$script:LogRetrySec -gt 0) { [double]$script:LogRetrySec } else { 5 })) }
        if ([datetime]::UtcNow -lt $script:logRetryUtc) { return }
        if ($null -ne $script:logWriter) { try { $script:logWriter.Dispose() } catch { }; $script:logWriter = $null }
        try { Step-ArkuzoDiagnosticLogPart } catch { }
    }
    try {
        if ($null -eq $script:logWriter) { Open-DiagnosticLog }
        if ($script:logWriter.BaseStream.Length -ge ([int64]$MaxLogMB * 1MB)) {
            $script:logWriter.Dispose(); $script:logWriter = $null
            Step-ArkuzoDiagnosticLogPart
            Open-DiagnosticLog
        }
        $record = [ordered]@{ time = (Get-Date).ToString('o'); session = $sessionTag; event = $Kind; data = $Data }
        $line = $record | ConvertTo-Json -Depth 12 -Compress
        if ($script:logFailed) {
            # First record of the reopened part says what happened (no error text: it may hold anything).
            $note = [ordered]@{ time = (Get-Date).ToString('o'); session = $sessionTag; event = 'LOG_WRITE_RECOVERED'; data = @{ failures = [int]$script:logFailureCount; part = [int]$script:logPart } }
            $script:logWriter.WriteLine(($note | ConvertTo-Json -Depth 4 -Compress))
        }
        $script:logWriter.WriteLine($line)
        $script:logFailed = $false; $script:logRetryUtc = $null
    } catch {
        $script:logFailed = $true
        $script:logFailureCount = [int]$script:logFailureCount + 1
        $script:logRetryUtc = [datetime]::UtcNow.AddSeconds($(if ([double]$script:LogRetrySec -gt 0) { [double]$script:LogRetrySec } else { 5 }))
        try { $script:dashboardIssues['log-write'] = @{ Message = "Logging failed: $($_.Exception.Message). Retrying in a new log file; recovery waits until a write succeeds."; Time = $(if ($null -ne $clock) { $clock.Elapsed.TotalSeconds } else { 0 }) } } catch { }
        if ($null -ne $script:logWriter) { try { $script:logWriter.Dispose() } catch { }; $script:logWriter = $null }
    }
}
function Write-ArkuzoFailureDiagnostic([string]$Kind, [Management.Automation.ErrorRecord]$Failure) {
    # Error messages, source text and invocation arguments can contain launch
    # tickets/cookies. Retain only bounded structural metadata, never raw text.
    try {
        $type = [string]$Failure.Exception.GetType().FullName
        if ($type.Length -gt 256) { $type = $type.Substring(0, 256) }
        $data = [ordered]@{
            pid = $PID; startTicks = $controllerStartTicks
            exceptionType = $type; hresult = $Failure.Exception.HResult
            category = [int]$Failure.CategoryInfo.Category
            line = $Failure.InvocationInfo.ScriptLineNumber
            column = $Failure.InvocationInfo.OffsetInLine
        }
        try { Write-Diagnostic $Kind $data } catch { $script:logFailed = $true }
        if ($script:logFailed) {
            # Two fixed overwritten files bound storage independently of the
            # rotating writer and keep cleanup from replacing fatal evidence.
            # Failure here must never replace the original terminating error.
            $record = [ordered]@{time=(Get-Date).ToString('o');session=$sessionTag;event=$Kind;data=$data}
            $text = $record | ConvertTo-Json -Depth 4 -Compress
            $file = if ($Kind -eq 'SAVER_FATAL_ERROR') { 'controller-failure.json' } else { 'controller-cleanup-failure.json' }
            [IO.File]::WriteAllText((Join-Path $LogDirectory $file), $text, (New-Object Text.UTF8Encoding($false)))
        }
    } catch { }
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
    # A member that is gone (it quit by itself, or a close whose bookkeeping failed
    # completed after all) may now have its Volt row count down.
    Set-ArkuzoFarmFreezeMemberStatus $State 'Exited'
    try { Register-ArkuzoNativeLaunchExit $ClientId $State } catch { }
    Register-ArkuzoExitedClientRecovery $ClientId $State
}
function Register-ArkuzoExitedClientRecovery([int]$ClientId, $State) {
    # When a whole server kicks the farm, recovery is serialized and most kicked
    # clients close themselves before their turn. A display change (remote desktop
    # disconnect, driver reload) freezes every client at once and they quit after
    # about three minutes. Their accounts still need the bounded Volt relaunch,
    # independent of restore_missing: the exit becomes a pending handoff instead
    # of a silently missing account.
    if ($MonitorOnly -or -not $ownsControllerMutex -or -not $restorePolicy.enabled -or -not $recoveryJournalHealthy -or $script:recoveryJournalCorrupt) { return }
    if ($null -eq $State -or $State.RecoveryRequested) { return }
    $recycle = $null -ne $State.HealthDecision -and $State.HealthDecision.Recycle
    $frozen = $null -ne $State.HangSince -and [double]$State.HangSince -ge 0
    if (-not $State.isDisconnected -and -not $recycle -and -not $frozen) { return }
    $key = [string]$State.BoundAccountId
    if ($key -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or $recoveryPending.ContainsKey($key)) { return }
    if ($restorePolicy.excluded_account_ids -contains $key -or ($null -ne $script:suspendedAccounts -and $script:suspendedAccounts.ContainsKey($key))) { return }
    $utc = [datetime]::UtcNow
    if (Test-ArkuzoAccountQuarantined $key $utc) { return }
    $entry = New-ArkuzoPendingEntry $key ([string]$State.BoundTrackerId) $ClientId ([long]$State.StartTicks)
    # The client is already gone: Volt's own relaunch gets restore_wait_sec from now.
    $entry.closedUtc = $utc.ToString('o')
    $previous = $recoveryPending.Clone()
    try {
        $script:recoveryPending[$key] = $entry
        Save-ArkuzoRecoveryJournal
        $why = if ($State.isDisconnected) { 'IN_GAME_DISCONNECT' } elseif ($recycle) { [string]$State.HealthDecision.Reason } else { 'UNRESPONSIVE_EXIT' }
        Write-Diagnostic 'EXITED_CLIENT_RECOVERY_QUEUED' @{ accountId = $key; pid = $ClientId; startTicks = $State.StartTicks; reason = $why; disconnectReason = $State.DisconnectReason
            note = 'Client closed itself while disconnected, frozen or waiting for recovery; its account is queued for a bounded Volt relaunch.' }
    } catch {
        $script:recoveryPending = $previous; $script:recoveryJournalHealthy = $false
        Warn-Throttled 'recovery-journal' 'Recovery outcome persistence/audit failed. Destructive recovery blocked.'
    }
}
# Pure crash-handler authorization; snapshots contain no process operations.
function Test-ArkuzoCrashHandlerIdentity($Snapshot, [string[]]$TrustedRoots) {
    try {
        if ($null -eq $Snapshot -or $Snapshot.Id -isnot [int] -or $Snapshot.Id -le 0 -or
            $Snapshot.StartTicks -isnot [long] -or $Snapshot.StartTicks -le 0 -or
            $Snapshot.Handle -isnot [IntPtr] -or $Snapshot.Handle -eq [IntPtr]::Zero -or
            $Snapshot.HasExited -isnot [bool] -or $Snapshot.HasExited -or
            $Snapshot.ProcessName -ne 'RobloxCrashHandler' -or $Snapshot.CimName -ne 'RobloxCrashHandler.exe' -or
            $Snapshot.CimId -ne $Snapshot.Id -or $Snapshot.SignatureStatus -cne 'Valid' -or
            $Snapshot.SignerSubject -notmatch '(?i)(?:^|,\s*)O=(?:"Roblox Corporation"|Roblox Corporation)(?:,|$)') { return $false }
        $paths = @($Snapshot.Path, $Snapshot.CimPath, $Snapshot.SignaturePath)
        foreach ($path in $paths) {
            if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\)') { return $false }
        }
        $imagePath = [IO.Path]::GetFullPath($Snapshot.Path)
        if ([IO.Path]::GetFileName($imagePath) -ne 'RobloxCrashHandler.exe' -or
            -not [string]::Equals($imagePath, [IO.Path]::GetFullPath($Snapshot.CimPath), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($imagePath, [IO.Path]::GetFullPath($Snapshot.SignaturePath), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        foreach ($root in $TrustedRoots) {
            if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\)') { continue }
            $prefix = [IO.Path]::GetFullPath($root).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
            if ($imagePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    } catch { return $false }
}
function Get-ArkuzoOrphanHandlerDecision($Handler, $Parent, [datetime]$NowUtc, $Monitor, $OwnsMutex, [string[]]$TrustedRoots, $Expected) {
    $reason = 'ReadOnly'; $close = $false
    try {
        if ($Monitor -is [bool] -and -not $Monitor -and $OwnsMutex -is [bool] -and $OwnsMutex) {
            $reason = 'IdentityUnverified'
            if ((Test-ArkuzoCrashHandlerIdentity $Handler $TrustedRoots) -and $null -ne $Expected -and
                $Handler.Id -eq $Expected.Id -and $Handler.StartTicks -eq $Expected.StartTicks -and $Handler.Handle -eq $Expected.Handle -and
                [string]::Equals([string]$Handler.Path, [string]$Expected.Path, [StringComparison]::OrdinalIgnoreCase) -and
                $Handler.ParentId -is [int] -and $Handler.ParentId -gt 0 -and $Handler.ParentId -ne $Handler.Id -and
                ($null -eq $Expected.ParentId -or $Handler.ParentId -eq $Expected.ParentId)) {
                $reason = 'YoungHandler'
                if (($NowUtc.ToUniversalTime().Ticks - $Handler.StartTicks) -gt [TimeSpan]::FromSeconds(60).Ticks) {
                    $reason = 'ParentUnverified'
                    if ($null -ne $Parent -and $Parent.QuerySucceeded -is [bool] -and $Parent.QuerySucceeded -and
                        $Parent.Id -eq $Handler.ParentId -and $Parent.Count -is [int]) {
                        if ($Parent.Count -eq 0 -and $Parent.AbsenceConfirmed -is [bool] -and $Parent.AbsenceConfirmed) { $close = $true; $reason = 'ParentAbsent' }
                        elseif ($Parent.Count -eq 1 -and $Parent.HasExited -is [bool] -and
                            $Parent.Handle -is [IntPtr] -and $Parent.Handle -ne [IntPtr]::Zero -and
                            $Parent.CimId -eq $Parent.Id -and $Parent.StartTicks -is [long] -and $Parent.StartTicks -gt 0 -and
                            $Parent.CimStartTicks -is [long] -and $Parent.CimStartTicks -gt 0 -and
                            ($Parent.StartTicks - $Parent.CimStartTicks) -ge 0 -and ($Parent.StartTicks - $Parent.CimStartTicks) -lt 10) {
                            if ($Parent.HasExited) {
                                if ($Parent.StartTicks -le $Handler.StartTicks) {
                                    $close = $true; $reason = 'ParentAbsent'
                                }
                            } else {
                                # WMI timestamps have microsecond precision; retain/recheck the exact .NET generation too.
                                $close = $Parent.StartTicks -gt $Handler.StartTicks
                                $reason = if ($close) { 'ParentPidReused' } else { 'HealthyParent' }
                            }
                        }
                    }
                }
            }
        }
    } catch { $close = $false; $reason = 'ObservationInvalid' }
    return [pscustomobject]@{ Close = $close; Reason = $reason }
}
function Test-ArkuzoOrphanHandlerExit($Expected, $Readback) {
    return ($null -ne $Expected -and $null -ne $Readback -and
        $Expected.Id -is [int] -and $Expected.Id -gt 0 -and $Expected.StartTicks -is [long] -and $Expected.StartTicks -gt 0 -and
        $Expected.Handle -is [IntPtr] -and $Expected.Handle -ne [IntPtr]::Zero -and
        $Readback.Id -eq $Expected.Id -and $Readback.StartTicks -eq $Expected.StartTicks -and $Readback.Handle -eq $Expected.Handle -and
        $Readback.WaitConfirmed -is [bool] -and $Readback.WaitConfirmed -and $Readback.HasExited -is [bool] -and $Readback.HasExited)
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
    version = $ArkuzoRuntimeVersion; health = $healthPolicy; recovery = $restorePolicy; pagefile = $pagefilePolicy
    mode = $Mode; advisoryMB = $MaxRamMB; softLimit = [bool]$SoftLimit
    trimming = [bool]$EnableTrimming; trimSeconds = $TrimEverySec; priority = $Priority
    memoryPriority = $MemoryPriority; adaptiveTrim = [bool]$AdaptiveTrim; pressureTrimAvailablePercent = $PressureTrimAvailablePercent
    totalPhysicalMB = $totalPhysicalMB; settingsError = $startupSettingsError
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

function Initialize-ArkuzoNativePrivileges {
    $status = [pscustomobject][ordered]@{
        attempted = $false; available = $null; reason = 'ControllerMutexNotOwned'; privileges = @()
        note = 'Only privileges already assigned to the current process token can be enabled. No elevation is requested; target protections still apply. Hard working-set limits remain opt-in.'
    }
    if ($MonitorOnly) { $status.reason = 'MonitorOnly' }
    elseif ($ownsControllerMutex) {
        $status.attempted = $true; $status.reason = 'Completed'
        foreach ($name in @('SeDebugPrivilege', 'SeIncreaseWorkingSetPrivilege')) {
            try { $status.privileges += [Arkuzo.MemorySaverNativeV1]::EnableCurrentProcessPrivilege($name) }
            catch {
                # Unexpected managed/PInvoke failures must also remain visible and best-effort.
                $failure = $_.Exception
                while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
                $code = $null; $message = $failure.Message
                if ($failure -is [ComponentModel.Win32Exception]) {
                    $code = $failure.NativeErrorCode
                    $message = 'Win32 ' + $code + ': ' + $message
                }
                $status.privileges += [pscustomobject]@{
                    Name=$name; Status='Failed'; Succeeded=$false; Present=$null; Enabled=$false
                    Win32Error=$code; Operation='EnableCurrentProcessPrivilege'; Message=$message; AdjustmentReturnedSuccess=$null
                }
            }
        }
        $status.available = @($status.privileges | Where-Object { -not $_.Succeeded -or -not $_.Enabled }).Count -eq 0
    }
    $script:nativePrivilegeInitialization = $status
    Write-ArkuzoNativePrivilegeStatus $status
    return $status
}

function Write-ArkuzoNativePrivilegeStatus($Status) {
    Write-Diagnostic 'NATIVE_PRIVILEGES' $Status
    if (-not $Status.attempted) { return }
    foreach ($privilege in @($Status.privileges)) {
        # Normal (non-administrator) accounts don't hold SeDebugPrivilege at all; the saver
        # works without it. Only a privilege that is held but can't be enabled is worth a notice.
        if ($privilege.Status -ceq 'NotAssigned' -or $privilege.Present -eq $false) { continue }
        if (-not $privilege.Succeeded -or -not $privilege.Enabled) {
            Warn-Throttled ('native-privilege-' + $privilege.Name) ($privilege.Name + ' unavailable: ' + $privilege.Message + ' Native operations remain best-effort; process protections still apply.')
        }
    }
}

# ---------------------------------------------------------------------------
# Resource settings of a client (priority, CPU affinity, memory priority, working-set limits).
# Three blue screens (10-11 Nov, bugcheck 0x1E, STATUS_PROCESS_IS_TERMINATING inside ntoskrnl)
# each hit while a RobloxPlayerBeta.exe the saver had started 2-5 s earlier was exiting during
# startup and another process was working on it. A client is therefore left alone until it has
# lived health.config_grace_sec and has a window (or answered once); every native call is
# skipped for a client that has exited or that the saver is closing.
# ---------------------------------------------------------------------------
function Test-ArkuzoClientClosing($State) {
    return ($null -ne $State -and ([bool]$State.RecoveryRequested -or [bool]$State.Closing))
}
function Test-ArkuzoClientLive($Client) {
    # Refresh, then HasExited (WaitForSingleObject on the process handle, timeout 0).
    try { $Client.Refresh(); $exited = $Client.HasExited; return ($exited -is [bool] -and -not $exited) } catch { return $false }
}
function Test-ArkuzoClientConfigReady($State, [double]$AgeSec, [bool]$WindowPresent, [double]$GraceSec) {
    # Pure apart from the latch on $State. Ready once the client is $GraceSec old and has a window
    # or has answered; it stays ready (a later missing window does not undo the settings).
    if ($null -eq $State) { return $false }
    if (Test-ArkuzoClientClosing $State) { return $false }
    if ($State.ConfigReady) { return $true }
    if ($AgeSec -lt $GraceSec -or -not ($WindowPresent -or [bool]$State.EverResponded)) { return $false }
    $State.ConfigReady = $true
    return $true
}
# One small function per native call, so tests can stand in for them.
function Read-ArkuzoClientLimits($Client) { return [Arkuzo.MemorySaverNativeV1]::ReadLimits($Client.Handle) }
function Read-ArkuzoClientMemoryPriority($Client) { return [Arkuzo.MemorySaverNativeV1]::ReadMemoryPriority($Client.Handle) }
function Set-ArkuzoClientMemoryPriority($Client, [uint32]$Value) { [Arkuzo.MemorySaverNativeV1]::SetMemoryPriority($Client.Handle, $Value) }
function Set-ArkuzoClientLimits($Client, [uint64]$Min, [uint64]$Max, [uint32]$Flags) { [Arkuzo.MemorySaverNativeV1]::SetLimits($Client.Handle, $Min, $Max, $Flags) }
function Get-ArkuzoClientAffinityMask($Original, [int]$Slot, [int]$Cores) { return [Arkuzo.MemorySaverNativeV1]::Affinity(([IntPtr]$Original).ToInt64(), $Slot, $Cores) }
function Invoke-ArkuzoClientTrim($Client) { [Arkuzo.MemorySaverNativeV1]::Trim($Client.Handle) }
function Invoke-ArkuzoClientConfiguration($Client, $State, [double]$Now) {
    # Caller: Test-ArkuzoClientConfigReady. The first time, the original values are read (the
    # moment before anything changes, so restoring on exit puts back what Roblox had). Then
    # priority, affinity, memory priority and the opt-in hard limit are applied; each step first
    # checks that the client still runs and is not being closed. Returns $false when nothing ran.
    if ((Test-ArkuzoClientClosing $State) -or -not (Test-ArkuzoClientLive $Client)) { return $false }
    if (-not $State.Configured) {
        $State.Priority = $Client.PriorityClass; $State.Affinity = $Client.ProcessorAffinity
        $State.Limits = $(try { Read-ArkuzoClientLimits $Client } catch { $null })
        $State.MemoryPriority = $(try { Read-ArkuzoClientMemoryPriority $Client } catch { $null })
        $State.Configured = $true
        Write-Diagnostic 'RESOURCE_CONFIGURATION_REQUESTED' @{ pid = $Client.Id; priority = $Priority; logicalCpu = $CoresPerInstance; memoryPriority = $MemoryPriority; hardCap = (-not [bool]$SoftLimit); targetMB = $MaxRamMB
            originalPriority = [string]$State.Priority; originalAffinity = $(try { ([IntPtr]$State.Affinity).ToInt64() } catch { $null }); graceSec = $healthPolicy.config_grace_sec }
    }
    foreach ($operation in @('Priority','Affinity','MemoryPriority','Limits')) {
        if ((Test-ArkuzoClientClosing $State) -or -not (Test-ArkuzoClientLive $Client)) { break }
        try {
            switch ($operation) {
                'Priority' { $Client.PriorityClass = $Priority }
                'Affinity' { if ($null -ne $State.Affinity) { $Client.ProcessorAffinity = Get-ArkuzoClientAffinityMask $State.Affinity $State.Slot $CoresPerInstance } }
                'MemoryPriority' {
                    # Only change what can be restored on exit.
                    if ($null -ne $State.MemoryPriority) {
                        Set-ArkuzoClientMemoryPriority $Client (ConvertTo-ArkuzoMemoryPriorityValue $MemoryPriority)
                        $State.MemoryPriorityChanged = $true
                    }
                }
                'Limits' {
                    if (-not $SoftLimit -and $null -ne $State.Limits) {
                        Set-ArkuzoClientLimits $Client 1MB $maxBytes $limitFlags
                        $State.LimitsChanged = $true
                    }
                }
            }
        } catch { Warn-Throttled "$($Client.Id)-$operation" "PID $($Client.Id): $operation failed: $($_.Exception.Message)" }
    }
    $State.LastConfig = $Now
    return $true
}

function Restore-Client($Client, $State) {
    # Start time prevents restoring an unrelated process after PID reuse.
    if ($Client.StartTime.ToUniversalTime().Ticks -ne $State.StartTicks -or $MonitorOnly) { return }
    # A client still inside its startup grace was never configured: nothing to put back.
    $operations = if ($State.Configured) { @('Priority','Affinity','MemoryPriority','Limits') } else { @() }
    foreach ($operation in $operations) {
        if (-not (Test-ArkuzoClientLive $Client)) { break }
        try {
            switch ($operation) {
                'Priority' { if ($null -eq $State.Priority) { continue }; $Client.PriorityClass = $State.Priority }
                'Affinity' { if ($null -eq $State.Affinity) { continue }; $Client.ProcessorAffinity = $State.Affinity }
                'MemoryPriority' {
                    if (-not $State.MemoryPriorityChanged -or $null -eq $State.MemoryPriority) { continue }
                    Set-ArkuzoClientMemoryPriority $Client ([uint32]$State.MemoryPriority)
                }
                'Limits' {
                    if (-not $State.LimitsChanged -or $null -eq $State.Limits) { continue }
                    # Explicitly clear introduced hard limits when originally absent.
                    $restoreFlags = [uint32]0
                    if (($State.Limits[2] -band 1) -ne 0) { $restoreFlags = $restoreFlags -bor 1 }
                    else { $restoreFlags = $restoreFlags -bor 2 }
                    if (($State.Limits[2] -band 4) -ne 0) { $restoreFlags = $restoreFlags -bor 4 }
                    else { $restoreFlags = $restoreFlags -bor 8 }
                    Set-ArkuzoClientLimits $Client $State.Limits[0] $State.Limits[1] $restoreFlags
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

try {
    if (-not $MonitorOnly) {
        $controllerMutex = New-Object Threading.Mutex($false, 'Local\ArkuzoSaver-ProcessController')
        try { $ownsControllerMutex = $controllerMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsControllerMutex = $true }
        if (-not $ownsControllerMutex) { throw 'Another ArkuzoSaver controller is already running.' }
        [Arkuzo.LoopWatchdogV1]::Start((Join-Path $DataDirectory 'saver-stall.json'), 60)
        Initialize-ArkuzoNativePrivileges | Out-Null
        [Arkuzo.LoopWatchdogV1]::Mark('log retention')
        $retention = Invoke-ArkuzoLogRetention $LogDirectory $sessionTag $MaxLogSessions $MaxLogTotalMB
        if ($retention.deletedFiles -gt 0 -or $retention.failed -gt 0) { Write-Diagnostic 'LOG_RETENTION' @{ maxSessions = $MaxLogSessions; maxTotalMB = $MaxLogTotalMB; deletedFiles = $retention.deletedFiles; deletedMB = $retention.deletedMB; keptSessions = $retention.keptSessions; keptMB = $retention.keptMB; failed = $retention.failed } }
        Initialize-ArkuzoGraphicsSettings
        Initialize-ArkuzoRecoveryJournal
        Resolve-ArkuzoAccountProvider
        Update-VoltRecoveryCapability -SyncControl
        Sync-ArkuzoAutoexecSignals
    }
    while ($true) {
        $script:loopPass = [long]$script:loopPass + 1
        Step-ArkuzoLoopPhase 'signals'
        [Arkuzo.LoopWatchdogV1]::Mark('loop: executor signals')
        $recoveredStall = [Arkuzo.LoopWatchdogV1]::TakeRecovered()
        if ($recoveredStall) {
            $stallParts = $recoveredStall.Split('|')
            Write-Diagnostic 'SAVER_STALL_RECOVERED' @{ phase = $stallParts[0]; stalledSec = [double]$stallParts[1] }
            Warn-Throttled 'saver-stall' ("Saver was blocked for $($stallParts[1])s during '$($stallParts[0])'.")
        }
        Process-ArkuzoExecutorSignals
        $swPhase = [Diagnostics.Stopwatch]::StartNew()
        Invoke-ArkuzoHealthObservation
        $swPhase.Stop()
        if ($swPhase.Elapsed.TotalSeconds -gt 5) {
            Warn-Throttled 'dashboard-stall-health' "Health observation stalled for $([math]::Round($swPhase.Elapsed.TotalSeconds,2))s"
            Write-Diagnostic 'DASHBOARD_STALL' @{ phase='HealthObservation'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
        }
        if ($RunForSec -gt 0 -and $clock.Elapsed.TotalSeconds -ge $RunForSec) { break }
        if (($StopFile -and (Test-Path -LiteralPath $StopFile)) -or (Test-Path -LiteralPath (Join-Path $DataDirectory 'stop.signal'))) { break }
        Step-ArkuzoLoopPhase 'policy'
        if ($clock.Elapsed.TotalSeconds -ge $nextPolicyCheck) {
            $swPhase = [Diagnostics.Stopwatch]::StartNew()
            [Arkuzo.LoopWatchdogV1]::Mark('policy reload')
            Update-ArkuzoLivePolicy
            if (-not $MonitorOnly) { Resolve-ArkuzoAccountProvider }
            if ($null -ne $pendingLiveSettings) { Update-ArkuzoLiveSettings $pendingLiveSettings; $pendingLiveSettings = $null }
            Sync-ArkuzoAutoexecSignals
            $swPhase.Stop()
            if ($swPhase.Elapsed.TotalSeconds -gt 5) {
                Write-Diagnostic 'DASHBOARD_STALL' @{ phase='PolicyCheck'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
            }
            $nextPolicyCheck = $clock.Elapsed.TotalSeconds + 10
        }
        Step-ArkuzoLoopPhase 'memory'
        if ($clock.Elapsed.TotalSeconds -ge $nextHealthSample) {
            $swPhase = [Diagnostics.Stopwatch]::StartNew()
            try { $systemMemory = Get-ArkuzoSystemMemory } catch { $systemMemory = $null; Warn-Throttled 'memory-query' 'OS commit telemetry unavailable.' }
            $swPhase.Stop()
            if ($swPhase.Elapsed.TotalSeconds -gt 5) {
                Write-Diagnostic 'DASHBOARD_STALL' @{ phase='MemoryQuery'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
            }
            $nextHealthSample = $clock.Elapsed.TotalSeconds + 5
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextPagefileCheck) {
            $swPhase = [Diagnostics.Stopwatch]::StartNew()
            [Arkuzo.LoopWatchdogV1]::Mark('pagefile check')
            Update-ArkuzoPagefileStatus
            if ($pagefilePolicy.enabled) {
                try { $systemMemory = Get-ArkuzoSystemMemory } catch { $systemMemory=$null; Warn-Throttled 'memory-query' 'OS commit telemetry unavailable after pagefile observation.' }
            }
            $swPhase.Stop()
            if ($swPhase.Elapsed.TotalSeconds -gt 5) {
                Write-Diagnostic 'DASHBOARD_STALL' @{ phase='PagefileCheck'; durationSec=[math]::Round($swPhase.Elapsed.TotalSeconds,2) }
            }
            $nextPagefileCheck = $clock.Elapsed.TotalSeconds + 30
        }
        Step-ArkuzoLoopPhase 'volt'
        Poll-ArkuzoVoltControlAsync
        if ($clock.Elapsed.TotalSeconds -ge $nextVoltCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('Volt status')
            Update-VoltRecoveryCapability
            Start-ArkuzoVoltControlStatusAsync
            $nextVoltCheck = $clock.Elapsed.TotalSeconds + 15
        }
        Step-ArkuzoLoopPhase 'accounts'
        if ((Test-ArkuzoNativeProvider) -and -not $MonitorOnly -and $clock.Elapsed.TotalSeconds -ge $nextNativeCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('Arkuzo accounts')
            $script:voltControlStatus = Get-ArkuzoNativeStatus; $script:voltControlCheckedUtc = [datetime]::UtcNow
            Invoke-ArkuzoNativeRequests
            [Arkuzo.LoopWatchdogV1]::Mark('arrange windows')
            Update-ArkuzoWindowArrangement
            $nextNativeCheck = $clock.Elapsed.TotalSeconds + 3
        }
        Step-ArkuzoLoopPhase 'launches'
        if (-not $MonitorOnly) {
            [Arkuzo.LoopWatchdogV1]::Mark('launch completion')
            # Ticket requests run in the background; start the clients whose ticket arrived.
            if (Test-ArkuzoNativeProvider) { Complete-ArkuzoNativeLaunches } else { Stop-ArkuzoNativeTicketJobs }
        }
        Step-ArkuzoLoopPhase 'clients'
        Poll-ArkuzoVersionCheckAsync
        if ($clock.Elapsed.TotalSeconds -ge $nextUpdateCheck) {
            Start-ArkuzoVersionCheckAsync
            $nextUpdateCheck = $clock.Elapsed.TotalSeconds + $updateCheckInterval
        }
        $trimPlan = Get-ArkuzoTrimPlan $systemMemory $totalPhysicalMB $TrimEverySec ([bool]$AdaptiveTrim) $PressureTrimAvailablePercent
        if (-not $MonitorOnly -and (Test-Path -LiteralPath $trimNowSignalPath)) {
            # Operator request (Control Center): make every client due now. Warmup,
            # soft target, responsiveness and global spacing still apply.
            Remove-Item -LiteralPath $trimNowSignalPath -Force -ErrorAction SilentlyContinue
            foreach ($state in @($tracked.Values)) { $state.LastTrim = -1e6 }
            Write-Diagnostic 'TRIM_NOW_REQUESTED' @{ clients = $tracked.Count }
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
            [Arkuzo.LoopWatchdogV1]::Mark('client ' + $client.Id + ': sample')
            Invoke-ArkuzoHealthObservation
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
                # The window is probed once, after the log IO below (Get-ArkuzoRecoveryHealthSample);
                # until then the previous sample decides about trimming.
                $isResponding = $false; $launchError = $false
                if ($tracked.ContainsKey($id) -and $tracked[$id].StartTicks -ne $ticks) { Record-ClientExit $id $tracked[$id] 'PID reused'; $tracked.Remove($id); if ($script:accountNameCache.ContainsKey($id)) { $script:accountNameCache.Remove($id) } }
                # Manage clients even while loading or with no visible window.
                if (-not $tracked.ContainsKey($id)) {
                    [Arkuzo.LoopWatchdogV1]::Mark('client ' + $id + ': first contact')
                    $slot = 0
                    $taken = @($tracked.Values | ForEach-Object { $_.Slot })
                    while ($taken -contains $slot) { $slot++ }
                    # Nothing is read from or set on the process here: a client can still die
                    # during startup, and the originals are captured just before the first change
                    # (Invoke-ArkuzoClientConfiguration, after health.config_grace_sec).
                    $state = @{
                        StartTicks = $ticks; Slot = $slot
                        Priority = $null; Affinity = $null; Limits = $null; MemoryPriority = $null; MemoryPriorityChanged = $false
                        Configured = $false; ConfigReady = $false; Closing = $false; RobloxBuild = $null; BuildSuccessSeen = $false
                        Watcher = $null; LastSnapshot = $null; LastStatus = $null
                        LimitsChanged = $false; LastProgress = $clock.Elapsed.TotalSeconds
                        LastTrim = $clock.Elapsed.TotalSeconds; LastConfig = -1e6; MinimizedByUs = $false
                        LastCpu = $client.TotalProcessorTime.TotalSeconds; CpuTime = $clock.Elapsed.TotalSeconds
                        HangSince = -1.0; StartupErrorSince = -1.0; DisconnectSince = -1.0; ParentId = 0; HealthDecision = $null; RecoveryRequested = $false
                        GameReady = $false; EverGameReady = $false; StartupGameHistory = 'UNKNOWN'; GameLogScanned = $false; LogPath = $null; LogOffset = [int64]0; TrackerId = $null; isDisconnected = $false; DisconnectReason = $null
                        BoundAccountId = $null; BoundTrackerId = $null
                        HangCpuBase = $null; HangCpuBaseAt = $null; HangCpuPercent = $null; FarmFreezeEpisode = $null; FarmFreezePid = $null; FreezeSince = -1.0; StartedSec = $null; EverResponded = $false
                    }
                    try {
                        $procRecord = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -OperationTimeoutSec 5 -ErrorAction Stop
                        $state.ParentId = [int]$procRecord.ParentProcessId
                        if ($procRecord.CommandLine) {
                            $state.TrackerId = Get-ArkuzoBrowserTrackerId $procRecord.CommandLine
                        }
                        # The Roblox build (version folder) for the dead-build guard.
                        if ($procRecord.ExecutablePath) { $state.RobloxBuild = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$procRecord.ExecutablePath)) }
                    } catch { }
                    # Launches are spaced from clients that start by other means (Volt, by hand).
                    # The engine's own launches are already spaced by launchDelaySec from their
                    # start; counting their appearance too would stretch every gap by the load time.
                    if (-not (Test-ArkuzoOwnNativeLaunch ([string]$state.TrackerId))) { $script:lastClientStartUtc = [datetime]::UtcNow }
                    if ($state.TrackerId) {
                        try {
                            $bound = Get-ArkuzoControlledAccount $state.TrackerId $id
                            if ($null -ne $bound) {
                                $script:sessionObservedAccounts[[string]$bound.accountId] = $true
                                $state.BoundAccountId = [string]$bound.accountId; $state.BoundTrackerId = [string]$bound.trackerId
                            }
                        } catch { }
                    }
                    $tracked[$id] = $state
                    $watcher = $null
                    try {
                        $watcher = [Diagnostics.Process]::GetProcessById($id)
                        $watcher.Handle | Out-Null # Retain a handle so exit code can survive process exit.
                        $state.Watcher = $watcher
                    } catch { if ($null -ne $watcher) { $watcher.Dispose() }; $watcher = $null }
                    Write-Diagnostic 'CLIENT_START' @{
                        pid = $id; startTicks = $ticks; slot = $slot; robloxVersion = $state.RobloxBuild
                        residentMB = $client.WorkingSet64 / 1MB; privateMB = $client.PrivateMemorySize64 / 1MB
                    }
                }
                $state = $tracked[$id]
                if ($null -ne $state.LastSnapshot) { $isResponding = ($state.LastSnapshot['responding'] -eq $true); $launchError = ($state.LastSnapshot['launchError'] -eq $true) }
                if ($state.ParentId -le 0 -or [string]::IsNullOrWhiteSpace($state.TrackerId)) {
                    if ($null -ne $voltControlStatus -and $voltControlStatus.available -and $null -ne $voltControlStatus.accounts) {
                        $matchedAcct = @($voltControlStatus.accounts | Where-Object { [int]$_.processId -eq $id })
                        if ($matchedAcct.Count -eq 1) {
                            if ($state.ParentId -le 0 -and $null -ne $voltControlStatus.managerId -and [int]$voltControlStatus.managerId -gt 0) {
                                $state.ParentId = [int]$voltControlStatus.managerId
                            }
                            if ([string]::IsNullOrWhiteSpace($state.TrackerId) -and -not [string]::IsNullOrWhiteSpace($matchedAcct[0].trackerId)) {
                                $state.TrackerId = [string]$matchedAcct[0].trackerId
                            }
                        }
                    }
                    if ($state.ParentId -le 0) {
                        try {
                            $procRecord = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -OperationTimeoutSec 5 -ErrorAction Stop
                            $state.ParentId = [int]$procRecord.ParentProcessId
                            if ($procRecord.CommandLine -and [string]::IsNullOrWhiteSpace($state.TrackerId)) {
                                $state.TrackerId = Get-ArkuzoBrowserTrackerId $procRecord.CommandLine
                            }
                        } catch { }
                    }
                    if ($state.ParentId -le 0 -and $null -ne $script:voltParents -and $script:voltParents.Count -eq 1) {
                        $singleParentId = [int](@($script:voltParents.Keys)[0])
                        if ($singleParentId -gt 0) { $state.ParentId = $singleParentId }
                    }
                    if ($state.TrackerId) {
                        try {
                            $bound = Get-ArkuzoControlledAccount $state.TrackerId $id
                            if ($null -ne $bound) {
                                $script:sessionObservedAccounts[[string]$bound.accountId] = $true
                                $state.BoundAccountId = [string]$bound.accountId; $state.BoundTrackerId = [string]$bound.trackerId
                            }
                        } catch { }
                    }
                }
                $now = $clock.Elapsed.TotalSeconds
                # Reapply periodically without hammering native setters on each poll; nothing before
                # the startup grace and a window (Test-ArkuzoClientConfigReady), never on a client
                # that has exited or is being closed.
                if (-not $MonitorOnly -and ($now - $state.LastConfig) -ge 10 -and
                    (Test-ArkuzoClientConfigReady $state (([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds) ($client.MainWindowHandle -ne [IntPtr]::Zero) ([double]$healthPolicy.config_grace_sec))) {
                    [void](Invoke-ArkuzoClientConfiguration $client $state $now)
                }
                if (-not $MonitorOnly -and $Minimize -and -not (Test-ArkuzoClientClosing $state) -and $client.MainWindowHandle -ne [IntPtr]::Zero) {
                    if (-not [Arkuzo.MemorySaverNativeV1]::IsIconic($client.MainWindowHandle)) {
                        if ([Arkuzo.MemorySaverNativeV1]::ShowWindowAsync($client.MainWindowHandle, 6)) {
                            $state.MinimizedByUs = $true
                        }
                    }
                }
                if (-not $MonitorOnly -and $EnableTrimming -and -not $launchError -and -not (Test-ArkuzoClientClosing $state) -and (([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds -ge $healthPolicy.warmup_sec) -and ($now - $state.LastTrim) -ge $trimPlan.IntervalSec -and ($now - $lastGlobalTrim) -ge $healthPolicy.trim_spacing_sec) {
                    # Opt-in only, above target, skip loading/unresponsive clients.
                    if ($client.WorkingSet64 -gt $maxBytes -and $window -ne [IntPtr]::Zero -and $isResponding -and (Test-ArkuzoClientLive $client)) {
                        try {
                            $beforeMB = $client.WorkingSet64 / 1MB
                            Invoke-ArkuzoClientTrim $client; $script:trimCount++; $lastGlobalTrim = $now
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
                    $cpu = [Math]::Min([double]100, [Math]::Max([double]0, [double](100 * ($cpuTime - $state.LastCpu) / ($elapsed * $cpuThreads))))
                    if (($cpuTime - $state.LastCpu) -gt 0.001) { $state.LastProgress = $sampleTime }
                    $state.LastCpu = $cpuTime; $state.CpuTime = $sampleTime
                }
                $totalCpu += $cpu
                $status = 'WINDOW OPEN'
                if (($sampleTime - $state.LastProgress) -ge 10) { $status = 'NO CPU >10s' }
                if ($client.MainWindowHandle -eq [IntPtr]::Zero) { $status = 'LOADING' }
                elseif ([Arkuzo.MemorySaverNativeV1]::IsIconic($client.MainWindowHandle)) { $status = 'MINIMIZED' }
                [Arkuzo.LoopWatchdogV1]::Mark('client ' + $id + ': game log')
                if ($null -eq $state.LogPath) {
                    $state.LogPath = Find-RobloxProcessLog -TargetProcessId $id -TrackerId $state.TrackerId -StartTimeUtc $client.StartTime.ToUniversalTime()
                }
                # The head says whether an adopted client already joined. Under memory
                # pressure the read can time out (9 Nov restart: 8 of 11 clients stayed
                # "not in game"), so retry it every 15 s until it is read once.
                if ($null -ne $state.LogPath -and -not $state.LogHeadRead -and -not $state.GameReady -and
                    ($null -eq $state.LogHeadTriedSec -or ($sampleTime - [double]$state.LogHeadTriedSec) -ge 15)) {
                    $state.LogHeadTriedSec = $sampleTime
                    try {
                        $head = Read-ArkuzoBoundedFile $state.LogPath 0 262144
                        if ($head.Ok) {
                            $state.LogHeadRead = $true
                            $headText = (@($head.Text -split "`r?`n" | Select-Object -First 350)) -join "`n"
                            if ($headText -match '(?i)\[DFLog::NetworkClient\] Connection accepted from') {
                                $state.GameReady = $true; $state.EverGameReady = $true
                            }
                        }
                    } catch { }
                }
                if ($null -ne $state.LogPath) {
                    $logOffsetRef = [ref]$state.LogOffset
                    $newLogText = Read-RobloxLogTail $state.LogPath $logOffsetRef
                    $state.LogOffset = $logOffsetRef.Value
                    if ($newLogText) {
                        if ($newLogText -match '(?i)\[DFLog::NetworkClient\] Connection accepted from') { $state.GameReady = $true; $state.EverGameReady = $true }
                        $discResult = Get-RobloxLogDisconnectReason $newLogText
                        if ($null -ne $discResult -and $discResult.Disconnected) {
                            $state.isDisconnected = $true
                            $state.GameReady = $false
                            $state.DisconnectReason = $discResult.Reason; $state.DisconnectSource = 'log'
                            Write-Diagnostic 'CLIENT_LOG_DISCONNECT_DETECTED' @{ pid = $id; reason = $discResult.Reason; errorCode = $discResult.ErrorCode }
                        }
                    }
                }
                # A client in game proves its build works (dead-build guard).
                if ($state.EverGameReady -and -not $state.BuildSuccessSeen) { $state.BuildSuccessSeen = $true; Register-ArkuzoRobloxBuildSuccess ([string]$state.RobloxBuild) }
                # Log discovery/tailing may have been slow. Recollect window/memory
                # evidence and timestamp it after IO, never reuse the earlier probe.
                [Arkuzo.LoopWatchdogV1]::Mark('client ' + $id + ': health probe')
                $healthSample = Get-ArkuzoRecoveryHealthSample $client $(if ($state.isDisconnected) { 'IN_GAME_DISCONNECT' } else { '' }) $state
                $healthSample.systemCommitPercent = if ($null -ne $systemMemory) { $systemMemory.commitPercent } else { 0 }
                $healthSample.eligible = (-not $MonitorOnly -and $healthPolicy.enabled -and $voltStatus.safeToRecycle -and (Test-ArkuzoClientOwnership $state))
                $sampleTime = $clock.Elapsed.TotalSeconds
                $isResponding = $healthSample.responding; $launchError = $healthSample.launchError
                $window = $client.MainWindowHandle
                if (-not $isResponding -and $window -ne [IntPtr]::Zero) { $status = 'NOT RESPONDING' }
                $state.HealthDecision = Get-ArkuzoHealthDecision $state $healthSample $healthPolicy $sampleTime
                Update-ArkuzoHangCpu $state $cpuTime $sampleTime $cpuThreads
                if ($state.HealthDecision.Status) { $status = $state.HealthDecision.Status }
                # Bind the exact Volt account while it is still verifiable: a kicked client
                # often closes itself before its turn in the serialized recovery queue.
                if (-not $state.BoundAccountId -and $state.TrackerId -and ($state.isDisconnected -or $state.HealthDecision.Recycle -or [double]$state.HangSince -ge 0)) {
                    try {
                        $bound = Get-ArkuzoControlledAccount $state.TrackerId $id
                        if ($null -ne $bound) { $state.BoundAccountId = [string]$bound.accountId; $state.BoundTrackerId = [string]$bound.trackerId }
                    } catch { }
                }
                $clientAgeSec = ([DateTime]::UtcNow - $client.StartTime.ToUniversalTime()).TotalSeconds
                $nextTrimText = Get-ArkuzoTrimCountdown $clientAgeSec $healthPolicy.warmup_sec $trimPlan.IntervalSec $sampleTime $state.LastTrim ([bool]$EnableTrimming) ([bool]$MonitorOnly)
                $clientIssues = @($dashboardIssues.Keys | Where-Object { $_ -eq [string]$id -or $_ -like "$id-*" })
                if ($clientIssues.Count -gt 0 -and -not $state.HealthDecision.Status) { $status = 'CHECK NOTICE' }
                $accountName = Resolve-ArkuzoAccountName -ProcessId $id -TrackerId $state.TrackerId -LogPath $state.LogPath
                $state.LastSnapshot = [ordered]@{
                    pid = $id; startTicks = [long]$state.StartTicks; cpuPercent = [Math]::Round($cpu, 2); residentMB = [Math]::Round($client.WorkingSet64 / 1MB, 1)
                    privateMB = [Math]::Round($client.PrivateMemorySize64 / 1MB, 1)
                    responding = $isResponding; windowPresent = ($window -ne [IntPtr]::Zero); launchError = $launchError
                    state = $status; sampleTime = (Get-Date).ToString('o')
                    eligible = [bool]$healthSample.eligible; isDisconnected = [bool]$state.isDisconnected; parentId = [int]$state.ParentId
                    account = $accountName; slot = [int]$state.Slot; ageSec = [Math]::Round($clientAgeSec); nextTrim = $nextTrimText
                    gameReady = [bool]$state.GameReady; disconnectReason = $state.DisconnectReason
                    memoryPriority = $(if ($state.MemoryPriorityChanged) { $MemoryPriority } else { $null })
                }
                $state.HealthSnapshotUtc=[datetime]::UtcNow.ToString('o')
                if ($state.LastStatus -ne $status) {
                    Write-Diagnostic 'CLIENT_STATE_CHANGED' @{ previous = $state.LastStatus; sample = $state.LastSnapshot }
                    $state.LastStatus = $status
                }
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
        $lastTotals = @{ detected = $clients.Count; managed = $tracked.Count; cpuPercent = [Math]::Round($totalCpu, 2)
            residentMB = [Math]::Round($totalResident / 1MB, 1); privateMB = [Math]::Round($totalPrivate / 1MB, 1) }
        Step-ArkuzoLoopPhase 'outcomes'
        if ($clock.Elapsed.TotalSeconds -ge $nextOutcomeCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('recovery outcomes')
            Update-ArkuzoRecoveryOutcomes
            $nextOutcomeCheck = $clock.Elapsed.TotalSeconds + (Get-ArkuzoOutcomeCheckDelay)
        }
        Step-ArkuzoLoopPhase 'heartbeat'
        if ($clock.Elapsed.TotalSeconds -ge $nextRuntimeHeartbeat) {
            [Arkuzo.LoopWatchdogV1]::Mark('heartbeat')
            Write-ArkuzoRuntimeStatus
            # Two seconds keeps the Control Center live; the file is small.
            $nextRuntimeHeartbeat = $clock.Elapsed.TotalSeconds + 2
        }
        Step-ArkuzoLoopPhase 'remote'
        [Arkuzo.LoopWatchdogV1]::Mark('remote session')
        Update-ArkuzoRemoteSession
        Update-ArkuzoKeepAwake ((-not $MonitorOnly) -and [bool]$healthPolicy.keep_display_awake -and $tracked.Count -gt 0)
        Step-ArkuzoLoopPhase 'farmFreeze'
        [Arkuzo.LoopWatchdogV1]::Mark('farm freeze')
        Update-ArkuzoFarmFreeze
        Step-ArkuzoLoopPhase 'closures'
        Invoke-ArkuzoRecoveryCandidates
        Step-ArkuzoLoopPhase 'logging'
        if ($clock.Elapsed.TotalSeconds -ge $nextLogSample) {
            Write-Diagnostic 'RESOURCE_SAMPLE' @{
                detected = $clients.Count; managed = $tracked.Count; systemMemory = $systemMemory; voltRecoveryReady = [bool]$voltStatus.safeToRecycle
                cpuPercent = [Math]::Round($totalCpu, 2); residentMB = [Math]::Round($totalResident / 1MB, 1)
                privateMB = [Math]::Round($totalPrivate / 1MB, 1)
                clients = @($tracked.Values | ForEach-Object { $_.LastSnapshot } | Where-Object { $null -ne $_ })
                # Where the loop spends its time: ms per pass since the previous sample, sleep excluded.
                timings = (Get-ArkuzoLoopTimings)
            }
            $nextLogSample = $clock.Elapsed.TotalSeconds + $LogEverySec
        }
        Step-ArkuzoLoopPhase 'crashEvents'
        if ($clock.Elapsed.TotalSeconds -ge $nextEventCheck) {
            [Arkuzo.LoopWatchdogV1]::Mark('crash events and handlers')
            Read-CrashEvents
            try {
                # WerFault is Windows-wide crash reporting and is deliberately never enumerated or modified.
                if (-not $MonitorOnly -and $ownsControllerMutex -and -not $logFailed) {
                    $trustedHandlerRoots = @()
                    foreach ($base in @(
                        @{Path=$env:LOCALAPPDATA;Child='Roblox/Versions'},
                        @{Path=$env:ProgramData;Child='Roblox/Roblox'},
                        @{Path=$env:ProgramFiles;Child='Roblox/Versions'},
                        @{Path=${env:ProgramFiles(x86)};Child='Roblox/Versions'}
                    )) {
                        if (-not [string]::IsNullOrWhiteSpace($base.Path)) { $trustedHandlerRoots += Join-Path $base.Path $base.Child }
                    }
                    # Builds installed by the Roblox tab; their handler must still be signed by Roblox.
                    $managedHandlerRoot = try { Get-ArkuzoManagedVersionsRoot } catch { $null }
                    if ($managedHandlerRoot) { $trustedHandlerRoots += $managedHandlerRoot }
                    foreach ($listedHandler in @(Get-CimInstance Win32_Process -Filter "Name='RobloxCrashHandler.exe'" -Property ProcessId -OperationTimeoutSec 5 -ErrorAction Stop)) {
                        $ch = $null; $owner = $null; $handlerId = $null; $phase = 'OpenHandle'
                        try {
                            $handlerId = [int]$listedHandler.ProcessId
                            if ($handlerId -le 0) { throw 'Crash handler PID unavailable' }
                            $ch = Get-Process -Id $handlerId -ErrorAction Stop
                            if ($null -eq $ch) { throw 'Crash handler no longer available' }
                            $handle = $ch.Handle # Retain the exact process, never terminate by PID/name.
                            $ch.Refresh()
                            $handlerId = [int]$ch.Id
                            $expected = @{Id=$handlerId;StartTicks=$ch.StartTime.ToUniversalTime().Ticks;Path=$ch.Path;Handle=$handle;ParentId=$null}
                            $decision = $null
                            foreach ($verification in 1..2) {
                                if ($null -ne $owner) { $owner.Dispose(); $owner = $null }
                                $phase = 'IdentityAndParentVerification'
                                $records = @(Get-CimInstance Win32_Process -Filter ("ProcessId=" + $handlerId) -Property ProcessId,Name,ExecutablePath,ParentProcessId -OperationTimeoutSec 5 -ErrorAction Stop)
                                if ($records.Count -ne 1) { throw 'Crash handler metadata unavailable/ambiguous' }
                                $record = $records[0]
                                $signature = Get-AuthenticodeSignature -LiteralPath $expected.Path -ErrorAction Stop
                                $ch.Refresh()
                                $handler = @{
                                    Id=[int]$ch.Id;StartTicks=$ch.StartTime.ToUniversalTime().Ticks;Handle=$ch.Handle;HasExited=$ch.HasExited
                                    ProcessName=$ch.ProcessName;Path=$ch.Path;CimId=$record.ProcessId;CimName=$record.Name;CimPath=$record.ExecutablePath
                                    SignatureStatus=[string]$signature.Status;SignerSubject=$signature.SignerCertificate.Subject;SignaturePath=$signature.Path
                                    ParentId=[int]$record.ParentProcessId
                                }
                                if (-not (Test-ArkuzoCrashHandlerIdentity $handler $trustedHandlerRoots)) { throw 'Crash handler executable identity/path unverified' }
                                $parentId = $handler.ParentId
                                if ($parentId -le 0 -or $parentId -eq $handlerId) { throw 'Crash handler parent identity unavailable' }
                                # Only a successful, empty CIM query proves absence. Access errors are unknown.
                                $parents = @(Get-CimInstance Win32_Process -Filter ("ProcessId=" + $parentId) -Property ProcessId,CreationDate -OperationTimeoutSec 5 -ErrorAction Stop)
                                $parent = @{QuerySucceeded=$true;Count=$parents.Count;Id=$parentId}
                                if ($parents.Count -eq 0) {
                                    # A missing WMI row alone cannot hide a live/inaccessible parent.
                                    $parent.AbsenceConfirmed = $false
                                    try {
                                        $owner = Get-Process -Id $parentId -ErrorAction Stop
                                        if (-not $owner.HasExited) {
                                            throw 'Parent absence contradicted/unconfirmed by process lookup'
                                        }
                                        $parent.AbsenceConfirmed = $true
                                    } catch {
                                        if ($_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId*') { throw }
                                        $parent.AbsenceConfirmed = $true
                                    }
                                }
                                if ($parents.Count -eq 1) {
                                    if ($parents[0].CreationDate -isnot [datetime]) { throw 'Crash handler parent creation time unavailable' }
                                    $owner = Get-Process -Id $parentId -ErrorAction Stop
                                    if ($null -eq $owner) { throw 'Crash handler parent could not be inspected' }
                                    $parent.Handle = $owner.Handle
                                    $owner.Refresh()
                                    $parent.Id = [int]$owner.Id; $parent.HasExited = $owner.HasExited
                                    $parent.StartTicks = $owner.StartTime.ToUniversalTime().Ticks
                                    $parent.CimId = $parents[0].ProcessId; $parent.CimStartTicks = $parents[0].CreationDate.ToUniversalTime().Ticks
                                }
                                $ch.Refresh()
                                $handler.Id = [int]$ch.Id; $handler.StartTicks = $ch.StartTime.ToUniversalTime().Ticks; $handler.HasExited = $ch.HasExited
                                $decision = Get-ArkuzoOrphanHandlerDecision $handler $parent ([datetime]::UtcNow) ([bool]$MonitorOnly) $ownsControllerMutex $trustedHandlerRoots $expected
                                if (-not $decision.Close) {
                                    if ($decision.Reason -in @('IdentityUnverified','ParentUnverified','ObservationInvalid')) { throw ('Crash handler cleanup refused: ' + $decision.Reason) }
                                    break
                                }
                                $expected.ParentId = $handler.ParentId
                                if ($verification -eq 1) {
                                    Write-Diagnostic 'ORPHAN_CRASH_HANDLER_CLOSE_REQUESTED' @{pid=$handlerId;startTicks=$expected.StartTicks;parentId=$parentId;reason=$decision.Reason}
                                    if ($logFailed) { throw 'Crash handler cleanup requires functioning audit logging' }
                                }
                            }
                            if ($null -eq $decision -or -not $decision.Close) { continue }
                            $phase = 'FinalIdentityVerification'
                            if ($null -ne $owner) {
                                $owner.Refresh()
                                $parent.Id = [int]$owner.Id; $parent.StartTicks = $owner.StartTime.ToUniversalTime().Ticks; $parent.HasExited = $owner.HasExited
                            }
                            $ch.Refresh()
                            $handler.Id = [int]$ch.Id; $handler.StartTicks = $ch.StartTime.ToUniversalTime().Ticks
                            $handler.Handle = $ch.Handle; $handler.HasExited = $ch.HasExited; $handler.ProcessName = $ch.ProcessName; $handler.Path = $ch.Path
                            # No logging/CIM IO between this generation/authority recheck and closure.
                            $decision = Get-ArkuzoOrphanHandlerDecision $handler $parent ([datetime]::UtcNow) ([bool]$MonitorOnly) $ownsControllerMutex $trustedHandlerRoots $expected
                            if (-not $decision.Close) { throw ('Crash handler cleanup refused: ' + $decision.Reason) }
                            if ($logFailed) { throw 'Crash handler cleanup requires functioning audit logging' }
                            $phase = 'CloseAndReadback'
                            $ch.Kill()
                            $waitConfirmed = $ch.WaitForExit(2000)
                            $ch.Refresh()
                            $readback = @{Id=[int]$ch.Id;StartTicks=$ch.StartTime.ToUniversalTime().Ticks;Handle=$ch.Handle;HasExited=$ch.HasExited;WaitConfirmed=$waitConfirmed}
                            if (-not (Test-ArkuzoOrphanHandlerExit $expected $readback)) { throw 'Crash handler exit not verified for the retained generation' }
                            Write-Diagnostic 'ORPHAN_CRASH_HANDLER_CLOSED' @{pid=$handlerId;startTicks=$expected.StartTicks;parentId=$expected.ParentId;reason=$decision.Reason;exitVerified=$true}
                        } catch {
                            Write-Diagnostic 'ORPHAN_CRASH_HANDLER_ERROR' @{pid=$handlerId;phase=$phase;message=$_.Exception.Message}
                            Warn-Throttled ('orphan-handler-' + $handlerId) ('Orphan crash-handler cleanup refused/failed for PID ' + $handlerId + ': ' + $_.Exception.Message)
                        } finally {
                            foreach ($resource in @($owner, $ch)) {
                                if ($null -eq $resource) { continue }
                                try { $resource.Dispose() } catch {
                                    Write-Diagnostic 'ORPHAN_CRASH_HANDLER_ERROR' @{pid=$handlerId;phase='HandleDispose';message=$_.Exception.Message}
                                }
                            }
                        }
                    }
                }
            } catch {
                Write-Diagnostic 'ORPHAN_CRASH_HANDLER_ERROR' @{phase='Enumeration';message=$_.Exception.Message}
                Warn-Throttled 'orphan-handler-enumeration' ('Orphan crash-handler query failed: ' + $_.Exception.Message)
            }
            $nextEventCheck = $clock.Elapsed.TotalSeconds + 15
        }
        if (($clock.Elapsed.TotalSeconds - $lastHistorySample) -ge 1) {
            $cpuHistory.Enqueue($totalCpu)
            while ($cpuHistory.Count -gt 60) { $cpuHistory.Dequeue() | Out-Null }
            $lastHistorySample = $clock.Elapsed.TotalSeconds
        }
        Step-ArkuzoLoopPhase 'dashboard'
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
        Complete-ArkuzoLoopPass
        [Arkuzo.LoopWatchdogV1]::Mark('idle')
        Start-Sleep -Milliseconds $PollMs
    }
} catch {
    Write-ArkuzoFailureDiagnostic 'SAVER_FATAL_ERROR' $_
    throw
} finally {
    try {
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
        Stop-ArkuzoNativeTicketJobs
    } catch {
        Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_
    } finally {
        try { if ($script:keepAwakeOn) { [void][Arkuzo.RemoteSessionNativeV1]::KeepAwake($false) } } catch { }
        # Cleanup/console failures must not mask the fatal error or skip lock and
        # diagnostic finalization. These independent best-effort steps never throw.
        try { Write-Diagnostic 'SESSION_STOP' @{ uptimeSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); trims = $trimCount } } catch { Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_ }
        try { if ($ownsControllerMutex -and $null -ne $controllerMutex) { $controllerMutex.ReleaseMutex() } } catch { Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_ }
        try { if ($null -ne $controllerMutex) { $controllerMutex.Dispose() } } catch { Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $_ }
        if ($null -ne $logWriter) { try { $logWriter.Dispose() } catch { } }
        try { if (-not $logFailed) { Write-Host "Diagnostics saved: $logPath" -ForegroundColor Cyan } } catch { }
        $clock.Stop()
    }
}
