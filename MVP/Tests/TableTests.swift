import AppKit
import WebKit
import XCTest

@MainActor
final class TableTests: XCTestCase {
  private let original = "\u{FEFF}前文\r\n\r\n| A |B|\r\n|:---|---:|\n| x | y |\r\n| z | q |\n\n后文"

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeDocument(_ text: String) async throws -> (MVPDocument, EditorViewController, WKWebView) {
    _ = NSApplication.shared
    let document = MVPDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    return (document, editor, web)
  }

  private func menu(_ command: String) -> NSMenuItem {
    let item = NSMenuItem(title: command, action: nil, keyEquivalent: "")
    item.representedObject = command
    return item
  }

  func testTableCellEditingNativeUndoAndMenuStatePreserveOriginalBytes() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    let table = try await web.evaluateJavaScript("document.querySelectorAll('.cm-mvp-table th').length === 2 && document.querySelector('td').style.textAlign === 'left'") as? Bool
    XCTAssertTrue(try XCTUnwrap(table))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    _ = try await web.evaluateJavaScript("""
      const target = document.querySelector('input[data-row="1"][data-column="0"]');
      target.focus(); target.value = '中文|单元格';
      target.dispatchEvent(new InputEvent('input', {bubbles: true})); null
      """)
    try await waitUntil { editor.latestRevision > 0 && editor.validateMenuItem(self.menu("tableRowBelow")) }
    XCTAssertTrue(editor.validateMenuItem(menu("tableDeleteRow")))
    XCTAssertFalse(editor.validateMenuItem(menu("heading1")))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.replacingOccurrences(of: "| x |", with: "| 中文\\|单元格 |").utf8))
    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    XCTAssertFalse(document.isDocumentEdited)
    _ = try await web.evaluateJavaScript("document.querySelector('input[data-row=\"0\"][data-column=\"0\"]').focus(); null")
    try await waitUntil { !editor.validateMenuItem(self.menu("tableDeleteRow")) }
    editor.performCommand("toggleSourceMode")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-mvp-table') === null") as? Bool == true }
    XCTAssertFalse(editor.validateMenuItem(menu("tableRowBelow")))
  }

  func testTableStructureNavigationAndInsertionHaveIndependentUndo() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    _ = try await web.evaluateJavaScript("""
      const target = document.querySelector('input[data-row="1"][data-column="0"]');
      target.focus(); target.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', bubbles: true, cancelable: true})); null
      """)
    let navigated = try await web.evaluateJavaScript("document.activeElement.dataset.row === '1' && document.activeElement.dataset.column === '1'") as? Bool
    XCTAssertTrue(try XCTUnwrap(navigated))
    let navigatedSnapshot = try await editor.snapshot()
    XCTAssertEqual(navigatedSnapshot.revision, 0)
    editor.performCommand("tableColumnAfter")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelectorAll('th').length === 3") as? Bool == true }
    let revision = editor.latestRevision
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
    let (newDocument, newEditor, newWeb) = try await makeDocument("正文\r\n尾\n")
    defer { newDocument.close() }
    newEditor.performCommand("insertTable")
    try await waitUntil { try await newWeb.evaluateJavaScript("document.querySelectorAll('th').length === 2 && document.activeElement.dataset.row === '1'") as? Bool == true }
    let insertedRevision = newEditor.latestRevision
    newEditor.undo(nil)
    try await waitUntil { newEditor.latestRevision > insertedRevision }
    try await newDocument.synchronize()
    XCTAssertEqual(try newDocument.data(ofType: "net.daringfireball.markdown"), Data("正文\r\n尾\n".utf8))
  }

  func testTableCompositionBlocksSnapshotsAndCommandsUntilCommit() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    _ = try await web.evaluateJavaScript("""
      const target = document.querySelector('input[data-row="1"][data-column="0"]');
      target.focus(); target.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true}));
      target.value = '组合输入'; target.dispatchEvent(new InputEvent('input', {bubbles: true, isComposing: true})); null
      """)
    try await waitUntil { editor.isComposing }
    do { _ = try await editor.snapshot(); XCTFail("表格候选不能作为确认文本保存") } catch {}
    editor.performCommand("toggleSourceMode")
    editor.performCommand("tableDeleteRow")
    let unchanged = try await editor.evaluateScript("document.querySelectorAll('tr').length === 3 && document.querySelector('[data-table-composing]')?.value === '组合输入'") as? Bool
    XCTAssertTrue(try XCTUnwrap(unchanged))
    _ = try await editor.evaluateScript("document.querySelector('[data-table-composing]').dispatchEvent(new CompositionEvent('compositionend', {bubbles: true})); null")
    try await waitUntil { !editor.isComposing && editor.latestRevision > 0 }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.replacingOccurrences(of: "| x |", with: "| 组合输入 |").utf8))
  }
  func testTableFormatCommandReadsActualCellSelectionBeforeNativeAction() async throws {
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    _ = try await web.evaluateJavaScript("""
      const target = document.querySelector('input[data-row="1"][data-column="0"]');
      target.focus(); target.setSelectionRange(0, 1); null
      """)
    editor.performCommand("bold")
    try await waitUntil { editor.latestRevision > 0 }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.replacingOccurrences(of: "| x |", with: "| **x** |").utf8))
  }
}
