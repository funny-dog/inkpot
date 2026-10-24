import AppKit
import SwiftUI
import WebKit

/// 外观偏好：跟随系统或固定浅色／深色。设置 NSApp.appearance 后窗口与 WKWebView 的
/// prefers-color-scheme 一并变化，编辑器页面内的深浅色自检测随之切换，导出仍固定浅色。
enum AppearanceMode: String, CaseIterable {
  case system, light, dark

  var appearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

/// 设置窗口收纳的偏好；字体沿用 EditorFonts，拼写检查沿用 WebKit 自己保存的设置。
@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  static let editingDidChange = Notification.Name("InkpotEditingPreferencesDidChange")
  nonisolated static let defaultImageFolder = "assets"
  private let defaults: UserDefaults
  private lazy var displayModes = DisplayModes(defaults: defaults)
  private lazy var zoom = EditorZoom(defaults: defaults)
  private var observers: [NSObjectProtocol] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // 字体面板与菜单也会改这些偏好，设置窗口打开时同步刷新。
    for (name, object) in [(EditorFonts.didChange, nil), (DisplayModes.didChange, nil), (EditorZoom.didChange, nil), (UserDefaults.didChangeNotification, defaults as AnyObject?)] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.objectWillChange.send() }
      })
    }
  }

  /// 保持原有启动行为；从访达打开指定文件时始终优先打开该文件。
  var restorePreviousSession: Bool {
    get { defaults.object(forKey: "startup.restorePreviousSession") as? Bool ?? true }
    set { objectWillChange.send(); defaults.set(newValue, forKey: "startup.restorePreviousSession") }
  }

  var focusMode: Bool {
    get { displayModes.focusEnabled }
    set { objectWillChange.send(); displayModes.set(focus: newValue) }
  }

  var typewriterMode: Bool {
    get { displayModes.typewriterEnabled }
    set { objectWillChange.send(); displayModes.set(typewriter: newValue) }
  }

  var zoomLevel: Double {
    get { zoom.level }
    set { objectWillChange.send(); zoom.level = newValue }
  }

  var zoomWithCommandScroll: Bool {
    get { zoom.commandScroll }
    set { objectWillChange.send(); zoom.commandScroll = newValue }
  }

  /// 文件树显示范围：所有文件或仅支持的文件，及是否显示隐藏项；修改后已打开的文件树立即刷新。
  var fileTreeShowsAllFiles: Bool {
    get { defaults.bool(forKey: "fileTree.allFiles") }
    set { setFileTreePreference(newValue, key: "fileTree.allFiles") }
  }

  var fileTreeShowsHidden: Bool {
    get { defaults.bool(forKey: "fileTree.hidden") }
    set { setFileTreePreference(newValue, key: "fileTree.hidden") }
  }

  var fileTreeFilter: FileTree.Filter { FileTree.Filter(allFiles: fileTreeShowsAllFiles, hidden: fileTreeShowsHidden) }

  private func setFileTreePreference(_ value: Bool, key: String) {
    objectWillChange.send()
    defaults.set(value, forKey: key)
    NotificationCenter.default.post(name: FileTree.filterDidChange, object: self)
  }

  /// 打开文档时默认进入源码模式；默认实时模式。
  var defaultSourceMode: Bool {
    get { defaults.bool(forKey: "editor.defaultSourceMode") }
    set { objectWillChange.send(); defaults.set(newValue, forKey: "editor.defaultSourceMode") }
  }

  var appearanceMode: AppearanceMode {
    get { defaults.string(forKey: "appearance.mode").flatMap(AppearanceMode.init) ?? .system }
    set {
      objectWillChange.send()
      defaults.set(newValue.rawValue, forKey: "appearance.mode")
      applyAppearance()
    }
  }

  func applyAppearance() { NSApp.appearance = appearanceMode.appearance }

  /// 编辑后自动保存：只对已保存过的文档生效，默认关闭（手动保存加本地恢复草稿）。
  var autosave: Bool {
    get { defaults.bool(forKey: "document.autosave") }
    set { objectWillChange.send(); defaults.set(newValue, forKey: "document.autosave") }
  }

  var pairBrackets: Bool {
    get { defaults.object(forKey: "editor.pairBrackets") as? Bool ?? true }
    set { setEditingPreference(newValue, key: "editor.pairBrackets") }
  }

  var pairMarkdown: Bool {
    get { defaults.object(forKey: "editor.pairMarkdown") as? Bool ?? true }
    set { setEditingPreference(newValue, key: "editor.pairMarkdown") }
  }

  var loadRemoteImages: Bool {
    get { defaults.bool(forKey: "images.loadRemote") }
    set { setEditingPreference(newValue, key: "images.loadRemote") }
  }

  /// Tab 缩进的空格数，只提供 2 与 4；其他值回退为 2。
  var indentWidth: Int {
    get { defaults.integer(forKey: "editor.indentWidth") == 4 ? 4 : 2 }
    set { setEditingPreference(newValue == 4 ? 4 : 2, key: "editor.indentWidth") }
  }

  private func setEditingPreference(_ value: Any, key: String) {
    objectWillChange.send()
    defaults.set(value, forKey: key)
    NotificationCenter.default.post(name: Self.editingDidChange, object: self)
  }

  func editingScript() throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["brackets": pairBrackets, "markdown": pairMarkdown, "remoteImages": loadRemoteImages, "indent": indentWidth])
    guard let json = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
    return "window.inkpot.setEditingPreferences(\(json))"
  }

  var documentImageFolder: Bool {
    get { defaults.bool(forKey: "images.documentFolder") }
    set { objectWillChange.send(); defaults.set(newValue, forKey: "images.documentFolder") }
  }

  /// 在设置中选择的图片文件夹（绝对路径）；未选择时使用文档同级的默认文件夹。
  var customImageFolder: URL? {
    get { defaults.string(forKey: "images.customFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
    set { objectWillChange.send(); defaults.set(newValue?.standardizedFileURL.path, forKey: "images.customFolder") }
  }

  /// 返回相对文档所在文件夹的图片目录，同时用作写入位置与 Markdown 中的引用路径。
  func imageFolder(beside url: URL) -> String {
    guard documentImageFolder else {
      guard let customImageFolder else { return imageFolder }
      return Self.relativePath(from: url.deletingLastPathComponent(), to: customImageFolder)
    }
    let name = Self.validImageFolder(String(url.deletingPathExtension().lastPathComponent.prefix(48))) ?? "文档"
    return name + ".assets"
  }

  /// 输入时检查拼写：WebKit 进程内全局生效并自行保存，通过任一编辑器的标准动作切换；没有打开的编辑器时直接写入偏好。
  var spellChecking: Bool {
    get { defaults.bool(forKey: "WebContinuousSpellCheckingEnabled") }
    set {
      guard newValue != spellChecking else { return }
      objectWillChange.send()
      let webView = NSDocumentController.shared.documents.lazy.compactMap { ($0 as? InkpotDocument)?.editor?.view as? WKWebView }.first
      if let webView { NSApp.sendAction(#selector(NSTextView.toggleContinuousSpellChecking(_:)), to: webView, from: nil) }
      defaults.set(newValue, forKey: "WebContinuousSpellCheckingEnabled")
    }
  }

  /// 输入框中的原始文字；实际使用前经 imageFolder 校验。
  var imageFolderInput: String {
    get { defaults.string(forKey: "images.folderName") ?? Self.defaultImageFolder }
    set { objectWillChange.send(); defaults.set(newValue, forKey: "images.folderName") }
  }

  /// 图片保存在文档同级的单层文件夹；空白、含路径分隔符、以点开头等无效名称回退为 assets。
  var imageFolder: String { Self.validImageFolder(imageFolderInput) ?? Self.defaultImageFolder }

  /// 两个文件夹之间的相对路径，例如 ../图片/博客；同一文件夹返回“.”。
  nonisolated static func relativePath(from base: URL, to target: URL) -> String {
    let from = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let to = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    var common = 0
    while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
    let parts = Array(repeating: "..", count: from.count - common) + to[common...]
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }

  nonisolated static func validImageFolder(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.hasPrefix("."),
          trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)) == nil else { return nil }
    return trimmed
  }

  func fontDescription(code: Bool) -> String {
    let font = EditorFonts.shared.font(code: code)
    return "\(font.displayName ?? font.fontName) \(Int(font.pointSize.rounded())) 点"
  }
}

/// 设置分类：与窗口工具栏的三个图标一一对应。
enum SettingsPane: String, CaseIterable {
  case general, editing, appearance

  var title: String {
    switch self {
    case .general: "通用"
    case .editing: "编辑"
    case .appearance: "外观"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .editing: "square.and.pencil"
    case .appearance: "circle.lefthalf.filled"
    }
  }
}

/// 说明文字统一为次要色小字。
private struct Caption: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

/// 通用：启动、保存与图片。
struct GeneralSettingsView: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Picker("启动时", selection: $settings.restorePreviousSession) {
          Text("恢复上次的文件和窗口").tag(true)
          Text("新建空白文档").tag(false)
        }
      } header: { Text("启动") } footer: {
        Caption("下次启动生效。从访达打开文件时优先打开指定文件；未保存草稿仍会提示恢复。")
      }
      Section {
        Picker("文件树", selection: $settings.fileTreeShowsAllFiles) {
          Text("支持的文件（Markdown 和纯文本）").tag(false)
          Text("所有文件").tag(true)
        }
        Toggle("显示隐藏的文件夹／文件", isOn: $settings.fileTreeShowsHidden)
      } header: { Text("文件树") } footer: {
        Caption("Markdown 和纯文本在 Inkpot 中打开，其他文件使用系统默认应用打开。")
      }
      Section("保存") {
        Toggle(isOn: $settings.autosave) {
          Text("编辑后自动保存")
          Text("仅对已保存过的文档生效，停止输入约 2 秒后保存。")
        }
      }
      Section {
        Picker("素材目录", selection: $settings.documentImageFolder) {
          Text("共享文件夹").tag(false)
          Text("文档名.assets").tag(true)
        }
        if !settings.documentImageFolder {
          LabeledContent("图片保存文件夹") {
            Text(settings.customImageFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "文档同级的 \(settings.imageFolder)")
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Button("选择…") { chooseImageFolder() }
            if settings.customImageFolder != nil {
              Button("恢复默认") { settings.customImageFolder = nil }
            }
          }
        }
        Toggle("加载远程图片（HTTPS）", isOn: $settings.loadRemoteImages)
      } header: { Text("图片") } footer: {
        Caption(settings.documentImageFolder ? "新插入的图片保存到文档同级的“文档名.assets”；不会迁移原有图片。"
          : settings.customImageFolder == nil
          ? "插入或粘贴的图片保存在文档同级的“\(settings.imageFolder)”文件夹中。"
          : "插入或粘贴的图片保存到所选文件夹，文档中写入相对路径。")
        Caption("远程图片默认不加载；开启后会向图片所在网站发出请求，不发送 Cookie。不支持远程 SVG。")
      }
      Section("关于") {
        LabeledContent("版本", value: ThirdPartyNotices.version)
        LabeledContent("第三方许可") {
          Button("查看…") { ThirdPartyNotices.show() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: SettingsWindowController.contentWidth, height: SettingsWindowController.contentHeight)
  }
}

extension GeneralSettingsView {
  /// 系统文件夹面板选择图片目录，可直接新建文件夹。
  func chooseImageFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "选择"
    panel.message = "选择插入或粘贴图片时保存的文件夹"
    panel.directoryURL = settings.customImageFolder
    if panel.runModal() == .OK, let url = panel.url { settings.customImageFolder = url }
  }
}

/// 编辑：默认模式与写作辅助。
struct EditingSettingsView: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      Section("打开文档") {
        Picker("默认模式", selection: $settings.defaultSourceMode) {
          Text("实时模式").tag(false)
          Text("源码模式").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
      }
      Section {
        Picker("缩进宽度", selection: $settings.indentWidth) {
          Text("2 个空格").tag(2)
          Text("4 个空格").tag(4)
        }
      } header: { Text("缩进") } footer: {
        Caption("Tab 缩进、⇧Tab 取消缩进；列表项按层级整行缩进。")
      }
      Section("写作辅助") {
        Toggle("自动配对括号与引号", isOn: $settings.pairBrackets)
        Toggle("自动配对 Markdown 字符", isOn: $settings.pairMarkdown)
        Toggle("输入时检查拼写", isOn: $settings.spellChecking)
        Toggle(isOn: $settings.focusMode) {
          Text("专注模式")
          Text("突出当前编辑的段落或内容块。（F8）")
        }
        Toggle(isOn: $settings.typewriterMode) {
          Text("打字机模式")
          Text("编辑时让当前行保持在窗口中部。（F9）")
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: SettingsWindowController.contentWidth, height: SettingsWindowController.contentHeight)
  }
}

/// 外观：深浅色缩略图选择、正文与代码字体及预览。
struct AppearanceSettingsView: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      Section("外观") {
        HStack(spacing: 12) {
          ForEach(AppearanceMode.allCases, id: \.self) { mode in
            AppearanceSwatch(mode: mode, selected: settings.appearanceMode == mode) { settings.appearanceMode = mode }
          }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("外观")
      }
      Section {
        HStack {
          Picker("缩放", selection: $settings.zoomLevel) {
            ForEach(EditorZoom.levels, id: \.self) { level in Text("\(Int((level * 100).rounded()))%").tag(level) }
          }
          Button("重置") { settings.zoomLevel = 1 }
            .disabled(settings.zoomLevel == 1)
        }
        Toggle("按住 Command 时使用鼠标滚轮缩放", isOn: $settings.zoomWithCommandScroll)
      } header: { Text("缩放") } footer: {
        Caption("也可使用 显示 → 实际大小 ⌘0／放大 ⌘+／缩小 ⌘−，所有窗口同步。")
      }
      Section {
        LabeledContent("正文") {
          Text(settings.fontDescription(code: false)).foregroundStyle(.secondary)
          Button("选择…") { EditorFonts.shared.showBodyFont(nil) }
        }
        LabeledContent("代码") {
          Text(settings.fontDescription(code: true)).foregroundStyle(.secondary)
          Button("选择…") { EditorFonts.shared.showCodeFont(nil) }
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("落笔成文，墨在纸上。").font(Font(EditorFonts.shared.font(code: false)))
          Text("let ink = \"Inkpot\"").font(Font(EditorFonts.shared.font(code: true))).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityLabel("字体预览")
      } header: { Text("字体") } footer: {
        HStack {
          Spacer()
          Button("恢复默认字体") { EditorFonts.shared.resetFonts(nil) }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: SettingsWindowController.contentWidth, height: SettingsWindowController.contentHeight)
  }
}

/// 外观缩略图：跟随系统为左浅右深，选中时外圈描强调色；读屏按单选按钮朗读。
private struct AppearanceSwatch: View {
  let mode: AppearanceMode
  let selected: Bool
  let action: () -> Void
  private let light = Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF5 / 255)
  private let dark = Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x22 / 255)

  var title: String {
    switch mode {
    case .system: "跟随系统"
    case .light: "浅色"
    case .dark: "深色"
    }
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        HStack(spacing: 0) {
          if mode != .dark { light }
          if mode != .light { dark }
        }
        .frame(height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
        Text(title).font(.system(size: 12))
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// Inkpot → 设置…（⌘,）：工具栏式分类的单例窗口，关闭后保留以便再次打开时位置与分类不变。
@MainActor
final class SettingsWindowController: NSWindowController {
  static let shared = SettingsWindowController()
  static let contentWidth: CGFloat = 520
  /// 各分类共用的固定高度；内容超出时在页内滚动，窗口不随分类伸缩，也不能拖动改变大小。
  static let contentHeight: CGFloat = 520
  let tabs = NSTabViewController()

  private init() {
    tabs.tabStyle = .toolbar
    let settings = AppSettings.shared
    for pane in SettingsPane.allCases {
      let root: AnyView = switch pane {
      case .general: AnyView(GeneralSettingsView(settings: settings))
      case .editing: AnyView(EditingSettingsView(settings: settings))
      case .appearance: AnyView(AppearanceSettingsView(settings: settings))
      }
      let hosting = NSHostingController(rootView: root)
      hosting.sizingOptions = [.preferredContentSize]
      hosting.title = pane.title
      let item = NSTabViewItem(viewController: hosting)
      item.label = pane.title
      item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
      item.identifier = pane.rawValue
      tabs.addTabViewItem(item)
    }
    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("InkpotSettings")
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("使用 shared 打开设置窗口") }

  var selectedPane: SettingsPane { SettingsPane.allCases[max(tabs.selectedTabViewItemIndex, 0)] }

  func show(_ pane: SettingsPane) { tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: pane) ?? 0 }

  @objc func showSettings(_ sender: Any?) {
    if window?.isVisible != true { window?.center() }
    showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
  }
}

/// 编辑后自动保存：停止输入一段时间后对已保存过的文档执行普通保存，沿用外部修改保护与字节保真。
/// 组合输入期间推迟；保存失败后暂停该文档的自动保存并提示一次，直到下一次保存成功。
@MainActor
final class DocumentAutosave {
  static var delay: Duration = .seconds(2)
  private weak var document: InkpotDocument?
  private let isEnabled: @MainActor () -> Bool
  private let report: @MainActor (InkpotDocument, NSError) -> Void
  private var task: Task<Void, Never>?
  private(set) var suspended = false

  init(
    document: InkpotDocument,
    isEnabled: @escaping @MainActor () -> Bool = { AppSettings.shared.autosave },
    report: @escaping @MainActor (InkpotDocument, NSError) -> Void = DocumentAutosave.presentOnWindow
  ) {
    self.document = document
    self.isEnabled = isEnabled
    self.report = report
  }

  /// 以文档窗口的表单提示，不打断其他窗口；没有窗口时退回普通提示。
  static func presentOnWindow(_ document: InkpotDocument, _ error: NSError) {
    if let window = document.windowForSheet {
      document.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    } else {
      document.presentError(error)
    }
  }

  func schedule() {
    guard isEnabled(), !suspended else { return }
    task?.cancel()
    task = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.delay)
      guard !Task.isCancelled else { return }
      await self?.saveNow()
    }
  }

  func saveNow() async {
    guard isEnabled(), !suspended, let document, let url = document.fileURL, let type = document.fileType,
          document.isDocumentEdited, document.editor?.isReady == true else { return }
    if document.editor?.isComposing == true {
      schedule()
      return
    }
    do {
      try await document.synchronize()
      guard document.isDocumentEdited else { return }
      try await document.save(to: url, ofType: type, for: .saveOperation)
    } catch {
      suspended = true
      let message = (error as NSError).localizedDescription
      report(document, NSError(domain: "Inkpot", code: 60, userInfo: [
        NSLocalizedDescriptionKey: "自动保存已暂停：\(message)",
        NSLocalizedRecoverySuggestionErrorKey: "当前内容仍保留在窗口中，请手动保存或另存为；保存成功后恢复自动保存。",
      ]))
    }
  }

  func saved() { suspended = false }

  func cancel() { task?.cancel() }
}
