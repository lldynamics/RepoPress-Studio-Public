import Foundation
import SQLite3

let knowledgeSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func knowledgeSQLiteCancellationProgressHandler(
  _ context: UnsafeMutableRawPointer?
) -> Int32 {
  _ = context
  return Task.isCancelled ? 1 : 0
}

struct KnowledgeDatabaseBackupInspection: Hashable, Sendable {
  var userVersion: Int
  var documentCount: Int
  var folderCount: Int
  var revisionCount: Int
  var chunkCount: Int
  var storageReferences: Set<String>
  var sampleTitles: [String]
}

struct KnowledgeDatabaseDeletionOutcome: Hashable, Sendable {
  var unreferencedStorageReferences: Set<String>
}

struct KnowledgeDatabaseImportRecord: Sendable {
  var document: KnowledgeDocument
  var revision: KnowledgeDocumentRevision
  var chunks: [KnowledgeChunk]
  var embeddings: [KnowledgeChunkEmbedding]
}

struct KnowledgeDatabaseCapturedTextAssignment: Sendable {
  var revisionID: UUID
  var storageReference: String
}

struct KnowledgeDatabaseFolderAssignment: Sendable {
  var documentID: UUID
  var folderID: UUID?
}

final class KnowledgeDatabase: @unchecked Sendable {
  static let currentSchemaVersion = 8

  let lock = NSLock()
  var handle: OpaquePointer?

  init(fileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "无法打开数据库"
      if let database { sqlite3_close(database) }
      throw KnowledgeLibraryError.database(message)
    }
    handle = database

    do {
      try execute("PRAGMA foreign_keys = ON;")
      let existingUserVersion = try withLock {
        try scalarIntUnlocked("PRAGMA user_version;")
      }
      guard existingUserVersion <= Self.currentSchemaVersion else {
        throw KnowledgeLibraryError.unsupportedDatabaseVersion(
          found: existingUserVersion,
          supported: Self.currentSchemaVersion
        )
      }
      try execute("PRAGMA journal_mode = WAL;")
      try execute("PRAGMA synchronous = NORMAL;")
      try migrate(from: existingUserVersion)
    } catch {
      sqlite3_close(database)
      handle = nil
      throw error
    }
  }

  deinit {
    if let handle {
      sqlite3_close(handle)
    }
  }

  init(readOnlyBackupURL fileURL: URL) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
        ?? "无法打开备份数据库"
      if let database { sqlite3_close(database) }
      throw KnowledgeLibraryBackupError.databaseIntegrity(message)
    }
    handle = database
  }

}
