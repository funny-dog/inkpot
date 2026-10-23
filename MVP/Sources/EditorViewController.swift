import AppKit
import WebKit

final class EditorViewController: NSViewController, WKNavigationDelegate, NSMenuItemValidation {
  var onChange: (() -> Void)?
  private(set) var isReady = false
  private(set) var latestRevision = 0
  private var canUndo = false
  private var canRedo = false
  private var searchInputFocused = false
  private var editorFocused = false
  private var initialText: String
  private let webView = DocumentWebView()
  private var loadingError: Error?
  private var pageReady = false
  private var resourceURL: URL? { Bundle(for: Self.self).url(forResource: "index", withExtension: "html") }

  init(text: String) {
    initialText = text
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("使用 init(text:) 初始化编辑器")
  }

  override func loadView() {
    view = webView
    webView.navigationDelegate = self
    webView.configuration.userContentController.add(DocumentMessageHandler(owner: self), name: "document")
    guard let url = resourceURL else {
      return fail(NSError(domain: "Kernmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少编辑器资源，请重新构建应用。旧文件未被修改。"]))
    }
    webView.loadFileURL(url, allowingReadAccessTo: url)
  }

  func snapshot() async throws -> (text: String, revision: Int) {
    if let loadingError { throw loadingError }
    guard isReady else {
      throw NSError(domain: "Kernmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "编辑器尚未就绪或已经停止，已阻止保存和关闭。"])
    }
    guard let result = try await webView.evaluateJavaScript("window.kernmarkMVP.snapshot()") as? [String: Any],
          let text = result["text"] as? String, let revision = result["revision"] as? Int, revision >= 0 else {
      throw NSError(domain: "Kernmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "读取最新内容失败，已阻止保存和关闭。"])
    }
    latestRevision = max(latestRevision, revision)
    return (text, revision)
  }

  func replaceText(_ text: String) {
    initialText = text
    guard isViewLoaded && pageReady else { return }
    isReady = false
    loadingError = nil
    latestRevision = 0
    canUndo = false
    canRedo = false
    Task { @MainActor in
      do {
        let argument = try encodedArgument(text)
        _ = try await webView.evaluateJavaScript("window.kernmarkMVP.open(\(argument)); null")
        isReady = true
      } catch {
        fail(error)
      }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
    navigationAction.request.url == resourceURL && !isReady ? .allow : .cancel
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
    fail(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
    fail(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    fail(NSError(domain: "Kernmark", code: 4, userInfo: [NSLocalizedDescriptionKey: "编辑器进程意外停止。已阻止覆盖磁盘文件；尚未保存的输入可能无法恢复。请保留此窗口。"]))
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(undo(_:)) { return isReady && (canUndo || searchInputFocused) }
    if menuItem.action == #selector(redo(_:)) { return isReady && (canRedo || searchInputFocused) }
    if let command = menuItem.representedObject as? String, !["find", "findNext", "findPrevious"].contains(command) {
      return isReady && editorFocused
    }
    return isReady
  }

  @objc func undo(_ sender: Any?) { performCommand("undo") }
  @objc func redo(_ sender: Any?) { performCommand("redo") }
  override func selectAll(_ sender: Any?) { performCommand("selectAll") }

  fileprivate func receive(_ message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame,
          let body = message.body as? [String: Any] else { return }
    if body["ready"] as? Bool == true {
      pageReady = true
      replaceText(initialText)
      return
    }
    guard let changed = body["changed"] as? Bool,
          let undo = body["canUndo"] as? Bool, let redo = body["canRedo"] as? Bool,
          let searchInputFocused = body["searchInputFocused"] as? Bool,
          let editorFocused = body["editorFocused"] as? Bool,
          let revision = body["revision"] as? Int, revision >= latestRevision else { return }
    let didAdvance = revision > latestRevision
    latestRevision = revision
    canUndo = undo
    canRedo = redo
    self.searchInputFocused = searchInputFocused
    self.editorFocused = editorFocused
    if changed && didAdvance { onChange?() }
  }

  func performCommand(_ name: String) {
    guard isReady else { return }
    Task { @MainActor in
      do {
        let argument = try encodedArgument(name)
        _ = try await webView.evaluateJavaScript("window.kernmarkMVP.command(\(argument)); null")
      } catch {
        fail(error)
      }
    }
  }

  private func fail(_ error: Error) {
    pageReady = false
    isReady = false
    loadingError = error
    if view.window != nil { presentError(error) }
  }

  private func encodedArgument(_ value: String) throws -> String {
    guard let result = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    return result
  }
}

private final class DocumentWebView: WKWebView {
  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    // WebKit 的“重新载入”会丢失尚未保存的编辑，基础编辑器只保留安全菜单项。
    for item in menu.items where item.tag == 12 { menu.removeItem(item) }
    super.willOpenMenu(menu, with: event)
  }
}

private final class DocumentMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var owner: EditorViewController?

  init(owner: EditorViewController) {
    self.owner = owner
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.receive(message)
  }
}
