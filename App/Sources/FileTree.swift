import AppKit

/// 文件树显示范围：默认只列 Markdown 与纯文本，可在设置中改为所有文件并显示隐藏项。
/// 显示所有文件时，其他类型也在 Inkpot 中按纯文本打开；非 UTF-8 文本会提示无法打开，不改动原文件。
enum FileTree {
  static let textExtensions: Set<String> = ["md", "markdown", "txt"]
  static let filterDidChange = Notification.Name("InkpotFileTreeFilterDidChange")

  struct Filter: Sendable {
    var allFiles = false
    var hidden = false
  }

  static func isText(_ url: URL) -> Bool { textExtensions.contains(url.pathExtension.lowercased()) }
}

extension FileTreeViewController {
  enum Placement { case current, tab, window }

  /// 打开文件树中的文件：当前窗口、新标签页或新窗口，均在 Inkpot 中打开。
  func open(_ url: URL, in placement: Placement) {
    switch placement {
    case .current: onOpen?(url)
    case .tab: onOpenInTab?(url)
    case .window: onOpenInWindow?(url)
    }
  }
}
