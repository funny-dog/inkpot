import AppKit
import WebKit
import XCTest

@MainActor
final class FileTreeTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func load(_ url: URL) throws -> (InkpotDocument, Bool) {
    let next = InkpotDocument()
    try next.read(from: Data(contentsOf: url), ofType: "net.daringfireball.markdown")
    next.fileURL = url
    NSDocumentController.shared.addDocument(next)
    return (next, false)
  }

  private func document(_ text: String, at url: URL) async throws -> (InkpotDocument, NSWindowController, EditorViewController) {
    _ = NSApplication.shared
    let document = InkpotDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    document.fileURL = url
    NSDocumentController.shared.addDocument(document)
    document.makeWindowControllers()
    let editor = try XCTUnwrap(document.editor)
    _ = editor.view
    try await waitUntil { editor.isReady }
    return (document, try XCTUnwrap(document.windowControllers.first), editor)
  }

  func testDirectoryListingFiltersPackagesLinksAndHiddenFilesAndSortsNaturally() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["10.MD", "2.md", "readme.markdown", "纯文本.txt", "image.png", ".hidden.md"] {
      try Data().write(to: root.appendingPathComponent(name))
    }
    for name in ["docs", "empty", ".git", "Demo.app"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("2.md"))
    let entries = try FolderEntry.read(root)
    XCTAssertEqual(entries.filter(\.isDirectory).map { $0.url.lastPathComponent }, ["docs", "empty"])
    let names = entries.filter { !$0.isDirectory }.map { $0.url.lastPathComponent }
    XCTAssertEqual(Array(names.prefix(2)), ["2.md", "10.MD"])
    XCTAssertEqual(Set(names), Set(["2.md", "10.MD", "readme.markdown", "纯文本.txt"]))
    XCTAssertTrue(entries.prefix(2).allSatisfy(\.isDirectory))
    XCTAssertThrowsError(try FolderEntry.read(root.appendingPathComponent("missing")))
  }

  func testTreeLoadsLazilyRefreshesAndIgnoresPreviousFolderResults() async throws {
    _ = NSApplication.shared
    let root = try folder()
    let other = try folder()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
    let sub = root.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let file = sub.appendingPathComponent("a.md")
    try Data("# A".utf8).write(to: file)
    let tree = FileTreeViewController()
    tree.openFolder(root)
    try await waitUntil { tree.root?.children?.count == 1 }
    let directory = try XCTUnwrap(tree.root?.children?.first)
    XCTAssertNil(directory.children)
    tree.outlineView.expandItem(directory)
    try await waitUntil { directory.children?.count == 1 }
    XCTAssertTrue(tree.outlineView.isItemExpanded(directory))
    tree.selectCurrentFile(file)
    XCTAssertEqual(tree.outlineView.selectedRow, 1)
    let cached = directory.children?.first
    try Data().write(to: sub.appendingPathComponent("b.txt"))
    tree.refresh(nil)
    try await waitUntil { directory.children?.count == 2 }
    XCTAssertIdentical(cached, directory.children?.first)
    XCTAssertTrue(tree.outlineView.isItemExpanded(directory))
    tree.outlineView.collapseItem(directory)
    tree.refresh(nil)
    try await waitUntil { tree.root?.loading == false }
    XCTAssertFalse(tree.outlineView.isItemExpanded(directory))
    tree.openFolder(root)
    tree.openFolder(other)
    try await waitUntil { tree.root?.entry.url == other && tree.root?.children != nil }
    XCTAssertEqual(tree.outlineView.numberOfRows, 0)
    tree.openFolder(root.appendingPathComponent("missing"))
    try await waitUntil { tree.root?.error != nil }
    XCTAssertEqual(tree.root?.loading, false)
    XCTAssertEqual(tree.outlineView.numberOfRows, 0)
  }

  func testSwitchReusesWindowAndEditorAndRejectsLatePreviousDocumentMessages() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("a.md")
    let targetURL = root.appendingPathComponent("b.md")
    let source = "\u{FEFF}# A\r\n原文\n"
    let target = "\u{FEFF}# B\r\n目标\n"
    try Data(source.utf8).write(to: sourceURL)
    try Data(target.utf8).write(to: targetURL)
    let (current, window, editor) = try await document(source, at: sourceURL)
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    defer { (window.document as? InkpotDocument)?.close() }
    let container = window.window?.contentViewController
    let session = DocumentFileSwitch(openDocument: load)
    let opened = try await session.open(targetURL, in: window)
    let next = try XCTUnwrap(opened)
    XCTAssertIdentical(window.document, next)
    XCTAssertIdentical(next.editor, editor)
    XCTAssertNil(current.editor)
    XCTAssertIdentical(window.window?.contentViewController, container)
    XCTAssertEqual(next.fileURL, targetURL)
    XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === current })
    try await waitUntil { editor.isReady && editor.headings.first?.title == "B" }
    let undoItem = NSMenuItem(title: "撤销", action: #selector(EditorViewController.undo(_:)), keyEquivalent: "z")
    XCTAssertFalse(editor.validateMenuItem(undoItem))
    _ = try await webView.evaluateJavaScript("""
      window.webkit.messageHandlers.document.postMessage({
        changed: true, generation: 1, revision: 999, canUndo: true, canRedo: true,
        searchInputFocused: false, editorFocused: true, sourceMode: true
      }); null
      """)
    try await next.synchronize()
    XCTAssertEqual(editor.latestRevision, 0)
    XCTAssertFalse(next.isDocumentEdited)
    XCTAssertEqual(try next.data(ofType: "net.daringfireball.markdown"), Data(target.utf8))
    XCTAssertEqual(try Data(contentsOf: sourceURL), Data(source.utf8))
    let files = try XCTUnwrap((container as? DocumentViewController)?.files)
    files.openFolder(root)
    files.selectCurrentFile(targetURL)
    try await waitUntil { files.outlineView.selectedRow == 1 }
    next.fileURL = sourceURL
    XCTAssertEqual(files.outlineView.selectedRow, 0)
  }

  func testCancelledSwitchKeepsUnsavedTextHistoryAndCurrentFile() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("a.md")
    let targetURL = root.appendingPathComponent("b.md")
    let source = "\u{FEFF}# A\r\n原文"
    try Data(source.utf8).write(to: sourceURL)
    try Data("# B".utf8).write(to: targetURL)
    let (current, window, editor) = try await document(source, at: sourceURL)
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    defer { current.close() }
    _ = try await webView.evaluateJavaScript("document.execCommand('insertText', false, '未保存'); null")
    try await waitUntil { editor.latestRevision > 0 }
    let before = try await editor.snapshot()
    var confirmed = false
    let session = DocumentFileSwitch(openDocument: load) { document in
      confirmed = true
      XCTAssertTrue(document.isDocumentEdited)
      return false
    }
    _ = try await session.open(targetURL, in: window)
    XCTAssertTrue(confirmed)
    XCTAssertIdentical(window.document, current)
    XCTAssertIdentical(current.editor, editor)
    let after = try await editor.snapshot()
    XCTAssertEqual(after.text, before.text)
    XCTAssertEqual(try Data(contentsOf: sourceURL), Data(source.utf8))
    XCTAssertFalse(NSDocumentController.shared.documents.contains { $0.fileURL == targetURL })
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > before.revision }
    try await current.synchronize()
    XCTAssertFalse(current.isDocumentEdited)
    XCTAssertEqual(try current.data(ofType: "net.daringfireball.markdown"), Data(source.utf8))
  }

  func testReadFailureAndAlreadyOpenTargetDoNotCloseOrReplaceCurrentDocument() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("a.md")
    let badURL = root.appendingPathComponent("bad.md")
    try Data([0xFF, 0xFE]).write(to: badURL)
    let (current, window, editor) = try await document("# A", at: sourceURL)
    defer { current.close() }
    var confirmations = 0
    let session = DocumentFileSwitch(openDocument: load) { _ in confirmations += 1; return true }
    do {
      _ = try await session.open(badURL, in: window)
      XCTFail("无效编码必须拒绝打开")
    } catch { XCTAssertIdentical(window.document, current) }
    do {
      _ = try await session.open(root.appendingPathComponent("missing.md"), in: window)
      XCTFail("不存在的文件必须报告错误")
    } catch { XCTAssertIdentical(current.editor, editor) }
    let existing = InkpotDocument()
    defer { existing.close() }
    let alreadyOpen = DocumentFileSwitch(openDocument: { _ in (existing, true) }, confirmClose: { _ in
      XCTFail("已打开文件应激活现有窗口，不关闭当前文档")
      return false
    })
    _ = try await alreadyOpen.open(badURL, in: window)
    XCTAssertIdentical(window.document, current)
    XCTAssertEqual(confirmations, 0)
    XCTAssertFalse(session.isOpening)
  }
}

extension FileTreeTests {
  func testSwitchSerializesRapidRequestsAndKeepsCurrentDocumentWhenSnapshotFails() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("a.md")
    let targetURL = root.appendingPathComponent("b.md")
    try Data("# B".utf8).write(to: targetURL)
    let (current, window, editor) = try await document("# A", at: sourceURL)
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    defer { current.close() }
    var pending: CheckedContinuation<(InkpotDocument, Bool), Never>?
    var loads = 0
    let session = DocumentFileSwitch(openDocument: { _ in
      loads += 1
      return await withCheckedContinuation { pending = $0 }
    }, confirmClose: { _ in false })
    let first = Task { try await session.open(targetURL, in: window) }
    try await waitUntil { pending != nil }
    let ignored = try await session.open(targetURL, in: window)
    XCTAssertNil(ignored)
    XCTAssertEqual(loads, 1)
    pending?.resume(returning: try load(targetURL))
    _ = try await first.value
    XCTAssertFalse(session.isOpening)
    XCTAssertIdentical(window.document, current)
    _ = try await webView.evaluateJavaScript("""
      const savedSnapshot = window.inkpot.snapshot;
      window.inkpot.snapshot = () => { throw new Error('测试同步失败'); }; null
      """)
    let failing = DocumentFileSwitch(openDocument: load) { _ in
      XCTFail("读取旧快照失败时不能进入关闭确认")
      return true
    }
    do {
      _ = try await failing.open(targetURL, in: window)
      XCTFail("快照失败必须阻止切换")
    } catch { XCTAssertIdentical(window.document, current) }
    XCTAssertIdentical(current.editor, editor)
    XCTAssertFalse(NSDocumentController.shared.documents.contains { $0.fileURL == targetURL })
    _ = try await webView.evaluateJavaScript("window.inkpot.snapshot = savedSnapshot; null")
    try await current.synchronize()
    XCTAssertFalse(current.isDocumentEdited)
  }
}
