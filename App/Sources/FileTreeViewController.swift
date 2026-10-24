import AppKit

struct FolderEntry: Sendable {
  let url: URL
  let isDirectory: Bool

  static func read(_ folder: URL) throws -> [Self] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
      .compactMap { url -> Self? in
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true, values.isPackage != true else { return nil }
        let directory = values.isDirectory == true
        guard directory || (values.isRegularFile == true && ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())) else { return nil }
        return Self(url: url.standardizedFileURL, isDirectory: directory)
      }
      .sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
      }
  }
}

final class FileTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  final class Item: NSObject {
    let entry: FolderEntry
    var children: [Item]?
    var loading = false
    var error: String?

    init(_ entry: FolderEntry) { self.entry = entry }
  }

  var onOpen: ((URL) -> Void)?
  var onOpenInTab: ((URL) -> Void)?
  /// 根目录变化时通知侧栏其他页面（例如文件夹搜索）。
  var onFolderChange: ((URL?) -> Void)?
  var folderURL: URL? { root?.entry.url }
  private var changeObserver: NSObjectProtocol?
  let outlineView = NSOutlineView()
  private(set) var root: Item?
  private let folderLabel = NSTextField(labelWithString: "未打开文件夹")
  private let header = NSStackView()
  private lazy var emptyState = SidebarEmptyState(
    symbol: "folder",
    title: "还没有打开文件夹",
    message: "打开一个文件夹，就能在这里浏览和切换其中的 Markdown 文件。",
    button: NSButton(title: "打开文件夹…", target: self, action: #selector(chooseFolder(_:)))
  )
  private let scrollView = NSScrollView()
  private var expanded: Set<URL> = []
  private var currentFile: URL?
  private var revealingCurrent = false
  private var scopedURL: URL?
  private var generation = 0

  deinit {
    scopedURL?.stopAccessingSecurityScopedResource()
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
  }

  override func loadView() {
    view = NSView()
    folderLabel.lineBreakMode = .byTruncatingMiddle
    folderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    folderLabel.textColor = .secondaryLabelColor
    folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let open = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "打开文件夹") ?? NSImage(), target: self, action: #selector(chooseFolder(_:)))
    open.toolTip = "打开或更换文件夹"
    open.isBordered = false
    let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新文件树") ?? NSImage(), target: self, action: #selector(refresh(_:)))
    refresh.toolTip = "刷新文件树"
    refresh.isBordered = false
    for child in [folderLabel, open, refresh] { header.addArrangedSubview(child) }
    header.spacing = 8
    // 未打开文件夹时由空状态说明，标题行与之重复，先隐藏。
    header.isHidden = root == nil
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.rowHeight = 28
    outlineView.indentationPerLevel = 12
    outlineView.style = .sourceList
    outlineView.setAccessibilityLabel("文件树")
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.target = self
    outlineView.action = #selector(activate(_:))
    outlineView.doubleAction = #selector(activate(_:))
    let menu = NSMenu()
    menu.delegate = self
    outlineView.menu = menu
    changeObserver = NotificationCenter.default.addObserver(forName: .inkpotFileTreeChanged, object: nil, queue: .main) { [weak self] notification in
      MainActor.assumeIsolated { self?.reloadAfterChange(notification) }
    }
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    for child in [header, scrollView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    emptyState.pin(in: view, centeredOn: scrollView)
  }

  private func reloadAfterChange(_ notification: Notification) {
    guard let root else { return }
    let source = notification.userInfo?["source"] as? URL
    let target = notification.userInfo?["target"] as? URL
    func moved(_ url: URL) -> URL {
      guard let source, let target else { return url }
      return FileTreeActions.relocated(url, from: source, to: target) ?? url
    }
    let remembered = Set(expanded.map(moved))
    if let currentFile { self.currentFile = moved(currentFile) }
    openFolder(moved(root.entry.url))
    expanded = remembered
  }

  @objc func chooseFolder(_ sender: Any?) {
    guard let window = view.window else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "打开文件夹"
    panel.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let url = panel.url { self?.openFolder(url) }
    }
  }

  func openFolder(_ url: URL) {
    _ = view
    generation += 1
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    root = Item(FolderEntry(url: url.standardizedFileURL, isDirectory: true))
    expanded = []
    revealingCurrent = true
    folderLabel.stringValue = url.lastPathComponent
    folderLabel.toolTip = url.path
    header.isHidden = false
    RecentFolders.shared.add(url)
    outlineView.reloadData()
    onFolderChange?(root?.entry.url)
    if let root { load(root) }
  }

  @objc func refresh(_ sender: Any?) {
    guard let root else { return }
    load(root, refresh: true)
    func reloadExpanded(_ item: Item) {
      for child in item.children ?? [] where expanded.contains(child.entry.url) {
        load(child, refresh: true)
        reloadExpanded(child)
      }
    }
    reloadExpanded(root)
  }

  private func load(_ item: Item, refresh: Bool = false) {
    guard !item.loading, item.children == nil || refresh else { return }
    item.loading = true
    let generation = generation
    let url = item.entry.url
    Task { @MainActor in
      let result = await Task.detached { Result { try FolderEntry.read(url) } }.value
      guard self.generation == generation else { return }
      item.loading = false
      let origin = scrollView.contentView.bounds.origin
      switch result {
      case let .success(entries):
        let old = Dictionary(uniqueKeysWithValues: (item.children ?? []).map { ($0.entry.url, $0) })
        item.children = entries.map { entry in
          if let cached = old[entry.url], cached.entry.isDirectory == entry.isDirectory { return cached }
          return Item(entry)
        }
        item.error = nil
      case let .failure(error):
        item.error = error.localizedDescription
        item.children = item.children ?? []
      }
      if item === root {
        folderLabel.stringValue = url.lastPathComponent + (item.error == nil ? "" : "（无法读取）")
        folderLabel.toolTip = item.error ?? url.path
        outlineView.reloadData()
        emptyState.title = item.error == nil ? "没有可显示的文件" : "无法读取文件夹"
        emptyState.message = item.error ?? "此文件夹中没有 Markdown 或文本文件。"
        emptyState.isHidden = item.children?.isEmpty == false
      } else {
        outlineView.reloadItem(item, reloadChildren: true)
      }
      restoreExpanded(root)
      scrollView.contentView.scroll(to: origin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
      updateSelection()
    }
  }

  private func restoreExpanded(_ parent: Item?) {
    for item in parent?.children ?? [] where expanded.contains(item.entry.url) {
      outlineView.expandItem(item)
      restoreExpanded(item)
    }
  }

  func selectCurrentFile(_ url: URL?) {
    let file = url?.standardizedFileURL
    if file != currentFile { revealingCurrent = true }
    currentFile = file
    updateSelection()
  }

  private func updateSelection() {
    outlineView.deselectAll(nil)
    guard let currentFile, let root else { return }
    func reveal(_ parent: Item) {
      for item in parent.children ?? [] {
        let matches = item.entry.url == currentFile
        let contains = item.entry.isDirectory && currentFile.path.hasPrefix(item.entry.url.path + "/")
        guard matches || contains else { continue }
        if contains && revealingCurrent {
          expanded.insert(item.entry.url)
          outlineView.expandItem(item)
          load(item)
        }
        if contains && outlineView.isItemExpanded(item) {
          reveal(item)
        } else {
          let row = outlineView.row(forItem: item)
          if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if revealingCurrent { outlineView.scrollRowToVisible(row) }
          }
          if matches { revealingCurrent = false }
        }
      }
    }
    reveal(root)
  }

  @objc private func activate(_ sender: Any?) {
    guard let item = outlineView.item(atRow: outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow) as? Item else { return }
    if item.entry.isDirectory {
      if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
    } else { onOpen?(item.entry.url) }
  }

  func outlineViewItemWillExpand(_ notification: Notification) {
    guard let item = notification.userInfo?["NSObject"] as? Item else { return }
    expanded.insert(item.entry.url)
    load(item, refresh: item.error != nil)
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    if let item = notification.userInfo?["NSObject"] as? Item {
      expanded.remove(item.entry.url)
      revealingCurrent = false
    }
  }
}

extension FileTreeViewController {
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    let parent = (item as? Item) ?? root
    if let parent { load(parent) }
    return parent?.children?.count ?? 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    ((item as? Item) ?? root)?.children?[index] ?? NSObject()
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.entry.isDirectory == true }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let item = item as? Item else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("file")
    let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
    if cell.textField == nil {
      let text = NSTextField(labelWithString: "")
      text.lineBreakMode = .byTruncatingMiddle
      let image = NSImageView()
      cell.addSubview(image)
      cell.addSubview(text)
      cell.imageView = image
      cell.textField = text
      image.frame = NSRect(x: 0, y: 5, width: 18, height: 18)
      text.frame = NSRect(x: 24, y: 5, width: 100, height: 18)
      text.autoresizingMask = [.width]
    }
    cell.identifier = identifier
    cell.textField?.stringValue = item.entry.url.lastPathComponent + (item.error == nil ? "" : "（无法读取）")
    cell.imageView?.image = NSImage(systemSymbolName: item.entry.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
    cell.toolTip = item.error ?? item.entry.url.path
    return cell
  }
}
