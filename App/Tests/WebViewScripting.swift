import AppKit
import WebKit

// WebKit 会以 InvalidTransition 拒绝与进行中求值并发的脚本调用，编辑器自身的脚本在
// EditorViewController.evaluateScript 中排队。测试脚本经同一队列执行，避免与编辑器的
// 求值并发而偶发失败；不属于编辑器的 WKWebView（如图片阅读页）仍直接求值。
extension WKWebView {
  @MainActor
  func evaluateQueued(_ javaScript: String) async throws -> Any? {
    if let editor = navigationDelegate as? EditorViewController { return try await editor.evaluateScript(javaScript) }
    return try await evaluateJavaScript(javaScript)
  }
}
