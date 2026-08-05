import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSReaderPresentationSupportTests: XCTestCase {
  func testArticleCoverThumbnailPresentationUsesCompactRoundedSize() {
    XCTAssertEqual(RSSArticleCoverThumbnailPresentation.dimension, 64)
    XCTAssertEqual(RSSArticleCoverThumbnailPresentation.cornerRadius, 10)
    XCTAssertEqual(RSSArticleCoverThumbnailPresentation.maximumPixelSize, 192)
  }

  @MainActor
  func testReaderMetricsAllowsLargeImageOnlyArticleToRender() throws {
    let padding = String(repeating: "<!-- image-only padding -->", count: 200)
    let article = RSSArticle(
      id: "large-image-only",
      feedID: UUID(),
      title: "Image only",
      link: try XCTUnwrap(URL(string: "https://example.com/posts/image-only")),
      contentHTML: padding + "<article><img src=\"https://cdn.example.com/image.jpg\"></article>"
    )
    XCTAssertGreaterThan(article.contentHTML.utf8.count, 4_096)
    XCTAssertTrue(article.readableText.isEmpty)

    let metrics = RSSReaderPresentationState().readerMetrics(for: article)

    XCTAssertTrue(metrics.hasRenderableBody)
    XCTAssertEqual(metrics.readingMinutes, 1)
  }

  @MainActor
  func testReaderMetricsUsesDisplayedSummaryAfterUnsafeContentIsRemoved() {
    let article = RSSArticle(
      id: "summary-reading-time",
      feedID: UUID(),
      title: "Summary reading time",
      summaryHTML: "<p>\(String(repeating: "中文摘要内容", count: 80))</p>",
      contentHTML: "<script>\(String(repeating: "ignored ", count: 500))</script>"
    )

    let metrics = RSSReaderPresentationState().readerMetrics(for: article)

    XCTAssertTrue(metrics.hasRenderableBody)
    XCTAssertGreaterThan(metrics.readingMinutes, 1)
  }

  func testSubscriptionDiscoveryKeepsPrimaryAndOtherFeedsInSourceOrder() throws {
    let sourceURL = try XCTUnwrap(URL(string: "https://example.com/blog/"))
    let primaryURL = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    let alternateURL = try XCTUnwrap(URL(string: "https://example.com/atom.xml"))

    let discovery = RSSSubscriptionDiscovery(
      sourceURL: sourceURL,
      feedURLs: [primaryURL, alternateURL, primaryURL]
    )

    XCTAssertEqual(discovery.primaryURL, primaryURL)
    XCTAssertEqual(discovery.alternativeURLs, [alternateURL])
  }

  func testFiltersBySourceAuthorTagAndDateThenSortsOldestFirst() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let firstFeedID = UUID()
    let secondFeedID = UUID()
    let matchingOld = article(
      id: "matching-old",
      feedID: firstFeedID,
      author: "Alice",
      date: now.addingTimeInterval(-3 * 86_400),
      tags: ["Swift"]
    )
    let matchingNew = article(
      id: "matching-new",
      feedID: firstFeedID,
      author: "alice",
      date: now.addingTimeInterval(-86_400),
      tags: ["swift"]
    )
    let wrongSource = article(
      id: "wrong-source",
      feedID: secondFeedID,
      author: "Alice",
      date: now,
      tags: ["Swift"]
    )

    let result = RSSArticlePresentationSupport.applyFiltersAndSort(
      to: [matchingNew, wrongSource, matchingOld],
      sourceID: firstFeedID,
      author: "ALICE",
      tag: "SWIFT",
      dateRange: .lastSevenDays,
      sortOrder: .oldest,
      now: now,
      calendar: calendar
    )

    XCTAssertEqual(result.map(\.id), ["matching-old", "matching-new"])
  }

  func testUnreadFirstKeepsNewestUnreadAheadOfReadArticles() {
    let feedID = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let read = RSSArticleHeader(
      id: "read",
      feedID: feedID,
      title: "Read",
      publishedAt: now,
      readAt: now
    )
    let unread = RSSArticleHeader(
      id: "unread",
      feedID: feedID,
      title: "Unread",
      publishedAt: now.addingTimeInterval(-300)
    )

    let result = RSSArticlePresentationSupport.applyFiltersAndSort(
      to: [read, unread],
      sourceID: nil,
      author: nil,
      tag: nil,
      dateRange: .all,
      sortOrder: .unreadFirst,
      now: now
    )

    XCTAssertEqual(result.map(\.id), ["unread", "read"])
  }

  func testListStateDistinguishesLoadingFailureValidEmptyFilteredEmptyAndCache() {
    XCTAssertEqual(
      RSSArticlePresentationSupport.listState(
        isRefreshing: true,
        cachedCount: 0,
        visibleCount: 0,
        hasActiveFilters: false,
        failedFeedTitle: nil,
        failedFeedMessage: nil
      ),
      .loading
    )
    XCTAssertEqual(
      RSSArticlePresentationSupport.listState(
        isRefreshing: false,
        cachedCount: 0,
        visibleCount: 0,
        hasActiveFilters: false,
        failedFeedTitle: "Feed",
        failedFeedMessage: "Timeout"
      ),
      .failed(feedTitle: "Feed", message: "Timeout")
    )
    XCTAssertEqual(
      RSSArticlePresentationSupport.listState(
        isRefreshing: false,
        cachedCount: 0,
        visibleCount: 0,
        hasActiveFilters: false,
        failedFeedTitle: nil,
        failedFeedMessage: nil
      ),
      .empty
    )
    XCTAssertEqual(
      RSSArticlePresentationSupport.listState(
        isRefreshing: false,
        cachedCount: 3,
        visibleCount: 0,
        hasActiveFilters: true,
        failedFeedTitle: nil,
        failedFeedMessage: nil
      ),
      .filteredEmpty
    )
    XCTAssertEqual(
      RSSArticlePresentationSupport.listState(
        isRefreshing: true,
        cachedCount: 3,
        visibleCount: 2,
        hasActiveFilters: false,
        failedFeedTitle: nil,
        failedFeedMessage: nil
      ),
      .refreshing(cachedCount: 2)
    )
    XCTAssertEqual(
      RSSArticlePresentationSupport.listState(
        isRefreshing: false,
        cachedCount: 3,
        visibleCount: 2,
        hasActiveFilters: false,
        failedFeedTitle: "Feed",
        failedFeedMessage: "Timeout"
      ),
      .staleContent(cachedCount: 2, feedTitle: "Feed", message: "Timeout")
    )
    XCTAssertEqual(
      RSSArticlePresentationSupport.listState(
        isRefreshing: false,
        cachedCount: 3,
        visibleCount: 0,
        hasActiveFilters: true,
        failedFeedTitle: "Feed",
        failedFeedMessage: "Timeout"
      ),
      .staleContent(cachedCount: 0, feedTitle: "Feed", message: "Timeout")
    )
  }

  func testLanguageResolverUsesArticleContentInsteadOfFixedChinese() {
    XCTAssertEqual(RSSArticleLanguageResolver.languageTag(for: "Swift package release notes"), "en")
    XCTAssertEqual(RSSArticleLanguageResolver.languageTag(for: "今天发布了新文章"), "zh-CN")
    XCTAssertEqual(RSSArticleLanguageResolver.languageTag(for: "新しい記事を公開"), "ja")
  }

  func testNeedsAttentionAndAccessibilityPreferStructuredIssue() throws {
    let issue = RSSFeedIssue(
      stage: .response,
      category: .authenticationRequired,
      retryStrategy: .requiresAction,
      userMessage: "需要登录"
    )
    let feed = RSSFeed(
      title: "Private",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml")),
      lastIssue: issue
    )

    XCTAssertTrue(RSSArticlePresentationSupport.feedNeedsAttention(feed))
    let value = RSSArticlePresentationSupport.feedAccessibilityValue(feed, unreadCount: 2)
    XCTAssertTrue(value.contains("2 篇未读"))
    XCTAssertTrue(value.contains("需要登录"))
    XCTAssertTrue(value.contains("需要修改地址或访问条件"))
  }

  func testRetryAccessibilityUsesEffectiveScheduledDate() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let issue = RSSFeedIssue(
      stage: .response,
      category: .rateLimited,
      retryStrategy: .afterDate,
      retryAt: now.addingTimeInterval(-60),
      userMessage: "请求过于频繁"
    )
    let feed = RSSFeed(
      title: "Limited",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml")),
      lastIssue: issue,
      nextRetryAt: now.addingTimeInterval(600)
    )

    XCTAssertEqual(feed.healthStatus(now: now), .backingOff)
    let value = RSSArticlePresentationSupport.feedAccessibilityValue(
      feed,
      unreadCount: 0,
      now: now
    )
    XCTAssertTrue(value.contains("下次重试"))
  }

  @MainActor
  func testSelectionCanKeepReadingWhenFilterHidesCurrentArticle() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSSelectionContinuity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feed = RSSFeed(
      title: "Feed",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    )
    let selected = RSSArticle(
      id: "selected",
      feedID: feed.id,
      title: "Selected",
      author: "Alice"
    )
    let visible = RSSArticle(
      id: "visible",
      feedID: feed.id,
      title: "Visible",
      author: "Bob"
    )
    let snapshot = RSSReaderSnapshot(feeds: [feed], articles: [selected, visible])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)

    let store = RSSReaderStore(fileURL: fileURL)
    let presentation = RSSReaderPresentationState()
    presentation.selectedArticleID = selected.id
    presentation.selectedAuthor = "Bob"

    presentation.synchronizeSelection(in: store, preservingExistingArticle: true)
    XCTAssertEqual(presentation.selectedArticleID, selected.id)

    presentation.synchronizeSelection(in: store, preservingExistingArticle: false)
    XCTAssertNil(presentation.selectedArticleID)
  }

  @MainActor
  func testPaginationLoadsInPagesClampsResetsAndKeepsOffPageSelection() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSPagination-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feed = RSSFeed(
      title: "Large Feed",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    )
    let articles = (0..<241).map { index in
      RSSArticle(
        id: "article-\(index)",
        feedID: feed.id,
        title: "Article \(index)",
        publishedAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
    let snapshot = RSSReaderSnapshot(feeds: [feed], articles: articles)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)

    let store = RSSReaderStore(fileURL: fileURL)
    let presentation = RSSReaderPresentationState()
    let matching = presentation.matchingArticles(in: store)
    XCTAssertEqual(matching.count, 241)
    XCTAssertEqual(presentation.visibleArticles(in: store).count, 120)
    presentation.groupsByDate = false
    XCTAssertEqual(
      presentation.visibleArticleSections(in: store).flatMap(\.articles).count,
      120
    )
    XCTAssertNil(presentation.visibleArticleSections(in: store).first?.kind)

    let offPageID = matching[200].id
    XCTAssertFalse(presentation.visibleArticles(in: store).contains { $0.id == offPageID })
    presentation.selectedArticleID = offPageID
    presentation.synchronizeSelection(in: store)
    XCTAssertEqual(presentation.selectedArticleID, offPageID)

    presentation.revealArticle(offPageID, in: store)
    XCTAssertEqual(presentation.visibleArticles(in: store).count, 240)
    XCTAssertEqual(
      presentation.visibleArticleSections(in: store).flatMap(\.articles).count,
      240
    )
    presentation.groupsByDate = true
    XCTAssertEqual(
      presentation.visibleArticleSections(in: store).flatMap(\.articles).count,
      240
    )
    XCTAssertNotNil(presentation.visibleArticleSections(in: store).first?.kind)
    presentation.resetArticleDisplayLimit()
    presentation.loadMoreArticles(totalCount: matching.count)
    XCTAssertEqual(presentation.visibleArticles(in: store).count, 240)
    presentation.loadMoreArticles(totalCount: matching.count)
    XCTAssertEqual(presentation.visibleArticles(in: store).count, 241)
    presentation.loadMoreArticles(totalCount: matching.count)
    XCTAssertEqual(presentation.visibleArticles(in: store).count, 241)
    presentation.resetArticleDisplayLimit()
    XCTAssertEqual(presentation.visibleArticles(in: store).count, 120)
  }

  @MainActor
  func testPresentationCachesInvalidateForQueryChangesAndStoreMutation() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSPresentationCache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let fileURL = rootURL.appendingPathComponent("reader.json")
    let feed = RSSFeed(
      title: "Feed",
      url: try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
    )
    let alice = RSSArticle(id: "alice", feedID: feed.id, title: "Alice", author: "Alice")
    let bob = RSSArticle(id: "bob", feedID: feed.id, title: "Bob", author: "Bob")
    let snapshot = RSSReaderSnapshot(feeds: [feed], articles: [alice, bob])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)

    let store = RSSReaderStore(fileURL: fileURL)
    let presentation = RSSReaderPresentationState()
    XCTAssertEqual(Set(presentation.matchingArticles(in: store).map(\.id)), ["alice", "bob"])
    XCTAssertEqual(presentation.scopedAuthors(in: store), ["Alice", "Bob"])
    XCTAssertEqual(presentation.sidebarCounts(in: store).unreadCount, 2)

    presentation.selectedAuthor = "Alice"
    XCTAssertEqual(presentation.matchingArticles(in: store).map(\.id), ["alice"])

    presentation.selectedAuthor = nil
    presentation.selectedScope = .unread
    _ = presentation.scopedArticles(in: store)
    _ = presentation.matchingArticles(in: store)
    let originalRevision = store.mutationRevision
    store.markRead("alice")

    XCTAssertGreaterThan(store.mutationRevision, originalRevision)
    XCTAssertEqual(presentation.scopedArticles(in: store).map(\.id), ["bob"])
    XCTAssertEqual(presentation.matchingArticles(in: store).map(\.id), ["bob"])
    XCTAssertEqual(presentation.unreadMatchingArticleIDs(in: store), ["bob"])
    XCTAssertEqual(presentation.sidebarCounts(in: store).unreadCount, 1)
  }

  @MainActor
  func testListSectionsKeepLightweightReadableSummary() {
    let feedID = UUID()
    let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let article = RSSArticleHeader(
      id: "stable",
      feedID: feedID,
      title: "Stable",
      readableSummary: "Plain list summary",
      fetchedAt: fetchedAt
    )
    let sections = RSSArticlePresentationSupport.sections(
      for: [article],
      groupsByDate: false,
      sortOrder: .newest
    )

    XCTAssertEqual(sections.first?.articles.first?.readableSummary, "Plain list summary")
  }

  func testCombinedFilterSortOptionsComposeIntoTheExpectedSections() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let matchingFeedID = UUID()
    let otherFeedID = UUID()
    let older = article(
      id: "older-match",
      feedID: matchingFeedID,
      author: "Alice",
      date: now.addingTimeInterval(-10 * 86_400),
      tags: ["Swift"]
    )
    let newer = article(
      id: "newer-match",
      feedID: matchingFeedID,
      author: "Alice",
      date: now.addingTimeInterval(-2 * 86_400),
      tags: ["swift"]
    )
    let excluded = article(
      id: "excluded",
      feedID: otherFeedID,
      author: "Alice",
      date: now.addingTimeInterval(-86_400),
      tags: ["Swift"]
    )

    let filtered = RSSArticlePresentationSupport.applyFiltersAndSort(
      to: [newer, excluded, older],
      sourceID: matchingFeedID,
      author: "alice",
      tag: "swift",
      dateRange: .lastThirtyDays,
      sortOrder: .oldest,
      now: now
    )
    let sections = RSSArticlePresentationSupport.sections(
      for: filtered,
      groupsByDate: true,
      sortOrder: .oldest,
      now: now
    )

    XCTAssertEqual(filtered.map(\.id), ["older-match", "newer-match"])
    XCTAssertEqual(sections.flatMap(\.articles).map(\.id), ["older-match", "newer-match"])
    XCTAssertTrue(sections.allSatisfy { $0.kind != nil })
  }

  private func article(
    id: String,
    feedID: UUID,
    author: String,
    date: Date,
    tags: [String]
  ) -> RSSArticleHeader {
    RSSArticleHeader(
      id: id,
      feedID: feedID,
      title: id,
      author: author,
      publishedAt: date,
      tags: tags
    )
  }
}
