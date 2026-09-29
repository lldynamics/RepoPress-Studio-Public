import Foundation
import OSLog

extension KnowledgeLibraryBackupService {
  private static let restoreTransactionFileName = ".KnowledgeLibraryRestoreTransaction.json"

  enum RestoreTransactionPhase: String, Codable, Sendable {
    case prepared
    case pendingMoved
    case currentMoved
    case installed
  }

  private struct RestoreTransaction: Codable {
    var phase: RestoreTransactionPhase
    var pendingPath: String
    var applyingPath: String
    var stagingPath: String
    var previousLibraryPath: String?
    var installedRestoreID: UUID?
  }

  func applyPendingRestoreIfNeeded() throws -> KnowledgeLibraryRestoreStartupResult? {
    try recoverInterruptedRestoreIfNeeded()
    let pendingURL = Self.pendingRestoreURL(for: rootURL)
    guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }

    let validated = try validatedBackup(at: pendingURL)
    let parentURL = rootURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let stagingURL = parentURL.appendingPathComponent(
      ".KnowledgeLibraryRestore-\(UUID().uuidString)",
      isDirectory: true
    )
    let applyingURL = parentURL.appendingPathComponent(
      ".KnowledgeLibraryApplying-\(UUID().uuidString).pslibrarybackup",
      isDirectory: true
    )
    let previousLibraryURL: URL?
    if fileManager.fileExists(atPath: rootURL.path) {
      let recoveryDirectory = parentURL.appendingPathComponent(
        "KnowledgeLibraryRecovery",
        isDirectory: true
      )
      try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
      previousLibraryURL = recoveryDirectory.appendingPathComponent(
        "BeforeRestore-\(UUID().uuidString)",
        isDirectory: true
      )
    } else {
      previousLibraryURL = nil
    }
    var shouldRemoveStaging = true
    defer {
      if shouldRemoveStaging { try? fileManager.removeItem(at: stagingURL) }
    }

    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    for record in validated.manifest.files {
      let destinationURL = stagingURL.appendingPathComponent(record.relativePath)
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let copiedRecord = try copyValidatedRegularFile(
        relativePath: record.relativePath,
        from: pendingURL,
        to: destinationURL
      )
      guard copiedRecord == record else {
        throw KnowledgeLibraryBackupError.checksumMismatch(record.relativePath)
      }
    }
    _ = try lifecycle.inspectBackup(
      at: stagingURL.appendingPathComponent(Self.databaseFileName)
    )
    try KnowledgeNoteCloudRestoreBoundary.markRestoredLibrary(at: stagingURL)

    var transaction = RestoreTransaction(
      phase: .prepared,
      pendingPath: pendingURL.path,
      applyingPath: applyingURL.path,
      stagingPath: stagingURL.path,
      previousLibraryPath: previousLibraryURL?.path,
      installedRestoreID: try KnowledgeNoteCloudRestoreBoundary.restoreID(at: stagingURL)
    )
    try persistRestoreTransaction(transaction)
    do {
      try fileManager.moveItem(at: pendingURL, to: applyingURL)
      transaction.phase = .pendingMoved
      try persistRestoreTransaction(transaction)

      // The old library is moved only after the pending package has a durable
      // transaction record. A restart can therefore restore either side.
      if fileManager.fileExists(atPath: rootURL.path) {
        guard let previousLibraryURL else {
          throw KnowledgeLibraryBackupError.restoreFailed("未能记录旧知识库恢复副本")
        }
        try fileManager.moveItem(at: rootURL, to: previousLibraryURL)
      }
      transaction.phase = .currentMoved
      try persistRestoreTransaction(transaction)

      do {
        try fileManager.moveItem(at: stagingURL, to: rootURL)
        shouldRemoveStaging = false
      } catch let replacementError {
        if let previousLibraryURL,
          !fileManager.fileExists(atPath: rootURL.path)
        {
          do {
            try fileManager.moveItem(at: previousLibraryURL, to: rootURL)
          } catch let rollbackError {
            throw KnowledgeLibraryRollbackError(
              operation: "替换知识库",
              primaryError: replacementError,
              rollbackError: rollbackError,
              recoveryURL: previousLibraryURL
            )
          }
        }
        throw replacementError
      }
      transaction.phase = .installed
      // The identity moved atomically with the library is the commit point.
      // Journal/cleanup failures after it must never requeue this restore.
      do {
        try persistRestoreTransaction(transaction)
        try fileManager.removeItem(at: applyingURL)
        try clearRestoreTransaction()
      } catch {
        Self.logger.warning(
          "Knowledge restore succeeded but transaction cleanup remains pending: \(error.localizedDescription, privacy: .public)"
        )
      }
    } catch let restoreError {
      do {
        try recoverInterruptedRestoreIfNeeded()
      } catch let recoveryError {
        throw KnowledgeLibraryBackupError.restoreFailed(
          "\(restoreError.localizedDescription)；启动恢复也失败：\(recoveryError.localizedDescription)"
        )
      }
      throw KnowledgeLibraryBackupError.restoreFailed(restoreError.localizedDescription)
    }

    var restoredPreview = validated.preview
    restoredPreview.backupURL = rootURL
    return KnowledgeLibraryRestoreStartupResult(
      restoredPreview: restoredPreview,
      previousLibraryURL: previousLibraryURL
    )
  }

  static func pendingRestoreURL(for rootURL: URL) -> URL {
    rootURL.deletingLastPathComponent().appendingPathComponent(
      ".KnowledgeLibraryPendingRestore.pslibrarybackup",
      isDirectory: true
    )
  }

  private var restoreTransactionURL: URL {
    rootURL.deletingLastPathComponent()
      .appendingPathComponent(Self.restoreTransactionFileName)
  }

  private func persistRestoreTransaction(_ transaction: RestoreTransaction) throws {
    try restoreTransactionCheckpoint(transaction.phase)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(transaction)
    try fileManager.createDirectory(
      at: restoreTransactionURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: restoreTransactionURL, options: [.atomic])
    let handle = try FileHandle(forWritingTo: restoreTransactionURL)
    try handle.synchronize()
    try handle.close()
  }

  private func clearRestoreTransaction() throws {
    if fileManager.fileExists(atPath: restoreTransactionURL.path) {
      try fileManager.removeItem(at: restoreTransactionURL)
    }
  }

  private func recoverInterruptedRestoreIfNeeded() throws {
    guard fileManager.fileExists(atPath: restoreTransactionURL.path) else { return }
    let data = try Data(contentsOf: restoreTransactionURL)
    let transaction = try JSONDecoder().decode(RestoreTransaction.self, from: data)
    let parentURL = rootURL.deletingLastPathComponent().standardizedFileURL
    let pendingURL = try validatedTransactionURL(transaction.pendingPath, parent: parentURL)
    let applyingURL = try validatedTransactionURL(transaction.applyingPath, parent: parentURL)
    let stagingURL = try validatedTransactionURL(transaction.stagingPath, parent: parentURL)
    let previousLibraryURL = try transaction.previousLibraryPath.map {
      try validatedTransactionURL(
        $0,
        parent: parentURL.appendingPathComponent("KnowledgeLibraryRecovery")
      )
    }

    // A crash can leave currentMoved on disk after the staging rename succeeds.
    // Compare the identity, not database bytes: the user may already have edited
    // the installed library before the next launch retries cleanup.
    if let installedRestoreID = transaction.installedRestoreID,
      try KnowledgeNoteCloudRestoreBoundary.restoreID(at: rootURL) == installedRestoreID
    {
      try removeRecoveryArtifact(at: applyingURL)
      try removeRecoveryArtifact(at: stagingURL)
      try clearRestoreTransaction()
      return
    }

    if transaction.phase == .installed && transaction.installedRestoreID != nil {
      throw KnowledgeLibraryBackupError.restoreFailed(
        "恢复后的知识库标识不匹配，已保留事务与恢复副本。请先备份并检查目录：\(rootURL.deletingLastPathComponent().path)")
    }
    if transaction.phase == .currentMoved,
      fileManager.fileExists(atPath: rootURL.path),
      !fileManager.fileExists(atPath: stagingURL.path)
    {
      // Legacy journals lack an identity. Do not roll back or replay an
      // ambiguous installation: either could overwrite subsequent user edits.
      throw KnowledgeLibraryBackupError.restoreFailed(
        "无法确认上次恢复的提交状态，已保留知识库和恢复副本。请先备份并检查目录：\(rootURL.deletingLastPathComponent().path)")
    }

    switch transaction.phase {
    case .prepared:
      if fileManager.fileExists(atPath: applyingURL.path),
        !fileManager.fileExists(atPath: pendingURL.path)
      {
        try fileManager.moveItem(at: applyingURL, to: pendingURL)
      }
      try removeRecoveryArtifact(at: stagingURL)

    case .pendingMoved, .currentMoved:
      if !fileManager.fileExists(atPath: rootURL.path),
        let previousLibraryURL,
        fileManager.fileExists(atPath: previousLibraryURL.path)
      {
        try fileManager.moveItem(at: previousLibraryURL, to: rootURL)
      }
      if fileManager.fileExists(atPath: applyingURL.path),
        !fileManager.fileExists(atPath: pendingURL.path)
      {
        try fileManager.moveItem(at: applyingURL, to: pendingURL)
      }
      try removeRecoveryArtifact(at: stagingURL)

    case .installed:
      // The new library is already visible. Keep the previous-library copy as
      // an explicit recovery point, but remove only exact temporary artifacts.
      try removeRecoveryArtifact(at: applyingURL)
      try removeRecoveryArtifact(at: stagingURL)
    }
    try clearRestoreTransaction()
  }

  private func removeRecoveryArtifact(at url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func validatedTransactionURL(_ path: String, parent: URL) throws -> URL {
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    guard candidate.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL
    else {
      throw KnowledgeLibraryBackupError.invalidPath(candidate.path)
    }
    return candidate
  }

}
