import AppKit

/// 只检查正式版本；下载和覆盖安装由用户在发布页完成。
struct UpdateRelease: Decodable {
  let tagName: String
  let draft: Bool
  let prerelease: Bool

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case draft, prerelease
  }

  static let latestURL = URL(string: "https://github.com/funny-dog/inkpot/releases/latest")

  static func version(_ text: String) throws -> [Int] {
    let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw UpdateError.invalidRelease }
    return try parts.map { part in
      guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
            part.count == 1 || part.first != "0", let number = Int(part) else { throw UpdateError.invalidRelease }
      return number
    }
  }

  static func newerVersion(data: Data, status: Int, current: String) throws -> String? {
    switch status {
    case 200: break
    case 404: throw UpdateError.unavailable
    case 403, 429: throw UpdateError.rateLimited
    default: throw URLError(.badServerResponse)
    }
    let release = try JSONDecoder().decode(Self.self, from: data)
    guard !release.draft, !release.prerelease else { throw UpdateError.invalidRelease }
    let latest = try version(release.tagName)
    let installed = try version(current)
    return installed.lexicographicallyPrecedes(latest) ? release.tagName : nil
  }

  static func check(current: String) async throws -> String? {
    guard let url = URL(string: "https://api.github.com/repos/funny-dog/inkpot/releases/latest") else { throw URLError(.badURL) }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Inkpot/\(current)", forHTTPHeaderField: "User-Agent")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return try newerVersion(data: data, status: response.statusCode, current: current)
  }
}

enum UpdateError: LocalizedError {
  case unavailable, rateLimited, invalidRelease

  var errorDescription: String? {
    switch self {
    case .unavailable: L10n.text("尚无可公开查询的正式版本。仓库可能仍为私有，或尚未发布 Release。")
    case .rateLimited: L10n.text("GitHub 暂时限制了版本查询，请稍后重试，或直接前往下载页。")
    case .invalidRelease: L10n.text("版本信息无法识别，请前往下载页确认正式版本。")
    }
  }
}

@MainActor
final class UpdateChecker {
  static let shared = UpdateChecker()
  private(set) var isChecking = false

  func check() {
    guard !isChecking else { return }
    isChecking = true
    Task { @MainActor in
      defer { isChecking = false }
      let alert = NSAlert()
      do {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { throw UpdateError.invalidRelease }
        if let latest = try await UpdateRelease.check(current: current) {
          alert.messageText = L10n.text("发现新版本 %@", latest)
          alert.informativeText = L10n.text("当前版本为 %@。请在下载页获取安装包及 SHA-256 校验文件；正常退出并处理未保存文档后，再覆盖安装到 /Applications/Inkpot.app。", current)
        } else {
          alert.messageText = L10n.text("已是最新版本")
          alert.informativeText = L10n.text("当前版本为 %@，没有更新的正式版本。", current)
          alert.addButton(withTitle: L10n.text("好"))
          alert.runModal()
          return
        }
      } catch {
        alert.messageText = L10n.text("无法检查更新")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
      }
      alert.addButton(withTitle: L10n.text("前往下载页"))
      alert.addButton(withTitle: L10n.text("稍后"))
      if alert.runModal() == .alertFirstButtonReturn, let url = UpdateRelease.latestURL { NSWorkspace.shared.open(url) }
    }
  }
}
