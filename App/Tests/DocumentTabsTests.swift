import AppKit
import XCTest

@MainActor
final class DocumentTabsTests: XCTestCase {
  private func document() throws -> (InkpotDocument, NSWindow) {
    _ = NSApplication.shared
    let document = InkpotDocument()
    NSDocumentController.shared.addDocument(document)
    document.makeWindowControllers()
    return (document, try XCTUnwrap(document.windowControllers.first?.window))
  }

  func testNativeTabGroupKeepsSeparateDocumentsEditorsAndFolderContext() throws {
    let (first, parent) = try document()
    let second = InkpotDocument()
    NSDocumentController.shared.addDocument(second)
    defer { first.close(); second.close() }
    let root = FileManager.default.temporaryDirectory
    let container = try XCTUnwrap(parent.contentViewController as? DocumentViewController)
    container.files.openFolder(root)
    container.toggleContent(files: true)
    DocumentTabs.attach(second, to: parent)
    let next = try XCTUnwrap(second.windowControllers.first?.window)
    XCTAssertEqual(parent.tabbingIdentifier, next.tabbingIdentifier)
    XCTAssertNotEqual(parent.tabbingMode, .disallowed)
    XCTAssertEqual(parent.tabGroup?.windows.contains { $0 === next }, true)
    XCTAssertIdentical(parent.tabGroup?.selectedWindow, next)
    XCTAssertNotIdentical(first.editor, second.editor)
    XCTAssertIdentical(parent.windowController?.document, first)
    XCTAssertIdentical(next.windowController?.document, second)
    let inherited = try XCTUnwrap(next.contentViewController as? DocumentViewController)
    XCTAssertEqual(inherited.files.root?.entry.url, root.standardizedFileURL)
    XCTAssertTrue(inherited.filesVisible)
    XCTAssertEqual(parent.windowController?.responds(to: #selector(NSResponder.newWindowForTab(_:))), true)
    second.close()
    XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === first })
  }

  func testOpeningExistingTabDoesNotMoveItAndReadFailureLeavesCurrentDocument() async throws {
    let (first, parent) = try document()
    let (existing, existingWindow) = try document()
    defer { first.close(); existing.close() }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("existing.md")
    existing.fileURL = url
    let opened = try await DocumentTabs.open(url, in: parent) { _ in (existing, true) }
    XCTAssertIdentical(opened, existing)
    XCTAssertIdentical(existing.windowControllers.first?.window, existingWindow)
    XCTAssertNotEqual(parent.tabGroup?.windows.contains { $0 === existingWindow }, true)
    do {
      _ = try await DocumentTabs.open(url, in: parent) { _ in throw CocoaError(.fileReadCorruptFile) }
      XCTFail("读取失败不能替换或关闭当前文档")
    } catch {}
    XCTAssertIdentical(parent.windowController?.document, first)
  }

  func testTabMenusUseNativeActionsAndDoNotConflictWithFontShortcut() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let menu = MainMenu.make(delegate: delegate)
    let item = try XCTUnwrap(menu.items[1].submenu?.items.first { $0.title == "新建标签页" })
    XCTAssertEqual(item.action, #selector(NSResponder.newWindowForTab(_:)))
    XCTAssertNil(item.target)
    XCTAssertEqual(item.keyEquivalent, "n")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
    let next = try XCTUnwrap(menu.items[5].submenu?.items.first { $0.title == "下一个标签页" })
    let previous = try XCTUnwrap(menu.items[5].submenu?.items.first { $0.title == "上一个标签页" })
    XCTAssertEqual(next.action, #selector(NSWindow.selectNextTab(_:)))
    XCTAssertEqual(next.keyEquivalent, "\t")
    XCTAssertEqual(next.keyEquivalentModifierMask, [.control])
    XCTAssertEqual(previous.keyEquivalentModifierMask, [.control, .shift])
    XCTAssertEqual(menu.items[4].submenu?.items.first { $0.title == "正文字体与字号…" }?.keyEquivalent, "t")
  }
}
