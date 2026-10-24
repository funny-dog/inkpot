import Foundation

/// WebKit 从应用偏好读取输入检查设置。默认开启“输入时检查拼写”，关闭会改写 Markdown 原文的
/// 自动纠正、智能引号、智能破折号、文本替换与链接识别；用户通过菜单切换后由 WebKit 自行保存。
enum TextChecking {
  static let defaults: [String: Any] = [
    "WebContinuousSpellCheckingEnabled": true,
    "WebGrammarCheckingEnabled": false,
    "WebAutomaticSpellingCorrectionEnabled": false,
    "WebAutomaticQuoteSubstitutionEnabled": false,
    "WebAutomaticDashSubstitutionEnabled": false,
    "WebAutomaticTextReplacementEnabled": false,
    "WebAutomaticLinkDetectionEnabled": false,
  ]

  /// 必须在创建第一个 WKWebView 之前调用。
  static func registerDefaults(_ userDefaults: UserDefaults = .standard) {
    userDefaults.register(defaults: defaults)
  }
}
