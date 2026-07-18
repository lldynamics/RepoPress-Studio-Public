import Foundation
import SQLite3
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeDatabaseCompatibilityTests: XCTestCase {
  func testVersion4DatabaseMigratesManagementTablesAtomically() throws {
    let rootURL = temporaryDirectory(named: "knowledge-v4-migration")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let databaseURL = rootURL.appendingPathComponent("library.sqlite")
    var service: KnowledgeLibraryService? = KnowledgeLibraryService(rootURL: rootURL)
    _ = try service?.documents()
    service = nil

    try executeSQLite(
      """
      DROP TABLE knowledge_backlinks;
      DROP TABLE knowledge_annotations;
      DROP TABLE knowledge_recycle_bin;
      PRAGMA user_version = 4;
      """,
      at: databaseURL
    )

    let migratedService = KnowledgeLibraryService(rootURL: rootURL)
    XCTAssertNoThrow(try migratedService.documents())
    XCTAssertEqual(
      try querySQLiteInt("PRAGMA user_version;", at: databaseURL),
      KnowledgeDatabase.currentSchemaVersion
    )
    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_recycle_bin';",
      at: databaseURL
    ), 1)
    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_annotations';",
      at: databaseURL
    ), 1)
    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_backlinks';",
      at: databaseURL
    ), 1)
  }

  func testFutureDatabaseVersionIsRejectedWithoutRewritingDatabase() throws {
    let rootURL = temporaryDirectory(named: "knowledge-future-schema")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let databaseURL = rootURL.appendingPathComponent("library.sqlite")
    let futureVersion = KnowledgeDatabase.currentSchemaVersion + 7

    try executeSQLite(
      """
      CREATE TABLE future_marker (value TEXT NOT NULL);
      INSERT INTO future_marker VALUES ('preserve-me');
      PRAGMA user_version = \(futureVersion);
      """,
      at: databaseURL
    )
    XCTAssertEqual(try querySQLiteText("PRAGMA journal_mode;", at: databaseURL), "delete")

    let service = KnowledgeLibraryService(rootURL: rootURL)
    do {
      _ = try service.documents()
      XCTFail("未来版本数据库必须被拒绝")
    } catch let error as KnowledgeLibraryError {
      guard case .unsupportedDatabaseVersion(let found, let supported) = error else {
        return XCTFail("应报告数据库版本不兼容，实际为：\(error)")
      }
      XCTAssertEqual(found, futureVersion)
      XCTAssertEqual(supported, KnowledgeDatabase.currentSchemaVersion)
    }

    XCTAssertEqual(try querySQLiteInt("PRAGMA user_version;", at: databaseURL), futureVersion)
    XCTAssertEqual(try querySQLiteText("SELECT value FROM future_marker;", at: databaseURL), "preserve-me")
    XCTAssertEqual(try querySQLiteText("PRAGMA journal_mode;", at: databaseURL), "delete")
  }

  func testBackupManifestWithFutureDatabaseVersionIsRejectedBeforeRestore() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-future-backup")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    let backupURL = rootURL.appendingPathComponent("future.pslibrarybackup", isDirectory: true)
    try "# 可恢复资料\n\n用于验证未来数据库版本护栏。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    _ = try await service.createBackup(at: backupURL, applicationVersion: "test")

    let manifestURL = backupURL.appendingPathComponent(KnowledgeLibraryBackupService.manifestFileName)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var manifest = try decoder.decode(
      KnowledgeLibraryBackupManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    manifest.databaseUserVersion = KnowledgeDatabase.currentSchemaVersion + 1
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

    do {
      _ = try await service.inspectBackup(at: backupURL)
      XCTFail("未来版本资料库备份必须被拒绝")
    } catch let error as KnowledgeLibraryBackupError {
      guard case .unsupportedDatabaseVersion(let found, let supported) = error else {
        return XCTFail("应报告备份数据库版本不兼容，实际为：\(error)")
      }
      XCTAssertEqual(found, KnowledgeDatabase.currentSchemaVersion + 1)
      XCTAssertEqual(supported, KnowledgeDatabase.currentSchemaVersion)
    }
  }

  private func temporaryDirectory(named name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func executeSQLite(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw NSError(domain: "KnowledgeDatabaseCompatibilityTests.sqlite", code: 1)
    }
    defer { sqlite3_close(database) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "SQLite fixture failed"
      sqlite3_free(errorMessage)
      throw NSError(
        domain: "KnowledgeDatabaseCompatibilityTests.sqlite",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  private func querySQLiteInt(_ sql: String, at databaseURL: URL) throws -> Int {
    Int(try querySQLiteInt64(sql, at: databaseURL))
  }

  private func querySQLiteInt64(_ sql: String, at databaseURL: URL) throws -> Int64 {
    try withSQLiteStatement(sql, at: databaseURL) { statement in
      sqlite3_column_int64(statement, 0)
    }
  }

  private func querySQLiteText(_ sql: String, at databaseURL: URL) throws -> String {
    try withSQLiteStatement(sql, at: databaseURL) { statement in
      guard let value = sqlite3_column_text(statement, 0) else { return "" }
      return String(cString: value)
    }
  }

  private func withSQLiteStatement<T>(
    _ sql: String,
    at databaseURL: URL,
    _ body: (OpaquePointer?) throws -> T
  ) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw NSError(domain: "KnowledgeDatabaseCompatibilityTests.sqlite", code: 3)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw NSError(domain: "KnowledgeDatabaseCompatibilityTests.sqlite", code: 4)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw NSError(domain: "KnowledgeDatabaseCompatibilityTests.sqlite", code: 5)
    }
    return try body(statement)
  }
}
