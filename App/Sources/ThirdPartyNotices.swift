import AppKit

/// 许可原文随应用离线提供，从“设置 → 关于”打开只读窗口查看，窗口按需创建。
@MainActor
enum ThirdPartyNotices {
  private static var window: NSWindow?

  static func text(bundle: Bundle = Bundle(for: AppDelegate.self)) throws -> String {
    guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "md") else { throw CocoaError(.fileNoSuchFile) }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// 版本号与构建号，例如“0.1.0（1）”。
  static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    return (info?["CFBundleVersion"] as? String).map { "\(short)（\($0)）" } ?? short
  }

  static func makeWindow(bundle: Bundle = Bundle(for: AppDelegate.self)) throws -> NSWindow {
    let notices = try text(bundle: bundle)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = L10n.text("第三方许可")
    window.minSize = NSSize(width: 480, height: 320)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentLayoutRect)
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    let text = NSTextView(frame: scroll.bounds)
    text.string = notices
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.usesFindBar = true
    text.font = .systemFont(ofSize: NSFont.systemFontSize)
    text.textColor = .textColor
    text.backgroundColor = .textBackgroundColor
    text.textContainerInset = NSSize(width: 16, height: 16)
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityLabel(L10n.text("第三方依赖及许可原文"))
    scroll.documentView = text
    window.contentView = scroll
    window.center()
    return window
  }

  static func show() {
    do {
      if window == nil { window = try makeWindow() }
      window?.makeKeyAndOrderFront(nil)
    } catch {
      NSApp.presentError(error)
    }
  }
}
