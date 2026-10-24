import AppKit
import WebKit
import XCTest

@MainActor
final class ImageTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func png(width: Int = 32) throws -> Data {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: 24,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))
    for x in 0..<width { for y in 0..<24 { bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.4, blue: 0.8, alpha: 1), atX: x, y: y) } }
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testImageStorageCreatesUniqueRelativeFilesAndRejectsNonImagesAndAssetLinks() throws {
    let root = try directory()
    let outside = try directory()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let data = try png()
    let url = root.appendingPathComponent("a.md")
    let first = try LocalImages.store(data, beside: url)
    let second = try LocalImages.store(data, beside: url)
    XCTAssertNotEqual(first.path, second.path)
    XCTAssertTrue(first.path.hasPrefix("assets/image-"))
    XCTAssertEqual(try Data(contentsOf: first.url), data)
    XCTAssertEqual(try LocalImages.read(first.path, relativeTo: url).0, data)
    for invalid in [Data("文本".utf8), Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8)] {
      XCTAssertThrowsError(try LocalImages.store(invalid, beside: url))
    }
    XCTAssertThrowsError(try LocalImages.read("https://example.com/a.png", relativeTo: url))
    XCTAssertThrowsError(try LocalImages.read("file://remotehost/a.png", relativeTo: url))
    let linkedDocument = outside.appendingPathComponent("b.md")
    try FileManager.default.createSymbolicLink(at: outside.appendingPathComponent("assets"), withDestinationURL: root)
    XCTAssertThrowsError(try LocalImages.store(data, beside: linkedDocument))
  }

  func testWKWebViewLoadsRelativeImageAndRebasesAfterSaveAsWithoutRewritingSource() async throws {
    _ = NSApplication.shared
    let root = try directory()
    let moved = try directory()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
    let name = "中文 图.png"
    try png().write(to: root.appendingPathComponent(name))
    try png(width: 48).write(to: moved.appendingPathComponent(name))
    let source = "\u{FEFF}# 图片\r\n\r\n![示意](<中文%20图.png>)\r\n尾\n"
    let document = InkpotDocument()
    defer { document.close() }
    document.safety.store = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
    try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
    document.fileURL = root.appendingPathComponent("a.md")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-image img')?.naturalWidth === 32") as? Bool == true
    }
    document.fileURL = moved.appendingPathComponent("b.md")
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-image img')?.naturalWidth === 48") as? Bool == true
    }
    editor.performCommand("toggleSourceMode")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-inkpot-image') === null") as? Bool == true }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(source.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testImageInsertionIsOneUndoStepAndRestoresMixedEndings() async throws {
    _ = NSApplication.shared
    let source = "\u{FEFF}原文\r\n尾\n"
    let document = InkpotDocument()
    defer { document.close() }
    try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
    let editor = document.makeEditor()
    _ = editor.view
    try await waitUntil { editor.isReady }
    try await editor.insertImage("assets/image-test.png")
    let inserted = try await editor.snapshot()
    XCTAssertEqual(inserted.text, "![图片](assets/image-test.png)原文\r\n尾\n")
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > inserted.revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(source.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testExportedHTMLKeepsImagesAfterOriginalIsRemoved() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let originalImage = root.appendingPathComponent("image.png")
    try png().write(to: originalImage)
    let document = InkpotDocument()
    defer { document.close() }
    try document.read(from: Data("前 ![图](image.png)".utf8), ofType: "net.daringfireball.markdown")
    document.fileURL = root.appendingPathComponent("document.md")
    let editor = document.makeEditor()
    _ = editor.view
    try await waitUntil { editor.isReady }
    let html = try await DocumentExport.documentHTML(document, pdfMode: false)
    XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
    try FileManager.default.removeItem(at: originalImage)
    let reader = WKWebView()
    try await reader.loadHTMLString(html, baseURL: nil)
    try await waitUntil { try await reader.evaluateJavaScript("document.querySelector('img')?.naturalWidth === 32") as? Bool == true }
  }

  func testRemoteImagesURLValidationAndRedirectionPolicy() async throws {
    // 验证 HTTPS URL 规则与非 HTTPS / 凭据拦截策略
    XCTAssertNoThrow(try RemoteImages.validate(url: try XCTUnwrap(URL(string: "https://example.com/image.png"))))
    XCTAssertThrowsError(try RemoteImages.validate(url: try XCTUnwrap(URL(string: "http://example.com/image.png")))) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnsupportedScheme)
    }
    XCTAssertThrowsError(try RemoteImages.validate(url: try XCTUnwrap(URL(string: "ftp://example.com/image.png")))) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnsupportedScheme)
    }
    XCTAssertThrowsError(try RemoteImages.validate(url: try XCTUnwrap(URL(string: "https://user:pass@example.com/image.png")))) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
    }
    XCTAssertThrowsError(try RemoteImages.validate(url: try XCTUnwrap(URL(string: "https://user@example.com/image.png")))) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
    }
    XCTAssertThrowsError(try RemoteImages.validate(url: try XCTUnwrap(URL(string: "https:///image.png")))) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnsupportedScheme)
    }

    // 通过本地 URLProtocol stub 验证重定向策略
    let (session, delegate) = makeTestSession()
    let pngData = try png()

    // 1. 重定向到不安全 HTTP 应被取消拦截
    TestImageURLProtocol.responseProvider = { req in
      if req.url?.absoluteString == "https://example.com/initial.png" {
        let resp = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://insecure.example.com/test.png"]))
        return (resp, [])
      }
      return (try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 200, httpVersion: nil, headerFields: [:])), [pngData])
    }
    do {
      _ = try await RemoteImages.read("https://example.com/initial.png", session: session, delegate: delegate)
      XCTFail("重定向至 HTTP 必须被拒绝")
    } catch {
      XCTAssertNotNil(error)
    }

    // 2. 重定向到带用户名密码的 HTTPS 也必须被拦截
    TestImageURLProtocol.responseProvider = { req in
      if req.url?.absoluteString == "https://example.com/auth-redirect.png" {
        let resp = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://user:pass@evil.com/test.png"]))
        return (resp, [])
      }
      return (try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 200, httpVersion: nil, headerFields: [:])), [pngData])
    }
    do {
      _ = try await RemoteImages.read("https://example.com/auth-redirect.png", session: session, delegate: delegate)
      XCTFail("重定向至带凭据的目标必须被拒绝")
    } catch {
      XCTAssertNotNil(error)
    }

    // 3. 重定向到合法 HTTPS 位图正常加载
    TestImageURLProtocol.responseProvider = { req in
      if req.url?.absoluteString == "https://example.com/valid-redirect.png" {
        let resp = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://cdn.example.com/image.png"]))
        return (resp, [])
      }
      let resp = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]))
      return (resp, [pngData])
    }
    let result = try await RemoteImages.read("https://example.com/valid-redirect.png", session: session, delegate: delegate)
    XCTAssertEqual(result.0, pngData)
  }

  func testRemoteImagesSizeAndPixelLimitations() async throws {
    // 1. Content-Length 预先声明超限（> 20MiB）在接收数据前即时取消
    let (session1, delegate1) = makeTestSession()
    TestImageURLProtocol.responseProvider = { req in
      let resp = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "26214400"]))
      return (resp, [])
    }
    do {
      _ = try await RemoteImages.read("https://example.com/huge-header.png", session: session1, delegate: delegate1)
      XCTFail("Content-Length 超限应当立即拒绝")
    } catch {
      let code = (error as NSError).code
      XCTAssertTrue(code == 36 || code == NSURLErrorCancelled)
    }

    // 2. 无预告大体积流（chunked）在接收过程中实时中断取消
    let (session2, delegate2) = makeTestSession()
    let chunk1 = Data(repeating: 0x12, count: 11 * 1024 * 1024)
    let chunk2 = Data(repeating: 0x34, count: 11 * 1024 * 1024)
    TestImageURLProtocol.responseProvider = { req in
      let resp = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(req.url), statusCode: 200, httpVersion: nil, headerFields: [:]))
      return (resp, [chunk1, chunk2])
    }
    do {
      _ = try await RemoteImages.read("https://example.com/stream-huge.png", session: session2, delegate: delegate2)
      XCTFail("流式下载累计超过 20MiB 时必须在接收过程中中断")
    } catch {
      let code = (error as NSError).code
      XCTAssertTrue(code == 36 || code == NSURLErrorCancelled)
    }

    // 3. 像素大小限制：正常像素通过，超出像素上限（如设定上限为 100 像素）拒绝
    let normal = try png(width: 32)
    XCTAssertNoThrow(try RemoteImages.validate(data: normal, maxPixels: 16_777_216))
    XCTAssertThrowsError(try RemoteImages.validate(data: normal, maxPixels: 100)) { error in
      XCTAssertEqual((error as NSError).code, 33)
    }
  }

  func testRemoteImagesRejectsNonImagesAndSVG() throws {
    let textData = Data("这是普通的文本数据，并非位图".utf8)
    XCTAssertThrowsError(try RemoteImages.validate(data: textData)) { error in
      XCTAssertEqual((error as NSError).code, 30)
    }

    let svgData = Data("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'></svg>".utf8)
    XCTAssertThrowsError(try RemoteImages.validate(data: svgData)) { error in
      XCTAssertEqual((error as NSError).code, 30)
    }

    let xmlSVG = Data("<?xml version='1.0' encoding='UTF-8'?><svg width='10' height='10'></svg>".utf8)
    XCTAssertThrowsError(try RemoteImages.validate(data: xmlSVG)) { error in
      XCTAssertEqual((error as NSError).code, 30)
    }
  }

  func testLocalImageHandlerRoutingAndSettings() {
    let handler = LocalImageHandler()
    // 默认关闭远程图片加载
    XCTAssertFalse(handler.allowRemoteImages)

    // 分流判定验证：网络引用不得误判为本地文件
    XCTAssertTrue(RemoteImages.isHTTPSReference("https://example.com/photo.png"))
    XCTAssertFalse(RemoteImages.isHTTPSReference("http://example.com/photo.png"))
    XCTAssertFalse(RemoteImages.isHTTPSReference("assets/photo.png"))

    XCTAssertTrue(RemoteImages.isNetworkReference("https://example.com/photo.png"))
    XCTAssertTrue(RemoteImages.isNetworkReference("http://example.com/photo.png"))
    XCTAssertTrue(RemoteImages.isNetworkReference("//example.com/photo.png"))
    XCTAssertFalse(RemoteImages.isNetworkReference("assets/photo.png"))
    XCTAssertFalse(RemoteImages.isNetworkReference("file:///Users/test/photo.png"))
  }

  private func makeTestSession() -> (URLSession, RemoteImageDelegate) {
    let configuration = RemoteImages.makeSessionConfiguration()
    configuration.protocolClasses = [TestImageURLProtocol.self]
    let delegate = RemoteImageDelegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    return (session, delegate)
  }
}

final class TestImageURLProtocol: URLProtocol {
  typealias ResponseProvider = (URLRequest) throws -> (HTTPURLResponse, [Data])

  nonisolated(unsafe) static var responseProvider: ResponseProvider?

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let provider = Self.responseProvider else {
      client?.urlProtocol(self, didFailWithError: CocoaError(.fileReadUnknown))
      return
    }
    do {
      let (response, chunks) = try provider(request)
      if let location = response.allHeaderFields["Location"] as? String, let targetURL = URL(string: location) {
        let redirectRequest = URLRequest(url: targetURL)
        client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for chunk in chunks {
        client?.urlProtocol(self, didLoad: chunk)
      }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
