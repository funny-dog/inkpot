import AppKit
import PDFKit
import WebKit
import XCTest

@MainActor
final class BasicsTests: XCTestCase {
  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func item(_ menu: NSMenu?, _ title: String) throws -> NSMenuItem {
    try XCTUnwrap(menu?.items.first { $0.title == title }, "缺少菜单项：\(title)")
  }

  func testEditorContextMenuKeepsSpellingAndReusesMenuCommands() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let main = MainMenu.make(delegate: delegate)
    let menu = NSMenu()
    let guess = NSMenuItem(title: "建议", action: nil, keyEquivalent: "")
    guess.tag = 15
    let reload = NSMenuItem(title: "重新载入", action: nil, keyEquivalent: "")
    reload.tag = 12
    menu.items = [guess, reload]
    EditorContextMenu.rebuild(menu, mainMenu: main)
    XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["建议", "剪切", "拷贝", "粘贴", "复制 / 粘贴为…", "段落", "格式", "插入"])
    let format = try XCTUnwrap(menu.items.first { $0.title == "格式" }?.submenu)
    XCTAssertEqual(format.items.map(\.title), ["粗体", "斜体", "删除线", "行内代码", "链接"])
    XCTAssertEqual(format.items.first?.keyEquivalent, "b")
    XCTAssertIdentical(format.items.first?.target, delegate)
    let insert = try XCTUnwrap(menu.items.first { $0.title == "插入" }?.submenu)
    XCTAssertEqual(insert.items.map(\.title), ["插入本地图片…", "插入表格", "分隔线"])
    XCTAssertEqual(menu.items.first { $0.title == "段落" }?.submenu?.items.filter { !$0.isSeparatorItem }.count, 12)
  }

  func testMenusIncludeStandardMacItemsWithExpectedShortcuts() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let menu = MainMenu.make(delegate: delegate)
    let app = menu.items[0].submenu
    let file = menu.items[1].submenu
    let edit = menu.items[2].submenu
    let display = menu.items[4].submenu
    let window = menu.items[5].submenu

    // 应用菜单依次为设置、检查更新与退出；第三方许可在设置 → 通用 → 关于中查看。
    XCTAssertEqual(app?.items.filter { !$0.isSeparatorItem }.map(\.title), ["设置…", "检查更新…", "退出 Inkpot"])
    let updates = try item(app, "检查更新…")
    XCTAssertIdentical(updates.target, delegate)
    XCTAssertTrue(delegate.validateMenuItem(updates))
    let help = menu.items.last?.submenu
    XCTAssertEqual(help?.items.map(\.title), ["官方网站", "反馈"])
    XCTAssertNotIdentical(NSApp.helpMenu, help)
    XCTAssertEqual(help?.items.allSatisfy { $0.target === delegate && delegate.validateMenuItem($0) }, true)
    XCTAssertEqual(app?.items.last?.title, "退出 Inkpot")

    let recent = try item(file, "打开最近使用")
    XCTAssertIdentical(recent.submenu, RecentDocumentsMenu.shared.menu)
    let print = try item(file, "打印…")
    XCTAssertEqual(print.keyEquivalent, "p")
    XCTAssertEqual(print.keyEquivalentModifierMask, NSEvent.ModifierFlags([.command]))
    XCTAssertIdentical(print.target, delegate)
    let pageSetup = try item(file, "页面设置…")
    XCTAssertEqual(pageSetup.action, NSSelectorFromString("runPageLayout:"))
    XCTAssertEqual(pageSetup.keyEquivalentModifierMask, NSEvent.ModifierFlags([.command, .shift]))

    let spelling = try XCTUnwrap(try item(edit, "拼写和语法").submenu)
    XCTAssertEqual(spelling.items.compactMap { $0.action.map(NSStringFromSelector) }, ["showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:"])
    XCTAssertTrue(spelling.items.allSatisfy { $0.target == nil })

    for (title, key) in [("实际大小", "0"), ("放大", "+"), ("缩小", "-")] {
      let zoom = try item(display, title)
      XCTAssertEqual(zoom.keyEquivalent, key)
      XCTAssertEqual(zoom.keyEquivalentModifierMask, NSEvent.ModifierFlags([.command]))
      XCTAssertIdentical(zoom.target, EditorZoom.shared)
    }
    XCTAssertEqual(display?.items.contains { $0.isHidden && $0.keyEquivalent == "=" && $0.allowsKeyEquivalentWhenHidden }, true)
    XCTAssertEqual(try item(file, "重命名…").action, NSSelectorFromString("renameFile:"))
    let dock = try XCTUnwrap(delegate.applicationDockMenu(NSApp))
    XCTAssertEqual(dock.items.map(\.title), ["新建", "打开…"])
    // 没有当前编辑器（其他应用在前台）时程序坞菜单也必须可用。
    XCTAssertTrue(dock.items.allSatisfy { delegate.validateMenuItem($0) })

    let fullScreen = try item(display, "进入全屏幕")
    XCTAssertEqual(fullScreen.action, NSSelectorFromString("toggleFullScreen:"))
    XCTAssertEqual(fullScreen.keyEquivalent, "f")
    XCTAssertEqual(fullScreen.keyEquivalentModifierMask, NSEvent.ModifierFlags([.command, .control]))

    let actions = window?.items.compactMap { $0.action.map(NSStringFromSelector) }
    XCTAssertEqual(actions, [
      "performMiniaturize:", "performZoom:", "toggleTabBar:", "toggleTabOverview:", "selectNextTab:", "selectPreviousTab:",
      "moveTabToNewWindow:", "mergeAllWindows:", "arrangeInFront:",
    ])
    XCTAssertIdentical(NSApp.windowsMenu, window)
  }

  func testThirdPartyNoticesLoadsBundledTextInReadOnlyWindow() throws {
    _ = NSApplication.shared
    let window = try ThirdPartyNotices.makeWindow()
    let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
    let text = try XCTUnwrap(scroll.documentView as? NSTextView)
    XCTAssertFalse(text.isEditable)
    XCTAssertTrue(text.isSelectable)
    XCTAssertTrue(text.usesFindBar)
    XCTAssertTrue(text.string.contains("@codemirror/view"))
    XCTAssertTrue(text.string.contains("Copyright (c) 2023 MarkEdit.app"))
    XCTAssertTrue(text.string.contains("EPL-2.0"))
    XCTAssertTrue(text.string.contains("Apache License"))
    XCTAssertThrowsError(try ThirdPartyNotices.makeWindow(bundle: Bundle(for: NSObject.self)))
  }

  func testRecentMenuDisambiguatesNamesOpensAndClears() throws {
    let base = FileManager.default.temporaryDirectory
    var urls = [
      base.appendingPathComponent("甲/笔记.md"), base.appendingPathComponent("乙/笔记.md"), base.appendingPathComponent("计划.md"),
    ]
    var opened: [URL] = []
    let recent = RecentDocumentsMenu(recentURLs: { urls }, open: { opened.append($0) }, clear: { urls = [] })
    recent.menuNeedsUpdate(recent.menu)
    XCTAssertEqual(recent.menu.items.map(\.title), ["笔记.md — 甲", "笔记.md — 乙", "计划.md", "", "清除菜单"])
    XCTAssertEqual(recent.menu.items[1].toolTip, urls[1].path)
    let clear = try XCTUnwrap(recent.menu.items.last)
    XCTAssertTrue(recent.validateMenuItem(clear))

    recent.openRecent(recent.menu.items[2])
    XCTAssertEqual(opened, [urls[2]])

    recent.clearRecent(nil)
    XCTAssertEqual(recent.menu.items.map(\.title), ["清除菜单"])
    XCTAssertFalse(recent.validateMenuItem(try XCTUnwrap(recent.menu.items.last)))
  }

  func testTextCheckingDefaultsEnableSpellingAndDisableRewrites() throws {
    let suite = "InkpotTextCheckingTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    TextChecking.registerDefaults(defaults)
    XCTAssertTrue(defaults.bool(forKey: "WebContinuousSpellCheckingEnabled"))
    for key in [
      "WebAutomaticSpellingCorrectionEnabled", "WebAutomaticQuoteSubstitutionEnabled", "WebAutomaticDashSubstitutionEnabled",
      "WebAutomaticTextReplacementEnabled", "WebAutomaticLinkDetectionEnabled", "WebGrammarCheckingEnabled",
    ] {
      XCTAssertNotNil(defaults.object(forKey: key), key)
      XCTAssertFalse(defaults.bool(forKey: key), key)
    }
    // 用户切换后的显式值优先于注册的默认值。
    defaults.set(false, forKey: "WebContinuousSpellCheckingEnabled")
    TextChecking.registerDefaults(defaults)
    XCTAssertFalse(defaults.bool(forKey: "WebContinuousSpellCheckingEnabled"))
  }

  func testDocumentWindowSupportsFullScreen() throws {
    _ = NSApplication.shared
    let document = InkpotDocument()
    try document.read(from: Data("正文".utf8), ofType: "net.daringfireball.markdown")
    document.makeWindowControllers()
    defer { document.close() }
    let window = try XCTUnwrap(document.windowControllers.first?.window)
    XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
  }

  func testPrintPaginatesLongDocumentWithVisibleText() async throws {
    _ = NSApplication.shared
    let paragraphs = (1...160).map { "第 \($0) 段：打印分页测试 paragraph \($0)。" }
    let text = "# 打印标题\n\n" + paragraphs.joined(separator: "\n\n") + "\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n末尾段落 END\n"
    let document = InkpotDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    defer { document.close() }
    _ = editor.view
    try await waitUntil { editor.isReady }

    let output = FileManager.default.temporaryDirectory.appendingPathComponent("inkpot-print-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    let info = NSPrintInfo()
    info.paperSize = NSSize(width: 595, height: 842)
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
    let (operation, webView) = try await DocumentPrint.operation(for: document, printInfo: info)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    // 与应用一致走表单式打印：WebKit 异步取页，主线程同步 run() 会互相等待。
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let done = PrintCompletion()
    let success = await withCheckedContinuation { continuation in
      done.continuation = continuation
      operation.runModal(for: window, delegate: done, didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }
    XCTAssertTrue(success)
    withExtendedLifetime(webView) {}

    let pdf = try XCTUnwrap(PDFDocument(url: output))
    XCTAssertGreaterThan(pdf.pageCount, 1)
    let first = try XCTUnwrap(pdf.page(at: 0)?.string)
    let last = try XCTUnwrap(pdf.page(at: pdf.pageCount - 1)?.string)
    XCTAssertTrue(first.contains("打印标题"))
    XCTAssertTrue(last.contains("END"))
    // 打印不改写文档：快照仍与原文一致。
    let snapshot = try await editor.snapshot()
    XCTAssertEqual(snapshot.text, text)
  }
}

private final class PrintCompletion: NSObject {
  var continuation: CheckedContinuation<Bool, Never>?

  @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
    continuation?.resume(returning: success)
    continuation = nil
  }
}
