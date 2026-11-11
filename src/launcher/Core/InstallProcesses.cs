using System.Diagnostics;
using System.Text.Json;
namespace Launcher;
// The fallback that stops a stuck launcher or engine when the exact takeover (ControllerTakeover) fails.
// It only ever touches processes of this installation: a launcher whose image is this install's own
// ArkuzoMemorySaver.exe, and a PowerShell whose -File is an Arkuzo-Memory-Saver.ps1 inside this
// install's app\ folder. Other installs, a run from source and unrelated PowerShell windows are left alone.
internal static class InstallProcesses
{
 internal const string EngineScript = "Arkuzo-Memory-Saver.ps1";
 internal static bool IsInside(string? path, string folder)
 {
  if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || !Path.IsPathFullyQualified(folder)) return false;
  var full = Path.GetFullPath(path);
  var parent = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)) + Path.DirectorySeparatorChar;
  return full.StartsWith(parent, StringComparison.OrdinalIgnoreCase);
 }
 // A launcher of this install: its image sits in the install folder itself (the root is the exe's folder).
 internal static bool IsOwnLauncher(string root, string? image) =>
  !string.IsNullOrWhiteSpace(image) && Path.IsPathFullyQualified(image) &&
  string.Equals(Path.GetDirectoryName(Path.GetFullPath(image)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)), StringComparison.OrdinalIgnoreCase);
 // An engine of this install: powershell.exe or pwsh.exe running exactly one -File, the engine script inside <root>\app\.
 internal static bool IsOwnEngine(string root, string? image, string? commandLine)
 {
  if (string.IsNullOrWhiteSpace(image) || string.IsNullOrWhiteSpace(commandLine)) return false;
  var exe = Path.GetFileName(image);
  if (!exe.Equals("powershell.exe", StringComparison.OrdinalIgnoreCase) && !exe.Equals("pwsh.exe", StringComparison.OrdinalIgnoreCase)) return false;
  var args = WindowsCommandLine.Parse(commandLine);
  var files = Enumerable.Range(1, Math.Max(0, args.Length - 1)).Where(i => args[i].Equals("-File", StringComparison.OrdinalIgnoreCase)).ToArray();
  if (files.Length != 1 || files[0] + 1 >= args.Length) return false;
  var script = args[files[0] + 1];
  if (!Path.IsPathFullyQualified(script) || !Path.GetFileName(Path.GetFullPath(script)).Equals(EngineScript, StringComparison.OrdinalIgnoreCase)) return false;
  return IsInside(script, Path.Combine(Path.GetFullPath(root), "app"));
 }
 internal sealed record Candidate(int Pid, long StartTicks);
 // Rows of Win32_Process as JSON (one object or an array): ProcessId, ExecutablePath, CommandLine, StartTicks (UTC).
 internal static List<Candidate> OwnEngines(string root, string json)
 {
  var found = new List<Candidate>();
  if (string.IsNullOrWhiteSpace(json)) return found;
  using var doc = JsonDocument.Parse(json);
  var rows = doc.RootElement.ValueKind == JsonValueKind.Array ? doc.RootElement.EnumerateArray().ToArray() : [doc.RootElement];
  foreach (var row in rows)
  {
   if (row.ValueKind != JsonValueKind.Object) continue;
   string? Text(string name) => row.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
   if (!row.TryGetProperty("ProcessId", out var pid) || pid.ValueKind != JsonValueKind.Number) continue;
   if (!row.TryGetProperty("StartTicks", out var ticks) || ticks.ValueKind != JsonValueKind.Number) continue;
   if (IsOwnEngine(root, Text("ExecutablePath"), Text("CommandLine"))) found.Add(new Candidate(pid.GetInt32(), ticks.GetInt64()));
  }
  return found;
 }
 // Same process, not a reused process id: the start times agree (CIM keeps microseconds).
 internal static bool SameStart(long expectedTicks, long actualTicks) => Math.Abs(expectedTicks - actualTicks) <= 20_000;

 internal static void StopOwnLaunchers(string root)
 {
  var currentPid = Environment.ProcessId;
  foreach (var proc in Process.GetProcessesByName("ArkuzoMemorySaver"))
  {
   using (proc)
   {
    try
    {
     if (proc.Id == currentPid || !IsOwnLauncher(root, proc.MainModule?.FileName)) continue;
     proc.Kill(); proc.WaitForExit(3000);
    }
    catch { }
   }
  }
 }
 internal static void StopOwnEngines(string root)
 {
  var query = new ProcessStartInfo(ControllerTakeoverPaths.PowerShell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
  query.ArgumentList.Add("-NoProfile"); query.ArgumentList.Add("-NonInteractive"); query.ArgumentList.Add("-Command");
  // Read-only: list PowerShell processes; the decision and the kill happen here, per exact process.
  query.ArgumentList.Add("$ErrorActionPreference='Stop'; @(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe' OR Name='pwsh.exe'\" | ForEach-Object { [pscustomobject]@{ ProcessId=[int]$_.ProcessId; ExecutablePath=[string]$_.ExecutablePath; CommandLine=[string]$_.CommandLine; StartTicks=[long]$_.CreationDate.ToUniversalTime().Ticks } }) | ConvertTo-Json -Compress -Depth 3");
  string output;
  using (var child = Process.Start(query) ?? throw new InvalidOperationException("Cannot list processes."))
  {
   var read = child.StandardOutput.ReadToEndAsync(); _ = child.StandardError.ReadToEndAsync();
   if (!child.WaitForExit(6000)) { try { child.Kill(); } catch { } return; }
   if (child.ExitCode != 0) return;
   output = read.GetAwaiter().GetResult();
  }
  foreach (var candidate in OwnEngines(root, output))
  {
   if (candidate.Pid == Environment.ProcessId) continue;
   try
   {
    using var proc = Process.GetProcessById(candidate.Pid);
    if (!SameStart(candidate.StartTicks, proc.StartTime.ToUniversalTime().Ticks)) continue;
    proc.Kill(); proc.WaitForExit(2000);
   }
   catch { }
  }
 }
}
