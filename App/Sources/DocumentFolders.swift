import AppKit

/// 退出时 AppKit 会先逐个询问未保存的文档，用户选择后这些文档会立即关闭，
/// 之后才调用 applicationShouldTerminate。会话必须在询问之前记录，否则这些标签会从恢复列表中消失。
final class InkpotDocumentController: NSDocumentController {
  @MainActor static var quitSnapshot: SessionState?

  override func reviewUnsavedDocuments(
    withAlertTitle title: String?, cancellable: Bool, delegate: Any?, didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?
  ) {
    MainActor.assumeIsolated { Self.quitSnapshot = DocumentSession.capture() }
    guard let target = delegate as AnyObject?, let selector = didReviewAllSelector else {
      super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate, didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
      return
    }
    // 拦截退出前未保存检查的结果：用户取消退出时立即清空 quitSnapshot，避免污染下次正常退出的会话记录。
    let proxy = UnsavedReviewProxy(target: target, selector: selector) { didReviewAll in
      if !didReviewAll {
        MainActor.assumeIsolated { Self.quitSnapshot = nil }
      }
    }
    super.reviewUnsavedDocuments(
      withAlertTitle: title,
      cancellable: cancellable,
      delegate: proxy,
      didReviewAllSelector: #selector(UnsavedReviewProxy.documentController(_:didReviewAll:contextInfo:)),
      contextInfo: contextInfo
    )
  }
}

private final class UnsavedReviewProxy: NSObject {
  private let target: AnyObject
  private let selector: Selector
  private let onFinish: (Bool) -> Void
  private var retainSelf: UnsavedReviewProxy?

  init(target: AnyObject, selector: Selector, onFinish: @escaping (Bool) -> Void) {
    self.target = target
    self.selector = selector
    self.onFinish = onFinish
    super.init()
    retainSelf = self
  }

  @objc func documentController(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
    defer { retainSelf = nil }
    onFinish(didReviewAll)
    typealias ReviewCallback = @convention(c) (AnyObject, Selector, NSDocumentController, ObjCBool, UnsafeMutableRawPointer?) -> Void
    if let implementation = target.method(for: selector) {
      let callback = unsafeBitCast(implementation, to: ReviewCallback.self)
      callback(target, selector, controller, ObjCBool(didReviewAll), contextInfo)
    }
  }
}

/// 记住每个文件上次所在的文件树文件夹：从“打开最近使用”、访达等途径打开的文件，
/// 在新窗口或新标签中显示时回到原来的文件树；没有记录时沿用同一标签组已打开的文件夹。
@MainActor
enum DocumentFolders {
  static let limit = 200
  private static let key = "documentFolders"

  /// 只记录位于该文件夹之内的文件，避免把无关文件和文件夹配对。
  static func remember(file: URL, folder: URL, defaults: UserDefaults = .standard) {
    guard FileTreeActions.relocated(file, from: folder, to: folder) != nil else { return }
    let path = file.standardizedFileURL.path
    let pairs = [[path, folder.standardizedFileURL.path]] + stored(defaults).filter { $0.first != path }
    defaults.set(Array(pairs.prefix(limit)), forKey: key)
  }

  static func folder(for file: URL, defaults: UserDefaults = .standard) -> URL? {
    let path = file.standardizedFileURL.path
    guard let folder = stored(defaults).first(where: { $0.first == path })?.last else { return nil }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue else { return nil }
    return URL(fileURLWithPath: folder, isDirectory: true)
  }

  private static func stored(_ defaults: UserDefaults) -> [[String]] {
    (defaults.array(forKey: key) as? [[String]])?.filter { $0.count == 2 } ?? []
  }

  /// 记录窗口当前文件与文件夹的对应关系；在文档关闭和会话记录时调用。
  static func remember(_ document: InkpotDocument) {
    for controller in document.windowControllers {
      if let file = document.fileURL, let folder = (controller.window?.contentViewController as? DocumentViewController)?.files.root?.entry.url {
        remember(file: file, folder: folder)
      }
    }
  }

  /// 文档窗口显示后，如果还没有文件树，优先回到该文件上次的文件夹，其次沿用同组标签的文件夹。
  static func adopt(_ document: InkpotDocument) {
    guard let window = document.windowControllers.first?.window,
          let controller = window.contentViewController as? DocumentViewController, controller.files.root == nil else { return }
    let sibling = window.tabbedWindows?.lazy
      .compactMap { $0.contentViewController as? DocumentViewController }
      .first { $0 !== controller && $0.files.root != nil }
    if let file = document.fileURL, let folder = folder(for: file) {
      controller.files.openFolder(folder)
      if !controller.filesVisible { controller.toggleContent(files: true) }
    } else if let sibling, let folder = sibling.files.root?.entry.url {
      controller.files.openFolder(folder)
      if document.fileURL != nil, sibling.filesVisible, !controller.filesVisible { controller.toggleContent(files: true) }
    }
  }
}
