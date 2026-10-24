import AppKit

extension FileTreeViewController: NSMenuDelegate, NSMenuItemValidation {
  func menuNeedsUpdate(_ menu: NSMenu) {
    let entry = (outlineView.item(atRow: outlineView.clickedRow) as? Item)?.entry
    let fresh = contextMenu(for: entry)
    menu.removeAllItems()
    for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
  }

  func contextMenu(for entry: FolderEntry?) -> NSMenu {
    let menu = NSMenu()
    guard let root else { return menu }
    let folder = entry.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? root.entry.url
    func add(_ title: String, _ action: Selector, _ url: URL) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.representedObject = url
      menu.addItem(item)
    }
    if let entry, !entry.isDirectory {
      add("在新标签页中打开", #selector(openInTab(_:)), entry.url)
      menu.addItem(.separator())
    }
    add("新建 Markdown 文件…", #selector(createFile(_:)), folder)
    add("新建文件夹…", #selector(createFolder(_:)), folder)
    if let entry {
      menu.addItem(.separator())
      add("重命名…", #selector(renameItem(_:)), entry.url)
      add("移到废纸篓", #selector(trashItem(_:)), entry.url)
    }
    return menu
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    !FileTreeActions.shared.isWorking && root != nil && (menuItem.action != #selector(openInTab(_:)) || onOpenInTab != nil)
  }

  @objc private func openInTab(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { onOpenInTab?(url) }
  }

  @objc private func createFile(_ sender: NSMenuItem) { create(sender, directory: false) }
  @objc private func createFolder(_ sender: NSMenuItem) { create(sender, directory: true) }

  private func create(_ sender: NSMenuItem, directory: Bool) {
    guard let folder = sender.representedObject as? URL else { return }
    askName(title: directory ? "新建文件夹" : "新建 Markdown 文件", name: directory ? "未命名文件夹" : "未命名.md") { [weak self] name in
      let url = try FileTreeActions.shared.create(in: folder, name: name, directory: directory)
      if !directory { self?.onOpenInTab?(url) }
    }
  }

  @objc private func renameItem(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    askName(title: "重命名", name: url.lastPathComponent) { name in
      _ = try await FileTreeActions.shared.rename(url, name: name)
    }
  }

  @objc private func trashItem(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    Task { @MainActor in
      do { _ = try await FileTreeActions.shared.trash(url) } catch { self.presentError(error) }
    }
  }

  private func askName(title: String, name: String, action: @escaping (String) async throws -> Void) {
    guard let window = view.window, !FileTreeActions.shared.isWorking else { return }
    let initialRoot = root
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(string: name)
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    field.setAccessibilityLabel("名称")
    alert.accessoryView = field
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn, root === initialRoot else { return }
      Task { @MainActor in
        do { try await action(field.stringValue) } catch { self.presentError(error) }
      }
    }
  }
}
