import AppKit

/// 全局字体偏好：正文与代码分别保存字体与字号，所有文档窗口即时同步。
@MainActor
final class EditorFonts: NSObject {
  static let shared = EditorFonts()
  static let didChange = Notification.Name("InkpotEditorFontsDidChange")
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    super.init()
  }

  func font(code: Bool) -> NSFont {
    let prefix = code ? "editor.codeFont" : "editor.bodyFont"
    let storedSize = defaults.double(forKey: prefix + "Size")
    let size = storedSize.isFinite && (8...72).contains(storedSize) ? storedSize : 15
    if let name = defaults.string(forKey: prefix + "Name"), let font = NSFont(name: name, size: size) { return font }
    return code ? NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
  }

  func setFont(_ font: NSFont, code: Bool) {
    guard font.pointSize.isFinite, (8...72).contains(font.pointSize) else { return }
    let prefix = code ? "editor.codeFont" : "editor.bodyFont"
    defaults.set(font.fontName, forKey: prefix + "Name")
    defaults.set(font.pointSize, forKey: prefix + "Size")
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }

  func script() throws -> String {
    let body = font(code: false)
    let code = font(code: true)
    let values: [String: Any] = [
      "bodyFamily": body.familyName == NSFont.systemFont(ofSize: 15).familyName ? "" : body.familyName ?? body.fontName,
      "bodySize": body.pointSize, "codeFamily": code.familyName ?? code.fontName, "codeSize": code.pointSize,
    ]
    let data = try JSONSerialization.data(withJSONObject: values)
    guard let json = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
    return "window.inkpot.setFonts(\(json))"
  }

  /// 已保存的字体家族；nil 表示默认（正文为系统字体，代码为 Menlo）。
  func family(code: Bool) -> String? {
    guard let name = defaults.string(forKey: (code ? "editor.codeFont" : "editor.bodyFont") + "Name"),
          NSFont(name: name, size: 13) != nil else { return nil }
    return font(code: code).familyName
  }

  /// 按家族的常规字重保存；nil 恢复默认字体，字号保持不变。
  func setFamily(_ family: String?, code: Bool) {
    let size = font(code: code).pointSize
    guard let family else {
      defaults.removeObject(forKey: (code ? "editor.codeFont" : "editor.bodyFont") + "Name")
      NotificationCenter.default.post(name: Self.didChange, object: self)
      return
    }
    let manager = NSFontManager.shared
    let regular = manager.font(withFamily: family, traits: [], weight: 5, size: size)
      ?? manager.availableMembers(ofFontFamily: family)?.first.flatMap { $0.first as? String }.flatMap { NSFont(name: $0, size: size) }
    if let regular { setFont(regular, code: code) }
  }

  func setSize(_ size: Double, code: Bool) {
    let current = font(code: code)
    if family(code: code) == nil {
      guard size.isFinite, (8...72).contains(size) else { return }
      defaults.set(size, forKey: (code ? "editor.codeFont" : "editor.bodyFont") + "Size")
      NotificationCenter.default.post(name: Self.didChange, object: self)
    } else if let resized = NSFont(name: current.fontName, size: size) {
      setFont(resized, code: code)
    }
  }

  /// 设置窗口的候选家族：正文列出全部已安装字体，代码只列等宽字体；首次使用时计算一次。
  static let bodyFamilies = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
  static let codeFamilies = bodyFamilies.filter { family in
    NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
  }

  /// 显示 → 字体与字号…：打开设置窗口的外观分类，在页内直接选择。
  @objc func showFontSettings(_ sender: Any?) {
    SettingsWindowController.shared.show(.appearance)
    SettingsWindowController.shared.showSettings(sender)
  }

  @objc func resetFonts(_ sender: Any?) {
    for key in ["editor.bodyFontName", "editor.bodyFontSize", "editor.codeFontName", "editor.codeFontSize"] { defaults.removeObject(forKey: key) }
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }
}

extension EditorViewController {
  @objc func updateFonts() {
    guard isReady else { return }
    Task { @MainActor in
      do { _ = try await evaluateScript(EditorFonts.shared.script() + "; null") } catch {
        if view.window != nil { presentError(error) }
      }
    }
  }
}
