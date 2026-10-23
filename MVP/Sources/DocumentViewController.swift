import AppKit

final class SidebarViewController: NSViewController {
  let outline = OutlineViewController()
  let files = FileTreeViewController()
  private let tabs = NSSegmentedControl(labels: ["文件", "大纲"], trackingMode: .selectOne, target: nil, action: nil)
  private(set) var showingFiles = false

  override func loadView() {
    view = NSView()
    tabs.target = self
    tabs.action = #selector(changeTab(_:))
    tabs.selectedSegment = 1
    tabs.setAccessibilityLabel("侧栏内容")
    tabs.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tabs)
    NSLayoutConstraint.activate([
      tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
    ])
    for controller in [files, outline] {
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
    showFiles(false)
  }

  func showFiles(_ show: Bool) {
    _ = view
    showingFiles = show
    tabs.selectedSegment = show ? 0 : 1
    files.view.isHidden = !show
    outline.view.isHidden = show
  }

  @objc private func changeTab(_ sender: Any?) { showFiles(tabs.selectedSegment == 0) }
}

final class DocumentViewController: NSSplitViewController, NSToolbarDelegate {
  private let sidebar = SidebarViewController()
  var outline: OutlineViewController { sidebar.outline }
  var files: FileTreeViewController { sidebar.files }
  private let editor: EditorViewController
  private let fileSwitch = DocumentFileSwitch()
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
    addSplitViewItem(NSSplitViewItem(viewController: editor))
    splitView.setPosition(240, ofDividerAt: 0)
    outline.onNavigate = { [weak editor] in editor?.navigateHeading($0) }
    editor.onOutline = { [weak self] headings, active in self?.outline.update(headings, active: active) }
    editor.onOutlineReset = { [weak self] in self?.outline.reset() }
    outline.update(editor.headings, active: editor.activeHeading)
    files.onOpen = { [weak self] url in self?.openFile(url) }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard activationObserver == nil, let window = view.window else { return }
    activationObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.files.refresh(nil)
        if let document = self?.view.window?.windowController?.document as? MVPDocument {
          Task { try? await document.safety.refreshFromDisk() }
        }
      }
    }
    files.selectCurrentFile((window.windowController?.document as? MVPDocument)?.fileURL)
  }

  var outlineVisible: Bool { !splitViewItems[0].isCollapsed && !sidebar.showingFiles }
  var filesVisible: Bool { !splitViewItems[0].isCollapsed && sidebar.showingFiles }

  func toggleContent(files showFiles: Bool) {
    let wasVisible = showFiles ? filesVisible : outlineVisible
    sidebar.showFiles(showFiles)
    splitViewItems[0].isCollapsed = wasVisible
  }

  @objc func openFolder(_ sender: Any?) {
    sidebar.showFiles(true)
    splitViewItems[0].isCollapsed = false
    files.selectCurrentFile((view.window?.windowController?.document as? MVPDocument)?.fileURL)
    files.chooseFolder(sender)
  }

  func openFile(_ url: URL, fragment: String? = nil) {
    guard let controller = view.window?.windowController, !fileSwitch.isOpening else { return }
    Task { @MainActor in
      do {
        let document = try await fileSwitch.open(url, in: controller)
        files.selectCurrentFile(document?.fileURL)
        if document?.editor === editor {
          editor.focusEditor()
          if let fragment { editor.navigateFragment(fragment) }
        }
      } catch {
        files.selectCurrentFile((controller.document as? MVPDocument)?.fileURL)
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
