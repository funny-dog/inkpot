using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace Inkpot.Storage;

public sealed record FolderEntry(string Path, bool IsDirectory)
{
    public string Name => System.IO.Path.GetFileName(Path);
}
public sealed record FolderMatch(string Path, int Line, int Column, int Length, string Preview);

public static partial class FolderIndex
{
    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase) { ".md", ".markdown", ".txt" };
    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff" };
    private static readonly HashSet<string> IgnoredSearchDirectories = new(StringComparer.OrdinalIgnoreCase) { "node_modules", "build", "DerivedData", "Pods", "target", "dist", "bin", "obj" };
    private static readonly System.Text.UTF8Encoding StrictUtf8 = new(false, true);

    public static bool IsText(string path) => TextExtensions.Contains(Path.GetExtension(path));
    public static bool IsImage(string path) => ImageExtensions.Contains(Path.GetExtension(path));
    public static bool IsSafeEntry(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
    public static List<FolderEntry> Children(string folder, bool allFiles, bool hidden)
    {
        return new DirectoryInfo(folder).EnumerateFileSystemInfos()
            .Where(entry => (entry.Attributes & FileAttributes.ReparsePoint) == 0
                && (hidden || ((entry.Attributes & FileAttributes.Hidden) == 0 && !entry.Name.StartsWith('.')))
                && (entry is DirectoryInfo || allFiles || IsText(entry.FullName)))
            .Select(entry => new FolderEntry(entry.FullName, entry is DirectoryInfo))
            .OrderByDescending(entry => entry.IsDirectory).ThenBy(entry => entry.Name, NaturalComparer.Instance).ToList();
    }
    public static async Task SearchAsync(string folder, string query, bool hidden, Action<FolderMatch> found, CancellationToken cancellation)
    {
        if (string.IsNullOrEmpty(query)) return;
        int count = 0;
        var pending = new Stack<string>(); pending.Push(folder);
        while (pending.TryPop(out var current))
        {
            cancellation.ThrowIfCancellationRequested();
            List<FolderEntry> entries;
            try { entries = Children(current, false, hidden); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
            var subDirectories = new List<string>();
            foreach (var entry in entries)
            {
                cancellation.ThrowIfCancellationRequested();
                if (entry.IsDirectory)
                {
                    if (!IgnoredSearchDirectories.Contains(entry.Name)) subDirectories.Add(entry.Path);
                    continue;
                }
                // Match the Mac search limit: skip huge files, avoid unnecessary SHA-256 hashing during search, stop at 1000 matches.
                string text;
                try
                {
                    if (new FileInfo(entry.Path).Length > 5 * 1024 * 1024) continue;
                    byte[] raw = await File.ReadAllBytesAsync(entry.Path, cancellation);
                    int offset = raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF ? 3 : 0;
                    text = StrictUtf8.GetString(raw, offset, raw.Length - offset);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Text.DecoderFallbackException) { continue; }
                if (text.IndexOf(query, StringComparison.OrdinalIgnoreCase) < 0) continue;
                int line = 0;
                using var reader = new StringReader(text);
                while (reader.ReadLine() is { } value)
                {
                    cancellation.ThrowIfCancellationRequested(); line++;
                    int from = 0;
                    while (value.IndexOf(query, from, StringComparison.OrdinalIgnoreCase) is int index && index >= 0)
                    {
                        found(new(entry.Path, line, index, query.Length, value.Length > 220 ? value.Substring(Math.Max(0, index - 30), Math.Min(220, value.Length - Math.Max(0, index - 30))) : value));
                        if (++count >= 1000) return;
                        from = index + query.Length;
                    }
                }
            }
            // 反向压栈使子目录保持与文件树一致的自然顺序遍历。
            for (int index = subDirectories.Count - 1; index >= 0; index--) pending.Push(subDirectories[index]);
        }
    }
    public static string ChildPath(string folder, string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name != Path.GetFileName(name) || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || name.EndsWith('.') || name.EndsWith(' ') || ReservedName().IsMatch(name)) throw new IOException("Invalid file name / 文件名无效。");
        return Path.Combine(Path.GetFullPath(folder), name);
    }
    [GeneratedRegex(@"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase)]
    private static partial Regex ReservedName();
    private sealed class NaturalComparer : IComparer<string>
    {
        internal static readonly NaturalComparer Instance = new();
        public int Compare(string? left, string? right) => StrCmpLogicalW(left ?? "", right ?? "");
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] private static extern int StrCmpLogicalW(string left, string right);
    }
}
