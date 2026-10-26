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

  private func makeDocument(_ text: String) async throws -> (InkpotDocument, EditorViewController) {
    _ = NSApplication.shared
    let document = InkpotDocument()
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
      try await editor.evaluateScript("document.querySelectorAll('.cm-inkpot-mermaid svg').length === 2 && document.querySelectorAll('.cm-inkpot-mermaid-error').length === 1") as? Bool == true
    }
    let fits = try await editor.evaluateScript("document.querySelector('.cm-inkpot-mermaid').scrollWidth <= document.querySelector('.cm-inkpot-mermaid').clientWidth") as? Bool
    XCTAssertTrue(try XCTUnwrap(fits))
    let safe = try await editor.evaluateScript("window.unsafeDiagram === undefined && document.querySelector('.cm-inkpot-mermaid img, .cm-inkpot-mermaid script, .cm-inkpot-mermaid foreignObject') === null") as? Bool
    XCTAssertTrue(try XCTUnwrap(safe))
    _ = try await editor.evaluateScript("window.inkpot.command('toggleSourceMode'); null")
    let sourceVisible = try await editor.evaluateScript("document.querySelector('.cm-inkpot-mermaid') === null") as? Bool
    XCTAssertTrue(try XCTUnwrap(sourceVisible))
    _ = try await editor.evaluateScript("window.inkpot.command('toggleSourceMode'); null")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testComplexFlowchartFitsEditorWidthAndResizesProportionally() async throws {
    let original = #"""
      开头

      ```mermaid
      flowchart TD
          UI["工作台批量选择文件\n前端上传队列，多选后逐个上传"]
          UI -->|"POST /api/import/file\n单文件 ≤100MB"| DUP{"同项目内 SHA256\n或 URL 已存在？"}
          DUP -->|是| DUPY["标记 duplicate，直接返回"]
          DUP -->|否| SAVE["原子写入 sources/ 记 SHA256\ningest_state=queued，版本1\n入队 job: parse"]

          subgraph W["后台 Worker（2 解析线程 + 1 索引线程）"]
              KIND{"来源 / 格式"}
              subgraph P1["文本与网页"]
                  WEB["网页 URL: fetch_web 抓取\nSSRF 防护：仅公网 HTTPS"]
                  DOC["EPUB / TXT / MD / DOCX\n解析章节，保留定位"]
              end
              subgraph P2["PDF 处理"]
                  PDF["本地 PDF: 校验 SHA256\n写入 pdf_pages 页缓存"]
                  PDF --> HIT{"该页有缓存？"}
                  HIT -->|是| REUSE["直接复用缓存"]
                  HIT -->|否| TXTQ{"文字层有字？"}
                  TXTQ -->|有| TXT["method=text"]
                  TXTQ -->|扫描页| LOC["本地 OCR: pdftoppm 200dpi\n+ tesseract 简繁中英"]
                  LOC --> OCR["method=ocr / blank"]
                  RM["远端 PDF (可选)\nWin GPU worker, 租约 120s"]
                  RM --> RMW["PaddleOCR 识别\nMac 端核对页覆盖"]
              end
              KIND --> P1 & P2
          end
          subgraph S["标准化与入库"]
              STD["stage_import: 清洗文本、质量检查"]
              STD --> APPL{"质量通过？"}
              APPL -->|是| APPL2["写入 standard_documents\n切 chunks (~1200字)，入队 index"]
              APPL -->|无变化| SAME["不升版本，不重建索引"]
              APPL -->|拦截| FAIL["job=failed"]
          end
          subgraph I["索引与检索"]
              IX["job: index"] --> ENS["ES 索引: BM25 + dense_vector"]
              ENS --> EMB{"Embedding？"}
              EMB -->|是| CACHE["SQLite 向量缓存"]
              EMB -->|否| KW["仅关键词索引"]
              CACHE & KW --> FIN["refresh 索引\ningest_state=ready"]
              FIN --> USE["搜索 / MCP 检索: BM25 + 向量 RRF 合并"]
          end
          SAVE --> KIND
          REUSE & TXT & OCR & WEB & DOC & RMW --> STD
          APPL2 --> IX
          SAME -.-> USE
          KIND -.->|失败| FAIL
      ```
      """#
    let (document, editor) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil {
      try await editor.evaluateScript("document.querySelector('.cm-inkpot-mermaid svg') !== null") as? Bool == true
    }
    for width in [800, 480, 1200] {
      editor.view.frame.size.width = CGFloat(width)
      try await Task.sleep(for: .milliseconds(50))
      let script = """
        (() => {
          const container = document.querySelector('.cm-inkpot-mermaid');
          const svg = container.querySelector('svg');
          const rect = svg.getBoundingClientRect(), box = svg.viewBox.baseVal;
          return { width: rect.width, height: rect.height, available: container.clientWidth,
            scroll: container.scrollWidth, naturalWidth: box.width, ratio: box.width / box.height };
        })()
        """
      let result = try await editor.evaluateScript(script)
      let size = try XCTUnwrap(result as? [String: Double])
      let available = try XCTUnwrap(size["available"])
      let drawingWidth = try XCTUnwrap(size["width"])
      XCTAssertGreaterThan(try XCTUnwrap(size["naturalWidth"]), available)
      XCTAssertGreaterThan(drawingWidth, 0)
      XCTAssertEqual(drawingWidth, available, accuracy: 1)
      XCTAssertLessThanOrEqual(try XCTUnwrap(size["scroll"]), available + 1)
      XCTAssertEqual(drawingWidth / (try XCTUnwrap(size["height"])), try XCTUnwrap(size["ratio"]), accuracy: 0.01)
    }
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
    _ = try await editor.evaluateScript("window.inkpot.command('toggleSourceMode'); null")
    let html = try await DocumentExport.documentHTML(document, pdfMode: false)
    XCTAssertEqual(html.components(separatedBy: "<svg").count - 1, 2)
    XCTAssertTrue(html.contains("结束"))
    XCTAssertFalse(html.contains("data-render-pending"))
    let restored = try await editor.evaluateScript("document.querySelector('.cm-editor').classList.contains('cm-inkpot-source')") as? Bool
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
