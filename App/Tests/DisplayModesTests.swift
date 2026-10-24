import AppKit
import XCTest

@MainActor
final class DisplayModesTests: XCTestCase {
  private func item(_ menu: NSMenu?, _ title: String) throws -> NSMenuItem {
    try XCTUnwrap(menu?.items.first { $0.title == L10n.text(title) }, "缺少菜单项：\(title)")
  }

  private func modesScript(_ modes: DisplayModes) throws -> [String: Bool] {
    let script = try modes.script()
    let prefix = "window.inkpot.setDisplayModes("
    XCTAssertTrue(script.hasPrefix(prefix), script)
    XCTAssertTrue(script.hasSuffix(")"), script)
    let json = String(script.dropFirst(prefix.count).dropLast())
    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Bool])
  }

  private func temporaryDefaults() throws -> UserDefaults {
    let suite = "InkpotDisplayModesTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return defaults
  }

  func testDisplayMenuItemsUseFunctionKeysAndSharedTarget() throws {
    _ = NSApplication.shared
    let menu = MainMenu.make(delegate: AppDelegate())
    let display = try XCTUnwrap(menu.items[4].submenu)
    let focus = try item(display, "专注模式")
    let f8: UInt32? = UInt32(NSF8FunctionKey)
    XCTAssertEqual(focus.action, NSSelectorFromString("toggleFocusMode:"))
    XCTAssertEqual(focus.keyEquivalent.unicodeScalars.first?.value, f8)
    XCTAssertTrue(focus.keyEquivalentModifierMask.isEmpty)
    XCTAssertIdentical(focus.target, DisplayModes.shared)
    let typewriter = try item(display, "打字机模式")
    let f9: UInt32? = UInt32(NSF9FunctionKey)
    XCTAssertEqual(typewriter.action, NSSelectorFromString("toggleTypewriterMode:"))
    XCTAssertEqual(typewriter.keyEquivalent.unicodeScalars.first?.value, f9)
    XCTAssertTrue(typewriter.keyEquivalentModifierMask.isEmpty)
    XCTAssertIdentical(typewriter.target, DisplayModes.shared)
  }

  func testTogglePersistsPreferenceAndNotifiesAllWindows() throws {
    let defaults = try temporaryDefaults()
    let modes = DisplayModes(defaults: defaults)
    let notified = expectation(forNotification: DisplayModes.didChange, object: modes)
    modes.toggleFocusMode(nil)
    wait(for: [notified], timeout: 1)
    XCTAssertTrue(modes.focusEnabled)
    XCTAssertFalse(modes.typewriterEnabled)
    XCTAssertTrue(defaults.bool(forKey: "editor.focusMode"))
    modes.toggleTypewriterMode(nil)
    XCTAssertTrue(modes.typewriterEnabled)
    XCTAssertTrue(defaults.bool(forKey: "editor.typewriterMode"))
  }

  func testScriptCarriesModesAndPartialUpdateKeepsOtherKey() throws {
    let modes = DisplayModes(defaults: try temporaryDefaults())
    let initial = try modesScript(modes)
    XCTAssertEqual(initial, ["focus": false, "typewriter": false])
    modes.set(focus: true, typewriter: true)
    let enabled = try modesScript(modes)
    XCTAssertEqual(enabled, ["focus": true, "typewriter": true])
    // 局部更新只影响传入的键。
    modes.set(typewriter: false)
    let partial = try modesScript(modes)
    XCTAssertEqual(partial, ["focus": true, "typewriter": false])
  }

  func testMenuItemValidationReflectsPreferenceState() throws {
    let modes = DisplayModes(defaults: try temporaryDefaults())
    let menu = MainMenu.make(delegate: AppDelegate())
    let display = try XCTUnwrap(menu.items[4].submenu)
    let focus = try item(display, "专注模式")
    let typewriter = try item(display, "打字机模式")
    XCTAssertTrue(modes.validateMenuItem(focus))
    XCTAssertEqual(focus.state, NSControl.StateValue.off)
    XCTAssertTrue(modes.validateMenuItem(typewriter))
    XCTAssertEqual(typewriter.state, NSControl.StateValue.off)
    modes.set(focus: true)
    XCTAssertTrue(modes.validateMenuItem(focus))
    XCTAssertEqual(focus.state, NSControl.StateValue.on)
    XCTAssertEqual(typewriter.state, NSControl.StateValue.off)
  }

  func testEditorViewControllerSurvivesChangeNotificationBeforeReady() {
    _ = NSApplication.shared
    let controller = EditorViewController(text: "正文")
    NotificationCenter.default.post(name: DisplayModes.didChange, object: DisplayModes.shared)
    XCTAssertFalse(controller.isReady)
  }
}
