import Foundation

/// synchronous default for source compatibility.
public struct WorkbenchPersistence: Sendable {
  public var fileURL: URL

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
      } catch {
        throw WorkbenchPersistenceError.unrecoverableSnapshot(
          primary: "主工作台数据文件不存在。",
          backup: error.localizedDescription
        )
      }
    }

    do {
      return WorkbenchSnapshotLoadResult(snapshot: try decodeValidatedSnapshot(at: fileURL))
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
      data: try JSONEncoder.workbench.encode(snapshot),
      retiredFeatureArchives: try retiredFeatureArchivesFromPersistedSnapshots()
    )
  }

  public func commit(_ preparedSave: WorkbenchPreparedPersistenceSave) throws
    -> WorkbenchPersistenceSaveResult
  {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = preparedSave.data
    try validateSnapshotData(data)

    let previousPrimaryExisted = fileManager.fileExists(atPath: fileURL.path)
    let previousPrimaryData: Data?
    let previousPrimaryWarning: String?
    if previousPrimaryExisted {
      do {
        let previousData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try validateSnapshotData(previousData)
        previousPrimaryData = previousData
        previousPrimaryWarning = nil
      } catch {
        previousPrimaryData = nil
        previousPrimaryWarning = "保存前的主快照无法验证：\(error.localizedDescription)"
      }
    } else {
      previousPrimaryData = nil
      previousPrimaryWarning = nil
    }

    try persistRetiredFeatureArchives(preparedSave.retiredFeatureArchives)
    try data.write(to: fileURL, options: [.atomic])

    do {
      if let previousPrimaryData {
        try previousPrimaryData.write(to: lastKnownGoodURL, options: [.atomic])
      } else if !previousPrimaryExisted
        || !fileManager.fileExists(atPath: lastKnownGoodURL.path)
      {
        try data.write(to: lastKnownGoodURL, options: [.atomic])
      }
      if let previousPrimaryWarning {
        return .savedWithoutBackup(
          "\(previousPrimaryWarning)；新主快照已保存，已有恢复点未被覆盖。"
        )
      }
      return .saved
    } catch {
      // The primary write succeeded. Surface the degraded recovery guarantee
      // instead of incorrectly reporting an unsaved document.
      return .savedWithoutBackup(error.localizedDescription)
    }
  }

  private func decodeValidatedSnapshot(at url: URL) throws -> WorkbenchSnapshot {
    let data = try BoundedFileReader.data(
      at: url,
      maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount
    )
    return try decodeValidatedSnapshot(from: data)
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

  public var recoveryArchiveDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("RecoveryArchives", isDirectory: true)
  }
}
