using System.Net;

namespace Inkpot.Storage;

public sealed record ImageBytes(byte[] Bytes, string Mime);

public static class ImageStorage
{
    public const int MaximumBytes = 20 * 1024 * 1024;
    private static readonly HttpClient Client = new(new HttpClientHandler { UseCookies = false, UseDefaultCredentials = false, AllowAutoRedirect = false })
        { Timeout = TimeSpan.FromSeconds(15) };

    public static string ResolveLocal(string destination, string? document)
    {
        if (destination.StartsWith("//", StringComparison.Ordinal)) throw new IOException("Unsupported image path.");
        if (Uri.TryCreate(destination, UriKind.Absolute, out var uri) && !Path.IsPathFullyQualified(destination))
        {
            if (!uri.IsFile) throw new IOException("Unsupported image scheme.");
            return uri.LocalPath;
        }
        destination = Uri.UnescapeDataString(destination);
        if (Path.IsPathFullyQualified(destination)) return Path.GetFullPath(destination);
        if (document is null) throw new IOException("Save the document before using relative images.");
        return Path.GetFullPath(destination, Path.GetDirectoryName(Path.GetFullPath(document))!);
    }

    public static async Task<ImageBytes> ReadAsync(string destination, string? document, bool remote, CancellationToken cancellation = default)
    {
        byte[] bytes;
        if (Uri.TryCreate(destination, UriKind.Absolute, out var uri) && uri.Scheme == "https")
        {
            if (!remote) throw new IOException("Remote images are disabled.");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            bytes = await DownloadAsync(uri, timeout.Token);
        }
        else
        {
            string path = ResolveLocal(destination, document);
            using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, true);
            if (input.Length > MaximumBytes) throw new IOException("Image exceeds 20 MB.");
            bytes = new byte[input.Length];
            await input.ReadExactlyAsync(bytes, cancellation);
        }
        return new(bytes, Mime(bytes));
    }

    private static async Task<byte[]> DownloadAsync(Uri uri, CancellationToken cancellation)
    {
        for (int redirect = 0; redirect <= 4; redirect++)
        {
            if (uri.Scheme != "https" || uri.UserInfo != "") throw new IOException("Only credential-free HTTPS images are supported.");
            using var response = await Client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } location)
            { uri = new Uri(uri, location); continue; }
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > MaximumBytes) throw new IOException("Image exceeds 20 MB.");
            using var input = await response.Content.ReadAsStreamAsync(cancellation);
            using var output = new MemoryStream();
            byte[] buffer = new byte[16384];
            int read;
            while ((read = await input.ReadAsync(buffer, cancellation)) > 0)
            {
                if (output.Length + read > MaximumBytes) throw new IOException("Image exceeds 20 MB.");
                await output.WriteAsync(buffer.AsMemory(0, read), cancellation);
            }
            return output.ToArray();
        }
        throw new IOException("Too many image redirects.");
    }

    public static string Mime(ReadOnlySpan<byte> bytes)
    {
        if (bytes.StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return "image/png";
        if (bytes.StartsWith(new byte[] { 255, 216, 255 })) return "image/jpeg";
        if (bytes.StartsWith("GIF87a"u8) || bytes.StartsWith("GIF89a"u8)) return "image/gif";
        if (bytes.Length >= 12 && bytes[..4].SequenceEqual("RIFF"u8) && bytes.Slice(8, 4).SequenceEqual("WEBP"u8)) return "image/webp";
        if (bytes.StartsWith("BM"u8)) return "image/bmp";
        if (bytes.StartsWith(new byte[] { 73, 73, 42, 0 }) || bytes.StartsWith(new byte[] { 77, 77, 0, 42 })) return "image/tiff";
        throw new IOException("Unsupported bitmap image / 不支持此图片格式。");
    }

    public static async Task<string> ImportAsync(byte[] bytes, string document, Preferences preferences)
    {
        string extension = Mime(bytes) switch { "image/jpeg" => ".jpg", "image/gif" => ".gif", "image/webp" => ".webp", "image/bmp" => ".bmp", "image/tiff" => ".tiff", _ => ".png" };
        if (bytes.Length > MaximumBytes) throw new IOException("Image exceeds 20 MB.");
        string parent = Path.GetDirectoryName(Path.GetFullPath(document))!;
        string directory = preferences.DocumentImageFolder ? Path.Combine(parent, Path.GetFileNameWithoutExtension(document) + ".assets")
            : preferences.ImageFolder is { Length: > 0 } custom ? Path.GetFullPath(custom) : Path.Combine(parent, "assets");
        if (Directory.Exists(directory) && !FolderIndex.IsSafeEntry(directory)) throw new IOException("Image assets folder cannot be a symbolic link.");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "image-" + Guid.NewGuid().ToString("N") + extension);
        await using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { await file.WriteAsync(bytes); }
        return Path.GetRelativePath(parent, path).Replace('\\', '/').Replace("%", "%25").Replace(" ", "%20").Replace("(", "%28").Replace(")", "%29").Replace("#", "%23");
    }
}
