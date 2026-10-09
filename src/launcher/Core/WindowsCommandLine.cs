using System.Runtime.InteropServices;
namespace Launcher;
internal static class WindowsCommandLine
{
 [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern IntPtr CommandLineToArgvW(string commandLine,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
 internal static string[] Parse(string commandLine)
 {
  if(string.IsNullOrWhiteSpace(commandLine) || commandLine[0]==' ' || commandLine.Contains('\0')) return [];
  // Native parsing accepts unterminated quotes; takeover must reject ambiguous input.
  bool quoted=false;int slashes=0;
  foreach(var ch in commandLine) {
   if(ch=='\\') {slashes++;continue;}
   if(ch=='"' && slashes%2==0) quoted=!quoted;
   slashes=0;
  }
  if(quoted) return [];
  var memory=CommandLineToArgvW(commandLine,out var count);
  if(memory==IntPtr.Zero) return [];
  try {
   var args=new string[count];
   for(int i=0;i<count;i++) args[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size)) ?? "";
   return args;
  } finally {LocalFree(memory);}
 }
}
