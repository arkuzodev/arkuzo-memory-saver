#requires -Version 5.1
# Roblox log reads are bounded: a log that cannot be opened (on 8 Nov a client
# frozen by a remote-desktop disconnect blocked every open of its log, and the
# saver hung on it at each start) is skipped instead of hanging the main loop.
# The blocking open is reproduced for real: a child process holds an oplock on
# the file and never acknowledges the break, so any other open waits.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
$script:warned = New-Object Collections.ArrayList
function Warn-Throttled($key, $message) { [void]$script:warned.Add($key) }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bounded-log-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$holder = $null
try {
    # ---- Same behaviour as before for readable logs ------------------------------------------
    $log = Join-Path $scratch 'tail.log'
    [IO.File]::WriteAllText($log, 'a' * 70000 + "`nlast line")
    $offset = [ref]([int64]0)
    $text = Read-RobloxLogTail $log $offset
    Assert ($text.Length -eq 65536 -and $text.EndsWith('last line') -and $offset.Value -eq 70010) 'first read: the last 64 KB, offset at the end'
    Assert ($null -eq (Read-RobloxLogTail $log $offset)) 'nothing new, nothing returned'
    [IO.File]::AppendAllText($log, "`n[FLog::Network] Connection lost")
    $text = Read-RobloxLogTail $log $offset
    Assert ($text -ceq "`n[FLog::Network] Connection lost" -and $offset.Value -eq (Get-Item $log).Length) 'appended text only'
    [IO.File]::AppendAllText($log, ('b' * 100000) + 'END')
    $text = Read-RobloxLogTail $log $offset
    Assert ($text.Length -eq 65536 -and $text.EndsWith('END') -and $offset.Value -eq (Get-Item $log).Length) 'a gap over 64 KB keeps only its last 64 KB'
    [IO.File]::WriteAllText($log, 'restarted')
    Assert ($null -eq (Read-RobloxLogTail $log $offset) -and $offset.Value -eq 0) 'a truncated log starts over'
    Assert ((Read-RobloxLogTail $log $offset) -ceq 'restarted') 'and is read from the start'
    Assert ($null -eq (Read-RobloxLogTail (Join-Path $scratch 'missing.log') ([ref]([int64]0)))) 'a missing log returns nothing'
    $head = Join-Path $scratch 'head.log'
    [IO.File]::WriteAllText($head, ((1..500 | ForEach-Object { "line $_" }) -join "`r`n"))
    $lines = @(Read-ArkuzoLogHeadLines $head 350)
    Assert ($lines.Count -eq 350 -and $lines[0] -ceq 'line 1' -and $lines[349] -ceq 'line 350') 'head lines like Get-Content -TotalCount'

    # ---- A log whose open blocks ---------------------------------------------------------------
    $blocked = Join-Path $scratch '0.1_20261108T152449Z_Player_57F12_last.log'
    [IO.File]::WriteAllText($blocked, 'websiteBTId is 123456789')
    $ready = Join-Path $scratch 'oplock.ready'
    $holderScript = Join-Path $scratch 'hold-oplock.ps1'
    [IO.File]::WriteAllText($holderScript, @'
param([string]$Path, [string]$Ready)
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class OplockHolder {
 [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
 [DllImport("kernel32.dll", SetLastError = true)] static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] input, int inputSize, IntPtr output, int outputSize, IntPtr returned, IntPtr overlapped);
 static SafeFileHandle handle; static IntPtr overlapped, output;
 // Read-handle-write oplock that is never acknowledged: any other open waits for its break.
 public static int Hold(string path) {
  handle = CreateFileW(path, 0x80000000, 7, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero); // GENERIC_READ, share all, OPEN_EXISTING, FILE_FLAG_OVERLAPPED
  if (handle.IsInvalid) return Marshal.GetLastWin32Error();
  byte[] input = new byte[12]; BitConverter.GetBytes((ushort)1).CopyTo(input, 0); BitConverter.GetBytes((ushort)12).CopyTo(input, 2);
  BitConverter.GetBytes(7u).CopyTo(input, 4); BitConverter.GetBytes(1u).CopyTo(input, 8); // READ|HANDLE|WRITE, REQUEST
  overlapped = Marshal.AllocHGlobal(64); for (int i = 0; i < 64; i++) Marshal.WriteByte(overlapped, i, 0);
  output = Marshal.AllocHGlobal(64);
  bool done = DeviceIoControl(handle, 0x00090240, input, 12, output, 24, IntPtr.Zero, overlapped); // FSCTL_REQUEST_OPLOCK
  return done ? -1 : Marshal.GetLastWin32Error(); // 997 = granted and pending
 }
}
"@
$code = [OplockHolder]::Hold($Path)
[IO.File]::WriteAllText($Ready, [string]$code)
Start-Sleep -Seconds 600
'@)
    $holder = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$holderScript`"", "`"$blocked`"", "`"$ready`"") -PassThru -WindowStyle Hidden
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $ready) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
    $code = $(if (Test-Path $ready) { (Get-Content $ready -Raw).Trim() } else { 'none' })
    if ($code -ne '997') {
        Write-Host "SKIP: this file system did not grant the test oplock (result $code); blocking-open checks not run"
    } else {
        $sw.Restart(); $offset = [ref]([int64]0)
        $text = Read-RobloxLogTail $blocked $offset
        $first = $sw.Elapsed.TotalSeconds
        Assert ($null -eq $text -and $offset.Value -eq 0) 'a log that cannot be opened returns nothing and keeps its offset'
        Assert ($first -ge 1.5 -and $first -lt 6) ("the read gives up after about 2 s ($([math]::Round($first,1)) s)")
        Assert ($warned -contains 'roblox-log-blocked') 'and says so'
        Assert ([Arkuzo.BoundedReadV1]::Stuck() -eq 1) 'one worker waits on the file'
        $sw.Restart()
        Assert ($null -eq (Read-RobloxLogTail $blocked $offset) -and $sw.ElapsedMilliseconds -lt 500) 'while it waits, the file is skipped at once'
        $sw.Restart()
        $found = Find-RobloxProcessLog -TargetProcessId 77 -TrackerId '123456789' -StartTimeUtc ([datetime]'2026-11-08T15:24:49Z') -LogsDir $scratch
        Assert ($null -eq $found -and $sw.Elapsed.TotalSeconds -lt 3) 'finding the log of that client does not hang either'
        Assert ([Arkuzo.BoundedReadV1]::Stuck() -eq 1) 'and starts no second worker on the same file'
        # The holder goes away (the frozen client exits): the file is read again.
        Stop-Process -Id $holder.Id -Force; $holder = $null
        $sw.Restart(); $text = $null
        while ($sw.Elapsed.TotalSeconds -lt 15 -and $null -eq $text) { $text = Read-RobloxLogTail $blocked $offset; if ($null -eq $text) { Start-Sleep -Milliseconds 200 } }
        Assert ($text -ceq 'websiteBTId is 123456789' -and [Arkuzo.BoundedReadV1]::Stuck() -eq 0) 'once the holder is gone the log reads normally again'
        Assert ((Find-RobloxProcessLog -TargetProcessId 77 -TrackerId '123456789' -StartTimeUtc ([datetime]'2026-11-08T15:24:49Z') -LogsDir $scratch) -eq $blocked) 'and binds to its client again'
    }
} finally {
    if ($null -ne $holder) { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue; [void]$holder.WaitForExit(5000) }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS: bounded Roblox log reads: same results for readable logs, a blocked open is skipped after 2 s and read again once it opens ($checks checks)"
