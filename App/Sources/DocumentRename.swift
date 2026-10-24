import AppKit

/// 文件 → 重命名…：在当前窗口弹出名称输入框，沿用文件树的协调移动与重名保护；
/// 尚未保存过的文档改为走“存储”面板选择名称和位置。
extension InkpotDocument {
  @objc func renameFile(_ sender: Any?) {
    guard let url = fileURL, let window = windowControllers.first?.window else {
      save(sender)
      return
    }
    let alert = NSAlert()
    alert.messageText = "重命名"
    alert.informativeText = "保留扩展名，或改为 .md、.markdown、.txt 之一。"
    let field = NSTextField(string: url.lastPathComponent)
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    field.setAccessibilityLabel("文件名")
    alert.accessoryView = field
    alert.addButton(withTitle: "重命名")
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn, field.stringValue != url.lastPathComponent else { return }
      Task { @MainActor in
        do { _ = try await FileTreeActions.shared.rename(url, name: field.stringValue) } catch { self.presentError(error) }
      }
    }
    // 与访达一致，默认只选中文件名主体，便于直接输入新名字。
    DispatchQueue.main.async {
      let base = (url.lastPathComponent as NSString).deletingPathExtension
      field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }
  }
}
