import AppKit

final class DocumentSafety {
  var store = RecoveryStore.standard
  private(set) var id = UUID()
  private(set) var restored = false
  private(set) var recoveredName: String?
  private weak var document: InkpotDocument?
  private var baseline = Data()
  private var task: Task<Void, Never>?
  private var closed = false
  private var reportedRecoveryError = false

  init(document: InkpotDocument) { self.document = document }
  deinit { task?.cancel() }

  func loaded(_ data: Data) { baseline = data }

  func restore(_ draft: RecoveryDraft) {
    id = draft.id
    restored = true
    recoveredName = L10n.text("恢复-%@", draft.originalURL?.lastPathComponent ?? L10n.text("未命名.md"))
  }

  func schedule() {
    task?.cancel()
    task = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, !closed, !Task.isCancelled else { return }
      guard document?.editor?.isComposing != true else { schedule(); return }
      do { try await persist() } catch {
        if !reportedRecoveryError, document?.editor?.view.window?.isVisible == true {
          reportedRecoveryError = true
          document?.presentError(NSError(domain: "Inkpot", code: 20, userInfo: [NSLocalizedDescriptionKey: L10n.text("本地恢复草稿写入失败。请手动保存文档。\n%@", error.localizedDescription)]))
        }
      }
    }
  }

  @MainActor
  func persist() async throws {
    guard let document, !closed else { return }
    try await document.synchronize()
    guard !closed, !Task.isCancelled else { return }
    if document.isDocumentEdited || restored {
      try store.write(RecoveryDraft(id: id, originalURL: document.fileURL, data: document.data(ofType: document.fileType ?? "net.daringfireball.markdown"), updated: .now))
    } else { try store.remove(id) }
    reportedRecoveryError = false
  }

  func saved(_ data: Data) {
    baseline = data
    restored = false
    recoveredName = nil
    clearDraft()
  }

  func close() {
    closed = true
    task?.cancel()
    clearDraft()
  }

  private func clearDraft() {
    do { try store.remove(id) } catch { NSLog("恢复草稿清理失败：%@", error.localizedDescription) }
  }

  func write(to url: URL, action: (URL) throws -> Void) throws {
    guard let document else { throw CocoaError(.fileWriteUnknown) }
    var coordinationError: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator(filePresenter: document).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
      result = Result {
        if document.fileURL?.standardizedFileURL == url.standardizedFileURL {
          guard try Data(contentsOf: target) == baseline else {
            throw NSError(domain: "Inkpot", code: 21, userInfo: [NSLocalizedDescriptionKey: L10n.text("磁盘文件已被其他程序修改，已阻止覆盖。当前编辑仍保留；请另存为，或通过“文件 → 重新载入磁盘版本”放弃当前修改后载入。")])
          }
        }
        try action(target)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileWriteUnknown) }
    try result.get()
  }

  @MainActor
  func refreshFromDisk() async throws {
    guard let document, let url = document.fileURL, !closed, document.editor?.isReady == true else { return }
    let previous = baseline
    let data = try await Task.detached { try Data(contentsOf: url) }.value
    guard !closed, document.fileURL == url, baseline == previous, data != previous else { return }
    try await document.synchronize()
    guard !document.isDocumentEdited else { try await persist(); return }
    try document.read(from: data, ofType: document.fileType ?? "net.daringfireball.markdown")
    document.updateChangeCount(.changeCleared)
    document.fileModificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try store.remove(id)
  }
}
