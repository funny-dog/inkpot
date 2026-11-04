import AppKit

/// 内置配色与 Web 编辑器的主题标识保持一致；默认主题沿用现有外观。
enum EditorTheme: String, CaseIterable {
  case `default`, lapis, ursine, notion, pie, drake, phycat, dracula

  /// 设置页预览使用的系统字体；正文实际 CSS 字体栈还允许已安装的上游字体。
  var bodyFontFamily: String? {
    switch self {
    case .default, .notion: nil
    case .lapis: "Songti SC"
    case .ursine: "Avenir Next"
    case .phycat: "Kaiti SC"
    case .pie, .drake, .dracula: "Helvetica Neue"
    }
  }

  var codeFontFamily: String { self == .pie || self == .dracula ? "Monaco" : "Menlo" }

  var title: String {
    switch self {
    case .default: L10n.text("Inkpot 默认")
    case .lapis: "Lapis"
    case .ursine: "Ursine"
    case .notion: "Notion"
    case .pie: "Pie"
    case .drake: "Drake"
    case .phycat: "Phycat"
    case .dracula: "Dracula"
    }
  }
}

/// 系统深浅色外观查询：打开文档时作为初始值传入编辑器，运行期变化由页面内自检测处理。
@MainActor
enum Appearance {
  static var isDark: Bool {
    guard let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) else { return false }
    return name == .darkAqua || name == .vibrantDark
  }
}
