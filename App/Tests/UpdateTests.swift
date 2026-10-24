import XCTest
import CryptoKit

private final class UpdateFixtureProtocol: URLProtocol {
  static var data = Data()
  static var status = 200

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil) else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class UpdateTests: XCTestCase {
  private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
    Data("{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(prerelease)}".utf8)
  }

  func testNewerVersionUsesNumericComponents() throws {
    XCTAssertEqual(try UpdateRelease.newerVersion(data: release("v0.10.0"), status: 200, current: "0.9.9"), "v0.10.0")
    XCTAssertEqual(try UpdateRelease.newerVersion(data: release("1.0.0"), status: 200, current: "0.99.99"), "1.0.0")
    XCTAssertNil(try UpdateRelease.newerVersion(data: release("v1.2.3"), status: 200, current: "1.2.3"))
    XCTAssertNil(try UpdateRelease.newerVersion(data: release("v1.2.2"), status: 200, current: "1.2.3"))
  }

  func testInvalidVersionsAreRejected() {
    for value in ["", "1.2", "1.2.3.4", "1.2.3-beta.1", "1.2.3+4", "01.2.3", "-1.2.3", "1..3", "１.2.3", "1.2.3\n", "999999999999999999999.2.3"] {
      XCTAssertThrowsError(try UpdateRelease.version(value), value)
    }
    XCTAssertThrowsError(try UpdateRelease.newerVersion(data: release("v1.0.0"), status: 200, current: "unknown"))
  }

  func testDraftAndPrereleaseAreRejected() {
    XCTAssertThrowsError(try UpdateRelease.newerVersion(data: release("v1.0.0", draft: true), status: 200, current: "0.1.0"))
    XCTAssertThrowsError(try UpdateRelease.newerVersion(data: release("v1.0.0", prerelease: true), status: 200, current: "0.1.0"))
    XCTAssertThrowsError(try UpdateRelease.newerVersion(data: Data("{}".utf8), status: 200, current: "0.1.0"))
  }

  func testUnavailableAndRateLimitsAreNotReportedAsUpToDate() {
    for (status, expected) in [(404, UpdateError.unavailable), (403, .rateLimited), (429, .rateLimited)] {
      XCTAssertThrowsError(try UpdateRelease.newerVersion(data: Data(), status: status, current: "0.1.0")) { error in
        XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
      }
    }
    XCTAssertThrowsError(try UpdateRelease.newerVersion(data: Data(), status: 500, current: "0.1.0"))
  }

  func testDownloadUsesLatestReleasePage() {
    XCTAssertEqual(UpdateRelease.latestURL?.absoluteString, "https://github.com/funny-dog/inkpot/releases/latest")
  }

  private func downloadableRelease(url: String = "https://github.com/funny-dog/inkpot/releases/download/v1.0.0/Inkpot.dmg", size: Int = 4) throws -> UpdateRelease {
    let data = try JSONSerialization.data(withJSONObject: [
      "tag_name": "v1.0.0", "draft": false, "prerelease": false,
      "assets": [
        ["name": "Inkpot.dmg", "size": size, "browser_download_url": url],
        ["name": "Inkpot.dmg.sha256", "size": 77, "browser_download_url": "https://github.com/funny-dog/inkpot/releases/download/v1.0.0/Inkpot.dmg.sha256"],
      ],
    ])
    return try JSONDecoder().decode(UpdateRelease.self, from: data)
  }

  func testDownloadRejectsUnexpectedSourcesAndSizes() throws {
    for url in [
      "http://github.com/funny-dog/inkpot/releases/download/v1.0.0/Inkpot.dmg",
      "https://example.com/funny-dog/inkpot/releases/download/v1.0.0/Inkpot.dmg",
      "https://github.com/other/repo/releases/download/v1.0.0/Inkpot.dmg",
      "https://github.com/funny-dog/inkpot/releases/download/v0.9.0/Inkpot.dmg",
    ] {
      let release = try downloadableRelease(url: url)
      XCTAssertThrowsError(try UpdateDownload.assets(for: release))
    }
    for size in [0, -1, UpdateDownload.maximumSize + 1] {
      let release = try downloadableRelease(size: size)
      XCTAssertThrowsError(try UpdateDownload.assets(for: release))
    }
    let missing = try JSONDecoder().decode(UpdateRelease.self, from: release("v1.0.0"))
    XCTAssertThrowsError(try UpdateDownload.assets(for: missing))
  }

  func testChecksumRejectsMalformedOrWrongFileNames() throws {
    let digest = String(repeating: "a", count: 64)
    XCTAssertEqual(try UpdateDownload.checksum(Data("\(digest.uppercased())  Inkpot.dmg\n".utf8)), digest)
    for value in ["", "\(digest)  other.dmg", "\(digest)  ../Inkpot.dmg", "\(digest)  Inkpot.dmg\nextra", "xyz  Inkpot.dmg"] {
      XCTAssertThrowsError(try UpdateDownload.checksum(Data(value.utf8)))
    }
  }

  func testFileVerificationRejectsChangedOrTruncatedDownload() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Inkpot.dmg")
    let data = Data("DMG!".utf8)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try data.write(to: url)
    XCTAssertTrue(try UpdateDownload.verify(url, digest: digest, size: 4))
    XCTAssertFalse(try UpdateDownload.verify(url, digest: digest, size: 5))
    try Data("BAD!".utf8).write(to: url)
    XCTAssertFalse(try UpdateDownload.verify(url, digest: digest, size: 4))
  }

  @MainActor
  func testAutomaticUpdatePreferenceDefaultsOnAndDailyLimit() throws {
    let suite = "InkpotUpdateTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(AutomaticUpdates(defaults: defaults).enabled)
    defaults.set(true, forKey: "updates.automatic")
    let updates = AutomaticUpdates(defaults: defaults)
    XCTAssertTrue(updates.enabled)
    updates.enabled = false
    XCTAssertFalse(AutomaticUpdates(defaults: defaults).enabled)
    let now = Date.now
    XCTAssertTrue(AutomaticUpdates.isDue(lastCheck: nil, now: now))
    XCTAssertFalse(AutomaticUpdates.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
    XCTAssertTrue(AutomaticUpdates.isDue(lastCheck: now.addingTimeInterval(-86400), now: now))
    XCTAssertTrue(AutomaticUpdates.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
  }

  func testOnlyVerifiedDownloadsReplaceCachedInstaller() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = cache.appendingPathComponent("Inkpot.dmg")
    try Data("old".utf8).write(to: destination)
    let temporary = root.appendingPathComponent("download")
    let data = Data("DMG!".utf8)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try Data("BAD!".utf8).write(to: temporary)
    XCTAssertThrowsError(try UpdateDownload.store(temporary, digest: digest, size: 4, directory: cache))
    XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    try data.write(to: temporary)
    XCTAssertEqual(try UpdateDownload.store(temporary, digest: digest, size: 4, directory: cache), destination)
    XCTAssertEqual(try Data(contentsOf: destination), data)
  }

  func testCachedDownloadRequiresFreshChecksumAndSuccessfulResponse() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Inkpot.dmg")
    let data = Data("DMG!".utf8)
    try data.write(to: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    UpdateFixtureProtocol.status = 200
    UpdateFixtureProtocol.data = Data("\(digest)  Inkpot.dmg\n".utf8)
    let release = try downloadableRelease()
    let cached = try await UpdateDownload.fetch(release, session: session, directory: directory)
    XCTAssertEqual(cached, url)
    UpdateFixtureProtocol.status = 404
    do {
      _ = try await UpdateDownload.fetch(release, session: session, directory: directory)
      XCTFail("远程校验文件读取失败时不能使用缓存")
    } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
  }
}
