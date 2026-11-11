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
