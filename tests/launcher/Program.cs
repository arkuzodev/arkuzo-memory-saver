using Launcher;
using System.Security.Cryptography;
using System.Text;
static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
static void Reject(Action action) { try { action(); } catch (InvalidDataException) { return; } throw new Exception("Expected rejection"); }
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
} finally { Directory.Delete(temp,true); }
var handler=new FixtureHandler(Zip(RuntimePackage.Files));
var remote=new GitHubReleaseSource(handler).FetchAsync().GetAwaiter().GetResult();
Assert(remote.Version=="v1.0.0" && handler.Requests.Count==3,"release downloaded");
Assert(handler.Requests[0]=="https://api.github.com/repos/arkuzodev/arkuzo-memory-saver/releases/latest","hardcoded latest endpoint");
foreach(var mode in new[]{"evil","prerelease","missing"}) Reject(()=>new GitHubReleaseSource(new FixtureHandler(Zip(RuntimePackage.Files),mode)).FetchAsync().GetAwaiter().GetResult());
Console.WriteLine("PASS GitHub latest published stable, fixed repository, no credentials, trusted URLs, required assets");
var entryTemp=Path.Combine(Environment.GetEnvironmentVariable("TMPDIR")!,"launcher-entry-tests-"+Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(entryTemp);
try {
 Assert(LauncherEntry.Run(new[]{"--unknown"},entryTemp)==2,"bad argument rejected");
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},entryTemp)==1,"first offline run honest");
 Assert(!Directory.Exists(Path.Combine(entryTemp,"app")),"verify missing does not create install");
 using(var held=new LauncherLock(entryTemp)) {
  var contender=Task.Run(()=> { try { using var second=new LauncherLock(entryTemp); return false; } catch(InvalidOperationException) { return true; } }).GetAwaiter().GetResult();
  Assert(contender,"mutex excludes contender");
 }
 var script=Path.Combine(entryTemp,"Arkuzo-Memory-Saver.ps1");
 File.WriteAllText(script,"param([string]$DataDirectory)\nif ($DataDirectory -ne '"+Path.Combine(entryTemp,"data").Replace("'","''")+"') { exit 99 }; exit 7");
 Assert(LauncherEntry.ExecuteChild(Updater.ChildStart(entryTemp,entryTemp))==7,"wait and return child exit code");
 var pkg=Zip(RuntimePackage.Files); new Installation(entryTemp).Install(new ReleasePayload("v1.0.0",pkg,Convert.ToHexStringLower(SHA256.HashData(pkg))));
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},entryTemp)==0,"offline verifies without executing invalid fixture script");
 File.Delete(Path.Combine(entryTemp,"data","config.json"));
 Assert(LauncherEntry.Run(new[]{"--offline","--verify-only"},entryTemp)==0 && File.Exists(Path.Combine(entryTemp,"data","config.json")),"missing config initialized from validated offline defaults");
 Console.WriteLine("PASS CLI flags, first-run error, mutex contention, real local PowerShell child exit 7, offline verify no child");
} finally {Directory.Delete(entryTemp,true); }
