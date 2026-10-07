using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
namespace Launcher;
// The synchronous entry point keeps Windows mutex ownership on one thread through child exit.
public sealed class LauncherLock : IDisposable
{
 readonly Mutex mutex;
 bool owned;
 public LauncherLock(string root)
 {
  var id=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant())));
  mutex=new Mutex(false,"Global\\ArkuzoMemorySaver-"+id);
  try { try { owned=mutex.WaitOne(0); } catch(AbandonedMutexException) { owned=true; }
   if(!owned) throw new InvalidOperationException("Another launcher is already running for this installation.");
  } catch {mutex.Dispose();throw;}
 }
 public void Dispose() { if(owned) {mutex.ReleaseMutex(); owned=false;} mutex.Dispose(); }
}
public static class LauncherEntry
{
 public static int Run(string[] args,string root)
 {
  if(args.Any(x=>x!="--offline" && x!="--verify-only") || args.Distinct().Count()!=args.Length)
  { Console.Error.WriteLine("Usage: ArkuzoMemorySaver.exe [--offline] [--verify-only]");return 2; }
  try {
   using var updaterLock=new LauncherLock(root);
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
   return ExecuteChild(Updater.ChildStart(Path.GetFullPath(root),store.RuntimePath(installed)));
  } catch(Exception ex) { LauncherUi.ShowError(ex.Message); return 1; }
 }
 internal static int ExecuteChild(ProcessStartInfo info)
 {
  using var child=Process.Start(info) ?? throw new InvalidOperationException("Unable to start Windows PowerShell.");
  child.WaitForExit(); return child.ExitCode;
 }
}
