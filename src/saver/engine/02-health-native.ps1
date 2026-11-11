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
