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

  private func makeDocument(_ text: String) async throws -> (MVPDocument, EditorViewController, WKWebView) {
    _ = NSApplication.shared
    let document = MVPDocument()
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
    _ = try await web.evaluateJavaScript("window.inkpotMVP.setAppearance(\(!dark)); null")
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-editor').className.includes('cm-mvp-dark') === \(String(!dark)) && document.documentElement.classList.contains('inkpot-dark') === \(String(!dark))") as? Bool == true
    }
    _ = try await web.evaluateJavaScript("window.inkpotMVP.setAppearance(\(dark)); null")
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-editor').className.includes('cm-mvp-dark') === \(String(dark))") as? Bool == true
    }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(original.utf8))
  }

  func testOpenCarriesCurrentSystemAppearance() async throws {
    let (document, editor, web) = try await makeDocument("正文")
    defer { document.close() }
    let dark = Appearance.isDark
    // open 已按系统外观初始化，无需任何后续脚本调用。
    let initial = try await web.evaluateJavaScript("document.querySelector('.cm-editor').className.includes('cm-mvp-dark') === \(String(dark))") as? Bool
    XCTAssertTrue(try XCTUnwrap(initial))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data("正文".utf8))
  }
}
