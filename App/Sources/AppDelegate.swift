import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var isTerminating = false
  // 启动恢复窗口完成前不让系统另开未命名文档；之后点按程序坞图标等仍按系统默认新建。
  private var launchFinished = false

  private var textInput: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

  private var editor: EditorViewController? {
    let editor = (NSDocumentController.shared.currentDocument as? InkpotDocument)?.editor
    return editor?.view.window === NSApp.keyWindow ? editor : nil
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(checkForUpdates(_:)) { return !UpdateChecker.shared.isChecking }
    if menuItem.action == #selector(insertImage(_:)) { return editor?.isReady == true }
    if [#selector(exportPDF(_:)), #selector(exportHTML(_:)), #selector(printMarkdown(_:))].contains(menuItem.action) { return editor?.isReady == true }
    if [#selector(showSettings(_:)), #selector(openWebsite(_:)), #selector(sendFeedback(_:)), #selector(checkForUpdates(_:)), #selector(newDocument(_:)), #selector(openFromDock(_:))].contains(menuItem.action) { return true }
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
    NSApp.activate(ignoringOtherApps: true)
    if NSApp.keyWindow?.contentViewController as? DocumentViewController == nil {
      NSDocumentController.shared.newDocument(nil)
    }
    (NSApp.keyWindow?.contentViewController as? DocumentViewController)?.openFolder(sender)
  }

  /// 打开最近的文件夹：在当前窗口的文件树中打开，没有文档窗口时先新建。
  func openFolder(at url: URL) {
    if NSApp.keyWindow?.contentViewController as? DocumentViewController == nil {
      NSDocumentController.shared.newDocument(nil)
    }
    guard let controller = NSApp.keyWindow?.contentViewController as? DocumentViewController
      ?? NSDocumentController.shared.documents.last?.windowControllers.first?.window?.contentViewController as? DocumentViewController else { return }
    controller.files.openFolder(url)
    if !controller.filesVisible { controller.toggleContent(files: true) }
  }

  @MainActor
  @objc func insertImage(_ sender: Any?) {
    (NSDocumentController.shared.currentDocument as? InkpotDocument)?.images.choose()
  }

  @MainActor
  @objc func exportPDF(_ sender: Any?) {
    if let document = NSDocumentController.shared.currentDocument as? InkpotDocument { Task { @MainActor in await DocumentExport.save(document, pdf: true) } }
  }

  @MainActor
  @objc func exportHTML(_ sender: Any?) {
    if let document = NSDocumentController.shared.currentDocument as? InkpotDocument { Task { @MainActor in await DocumentExport.save(document, pdf: false) } }
  }

  @MainActor
  @objc func printMarkdown(_ sender: Any?) {
    if let document = NSDocumentController.shared.currentDocument as? InkpotDocument { Task { @MainActor in await DocumentPrint.run(document) } }
  }

  static let websiteURL = URL(string: "https://github.com/funny-dog/inkpot")
  static let feedbackURL = URL(string: "https://github.com/funny-dog/inkpot/issues")

  @objc func openWebsite(_ sender: Any?) { if let url = Self.websiteURL { NSWorkspace.shared.open(url) } }

  @objc func sendFeedback(_ sender: Any?) { if let url = Self.feedbackURL { NSWorkspace.shared.open(url) } }

  /// 新建（⌘N、程序坞）：另开独立窗口；打开的文件与“新建标签页”仍并入当前窗口的标签组。
  @objc func newDocument(_ sender: Any?) {
    NSApp.activate(ignoringOtherApps: true)
    InkpotDocument.opensInSeparateWindow = true
    defer { InkpotDocument.opensInSeparateWindow = false }
    NSDocumentController.shared.newDocument(sender)
    // 窗口显示后恢复为接收标签，之后在它上面打开的文件仍进入标签页。
    NSDocumentController.shared.documents.last?.windowControllers.first?.window?.tabbingMode = .preferred
  }

  @MainActor
  @objc func checkForUpdates(_ sender: Any?) {
    UpdateChecker.shared.check()
  }

  /// 程序坞右键菜单：新建、打开文件与文件夹，与文件菜单行为一致。
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    for (title, action) in [("新建", #selector(newDocument(_:))), ("打开…", #selector(openFromDock(_:))), ("打开文件夹…", #selector(openFolder(_:)))] {
      let item = NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    return menu
  }

  /// 从程序坞打开时应用可能还在后台，先激活，使打开面板出现在最前面。
  @objc func openFromDock(_ sender: Any?) {
    NSApp.activate(ignoringOtherApps: true)
    NSDocumentController.shared.openDocument(sender)
  }

  @objc func restoreDrafts(_ sender: Any?) { recoverDrafts(automatic: false) }

  // 设置窗口在第一次打开时才创建，不增加启动开销。
  @MainActor
  @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.showSettings(sender) }

  private func recoverDrafts(automatic: Bool) {
    do {
      let documents = NSDocumentController.shared.documents.compactMap { $0 as? InkpotDocument }
      let active = Set(documents.map { $0.safety.id })
      let healthy = Set(documents.filter { $0.editor?.isReady == true }.map { $0.safety.id })
      let drafts = try RecoveryStore.standard.drafts().filter { !healthy.contains($0.id) }
      guard !drafts.isEmpty else {
        if !automatic { let alert = NSAlert(); alert.messageText = L10n.text("没有需要恢复的草稿"); alert.runModal() }
        return
      }
      let alert = NSAlert()
      alert.messageText = L10n.text("发现 %ld 份未保存草稿", drafts.count)
      alert.informativeText = L10n.text("恢复后将打开独立副本，不覆盖原文件。选择稍后会保留草稿。")
      alert.addButton(withTitle: L10n.text("恢复草稿"))
      alert.addButton(withTitle: L10n.text("稍后"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      for draft in drafts {
        let document = InkpotDocument()
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
    NSApp.activate(ignoringOtherApps: true)
    Task { @MainActor in
      // 启动偏好只控制会话恢复；从访达打开的指定文件与未保存草稿不受影响。
      if let session = DocumentSession.loadForLaunch(
        restoringPreviousSession: AppSettings.shared.restorePreviousSession,
        hasOpenDocuments: !NSDocumentController.shared.documents.isEmpty
      ) {
        let missing = await DocumentSession.restore(session)
        if !missing.isEmpty {
          let alert = NSAlert()
          alert.messageText = L10n.text("部分文件或文件夹未能恢复")
          alert.informativeText = L10n.text("以下项目可能已被移走或删除：\n") + missing.joined(separator: "\n")
          alert.runModal()
        }
      }
      if NSDocumentController.shared.documents.isEmpty {
        NSDocumentController.shared.newDocument(nil)
      }
      launchFinished = true
      recoverDrafts(automatic: true)
      AutomaticUpdates.shared.start()
    }
  }

  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { launchFinished }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    // 关闭文档前记录窗口与标签；取消退出时下次退出会重新记录。
    // 优先使用询问未保存文档之前记录的会话，那时被关闭的文档还在。
    DocumentSession.save(InkpotDocumentController.quitSnapshot ?? DocumentSession.capture())
    InkpotDocumentController.quitSnapshot = nil
    Task { @MainActor in
      do {
        // 退出前也要等待 WebKit，避免最后一次输入尚未通知原生窗口就被关闭。
        for case let document as InkpotDocument in NSDocumentController.shared.documents {
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
    MainActor.assumeIsolated { InkpotDocumentController.quitSnapshot = nil }
    NSApp.reply(toApplicationShouldTerminate: didCloseAll)
  }
}
