namespace Inkpot.Storage;

/// <summary>
/// 记录文件的基线元数据，用于保存前比对并发或外部修改。
/// </summary>
/// <param name="Length">文件字节大小。</param>
/// <param name="LastWriteTimeUtc">文件最后修改时间（UTC）。</param>
/// <param name="Sha256">文件内容的 SHA-256 哈希值（小写十六进制字符串）。</param>
public record FileBaseline(long Length, DateTime LastWriteTimeUtc, string Sha256);
