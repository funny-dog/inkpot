import AppKit

final class MVPDocument: NSDocument {
  private var content = DocumentContent()
  private var savedData = Data()
  private var snapshotRevision = 0
  private var snapshotIsValid = true
  private(set) var editor: EditorViewController?

  override static var autosavesDrafts: Bool { false }
  override static var autosavesInPlace: Bool { false }

  func makeEditor() -> EditorViewController {
    if let editor { return editor }
    let controller = EditorViewController(text: content.text)
    controller.onChange = { [weak self] in
      self?.snapshotIsValid = false
      self?.updateChangeCount(.changeDone)
    }
    editor = controller
    return controller
  }

  override func makeWindowControllers() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.minSize = NSSize(width: 360, height: 240)
    window.contentViewController = makeEditor()
    window.center()
    addWindowController(NSWindowController(window: window))
  }

  override func read(from data: Data, ofType typeName: String) throws {
    content = try DocumentContent(data: data)
    savedData = data
    editor?.replaceText(content.text)
  }

  override func data(ofType typeName: String) throws -> Data {
    if let editor, !snapshotIsValid || !editor.isReady || editor.latestRevision != snapshotRevision {
      throw NSError(domain: "Kernmark", code: 5, userInfo: [NSLocalizedDescriptionKey: "编辑内容尚未同步，已阻止写入旧内容，请重试保存。"])
    }
    return content.data
  }

  func synchronize() async throws {
    if let editor {
      snapshotIsValid = false
      let snapshot = try await editor.snapshot()
      content.text = snapshot.text
      snapshotRevision = snapshot.revision
      guard snapshotRevision == editor.latestRevision else {
        throw NSError(domain: "Kernmark", code: 6, userInfo: [NSLocalizedDescriptionKey: "读取期间文档发生了变化，请暂停输入后重试。"])
      }
      snapshotIsValid = true
      // String 的相等判断会合并 Unicode 等价字符，文件脏状态必须比较实际字节。
      if content.data == savedData {
        updateChangeCount(.changeCleared)
      } else if !isDocumentEdited {
        updateChangeCount(.changeDone)
      }
    }
  }

  override func save(_ sender: Any?) {
    synchronizeThen { super.save(sender) }
  }

  override func saveAs(_ sender: Any?) {
    synchronizeThen { super.saveAs(sender) }
  }

  override func autosave(withImplicitCancellability implicitlyCancellable: Bool) async throws {
    try await synchronize()
    try await super.autosave(withImplicitCancellability: implicitlyCancellable)
  }

  override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
    Task { @MainActor in
      do {
        try await synchronize()
      } catch {
        presentError(error)
        // 同步失败后必须由用户明确放弃内容；保存路径仍会拒绝写入旧快照。
        updateChangeCount(.changeDone)
      }
      super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }
  }

  override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
    let writtenData = content.data
    try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    // 自动备份或另存副本并不代表原文件已保存，不能因此清除未保存状态。
    if [.saveOperation, .saveAsOperation, .autosaveInPlaceOperation, .autosaveAsOperation].contains(saveOperation) {
      savedData = writtenData
    }
  }

  override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
    typeName == "net.daringfireball.markdown" ? "md" : "txt"
  }

  private func synchronizeThen(_ action: @escaping () -> Void) {
    Task { @MainActor in
      do {
        try await synchronize()
        action()
      } catch {
        presentError(error)
      }
    }
  }
}
