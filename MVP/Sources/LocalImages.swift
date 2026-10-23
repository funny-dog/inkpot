import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

enum LocalImages {
  static func validated(_ data: Data) throws -> (data: Data, type: UTType) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
          let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String), type.conforms(to: .image) else {
      throw NSError(domain: "Kernmark", code: 30, userInfo: [NSLocalizedDescriptionKey: "无法读取此图片。当前支持常见的本地位图，不执行 SVG 或其他文档内容。"])
    }
    return (data, type)
  }

  static func store(_ data: Data, beside documentURL: URL) throws -> (path: String, url: URL) {
    let image = try validated(data)
    var bytes = image.data
    var type = image.type
    if ![UTType.png, .jpeg, .gif, .webP].contains(type) {
      guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      bytes = png
      type = .png
    }
    let folder = documentURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path) {
      let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = "image-" + UUID().uuidString.lowercased() + "." + (type.preferredFilenameExtension ?? "png")
    let url = folder.appendingPathComponent(name)
    try bytes.write(to: url, options: .withoutOverwriting)
    return ("assets/" + name, url)
  }

  static func read(_ reference: String, relativeTo documentURL: URL?) throws -> (Data, String) {
    // 先编码中文等字符，同时保留 Markdown URL 中已有的百分号转义。
    let encoded = reference.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#")))
    guard let documentURL, let encoded, let url = URL(string: encoded, relativeTo: documentURL)?.absoluteURL, url.isFileURL, (url.host?.isEmpty ?? true) || url.host == "localhost" else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let image = try validated(data)
    return (image.data, image.type.preferredMIMEType ?? "application/octet-stream")
  }
}

final class LocalImageHandler: NSObject, WKURLSchemeHandler {
  var documentURL: URL?
  var generation = 0
  private var tasks: Set<ObjectIdentifier> = []

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.queryItems?.first(where: { $0.name == "document" })?.value == String(generation),
          let reference = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding else {
      urlSchemeTask.didFailWithError(CocoaError(.userCancelled))
      return
    }
    let id = ObjectIdentifier(urlSchemeTask)
    tasks.insert(id)
    let documentURL = documentURL
    let generation = generation
    Task { @MainActor in
      let result = await Task.detached { Result { try LocalImages.read(reference, relativeTo: documentURL) } }.value
      guard tasks.remove(id) != nil else { return }
      guard self.generation == generation else { urlSchemeTask.didFailWithError(CocoaError(.userCancelled)); return }
      switch result {
      case let .success((data, mime)):
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
      case let .failure(error): urlSchemeTask.didFailWithError(error)
      }
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { tasks.remove(ObjectIdentifier(urlSchemeTask)) }
}

@MainActor
final class DocumentImages {
  private weak var document: MVPDocument?

  init(document: MVPDocument) { self.document = document }

  func choose() {
    guard let window = document?.editor?.view.window, canInsert else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .tiff, .heic]
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] result in
      if result == .OK, let url = panel.url { self?.insert(url: url) }
    }
  }

  private var canInsert: Bool {
    guard document?.fileURL != nil else {
      document?.presentError(NSError(domain: "Kernmark", code: 31, userInfo: [NSLocalizedDescriptionKey: "请先保存 Markdown 文档，再插入或粘贴图片。图片将保存在文档同级的 assets 文件夹。 "]))
      return false
    }
    return document?.editor?.isReady == true
  }

  func paste() {
    guard canInsert else { return }
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      insert(data: data)
    } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
      insert(url: url)
    }
  }

  private func insert(url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do { insert(data: try Data(contentsOf: url)) } catch { document?.presentError(error) }
  }

  private func insert(data: Data) {
    guard let document, let base = document.fileURL, let editor = document.editor else { return }
    Task { @MainActor in
      var asset: URL?
      do {
        let image = try await Task.detached { try LocalImages.store(data, beside: base) }.value
        asset = image.url
        guard document.fileURL == base, document.editor === editor, !document.windowControllers.isEmpty else { throw CocoaError(.userCancelled) }
        try await editor.insertImage(image.path)
        asset = nil
      } catch {
        if let asset { try? FileManager.default.removeItem(at: asset) }
        if (error as NSError).code != NSUserCancelledError { document.presentError(error) }
      }
    }
  }
}
