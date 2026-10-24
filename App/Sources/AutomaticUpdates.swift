import AppKit
import CryptoKit
import Combine

/// 自动下载只写入应用缓存；不挂载安装包、不替换应用，也不关闭文档。
enum UpdateDownload {
  static let maximumSize = 200 * 1024 * 1024

  static func assets(for release: UpdateRelease) throws -> (image: UpdateRelease.Asset, checksum: UpdateRelease.Asset) {
    _ = try UpdateRelease.version(release.tagName)
    guard let image = release.assets?.first(where: { $0.name == "Inkpot.dmg" }),
          let checksum = release.assets?.first(where: { $0.name == "Inkpot.dmg.sha256" }),
          (1...maximumSize).contains(image.size), (1...4096).contains(checksum.size) else { throw UpdateDownloadError.invalidAssets }
    for asset in [image, checksum] {
      let url = asset.browserDownloadURL
      guard url.scheme == "https", url.host == "github.com", url.port == nil, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil,
            url.path == "/funny-dog/inkpot/releases/download/\(release.tagName)/\(asset.name)" else { throw UpdateDownloadError.invalidAssets }
    }
    return (image, checksum)
  }

  static func checksum(_ data: Data) throws -> String {
    guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw UpdateDownloadError.checksum }
    let parts = text.split { $0.isWhitespace }
    guard parts.count == 2, parts[1] == "Inkpot.dmg", parts[0].count == 64,
          parts[0].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw UpdateDownloadError.checksum }
    return parts[0].lowercased()
  }

  static func verify(_ url: URL, digest: String, size: Int) throws -> Bool {
    guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == size else { return false }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
      try Task.checkCancellation()
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
  }

  static func fetch(_ release: UpdateRelease, session: URLSession, directory: URL) async throws -> URL {
    let assets = try assets(for: release)
    var checksumRequest = URLRequest(url: assets.checksum.browserDownloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    checksumRequest.setValue("Inkpot", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: checksumRequest)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let digest = try checksum(data)
    let destination = directory.appendingPathComponent("Inkpot.dmg")
    if FileManager.default.fileExists(atPath: destination.path), (try? verify(destination, digest: digest, size: assets.image.size)) == true {
      try Task.checkCancellation()
      return destination
    }
    let request = URLRequest(url: assets.image.browserDownloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
    let (temporary, imageResponse) = try await session.download(for: request, delegate: UpdateDownloadLimit(size: assets.image.size))
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try store(temporary, digest: digest, size: assets.image.size, directory: directory)
  }

  static func store(_ temporary: URL, digest: String, size: Int, directory: URL) throws -> URL {
    guard try verify(temporary, digest: digest, size: size) else { throw UpdateDownloadError.checksum }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("Inkpot.dmg")
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
    return destination
  }
}

private final class UpdateDownloadLimit: NSObject, URLSessionDownloadDelegate {
  private let size: Int

  init(size: Int) { self.size = size }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    if totalBytesWritten > size || totalBytesExpectedToWrite > size { downloadTask.cancel() }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // 临时文件由 URLSession 的异步 download(for:) 返回并统一校验。
  }
}

enum UpdateDownloadError: LocalizedError {
  case invalidAssets, checksum

  var errorDescription: String? {
    switch self {
    case .invalidAssets: L10n.text("此版本缺少有效的 DMG 安装包或 SHA-256 校验文件，请前往下载页手动获取。")
    case .checksum: L10n.text("安装包校验失败，未保留此次下载。请稍后重试或前往下载页。")
    }
  }
}

@MainActor
final class AutomaticUpdates: ObservableObject {
  static let shared = AutomaticUpdates()
  static let interval: TimeInterval = 24 * 60 * 60
  private let defaults: UserDefaults
  private var timer: Timer?
  private var task: Task<Void, Never>?
  @Published private(set) var status = ""
  @Published private(set) var downloadedURL: URL?

  var enabled: Bool {
    get { defaults.object(forKey: "updates.automatic") as? Bool ?? true }
    set {
      guard newValue != enabled else { return }
      objectWillChange.send()
      defaults.set(newValue, forKey: "updates.automatic")
      if newValue {
        start(force: true)
      } else {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        status = ""
      }
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let tag = defaults.string(forKey: "updates.downloadedVersion"),
       let version = try? UpdateRelease.version(tag),
       let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       let installed = try? UpdateRelease.version(current), installed.lexicographicallyPrecedes(version) {
      let url = Self.directory(for: tag).appendingPathComponent("Inkpot.dmg")
      if FileManager.default.fileExists(atPath: url.path) {
        downloadedURL = url
        status = L10n.text("新版本 %@ 已下载", tag)
      }
    }
  }

  static func directory(for tag: String) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.erhu.inkpot/Updates", isDirectory: true)
      .appendingPathComponent(tag, isDirectory: true)
  }

  static func isDue(lastCheck: Date?, now: Date) -> Bool {
    guard let lastCheck else { return true }
    return lastCheck > now || now.timeIntervalSince(lastCheck) >= interval
  }

  func start(force: Bool = false) {
    guard enabled else { return }
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.run() }
      }
    }
    run(force: force)
  }

  private func run(force: Bool = false) {
    guard enabled, task == nil,
          force || Self.isDue(lastCheck: defaults.object(forKey: "updates.lastCheck") as? Date, now: .now) else { return }
    defaults.set(Date.now, forKey: "updates.lastCheck")
    status = L10n.text("正在检查更新…")
    task = Task { @MainActor in
      defer {
        task = nil
        if Task.isCancelled && enabled { run(force: true) }
      }
      let session = UpdateRelease.makeSession()
      defer { session.finishTasksAndInvalidate() }
      do {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { throw UpdateError.invalidRelease }
        guard let release = try await UpdateRelease.fetch(current: current, session: session) else {
          if !Task.isCancelled && enabled {
            downloadedURL = nil
            defaults.removeObject(forKey: "updates.downloadedVersion")
            status = L10n.text("已是最新版本")
          }
          return
        }
        try Task.checkCancellation()
        guard enabled else { return }
        status = L10n.text("正在下载新版本 %@…", release.tagName)
        let url = try await UpdateDownload.fetch(release, session: session, directory: Self.directory(for: release.tagName))
        try Task.checkCancellation()
        guard enabled else { return }
        defaults.set(release.tagName, forKey: "updates.downloadedVersion")
        downloadedURL = url
        status = L10n.text("新版本 %@ 已下载", release.tagName)
      } catch {
        if !Task.isCancelled && enabled { status = L10n.text("自动更新失败：%@", error.localizedDescription) }
      }
    }
  }

  func revealDownload() {
    guard let downloadedURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([downloadedURL])
  }
}
