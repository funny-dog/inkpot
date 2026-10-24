import AppKit
import WebKit
import UniformTypeIdentifiers

/// 拖拽支持：Markdown 与文本文件作为文档打开，图片文件插入当前文档。
enum DragDrop {
  private static let documentExtensions: Set<String> = ["md", "markdown", "txt"]
  private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "heic"]

  static func isFolder(_ url: URL) -> Bool {
    guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { return false }
    return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
  }

  static func accepts(_ urls: [URL]) -> Bool {
    urls.contains { isFolder($0) || documentExtensions.contains($0.pathExtension.lowercased()) || imageExtensions.contains($0.pathExtension.lowercased()) }
  }

  static func perform(urls: [URL], in webView: WKWebView) {
    guard let document = webView.window?.windowController?.document as? InkpotDocument else { return }
    let documents = urls.filter { documentExtensions.contains($0.pathExtension.lowercased()) }
    let images = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    if let controller = webView.window?.contentViewController as? DocumentViewController {
      if let folder = urls.first(where: { isFolder($0) }) {
        controller.files.openFolder(folder)
        if !controller.filesVisible { controller.toggleContent(files: true) }
      }
      for url in documents { controller.openFile(url) }
    }
    guard !images.isEmpty else { return }
    insertImages(images, into: document)
  }

  private static func insertImages(_ urls: [URL], into document: InkpotDocument) {
    guard let base = document.fileURL else {
      Task { @MainActor in
        document.presentError(NSError(domain: "Inkpot", code: 41, userInfo: [NSLocalizedDescriptionKey: L10n.text("请先保存 Markdown 文档，再拖入图片。图片将保存在文档同级的 %@ 文件夹。", AppSettings.shared.imageFolder)]))
      }
      return
    }
    Task { @MainActor in
      for url in urls {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
          let data = try Data(contentsOf: url)
          let image = try await Task.detached { [folder = AppSettings.shared.imageFolder(beside: base)] in try LocalImages.store(data, beside: base, folderName: folder) }.value
          try await document.editor?.insertImage(image.path)
        } catch {
          if (error as NSError).code != NSUserCancelledError { document.presentError(error) }
        }
      }
      document.editor?.focusEditor()
    }
  }
}
