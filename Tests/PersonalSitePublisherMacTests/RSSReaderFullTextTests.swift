import Combine
import Foundation
import SQLite3
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingKnowledgeCore

@MainActor
final class RSSReaderFullTextTests: XCTestCase {
  func testCurrentFullTextRemainsReadableWhenCacheWriteFails() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rss-full-text-write-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      id: UUID(), title: "缓存失败订阅", url: try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    )
    let sourceURL = try XCTUnwrap(URL(string: "https://example.com/current"))
    let article = RSSArticle(
      id: "cache-write-failure", feedID: feed.id, title: "当前文章", link: sourceURL,
      summaryHTML: "<p>摘要</p>"
    )
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
    }
    try executeSQLite(
      """
      CREATE TRIGGER reject_full_text_cache_write
      BEFORE INSERT ON rss_article_full_text
      BEGIN
        SELECT RAISE(ABORT, 'cache write intentionally rejected');
      END;
      """,
      at: fileURL
    )
    let store = RSSReaderStore(fileURL: fileURL)
    let state = RSSReaderPresentationState()
    let record = RSSArticleFullTextRecord.ready(
      articleID: article.id,
      contentHTML: "<p>已抽取正文</p>",
      plainText: "已抽取正文",
      sourceURL: sourceURL,
      confidence: 0.9
    )

    let current = await state.persistAndConfirmCurrentFullTextRecord(
      record, requestedArticle: article, store: store
    )

    XCTAssertEqual(current?.id, article.id)
    XCTAssertEqual(current?.link, sourceURL)
    XCTAssertNil(try store.fullTextRecord(articleID: article.id))

    var movedArticle = article
    movedArticle.link = try XCTUnwrap(URL(string: "https://example.com/moved"))
    let movedDatabase = try RSSReaderDatabase(fileURL: fileURL)
    try movedDatabase.upsertArticles([movedArticle])
    let rejected = await state.persistAndConfirmCurrentFullTextRecord(
      record, requestedArticle: article, store: store
    )
    XCTAssertNil(rejected)
  }

  func testPresentationStateFullTextToggling() async {
    let state = RSSReaderPresentationState()
    let article = RSSArticle(
      id: "art-test-toggle",
      feedID: UUID(),
      title: "测试文章",
      link: URL(string: "https://example.com/art-1"),
      summaryHTML: "<p>截断摘要</p>",
      contentHTML: ""
    )

    XCTAssertTrue(state.isTruncatedCandidate(article))
    XCTAssertFalse(state.isShowingFullText(for: article.id))
    XCTAssertFalse(state.isFetchingFullText(for: article.id))

    // Inject a cached full-text article
    let fullText = RSSArticle(
      id: article.id,
      feedID: article.feedID,
      title: article.title,
      link: article.link,
      summaryHTML: article.summaryHTML,
      contentHTML: "<p>完整正文内容已经成功提取完毕。</p>"
    )
    state.fullTextArticles[article.id] = fullText

    state.toggleFullText(for: article)
    XCTAssertTrue(state.isShowingFullText(for: article.id))

    let effective = state.effectiveArticle(for: article)
    XCTAssertEqual(effective.contentHTML, "<p>完整正文内容已经成功提取完毕。</p>")

    // Toggle back to summary
    state.toggleFullText(for: article)
    XCTAssertFalse(state.isShowingFullText(for: article.id))

    let fallback = state.effectiveArticle(for: article)
    XCTAssertEqual(fallback.contentHTML, "")
  }

  func testUserPreferencesDefaults() {
    let suiteName = "test-rss-user-prefs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabled(defaults: defaults))
    XCTAssertFalse(RSSReaderUserPreferences.automaticFullTextExtractionEnabled(defaults: defaults))

    defaults.set(true, forKey: RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabledKey)
    defaults.set(true, forKey: RSSReaderUserPreferences.automaticFullTextExtractionEnabledKey)

    XCTAssertTrue(RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabled(defaults: defaults))
    XCTAssertTrue(RSSReaderUserPreferences.automaticFullTextExtractionEnabled(defaults: defaults))
  }

  func testPresentationRestoresIndependentFullTextWithoutForcingToggleBackOn() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rss-presentation-full-text-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feed = RSSFeed(
      id: UUID(),
      title: "测试订阅",
      url: URL(string: "https://example.com/feed.xml")!
    )
    let article = RSSArticle(
      id: "persisted-full-text",
      feedID: feed.id,
      title: "持久化全文",
      link: URL(string: "https://example.com/post"),
      summaryHTML: "<p>截断摘要</p>"
    )
    let firstAttempt = Date(timeIntervalSince1970: 1_700_000_000)
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
      try database.upsertFullTextRecord(
        .ready(
          articleID: article.id,
          contentHTML: "<p>独立持久化完整正文</p>",
          plainText: "独立持久化完整正文",
          sourceURL: article.link,
          resolvedURL: article.link,
          extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
          extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
          confidence: 0.9,
          attemptedAt: firstAttempt
        )
      )
    }
    let store = RSSReaderStore(fileURL: fileURL)
    let state = RSSReaderPresentationState()

    XCTAssertTrue(state.restoreCachedFullText(for: article, store: store))
    XCTAssertTrue(state.isShowingFullText(for: article.id))
    XCTAssertEqual(
      state.effectiveArticle(for: article).contentHTML,
      "<p>独立持久化完整正文</p>"
    )

    state.toggleFullText(for: article, store: store)
    XCTAssertFalse(state.isShowingFullText(for: article.id))
    XCTAssertTrue(state.restoreCachedFullText(for: article, store: store))
    XCTAssertFalse(state.isShowingFullText(for: article.id))

    let relaunchedState = RSSReaderPresentationState()
    XCTAssertTrue(relaunchedState.restoreCachedFullText(for: article, store: store))
    XCTAssertTrue(relaunchedState.isShowingFullText(for: article.id))

    try store.saveFullTextRecord(
      .ready(
        articleID: article.id,
        contentHTML: "<p>另一窗口刚刚提取的新正文</p>",
        plainText: "另一窗口刚刚提取的新正文",
        sourceURL: article.link,
        resolvedURL: article.link,
        extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
        extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
        confidence: 0.95,
        attemptedAt: firstAttempt.addingTimeInterval(120)
      )
    )
    XCTAssertTrue(relaunchedState.restoreCachedFullText(for: article, store: store))
    XCTAssertEqual(
      relaunchedState.effectiveArticle(for: article).contentHTML,
      "<p>另一窗口刚刚提取的新正文</p>"
    )

    var refreshedArticle = article
    refreshedArticle.fetchedAt = firstAttempt.addingTimeInterval(180)
    XCTAssertTrue(relaunchedState.cachedFullTextNeedsRevalidation(for: refreshedArticle))

    var movedArticle = refreshedArticle
    movedArticle.link = URL(string: "https://example.com/moved-post")
    XCTAssertFalse(relaunchedState.restoreCachedFullText(for: movedArticle, store: store))
    XCTAssertFalse(relaunchedState.isShowingFullText(for: article.id))
  }

  func testReadyFallbackHonorsRetryBackoffBeforeAutomaticRevalidation() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rss-full-text-backoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let feed = RSSFeed(
      id: UUID(),
      title: "Backoff Feed",
      url: URL(string: "https://example.com/feed.xml")!
    )
    var article = RSSArticle(
      id: "ready-with-failed-refresh",
      feedID: feed.id,
      title: "Backoff",
      link: URL(string: "https://example.com/backoff"),
      summaryHTML: "<p>摘要</p>"
    )
    let attemptedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let retryAfter = attemptedAt.addingTimeInterval(600)
    article.fetchedAt = attemptedAt.addingTimeInterval(60)
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    do {
      let database = try RSSReaderDatabase(fileURL: fileURL)
      try database.upsertFeed(feed)
      try database.upsertArticles([article])
    }
    let store = RSSReaderStore(fileURL: fileURL)
    try store.saveFullTextRecord(
      RSSArticleFullTextRecord(
        articleID: article.id,
        status: .ready,
        contentHTML: "<p>上一次成功正文</p>",
        plainText: "上一次成功正文",
        sourceURL: article.link,
        resolvedURL: article.link,
        extractorIdentifier: RSSArticleDOMExtractionService.extractorIdentifier,
        extractorVersion: RSSArticleDOMExtractionService.extractorVersion,
        confidence: 0.8,
        attemptedAt: attemptedAt,
        retryAfter: retryAfter,
        failureMessage: "最近一次更新失败"
      )
    )
    let state = RSSReaderPresentationState()

    XCTAssertTrue(state.restoreCachedFullText(for: article, store: store))
    XCTAssertFalse(
      state.cachedFullTextNeedsRevalidation(
        for: article,
        now: attemptedAt.addingTimeInterval(300)
      )
    )
    XCTAssertTrue(
      state.cachedFullTextNeedsRevalidation(
        for: article,
        now: retryAfter.addingTimeInterval(1)
      )
    )
    XCTAssertEqual(state.effectiveArticle(for: article).contentHTML, "<p>上一次成功正文</p>")
  }

  private func executeSQLite(_ sql: String, at fileURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      fileURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
    ) == SQLITE_OK, let handle else {
      if let handle { sqlite3_close(handle) }
      throw NSError(domain: "RSSReaderFullTextTests", code: 1)
    }
    defer { sqlite3_close(handle) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw NSError(
        domain: "RSSReaderFullTextTests", code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }
}
