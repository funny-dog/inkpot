//
//  SidebarViewController.swift
//  MarkEditMac
//
//  Created by Inkpot on 2026-10-23.
//

import AppKit
import MarkEditKit

/// 侧栏模式
enum SidebarMode: Int {
  case folder = 0
  case outline = 1
}

/// 侧栏控制器（包含文件夹树懒加载与大纲导航）
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  /// 当前关联的编辑器控制器（弱引用，支持外部显式注入）
  weak var hostViewController: EditorViewController?

  /// 文件夹安全作用域凭证管理
  private let securityScope = SidebarSecurityScope()

  /// 当前侧栏展示模式
  private(set) var currentMode: SidebarMode = .folder

  /// 当前打开的根文件夹 URL
  private(set) var currentFolderURL: URL?

  /// 根文件夹节点模型
  private var rootFolderItem: FileTreeItem?

  /// 大纲根项列表
  private var outlineRootItems: [OutlineItem] = []

  /// 根节点操作项：“打开文件夹…”
  private let openFolderActionItem = FileTreeItem.makeOpenFolderActionItem()

  // MARK: - UI 组件

  /// 顶部模式切换控件
  private lazy var modeSegmentedControl: NSSegmentedControl = {
    let control = NSSegmentedControl(
      labels: [
        SidebarStrings.localized(.folders),
        SidebarStrings.localized(.outline),
      ],
      trackingMode: .selectOne,
      target: self,
      action: #selector(modeSegmentChanged(_:))
    )
    control.translatesAutoresizingMaskIntoConstraints = false
    control.selectedSegment = 0
    control.segmentStyle = .texturedRounded
    return control
  }()

  /// 滚动视图
  private let scrollView: NSScrollView = {
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    return scrollView
  }()

  /// 大纲与文件树共用的原生 OutlineView
  private lazy var outlineView: NSOutlineView = {
    let outline = SidebarOutlineView()
    outline.autoresizingMask = [.width]
    outline.headerView = nil
    outline.backgroundColor = .clear
    outline.rowSizeStyle = .default
    outline.floatsGroupRows = false
    outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    outline.allowsMultipleSelection = false

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
    column.isEditable = false
    outline.addTableColumn(column)
    outline.outlineTableColumn = column

    outline.dataSource = self
    outline.delegate = self
    outline.target = self
    outline.action = #selector(handleOutlineClick(_:))
    return outline
  }()

  // MARK: - 生命周期

  override func loadView() {
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 480))
    self.view = container
    setUpLayout()
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // 监听窗口激活通知：仅在窗口激活时执行轻量级刷新，不做后台监听与磁盘写入
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    refreshContent()
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    // 若侧栏从窗口层级中彻底移除且窗口不可见，释放安全作用域权限
    if view.window == nil {
      securityScope.stopAccessing()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    securityScope.stopAccessing()
  }

  // MARK: - UI 布局

  private func setUpLayout() {
    view.addSubview(modeSegmentedControl)
    view.addSubview(scrollView)
    scrollView.documentView = outlineView

    NSLayoutConstraint.activate([
      modeSegmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      modeSegmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      modeSegmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      modeSegmentedControl.heightAnchor.constraint(equalToConstant: 24),

      scrollView.topAnchor.constraint(equalTo: modeSegmentedControl.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  // MARK: - 活跃编辑器获取

  /// 获取当前活跃的 EditorViewController（支持显式设置、容器子控制器或主窗口查找）
  var activeEditorViewController: EditorViewController? {
    if let hostViewController {
      return hostViewController
    }

    if let splitViewController = parent as? NSSplitViewController {
      for item in splitViewController.splitViewItems {
        if let editor = item.viewController as? EditorViewController {
          return editor
        }
      }
    }

    if let windowController = view.window?.windowController as? EditorWindowController {
      return windowController.contentViewController as? EditorViewController
    }

    if let windowController = NSApp.mainWindow?.windowController as? EditorWindowController {
      return windowController.contentViewController as? EditorViewController
    }

    return nil
  }

  // MARK: - 模式与数据刷新

  @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
    let mode = SidebarMode(rawValue: sender.selectedSegment) ?? .folder
    switchMode(mode)
  }

  /// 切换侧栏模式（文件夹树 / 大纲）
  func switchMode(_ mode: SidebarMode) {
    currentMode = mode
    modeSegmentedControl.selectedSegment = mode.rawValue
    refreshContent()
  }

  func refreshOutlineIfVisible() {
    if isViewLoaded, !view.isHidden, currentMode == .outline { refreshOutline() }
  }

  /// 仅在窗口激活或切换时调用的刷新
  func refreshContent() {
    switch currentMode {
    case .folder:
      refreshFolderTree()
    case .outline:
      refreshOutline()
    }
  }

  /// 刷新文件夹树（重置缓存并重新加载）
  private func refreshFolderTree() {
    let expanded = Set((0..<outlineView.numberOfRows).compactMap { row -> URL? in
      guard let item = outlineView.item(atRow: row) as? FileTreeItem, outlineView.isItemExpanded(item) else { return nil }
      return item.url
    })
    rootFolderItem?.invalidateChildren()
    outlineView.reloadData()
    var row = 0
    while row < outlineView.numberOfRows {
      if let item = outlineView.item(atRow: row) as? FileTreeItem, expanded.contains(item.url) {
        outlineView.expandItem(item)
      }
      row += 1
    }
  }

  /// 刷新文档大纲（异步读取 EditorViewController.tableOfContents）
  private func refreshOutline() {
    guard let editor = activeEditorViewController else {
      self.outlineRootItems = []
      self.outlineView.reloadData()
      return
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      let document = editor.document
      let headings = await editor.tableOfContents ?? []
      guard editor.document === document, currentMode == .outline else { return }
      self.outlineRootItems = OutlineItem.buildTree(from: headings)
      self.outlineView.reloadData()
      self.outlineView.expandItem(nil, expandChildren: true)
    }
  }

  @objc private func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === self.view.window else {
      return
    }
    // 仅窗口激活时刷新，无复杂事件监听或磁盘开销
    refreshContent()
  }

  // MARK: - 文件夹打开与安全作用域

  /// 打开选择文件夹的 NSOpenPanel
  @objc func openFolderPanel(_ sender: Any? = nil) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = SidebarStrings.localized(.openFolder)
    panel.message = SidebarStrings.localized(.selectFolderPrompt)
    panel.showsHiddenFiles = AppPreferences.General.showHiddenFiles

    guard let window = view.window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let selectedURL = panel.url else {
        return
      }
      self?.setRootFolder(selectedURL)
    }
  }

  /// 设置当前展示的根文件夹
  func setRootFolder(_ url: URL) {
    let canonical = url.resolvingSymlinksInPath().path
    securityScope.startAccessing(url: url)

    self.currentFolderURL = url
    self.rootFolderItem = FileTreeItem(
      url: url,
      isDirectory: true,
      isSymlink: false,
      canonicalPath: canonical,
      ancestorPaths: [canonical]
    )

    if currentMode != .folder {
      switchMode(.folder)
    } else {
      refreshFolderTree()
    }
  }
}

// MARK: - 点击与菜单响应

extension SidebarViewController {
  // MARK: - 交互点击处理

  @objc private func handleOutlineClick(_ sender: NSOutlineView) {
    let clickedRow = NSApp.currentEvent?.type == .keyDown ? sender.selectedRow : sender.clickedRow
    guard clickedRow >= 0, let item = sender.item(atRow: clickedRow) else {
      return
    }

    switch currentMode {
    case .folder:
      guard let fileItem = item as? FileTreeItem else { return }
      if fileItem.isOpenFolderAction {
        openFolderPanel(self)
        return
      }

      if fileItem.isDirectory {
        // 单击目录项切换折叠/展开
        if sender.isItemExpanded(fileItem) {
          sender.collapseItem(fileItem)
        } else {
          sender.expandItem(fileItem)
        }
      } else {
        // 单击文件：由 AppDocumentController 现有 openDocument 打开
        let fileURL = fileItem.url
        (NSDocumentController.shared as? AppDocumentController)?.openDocument(
          withContentsOf: fileURL, display: true
        ) { [weak self] document, _, error in
          if let error {
            NSApp.presentError(error)
            return
          }

          guard let folder = self?.currentFolderURL,
                let editor = document?.windowControllers.first?.contentViewController as? EditorViewController else {
            return
          }

          _ = editor.view
          editor.inkpotSidebar?.setRootFolder(folder)
          editor.inkpotSidebar?.view.isHidden = false
          editor.view.needsLayout = true
        }
      }

    case .outline:
      guard let outlineItem = item as? OutlineItem else { return }
      if let editor = activeEditorViewController {
        editor.startTextEditing()
        editor.bridge.toc.gotoHeader(headingInfo: outlineItem.headingInfo)
      }
    }
  }

  // MARK: - 菜单 Action 响应

  @objc func openFolderMenuAction(_ sender: Any?) {
    openFolderPanel(sender)
  }

  @objc func toggleSidebarMenuAction(_ sender: Any?) {
    let next = currentMode == .folder ? SidebarMode.outline : .folder
    switchMode(next)
  }
}

// MARK: - NSOutlineViewDataSource & Delegate

extension SidebarViewController {
  // MARK: - NSOutlineViewDataSource

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    switch currentMode {
    case .folder:
      if item == nil {
        // 根节点：如果未打开文件夹，显示单项“打开文件夹…”；已打开则展示操作项及顶层子项
        guard let root = rootFolderItem else {
          return 1
        }
        return 1 + root.loadChildrenIfNeeded().count
      }

      guard let fileItem = item as? FileTreeItem else { return 0 }
      return fileItem.loadChildrenIfNeeded().count

    case .outline:
      if item == nil {
        return outlineRootItems.count
      }
      guard let outlineItem = item as? OutlineItem else { return 0 }
      return outlineItem.children.count
    }
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    switch currentMode {
    case .folder:
      if item == nil {
        if index == 0 {
          return openFolderActionItem
        }
        guard let root = rootFolderItem else {
          return openFolderActionItem
        }
        let children = root.loadChildrenIfNeeded()
        let childIndex = index - 1
        if childIndex >= 0 && childIndex < children.count {
          return children[childIndex]
        }
        return openFolderActionItem
      }

      guard let fileItem = item as? FileTreeItem else { return NSObject() }
      let children = fileItem.loadChildrenIfNeeded()
      return children[index]

    case .outline:
      if item == nil {
        return outlineRootItems[index]
      }
      guard let outlineItem = item as? OutlineItem else { return NSObject() }
      return outlineItem.children[index]
    }
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    switch currentMode {
    case .folder:
      guard let fileItem = item as? FileTreeItem else { return false }
      if fileItem.isOpenFolderAction {
        return false
      }
      return fileItem.isDirectory

    case .outline:
      guard let outlineItem = item as? OutlineItem else { return false }
      return !outlineItem.children.isEmpty
    }
  }

  // MARK: - NSOutlineViewDelegate

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    let view = outlineView.makeView(withIdentifier: SidebarCellView.identifier, owner: self) as? SidebarCellView
      ?? SidebarCellView()
    view.identifier = SidebarCellView.identifier

    switch currentMode {
    case .folder:
      if let fileItem = item as? FileTreeItem {
        view.configure(with: fileItem)
      }
    case .outline:
      if let outlineItem = item as? OutlineItem {
        view.configure(with: outlineItem)
      }
    }

    return view
  }

  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    return 24
  }
}

private final class SidebarOutlineView: NSOutlineView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      if let action { NSApp.sendAction(action, to: target, from: self) }
    } else {
      super.keyDown(with: event)
    }
  }
}
