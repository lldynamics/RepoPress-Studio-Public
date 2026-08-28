import Foundation
import SQLite3

let knowledgeSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func knowledgeSQLiteCancellationProgressHandler(
  _ context: UnsafeMutableRawPointer?
) -> Int32 {
  _ = context
  return Task.isCancelled ? 1 : 0
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

public enum KnowledgeDatabaseWALCheckpointMode: Sendable {
  case passive
  case full
  case restart
  case truncate

  var sqliteMode: Int32 {
    switch self {
    case .passive: return SQLITE_CHECKPOINT_PASSIVE
    case .full: return SQLITE_CHECKPOINT_FULL
    case .restart: return SQLITE_CHECKPOINT_RESTART
    case .truncate: return SQLITE_CHECKPOINT_TRUNCATE
    }
  }
}

final class KnowledgeDatabase: @unchecked Sendable, KnowledgeBackupSnapshotSource {
  static let currentSchemaVersion = 9

  let lock = NSLock()
  /// Immutable flat vector snapshots keyed by model and dimension.  All
  /// access occurs while `lock` is held by the database methods; the snapshot
  /// itself is Sendable and never mutated after insertion.
  let semanticFlatVectorIndexes = KnowledgeSemanticVectorFlatIndexCache()
  var semanticFlatVectorIndexChangeToken: Int64 = 0
  let statementCache = SQLitePreparedStatementCache()
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
    _ = sqlite3_busy_timeout(database, 5_000)

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
      statementCache.finalizeAll()
      sqlite3_close(database)
      handle = nil
      throw error
    }
  }

  deinit {
    statementCache.finalizeAll()
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
    _ = sqlite3_busy_timeout(database, 5_000)
  }

}
