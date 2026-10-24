namespace Inkpot.Storage;

/// <summary>
/// 表示从磁盘成功加载的文档数据。
/// </summary>
/// <param name="Text">剥离 UTF-8 BOM 后的文档正文，精确保持原文件换行符。</param>
/// <param name="HasBom">读取时原始文件是否带有 UTF-8 BOM 标识。</param>
/// <param name="Baseline">加载完成时刻记录的文件基线信息。</param>
public record LoadedDocument(string Text, bool HasBom, FileBaseline Baseline);
