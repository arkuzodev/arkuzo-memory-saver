using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace Launcher;
internal sealed class AlreadyRunningException(string message) : InvalidOperationException(message);
// The synchronous entry point keeps Windows mutex ownership on one thread through child exit.
public sealed class LauncherLock : IDisposable
{
 readonly Mutex mutex;
 bool owned;
 public LauncherLock(string root, bool verifyOnly = false)
 {
  var id=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant())));
  mutex=new Mutex(false,"Global\\ArkuzoMemorySaver-"+id);
  try {
   try { owned=mutex.WaitOne(0); } catch(AbandonedMutexException) { owned=true; }
   if(!owned) {
    if (verifyOnly) throw new AlreadyRunningException("Another launcher is already running for this installation.");
    AutocloseRunningLauncherProcesses();
    try { owned=mutex.WaitOne(3000); } catch(AbandonedMutexException) { owned=true; }
    if(!owned) throw new AlreadyRunningException("Another launcher is already running for this installation.");
   }
  } catch {mutex.Dispose();throw;}
 }
 private static void AutocloseRunningLauncherProcesses()
 {
  try
  {
   var currentPid = Environment.ProcessId;
   foreach (var proc in Process.GetProcessesByName("ArkuzoMemorySaver"))
   {
    if (proc.Id != currentPid)
    {
     try { proc.Kill(); proc.WaitForExit(3000); } catch { }
    }
   }
  }
  catch { }
 }
 public void Dispose() { if(owned) {mutex.ReleaseMutex(); owned=false;} mutex.Dispose(); }
}
public static class LauncherEntry
{
 internal const string ControllerMutexName = "Local\\ArkuzoSaver-ProcessController";
 public static int Run(string[] args,string root) => Run(args,root,ControllerMutexName,null,new WindowsControllerIo());
 internal static int Run(string[] args,string root,string controllerMutexName,Action? acknowledgement,IControllerIo io)
 {
  LauncherUi.DisableQuickEdit();
  void DismissNotice() {
   if(args.Contains("--verify-only")) return;
   if(acknowledgement is null) LauncherUi.WaitForDismissal(false); else acknowledgement();
  }
  if(args.Any(x=>x!="--offline" && x!="--verify-only") || args.Distinct().Count()!=args.Length)
  { Console.Error.WriteLine("Usage: ArkuzoMemorySaver.exe [--offline] [--verify-only]");return 2; }
  try {
   using var updaterLock=new LauncherLock(root, args.Contains("--verify-only"));
   if (!args.Contains("--verify-only") && io.IsRunning(controllerMutexName))
   {
       bool replaced = false;
       try { replaced = ControllerTakeover.Replace(root, controllerMutexName, io); } catch { }
       if (!replaced && io is WindowsControllerIo)
       {
           AutocloseRunningSaverProcesses(root, controllerMutexName);
       }
       if (io.IsRunning(controllerMutexName))
           throw new AlreadyRunningException("Existing controller ownership could not be verified or its mutex was not released.");
   }
   if (!Console.IsOutputRedirected && !args.Contains("--verify-only"))
   {
       LauncherUi.ShowBanner();
       LauncherUi.Step("INIT", "Securing single-instance environment lock...");
   }
   var store=new Installation(Path.GetFullPath(root));
   if (Console.IsOutputRedirected || args.Contains("--verify-only"))
   {
       Console.WriteLine("Arkuzo Memory Saver launcher (unsigned executable).");
   }
   if (!Console.IsOutputRedirected && !args.Contains("--verify-only"))
   {
       LauncherUi.Step("GATE", args.Contains("--offline") ? "Validating local runtime cache (offline)..." : "Connecting to GitHub release gateway...");
   }
   var installed=Updater.PrepareAsync(store,args.Contains("--offline")).GetAwaiter().GetResult();
   store.InitializeData();
   if (Console.IsOutputRedirected || args.Contains("--verify-only"))
   {
       Console.WriteLine("Verified runtime "+installed.Version+" (SHA-256 "+installed.ZipSha256+").");
   }
   if(args.Contains("--verify-only")) return 0;
   if (!Console.IsOutputRedirected)
   {
       LauncherUi.Step("DIGEST", $"Runtime integrity verified: {installed.Version} (SHA-256 {installed.ZipSha256[..12]}...)", ConsoleColor.Green);
       LauncherUi.Step("LOCK", "Storage isolation: data/config.json locked", ConsoleColor.Green);
       LauncherUi.ProgressAnimation("PREPARING GUARDIAN CORE");
       LauncherUi.Step("BOOT", "Launching autonomous memory guardian...\n", ConsoleColor.Cyan);
       Thread.Sleep(60);
   }
   store.Validate();
   Installation.SafePath(Path.Combine(root,"data","config.json"));
   var exitCode=ExecuteChild(Updater.ChildStart(Path.GetFullPath(root),store.RuntimePath(installed)));
   if(exitCode!=0) {
    LauncherUi.ShowError("Memory Saver exited with code "+exitCode+". See the details above.");
    DismissNotice();
   }
   return exitCode;
  } catch(AlreadyRunningException ex) {
   LauncherUi.ShowAlreadyRunning(ex.Message);
   DismissNotice();
   return args.Contains("--verify-only") ? 1 : 0;
  } catch(Exception ex) {
   LauncherUi.ShowError(ex.Message);
   DismissNotice();
   return 1;
  }
 }
 internal static bool ControllerIsRunning(string mutexName)
 {
  if (!Mutex.TryOpenExisting(mutexName,out var controller)) return false;
  using(controller) {
   var acquired=false;
   try {
    try { acquired=controller.WaitOne(0); }
    catch(AbandonedMutexException) { acquired=true; }
    return !acquired;
   } finally { if(acquired) controller.ReleaseMutex(); }
  }
 }
 internal static int ExecuteChild(ProcessStartInfo info)
 {
  using var child=Process.Start(info) ?? throw new InvalidOperationException("Unable to start Windows PowerShell.");
  child.WaitForExit(); return child.ExitCode;
 }
 internal static void AutocloseRunningSaverProcesses(string root, string controllerMutexName)
 {
  try
  {
   foreach (var statusPath in new[] { Path.Combine(root, "data", "runtime-status.json"), Path.Combine(root, "runtime-status.json") })
   {
    if (File.Exists(statusPath))
    {
     try
     {
      using var doc = JsonDocument.Parse(File.ReadAllText(statusPath));
      if (doc.RootElement.TryGetProperty("pid", out var pidProp))
      {
       var p = Process.GetProcessById(pidProp.GetInt32());
       if (p.ProcessName.Contains("powershell", StringComparison.OrdinalIgnoreCase) ||
           p.ProcessName.Contains("pwsh", StringComparison.OrdinalIgnoreCase))
       {
        p.Kill();
        p.WaitForExit(2000);
       }
      }
     }
     catch { }
    }
   }
   foreach (var name in new[] { "powershell", "pwsh" })
   {
    foreach (var proc in Process.GetProcessesByName(name))
    {
     try
     {
      if (!string.IsNullOrEmpty(proc.MainWindowTitle) &&
          (proc.MainWindowTitle.Contains("ARKUZO", StringComparison.OrdinalIgnoreCase) ||
           proc.MainWindowTitle.Contains("Memory Saver", StringComparison.OrdinalIgnoreCase)))
      {
       proc.Kill();
       proc.WaitForExit(2000);
      }
     }
     catch { }
    }
   }
   using var cimKill = Process.Start(new ProcessStartInfo("powershell.exe",
       "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"Get-CimInstance Win32_Process | Where-Object { ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe') -and $_.CommandLine -like '*Arkuzo-Memory-Saver*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }\"")
   {
       CreateNoWindow = true,
       UseShellExecute = false
   });
   cimKill?.WaitForExit(4000);
   for (int i = 0; i < 30; i++)
   {
       if (!ControllerIsRunning(controllerMutexName)) break;
       Thread.Sleep(100);
   }
  }
  catch { }
 }
}
