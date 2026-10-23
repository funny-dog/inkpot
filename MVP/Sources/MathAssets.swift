import WebKit

/// 公式与图表渲染资源经 inkpot-asset://math/ 从应用包按需提供。
/// 只允许打包的脚本、KaTeX 样式及字体；跨域头让 file:// 页面能够加载 ES 模块和字体。
enum MathAssets {
  private static let fontMimes = ["woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"]

  static func resolve(_ path: String, in bundle: Bundle) -> (data: Data, mime: String)? {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { return nil }
    guard path.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "/" || $0 == "-" || $0 == "_") }) else { return nil }
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    let fileExtension = url.pathExtension.lowercased()
    let directory = path.split(separator: "/").dropLast().joined(separator: "/")
    let mime: String
    if directory.isEmpty, fileExtension == "mjs" {
      mime = "text/javascript"
    } else if name == "katex.min.css" {
      mime = "text/css"
    } else if directory == "fonts", let fontMime = fontMimes[fileExtension] {
      mime = fontMime
    } else {
      return nil
    }
    // 路径已通过白名单校验，直接拼接；Bundle 的子目录查找在测试进程中不可靠。
    guard let resources = bundle.resourceURL, let data = try? Data(contentsOf: resources.appendingPathComponent("math/\(path)"), options: .mappedIfSafe) else { return nil }
    return (data, mime)
  }
}

final class MathAssetHandler: NSObject, WKURLSchemeHandler {
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "inkpot-asset", components.host == "math",
          let path = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding,
          let asset = MathAssets.resolve(path, in: Bundle(for: MathAssetHandler.self)) else {
      urlSchemeTask.didFailWithError(CocoaError(.fileReadUnsupportedScheme))
      return
    }
    let headers = ["Content-Type": asset.mime, "Access-Control-Allow-Origin": "*"]
    guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
      urlSchemeTask.didFailWithError(CocoaError(.fileReadCorruptFile))
      return
    }
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(asset.data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
