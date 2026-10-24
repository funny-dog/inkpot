import AppKit

final class SidebarViewController: NSViewController {
  enum Content { case files, outline, search }

  let outline = OutlineViewController()
  let files = FileTreeViewController()
  let search = FolderSearchViewController()
  private let tabs = NSSegmentedControl(labels: ["文件", "大纲", "搜索"], trackingMode: .selectOne, target: nil, action: nil)
  private(set) var content: Content = .outline

  override func loadView() {
    view = NSView()
    tabs.target = self
    tabs.action = #selector(changeTab(_:))
    tabs.setAccessibilityLabel("侧栏内容")
    tabs.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tabs)
    NSLayoutConstraint.activate([
      tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
    ])
    for controller in [files, outline, search] {
      addChild(controller)
      controller.view.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(controller.view)
      NSLayoutConstraint.activate([
        controller.view.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4),
        controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }
    show(.outline)
  }

  func show(_ content: Content) {
    _ = view
    self.content = content
    switch content {
    case .files: tabs.selectedSegment = 0
    case .outline: tabs.selectedSegment = 1
    case .search: tabs.selectedSegment = 2
    }
    files.view.isHidden = content != .files
    outline.view.isHidden = content != .outline
    search.view.isHidden = content != .search
  }

  func showFiles(_ show: Bool) { self.show(show ? .files : .outline) }

  @objc private func changeTab(_ sender: Any?) {
    switch tabs.selectedSegment {
    case 0: show(.files)
    case 2: show(.search)
    default: show(.outline)
    }
  }
}

/// 编辑器区域容器：编辑器下方常驻字数统计状态条。
final class EditorContainerViewController: NSViewController {
  private let statusField = NSTextField(labelWithString: "")
  var statusText: String { statusField.stringValue }
  let editor: EditorViewController

  init(editor: EditorViewController) {
    self.editor = editor
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("使用 init(editor:) 初始化容器") }

  override func loadView() {
    view = NSView()
    addChild(editor)
    editor.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(editor.view)
    statusField.alignment = .right
    statusField.font = .systemFont(ofSize: 11)
    statusField.textColor = .secondaryLabelColor
    statusField.lineBreakMode = .byTruncatingHead
    statusField.cell?.wraps = false
    statusField.setAccessibilityLabel("字数统计")
    statusField.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusField)
    NSLayoutConstraint.activate([
      editor.view.topAnchor.constraint(equalTo: view.topAnchor),
      editor.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editor.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editor.view.bottomAnchor.constraint(equalTo: statusField.topAnchor),
      statusField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      statusField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      statusField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
    ])
    editor.onStats = { [weak self] words, characters, lines in
      self?.statusField.stringValue = "\(words) 字 · \(characters) 字符 · \(lines) 行"
    }
    if let stats = editor.latestStats {
      statusField.stringValue = "\(stats.words) 字 · \(stats.characters) 字符 · \(stats.lines) 行"
    }
  }
}

final class DocumentViewController: NSSplitViewController, NSToolbarDelegate {
  private let sidebar = SidebarViewController()
  var outline: OutlineViewController { sidebar.outline }
  var files: FileTreeViewController { sidebar.files }
  var search: FolderSearchViewController { sidebar.search }
  private let editor: EditorViewController
  private lazy var editorContainer = EditorContainerViewController(editor: editor)
  var fileSwitch = DocumentFileSwitch()
  private var activationObserver: NSObjectProtocol?

  init(editor: EditorViewController) {
    self.editor = editor
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("使用 init(editor:) 初始化文档") }

  deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

  override func viewDidLoad() {
    super.viewDidLoad()
    let item = NSSplitViewItem(sidebarWithViewController: sidebar)
    item.minimumThickness = 180
    item.maximumThickness = 360
    item.canCollapse = true
    addSplitViewItem(item)
    addSplitViewItem(NSSplitViewItem(viewController: editorContainer))
    splitView.setPosition(240, ofDividerAt: 0)
    outline.onNavigate = { [weak editor] in editor?.navigateHeading($0) }
    editor.onOutline = { [weak self] headings, active in self?.outline.update(headings, active: active) }
    editor.onOutlineReset = { [weak self] in self?.outline.reset() }
    outline.update(editor.headings, active: editor.activeHeading)
    files.onOpen = { [weak self] url in self?.openFile(url) }
    files.onOpenInTab = { [weak self] url in
      guard let self, let window = view.window else { return }
      Task { @MainActor in
        do { try await DocumentTabs.open(url, in: window).showWindows() } catch { self.presentError(error) }
      }
    }
    files.onFolderChange = { [weak self] url in self?.search.folderURL = url }
    search.folderURL = files.folderURL
    search.onOpenMatch = { [weak self] match in self?.openFile(match.url, match: match) }
    search.onOpenFolder = { [weak self] in self?.openFolder(nil) }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard activationObserver == nil, let window = view.window else { return }
    activationObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.files.refresh(nil)
        if let document = self?.view.window?.windowController?.document as? InkpotDocument {
          Task { try? await document.safety.refreshFromDisk() }
        }
      }
    }
    files.selectCurrentFile((window.windowController?.document as? InkpotDocument)?.fileURL)
  }

  var outlineVisible: Bool { !splitViewItems[0].isCollapsed && sidebar.content == .outline }
  var filesVisible: Bool { !splitViewItems[0].isCollapsed && sidebar.content == .files }
  var searchVisible: Bool { !splitViewItems[0].isCollapsed && sidebar.content == .search }

  /// 会话恢复用的侧栏状态：是否收起、显示文件树还是大纲（搜索页按大纲恢复）、宽度。
  var sidebarState: (collapsed: Bool, showingFiles: Bool, width: Double) {
    (splitViewItems[0].isCollapsed, sidebar.content == .files, Double(sidebar.view.frame.width))
  }

  func applySidebarState(collapsed: Bool, showingFiles: Bool, width: Double) {
    sidebar.showFiles(showingFiles)
    splitViewItems[0].isCollapsed = collapsed
    if !collapsed, width > 0 { splitView.setPosition(CGFloat(width), ofDividerAt: 0) }
  }

  func toggleContent(files showFiles: Bool) {
    let wasVisible = showFiles ? filesVisible : outlineVisible
    sidebar.showFiles(showFiles)
    splitViewItems[0].isCollapsed = wasVisible
  }

  /// 编辑菜单“在文件夹中查找…”：显示侧栏搜索页并聚焦搜索框；没有文件夹时由搜索页提示先打开。
  @objc func findInFolder(_ sender: Any?) {
    sidebar.show(.search)
    splitViewItems[0].isCollapsed = false
    search.folderURL = files.folderURL
    search.focusSearchField()
  }

  @objc func openFolder(_ sender: Any?) {
    sidebar.showFiles(true)
    splitViewItems[0].isCollapsed = false
    files.selectCurrentFile((view.window?.windowController?.document as? InkpotDocument)?.fileURL)
    files.chooseFolder(sender)
  }

  func openFile(_ url: URL, fragment: String? = nil, match: FolderSearchMatch? = nil) {
    guard let controller = view.window?.windowController, !fileSwitch.isOpening else { return }
    Task { @MainActor in
      do {
        let document = try await fileSwitch.open(url, in: controller)
        files.selectCurrentFile(document?.fileURL)
        if document?.editor === editor {
          editor.focusEditor()
          if let fragment { editor.navigateFragment(fragment) }
          if let match { editor.selectMatch(line: match.line, column: match.column, length: match.length) }
        }
      } catch {
        files.selectCurrentFile((controller.document as? InkpotDocument)?.fileURL)
        presentError(error)
      }
    }
  }

  func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "document")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    return toolbar
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar] }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar] }
  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = "侧栏"
    item.toolTip = "显示或隐藏文件树和标题大纲"
    item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "侧栏")
    item.target = self
    item.action = #selector(toggleSidebar(_:))
    return item
  }
}
