using System.Diagnostics;
using System.Text.Json;
namespace Launcher;
internal interface IControlCenterHost
{
 bool IsRunning();
 string? FindPython();
 void Start(ProcessStartInfo info);
}
internal static class ControlCenter
{
 // Must match APP_ID and DEFAULT_PORT in Arkuzo-Control-Center.py.
 internal const string AppId="arkuzo-control-center";
 internal const int Port=48650;
 internal static string Url => "http://127.0.0.1:"+Port+"/";
 internal static readonly IControlCenterHost Unavailable=new UnavailableControlCenterHost();
 sealed class UnavailableControlCenterHost : IControlCenterHost
 {
  public bool IsRunning() => false;
  public string? FindPython() => null;
  public void Start(ProcessStartInfo info) => throw new InvalidOperationException("Control Center is unavailable.");
 }
}
internal sealed class WindowsControlCenterHost : IControlCenterHost
{
 public bool IsRunning()
 {
  try {
   using var client=new HttpClient(new HttpClientHandler {UseProxy=false,AllowAutoRedirect=false,UseCookies=false}) {Timeout=TimeSpan.FromSeconds(1.5)};
   using var doc=JsonDocument.Parse(client.GetByteArrayAsync(ControlCenter.Url+"api/ping").GetAwaiter().GetResult());
   return doc.RootElement.ValueKind==JsonValueKind.Object && doc.RootElement.TryGetProperty("app",out var app) && app.ValueKind==JsonValueKind.String && app.GetString()==ControlCenter.AppId;
  } catch { return false; }
 }
 // PATH only, like the Volt probe; relative PATH entries are ignored so the working directory never supplies Python.
 public string? FindPython()
 {
  foreach(var entry in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
  {
   var dir=entry.Trim().Trim('"');
   if(dir.Length==0 || !Path.IsPathFullyQualified(dir)) continue;
   var candidate=Path.Combine(dir,"pythonw.exe");
   if(File.Exists(candidate) && Probe(candidate)) return candidate;
  }
  return null;
 }
 static bool Probe(string python)
 {
  try {
   var info=new ProcessStartInfo(python) {UseShellExecute=false,CreateNoWindow=true};
   foreach(var arg in new[]{"-I","-c","import sys; sys.exit(0 if sys.version_info >= (3, 8) else 3)"}) info.ArgumentList.Add(arg);
   using var probe=Process.Start(info);
   if(probe is null) return false;
   if(!probe.WaitForExit(10000)) { try { probe.Kill(); } catch { } return false; }
   return probe.ExitCode==0;
  } catch { return false; }
 }
 public void Start(ProcessStartInfo info)
 {
  using var child=Process.Start(info) ?? throw new InvalidOperationException("Unable to start the Control Center.");
 }
}
