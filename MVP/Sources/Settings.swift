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
  nonisolated static let defaultImageFolder = "assets"
  private let defaults: UserDefaults
  private lazy var displayModes = DisplayModes(defaults: defaults)
  private var observers: [NSObjectProtocol] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // 字体面板与菜单也会改这些偏好，设置窗口打开时同步刷新。
    for (name, object) in [(EditorFonts.didChange, nil), (DisplayModes.didChange, nil), (UserDefaults.didChangeNotification, defaults as AnyObject?)] {
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

  /// 输入时检查拼写：WebKit 进程内全局生效并自行保存，通过任一编辑器的标准动作切换；没有打开的编辑器时直接写入偏好。
  var spellChecking: Bool {
    get { defaults.bool(forKey: "WebContinuousSpellCheckingEnabled") }
    set {
      guard newValue != spellChecking else { return }
      objectWillChange.send()
      let webView = NSDocumentController.shared.documents.lazy.compactMap { ($0 as? MVPDocument)?.editor?.view as? WKWebView }.first
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

struct SettingsView: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      Section("启动") {
        Picker("启动时", selection: $settings.restorePreviousSession) {
          Text("恢复上次的文件和窗口").tag(true)
          Text("新建空白文档").tag(false)
        }
        Text("下次启动生效。从访达打开文件时优先打开指定文件；未保存草稿仍会提示恢复。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("字体") {
        LabeledContent("正文") {
          Text(settings.fontDescription(code: false)).foregroundStyle(.secondary)
          Button("选择…") { EditorFonts.shared.showBodyFont(nil) }
        }
        LabeledContent("代码") {
          Text(settings.fontDescription(code: true)).foregroundStyle(.secondary)
          Button("选择…") { EditorFonts.shared.showCodeFont(nil) }
        }
        Button("恢复默认字体") { EditorFonts.shared.resetFonts(nil) }
      }
      Section("编辑") {
        Picker("打开文档时", selection: $settings.defaultSourceMode) {
          Text("实时模式").tag(false)
          Text("源码模式").tag(true)
        }
        Toggle("输入时检查拼写", isOn: $settings.spellChecking)
        Toggle(isOn: $settings.focusMode) {
          Text("专注模式")
          Text("突出当前编辑的段落或内容块。")
        }
        Toggle(isOn: $settings.typewriterMode) {
          Text("打字机模式")
          Text("编辑时让当前行保持在窗口中部。")
        }
        Toggle(isOn: $settings.autosave) {
          Text("编辑后自动保存")
          Text("仅对已保存过的文档生效，停止输入约 2 秒后保存；关闭时仍有本地恢复草稿。")
        }
      }
      Section("外观") {
        Picker("外观", selection: $settings.appearanceMode) {
          Text("跟随系统").tag(AppearanceMode.system)
          Text("浅色").tag(AppearanceMode.light)
          Text("深色").tag(AppearanceMode.dark)
        }
        .pickerStyle(.segmented)
      }
      Section("图片") {
        TextField("图片保存文件夹", text: $settings.imageFolderInput)
        Text(AppSettings.validImageFolder(settings.imageFolderInput) == nil
          ? "名称无效，将使用 \(AppSettings.defaultImageFolder)。不能为空、以点开头或包含 / : 等字符。"
          : "插入或粘贴的图片保存在文档同级的“\(settings.imageFolder)”文件夹中。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 620)
  }
}

/// Inkpot → 设置…（⌘,）：单例窗口，关闭后保留以便再次打开时位置不变。
@MainActor
final class SettingsWindowController: NSWindowController {
  static let shared = SettingsWindowController()

  private init() {
    let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: .shared)))
    window.title = "设置"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("InkpotSettings")
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("使用 shared 打开设置窗口") }

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
  private weak var document: MVPDocument?
  private let isEnabled: @MainActor () -> Bool
  private let report: @MainActor (MVPDocument, NSError) -> Void
  private var task: Task<Void, Never>?
  private(set) var suspended = false

  init(
    document: MVPDocument,
    isEnabled: @escaping @MainActor () -> Bool = { AppSettings.shared.autosave },
    report: @escaping @MainActor (MVPDocument, NSError) -> Void = DocumentAutosave.presentOnWindow
  ) {
    self.document = document
    self.isEnabled = isEnabled
    self.report = report
  }

  /// 以文档窗口的表单提示，不打断其他窗口；没有窗口时退回普通提示。
  static func presentOnWindow(_ document: MVPDocument, _ error: NSError) {
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
