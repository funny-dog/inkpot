import AppKit
import WebKit
import XCTest

@MainActor
final class AppearanceTests: XCTestCase {
  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeDocument(_ text: String) async throws -> (InkpotDocument, EditorViewController, WKWebView) {
    _ = NSApplication.shared
    let document = InkpotDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    return (document, editor, web)
  }

  func testSetAppearanceTogglesEditorDarkClassWithoutChangingBytes() async throws {
    let original = "\u{FEFF}标题\r\n\r\n正文"
    let (document, editor, web) = try await makeDocument(original)
    defer { document.close() }
    let dark = Appearance.isDark
    _ = try await web.evaluateJavaScript("window.inkpot.setAppearance(\(!dark)); null")
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-editor').className.includes('cm-inkpot-dark') === \(String(!dark)) && document.documentElement.classList.contains('inkpot-dark') === \(String(!dark))") as? Bool == true
    }
    _ = try await web.evaluateJavaScript("window.inkpot.setAppearance(\(dark)); null")
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-editor').className.includes('cm-inkpot-dark') === \(String(dark))") as? Bool == true
    }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  func testOpenCarriesCurrentSystemAppearance() async throws {
    let (document, editor, web) = try await makeDocument("正文")
    defer { document.close() }
    let dark = Appearance.isDark
    // open 已按系统外观初始化，无需任何后续脚本调用。
    let initial = try await web.evaluateJavaScript("document.querySelector('.cm-editor').className.includes('cm-inkpot-dark') === \(String(dark))") as? Bool
    XCTAssertTrue(try XCTUnwrap(initial))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data("正文".utf8))
  }
}

extension AppearanceTests {
  func testFontPreferencesPersistAndRejectInvalidSizes() throws {
    _ = NSApplication.shared
    let suite = "InkpotFontsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fonts = EditorFonts(defaults: defaults)
    XCTAssertEqual(fonts.font(code: false).pointSize, 15)
    fonts.setFont(try XCTUnwrap(NSFont(name: "Helvetica", size: 20)), code: false)
    fonts.setFont(try XCTUnwrap(NSFont(name: "Menlo", size: 17)), code: true)
    let reopened = EditorFonts(defaults: defaults)
    XCTAssertEqual(reopened.font(code: false).familyName, "Helvetica")
    XCTAssertEqual(reopened.font(code: false).pointSize, 20)
    XCTAssertEqual(reopened.font(code: true).pointSize, 17)
    defaults.set(1000, forKey: "editor.bodyFontSize")
    defaults.set("missing-font", forKey: "editor.bodyFontName")
    XCTAssertEqual(reopened.font(code: false).pointSize, 15)
    fonts.resetFonts(nil)
    XCTAssertEqual(fonts.font(code: true).pointSize, 15)
  }

  func testFontChangesReachAllEditorsAndNewDocumentsWithoutChangingBytes() async throws {
    let keys = ["editor.bodyFontName", "editor.bodyFontSize", "editor.codeFontName", "editor.codeFontSize"]
    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
      }
      NotificationCenter.default.post(name: EditorFonts.didChange, object: nil)
    }
    let original = "\u{FEFF}正文\r\n\r\n```js\ncode\n```"
    let (first, editor, _) = try await makeDocument(original)
    let (second, other, _) = try await makeDocument(original)
    defer { first.close(); second.close() }
    for controller in [editor, other] { controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600) }
    try await Task.sleep(for: .milliseconds(600))
    EditorFonts.shared.setFont(try XCTUnwrap(NSFont(name: "Helvetica", size: 20)), code: false)
    EditorFonts.shared.setFont(try XCTUnwrap(NSFont(name: "Menlo", size: 17)), code: true)
    for controller in [editor, other] {
      try await waitUntil {
        try await controller.evaluateScript("getComputedStyle(document.querySelector('.cm-scroller')).fontSize === '20px' && getComputedStyle(document.querySelector('.cm-inkpot-code:not(.cm-inkpot-code-header):not(.cm-inkpot-code-footer)')).fontSize === '17px'") as? Bool == true
      }
    }
    let (third, newest, _) = try await makeDocument(original)
    defer { third.close() }
    try await Task.sleep(for: .milliseconds(600))
    let size = try await newest.evaluateScript("getComputedStyle(document.querySelector('.cm-scroller')).fontSize") as? String
    XCTAssertEqual(size, "20px")
    for document in [first, second, third] {
      try await document.synchronize()
      XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
      XCTAssertFalse(document.isDocumentEdited)
    }
  }
}
