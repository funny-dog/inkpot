import AppKit
import WebKit
import XCTest

@MainActor
final class FolderSearchTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  private func write(_ text: String, _ relativePath: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testRecursiveSearchSkipsHiddenPackagesAndLinks() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("搜索", "首页.md", in: root)
    try write("搜索", "notes/a.markdown", in: root)
    try write("搜索", "notes/b.txt", in: root)
    try write("搜索", "notes/cover.png", in: root)
    try write("搜索", ".hidden.md", in: root)
    try write("搜索", ".git/config.md", in: root)
    try write("搜索", "Demo.app/inside.md", in: root)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link.md"),
      withDestinationURL: root.appendingPathComponent("首页.md")
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linkdir"),
      withDestinationURL: root.appendingPathComponent("notes")
    )
    let result = FolderSearch.search(in: root, query: "搜索")
    XCTAssertFalse(result.cancelled)
    XCTAssertFalse(result.truncated)
    XCTAssertEqual(Set(result.files.map(\.relativePath)), ["首页.md", "notes/a.markdown", "notes/b.txt"])
    XCTAssertEqual(result.matchCount, 3)
  }

  func testSearchIsCaseInsensitiveAndReportsLineColumnAndHighlight() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("第一行\nHello World\nHELLO\nhello", "cases.md", in: root)
    let matches = try XCTUnwrap(FolderSearch.search(in: root, query: "hello").files.first?.matches)
    XCTAssertEqual(matches.map(\.line), [2, 3, 4])
    XCTAssertEqual(matches.map(\.column), [0, 0, 0])
    XCTAssertEqual(matches.map(\.length), [5, 5, 5])
    XCTAssertEqual(matches[0].snippet, "Hello World")
    XCTAssertEqual(matches[0].highlight, NSRange(location: 0, length: 5))
  }

  func testChineseContentAndCRLFLineEndingsKeepUTF16Offsets() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("标题\r\n这里有全文搜索功能\r\n尾", "中文.md", in: root)
    let matches = try XCTUnwrap(FolderSearch.search(in: root, query: "搜索").files.first?.matches)
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches[0].line, 2)
    XCTAssertEqual(matches[0].column, 5)
    XCTAssertEqual(matches[0].length, 2)
    XCTAssertEqual(matches[0].snippet, "这里有全文搜索功能")
    XCTAssertEqual(matches[0].highlight, NSRange(location: 5, length: 2))
  }

  func testLongLinesKeepTheKeywordInsideAShortSnippet() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let prefix = String(repeating: "前", count: 400)
    try write(prefix + "关键词" + String(repeating: "后", count: 400), "long.md", in: root)
    let match = try XCTUnwrap(FolderSearch.search(in: root, query: "关键词").files.first?.matches.first)
    XCTAssertLessThan(match.snippet.utf16.count, FolderSearch.snippetLimit + 3)
    XCTAssertTrue(match.snippet.contains("关键词"))
    let range = NSRange(location: 0, length: (match.snippet as NSString).length)
    XCTAssertTrue(NSLocationInRange(match.highlight.location, range))
    XCTAssertEqual((match.snippet as NSString).substring(with: match.highlight), "关键词")
  }

  func testResultLimitTruncatesAndMarksTheResult() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let line = String(repeating: "命中 ", count: 5)
    try write((0..<4).map { _ in line }.joined(separator: "\n"), "many.md", in: root)
    XCTAssertEqual(FolderSearch.resultLimit, 1000)
    let limited = FolderSearch.search(in: root, query: "命中", limit: 7)
    XCTAssertEqual(limited.matchCount, 7)
    XCTAssertTrue(limited.truncated)
    XCTAssertEqual(limited.files.reduce(0) { $0 + $1.matches.count }, 7)
    let exact = FolderSearch.search(in: root, query: "命中", limit: 20)
    XCTAssertEqual(exact.matchCount, 20)
    XCTAssertFalse(exact.truncated)
  }

  func testCancellationStopsTheScanEarly() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<5 { try write("关键词", "f\(index).md", in: root) }
    var checks = 0
    let result = FolderSearch.search(in: root, query: "关键词") {
      checks += 1
      return checks > 2
    }
    XCTAssertTrue(result.cancelled)
    XCTAssertLessThan(result.matchCount, 5)
  }

  func testSkipsFilesOverSizeLimitAndInvalidUTF8() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("关键词", "ok.md", in: root)
    var oversized = Data("关键词\n".utf8)
    oversized.append(Data(repeating: 0x61, count: FolderSearch.fileSizeLimit + 1))
    try oversized.write(to: root.appendingPathComponent("big.md"))
    try Data([0xFF, 0xFE, 0x00, 0x47]).write(to: root.appendingPathComponent("bad.md"))
    let result = FolderSearch.search(in: root, query: "关键词")
    XCTAssertEqual(result.files.map(\.relativePath), ["ok.md"])
    XCTAssertEqual(result.matchCount, 1)
  }

  func testFindInFolderShowsSearchPageAndPromptsWithoutFolder() async throws {
    _ = NSApplication.shared
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let (document, window, controller, _) = try await makeDocument(at: root.appendingPathComponent("none.md"))
    defer { (window.document as? MVPDocument)?.close() }
    XCTAssertFalse(controller.searchVisible)
    controller.findInFolder(nil)
    XCTAssertTrue(controller.searchVisible)
    XCTAssertNil(controller.search.folderURL)
    XCTAssertEqual(controller.search.statusText, "未打开文件夹")
    XCTAssertFalse(controller.search.searchField.isEnabled)
    controller.files.openFolder(root)
    XCTAssertEqual(controller.search.folderURL, root.standardizedFileURL)
    XCTAssertTrue(controller.search.searchField.isEnabled)
    XCTAssertEqual(controller.search.statusText, "输入关键词搜索当前文件夹")
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testSearchPageDebouncesAndReplacesThePreviousQuery() async throws {
    _ = NSApplication.shared
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("无关内容", "a.md", in: root)
    try write("关键词", "b.md", in: root)
    let page = FolderSearchViewController()
    _ = page.view
    page.debounceInterval = .milliseconds(10)
    page.folderURL = root
    page.beginSearch("无关")
    page.beginSearch("关键词")
    try await waitUntil { !page.isSearching && page.result.matchCount == 1 }
    XCTAssertEqual(page.result.files.map(\.relativePath), ["b.md"])
    XCTAssertEqual(page.statusText, "1 个文件 · 1 处匹配")
    page.beginSearch("没有这个词")
    try await waitUntil { !page.isSearching && page.result.matchCount == 0 }
    XCTAssertEqual(page.statusText, "没有找到匹配内容")
  }

  func testOpeningSearchResultSwitchesFileAndSelectsTheMatch() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try write("# 甲\n开头\n", "a.md", in: root)
    let target = "第一行\n这里有关键词内容\n尾行\n"
    let second = try write(target, "b.md", in: root)
    let (document, window, controller, editor) = try await makeDocument(at: first)
    defer { (window.document as? MVPDocument)?.close() }
    controller.fileSwitch = DocumentFileSwitch(openDocument: load, confirmClose: { _ in true })
    controller.files.openFolder(root)
    let result = FolderSearch.search(in: root, query: "关键词")
    let match = try XCTUnwrap(result.files.first?.matches.first)
    XCTAssertEqual(match.url, second.standardizedFileURL)
    XCTAssertEqual(match.line, 2)
    controller.openFile(match.url, match: match)
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { (window.document as? MVPDocument)?.fileURL?.standardizedFileURL == second.standardizedFileURL }
    // 隐藏窗口中的 WebView 在聚焦切换期间可能拒绝并发求值，轮询时按否处理并重试。
    try await waitUntil {
      let selection = try? await webView.evaluateJavaScript("window.getSelection()?.toString() ?? ''")
      return (selection as? String) == "关键词"
    }
    let opened = try XCTUnwrap(window.document as? MVPDocument)
    XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === document })
    try await opened.synchronize()
    XCTAssertEqual(try opened.data(ofType: "net.daringfireball.markdown"), Data(target.utf8))
    XCTAssertFalse(opened.isDocumentEdited)
  }

  func testMenuExposesFindInFolderWithShiftCommandF() throws {
    _ = NSApplication.shared
    let menu = MainMenu.make(delegate: AppDelegate())
    let item = try XCTUnwrap(menu.items[2].submenu?.items.first { $0.title == "在文件夹中查找…" })
    XCTAssertEqual(item.action, #selector(DocumentViewController.findInFolder(_:)))
    XCTAssertNil(item.target)
    XCTAssertEqual(item.keyEquivalent, "f")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
  }
}

extension FolderSearchTests {
  private func makeDocument(at url: URL) async throws -> (MVPDocument, NSWindowController, DocumentViewController, EditorViewController) {
    _ = NSApplication.shared
    let document = MVPDocument()
    if FileManager.default.fileExists(atPath: url.path) {
      try document.read(from: Data(contentsOf: url), ofType: "net.daringfireball.markdown")
    }
    document.fileURL = url
    NSDocumentController.shared.addDocument(document)
    document.makeWindowControllers()
    let window = document.windowControllers.first
    let controller = window?.window?.contentViewController as? DocumentViewController
    let editor = document.editor
    _ = editor?.view
    let ready = try XCTUnwrap(editor)
    try await waitUntil { ready.isReady }
    return (
      document,
      try XCTUnwrap(window),
      try XCTUnwrap(controller),
      ready
    )
  }

  private func load(_ url: URL) async throws -> (MVPDocument, Bool) {
    let document = MVPDocument()
    try document.read(from: Data(contentsOf: url), ofType: "net.daringfireball.markdown")
    document.fileURL = url
    NSDocumentController.shared.addDocument(document)
    return (document, false)
  }
}
