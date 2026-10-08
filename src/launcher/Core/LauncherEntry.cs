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
    if (!owned) throw new AlreadyRunningException("Another launcher is already running for this installation.");
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
 public static int Run(string[] args,string root) => Run(args,root,ControllerMutexName);
 internal static int Run(string[] args,string root,string controllerMutexName,Action? acknowledgement=null)
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
   if (!args.Contains("--verify-only") && ControllerIsRunning(controllerMutexName))
   {
       var rootFull = Path.GetFullPath(root);
       var dataDir = Directory.Exists(Path.Combine(rootFull, "data")) ? Path.Combine(rootFull, "data") : rootFull;
       var statusPath = File.Exists(Path.Combine(dataDir, "runtime-status.json"))
           ? Path.Combine(dataDir, "runtime-status.json")
           : Path.Combine(rootFull, "runtime-status.json");
       var targetDir = File.Exists(statusPath) ? Path.GetDirectoryName(statusPath)! : dataDir;
       var stopFile = Path.Combine(targetDir, "controller.stop");

       int? activePid = null;
       Process? activeProc = null;
       if (File.Exists(statusPath))
       {
           try
           {
               using var doc = JsonDocument.Parse(File.ReadAllBytes(statusPath));
               if (doc.RootElement.TryGetProperty("pid", out var pidProp) && pidProp.TryGetInt32(out var p))
               {
                   try
                   {
                       var proc = Process.GetProcessById(p);
                       if (!proc.HasExited)
                       {
                           var pName = proc.ProcessName.ToLowerInvariant();
                           if (pName.Contains("powershell") || pName.Contains("pwsh") || pName.Contains("cmd"))
                           {
                               activePid = p;
                               activeProc = proc;
                           }
                       }
                   }
                   catch { }
               }
           }
           catch { }
       }

       if (activePid.HasValue && activeProc != null)
       {
           Directory.CreateDirectory(targetDir);
           File.WriteAllText(stopFile, "Graceful stop signaled by launcher.");
           if (!Console.IsOutputRedirected)
           {
               LauncherUi.Step("STOP", $"Signaling existing controller (PID {activePid.Value}) to stop gracefully...", ConsoleColor.Yellow);
           }
           var gracefulDeadline = DateTime.UtcNow.AddSeconds(5);
           while (DateTime.UtcNow < gracefulDeadline)
           {
               var exited = false;
               try { exited = activeProc.HasExited; } catch { exited = true; }
               if (exited && !ControllerIsRunning(controllerMutexName))
                   break;
               Thread.Sleep(250);
           }

           try
           {
               if (!activeProc.HasExited)
               {
                   if (!Console.IsOutputRedirected)
                   {
                       LauncherUi.Step("KILL", $"Controller (PID {activePid.Value}) did not exit gracefully, terminating controller process...", ConsoleColor.Yellow);
                   }
                   activeProc.Kill();
                   activeProc.WaitForExit(3000);
               }
           }
           catch { }
       }

       // Autoclose any lingering saver processes
       if (ControllerIsRunning(controllerMutexName))
       {
           AutocloseRunningSaverProcesses();
       }

       var mutexDeadline = DateTime.UtcNow.AddSeconds(5);
       while (DateTime.UtcNow < mutexDeadline && ControllerIsRunning(controllerMutexName))
       {
           Thread.Sleep(250);
       }

       if (File.Exists(stopFile))
       {
           try { File.Delete(stopFile); } catch { }
       }

       if (ControllerIsRunning(controllerMutexName))
       {
           throw new AlreadyRunningException("Existing Memory Saver controller mutex was not released in time.");
       }

       if (!Console.IsOutputRedirected)
       {
           LauncherUi.Step("REPLACE", "Previous controller shut down cleanly. Proceeding with startup.", ConsoleColor.Green);
       }
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
 internal static void AutocloseRunningSaverProcesses()
 {
  try
  {
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
       "-NoProfile -Command \"Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell|pwsh' -and $_.CommandLine -like '*Arkuzo-Memory-Saver*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }\"")
   {
       CreateNoWindow = true,
       UseShellExecute = false
   });
   cimKill?.WaitForExit(4000);
  }
  catch { }
 }
}
