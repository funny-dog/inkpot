import AppKit
import WebKit
import XCTest

@MainActor
final class DocumentTests: XCTestCase {
  func testWritingKeysContinueAndExitMarkupWithIndependentUndoAndExactSave() async throws {
    _ = NSApplication.shared
    for (prefix, nextPrefix, parentPrefix) in [("- ", "- ", ""), ("9) ", "10) ", ""), ("> ", "> ", ""), ("> - ", "> - ", "> ")] {
      let document = MVPDocument()
      defer { document.close() }
      let original = "\u{FEFF}\(prefix)中文\r\n尾\n"
      try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
      let editor = document.makeEditor()
      let webView = try XCTUnwrap(editor.view as? WKWebView)
      try await waitUntil { editor.isReady }
      editor.performCommand("find")
      try await waitUntil {
        try await webView.evaluateJavaScript("document.activeElement?.name === 'search'") as? Bool == true
      }
      _ = try await webView.evaluateJavaScript("""
        const find = document.querySelector('input[name=search]');
        find.value = '中文'; find.dispatchEvent(new InputEvent('input', {bubbles: true}));
        document.querySelector('button[name=next]').click();
        document.querySelector('button[name=close]').click();
        for (const [key, keyCode] of [['ArrowRight', 39], ['Enter', 13]]) {
          document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key, keyCode, bubbles: true, cancelable: true}));
        } null
        """)
      let continued = try await editor.snapshot()
      XCTAssertEqual(continued.text, "\(prefix)中文\r\n\(nextPrefix)\r\n尾\n")
      _ = try await webView.evaluateJavaScript("""
        document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {
          key: 'Enter', keyCode: 13, bubbles: true, cancelable: true
        })); null
        """)
      let exited = try await editor.snapshot()
      XCTAssertEqual(exited.text, "\(prefix)中文\r\n\(parentPrefix)\r\n尾\n")
      editor.undo(nil)
      try await waitUntil { editor.latestRevision > exited.revision }
      let undone = try await editor.snapshot()
      XCTAssertEqual(undone.text, continued.text)
      editor.undo(nil)
      try await waitUntil { editor.latestRevision > undone.revision }
      try await document.synchronize()
      XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
      XCTAssertFalse(document.isDocumentEdited)
    }
  }

  func testLivePreviewAndNativeModeSwitchPreserveSourceAndSavedState() async throws {
    _ = NSApplication.shared
    let document = MVPDocument()
    defer { document.close() }
    let original = "\u{FEFF}# 标题\r\n**粗体** 和 *斜体*\n- 列表\r\n> 引用"
    let data = Data(original.utf8)
    try document.read(from: data, ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    let rendered = try await webView.evaluateJavaScript("""
      document.querySelector('.cm-mvp-heading1')?.textContent === '标题' &&
      document.querySelector('.cm-mvp-list-marker')?.textContent === '• ' &&
      document.querySelectorAll('.cm-mvp-hidden-inline').length === 4 &&
      getComputedStyle(document.querySelector('.cm-mvp-hidden-inline')).fontSize === '0px'
      """) as? Bool
    XCTAssertTrue(try XCTUnwrap(rendered))
    editor.performCommand("find")
    try await waitUntil {
      try await webView.evaluateJavaScript("document.activeElement?.name === 'search'") as? Bool == true
    }
    _ = try await webView.evaluateJavaScript("""
      const find = document.querySelector('input[name=search]');
      find.value = '粗体'; find.dispatchEvent(new InputEvent('input', {bubbles: true})); null
      """)
    editor.performCommand("findNext")
    try await waitUntil {
      try await webView.evaluateJavaScript("document.querySelectorAll('.cm-mvp-hidden-inline').length === 2") as? Bool == true
    }
    _ = try await webView.evaluateJavaScript("document.querySelector('button[name=close]').click(); null")
    let item = NSMenuItem(title: "源码模式", action: nil, keyEquivalent: "M")
    item.representedObject = "toggleSourceMode"
    XCTAssertTrue(editor.validateMenuItem(item))
    XCTAssertEqual(item.state, .off)
    editor.performCommand("toggleSourceMode")
    try await waitUntil { editor.validateMenuItem(item) && item.state == .on }
    let sourceVisible = try await webView.evaluateJavaScript("""
      document.querySelector('.cm-content').textContent.includes('# 标题') &&
      document.querySelector('.cm-mvp-hidden-inline') === null &&
      document.querySelector('.cm-mvp-list-marker') === null
      """) as? Bool
    XCTAssertTrue(try XCTUnwrap(sourceVisible))
    editor.performCommand("toggleSourceMode")
    try await waitUntil { editor.validateMenuItem(item) && item.state == .off }
    let snapshot = try await editor.snapshot()
    XCTAssertEqual(snapshot.revision, 0)
    XCTAssertEqual(editor.latestRevision, 0)
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), data)
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testNativeFormattingAndSearchShareEditorHistoryWithoutChangingSearchInputIntoDocument() async throws {
    _ = NSApplication.shared
    let document = MVPDocument()
    defer { document.close() }
    let original = "# 标题\r\n中文 中文\n尾"
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    editor.performCommand("heading2")
    try await waitUntil { editor.latestRevision > 0 }
    let formatted = try await editor.snapshot()
    XCTAssertEqual(formatted.text, "## 标题\r\n中文 中文\n尾")
    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertFalse(document.isDocumentEdited)

    editor.performCommand("find")
    try await waitUntil {
      try await webView.evaluateJavaScript("document.activeElement?.name === 'search'") as? Bool == true
    }
    let formatItem = NSMenuItem(title: "粗体", action: nil, keyEquivalent: "b")
    formatItem.representedObject = "bold"
    try await waitUntil { !editor.validateMenuItem(formatItem) }
    _ = try await webView.evaluateJavaScript("""
      const find = document.querySelector('input[name=search]');
      find.value = '中文'; find.dispatchEvent(new InputEvent('input', {bubbles: true})); null
      """)
    editor.selectAll(nil)
    try await waitUntil {
      try await webView.evaluateJavaScript("document.activeElement.selectionStart === 0 && document.activeElement.selectionEnd === 2") as? Bool == true
    }
    editor.performCommand("bold")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)

    _ = try await webView.evaluateJavaScript("""
      const replacement = document.querySelector('input[name=replace]');
      replacement.value = '替换'; replacement.dispatchEvent(new InputEvent('input', {bubbles: true}));
      document.querySelector('button[name=replaceAll]').click(); null
      """)
    let replaced = try await editor.snapshot()
    XCTAssertEqual(replaced.text, "# 标题\r\n替换 替换\n尾")
    _ = try await webView.evaluateJavaScript("document.querySelector('button[name=close]').click(); null")
    let replacedRevision = replaced.revision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > replacedRevision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testEditorSnapshotSaveAndBackupKeepLatestInputAndDirtyState() async throws {
    _ = NSApplication.shared
    let document = MVPDocument()
    defer { document.close() }
    let original = "# 中文\r\n<script>字面文本</script>\n"
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    let initialSnapshot = try await editor.snapshot()
    XCTAssertEqual(initialSnapshot.text, original)
    _ = try await webView.evaluateJavaScript(
      "document.querySelector('.cm-content').focus(); document.execCommand('insertText', false, '末字');"
    )
    try await waitUntil { editor.latestRevision > 0 }
    XCTAssertThrowsError(try document.data(ofType: "net.daringfireball.markdown"))
    try await document.synchronize()
    let updated = try document.data(ofType: "net.daringfireball.markdown")
    XCTAssertEqual(updated, Data(("末字" + original).utf8))
    XCTAssertTrue(document.isDocumentEdited)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try document.writeSafely(to: folder.appendingPathComponent("backup.md"), ofType: "net.daringfireball.markdown", for: .autosaveElsewhereOperation)
    try await document.synchronize()
    XCTAssertTrue(document.isDocumentEdited)
    try document.writeSafely(to: folder.appendingPathComponent("saved.md"), ofType: "net.daringfireball.markdown", for: .saveOperation)
    try await document.synchronize()
    XCTAssertFalse(document.isDocumentEdited)

    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertTrue(document.isDocumentEdited)
    _ = try await webView.evaluateJavaScript(
      "window.inkpotMVP.snapshot = () => { throw new Error('模拟同步失败'); }; null"
    )
    do {
      try await document.synchronize()
      XCTFail("同步失败时不应允许保存旧快照")
    } catch {
      XCTAssertTrue(editor.isReady)
      XCTAssertThrowsError(try document.data(ofType: "net.daringfireball.markdown"))
    }
    editor.webViewWebContentProcessDidTerminate(webView)
    do {
      _ = try await editor.snapshot()
      XCTFail("编辑器停止后不应允许读取旧快照")
    } catch {
      XCTAssertThrowsError(try document.data(ofType: "net.daringfireball.markdown"))
    }
  }

  func testUneditedUTF8RoundTripsExactBytes() throws {
    for source in ["", "# 中文 👨‍👩‍👧\n", "a\r\nb\nc\rd\r\n", "e\u{301}\t  \n", "\u{FEFF}# BOM\r\n"] {
      let data = Data(source.utf8)
      let document = MVPDocument()
      try document.read(from: data, ofType: "net.daringfireball.markdown")
      XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), data)
    }
  }

  func testEditingRetainsBOMAndUnicodeBytes() throws {
    var content = try DocumentContent(data: Data("\u{FEFF}初始\r\n".utf8))
    content.text = "e\u{301}\r\n中文"
    XCTAssertEqual(content.data, Data("\u{FEFF}e\u{301}\r\n中文".utf8))
  }

  func testInvalidEncodingDoesNotReplaceLoadedDocument() throws {
    let document = MVPDocument()
    let original = Data("原文件\r\n".utf8)
    try document.read(from: original, ofType: "net.daringfireball.markdown")
    for invalid in [Data([0xFF, 0xFE, 0x41, 0x00]), Data([0xC3, 0x28]), Data([0xEF, 0xBB, 0xBF, 0xFF])] {
      XCTAssertThrowsError(try document.read(from: invalid, ofType: "net.daringfireball.markdown"))
      XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), original)
    }
  }

  func testSafeWriteAndFailedWriteKeepDocumentContent() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let document = MVPDocument()
    let data = Data("\u{FEFF}# 保存\r\n".utf8)
    try document.read(from: data, ofType: "net.daringfireball.markdown")
    let destination = folder.appendingPathComponent("note.md")
    try document.writeSafely(to: destination, ofType: "net.daringfireball.markdown", for: .saveOperation)
    XCTAssertEqual(try Data(contentsOf: destination), data)
    XCTAssertThrowsError(try document.writeSafely(
      to: folder.appendingPathComponent("missing/note.md"),
      ofType: "net.daringfireball.markdown",
      for: .saveOperation
    ))
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), data)
    XCTAssertEqual(try Data(contentsOf: destination), data)
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else {
        throw NSError(domain: "InkpotMVPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待编辑器状态超时"])
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

extension DocumentTests {
  func testCodeBlocksEditLanguageCreateTypeExitAndUndoWithoutChangingOriginalBytes() async throws {
    _ = NSApplication.shared
    let document = MVPDocument()
    defer { document.close() }
    let original = "\u{FEFF}```js\r\n\t原文  \n```\r尾"
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    let rendered = try await webView.evaluateJavaScript("""
      document.querySelector('.cm-mvp-code-language')?.textContent === 'js' &&
      !document.querySelector('.cm-content').textContent.includes('```') &&
      getComputedStyle(document.querySelectorAll('.cm-mvp-code')[1]).fontFamily.includes('Menlo')
      """) as? Bool
    XCTAssertTrue(try XCTUnwrap(rendered))
    _ = try await webView.evaluateJavaScript("""
      document.querySelector('.cm-mvp-code-language').click();
      document.execCommand('insertText', false, 'python');
      document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', keyCode: 13, bubbles: true, cancelable: true})); null
      """)
    let changed = try await editor.snapshot()
    XCTAssertEqual(changed.text, "```python\r\n\t原文  \n```\r尾")
    let labelUpdated = try await webView.evaluateJavaScript("document.querySelector('.cm-mvp-code-language')?.textContent === 'python'") as? Bool
    XCTAssertTrue(try XCTUnwrap(labelUpdated))
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > changed.revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)

    try document.read(from: Data("```".utf8), ofType: "net.daringfireball.markdown")
    try await waitUntil { editor.isReady }
    _ = try await webView.evaluateJavaScript("""
      for (const [key, keyCode] of [['End', 35], ['Enter', 13]]) {
        document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key, keyCode, bubbles: true, cancelable: true}));
      } null
      """)
    let created = try await editor.snapshot()
    XCTAssertEqual(created.text, "```\n\n```")
    _ = try await webView.evaluateJavaScript("document.execCommand('insertText', false, '字'); null")
    let typed = try await editor.snapshot()
    XCTAssertEqual(typed.text, "```\n字\n```")
    _ = try await webView.evaluateJavaScript("""
      document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', keyCode: 13, metaKey: true, bubbles: true, cancelable: true})); null
      """)
    let exited = try await editor.snapshot()
    XCTAssertEqual(exited.text, "```\n字\n```\n")
    for _ in 0..<3 {
      let revision = editor.latestRevision
      editor.undo(nil)
      try await waitUntil { editor.latestRevision > revision }
    }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data("```".utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }
}

extension DocumentTests {
  func testOutlineHierarchyKeepsCollapseAndUsesAncestorHighlightWithoutNavigating() {
    _ = NSApplication.shared
    let controller = OutlineViewController()
    let entries = [
      DocumentHeading(id: 0, from: 0, to: 4, level: 1, title: "同名"),
      DocumentHeading(id: 1, from: 6, to: 12, level: 3, title: "子标题"),
      DocumentHeading(id: 2, from: 14, to: 19, level: 2, title: "同名"),
      DocumentHeading(id: 3, from: 20, to: 24, level: 1, title: "末尾"),
    ]
    var navigations: [Int] = []
    controller.onNavigate = { navigations.append($0) }
    controller.update(entries, active: 1)
    let outline = controller.outlineView
    XCTAssertEqual(outline.numberOfRows, 4)
    XCTAssertEqual(outline.level(forRow: 1), 1)
    XCTAssertEqual(outline.level(forRow: 2), 1)
    XCTAssertEqual(outline.selectedRow, 1)
    let root = outline.item(atRow: 0)
    outline.collapseItem(root)
    controller.update(nil, active: 2)
    XCTAssertEqual(outline.numberOfRows, 2)
    XCTAssertEqual(outline.selectedRow, 0)
    var renamed = entries
    renamed[0] = DocumentHeading(id: 0, from: 0, to: 6, level: 1, title: "重命名")
    controller.update(renamed, active: 2)
    XCTAssertEqual(outline.numberOfRows, 2)
    XCTAssertFalse(outline.isItemExpanded(root))
    XCTAssertEqual((root as? OutlineViewController.Item)?.heading.title, "重命名")
    let inserted = DocumentHeading(id: 4, from: 19, to: 20, level: 4, title: "新增子标题")
    renamed.insert(inserted, at: 3)
    controller.update(renamed, active: 4)
    XCTAssertEqual(outline.numberOfRows, 2)
    XCTAssertEqual(outline.selectedRow, 0)
    XCTAssertFalse(outline.isItemExpanded(root))
    XCTAssertTrue(navigations.isEmpty)
    outline.expandItem(root)
    outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    _ = outline.target?.perform(outline.action, with: outline)
    XCTAssertEqual(navigations, [2])
    controller.reset()
    XCTAssertEqual(outline.numberOfRows, 0)
  }

  func testOutlineBridgeNavigatesScrollsAndRenamesWithoutLosingOriginalBytes() async throws {
    _ = NSApplication.shared
    let document = MVPDocument()
    defer { document.close() }
    let body = String(repeating: "正文\n\n", count: 40)
    let original = "\u{FEFF}# 第一章\r\n\(body)## **第二章**\r\n\(body)### 子标题\n\(body)```md\n# 假标题\n```\n"
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let webView = try XCTUnwrap(editor.view as? WKWebView)
    // 隐藏测试窗口没有显示帧，用定时器驱动相同的测量回调。
    webView.configuration.userContentController.addUserScript(WKUserScript(
      source: """
        window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16);
        window.cancelAnimationFrame = clearTimeout;
        """,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    ))
    document.makeWindowControllers()
    let window = try XCTUnwrap(document.windowControllers.first?.window)
    let container = try XCTUnwrap(window.contentViewController as? DocumentViewController)
    window.contentView?.layoutSubtreeIfNeeded()
    try await waitUntil { editor.isReady && editor.headings.count == 3 }
    XCTAssertEqual(editor.headings.map(\.title), ["第一章", "第二章", "子标题"])
    XCTAssertEqual(container.outline.outlineView.numberOfRows, 3)
    let item = NSMenuItem(title: "标题大纲", action: nil, keyEquivalent: "O")
    item.representedObject = "toggleOutline"
    XCTAssertTrue(editor.validateMenuItem(item))
    XCTAssertEqual(item.state, .on)
    editor.performCommand("toggleOutline")
    try await waitUntil { editor.validateMenuItem(item) && item.state == .off }
    editor.performCommand("toggleOutline")
    try await waitUntil { editor.validateMenuItem(item) && item.state == .on }
    let second = editor.headings[1].id
    editor.navigateHeading(second)
    try await waitUntil { editor.activeHeading == second }
    let scrollTop = try await webView.evaluateJavaScript("document.querySelector('.cm-scroller').scrollTop") as? Double
    XCTAssertGreaterThan(try XCTUnwrap(scrollTop), 100)
    let first = editor.headings[0].id
    _ = try await webView.evaluateJavaScript("""
      const scroller = document.querySelector('.cm-scroller');
      scroller.scrollTop = 0; scroller.dispatchEvent(new Event('scroll')); null
      """)
    try await waitUntil { editor.activeHeading == first }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
    editor.navigateHeading(first)
    try await waitUntil {
      try await webView.evaluateJavaScript("window.getSelection()?.anchorNode?.textContent.includes('第一章')") as? Bool == true
    }
    _ = try await webView.evaluateJavaScript("document.execCommand('insertText', false, '新'); null")
    try await waitUntil { editor.headings.first?.title == "新第一章" }
    XCTAssertEqual(editor.headings.first?.id, first)
    XCTAssertEqual(editor.headings[1].id, second)
    editor.undo(nil)
    try await waitUntil { editor.headings.first?.title == "第一章" }
    editor.performCommand("toggleSourceMode")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }
}

extension DocumentTests {
  func testBasicMarkdownRenderingAndAnchorNavigationPreserveDocumentBytes() async throws {
    _ = NSApplication.shared
    let original = "\u{FEFF}起点\r\n===\r\n\r\n前 `code` 与 [跳转](#目标)\r\n\r\n---\r\n\r\n## 目标\r\n尾\n"
    let document = MVPDocument()
    defer { document.close() }
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady && editor.headings.count == 2 }
    let rendered = try await web.evaluateJavaScript("""
      document.querySelector('.cm-mvp-heading1')?.textContent === '起点' &&
      getComputedStyle(document.querySelector('.cm-mvp-setext-mark')).height === '0px' &&
      document.querySelector('.cm-mvp-inline-code') !== null &&
      document.querySelector('.cm-mvp-link') !== null &&
      document.querySelector('[role=separator]') !== null
      """) as? Bool
    XCTAssertTrue(try XCTUnwrap(rendered))
    editor.performCommand("find")
    try await waitUntil { try await web.evaluateJavaScript("document.activeElement?.name === 'search'") as? Bool == true }
    _ = try await web.evaluateJavaScript("""
      const search = document.querySelector('input[name=search]');
      search.value = '跳转'; search.dispatchEvent(new InputEvent('input', {bubbles: true}));
      document.querySelector('button[name=next]').click();
      document.querySelector('button[name=close]').click();
      document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Enter', keyCode: 13, metaKey: true, bubbles: true, cancelable: true
      })); null
      """)
    try await waitUntil { try await web.evaluateJavaScript("window.getSelection()?.anchorNode?.textContent.includes('目标')") as? Bool == true }
    let snapshot = try await editor.snapshot()
    XCTAssertEqual(snapshot.revision, 0)
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }
}

extension DocumentTests {
  func testLinkTargetsOnlyAllowExplicitSafeSchemesAndTextFiles() {
    let base = URL(fileURLWithPath: "/tmp/docs/a.md")
    XCTAssertEqual(EditorViewController.supportedLink("b.md#标题", relativeTo: base)?.path, "/tmp/docs/b.md")
    XCTAssertEqual(EditorViewController.supportedLink("中文%20文档.md#标题", relativeTo: base)?.path, "/tmp/docs/中文 文档.md")
    XCTAssertNotNil(EditorViewController.supportedLink("https://example.com", relativeTo: base))
    XCTAssertNotNil(EditorViewController.supportedLink("mailto:a@example.com", relativeTo: base))
    for link in ["javascript:alert(1)", "data:text/html,test", "file:///tmp/a.command", "file:///Applications/Test.app", "custom-app:run"] {
      XCTAssertNil(EditorViewController.supportedLink(link, relativeTo: base))
    }
  }
}

extension DocumentTests {
  func testRichPasteConvertsInWebKitAndUndoRestoresExactBytes() async throws {
    _ = NSApplication.shared
    let original = "\u{FEFF}替换\r\n尾\n"
    let document = MVPDocument()
    defer { document.close() }
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    XCTAssertTrue(editor.view is WKWebView)
    try await waitUntil { editor.isReady }
    // 无窗口 WebView 聚焦后需等待焦点迁移结束，再驱动剪贴板事件。
    try await Task.sleep(for: .milliseconds(600))
    let handled = try await editor.evaluateScript("""
      (() => {
        window.inkpotMVP.command('selectAll');
        const data = new DataTransfer();
        data.setData('text/html', '<h2>粘贴</h2><p><strong>粗体</strong>与<a href="https://example.com">链接</a></p>');
        data.setData('text/plain', '粘贴\\n粗体与链接');
        const event = new ClipboardEvent('paste', {bubbles: true, cancelable: true, clipboardData: data});
        document.querySelector('.cm-content').dispatchEvent(event);
        return event.defaultPrevented;
      })()
      """) as? Bool
    XCTAssertTrue(try XCTUnwrap(handled))
    try await waitUntil { editor.latestRevision > 0 }
    let pasted = try await editor.snapshot()
    let expected = "## 粘贴\r\n\r\n**粗体**与[链接](https://example.com)"
    XCTAssertEqual(pasted.text, expected)
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(("\u{FEFF}" + expected).utf8))
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > pasted.revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }
}
