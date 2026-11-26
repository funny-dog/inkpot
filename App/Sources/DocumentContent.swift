import Foundation

struct DocumentContent {
  enum TextEncoding: Equatable {
    case utf8(bom: Bool)
    case utf16LE
    case utf16BE
    case gb18030
  }

  private static let gb18030Encoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    )
  )

  var text = ""
  private(set) var encoding: TextEncoding = .utf8(bom: false)

  init() {}

  init(data: Data) throws {
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      guard let decoded = String(data: data.dropFirst(3), encoding: .utf8) else {
        throw Self.unsupportedEncodingError()
      }
      encoding = .utf8(bom: true)
      text = decoded
      return
    }
    if let decoded = String(data: data, encoding: .utf8) {
      encoding = .utf8(bom: false)
      text = decoded
      return
    }
    if data.count >= 4, data.count.isMultiple(of: 2) {
      let body = Data(data.dropFirst(2))
      if data.starts(with: [0xFF, 0xFE]),
         let decoded = String(data: body, encoding: .utf16LittleEndian),
         !decoded.contains("\0"),
         decoded.data(using: .utf16LittleEndian) == body {
        encoding = .utf16LE
        text = decoded
        return
      }
      if data.starts(with: [0xFE, 0xFF]),
         let decoded = String(data: body, encoding: .utf16BigEndian),
         !decoded.contains("\0"),
         decoded.data(using: .utf16BigEndian) == body {
        encoding = .utf16BE
        text = decoded
        return
      }
    }
    // 不含 NUL 字节且不带其他 BOM 时尝试 GB18030，并要求逐字节往返完全一致。
    if !data.isEmpty,
       !data.contains(0x00),
       !data.starts(with: [0xFF, 0xFE]),
       !data.starts(with: [0xFE, 0xFF]),
       let decoded = String(data: data, encoding: Self.gb18030Encoding),
       !decoded.contains("\0"),
       decoded.data(using: Self.gb18030Encoding) == data {
      encoding = .gb18030
      text = decoded
      return
    }
    throw Self.unsupportedEncodingError()
  }

  var data: Data {
    switch encoding {
    case .utf8(let hasBOM):
      (hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
    case .utf16LE:
      Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
    case .utf16BE:
      Data([0xFE, 0xFF]) + (text.data(using: .utf16BigEndian) ?? Data())
    case .gb18030:
      if let encoded = text.data(using: Self.gb18030Encoding),
         String(data: encoded, encoding: Self.gb18030Encoding) == text {
        encoded
      } else {
        // 若编辑后加入了 GB18030 无法无损表达的字符，回退 UTF-8 避免写盘静默丢字。
        Data(text.utf8)
      }
    }
  }

  private static func unsupportedEncodingError() -> NSError {
    NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileReadInapplicableStringEncodingError,
      userInfo: [NSLocalizedDescriptionKey: L10n.text("无法识别的文本编码（支持 UTF-8、UTF-16 与 GB18030）。文件未被修改，请使用原编码的编辑器打开。")]
    )
  }
}
