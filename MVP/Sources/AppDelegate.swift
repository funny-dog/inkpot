import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var isTerminating = false

  private var textInput: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

  private var editor: EditorViewController? {
    let editor = (NSDocumentController.shared.currentDocument as? MVPDocument)?.editor
    return editor?.view.window === NSApp.keyWindow ? editor : nil
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(insertImage(_:)) { return editor?.isReady == true }
    if [#selector(exportPDF(_:)), #selector(exportHTML(_:)), #selector(printMarkdown(_:))].contains(menuItem.action) { return editor?.isReady == true }
    if menuItem.action == #selector(showAbout(_:)) { return true }
    if menuItem.action == #selector(restoreDrafts(_:)) { return true }
    if menuItem.action == #selector(openFolder(_:)) { return true }
    if menuItem.representedObject is String {
      return textInput == nil && editor?.validateMenuItem(menuItem) == true
    }
    if let textInput {
      if menuItem.action == #selector(undo(_:)) { return textInput.undoManager?.canUndo == true }
      if menuItem.action == #selector(redo(_:)) { return textInput.undoManager?.canRedo == true }
      return true
    }
    return editor?.validateMenuItem(menuItem) == true
  }

  @objc func undo(_ sender: Any?) {
    if let textInput { textInput.undoManager?.undo() } else { editor?.undo(sender) }
  }

  @objc func redo(_ sender: Any?) {
    if let textInput { textInput.undoManager?.redo() } else { editor?.redo(sender) }
  }

  @objc func selectAll(_ sender: Any?) {
    if let textInput { textInput.selectAll(sender) } else { editor?.selectAll(sender) }
  }

  @objc func editorCommand(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? String else { return }
    editor?.performCommand(command)
  }

  @objc func openFolder(_ sender: Any?) {
    if NSApp.keyWindow?.contentViewController as? DocumentViewController == nil {
      NSDocumentController.shared.newDocument(nil)
    }
    (NSApp.keyWindow?.contentViewController as? DocumentViewController)?.openFolder(sender)
  }

  @MainActor
  @objc func insertImage(_ sender: Any?) {
    (NSDocumentController.shared.currentDocument as? MVPDocument)?.images.choose()
  }

  @MainActor
  @objc func exportPDF(_ sender: Any?) {
    if let document = NSDocumentController.shared.currentDocument as? MVPDocument { Task { @MainActor in await DocumentExport.save(document, pdf: true) } }
  }

  @MainActor
  @objc func exportHTML(_ sender: Any?) {
    if let document = NSDocumentController.shared.currentDocument as? MVPDocument { Task { @MainActor in await DocumentExport.save(document, pdf: false) } }
  }

  @MainActor
  @objc func printMarkdown(_ sender: Any?) {
    if let document = NSDocumentController.shared.currentDocument as? MVPDocument { Task { @MainActor in await DocumentPrint.run(document) } }
  }

  @objc func showAbout(_ sender: Any?) {
    // 保留上游及主要依赖的许可声明。
    let credits = NSAttributedString(
      string: "基于 MarkEdit 的编辑器内核分叉开发（MIT 许可）。\n使用 CodeMirror、Lezer、KaTeX、Mermaid 与 Turndown（均为 MIT 许可）。",
      attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
    )
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
  }

  @objc func restoreDrafts(_ sender: Any?) { recoverDrafts(automatic: false) }

  private func recoverDrafts(automatic: Bool) {
    do {
      let documents = NSDocumentController.shared.documents.compactMap { $0 as? MVPDocument }
      let active = Set(documents.map { $0.safety.id })
      let healthy = Set(documents.filter { $0.editor?.isReady == true }.map { $0.safety.id })
      let drafts = try RecoveryStore.standard.drafts().filter { !healthy.contains($0.id) }
      guard !drafts.isEmpty else {
        if !automatic { let alert = NSAlert(); alert.messageText = "没有需要恢复的草稿"; alert.runModal() }
        return
      }
      let alert = NSAlert()
      alert.messageText = "发现 \(drafts.count) 份未保存草稿"
      alert.informativeText = "恢复后将打开独立副本，不覆盖原文件。选择稍后会保留草稿。"
      alert.addButton(withTitle: "恢复草稿")
      alert.addButton(withTitle: "稍后")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      for draft in drafts {
        let document = MVPDocument()
        try document.read(from: draft.data, ofType: "net.daringfireball.markdown")
        let restored = active.contains(draft.id)
          ? RecoveryDraft(id: UUID(), originalURL: draft.originalURL, data: draft.data, updated: draft.updated) : draft
        document.safety.restore(restored)
        document.updateChangeCount(.changeDone)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
      }
    } catch { NSApp.presentError(error) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if NSDocumentController.shared.documents.isEmpty {
      NSDocumentController.shared.newDocument(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    recoverDrafts(automatic: true)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    Task { @MainActor in
      do {
        // 退出前也要等待 WebKit，避免最后一次输入尚未通知原生窗口就被关闭。
        for case let document as MVPDocument in NSDocumentController.shared.documents {
          try await document.synchronize()
        }
        NSDocumentController.shared.closeAllDocuments(
          withDelegate: self,
          didCloseAllSelector: #selector(didCloseAll(_:didCloseAll:contextInfo:)),
          contextInfo: nil
        )
      } catch {
        isTerminating = false
        sender.presentError(error)
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }

  @objc private func didCloseAll(_ controller: NSDocumentController, didCloseAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
    isTerminating = false
    NSApp.reply(toApplicationShouldTerminate: didCloseAll)
  }
}
