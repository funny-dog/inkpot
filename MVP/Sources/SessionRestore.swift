import AppKit

/// 文件或文件夹的位置：保存路径与普通书签，书签可跟随重命名和移动；移到废纸篓或已删除视为丢失。
/// 应用不启用沙盒（直接分发方案），不需要安全作用域书签。
struct SessionLocation: Codable, Equatable {
  var path: String
  var bookmark: Data?

  init(_ url: URL) {
    path = url.standardizedFileURL.path
    bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  var name: String { (path as NSString).lastPathComponent }

  func resolve(fileManager: FileManager = .default) -> URL? {
    var candidates: [URL] = []
    if let bookmark {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
        candidates.append(url)
      }
    }
    candidates.append(URL(fileURLWithPath: path))
    return candidates.map(\.standardizedFileURL).first { url in
      !url.pathComponents.contains(".Trash") && fileManager.fileExists(atPath: url.path)
    }
  }
}

/// 最近打开的文件夹：最多 10 个，最新的在前，同一路径只保留一项。
@MainActor
final class RecentFolders {
  static let shared = RecentFolders()
  static let limit = 10
  private let defaults: UserDefaults
  private let key = "recentFolders"

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var locations: [SessionLocation] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([SessionLocation].self, from: data)) ?? []
  }

  func add(_ url: URL) {
    let location = SessionLocation(url)
    save([location] + locations.filter { $0.path != location.path })
  }

  func remove(_ location: SessionLocation) { save(locations.filter { $0.path != location.path }) }

  func clear() { defaults.removeObject(forKey: key) }

  private func save(_ locations: [SessionLocation]) {
    defaults.set(try? JSONEncoder().encode(Array(locations.prefix(Self.limit))), forKey: key)
  }
}

/// 文件 → 打开最近的文件夹：展开时重建；已被移走或删除的文件夹给出提示并移出列表。
@MainActor
final class RecentFoldersMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
  static let shared = RecentFoldersMenu()

  let menu = NSMenu(title: "打开最近的文件夹")
  private let folders: RecentFolders
  private let open: @MainActor (URL) -> Void
  private let notifyMissing: @MainActor (SessionLocation) -> Void

  init(
    folders: RecentFolders? = nil,
    open: @escaping @MainActor (URL) -> Void = { (NSApp.delegate as? AppDelegate)?.openFolder(at: $0) },
    notifyMissing: @escaping @MainActor (SessionLocation) -> Void = RecentFoldersMenu.alertMissing
  ) {
    self.folders = folders ?? .shared
    self.open = open
    self.notifyMissing = notifyMissing
    super.init()
    menu.delegate = self
    rebuild()
  }

  func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

  func rebuild() {
    menu.removeAllItems()
    let locations = folders.locations
    let counts = Dictionary(grouping: locations, by: \.name).mapValues(\.count)
    for location in locations {
      // 同名文件夹追加上级目录，便于区分。
      let parent = ((location.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
      let item = NSMenuItem(title: (counts[location.name] ?? 0) > 1 ? "\(location.name) — \(parent)" : location.name, action: #selector(openRecent(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = location.path
      item.toolTip = location.path
      item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
      menu.addItem(item)
    }
    if !locations.isEmpty { menu.addItem(.separator()) }
    let clearItem = NSMenuItem(title: "清除菜单", action: #selector(clearRecent(_:)), keyEquivalent: "")
    clearItem.target = self
    menu.addItem(clearItem)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    menuItem.action == #selector(clearRecent(_:)) ? !folders.locations.isEmpty : true
  }

  @objc func openRecent(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String, let location = folders.locations.first(where: { $0.path == path }) else { return }
    guard let url = location.resolve() else {
      folders.remove(location)
      rebuild()
      notifyMissing(location)
      return
    }
    open(url)
  }

  static func alertMissing(_ location: SessionLocation) {
    let alert = NSAlert()
    alert.messageText = "找不到文件夹“\(location.name)”"
    alert.informativeText = "它可能已被移走、删除或位于未连接的磁盘上，已从最近的文件夹中移除。"
    alert.runModal()
  }

  @objc func clearRecent(_ sender: Any?) {
    folders.clear()
    rebuild()
  }
}

/// 退出时的窗口与标签：每个标签记录文件、文件夹与侧栏状态；未保存过的空白标签只在打开了文件夹时记录，
/// 未保存的内容由本地恢复草稿负责。
struct SessionState: Codable, Equatable {
  struct Tab: Codable, Equatable {
    var file: SessionLocation?
    var folder: SessionLocation?
    var sidebarCollapsed: Bool
    var showingFiles: Bool
    var sidebarWidth: Double
  }

  struct Window: Codable, Equatable {
    var frame: String
    var tabs: [Tab]
    var selectedTab: Int
  }

  var windows: [Window]
}

@MainActor
enum DocumentSession {
  private static let key = "session.state"

  static func load(defaults: UserDefaults = .standard) -> SessionState? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(SessionState.self, from: data)
  }

  static func save(_ state: SessionState, defaults: UserDefaults = .standard) {
    defaults.set(try? JSONEncoder().encode(state), forKey: key)
  }

  /// 按前后顺序记录文档窗口；同一标签组只记录一次，保留标签顺序与当前标签。
  static func capture(windows: [NSWindow]? = nil) -> SessionState {
    let windows = windows ?? NSApp.orderedWindows + NSApp.windows
    var seen = Set<ObjectIdentifier>()
    var result: [SessionState.Window] = []
    for window in windows where !seen.contains(ObjectIdentifier(window)) && window.contentViewController is DocumentViewController {
      let group = window.tabbedWindows ?? [window]
      group.forEach { seen.insert(ObjectIdentifier($0)) }
      let selected = window.tabGroup?.selectedWindow ?? window
      var tabs: [SessionState.Tab] = []
      var selectedTab = 0
      for tabWindow in group {
        guard let controller = tabWindow.contentViewController as? DocumentViewController else { continue }
        let file = (tabWindow.windowController?.document as? MVPDocument)?.fileURL
        let folder = controller.files.root?.entry.url
        guard file != nil || folder != nil else { continue }
        if tabWindow === selected { selectedTab = tabs.count }
        let sidebar = controller.sidebarState
        tabs.append(.init(
          file: file.map(SessionLocation.init),
          folder: folder.map(SessionLocation.init),
          sidebarCollapsed: sidebar.collapsed,
          showingFiles: sidebar.showingFiles,
          sidebarWidth: sidebar.width
        ))
      }
      if !tabs.isEmpty { result.append(.init(frame: NSStringFromRect(window.frame), tabs: tabs, selectedTab: selectedTab)) }
    }
    return SessionState(windows: result)
  }

  /// 从后往前恢复，使原来最前的窗口最后显示、位于最前。返回未能恢复的文件或文件夹名称。
  @discardableResult
  static func restore(
    _ state: SessionState,
    open: (URL) async throws -> (MVPDocument, Bool) = DocumentFileSwitch.load
  ) async -> [String] {
    var missing: [String] = []
    for saved in state.windows.reversed() {
      var last: NSWindow?
      var selected: NSWindow?
      var fallbackFolder: URL?
      for (index, tab) in saved.tabs.enumerated() {
        let folder = tab.folder.flatMap { $0.resolve() }
        if let name = tab.folder?.name, folder == nil, !missing.contains(name) { missing.append(name) }
        fallbackFolder = fallbackFolder ?? folder
        let document: MVPDocument
        if let file = tab.file {
          guard let url = file.resolve(), let result = try? await open(url) else {
            missing.append(file.name)
            continue
          }
          if result.1 || !result.0.windowControllers.isEmpty { continue }
          document = result.0
        } else {
          document = blankDocument()
        }
        guard let window = place(document, folder: folder, tab: tab, after: last, frame: saved.frame) else { continue }
        last = window
        if index == saved.selectedTab { selected = window }
      }
      // 整个窗口的文件都已丢失时，保留一个空白窗口显示原来的文件夹。
      if last == nil, let fallbackFolder, let tab = saved.tabs.first {
        _ = place(blankDocument(), folder: fallbackFolder, tab: tab, after: nil, frame: saved.frame)
      }
      if let selected { selected.tabGroup?.selectedWindow = selected }
    }
    return missing
  }

  private static func blankDocument() -> MVPDocument {
    let document = MVPDocument()
    NSDocumentController.shared.addDocument(document)
    return document
  }

  /// 建立文档窗口并恢复文件夹与侧栏；有前一个标签时接在其后，否则按记录的位置作为独立窗口显示。
  private static func place(_ document: MVPDocument, folder: URL?, tab: SessionState.Tab, after previous: NSWindow?, frame: String) -> NSWindow? {
    document.makeWindowControllers()
    guard let window = document.windowControllers.first?.window,
          let controller = window.contentViewController as? DocumentViewController else { return nil }
    if let folder { controller.files.openFolder(folder) }
    controller.applySidebarState(collapsed: tab.sidebarCollapsed, showingFiles: tab.showingFiles, width: tab.sidebarWidth)
    if let previous {
      previous.addTabbedWindow(window, ordered: .above)
      document.showWindows()
    } else {
      // 首个窗口不自动并入其他窗口的标签组，保持原来的分窗。
      window.tabbingMode = .disallowed
      window.setFrame(NSRectFromString(frame), display: false)
      document.showWindows()
      window.tabbingMode = .automatic
    }
    return window
  }
}
