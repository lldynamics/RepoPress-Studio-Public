import Foundation

/// synchronous default for source compatibility.
public struct WorkbenchPersistence: Sendable {
  public var fileURL: URL
  let baseline = WorkbenchPersistenceBaseline()

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let supportURL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
      self.fileURL =
        supportURL
        .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
        .appendingPathComponent("workbench.json")
    }
  }

  public func load() throws -> WorkbenchSnapshot? {
    try loadWithRecovery().snapshot
  }

  public func loadWithRecovery() throws -> WorkbenchSnapshotLoadResult {
    if !FileManager.default.fileExists(atPath: fileURL.path),
      !FileManager.default.fileExists(atPath: lastKnownGoodURL.path)
    {
      // Loading a new workspace must not require a writable parent. A writer
      // racing this read is detected by the missing baseline at commit time.
      baseline.observe("missing", for: fileURL.path)
      return WorkbenchSnapshotLoadResult(snapshot: nil)
    }
    return try withRecordFileLock {
      // Retain the observed revision even when the payload is corrupt, so an
      // explicitly requested recovery still detects a concurrent writer.
      let version = try currentStorageVersion()
      baseline.observe(version, for: fileURL.path)
      let result = try loadWithRecoveryUnlocked()
      return result
    }
  }

  func loadWithRecoveryUnlocked() throws -> WorkbenchSnapshotLoadResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      guard FileManager.default.fileExists(atPath: lastKnownGoodURL.path) else {
        return WorkbenchSnapshotLoadResult(snapshot: nil)
      }

      do {
        let snapshot = try decodeValidatedSnapshot(at: lastKnownGoodURL)
        return WorkbenchSnapshotLoadResult(
          snapshot: snapshot,
          recoveryMessage: "工作台数据文件缺失，已从上次有效备份恢复。"
        )
      } catch WorkbenchRecordStorageError.unsupportedVersion(let message) {
        throw WorkbenchRecordStorageError.unsupportedVersion(message)
      } catch {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(
          primary: "主工作台数据文件不存在。",
          backup: error.localizedDescription
        )
      }
    }

    do {
      return WorkbenchSnapshotLoadResult(snapshot: try decodeValidatedSnapshot(at: fileURL))
    } catch WorkbenchRecordStorageError.unsupportedVersion(let message) {
      throw WorkbenchRecordStorageError.unsupportedVersion(message)
    } catch {
      let primaryError = error.localizedDescription
      guard FileManager.default.fileExists(atPath: lastKnownGoodURL.path) else {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(primary: primaryError, backup: nil)
      }

      do {
        let snapshot = try decodeValidatedSnapshot(at: lastKnownGoodURL)
        return WorkbenchSnapshotLoadResult(
          snapshot: snapshot,
          recoveryMessage: "工作台数据文件损坏，已从上次有效备份恢复。原始文件保留在原处。"
        )
      } catch WorkbenchRecordStorageError.unsupportedVersion(let message) {
        throw WorkbenchRecordStorageError.unsupportedVersion(message)
      } catch {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(
          primary: primaryError,
          backup: error.localizedDescription
        )
      }
    }
  }

  public func prepareSave(
    _ snapshot: WorkbenchSnapshot,
    reclaimUnreferencedAttachments _: Bool = true
  ) throws -> WorkbenchPreparedPersistenceSave {
    return WorkbenchPreparedPersistenceSave(
      records: try WorkbenchRecordPayload(snapshot: snapshot),
      retiredFeatureArchives: try retiredFeatureArchivesFromPersistedSnapshots()
    )
  }

  public func commit(_ preparedSave: WorkbenchPreparedPersistenceSave) throws
    -> WorkbenchPersistenceSaveResult
  {
    try commitRecords(preparedSave.records, retiredArchives: preparedSave.retiredFeatureArchives)
  }

  private func decodeValidatedSnapshot(at url: URL) throws -> WorkbenchSnapshot {
    try loadStoredSnapshot(at: url)
  }

  @discardableResult
  private func decodeValidatedSnapshot(from data: Data) throws -> WorkbenchSnapshot {
    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)
    try WorkbenchSnapshotSemanticValidator.validate(snapshot)
    return snapshot
  }

  func validateSnapshotData(_ data: Data) throws {
    try decodeValidatedSnapshot(from: data)
  }

  public func save(_ snapshot: WorkbenchSnapshot) throws -> WorkbenchPersistenceSaveResult {
    try commit(prepareSave(snapshot))
  }

  public var lastKnownGoodURL: URL {
    fileURL
      .deletingPathExtension()
      .appendingPathExtension("last-known-good.json")
  }

  /// A small independent journal for editor buffers that have not reached the
  /// main workbench snapshot yet. It is intentionally separate so a damaged
  /// snapshot cannot also erase the latest unsaved writing buffer.
  public var draftRecoveryJournalURL: URL {
    fileURL
      .deletingPathExtension()
      .appendingPathExtension("draft-recovery.json")
  }

  /// Independent, privacy-bounded activity history. It is intentionally kept
  /// outside `WorkbenchSnapshot` so a damaged log cannot prevent the main
  /// workspace from opening and clearing history never mutates release data.
  public var operationLedgerURL: URL {
    fileURL
      .deletingPathExtension()
      .appendingPathExtension("operation-log.json")
  }

  public var recoveryArchiveDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("RecoveryArchives", isDirectory: true)
  }
}
