using System.Net;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
sealed class FixtureHandler(byte[] zip, string mode="valid") : HttpMessageHandler
{
 public List<string> Requests {get;}=[];
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
 {
  Requests.Add(request.RequestUri!.AbsoluteUri);
  if(request.Headers.Authorization is not null) throw new Exception("No credentials allowed");
  if(!request.Headers.UserAgent.Any()) throw new Exception("User agent missing");
  byte[] content;
  if(Requests.Count==1) {
   var assets=new[]{ new {name="ArkuzoMemorySaver-runtime.zip", state="uploaded", size=zip.Length, digest=(string?)("sha256:"+Convert.ToHexStringLower(SHA256.HashData(zip))),browser_download_url="https://github.com/arkuzodev/arkuzo-memory-saver/releases/download/v1.0.0/ArkuzoMemorySaver-runtime.zip"}, new {name="ArkuzoMemorySaver-runtime.sha256",state="uploaded", size=64,digest=(string?)null,browser_download_url=mode=="evil"?"https://evil.example/a":"https://github.com/arkuzodev/arkuzo-memory-saver/releases/download/v1.0.0/ArkuzoMemorySaver-runtime.sha256"} };
   content=JsonSerializer.SerializeToUtf8Bytes(new{ tag_name="v1.0.0",draft=false, prerelease=mode=="prerelease",published_at="2026-10-07T00:00:00Z",assets=mode=="missing"?assets.Take(1).ToArray():assets });
  } else content=request.RequestUri.AbsolutePath.EndsWith(".zip")?zip:Encoding.UTF8.GetBytes(Convert.ToHexStringLower(SHA256.HashData(zip)));
  return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(content)});
 }
}
