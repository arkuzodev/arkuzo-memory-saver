using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace Launcher;
public sealed record AddonPayload(byte[] Zip, string Checksum, string? Digest=null);
public sealed record ReleasePayload(string Version, byte[] Zip, string Checksum, string? Digest=null, AddonPayload? ControlCenter=null);
public sealed record Installed(string Version, string ZipSha256, Dictionary<string,string> Files);
public sealed class Installation(string root)
{
    string Pointer => Path.Combine(root,"app","current.json");
    // The add-on lives beside, never inside, app/versions and current.json, so an older launcher
    // pointed at the same folder still sees exactly the four-file layout it validates.
    string ControlCenterPointer => Path.Combine(root,"app","control-center.json");
    public static readonly string[] ControlCenterLayout = [..RuntimePackage.Files, ..RuntimePackage.ControlCenterFiles];
    public static Version ParseVersion(string value)
    {
        if (!Regex.IsMatch(value,@"\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z") || !Version.TryParse(value[1..],out var version))
            throw new InvalidDataException("Release tag must be stable vMAJOR.MINOR.PATCH.");
        return version;
    }
    public static void SafePath(string path)
    {
        var current=Path.GetFullPath(path);
        while (!string.IsNullOrEmpty(current))
        {
            if ((File.Exists(current)||Directory.Exists(current)) && (File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)
                throw new InvalidDataException("Reparse points are not allowed in launcher storage.");
            current=Path.GetDirectoryName(current);
        }
    }
    static Installed ReadPointer(string pointer,string[] names)
    {
        SafePath(pointer);
        if (!File.Exists(pointer) || new FileInfo(pointer).Length>16384) throw new InvalidDataException("No known-good local runtime is installed.");
        try {
            var installed=JsonSerializer.Deserialize<Installed>(File.ReadAllBytes(pointer)) ?? throw new InvalidDataException("Invalid install metadata.");
            ParseVersion(installed.Version);
            if (installed.Files is null || installed.Files.Count!=names.Length || !names.All(installed.Files.ContainsKey) ||
                !Regex.IsMatch(installed.ZipSha256 ?? "",@"\A[a-f0-9]{64}\z")) throw new InvalidDataException("Invalid install metadata.");
            return installed;
        } catch (JsonException ex) { throw new InvalidDataException("Invalid install metadata.",ex); }
    }
    Installed ReadPointer() => ReadPointer(Pointer,RuntimePackage.Files);
    public bool TryGetInstalled(out Installed installed)
    {
        try {
            installed = ReadPointer();
            return true;
        } catch {
            installed = null!;
            return false;
        }
    }
    public Installed Validate()
    {
        var installed=ReadPointer(); ValidateFiles(RuntimePath(installed),installed,RuntimePackage.Files); return installed;
    }
    static void ValidateFiles(string path,Installed installed,string[] names)
    {
        SafePath(path);
        if (!Directory.Exists(path) || Directory.GetFileSystemEntries(path).Length!=names.Length) throw new InvalidDataException("Runtime files are missing or unexpected.");
        long total=0;
        foreach(var name in names)
        {
            var file=Path.Combine(path,name); SafePath(file);
            if (!File.Exists(file) || (total+=new FileInfo(file).Length)>RuntimePackage.Limit) throw new InvalidDataException("Runtime file is missing or oversized.");
            if (!Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file))).Equals(installed.Files[name],StringComparison.Ordinal))
                throw new InvalidDataException("Cached runtime hash mismatch: "+name);
        }
    }
    static void WriteFiles(string target,string stage,Installed installed,Dictionary<string,byte[]> files,string[] names)
    {
        if (Directory.Exists(target))
        {
            try { ValidateFiles(target,installed,names); }
            catch (InvalidDataException)
            {
                foreach (var file in files) File.WriteAllBytes(Path.Combine(target, file.Key), file.Value);
                ValidateFiles(target,installed,names);
            }
        }
        else
        {
            Directory.CreateDirectory(stage);
            foreach(var file in files) File.WriteAllBytes(Path.Combine(stage,file.Key),file.Value);
            Directory.Move(stage,target);
        }
    }
    static void WritePointer(string pointer,Installed installed)
    {
        var pointerTemp=pointer+"."+Guid.NewGuid().ToString("N")+".tmp";
        try
        {
            using(var stream=new FileStream(pointerTemp,FileMode.CreateNew,FileAccess.Write,FileShare.None))
            { JsonSerializer.Serialize(stream,installed); stream.Flush(true); }
            if(File.Exists(pointer)) File.Replace(pointerTemp,pointer,null); else File.Move(pointerTemp,pointer);
        }
        finally { if(File.Exists(pointerTemp)) File.Delete(pointerTemp); }
    }
    static Dictionary<string,string> Hashes(Dictionary<string,byte[]> files) => files.ToDictionary(x=>x.Key,x=>Convert.ToHexStringLower(SHA256.HashData(x.Value)));
    static (string Hash,Dictionary<string,byte[]> Files) VerifyAddon(AddonPayload addon) =>
        (RuntimePackage.CheckHash(addon.Zip,addon.Checksum,addon.Digest,RuntimePackage.ControlCenterZipName),RuntimePackage.Unpack(addon.Zip,RuntimePackage.ControlCenterFiles));
    public Installed Install(ReleasePayload release)
    {
        var incoming=ParseVersion(release.Version); SafePath(Pointer);
        if (File.Exists(Pointer) && incoming<ParseVersion(ReadPointer().Version)) throw new InvalidDataException("Refusing release downgrade.");
        var hash=RuntimePackage.CheckHash(release.Zip,release.Checksum,release.Digest);
        var files=RuntimePackage.Unpack(release.Zip);
        // A corrupt add-on blocks the whole update before anything is written.
        var addon=release.ControlCenter is null ? ((string Hash,Dictionary<string,byte[]> Files)?)null : VerifyAddon(release.ControlCenter);
        var installed=new Installed(release.Version,hash,Hashes(files));
        var target=RuntimePath(installed); SafePath(target);
        var versions=Path.GetDirectoryName(target)!; Directory.CreateDirectory(versions);
        var stage=Path.Combine(versions,".stage-"+Guid.NewGuid().ToString("N"));
        try
        {
            WriteFiles(target,stage,installed,files,RuntimePackage.Files);
            var config=Path.Combine(root,"data","config.json"); SafePath(config);
            Directory.CreateDirectory(Path.GetDirectoryName(config)!);
            if (!File.Exists(config))
            {
                var configTemp=config+"."+Guid.NewGuid().ToString("N")+".tmp";
                try { var legacy=Path.Combine(root,"config.json"); SafePath(legacy); if(File.Exists(legacy)) File.Copy(legacy,configTemp,false); else File.WriteAllBytes(configTemp,files["defaults.json"]); File.Move(configTemp,config,false); }
                finally { if(File.Exists(configTemp)) File.Delete(configTemp); }
            }
            WritePointer(Pointer,installed);
        }
        finally { if(Directory.Exists(stage)) Directory.Delete(stage,true); }
        var validated=Validate();
        if (addon is { } verified) InstallControlCenter(validated,verified.Hash,verified.Files);
        return validated;
    }
    public Installed InstallControlCenter(ReleasePayload release,Installed core)
    {
        if (release.ControlCenter is null || release.Version!=core.Version) throw new InvalidDataException("Control Center add-on does not belong to the installed runtime.");
        var (hash,files)=VerifyAddon(release.ControlCenter);
        return InstallControlCenter(core,hash,files);
    }
    Installed InstallControlCenter(Installed core,string hash,Dictionary<string,byte[]> addon)
    {
        // The Control Center starts the engine next to itself, so its folder carries verified copies of the core files.
        var files=new Dictionary<string,byte[]>(addon,StringComparer.Ordinal);
        foreach (var name in RuntimePackage.Files)
        {
            var source=Path.Combine(RuntimePath(core),name); SafePath(source);
            var bytes=File.ReadAllBytes(source);
            if (!Convert.ToHexStringLower(SHA256.HashData(bytes)).Equals(core.Files[name],StringComparison.Ordinal)) throw new InvalidDataException("Cached runtime hash mismatch: "+name);
            files.Add(name,bytes);
        }
        var installed=new Installed(core.Version,hash,Hashes(files));
        var target=ControlCenterPath(core); SafePath(target); SafePath(ControlCenterPointer);
        var parent=Path.GetDirectoryName(target)!; Directory.CreateDirectory(parent);
        var stage=Path.Combine(parent,".stage-"+Guid.NewGuid().ToString("N"));
        try { WriteFiles(target,stage,installed,files,ControlCenterLayout); }
        finally { if(Directory.Exists(stage)) Directory.Delete(stage,true); }
        WritePointer(ControlCenterPointer,installed);
        return ValidateControlCenter(core) ?? throw new InvalidDataException("Control Center add-on failed validation.");
    }
    // Null when no add-on is installed for this exact runtime version; a stale add-on never runs a newer engine.
    public Installed? ValidateControlCenter(Installed core)
    {
        SafePath(ControlCenterPointer);
        if (!File.Exists(ControlCenterPointer)) return null;
        var installed=ReadPointer(ControlCenterPointer,ControlCenterLayout);
        if (installed.Version!=core.Version) return null;
        if (!RuntimePackage.Files.All(x=>installed.Files[x]==core.Files[x])) throw new InvalidDataException("Control Center add-on does not match the installed runtime.");
        ValidateFiles(ControlCenterPath(core),installed,ControlCenterLayout);
        return installed;
    }
    public bool HasValidControlCenter(Installed core)
    {
        try { return ValidateControlCenter(core) is not null; }
        catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException) { return false; }
    }
    public void InitializeData()
    {
        var installed=Validate();
        var config=Path.Combine(root,"data","config.json"); SafePath(config);
        if(File.Exists(config)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(config)!);
        var temp=config+"."+Guid.NewGuid().ToString("N")+".tmp";
        try { var legacy=Path.Combine(root,"config.json"); SafePath(legacy); File.Copy(File.Exists(legacy)?legacy:Path.Combine(RuntimePath(installed),"defaults.json"),temp,false); File.Move(temp,config,false); }
        finally {if(File.Exists(temp)) File.Delete(temp);}
    }
    public string RuntimePath(Installed installed) => Path.Combine(root,"app","versions",installed.Version);
    public string ControlCenterPath(Installed core) => Path.Combine(root,"app","control-center",core.Version);
}
