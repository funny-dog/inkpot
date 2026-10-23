import AppKit
import MarkEditCore
import MarkEditKit
import WebKit
import XCTest
@testable import MarkEdit

@MainActor
final class KernmarkTests: XCTestCase {
  func testNewDocumentLineEndingsNormalizeLegacyCR() throws {
    let preferences = ApplicationEnvironment.preferences
    let key = "general.default-line-endings"
    let saved = preferences.object(forKey: key)
    defer {
      if let saved {
        preferences.set(saved, forKey: key)
      } else {
        preferences.removeObject(forKey: key)
      }
    }

    preferences.set(try JSONEncoder().encode(LineEndings.cr), forKey: key)
    XCTAssertEqual(AppPreferences.General.defaultLineEndings, .lf)
    AppPreferences.General.defaultLineEndings = .crlf
    XCTAssertEqual(AppPreferences.General.defaultLineEndings, .crlf)
    AppPreferences.General.defaultLineEndings = .cr
    XCTAssertEqual(AppPreferences.General.defaultLineEndings, .lf)
    XCTAssertEqual(LineEndings.cr.characters, "\r")
  }

  func testTransparencyFollowsSystemInsteadOfRetiredOverride() throws {
    let preferences = ApplicationEnvironment.preferences
    let key = "window.reduce-transparency"
    let saved = preferences.object(forKey: key)
    defer {
      if let saved {
        preferences.set(saved, forKey: key)
      } else {
        preferences.removeObject(forKey: key)
      }
    }

    for value in [false, true] {
      preferences.set(try JSONEncoder().encode(value), forKey: key)
      XCTAssertEqual(AppDesign.reduceTransparency, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
  }

  func testKernmarkPreferencesReachEditorConfig() throws {
    let liveMode = AppPreferences.Editor.liveMode
    let vimMode = AppPreferences.Editor.vimMode
    defer {
      AppPreferences.Editor.liveMode = liveMode
      AppPreferences.Editor.vimMode = vimMode
    }
    AppPreferences.Editor.liveMode = false
    AppPreferences.Editor.vimMode = true
    // EditorConfig 的字段是 internal，通过序列化结果断言与 Web 端实际收到的值一致
    let config = AppPreferences.editorConfig(theme: AppTheme.current.editorTheme)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
    XCTAssertEqual(json?["liveMode"] as? Bool, false)
    XCTAssertEqual(json?["vimMode"] as? Bool, true)
  }

  func testKernmarkFolderTreeIsLazyAndSkipsHiddenFilesAndSymlinkCycles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
    try Data("# 标题".utf8).write(to: root.appendingPathComponent("note.md"))
    try Data().write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
    let showHidden = AppPreferences.General.showHiddenFiles
    defer { AppPreferences.General.showHiddenFiles = showHidden }
    AppPreferences.General.showHiddenFiles = false
    let item = FileTreeItem(url: root, isDirectory: true, isSymlink: false, canonicalPath: root.resolvingSymlinksInPath().path)
    XCTAssertNil(item.children)
    XCTAssertEqual(item.loadChildrenIfNeeded().map(\.displayName), ["folder", "note.md"])
  }

  func testKernmarkOfflineRenderersLoadThroughAssetScheme() async throws {
    let loaded = expectation(description: "离线渲染资源页面加载")
    let configuration = WKWebViewConfiguration.newConfig()
    configuration.setURLSchemeHandler(KernmarkAssetLoader(), forURLScheme: KernmarkAssetLoader.scheme)
    let probe = KernmarkNavigationProbe(loaded: loaded)
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
    webView.navigationDelegate = probe
    webView.loadHTMLString("<html><body></body></html>", baseURL: EditorWebView.baseURL)
    await fulfillment(of: [loaded], timeout: 10)
    let script = """
    const katex = (await import('kernmark-asset://editor/katex.mjs')).default;
    const mermaid = (await import('kernmark-asset://editor/mermaid.mjs')).default;
    mermaid.initialize({startOnLoad: false, securityLevel: 'strict'});
    const diagram = await mermaid.render('offline-test', 'graph TD; A-->B');
    const css = await fetch('kernmark-asset://editor/katex.min.css');
    return {math: katex.renderToString('x^2').includes('katex'), diagram: diagram.svg.includes('<svg'), css: css.ok};
    """
    let result = try await webView.callAsyncJavaScript(
      script, arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Bool]
    XCTAssertEqual(result, ["math": true, "diagram": true, "css": true])
    withExtendedLifetime(probe) {}
  }
}

@MainActor
private final class KernmarkNavigationProbe: NSObject, WKNavigationDelegate {
  private let loaded: XCTestExpectation

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
    loaded.fulfill()
  }

  init(loaded: XCTestExpectation) {
    self.loaded = loaded
  }
}
