import AppKit

/// 打开最近使用：每次展开时按系统记录的最近文档重建，只用公开接口，不依赖 AppKit 的私有菜单名。
/// 最近文档由 NSDocumentController 在打开、保存和文件树切换时自动记录。
@MainActor
final class RecentDocumentsMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
  static let shared = RecentDocumentsMenu()

  let menu = NSMenu(title: "打开最近使用")
  private let recentURLs: () -> [URL]
  private let open: (URL) -> Void
  private let clear: () -> Void

  init(
    recentURLs: @escaping () -> [URL] = { NSDocumentController.shared.recentDocumentURLs },
    open: @escaping (URL) -> Void = RecentDocumentsMenu.openDocument,
    clear: @escaping () -> Void = { NSDocumentController.shared.clearRecentDocuments(nil) }
  ) {
    self.recentURLs = recentURLs
    self.open = open
    self.clear = clear
    super.init()
    menu.delegate = self
    rebuild()
  }

  func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

  func rebuild() {
    menu.removeAllItems()
    let urls = recentURLs()
    let counts = Dictionary(grouping: urls, by: \.lastPathComponent).mapValues(\.count)
    for url in urls {
      // 同名文件追加所在文件夹，便于区分。
      let name = url.lastPathComponent
      let title = (counts[name] ?? 0) > 1 ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)" : name
      let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = url
      item.toolTip = url.path
      let icon = NSWorkspace.shared.icon(forFile: url.path)
      icon.size = NSSize(width: 16, height: 16)
      item.image = icon
      menu.addItem(item)
    }
    if !urls.isEmpty { menu.addItem(.separator()) }
    let clearItem = NSMenuItem(title: "清除菜单", action: #selector(clearRecent(_:)), keyEquivalent: "")
    clearItem.target = self
    menu.addItem(clearItem)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    menuItem.action == #selector(clearRecent(_:)) ? !recentURLs().isEmpty : true
  }

  @objc func openRecent(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { open(url) }
  }

  @objc func clearRecent(_ sender: Any?) {
    clear()
    rebuild()
  }

  static func openDocument(_ url: URL) {
    // 已在其他窗口打开时由 NSDocumentController 激活现有窗口；文件已被移走时报告错误。
    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
      if let error { NSApp.presentError(error) }
    }
  }
}
