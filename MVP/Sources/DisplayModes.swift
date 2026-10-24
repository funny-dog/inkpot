import AppKit

/// 全局专注与打字机模式偏好：UserDefaults 持久化、菜单开关与所有文档窗口即时同步，做法与 EditorFonts 一致。
@MainActor
final class DisplayModes: NSObject, NSMenuItemValidation {
  static let shared = DisplayModes()
  static let didChange = Notification.Name("InkpotDisplayModesDidChange")
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    super.init()
  }

  var focusEnabled: Bool { defaults.bool(forKey: "editor.focusMode") }
  var typewriterEnabled: Bool { defaults.bool(forKey: "editor.typewriterMode") }

  /// 局部更新：只写入传入的键，随后广播给所有已打开的编辑器窗口。
  func set(focus: Bool? = nil, typewriter: Bool? = nil) {
    if let focus { defaults.set(focus, forKey: "editor.focusMode") }
    if let typewriter { defaults.set(typewriter, forKey: "editor.typewriterMode") }
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }

  func script() throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["focus": focusEnabled, "typewriter": typewriterEnabled])
    guard let json = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return "window.inkpotMVP.setDisplayModes(\(json))"
  }

  @objc func toggleFocusMode(_ sender: Any?) { set(focus: !focusEnabled) }

  @objc func toggleTypewriterMode(_ sender: Any?) { set(typewriter: !typewriterEnabled) }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(toggleFocusMode(_:)) { menuItem.state = focusEnabled ? .on : .off }
    if menuItem.action == #selector(toggleTypewriterMode(_:)) { menuItem.state = typewriterEnabled ? .on : .off }
    return true
  }
}

extension EditorViewController {
  @objc func updateDisplayModes() {
    guard isReady else { return }
    Task { @MainActor in
      do { _ = try await evaluateScript(DisplayModes.shared.script() + "; null") } catch {
        if view.window != nil { presentError(error) }
      }
    }
  }
}
