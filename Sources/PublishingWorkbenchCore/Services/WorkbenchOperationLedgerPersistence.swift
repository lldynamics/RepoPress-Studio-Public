import Foundation

/// Test and diagnostic hooks for the ledger's filesystem boundary. Production
/// callers use the default no-op hooks.
public struct WorkbenchOperationLedgerPersistenceHooks: Sendable {
  public let beforeLoad: (@Sendable () -> Void)?
  public let beforeSave: (@Sendable () -> Void)?
  public let beforeQuarantine: (@Sendable () -> Void)?

  public init(
    beforeLoad: (@Sendable () -> Void)? = nil,
    beforeSave: (@Sendable () -> Void)? = nil,
    beforeQuarantine: (@Sendable () -> Void)? = nil
  ) {
    self.beforeLoad = beforeLoad
    self.beforeSave = beforeSave
    self.beforeQuarantine = beforeQuarantine
  }
}

public struct WorkbenchOperationLedgerLoadResult: Sendable {
  public let document: WorkbenchOperationLedgerDocument
  public let recoveryMessage: String?

  public init(
    document: WorkbenchOperationLedgerDocument,
    recoveryMessage: String? = nil
  ) {
    self.document = document
    self.recoveryMessage = recoveryMessage
  }
}

public struct WorkbenchOperationLedgerPersistence: Sendable {
  public static let maximumLedgerByteCount = 4 * 1_024 * 1_024

  public let fileURL: URL
  private let hooks: WorkbenchOperationLedgerPersistenceHooks

  public init(
    fileURL: URL,
    hooks: WorkbenchOperationLedgerPersistenceHooks = .init()
  ) {
    self.fileURL = fileURL
    self.hooks = hooks
  }

  public var lastKnownGoodURL: URL {
    fileURL
      .deletingPathExtension()
      .appendingPathExtension("last-known-good.json")
  }

  public func loadWithRecovery(now: Date = Date()) throws -> WorkbenchOperationLedgerLoadResult {
    hooks.beforeLoad?()
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else {
      guard fileManager.fileExists(atPath: lastKnownGoodURL.path) else {
        return WorkbenchOperationLedgerLoadResult(document: .init())
      }
      return WorkbenchOperationLedgerLoadResult(
        document: try decodeDocument(at: lastKnownGoodURL, now: now),
        recoveryMessage: CoreL10n.text("活动记录主文件缺失，已从上次有效备份恢复。")
      )
    }

    do {
      return WorkbenchOperationLedgerLoadResult(
        document: try decodeDocument(at: fileURL, now: now)
      )
    } catch {
      let primaryError = error.localizedDescription
      guard fileManager.fileExists(atPath: lastKnownGoodURL.path) else {
        throw WorkbenchOperationLedgerPersistenceError.unrecoverableLedger(
          primary: primaryError,
          backup: nil
        )
      }
      do {
        return WorkbenchOperationLedgerLoadResult(
          document: try decodeDocument(at: lastKnownGoodURL, now: now),
          recoveryMessage: CoreL10n.text("活动记录文件损坏，已从上次有效备份恢复。")
        )
      } catch {
        throw WorkbenchOperationLedgerPersistenceError.unrecoverableLedger(
          primary: primaryError,
          backup: error.localizedDescription
        )
      }
    }
  }

  public func save(_ document: WorkbenchOperationLedgerDocument, now: Date = Date()) throws {
    hooks.beforeSave?()
    let data = try Self.encodedDocument(document, now: now)

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var previousPrimaryData: Data?
    if fileManager.fileExists(atPath: fileURL.path) {
      do {
        let data = try BoundedFileReader.data(
          at: fileURL,
          maximumByteCount: Self.maximumLedgerByteCount
        )
        _ = try Self.decodedDocument(from: data, now: now)
        previousPrimaryData = data
      } catch {
        previousPrimaryData = nil
      }
    }

    if let previousPrimaryData {
      try previousPrimaryData.write(to: lastKnownGoodURL, options: [.atomic])
    } else if !fileManager.fileExists(atPath: lastKnownGoodURL.path) {
      try data.write(to: lastKnownGoodURL, options: [.atomic])
    }
    try data.write(to: fileURL, options: [.atomic])
  }

  /// Preserves unreadable files for manual inspection before a fresh ledger
  /// is allowed to replace them.
  public func quarantineUnreadableFiles() throws -> [URL] {
    hooks.beforeQuarantine?()
    let fileManager = FileManager.default
    var quarantined: [URL] = []
    for sourceURL in [fileURL, lastKnownGoodURL]
    where fileManager.fileExists(atPath: sourceURL.path) {
      let destinationURL =
        sourceURL
        .deletingPathExtension()
        .appendingPathExtension("unreadable-\(UUID().uuidString.lowercased()).json")
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      quarantined.append(destinationURL)
    }
    return quarantined
  }

  private func decodeDocument(
    at url: URL,
    now: Date
  ) throws -> WorkbenchOperationLedgerDocument {
    let data = try BoundedFileReader.data(
      at: url,
      maximumByteCount: Self.maximumLedgerByteCount
    )
    return try decodeDocument(from: data, now: now)
  }

  private func decodeDocument(
    from data: Data,
    now: Date
  ) throws -> WorkbenchOperationLedgerDocument {
    try Self.decodedDocument(from: data, now: now)
  }

  static func encodedDocument(
    _ document: WorkbenchOperationLedgerDocument,
    now: Date = Date()
  ) throws -> Data {
    let data = try makeEncoder().encode(document.normalized(now: now))
    guard data.count <= maximumLedgerByteCount else {
      throw WorkbenchOperationLedgerPersistenceError.exceedsSizeLimit
    }
    _ = try decodedDocument(from: data, now: now)
    return data
  }

  static func decodedDocument(
    from data: Data,
    now: Date = Date()
  ) throws -> WorkbenchOperationLedgerDocument {
    guard data.count <= maximumLedgerByteCount else {
      throw WorkbenchOperationLedgerPersistenceError.exceedsSizeLimit
    }
    let document = try Self.makeDecoder().decode(
      WorkbenchOperationLedgerDocument.self,
      from: data
    )
    for record in document.records {
      let counts = [
        record.processedItemCount,
        record.createdItemCount,
        record.updatedItemCount,
        record.skippedItemCount,
        record.draftCount,
        record.draftVersionCount,
      ].compactMap { $0 }
      guard counts.allSatisfy({ $0 >= 0 }), (record.savedByteCount ?? 0) >= 0 else {
        throw WorkbenchOperationLedgerPersistenceError.invalidRecord
      }
    }
    return document.normalized(now: now)
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}

public enum WorkbenchOperationLedgerPersistenceError: LocalizedError, Equatable, Sendable {
  case exceedsSizeLimit
  case invalidRecord
  case unrecoverableLedger(primary: String, backup: String?)

  public var errorDescription: String? {
    switch self {
    case .exceedsSizeLimit:
      return CoreL10n.text("活动记录文件超过大小限制。")
    case .invalidRecord:
      return CoreL10n.text("活动记录包含无效的计数。")
    case .unrecoverableLedger(let primary, let backup):
      if let backup {
        return CoreL10n.format(
          "活动记录及其备份都无法读取：%@；%@",
          primary,
          backup
        )
      }
      return CoreL10n.format("活动记录无法读取：%@", primary)
    }
  }
}
