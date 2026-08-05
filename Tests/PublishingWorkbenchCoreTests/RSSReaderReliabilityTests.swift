import Foundation
import SQLite3
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RSSReaderReliabilityTests: XCTestCase {
  func testStructuredIssuePersistsAcrossSQLiteReopen() async throws {
    let rootURL = try temporaryRoot("issue-persistence")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let retryAt = Date().addingTimeInterval(3_600)
    let issue = RSSFeedIssue.http(
      statusCode: 429,
      retryAt: retryAt,
      technicalDetail: "HTTP 429; Retry-After=3600"
    )
    let script = RSSReliabilityFetchScript(steps: [.issue(issue)])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("limited.xml"), title: "限流订阅")

    await store.refresh(feedID: feedID)

    let failedFeed = try XCTUnwrap(store.feeds.first)
    XCTAssertEqual(failedFeed.lastIssue, issue)
    XCTAssertEqual(failedFeed.nextRetryAt, retryAt)
    XCTAssertEqual(store.nextScheduledRefreshAt, retryAt)

    let reopened = RSSReaderStore(fileURL: fileURL)
    let persistedFeed = try XCTUnwrap(reopened.feeds.first)
    let persistedIssue = try XCTUnwrap(persistedFeed.lastIssue)
    XCTAssertEqual(persistedIssue.stage, issue.stage)
    XCTAssertEqual(persistedIssue.category, issue.category)
    XCTAssertEqual(persistedIssue.retryStrategy, issue.retryStrategy)
    XCTAssertEqual(persistedIssue.userMessage, issue.userMessage)
    XCTAssertEqual(persistedIssue.technicalDetail, issue.technicalDetail)
    XCTAssertEqual(
      try XCTUnwrap(persistedIssue.retryAt).timeIntervalSince1970,
      retryAt.timeIntervalSince1970,
      accuracy: 0.001
    )
    XCTAssertEqual(
      persistedIssue.occurredAt.timeIntervalSince1970,
      issue.occurredAt.timeIntervalSince1970,
      accuracy: 0.001
    )
    XCTAssertEqual(
      try XCTUnwrap(persistedFeed.nextRetryAt).timeIntervalSince1970,
      retryAt.timeIntervalSince1970,
      accuracy: 0.001
    )
    XCTAssertEqual(
      try querySQLiteInt("PRAGMA user_version;", at: fileURL),
      RSSReaderDatabase.currentSchemaVersion
    )
  }

  func testVersionOneDatabaseMigratesLegacyLastErrorIntoIssueJSON() throws {
    let rootURL = try temporaryRoot("v1-migration")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let feedID = UUID()
    try executeSQLite(
      """
      CREATE TABLE rss_feeds (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        url TEXT NOT NULL UNIQUE,
        site_url TEXT,
        icon_url TEXT,
        added_at REAL NOT NULL,
        last_updated_at REAL,
        etag TEXT,
        last_modified TEXT,
        last_error TEXT,
        last_refresh_attempt_at REAL,
        refresh_failure_count INTEGER NOT NULL DEFAULT 0,
        next_retry_at REAL,
        last_refresh_duration REAL
      );
      INSERT INTO rss_feeds (
        id, title, url, added_at, last_error, last_refresh_attempt_at,
        refresh_failure_count
      ) VALUES (
        '\(feedID.uuidString)', '旧订阅', 'https://example.com/legacy.xml',
        100, '旧版网络错误', 200, 2
      );
      PRAGMA user_version = 1;
      """,
      at: fileURL
    )

    let store = RSSReaderStore(fileURL: fileURL)
    let feed = try XCTUnwrap(store.feeds.first)

    XCTAssertEqual(feed.id, feedID)
    XCTAssertEqual(feed.lastError, "旧版网络错误")
    XCTAssertEqual(feed.lastIssue?.category, .unknown)
    XCTAssertEqual(feed.lastIssue?.retryStrategy, .automatic)
    XCTAssertEqual(
      try querySQLiteInt("PRAGMA user_version;", at: fileURL),
      RSSReaderDatabase.currentSchemaVersion
    )
    XCTAssertFalse(
      try querySQLiteText(
        "SELECT last_issue_json FROM rss_feeds WHERE id = '\(feedID.uuidString)';",
        at: fileURL
      ).isEmpty
    )
  }

  func testRequiresActionIssueNeverFakesAutomaticRetry() async throws {
    let rootURL = try temporaryRoot("requires-action")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let script = RSSReliabilityFetchScript(steps: [
      .issue(RSSFeedIssue.http(statusCode: 404)),
      .result(makeResult(title: "不应读取", articleID: "unexpected")),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("missing.xml"))

    await store.refresh(feedID: feedID)
    await store.refreshStaleFeeds(maxAge: 0, now: Date().addingTimeInterval(86_400))

    let callCount = await script.callCount()
    XCTAssertEqual(callCount, 1)
    XCTAssertEqual(store.feeds.first?.lastIssue?.retryStrategy, .requiresAction)
    XCTAssertNil(store.feeds.first?.nextRetryAt)
    XCTAssertNil(store.nextScheduledRefreshAt)
  }

  func testRetryAfterTakesPriorityUntilExactRetryDate() async throws {
    let rootURL = try temporaryRoot("retry-after")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let retryAt = Date().addingTimeInterval(600)
    let script = RSSReliabilityFetchScript(steps: [
      .issue(RSSFeedIssue.http(statusCode: 503, retryAt: retryAt)),
      .result(makeResult(title: "恢复订阅", articleID: "recovered")),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("temporarily-down.xml"))

    await store.refresh(feedID: feedID)
    XCTAssertEqual(store.feeds.first?.nextRetryAt, retryAt)
    await store.refreshStaleFeeds(maxAge: 0, now: retryAt.addingTimeInterval(-0.001))
    let earlyCallCount = await script.callCount()
    XCTAssertEqual(earlyCallCount, 1)

    await store.refreshStaleFeeds(maxAge: 0, now: retryAt)
    let dueCallCount = await script.callCount()
    XCTAssertEqual(dueCallCount, 2)
    XCTAssertNil(store.feeds.first?.lastIssue)
    XCTAssertNil(store.feeds.first?.nextRetryAt)
  }

  func testConcurrentRefreshOfSameFeedIsDeduplicated() async throws {
    let rootURL = try temporaryRoot("concurrent-deduplication")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let counter = RSSReliabilityCallCounter()
    let result = makeResult(title: "并发订阅", articleID: "one")
    let store = RSSReaderStore(
      fileURL: fileURL,
      fetchOperation: { _, _, _ in
        await counter.increment()
        try await Task.sleep(nanoseconds: 200_000_000)
        return result
      }
    )
    let feedID = try store.addFeed(url: try feedURL("concurrent.xml"))

    let first = Task { @MainActor in await store.refresh(feedID: feedID) }
    while await counter.value() == 0 { await Task.yield() }
    let second = Task { @MainActor in await store.refresh(feedID: feedID) }
    await second.value

    XCTAssertTrue(store.isFeedRefreshing(feedID))
    let overlappingCallCount = await counter.value()
    XCTAssertEqual(overlappingCallCount, 1)
    await first.value
    XCTAssertFalse(store.isFeedRefreshing(feedID))
    let completedCallCount = await counter.value()
    XCTAssertEqual(completedCallCount, 1)
  }

  func testPersistenceFailureRollsBackFeedArticlesAndFTSBeforePublishing() async throws {
    let rootURL = try temporaryRoot("atomic-refresh")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(title: "原订阅", articleID: "old", articleTitle: "旧内容")),
      .result(makeResult(title: "新订阅", articleID: "new", articleTitle: "新内容")),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("atomic.xml"))
    await store.refresh(feedID: feedID)
    let originalUpdatedAt = store.feeds.first?.lastUpdatedAt

    try executeSQLite(
      """
      CREATE TRIGGER block_new_rss_article
      BEFORE INSERT ON rss_articles
      WHEN NEW.id LIKE '%:new'
      BEGIN
        SELECT RAISE(ABORT, 'blocked by reliability test');
      END;
      """,
      at: fileURL
    )
    await store.refresh(feedID: feedID)

    XCTAssertEqual(store.feeds.first?.title, "原订阅")
    XCTAssertEqual(store.feeds.first?.lastUpdatedAt, originalUpdatedAt)
    XCTAssertEqual(store.articleHeaders.map(\.title), ["旧内容"])
    let reopened = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(reopened.feeds.first?.title, "原订阅")
    XCTAssertEqual(
      try XCTUnwrap(reopened.feeds.first?.lastUpdatedAt).timeIntervalSince1970,
      try XCTUnwrap(originalUpdatedAt).timeIntervalSince1970,
      accuracy: 0.001
    )
    XCTAssertEqual(reopened.articleHeaders.map(\.title), ["旧内容"])
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "旧内容").count, 1)
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "新内容").count, 0)
  }

  func testRefreshRetainsAllObservedArticlesBeyondLegacyLimitAcrossReopen() async throws {
    let rootURL = try temporaryRoot("unlimited-local-retention")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let historicalArticles = (0..<1_200).map { index in
      RSSParsedArticle(
        id: "history-\(index)",
        title: "历史文章 \(index)",
        publishedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        summaryHTML: "历史摘要 \(index)",
        contentHTML: index == 0 ? "oldestlocalmarker" : "历史正文 \(index)"
      )
    }
    let newestArticle = RSSParsedArticle(
      id: "newest",
      title: "新增文章",
      publishedAt: Date(timeIntervalSince1970: 2_000),
      contentHTML: "newestlocalmarker"
    )
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(title: "全量本地订阅", articles: historicalArticles)),
      .result(makeResult(title: "全量本地订阅", articles: [newestArticle])),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("unlimited.xml"))

    await store.refresh(feedID: feedID)
    XCTAssertEqual(store.articleHeaders.count, 1_200)
    await store.refresh(feedID: feedID)

    XCTAssertEqual(store.articleHeaders.count, 1_201)
    XCTAssertTrue(store.articleHeaders.contains { $0.id.hasSuffix(":history-0") })
    XCTAssertEqual(store.articleHeaders(for: .all, searchText: "oldestlocalmarker").count, 1)
    XCTAssertEqual(try querySQLiteInt("SELECT COUNT(*) FROM rss_articles;", at: fileURL), 1_201)
    XCTAssertEqual(try querySQLiteInt("SELECT COUNT(*) FROM rss_articles_fts;", at: fileURL), 1_201)

    let reopened = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(reopened.articleHeaders.count, 1_201)
    XCTAssertTrue(reopened.articleHeaders.contains { $0.id.hasSuffix(":history-0") })
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "oldestlocalmarker").count, 1)
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "newestlocalmarker").count, 1)
  }

  func testValidEmptyFeedRefreshPreservesCachedArticlesHighlightsAndFTS() async throws {
    let rootURL = try temporaryRoot("empty-feed-retention")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(
        title: "暂时有文章",
        articles: [
          RSSParsedArticle(
            id: "cached",
            title: "已缓存文章",
            contentHTML: "emptyfeedretentionmarker"
          ),
        ]
      )),
      .result(makeResult(title: "当前为空", articles: [])),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("empty-retention.xml"))
    await store.refresh(feedID: feedID)
    let articleID = try XCTUnwrap(store.articleHeaders.first?.id)
    let highlight = try store.saveHighlight(articleID: articleID, text: "保留这条高亮")

    await store.refresh(feedID: feedID)

    XCTAssertEqual(store.feeds.first?.title, "当前为空")
    XCTAssertEqual(store.articleHeaders.map(\.id), [articleID])
    XCTAssertEqual(store.highlights.map(\.id), [highlight.id])
    XCTAssertEqual(store.articleHeaders(for: .all, searchText: "emptyfeedretentionmarker").count, 1)
    XCTAssertEqual(try querySQLiteInt("SELECT COUNT(*) FROM rss_articles;", at: fileURL), 1)
    XCTAssertEqual(try querySQLiteInt("SELECT COUNT(*) FROM rss_articles_fts;", at: fileURL), 1)
    XCTAssertEqual(try querySQLiteInt("SELECT COUNT(*) FROM rss_article_highlights;", at: fileURL), 1)

    let reopened = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(reopened.articleHeaders.map(\.id), [articleID])
    XCTAssertEqual(reopened.highlights.map(\.id), [highlight.id])
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "emptyfeedretentionmarker").count, 1)
  }

  func testRemoteContentUpdatePreservesLocalStateHighlightsAndRefreshesFTS() async throws {
    let rootURL = try temporaryRoot("remote-content-update")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let publishedAt = Date(timeIntervalSince1970: 1_000)
    let original = RSSParsedArticle(
      id: "stable",
      title: "旧标题",
      link: try feedURL("articles/old"),
      author: "旧作者",
      publishedAt: publishedAt,
      summaryHTML: "oldsummarymarker",
      contentHTML: "oldcontentmarker"
    )
    let updated = RSSParsedArticle(
      id: "stable",
      title: "新标题",
      link: try feedURL("articles/new"),
      author: "新作者",
      publishedAt: publishedAt.addingTimeInterval(60),
      summaryHTML: "newsummarymarker",
      contentHTML: "newcontentmarker"
    )
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(title: "内容更新", articles: [original])),
      .result(makeResult(title: "内容更新", articles: [updated])),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("content-update.xml"))
    await store.refresh(feedID: feedID)
    let articleID = try XCTUnwrap(store.articleHeaders.first?.id)
    store.markRead(articleID)
    store.toggleStarred(articleID)
    store.setArticleTags(["本地标签"], for: articleID)
    let highlight = try store.saveHighlight(articleID: articleID, text: "本地高亮")

    await store.refresh(feedID: feedID)

    let loadedArticle = try await store.loadArticle(id: articleID)
    let article = try XCTUnwrap(loadedArticle)
    XCTAssertEqual(store.articleHeaders.count, 1)
    XCTAssertEqual(article.title, "新标题")
    XCTAssertEqual(article.link, updated.link)
    XCTAssertEqual(article.author, "新作者")
    XCTAssertEqual(article.summaryHTML, "newsummarymarker")
    XCTAssertEqual(article.contentHTML, "newcontentmarker")
    XCTAssertTrue(article.isRead)
    XCTAssertTrue(article.isStarred)
    XCTAssertEqual(article.tags, ["本地标签"])
    XCTAssertEqual(store.highlights.map(\.id), [highlight.id])
    XCTAssertTrue(store.articleHeaders(for: .all, searchText: "oldcontentmarker").isEmpty)
    XCTAssertEqual(store.articleHeaders(for: .all, searchText: "newcontentmarker").map(\.id), [articleID])

    let reopened = RSSReaderStore(fileURL: fileURL)
    let loadedPersistedArticle = try await reopened.loadArticle(id: articleID)
    let persisted = try XCTUnwrap(loadedPersistedArticle)
    XCTAssertEqual(persisted.title, "新标题")
    XCTAssertTrue(persisted.isRead)
    XCTAssertTrue(persisted.isStarred)
    XCTAssertEqual(persisted.tags, ["本地标签"])
    XCTAssertEqual(reopened.highlights.map(\.id), [highlight.id])
    XCTAssertTrue(reopened.articleHeaders(for: .all, searchText: "oldcontentmarker").isEmpty)
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "newcontentmarker").map(\.id), [articleID])
    XCTAssertEqual(try querySQLiteInt("SELECT COUNT(*) FROM rss_articles_fts;", at: fileURL), 1)
  }

  func testUnchangedRemoteArticleIsNotRewrittenDuringRefresh() async throws {
    let rootURL = try temporaryRoot("unchanged-article-upsert")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let unchanged = RSSParsedArticle(
      id: "unchanged",
      title: "未变文章",
      publishedAt: Date(timeIntervalSince1970: 1_000),
      contentHTML: "unchangedcontentmarker"
    )
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(title: "首次订阅标题", articles: [unchanged])),
      .result(makeResult(title: "已更新订阅标题", articles: [unchanged])),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("unchanged.xml"))
    await store.refresh(feedID: feedID)
    try executeSQLite(
      """
      CREATE TRIGGER block_unchanged_rss_article_rewrite
      BEFORE INSERT ON rss_articles
      WHEN NEW.id LIKE '%:unchanged'
      BEGIN
        SELECT RAISE(ABORT, 'unchanged article must not be rewritten');
      END;
      """,
      at: fileURL
    )

    await store.refresh(feedID: feedID)

    XCTAssertEqual(store.feeds.first?.title, "已更新订阅标题")
    XCTAssertEqual(store.articleHeaders.count, 1)
    XCTAssertNil(store.feeds.first?.lastIssue)
    XCTAssertEqual(store.lastRefreshSummary?.successCount, 1)
    XCTAssertEqual(store.lastRefreshSummary?.failureCount, 0)
  }

  func testReadStarAndTagUpdatesDoNotRewriteArticleContentOrFTS() async throws {
    let rootURL = try temporaryRoot("lightweight-local-state")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(
        title: "轻量状态更新",
        articles: [
          RSSParsedArticle(
            id: "stable-content",
            title: "不重写正文",
            contentHTML: "lightweightstatemarker"
          ),
        ]
      )),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("lightweight-state.xml"))
    await store.refresh(feedID: feedID)
    let articleID = try XCTUnwrap(store.articleHeaders.first?.id)
    try executeSQLite(
      """
      CREATE TRIGGER block_local_state_article_reinsert
      BEFORE INSERT ON rss_articles
      BEGIN
        SELECT RAISE(ABORT, 'local state must not reinsert article content');
      END;
      """,
      at: fileURL
    )

    store.markRead(articleID)
    store.toggleStarred(articleID)
    store.setArticleTags(["本地标签"], for: articleID)

    let updated = try XCTUnwrap(store.articleHeaders.first)
    XCTAssertTrue(updated.isRead)
    XCTAssertTrue(updated.isStarred)
    XCTAssertEqual(updated.tags, ["本地标签"])
    XCTAssertEqual(store.articleHeaders(for: .all, searchText: "lightweightstatemarker").map(\.id), [articleID])

    let reopened = RSSReaderStore(fileURL: fileURL)
    let persisted = try XCTUnwrap(reopened.articleHeaders.first)
    XCTAssertTrue(persisted.isRead)
    XCTAssertTrue(persisted.isStarred)
    XCTAssertEqual(persisted.tags, ["本地标签"])
    XCTAssertEqual(reopened.articleHeaders(for: .all, searchText: "lightweightstatemarker").map(\.id), [articleID])
  }

  func testUpdatingFeedURLPreservesLocalKnowledgeAndClearsRequestState() async throws {
    let rootURL = try temporaryRoot("update-url")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(
        title: "可改址订阅",
        articleID: "kept",
        articleTitle: "保留文章",
        etag: "old-etag",
        lastModified: "old-modified"
      )),
      .issue(RSSFeedIssue.http(statusCode: 404)),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let oldURL = try feedURL("old.xml")
    let newURL = try feedURL("new.xml")
    let feedID = try store.addFeed(url: oldURL)
    await store.refresh(feedID: feedID)
    let articleID = try XCTUnwrap(store.articleHeaders.first?.id)
    store.markRead(articleID)
    store.toggleStarred(articleID)
    let highlight = try store.saveHighlight(articleID: articleID, text: "保留高亮")
    await store.refresh(feedID: feedID)
    XCTAssertNotNil(store.feeds.first?.lastIssue)

    try store.updateFeedURL(feedID: feedID, newURL: newURL)

    let updated = try XCTUnwrap(store.feeds.first)
    XCTAssertEqual(updated.id, feedID)
    XCTAssertEqual(updated.url, newURL)
    XCTAssertNil(updated.etag)
    XCTAssertNil(updated.lastModified)
    XCTAssertNil(updated.lastIssue)
    XCTAssertNil(updated.nextRetryAt)
    XCTAssertTrue(store.articleHeaders.first?.isRead == true)
    XCTAssertTrue(store.articleHeaders.first?.isStarred == true)
    XCTAssertEqual(store.highlights.first?.id, highlight.id)

    let reopened = RSSReaderStore(fileURL: fileURL)
    XCTAssertEqual(reopened.feeds.first?.url, newURL)
    XCTAssertTrue(reopened.articleHeaders.first?.isStarred == true)
    XCTAssertEqual(reopened.highlights.first?.id, highlight.id)
  }

  func testMarkAllReadCanBeUndoneAndBothStatesPersist() async throws {
    let rootURL = try temporaryRoot("batch-read-undo")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(
        title: "批量阅读",
        articles: [
          RSSParsedArticle(id: "one", title: "文章一"),
          RSSParsedArticle(id: "two", title: "文章二"),
        ]
      )),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("batch.xml"))
    await store.refresh(feedID: feedID)
    let articleIDs = Set(store.articleHeaders.map(\.id))

    XCTAssertEqual(store.markAllRead(articleIDs: articleIDs), 2)
    XCTAssertTrue(store.canUndoLastBatchRead)
    XCTAssertTrue(store.articleHeaders.allSatisfy(\.isRead))
    XCTAssertTrue(RSSReaderStore(fileURL: fileURL).articleHeaders.allSatisfy(\.isRead))

    XCTAssertEqual(store.undoLastBatchRead(), 2)
    XCTAssertFalse(store.canUndoLastBatchRead)
    XCTAssertTrue(store.articleHeaders.allSatisfy { !$0.isRead })
    XCTAssertTrue(RSSReaderStore(fileURL: fileURL).articleHeaders.allSatisfy { !$0.isRead })
  }

  func testStaleRefreshUsesThirtyMinuteBoundary() async throws {
    let rootURL = try temporaryRoot("stale-refresh")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let script = RSSReliabilityFetchScript(steps: [
      .result(makeResult(title: "时效订阅", articleID: "one")),
      .result(makeResult(title: "时效订阅", articleID: "two")),
    ])
    let store = makeStore(fileURL: fileURL, script: script)
    let feedID = try store.addFeed(url: try feedURL("stale.xml"))
    await store.refresh(feedID: feedID)
    let updatedAt = try XCTUnwrap(store.feeds.first?.lastUpdatedAt)

    await store.refreshStaleFeeds(now: updatedAt.addingTimeInterval(1_799))
    let freshCallCount = await script.callCount()
    XCTAssertEqual(freshCallCount, 1)
    await store.refreshStaleFeeds(now: updatedAt.addingTimeInterval(1_800))
    let staleCallCount = await script.callCount()
    XCTAssertEqual(staleCallCount, 2)
  }

  func testURLValidationUniquenessAndDefaultOPMLRedaction() throws {
    let rootURL = try temporaryRoot("url-privacy")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("reader.sqlite")
    let store = RSSReaderStore(fileURL: fileURL)
    let unsafeURL = try XCTUnwrap(
      URL(string: "https://reader:secret@example.com/private.xml")
    )
    XCTAssertThrowsError(try store.addFeed(url: unsafeURL))
    XCTAssertThrowsError(
      try store.addFeed(url: try XCTUnwrap(URL(string: "https:missing-host.xml")))
    )

    let firstID = try store.addFeed(
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml?token=topsecret"))
    )
    let secondURL = try feedURL("second.xml")
    _ = try store.addFeed(url: secondURL)
    XCTAssertThrowsError(try store.updateFeedURL(feedID: firstID, newURL: secondURL))
    XCTAssertThrowsError(try store.updateFeedURL(feedID: firstID, newURL: unsafeURL))

    let opml = try RSSOPMLWriter.makeDocument(
      subscriptions: store.feeds.map {
        RSSOPMLSubscription(title: $0.displayTitle, url: $0.url, siteURL: $0.siteURL)
      }
    )
    let exportedText = String(decoding: opml, as: UTF8.self)
    XCTAssertFalse(exportedText.contains("topsecret"))
    XCTAssertTrue(exportedText.contains("REDACTED"))
  }

  private func makeStore(
    fileURL: URL,
    script: RSSReliabilityFetchScript
  ) -> RSSReaderStore {
    RSSReaderStore(
      fileURL: fileURL,
      fetchOperation: { url, etag, lastModified in
        try await script.fetch(url: url, etag: etag, lastModified: lastModified)
      }
    )
  }

  private func temporaryRoot(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSReaderReliability-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func feedURL(_ name: String) throws -> URL {
    try XCTUnwrap(URL(string: "https://example.com/\(name)"))
  }

  private func executeSQLite(_ sql: String, at fileURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      fileURL.path,
      &handle,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK,
      let handle
    else {
      defer { if let handle { sqlite3_close(handle) } }
      throw RSSReliabilitySQLiteError(message: "SQLite open failed")
    }
    defer { sqlite3_close(handle) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw RSSReliabilitySQLiteError(message: message)
    }
  }

  private func querySQLiteInt(_ sql: String, at fileURL: URL) throws -> Int {
    Int(try querySQLiteInt64(sql, at: fileURL))
  }

  private func querySQLiteInt64(_ sql: String, at fileURL: URL) throws -> Int64 {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let handle
    else { throw RSSReliabilitySQLiteError(message: "SQLite open failed") }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RSSReliabilitySQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw RSSReliabilitySQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func querySQLiteText(_ sql: String, at fileURL: URL) throws -> String {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let handle
    else { throw RSSReliabilitySQLiteError(message: "SQLite open failed") }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RSSReliabilitySQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0)
    else { throw RSSReliabilitySQLiteError(message: "SQLite text query failed") }
    return String(cString: value)
  }
}

private enum RSSReliabilityFetchStep: Sendable {
  case result(RSSFeedFetchResult)
  case issue(RSSFeedIssue)
}

private actor RSSReliabilityFetchScript {
  private var steps: [RSSReliabilityFetchStep]
  private var calls = 0

  init(steps: [RSSReliabilityFetchStep]) {
    self.steps = steps
  }

  func fetch(
    url: URL,
    etag: String?,
    lastModified: String?
  ) throws -> RSSFeedFetchResult {
    _ = (url, etag, lastModified)
    calls += 1
    guard !steps.isEmpty else {
      throw RSSReaderError.network("Reliability test fetch script exhausted")
    }
    switch steps.removeFirst() {
    case let .result(result):
      return result
    case let .issue(issue):
      throw RSSReaderError.issue(issue)
    }
  }

  func callCount() -> Int { calls }
}

private actor RSSReliabilityCallCounter {
  private var count = 0

  func increment() { count += 1 }
  func value() -> Int { count }
}

private struct RSSReliabilitySQLiteError: Error {
  var message: String
}

private func makeResult(
  title: String,
  articleID: String,
  articleTitle: String = "测试文章",
  etag: String? = nil,
  lastModified: String? = nil
) -> RSSFeedFetchResult {
  makeResult(
    title: title,
    articles: [RSSParsedArticle(id: articleID, title: articleTitle)],
    etag: etag,
    lastModified: lastModified
  )
}

private func makeResult(
  title: String,
  articles: [RSSParsedArticle],
  etag: String? = nil,
  lastModified: String? = nil
) -> RSSFeedFetchResult {
  RSSFeedFetchResult(
    parsedFeed: RSSParsedFeed(
      title: title,
      siteURL: URL(string: "https://example.com/"),
      articles: articles
    ),
    responseURL: URL(string: "https://example.com/"),
    etag: etag,
    lastModified: lastModified,
    notModified: false
  )
}
