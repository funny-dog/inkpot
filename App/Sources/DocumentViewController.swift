import AppKit

final class SidebarViewController: NSViewController {
  enum Content { case files, outline, search }

  let outline = OutlineViewController()
  let files = FileTreeViewController()
  let search = FolderSearchViewController()
  let tabs = SidebarTabBar(titles: ["文件", "大纲", "搜索"].map { L10n.text($0) })
  private(set) var content: Content = .outline

  override func loadView() {
    view = NSView()
    tabs.onSelect = { [weak self] index in self?.show(index == 0 ? .files : index == 2 ? .search : .outline) }
    tabs.setAccessibilityLabel(L10n.text("侧栏内容"))
    tabs.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tabs)
    NSLayoutConstraint.activate([
      // 窗口内容延伸到标题栏下方，侧栏内容从安全区起排，避开红绿灯按钮。
      tabs.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
      tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      tabs.heightAnchor.constraint(equalToConstant: 28),
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
    case .files: tabs.select(0)
    case .outline: tabs.select(1)
    case .search: tabs.select(2)
    }
    files.view.isHidden = content != .files
    outline.view.isHidden = content != .outline
    search.view.isHidden = content != .search
  }

  func showFiles(_ show: Bool) { self.show(show ? .files : .outline) }
}

/// 编辑器区域容器：编辑器下方常驻状态栏，左侧显示编辑模式与保存状态，右侧显示字数统计与缩放。
final class EditorContainerViewController: NSViewController {
  private let statusField = NSTextField(labelWithString: "")
  private let modeField = NSTextField(labelWithString: L10n.text("实时模式"))
  private let saveField = NSTextField(labelWithString: "")
  private let divider = NSBox()
  let zoomControl = EditorZoomControl()
  var statusText: String { statusField.stringValue }
  var modeText: String { modeField.stringValue }
  var saveText: String { saveField.stringValue }
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
    let bar = NSView()
    let separator = NSBox()
    separator.boxType = .separator
    divider.boxType = .custom
    divider.borderWidth = 0
    divider.fillColor = .separatorColor
    divider.isHidden = true
    for field in [modeField, saveField, statusField] {
      field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      field.textColor = .secondaryLabelColor
      field.cell?.wraps = false
    }
    statusField.alignment = .right
    statusField.lineBreakMode = .byTruncatingHead
    statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    statusField.setAccessibilityLabel(L10n.text("字数统计"))
    modeField.setAccessibilityLabel(L10n.text("编辑模式"))
    saveField.setAccessibilityLabel(L10n.text("保存状态"))
    for (child, parent) in [(editor.view, view), (bar, view), (separator, bar), (modeField, bar), (divider, bar), (saveField, bar), (statusField, bar), (zoomControl, bar)] {
      child.translatesAutoresizingMaskIntoConstraints = false
      parent.addSubview(child)
    }
    NSLayoutConstraint.activate([
      // 窗口内容延伸到工具栏下方，编辑器从安全区起排，滚动内容不被工具栏遮住。
      editor.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      editor.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      editor.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      editor.view.bottomAnchor.constraint(equalTo: bar.topAnchor),
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bar.heightAnchor.constraint(equalToConstant: 26),
      separator.topAnchor.constraint(equalTo: bar.topAnchor),
      separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      modeField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
      modeField.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 0.5),
      divider.leadingAnchor.constraint(equalTo: modeField.trailingAnchor, constant: 10),
      divider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      divider.widthAnchor.constraint(equalToConstant: 1),
      divider.heightAnchor.constraint(equalToConstant: 11),
      saveField.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 10),
      saveField.centerYAnchor.constraint(equalTo: modeField.centerYAnchor),
      statusField.leadingAnchor.constraint(greaterThanOrEqualTo: saveField.trailingAnchor, constant: 12),
      statusField.trailingAnchor.constraint(equalTo: zoomControl.leadingAnchor, constant: -12),
      statusField.centerYAnchor.constraint(equalTo: modeField.centerYAnchor),
      zoomControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
      zoomControl.centerYAnchor.constraint(equalTo: modeField.centerYAnchor),
    ])
    editor.onStats = { [weak self] words, characters, lines in self?.showStats(words, characters, lines) }
    if let stats = editor.latestStats { showStats(stats.words, stats.characters, stats.lines) }
    editor.onSourceModeChange = { [weak self] source in self?.showMode(source) }
    showMode(editor.isSourceMode)
  }

  private func showStats(_ words: Int, _ characters: Int, _ lines: Int) {
    statusField.stringValue = L10n.text("%@ 字 · %@ 字符 · %@ 行", words.formatted(), characters.formatted(), lines.formatted())
  }

  /// 保存状态：有未保存修改、已保存或已自动保存；从未保存过的空白文档不显示。
  func showSaveState(edited: Bool, saved: Bool, autosave: Bool) {
    _ = view
    saveField.stringValue = edited ? L10n.text("未保存") : saved ? (autosave ? L10n.text("已自动保存") : L10n.text("已保存")) : ""
    divider.isHidden = saveField.stringValue.isEmpty
  }

  private func showMode(_ source: Bool) {
    modeField.stringValue = source ? L10n.text("源码模式") : L10n.text("实时模式")
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
    files.onOpenInWindow = { [weak self] url in
      guard let self, let window = view.window else { return }
      Task { @MainActor in
        do { try await DocumentTabs.openInWindow(url, from: window) } catch { self.presentError(error) }
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
    updateSaveState()
  }

  /// 文档编辑状态变化（窗口控制器转发）或首次显示时刷新状态栏的保存状态。
  func updateSaveState() {
    let document = view.window?.windowController?.document as? InkpotDocument
    editorContainer.showSaveState(edited: document?.isDocumentEdited ?? false, saved: document?.fileURL != nil, autosave: AppSettings.shared.autosave)
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
    toolbar.allowsUserCustomization = true
    return toolbar
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space, .inkpotFocusMode, .inkpotSourceMode]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .inkpotFocusMode, .inkpotSourceMode]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    switch itemIdentifier {
    case .toggleSidebar:
      item.label = L10n.text("侧栏")
      item.toolTip = L10n.text("显示或隐藏文件树和标题大纲")
      item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L10n.text("侧栏"))
      item.target = self
      item.action = #selector(toggleSidebar(_:))
    case .inkpotFocusMode:
      item.label = L10n.text("专注模式")
      item.toolTip = L10n.text("专注模式（F8）：淡化当前段落以外的内容")
      item.image = NSImage(systemSymbolName: "scope", accessibilityDescription: L10n.text("专注模式"))
      item.target = DisplayModes.shared
      item.action = #selector(DisplayModes.toggleFocusMode(_:))
    case .inkpotSourceMode:
      item.label = L10n.text("源码模式")
      item.toolTip = L10n.text("源码模式（⇧⌘M）：在 Markdown 源码与实时预览之间切换")
      item.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: L10n.text("源码模式"))
      item.target = self
      item.action = #selector(toggleSourceMode(_:))
    default:
      return nil
    }
    item.isBordered = true
    return item
  }

  @objc func toggleSourceMode(_ sender: Any?) { editor.performCommand("toggleSourceMode") }
}

extension NSToolbarItem.Identifier {
  static let inkpotFocusMode = NSToolbarItem.Identifier("com.erhu.inkpot.focusMode")
  static let inkpotSourceMode = NSToolbarItem.Identifier("com.erhu.inkpot.sourceMode")
}
