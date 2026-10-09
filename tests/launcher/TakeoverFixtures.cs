using Launcher;
using System.Security.Cryptography;
using System.Text.Json;

internal sealed class FixtureControllerIo : IControllerIo
{
 public bool Running;
 public string Heartbeat="";
 public int Opens,Signals,Removes;
 public readonly FixtureControllerProcess Process=new();
 public DateTime UtcNow { get; set; }=new DateTime(2026,10,8,18,0,0,DateTimeKind.Utc);
 public bool IsRunning(string name)=>Running;
 public string ReadHeartbeat(string path)=>Heartbeat;
 public IControllerProcess Open(int pid) { Opens++; return Process; }
 public void Signal(string path,string token) { Signals++; Process.OnSignal?.Invoke(); }
 public void RemoveSignal(string path,string token) { Removes++; }
}
internal sealed class FixtureControllerProcess : IControllerProcess
{
 public ControllerIdentity Identity=new(777,1,"","");
 public int Reads,Kills;
 public bool HasExited {get;set;}
 public Action? OnSignal,OnRead;
 public Func<bool>? OnWait;
 public ControllerIdentity ReadIdentity() { Reads++; OnRead?.Invoke(); return Identity; }
 public bool WaitForExit(int ms) => OnWait?.Invoke() ?? HasExited;
 public void Kill() { Kills++; HasExited=true; }
 public void Dispose() { }
}
internal static class TakeoverFixtures
{
 static void Check(bool value,string message) { if(!value) throw new Exception(message); }
 internal static void Run()
 {
  var root=Path.Combine(Environment.GetEnvironmentVariable("TMPDIR")!,"takeover identity ü-"+Guid.NewGuid().ToString("N"));
  Directory.CreateDirectory(root);
  try {
   using var ms=new MemoryStream();
   using(var zip=new System.IO.Compression.ZipArchive(ms,System.IO.Compression.ZipArchiveMode.Create,true))
    foreach(var f in RuntimePackage.Files) { using var stream=zip.CreateEntry(f).Open(); stream.Write(new byte[4]); }
   var bytes=ms.ToArray();var store=new Installation(root);
   var installed=store.Install(new ReleasePayload("v1.0.0",bytes,Convert.ToHexStringLower(SHA256.HashData(bytes))));
   var script=Path.Combine(store.RuntimePath(installed),"Arkuzo-Memory-Saver.ps1");var data=Path.Combine(root,"data");
   FixtureControllerIo Make() {
    var io=new FixtureControllerIo {Running=true};
    var ticks=io.UtcNow.AddMinutes(-1).Ticks;
    io.Heartbeat=JsonSerializer.Serialize(new {pid=777,startTicks=ticks,updatedUtc=io.UtcNow,controller=true,monitorOnly=false});
    io.Process.Identity=new(777,ticks,ControllerTakeoverPaths.PowerShell,$"\"{ControllerTakeoverPaths.PowerShell}\" -NoProfile -ExecutionPolicy Bypass -File \"{script}\" -DataDirectory \"{data}\" -Headless");
    io.Process.OnWait=()=> {if(io.Process.HasExited) io.Running=false;return io.Process.HasExited;};
    return io;
   }
   var valid=Make();
   Check(ControllerTakeover.Replace(root,"fixture",valid),"exact headless owned controller allowed");
   Check(valid.Signals==1 && valid.Process.Kills==1 && valid.Removes==1,"only retained owned controller is signaled and terminated");
   var benign=Make();
   benign.Process.Identity=benign.Process.Identity with {CommandLine=$"\"{ControllerTakeoverPaths.PowerShell}\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{script}\" -DataDirectory \"{data}\" -Headless"};
   Check(ControllerTakeover.Replace(root,"fixture",benign),"benign flags headless controller allowed");
   Console.WriteLine("PASS exact headless owned controller fixture");
   var graceful=Make();graceful.Process.OnSignal=()=>graceful.Process.HasExited=true;
   Check(ControllerTakeover.Replace(root,"fixture",graceful) && graceful.Process.Kills==0,"graceful controller needs no kill");
   var cases=new Dictionary<string,Action<FixtureControllerIo>> {
    ["foreign controller script"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=io.Process.Identity.CommandLine.Replace(script,Path.Combine(root,"foreign","Arkuzo-Memory-Saver.ps1"))},
    ["foreign data directory"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=io.Process.Identity.CommandLine.Replace(data,data+"foreign")},
    ["query process"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=$"powershell.exe -Command Get-CimInstance '*Arkuzo-Memory-Saver*'"},
    ["test parent"]=io=>io.Process.Identity=io.Process.Identity with {Image=Environment.ProcessPath!},
    ["PID reuse"]=io=>io.Process.Identity=io.Process.Identity with {StartTicks=io.Process.Identity.StartTicks+1},
    ["missing generation"]=io=>io.Heartbeat="{\"pid\":777}",
    ["missing script path"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine="powershell.exe -File"},
    ["forged stale heartbeat"]=io=>io.Heartbeat=JsonSerializer.Serialize(new {pid=777,startTicks=io.Process.Identity.StartTicks,updatedUtc=io.UtcNow.AddMinutes(-10),controller=true,monitorOnly=false}),
    ["wrong executable"]=io=>io.Process.Identity=io.Process.Identity with {Image=Path.Combine(root,"powershell.exe")},
    ["encoded command"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=io.Process.Identity.CommandLine+" -EncodedCommand AAA"},
    ["bounded diagnostic"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=io.Process.Identity.CommandLine+" -RunForSec 15"},
    ["monitor diagnostic"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=io.Process.Identity.CommandLine+" -MonitorOnly"},
    ["ambiguous file args"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=io.Process.Identity.CommandLine+" -File other.ps1"},
    ["broken quoting"]=io=>io.Process.Identity=io.Process.Identity with {CommandLine=io.Process.Identity.CommandLine+" \""},
    ["heartbeat becomes stale during inspection"]=io=>io.Process.OnRead=()=> {if(io.Process.Reads==2) io.UtcNow=io.UtcNow.AddMinutes(1);},
    ["identity changes before signal"]=io=>io.Process.OnRead=()=> {if(io.Process.Reads==2) io.Process.Identity=io.Process.Identity with {StartTicks=1};}
   };
   foreach(var entry in cases) { var io=Make();entry.Value(io);Check(!ControllerTakeover.Replace(root,"fixture",io),entry.Key+" refused");Check(io.Process.Kills==0 && io.Signals==0,entry.Key+" has no destructive effect"); }
   var changed=Make();changed.Process.OnSignal=()=>changed.Process.Identity=changed.Process.Identity with {StartTicks=1};
   Check(!ControllerTakeover.Replace(root,"fixture",changed) && changed.Process.Kills==0,"generation change during graceful wait prevents kill");
   var missing=Make();missing.Heartbeat="";Check(!ControllerTakeover.Replace(root,"fixture",missing) && missing.Opens==0,"no heartbeat means no discovery fallback");
   var stuck=Make();stuck.Process.OnWait=()=>false;
   Check(!ControllerTakeover.Replace(root,"fixture",stuck),"unconfirmed exit/mutex release cannot count as success");
   var verify=Make();Check(LauncherEntry.Run(["--offline","--verify-only"],root,"fixture",()=>{},verify)==0 && verify.Opens==0 && verify.Signals==0,"verify only bypasses takeover IO");
   Console.WriteLine("PASS foreign/query/parent/PID-reuse/missing/stale/argv/image/TOCTOU/no-fallback/verify-only fixture safety");
  } finally {Directory.Delete(root,true);}
 }
}
