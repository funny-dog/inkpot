import AppKit
import XCTest

@MainActor
final class SessionRestoreTests: XCTestCase {
  private let suite = "SessionRestoreTests"
  // XCTest 为每个测试方法新建实例，目录与偏好域随实例隔离。
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionRestoreTests-\(UUID().uuidString)")
  private let defaults = UserDefaults(suiteName: "SessionRestoreTests") ?? .standard

  override func setUp() async throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDown() async throws {
    for document in NSDocumentController.shared.documents { document.close() }
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  private func file(_ name: String, _ text: String = "# 内容") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  // 测试进程没有应用的文档类型声明，按应用的读取方式直接建文档；已打开的同一文件返回现有文档。
  private func load(_ url: URL) throws -> (MVPDocument, Bool) {
    if let existing = NSDocumentController.shared.document(for: url) as? MVPDocument { return (existing, true) }
    let document = MVPDocument()
    try document.read(from: Data(contentsOf: url), ofType: "net.daringfireball.markdown")
    document.fileURL = url
    NSDocumentController.shared.addDocument(document)
    return (document, false)
  }

  func testLocationFollowsRenameAndTreatsDeletedOrTrashedAsMissing() throws {
    let folder = directory.appendingPathComponent("笔记")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let location = SessionLocation(folder)
    let renamed = directory.appendingPathComponent("笔记（改名）")
    try FileManager.default.moveItem(at: folder, to: renamed)
    XCTAssertEqual(location.resolve()?.path, renamed.standardizedFileURL.path)
    XCTAssertEqual(location.name, "笔记")
    try FileManager.default.removeItem(at: renamed)
    XCTAssertNil(location.resolve())
    let trashed = directory.appendingPathComponent(".Trash/旧笔记")
    try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
    XCTAssertNil(SessionLocation(trashed).resolve())
  }

  func testRecentFoldersDeduplicateKeepLatestFirstLimitAndClear() throws {
    let folders = RecentFolders(defaults: defaults)
    var urls: [URL] = []
    for index in 0..<12 {
      let url = directory.appendingPathComponent("文件夹\(index)")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      urls.append(url)
      folders.add(url)
    }
    folders.add(urls[5])
    XCTAssertEqual(folders.locations.count, RecentFolders.limit)
    XCTAssertEqual(folders.locations.first?.name, "文件夹5")
    XCTAssertEqual(folders.locations.filter { $0.name == "文件夹5" }.count, 1)
    XCTAssertFalse(folders.locations.contains { $0.name == "文件夹0" })
    folders.clear()
    XCTAssertTrue(folders.locations.isEmpty)
  }

  func testRecentFoldersMenuOpensExistingAndRemovesMissingWithNotice() throws {
    let folders = RecentFolders(defaults: defaults)
    let kept = directory.appendingPathComponent("保留")
    let gone = directory.appendingPathComponent("已删除")
    for url in [kept, gone] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); folders.add(url) }
    var opened: [URL] = []
    var missing: [String] = []
    let menu = RecentFoldersMenu(folders: folders, open: { opened.append($0) }, notifyMissing: { missing.append($0.name) })
    try FileManager.default.removeItem(at: gone)
    menu.rebuild()
    XCTAssertEqual(menu.menu.items.map(\.title), ["已删除", "保留", "", "清除菜单"])
    menu.openRecent(menu.menu.items[0])
    XCTAssertEqual(missing, ["已删除"])
    XCTAssertEqual(folders.locations.map(\.name), ["保留"])
    menu.openRecent(menu.menu.items[0])
    XCTAssertEqual(opened.map(\.lastPathComponent), ["保留"])
    let clear = try XCTUnwrap(menu.menu.items.last)
    XCTAssertTrue(menu.validateMenuItem(clear))
    menu.clearRecent(nil)
    XCTAssertFalse(menu.validateMenuItem(try XCTUnwrap(menu.menu.items.last)))
  }

  func testFileMenuListsRecentFoldersSubmenu() throws {
    let menu = MainMenu.make(delegate: AppDelegate())
    let item = try XCTUnwrap(menu.items[1].submenu?.items.first { $0.title == "打开最近的文件夹" })
    XCTAssertIdentical(item.submenu, RecentFoldersMenu.shared.menu)
  }

  func testCaptureAndRestoreWindowsTabsFoldersSidebarAndReportMissing() async throws {
    let first = try file("一.md"), second = try file("二.md"), third = try file("三.md"), lost = try file("丢失.md")
    let (one, _) = try load(first)
    one.makeWindowControllers()
    let window = try XCTUnwrap(one.windowControllers.first?.window)
    let container = try XCTUnwrap(window.contentViewController as? DocumentViewController)
    container.files.openFolder(directory)
    container.toggleContent(files: true)
    let (two, _) = try load(second)
    DocumentTabs.attach(two, to: window)
    let (lostDocument, _) = try load(lost)
    DocumentTabs.attach(lostDocument, to: window)
    window.tabGroup?.selectedWindow = two.windowControllers.first?.window
    let (three, _) = try load(third)
    three.makeWindowControllers()
    let separate = try XCTUnwrap(three.windowControllers.first?.window)
    (separate.contentViewController as? DocumentViewController)?.applySidebarState(collapsed: true, showingFiles: false, width: 0)
    // 未保存过、也没有文件夹的空白标签不记录。
    let blank = MVPDocument()
    NSDocumentController.shared.addDocument(blank)
    blank.makeWindowControllers()

    let state = DocumentSession.capture(windows: [window, separate, try XCTUnwrap(blank.windowControllers.first?.window)])
    XCTAssertEqual(state.windows.count, 2)
    // 新标签插在父窗口之后，标签栏顺序为 一、丢失、二。
    XCTAssertEqual(state.windows[0].tabs.map { $0.file?.name }, ["一.md", "丢失.md", "二.md"])
    XCTAssertEqual(state.windows[0].selectedTab, 2)
    XCTAssertEqual(state.windows[0].tabs[0].folder?.path, directory.standardizedFileURL.path)
    XCTAssertTrue(state.windows[0].tabs[0].showingFiles)
    XCTAssertFalse(state.windows[0].tabs[0].sidebarCollapsed)
    XCTAssertTrue(state.windows[1].tabs[0].sidebarCollapsed)
    DocumentSession.save(state, defaults: defaults)
    XCTAssertEqual(DocumentSession.load(defaults: defaults), state)

    for document in NSDocumentController.shared.documents { document.close() }
    try FileManager.default.removeItem(at: lost)
    let missing = await DocumentSession.restore(try XCTUnwrap(DocumentSession.load(defaults: defaults)), open: load)
    XCTAssertEqual(missing, ["丢失.md"])
    let restored = NSDocumentController.shared.documents.compactMap { $0 as? MVPDocument }
    XCTAssertEqual(Set(restored.compactMap { $0.fileURL?.lastPathComponent }), ["一.md", "二.md", "三.md"])
    let restoredOne = try XCTUnwrap(restored.first { $0.fileURL?.lastPathComponent == "一.md" }?.windowControllers.first?.window)
    let restoredTwo = try XCTUnwrap(restored.first { $0.fileURL?.lastPathComponent == "二.md" }?.windowControllers.first?.window)
    let restoredThree = try XCTUnwrap(restored.first { $0.fileURL?.lastPathComponent == "三.md" }?.windowControllers.first?.window)
    XCTAssertEqual(restoredOne.tabbedWindows?.map { ($0.windowController?.document as? MVPDocument)?.fileURL?.lastPathComponent }, ["一.md", "二.md"])
    XCTAssertIdentical(restoredOne.tabGroup?.selectedWindow, restoredTwo)
    XCTAssertNil(restoredThree.tabbedWindows)
    let restoredContainer = try XCTUnwrap(restoredTwo.contentViewController as? DocumentViewController)
    XCTAssertEqual(restoredContainer.files.root?.entry.url, directory.standardizedFileURL)
    XCTAssertTrue(restoredContainer.filesVisible)
    XCTAssertTrue(try XCTUnwrap(restoredThree.contentViewController as? DocumentViewController).sidebarState.collapsed)
  }

  func testWindowWhoseFilesAreAllMissingKeepsBlankWindowWithFolder() async throws {
    let gone = directory.appendingPathComponent("不存在.md")
    let tab = SessionState.Tab(file: SessionLocation(gone), folder: SessionLocation(directory), sidebarCollapsed: false, showingFiles: true, sidebarWidth: 260)
    let state = SessionState(windows: [.init(frame: NSStringFromRect(NSRect(x: 100, y: 100, width: 700, height: 500)), tabs: [tab], selectedTab: 0)])
    let missing = await DocumentSession.restore(state, open: load)
    XCTAssertEqual(missing, ["不存在.md"])
    let document = try XCTUnwrap(NSDocumentController.shared.documents.first as? MVPDocument)
    XCTAssertNil(document.fileURL)
    let container = try XCTUnwrap(document.windowControllers.first?.window?.contentViewController as? DocumentViewController)
    XCTAssertEqual(container.files.root?.entry.url, directory.standardizedFileURL)
    XCTAssertTrue(container.filesVisible)
  }

  func testStartupPreferenceSkipsRestoreWithoutDeletingSessionAndRespectsOpenedFiles() throws {
    let tab = SessionState.Tab(file: SessionLocation(try file("上次.md")), folder: nil, sidebarCollapsed: true, showingFiles: false, sidebarWidth: 260)
    let state = SessionState(windows: [.init(frame: "", tabs: [tab], selectedTab: 0)])
    DocumentSession.save(state, defaults: defaults)
    let settings = AppSettings(defaults: defaults)
    XCTAssertEqual(DocumentSession.loadForLaunch(restoringPreviousSession: settings.restorePreviousSession, hasOpenDocuments: false, defaults: defaults), state)
    XCTAssertNil(DocumentSession.loadForLaunch(restoringPreviousSession: settings.restorePreviousSession, hasOpenDocuments: true, defaults: defaults))
    settings.restorePreviousSession = false
    XCTAssertNil(DocumentSession.loadForLaunch(restoringPreviousSession: settings.restorePreviousSession, hasOpenDocuments: false, defaults: defaults))
    XCTAssertEqual(DocumentSession.load(defaults: defaults), state)
    settings.restorePreviousSession = true
    XCTAssertEqual(DocumentSession.loadForLaunch(restoringPreviousSession: settings.restorePreviousSession, hasOpenDocuments: false, defaults: defaults), state)
    defaults.removePersistentDomain(forName: suite)
    XCTAssertNil(DocumentSession.loadForLaunch(restoringPreviousSession: true, hasOpenDocuments: false, defaults: defaults))
  }
}
