import AppKit

/// 正文右键菜单：剪切、拷贝、粘贴，复制／粘贴为，以及段落、格式、插入三个子菜单。
/// 命令项从主菜单复制，标题、快捷键与可用状态和菜单栏保持一致；只保留 WebKit 的拼写建议项。
@MainActor
enum EditorContextMenu {
  /// WebKit 菜单项标签：拼写建议、无建议、忽略拼写、学习拼写。
  private static let spellingTags: Set<Int> = [15, 16, 17, 18]

  static func rebuild(_ menu: NSMenu, mainMenu: NSMenu? = NSApp.mainMenu) {
    let spelling = menu.items.filter { spellingTags.contains($0.tag) }
    menu.removeAllItems()
    for item in spelling { menu.addItem(item) }
    if !spelling.isEmpty { menu.addItem(.separator()) }
    for (title, action) in [("剪切", #selector(NSText.cut(_:))), ("拷贝", #selector(NSText.copy(_:))), ("粘贴", #selector(NSText.paste(_:)))] {
      menu.addItem(NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: ""))
    }
    menu.addItem(submenu(L10n.text("复制 / 粘贴为…"), ["copyMarkdown", "pastePlainText"], from: mainMenu))
    menu.addItem(.separator())
    let paragraph = [
      "heading1", "heading2", "heading3", "heading4", "heading5", "heading6", "",
      "orderedList", "bulletList", "taskList", "", "blockquote", "codeBlock", "insertMathBlock",
    ]
    menu.addItem(submenu(L10n.text("段落"), paragraph, from: mainMenu))
    menu.addItem(submenu(L10n.text("格式"), ["bold", "italic", "strikethrough", "inlineCode", "link"], from: mainMenu))
    menu.addItem(submenu(L10n.text("插入"), ["insertImage:", "insertTable", "horizontalRule"], from: mainMenu))
  }

  /// 空字符串表示分隔线；找不到的命令跳过，避免菜单结构变化时出现无响应的项。
  private static func submenu(_ title: String, _ commands: [String], from mainMenu: NSMenu?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: title)
    for command in commands {
      if command.isEmpty {
        submenu.addItem(.separator())
      } else if let source = mainMenu.flatMap({ find(command, in: $0) }), let copy = source.copy() as? NSMenuItem {
        submenu.addItem(copy)
      }
    }
    item.submenu = submenu
    return item
  }

  private static func find(_ command: String, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
      if item.representedObject as? String == command || (command.hasSuffix(":") && item.action == NSSelectorFromString(command)) { return item }
      if let submenu = item.submenu, let found = find(command, in: submenu) { return found }
    }
    return nil
  }
}
