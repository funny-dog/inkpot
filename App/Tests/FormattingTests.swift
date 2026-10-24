import AppKit
import WebKit
import XCTest

@MainActor
final class FormattingTests: XCTestCase {
  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testFormatMenusIncludeNewCommandsWithMatchingShortcuts() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let format = MainMenu.make(delegate: delegate).items[3].submenu
    let commands: [(String, String, String)] = [
      ("删除线", "strikethrough", "X"), ("行内代码", "inlineCode", "e"), ("链接", "link", "k"),
      ("引用", "blockquote", "."), ("任务列表", "taskList", "9"),
      ("代码块", "codeBlock", "C"), ("分隔线", "horizontalRule", "H"),
    ]
    for (title, command, key) in commands {
      let entry = try XCTUnwrap(format?.items.first { $0.title == title })
      XCTAssertEqual(entry.representedObject as? String, command)
      XCTAssertEqual(entry.action, #selector(AppDelegate.editorCommand(_:)))
      XCTAssertIdentical(entry.target, delegate)
      XCTAssertEqual(entry.keyEquivalent, key.lowercased())
      let shifted = key != key.lowercased() || ["taskList", "blockquote"].contains(command)
      XCTAssertEqual(entry.keyEquivalentModifierMask, NSEvent.ModifierFlags(shifted ? [.command, .shift] : [.command]))
    }
  }

  func testNewFormatCommandsThroughNativeBridgeAndUndoPreserveOriginalBytes() async throws {
    _ = NSApplication.shared
    let original = "\u{FEFF}中文\r\n尾\n"
    for (command, expected) in [
      ("strikethrough", "~~中文~~\r\n尾\n"), ("inlineCode", "`中文`\r\n尾\n"),
      ("link", "[中文](url)\r\n尾\n"), ("blockquote", "> 中文\r\n尾\n"),
      ("taskList", "- [ ] 中文\r\n尾\n"), ("codeBlock", "```\r\n中文\r\n```\r\n尾\n"),
      ("horizontalRule", "中文\r\n\r\n---\r\n\r\n\r\n尾\n"),
    ] {
      let document = InkpotDocument()
      defer { document.close() }
      try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
      let editor = document.makeEditor()
      _ = editor.view
      try await waitUntil { editor.isReady }
      editor.performCommand("find")
      try await waitUntil { try await editor.evaluateScript("document.activeElement?.name === 'search'") as? Bool == true }
      _ = try await editor.evaluateScript("""
        const find = document.querySelector('input[name=search]');
        find.value = '中文'; find.dispatchEvent(new InputEvent('input', {bubbles: true}));
        document.querySelector('button[name=next]').click();
        document.querySelector('button[name=close]').click(); null
        """)
      editor.performCommand(command)
      try await waitUntil { editor.latestRevision > 0 }
      let snapshot = try await editor.snapshot()
      XCTAssertEqual(snapshot.text, expected, command)
      editor.undo(nil)
      try await waitUntil { editor.latestRevision > snapshot.revision }
      try await document.synchronize()
      XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8), command)
    }
  }

  func testNativeAutomaticPairsAndFenceCreation() async throws {
    _ = NSApplication.shared
    for (opening, closing) in [("(", ")"), ("[", "]"), ("\"", "\""), ("`", "`"), ("*", "*")] {
      let document = InkpotDocument()
      defer { document.close() }
      let editor = document.makeEditor()
      _ = editor.view
      try await waitUntil { editor.isReady }
      try await Task.sleep(for: .milliseconds(600))
      let argument = try XCTUnwrap(String(data: JSONEncoder().encode(opening), encoding: .utf8))
      _ = try await editor.evaluateScript("document.execCommand('insertText', false, \(argument)); null")
      try await waitUntil { editor.latestRevision > 0 }
      let paired = try await editor.snapshot()
      XCTAssertEqual(paired.text, opening + closing)
      if opening == "`" {
        for _ in 0..<2 {
          let revision = editor.latestRevision
          _ = try await editor.evaluateScript("document.execCommand('insertText', false, '`'); null")
          try await waitUntil { editor.latestRevision > revision }
        }
        _ = try await editor.evaluateScript("""
          document.execCommand('insertText', false, 'js');
          document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {
            key: 'Enter', keyCode: 13, bubbles: true, cancelable: true
          })); null
          """)
        let code = try await editor.snapshot()
        XCTAssertEqual(code.text, "```js\n\n```")
      }
    }
  }

  func testNativeSearchOptionsAndPairInputKeepDocumentAndHistory() async throws {
    _ = NSApplication.shared
    let document = InkpotDocument()
    defer { document.close() }
    let original = "\u{FEFF}Cat cat cats\r\n尾\n"
    try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    _ = editor.view
    try await waitUntil { editor.isReady }
    editor.performCommand("find")
    try await waitUntil { try await editor.evaluateScript("document.activeElement?.name === 'search'") as? Bool == true }
    _ = try await editor.evaluateScript("""
      const find = document.querySelector('input[name=search]');
      find.value = 'cat'; find.dispatchEvent(new InputEvent('input', {bubbles: true}));
      document.querySelector('input[name=caseSensitive]').click();
      document.querySelector('input[name=wholeWord]').click();
      document.querySelector('button[name=next]').click();
      document.querySelector('button[name=close]').click(); null
      """)
    // 无窗口 WebView 的焦点迁移需要落定后才能注入真实文本输入。
    try await Task.sleep(for: .milliseconds(600))
    _ = try await editor.evaluateScript("document.execCommand('insertText', false, '('); null")
    try await waitUntil { editor.latestRevision > 0 }
    let paired = try await editor.snapshot()
    XCTAssertEqual(paired.text, "Cat (cat) cats\r\n尾\n")
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > paired.revision }
    editor.performCommand("find")
    try await waitUntil { try await editor.evaluateScript("document.activeElement?.name === 'search'") as? Bool == true }
    _ = try await editor.evaluateScript("""
      const regexFind = document.querySelector('input[name=search]');
      regexFind.value = '(cat)'; regexFind.dispatchEvent(new InputEvent('input', {bubbles: true}));
      document.querySelector('input[name=regexp]').click();
      const replace = document.querySelector('input[name=replace]');
      replace.value = '[$1]'; replace.dispatchEvent(new InputEvent('input', {bubbles: true}));
      document.querySelector('button[name=replaceAll]').click(); null
      """)
    let replaced = try await editor.snapshot()
    XCTAssertEqual(replaced.text, "Cat [cat] cats\r\n尾\n")
    _ = try await editor.evaluateScript("document.querySelector('button[name=close]').click(); null")
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > replaced.revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }
}
