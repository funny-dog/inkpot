import AppKit
import WebKit
import XCTest

/// 对照第二阶段设计稿的关键数值，在真实 WebKit 与窗口布局中核验，不依赖截图。
@MainActor
final class DesignConformanceTests: XCTestCase {
  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func json(_ editor: EditorViewController, _ script: String) async throws -> [String: Any] {
    let value = try await editor.evaluateScript("JSON.stringify((() => { \(script) })())")
    let text = try XCTUnwrap(value as? String)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }

  func testDocumentWindowMatchesDesignLayout() async throws {
    _ = NSApplication.shared
    let document = InkpotDocument()
    document.makeWindowControllers()
    defer { document.close() }
    let window = try XCTUnwrap(document.windowControllers.first?.window)
    window.setContentSize(NSSize(width: 1200, height: 780))
    let controller = try XCTUnwrap(window.contentViewController as? DocumentViewController)
    let editor = try XCTUnwrap(document.editor)
    controller.view.layoutSubtreeIfNeeded()
    try await waitUntil { editor.isReady }

    // 窗口：内容延伸到标题栏下方，统一工具栏。
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertEqual(window.toolbarStyle, .unified)
    // 编辑器从安全区起排，不被工具栏遮住。
    let editorTop = editor.view.convert(editor.view.bounds, to: nil).maxY
    XCTAssertLessThanOrEqual(editorTop, window.contentLayoutRect.maxY + 0.5)

    // 正文：限宽 45em + 左右各 48px 内边距并居中，行距 1.75，标题前留白。
    let layout = try await json(editor, """
      const content = document.querySelector('.cm-content');
      const scroller = document.querySelector('.cm-scroller');
      const box = content.getBoundingClientRect();
      const style = getComputedStyle(content);
      const size = parseFloat(getComputedStyle(scroller).fontSize);
      return { size, width: box.width, left: box.left, scrollerWidth: scroller.clientWidth,
        lineHeight: parseFloat(getComputedStyle(scroller).lineHeight), padTop: parseFloat(style.paddingTop), padLeft: parseFloat(style.paddingLeft) };
      """)
    let size = number(layout["size"])
    XCTAssertEqual(number(layout["width"]), min(45 * size + 96, number(layout["scrollerWidth"])), accuracy: 1)
    XCTAssertEqual(number(layout["left"]) * 2 + number(layout["width"]), number(layout["scrollerWidth"]), accuracy: 2)
    XCTAssertEqual(number(layout["lineHeight"]), size * 1.75, accuracy: 0.5)
    XCTAssertEqual(number(layout["padTop"]), 44)
    XCTAssertEqual(number(layout["padLeft"]), 48)

    // 空文档：占位文字与底部快捷键提示条（距底 56px，四项）。
    let empty = try await json(editor, """
      const hints = document.querySelector('.cm-inkpot-welcome');
      const editorBox = document.querySelector('.cm-editor').getBoundingClientRect();
      return { placeholder: document.querySelector('.cm-placeholder')?.textContent ?? '', shown: getComputedStyle(hints).display !== 'none',
        bottom: editorBox.bottom - hints.getBoundingClientRect().bottom, keys: [...hints.querySelectorAll('dt')].map(node => node.textContent) };
      """)
    XCTAssertEqual(empty["placeholder"] as? String, L10n.language == "en" ? "Start writing…" : "开始写作…")
    XCTAssertEqual(empty["shown"] as? Bool, true)
    XCTAssertEqual(number(empty["bottom"]), 56, accuracy: 1)
    XCTAssertEqual(empty["keys"] as? [String], ["⌘O", "⌥⌘O", "⇧⌘M", "⌘,"])

    // 查找栏：输入框在左、“完成”贴右，选项与箭头组在中间，高度与圆角按稿。
    editor.performCommand("find")
    try await waitUntil { try await editor.evaluateScript("document.querySelector('.cm-inkpot-search') !== null") as? Bool == true }
    let find = try await json(editor, """
      const panel = document.querySelector('.cm-inkpot-search');
      if (!panel) return { open: false };
      const rect = selector => panel.querySelector(selector).getBoundingClientRect();
      const field = rect('.cm-inkpot-search-field'), options = rect('.cm-inkpot-search-options'), nav = rect('.cm-inkpot-search-nav');
      const done = rect('button[name=close]'), panelBox = panel.getBoundingClientRect();
      return { open: true, order: field.right <= options.left && options.right <= nav.left && nav.right <= done.left,
        doneGap: panelBox.right - done.right, fieldHeight: field.height, fieldRadius: getComputedStyle(panel.querySelector('.cm-inkpot-search-field')).borderTopLeftRadius,
        top: panelBox.top };
      """)
    XCTAssertEqual(find["open"] as? Bool, true)
    XCTAssertEqual(find["order"] as? Bool, true)
    XCTAssertEqual(number(find["doneGap"]), 12, accuracy: 1)
    XCTAssertEqual(number(find["fieldHeight"]), 26, accuracy: 0.5)
    XCTAssertEqual(find["fieldRadius"] as? String, "6px")
    XCTAssertEqual(number(find["top"]), 0, accuracy: 0.5)

    // 状态栏：模式、保存状态、字数。
    let container = try XCTUnwrap(controller.splitViewItems.last?.viewController as? EditorContainerViewController)
    XCTAssertEqual(container.modeText, L10n.text("实时模式"))
    XCTAssertEqual(container.saveText, "")
    container.showSaveState(edited: true, saved: true, autosave: false)
    XCTAssertEqual(container.saveText, L10n.text("未保存"))
    container.showSaveState(edited: false, saved: true, autosave: true)
    XCTAssertEqual(container.saveText, L10n.text("已自动保存"))
  }

  func testSidebarStartsBelowTitlebarAndTabsMatchDesign() throws {
    let document = InkpotDocument()
    document.makeWindowControllers()
    defer { document.close() }
    let window = try XCTUnwrap(document.windowControllers.first?.window)
    let controller = try XCTUnwrap(window.contentViewController as? DocumentViewController)
    controller.view.layoutSubtreeIfNeeded()
    let sidebar = try XCTUnwrap(controller.splitViewItems.first?.viewController as? SidebarViewController)
    let tabs = sidebar.tabs.convert(sidebar.tabs.bounds, to: nil)
    // 切换条在红绿灯所在的标题栏区域下方，高 28、两侧各留 12。
    XCTAssertLessThanOrEqual(tabs.maxY, window.contentLayoutRect.maxY)
    XCTAssertEqual(tabs.height, 28)
    XCTAssertEqual(tabs.minX, 12)
    XCTAssertEqual(sidebar.view.frame.width - tabs.maxX, 12, accuracy: 0.5)
  }
}
