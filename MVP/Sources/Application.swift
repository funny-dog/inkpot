import AppKit

@main
enum Application {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = makeMenu(delegate: delegate)
    _ = NSDocumentController.shared
    app.run()
    withExtendedLifetime(delegate) {}
  }

  private static func makeMenu(delegate: AppDelegate) -> NSMenu {
    let menu = NSMenu()
    let groups: [(String, [(String, String, String)])] = [
      ("Kernmark", [("退出 Kernmark", "terminate:", "q")]),
      ("文件", [
        ("新建", "newDocument:", "n"), ("打开…", "openDocument:", "o"),
        ("关闭", "performClose:", "w"), ("保存", "saveDocument:", "s"),
        ("另存为…", "saveDocumentAs:", "S"),
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
      ]),
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
        if ["undo:", "redo:", "selectAll:"].contains(action) { entry.target = delegate }
        if !action.hasSuffix(":") {
          entry.action = #selector(AppDelegate.editorCommand(_:))
          entry.representedObject = action
          entry.target = delegate
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

  func applicationDidFinishLaunching(_ notification: Notification) {
    if NSDocumentController.shared.documents.isEmpty {
      NSDocumentController.shared.newDocument(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
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
