import AppKit

@MainActor
final class DocumentFileSwitch {
  private(set) var isOpening = false
  private let openDocument: (URL) async throws -> (InkpotDocument, Bool)
  private let confirmClose: (InkpotDocument) async -> Bool

  init(
    openDocument: @escaping (URL) async throws -> (InkpotDocument, Bool) = DocumentFileSwitch.load,
    confirmClose: @escaping (InkpotDocument) async -> Bool = DocumentFileSwitch.confirm
  ) {
    self.openDocument = openDocument
    self.confirmClose = confirmClose
  }

  func open(_ url: URL, in windowController: NSWindowController) async throws -> InkpotDocument? {
    guard !isOpening, let current = windowController.document as? InkpotDocument,
          current.editor?.isReady == true else { return nil }
    guard current.fileURL?.standardizedFileURL != url.standardizedFileURL else { return current }
    isOpening = true
    defer { isOpening = false }
    let (next, alreadyOpen) = try await openDocument(url)
    if alreadyOpen || !next.windowControllers.isEmpty {
      next.showWindows()
      return current
    }
    var adopted = false
    defer { if !adopted { next.close() } }
    // 先读目标、同步原文，再显示系统关闭提示；失败或取消时保留原窗口和编辑历史。
    guard windowController.document === current else { return nil }
    try await current.synchronize()
    guard await confirmClose(current) else { return current }
    guard windowController.document === current, current.editor?.isReady == true else { return current }
    current.removeWindowController(windowController)
    current.transferEditor(to: next)
    next.addWindowController(windowController)
    windowController.synchronizeWindowTitleWithDocumentName()
    current.close()
    adopted = true
    return next
  }

  static func load(_ url: URL) async throws -> (InkpotDocument, Bool) {
    // 文件树显示所有文件时，其他扩展名按纯文本载入；不是 UTF-8 文本的文件由读取校验报错，原文件不受影响。
    if !FileTree.isText(url) {
      if let existing = NSDocumentController.shared.document(for: url) as? InkpotDocument { return (existing, true) }
      let document = try InkpotDocument(contentsOf: url, ofType: "public.plain-text")
      NSDocumentController.shared.addDocument(document)
      NSDocumentController.shared.noteNewRecentDocument(document)
      return (document, false)
    }
    let (document, alreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
    guard let document = document as? InkpotDocument else { throw CocoaError(.fileReadUnsupportedScheme) }
    return (document, alreadyOpen)
  }

  static func confirm(_ document: InkpotDocument) async -> Bool {
    let request = DocumentCloseRequest()
    return await request.confirm(document)
  }
}

@MainActor
private final class DocumentCloseRequest: NSObject {
  private var continuation: CheckedContinuation<Bool, Never>?

  func confirm(_ document: NSDocument) async -> Bool {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      document.canClose(withDelegate: self, shouldClose: #selector(didDecide(_:shouldClose:contextInfo:)), contextInfo: nil)
    }
  }

  @objc private func didDecide(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
    continuation?.resume(returning: shouldClose)
    continuation = nil
  }
}
