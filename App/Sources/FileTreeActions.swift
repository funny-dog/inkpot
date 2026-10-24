import AppKit

extension Notification.Name {
  static let inkpotFileTreeChanged = Notification.Name("InkpotFileTreeChanged")
}

@MainActor
final class FileTreeActions {
  static let shared = FileTreeActions()
  private(set) var isWorking = false
  private let documents: @MainActor () -> [InkpotDocument]
  private let confirmClose: (InkpotDocument) async -> Bool
  private let recycle: (URL) throws -> Void

  init(
    documents: @escaping @MainActor () -> [InkpotDocument] = { NSDocumentController.shared.documents.compactMap { $0 as? InkpotDocument } },
    confirmClose: @escaping (InkpotDocument) async -> Bool = DocumentFileSwitch.confirm,
    recycle: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
  ) {
    self.documents = documents
    self.confirmClose = confirmClose
    self.recycle = recycle
  }

  static func relocated(_ url: URL, from source: URL, to destination: URL) -> URL? {
    let path = url.standardizedFileURL.path
    let sourcePath = source.standardizedFileURL.path
    guard path == sourcePath || path.hasPrefix(sourcePath + "/") else { return nil }
    return URL(fileURLWithPath: destination.standardizedFileURL.path + path.dropFirst(sourcePath.count))
  }

  /// requireText 为真时只接受 Markdown 与纯文本扩展名；重命名其他类型文件时不限制扩展名。
  static func named(_ name: String, in folder: URL, directory: Bool, requireText: Bool = true) throws -> URL {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.hasPrefix("."),
          name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\0\r\n")) == nil else {
      throw NSError(domain: "Inkpot", code: 50, userInfo: [NSLocalizedDescriptionKey: "请输入有效名称；不能以点开头或包含斜杠、冒号和换行。"])
    }
    let url = folder.appendingPathComponent(name, isDirectory: directory).standardizedFileURL
    guard directory || !requireText || FileTree.textExtensions.contains(url.pathExtension.lowercased()) else {
      throw NSError(domain: "Inkpot", code: 51, userInfo: [NSLocalizedDescriptionKey: "文件请使用 .md、.markdown 或 .txt 扩展名。"])
    }
    return url
  }

  func create(in folder: URL, name: String, directory: Bool) throws -> URL {
    guard !isWorking else { throw CocoaError(.userCancelled) }
    let target = try Self.named(name, in: folder, directory: directory)
    if directory {
      guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    } else { try Data().write(to: target, options: .withoutOverwriting) }
    changed()
    return target
  }

  /// 在同一文件夹复制为“原名 副本”，重名时依次加序号；复制的是磁盘上的版本。
  func duplicate(_ source: URL) throws -> URL {
    guard !isWorking else { throw CocoaError(.userCancelled) }
    let folder = source.deletingLastPathComponent()
    let base = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var index = 1
    var target: URL
    repeat {
      let name = (index == 1 ? "\(base) 副本" : "\(base) 副本 \(index)") + (ext.isEmpty ? "" : ".\(ext)")
      target = folder.appendingPathComponent(name).standardizedFileURL
      index += 1
    } while FileManager.default.fileExists(atPath: target.path)
    try FileManager.default.copyItem(at: source, to: target)
    changed()
    return target
  }

  func rename(_ source: URL, name: String) async throws -> URL {
    guard !isWorking else { throw CocoaError(.userCancelled) }
    isWorking = true
    defer { isWorking = false }
    let directory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    let requireText = FileTree.textExtensions.contains(source.pathExtension.lowercased())
    let target = try Self.named(name, in: source.deletingLastPathComponent(), directory: directory, requireText: requireText)
    guard target != source.standardizedFileURL else { return target }
    guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
    let affected = matching(source)
    for document in affected { try await document.synchronize() }
    var coordinationError: NSError?
    var moveResult: Result<Void, Error>?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordinationError) { old, new in
      moveResult = Result {
        coordinator.item(at: old, willMoveTo: new)
        try FileManager.default.moveItem(at: old, to: new)
        coordinator.item(at: old, didMoveTo: new)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let moveResult else { throw CocoaError(.fileWriteUnknown) }
    try moveResult.get()
    for document in affected {
      if let current = document.fileURL, let moved = Self.relocated(current, from: source, to: target) {
        document.fileURL = moved
        for controller in document.windowControllers { controller.synchronizeWindowTitleWithDocumentName() }
        NSDocumentController.shared.noteNewRecentDocumentURL(moved)
        if document.isDocumentEdited { document.safety.schedule() }
      }
    }
    changed(from: source, to: target)
    return target
  }

  func trash(_ source: URL) async throws -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    defer { isWorking = false }
    var approved: [ObjectIdentifier: Data] = [:]
    for document in matching(source) {
      try await document.synchronize()
      guard await confirmClose(document) else { return false }
      approved[ObjectIdentifier(document)] = try document.data(ofType: document.fileType ?? "net.daringfireball.markdown")
    }
    let affected = matching(source)
    var revisions: [ObjectIdentifier: Int] = [:]
    var paths: [ObjectIdentifier: URL] = [:]
    for document in affected {
      try await document.synchronize()
      revisions[ObjectIdentifier(document)] = document.editor?.latestRevision ?? -1
      paths[ObjectIdentifier(document)] = document.fileURL
      guard approved[ObjectIdentifier(document)] == (try document.data(ofType: document.fileType ?? "net.daringfireball.markdown")) else {
        throw NSError(domain: "Inkpot", code: 52, userInfo: [NSLocalizedDescriptionKey: "确认期间文档又发生了变化，已取消移到废纸篓。请检查内容后重试。"])
      }
    }
    guard Set(matching(source).map(ObjectIdentifier.init)) == Set(affected.map(ObjectIdentifier.init)), affected.allSatisfy({
      revisions[ObjectIdentifier($0)] == ($0.editor?.latestRevision ?? -1) && paths[ObjectIdentifier($0)] == $0.fileURL
    }) else { throw CocoaError(.userCancelled) }
    // 移动成功后才关闭；失败时保留原文档及尚未保存的编辑历史。
    try recycle(source)
    for document in affected { document.close() }
    changed(from: source)
    return true
  }

  private func matching(_ source: URL) -> [InkpotDocument] {
    documents().filter { document in
      document.fileURL.flatMap { Self.relocated($0, from: source, to: source) } != nil
    }
  }

  private func changed(from source: URL? = nil, to target: URL? = nil) {
    var info: [String: URL] = [:]
    info["source"] = source
    info["target"] = target
    NotificationCenter.default.post(name: .inkpotFileTreeChanged, object: nil, userInfo: info)
  }
}
