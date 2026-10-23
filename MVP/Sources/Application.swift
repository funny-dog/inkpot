import AppKit

@main
enum Application {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.mainMenu = makeMenu(delegate: delegate)
    _ = NSDocumentController.shared
    app.run()
    withExtendedLifetime(delegate) {}
  }

  private static func makeMenu(delegate: AppDelegate) -> NSMenu {
    let menu = NSMenu()
    let groups: [(String, [(String, String, String)])] = [
      ("Inkpot", [("退出 Inkpot", "terminate:", "q")]),
      ("文件", [
        ("新建", "newDocument:", "n"), ("打开…", "openDocument:", "o"),
        ("打开文件夹…", "openFolder:", "o"),
        ("关闭", "performClose:", "w"), ("保存", "saveDocument:", "s"),
        ("另存为…", "saveDocumentAs:", "S"),
        ("导出为 PDF…", "exportPDF:", ""),
        ("导出为 HTML…", "exportHTML:", ""),
        ("重新载入磁盘版本…", "revertDocumentToSaved:", ""),
        ("恢复未保存草稿…", "restoreDrafts:", ""),
      ]),
      ("编辑", [
        ("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
        ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
        ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a"),
        ("", "", ""), ("查找与替换…", "find", "f"),
        ("查找下一个", "findNext", "g"), ("查找上一个", "findPrevious", "G"),
      ]),
      ("格式", [
        ("粗体", "bold", "b"), ("斜体", "italic", "i"), ("", "", ""),
        ("一级标题", "heading1", "1"), ("二级标题", "heading2", "2"),
        ("三级标题", "heading3", "3"), ("四级标题", "heading4", "4"),
        ("五级标题", "heading5", "5"), ("六级标题", "heading6", "6"), ("", "", ""),
        ("有序列表", "orderedList", "7"), ("无序列表", "bulletList", "8"),
        ("插入本地图片…", "insertImage:", ""), ("表格", "tableMenu", ""), ("公式块", "insertMathBlock", ""),
      ]),
      ("显示", [("文件树", "toggleFiles", "E"), ("标题大纲", "toggleOutline", "O"), ("源码模式", "toggleSourceMode", "M")]),
      ("窗口", [("最小化", "performMiniaturize:", "m")]),
    ]
    for (title, entries) in groups {
      let item = NSMenuItem()
      let submenu = NSMenu(title: title)
      item.submenu = submenu
      for (label, action, key) in entries {
        if label.isEmpty {
          submenu.addItem(.separator())
          continue
        }
        let entry = NSMenuItem(title: label, action: NSSelectorFromString(action), keyEquivalent: key.lowercased())
        entry.keyEquivalentModifierMask = key != key.lowercased() || ["orderedList", "bulletList"].contains(action) ? [.command, .shift] : [.command]
        if action == "insertImage:" || action == "exportPDF:" || action == "exportHTML:" { entry.target = delegate }
        if action == "restoreDrafts:" { entry.target = delegate }
        if action == "openFolder:" { entry.keyEquivalentModifierMask = [.command, .option]; entry.target = delegate }
        if ["undo:", "redo:", "selectAll:"].contains(action) { entry.target = delegate }
        if !action.hasSuffix(":") {
          entry.action = #selector(AppDelegate.editorCommand(_:))
          entry.representedObject = action
          entry.target = delegate
        }
        if action == "tableMenu" {
          entry.action = nil
          let tables = NSMenu(title: "表格")
          for (title, command) in [
            ("插入表格", "insertTable"), ("在上方插入行", "tableRowAbove"), ("在下方插入行", "tableRowBelow"),
            ("在左侧插入列", "tableColumnBefore"), ("在右侧插入列", "tableColumnAfter"),
            ("删除当前行", "tableDeleteRow"), ("删除当前列", "tableDeleteColumn"),
            ("当前列左对齐", "tableAlignLeft"), ("当前列居中", "tableAlignCenter"), ("当前列右对齐", "tableAlignRight"),
          ] {
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.editorCommand(_:)), keyEquivalent: "")
            item.representedObject = command
            item.target = delegate
            tables.addItem(item)
          }
          entry.submenu = tables
        }
        submenu.addItem(entry)
      }
      menu.addItem(item)
      if title == "窗口" { NSApp.windowsMenu = submenu }
    }
    return menu
  }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var isTerminating = false

  private var textInput: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

  private var editor: EditorViewController? {
    let editor = (NSDocumentController.shared.currentDocument as? MVPDocument)?.editor
    return editor?.view.window === NSApp.keyWindow ? editor : nil
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(insertImage(_:)) { return editor?.isReady == true }
    if menuItem.action == #selector(exportPDF(_:)) || menuItem.action == #selector(exportHTML(_:)) { return editor?.isReady == true }
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
