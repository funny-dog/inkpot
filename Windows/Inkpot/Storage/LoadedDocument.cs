namespace Inkpot.Storage;

/// <summary>
/// 表示从磁盘成功加载的文档数据。
/// </summary>
/// <param name="Text">剥离 BOM 并解码后的文档正文，精确保持原文件换行符。</param>
/// <param name="HasBom">读取时原始文件是否带有 BOM 标识。</param>
/// <param name="Baseline">加载完成时刻记录的文件基线信息。</param>
/// <param name="Encoding">原始文本编码（utf-8 / utf-16le / utf-16be / gb18030）。</param>
public record LoadedDocument(string Text, bool HasBom, FileBaseline Baseline, string Encoding = "utf-8");
