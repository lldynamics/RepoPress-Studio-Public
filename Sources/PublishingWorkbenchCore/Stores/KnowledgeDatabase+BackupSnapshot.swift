import Foundation
import SQLite3

extension KnowledgeDatabase {
  /// Validates the database through its existing read-write connection.
  ///
  /// A WAL database opened read-only may still need to create or update its
  /// shared-memory file. Initialization therefore validates the staged
  /// database through the same connection that created it. Offline backup
  /// files continue to use the strictly read-only `inspectBackup(at:)` path
  /// below.
  func inspectOpenDatabase() throws -> KnowledgePersistenceInspection {
    try withLock {
      let userVersion = try scalarIntUnlocked("PRAGMA user_version;")
      guard userVersion <= Self.currentSchemaVersion else {
        throw KnowledgeLibraryBackupError.unsupportedDatabaseVersion(
          found: userVersion,
          supported: Self.currentSchemaVersion
        )
      }
      return try backupInspectionUnlocked(validateIntegrity: true)
    }
  }

  func createBackupSnapshot(at destinationURL: URL) throws -> KnowledgePersistenceInspection {
    try withCancellableLock {
      guard let handle else {
        throw KnowledgeLibraryBackupError.databaseIntegrity("资料库数据库尚未打开")
      }
      try FileManager.default.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
      }

      var destinationHandle: OpaquePointer?
      let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
      guard sqlite3_open_v2(destinationURL.path, &destinationHandle, flags, nil) == SQLITE_OK,
            let destinationHandle else {
        let message = destinationHandle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
          ?? "无法创建 SQLite 快照"
        if let destinationHandle { sqlite3_close(destinationHandle) }
        throw KnowledgeLibraryBackupError.databaseIntegrity(message)
      }
      defer { sqlite3_close(destinationHandle) }

      guard let backup = sqlite3_backup_init(destinationHandle, "main", handle, "main") else {
        throw KnowledgeLibraryBackupError.databaseIntegrity(
          String(cString: sqlite3_errmsg(destinationHandle))
        )
      }

      var didFinishBackup = false
      defer {
        if !didFinishBackup {
          _ = sqlite3_backup_finish(backup)
        }
      }

      var stepResult: Int32 = SQLITE_OK
      var stepCount = 0
      while true {
        try Task.checkCancellation()
        stepResult = sqlite3_backup_step(backup, 128)
        stepCount += 1
        backupStepHook(stepCount)
        try Task.checkCancellation()

        if stepResult == SQLITE_DONE {
          break
        }
        if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
          sqlite3_sleep(10)
          continue
        }

        break
      }
      let finishResult = sqlite3_backup_finish(backup)
      didFinishBackup = true
      guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
        throw KnowledgeLibraryBackupError.databaseIntegrity(
          String(cString: sqlite3_errmsg(destinationHandle))
        )
      }

      var journalError: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(
        destinationHandle,
        "PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL;",
        nil,
        nil,
        &journalError
      ) == SQLITE_OK else {
        let message = journalError.map { String(cString: $0) }
          ?? String(cString: sqlite3_errmsg(destinationHandle))
        sqlite3_free(journalError)
        throw KnowledgeLibraryBackupError.databaseIntegrity(message)
      }

      return try backupInspectionUnlocked(validateIntegrity: false)
    }
  }

  static func inspectBackup(at fileURL: URL) throws -> KnowledgePersistenceInspection {
    do {
      let database = try KnowledgeDatabase(readOnlyBackupURL: fileURL)
      return try database.withLock {
        let userVersion = try database.scalarIntUnlocked("PRAGMA user_version;")
        guard userVersion <= Self.currentSchemaVersion else {
          throw KnowledgeLibraryBackupError.unsupportedDatabaseVersion(
            found: userVersion,
            supported: Self.currentSchemaVersion
          )
        }
        return try database.backupInspectionUnlocked(validateIntegrity: true)
      }
    } catch let error as KnowledgeLibraryBackupError {
      throw error
    } catch {
      throw KnowledgeLibraryBackupError.databaseIntegrity(error.localizedDescription)
    }
  }
}
