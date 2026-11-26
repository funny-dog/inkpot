import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import WebKit

enum LocalImages {
  static func validated(_ data: Data) throws -> (data: Data, type: UTType) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
          let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String), type.conforms(to: .image) else {
      throw NSError(domain: "Inkpot", code: 30, userInfo: [NSLocalizedDescriptionKey: L10n.text("无法读取此图片。当前支持常见的本地位图，不执行 SVG 或其他文档内容。")])
    }
    return (data, type)
  }

  static func store(_ data: Data, beside documentURL: URL, folderName: String = AppSettings.defaultImageFolder) throws -> (path: String, url: URL) {
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
    let folder = documentURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path) {
      let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = "image-" + UUID().uuidString.lowercased() + "." + (type.preferredFilenameExtension ?? "png")
    let url = folder.appendingPathComponent(name)
    try bytes.write(to: url, options: .withoutOverwriting)
    // Markdown 链接目标中的百分号、空格、括号与查询/锚点字符需要转义，其他字符（含中文）保持原样，读取时会还原。
    let reference = folderName
      .replacingOccurrences(of: "%", with: "%25")
      .replacingOccurrences(of: " ", with: "%20")
      .replacingOccurrences(of: "(", with: "%28")
      .replacingOccurrences(of: ")", with: "%29")
      .replacingOccurrences(of: "#", with: "%23")
      .replacingOccurrences(of: "?", with: "%3F")
    return (reference + "/" + name, url)
  }

  static func read(_ reference: String, relativeTo documentURL: URL?) throws -> (Data, String) {
    // 先编码中文及 #/? 等路径字符，同时保留 Markdown URL 中已有的百分号转义，避免文件名含 # 被裁成 URL fragment。
    let encoded = reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "%:")))
    guard let documentURL, let encoded, let url = URL(string: encoded, relativeTo: documentURL)?.absoluteURL, url.isFileURL, (url.host?.isEmpty ?? true) || url.host == "localhost" else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    // 仅允许读取常规文件并限制体积，避免读取设备文件或巨型位图导致内存溢出。
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw CocoaError(.fileReadNoPermission)
    }
    if let fileSize = values.fileSize, fileSize > RemoteImages.maxBytes {
      throw NSError(domain: "Inkpot", code: 36, userInfo: [NSLocalizedDescriptionKey: L10n.text("图片体积超出限制（最大支持 20MB）。")])
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    if data.count > RemoteImages.maxBytes {
      throw NSError(domain: "Inkpot", code: 36, userInfo: [NSLocalizedDescriptionKey: L10n.text("图片体积超出限制（最大支持 20MB）。")])
    }
    let image = try RemoteImages.validate(data: data)
    return (image.data, image.type.preferredMIMEType ?? "application/octet-stream")
  }
}

/// 负责 HTTPS 远程位图的安全下载与合法性校验。
enum RemoteImages {
  /// 单张图片最大下载体积：20 MiB。
  static let maxBytes = 20 * 1024 * 1024
  /// 避免解码巨图炸弹的最大像素上限：16,777,216（4096 x 4096）。
  static let maxPixelCount = 16_777_216
  /// 单次请求超时时间（秒）。
  static let requestTimeout: TimeInterval = 15
  /// 资源整体超时时间（秒）。
  static let resourceTimeout: TimeInterval = 30

  /// 判断引用是否为 HTTPS 远程图片地址。
  static func isHTTPSReference(_ reference: String) -> Bool {
    guard let url = URL(string: reference), let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "https"
  }

  /// 判断引用是否为网络地址（非本地文件路径）。
  static func isNetworkReference(_ reference: String) -> Bool {
    if reference.hasPrefix("//") { return true }
    guard let url = URL(string: reference), let scheme = url.scheme?.lowercased() else { return false }
    return scheme != "file"
  }

  /// 校验 URL 是否为合法安全的 HTTPS 请求，拒绝非 HTTPS、URL 用户名/密码、空 host 及回环/内网地址。
  static func validate(url: URL) throws {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    guard components.scheme?.lowercased() == "https" else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    guard (components.user?.isEmpty ?? true) && (components.password?.isEmpty ?? true) else {
      throw CocoaError(.fileReadNoPermission)
    }
    guard let host = components.host, !host.isEmpty else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    if isPrivateOrLoopbackHost(host) {
      throw CocoaError(.fileReadNoPermission)
    }
  }

  /// 拦截本机回环、链路本地及私有内网主机名与 IP，避免远程图片功能被用于内网探测。
  static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      .lowercased()
    if normalized.isEmpty || normalized == "localhost" || normalized.hasSuffix(".local") || normalized.hasSuffix(".localhost") {
      return true
    }
    let bare = normalized.hasPrefix("[") && normalized.hasSuffix("]") ? String(normalized.dropFirst().dropLast()) : normalized
    var v4 = in_addr()
    if inet_pton(AF_INET, bare, &v4) == 1 {
      return isPrivateIPv4(UInt32(bigEndian: v4.s_addr))
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, bare, &v6) == 1 {
      let bytes = withUnsafeBytes(of: &v6) { Array($0) }
      // :: 或 ::1
      if bytes.prefix(15).allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) { return true }
      // IPv4 映射地址 ::ffff:a.b.c.d
      if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
        let mapped = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
        return isPrivateIPv4(mapped)
      }
      // 唯一本地地址 fc00::/7、链路本地 fe80::/10、多播 ff00::/8
      if (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) || bytes[0] == 0xFF { return true }
    }
    return false
  }

  private static func isPrivateIPv4(_ address: UInt32) -> Bool {
    let first = (address >> 24) & 0xFF
    let second = (address >> 16) & 0xFF
    return first == 0 || first == 10 || first == 127
      || (first == 169 && second == 254)
      || (first == 172 && (16...31).contains(second))
      || (first == 192 && second == 168)
      || (first == 100 && (64...127).contains(second))
  }

  /// 提取图片元数据并验证像素数量，避免大图内存爆炸。
  static func validatePixelCount(in data: Data, maxPixels: Int = maxPixelCount) throws {
    let options = [kCGImageSourceShouldCache as String: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
      throw NSError(domain: "Inkpot", code: 30, userInfo: [NSLocalizedDescriptionKey: L10n.text("无法解析图片元数据。")])
    }
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    guard width > 0, height > 0, width <= maxPixels / height else {
      throw NSError(domain: "Inkpot", code: 33, userInfo: [NSLocalizedDescriptionKey: L10n.text("图片像素超出允许的最大限制。")])
    }
  }

  /// 验证图片格式：使用 LocalImages.validated 校验基础位图类型，明确拒绝 SVG 与非位图内容。
  @discardableResult
  static func validate(data: Data, maxPixels: Int = maxPixelCount) throws -> (data: Data, type: UTType) {
    let validated = try LocalImages.validated(data)
    guard validated.type != .svg && !validated.type.conforms(to: .svg) else {
      throw NSError(domain: "Inkpot", code: 30, userInfo: [NSLocalizedDescriptionKey: L10n.text("无法读取此图片。当前支持常见的本地位图，不执行 SVG 或其他文档内容。")])
    }
    try validatePixelCount(in: data, maxPixels: maxPixels)
    return validated
  }

  /// 创建禁用 Cookie、凭据存储及持久缓存的临时会话配置。
  static func makeSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    return configuration
  }

  /// 默认共享代理与会话实例，供复用。
  static let sharedDelegate = RemoteImageDelegate()
  static let sharedSession: URLSession = URLSession(configuration: makeSessionConfiguration(), delegate: sharedDelegate, delegateQueue: nil)

  /// 执行网络下载并在接收过程中实施体积与安全拦截。
  static func download(url: URL, session: URLSession = sharedSession, delegate: RemoteImageDelegate = sharedDelegate) async throws -> (Data, String) {
    try validate(url: url)
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: requestTimeout)
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.register(task: task, continuation: continuation)
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  /// 读取并验证 HTTPS 远程位图。
  static func read(_ url: URL, session: URLSession = sharedSession, delegate: RemoteImageDelegate = sharedDelegate, maxPixels: Int = maxPixelCount) async throws -> (Data, String) {
    let (rawData, reportedMime) = try await download(url: url, session: session, delegate: delegate)
    let validated = try validate(data: rawData, maxPixels: maxPixels)
    let mime = validated.type.preferredMIMEType ?? reportedMime
    return (validated.data, mime)
  }

  /// 支持字符串引用的便捷入口。
  static func read(_ reference: String, session: URLSession = sharedSession, delegate: RemoteImageDelegate = sharedDelegate, maxPixels: Int = maxPixelCount) async throws -> (Data, String) {
    guard let url = URL(string: reference) else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    return try await read(url, session: session, delegate: delegate, maxPixels: maxPixels)
  }
}

/// 负责并发网络任务的体积限制、重定向控制及生命周期监听。
final class RemoteImageDelegate: NSObject, URLSessionDataDelegate {
  private final class TaskContext {
    let continuation: CheckedContinuation<(Data, String), Error>
    var data = Data()
    var mimeType: String?
    var exceededLimit = false

    init(continuation: CheckedContinuation<(Data, String), Error>) {
      self.continuation = continuation
    }
  }

  private var tasks: [Int: TaskContext] = [:]
  private let lock = NSLock()

  func register(task: URLSessionTask, continuation: CheckedContinuation<(Data, String), Error>) {
    lock.lock()
    tasks[task.taskIdentifier] = TaskContext(continuation: continuation)
    lock.unlock()
  }

  private func unregister(task: URLSessionTask) -> TaskContext? {
    lock.lock()
    defer { lock.unlock() }
    return tasks.removeValue(forKey: task.taskIdentifier)
  }

  private func context(for task: URLSessionTask) -> TaskContext? {
    lock.lock()
    defer { lock.unlock() }
    return tasks[task.taskIdentifier]
  }

  // 重定向策略：新目标也必须是合法 HTTPS，拒绝带凭据或非 HTTPS 重定向。
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let targetURL = newRequest.url else {
      task.cancel()
      completionHandler(nil)
      return
    }
    do {
      try RemoteImages.validate(url: targetURL)
      completionHandler(newRequest)
    } catch {
      task.cancel()
      completionHandler(nil)
    }
  }

  // 响应头接收：检查 HTTP 状态码及已知内容长度是否超限。
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
      completionHandler(.cancel)
      return
    }
    if response.expectedContentLength > RemoteImages.maxBytes {
      if let context = context(for: dataTask) {
        context.exceededLimit = true
      }
      completionHandler(.cancel)
      return
    }
    if let context = context(for: dataTask) {
      context.mimeType = response.mimeType
    }
    completionHandler(.allow)
  }

  // 数据接收流：在接收过程中累计体积，超过 20MiB 立即取消任务。
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let context = context(for: dataTask) else { return }
    if context.data.count + data.count > RemoteImages.maxBytes {
      context.exceededLimit = true
      dataTask.cancel()
      return
    }
    context.data.append(data)
  }

  // 任务完成与错误回调。
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let context = unregister(task: task) else { return }
    if context.exceededLimit {
      context.continuation.resume(throwing: NSError(domain: "Inkpot", code: 36, userInfo: [NSLocalizedDescriptionKey: L10n.text("图片体积超出限制（最大支持 20MB）。")]))
      return
    }
    if let error {
      context.continuation.resume(throwing: error)
      return
    }
    context.continuation.resume(returning: (context.data, context.mimeType ?? "application/octet-stream"))
  }
}

final class LocalImageHandler: NSObject, WKURLSchemeHandler {
  var documentURL: URL?
  var generation = 0 {
    didSet { if generation != oldValue { for entry in tasks.values { entry.task.cancel() } } }
  }
  /// 是否允许加载远程 HTTPS 图片，默认关闭。
  var allowRemoteImages = false {
    didSet {
      // 关闭远程图片时仅取消远程下载任务，避免误杀正在读取的本地图片。
      if !allowRemoteImages {
        for entry in tasks.values where entry.isRemote { entry.task.cancel() }
      }
    }
  }
  private var tasks: [ObjectIdentifier: (task: Task<Void, Never>, isRemote: Bool)] = [:]

  deinit {
    for entry in tasks.values { entry.task.cancel() }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme == "inkpot-image", components.host == "local",
          components.queryItems?.first(where: { $0.name == "document" })?.value == String(generation),
          let reference = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding else {
      urlSchemeTask.didFailWithError(CocoaError(.userCancelled))
      return
    }
    let id = ObjectIdentifier(urlSchemeTask)
    let documentURL = documentURL
    let generation = generation
    let allowRemote = allowRemoteImages
    let isRemote = RemoteImages.isHTTPSReference(reference)

    let task = Task { @MainActor [weak self] in
      let result: Result<(Data, String), Error>
      if isRemote {
        if !allowRemote {
          result = .failure(NSError(domain: "Inkpot", code: 35, userInfo: [NSLocalizedDescriptionKey: L10n.text("已禁用远程图片加载。可在设置中开启。")]))
        } else {
          do {
            let loaded = try await RemoteImages.read(reference)
            result = .success(loaded)
          } catch {
            result = .failure(error)
          }
        }
      } else if RemoteImages.isNetworkReference(reference) {
        // 网络地址但非合法 HTTPS，坚决拒绝，绝不当作本地文件路径。
        result = .failure(CocoaError(.fileReadUnsupportedScheme))
      } else {
        result = await Task.detached {
          Result { try LocalImages.read(reference, relativeTo: documentURL) }
        }.value
      }

      guard let self, self.tasks.removeValue(forKey: id) != nil else { return }
      guard self.generation == generation, !Task.isCancelled, !isRemote || self.allowRemoteImages else {
        urlSchemeTask.didFailWithError(CocoaError(.userCancelled))
        return
      }
      switch result {
      case let .success((data, mime)):
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"]) else {
          urlSchemeTask.didFailWithError(CocoaError(.fileReadCorruptFile))
          return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
      case let .failure(error):
        urlSchemeTask.didFailWithError(error)
      }
    }
    tasks[id] = (task, isRemote)
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    let id = ObjectIdentifier(urlSchemeTask)
    tasks.removeValue(forKey: id)?.task.cancel()
  }
}

@MainActor
final class DocumentImages {
  private weak var document: InkpotDocument?

  init(document: InkpotDocument) { self.document = document }

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
      document?.presentError(NSError(domain: "Inkpot", code: 31, userInfo: [NSLocalizedDescriptionKey: L10n.text("请先保存 Markdown 文档，再插入或粘贴图片。图片将按设置保存到文档同级的素材文件夹。 ")]))
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
        let image = try await Task.detached { [folder = AppSettings.shared.imageFolder(beside: base)] in try LocalImages.store(data, beside: base, folderName: folder) }.value
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
