// 渲染应用图标（方案 B：墨蓝底白色笔尖）到 App/Assets.xcassets/AppIcon.appiconset。
// 用法：swift scripts/render-app-icon.swift
// 几何取自设计稿：1024 画布内 824×824 圆角方块（圆角 185），笔尖与通气孔、笔缝按同一坐标绘制。
import AppKit

let ink = NSColor(srgbRed: 0x1F / 255.0, green: 0x3B / 255.0, blue: 0x5C / 255.0, alpha: 1)
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

/// 设计稿坐标以左上为原点，CoreGraphics 以左下为原点，绘制前翻转。
func draw(in context: CGContext) {
  context.translateBy(x: 0, y: 1024)
  context.scaleBy(x: 1, y: -1)
  // 底板投影：macOS 图标模板的轻微下投影。
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
  let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
  context.addPath(plate)
  context.setFillColor(ink.cgColor)
  context.fillPath()
  context.restoreGState()
  // 笔尖：上端尖角，两侧二次曲线收到下端尖角。
  let nib = CGMutablePath()
  nib.move(to: CGPoint(x: 512, y: 236))
  nib.addLine(to: CGPoint(x: 676, y: 478))
  nib.addQuadCurve(to: CGPoint(x: 512, y: 800), control: CGPoint(x: 676, y: 628))
  nib.addQuadCurve(to: CGPoint(x: 348, y: 478), control: CGPoint(x: 348, y: 628))
  nib.closeSubpath()
  context.addPath(nib)
  context.setFillColor(NSColor.white.cgColor)
  context.fillPath()
  // 通气孔与笔缝用底色挖出。
  context.setFillColor(ink.cgColor)
  context.fillEllipse(in: CGRect(x: 512 - 36, y: 520 - 36, width: 72, height: 72))
  context.fill(CGRect(x: 503, y: 556, width: 18, height: 250))
}

func render(pixels: Int) throws -> Data {
  guard let context = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { throw CocoaError(.featureUnsupported) }
  context.interpolationQuality = .high
  context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
  draw(in: context)
  guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  return png
}

let entries: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for entry in entries {
  let name = "icon_\(entry.points)x\(entry.points)\(entry.scale == 2 ? "@2x" : "").png"
  try render(pixels: entry.points * entry.scale).write(to: output.appendingPathComponent(name))
  images.append(["idiom": "mac", "size": "\(entry.points)x\(entry.points)", "scale": "\(entry.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
let catalog: [String: Any] = ["info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("已写入 \(output.path)")
