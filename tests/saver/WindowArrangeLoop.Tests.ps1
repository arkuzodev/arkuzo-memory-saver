#requires -Version 5.1
# The engine's window arrangement pass (Update-ArkuzoWindowArrangement) against a fake
# Win32 layer: with more clients than fit, the default tiles as many as fit without
# overlap and minimizes the rest; the window that has the focus is never minimized;
# an overflow window the user restores stays up until the layout changes or Arrange now.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
$wanted = @('Get-ArkuzoVaultSetting', 'Get-ArkuzoArrangeSettings', 'Get-ArkuzoRobloxMinWindow', 'Get-ArkuzoWindowSlots', 'Test-ArkuzoSlotMinimized',
    'Test-ArkuzoSlotsOverlap', 'Get-ArkuzoArrangeTargets', 'Test-ArkuzoWindowInPlace', 'Update-ArkuzoWindowArrangement', 'Initialize-ArkuzoWindowNative', 'Test-ArkuzoNativeProvider')
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($wanted -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
function Warn-Throttled($Key, $Message) { throw $Message }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }

# The production type is only compiled when it does not exist yet, so this fake takes its place.
Add-Type -TypeDefinition @'
using System.Collections.Generic;
namespace Arkuzo {
 public static class WindowArrangeV3 {
  public static List<string> Calls = new List<string>();
  public static Dictionary<long, int[]> Rects = new Dictionary<long, int[]>();
  public static Dictionary<int, long> Windows = new Dictionary<int, long>();
  public static long Fg = 0;
  public static int[][] Monitors() { return new[] { new[] { 0, 0, 1920, 1032, 96, 1 } }; }
  public static Dictionary<int, long> ClientWindows(int[] pids) { var d = new Dictionary<int, long>(); foreach (var p in pids) if (Windows.ContainsKey(p)) d[p] = Windows[p]; return d; }
  public static int[] Rect(long h) { return Rects.ContainsKey(h) ? Rects[h] : null; }
  public static long Foreground() { return Fg; }
  public static bool Place(long h, int x, int y, int w, int ht, string visibility) {
   Calls.Add("place " + h + " " + x + "," + y + "," + w + "," + ht + " " + visibility);
   Rects[h] = visibility == "minimized" ? new[] { x, y, w, ht, 1, 0 } : new[] { x, y, w, ht, 0, 0 };
   return true;
  }
  public static void Stack(long[] ordered, bool background) { Calls.Add("stack " + ordered.Length); }
 }
}
'@

$MonitorOnly = $false; $ownsControllerMutex = $true; $Minimize = $false
$script:accountProvider = 'arkuzo'
$script:arrangeMinWindow = @{}; $script:arrangeHandledRequestMs = 0; $script:arrangeLastSignature = ''
$names = @('Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo')
$accounts = @(); $tracked = @{}
for ($i = 0; $i -lt $names.Count; $i++) {
    $accounts += [pscustomobject]@{ accountId = "id-$i"; displayName = $names[$i]; trackerId = [string](100 + $i); autoRelaunch = $true; cookieAlive = $true }
    $tracked[1000 + $i] = @{ Watcher = [pscustomobject]@{ Id = 1000 + $i }; TrackerId = [string](100 + $i); StartTicks = [long](5000 + $i) }
    [Arkuzo.WindowArrangeV3]::Windows[1000 + $i] = [long](9000 + $i)
    [Arkuzo.WindowArrangeV3]::Rects[[long](9000 + $i)] = [int[]]@(0, 0, 1920, 1032, 0, 1)
}
$voltControlStatus = [pscustomobject]@{ available = $true; accounts = $accounts }
$settings = [pscustomobject]@{ arrangeWindows = $true }
$script:nativeVault = [pscustomobject]@{ settings = $settings }
$calls = { @([Arkuzo.WindowArrangeV3]::Calls) }
$reset = { [Arkuzo.WindowArrangeV3]::Calls.Clear() }

# Charlie (the third tile, an overflow one) has the focus: it must not be minimized yet.
[Arkuzo.WindowArrangeV3]::Fg = 9002
Update-ArkuzoWindowArrangement
$c = @(& $calls)
Assert ($c -contains 'place 9000 0,0,958,744 normal' -and $c -contains 'place 9001 962,0,958,744 normal') 'auto: the two windows that fit are tiled side by side, as large as fits'
Assert ($c -contains 'place 9003 962,0,958,744 minimized' -and $c -contains 'place 9004 0,0,958,744 minimized') 'auto: the rest are minimized onto a tile'
Assert (-not (@($c) -match '^place 9002 ')) 'the focused window is never minimized'
Assert (-not (@($c) -match '^stack')) 'tiles do not overlap, so the stacking order is left alone'

# The focus moves on: Charlie is minimized now; the others are settled and not touched again.
& $reset; [Arkuzo.WindowArrangeV3]::Fg = 0
Update-ArkuzoWindowArrangement
$c = @(& $calls)
Assert ($c.Count -eq 1 -and $c[0] -eq 'place 9002 0,0,958,744 minimized') 'the focused overflow window is minimized once the focus has moved'

# The user restores Delta to look at it: it stays up.
& $reset; [Arkuzo.WindowArrangeV3]::Rects[[long]9003] = [int[]]@(962, 0, 958, 744, 0, 0)
Update-ArkuzoWindowArrangement
Assert ((& $calls).Count -eq 0) 'an overflow window the user restored is left alone'
# A tiled window moved away snaps back (Keep in place).
[Arkuzo.WindowArrangeV3]::Rects[[long]9001] = [int[]]@(300, 300, 958, 744, 0, 0)
Update-ArkuzoWindowArrangement
Assert (@(& $calls) -contains 'place 9001 962,0,958,744 normal' -and @(& $calls).Count -eq 1) 'a tiled window that was moved is put back'

# Arrange now re-minimizes the restored one.
& $reset; $settings | Add-Member -NotePropertyName arrangeRequestedAtMs -NotePropertyValue 1794149549000 -Force
Update-ArkuzoWindowArrangement
Assert (@(& $calls) -contains 'place 9003 962,0,958,744 minimized') 'Arrange now minimizes the overflow windows again'

# Overlap: every window on screen, overlapping evenly, stacked so each keeps its corner.
& $reset; $settings | Add-Member -NotePropertyName arrangeOverflow -NotePropertyValue 'overlap' -Force
Update-ArkuzoWindowArrangement
$c = @(& $calls)
Assert (@($c -match ' minimized$').Count -eq 0 -and @($c -match '^place ').Count -eq 5 -and $c -contains 'stack 5') 'overlap: all five on screen, stacked'

Write-Output "PASS: $script:checks window arrangement pass checks (tiles without overlap, minimizes the rest, never the focused window)"
