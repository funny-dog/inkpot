import AppKit
import WebKit
import XCTest

@MainActor
final class StatisticsTests: XCTestCase {
  func testStatusBarZoomChangesPageAndFollowsOtherControls() throws {
    _ = NSApplication.shared
    let previous = EditorZoom.shared.level
    defer { EditorZoom.shared.level = previous }
    EditorZoom.shared.level = 1
    let editor = EditorViewController(text: "原文")
    let container = EditorContainerViewController(editor: editor)
    _ = container.view
    let other = EditorZoomControl()
    XCTAssertEqual(container.zoomControl.titleOfSelectedItem, "100%")
    XCTAssertEqual(container.zoomControl.itemTitles, EditorZoom.levels.map { "\(Int(($0 * 100).rounded()))%" })
    container.zoomControl.selectItem(withTitle: "125%")
    let action = try XCTUnwrap(container.zoomControl.action)
    XCTAssertTrue(NSApp.sendAction(action, to: container.zoomControl.target, from: container.zoomControl))
    XCTAssertEqual(EditorZoom.shared.level, 1.25)
    XCTAssertEqual((editor.view as? WKWebView)?.pageZoom, 1.25)
    XCTAssertEqual(other.titleOfSelectedItem, "125%")
    EditorZoom.shared.zoomOut(nil)
    XCTAssertEqual(container.zoomControl.titleOfSelectedItem, "110%")
    XCTAssertEqual(other.titleOfSelectedItem, "110%")
    EditorZoom.shared.resetZoom(nil)
    XCTAssertEqual(container.zoomControl.titleOfSelectedItem, "100%")
  }

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
      let page = (try? await web.evaluateQueued(
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
    XCTAssertEqual(container.statusText, L10n.text("%@ 字 · %@ 字符 · %@ 行", "6", "11", "4"))
    // 状态栏左侧跟随编辑器切换显示当前模式。
    XCTAssertEqual(container.modeText, L10n.text("实时模式"))
    editor.performCommand("toggleSourceMode")
    try await waitUntil { editor.isSourceMode }
    XCTAssertEqual(container.modeText, L10n.text("源码模式"))
    editor.performCommand("toggleSourceMode")
    try await waitUntil { !editor.isSourceMode }
    XCTAssertEqual(container.modeText, L10n.text("实时模式"))
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(text.utf8))
  }

  func testDocumentToolbarOffersFocusAndSourceModes() throws {
    let controller = DocumentViewController(editor: InkpotDocument().makeEditor())
    let toolbar = controller.makeToolbar()
    let defaults = controller.toolbarDefaultItemIdentifiers(toolbar)
    XCTAssertEqual(defaults.first, .toggleSidebar)
    XCTAssertTrue(defaults.contains(.sidebarTrackingSeparator))
    let source = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .inkpotSourceMode, willBeInsertedIntoToolbar: true))
    XCTAssertEqual(source.action, #selector(DocumentViewController.toggleSourceMode(_:)))
    let focus = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .inkpotFocusMode, willBeInsertedIntoToolbar: true))
    XCTAssertIdentical(focus.target, DisplayModes.shared)
    XCTAssertEqual(focus.action, #selector(DisplayModes.toggleFocusMode(_:)))
  }
}
