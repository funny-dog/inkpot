import AppKit

struct DocumentHeading: Decodable, Equatable {
  let id: Int
  let from: Int
  let to: Int
  let level: Int
  let title: String
}

final class OutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  final class Item: NSObject {
    var heading: DocumentHeading
    var children: [Item] = []
    weak var parent: Item?

    init(_ heading: DocumentHeading) { self.heading = heading }
  }

  var onNavigate: ((Int) -> Void)?
  let outlineView = NSOutlineView()
  private let scrollView = NSScrollView()
  private let emptyState = SidebarEmptyState(symbol: "list.bullet.indent", title: "还没有标题", message: "以 # 开头的行会作为标题列在这里，点击即可跳转。")
  private var active: Int?
  private var roots: [Item] = []
  private var items: [Int: Item] = [:]
  private var headings: [DocumentHeading] = []

  override func loadView() {
    view = NSView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.rowHeight = 28
    outlineView.indentationPerLevel = 14
    outlineView.style = .sourceList
    outlineView.setAccessibilityLabel("标题大纲")
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.target = self
    outlineView.action = #selector(navigate(_:))
    outlineView.doubleAction = #selector(navigate(_:))
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    emptyState.pin(in: view, centeredOn: scrollView)
  }

  func update(_ headings: [DocumentHeading]?, active: Int?) {
    _ = view
    let activeChanged = self.active != active
    self.active = active
    if let headings, headings != self.headings { rebuild(headings) }
    var selected = active.flatMap { items[$0] }
    while let item = selected, outlineView.row(forItem: item) < 0 {
      selected = item.parent
    }
    if let selected {
      let row = outlineView.row(forItem: selected)
      outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      if activeChanged { outlineView.scrollRowToVisible(row) }
    } else {
      outlineView.deselectAll(nil)
    }
  }

  func reset() {
    roots = []
    items = [:]
    headings = []
    update([], active: nil)
    outlineView.reloadData()
    emptyState.isHidden = false
  }

  private func rebuild(_ headings: [DocumentHeading]) {
    let previous = items
    let collapsed = Set(items.values.filter { !$0.children.isEmpty && !outlineView.isItemExpanded($0) }.map { $0.heading.id })
    let origin = scrollView.contentView.bounds.origin
    let structureChanged = self.headings.map { [$0.id, $0.level] } != headings.map { [$0.id, $0.level] }
    self.headings = headings
    roots = []
    items = [:]
    var stack: [Item] = []
    var renamed: [Item] = []
    for heading in headings {
      let item = previous[heading.id] ?? Item(heading)
      if item.heading.title != heading.title { renamed.append(item) }
      item.heading = heading
      item.children = []
      while let parent = stack.last, parent.heading.level >= heading.level { stack.removeLast() }
      item.parent = stack.last
      if let parent = stack.last { parent.children.append(item) } else { roots.append(item) }
      stack.append(item)
      items[heading.id] = item
    }
    if structureChanged {
      outlineView.reloadData()
      for heading in headings where !collapsed.contains(heading.id) {
        if let item = items[heading.id] { outlineView.expandItem(item) }
      }
    } else {
      for item in renamed { outlineView.reloadItem(item) }
    }
    scrollView.contentView.scroll(to: origin)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    emptyState.isHidden = !headings.isEmpty
  }

  @objc private func navigate(_ sender: Any?) {
    guard let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else { return }
    onNavigate?(item.heading.id)
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? Item)?.children.count ?? roots.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    ((item as? Item)?.children ?? roots)[index]
  }

  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? Item)?.children.isEmpty == false
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let item = item as? Item else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("heading")
    let label = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarLabel ?? SidebarLabel(labelWithString: "")
    label.identifier = identifier
    label.stringValue = item.heading.title
    label.toolTip = "H\(item.heading.level) · \(item.heading.title)"
    label.lineBreakMode = .byTruncatingTail
    label.baseWeight = item.heading.level == 1 ? .semibold : .regular
    label.baseColor = item.heading.level >= 3 ? .secondaryLabelColor : .labelColor
    label.setAccessibilityLabel("\(item.heading.level)级标题，\(item.heading.title)")
    return label
  }
}
