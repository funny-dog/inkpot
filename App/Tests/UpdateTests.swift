import XCTest

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
}
