import AppKit
import WebKit
import XCTest

@MainActor
final class DocumentTests: XCTestCase {
  func testNativeFormattingAndSearchShareEditorHistoryWithoutChangingSearchInputIntoDocument() async throws {
    _ = NSApplication.shared
    let document = MVPDocument()
    defer { document.close() }
    let original = "# 标题\r\n中文 中文\n尾"
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    editor.performCommand("heading2")
    try await waitUntil { editor.latestRevision > 0 }
    let formatted = try await editor.snapshot()
    XCTAssertEqual(formatted.text, "## 标题\r\n中文 中文\n尾")
    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertFalse(document.isDocumentEdited)

    editor.performCommand("find")
    try await waitUntil {
      try await webView.evaluateJavaScript("document.activeElement?.name === 'search'") as? Bool == true
    }
    let formatItem = NSMenuItem(title: "粗体", action: nil, keyEquivalent: "b")
    formatItem.representedObject = "bold"
    try await waitUntil { !editor.validateMenuItem(formatItem) }
    _ = try await webView.evaluateJavaScript("""
      const find = document.querySelector('input[name=search]');
      find.value = '中文'; find.dispatchEvent(new InputEvent('input', {bubbles: true})); null
      """)
    editor.selectAll(nil)
    try await waitUntil {
      try await webView.evaluateJavaScript("document.activeElement.selectionStart === 0 && document.activeElement.selectionEnd === 2") as? Bool == true
    }
    editor.performCommand("bold")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)

    _ = try await webView.evaluateJavaScript("""
      const replacement = document.querySelector('input[name=replace]');
      replacement.value = '替换'; replacement.dispatchEvent(new InputEvent('input', {bubbles: true}));
      document.querySelector('button[name=replaceAll]').click(); null
      """)
    let replaced = try await editor.snapshot()
    XCTAssertEqual(replaced.text, "# 标题\r\n替换 替换\n尾")
    _ = try await webView.evaluateJavaScript("document.querySelector('button[name=close]').click(); null")
    let replacedRevision = replaced.revision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > replacedRevision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testEditorSnapshotSaveAndBackupKeepLatestInputAndDirtyState() async throws {
    _ = NSApplication.shared
    let document = MVPDocument()
    defer { document.close() }
    let original = "# 中文\r\n<script>字面文本</script>\n"
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    let initialSnapshot = try await editor.snapshot()
    XCTAssertEqual(initialSnapshot.text, original)
    _ = try await webView.evaluateJavaScript(
      "document.querySelector('.cm-content').focus(); document.execCommand('insertText', false, '末字');"
    )
    try await waitUntil { editor.latestRevision > 0 }
    XCTAssertThrowsError(try document.data(ofType: "net.daringfireball.markdown"))
    try await document.synchronize()
    let updated = try document.data(ofType: "net.daringfireball.markdown")
    XCTAssertEqual(updated, Data(("末字" + original).utf8))
    XCTAssertTrue(document.isDocumentEdited)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try document.writeSafely(to: folder.appendingPathComponent("backup.md"), ofType: "net.daringfireball.markdown", for: .autosaveElsewhereOperation)
    try await document.synchronize()
    XCTAssertTrue(document.isDocumentEdited)
    try document.writeSafely(to: folder.appendingPathComponent("saved.md"), ofType: "net.daringfireball.markdown", for: .saveOperation)
    try await document.synchronize()
    XCTAssertFalse(document.isDocumentEdited)

    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertTrue(document.isDocumentEdited)
    _ = try await webView.evaluateJavaScript(
      "window.kernmarkMVP.snapshot = () => { throw new Error('模拟同步失败'); }; null"
    )
    do {
      try await document.synchronize()
      XCTFail("同步失败时不应允许保存旧快照")
    } catch {
      XCTAssertTrue(editor.isReady)
      XCTAssertThrowsError(try document.data(ofType: "net.daringfireball.markdown"))
    }
    editor.webViewWebContentProcessDidTerminate(webView)
    do {
      _ = try await editor.snapshot()
      XCTFail("编辑器停止后不应允许读取旧快照")
    } catch {
      XCTAssertThrowsError(try document.data(ofType: "net.daringfireball.markdown"))
    }
  }

  func testUneditedUTF8RoundTripsExactBytes() throws {
    for source in ["", "# 中文 👨‍👩‍👧\n", "a\r\nb\nc\rd\r\n", "e\u{301}\t  \n", "\u{FEFF}# BOM\r\n"] {
      let data = Data(source.utf8)
      let document = MVPDocument()
      try document.read(from: data, ofType: "net.daringfireball.markdown")
      XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), data)
    }
  }

  func testEditingRetainsBOMAndUnicodeBytes() throws {
    var content = try DocumentContent(data: Data("\u{FEFF}初始\r\n".utf8))
    content.text = "e\u{301}\r\n中文"
    XCTAssertEqual(content.data, Data("\u{FEFF}e\u{301}\r\n中文".utf8))
  }

  func testInvalidEncodingDoesNotReplaceLoadedDocument() throws {
    let document = MVPDocument()
    let original = Data("原文件\r\n".utf8)
    try document.read(from: original, ofType: "net.daringfireball.markdown")
    for invalid in [Data([0xFF, 0xFE, 0x41, 0x00]), Data([0xC3, 0x28]), Data([0xEF, 0xBB, 0xBF, 0xFF])] {
      XCTAssertThrowsError(try document.read(from: invalid, ofType: "net.daringfireball.markdown"))
      XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), original)
    }
  }

  func testSafeWriteAndFailedWriteKeepDocumentContent() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let document = MVPDocument()
    let data = Data("\u{FEFF}# 保存\r\n".utf8)
    try document.read(from: data, ofType: "net.daringfireball.markdown")
    let destination = folder.appendingPathComponent("note.md")
    try document.writeSafely(to: destination, ofType: "net.daringfireball.markdown", for: .saveOperation)
    XCTAssertEqual(try Data(contentsOf: destination), data)
    XCTAssertThrowsError(try document.writeSafely(
      to: folder.appendingPathComponent("missing/note.md"),
      ofType: "net.daringfireball.markdown",
      for: .saveOperation
    ))
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), data)
    XCTAssertEqual(try Data(contentsOf: destination), data)
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else {
        throw NSError(domain: "KernmarkMVPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待编辑器状态超时"])
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}
