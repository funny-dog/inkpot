import AppKit

/// 侧栏“搜索”页：搜索框、状态提示和按文件分组的结果列表。
final class FolderSearchViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  /// 点击某处匹配时交给文档窗口打开并定位。
  var onOpenMatch: ((FolderSearchMatch) -> Void)?
  /// 未打开文件夹时，从空状态直接打开文件夹。
  var onOpenFolder: (() -> Void)?

  /// 搜索范围：当前窗口文件树的根目录。
  var folderURL: URL? {
    didSet {
      guard folderURL != oldValue else { return }
      cancelSearch()
      apply(FolderSearchResult())
      updateStatus()
      if !searchField.stringValue.isEmpty { beginSearch(searchField.stringValue) }
    }
  }

  /// 输入停止后开始搜索的等待时间；测试可缩短。
  var debounceInterval: Duration = .milliseconds(300)

  let searchField = NSSearchField()
  let outlineView = NSOutlineView()
  private(set) var result = FolderSearchResult()
  private(set) var isSearching = false
  private(set) var activeQuery = ""

  private let scrollView = NSScrollView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let emptyLabel = NSTextField(wrappingLabelWithString: "先打开文件夹，再搜索其中的 Markdown 与文本文件")
  private let openButton = NSButton(title: "打开文件夹…", target: nil, action: nil)
  private var groups: [Group] = []
  private var searchTask: Task<Void, Never>?
  private var activeToken: SearchCancellation?

  final class Group: NSObject {
    let file: FolderSearchFile

    init(_ file: FolderSearchFile) {
      self.file = file
    }
  }

  final class MatchItem: NSObject {
    let match: FolderSearchMatch

    init(_ match: FolderSearchMatch) {
      self.match = match
    }
  }

  override func loadView() {
    view = NSView()
    searchField.placeholderString = "在文件夹中搜索"
    searchField.target = self
    searchField.action = #selector(searchFieldChanged(_:))
    searchField.sendsWholeSearchString = false
    searchField.setAccessibilityLabel("在文件夹中搜索")
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.setAccessibilityLabel("搜索状态")
    emptyLabel.alignment = .center
    emptyLabel.textColor = .secondaryLabelColor
    openButton.target = self
    openButton.action = #selector(chooseFolder(_:))
    let empty = NSStackView(views: [emptyLabel, openButton])
    empty.orientation = .vertical
    empty.spacing = 12
    empty.identifier = NSUserInterfaceItemIdentifier("searchEmpty")
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.rowHeight = 24
    outlineView.indentationPerLevel = 10
    outlineView.style = .sourceList
    outlineView.setAccessibilityLabel("搜索结果")
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.target = self
    outlineView.action = #selector(activate(_:))
    outlineView.doubleAction = #selector(activate(_:))
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    for child in [searchField, statusLabel, scrollView, empty] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      empty.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
      empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
    ])
    reloadResults()
    updateStatus()
  }

  func focusSearchField() {
    _ = view
    view.window?.makeFirstResponder(searchField)
  }

  /// 输入停止 `debounceInterval` 后开始搜索；再次输入会取消上一次搜索。
  func beginSearch(_ query: String) {
    cancelSearch()
    activeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let folder = folderURL, !activeQuery.isEmpty else {
      apply(FolderSearchResult())
      updateStatus()
      return
    }
    isSearching = true
    updateStatus()
    let token = SearchCancellation()
    let interval = debounceInterval
    let query = activeQuery
    activeToken = token
    searchTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: interval)
      guard let self, !Task.isCancelled else { return }
      let outcome = await Task.detached(priority: .userInitiated) {
        FolderSearch.search(in: folder, query: query) { token.isCancelled }
      }.value
      guard !Task.isCancelled, self.activeToken === token else { return }
      self.activeToken = nil
      self.isSearching = false
      guard !outcome.cancelled else { return }
      self.apply(outcome)
      self.updateStatus()
    }
  }

  func cancelSearch() {
    searchTask?.cancel()
    searchTask = nil
    activeToken?.cancel()
    activeToken = nil
    isSearching = false
  }

  var statusText: String {
    guard folderURL != nil else { return "未打开文件夹" }
    if isSearching { return "正在搜索…" }
    guard !activeQuery.isEmpty else { return "输入关键词搜索当前文件夹" }
    guard result.matchCount > 0 else { return "没有找到匹配内容" }
    let base = "\(result.files.count) 个文件 · \(result.matchCount) 处匹配"
    return result.truncated ? base + "（已截断，仅显示前 \(FolderSearch.resultLimit) 处）" : base
  }

  private func apply(_ outcome: FolderSearchResult) {
    result = outcome
    groups = outcome.files.map(Group.init)
    reloadResults()
  }

  private func reloadResults() {
    guard isViewLoaded else { return }
    outlineView.reloadData()
    for group in groups { outlineView.expandItem(group) }
  }

  private func updateStatus() {
    guard isViewLoaded else { return }
    let hasFolder = folderURL != nil
    emptyLabel.isHidden = hasFolder
    openButton.isHidden = hasFolder
    searchField.isEnabled = hasFolder
    scrollView.isHidden = !hasFolder
    statusLabel.stringValue = statusText
  }

  @objc private func searchFieldChanged(_ sender: NSSearchField) {
    beginSearch(sender.stringValue)
  }

  @objc private func chooseFolder(_ sender: Any?) {
    onOpenFolder?()
  }

  @objc private func activate(_ sender: Any?) {
    let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
    guard let item = outlineView.item(atRow: row) else { return }
    if let match = item as? MatchItem {
      onOpenMatch?(match.match)
    } else if let group = item as? Group {
      if outlineView.isItemExpanded(group) { outlineView.collapseItem(group) } else { outlineView.expandItem(group) }
    }
  }
}

extension FolderSearchViewController {
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if let group = item as? Group { return group.file.matches.count }
    return item == nil ? groups.count : 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let group = item as? Group else { return groups[index] }
    return MatchItem(group.file.matches[index])
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    item is Group
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    if let group = item as? Group {
      let cell = makeCell(identifier: "searchFile", in: outlineView)
      cell.textField?.font = .boldSystemFont(ofSize: 12)
      cell.textField?.stringValue = group.file.relativePath
      cell.textField?.toolTip = group.file.url.path
      cell.textField?.setAccessibilityLabel("文件 \(group.file.relativePath)，\(group.file.matches.count) 处匹配")
      return cell
    }
    guard let item = item as? MatchItem else { return nil }
    let cell = makeCell(identifier: "searchMatch", in: outlineView)
    cell.textField?.attributedStringValue = Self.attributedMatch(item.match)
    cell.textField?.toolTip = "\(item.match.url.path) 第 \(item.match.line) 行"
    cell.textField?.setAccessibilityLabel("第 \(item.match.line) 行，\(item.match.snippet)")
    return cell
  }

  private func makeCell(identifier: String, in outlineView: NSOutlineView) -> NSTableCellView {
    let identifier = NSUserInterfaceItemIdentifier(identifier)
    if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
      return cell
    }
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.textField = label
    cell.identifier = identifier
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  static func attributedMatch(_ match: FolderSearchMatch) -> NSAttributedString {
    let text = NSMutableAttributedString(string: "\(match.line)  ", attributes: [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ])
    let prefixLength = (text.string as NSString).length
    text.append(NSAttributedString(string: match.snippet, attributes: [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor.labelColor,
    ]))
    let snippetLength = (match.snippet as NSString).length
    let highlight = match.highlight
    if highlight.length > 0, highlight.location >= 0, NSMaxRange(highlight) <= snippetLength {
      text.addAttribute(
        .font,
        value: NSFont.boldSystemFont(ofSize: 12),
        range: NSRange(location: prefixLength + highlight.location, length: highlight.length)
      )
    }
    return text
  }
}

/// 搜索的取消标记：后台任务与界面线程都会读写。
final class SearchCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
