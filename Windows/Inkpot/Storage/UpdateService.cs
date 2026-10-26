using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;

namespace Inkpot.Storage;

public sealed record AvailableUpdate(string Tag, string? DownloadedPath);

public static class UpdateService
{
    public const string DownloadPage = "https://github.com/funny-dog/inkpot/releases/latest";
    private const int MaxSize = 200 * 1024 * 1024;
    private static readonly HttpClient Client = new(new HttpClientHandler { UseCookies = false }) { Timeout = TimeSpan.FromMinutes(5) };

    public static async Task<AvailableUpdate?> CheckAsync(string current, string cache, bool download, CancellationToken cancellation = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/funny-dog/inkpot/releases/latest");
        request.Headers.UserAgent.ParseAdd("Inkpot/" + current);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        using var response = await Client.SendAsync(request, cancellation);
        response.EnsureSuccessStatusCode();
        using var release = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellation));
        var root = release.RootElement;
        string tag = root.GetProperty("tag_name").GetString()!;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) throw new IOException("Invalid release.");
        if (!IsNewer(tag, current)) return null;
        if (!download) return new(tag, null);
        var assets = root.GetProperty("assets").EnumerateArray().ToArray();
        // A release must explicitly publish a Windows archive and its checksum. Never download a Mac asset.
        var archive = assets.FirstOrDefault(asset => asset.GetProperty("name").GetString() == "Inkpot-windows-x64.zip");
        var checksum = assets.FirstOrDefault(asset => asset.GetProperty("name").GetString() == "Inkpot-windows-x64.zip.sha256");
        if (archive.ValueKind == JsonValueKind.Undefined || checksum.ValueKind == JsonValueKind.Undefined) return new(tag, null);
        string AssetUrl(JsonElement asset, long maximum)
        {
            long size = asset.GetProperty("size").GetInt64();
            string name = asset.GetProperty("name").GetString()!;
            string url = asset.GetProperty("browser_download_url").GetString()!;
            if (size < 1 || size > maximum || url != $"https://github.com/funny-dog/inkpot/releases/download/{tag}/{name}") throw new IOException("Invalid update asset.");
            return url;
        }
        string archiveUrl = AssetUrl(archive, MaxSize), checksumUrl = AssetUrl(checksum, 4096);
        string digest = (await Client.GetStringAsync(checksumUrl, cancellation)).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)[0];
        if (digest.Length != 64 || !digest.All(Uri.IsHexDigit)) throw new IOException("Invalid SHA-256 checksum.");
        Directory.CreateDirectory(cache);
        string destination = Path.Combine(cache, "Inkpot-windows-x64.zip");
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using var package = await Client.GetAsync(archiveUrl, HttpCompletionOption.ResponseHeadersRead, cancellation);
            package.EnsureSuccessStatusCode();
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                using var input = await package.Content.ReadAsStreamAsync(cancellation);
                byte[] buffer = new byte[65536]; int read;
                while ((read = await input.ReadAsync(buffer, cancellation)) > 0)
                {
                    if (output.Length + read > MaxSize) throw new IOException("Update exceeds size limit.");
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellation);
                }
                await output.FlushAsync(cancellation);
            }
            using (var input = File.OpenRead(temporary))
                if (input.Length != archive.GetProperty("size").GetInt64() || !Convert.ToHexString(await SHA256.HashDataAsync(input, cancellation)).Equals(digest, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Update checksum mismatch / 安装包校验失败。");
            File.Move(temporary, destination, true);
            return new(tag, destination);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static bool IsNewer(string tag, string current)
    {
        static Version Parse(string value)
        {
            value = value.StartsWith('v') ? value[1..] : value;
            var parts = value.Split('.');
            if (parts.Length != 3 || parts.Any(part => part.Length == 0 || !part.All(char.IsAsciiDigit) || (part.Length > 1 && part[0] == '0')) || !Version.TryParse(value, out var version))
                throw new IOException("Invalid release version.");
            return version;
        }
        return Parse(tag) > Parse(current);
    }
}
