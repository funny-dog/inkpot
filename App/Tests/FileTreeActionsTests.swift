import AppKit
import WebKit
import XCTest

@MainActor
final class FileTreeActionsTests: XCTestCase {
  private let type = "net.daringfireball.markdown"

  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func document(_ url: URL, text: String = "正文") throws -> InkpotDocument {
    let document = InkpotDocument()
    try Data(text.utf8).write(to: url)
    try document.read(from: Data(text.utf8), ofType: type)
    document.fileURL = url
    document.fileType = type
    NSDocumentController.shared.addDocument(document)
    return document
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(5)
    while !(try await condition()) {
      guard Date.now < deadline else { throw CocoaError(.coderReadCorrupt) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testCreateValidatesNamesAndNeverOverwritesExistingFilesOrFolders() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let actions = FileTreeActions { [] }
    let file = try actions.create(in: root, name: "中文 空格.md", directory: false)
    try Data("已有内容".utf8).write(to: file)
    XCTAssertThrowsError(try actions.create(in: root, name: "中文 空格.md", directory: false))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "已有内容")
    _ = try actions.create(in: root, name: "子目录", directory: true)
    XCTAssertThrowsError(try actions.create(in: root, name: "子目录", directory: true))
    for name in ["", "  ", ".", "..", "../越界.md", "子/越界.md", ".隐藏.md", "换\n行.md", "a:b.md", "a.pdf"] {
      XCTAssertThrowsError(try actions.create(in: root, name: name, directory: false), name)
    }
    XCTAssertEqual(Set(try FolderEntry.read(root).map { $0.url.lastPathComponent }), Set(["中文 空格.md", "子目录"]))
  }

  func testContextMenuUsesClickedItemAndRootMenuOnlyCreates() throws {
    _ = NSApplication.shared
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = FileTreeViewController()
    tree.openFolder(root)
    XCTAssertEqual(tree.contextMenu(for: nil).items.map(\.title), ["新建 Markdown 文件…", "新建文件夹…"])
    let url = root.appendingPathComponent("目标.md")
    let menu = tree.contextMenu(for: FolderEntry(url: url, isDirectory: false))
    XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["在新标签页中打开", "新建 Markdown 文件…", "新建文件夹…", "重命名…", "移到废纸篓"])
    XCTAssertEqual(menu.items.first?.representedObject as? URL, url)
    XCTAssertEqual(menu.items.last?.representedObject as? URL, url)
    let directory = tree.contextMenu(for: FolderEntry(url: root.appendingPathComponent("目录"), isDirectory: true))
    XCTAssertFalse(directory.items.contains { $0.title == "在新标签页中打开" })
    XCTAssertEqual(directory.items.first?.representedObject as? URL, root.appendingPathComponent("目录"))
  }

  func testFolderRenameFollowsOpenDirtyDocumentAndOtherTreesWithoutChangingHistory() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("旧目录", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
    let original = "\u{FEFF}原文\r\n尾\n"
    let document = try document(old.appendingPathComponent("a.md"), text: original)
    defer { document.close() }
    document.makeWindowControllers()
    let editor = try XCTUnwrap(document.editor)
    let web = try XCTUnwrap(editor.view as? WKWebView)
    try await waitUntil { editor.isReady }
    try await Task.sleep(for: .milliseconds(600))
    _ = try await editor.evaluateScript("document.execCommand('insertText', false, '修改'); null")
    try await waitUntil { editor.latestRevision > 0 }
    let before = try await editor.snapshot()
    let tree = FileTreeViewController()
    tree.openFolder(old)
    try await waitUntil { tree.root?.children?.count == 1 }
    tree.selectCurrentFile(document.fileURL)
    let actions = FileTreeActions { [document] }
    let moved = try await actions.rename(old, name: "新目录")
    let newFile = moved.appendingPathComponent("a.md")
    XCTAssertEqual(document.fileURL, newFile)
    XCTAssertTrue(document.isDocumentEdited)
    let after = try await editor.snapshot()
    XCTAssertEqual(after.text, before.text)
    XCTAssertIdentical(web, document.editor?.view)
    try await waitUntil { tree.root?.entry.url == moved && tree.outlineView.selectedRow == 0 }
    XCTAssertEqual(try Data(contentsOf: newFile), Data(original.utf8))
    editor.undo(nil)
    try await waitUntil { editor.latestRevision > after.revision }
    try await document.synchronize()
    XCTAssertEqual(try document.data(ofType: type), Data(original.utf8))
    try document.writeSafely(to: newFile, ofType: type, for: .saveOperation)
    XCTAssertEqual(try Data(contentsOf: newFile), Data(original.utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertNil(FileTreeActions.relocated(root.appendingPathComponent("旧目录-其他/a.md"), from: old, to: moved))
  }

  func testRenameCollisionDoesNotReplaceTargetOrChangeOpenPath() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = try document(root.appendingPathComponent("a.md"))
    defer { document.close() }
    let occupied = root.appendingPathComponent("b.md")
    try Data("目标内容".utf8).write(to: occupied)
    let actions = FileTreeActions { [document] }
    do { _ = try await actions.rename(try XCTUnwrap(document.fileURL), name: "b.md"); XCTFail("不能覆盖已有文件") } catch {}
    XCTAssertEqual(document.fileURL, root.appendingPathComponent("a.md"))
    XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "目标内容")
  }

  func testTrashCancellationAndFailureKeepDocumentsAndDiskContents() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = try document(root.appendingPathComponent("a.md"))
    defer { document.close() }
    document.updateChangeCount(.changeDone)
    var recycled = false
    let cancelled = FileTreeActions(documents: { [document] }, confirmClose: { _ in false }, recycle: { _ in recycled = true })
    let first = try await cancelled.trash(root)
    XCTAssertFalse(first)
    XCTAssertFalse(recycled)
    let failing = FileTreeActions(documents: { [document] }, confirmClose: { _ in true }, recycle: { _ in throw CocoaError(.fileWriteNoPermission) })
    do { _ = try await failing.trash(root); XCTFail("应报告失败") } catch {}
    XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === document })
    XCTAssertTrue(document.isDocumentEdited)
    XCTAssertEqual(try document.data(ofType: type), try Data(contentsOf: root.appendingPathComponent("a.md")))
    XCTAssertFalse(failing.isWorking)
  }

  func testTrashClosesOnlyDescendantsAfterSuccessAndLeavesSaveAsDocumentOpen() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let first = try document(directory.appendingPathComponent("a.md"))
    let savedAs = try document(directory.appendingPathComponent("b.md"))
    let outside = try document(root.appendingPathComponent("docs-other.md"))
    defer { first.close(); savedAs.close(); outside.close() }
    let all = [first, savedAs, outside]
    var recycled = false
    let actions = FileTreeActions(
      documents: { all },
      confirmClose: { document in
        if document === savedAs { document.fileURL = root.appendingPathComponent("保留.md") }
        return true
      },
      recycle: { source in
        XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === first })
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("模拟废纸篓"))
        recycled = true
      }
    )
    let succeeded = try await actions.trash(directory)
    XCTAssertTrue(succeeded)
    XCTAssertTrue(recycled)
    XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === first })
    XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === savedAs })
    XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === outside })
  }

  func testChangesDuringConfirmationCancelBeforeTrash() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try document(root.appendingPathComponent("a.md"))
    let second = try document(root.appendingPathComponent("b.md"))
    defer { first.close(); second.close() }
    var recycled = false
    let actions = FileTreeActions(
      documents: { [first, second] },
      confirmClose: { document in
        if document === second {
          try? first.read(from: Data("新修改".utf8), ofType: self.type)
          first.updateChangeCount(.changeDone)
        }
        return true
      },
      recycle: { _ in recycled = true }
    )
    do { _ = try await actions.trash(root); XCTFail("确认期间的新修改必须阻止移动") } catch {}
    XCTAssertFalse(recycled)
    XCTAssertEqual(try first.data(ofType: type), Data("新修改".utf8))
    XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === first })
  }

  func testActualTrashUsesRecoverableSystemLocation() async throws {
    let root = try folder()
    let file = root.appendingPathComponent("inkpot-trash-\(UUID().uuidString).md")
    var trashed: URL?
    defer {
      if let trashed { try? FileManager.default.moveItem(at: trashed, to: file) }
      try? FileManager.default.removeItem(at: root)
    }
    let data = Data("可恢复的内容".utf8)
    try data.write(to: file)
    let actions = FileTreeActions(documents: { [] }, recycle: { url in
      var result: NSURL?
      try FileManager.default.trashItem(at: url, resultingItemURL: &result)
      trashed = result as URL?
    })
    let success = try await actions.trash(file)
    XCTAssertTrue(success)
    let destination = try XCTUnwrap(trashed)
    XCTAssertNotEqual(destination, file)
    XCTAssertEqual(try Data(contentsOf: destination), data)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }
}
