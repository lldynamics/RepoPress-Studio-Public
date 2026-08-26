import Foundation

extension WorkbenchPersistence {
  public func exportRecoveryFiles(to directoryURL: URL) throws -> URL {
    return try archiveRecoveryFiles(
      in: directoryURL,
      folderPrefix: "PersonalSitePublisher-Recovery"
    )
  }

  /// Validates a chosen snapshot before archiving the unreadable files and
  /// replacing both persistence copies. The live store should restart before it
  /// uses this file so no state from the temporary blank workbench is merged in.
  @discardableResult
  public func installRecoverySnapshot(from sourceURL: URL) throws -> URL {
    try installRecoverySnapshot(
      from: sourceURL,
      fileOperations: WorkbenchRecoveryFileOperations(
        writeAtomically: { data, destinationURL in
          try data.write(to: destinationURL, options: .atomic)
        },
        archiveExistingSnapshots: {
          try archiveUnrecoverableSnapshotFiles()
        }
      )
    )
  }

  @discardableResult
  func installRecoverySnapshot(
    from sourceURL: URL,
    fileOperations: WorkbenchRecoveryFileOperations
  ) throws -> URL {
    let data: Data
    do {
      data = try BoundedFileReader.data(
        at: sourceURL,
        maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount
      )
    } catch {
      throw WorkbenchPersistenceError.invalidRecoverySnapshot(error.localizedDescription)
    }
    do {
      try validateSnapshotData(data)
    } catch {
      throw WorkbenchPersistenceError.invalidRecoverySnapshot(error.localizedDescription)
    }

    let fileManager = FileManager.default
    let parentDirectoryURL = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parentDirectoryURL,
      withIntermediateDirectories: true
    )

    let stagingDirectoryURL = parentDirectoryURL.appendingPathComponent(
      ".workbench-recovery-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: stagingDirectoryURL,
      withIntermediateDirectories: false
    )
    defer {
      try? fileManager.removeItem(at: stagingDirectoryURL)
    }

    let stagedPrimaryURL = stagingDirectoryURL.appendingPathComponent(fileURL.lastPathComponent)
    let stagedLastKnownGoodURL = stagingDirectoryURL.appendingPathComponent(
      lastKnownGoodURL.lastPathComponent
    )
    do {
      try fileOperations.writeAtomically(data, stagedPrimaryURL)
      try fileOperations.writeAtomically(data, stagedLastKnownGoodURL)
      try validateStagedRecoverySnapshot(at: stagedPrimaryURL, expectedData: data)
      try validateStagedRecoverySnapshot(at: stagedLastKnownGoodURL, expectedData: data)
    } catch let error as WorkbenchRecoveryTransactionError {
      throw error
    } catch {
      throw WorkbenchRecoveryTransactionError.stagingFailed(error.localizedDescription)
    }

    let archiveURL: URL
    do {
      archiveURL = try fileOperations.archiveExistingSnapshots()
    } catch {
      throw WorkbenchRecoveryTransactionError.archiveFailed(error.localizedDescription)
    }
    do {
      try fileOperations.writeAtomically(data, lastKnownGoodURL)
    } catch {
      throw WorkbenchRecoveryTransactionError.backupInstallFailed(error.localizedDescription)
    }
    do {
      try fileOperations.writeAtomically(data, fileURL)
    } catch {
      throw WorkbenchRecoveryTransactionError.primaryInstallFailed(error.localizedDescription)
    }
    return archiveURL
  }

  private func validateStagedRecoverySnapshot(at url: URL, expectedData: Data) throws {
    let stagedData = try BoundedFileReader.data(
      at: url,
      maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount
    )
    guard stagedData == expectedData else {
      throw WorkbenchRecoveryTransactionError.stagedDataMismatch(url.lastPathComponent)
    }
    try validateSnapshotData(stagedData)
  }

  /// Preserves both unreadable persistence copies before an explicit reset.
  @discardableResult
  public func archiveUnrecoverableSnapshotFiles() throws -> URL {
    try archiveRecoveryFiles(
      in: recoveryArchiveDirectoryURL,
      folderPrefix: "UnrecoverableWorkbench"
    )
  }

  private func archiveRecoveryFiles(in parentDirectoryURL: URL, folderPrefix: String) throws -> URL
  {
    let fileManager = FileManager.default
    let sourceURLs = [fileURL, lastKnownGoodURL].filter { fileManager.fileExists(atPath: $0.path) }
    guard !sourceURLs.isEmpty else {
      throw WorkbenchPersistenceError.recoveryFilesUnavailable
    }

    try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
    let archiveURL = parentDirectoryURL.appendingPathComponent(
      "\(folderPrefix)-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: archiveURL, withIntermediateDirectories: false)
    do {
      for sourceURL in sourceURLs {
        try fileManager.copyItem(
          at: sourceURL,
          to: archiveURL.appendingPathComponent(sourceURL.lastPathComponent)
        )
      }
    } catch {
      do {
        try fileManager.removeItem(at: archiveURL)
      } catch let cleanupError {
        throw WorkbenchPersistenceError.recoveryArchiveCleanupFailed(
          path: archiveURL.path,
          reason: "复制失败：\(error.localizedDescription)；清理失败：\(cleanupError.localizedDescription)"
        )
      }
      throw error
    }
    return archiveURL
  }

}
