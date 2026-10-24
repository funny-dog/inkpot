import AppKit
import UniformTypeIdentifiers
import WebKit

/// 文档导出：HTML 直接取实时视图序列化，PDF 支持分页多页与连续长页。
@MainActor
enum DocumentExport {
  /// 上次导出目录偏好键。
  static let lastExportDirectoryKey = "InkpotLastExportDirectory"
  /// PDF 导出是否分页偏好键。
  static let exportPDFPaginatedKey = "InkpotExportPDFPaginated"

  /// PDF 导出分页偏好（默认 true：分页 PDF）。
  static var isPDFPaginatedPreferred: Bool {
    get {
      if UserDefaults.standard.object(forKey: exportPDFPaginatedKey) == nil {
        return true
      }
      return UserDefaults.standard.bool(forKey: exportPDFPaginatedKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: exportPDFPaginatedKey)
    }
  }

  /// 建议的导出保存目录：文档同级目录优先，其次上次导出位置，最后为下载目录。
  static func suggestedDirectory(for document: InkpotDocument) -> URL {
    if let docURL = document.fileURL {
      let folder = docURL.deletingLastPathComponent()
      if FileManager.default.fileExists(atPath: folder.path) {
        return folder
      }
    }
    if let lastPath = UserDefaults.standard.string(forKey: lastExportDirectoryKey) {
      let lastURL = URL(fileURLWithPath: lastPath)
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: lastURL.path, isDirectory: &isDir), isDir.boolValue {
        return lastURL
      }
    }
    return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
  }

  /// 建议的文件名。
  static func suggestedFilename(for document: InkpotDocument, extensionName: String) -> String {
    let base: String
    if let docURL = document.fileURL {
      base = docURL.deletingPathExtension().lastPathComponent
    } else if let name = document.displayName, !name.isEmpty {
      base = name
    } else {
      base = "未命名"
    }
    return "\(base).\(extensionName)"
  }

  /// 校验导出目标路径安全：禁止覆盖当前 Markdown 源文件。
  static func validateDestination(sourceURL: URL?, destinationURL: URL) throws {
    guard let sourceURL else { return }
    if sourceURL.resolvingSymlinksInPath().standardizedFileURL == destinationURL.resolvingSymlinksInPath().standardizedFileURL {
      throw NSError(domain: "Inkpot", code: 42, userInfo: [NSLocalizedDescriptionKey: "导出目标不能是当前 Markdown 源文件。"])
    }
  }

  static func documentHTML(_ document: InkpotDocument, pdfMode: Bool) async throws -> String {
    guard let editor = document.editor, editor.isReady else {
      throw NSError(domain: "Inkpot", code: 40, userInfo: [NSLocalizedDescriptionKey: "编辑器尚未就绪，已取消导出。"])
    }
    // 页面完成全篇布局并等待公式、图表渲染，再返回独立 HTML。
    guard let html = try await editor.evaluateScript("window.inkpot.exportHTML(\(pdfMode ? "'pdf'" : "'html'"))", awaitPromise: true) as? String else {
      throw NSError(domain: "Inkpot", code: 41, userInfo: [NSLocalizedDescriptionKey: "读取导出内容失败，未写入文件。"])
    }
    return html
  }

  /// 在离屏 WebView 中按给定宽度排版导出 HTML，等待资源加载后把高度撑满全文；PDF 导出与打印共用。
  static func renderedWebView(_ document: InkpotDocument, width: CGFloat) async throws -> WKWebView {
    let html = try await documentHTML(document, pdfMode: true)
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(MathAssetHandler(), forURLScheme: "inkpot-asset")
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800), configuration: configuration)
    // 相对路径的本地图片按文档所在目录解析。
    try await webView.loadHTMLString(html, baseURL: document.fileURL?.deletingLastPathComponent())
    let loaded = { try await webView.evaluateJavaScript("document.readyState === 'complete'") as? Bool == true }
    let deadline = Date.now.addingTimeInterval(10)
    while !(try await loaded()) && Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(300))
    let height = (try await webView.evaluateJavaScript("Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight))") as? Double) ?? 800
    webView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 100))
    return webView
  }

  /// 生成真正多页 PDF：复用 DocumentPrint.operation 与文档 printInfo，通过临时文件生成后读取并清理。
  static func paginatedPDFData(_ document: InkpotDocument) async throws -> Data {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("inkpot-export-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    try await DocumentPrint.printToPDF(for: document, to: tempURL)
    return try Data(contentsOf: tempURL)
  }

  /// 生成 PDF 数据。默认保持连续单页以兼容旧调用，传入 paginated: true 生成分页多页 PDF。
  static func pdfData(_ document: InkpotDocument, paginated: Bool = false) async throws -> Data {
    if paginated {
      return try await paginatedPDFData(document)
    }
    let webView = try await renderedWebView(document, width: 794)
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

  /// 导出保存：先通过 NSSavePanel 获取目标路径与选项；取消不执行渲染；成功后原子写入且不自动激活 Finder。
  static func save(_ document: InkpotDocument, pdf: Bool) async {
    let panel = NSSavePanel()
    let extensionName = pdf ? "pdf" : "html"
    panel.allowedContentTypes = [pdf ? .pdf : .html]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.directoryURL = suggestedDirectory(for: document)
    panel.nameFieldStringValue = suggestedFilename(for: document, extensionName: extensionName)

    var layout: NSPopUpButton?
    if pdf {
      let control = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28), pullsDown: false)
      control.addItems(withTitles: ["分页 PDF", "连续长页"])
      control.selectItem(at: isPDFPaginatedPreferred ? 0 : 1)
      control.setAccessibilityLabel("PDF 页面布局")
      panel.accessoryView = control
      layout = control
    }

    let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
      if let window = document.windowForSheet {
        panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      } else {
        continuation.resume(returning: panel.runModal())
      }
    }

    // 取消不得写入或先启动渲染。
    guard response == .OK, let targetURL = panel.url else { return }

    do {
      // 禁止覆盖当前 Markdown 源文件。
      try validateDestination(sourceURL: document.fileURL, destinationURL: targetURL)

      // 记录本次导出目录与 PDF 分页偏好。
      UserDefaults.standard.set(targetURL.deletingLastPathComponent().path, forKey: lastExportDirectoryKey)
      let paginated = layout.map { $0.indexOfSelectedItem == 0 } ?? isPDFPaginatedPreferred
      if pdf {
        isPDFPaginatedPreferred = paginated
      }

      // 开始渲染：如果渲染失败，立即抛错，不会破坏已有目标文件。
      let data: Data
      if pdf {
        data = try await pdfData(document, paginated: paginated)
      } else {
        data = Data(try await documentHTML(document, pdfMode: false).utf8)
      }

      // 原子写入目标，确保文件完整。
      try data.write(to: targetURL, options: .atomic)
    } catch {
      document.presentError(error)
    }
  }
}
