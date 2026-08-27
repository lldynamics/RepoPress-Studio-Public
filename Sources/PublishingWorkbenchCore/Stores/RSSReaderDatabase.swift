import Foundation
import SQLite3

struct RSSReaderDatabaseStatistics: Equatable, Sendable {
  var feedCount: Int
  var articleCount: Int
  var highlightCount: Int
}

public enum RSSReaderDatabaseWALCheckpointMode: Sendable {
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

/// SQLite access is serialized by `lock`, so the connection can be shared by
/// the main-actor store and a detached read-only search task without moving
/// the store itself off the main actor.
final class RSSReaderDatabase: @unchecked Sendable {
  static let currentSchemaVersion = 6

  let fileURL: URL
  var handle: OpaquePointer?
  let lock = NSLock()
  let statementCache = SQLitePreparedStatementCache()

  init(fileURL: URL, fileManager: FileManager = .default) throws {
    self.fileURL = fileURL
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      let message =
        database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
        ?? "无法打开 RSS SQLite 数据库"
      if let database { sqlite3_close(database) }
      throw RSSReaderError.persistence(message)
    }
    handle = database
    _ = sqlite3_busy_timeout(database, 5_000)

    do {
      try execute("PRAGMA foreign_keys = ON;")
      let version = try scalarInt("PRAGMA user_version;")
      guard version <= Self.currentSchemaVersion else {
        throw RSSReaderError.persistence(
          "RSS SQLite 缓存版本 \(version) 高于当前支持版本 \(Self.currentSchemaVersion)"
        )
      }
      try migrate(from: version)
      try execute("PRAGMA journal_mode = WAL;")
      try execute("PRAGMA synchronous = NORMAL;")
    } catch {
      statementCache.finalizeAll()
      sqlite3_close(database)
      handle = nil
      throw error
    }
  }

  init(readOnlyFileURL fileURL: URL) throws {
    self.fileURL = fileURL
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      let message =
        database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
        ?? "无法只读打开 RSS SQLite 数据库"
      if let database { sqlite3_close(database) }
      throw RSSReaderError.persistence(message)
    }
    handle = database
    _ = sqlite3_busy_timeout(database, 5_000)

    do {
      let version = try scalarInt("PRAGMA user_version;")
      guard version == Self.currentSchemaVersion else {
        throw RSSReaderError.persistence(
          "RSS 只读数据库版本 \(version) 与当前版本 \(Self.currentSchemaVersion) 不一致"
        )
      }
      try withLock { try validateSchemaContractUnlocked() }
    } catch {
      statementCache.finalizeAll()
      sqlite3_close(database)
      handle = nil
      throw error
    }
  }

  deinit {
    statementCache.finalizeAll()
    if let handle { sqlite3_close(handle) }
  }

  var isEmpty: Bool {
    get throws {
      let statistics = try statistics()
      return statistics.feedCount == 0 && statistics.articleCount == 0
    }
  }

}
