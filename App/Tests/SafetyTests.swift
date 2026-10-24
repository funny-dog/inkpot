import AppKit
import WebKit
import XCTest

@MainActor
final class SafetyTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func document(_ data: Data, url: URL?, store: RecoveryStore) async throws -> InkpotDocument {
    _ = NSApplication.shared
    let document = InkpotDocument()
    document.safety.store = store
    try document.read(from: data, ofType: "net.daringfireball.markdown")
    document.fileURL = url
    let editor = document.makeEditor()
    _ = editor.view
    try await waitUntil { editor.isReady }
    return document
  }

  func testRecoveryStoreKeepsLatestBytesPermissionsAndOtherValidDrafts() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
    let id = UUID()
    let original = Data("\u{FEFF}中文\r\n尾\n".utf8)
    try store.write(RecoveryDraft(id: id, originalURL: nil, data: Data(), updated: .distantPast))
    try store.write(RecoveryDraft(id: id, originalURL: root.appendingPathComponent("a.md"), data: original, updated: .now))
    let bad = store.directory.appendingPathComponent("bad.json")
    try Data("损坏记录".utf8).write(to: bad)
    let drafts = try store.drafts()
    XCTAssertEqual(drafts.count, 1)
    XCTAssertEqual(drafts[0].data, original)
    let file = store.directory.appendingPathComponent(id.uuidString + ".json")
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
    try store.remove(id)
    XCTAssertTrue(try store.drafts().isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
  }

  func testDraftRestorePreservesBOMMixedEndingsAndDoesNotOverwriteOriginal() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("a.md")
    let original = Data("\u{FEFF}# 原文\r\n尾\n".utf8)
    try original.write(to: url)
    let store = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
    let document = try await document(original, url: url, store: store)
    defer { document.close() }
    let editor = try XCTUnwrap(document.editor)
    let web = try XCTUnwrap(editor.view as? WKWebView)
    _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, '修改'); null")
    try await waitUntil { editor.latestRevision > 0 }
    try await document.safety.persist()
    let draft = try XCTUnwrap(store.drafts().first)
    XCTAssertEqual(draft.data, Data("\u{FEFF}修改# 原文\r\n尾\n".utf8))
    XCTAssertEqual(try Data(contentsOf: url), original)
    let recovered = InkpotDocument()
    defer { recovered.close() }
    recovered.safety.store = store
    try recovered.read(from: draft.data, ofType: "net.daringfireball.markdown")
    recovered.safety.restore(draft)
    recovered.updateChangeCount(.changeDone)
    let restoredEditor = recovered.makeEditor()
    _ = restoredEditor.view
    try await waitUntil { restoredEditor.isReady }
    try await recovered.synchronize()
    XCTAssertTrue(recovered.isDocumentEdited)
    XCTAssertNil(recovered.fileURL)
    XCTAssertEqual(try recovered.data(ofType: "net.daringfireball.markdown"), draft.data)
    try recovered.writeSafely(to: root.appendingPathComponent("copy.md"), ofType: "net.daringfireball.markdown", for: .saveAsOperation)
    XCTAssertTrue(try store.drafts().isEmpty)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testExternalChangeReloadsCleanDocumentAndBlocksOverwriteWhenEdited() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("a.md")
    let original = Data("# 原文\r\n".utf8)
    try original.write(to: url)
    let store = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
    let document = try await document(original, url: url, store: store)
    defer { document.close() }
    let editor = try XCTUnwrap(document.editor)
    let web = try XCTUnwrap(editor.view as? WKWebView)
    let external = Data("\u{FEFF}# 外部\n".utf8)
    try external.write(to: url)
    try await document.safety.refreshFromDisk()
    try await waitUntil { editor.isReady }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), external)
    XCTAssertFalse(document.isDocumentEdited)
    _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, '本地'); null")
    try await waitUntil { editor.latestRevision > 0 }
    try await document.synchronize()
    let local = try document.data(ofType: "net.daringfireball.markdown")
    let changedAgain = Data("# 外部第二版\n".utf8)
    try changedAgain.write(to: url)
    try await document.safety.refreshFromDisk()
    XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), local)
    XCTAssertThrowsError(try document.writeSafely(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation))
    XCTAssertEqual(try Data(contentsOf: url), changedAgain)
    XCTAssertEqual(try store.drafts().first?.data, local)
    let copy = root.appendingPathComponent("local-copy.md")
    try document.writeSafely(to: copy, ofType: "net.daringfireball.markdown", for: .saveAsOperation)
    XCTAssertEqual(try Data(contentsOf: copy), local)
    XCTAssertEqual(try Data(contentsOf: url), changedAgain)
  }

  func testFailedSnapshotKeepsPreviousRecoveryAndCloseClearsOnlyItsOwnDraft() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
    let document = try await document(Data("原文".utf8), url: nil, store: store)
    defer { document.close() }
    let editor = try XCTUnwrap(document.editor)
    let web = try XCTUnwrap(editor.view as? WKWebView)
    _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, '新'); null")
    try await waitUntil { editor.latestRevision > 0 }
    try await document.safety.persist()
    let bytes = try XCTUnwrap(store.drafts().first?.data)
    _ = try await web.evaluateJavaScript("window.inkpot.snapshot = () => { throw new Error('测试读取失败'); }; null")
    do { try await document.safety.persist(); XCTFail("失败的快照不能写入恢复文件") } catch {}
    XCTAssertEqual(try store.drafts().first?.data, bytes)
    let other = UUID()
    try store.write(RecoveryDraft(id: other, originalURL: nil, data: Data("其他文档".utf8), updated: .now))
    document.close()
    XCTAssertEqual(try store.drafts().map(\.id), [other])
  }
}

extension SafetyTests {
  func testDebouncedRecoveryWaitsForCompositionAndStopsAfterClose() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
    let document = try await document(Data("原文".utf8), url: nil, store: store)
    defer { document.close() }
    let editor = try XCTUnwrap(document.editor)
    let web = try XCTUnwrap(editor.view as? WKWebView)
    _ = try await web.evaluateJavaScript("""
      document.execCommand('insertText', false, '新');
      document.querySelector('.cm-content').dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true})); null
      """)
    try await waitUntil { editor.isComposing }
    do { _ = try await editor.snapshot(); XCTFail("候选刚开始时也不能采集快照") } catch {}
    try await Task.sleep(for: .milliseconds(1100))
    XCTAssertTrue(try store.drafts().isEmpty)
    _ = try await web.evaluateJavaScript("""
      document.querySelector('.cm-content').dispatchEvent(new CompositionEvent('compositionend', {bubbles: true})); null
      """)
    try await waitUntil { !editor.isComposing }
    try await waitUntil { try store.drafts().count == 1 }
    XCTAssertEqual(try store.drafts().first?.data, Data("新原文".utf8))
    document.close()
    XCTAssertTrue(try store.drafts().isEmpty)
  }

  func testLegacyRecoveryDirectoryMigratesWholeFolderAndNeverOverwritesCurrent() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Kernmark/Recovery")
    let current = root.appendingPathComponent("Inkpot/Recovery")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let draft = legacy.appendingPathComponent("legacy.json")
    try Data("旧草稿".utf8).write(to: draft)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draft.path)

    RecoveryStore.migrateLegacyDirectory(from: legacy, to: current)
    let migrated = current.appendingPathComponent("legacy.json")
    XCTAssertEqual(try Data(contentsOf: migrated), Data("旧草稿".utf8))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: migrated.path)[.posixPermissions] as? Int, 0o600)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? Int, 0o700)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

    RecoveryStore.migrateLegacyDirectory(from: legacy, to: current)
    XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.path))

    try Data("新草稿".utf8).write(to: current.appendingPathComponent("new.json"))
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("迟到旧草稿".utf8).write(to: legacy.appendingPathComponent("again.json"))
    RecoveryStore.migrateLegacyDirectory(from: legacy, to: current)
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("again.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("new.json").path))
  }
}
