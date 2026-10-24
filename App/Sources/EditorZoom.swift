import AppKit
import WebKit

/// 编辑器页面缩放：全局偏好，菜单（⌘0 / ⌘+ / ⌘−）、设置窗口与按住 Command 滚动滚轮共同调整，所有文档窗口即时同步。
/// 只改变 WKWebView 的 pageZoom，不影响导出与打印（二者使用独立的渲染视图）。
@MainActor
final class EditorZoom: NSObject, NSMenuItemValidation {
  static let shared = EditorZoom()
  static let didChange = Notification.Name("InkpotEditorZoomDidChange")
  static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
  private let defaults: UserDefaults
  private var pendingScroll: CGFloat = 0

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    super.init()
  }

  /// 读取时吸附到最近的档位，避免手改偏好后出现菜单无法回到的中间值。
  var level: Double {
    get {
      let stored = defaults.object(forKey: "editor.zoom") as? Double ?? 1
      return Self.levels.min { abs($0 - stored) < abs($1 - stored) } ?? 1
    }
    set {
      let snapped = Self.levels.min { abs($0 - newValue) < abs($1 - newValue) } ?? 1
      guard snapped != level else { return }
      defaults.set(snapped, forKey: "editor.zoom")
      NotificationCenter.default.post(name: Self.didChange, object: self)
    }
  }

  /// 按住 Command 时用鼠标滚轮缩放，默认关闭，避免与系统辅助功能的缩放手势冲突。
  var commandScroll: Bool {
    get { defaults.bool(forKey: "editor.zoomWithCommandScroll") }
    set { defaults.set(newValue, forKey: "editor.zoomWithCommandScroll") }
  }

  private func step(_ offset: Int) {
    let index = Self.levels.firstIndex(of: level) ?? Self.levels.firstIndex(of: 1) ?? 0
    level = Self.levels[min(max(index + offset, 0), Self.levels.count - 1)]
  }

  @objc func zoomIn(_ sender: Any?) { step(1) }
  @objc func zoomOut(_ sender: Any?) { step(-1) }
  @objc func resetZoom(_ sender: Any?) { level = 1 }

  /// 滚轮事件：触控板的连续增量累计到阈值才换一档，普通鼠标每格换一档；未开启时交还给页面滚动。
  func handleScroll(_ event: NSEvent) -> Bool {
    guard commandScroll, event.modifierFlags.contains(.command) else { return false }
    if event.phase == .began || event.phase == .mayBegin { pendingScroll = 0 }
    pendingScroll += event.scrollingDeltaY
    let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
    if abs(pendingScroll) >= threshold {
      step(pendingScroll > 0 ? 1 : -1)
      pendingScroll = 0
    }
    return true
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(zoomIn(_:)): level < Self.levels.last ?? 2
    case #selector(zoomOut(_:)): level > Self.levels.first ?? 0.5
    case #selector(resetZoom(_:)): level != 1
    default: true
    }
  }
}

extension EditorViewController {
  @objc func updateZoom() {
    (view as? WKWebView)?.pageZoom = EditorZoom.shared.level
  }
}
