import Foundation

/// 一处搜索结果：所在文件、行号（从 1 开始）、该行内的 UTF-16 偏移与长度，以及列表显示用的摘要。
struct FolderSearchMatch: Equatable, Sendable {
  let url: URL
  let line: Int
  /// 匹配在行内的起始 UTF-16 偏移，与编辑器的文档位置口径一致。
  let column: Int
  /// 匹配的 UTF-16 长度。
  let length: Int
  /// 该行摘要，过长时围绕匹配截取。
  let snippet: String
  /// 关键词在摘要中的 UTF-16 范围，用于加粗。
  let highlight: NSRange
}

/// 一个文件的全部匹配，用于分组显示。
struct FolderSearchFile: Equatable, Sendable {
  let url: URL
  let relativePath: String
  let matches: [FolderSearchMatch]
}

struct FolderSearchResult: Equatable, Sendable {
  var files: [FolderSearchFile] = []
  var truncated = false
  var cancelled = false

  var matchCount: Int { files.reduce(0) { $0 + $1.matches.count } }
}

/// 当前文件夹内的全文搜索：只读 UTF-8 的 Markdown 与纯文本，普通文本、不区分大小写。
/// 过滤规则与 `FolderEntry` 一致；不引入索引，每次按需遍历。
enum FolderSearch {
  static let resultLimit = 1000
  static let fileSizeLimit = 5 * 1024 * 1024
  static let snippetLimit = 300
  private static let fileExtensions: Set<String> = ["md", "markdown", "txt"]
  private static let snippetLeadingContext = 60

  /// 同步遍历并搜索；界面层负责放到后台执行，并可通过 `isCancelled` 中止。
  static func search(
    in root: URL,
    query: String,
    limit: Int = resultLimit,
    sizeLimit: Int = fileSizeLimit,
    isCancelled: () -> Bool = { false }
  ) -> FolderSearchResult {
    var result = FolderSearchResult()
    guard !query.isEmpty, limit > 0 else { return result }
    let root = root.standardizedFileURL
    guard let documents = documents(in: root, isCancelled: isCancelled) else {
      result.cancelled = true
      return result
    }
    // 多取一条，用来区分“刚好达到上限”和“确实还有更多”。
    let target = limit + 1
    var collected: [FolderSearchFile] = []
    var total = 0
    for url in documents {
      if isCancelled() {
        result.cancelled = true
        return result
      }
      if total >= target { break }
      guard let content = read(url, sizeLimit: sizeLimit) else { continue }
      guard let matches = matches(in: content, query: query, url: url, take: target - total, isCancelled: isCancelled) else {
        result.cancelled = true
        return result
      }
      if !matches.isEmpty {
        collected.append(FolderSearchFile(url: url, relativePath: relativePath(url, root: root), matches: matches))
        total += matches.count
      }
    }
    var remaining = limit
    result.files = collected.compactMap { file in
      guard remaining > 0 else { return nil }
      let matches = Array(file.matches.prefix(remaining))
      remaining -= matches.count
      return FolderSearchFile(url: file.url, relativePath: file.relativePath, matches: matches)
    }
    result.truncated = total > limit
    return result
  }

  /// 递归列出可搜索的文件，跳过隐藏文件、应用包与符号链接；返回 nil 表示被取消。
  static func documents(in root: URL, isCancelled: () -> Bool = { false }) -> [URL]? {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(
      at: root,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, _ in true }
    ) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
      if isCancelled() { return nil }
      guard let values = try? url.resourceValues(forKeys: keys) else { continue }
      if values.isDirectory == true {
        // 目录本身不出现；隐藏目录、包与符号链接目录不再向下遍历。
        if values.isHidden == true || values.isPackage == true || values.isSymbolicLink == true
          || url.lastPathComponent.hasPrefix(".") {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isSymbolicLink != true, values.isPackage != true, values.isRegularFile == true else { continue }
      guard fileExtensions.contains(url.pathExtension.lowercased()) else { continue }
      files.append(url.standardizedFileURL)
    }
    return files.sorted { $0.path < $1.path }
  }

  /// 只读 UTF-8；超过大小上限或无法按 UTF-8 解码时返回 nil。
  private static func read(_ url: URL, sizeLimit: Int) -> String? {
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > sizeLimit { return nil }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= sizeLimit else { return nil }
    // 与 `DocumentContent` 一致：UTF-8 BOM 不计入正文，避免首行列偏移整体后移。
    let content = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    return String(data: content, encoding: .utf8)
  }

  /// 逐行查找；返回 nil 表示被取消。
  private static func matches(
    in content: String,
    query: String,
    url: URL,
    take: Int,
    isCancelled: () -> Bool
  ) -> [FolderSearchMatch]? {
    let text = content as NSString
    var result: [FolderSearchMatch] = []
    var line = 1
    var location = 0
    while location <= text.length {
      if isCancelled() { return nil }
      var end = location
      while end < text.length, text.character(at: end) != 0x0A, text.character(at: end) != 0x0D { end += 1 }
      appendMatches(
        in: text,
        lineRange: NSRange(location: location, length: end - location),
        query: query,
        url: url,
        line: line,
        take: take,
        to: &result
      )
      if result.count >= take { return result }
      guard end < text.length else { break }
      let crlf = text.character(at: end) == 0x0D && end + 1 < text.length && text.character(at: end + 1) == 0x0A
      location = end + (crlf ? 2 : 1)
      line += 1
    }
    return result
  }

  private static func appendMatches(
    in text: NSString,
    lineRange: NSRange,
    query: String,
    url: URL,
    line: Int,
    take: Int,
    to result: inout [FolderSearchMatch]
  ) {
    var search = lineRange
    while search.length > 0, result.count < take {
      let found = text.range(of: query, options: [.caseInsensitive], range: search)
      guard found.location != NSNotFound else { return }
      let snippet = snippet(in: text, lineRange: lineRange, match: found)
      result.append(FolderSearchMatch(
        url: url,
        line: line,
        column: found.location - lineRange.location,
        length: found.length,
        snippet: snippet.text,
        highlight: snippet.highlight
      ))
      let next = found.location + max(found.length, 1)
      guard next <= NSMaxRange(lineRange) else { return }
      search = NSRange(location: next, length: NSMaxRange(lineRange) - next)
    }
  }

  /// 摘要去掉行尾空白；超长行围绕匹配截取，返回关键词在摘要中的范围。
  private static func snippet(in text: NSString, lineRange: NSRange, match: NSRange) -> (text: String, highlight: NSRange) {
    let line = text.substring(with: lineRange) as NSString
    var length = line.length
    while length > 0, CharacterSet.whitespaces.contains(Unicode.Scalar(line.character(at: length - 1)) ?? " ") {
      length -= 1
    }
    let offset = match.location - lineRange.location
    guard length > snippetLimit else {
      return (line.substring(to: length), NSRange(location: offset, length: match.length))
    }
    var start = max(0, offset - snippetLeadingContext)
    var end = min(length, start + snippetLimit)
    if end == length { start = max(0, end - snippetLimit) }
    // 截取边界落在代理对中间时向内收一位，避免产出孤立代理。
    if start > 0, isLowSurrogate(line.character(at: start)) { start += 1 }
    if end < length, isLowSurrogate(line.character(at: end)) { end -= 1 }
    let prefix = start > 0 ? "…" : ""
    let suffix = end < length ? "…" : ""
    let body = line.substring(with: NSRange(location: start, length: end - start))
    let highlight = NSRange(
      location: prefix.utf16.count + offset - start,
      length: min(match.length, max(0, end - match.location))
    )
    return (prefix + body + suffix, highlight)
  }

  private static func isLowSurrogate(_ unit: unichar) -> Bool {
    unit >= 0xDC00 && unit <= 0xDFFF
  }

  private static func relativePath(_ url: URL, root: URL) -> String {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
  }
}
