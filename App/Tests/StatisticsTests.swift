import AppKit
import WebKit
import XCTest

@MainActor
final class StatisticsTests: XCTestCase {
  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testStatsFlowThroughNativeCallback() async throws {
    let text = "你好 world\r\n\r\n第二行\n"
    _ = NSApplication.shared
    let document = InkpotDocument()
    try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    defer { document.close() }
    guard let web = editor.view as? WKWebView else { return XCTFail("缺少 WebView") }
    do {
      try await waitUntil { editor.isReady && editor.latestStats != nil }
    } catch {
      let page = (try? await web.evaluateJavaScript(
        "JSON.stringify({ready: document.readyState, api: typeof window.inkpot, dark: matchMedia('(prefers-color-scheme: dark)').matches})"
      )) as? String ?? "求值失败"
      XCTFail("就绪=\(editor.isReady) 页面=\(page)")
      return
    }
    let stats = try XCTUnwrap(editor.latestStats)
    XCTAssertEqual(stats.words, 6)
    XCTAssertEqual(stats.characters, 11)
    XCTAssertEqual(stats.lines, 4)
    // 状态条容器加载后直接显示最新统计。
    let container = EditorContainerViewController(editor: editor)
    container.loadView()
    XCTAssertEqual(container.statusText, "6 字 · 11 字符 · 4 行")
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(text.utf8))
  }
}
