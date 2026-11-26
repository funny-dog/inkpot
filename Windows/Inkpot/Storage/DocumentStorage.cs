using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Inkpot.Storage;

public static class DocumentStorage
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly UnicodeEncoding StrictUtf16Le = new(bigEndian: false, byteOrderMark: false, throwOnInvalidBytes: true);
    private static readonly UnicodeEncoding StrictUtf16Be = new(bigEndian: true, byteOrderMark: false, throwOnInvalidBytes: true);
    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];
    private static readonly byte[] Utf16LeBom = [0xFF, 0xFE];
    private static readonly byte[] Utf16BeBom = [0xFE, 0xFF];
    private const uint CodePageGb18030 = 54936;
    private const uint MbErrInvalidChars = 0x00000008;

    [DllImport("kernel32.dll", EntryPoint = "MoveFileExW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileEx(string source, string destination, uint flags);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern int MultiByteToWideChar(uint codePage, uint flags, [In] byte[] bytes, int byteCount, [Out] char[]? chars, int charCount);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern int WideCharToMultiByte(uint codePage, uint flags, string chars, int charCount, [Out] byte[]? bytes, int byteCount, IntPtr defaultChar, IntPtr usedDefaultChar);

    public static async Task<LoadedDocument> ReadAsync(string path)
    {
        using var stream = OpenRead(path);
        byte[] bytes = new byte[stream.Length];
        // 读取期间禁止其他写入和删除；不接受截断后的补零内容。
        await stream.ReadExactlyAsync(bytes).ConfigureAwait(false);
        var (text, hasBom, encoding) = DecodeBytes(bytes);
        var baseline = new FileBaseline(bytes.Length, File.GetLastWriteTimeUtc(stream.SafeFileHandle), Hash(bytes));
        return new LoadedDocument(text, hasBom, baseline, encoding);
    }

    public static async Task<FileBaseline> SaveAsync(string path, string text, bool hasBom,
        FileBaseline? expectedBaseline, bool overwriteExternal = false, string encoding = "utf-8")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(text);
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)!;
        if (!Directory.Exists(directory)) throw new DirectoryNotFoundException(directory);
        byte[] bytes = EncodeBytes(text, hasBom, encoding);
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
            {
                var error = new Win32Exception(Marshal.GetLastWin32Error());
                throw new IOException(error.Message, error);
            }
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

    private static (string Text, bool HasBom, string Encoding) DecodeBytes(byte[] bytes)
    {
        var span = bytes.AsSpan();
        if (span.StartsWith(Utf8Bom))
            return (StrictUtf8.GetString(bytes, 3, bytes.Length - 3), true, "utf-8");
        DecoderFallbackException utf8Error;
        try { return (StrictUtf8.GetString(bytes), false, "utf-8"); }
        catch (DecoderFallbackException error) { utf8Error = error; }

        if (bytes.Length >= 4 && bytes.Length % 2 == 0)
        {
            if (span.StartsWith(Utf16LeBom))
            {
                try
                {
                    string decoded = StrictUtf16Le.GetString(bytes, 2, bytes.Length - 2);
                    if (!decoded.Contains('\0')) return (decoded, true, "utf-16le");
                }
                catch (DecoderFallbackException) { }
            }
            else if (span.StartsWith(Utf16BeBom))
            {
                try
                {
                    string decoded = StrictUtf16Be.GetString(bytes, 2, bytes.Length - 2);
                    if (!decoded.Contains('\0')) return (decoded, true, "utf-16be");
                }
                catch (DecoderFallbackException) { }
            }
        }

        // 不含 NUL 字节且不带其他 BOM 时尝试 GB18030，并要求逐字节往返完全一致。
        if (bytes.Length > 0 && !span.Contains((byte)0) && !span.StartsWith(Utf16LeBom) && !span.StartsWith(Utf16BeBom)
            && TryDecodeGb18030(bytes, out string? gbText) && gbText is not null
            && TryEncodeGb18030(gbText, out byte[]? roundtrip) && roundtrip is not null && span.SequenceEqual(roundtrip))
            return (gbText, false, "gb18030");

        throw utf8Error;
    }

    private static byte[] EncodeBytes(string text, bool hasBom, string? encoding)
    {
        switch (encoding)
        {
            case "utf-16le":
                return [.. Utf16LeBom, .. StrictUtf16Le.GetBytes(text)];
            case "utf-16be":
                return [.. Utf16BeBom, .. StrictUtf16Be.GetBytes(text)];
            case "gb18030":
                if (text.Length == 0) return [];
                if (TryEncodeGb18030(text, out byte[]? encoded) && encoded is not null
                    && TryDecodeGb18030(encoded, out string? decoded) && string.Equals(decoded, text, StringComparison.Ordinal))
                    return encoded;
                // 若编辑后加入了目标编码无法无损表示的字符，安全回退 UTF-8 避免静默丢字。
                return StrictUtf8.GetBytes(text);
            default:
                byte[] utf8 = StrictUtf8.GetBytes(text);
                return hasBom ? [.. Utf8Bom, .. utf8] : utf8;
        }
    }

    private static bool TryDecodeGb18030(byte[] bytes, out string? text)
    {
        text = null;
        if (bytes.Length == 0) { text = ""; return true; }
        int required = MultiByteToWideChar(CodePageGb18030, MbErrInvalidChars, bytes, bytes.Length, null, 0);
        if (required <= 0) return false;
        char[] buffer = new char[required];
        int written = MultiByteToWideChar(CodePageGb18030, MbErrInvalidChars, bytes, bytes.Length, buffer, buffer.Length);
        if (written <= 0) return false;
        string decoded = new(buffer, 0, written);
        if (decoded.Contains('\0')) return false;
        text = decoded;
        return true;
    }

    private static bool TryEncodeGb18030(string text, out byte[]? bytes)
    {
        bytes = null;
        if (text.Length == 0) { bytes = []; return true; }
        int required = WideCharToMultiByte(CodePageGb18030, 0, text, text.Length, null, 0, IntPtr.Zero, IntPtr.Zero);
        if (required <= 0) return false;
        byte[] buffer = new byte[required];
        int written = WideCharToMultiByte(CodePageGb18030, 0, text, text.Length, buffer, buffer.Length, IntPtr.Zero, IntPtr.Zero);
        if (written <= 0) return false;
        bytes = written == buffer.Length ? buffer : buffer[..written];
        return true;
    }

    private static FileStream OpenRead(string path) => new(Path.GetFullPath(path), FileMode.Open, FileAccess.Read,
        FileShare.Read, 4096, FileOptions.Asynchronous);
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
}
