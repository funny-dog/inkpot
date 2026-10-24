import AppKit
import WebKit

final class EditorViewController: NSViewController, WKNavigationDelegate, NSMenuItemValidation {
  var onChange: (() -> Void)?
  var onOutline: (([DocumentHeading]?, Int?) -> Void)?
  var onOutlineReset: (() -> Void)?
  var onStats: ((Int, Int, Int) -> Void)?
  private(set) var headings: [DocumentHeading] = []
  private(set) var latestStats: (words: Int, characters: Int, lines: Int)?
  private(set) var activeHeading: Int?
  private var generation = 0
  private var pendingFragment: String?
  private(set) var isComposing = false
  private(set) var isReady = false
  private(set) var latestRevision = 0
  private var canUndo = false
  private var canRedo = false
  private var searchInputFocused = false
  private var editorFocused = false
  private var sourceMode = false
  private var tableActions: Set<String> = []
  private var tableCellFocused = false
  private var initialText: String
  private let imageHandler = LocalImageHandler()
  private let mathHandler = MathAssetHandler()
  private lazy var webView: DocumentWebView = {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(imageHandler, forURLScheme: "inkpot-image")
    configuration.setURLSchemeHandler(mathHandler, forURLScheme: "inkpot-asset")
    return DocumentWebView(frame: .zero, configuration: configuration)
  }()
  private var loadingError: Error?
  private var pageReady = false
  private var resourceURL: URL? { Bundle(for: Self.self).url(forResource: "index", withExtension: "html") }

  init(text: String) {
    initialText = text
    super.init(nibName: nil, bundle: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(updateFonts), name: EditorFonts.didChange, object: nil)
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
      return fail(NSError(domain: "Inkpot", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少编辑器资源，请重新构建应用。旧文件未被修改。"]))
    }
    webView.loadFileURL(url, allowingReadAccessTo: url)
  }

  /// WebKit 会拒绝与进行中的求值并发的调用（InvalidTransition），编辑器的全部脚本按序排队。
  private var scriptTail: Task<Any?, Error> = Task { nil }

  func evaluateScript(_ javaScript: String, awaitPromise: Bool = false) async throws -> Any? {
    let previous = scriptTail
    let task = Task<Any?, Error> { [weak self] in
      _ = try? await previous.value
      guard let self else { return nil }
      guard let web = self.view as? WKWebView else { return nil }
      if awaitPromise { return try await web.callAsyncJavaScript("return await (\(javaScript));", arguments: [:], in: nil, contentWorld: .page) }
      return try await web.evaluateJavaScript(javaScript)
    }
    scriptTail = task
    return try await task.value
  }

  func snapshot() async throws -> (text: String, revision: Int) {
    if let loadingError { throw loadingError }
    guard isReady else {
      throw NSError(domain: "Inkpot", code: 2, userInfo: [NSLocalizedDescriptionKey: "编辑器尚未就绪或已经停止，已阻止保存和关闭。"])
    }
    let snapshotGeneration = generation
    guard let result = try await evaluateScript("window.inkpotMVP.snapshot()") as? [String: Any],
          let text = result["text"] as? String, let revision = result["revision"] as? Int, revision >= 0, snapshotGeneration == generation else {
      throw NSError(domain: "Inkpot", code: 3, userInfo: [NSLocalizedDescriptionKey: "读取最新内容失败，已阻止保存和关闭。"])
    }
    latestRevision = max(latestRevision, revision)
    return (text, revision)
  }

  func replaceText(_ text: String) {
    initialText = text
    guard isViewLoaded && pageReady else { return }
    isReady = false
    generation += 1
    imageHandler.generation = generation
    headings = []
    activeHeading = nil
    onOutlineReset?()
    loadingError = nil
    latestRevision = 0
    canUndo = false
    canRedo = false
    sourceMode = false
    tableActions = []
    tableCellFocused = false
    pendingFragment = nil
    let documentGeneration = generation
    Task { @MainActor in
      do {
        guard generation == documentGeneration else { return }
        let argument = try encodedArgument(text)
        // 设置中选择默认源码模式时，打开后立即切换；切换不改动文档与撤销历史。
        let mode = AppSettings.shared.defaultSourceMode ? "window.inkpotMVP.command('toggleSourceMode'); " : ""
        _ = try await evaluateScript("window.inkpotMVP.open(\(argument), \(documentGeneration), \(Appearance.isDark)); \(try EditorFonts.shared.script()); \(mode)null")
        guard generation == documentGeneration else { return }
        isReady = true
        if let pendingFragment { self.pendingFragment = nil; navigateFragment(pendingFragment) }
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
    fail(NSError(domain: "Inkpot", code: 4, userInfo: [NSLocalizedDescriptionKey: "编辑器进程意外停止。已阻止覆盖磁盘文件；尚未保存的输入可能无法恢复。请保留此窗口。"]))
  }

  /// 编辑器可能被容器视图控制器包裹，沿 parent 链向上找文档容器。
  var documentContainer: DocumentViewController? {
    var current: NSViewController? = self
    while let controller = current {
      if let container = controller as? DocumentViewController { return container }
      current = controller.parent
    }
    return nil
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.representedObject as? String == "toggleOutline" {
      menuItem.state = documentContainer?.outlineVisible == true ? .on : .off
      return documentContainer != nil
    }
    if menuItem.representedObject as? String == "toggleFiles" {
      menuItem.state = documentContainer?.filesVisible == true ? .on : .off
      return documentContainer != nil
    }
    if menuItem.representedObject as? String == "toggleSourceMode" {
      menuItem.state = sourceMode ? .on : .off
      return isReady
    }
    if menuItem.action == #selector(undo(_:)) { return isReady && (canUndo || searchInputFocused) }
    if menuItem.action == #selector(redo(_:)) { return isReady && (canRedo || searchInputFocused) }
    if let command = menuItem.representedObject as? String {
      if command == "insertTable" || command.hasPrefix("table") { return isReady && tableActions.contains(command) && editorFocused }
      if tableCellFocused && (command.hasPrefix("heading") || ["orderedList", "bulletList", "taskList", "blockquote", "codeBlock", "horizontalRule"].contains(command)) { return false }
    }
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
    if body["pasteImage"] as? Bool == true, body["generation"] as? Int == generation {
      (view.window?.windowController?.document as? MVPDocument)?.images.paste()
      return
    }
    if let destination = body["openLink"] as? String, body["generation"] as? Int == generation {
      openLink(destination)
      return
    }
    if body["outline"] as? Bool == true {
      receiveOutline(body)
      return
    }
    guard body["generation"] as? Int == generation,
          let changed = body["changed"] as? Bool,
          let undo = body["canUndo"] as? Bool, let redo = body["canRedo"] as? Bool,
          let searchInputFocused = body["searchInputFocused"] as? Bool,
          let editorFocused = body["editorFocused"] as? Bool,
          let sourceMode = body["sourceMode"] as? Bool,
          let revision = body["revision"] as? Int, revision >= latestRevision else { return }
    let didAdvance = revision > latestRevision
    latestRevision = revision
    canUndo = undo
    canRedo = redo
    self.searchInputFocused = searchInputFocused
    self.editorFocused = editorFocused
    self.sourceMode = sourceMode
    tableActions = Set(body["tableActions"] as? [String] ?? [])
    tableCellFocused = body["tableCellFocused"] as? Bool ?? false
    isComposing = body["composing"] as? Bool ?? false
    if let stats = body["stats"] as? [String: Any],
       let words = stats["words"] as? Int, let characters = stats["characters"] as? Int, let lines = stats["lines"] as? Int {
      latestStats = (words, characters, lines)
      onStats?(words, characters, lines)
    }
    if changed && didAdvance { onChange?() }
  }

  func performCommand(_ name: String) {
    if ["toggleOutline", "toggleFiles"].contains(name), let container = documentContainer {
      container.toggleContent(files: name == "toggleFiles")
      return
    }
    guard isReady else { return }
    Task { @MainActor in
      do {
        let argument = try encodedArgument(name)
        _ = try await evaluateScript("window.inkpotMVP.command(\(argument)); null")
      } catch {
        fail(error)
      }
    }
  }

  private func receiveOutline(_ body: [String: Any]) {
    guard body["generation"] as? Int == generation,
          let revision = body["revision"] as? Int, revision >= latestRevision else { return }
    var updated: [DocumentHeading]?
    if let raw = body["headings"] as? [[String: Any]] {
      guard let data = try? JSONSerialization.data(withJSONObject: raw),
            let decoded = try? JSONDecoder().decode([DocumentHeading].self, from: data),
            decoded.allSatisfy({ (1...6).contains($0.level) && $0.id >= 0 && $0.from >= 0 && $0.to >= $0.from }),
            Set(decoded.map(\.id)).count == decoded.count else { return }
      headings = decoded
      updated = decoded
    }
    activeHeading = body["active"] as? Int
    onOutline?(updated, activeHeading)
  }

  func navigateHeading(_ id: Int) {
    guard isReady, headings.contains(where: { $0.id == id }) else { return }
    view.window?.makeFirstResponder(webView)
    Task { @MainActor in
      do {
        _ = try await evaluateScript("window.inkpotMVP.navigateHeading(\(id)); null")
      } catch { fail(error) }
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

extension EditorViewController {
  func focusEditor() {
    view.window?.makeFirstResponder(webView)
    performCommand("focus")
  }

  func navigateFragment(_ fragment: String) {
    guard isReady else { pendingFragment = fragment; return }
    view.window?.makeFirstResponder(webView)
    Task { @MainActor in
      do {
        let argument = try encodedArgument(fragment.removingPercentEncoding ?? fragment)
        _ = try await evaluateScript("window.inkpotMVP.navigateFragment(\(argument)); null")
      } catch { presentError(error) }
    }
  }

  private func openLink(_ destination: String) {
    guard isReady else { return }
    if destination.hasPrefix("#") {
      navigateFragment(String(destination.dropFirst()))
      return
    }
    let fileURL = (view.window?.windowController?.document as? MVPDocument)?.fileURL
    guard let url = Self.supportedLink(destination, relativeTo: fileURL) else {
      presentError(NSError(domain: "Inkpot", code: 22, userInfo: [NSLocalizedDescriptionKey: "此链接类型暂不支持。可打开网页、邮件、Markdown 或文本文件链接。 "]))
      return
    }
    if !url.isFileURL {
      NSWorkspace.shared.open(url)
    } else if url.isFileURL, ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
      let fragment = components?.fragment
      components?.fragment = nil
      if let file = components?.url { documentContainer?.openFile(file, fragment: fragment) }
    }
  }

  static func supportedLink(_ destination: String, relativeTo fileURL: URL?) -> URL? {
    let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#")))
    guard let encoded, let url = URL(string: encoded, relativeTo: fileURL)?.absoluteURL else { return nil }
    if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { return url }
    return url.isFileURL && ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) ? url : nil
  }

  func setImageDocumentURL(_ url: URL?) {
    imageHandler.documentURL = url
    if isReady {
      Task { @MainActor in _ = try? await evaluateScript("window.inkpotMVP.refreshImages(); null") }
    }
  }

  func insertImage(_ path: String) async throws {
    guard isReady else { throw CocoaError(.userCancelled) }
    let argument = try encodedArgument(path)
    _ = try await evaluateScript("window.inkpotMVP.insertImage(\(argument)); null")
    focusEditor()
  }
}

private final class DocumentWebView: WKWebView {
  override init(frame frameRect: NSRect, configuration: WKWebViewConfiguration) {
    super.init(frame: frameRect, configuration: configuration)
    registerForDraggedTypes([.fileURL])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("使用 init(frame:configuration:) 初始化编辑器") }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    // WebKit 的“重新载入”会丢失尚未保存的编辑，基础编辑器只保留安全菜单项。
    for item in menu.items where item.tag == 12 { menu.removeItem(item) }
    super.willOpenMenu(menu, with: event)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    DragDrop.accepts(urls(from: sender)) ? .copy : []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = urls(from: sender)
    guard DragDrop.accepts(urls) else { return false }
    DragDrop.perform(urls: urls, in: self)
    return true
  }

  private func urls(from sender: NSDraggingInfo) -> [URL] {
    (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
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
