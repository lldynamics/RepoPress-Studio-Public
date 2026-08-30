import AppKit
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class RSSArticleSearchDraft: ObservableObject {
  @Published var text = ""
}

@MainActor
final class RSSReaderPresentationState: ObservableObject {
  private struct ArticleScopeCacheKey: Equatable {
    let revision: UInt64
    let scope: RSSArticleScope
  }

  private struct ArticleQueryCacheKey: Equatable {
    let revision: UInt64
    let scope: RSSArticleScope
    let searchText: String
    let unreadOnly: Bool
    let sourceID: UUID?
    let author: String?
    let tag: String?
    let dateRange: String
    let sortOrder: String
  }

  private struct VisibleArticlePageCacheKey: Equatable {
    let query: ArticleQueryCacheKey
    let displayLimit: Int
  }

  private struct ArticleSectionsCacheKey: Equatable {
    let page: VisibleArticlePageCacheKey
    let groupsByDate: Bool
    let calendarDay: Date
  }

  private struct ArticleFacets {
    let sourceIDs: Set<UUID>
    let authors: [String]
    let tags: [String]
  }

  private struct ReaderMetricsCacheEntry {
    let fetchedAt: Date
    let hasRenderableBody: Bool
    let readingMinutes: Int
  }

  static let articlePageSize = 120

  @Published var selectedScope: RSSArticleScope? = .all
  @Published var selectedArticleID: String?
  @Published var debouncedSearchText = ""
  @Published var unreadOnly = false
  @Published var sortOrder: RSSArticleSortOrder = .newest
  @Published var groupsByDate = true
  @Published var selectedSourceID: UUID?
  @Published var selectedAuthor: String?
  @Published var selectedTag: String?
  @Published var dateRange: RSSArticleDateRange = .all
  @Published var isAddSubscriptionPresented = false
  @Published var subscriptionDiscovery: RSSSubscriptionDiscovery?
  @Published private(set) var isDiscoveringSubscription = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published private(set) var articleDisplayLimit = 120
  @Published private(set) var searchFocusRequestID = UUID()
  @Published var fullTextArticles: [String: RSSArticle] = [:]
  @Published private(set) var fullTextRecords: [String: RSSArticleFullTextRecord] = [:]
  @Published var showingFullTextIDs: Set<String> = []
  @Published var fetchingFullTextIDs: Set<String> = []
  @Published var fullTextErrorByArticleID: [String: String] = [:]
  let searchDraft = RSSArticleSearchDraft()
  let fullTextService = RSSArticleFullTextService()
  let fullTextRequestBroker = RSSArticleFullTextRequestBroker.shared

  private var subscriptionDiscoveryRequestID = UUID()

  private var scopedArticlesCache: (key: ArticleScopeCacheKey, articles: [RSSArticleHeader])?
  private var matchingArticlesCache:
    (
      key: ArticleQueryCacheKey,
      articles: [RSSArticleHeader],
      unreadArticleIDs: Set<String>
    )?
  private var visibleArticlesCache:
    (
      key: VisibleArticlePageCacheKey,
      articles: [RSSArticleHeader]
    )?
  private var articleSectionsCache:
    (
      key: ArticleSectionsCacheKey,
      sections: [RSSArticleListSection]
    )?
  private var articleFacetsCache: (key: ArticleScopeCacheKey, facets: ArticleFacets)?
  private var readerMetricsCache: [String: ReaderMetricsCacheEntry] = [:]
  private var readerMetricsLRU: [String] = []
  private var fullTextArticleLRU: [String] = []
  private var fullTextErrorLRU: [String] = []
  private var sidebarCountsCache: (revision: UInt64, counts: RSSFeedSidebarCounts)?

  func matchingArticles(in store: RSSReaderStore) -> [RSSArticleHeader] {
    let key = articleQueryCacheKey(in: store)
    if let matchingArticlesCache, matchingArticlesCache.key == key {
      return matchingArticlesCache.articles
    }
    let base = store.articleHeaders(
      for: selectedScope ?? .all,
      searchText: debouncedSearchText,
      unreadOnly: unreadOnly
    )
    let result = RSSArticlePresentationSupport.applyFiltersAndSort(
      to: base,
      sourceID: selectedSourceID,
      author: selectedAuthor,
      tag: selectedTag,
      dateRange: dateRange,
      sortOrder: sortOrder
    )
    matchingArticlesCache = (
      key,
      result,
      Set(result.lazy.filter { !$0.isRead }.map(\.id))
    )
    return result
  }

  func unreadMatchingArticleIDs(in store: RSSReaderStore) -> Set<String> {
    let key = articleQueryCacheKey(in: store)
    if let matchingArticlesCache, matchingArticlesCache.key == key {
      return matchingArticlesCache.unreadArticleIDs
    }
    _ = matchingArticles(in: store)
    return matchingArticlesCache?.unreadArticleIDs ?? []
  }

  func cachePreparedMatchingArticles(
    _ articles: [RSSArticleHeader],
    unreadArticleIDs: Set<String>,
    in store: RSSReaderStore
  ) {
    matchingArticlesCache = (
      articleQueryCacheKey(in: store),
      articles,
      unreadArticleIDs
    )
  }

  func scopedArticles(in store: RSSReaderStore) -> [RSSArticleHeader] {
    let scope = selectedScope ?? .all
    let key = ArticleScopeCacheKey(revision: store.mutationRevision, scope: scope)
    if let scopedArticlesCache, scopedArticlesCache.key == key {
      return scopedArticlesCache.articles
    }
    let result = store.articleHeaders(for: scope)
    scopedArticlesCache = (key, result)
    return result
  }

  func visibleArticles(in store: RSSReaderStore) -> [RSSArticleHeader] {
    let key = visibleArticlePageCacheKey(in: store)
    if let visibleArticlesCache, visibleArticlesCache.key == key {
      return visibleArticlesCache.articles
    }
    let articles = Array(matchingArticles(in: store).prefix(articleDisplayLimit))
    visibleArticlesCache = (key, articles)
    return articles
  }

  func visibleArticleSections(
    in store: RSSReaderStore,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [RSSArticleListSection] {
    let pageKey = visibleArticlePageCacheKey(in: store)
    let key = ArticleSectionsCacheKey(
      page: pageKey,
      groupsByDate: groupsByDate,
      calendarDay: calendar.startOfDay(for: now)
    )
    if let articleSectionsCache, articleSectionsCache.key == key {
      return articleSectionsCache.sections
    }
    let sections = RSSArticlePresentationSupport.sections(
      for: visibleArticles(in: store),
      groupsByDate: groupsByDate,
      sortOrder: sortOrder,
      now: now,
      calendar: calendar
    )
    articleSectionsCache = (key, sections)
    return sections
  }

  func scopedAuthors(in store: RSSReaderStore) -> [String] {
    scopedFacets(in: store).authors
  }

  func scopedTags(in store: RSSReaderStore) -> [String] {
    scopedFacets(in: store).tags
  }

  func resetArticleDisplayLimit() {
    guard articleDisplayLimit != Self.articlePageSize else { return }
    articleDisplayLimit = Self.articlePageSize
  }

  func requestSearchFocus() {
    searchFocusRequestID = UUID()
  }

  func loadMoreArticles(totalCount: Int) {
    let nextLimit = min(totalCount, articleDisplayLimit + Self.articlePageSize)
    guard nextLimit != articleDisplayLimit else { return }
    articleDisplayLimit = nextLimit
  }

  func revealArticle(_ articleID: String, in store: RSSReaderStore) {
    let matching = matchingArticles(in: store)
    guard let index = matching.firstIndex(where: { $0.id == articleID }) else { return }
    let requiredLimit = ((index / Self.articlePageSize) + 1) * Self.articlePageSize
    let nextLimit = min(matching.count, max(articleDisplayLimit, requiredLimit))
    guard nextLimit != articleDisplayLimit else { return }
    articleDisplayLimit = nextLimit
  }

  /// Fast-path for a prepared list. The visible list already owns this index
  /// map, so keyboard navigation/reveal must not re-filter and linearly scan
  /// thousands of headers on the main actor.
  func revealArticle(_ articleID: String, index: Int, totalCount: Int) {
    guard index >= 0, index < totalCount else { return }
    let requiredLimit = ((index / Self.articlePageSize) + 1) * Self.articlePageSize
    let nextLimit = min(totalCount, max(articleDisplayLimit, requiredLimit))
    guard nextLimit != articleDisplayLimit else { return }
    articleDisplayLimit = nextLimit
  }

  func sidebarCounts(in store: RSSReaderStore) -> RSSFeedSidebarCounts {
    if let sidebarCountsCache, sidebarCountsCache.revision == store.mutationRevision {
      return sidebarCountsCache.counts
    }
    let counts = RSSFeedSidebarCounts(articles: store.articleHeaders)
    sidebarCountsCache = (store.mutationRevision, counts)
    return counts
  }

  func articleHeader(id: String?, in store: RSSReaderStore) -> RSSArticleHeader? {
    guard let id else { return nil }
    return store.articleHeader(id: id)
  }

  func readerMetrics(for article: RSSArticle) -> (hasRenderableBody: Bool, readingMinutes: Int) {
    if let cached = readerMetricsCache[article.id],
      cached.fetchedAt == article.fetchedAt
    {
      touchReaderMetrics(article.id)
      return (cached.hasRenderableBody, cached.readingMinutes)
    }
    let bodyMetrics = RSSArticleHTMLRenderer.bodyMetrics(article: article)
    let metrics = ReaderMetricsCacheEntry(
      fetchedAt: article.fetchedAt,
      hasRenderableBody: bodyMetrics.hasRenderableBody,
      readingMinutes: max(1, Int(ceil(Double(bodyMetrics.readingUnits) / 220.0)))
    )
    readerMetricsCache[article.id] = metrics
    touchReaderMetrics(article.id)
    if readerMetricsLRU.count > 100 {
      let evictedID = readerMetricsLRU.removeFirst()
      readerMetricsCache.removeValue(forKey: evictedID)
    }
    return (metrics.hasRenderableBody, metrics.readingMinutes)
  }

  /// Stores metrics computed off the main actor before the reader view is
  /// published. The reader can then use `readerMetrics(for:)` as a cheap cache
  /// lookup instead of sanitizing the article body during view construction.
  func cacheReaderMetrics(
    for article: RSSArticle,
    hasRenderableBody: Bool,
    readingUnits: Int
  ) {
    let metrics = ReaderMetricsCacheEntry(
      fetchedAt: article.fetchedAt,
      hasRenderableBody: hasRenderableBody,
      readingMinutes: max(1, Int(ceil(Double(max(0, readingUnits)) / 220.0)))
    )
    readerMetricsCache[article.id] = metrics
    touchReaderMetrics(article.id)
    if readerMetricsLRU.count > 100 {
      let evictedID = readerMetricsLRU.removeFirst()
      readerMetricsCache.removeValue(forKey: evictedID)
    }
  }

  private func touchReaderMetrics(_ articleID: String) {
    readerMetricsLRU.removeAll { $0 == articleID }
    readerMetricsLRU.append(articleID)
  }

  private func articleQueryCacheKey(in store: RSSReaderStore) -> ArticleQueryCacheKey {
    ArticleQueryCacheKey(
      revision: store.mutationRevision,
      scope: selectedScope ?? .all,
      searchText: debouncedSearchText,
      unreadOnly: unreadOnly,
      sourceID: selectedSourceID,
      author: selectedAuthor,
      tag: selectedTag,
      dateRange: dateRange.rawValue,
      sortOrder: sortOrder.rawValue
    )
  }

  private func visibleArticlePageCacheKey(
    in store: RSSReaderStore
  ) -> VisibleArticlePageCacheKey {
    VisibleArticlePageCacheKey(
      query: articleQueryCacheKey(in: store),
      displayLimit: articleDisplayLimit
    )
  }

  private func scopedFacets(in store: RSSReaderStore) -> ArticleFacets {
    let scope = selectedScope ?? .all
    let key = ArticleScopeCacheKey(revision: store.mutationRevision, scope: scope)
    if let articleFacetsCache, articleFacetsCache.key == key {
      return articleFacetsCache.facets
    }
    let articles = scopedArticles(in: store)
    let facets = ArticleFacets(
      sourceIDs: Set(articles.map(\.feedID)),
      authors: Array(Set(articles.compactMap { $0.author?.trimmedForPublishing.nilIfEmpty }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending },
      tags: Array(Set(articles.flatMap(\.tags)))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    )
    articleFacetsCache = (key, facets)
    return facets
  }

  func synchronizeSelection(
    in store: RSSReaderStore,
    preservingExistingArticle: Bool = false
  ) {
    guard let selectedArticleID else { return }
    if preservingExistingArticle,
      store.articleHeader(id: selectedArticleID) != nil
    {
      return
    }
    if !matchingArticles(in: store).contains(where: { $0.id == selectedArticleID }) {
      self.selectedArticleID = nil
    }
  }

  func addSubscription(_ value: String, to store: RSSReaderStore) {
    let trimmedValue = value.trimmedForPublishing
    guard let url = URL(string: trimmedValue) else {
      errorMessage = RSSReaderError.invalidFeedURL.localizedDescription
      return
    }
    errorMessage = nil
    isAddSubscriptionPresented = false
    isDiscoveringSubscription = true
    statusMessage = String(localized: "正在发现 RSS / Atom 订阅…")
    let requestID = UUID()
    subscriptionDiscoveryRequestID = requestID
    Task { @MainActor [weak self] in
      guard let self else { return }
      let discovered =
        (try? await RSSFeedDiscoveryService(
          allowsPrivateNetworkAccess: store.privateNetworkAccessEnabled
        ).discover(from: url)) ?? []
      guard self.subscriptionDiscoveryRequestID == requestID else { return }
      self.isDiscoveringSubscription = false
      if discovered.count > 1 {
        self.subscriptionDiscovery = RSSSubscriptionDiscovery(
          sourceURL: url,
          feedURLs: discovered
        )
        return
      }
      do {
        try await addFeedURLs(discovered.isEmpty ? [url] : discovered, to: store)
      } catch {
        statusMessage = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  func addDiscoveredSubscriptions(_ feedURLs: [URL], to store: RSSReaderStore) {
    guard !feedURLs.isEmpty else {
      cancelSubscriptionDiscovery()
      return
    }
    subscriptionDiscovery = nil
    isDiscoveringSubscription = false
    subscriptionDiscoveryRequestID = UUID()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await addFeedURLs(feedURLs, to: store)
      } catch {
        statusMessage = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  func cancelSubscriptionDiscovery() {
    subscriptionDiscovery = nil
    isDiscoveringSubscription = false
    subscriptionDiscoveryRequestID = UUID()
    statusMessage = nil
  }

  private func addFeedURLs(_ feedURLs: [URL], to store: RSSReaderStore) async throws {
    var feedIDs: [UUID] = []
    for feedURL in feedURLs {
      feedIDs.append(try store.addFeed(url: feedURL))
    }
    guard let firstFeedID = feedIDs.first else {
      throw RSSReaderError.invalidFeedURL
    }
    selectedScope = .feed(firstFeedID)
    selectedArticleID = nil
    for feedID in feedIDs {
      await store.refresh(feedID: feedID)
    }
    synchronizeSelection(in: store)
  }

  public func isTruncatedCandidate(_ article: RSSArticle) -> Bool {
    fullTextService.isTruncatedCandidate(article)
  }

  public func isShowingFullText(for articleID: String) -> Bool {
    showingFullTextIDs.contains(articleID)
  }

  public func isFetchingFullText(for articleID: String) -> Bool {
    fetchingFullTextIDs.contains(articleID)
  }

  public func fullTextError(for articleID: String) -> String? {
    fullTextErrorByArticleID[articleID]
  }

  public func effectiveArticle(for article: RSSArticle) -> RSSArticle {
    if showingFullTextIDs.contains(article.id), let fullText = fullTextArticles[article.id] {
      return fullText
    }
    return article
  }

  /// Restores a successful independent cache record when an article is opened.
  /// A record already present in this presentation session keeps the user's
  /// current summary/full-text toggle instead of forcing it on again.
  @discardableResult
  public func restoreCachedFullText(
    for article: RSSArticle,
    store: RSSReaderStore
  ) -> Bool {
    let persistedRecord = try? store.fullTextRecord(articleID: article.id)
    if fullTextArticles[article.id] != nil {
      if let record = fullTextRecords[article.id] {
        if !Self.record(record, matches: article) {
          clearFullTextCache(articleID: article.id)
        } else {
          // Another reader window may have refreshed the shared SQLite cache.
          // Adopt only a newer successful record, without changing this
          // window's current summary/full-text toggle.
          if let persistedRecord,
             persistedRecord.status == .ready,
             Self.record(persistedRecord, matches: article),
             persistedRecord.attemptedAt > record.attemptedAt {
            cacheFullText(persistedRecord, for: article)
          }
          touchFullTextArticle(article.id)
          return true
        }
      } else {
        touchFullTextArticle(article.id)
        return true
      }
    }
    guard let persistedRecord,
          persistedRecord.status == .ready,
          Self.record(persistedRecord, matches: article) else {
      return false
    }
    cacheFullText(persistedRecord, for: article)
    showingFullTextIDs.insert(article.id)
    return true
  }

  public func cachedFullTextNeedsRevalidation(
    for article: RSSArticle,
    now: Date = Date()
  ) -> Bool {
    guard let record = fullTextRecords[article.id],
          record.status == .ready,
          Self.record(record, matches: article) else {
      return false
    }
    if let retryAfter = record.retryAfter, retryAfter > now { return false }
    if !Self.usesCurrentExtractor(record) { return true }
    if record.retryAfter != nil || record.failureMessage != nil { return true }
    return article.fetchedAt > record.attemptedAt
  }

  public func fetchFullText(
    for article: RSSArticle,
    store: RSSReaderStore? = nil,
    respectsRetryAfter: Bool = false,
    forceRefresh: Bool = false
  ) async {
    let articleID = article.id
    guard !fetchingFullTextIDs.contains(articleID) else { return }

    var cachedRecord: RSSArticleFullTextRecord?
    if let memoryRecord = fullTextRecords[articleID] {
      if Self.record(memoryRecord, matches: article) {
        cachedRecord = memoryRecord
      } else {
        clearFullTextCache(articleID: articleID)
      }
    }
    if let store {
      do {
        if let persistedRecord = try store.fullTextRecord(articleID: articleID),
           Self.record(persistedRecord, matches: article) {
          if cachedRecord.map({ persistedRecord.attemptedAt > $0.attemptedAt }) ?? true {
            cachedRecord = persistedRecord
          }
        }
      } catch {
        // An in-memory ready record remains usable when the cache read fails.
      }
    }
    if respectsRetryAfter,
       let retryAfter = cachedRecord?.retryAfter,
       retryAfter > Date() {
      return
    }

    fetchingFullTextIDs.insert(articleID)
    fullTextErrorByArticleID.removeValue(forKey: articleID)
    fullTextErrorLRU.removeAll { $0 == articleID }
    defer { fetchingFullTextIDs.remove(articleID) }

    do {
      let record = try await fullTextRequestBroker.fetch(
        article: article,
        cachedRecord: cachedRecord,
        allowsPrivateNetworkAccess: store?.privateNetworkAccessEnabled ?? false,
        forceRefresh: forceRefresh,
        service: fullTextService
      )
      if record.status == .ready {
        let fullTextArticle = fullTextService.articleByApplying(record, to: article)
        let bodyMetrics = await Task.detached(priority: .userInitiated) {
          RSSArticleHTMLRenderer.bodyMetrics(article: fullTextArticle)
        }.value
        cacheFullText(record, for: article)
        cacheReaderMetrics(
          for: fullTextArticle,
          hasRenderableBody: bodyMetrics.hasRenderableBody,
          readingUnits: bodyMetrics.readingUnits
        )
        showingFullTextIDs.insert(articleID)
        // Reading proceeds immediately; SQLite/FTS persistence stays off the
        // main actor and may finish just after the reader updates.
        if let store { try? await store.saveFullTextRecordAsync(record) }
        return
      }

      // A rejected re-extraction never replaces the last known-good ready
      // body. Retry metadata is merged into that ready record so automatic
      // opening still honors backoff instead of hammering the origin.
      if let cachedRecord, cachedRecord.status == .ready {
        let preservedRecord = Self.readyRecord(
          preserving: cachedRecord,
          afterFailedAttempt: record
        )
        cacheFullText(preservedRecord, for: article)
        showingFullTextIDs.insert(articleID)
        if let store { try? await store.saveFullTextRecordAsync(preservedRecord) }
      }
      recordFullTextError(
        record.failureMessage ?? String(localized: "提取结果未通过正文质量校验。"),
        articleID: articleID
      )
      if let store, cachedRecord?.status != .ready {
        try? await store.saveFullTextRecordAsync(record)
      }
    } catch {
      let failedRecord = fullTextService.failureRecord(
        for: article,
        cachedRecord: cachedRecord,
        error: error
      )
      if let cachedRecord, cachedRecord.status == .ready {
        let preservedRecord = Self.readyRecord(
          preserving: cachedRecord,
          afterFailedAttempt: failedRecord
        )
        cacheFullText(preservedRecord, for: article)
        showingFullTextIDs.insert(articleID)
        if let store { try? await store.saveFullTextRecordAsync(preservedRecord) }
      } else if let store {
        try? await store.saveFullTextRecordAsync(failedRecord)
      }
      recordFullTextError(error.localizedDescription, articleID: articleID)
    }
  }

  public func toggleFullText(for article: RSSArticle, store: RSSReaderStore? = nil) {
    let articleID = article.id
    if showingFullTextIDs.contains(articleID) {
      showingFullTextIDs.remove(articleID)
    } else {
      if fullTextArticles[articleID] != nil {
        touchFullTextArticle(articleID)
        showingFullTextIDs.insert(articleID)
      } else if let store, restoreCachedFullText(for: article, store: store) {
        showingFullTextIDs.insert(articleID)
      } else {
        Task {
          await fetchFullText(for: article, store: store)
        }
      }
    }
  }

  private func cacheFullText(
    _ record: RSSArticleFullTextRecord,
    for article: RSSArticle
  ) {
    fullTextRecords[article.id] = record
    fullTextArticles[article.id] = fullTextService.articleByApplying(record, to: article)
    readerMetricsCache.removeValue(forKey: article.id)
    readerMetricsLRU.removeAll { $0 == article.id }
    touchFullTextArticle(article.id)
    while fullTextArticleLRU.count > 16, let evictedID = fullTextArticleLRU.first {
      fullTextArticleLRU.removeFirst()
      fullTextArticles.removeValue(forKey: evictedID)
      fullTextRecords.removeValue(forKey: evictedID)
      showingFullTextIDs.remove(evictedID)
      fullTextErrorByArticleID.removeValue(forKey: evictedID)
      fullTextErrorLRU.removeAll { $0 == evictedID }
    }
  }

  private func touchFullTextArticle(_ articleID: String) {
    fullTextArticleLRU.removeAll { $0 == articleID }
    fullTextArticleLRU.append(articleID)
  }

  private func clearFullTextCache(articleID: String) {
    fullTextArticles.removeValue(forKey: articleID)
    fullTextRecords.removeValue(forKey: articleID)
    showingFullTextIDs.remove(articleID)
    fullTextArticleLRU.removeAll { $0 == articleID }
  }

  private func recordFullTextError(_ message: String, articleID: String) {
    fullTextErrorByArticleID[articleID] = message
    fullTextErrorLRU.removeAll { $0 == articleID }
    fullTextErrorLRU.append(articleID)
    while fullTextErrorLRU.count > 32, let evictedID = fullTextErrorLRU.first {
      fullTextErrorLRU.removeFirst()
      fullTextErrorByArticleID.removeValue(forKey: evictedID)
    }
  }

  private static func record(
    _ record: RSSArticleFullTextRecord,
    matches article: RSSArticle
  ) -> Bool {
    guard record.articleID == article.id,
          let sourceURL = record.sourceURL,
          let articleURL = article.link else { return false }
    return sourceURL.absoluteString == articleURL.absoluteString
  }

  private static func usesCurrentExtractor(_ record: RSSArticleFullTextRecord) -> Bool {
    record.extractorIdentifier == RSSArticleDOMExtractionService.extractorIdentifier
      && record.extractorVersion == RSSArticleDOMExtractionService.extractorVersion
  }

  private static func readyRecord(
    preserving cachedRecord: RSSArticleFullTextRecord,
    afterFailedAttempt attempt: RSSArticleFullTextRecord
  ) -> RSSArticleFullTextRecord {
    RSSArticleFullTextRecord(
      articleID: cachedRecord.articleID,
      status: .ready,
      contentHTML: cachedRecord.contentHTML,
      plainText: cachedRecord.plainText,
      sourceURL: cachedRecord.sourceURL,
      resolvedURL: cachedRecord.resolvedURL,
      extractorIdentifier: cachedRecord.extractorIdentifier,
      extractorVersion: cachedRecord.extractorVersion,
      sourceETag: cachedRecord.sourceETag,
      sourceLastModified: cachedRecord.sourceLastModified,
      sourceContentHash: cachedRecord.sourceContentHash,
      confidence: cachedRecord.confidence,
      attemptedAt: attempt.attemptedAt,
      retryAfter: attempt.retryAfter,
      failureMessage: attempt.failureMessage
    )
  }
}

/// Keeps the high-frequency WebKit scroll callback from publishing duplicate
/// state updates while preserving the initial value, the completion value, and
/// the 1% progress granularity used by the list presentation.
enum RSSReadingProgressPolicy {
  static let minimumPersistDelta = 0.01

  static func shouldRecord(
    previousProgress: Double?,
    progress: Double
  ) -> Bool {
    guard progress.isFinite else { return false }
    let normalized = min(max(progress, 0), 1)
    guard let previousProgress else { return true }
    let previous = min(max(previousProgress, 0), 1)
    guard normalized != previous else { return false }
    if RSSReadingCompletionPolicy.didCrossCompletionThreshold(
      previousProgress: previous,
      progress: normalized
    ) {
      return true
    }
    return normalized == 0
      || normalized == 1
      || abs(normalized - previous) >= minimumPersistDelta
  }
}
