using System.Diagnostics;
using Launcher;
using System.Security.Cryptography;
using System.Text;
static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
static void Reject(Action action) { try { action(); } catch (InvalidDataException) { return; } throw new Exception("Expected rejection"); }
var confirmations=0;
LauncherUi.WaitForDismissal(false,false,false,()=>confirmations++);
Assert(confirmations==1,"interactive notice waits for acknowledgement instead of disappearing");
foreach(var redirects in new[]{(true,false),(false,true),(true,true)})
 LauncherUi.WaitForDismissal(false,redirects.Item1,redirects.Item2,()=>confirmations++);
LauncherUi.WaitForDismissal(true,false,false,()=>confirmations++);
Assert(confirmations==1,"redirected and verify-only launches never wait for a key");
Console.WriteLine("PASS visible interactive notices and nonblocking verification/redirected output");
var bytes=Encoding.UTF8.GetBytes("real fixture bytes");
var hash=Convert.ToHexStringLower(SHA256.HashData(bytes));
Assert(RuntimePackage.CheckHash(bytes, hash+"  ArkuzoMemorySaver-runtime.zip\n", "sha256:"+hash)==hash,"valid checksum");
Reject(()=>RuntimePackage.CheckHash(bytes, new string('0',64)));
Reject(()=>RuntimePackage.CheckHash(bytes, hash,"sha256:"+new string('0',64)));
Reject(()=>RuntimePackage.CheckHash(bytes,hash+"  other.zip"));
Console.WriteLine("PASS checksum, mismatch, GitHub digest, filename");
static byte[] Zip(IEnumerable<string> names, int size=4, bool symlink=false) {
 using var ms=new MemoryStream();
 using(var archive=new System.IO.Compression.ZipArchive(ms,System.IO.Compression.ZipArchiveMode.Create,true)) {
  foreach(var name in names) { var entry=archive.CreateEntry(name); if(symlink) entry.ExternalAttributes=unchecked((int)0xA1FF0000); using var stream=entry.Open(); stream.Write(new byte[size]); }
 }
 return ms.ToArray();
}
Assert(RuntimePackage.Unpack(Zip(RuntimePackage.Files)).Count==4,"four files");
foreach(var name in new[]{"../evil","sub/defaults.json","C:/evil","defaults.json/","DEFAULTS.JSON","extra.ps1","..\\evil"}) Reject(()=>RuntimePackage.Unpack(Zip(RuntimePackage.Files.Skip(1).Prepend(name))));
Reject(()=>RuntimePackage.Unpack(Zip(RuntimePackage.Files.Skip(1))));
Reject(()=>RuntimePackage.Unpack(Zip(RuntimePackage.Files.Append("defaults.json"))));
Reject(()=>RuntimePackage.Unpack(Zip(RuntimePackage.Files,symlink:true)));
Reject(()=>RuntimePackage.Unpack(Zip(RuntimePackage.Files,RuntimePackage.Limit/4+1)));
Console.WriteLine("PASS strict ZIP: traversal, nested, drive, case, extra, missing, duplicate, symlink, oversize");
var cc=RuntimePackage.ControlCenterFiles;
Assert(RuntimePackage.Unpack(Zip(cc),cc).Count==2,"two Control Center files");
foreach(var name in new[]{"../evil","sub/Arkuzo-Control-Center.py","ARKUZO-CONTROL-CENTER.HTML","Arkuzo-Memory-Saver.ps1"}) Reject(()=>RuntimePackage.Unpack(Zip(cc.Skip(1).Prepend(name)),cc));
Reject(()=>RuntimePackage.Unpack(Zip(cc.Concat(RuntimePackage.Files)),cc));
Reject(()=>RuntimePackage.Unpack(Zip(cc.Append("extra.py")),cc));
Reject(()=>RuntimePackage.Unpack(Zip(cc),RuntimePackage.Files));
Reject(()=>RuntimePackage.Unpack(Zip(RuntimePackage.Files.Concat(cc))));
Reject(()=>RuntimePackage.Unpack(Zip(cc,symlink:true),cc));
Reject(()=>RuntimePackage.Unpack(Zip(cc,RuntimePackage.Limit/2+1),cc));
Assert(RuntimePackage.CheckHash(bytes,hash+"  ArkuzoMemorySaver-controlcenter.zip\n",null,RuntimePackage.ControlCenterZipName)==hash,"Control Center checksum");
Reject(()=>RuntimePackage.CheckHash(bytes,hash+"  ArkuzoMemorySaver-runtime.zip",null,RuntimePackage.ControlCenterZipName));
Reject(()=>RuntimePackage.CheckHash(bytes,hash+"  ArkuzoMemorySaver-controlcenter.zip"));
var repo=new DirectoryInfo(AppContext.BaseDirectory);
while(repo is not null && !File.Exists(Path.Combine(repo.FullName,"src","saver","Arkuzo-Control-Center.py"))) repo=repo.Parent;
Assert(repo is not null && cc.All(x=>File.Exists(Path.Combine(repo.FullName,"src","saver",x))),"add-on files exist in src/saver");
var ccSource=File.ReadAllText(Path.Combine(repo!.FullName,"src","saver","Arkuzo-Control-Center.py"));
Assert(ccSource.Contains("APP_ID = '"+ControlCenter.AppId+"'") && System.Text.RegularExpressions.Regex.IsMatch(ccSource,@"^DEFAULT_PORT = "+ControlCenter.Port+@"\r?$",System.Text.RegularExpressions.RegexOptions.Multiline),"launcher ping matches the Control Center app id and port");
Console.WriteLine("PASS Control Center add-on: strict two-file ZIP, six-file runtime ZIP rejected, checksum bound to asset name");
var temp=Path.Combine(Environment.GetEnvironmentVariable("TMPDIR")!,"launcher-tests-"+Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temp);
try {
 var store=new Installation(temp);
 Directory.CreateDirectory(Path.Combine(temp,"legacy-case"));
 var legacyRoot=Path.Combine(temp,"legacy-case");
 var legacyBytes=new byte[]{239,187,191,123,255,0,125};
 File.WriteAllBytes(Path.Combine(legacyRoot,"config.json"),legacyBytes);
 var legacyPkg=Zip(RuntimePackage.Files);
 var legacyStore=new Installation(legacyRoot);
 legacyStore.Install(new ReleasePayload("v1.0.0",legacyPkg,Convert.ToHexStringLower(SHA256.HashData(legacyPkg))));
 Assert(File.ReadAllBytes(Path.Combine(legacyRoot,"data","config.json")).SequenceEqual(legacyBytes),"legacy bytes copied");
 Assert(File.ReadAllBytes(Path.Combine(legacyRoot,"config.json")).SequenceEqual(legacyBytes),"legacy original retained");
 var payload=Zip(RuntimePackage.Files);
 var release=new ReleasePayload("v1.0.0",payload,Convert.ToHexStringLower(SHA256.HashData(payload)));
 Reject(()=>store.Validate());
 var install=store.Install(release);
 Assert(store.Validate().Version=="v1.0.0","installed validation");
 Assert(File.ReadAllBytes(Path.Combine(temp,"data","config.json")).SequenceEqual(new byte[4]),"defaults copied");
 var custom=new byte[]{255,0,1,128,10}; File.WriteAllBytes(Path.Combine(temp,"data","config.json"),custom);
 store.Install(release with {Version="v1.1.0"});
 Assert(File.ReadAllBytes(Path.Combine(temp,"data","config.json")).SequenceEqual(custom),"config byte preservation");
 Reject(()=>store.Install(release));
 Assert(store.Validate().Version=="v1.1.0","downgrade pointer unchanged");
 Reject(()=>store.Install(release with {Version="v1.2.0-beta"}));
 Reject(()=>store.Install(release with {Version="../evil"}));
 File.WriteAllText(Path.Combine(store.RuntimePath(store.Validate()),"Arkuzo-Memory-Saver.ps1"),"tampered");
 Reject(()=>store.Validate());
 Console.WriteLine("PASS install, cached hashes, missing cache, defaults, byte-preserved config, downgrade, stable version, tamper");
 Reject(()=>Updater.PrepareAsync(store,true,()=>throw new Exception("must not fetch")).GetAwaiter().GetResult());
 File.WriteAllBytes(Path.Combine(store.RuntimePath(new Installed("v1.1.0","",[])),"Arkuzo-Memory-Saver.ps1"),new byte[4]);
 Assert(Updater.PrepareAsync(store,true,()=>throw new Exception("must not fetch")).GetAwaiter().GetResult().Version=="v1.1.0","offline no network");
 Assert(Updater.PrepareAsync(store,false,()=>Task.FromException<ReleasePayload>(new HttpRequestException("network down"))).GetAwaiter().GetResult().Version=="v1.1.0","network fallback validated");
 Reject(()=>Updater.PrepareAsync(store,false,()=>Task.FromResult(release with {Version="v1.2.0",Checksum=new string('0',64)})).GetAwaiter().GetResult());
 var child=Updater.ChildStart(temp,store.RuntimePath(store.Validate()));
 Assert(child.FileName.EndsWith("powershell.exe",StringComparison.OrdinalIgnoreCase),"PowerShell exact binary");
 Assert(child.ArgumentList.SequenceEqual(new[]{"-NoProfile","-ExecutionPolicy","Bypass","-File",Path.Combine(store.RuntimePath(store.Validate()),"Arkuzo-Memory-Saver.ps1"),"-DataDirectory",Path.Combine(temp,"data")}),"exact child args");
 Assert(!child.UseShellExecute && !child.RedirectStandardOutput && !child.RedirectStandardInput && !child.RedirectStandardError,"console inherited");
 Console.WriteLine("PASS offline no-network, validated fallback, corrupt update fails closed, exact interactive child arguments");
 var ccRoot=Path.Combine(temp,"control-center");
 var ccStore=new Installation(ccRoot);
 var ccZip=Zip(cc,8);
 var addon=new AddonPayload(ccZip,Convert.ToHexStringLower(SHA256.HashData(ccZip))+"  ArkuzoMemorySaver-controlcenter.zip");
 Reject(()=>ccStore.Install(release with {ControlCenter=addon with {Checksum=new string('0',64)}}));
 Assert(!ccStore.TryGetInstalled(out _),"corrupt add-on blocks the whole update before anything is written");
 var core=ccStore.Install(release with {ControlCenter=addon});
 var ccInstalled=ccStore.ValidateControlCenter(core);
 Assert(ccInstalled is not null && ccInstalled.Version=="v1.0.0" && ccInstalled.Files.Count==6,"add-on installed for the runtime version");
 Assert(Directory.GetFileSystemEntries(ccStore.ControlCenterPath(core)).Length==6,"Control Center folder holds the add-on and verified engine copies");
 // What an older launcher on the same folder reads must stay exactly the four-file layout.
 Assert(Directory.GetFileSystemEntries(ccStore.RuntimePath(core)).Length==4,"versions folder keeps exactly four files");
 var pointer=System.Text.Json.JsonSerializer.Deserialize<Installed>(File.ReadAllBytes(Path.Combine(ccRoot,"app","current.json")))!;
 Assert(pointer.Files.Count==4 && RuntimePackage.Files.All(pointer.Files.ContainsKey),"current.json keeps the old four-file schema");
 Assert(ccStore.Validate().Version=="v1.0.0","core validation unchanged");
 var html=Path.Combine(ccStore.ControlCenterPath(core),"Arkuzo-Control-Center.html");
 File.WriteAllText(html,"tampered");
 Reject(()=>ccStore.ValidateControlCenter(core));
 Assert(!ccStore.HasValidControlCenter(core),"tampered add-on is not valid");
 Assert(Updater.PrepareAsync(ccStore,false,()=>Task.FromResult(release with {ControlCenter=addon})).GetAwaiter().GetResult().Version=="v1.0.0" && ccStore.HasValidControlCenter(core),"same-version release repairs the add-on");
 File.WriteAllText(Path.Combine(ccStore.ControlCenterPath(core),"Arkuzo-Memory-Saver.ps1"),"tampered");
 Reject(()=>ccStore.ValidateControlCenter(core));
 File.WriteAllBytes(Path.Combine(ccStore.ControlCenterPath(core),"Arkuzo-Memory-Saver.ps1"),new byte[4]);
 File.WriteAllText(Path.Combine(ccStore.ControlCenterPath(core),"extra.py"),"planted");
 Reject(()=>ccStore.ValidateControlCenter(core));
 File.Delete(Path.Combine(ccStore.ControlCenterPath(core),"extra.py"));
 Assert(ccStore.HasValidControlCenter(core),"restored add-on validates");
 var newer=ccStore.Install(release with {Version="v1.1.0"});
 Assert(ccStore.ValidateControlCenter(newer) is null,"stale add-on never runs a newer engine");
 Reject(()=>ccStore.InstallControlCenter(release with {ControlCenter=addon},newer));
 Assert(Updater.PrepareAsync(ccStore,false,()=>Task.FromResult(release with {Version="v1.1.0",ControlCenter=addon})).GetAwaiter().GetResult().Version=="v1.1.0" && ccStore.HasValidControlCenter(newer),"add-on is fetched for a runtime installed without it");
 var legacyOnly=new Installation(Path.Combine(temp,"legacy-only"));
 legacyOnly.Install(release);
 Assert(legacyOnly.ValidateControlCenter(legacyOnly.Validate()) is null,"release without the add-on installs only the core runtime");
 var ccChild=Updater.ControlCenterStart(ccRoot,ccStore.ControlCenterPath(newer),@"C:\Python\pythonw.exe");
 Assert(ccChild.FileName==@"C:\Python\pythonw.exe" && ccChild.WorkingDirectory==ccStore.ControlCenterPath(newer),"Control Center runs from its validated folder");
 Assert(ccChild.ArgumentList.SequenceEqual(new[]{"-I",Path.Combine(ccStore.ControlCenterPath(newer),"Arkuzo-Control-Center.py"),"--data",Path.Combine(ccRoot,"data")}),"exact Control Center arguments");
 Console.WriteLine("PASS add-on install: fail-closed checksum, old-layout compatibility, tamper/extra rejection, repair, version pinning, exact pythonw arguments");
} finally { Directory.Delete(temp,true); }
var handler=new FixtureHandler(Zip(RuntimePackage.Files));
var remote=new GitHubReleaseSource(handler).FetchAsync().GetAwaiter().GetResult();
Assert(remote.Version=="v1.0.0" && handler.Requests.Count==3,"release downloaded");
Assert(handler.Requests[0]=="https://api.github.com/repos/arkuzodev/arkuzo-memory-saver/releases/latest","hardcoded latest endpoint");
foreach(var mode in new[]{"evil","prerelease","missing"}) Reject(()=>new GitHubReleaseSource(new FixtureHandler(Zip(RuntimePackage.Files),mode)).FetchAsync().GetAwaiter().GetResult());
Assert(remote.ControlCenter is null,"release without add-on assets fetches only the core runtime");
var ccHandler=new FixtureHandler(Zip(RuntimePackage.Files),controlCenter:Zip(cc));
var ccRemote=new GitHubReleaseSource(ccHandler).FetchAsync().GetAwaiter().GetResult();
Assert(ccRemote.ControlCenter is not null && ccHandler.Requests.Count==5 && ccHandler.Requests.Contains("https://github.com/arkuzodev/arkuzo-memory-saver/releases/download/v1.0.0/ArkuzoMemorySaver-controlcenter.zip"),"add-on downloaded from the fixed release");
foreach(var mode in new[]{"cc-evil","cc-partial"}) Reject(()=>new GitHubReleaseSource(new FixtureHandler(Zip(RuntimePackage.Files),mode,Zip(cc))).FetchAsync().GetAwaiter().GetResult());
var tamperedRemote=new GitHubReleaseSource(new FixtureHandler(Zip(RuntimePackage.Files),"cc-tampered",Zip(cc))).FetchAsync().GetAwaiter().GetResult();
var tamperedRoot=Path.Combine(Environment.GetEnvironmentVariable("TMPDIR")!,"launcher-cc-tamper-"+Guid.NewGuid().ToString("N"));
try { Reject(()=>new Installation(tamperedRoot).Install(tamperedRemote)); Assert(!new Installation(tamperedRoot).TryGetInstalled(out _),"tampered add-on download installs nothing"); }
finally { if(Directory.Exists(tamperedRoot)) Directory.Delete(tamperedRoot,true); }
Console.WriteLine("PASS GitHub latest published stable, fixed repository, no credentials, trusted URLs, required assets, optional paired add-on");
var entryTemp=Path.Combine(Environment.GetEnvironmentVariable("TMPDIR")!,"launcher-entry-tests-"+Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(entryTemp);
try {
 Assert(LauncherEntry.Run(new[]{"--unknown"},entryTemp,"fixture",null,new FixtureControllerIo())==2,"bad argument rejected");
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},entryTemp,"fixture",null,new FixtureControllerIo())==1,"first offline run honest");
 Assert(!Directory.Exists(Path.Combine(entryTemp,"app")),"verify missing does not create install");
 using(var held=new LauncherLock(entryTemp)) {
  var contender=Task.Run(()=> { try { using var second=new LauncherLock(entryTemp); return false; } catch(InvalidOperationException) { return true; } }).GetAwaiter().GetResult();
  Assert(contender,"mutex excludes contender");
  var savedOut=Console.Out;
  using var duplicateOutput=new StringWriter();
  Console.SetOut(duplicateOutput);
  try {
   var duplicateWaits=0;
   var duplicateExit=Task.Run(()=>LauncherEntry.Run(new[]{"--offline"},entryTemp,LauncherEntry.ControllerMutexName,()=>duplicateWaits++,new FixtureControllerIo())).GetAwaiter().GetResult();
   Assert(duplicateExit==0,"second launch is an explicit already-running no-op, not a startup error");
   Assert(duplicateWaits==1,"same-installation notice uses injected acknowledgement instead of reading real keyboard input");
   Assert(duplicateOutput.ToString().Contains("[ALREADY RUNNING]",StringComparison.Ordinal),"second launch explains why no competing saver is started");
   Assert(!Directory.Exists(Path.Combine(entryTemp,"app")),"second launch never prepares or executes another runtime");
  } finally { Console.SetOut(savedOut); }
 }
 var controllerName="Local\\ArkuzoLauncher-ControllerTest-"+Guid.NewGuid().ToString("N");
 using(var controller=new Mutex(false,controllerName)) {
  Assert(controller.WaitOne(0),"test owns a separate controller mutex");
  try {
   var savedOut=Console.Out;
   using var controllerOutput=new StringWriter();
   Console.SetOut(controllerOutput);
   try {
    var noticeWaits=0;
    var duplicateExit=Task.Run(()=>LauncherEntry.Run(new[]{"--offline"},entryTemp,controllerName,()=>noticeWaits++,new FixtureControllerIo { Running=true })).GetAwaiter().GetResult();
    Assert(duplicateExit==0,"a controller in another installation is a safe already-running no-op");
    Assert(noticeWaits==1,"already-running notice stays open until acknowledged");
    Assert(controllerOutput.ToString().Contains("[ALREADY RUNNING]",StringComparison.Ordinal),"cross-installation controller is detected before startup");
    Assert(!Directory.Exists(Path.Combine(entryTemp,"app")) && !Directory.Exists(Path.Combine(entryTemp,"data")),"controller preflight has no runtime/config/log side effects");
   } finally { Console.SetOut(savedOut); }
  } finally { controller.ReleaseMutex(); }
 }
 TakeoverFixtures.Run();
 var startupWaits=0;
 var noRuntimeRoot=Path.Combine(entryTemp,"missing-runtime");
 Assert(LauncherEntry.Run(new[]{"--offline"},noRuntimeRoot,controllerName,()=>startupWaits++,new FixtureControllerIo())==1 && startupWaits==1,"ordinary startup errors remain visible until acknowledged");
 startupWaits=0;
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},noRuntimeRoot,controllerName,()=>startupWaits++,new FixtureControllerIo())==1 && startupWaits==0,"verification failures retain nonzero exit without waiting");
 var childRoot=Path.Combine(entryTemp,"child-exit-notice");
 byte[] ChildFixture(int exitCode) {
  using var ms=new MemoryStream();
  using(var archive=new System.IO.Compression.ZipArchive(ms,System.IO.Compression.ZipArchiveMode.Create,true))
   foreach(var file in RuntimePackage.Files) {
    using var writer=new StreamWriter(archive.CreateEntry(file).Open(),new UTF8Encoding(false));
    writer.Write(file=="Arkuzo-Memory-Saver.ps1" ? "param([string]$DataDirectory)\nexit "+exitCode : "{}");
   }
  return ms.ToArray();
 }
 var failedChild=ChildFixture(7);
 new Installation(childRoot).Install(new ReleasePayload("v1.0.0",failedChild,Convert.ToHexStringLower(SHA256.HashData(failedChild))));
 var childWaits=0;
 Assert(LauncherEntry.Run(new[]{"--offline"},childRoot,controllerName,()=>childWaits++,new FixtureControllerIo())==7 && childWaits==1,"runtime startup errors preserve child exit code and readable console");
 var stoppedChild=ChildFixture(0);
 new Installation(childRoot).Install(new ReleasePayload("v1.0.1",stoppedChild,Convert.ToHexStringLower(SHA256.HashData(stoppedChild))));
 childWaits=0;
 Assert(LauncherEntry.Run(new[]{"--offline"},childRoot,controllerName,()=>childWaits++,new FixtureControllerIo())==0 && childWaits==0,"a normal saver stop does not add an unexpected acknowledgement prompt");
 Console.WriteLine("PASS cross-installation preflight, visible startup/child errors, verification no-wait, normal stop");
 // The console engine of this fixture exits 7, so a 7 proves the console saver ran instead of the Control Center.
 var launchRoot=Path.Combine(entryTemp,"control-center-launch");
 var consoleChild=ChildFixture(7);
 var launchAddon=Zip(RuntimePackage.ControlCenterFiles);
 var launchRelease=new ReleasePayload("v1.0.0",consoleChild,Convert.ToHexStringLower(SHA256.HashData(consoleChild)),null,new AddonPayload(launchAddon,Convert.ToHexStringLower(SHA256.HashData(launchAddon))));
 var noAddonRoot=Path.Combine(entryTemp,"control-center-none");
 new Installation(noAddonRoot).Install(launchRelease with {ControlCenter=null});
 var noAddon=new FixtureControlCenterHost {Python=@"C:\Python\pythonw.exe"};
 Assert(LauncherEntry.Run(new[]{"--offline"},noAddonRoot,controllerName,()=>{},new FixtureControllerIo(),noAddon)==7 && noAddon.Started.Count==0,"runtime without the add-on keeps the console saver");
 var launchStore=new Installation(launchRoot);
 var launchCore=launchStore.Install(launchRelease);
 var withPython=new FixtureControlCenterHost {Python=@"C:\Python\pythonw.exe"};
 Assert(LauncherEntry.Run(new[]{"--offline"},launchRoot,controllerName,()=>{},new FixtureControllerIo(),withPython)==0 && withPython.Started.Count==1,"Python present starts the Control Center instead of the console saver");
 Assert(withPython.Started[0].ArgumentList.SequenceEqual(Updater.ControlCenterStart(Path.GetFullPath(launchRoot),launchStore.ControlCenterPath(launchCore),@"C:\Python\pythonw.exe").ArgumentList),"Control Center launched from the validated add-on folder");
 var noPython=new FixtureControlCenterHost();
 Assert(LauncherEntry.Run(new[]{"--offline"},launchRoot,controllerName,()=>{},new FixtureControllerIo(),noPython)==7 && noPython.Started.Count==0,"no Python falls back to the console saver");
 var forced=new FixtureControlCenterHost {Python=@"C:\Python\pythonw.exe"};
 Assert(LauncherEntry.Run(new[]{"--offline","--console"},launchRoot,controllerName,()=>{},new FixtureControllerIo(),forced)==7 && forced.Started.Count==0,"--console keeps the console saver");
 var verifyHost=new FixtureControlCenterHost {Python=@"C:\Python\pythonw.exe",Running=true};
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},launchRoot,controllerName,null,new FixtureControllerIo(),verifyHost)==0 && verifyHost.Started.Count==0,"verify-only never starts the Control Center");
 var supervising=new FixtureControlCenterHost {Python=@"C:\Python\pythonw.exe",Running=true};
 var supervisedSaver=new FixtureControllerIo {Running=true};
 Assert(LauncherEntry.Run(new[]{"--offline"},launchRoot,controllerName,()=>{},supervisedSaver,supervising)==0 && supervising.Started.Count==1 && supervisedSaver.Opens==0 && supervisedSaver.Signals==0,"a running Control Center is reopened, and its saver is never taken over");
 var consoleWaits=0;
 var consoleBlocked=new FixtureControlCenterHost {Python=@"C:\Python\pythonw.exe",Running=true};
 Assert(LauncherEntry.Run(new[]{"--offline","--console"},launchRoot,controllerName,()=>consoleWaits++,new FixtureControllerIo {Running=true},consoleBlocked)==0 && consoleWaits==1 && consoleBlocked.Started.Count==0,"--console never competes with a running Control Center");
 var unusable=new FixtureControlCenterHost {Running=true};
 consoleWaits=0;
 Assert(LauncherEntry.Run(new[]{"--offline"},launchRoot,controllerName,()=>consoleWaits++,new FixtureControllerIo(),unusable)==0 && consoleWaits==1,"a running Control Center without local Python is an already-running no-op, not a second saver");
 File.WriteAllText(Path.Combine(launchStore.ControlCenterPath(launchCore),"Arkuzo-Control-Center.py"),"tampered");
 var tamperedHost=new FixtureControlCenterHost {Python=@"C:\Python\pythonw.exe"};
 Assert(LauncherEntry.Run(new[]{"--offline"},launchRoot,controllerName,()=>{},new FixtureControllerIo(),tamperedHost)==1 && tamperedHost.Started.Count==0,"tampered Control Center fails closed");
 Assert(LauncherEntry.Run(new[]{"--offline","--console","--console"},launchRoot,controllerName,null,new FixtureControllerIo(),tamperedHost)==2,"duplicate flag rejected");
 Console.WriteLine("PASS Control Center launch with pythonw, console fallback, --console opt-out, no takeover of a supervising Control Center, tamper fails closed");
 var script=Path.Combine(entryTemp,"Arkuzo-Memory-Saver.ps1");
 File.WriteAllText(script,"param([string]$DataDirectory)\nif ($DataDirectory -ne '"+Path.Combine(entryTemp,"data").Replace("'","''")+"') { exit 99 }; exit 7");
 Assert(LauncherEntry.ExecuteChild(Updater.ChildStart(entryTemp,entryTemp))==7,"wait and return child exit code");
 var pkg=Zip(RuntimePackage.Files); new Installation(entryTemp).Install(new ReleasePayload("v1.0.0",pkg,Convert.ToHexStringLower(SHA256.HashData(pkg))));
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},entryTemp,"fixture",null,new FixtureControllerIo())==0,"offline verifies without executing invalid fixture script");
 File.Delete(Path.Combine(entryTemp,"data","config.json"));
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},entryTemp,"fixture",null,new FixtureControllerIo())==0 && File.Exists(Path.Combine(entryTemp,"data","config.json")),"missing config initialized from validated offline defaults");
 Console.WriteLine("PASS CLI flags, first-run error, mutex contention, real local PowerShell child exit 7, offline verify no child");
} finally {Directory.Delete(entryTemp,true); }
