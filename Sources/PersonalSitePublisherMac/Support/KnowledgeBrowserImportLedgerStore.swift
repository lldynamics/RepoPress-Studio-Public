import Foundation
import PublishingWorkbenchCore

struct KnowledgeBrowserImportLedgerDefaults: @unchecked Sendable {
  let value: UserDefaults

  init(_ value: UserDefaults) {
    self.value = value
  }
}

actor KnowledgeBrowserImportLedgerStore {
  private let fileURL: URL?
  private let defaults: UserDefaults
  private let legacyDefaultsKey: String

  init(
    fileURL: URL?,
    defaults: KnowledgeBrowserImportLedgerDefaults,
    legacyDefaultsKey: String
  ) {
    self.fileURL = fileURL
    self.defaults = defaults.value
    self.legacyDefaultsKey = legacyDefaultsKey
  }

  func persist(_ records: [KnowledgeBrowserImportOperationRecord]) throws {
    if let fileURL {
      try Self.write(records, to: fileURL)
      defaults.removeObject(forKey: legacyDefaultsKey)
    } else {
      defaults.set(
        try PropertyListEncoder().encode(records),
        forKey: legacyDefaultsKey
      )
    }
  }

  func archiveUnreadableLedger() throws -> URL? {
    guard let fileURL,
          FileManager.default.fileExists(atPath: fileURL.path) else {
      defaults.removeObject(forKey: legacyDefaultsKey)
      return nil
    }
    let timestamp = ISO8601DateFormatter()
      .string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let backupURL = fileURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        "import-operation-ledger-corrupt-\(timestamp)-\(UUID().uuidString.prefix(8)).plist"
      )
    try FileManager.default.moveItem(at: fileURL, to: backupURL)
    defaults.removeObject(forKey: legacyDefaultsKey)
    return backupURL
  }

  private static func write(
    _ records: [KnowledgeBrowserImportOperationRecord],
    to url: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(records).write(to: url, options: .atomic)
  }
}
