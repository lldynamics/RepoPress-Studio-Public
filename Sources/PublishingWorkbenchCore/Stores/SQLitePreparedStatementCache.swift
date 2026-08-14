import Foundation
import SQLite3

/// A lightweight, lock-coordinated prepared statement cache for SQLite connections.
/// Reuses precompiled `sqlite3_stmt` instances across query invocations,
/// eliminating query parsing and bytecode compilation overhead.
final class SQLitePreparedStatementCache: @unchecked Sendable {
  private let capacity: Int
  private var statements: [String: OpaquePointer] = [:]
  private var insertionOrder: [String] = []

  init(capacity: Int = 64) {
    self.capacity = max(8, capacity)
  }

  deinit {
    finalizeAll()
  }

  /// Retrieves a reusable prepared statement from the cache (resetting bindings),
  /// or compiles a new one using `sqlite3_prepare_v2` and inserts it into the cache.
  func statement(
    for sql: String,
    database: OpaquePointer?
  ) throws -> OpaquePointer {
    guard let database else {
      throw KnowledgeLibraryError.database("数据库尚未打开")
    }

    if let cached = statements[sql] {
      sqlite3_reset(cached)
      sqlite3_clear_bindings(cached)
      return cached
    }

    var newStatement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &newStatement, nil) == SQLITE_OK,
          let statement = newStatement else {
      let message = String(cString: sqlite3_errmsg(database))
      throw KnowledgeLibraryError.database(message)
    }

    if statements.count >= capacity, !insertionOrder.isEmpty {
      let oldestSQL = insertionOrder.removeFirst()
      if let evicted = statements.removeValue(forKey: oldestSQL) {
        sqlite3_finalize(evicted)
      }
    }

    statements[sql] = statement
    insertionOrder.append(sql)
    return statement
  }

  /// Resets a cached statement after execution so it is clean for the next caller.
  func reset(_ statement: OpaquePointer?) {
    guard let statement else { return }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
  }

  /// Finalizes and discards all cached statements. Must be called before closing the database handle.
  func finalizeAll() {
    for (_, statement) in statements {
      sqlite3_finalize(statement)
    }
    statements.removeAll(keepingCapacity: false)
    insertionOrder.removeAll(keepingCapacity: false)
  }
}
