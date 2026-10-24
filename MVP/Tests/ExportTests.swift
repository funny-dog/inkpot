import AppKit
import WebKit
import XCTest

@MainActor
final class ExportTests: XCTestCase {
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

  private let original = "# 标题\r\n\r\n**加粗** ~~删除~~ ==高亮==\r\n\r\n| a | b |\n| --- | --- |\n| 1 | 2 |\r\n\r\n$$\nE = mc^2\n$$\r\n\r\n- [x] 任务\r\n"

  func testExportHTMLStructureAndByteFidelity() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil { try await web.evaluateJavaScript("document.querySelectorAll('.cm-mvp-math .katex').length === 1") as? Bool == true }
    let html = try await DocumentExport.documentHTML(document, pdfMode: false)
    XCTAssertTrue(html.contains("<!doctype html>"))
    XCTAssertTrue(html.contains("<title>标题</title>"))
    XCTAssertTrue(html.contains("<table"))
    XCTAssertTrue(html.contains("font-weight: bold") || html.contains("font-weight: 700"))
    XCTAssertTrue(html.contains("line-through"))
    XCTAssertTrue(html.contains("E = mc^2"))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  func testCodeBlocksHighlightFromBundleAssetsAndExportColors() async throws {
    let text = "```swift\r\nlet 名称 = \"值\" // 注释\r\n```\r\n\r\n```unknown\r\nlet x\r\n```\r\n"
    let (document, editor, web) = try await makeDocument(text)
    defer { document.close() }
    // 真实 WKWebView 中经 inkpot-asset:// 从应用包加载 Swift 语言文件并着色；未知语言保持原样。
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-mvp-token-keyword')?.textContent === 'let' && document.querySelectorAll('.cm-mvp-token-keyword').length === 1") as? Bool == true
    }
    editor.performCommand("toggleSourceMode")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-mvp-code') === null && document.querySelector('.cm-mvp-token-comment') !== null") as? Bool == true }
    editor.performCommand("toggleSourceMode")
    let html = try await DocumentExport.documentHTML(document, pdfMode: true)
    XCTAssertTrue(html.contains("cm-mvp-token-keyword"))
    XCTAssertTrue(html.contains("color: rgb(166, 38, 164)"))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(text.utf8))
  }

  func testExportPDFGeneratesValidData() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil { try await web.evaluateJavaScript("document.querySelectorAll('.cm-mvp-math .katex').length === 1") as? Bool == true }
    let data = try await DocumentExport.pdfData(document)
    XCTAssertGreaterThan(data.count, 1000)
    XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }
}
