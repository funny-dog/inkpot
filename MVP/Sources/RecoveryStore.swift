import Foundation

struct RecoveryDraft: Codable {
  let id: UUID
  let originalURL: URL?
  let data: Data
  let updated: Date
}

struct RecoveryStore {
  static let standard = Self(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Kernmark/Recovery", isDirectory: true))
  let directory: URL

  func write(_ draft: RecoveryDraft) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(draft.id.uuidString).appendingPathExtension("json")
    try JSONEncoder().encode(draft).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func drafts() throws -> [RecoveryDraft] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .compactMap { url in
        // 损坏的记录留在磁盘，不妨碍其他草稿恢复，也不擅自清除它。
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecoveryDraft.self, from: data)
      }
      .sorted { $0.updated > $1.updated }
  }

  func remove(_ id: UUID) throws {
    let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }
}
