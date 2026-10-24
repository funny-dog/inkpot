import AppKit

@main
enum Application {
  static func main() {
    // 输入检查默认值须在创建第一个 WKWebView 之前注册。
    TextChecking.registerDefaults()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    AppSettings.shared.applyAppearance()
    app.activate(ignoringOtherApps: true)
    app.mainMenu = MainMenu.make(delegate: delegate)
    _ = NSDocumentController.shared
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
