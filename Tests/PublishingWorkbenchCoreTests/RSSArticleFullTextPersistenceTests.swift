import Foundation
import SQLite3
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RSSArticleFullTextPersistenceTests: XCTestCase {
  func testV5MigrationCreatesFullTextTableAndPreservesArticleContent() throws {
    let rootURL = temporaryRoot("rss-full-text-v5-migration")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = try makeFeed()
    let originalContent = "<p>RSS feed 原始正文，不应被迁移覆盖。</p>"
    let article = RSSArticle(
      id: "migration-article",
      feedID: feed.id,
      title: "迁移文章",
      link: try XCTUnwrap(URL(string: "https://example.com/posts/migration")),
      summaryHTML: "<p>RSS 摘要</p>",
      contentHTML: originalContent,
      webPageSnapshotHTML: "<p>旧快照</p>"
    )

    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
    }

    // Remove the v6-only table and mark the otherwise valid database as v5.
    // Reopening it exercises the same migration path used by an existing v5
    // installation while keeping the article data intact.
    try executeSQLite(
      "DROP TABLE rss_article_full_text; PRAGMA user_version = 5;",
      at: fileURL
    )

    let migrated = try RSSReaderDatabase(fileURL: fileURL)
    XCTAssertEqual(
      try migrated.scalarInt("PRAGMA user_version;"),
      RSSReaderDatabase.currentSchemaVersion
    )
    XCTAssertEqual(
      try migrated.scalarInt("SELECT COUNT(*) FROM rss_article_full_text;"),
      0
    )
    XCTAssertNil(try migrated.fullTextRecord(articleID: article.id))
    XCTAssertEqual(try migrated.article(id: article.id)?.contentHTML, originalContent)
    XCTAssertEqual(
      try migrated.article(id: article.id)?.webPageSnapshotHTML,
      "<p>旧快照</p>"
    )
  }

  func testFailedLegacyMigrationRollsBackDDLDataAndUserVersion() throws {
    let rootURL = temporaryRoot("rss-legacy-migration-rollback")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = try makeFeed()
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
    }
    try executeSQLite(
      """
      UPDATE rss_feeds
      SET last_error = 'legacy failure', last_issue_json = NULL;
      DROP TABLE rss_article_full_text;
      PRAGMA user_version = 1;
      CREATE TRIGGER block_legacy_issue_migration
      BEFORE UPDATE OF last_issue_json ON rss_feeds
      BEGIN
        SELECT RAISE(ABORT, 'blocked migration');
      END;
      """,
      at: fileURL
    )

    XCTAssertThrowsError(try RSSReaderDatabase(fileURL: fileURL))
    XCTAssertEqual(try querySQLiteInt("PRAGMA user_version;", at: fileURL), 1)
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM sqlite_master "
          + "WHERE type = 'table' AND name = 'rss_article_full_text';",
        at: fileURL
      ),
      0
    )
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM rss_feeds WHERE last_issue_json IS NULL;",
        at: fileURL
      ),
      1
    )
  }

  func testMalformedV5FullTextTableDoesNotAdvanceSchemaVersion() throws {
    let rootURL = temporaryRoot("rss-malformed-v5-migration")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    do {
      _ = try RSSReaderDatabase(fileURL: fileURL)
    }
    try executeSQLite(
      """
      DROP TABLE rss_article_full_text;
      CREATE TABLE rss_article_full_text (
        article_id TEXT PRIMARY KEY NOT NULL,
        status TEXT NOT NULL,
        attempted_at REAL NOT NULL
      );
      PRAGMA user_version = 5;
      """,
      at: fileURL
    )

    XCTAssertThrowsError(try RSSReaderDatabase(fileURL: fileURL))
    XCTAssertEqual(try querySQLiteInt("PRAGMA user_version;", at: fileURL), 5)
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM pragma_table_info('rss_article_full_text') "
          + "WHERE name = 'plain_text';",
        at: fileURL
      ),
      0
    )
  }

  func testFutureVersionIsRejectedBeforeJournalModeChanges() throws {
    let rootURL = temporaryRoot("rss-future-version")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    do {
      _ = try RSSReaderDatabase(fileURL: fileURL)
    }
    let futureVersion = RSSReaderDatabase.currentSchemaVersion + 1
    try executeSQLite(
      """
      PRAGMA journal_mode = DELETE;
      CREATE TABLE future_marker (value TEXT NOT NULL);
      INSERT INTO future_marker VALUES ('preserve-me');
      PRAGMA user_version = \(futureVersion);
      """,
      at: fileURL
    )
    XCTAssertEqual(try querySQLiteText("PRAGMA journal_mode;", at: fileURL), "delete")

    XCTAssertThrowsError(try RSSReaderDatabase(fileURL: fileURL))
    XCTAssertEqual(try querySQLiteInt("PRAGMA user_version;", at: fileURL), futureVersion)
    XCTAssertEqual(
      try querySQLiteText("SELECT value FROM future_marker;", at: fileURL),
      "preserve-me"
    )
    XCTAssertEqual(try querySQLiteText("PRAGMA journal_mode;", at: fileURL), "delete")
  }

  func testReadOnlyConnectionOpensWhileWriterHoldsImmediateTransaction() throws {
    let rootURL = temporaryRoot("rss-read-only-connection")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = try makeFeed()
    let article = RSSArticle(
      id: "read-only-article",
      feedID: feed.id,
      title: "只读连接",
      contentHTML: "<p>已提交正文</p>"
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
    }

    var writer: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(
        fileURL.path,
        &writer,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
      ),
      SQLITE_OK
    )
    let writerHandle = try XCTUnwrap(writer)
    defer {
      sqlite3_exec(writerHandle, "ROLLBACK;", nil, nil, nil)
      sqlite3_close(writerHandle)
    }
    XCTAssertEqual(
      sqlite3_exec(writerHandle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil),
      SQLITE_OK
    )

    let readOnly = try RSSReaderDatabase(readOnlyFileURL: fileURL)
    XCTAssertEqual(try readOnly.article(id: article.id)?.title, article.title)
  }

  func testReadyAndFailedRecordsRoundTripAndUpsertWithoutChangingArticleContent() throws {
    let rootURL = temporaryRoot("rss-full-text-round-trip")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = try makeFeed()
    let originalContent = "<p>Feed 正文保持不变。</p>"
    let article = RSSArticle(
      id: "round-trip-article",
      feedID: feed.id,
      title: "全文缓存",
      contentHTML: originalContent
    )
    let database = try RSSReaderDatabase(fileURL: fileURL)
    try database.upsertFeed(feed)
    try database.upsertArticles([article])

    let sourceURL = try XCTUnwrap(URL(string: "https://example.com/posts/full-text"))
    let resolvedURL = try XCTUnwrap(URL(string: "https://www.example.com/posts/full-text"))
    let attemptedAt = Date(timeIntervalSince1970: 1_700_000_000.25)
    let ready = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: "<article><p>原站完整正文。</p></article>",
      plainText: "原站完整正文。",
      sourceURL: sourceURL,
      resolvedURL: resolvedURL,
      extractorIdentifier: "readability",
      extractorVersion: "1",
      sourceETag: "\"abc\"",
      sourceLastModified: "Wed, 27 Aug 2026 08:00:00 GMT",
      sourceContentHash: "sha256:abc",
      confidence: 1.25,
      attemptedAt: attemptedAt
    )
    XCTAssertEqual(ready.status, .ready)
    XCTAssertEqual(ready.confidence, 1)

    try database.upsertFullTextRecord(ready)
    XCTAssertEqual(try database.fullTextRecord(articleID: article.id), ready)
    XCTAssertEqual(try database.article(id: article.id)?.contentHTML, originalContent)

    let retryAfter = Date(timeIntervalSince1970: 1_700_000_600.5)
    let failed = RSSArticleFullTextRecord.failed(
      articleID: article.id,
      sourceURL: sourceURL,
      resolvedURL: resolvedURL,
      extractorIdentifier: "readability",
      extractorVersion: "1",
      sourceETag: "\"def\"",
      sourceLastModified: "Wed, 27 Aug 2026 08:10:00 GMT",
      sourceContentHash: "sha256:def",
      confidence: -0.4,
      attemptedAt: attemptedAt.addingTimeInterval(60),
      retryAfter: retryAfter,
      failureMessage: "原站返回了登录页。"
    )
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(failed.confidence, 0)
    XCTAssertEqual(failed.contentHTML, "")
    XCTAssertEqual(failed.plainText, "")

    try database.upsertFullTextRecord(failed)
    XCTAssertEqual(try database.fullTextRecord(articleID: article.id), failed)
    XCTAssertEqual(try database.article(id: article.id)?.contentHTML, originalContent)
  }

  func testDeletingArticleCascadesItsFullTextRecord() throws {
    let rootURL = temporaryRoot("rss-full-text-cascade")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = try makeFeed()
    let article = RSSArticle(
      id: "cascade-article",
      feedID: feed.id,
      title: "级联删除",
      contentHTML: "<p>Feed 内容</p>"
    )
    let database = try RSSReaderDatabase(fileURL: fileURL)
    try database.upsertFeed(feed)
    try database.upsertArticles([article])
    try database.upsertFullTextRecord(
      .ready(
        articleID: article.id,
        contentHTML: "<p>独立全文</p>",
        plainText: "独立全文",
        confidence: 0.9
      )
    )
    XCTAssertNotNil(try database.fullTextRecord(articleID: article.id))

    try database.deleteArticles(ids: [article.id])

    XCTAssertNil(try database.fullTextRecord(articleID: article.id))
    XCTAssertEqual(
      try database.scalarInt("SELECT COUNT(*) FROM rss_article_full_text;"),
      0
    )
  }

  func testBackupContainsFullTextTableAndRecordWithoutChangingInspectionShape() throws {
    let rootURL = temporaryRoot("rss-full-text-backup")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("reader.sqlite")
    let backupURL = rootURL.appendingPathComponent("backup.sqlite")
    let feed = try makeFeed()
    let article = RSSArticle(
      id: "backup-article",
      feedID: feed.id,
      title: "备份全文",
      contentHTML: "<p>Feed 正文</p>"
    )
    do {
      let database = try RSSReaderDatabase(fileURL: sourceURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
      try database.upsertFullTextRecord(
        .rejected(
          articleID: article.id,
          sourceURL: article.link,
          extractorIdentifier: "readability",
          extractorVersion: "1",
          confidence: 0.2,
          failureMessage: "质量闸门拒绝"
        )
      )
    }

    let service = RSSReaderBackupService()
    let inspection = try service.createBackup(from: sourceURL, at: backupURL)
    XCTAssertEqual(inspection.databaseSchemaVersion, RSSReaderDatabase.currentSchemaVersion)
    XCTAssertEqual(
      try querySQLiteInt("SELECT COUNT(*) FROM rss_article_full_text;", at: backupURL),
      1
    )
    XCTAssertEqual(
      try querySQLiteText(
        "SELECT status FROM rss_article_full_text WHERE article_id = 'backup-article';",
        at: backupURL
      ),
      RSSArticleFullTextStatus.rejected.rawValue
    )
    XCTAssertEqual(
      try service.inspectBackup(at: backupURL),
      inspection
    )
  }

  func testReadyInitializerNormalizesAnEmptyResultToRejection() {
    let record = RSSArticleFullTextRecord(
      articleID: "empty-ready",
      status: .ready,
      extractorIdentifier: "readability",
      extractorVersion: "1"
    )

    XCTAssertEqual(record.status, .rejected)
    XCTAssertEqual(record.contentHTML, "")
    XCTAssertEqual(record.plainText, "")

    let plainTextOnly = RSSArticleFullTextRecord(
      articleID: "plain-only",
      status: .ready,
      plainText: "没有可渲染 HTML 的文本",
      confidence: 0.8
    )
    XCTAssertEqual(plainTextOnly.status, .rejected)
  }

  func testFeedRefreshKeepsIndependentFullTextAndItsSearchIndex() throws {
    let rootURL = temporaryRoot("rss-full-text-refresh")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let database = try RSSReaderDatabase(
      fileURL: rootURL.appendingPathComponent("reader.sqlite")
    )
    let feed = try makeFeed()
    let article = RSSArticle(
      id: "refresh-article",
      feedID: feed.id,
      title: "刷新测试",
      contentHTML: "<p>Feed 第一版摘要</p>"
    )
    try database.upsertFeed(feed)
    try database.upsertArticles([article])
    let fullText = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: "<article><p>独立全文</p></article>",
      plainText: "独立检索 extractedsentinel",
      confidence: 0.92,
      attemptedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try database.upsertFullTextRecord(fullText)
    XCTAssertTrue(
      try database.matchingArticleIDs(query: "extractedsentinel").contains(article.id)
    )

    var refreshedArticle = article
    refreshedArticle.contentHTML = "<p>Feed 第二版仍然是摘要</p>"
    refreshedArticle.fetchedAt = article.fetchedAt.addingTimeInterval(60)
    try database.upsertArticles([refreshedArticle])

    XCTAssertEqual(try database.fullTextRecord(articleID: article.id), fullText)
    XCTAssertEqual(
      try database.article(id: article.id)?.contentHTML,
      refreshedArticle.contentHTML
    )
    XCTAssertTrue(
      try database.matchingArticleIDs(query: "extractedsentinel").contains(article.id)
    )

    try database.deleteFullTextRecord(articleID: article.id)
    XCTAssertFalse(
      try database.matchingArticleIDs(query: "extractedsentinel").contains(article.id)
    )
  }

  func testStoreDeleteUndoRestoresIndependentFullText() throws {
    let rootURL = temporaryRoot("rss-full-text-delete-undo")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = try makeFeed()
    let article = RSSArticle(
      id: "undo-article",
      feedID: feed.id,
      title: "可撤销文章",
      contentHTML: "<p>Feed 摘要</p>"
    )
    let fullText = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: "<p>可撤销独立全文</p>",
      plainText: "可撤销独立全文",
      confidence: 0.88,
      attemptedAt: Date(timeIntervalSince1970: 1_700_000_200)
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
      try database.upsertFullTextRecord(fullText)
    }

    let store = RSSReaderStore(fileURL: fileURL)
    store.removeFeed(id: feed.id)
    XCTAssertNil(try store.fullTextRecord(articleID: article.id))

    store.undoLastDeletion()

    XCTAssertEqual(try store.fullTextRecord(articleID: article.id), fullText)
  }

  private func makeFeed() throws -> RSSFeed {
    RSSFeed(
      id: UUID(),
      title: "全文测试订阅",
      url: try XCTUnwrap(URL(string: "https://example.com/rss.xml"))
    )
  }

  private func temporaryRoot(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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
      throw NSError(domain: "RSSArticleFullTextPersistenceTests", code: 1, userInfo: [
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
      throw NSError(domain: "RSSArticleFullTextPersistenceTests", code: 2, userInfo: [
        NSLocalizedDescriptionKey: message
      ])
    }
  }

  private func querySQLiteInt(_ sql: String, at fileURL: URL) throws -> Int {
    try withSQLiteStatement(sql, at: fileURL) { statement in
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "RSSArticleFullTextPersistenceTests", code: 3)
      }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  private func querySQLiteText(_ sql: String, at fileURL: URL) throws -> String {
    try withSQLiteStatement(sql, at: fileURL) { statement in
      guard sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0) else {
        throw NSError(domain: "RSSArticleFullTextPersistenceTests", code: 4)
      }
      return String(cString: value)
    }
  }

  private func withSQLiteStatement<T>(
    _ sql: String,
    at fileURL: URL,
    _ body: (OpaquePointer) throws -> T
  ) throws -> T {
    var handle: OpaquePointer?
    let openResult = sqlite3_open_v2(
      fileURL.path,
      &handle,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openResult == SQLITE_OK, let handle else {
      if let handle { sqlite3_close(handle) }
      throw NSError(domain: "RSSArticleFullTextPersistenceTests", code: 5)
    }
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw NSError(domain: "RSSArticleFullTextPersistenceTests", code: 6)
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }
}
