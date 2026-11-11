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

