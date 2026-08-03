import Foundation
import PublishingWorkbenchCore

struct KnowledgeBrowserImportLedgerDefaults: @unchecked Sendable {
  let value: UserDefaults

  init(_ value: UserDefaults) {
    self.value = value
  }
}

enum KnowledgeBrowserImportLedgerIssueKind: Sendable {
  case unreadable
  case unwritable
}

struct KnowledgeBrowserImportLedgerLoadResult: Sendable {
  let ledger: KnowledgeBrowserImportOperationLedger
  let persistenceIssue: String?
  let issueKind: KnowledgeBrowserImportLedgerIssueKind?
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

  func loadPruned(at now: Date) -> KnowledgeBrowserImportLedgerLoadResult {
    let records: [KnowledgeBrowserImportOperationRecord]
    do {
      records = try loadRecords()
    } catch {
      return KnowledgeBrowserImportLedgerLoadResult(
        ledger: KnowledgeBrowserImportOperationLedger(),
        persistenceIssue: "浏览器保存幂等账本无法读取：\(error.localizedDescription)",
        issueKind: .unreadable
      )
    }

    var ledger = KnowledgeBrowserImportOperationLedger(records: records)
    ledger.prune(at: now)
    do {
      try persist(ledger.records)
      return KnowledgeBrowserImportLedgerLoadResult(
        ledger: ledger,
        persistenceIssue: nil,
        issueKind: nil
      )
    } catch {
      return KnowledgeBrowserImportLedgerLoadResult(
        ledger: ledger,
        persistenceIssue: "浏览器保存幂等账本无法持久化：\(error.localizedDescription)",
        issueKind: .unwritable
      )
    }
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

  private func loadRecords() throws -> [KnowledgeBrowserImportOperationRecord] {
    let data: Data?
    if let fileURL,
       FileManager.default.fileExists(atPath: fileURL.path) {
      data = try BoundedFileReader.data(
        at: fileURL,
        maximumByteCount: WorkbenchFileReadLimits.maximumBrowserImportLedgerByteCount
      )
    } else {
      data = defaults.data(forKey: legacyDefaultsKey)
      if let data,
         data.count > WorkbenchFileReadLimits.maximumBrowserImportLedgerByteCount {
        throw BoundedFileReadError.exceedsByteLimit(
          "UserDefaults:\(legacyDefaultsKey)",
          WorkbenchFileReadLimits.maximumBrowserImportLedgerByteCount
        )
      }
    }
    guard let data else { return [] }
    return try PropertyListDecoder().decode(
      [KnowledgeBrowserImportOperationRecord].self,
      from: data
    )
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
