using System.Net;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
sealed class FixtureHandler(byte[] zip, string mode="valid", byte[]? controlCenter=null) : HttpMessageHandler
{
 public List<string> Requests {get;}=[];
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
 {
  Requests.Add(request.RequestUri!.AbsoluteUri);
  if(request.Headers.Authorization is not null) throw new Exception("No credentials allowed");
  if(!request.Headers.UserAgent.Any()) throw new Exception("User agent missing");
  byte[] content;
  if(Requests.Count==1) {
   const string release="https://github.com/arkuzodev/arkuzo-memory-saver/releases/download/v1.0.0/";
   var assets=new List<object>{ new {name="ArkuzoMemorySaver-runtime.zip", state="uploaded", size=zip.Length, digest=(string?)("sha256:"+Convert.ToHexStringLower(SHA256.HashData(zip))),browser_download_url=release+"ArkuzoMemorySaver-runtime.zip"}, new {name="ArkuzoMemorySaver-runtime.sha256",state="uploaded", size=64,digest=(string?)null,browser_download_url=mode=="evil"?"https://evil.example/a":release+"ArkuzoMemorySaver-runtime.sha256"} };
   if(mode=="missing") assets.RemoveAt(1);
   if(controlCenter is not null) {
    assets.Add(new {name="ArkuzoMemorySaver-controlcenter.zip", state="uploaded", size=controlCenter.Length, digest=(string?)("sha256:"+Convert.ToHexStringLower(SHA256.HashData(controlCenter))),browser_download_url=mode=="cc-evil"?"https://evil.example/cc.zip":release+"ArkuzoMemorySaver-controlcenter.zip"});
    if(mode!="cc-partial") assets.Add(new {name="ArkuzoMemorySaver-controlcenter.sha256",state="uploaded", size=64,digest=(string?)null,browser_download_url=release+"ArkuzoMemorySaver-controlcenter.sha256"});
   }
   content=JsonSerializer.SerializeToUtf8Bytes(new{ tag_name="v1.0.0",draft=false, prerelease=mode=="prerelease",published_at="2026-10-07T00:00:00Z",assets });
  } else {
   var cc=request.RequestUri.AbsolutePath.Contains("controlcenter");
   var body=cc ? controlCenter! : zip;
   content=request.RequestUri.AbsolutePath.EndsWith(".zip")?body:Encoding.UTF8.GetBytes(Convert.ToHexStringLower(SHA256.HashData(mode=="cc-tampered" && cc ? [1] : body)));
  }
  return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(content)});
 }
}
