using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace Launcher;
public sealed record ReleasePayload(string Version, byte[] Zip, string Checksum, string? Digest=null);
public sealed record Installed(string Version, string ZipSha256, Dictionary<string,string> Files);
public sealed class Installation(string root)
{
    string Pointer => Path.Combine(root,"app","current.json");
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
    Installed ReadPointer()
    {
        SafePath(Pointer);
        if (!File.Exists(Pointer) || new FileInfo(Pointer).Length>16384) throw new InvalidDataException("No known-good local runtime is installed.");
        try {
            var installed=JsonSerializer.Deserialize<Installed>(File.ReadAllBytes(Pointer)) ?? throw new InvalidDataException("Invalid install metadata.");
            ParseVersion(installed.Version);
            if (installed.Files is null || installed.Files.Count!=4 || !RuntimePackage.Files.All(installed.Files.ContainsKey) ||
                !Regex.IsMatch(installed.ZipSha256 ?? "",@"\A[a-f0-9]{64}\z")) throw new InvalidDataException("Invalid install metadata.");
            return installed;
        } catch (JsonException ex) { throw new InvalidDataException("Invalid install metadata.",ex); }
    }
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
        var installed=ReadPointer(); ValidateFiles(installed); return installed;
    }
    void ValidateFiles(Installed installed)
    {
        var path=RuntimePath(installed); SafePath(path);
        if (!Directory.Exists(path) || Directory.GetFileSystemEntries(path).Length!=4) throw new InvalidDataException("Runtime files are missing or unexpected.");
        long total=0;
        foreach(var name in RuntimePackage.Files)
        {
            var file=Path.Combine(path,name); SafePath(file);
            if (!File.Exists(file) || (total+=new FileInfo(file).Length)>RuntimePackage.Limit) throw new InvalidDataException("Runtime file is missing or oversized.");
            if (!Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file))).Equals(installed.Files[name],StringComparison.Ordinal))
                throw new InvalidDataException("Cached runtime hash mismatch: "+name);
        }
    }
    public Installed Install(ReleasePayload release)
    {
        var incoming=ParseVersion(release.Version); SafePath(Pointer);
        if (File.Exists(Pointer) && incoming<ParseVersion(ReadPointer().Version)) throw new InvalidDataException("Refusing release downgrade.");
        var hash=RuntimePackage.CheckHash(release.Zip,release.Checksum,release.Digest);
        var files=RuntimePackage.Unpack(release.Zip);
        var installed=new Installed(release.Version,hash,files.ToDictionary(x=>x.Key,x=>Convert.ToHexStringLower(SHA256.HashData(x.Value))));
        var target=RuntimePath(installed); SafePath(target);
        var versions=Path.GetDirectoryName(target)!; Directory.CreateDirectory(versions);
        var stage=Path.Combine(versions,".stage-"+Guid.NewGuid().ToString("N"));
        try
        {
            if (Directory.Exists(target))
            {
                try { ValidateFiles(installed); }
                catch (InvalidDataException)
                {
                    foreach (var file in files) File.WriteAllBytes(Path.Combine(target, file.Key), file.Value);
                    ValidateFiles(installed);
                }
            }
            else
            {
                Directory.CreateDirectory(stage);
                foreach(var file in files) File.WriteAllBytes(Path.Combine(stage,file.Key),file.Value);
                Directory.Move(stage,target);
            }
            var config=Path.Combine(root,"data","config.json"); SafePath(config);
            Directory.CreateDirectory(Path.GetDirectoryName(config)!);
            if (!File.Exists(config))
            {
                var configTemp=config+"."+Guid.NewGuid().ToString("N")+".tmp";
                try { var legacy=Path.Combine(root,"config.json"); SafePath(legacy); if(File.Exists(legacy)) File.Copy(legacy,configTemp,false); else File.WriteAllBytes(configTemp,files["defaults.json"]); File.Move(configTemp,config,false); }
                finally { if(File.Exists(configTemp)) File.Delete(configTemp); }
            }
            var pointerTemp=Pointer+"."+Guid.NewGuid().ToString("N")+".tmp";
            try
            {
                using(var stream=new FileStream(pointerTemp,FileMode.CreateNew,FileAccess.Write,FileShare.None))
                { JsonSerializer.Serialize(stream,installed); stream.Flush(true); }
                if(File.Exists(Pointer)) File.Replace(pointerTemp,Pointer,null); else File.Move(pointerTemp,Pointer);
            }
            finally { if(File.Exists(pointerTemp)) File.Delete(pointerTemp); }
            return Validate();
        }
        finally { if(Directory.Exists(stage)) Directory.Delete(stage,true); }
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
}
