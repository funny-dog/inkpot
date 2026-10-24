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
    let document = MVPDocument()
    defer { document.close() }
    document.safety.store = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
    try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
    document.fileURL = root.appendingPathComponent("a.md")
    let editor = document.makeEditor()
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-mvp-image img')?.naturalWidth === 32") as? Bool == true
    }
    document.fileURL = moved.appendingPathComponent("b.md")
    try await waitUntil {
      try await web.evaluateJavaScript("document.querySelector('.cm-mvp-image img')?.naturalWidth === 48") as? Bool == true
    }
    editor.performCommand("toggleSourceMode")
    try await waitUntil { try await web.evaluateJavaScript("document.querySelector('.cm-mvp-image') === null") as? Bool == true }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(source.utf8))
    XCTAssertFalse(document.isDocumentEdited)
  }

  func testImageInsertionIsOneUndoStepAndRestoresMixedEndings() async throws {
    _ = NSApplication.shared
    let source = "\u{FEFF}原文\r\n尾\n"
    let document = MVPDocument()
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
}
