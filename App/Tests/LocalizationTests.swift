import AppKit
import WebKit
import XCTest

@MainActor
final class LocalizationTests: XCTestCase {
  private func strings(_ language: String) throws -> [String: String] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
    return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
  }

  func testBothLanguagesHaveMatchingKeysAndFormatArguments() throws {
    let chinese = try strings("zh-Hans")
    let english = try strings("en")
    XCTAssertFalse(english.isEmpty)
    XCTAssertEqual(Set(chinese.keys), Set(english.keys))
    let pattern = try NSRegularExpression(pattern: #"%(?:[1-9][0-9]*\$)?[-+#0 .0-9]*(?:ll|l|z)?[@difu]"#)
    func arguments(_ text: String) -> [String] {
      pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
    }
    for (key, value) in chinese {
      let translation = try XCTUnwrap(english[key])
      XCTAssertFalse(translation.isEmpty, key)
      XCTAssertEqual(arguments(value), arguments(translation), key)
    }
    XCTAssertEqual(english["设置…"], "Settings…")
    XCTAssertEqual(chinese["设置…"], "设置…")
  }

  func testNativeMenuUsesApplicationLanguage() {
    _ = NSApplication.shared
    let menu = MainMenu.make(delegate: AppDelegate())
    XCTAssertEqual(L10n.text("设置…"), L10n.language == "en" ? "Settings…" : "设置…")
    XCTAssertEqual(menu.items.first?.submenu?.items.contains { $0.title == L10n.text("设置…") }, true)
    XCTAssertTrue(menu.items.contains { $0.submenu?.title == L10n.text("文件") })
  }

  func testWebEditorUsesSameLanguageAndPreservesDocument() async throws {
    _ = NSApplication.shared
    let editor = EditorViewController(text: "")
    let web = try XCTUnwrap(editor.view as? WKWebView)
    let deadline = Date.now.addingTimeInterval(10)
    while !editor.isReady {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
    let language = try await web.evaluateJavaScript("document.documentElement.lang") as? String
    XCTAssertEqual(language, L10n.language)
    let placeholder = try await web.evaluateJavaScript("document.querySelector('.cm-placeholder')?.textContent") as? String
    XCTAssertEqual(placeholder, L10n.language == "en" ? "Start writing…" : "开始写作…")
    _ = try await editor.evaluateScript("window.inkpot.command('find'); null")
    let done = try await editor.evaluateScript("document.querySelector('button[name=close]')?.textContent") as? String
    XCTAssertEqual(done, L10n.language == "en" ? "Done" : "完成")
    editor.replaceText("# 中文标题\r\n\r\nEnglish 与中文\n")
    while !editor.isReady {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
    let snapshot = try await editor.snapshot()
    XCTAssertEqual(snapshot.text, "# 中文标题\r\n\r\nEnglish 与中文\n")
  }
}
