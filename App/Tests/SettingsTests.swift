import AppKit
import WebKit
import XCTest

@MainActor
final class SettingsTests: XCTestCase {
  private let suite = "SettingsTests"
  // XCTest 为每个测试方法新建实例，目录与偏好域随实例隔离。
  private let defaults = UserDefaults(suiteName: "SettingsTests") ?? .standard
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsTests-\(UUID().uuidString)")

  override func setUp() async throws {
    _ = NSApplication.shared
    defaults.removePersistentDomain(forName: suite)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
    AppSettings.shared.defaultSourceMode = false
    AppSettings.shared.appearanceMode = .system
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func document(_ text: String, url: URL? = nil) async throws -> (InkpotDocument, EditorViewController, WKWebView) {
    let document = InkpotDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    if let url {
      try Data(text.utf8).write(to: url)
      document.fileURL = url
      document.fileType = "net.daringfireball.markdown"
      document.fileModificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    return (document, editor, web)
  }

  func testDefaultsAndImageFolderValidation() {
    let settings = AppSettings(defaults: defaults)
    XCTAssertTrue(settings.restorePreviousSession)
    XCTAssertFalse(settings.focusMode)
    XCTAssertFalse(settings.typewriterMode)
    XCTAssertFalse(settings.defaultSourceMode)
    XCTAssertEqual(settings.appearanceMode, .system)
    XCTAssertFalse(settings.autosave)
    XCTAssertEqual(settings.imageFolder, "assets")
    for valid in ["图片", "my images", "assets-2"] { XCTAssertEqual(AppSettings.validImageFolder(" \(valid) "), valid) }
    for invalid in ["", "  ", ".hidden", "a/b", "a:b", "..", String(repeating: "长", count: 65)] { XCTAssertNil(AppSettings.validImageFolder(invalid)) }
    settings.imageFolderInput = "a/b"
    XCTAssertEqual(settings.imageFolder, "assets")
    settings.imageFolderInput = "图片 素材"
    XCTAssertEqual(AppSettings(defaults: defaults).imageFolder, "图片 素材")
  }

  func testStartupPreferencePersistsAndCanBeReenabled() {
    let settings = AppSettings(defaults: defaults)
    settings.restorePreviousSession = false
    XCTAssertFalse(AppSettings(defaults: defaults).restorePreviousSession)
    settings.restorePreviousSession = true
    XCTAssertTrue(AppSettings(defaults: defaults).restorePreviousSession)
  }

  func testPairingAndImagePreferencesPersistWithSafeDefaults() {
    let settings = AppSettings(defaults: defaults)
    XCTAssertTrue(settings.pairBrackets)
    XCTAssertTrue(settings.pairMarkdown)
    XCTAssertFalse(settings.loadRemoteImages)
    settings.pairBrackets = false
    settings.pairMarkdown = false
    settings.loadRemoteImages = true
    let reloaded = AppSettings(defaults: defaults)
    XCTAssertFalse(reloaded.pairBrackets)
    XCTAssertFalse(reloaded.pairMarkdown)
    XCTAssertTrue(reloaded.loadRemoteImages)
    let url = root.appendingPathComponent("中文笔记.md")
    XCTAssertEqual(settings.imageFolder(beside: url), "assets")
    settings.documentImageFolder = true
    XCTAssertEqual(settings.imageFolder(beside: url), "中文笔记.assets")
    XCTAssertEqual(settings.imageFolder(beside: root.appendingPathComponent(".hidden.md")), "文档.assets")
  }

  func testChosenImageFolderIndentAndZoomPreferences() throws {
    let settings = AppSettings(defaults: defaults)
    let document = root.appendingPathComponent("文稿/笔记.md")
    settings.customImageFolder = root.appendingPathComponent("图片 素材/博客")
    XCTAssertEqual(settings.imageFolder(beside: document), "../图片 素材/博客")
    settings.customImageFolder = root.appendingPathComponent("文稿")
    XCTAssertEqual(settings.imageFolder(beside: document), ".")
    settings.documentImageFolder = true
    XCTAssertEqual(settings.imageFolder(beside: document), "笔记.assets")
    settings.documentImageFolder = false
    settings.customImageFolder = nil
    XCTAssertEqual(settings.imageFolder(beside: document), "assets")

    XCTAssertEqual(settings.indentWidth, 2)
    settings.indentWidth = 4
    XCTAssertEqual(AppSettings(defaults: defaults).indentWidth, 4)
    XCTAssertTrue(try settings.editingScript().contains("\"indent\":4"))
    settings.indentWidth = 3
    XCTAssertEqual(settings.indentWidth, 2)

    let zoom = EditorZoom(defaults: defaults)
    XCTAssertEqual(zoom.level, 1)
    zoom.zoomIn(nil)
    XCTAssertEqual(zoom.level, 1.1)
    zoom.level = 0.1
    XCTAssertEqual(zoom.level, 0.5)
    zoom.zoomOut(nil)
    XCTAssertEqual(zoom.level, 0.5)
    zoom.resetZoom(nil)
    XCTAssertEqual(settings.zoomLevel, 1)
  }

  func testExplicitPlainPasteAndMarkdownCopyPreserveSourceAndUndo() async throws {
    let original = "**中文**\r\n尾\n"
    let (document, editor, _) = try await document(original)
    defer { document.close() }
    _ = try await editor.evaluateScript("window.inkpot.selectMatch(1, 0, 6); null")
    let copied = try await editor.evaluateScript("window.inkpot.selectedMarkdown()") as? String
    XCTAssertEqual(copied, "**中文**")
    _ = try await editor.evaluateScript("window.inkpot.pastePlainText('# 原样 **粘贴**'); null")
    let pasted = try await editor.snapshot()
    XCTAssertEqual(pasted.text, "# 原样 **粘贴**\r\n尾\n")
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > pasted.revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  func testDisplayModeSettingsShareMenuPreferencesAndNotifications() {
    let settings = AppSettings(defaults: defaults)
    let modes = DisplayModes(defaults: defaults)
    let notified = expectation(forNotification: DisplayModes.didChange, object: nil)
    settings.focusMode = true
    wait(for: [notified], timeout: 1)
    XCTAssertTrue(modes.focusEnabled)
    XCTAssertFalse(modes.typewriterEnabled)
    settings.typewriterMode = true
    XCTAssertTrue(modes.typewriterEnabled)
    XCTAssertTrue(AppSettings(defaults: defaults).focusMode)
    XCTAssertTrue(AppSettings(defaults: defaults).typewriterMode)
    modes.toggleFocusMode(nil)
    modes.toggleTypewriterMode(nil)
    XCTAssertFalse(settings.focusMode)
    XCTAssertFalse(settings.typewriterMode)
  }

  func testImagesStoreInConfiguredFolderWithEscapedMarkdownPath() throws {
    let documentURL = root.appendingPathComponent("文档.md")
    let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
    let stored = try LocalImages.store(png, beside: documentURL, folderName: "图片 (素材)")
    XCTAssertTrue(stored.path.hasPrefix("图片%20%28素材%29/image-"))
    XCTAssertEqual(stored.url.deletingLastPathComponent().lastPathComponent, "图片 (素材)")
    XCTAssertEqual(try LocalImages.read(stored.path, relativeTo: documentURL).0, png)
  }

  func testAppearanceModeSetsApplicationAppearance() {
    let settings = AppSettings(defaults: defaults)
    settings.appearanceMode = .dark
    XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
    XCTAssertTrue(Appearance.isDark)
    settings.appearanceMode = .light
    XCTAssertEqual(NSApp.appearance?.name, .aqua)
    XCTAssertFalse(Appearance.isDark)
    settings.appearanceMode = .system
    XCTAssertNil(NSApp.appearance)
    XCTAssertEqual(AppSettings(defaults: defaults).appearanceMode, .system)
  }

  func testDefaultSourceModeOpensDocumentsInSourceModeWithoutEditing() async throws {
    AppSettings.shared.defaultSourceMode = true
    let (document, editor, web) = try await document("**粗体**")
    defer { document.close() }
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-source') !== null") as? Bool == true }
    let item = NSMenuItem(title: "源码模式", action: nil, keyEquivalent: "")
    item.representedObject = "toggleSourceMode"
    try await waitUntil { _ = editor.validateMenuItem(item); return item.state == .on }
    XCTAssertFalse(document.isDocumentEdited)
    AppSettings.shared.defaultSourceMode = false
    editor.replaceText("新内容")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-live') !== null") as? Bool == true }
  }

  func testAutosaveWritesAfterIdleSkipsUntitledAndSuspendsAfterFailure() async throws {
    DocumentAutosave.delay = .milliseconds(100)
    defer { DocumentAutosave.delay = .seconds(2) }
    let url = root.appendingPathComponent("自动.md")
    let (document, editor, web) = try await document("原文\r\n", url: url)
    defer { document.close() }
    var reported: [String] = []
    let autosave = DocumentAutosave(document: document, isEnabled: { true }, report: { _, error in reported.append(error.localizedDescription) })
    _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, '新'); null")
    try await waitUntil { editor.latestRevision > 0 && document.isDocumentEdited }
    autosave.schedule()
    try await waitUntil { (try? Data(contentsOf: url)) == Data("新原文\r\n".utf8) }
    try await waitUntil { !document.isDocumentEdited }

    // 外部修改后自动保存不覆盖，暂停并保留窗口中的内容。
    try await Task.sleep(for: .milliseconds(1100))
    try Data("外部\r\n".utf8).write(to: url)
    _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, '再'); null")
    try await waitUntil { editor.latestRevision > 1 }
    await autosave.saveNow()
    XCTAssertTrue(autosave.suspended)
    XCTAssertEqual(reported.count, 1)
    XCTAssertEqual(reported.first?.hasPrefix("自动保存已暂停"), true)
    XCTAssertEqual(try Data(contentsOf: url), Data("外部\r\n".utf8))
    // 暂停后继续编辑不再尝试保存，也不重复提示。
    await autosave.saveNow()
    XCTAssertEqual(reported.count, 1)

    let (untitled, untitledEditor, untitledWeb) = try await self.document("空白")
    defer { untitled.close() }
    let disabled = DocumentAutosave(document: untitled, isEnabled: { true }, report: { _, _ in XCTFail("未保存过的文档不应自动保存") })
    _ = try await untitledWeb.evaluateJavaScript("document.execCommand('insertText', false, '字'); null")
    try await waitUntil { untitledEditor.latestRevision > 0 }
    await disabled.saveNow()
    XCTAssertTrue(untitled.isDocumentEdited)
    XCTAssertFalse(disabled.suspended)
  }

  func testSettingsMenuItemAndWindow() async throws {
    let delegate = AppDelegate()
    let menu = MainMenu.make(delegate: delegate)
    let item = try XCTUnwrap(menu.items[0].submenu?.items.first { $0.title == "设置…" })
    XCTAssertEqual(item.keyEquivalent, ",")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    XCTAssertIdentical(item.target, delegate)
    XCTAssertTrue(delegate.validateMenuItem(item))
    delegate.showSettings(nil)
    let controller = SettingsWindowController.shared
    let window = try XCTUnwrap(controller.window)
    XCTAssertTrue(window.isVisible)
    // 工具栏式分类：通用、编辑、外观三页，窗口标题跟随当前分类。
    XCTAssertEqual(controller.tabs.tabStyle, .toolbar)
    XCTAssertEqual(controller.tabs.tabViewItems.map(\.label), ["通用", "编辑", "外观"])
    XCTAssertEqual(window.toolbar?.items.count, 3)
    for pane in SettingsPane.allCases {
      controller.show(pane)
      XCTAssertEqual(controller.selectedPane, pane)
      try await waitUntil { window.title == pane.title }
      try await waitUntil { window.contentView?.frame.width == SettingsWindowController.contentWidth }
      // 固定大小：各分类高度一致，且不能拖动缩放。
      try await waitUntil { window.contentLayoutRect.height == SettingsWindowController.contentHeight }
      XCTAssertFalse(window.styleMask.contains(.resizable))
      XCTAssertLessThanOrEqual(window.frame.height, try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame.height)
    }
    controller.show(.general)
    window.close()
  }
}
