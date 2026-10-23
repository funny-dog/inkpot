import AppKit
import UniformTypeIdentifiers
import WebKit

/// 文档导出：HTML 直接取实时视图序列化，PDF 用离屏 WebView 渲染后生成为连续单页。
enum DocumentExport {
  static func documentHTML(_ document: MVPDocument, pdfMode: Bool) async throws -> String {
    guard let editor = document.editor, editor.isReady else {
      throw NSError(domain: "Inkpot", code: 40, userInfo: [NSLocalizedDescriptionKey: "编辑器尚未就绪，已取消导出。"])
    }
    // 等待公式完成渲染，避免导出内容回退为源码文本。
    let ready = "document.querySelectorAll('.cm-mvp-math:not(.cm-mvp-math-error) .katex').length === document.querySelectorAll('.cm-mvp-math:not(.cm-mvp-math-error)').length"
    let settled = { try await editor.evaluateScript(ready) as? Bool == true }
    let deadline = Date.now.addingTimeInterval(3)
    while !(try await settled()) && Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    return try await editor.evaluateScript("window.inkpotMVP.exportHTML(\(pdfMode ? "'pdf'" : "'html'"))") as? String ?? ""
  }

  static func pdfData(_ document: MVPDocument) async throws -> Data {
    let html = try await documentHTML(document, pdfMode: true)
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(MathAssetHandler(), forURLScheme: "inkpot-asset")
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 800), configuration: configuration)
    // 相对路径的本地图片按文档所在目录解析。
    try await webView.loadHTMLString(html, baseURL: document.fileURL?.deletingLastPathComponent())
    let loaded = { try await webView.evaluateJavaScript("document.readyState === 'complete'") as? Bool == true }
    let deadline = Date.now.addingTimeInterval(10)
    while !(try await loaded()) && Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(300))
    let height = (try await webView.evaluateJavaScript("Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight))") as? Double) ?? 800
    webView.frame = NSRect(x: 0, y: 0, width: 794, height: max(height, 100))
    let pdfConfiguration = WKPDFConfiguration()
    pdfConfiguration.rect = .null
    return try await withCheckedThrowingContinuation { continuation in
      webView.createPDF(configuration: pdfConfiguration) { result in
        switch result {
        case let .success(data): continuation.resume(returning: data)
        case let .failure(error): continuation.resume(throwing: error)
        }
      }
    }
  }

  static func save(_ document: MVPDocument, pdf: Bool) async {
    do {
      let data = pdf ? try await pdfData(document) : Data(try await documentHTML(document, pdfMode: false).utf8)
      // 已保存文档导出到同级目录，未保存文档导出到“下载”；同名不覆盖，追加序号。
      let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "未命名"
      let folder = document.fileURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
      let extensionName = pdf ? "pdf" : "html"
      var url = folder.appendingPathComponent("\(base).\(extensionName)")
      var sequence = 2
      while FileManager.default.fileExists(atPath: url.path) {
        url = folder.appendingPathComponent("\(base)-\(sequence).\(extensionName)")
        sequence += 1
      }
      try data.write(to: url, options: .atomic)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      document.presentError(error)
    }
  }
}
