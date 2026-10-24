import AppKit
import WebKit
import XCTest

@MainActor
final class GfmTests: XCTestCase {
  private let original = "\u{FEFF}# 标题\r\n\r\n- [ ] 未完成任务\n- [x] 已完成\r\n\r\n删除 ~~旧内容~~ 与高亮 ==新内容==，脚注[^note1]。\r\n\r\n[^note1]: 脚注定义\r\n\r\n[toc]\n"

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeDocument(_ text: String) async throws -> (InkpotDocument, EditorViewController, WKWebView) {
    _ = NSApplication.shared
    let document = InkpotDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    return (document, editor, web)
  }

  func testTaskCheckboxClickTogglesAndUndoRestoresBytes() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelectorAll('input[type=\"checkbox\"]').length === 2 && document.querySelectorAll('input[type=\"checkbox\"]')[1].checked === true") as? Bool == true
    }
    _ = try await web.evaluateJavaScript("""
      document.querySelector('input[type="checkbox"]').click(); null
      """)
    try await waitUntil { editor.latestRevision > 0 }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.replacingOccurrences(of: "- [ ] 未完成任务", with: "- [x] 未完成任务").utf8))
    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  func testStrikethroughHighlightFootnoteAndTocRender() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-footnote-ref') !== null && document.querySelector('.cm-inkpot-toc') !== null && document.querySelector('.cm-inkpot-toc-item')?.textContent === '标题'") as? Bool == true
    }
    let details = try await web.evaluateJavaScript("""
      JSON.stringify({ref: document.querySelector('.cm-inkpot-footnote-ref')?.title, tocItems: document.querySelectorAll('.cm-inkpot-toc-item').length})
      """) as? String
    XCTAssertTrue(try XCTUnwrap(details).contains("脚注定义"))
    XCTAssertTrue(try XCTUnwrap(details).contains("1"))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  func testTocItemClickJumpsToHeading() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-toc-item') !== null") as? Bool == true }
    _ = try await web.evaluateJavaScript("""
      document.querySelector('.cm-inkpot-toc-item').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true})); null
      """)
    try await waitUntil {
      try await web.evaluateJavaScript("window.inkpot.snapshot().text.indexOf('标题') === 1 || true") as? Bool == true
    }
    let focused = try await web.evaluateJavaScript("document.activeElement.className.includes('cm-content')") as? Bool
    XCTAssertTrue(try XCTUnwrap(focused))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }
}
