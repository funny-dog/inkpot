import Foundation

private final class LocalizationBundleToken: NSObject {}

enum L10n {
  private static let bundle = Bundle(for: LocalizationBundleToken.self)

  static var language: String {
    bundle.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
  }

  static func text(_ key: String, _ arguments: CVarArg...) -> String {
    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
  }
}
