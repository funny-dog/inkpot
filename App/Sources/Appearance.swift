import AppKit

/// 系统深浅色外观查询：打开文档时作为初始值传入编辑器，运行期变化由页面内自检测处理。
@MainActor
enum Appearance {
  static var isDark: Bool {
    guard let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) else { return false }
    return name == .darkAqua || name == .vibrantDark
  }
}
