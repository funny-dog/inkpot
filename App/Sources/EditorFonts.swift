import AppKit

/// 全局显示偏好：复用系统字体面板，所有文档窗口即时同步。
@MainActor
final class EditorFonts: NSObject {
  static let shared = EditorFonts()
  static let didChange = Notification.Name("InkpotEditorFontsDidChange")
  private let defaults: UserDefaults
  private var editingCode = false

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

  @objc func showBodyFont(_ sender: Any?) { showFont(code: false, sender: sender) }
  @objc func showCodeFont(_ sender: Any?) { showFont(code: true, sender: sender) }

  private func showFont(code: Bool, sender: Any?) {
    editingCode = code
    let manager = NSFontManager.shared
    manager.target = self
    manager.action = #selector(changeFont(_:))
    manager.setSelectedFont(font(code: code), isMultiple: false)
    NSFontPanel.shared.title = code ? "代码字体与字号" : "正文字体与字号"
    manager.orderFrontFontPanel(sender)
  }

  @objc func changeFont(_ sender: NSFontManager) {
    setFont(sender.convert(font(code: editingCode)), code: editingCode)
  }

  @objc func resetFonts(_ sender: Any?) {
    for key in ["editor.bodyFontName", "editor.bodyFontSize", "editor.codeFontName", "editor.codeFontSize"] { defaults.removeObject(forKey: key) }
    NSFontManager.shared.setSelectedFont(font(code: editingCode), isMultiple: false)
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
