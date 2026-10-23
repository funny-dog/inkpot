import AppKit
import WebKit
import XCTest

@MainActor
final class MermaidTests: XCTestCase {
  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(10)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(30))
    }
  }

  private func makeDocument(_ text: String) async throws -> (MVPDocument, EditorViewController) {
    _ = NSApplication.shared
    let document = MVPDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    try await waitUntil { editor.isReady }
    try await Task.sleep(for: .milliseconds(600))
    return (document, editor)
  }

  func testOfflineDiagramsErrorsStrictConfigurationAndSourceFidelity() async throws {
    let original = """
      \u{FEFF}开头\r

      ```mermaid
      %%{init: {"securityLevel":"loose","htmlLabels":true}}%%
      flowchart LR
      A["<img src=x onerror=window.unsafeDiagram=1>"] --> B[中文] --> C --> D --> E --> F --> G --> H --> I --> J
      ```

      ```mermaid
      sequenceDiagram
      Alice->>Bob: 你好
      ```

      ```mermaid
      invalid-diagram
      ```
      """
    let (document, editor) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil {
      try await editor.evaluateScript("document.querySelectorAll('.cm-mvp-mermaid svg').length === 2 && document.querySelectorAll('.cm-mvp-mermaid-error').length === 1") as? Bool == true
    }
    let scrolls = try await editor.evaluateScript("document.querySelector('.cm-mvp-mermaid').scrollWidth > document.querySelector('.cm-mvp-mermaid').clientWidth") as? Bool
    XCTAssertTrue(try XCTUnwrap(scrolls))
    let safe = try await editor.evaluateScript("window.unsafeDiagram === undefined && document.querySelector('.cm-mvp-mermaid img, .cm-mvp-mermaid script, .cm-mvp-mermaid foreignObject') === null") as? Bool
    XCTAssertTrue(try XCTUnwrap(safe))
    _ = try await editor.evaluateScript("window.inkpotMVP.command('toggleSourceMode'); null")
    let sourceVisible = try await editor.evaluateScript("document.querySelector('.cm-mvp-mermaid') === null") as? Bool
    XCTAssertTrue(try XCTUnwrap(sourceVisible))
    _ = try await editor.evaluateScript("window.inkpotMVP.command('toggleSourceMode'); null")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testExportIncludesOffscreenDiagramsFromSourceModeAndProducesPDF() async throws {
    let original = "\u{FEFF}开头\r\n\r\n```mermaid\r\nflowchart LR\r\nA-->B\n```\r\n\r\n"
      + String(repeating: "正文\n\n", count: 40)
      + "```mermaid\nsequenceDiagram\nAlice->>Bob: 结束\n```\n"
    let (document, editor) = try await makeDocument(original)
    defer { document.close() }
    _ = try await editor.evaluateScript("window.inkpotMVP.command('toggleSourceMode'); null")
    let html = try await DocumentExport.documentHTML(document, pdfMode: false)
    XCTAssertEqual(html.components(separatedBy: "<svg").count - 1, 2)
    XCTAssertTrue(html.contains("结束"))
    XCTAssertFalse(html.contains("data-render-pending"))
    let restored = try await editor.evaluateScript("document.querySelector('.cm-editor').classList.contains('cm-mvp-source')") as? Bool
    XCTAssertTrue(try XCTUnwrap(restored))
    let pdf = try await DocumentExport.pdfData(document)
    XCTAssertEqual(String(data: pdf.prefix(5), encoding: .ascii), "%PDF-")
    XCTAssertGreaterThan(pdf.count, 1000)
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testRenderAssetsOnlyServeBundledScriptsStylesAndFonts() {
    let bundle = Bundle(for: Self.self)
    XCTAssertNotNil(MathAssets.resolve("mermaid.mjs", in: bundle))
    XCTAssertNotNil(MathAssets.resolve("katex.mjs", in: bundle))
    XCTAssertNotNil(MathAssets.resolve("fonts/KaTeX_Main-Regular.woff2", in: bundle))
    for path in ["../mermaid.mjs", "/mermaid.mjs", "other/mermaid.mjs", "Info.plist", "mermaid.mjs?x=1"] {
      XCTAssertNil(MathAssets.resolve(path, in: bundle))
    }
  }
}
