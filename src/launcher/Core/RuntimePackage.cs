using System.Security.Cryptography;
using System.Text.RegularExpressions;
namespace Launcher;
public static class RuntimePackage
{
    public static readonly string[] Files = ["Arkuzo-Memory-Saver.ps1", "Arkuzo-Volt-Control.ps1", "Arkuzo-Volt-Probe.py", "defaults.json"];
    public const int Limit = 16 * 1024 * 1024;
    public static Dictionary<string, byte[]> Unpack(byte[] zip)
    {
        if (zip.Length > Limit) throw new InvalidDataException("Runtime archive exceeds 16 MB.");
        using var input = new MemoryStream(zip, false);
        using var archive = new System.IO.Compression.ZipArchive(input, System.IO.Compression.ZipArchiveMode.Read);
        if (archive.Entries.Count != Files.Length) throw new InvalidDataException("Runtime must contain exactly four root files.");
        var result = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        long total = 0;
        foreach (var entry in archive.Entries)
        {
            var unixType = (entry.ExternalAttributes >> 16) & 0xF000;
            if (!Files.Contains(entry.FullName, StringComparer.Ordinal) || result.ContainsKey(entry.FullName) ||
                (unixType != 0 && unixType != 0x8000) || (entry.ExternalAttributes & 0x410) != 0)
                throw new InvalidDataException("Unsafe or unexpected runtime ZIP entry.");
            if (entry.Length < 0 || entry.Length > Limit || (total += entry.Length) > Limit)
                throw new InvalidDataException("Expanded runtime exceeds 16 MB.");
            using var stream = entry.Open();
            using var output = new MemoryStream();
            var buffer = new byte[81920];
            int n;
            while ((n = stream.Read(buffer)) != 0)
            {
                if (output.Length + n > entry.Length) throw new InvalidDataException("ZIP length mismatch.");
                output.Write(buffer, 0, n);
            }
            if (output.Length != entry.Length) throw new InvalidDataException("Truncated ZIP entry.");
            result.Add(entry.FullName, output.ToArray());
        }
        return result;
    }
    public static string CheckHash(byte[] zip, string checksum, string? digest = null)
    {
        var match = Regex.Match(checksum.Trim(), @"\A([a-fA-F0-9]{64})(?:\s+\*?ArkuzoMemorySaver-runtime\.zip)?\z");
        if (!match.Success) throw new InvalidDataException("Invalid runtime checksum file.");
        var hash = Convert.ToHexStringLower(SHA256.HashData(zip));
        if (!hash.Equals(match.Groups[1].Value, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Runtime SHA-256 mismatch.");
        if (digest is not null && !digest.Equals("sha256:" + hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("GitHub asset digest mismatch.");
        return hash;
    }
}