import AppKit

@MainActor
enum DocumentTabs {
  static func attach(_ document: MVPDocument, to parent: NSWindow) {
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
    load: (URL) async throws -> (MVPDocument, Bool) = DocumentFileSwitch.load
  ) async throws -> MVPDocument {
    let (document, alreadyOpen) = try await load(url)
    if !alreadyOpen { attach(document, to: parent) }
    return document
  }

  static func new(in parent: NSWindow) {
    let document = MVPDocument()
    NSDocumentController.shared.addDocument(document)
    attach(document, to: parent)
    document.showWindows()
  }
}

final class DocumentWindowController: NSWindowController {
  override func newWindowForTab(_ sender: Any?) {
    if let window { DocumentTabs.new(in: window) }
  }
}
