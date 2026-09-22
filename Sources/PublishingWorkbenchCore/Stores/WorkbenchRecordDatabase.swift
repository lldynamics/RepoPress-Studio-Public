import Foundation
import SQLite3

/// Short-lived connections are used only inside the persistence file lock.
/// FULL synchronization protects the record commit; Markdown objects are
/// immutable and written before this transaction begins.
final class WorkbenchRecordDatabase {
  private var handle: OpaquePointer?
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(url: URL, create: Bool = false, readOnly: Bool = false) throws {
    var opened: OpaquePointer?
    let flags =
      SQLITE_OPEN_FULLMUTEX
      | (readOnly
        ? SQLITE_OPEN_READONLY
        : (create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE))
    let result = sqlite3_open_v2(url.path, &opened, flags, nil)
    guard result == SQLITE_OK, let opened else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开文档记录数据库。"
      if let opened { sqlite3_close(opened) }
      throw WorkbenchRecordStorageError.database(message)
    }
    handle = opened
    sqlite3_busy_timeout(handle, 5_000)
    do {
      let version = try scalar("PRAGMA user_version")
      guard (1...2).contains(version) || (create && version == 0) else {
        throw WorkbenchRecordStorageError.unsupportedVersion("不支持的文档数据库版本：\(version)")
      }
      try execute("PRAGMA synchronous=FULL")
      if version == 0 {
        try execute(
          """
          BEGIN IMMEDIATE;
          CREATE TABLE records (
            collection TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL,
            payload BLOB NOT NULL, digest TEXT NOT NULL,
            PRIMARY KEY(collection,id));
          CREATE TABLE storage_state (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
          INSERT INTO storage_state(id,revision) VALUES(1,0);
          PRAGMA user_version=2;
          COMMIT;
          """)
      } else if version == 1 && !readOnly {
        try execute(
          """
          BEGIN IMMEDIATE;
          CREATE TABLE IF NOT EXISTS storage_state (
            id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
          INSERT OR IGNORE INTO storage_state(id,revision) VALUES(1,0);
          PRAGMA user_version=2;
          COMMIT;
          """)
      }
      let schemaProbe = try prepare(
        "SELECT collection,id,position,payload,digest FROM records LIMIT 0")
      sqlite3_finalize(schemaProbe)
      _ = try revision
    } catch {
      sqlite3_close(handle)
      handle = nil
      throw error
    }
  }

  deinit { if let handle { sqlite3_close(handle) } }

  var revision: Int {
    get throws {
      if try scalar("PRAGMA user_version") == 1,
        try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='storage_state'")
          == 0
      {
        return 0
      }
      guard try scalar("SELECT count(*) FROM storage_state") == 1 else {
        throw WorkbenchRecordStorageError.invalidData("文档数据库修订记录无效。")
      }
      let revision = try scalar("SELECT revision FROM storage_state WHERE id=1")
      guard revision >= 0 else { throw WorkbenchRecordStorageError.invalidData("文档数据库修订号无效。") }
      return revision
    }
  }

  func records() throws -> [WorkbenchStorageRecord] {
    let statement = try prepare(
      "SELECT collection,id,position,payload,digest FROM records ORDER BY collection,position")
    defer { sqlite3_finalize(statement) }
    var result: [WorkbenchStorageRecord] = []
    var totalBytes = 0
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW,
        let collection = sqlite3_column_text(statement, 0),
        let id = sqlite3_column_text(statement, 1),
        let digest = sqlite3_column_text(statement, 4)
      else { throw failure() }
      let byteCount = Int(sqlite3_column_bytes(statement, 3))
      totalBytes += byteCount
      guard byteCount > 0,
        totalBytes <= WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount,
        let bytes = sqlite3_column_blob(statement, 3)
      else { throw WorkbenchRecordStorageError.invalidData("文档记录大小超出限制。") }
      let data = Data(bytes: bytes, count: byteCount)
      guard WorkbenchRecordPayload.digest(data) == String(cString: digest) else {
        throw WorkbenchRecordStorageError.invalidData("文档记录校验失败。")
      }
      result.append(
        WorkbenchStorageRecord(
          collection: String(cString: collection), id: String(cString: id),
          position: Int(sqlite3_column_int64(statement, 2)), data: data))
    }
    return result
  }

  /// Unchanged rows are never rewritten. All deletions and replacements belong
  /// to one transaction, so interrupted commits expose either complete version.
  @discardableResult
  func replace(with records: [WorkbenchStorageRecord]) throws -> Int {
    try execute("BEGIN IMMEDIATE")
    do {
      let existing = try self.records()
      func key(_ row: WorkbenchStorageRecord) -> String { row.collection + "/" + row.id }
      let previous = Dictionary(uniqueKeysWithValues: existing.map { (key($0), $0) })
      let desired = Set(records.map(key))
      var changed = 0
      let upsert = try prepare(
        """
        INSERT INTO records(collection,id,position,payload,digest) VALUES(?,?,?,?,?)
        ON CONFLICT(collection,id) DO UPDATE SET
        position=excluded.position,payload=excluded.payload,digest=excluded.digest
        """)
      defer { sqlite3_finalize(upsert) }
      let delete = try prepare("DELETE FROM records WHERE collection=? AND id=?")
      defer { sqlite3_finalize(delete) }
      for row in records where previous[key(row)] != row {
        sqlite3_reset(upsert)
        sqlite3_clear_bindings(upsert)
        try bind(row.collection, at: 1, to: upsert)
        try bind(row.id, at: 2, to: upsert)
        guard sqlite3_bind_int64(upsert, 3, Int64(row.position)) == SQLITE_OK else {
          throw failure()
        }
        let bound = row.data.withUnsafeBytes {
          sqlite3_bind_blob(upsert, 4, $0.baseAddress, Int32($0.count), Self.transient)
        }
        guard bound == SQLITE_OK else { throw failure() }
        try bind(WorkbenchRecordPayload.digest(row.data), at: 5, to: upsert)
        guard sqlite3_step(upsert) == SQLITE_DONE else { throw failure() }
        changed += 1
      }
      for row in existing where !desired.contains(key(row)) {
        sqlite3_reset(delete)
        sqlite3_clear_bindings(delete)
        try bind(row.collection, at: 1, to: delete)
        try bind(row.id, at: 2, to: delete)
        guard sqlite3_step(delete) == SQLITE_DONE else { throw failure() }
        changed += 1
      }
      if changed > 0 { try execute("UPDATE storage_state SET revision=revision+1 WHERE id=1") }
      try execute("COMMIT")
      return changed
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// SQLite's backup API produces a consistent standalone database, including
  /// data that might still be in a journal. The caller atomically installs it.
  func backup(to destination: URL) throws {
    var target: OpaquePointer?
    guard
      sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        == SQLITE_OK,
      let target
    else {
      if let target { sqlite3_close(target) }
      throw WorkbenchRecordStorageError.database("无法创建文档恢复数据库。")
    }
    defer { sqlite3_close(target) }
    guard let backup = sqlite3_backup_init(target, "main", handle, "main") else {
      throw WorkbenchRecordStorageError.database(String(cString: sqlite3_errmsg(target)))
    }
    let result = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finished == SQLITE_OK else {
      throw WorkbenchRecordStorageError.database(String(cString: sqlite3_errmsg(target)))
    }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }

  private func scalar(_ sql: String) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure()
    }
    return statement
  }

  private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
    let code = text.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    guard code == SQLITE_OK else { throw failure() }
  }

  private func failure() -> WorkbenchRecordStorageError {
    .database(String(cString: sqlite3_errmsg(handle)))
  }
}
