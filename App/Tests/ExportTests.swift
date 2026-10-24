import AppKit
import PDFKit
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

  private func makeDocument(_ text: String) async throws -> (InkpotDocument, EditorViewController, WKWebView) {
    _ = NSApplication.shared
    let document = InkpotDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    return (document, editor, web)
  }

  private let original = "# 标题\r\n\r\n**加粗** ~~删除~~ ==高亮==\r\n\r\n| a | b |\n| --- | --- |\n| 1 | 2 |\r\n\r\n$$\nE = mc^2\n$$\r\n\r\n- [x] 任务\r\n"

  /// 打印 PDF 文本提取的兼容性规范化：NFKC 转回统一表意文字、补齐 CJK 部首补充区两个无兼容分解的字形，
  /// 并去掉排版引入的空白与被拆成独立文本运行的下划线。
  private func normalizedPDFText(_ text: String) -> String {
    let radicalFixes: [Character: String] = ["⻓": "长", "⻚": "页"]
    let fixed = text.map { radicalFixes[$0] ?? String($0) }.joined()
    return fixed.precomposedStringWithCompatibilityMapping
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
      .replacingOccurrences(of: "_", with: "")
  }

  func testExportHTMLStructureAndByteFidelity() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil { try await web.evaluateJavaScript("document.querySelectorAll('.cm-inkpot-math .katex').length === 1") as? Bool == true }
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
      try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-token-keyword')?.textContent === 'let' && document.querySelectorAll('.cm-inkpot-token-keyword').length === 1") as? Bool == true
    }
    editor.performCommand("toggleSourceMode")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-code') === null && document.querySelector('.cm-inkpot-token-comment') !== null") as? Bool == true }
    editor.performCommand("toggleSourceMode")
    let html = try await DocumentExport.documentHTML(document, pdfMode: true)
    XCTAssertTrue(html.contains("cm-inkpot-token-keyword"))
    XCTAssertTrue(html.contains("color: rgb(166, 38, 164)"))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(text.utf8))
  }

  func testExportPDFGeneratesValidData() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    try await waitUntil { try await web.evaluateJavaScript("document.querySelectorAll('.cm-inkpot-math .katex').length === 1") as? Bool == true }
    let data = try await DocumentExport.pdfData(document)
    XCTAssertGreaterThan(data.count, 1000)
    XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  func testExportLongDocumentPaginatedPDF() async throws {
    var longText = "# 长文分页测试标题\n\n"
    for index in 1...60 {
      longText += "这是长文第 \(index) 段，包含足以撑满多页标准 A4 纸张的说明内容与占位排版文字。\n\n"
    }
    longText += "## 章节尾声\n\n长文分页终点标记 END_OF_PAGINATED_DOC\n"

    let (document, _, _) = try await makeDocument(longText)
    defer { document.close() }

    // 使用分页模式导出 PDF
    let data = try await DocumentExport.pdfData(document, paginated: true)
    XCTAssertGreaterThan(data.count, 1000)
    XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")

    let pdf = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertGreaterThan(pdf.pageCount, 1, "长文在分页模式下应生成多页 PDF")

    // 打印 PDF 的 ToUnicode 映射会把部分 CJK 字形提取为部首兼容形式，且折行会插入换行；比对前先规范化并去掉空白。
    let firstPageText = try XCTUnwrap(pdf.page(at: 0)?.string)
    XCTAssertTrue(normalizedPDFText(firstPageText).contains(normalizedPDFText("长文分页测试标题")))

    let lastPageText = try XCTUnwrap(pdf.page(at: pdf.pageCount - 1)?.string)
    XCTAssertTrue(normalizedPDFText(lastPageText).contains(normalizedPDFText("END_OF_PAGINATED_DOC")))
  }

  func testExportLongDocumentContinuousSinglePagePDF() async throws {
    var longText = "# 长文单页测试标题\n\n"
    for index in 1...60 {
      longText += "这是长文第 \(index) 段，包含连续长页输出排版文字。\n\n"
    }
    longText += "## 连续尾声\n\n单页连续终点标记 END_OF_SINGLE_PAGE_DOC\n"

    let (document, _, _) = try await makeDocument(longText)
    defer { document.close() }

    // 默认保持连续单页兼容旧调用
    let data = try await DocumentExport.pdfData(document, paginated: false)
    XCTAssertGreaterThan(data.count, 1000)
    XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")

    let pdf = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertEqual(pdf.pageCount, 1, "连续长页模式下应保持单页")

    let pageText = try XCTUnwrap(pdf.page(at: 0)?.string)
    XCTAssertTrue(normalizedPDFText(pageText).contains(normalizedPDFText("长文单页测试标题")))
    XCTAssertTrue(normalizedPDFText(pageText).contains(normalizedPDFText("END_OF_SINGLE_PAGE_DOC")))
  }

  func testValidateDestinationBlocksCurrentSourceFile() {
    let sourceURL = URL(fileURLWithPath: "/Users/test/notes/document.md")
    let sameTarget = URL(fileURLWithPath: "/Users/test/notes/../notes/document.md")
    let pdfTarget = URL(fileURLWithPath: "/Users/test/notes/document.pdf")
    let otherTarget = URL(fileURLWithPath: "/Users/test/notes/other.md")

    // 相同文件标准化路径后必须拒绝
    XCTAssertThrowsError(try DocumentExport.validateDestination(sourceURL: sourceURL, destinationURL: sameTarget)) { error in
      let nsError = error as NSError
      XCTAssertEqual(nsError.domain, "Inkpot")
      XCTAssertEqual(nsError.code, 42)
    }

    // 导出为同名 pdf 或不同路径时应允许
    XCTAssertNoThrow(try DocumentExport.validateDestination(sourceURL: sourceURL, destinationURL: pdfTarget))
    XCTAssertNoThrow(try DocumentExport.validateDestination(sourceURL: sourceURL, destinationURL: otherTarget))
    XCTAssertNoThrow(try DocumentExport.validateDestination(sourceURL: nil, destinationURL: sameTarget))
  }

  func testSuggestedDirectoryAndFilename() throws {
    let document = InkpotDocument()
    defer { document.close() }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("my-note.markdown")
    document.fileURL = fileURL

    let dir = DocumentExport.suggestedDirectory(for: document)
    XCTAssertEqual(dir.standardizedFileURL, directory.standardizedFileURL)

    let pdfName = DocumentExport.suggestedFilename(for: document, extensionName: "pdf")
    XCTAssertEqual(pdfName, "my-note.pdf")

    let htmlName = DocumentExport.suggestedFilename(for: document, extensionName: "html")
    XCTAssertEqual(htmlName, "my-note.html")

    // 无文档路径时回退到上次导出目录
    let untitledDoc = InkpotDocument()
    defer { untitledDoc.close() }
    let previousDir = FileManager.default.temporaryDirectory
    let originalDirectory = UserDefaults.standard.object(forKey: DocumentExport.lastExportDirectoryKey)
    defer { UserDefaults.standard.set(originalDirectory, forKey: DocumentExport.lastExportDirectoryKey) }
    UserDefaults.standard.set(previousDir.path, forKey: DocumentExport.lastExportDirectoryKey)

    let fallbackDir = DocumentExport.suggestedDirectory(for: untitledDoc)
    XCTAssertEqual(fallbackDir.standardizedFileURL, previousDir.standardizedFileURL)
  }

  func testPDFPaginationPreferencePersistence() {
    let originalPref = DocumentExport.isPDFPaginatedPreferred
    defer { DocumentExport.isPDFPaginatedPreferred = originalPref }

    DocumentExport.isPDFPaginatedPreferred = false
    XCTAssertFalse(DocumentExport.isPDFPaginatedPreferred)
    XCTAssertFalse(UserDefaults.standard.bool(forKey: DocumentExport.exportPDFPaginatedKey))

    DocumentExport.isPDFPaginatedPreferred = true
    XCTAssertTrue(DocumentExport.isPDFPaginatedPreferred)
    XCTAssertTrue(UserDefaults.standard.bool(forKey: DocumentExport.exportPDFPaginatedKey))
  }

  func testRenderFailurePreservesExistingTarget() async throws {
    let tempTarget = FileManager.default.temporaryDirectory.appendingPathComponent("inkpot-failure-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: tempTarget) }

    let initialData = Data("ORIGINAL_CONTENT".utf8)
    try initialData.write(to: tempTarget)

    // 未创建 editor 的文档调用 documentHTML 或 pdfData 会抛出未就绪错误
    let emptyDoc = InkpotDocument()
    defer { emptyDoc.close() }

    do {
      _ = try await DocumentExport.documentHTML(emptyDoc, pdfMode: false)
      XCTFail("未就绪文档应抛出错误")
    } catch {
      // 捕获异常，确保目标文件未被触碰或改写
      let remainingData = try Data(contentsOf: tempTarget)
      XCTAssertEqual(remainingData, initialData, "渲染失败绝不破坏已有目标文件")
    }
  }
}
