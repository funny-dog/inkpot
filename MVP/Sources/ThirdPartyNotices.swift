import AppKit

/// 许可原文随应用离线提供，窗口按需创建。
@MainActor
final class ThirdPartyNoticesWindowController: NSWindowController {
  init(bundle: Bundle = Bundle(for: ThirdPartyNoticesWindowController.self)) throws {
    guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "md") else { throw CocoaError(.fileNoSuchFile) }
    let notices = try String(contentsOf: url, encoding: .utf8)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "第三方许可"
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
    text.setAccessibilityLabel("第三方依赖及许可原文")
    scroll.documentView = text
    window.contentView = scroll
    super.init(window: window)
    window.center()
  }

  required init?(coder: NSCoder) { nil }
}
