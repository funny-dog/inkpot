import AppKit

@MainActor
enum DocumentTabs {
  static func attach(_ document: InkpotDocument, to parent: NSWindow) {
    if document.windowControllers.isEmpty { document.makeWindowControllers() }
    guard let window = document.windowControllers.first?.window, window !== parent else { return }
    if let folder = (parent.contentViewController as? DocumentViewController)?.files.root?.entry.url,
       let container = window.contentViewController as? DocumentViewController {
      container.files.openFolder(folder)
      if (parent.contentViewController as? DocumentViewController)?.filesVisible == true { container.toggleContent(files: true) }
    }
    parent.addTabbedWindow(window, ordered: .above)
    parent.tabGroup?.selectedWindow = window
  }

  static func open(
    _ url: URL,
    in parent: NSWindow,
    load: (URL) async throws -> (InkpotDocument, Bool) = DocumentFileSwitch.load
  ) async throws -> InkpotDocument {
    let (document, alreadyOpen) = try await load(url)
    if !alreadyOpen { attach(document, to: parent) }
    return document
  }

  /// 在独立窗口中打开，并带上来源窗口的文件树；文件已打开时直接前置它所在的窗口。
  static func openInWindow(
    _ url: URL,
    from parent: NSWindow,
    load: (URL) async throws -> (InkpotDocument, Bool) = DocumentFileSwitch.load
  ) async throws {
    let (document, alreadyOpen) = try await load(url)
    guard !alreadyOpen, document.windowControllers.isEmpty else { return document.showWindows() }
    InkpotDocument.opensInSeparateWindow = true
    document.makeWindowControllers()
    InkpotDocument.opensInSeparateWindow = false
    guard let window = document.windowControllers.first?.window else { return }
    if let source = parent.contentViewController as? DocumentViewController, let folder = source.files.root?.entry.url,
       let container = window.contentViewController as? DocumentViewController {
      container.files.openFolder(folder)
      if source.filesVisible { container.toggleContent(files: true) }
    }
    window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 28, y: parent.frame.maxY - 28))
    document.showWindows()
    window.tabbingMode = .preferred
  }

  static func new(in parent: NSWindow) {
    let document = InkpotDocument()
    NSDocumentController.shared.addDocument(document)
    attach(document, to: parent)
    document.showWindows()
  }
}

final class DocumentWindowController: NSWindowController {
  /// 文档编辑状态变化时同步状态栏的保存状态。
  override func setDocumentEdited(_ dirtyFlag: Bool) {
    super.setDocumentEdited(dirtyFlag)
    (contentViewController as? DocumentViewController)?.updateSaveState()
  }

  override func newWindowForTab(_ sender: Any?) {
    if let window { DocumentTabs.new(in: window) }
  }
}
