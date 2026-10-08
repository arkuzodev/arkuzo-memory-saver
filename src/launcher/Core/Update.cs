using System.Diagnostics;
namespace Launcher;
public sealed class GitHubReleaseSource
{
 private readonly HttpMessageHandler handler;
 public GitHubReleaseSource() : this(new HttpClientHandler {AllowAutoRedirect=false,UseCookies=false}) { }
 internal GitHubReleaseSource(HttpMessageHandler handler) { this.handler=handler; }
 public async Task<ReleasePayload> FetchAsync()
 {
  using var client=new HttpClient(handler) {Timeout=TimeSpan.FromSeconds(30)};
  client.DefaultRequestHeaders.UserAgent.ParseAdd("ArkuzoMemorySaver-Launcher/1.0.2");
  client.DefaultRequestHeaders.Add("X-GitHub-Api-Version","2022-11-28");
  using var budget=new CancellationTokenSource(TimeSpan.FromSeconds(90));
  var metadata=await Download(client,"https://api.github.com/repos/arkuzodev/arkuzo-memory-saver/releases/latest",1024*1024,budget.Token);
  try {
   using var document=System.Text.Json.JsonDocument.Parse(metadata);
   var release=document.RootElement;
   if(release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean() || release.GetProperty("published_at").ValueKind!=System.Text.Json.JsonValueKind.String)
    throw new InvalidDataException("Latest release is not published and stable.");
   var version=release.GetProperty("tag_name").GetString() ?? ""; Installation.ParseVersion(version);
   var assets=release.GetProperty("assets").EnumerateArray().ToArray();
   var zipAsset=Asset(assets,"ArkuzoMemorySaver-runtime.zip",version,RuntimePackage.Limit);
   var checksumAsset=Asset(assets,"ArkuzoMemorySaver-runtime.sha256",version,4096);
   var zip=await Download(client,zipAsset.Url,RuntimePackage.Limit,budget.Token);
   var checksum=await Download(client,checksumAsset.Url,4096,budget.Token);
   if(zip.Length!=zipAsset.Size || checksum.Length!=checksumAsset.Size) throw new InvalidDataException("Release asset size mismatch.");
   if(checksumAsset.Digest is not null && !checksumAsset.Digest.Equals("sha256:"+System.Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(checksum)),StringComparison.OrdinalIgnoreCase))
    throw new InvalidDataException("GitHub checksum asset digest mismatch.");
   return new ReleasePayload(version,zip,new System.Text.UTF8Encoding(false,true).GetString(checksum),zipAsset.Digest);
  } catch(Exception ex) when(ex is System.Text.Json.JsonException or KeyNotFoundException or InvalidOperationException or System.Text.DecoderFallbackException)
  { throw new InvalidDataException("Invalid GitHub release metadata.",ex); }
 }
 static (string Url,long Size,string? Digest) Asset(System.Text.Json.JsonElement[] assets,string name,string version,int limit)
 {
  var matches=assets.Where(x=>x.GetProperty("name").GetString()==name).ToArray();
  if(matches.Length!=1) throw new InvalidDataException("Required release asset missing or duplicated: "+name);
  var asset=matches[0]; var size=asset.GetProperty("size").GetInt64();
  var expected="https://github.com/arkuzodev/arkuzo-memory-saver/releases/download/"+version+"/"+name;
  if(asset.GetProperty("state").GetString()!="uploaded" || size<=0 || size>limit || asset.GetProperty("browser_download_url").GetString()!=expected)
   throw new InvalidDataException("Invalid or unsafe release asset: "+name);
  return (expected,size,asset.TryGetProperty("digest",out var digest) && digest.ValueKind!=System.Text.Json.JsonValueKind.Null ? digest.GetString():null);
 }
 static async Task<byte[]> Download(HttpClient client,string address,int limit,CancellationToken token)
 {
  var uri=new Uri(address);
  for(var redirects=0;redirects<=5;redirects++) {
   if(uri.Scheme!="https" || !uri.IsDefaultPort || !string.IsNullOrEmpty(uri.UserInfo) || !new[]{"api.github.com","github.com","release-assets.githubusercontent.com","objects.githubusercontent.com"}.Contains(uri.Host,StringComparer.OrdinalIgnoreCase))
    throw new InvalidDataException("Unsafe GitHub download redirect.");
   using var response=await client.GetAsync(uri,HttpCompletionOption.ResponseHeadersRead,token);
   if((int)response.StatusCode is 301 or 302 or 303 or 307 or 308) {
    if(response.Headers.Location is null) throw new InvalidDataException("Missing redirect location.");
    uri=new Uri(uri,response.Headers.Location); continue;
   }
   response.EnsureSuccessStatusCode();
   if(response.Content.Headers.ContentLength>limit) throw new InvalidDataException("Download exceeds size limit.");
   using var stream=await response.Content.ReadAsStreamAsync(token);
   using var output=new MemoryStream(); var buffer=new byte[81920]; int n;
   try {
    while((n=await stream.ReadAsync(buffer,token))!=0) { if(output.Length+n>limit) throw new InvalidDataException("Download exceeds size limit."); output.Write(buffer,0,n); }
   } catch(IOException ex) { throw new HttpRequestException("Download interrupted.",ex); }
   return output.ToArray();
  }
  throw new InvalidDataException("Too many GitHub download redirects.");
 }
}
public static class Updater
{
 public static Task<Installed> PrepareAsync(Installation store,bool offline) => PrepareAsync(store,offline,new GitHubReleaseSource().FetchAsync);
 internal static async Task<Installed> PrepareAsync(Installation store,bool offline,Func<Task<ReleasePayload>> fetch)
 {
  if(offline) return store.Validate();
  ReleasePayload release;
  try { release=await fetch().ConfigureAwait(false); }
  catch(Exception ex) when(ex is HttpRequestException or TaskCanceledException)
  {
   Console.Error.WriteLine("Network unavailable. Validating known-good local runtime.");
   return store.Validate();
  }
  if (store.TryGetInstalled(out var current) && Installation.ParseVersion(release.Version) <= Installation.ParseVersion(current.Version))
  {
   return store.Validate();
  }
  return store.Install(release);
 }
 public static ProcessStartInfo ChildStart(string root,string runtime)
 {
  var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe")) { UseShellExecute=false, WorkingDirectory=runtime };
  foreach(var arg in new[]{"-NoProfile","-ExecutionPolicy","Bypass","-File",Path.Combine(runtime,"Arkuzo-Memory-Saver.ps1"),"-DataDirectory",Path.Combine(root,"data")}) start.ArgumentList.Add(arg);
  return start;
 }
}
