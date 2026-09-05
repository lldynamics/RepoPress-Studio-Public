import Foundation
import SQLite3
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RSSReaderBackupServiceTests: XCTestCase {
  func testCancelledBackupStepCleansTemporaryFileAndPreservesDestination() async throws {
    let rootURL = temporaryRoot("rss-backup-cancel")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.sqlite")
    _ = try makeVersionSixDatabase(at: sourceURL)
    let destinationURL = rootURL.appendingPathComponent("existing.sqlite")
    let sentinel = Data("preserve destination".utf8)
    try sentinel.write(to: destinationURL)

    let gate = RSSBackupStepGate()
    let service = RSSReaderBackupService(backupStepHook: { _ in
      gate.signalStep()
      gate.waitUntilCancellationIsForwarded()
    })
    let worker = Task.detached {
      try service.createBackup(from: sourceURL, at: destinationURL)
    }

    XCTAssertTrue(gate.waitForStep(timeout: 2))
    let cancellationStartedAt = Date()
    worker.cancel()
    gate.allowCancellationToProceed()
    let result = await worker.result
    guard case .failure(let error) = result else {
      return XCTFail("cancelled RSS backup unexpectedly succeeded")
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 1)
    XCTAssertEqual(try Data(contentsOf: destinationURL), sentinel)
    let temporaryEntries = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
      .filter { $0.hasPrefix(".existing.sqlite.creating-") }
    XCTAssertEqual(temporaryEntries, [])
  }

  func testVersionFiveBackupPassesInspectionAndMigratesWhenOpened() throws {
    let rootURL = temporaryRoot("rss-backup-v5-compatibility")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("v5.sqlite")
    let installedURL = rootURL.appendingPathComponent("installed.sqlite")
    let article = try makeVersionFiveDatabase(at: sourceURL)
    let service = RSSReaderBackupService()

    let inspection = try service.inspectBackup(at: sourceURL)
    XCTAssertEqual(inspection.databaseSchemaVersion, 5)
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'rss_article_full_text';",
        at: sourceURL
      ),
      0
    )

    // Workspace restore installs the validated file first. Opening it through
    // the normal database entry point then performs the v5 -> v6 migration.
    try FileManager.default.copyItem(at: sourceURL, to: installedURL)
    let migrated = try RSSReaderDatabase(fileURL: installedURL)
    XCTAssertEqual(
      try migrated.scalarInt("PRAGMA user_version;"),
      RSSReaderDatabase.currentSchemaVersion
    )
    XCTAssertEqual(try migrated.article(id: article.id)?.contentHTML, "<p>旧版 Feed 正文</p>")
    XCTAssertEqual(try migrated.scalarInt("SELECT COUNT(*) FROM rss_article_full_text;"), 0)
  }

  func testVersionSixBackupRequiresTheFullTextTable() throws {
    let rootURL = temporaryRoot("rss-backup-v6-full-text")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("v6.sqlite")
    let missingTableURL = rootURL.appendingPathComponent("missing-full-text.sqlite")
    _ = try makeVersionSixDatabase(at: sourceURL)
    let service = RSSReaderBackupService()

    XCTAssertEqual(
      try service.inspectBackup(at: sourceURL).databaseSchemaVersion,
      RSSReaderDatabase.currentSchemaVersion
    )
    try FileManager.default.copyItem(at: sourceURL, to: missingTableURL)
    try executeSQLite("DROP TABLE rss_article_full_text;", at: missingTableURL)

    XCTAssertThrowsError(try service.inspectBackup(at: missingTableURL)) { error in
      guard case .databaseIntegrity(let detail)? = error as? RSSReaderBackupError else {
        return XCTFail("应拒绝缺少 v6 全文表的备份，实际为：\(error)")
      }
      XCTAssertTrue(detail.contains("必需数据表"), "实际错误：\(detail)")
    }
  }

  func testUnknownDatabaseVersionsAreRejected() throws {
    let rootURL = temporaryRoot("rss-backup-unknown-version")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let databaseURL = rootURL.appendingPathComponent("future.sqlite")
    _ = try makeVersionSixDatabase(at: databaseURL)
    let unknownVersion = RSSReaderDatabase.currentSchemaVersion + 1
    try executeSQLite(
      "PRAGMA user_version = \(unknownVersion); PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode = DELETE;",
      at: databaseURL
    )
    removeSidecars(at: databaseURL)

    XCTAssertThrowsError(try RSSReaderBackupService().inspectBackup(at: databaseURL)) { error in
      guard case .unsupportedDatabaseVersion(let found, let supported)? =
        error as? RSSReaderBackupError else {
        return XCTFail("应拒绝未知 RSS 数据库版本，实际为：\(error)")
      }
      XCTAssertEqual(found, unknownVersion)
      XCTAssertEqual(supported, RSSReaderDatabase.currentSchemaVersion)
    }
  }

  func testVersionFiveStillRequiresItsLegacyTables() throws {
    let rootURL = temporaryRoot("rss-backup-v5-required-tables")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let databaseURL = rootURL.appendingPathComponent("incomplete-v5.sqlite")
    _ = try makeVersionFiveDatabase(at: databaseURL)
    try executeSQLite("DROP TABLE rss_article_highlights;", at: databaseURL)

    XCTAssertThrowsError(try RSSReaderBackupService().inspectBackup(at: databaseURL)) { error in
      guard case .databaseIntegrity(let detail)? = error as? RSSReaderBackupError else {
        return XCTFail("应拒绝缺少 v5 必需表的备份，实际为：\(error)")
      }
      XCTAssertTrue(detail.contains("必需数据表"), "实际错误：\(detail)")
    }
  }

  private func makeVersionFiveDatabase(at fileURL: URL) throws -> RSSArticle {
    let feed = RSSFeed(
      id: UUID(),
      title: "v5 订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/v5.xml"))
    )
    let article = RSSArticle(
      id: "v5-article",
      feedID: feed.id,
      title: "v5 文章",
      contentHTML: "<p>旧版 Feed 正文</p>"
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
    }
    try executeSQLite(
      "DROP TABLE rss_article_full_text; PRAGMA user_version = 5; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode = DELETE;",
      at: fileURL
    )
    removeSidecars(at: fileURL)
    return article
  }

  private func makeVersionSixDatabase(at fileURL: URL) throws -> RSSArticle {
    let feed = RSSFeed(
      id: UUID(),
      title: "v6 订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/v6.xml"))
    )
    let article = RSSArticle(
      id: "v6-article",
      feedID: feed.id,
      title: "v6 文章",
      contentHTML: "<p>Feed 正文</p>"
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
      try database.upsertFullTextRecord(
        .ready(
          articleID: article.id,
          contentHTML: "<p>独立原站全文</p>",
          plainText: "独立原站全文",
          confidence: 0.9
        )
      )
    }
    try executeSQLite(
      "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode = DELETE;",
      at: fileURL
    )
    removeSidecars(at: fileURL)
    return article
  }

  private func temporaryRoot(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func removeSidecars(at databaseURL: URL) {
    for suffix in ["-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: databaseURL.path + suffix)
      )
    }
  }

  private func executeSQLite(_ sql: String, at fileURL: URL) throws {
    var handle: OpaquePointer?
    let openResult = sqlite3_open_v2(
      fileURL.path,
      &handle,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openResult == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      if let handle { sqlite3_close(handle) }
      throw NSError(domain: "RSSReaderBackupServiceTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message
      ])
    }
    defer { sqlite3_close(handle) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw NSError(domain: "RSSReaderBackupServiceTests", code: 2, userInfo: [
        NSLocalizedDescriptionKey: message
      ])
    }
  }

  private func querySQLiteInt(_ sql: String, at fileURL: URL) throws -> Int {
    var handle: OpaquePointer?
    let openResult = sqlite3_open_v2(
      fileURL.path,
      &handle,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openResult == SQLITE_OK, let handle else {
      if let handle { sqlite3_close(handle) }
      throw NSError(domain: "RSSReaderBackupServiceTests", code: 3)
    }
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw NSError(domain: "RSSReaderBackupServiceTests", code: 4)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw NSError(domain: "RSSReaderBackupServiceTests", code: 5)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }
}

private final class RSSBackupStepGate: Sendable {
  private let stepped = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func signalStep() { stepped.signal() }
  func waitForStep(timeout: TimeInterval) -> Bool {
    stepped.wait(timeout: .now() + timeout) == .success
  }
  func waitUntilCancellationIsForwarded() { release.wait() }
  func allowCancellationToProceed() { release.signal() }
}
