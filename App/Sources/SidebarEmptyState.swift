import AppKit

/// 侧栏空状态：符号图标、粗体标题、次要说明与可选按钮，文件树、大纲和搜索三页共用一套排版。
final class SidebarEmptyState: NSStackView {
  private let imageView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let messageField = NSTextField(wrappingLabelWithString: "")

  var title: String {
    get { titleField.stringValue }
    set { titleField.stringValue = newValue; updateAccessibility() }
  }

  var message: String {
    get { messageField.stringValue }
    set { messageField.stringValue = newValue; updateAccessibility() }
  }

  init(symbol: String, title: String, message: String, button: NSButton? = nil) {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .centerX
    spacing = 4
    imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
    imageView.contentTintColor = .tertiaryLabelColor
    imageView.setAccessibilityElement(false)
    titleField.font = .systemFont(ofSize: 13, weight: .semibold)
    titleField.alignment = .center
    messageField.font = .systemFont(ofSize: 12)
    messageField.textColor = .secondaryLabelColor
    messageField.alignment = .center
    for view in [imageView, titleField, messageField] { addArrangedSubview(view) }
    setCustomSpacing(10, after: imageView)
    // 说明文字随侧栏宽度换行。
    messageField.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    if let button {
      button.bezelStyle = .rounded
      button.controlSize = .regular
      addArrangedSubview(button)
      setCustomSpacing(14, after: messageField)
    }
    self.title = title
    self.message = message
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("使用 init(symbol:title:message:button:) 初始化空状态") }

  /// 把标题与说明合成一句，VoiceOver 读到空状态时一次读完。
  private func updateAccessibility() {
    titleField.setAccessibilityLabel(message.isEmpty ? title : "\(title)。\(message)")
    messageField.setAccessibilityElement(false)
  }

  /// 放进侧栏页面：水平留边，垂直位于给定参照视图的中线略偏上。
  func pin(in view: NSView, centeredOn reference: NSView) {
    translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(self)
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      centerYAnchor.constraint(equalTo: reference.centerYAnchor, constant: -40),
    ])
  }
}
