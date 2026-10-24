import Foundation

struct DocumentContent {
  var text = ""
  private var hasBOM = false

  init() {}

  init(data: Data) throws {
    hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
    let content = hasBOM ? data.dropFirst(3) : data[...]
    guard let decoded = String(data: content, encoding: .utf8) else {
      throw NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileReadInapplicableStringEncodingError,
        userInfo: [NSLocalizedDescriptionKey: "当前仅支持 UTF-8 文本。文件未被修改，请使用原编码的编辑器打开。"]
      )
    }
    text = decoded
  }

  var data: Data {
    (hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
  }
}
