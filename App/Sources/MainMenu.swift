import AppKit

/// 主菜单；与入口分开，便于测试目标直接编译与检查。
@MainActor
enum MainMenu {
  static func make(delegate: AppDelegate) -> NSMenu {
    let menu = NSMenu()
    let groups: [(String, [(String, String, String)])] = [
      ("Inkpot", [
        ("设置…", "showSettings:", ","), ("检查更新…", "checkForUpdates:", ""), ("", "", ""), ("退出 Inkpot", "terminate:", "q"),
      ]),
      ("文件", [
        ("新建", "newDocument:", "n"), ("新建标签页", "newWindowForTab:", "n"), ("打开…", "openDocument:", "o"),
        ("打开文件夹…", "openFolder:", "o"), ("打开最近使用", "recentMenu", ""), ("打开最近的文件夹", "recentFoldersMenu", ""),
        ("关闭", "performClose:", "w"), ("保存", "saveDocument:", "s"),
        ("另存为…", "saveDocumentAs:", "S"), ("重命名…", "renameFile:", ""),
        ("导出为 PDF…", "exportPDF:", ""),
        ("导出为 HTML…", "exportHTML:", ""),
        ("重新载入磁盘版本…", "revertDocumentToSaved:", ""),
        ("恢复未保存草稿…", "restoreDrafts:", ""), ("", "", ""),
        ("页面设置…", "runPageLayout:", "P"), ("打印…", "printMarkdown:", "p"),
      ]),
      ("编辑", [
        ("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
        ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
        ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a"),
        ("复制 Markdown", "copyMarkdown", ""), ("粘贴为纯文本", "pastePlainText", "V"),
        ("", "", ""), ("查找与替换…", "find", "f"),
        ("查找下一个", "findNext", "g"), ("查找上一个", "findPrevious", "G"),
        ("", "", ""), ("在文件夹中查找…", "findInFolder:", "F"),
        ("", "", ""), ("拼写和语法", "spellingMenu", ""),
      ]),
      ("格式", [
        ("粗体", "bold", "b"), ("斜体", "italic", "i"), ("删除线", "strikethrough", "X"),
        ("行内代码", "inlineCode", "e"), ("链接", "link", "k"), ("", "", ""),
        ("一级标题", "heading1", "1"), ("二级标题", "heading2", "2"),
        ("三级标题", "heading3", "3"), ("四级标题", "heading4", "4"),
        ("五级标题", "heading5", "5"), ("六级标题", "heading6", "6"), ("", "", ""),
        ("有序列表", "orderedList", "7"), ("无序列表", "bulletList", "8"),
        ("任务列表", "taskList", "9"), ("引用", "blockquote", "."),
        ("代码块", "codeBlock", "C"), ("分隔线", "horizontalRule", "H"),
        ("插入本地图片…", "insertImage:", ""), ("表格", "tableMenu", ""), ("公式块", "insertMathBlock", ""),
      ]),
      ("显示", [
        ("文件树", "toggleFiles", "E"), ("标题大纲", "toggleOutline", "O"), ("源码模式", "toggleSourceMode", "M"),
        ("专注模式", "toggleFocusMode:", "F8"), ("打字机模式", "toggleTypewriterMode:", "F9"),
        ("", "", ""), ("正文字体与字号…", "showBodyFont:", "t"), ("代码字体与字号…", "showCodeFont:", ""),
        ("恢复默认字体", "resetFonts:", ""), ("", "", ""),
        ("实际大小", "resetZoom:", "0"), ("放大", "zoomIn:", "+"), ("缩小", "zoomOut:", "-"),
        ("", "", ""), ("进入全屏幕", "toggleFullScreen:", "f"),
      ]),
      ("窗口", [
        ("最小化", "performMiniaturize:", "m"), ("缩放", "performZoom:", ""), ("", "", ""),
        ("显示标签栏", "toggleTabBar:", ""), ("显示所有标签页", "toggleTabOverview:", ""),
        ("下一个标签页", "selectNextTab:", "\t"), ("上一个标签页", "selectPreviousTab:", "\t"),
        ("将标签页移到新窗口", "moveTabToNewWindow:", ""), ("合并所有窗口", "mergeAllWindows:", ""),
        ("", "", ""), ("前置全部窗口", "arrangeInFront:", ""),
      ]),
      ("帮助", [("官方网站", "openWebsite:", ""), ("反馈", "sendFeedback:", "")]),
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
        if ["showBodyFont:", "showCodeFont:", "resetFonts:"].contains(action) { entry.target = EditorFonts.shared }
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
          let spelling = NSMenu(title: "拼写和语法")
          for (title, selector, key) in [
            ("显示拼写和语法", "showGuessPanel:", ":"), ("立即检查文稿", "checkSpelling:", ";"),
            ("", "", ""), ("输入时检查拼写", "toggleContinuousSpellChecking:", ""),
          ] {
            spelling.addItem(title.isEmpty ? .separator() : NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
          }
          entry.submenu = spelling
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
      if title == "窗口" { NSApp.windowsMenu = submenu }
      // 系统会给帮助菜单自动加入搜索框；把帮助菜单指向一个不显示的空菜单，真正的帮助菜单就只有官方网站和反馈。
      if title == "帮助" { NSApp.helpMenu = NSMenu(title: "") }
    }
    return menu
  }
}
