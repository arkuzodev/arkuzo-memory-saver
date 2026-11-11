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
    // What was current before the last update (same schema as the pointers), so --rollback can go back
    // to it, and the version a rollback left, which the updater skips until a newer release appears.
    string PreviousPointer => Path.Combine(root,"app","previous.json");
    string ControlCenterPreviousPointer => Path.Combine(root,"app","control-center.previous.json");
    string SkippedPointer => Path.Combine(root,"app","skipped-version.json");
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
                // Repair in place. Anything that does not belong (a stray file or folder) would fail
                // validation on every start, so it is removed; links are never followed.
                foreach (var entry in Directory.GetFileSystemEntries(target))
                {
                    if (names.Contains(Path.GetFileName(entry), StringComparer.Ordinal) && File.Exists(entry)) continue;
                    var attributes = File.GetAttributes(entry);
                    if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Reparse points are not allowed in launcher storage.");
                    if ((attributes & FileAttributes.Directory) != 0) Directory.Delete(entry, true);
                    else { File.SetAttributes(entry, FileAttributes.Normal); File.Delete(entry); }
                }
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
            var before=ReadPointerOrNull(Pointer,RuntimePackage.Files);
            if (before is not null && before.Version!=installed.Version) WritePointer(PreviousPointer,before);
            WritePointer(Pointer,installed);
        }
        finally { if(Directory.Exists(stage)) Directory.Delete(stage,true); }
        var validated=Validate();
        if (addon is { } verified) InstallControlCenter(validated,verified.Hash,verified.Files);
        if (SkippedVersion is { } skipped && skipped!=validated.Version) { SafePath(SkippedPointer); File.Delete(SkippedPointer); }
        PruneOldVersions();
        return validated;
    }
    Installed? ReadPointerOrNull(string pointer,string[] names)
    {
        try { return File.Exists(pointer) ? ReadPointer(pointer,names) : null; }
        catch (InvalidDataException) { return null; }
    }
    // The release a rollback left behind; null when there is none (or the file is unreadable).
    public string? SkippedVersion
    {
        get
        {
            try {
                SafePath(SkippedPointer);
                if (!File.Exists(SkippedPointer) || new FileInfo(SkippedPointer).Length>4096) return null;
                using var doc=JsonDocument.Parse(File.ReadAllBytes(SkippedPointer));
                var version=doc.RootElement.GetProperty("Version").GetString() ?? "";
                ParseVersion(version);
                return version;
            } catch (Exception ex) when (ex is JsonException or InvalidDataException or KeyNotFoundException or InvalidOperationException or IOException) { return null; }
        }
    }
    // Keeps the version folders named by the current and the previous pointers (runtime and add-on) and
    // removes every other stable-version folder under app/versions and app/control-center. Best effort:
    // anything that is not a plain version folder, or cannot be removed now, is left alone.
    public List<string> PruneOldVersions()
    {
        var removed=new List<string>();
        var keep=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (pointer,names) in new[]{(Pointer,RuntimePackage.Files),(PreviousPointer,RuntimePackage.Files),(ControlCenterPointer,ControlCenterLayout),(ControlCenterPreviousPointer,ControlCenterLayout)})
            if (ReadPointerOrNull(pointer,names) is { } known) keep.Add(known.Version);
        if (keep.Count==0) return removed;
        foreach (var folder in new[]{Path.Combine(root,"app","versions"),Path.Combine(root,"app","control-center")})
        {
            try {
                SafePath(folder);
                if (!Directory.Exists(folder)) continue;
                foreach (var dir in Directory.GetDirectories(folder))
                {
                    var name=Path.GetFileName(dir);
                    try { ParseVersion(name); } catch (InvalidDataException) { continue; }
                    if (keep.Contains(name) || (File.GetAttributes(dir)&FileAttributes.ReparsePoint)!=0) continue;
                    try { Directory.Delete(dir,true); removed.Add(dir); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                }
            } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException) { }
        }
        return removed;
    }
    // Makes the previous version current again, after checking its files, and skips the version it
    // replaces until a newer release is published. Throws when there is no valid previous version.
    public Installed Rollback()
    {
        SafePath(PreviousPointer);
        if (!File.Exists(PreviousPointer)) throw new InvalidDataException("There is no previous version to roll back to.");
        var previous=ReadPointer(PreviousPointer,RuntimePackage.Files);
        ValidateFiles(RuntimePath(previous),previous,RuntimePackage.Files);
        var addon=ReadPointerOrNull(ControlCenterPreviousPointer,ControlCenterLayout);
        if (addon is not null && (addon.Version!=previous.Version || !RuntimePackage.Files.All(x=>addon.Files[x]==previous.Files[x]))) addon=null;
        if (addon is not null) {
            try { ValidateFiles(ControlCenterPath(previous),addon,ControlCenterLayout); }
            catch (InvalidDataException) { addon=null; }
        }
        var current=ReadPointerOrNull(Pointer,RuntimePackage.Files);
        if (current is not null && ParseVersion(current.Version)>ParseVersion(previous.Version))
        {
            SafePath(SkippedPointer);
            var temp=SkippedPointer+"."+Guid.NewGuid().ToString("N")+".tmp";
            try {
                File.WriteAllBytes(temp,JsonSerializer.SerializeToUtf8Bytes(new { Version=current.Version }));
                File.Move(temp,SkippedPointer,true);
            } finally { if(File.Exists(temp)) File.Delete(temp); }
        }
        WritePointer(Pointer,previous);
        if (addon is not null) WritePointer(ControlCenterPointer,addon);
        File.Delete(PreviousPointer);
        if (File.Exists(ControlCenterPreviousPointer)) File.Delete(ControlCenterPreviousPointer);
        return Validate();
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
        var before=ReadPointerOrNull(ControlCenterPointer,ControlCenterLayout);
        if (before is not null && before.Version!=installed.Version) WritePointer(ControlCenterPreviousPointer,before);
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
