import AppKit

extension NSColor {
  /// 应用强调色：浅色墨蓝 #2b5a8c，深色 #7cb0e8，与编辑器链接色一致。
  static let inkpotAccent = NSColor(name: "inkpotAccent") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 0x7C / 255.0, green: 0xB0 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
      : NSColor(srgbRed: 0x2B / 255.0, green: 0x5A / 255.0, blue: 0x8C / 255.0, alpha: 1)
  }
}

private extension NSView {
  var isDarkAppearance: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// 侧栏顶部的“文件 / 大纲 / 搜索”切换：浅灰底槽配白色滑块，按设计稿自绘；读屏按单选按钮组朗读。
final class SidebarTabBar: NSView {
  var onSelect: ((Int) -> Void)?
  private(set) var selectedIndex = 0
  private var buttons: [Tab] = []

  final class Tab: NSButton {
    var isChosen = false { didSet { refresh() } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
      layer?.cornerRadius = 5
      layer?.backgroundColor = isChosen ? (isDarkAppearance ? NSColor(white: 0.24, alpha: 1) : .white).cgColor : NSColor.clear.cgColor
      layer?.shadowOpacity = isChosen ? 1 : 0
      layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
      layer?.shadowOffset = CGSize(width: 0, height: -1)
      layer?.shadowRadius = 1
    }

    func refresh() {
      attributedTitle = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: isChosen ? .semibold : .medium),
        .foregroundColor: isChosen ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
      setAccessibilityValue(isChosen)
      needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      needsDisplay = true
    }
  }

  init(titles: [String]) {
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.radioGroup)
    let stack = NSStackView()
    stack.distribution = .fillEqually
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    for (index, title) in titles.enumerated() {
      let tab = Tab(title: title, target: self, action: #selector(choose(_:)))
      tab.tag = index
      tab.isBordered = false
      tab.wantsLayer = true
      tab.setAccessibilityRole(.radioButton)
      tab.heightAnchor.constraint(equalToConstant: 24).isActive = true
      tab.refresh()
      buttons.append(tab)
      stack.addArrangedSubview(tab)
    }
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
    ])
    select(0)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("使用 init(titles:) 初始化侧栏切换") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.cornerRadius = 7
    layer?.backgroundColor = (isDarkAppearance ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.06)).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  var titles: [String] { buttons.map(\.title) }

  func select(_ index: Int) {
    selectedIndex = index
    for button in buttons { button.isChosen = button.tag == index }
  }

  @objc private func choose(_ sender: NSButton) {
    select(sender.tag)
    onSelect?(sender.tag)
  }
}

/// 侧栏行内文字：记住未选中时的颜色与字重，所在行成为当前项时换成强调色并加粗。
final class SidebarLabel: NSTextField {
  /// 文件树与大纲共用的字号与行高。
  static let fontSize: CGFloat = 15
  static let rowHeight: CGFloat = 34

  /// 侧栏单元格：可选图标加文字，二者在行内垂直居中；行高变化时不需要重新计算坐标。
  static func cell(identifier: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let text = SidebarLabel(labelWithString: "")
    text.refresh()
    text.translatesAutoresizingMaskIntoConstraints = false
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    cell.addSubview(text)
    cell.textField = text
    var constraints = [
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
    ]
    if icon {
      let image = NSImageView()
      image.contentTintColor = .secondaryLabelColor
      image.symbolConfiguration = .init(pointSize: fontSize, weight: .regular)
      image.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(image)
      cell.imageView = image
      constraints += [
        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        image.widthAnchor.constraint(equalToConstant: 20),
        image.heightAnchor.constraint(equalToConstant: 20),
        text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
      ]
    } else {
      constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
    }
    NSLayoutConstraint.activate(constraints)
    return cell
  }

  var baseColor: NSColor = .labelColor { didSet { refresh() } }
  var baseWeight: NSFont.Weight = .regular { didSet { refresh() } }
  var isCurrent = false { didSet { if oldValue != isCurrent { refresh() } } }

  func refresh() {
    textColor = isCurrent ? .inkpotAccent : baseColor
    font = .systemFont(ofSize: Self.fontSize, weight: isCurrent ? .semibold : baseWeight)
  }
}

/// 侧栏选中行：两侧留 10 点的圆角浅色强调底，代替系统灰色/蓝色选中条，与设计稿一致。
final class SidebarRowView: NSTableRowView {
  override var isSelected: Bool {
    didSet {
      for label in labels(in: self) { label.isCurrent = isSelected }
      needsDisplay = true
    }
  }

  // 选中后不让系统把行内文字切换成反白。
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

  override func drawSelection(in dirtyRect: NSRect) {
    let alpha = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.16 : 0.12
    NSColor.inkpotAccent.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    for label in labels(in: subview) { label.isCurrent = isSelected }
  }

  private func labels(in view: NSView) -> [SidebarLabel] {
    if let label = view as? SidebarLabel { return [label] }
    return view.subviews.flatMap { labels(in: $0) }
  }
}
