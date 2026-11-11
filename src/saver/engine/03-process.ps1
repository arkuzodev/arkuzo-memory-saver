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
