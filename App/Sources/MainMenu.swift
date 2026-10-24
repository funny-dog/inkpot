import AppKit

/// 主菜单；与入口分开，便于测试目标直接编译与检查。
@MainActor
enum MainMenu {
  static func make(delegate: AppDelegate) -> NSMenu {
    let menu = NSMenu()
    let groups: [(String, [(String, String, String)])] = [
      ("Inkpot", [
        (L10n.text("设置…"), "showSettings:", ","), (L10n.text("检查更新…"), "checkForUpdates:", ""), ("", "", ""), (L10n.text("退出 Inkpot"), "terminate:", "q"),
      ]),
      (L10n.text("文件"), [
        (L10n.text("新建"), "newDocument:", "n"), (L10n.text("新建标签页"), "newWindowForTab:", "n"), (L10n.text("打开…"), "openDocument:", "o"),
        (L10n.text("打开文件夹…"), "openFolder:", "o"), (L10n.text("打开最近使用"), "recentMenu", ""), (L10n.text("打开最近的文件夹"), "recentFoldersMenu", ""),
        (L10n.text("关闭"), "performClose:", "w"), (L10n.text("保存"), "saveDocument:", "s"),
        (L10n.text("另存为…"), "saveDocumentAs:", "S"), (L10n.text("重命名…"), "renameFile:", ""),
        (L10n.text("导出为 PDF…"), "exportPDF:", ""),
        (L10n.text("导出为 HTML…"), "exportHTML:", ""),
        (L10n.text("重新载入磁盘版本…"), "revertDocumentToSaved:", ""),
        (L10n.text("恢复未保存草稿…"), "restoreDrafts:", ""), ("", "", ""),
        (L10n.text("页面设置…"), "runPageLayout:", "P"), (L10n.text("打印…"), "printMarkdown:", "p"),
      ]),
      (L10n.text("编辑"), [
        (L10n.text("撤销"), "undo:", "z"), (L10n.text("重做"), "redo:", "Z"),
        (L10n.text("剪切"), "cut:", "x"), (L10n.text("复制"), "copy:", "c"),
        (L10n.text("粘贴"), "paste:", "v"), (L10n.text("全选"), "selectAll:", "a"),
        (L10n.text("复制 Markdown"), "copyMarkdown", ""), (L10n.text("粘贴为纯文本"), "pastePlainText", "V"),
        ("", "", ""), (L10n.text("查找与替换…"), "find", "f"),
        (L10n.text("查找下一个"), "findNext", "g"), (L10n.text("查找上一个"), "findPrevious", "G"),
        ("", "", ""), (L10n.text("在文件夹中查找…"), "findInFolder:", "F"),
        ("", "", ""), (L10n.text("拼写和语法"), "spellingMenu", ""),
      ]),
      (L10n.text("格式"), [
        (L10n.text("粗体"), "bold", "b"), (L10n.text("斜体"), "italic", "i"), (L10n.text("删除线"), "strikethrough", "X"),
        (L10n.text("行内代码"), "inlineCode", "e"), (L10n.text("链接"), "link", "k"), ("", "", ""),
        (L10n.text("一级标题"), "heading1", "1"), (L10n.text("二级标题"), "heading2", "2"),
        (L10n.text("三级标题"), "heading3", "3"), (L10n.text("四级标题"), "heading4", "4"),
        (L10n.text("五级标题"), "heading5", "5"), (L10n.text("六级标题"), "heading6", "6"), ("", "", ""),
        (L10n.text("有序列表"), "orderedList", "7"), (L10n.text("无序列表"), "bulletList", "8"),
        (L10n.text("任务列表"), "taskList", "9"), (L10n.text("引用"), "blockquote", "."),
        (L10n.text("代码块"), "codeBlock", "C"), (L10n.text("分隔线"), "horizontalRule", "H"),
        (L10n.text("插入本地图片…"), "insertImage:", ""), (L10n.text("表格"), "tableMenu", ""), (L10n.text("公式块"), "insertMathBlock", ""),
      ]),
      (L10n.text("显示"), [
        (L10n.text("文件树"), "toggleFiles", "E"), (L10n.text("标题大纲"), "toggleOutline", "O"), (L10n.text("源码模式"), "toggleSourceMode", "M"),
        (L10n.text("专注模式"), "toggleFocusMode:", "F8"), (L10n.text("打字机模式"), "toggleTypewriterMode:", "F9"),
        ("", "", ""), (L10n.text("字体与字号…"), "showFontSettings:", "t"),
        (L10n.text("恢复默认字体"), "resetFonts:", ""), ("", "", ""),
        (L10n.text("实际大小"), "resetZoom:", "0"), (L10n.text("放大"), "zoomIn:", "+"), (L10n.text("缩小"), "zoomOut:", "-"),
        ("", "", ""), (L10n.text("进入全屏幕"), "toggleFullScreen:", "f"),
      ]),
      (L10n.text("窗口"), [
        (L10n.text("最小化"), "performMiniaturize:", "m"), (L10n.text("缩放"), "performZoom:", ""), ("", "", ""),
        (L10n.text("显示标签栏"), "toggleTabBar:", ""), (L10n.text("显示所有标签页"), "toggleTabOverview:", ""),
        (L10n.text("下一个标签页"), "selectNextTab:", "\t"), (L10n.text("上一个标签页"), "selectPreviousTab:", "\t"),
        (L10n.text("将标签页移到新窗口"), "moveTabToNewWindow:", ""), (L10n.text("合并所有窗口"), "mergeAllWindows:", ""),
        ("", "", ""), (L10n.text("前置全部窗口"), "arrangeInFront:", ""),
      ]),
      (L10n.text("帮助"), [(L10n.text("官方网站"), "openWebsite:", ""), (L10n.text("反馈"), "sendFeedback:", "")]),
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
        entry.keyEquivalentModifierMask = key != key.lowercased() || ["orderedList", "bulletList", "taskList", "blockquote"].contains(action) ? [.command, .shift] : [.command]
        if ["insertImage:", "exportPDF:", "exportHTML:", "printMarkdown:", "openWebsite:", "sendFeedback:", "checkForUpdates:"].contains(action) { entry.target = delegate }
        if ["resetZoom:", "zoomIn:", "zoomOut:"].contains(action) { entry.target = EditorZoom.shared }
        if action == "newWindowForTab:" { entry.keyEquivalentModifierMask = [.command, .option] }
        if action == "selectNextTab:" { entry.keyEquivalentModifierMask = [.control] }
        if action == "selectPreviousTab:" { entry.keyEquivalentModifierMask = [.control, .shift] }
        if action == "toggleFullScreen:" { entry.keyEquivalentModifierMask = [.command, .control] }
        if ["showFontSettings:", "resetFonts:"].contains(action) { entry.target = EditorFonts.shared }
        if ["toggleFocusMode:", "toggleTypewriterMode:"].contains(action) {
          entry.target = DisplayModes.shared
          let functionKey = action == "toggleFocusMode:" ? NSF8FunctionKey : NSF9FunctionKey
          if let scalar = UnicodeScalar(functionKey) { entry.keyEquivalent = String(scalar) }
          entry.keyEquivalentModifierMask = []
        }
        if action == "restoreDrafts:" { entry.target = delegate }
        if action == "showSettings:" { entry.target = delegate }
        if action == "openFolder:" { entry.keyEquivalentModifierMask = [.command, .option]; entry.target = delegate }
        if ["undo:", "redo:", "selectAll:"].contains(action) { entry.target = delegate }
        if !action.hasSuffix(":") {
          entry.action = #selector(AppDelegate.editorCommand(_:))
          entry.representedObject = action
          entry.target = delegate
        }
        if action == "recentMenu" || action == "recentFoldersMenu" {
          entry.action = nil
          entry.representedObject = nil
          entry.target = nil
          entry.submenu = action == "recentMenu" ? RecentDocumentsMenu.shared.menu : RecentFoldersMenu.shared.menu
        }
        if action == "spellingMenu" {
          // 系统标准动作，由当前编辑器 WebView 响应并显示勾选状态；设置由 WebKit 保存。
          entry.action = nil
          entry.representedObject = nil
          entry.target = nil
          let spelling = NSMenu(title: L10n.text("拼写和语法"))
          for (title, selector, key) in [
            (L10n.text("显示拼写和语法"), "showGuessPanel:", ":"), (L10n.text("立即检查文稿"), "checkSpelling:", ";"),
            ("", "", ""), (L10n.text("输入时检查拼写"), "toggleContinuousSpellChecking:", ""),
          ] {
            spelling.addItem(title.isEmpty ? .separator() : NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
          }
          entry.submenu = spelling
        }
        if action == "tableMenu" {
          entry.action = nil
          let tables = NSMenu(title: L10n.text("表格"))
          for (title, command) in [
            (L10n.text("插入表格"), "insertTable"), (L10n.text("在上方插入行"), "tableRowAbove"), (L10n.text("在下方插入行"), "tableRowBelow"),
            (L10n.text("在左侧插入列"), "tableColumnBefore"), (L10n.text("在右侧插入列"), "tableColumnAfter"),
            (L10n.text("删除当前行"), "tableDeleteRow"), (L10n.text("删除当前列"), "tableDeleteColumn"),
            (L10n.text("当前列左对齐"), "tableAlignLeft"), (L10n.text("当前列居中"), "tableAlignCenter"), (L10n.text("当前列右对齐"), "tableAlignRight"),
          ] {
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.editorCommand(_:)), keyEquivalent: "")
            item.representedObject = command
            item.target = delegate
            tables.addItem(item)
          }
          entry.submenu = tables
        }
        submenu.addItem(entry)
        if action == "zoomIn:" {
          // 美式键盘上 ⌘+ 需要按 Shift，补一个隐藏的 ⌘= 让不按 Shift 也能放大。
          let alternate = NSMenuItem(title: label, action: entry.action, keyEquivalent: "=")
          alternate.target = EditorZoom.shared
          alternate.isHidden = true
          alternate.allowsKeyEquivalentWhenHidden = true
          submenu.addItem(alternate)
        }
      }
      menu.addItem(item)
      if title == L10n.text("窗口") { NSApp.windowsMenu = submenu }
      // 系统会给帮助菜单自动加入搜索框；把帮助菜单指向一个不显示的空菜单，真正的帮助菜单就只有官方网站和反馈。
      if title == L10n.text("帮助") { NSApp.helpMenu = NSMenu(title: "") }
    }
    return menu
  }
}
