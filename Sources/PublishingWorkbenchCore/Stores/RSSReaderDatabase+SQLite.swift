import Foundation
import SQLite3

private let rssSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension RSSReaderDatabase {
  func columnExistsUnlocked(table: String, column: String) throws -> Bool {
    let statement = try prepareUnlocked("PRAGMA table_info(\(table));")
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if text(statement, 1)?.caseInsensitiveCompare(column) == .orderedSame {
        return true
      }
    }
    try checkStatementCompletion(statement)
    return false
  }

  func migrateLegacyFeedIssuesUnlocked() throws {
    let selectStatement = try prepareUnlocked(
      """
      SELECT id, last_error, last_refresh_attempt_at
      FROM rss_feeds
      WHERE last_issue_json IS NULL AND last_error IS NOT NULL AND last_error != '';
      """)
    var migratedValues: [(id: String, issueJSON: String)] = []
    while sqlite3_step(selectStatement) == SQLITE_ROW {
      guard let id = text(selectStatement, 0),
        let message = text(selectStatement, 1)
      else { continue }
      let issue = RSSFeedIssue(
        stage: .transport,
        category: .unknown,
        retryStrategy: .automatic,
        userMessage: message,
        technicalDetail: "由旧版 SQLite last_error 迁移",
        occurredAt: optionalDate(selectStatement, 2) ?? Date()
      )
      if let issueJSON = try encodeIssue(issue) {
        migratedValues.append((id, issueJSON))
      }
    }
    try checkStatementCompletion(selectStatement)
    sqlite3_finalize(selectStatement)

    guard !migratedValues.isEmpty else { return }
    let updateStatement = try prepareUnlocked(
      "UPDATE rss_feeds SET last_issue_json = ? WHERE id = ?;"
    )
    defer { sqlite3_finalize(updateStatement) }
    for value in migratedValues {
      sqlite3_reset(updateStatement)
      sqlite3_clear_bindings(updateStatement)
      bind(value.issueJSON, at: 1, to: updateStatement)
      bind(value.id, at: 2, to: updateStatement)
      guard sqlite3_step(updateStatement) == SQLITE_DONE else {
        throw databaseErrorUnlocked()
      }
    }
  }

  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  func transactionUnlocked(_ body: () throws -> Void) throws {
    try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
    do {
      try body()
      try executeUnlocked("COMMIT;")
    } catch {
      try rethrowAfterRollbackUnlocked(error)
    }
  }

  func rethrowAfterRollbackUnlocked(_ primaryError: Error) throws -> Never {
    do {
      try executeUnlocked("ROLLBACK;")
    } catch {
      throw RSSReaderError.persistence(
        "RSS 数据库操作失败：\(primaryError.localizedDescription)；回滚失败：\(error.localizedDescription)"
      )
    }
    throw primaryError
  }

  func execute(_ sql: String) throws {
    try withLock { try executeUnlocked(sql) }
  }

  func executeUnlocked(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<Int8>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message: String
      if let errorMessage {
        message = String(cString: errorMessage)
      } else {
        message = databaseErrorUnlocked().localizedDescription
      }
      sqlite3_free(errorMessage)
      throw RSSReaderError.persistence(message)
    }
  }

  func scalarInt(_ sql: String) throws -> Int {
    try withLock { try scalarIntUnlocked(sql) }
  }

  func scalarIntUnlocked(_ sql: String) throws -> Int {
    try withCachedStatementUnlocked(sql) { statement in
      let result = sqlite3_step(statement)
      guard result == SQLITE_ROW else { throw databaseErrorUnlocked() }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  func cachedStatementUnlocked(_ sql: String) throws -> OpaquePointer {
    guard let handle else { throw databaseErrorUnlocked() }
    return try statementCache.statement(for: sql, database: handle)
  }

  func resetCachedStatementUnlocked(_ statement: OpaquePointer?) {
    statementCache.reset(statement)
  }

  func withCachedStatementUnlocked<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    let statement = try cachedStatementUnlocked(sql)
    defer { resetCachedStatementUnlocked(statement) }
    return try body(statement)
  }

  func withCachedStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    try withLock {
      try withCachedStatementUnlocked(sql, body)
    }
  }

  func prepareUnlocked(_ sql: String) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw databaseErrorUnlocked()
    }
    return statement
  }

  func checkStatementCompletion(_ statement: OpaquePointer?) throws {
    let result = sqlite3_errcode(handle)
    guard result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE else {
      throw databaseErrorUnlocked()
    }
    _ = statement
  }

  func databaseErrorUnlocked() -> RSSReaderError {
    RSSReaderError.persistence(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 操作失败")
  }

  func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
    _ = value.withCString { pointer in
      sqlite3_bind_text(statement, index, pointer, -1, rssSQLiteTransient)
    }
  }

  func bindOptional(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    bind(value, at: index, to: statement)
  }

  func bindOptional(_ value: Double?, at index: Int32, to statement: OpaquePointer?) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_double(statement, index, value)
  }

  func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
  }

  func date(_ statement: OpaquePointer?, _ index: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
  }

  func optionalDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : date(statement, index)
  }

  func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil : sqlite3_column_double(statement, index)
  }

  func optionalURL(_ statement: OpaquePointer?, _ index: Int32) -> URL? {
    text(statement, index).flatMap(URL.init(string:))
  }

  func requiredURL(_ statement: OpaquePointer?, _ index: Int32, field: String) throws -> URL
  {
    guard let value = optionalURL(statement, index) else {
      throw RSSReaderError.persistence("\(field) 缺少有效 URL")
    }
    return value
  }

  func requiredUUID(_ statement: OpaquePointer?, _ index: Int32, field: String) throws
    -> UUID
  {
    guard let value = text(statement, index), let uuid = UUID(uuidString: value) else {
      throw RSSReaderError.persistence("\(field) 缺少有效 UUID")
    }
    return uuid
  }

  func checkpointWALUnlocked(mode: RSSReaderDatabaseWALCheckpointMode = .passive) throws {
    guard let handle else { throw RSSReaderError.persistence("数据库未打开") }
    var logSize: Int32 = 0
    var checkpointedCount: Int32 = 0
    let rc = sqlite3_wal_checkpoint_v2(handle, nil, mode.sqliteMode, &logSize, &checkpointedCount)
    guard rc == SQLITE_OK else { throw databaseErrorUnlocked() }
  }

  public func checkpointWAL(mode: RSSReaderDatabaseWALCheckpointMode = .passive) throws {
    try withLock { try checkpointWALUnlocked(mode: mode) }
  }

  public func optimizeDatabase() throws {
    try withLock { try executeUnlocked("PRAGMA optimize;") }
  }
}
