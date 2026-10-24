import AppKit
import WebKit

/// 打印：沿用 PDF 导出的 HTML（完整公式与图表），在离屏 WebView 中按纸张可打印宽度排版，交给系统打印面板分页。
/// 纸张与边距来自文档的页面设置（文件 → 页面设置…）。
@MainActor
enum DocumentPrint {
  static func operation(for document: InkpotDocument, printInfo: NSPrintInfo) async throws -> (NSPrintOperation, WKWebView) {
    guard let info = printInfo.copy() as? NSPrintInfo else {
      throw NSError(domain: "Inkpot", code: 50, userInfo: [NSLocalizedDescriptionKey: "读取页面设置失败，已取消打印。"])
    }
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isHorizontallyCentered = false
    info.isVerticallyCentered = false
    let width = max(info.paperSize.width - info.leftMargin - info.rightMargin, 200)
    let webView = try await DocumentExport.renderedWebView(document, width: width)
    let operation = webView.printOperation(with: info)
    operation.jobTitle = document.displayName
    operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
    // WKWebView 的打印视图默认尺寸为零，不设置会打印出空白页。
    operation.view?.frame = webView.bounds
    return (operation, webView)
  }

  static func run(_ document: InkpotDocument) async {
    do {
      let (operation, webView) = try await operation(for: document, printInfo: document.printInfo)
      let session = PrintSession(webView: webView)
      if let window = document.windowForSheet {
        operation.runModal(for: window, delegate: session, didRun: #selector(PrintSession.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
      } else {
        operation.run()
        session.finish()
      }
    } catch {
      document.presentError(error)
    }
  }
}

/// 打印面板以表单显示期间保留离屏 WebView，完成或取消后释放。
@MainActor
private final class PrintSession: NSObject {
  private static var active: Set<PrintSession> = []
  private let webView: WKWebView

  init(webView: WKWebView) {
    self.webView = webView
    super.init()
    Self.active.insert(self)
  }

  func finish() { Self.active.remove(self) }

  @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
    finish()
  }
}
