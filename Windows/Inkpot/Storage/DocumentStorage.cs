using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Inkpot.Storage;

public static class DocumentStorage
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];

    [DllImport("kernel32.dll", EntryPoint = "MoveFileExW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileEx(string source, string destination, uint flags);

    public static async Task<LoadedDocument> ReadAsync(string path)
    {
        using var stream = OpenRead(path);
        byte[] bytes = new byte[stream.Length];
        // 读取期间禁止其他写入和删除；不接受截断后的补零内容。
        await stream.ReadExactlyAsync(bytes).ConfigureAwait(false);
        bool hasBom = bytes.AsSpan().StartsWith(Utf8Bom);
        string text = StrictUtf8.GetString(bytes, hasBom ? 3 : 0, bytes.Length - (hasBom ? 3 : 0));
        var baseline = new FileBaseline(bytes.Length, File.GetLastWriteTimeUtc(stream.SafeFileHandle), Hash(bytes));
        return new LoadedDocument(text, hasBom, baseline);
    }

    public static async Task<FileBaseline> SaveAsync(string path, string text, bool hasBom,
        FileBaseline? expectedBaseline, bool overwriteExternal = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(text);
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)!;
        if (!Directory.Exists(directory)) throw new DirectoryNotFoundException(directory);
        byte[] encoded = StrictUtf8.GetBytes(text);
        byte[] bytes = hasBom ? [.. Utf8Bom, .. encoded] : encoded;
        string tempPath = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var temp = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await temp.WriteAsync(bytes).ConfigureAwait(false);
                await temp.FlushAsync().ConfigureAwait(false);
                temp.Flush(flushToDisk: true);
            }
            var saved = new FileBaseline(bytes.Length, File.GetLastWriteTimeUtc(tempPath), Hash(bytes));
            if (expectedBaseline is not null && !overwriteExternal)
            {
                FileBaseline current;
                try
                {
                    using var stream = OpenRead(fullPath);
                    byte[] hash = await SHA256.HashDataAsync(stream).ConfigureAwait(false);
                    current = new FileBaseline(stream.Length, File.GetLastWriteTimeUtc(stream.SafeFileHandle), Convert.ToHexString(hash));
                }
                catch (FileNotFoundException) { throw new ExternalChangeException("文件已在外部删除。"); }
                if (current.Length != expectedBaseline.Length || current.LastWriteTimeUtc != expectedBaseline.LastWriteTimeUtc
                    || !current.Sha256.Equals(expectedBaseline.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new ExternalChangeException("文件已在外部修改。");
            }
            // 同卷原子替换并写穿；不先删除目标文件，替换失败时原文件仍在。
            if (!MoveFileEx(tempPath, fullPath, 0x1 | 0x8))
                throw new IOException("无法原子保存文件。", new Win32Exception(Marshal.GetLastWin32Error()));
            // 使用本次实际写入的基线，避免把替换后发生的外部修改认作自己的内容。
            return saved;
        }
        finally
        {
            try { File.Delete(tempPath); }
            catch (IOException) { /* 清理失败不掩盖原始保存错误。 */ }
            catch (UnauthorizedAccessException) { /* 目录权限变化时保留原始错误。 */ }
        }
    }

    private static FileStream OpenRead(string path) => new(Path.GetFullPath(path), FileMode.Open, FileAccess.Read,
        FileShare.Read, 4096, FileOptions.Asynchronous);
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
}
