import AppKit
import WebKit
import XCTest

@MainActor
final class MathTests: XCTestCase {
  private let original = "\u{FEFF}行内 $x^2$ 公式\r\n\r\n$$\r\nE = mc^2\n$$\r\n\r\n尾行"

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeDocument(_ text: String) async throws -> (MVPDocument, EditorViewController, WKWebView) {
    _ = NSApplication.shared
    let document = MVPDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    return (document, editor, web)
  }

  private func menu(_ command: String) -> NSMenuItem {
    let item = NSMenuItem(title: command, action: nil, keyEquivalent: "")
    item.representedObject = command
    return item
  }

  func testMathRendersFromBundleAssetsAndPreservesOriginalBytes() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    // 真实 WKWebView 中从应用包加载 KaTeX（scheme 资源、跨域模块与字体）并渲染两个公式。
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelectorAll('.cm-mvp-math').length === 2 && document.querySelectorAll('.cm-mvp-math .katex').length === 2") as? Bool == true
    }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertTrue(editor.validateMenuItem(menu("insertMathBlock")))
    editor.performCommand("toggleSourceMode")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-mvp-math') === null") as? Bool == true }
    editor.performCommand("toggleSourceMode")
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelectorAll('.cm-mvp-math .katex').length === 2") as? Bool == true
    }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  private func settle() async {
    // 无窗口的测试 WebView 中，编辑器聚焦会短暂处于焦点迁移状态，立即轮询会被 WebKit 拒绝。
    try? await Task.sleep(for: .milliseconds(600))
  }

  func testInsertMathBlockCommandInsertsEditableBlockWithIndependentUndo() async throws {
    let (document, editor, web) = try await makeDocument("正文\r\n尾\n")
    defer { document.close() }
    editor.performCommand("insertMathBlock")
    try await settle()
    let snapshot = try await web.evaluateJavaScript("window.inkpotMVP.snapshot().text") as? String
    XCTAssertEqual(snapshot, "$$\r\n\r\n$$\r\n\r\n正文\r\n尾\n")
    let focus = try await web.evaluateJavaScript("document.activeElement.className") as? String
    XCTAssertEqual(focus, "cm-content cm-lineWrapping")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data("$$\r\n\r\n$$\r\n\r\n正文\r\n尾\n".utf8))
    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data("正文\r\n尾\n".utf8))
  }

  func testClickMathRevealsSourceAndPreservesBytes() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil { try await web.evaluateJavaScript("document.querySelectorAll('.cm-mvp-math .katex').length === 2") as? Bool == true }
    _ = try await web.evaluateJavaScript("""
      document.querySelector('.cm-mvp-math-block').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true})); null
      """)
    try await settle()
    let revealed = try await web.evaluateJavaScript("document.querySelector('.cm-mvp-math-block') === null") as? Bool
    XCTAssertTrue(try XCTUnwrap(revealed), "点击公式后应展开显示源码")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }
}
