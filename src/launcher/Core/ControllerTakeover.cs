using System.Diagnostics;
using System.Text;
using System.Text.Json;
namespace Launcher;

internal sealed record ControllerIdentity(int Pid, long StartTicks, string Image, string CommandLine);
internal interface IControllerProcess : IDisposable
{
 ControllerIdentity ReadIdentity();
 bool HasExited { get; }
 bool WaitForExit(int milliseconds);
 void Kill();
}
internal interface IControllerIo
{
 bool IsRunning(string mutexName);
 string ReadHeartbeat(string path);
 DateTime UtcNow { get; }
 IControllerProcess Open(int pid);
 void Signal(string path, string token);
 void RemoveSignal(string path, string token);
}
internal static class ControllerTakeover
{
 internal static bool Replace(string root, string mutexName, IControllerIo io)
 {
  // Heartbeat is a hint, never process authority. No fallback discovery is permitted.
  string? signal=null; string token=Guid.NewGuid().ToString("N"); bool signaled=false;
  try {
   root=Path.GetFullPath(root);
   var store=new Installation(root);var installed=store.Validate();
   var script=Path.Combine(store.RuntimePath(installed),"Arkuzo-Memory-Saver.ps1");
   var data=Path.Combine(root,"data");var status=Path.Combine(data,"runtime-status.json");
   signal=Path.Combine(data,"controller.stop");
   Installation.SafePath(status);Installation.SafePath(signal);
   using var doc=JsonDocument.Parse(io.ReadHeartbeat(status));var row=doc.RootElement;
   var pid=row.GetProperty("pid").GetInt32();var ticks=row.GetProperty("startTicks").GetInt64();
   var updated=row.GetProperty("updatedUtc").GetDateTime().ToUniversalTime();
   var age=(io.UtcNow-updated).TotalSeconds;
   if(pid<=0 || pid==Environment.ProcessId || ticks<=0 || ticks>updated.Ticks || age<0 || age>25 || !row.GetProperty("controller").GetBoolean() || row.GetProperty("monitorOnly").GetBoolean()) return false;
   using var process=io.Open(pid);
   var identity=process.ReadIdentity();
   bool Valid(ControllerIdentity id) => id.Pid==pid && id.StartTicks==ticks && Matches(id,script,data) && (io.UtcNow-updated).TotalSeconds is >=0 and <=25;
   if(!Valid(identity) || process.HasExited) return false;
   // Revalidate all authority after slow inspection, before creating any stop file.
   store.Validate();Installation.SafePath(signal);
   if(!Valid(process.ReadIdentity()) || process.HasExited) return false;
   io.Signal(signal,token);signaled=true;
   if(!process.WaitForExit(5000)) {
    // Retain the original process handle; never reacquire a PID for termination.
    if(!Valid(process.ReadIdentity()) || process.HasExited) return false;
    process.Kill();
    if(!process.WaitForExit(3000)) return false;
   }
   if(!process.HasExited || io.IsRunning(mutexName)) return false;
   return true;
  } catch { return false; }
  finally { if(signaled && signal is not null) { try { io.RemoveSignal(signal,token); } catch { } } }
 }
 internal static bool Matches(ControllerIdentity id,string script,string data)
 {
  if(!ControllerTakeoverPaths.Same(id.Image,ControllerTakeoverPaths.PowerShell)) return false;
  var args=WindowsCommandLine.Parse(id.CommandLine);
  if(args.Length<6 || !ControllerTakeoverPaths.Same(args[0],id.Image)) return false;

  int fileIndex=-1;
  int fileCount=0;
  for(int i=1;i<args.Length;i++) {
   if(args[i].Equals("-File",StringComparison.OrdinalIgnoreCase)) {
    fileCount++;
    fileIndex=i;
   }
  }
  if(fileCount!=1 || fileIndex+1>=args.Length) return false;

  bool hasNoProfile=false;
  bool hasBypass=false;
  for(int i=1;i<fileIndex;i++) {
   var arg=args[i];
   if(arg.Equals("-NoProfile",StringComparison.OrdinalIgnoreCase)) { hasNoProfile=true; continue; }
   if(arg.Equals("-NoLogo",StringComparison.OrdinalIgnoreCase)) continue;
   if(arg.Equals("-NonInteractive",StringComparison.OrdinalIgnoreCase)) continue;
   if(arg.Equals("-ExecutionPolicy",StringComparison.OrdinalIgnoreCase) && i+1<fileIndex && args[i+1].Equals("Bypass",StringComparison.OrdinalIgnoreCase)) {
    hasBypass=true;
    i++;
    continue;
   }
   return false;
  }
  if(!hasNoProfile || !hasBypass) return false;

  var scriptArg=args[fileIndex+1];
  if(!ControllerTakeoverPaths.Same(scriptArg,script)) return false;

  int dataIndex=-1;
  int dataCount=0;
  for(int i=fileIndex+2;i<args.Length;i++) {
   if(args[i].Equals("-DataDirectory",StringComparison.OrdinalIgnoreCase)) {
    dataCount++;
    dataIndex=i;
   }
  }
  if(dataCount!=1 || dataIndex+1>=args.Length) return false;
  if(!ControllerTakeoverPaths.Same(args[dataIndex+1],data)) return false;

  for(int i=fileIndex+2;i<args.Length;i++) {
   if(i==dataIndex || i==dataIndex+1) continue;
   var arg=args[i];
   if(arg.Equals("-Headless",StringComparison.OrdinalIgnoreCase)) continue;
   if(arg.Equals("-StopFile",StringComparison.OrdinalIgnoreCase) && i+1<args.Length) { i++; continue; }
   return false;
  }
  return true;
 }
}
internal sealed class WindowsControllerIo : IControllerIo
{
 public bool IsRunning(string name) => LauncherEntry.ControllerIsRunning(name);
 public string ReadHeartbeat(string path) => File.ReadAllText(path);
 public DateTime UtcNow => DateTime.UtcNow;
 public IControllerProcess Open(int pid) => new WindowsControllerProcess(pid);
 public void Signal(string path, string token) { using var f=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None); var b=Encoding.UTF8.GetBytes(token); f.Write(b); f.Flush(true); }
 public void RemoveSignal(string path,string token) { if(File.ReadAllText(path)==token) File.Delete(path); }
}
internal sealed class WindowsControllerProcess : IControllerProcess
{
 readonly Process process;
 internal WindowsControllerProcess(int pid) { process=Process.GetProcessById(pid); _=process.Handle; }
 public bool HasExited => process.HasExited;
 public bool WaitForExit(int ms) => process.WaitForExit(ms);
 public void Kill() => process.Kill();
 public void Dispose() => process.Dispose();
 public ControllerIdentity ReadIdentity()
 {
  if(process.HasExited) throw new InvalidOperationException("Controller exited.");
  var ticks=process.StartTime.ToUniversalTime().Ticks;
  var image=process.MainModule?.FileName ?? throw new InvalidOperationException("No process image.");
  // Read only this PID. Never enumerate or execute a termination command in a query host.
  var query=new ProcessStartInfo(ControllerTakeoverPaths.PowerShell) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true };
  query.ArgumentList.Add("-NoProfile"); query.ArgumentList.Add("-NonInteractive"); query.ArgumentList.Add("-Command");
  query.ArgumentList.Add("$ErrorActionPreference='Stop'; Get-CimInstance Win32_Process -Filter 'ProcessId="+process.Id+"' | Select-Object ProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Compress");
  using var child=Process.Start(query) ?? throw new InvalidOperationException("Cannot inspect controller.");
  var output=child.StandardOutput.ReadToEndAsync(); var error=child.StandardError.ReadToEndAsync();
  if(!child.WaitForExit(3000)) throw new InvalidOperationException("Controller identity query timed out.");
  if(child.ExitCode!=0) throw new InvalidOperationException("Controller identity query failed.");
  using var doc=JsonDocument.Parse(output.GetAwaiter().GetResult());
  var row=doc.RootElement;
  if(row.ValueKind!=JsonValueKind.Object || row.GetProperty("ProcessId").GetInt32()!=process.Id || !ControllerTakeoverPaths.Same(image,row.GetProperty("ExecutablePath").GetString())) throw new InvalidOperationException("Unbound controller image.");
  if(process.HasExited || process.StartTime.ToUniversalTime().Ticks!=ticks) throw new InvalidOperationException("Controller generation changed.");
  return new(process.Id,ticks,image,row.GetProperty("CommandLine").GetString() ?? "");
 }
}
internal static class ControllerTakeoverPaths
{
 internal static string PowerShell => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
 internal static bool Same(string? a,string? b) => !string.IsNullOrWhiteSpace(a) && !string.IsNullOrWhiteSpace(b) && Path.IsPathFullyQualified(a) && Path.IsPathFullyQualified(b) && string.Equals(Path.GetFullPath(a),Path.GetFullPath(b),StringComparison.OrdinalIgnoreCase);
}
