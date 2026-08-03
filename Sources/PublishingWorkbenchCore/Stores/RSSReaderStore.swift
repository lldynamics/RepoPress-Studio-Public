import Combine
import Foundation

public struct RSSReaderSnapshot: Codable, Sendable {
  public static let currentSchemaVersion = 3

  public var schemaVersion: Int
  public var feeds: [RSSFeed]
  public var articles: [RSSArticle]
  public var highlights: [RSSArticleHighlight]
  public var mediaAssets: [RSSMediaAsset]

  public init(
    schemaVersion: Int = RSSReaderSnapshot.currentSchemaVersion,
    feeds: [RSSFeed] = [],
    articles: [RSSArticle] = [],
    highlights: [RSSArticleHighlight] = [],
    mediaAssets: [RSSMediaAsset] = []
  ) {
    self.schemaVersion = schemaVersion
    self.feeds = feeds
    self.articles = articles
    self.highlights = highlights
    self.mediaAssets = mediaAssets
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case feeds
    case articles
    case highlights
    case mediaAssets
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
      feeds: try container.decodeIfPresent([RSSFeed].self, forKey: .feeds) ?? [],
      articles: try container.decodeIfPresent([RSSArticle].self, forKey: .articles) ?? [],
      highlights: try container.decodeIfPresent([RSSArticleHighlight].self, forKey: .highlights) ?? [],
      mediaAssets: try container.decodeIfPresent([RSSMediaAsset].self, forKey: .mediaAssets) ?? []
    )
  }
}

private struct RSSArticlePayloadLRU {
  let capacity: Int
  private var articlesByID: [String: RSSArticle] = [:]
  private var idsByRecency: [String] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  var count: Int { articlesByID.count }
  var cachedIDs: Set<String> { Set(articlesByID.keys) }

  mutating func article(id: String) -> RSSArticle? {
    guard let article = articlesByID[id] else { return nil }
    markRecentlyUsed(id)
    return article
  }

  mutating func insert(_ article: RSSArticle) {
    articlesByID[article.id] = article
    markRecentlyUsed(article.id)
    while articlesByID.count > capacity, let leastRecentID = idsByRecency.first {
      idsByRecency.removeFirst()
      articlesByID.removeValue(forKey: leastRecentID)
    }
  }

  mutating func remove(id: String) {
    articlesByID.removeValue(forKey: id)
    idsByRecency.removeAll { $0 == id }
  }

  mutating func remove(ids: Set<String>) {
    guard !ids.isEmpty else { return }
    for id in ids { articlesByID.removeValue(forKey: id) }
    idsByRecency.removeAll { ids.contains($0) }
  }

  mutating func removeAll() {
    articlesByID.removeAll(keepingCapacity: true)
    idsByRecency.removeAll(keepingCapacity: true)
  }

  private mutating func markRecentlyUsed(_ id: String) {
    idsByRecency.removeAll { $0 == id }
    idsByRecency.append(id)
  }
}

private actor RSSArticlePayloadLoader {
  private let databaseURL: URL
  private var database: RSSReaderDatabase?

  init(databaseURL: URL) {
    self.databaseURL = databaseURL
  }

  func article(id: String) throws -> RSSArticle? {
    if database == nil {
      database = try RSSReaderDatabase(fileURL: databaseURL)
    }
    return try database?.article(id: id)
  }
}

@MainActor
public final class RSSReaderStore: ObservableObject {
  public static let retentionDaysDefaultsKey = "rssArticleRetentionDays"
  public static let automaticPruningDefaultsKey = "rssAutomaticPruningEnabled"
  public static let lastPruneDateDefaultsKey = "rssLastAutomaticPruneDate"
  public static let defaultRetentionDays = 60
  public static let maximumRefreshConcurrency = 6

  nonisolated public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return supportURL
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("RSSReader", isDirectory: true)
      .appendingPathComponent("reader.sqlite", isDirectory: false)
  }

  nonisolated public static func databaseFileURL(for fileURL: URL) -> URL {
    guard fileURL.pathExtension.lowercased() == "json" else { return fileURL }
    return fileURL.deletingPathExtension().appendingPathExtension("sqlite")
  }

  nonisolated public static func legacyFileURL(for fileURL: URL) -> URL {
    guard fileURL.pathExtension.lowercased() != "json" else { return fileURL }
    return fileURL.deletingPathExtension().appendingPathExtension("json")
  }

  nonisolated public static func mediaCacheDirectoryURL(for fileURL: URL) -> URL {
    databaseFileURL(for: fileURL)
      .deletingLastPathComponent()
      .appendingPathComponent("RSSMedia", isDirectory: true)
  }

  public var mediaCacheDirectoryURL: URL {
    Self.mediaCacheDirectoryURL(for: fileURL)
  }

  @Published public private(set) var feeds: [RSSFeed] = []
  @Published public private(set) var articleHeaders: [RSSArticleHeader] = []
  @Published public private(set) var highlights: [RSSArticleHighlight] = []
  @Published public private(set) var mediaAssets: [RSSMediaAsset] = []
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var refreshingFeedIDs: Set<UUID> = []
  @Published public private(set) var statusMessage: String?
  @Published public private(set) var lastError: String?
  @Published public private(set) var lastRefreshSummary: RSSRefreshSummary?
  @Published public private(set) var mutationRevision: UInt64 = 0
  @Published public private(set) var canUndoLastDeletion = false
  @Published public private(set) var canUndoLastBatchRead = false
  @Published public private(set) var retentionDays: Int
  @Published public private(set) var automaticPruningEnabled: Bool
  @Published public private(set) var lastPruneSummary: RSSArticlePruneSummary?

  public let fileURL: URL

  public typealias FeedFetchOperation = @Sendable (
    _ feedURL: URL,
    _ etag: String?,
    _ lastModified: String?
  ) async throws -> RSSFeedFetchResult

  private let fetchOperation: FeedFetchOperation
  private let fileManager: FileManager
  private let userDefaults: UserDefaults
  private let databaseURL: URL
  private let legacyURL: URL
  private let mediaArchiver: RSSMediaArchiver
  private var database: RSSReaderDatabase?
  private var payloadLoader: RSSArticlePayloadLoader?
  private var payloadCache = RSSArticlePayloadLRU(capacity: 16)
  private var articleLoadTasks: [String: Task<RSSArticle?, Error>] = [:]
  private var legacyArticles: [RSSArticle] = []
  private var mediaArchiveArticleIDs = Set<String>()
  private var lastDeletedFeedSnapshot: DeletedFeedSnapshot?
  private var lastBatchReadSnapshot: BatchReadSnapshot?
  private var backgroundRefreshTimer: Timer?
  private var retryTimer: Timer?
  private var backgroundRefreshInterval: TimeInterval?

  private struct DeletedFeedSnapshot {
    var feed: RSSFeed
    var articles: [RSSArticle]
    var highlights: [RSSArticleHighlight]
    var mediaAssets: [RSSMediaAsset]
  }

  private struct RefreshRequest: Sendable {
    var feedID: UUID
    var url: URL
    var etag: String?
    var lastModified: String?
    var startedAt: Date
  }

  private struct RefreshFetchOutcome: Sendable {
    var request: RefreshRequest
    var result: RSSFeedFetchResult?
    var issue: RSSFeedIssue?
  }

  private struct RefreshOutcome: Sendable {
    var succeeded: Bool
    var skipped: Bool
    var message: String?
    var issue: RSSFeedIssue?
  }

  private struct BatchReadState {
    var articleID: String
    var readAt: Date?
  }

  private struct BatchReadSnapshot {
    var states: [BatchReadState]
  }

  private struct MergeResult {
    var headers: [RSSArticleHeader]
    var articlesToUpsert: [RSSArticle]
    var highlights: [RSSArticleHighlight]
  }

  static let articlePayloadCacheCapacity = 16
  private static let persistedDateComparisonTolerance: TimeInterval = 0.000001

  private static func persistedDatesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
    abs(lhs.timeIntervalSince(rhs)) <= persistedDateComparisonTolerance
  }

  public init(
    fileURL: URL? = nil,
    client: RSSFeedClient = RSSFeedClient(),
    fileManager: FileManager = .default,
    fetchOperation: FeedFetchOperation? = nil,
    userDefaults: UserDefaults = .standard,
    mediaArchiver: RSSMediaArchiver? = nil
  ) {
    let requestedFileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    self.fileURL = requestedFileURL
    self.fetchOperation = fetchOperation ?? { feedURL, etag, lastModified in
      try await client.fetch(feedURL: feedURL, etag: etag, lastModified: lastModified)
    }
    self.fileManager = fileManager
    self.userDefaults = userDefaults
    self.databaseURL = Self.databaseFileURL(for: requestedFileURL)
    self.legacyURL = Self.legacyFileURL(for: requestedFileURL)
    let storedRetentionDays = userDefaults.object(
      forKey: Self.retentionDaysDefaultsKey
    ) as? Int ?? Self.defaultRetentionDays
    self.retentionDays = Self.normalizedRetentionDays(storedRetentionDays)
    self.automaticPruningEnabled = userDefaults.object(
      forKey: Self.automaticPruningDefaultsKey
    ) as? Bool ?? false
    self.mediaArchiver = mediaArchiver ?? RSSMediaArchiver(
      cacheDirectoryURL: Self.mediaCacheDirectoryURL(for: requestedFileURL),
      fileManager: fileManager
    )

    do {
      self.database = try RSSReaderDatabase(fileURL: Self.databaseFileURL(for: requestedFileURL), fileManager: fileManager)
      self.payloadLoader = RSSArticlePayloadLoader(databaseURL: Self.databaseFileURL(for: requestedFileURL))
    } catch {
      self.database = nil
      self.payloadLoader = nil
      self.lastError = "RSS 将使用兼容缓存：SQLite 数据库不可用。\n\(error.localizedDescription)"
    }

    load()
  }

  deinit {
    backgroundRefreshTimer?.invalidate()
    retryTimer?.invalidate()
    for task in articleLoadTasks.values { task.cancel() }
  }

  /// Payload-free compatibility view for call sites that have not migrated to
  /// `articleHeaders` yet. Reading this property never performs database I/O.
  @available(*, deprecated, message: "Use articleHeaders and loadArticle(id:) instead")
  public var articles: [RSSArticle] {
    if database == nil { return legacyArticles }
    return articleHeaders.map(RSSArticle.init(header:))
  }

  public var unreadCount: Int {
    articleHeaders.reduce(into: 0) { count, header in
      if !header.isRead { count += 1 }
    }
  }

  public func unreadCount(for feedID: UUID) -> Int {
    articleHeaders.reduce(into: 0) { count, header in
      if header.feedID == feedID && !header.isRead { count += 1 }
    }
  }

  public func highlights(for articleID: String) -> [RSSArticleHighlight] {
    highlights
      .filter { $0.articleID == articleID }
      .sorted { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.createdAt > rhs.createdAt
      }
  }

  public func mediaAssets(for articleID: String) -> [RSSMediaAsset] {
    mediaAssets
      .filter { $0.articleID == articleID }
      .sorted { $0.remoteURL.absoluteString < $1.remoteURL.absoluteString }
  }

  public func updateRetentionSettings(enabled: Bool, days: Int) {
    automaticPruningEnabled = enabled
    retentionDays = Self.normalizedRetentionDays(days)
    userDefaults.set(automaticPruningEnabled, forKey: Self.automaticPruningDefaultsKey)
    userDefaults.set(retentionDays, forKey: Self.retentionDaysDefaultsKey)
    if enabled {
      _ = pruneReadArticles(olderThanDays: retentionDays)
    }
  }

  @discardableResult
  public func pruneReadArticles(
    olderThanDays days: Int? = nil,
    now: Date = Date()
  ) -> RSSArticlePruneSummary {
    let normalizedDays = Self.normalizedRetentionDays(days ?? retentionDays)
    let cutoff = now.addingTimeInterval(-TimeInterval(normalizedDays) * 86_400)
    let candidateIDs: Set<String>
    do {
      if let database {
        candidateIDs = try database.eligibleArticleIDsForPruning(before: cutoff)
      } else {
        candidateIDs = Set(legacyArticles.compactMap { article in
          guard article.isRead,
                !article.isStarred,
                (article.publishedAt ?? article.fetchedAt) < cutoff,
                !highlights.contains(where: { $0.articleID == article.id })
          else { return nil }
          return article.id
        })
      }
    } catch {
      lastError = "RSS 历史清理失败：\(error.localizedDescription)"
      let summary = RSSArticlePruneSummary(cutoffDate: cutoff)
      lastPruneSummary = summary
      return summary
    }

    guard !candidateIDs.isEmpty else {
      let summary = RSSArticlePruneSummary(cutoffDate: cutoff)
      lastPruneSummary = summary
      userDefaults.set(now, forKey: Self.lastPruneDateDefaultsKey)
      return summary
    }

    let removedAssets = mediaAssets.filter { candidateIDs.contains($0.articleID) }
    do {
      try database?.deleteArticles(ids: candidateIDs)
      articleHeaders.removeAll { candidateIDs.contains($0.id) }
      legacyArticles.removeAll { candidateIDs.contains($0.id) }
      highlights.removeAll { candidateIDs.contains($0.articleID) }
      mediaAssets.removeAll { candidateIDs.contains($0.articleID) }
      payloadCache.remove(ids: candidateIDs)
      for articleID in candidateIDs {
        articleLoadTasks[articleID]?.cancel()
        articleLoadTasks[articleID] = nil
      }
      try persistLegacyIfNeeded()
      let summary = RSSArticlePruneSummary(
        removedArticleCount: candidateIDs.count,
        removedMediaAssetCount: removedAssets.count,
        cutoffDate: cutoff
      )
      lastPruneSummary = summary
      userDefaults.set(now, forKey: Self.lastPruneDateDefaultsKey)
      statusMessage = "已清理 \(candidateIDs.count) 篇过期已读文章。"
      lastError = nil
      bumpMutationRevision()
      Task { await mediaArchiver.remove(assets: removedAssets) }
      return summary
    } catch {
      lastError = "RSS 历史清理失败：\(error.localizedDescription)"
      let summary = RSSArticlePruneSummary(cutoffDate: cutoff)
      lastPruneSummary = summary
      return summary
    }
  }

  public func articleHeaders(
    for scope: RSSArticleScope,
    searchText: String = "",
    unreadOnly: Bool = false
  ) -> [RSSArticleHeader] {
    let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let searchIDs: Set<String>? = if normalizedSearch.isEmpty {
      nil
    } else if database == nil {
      Set(legacyArticles.lazy.filter { article in
        article.title.localizedCaseInsensitiveContains(normalizedSearch)
          || article.readableText.localizedCaseInsensitiveContains(normalizedSearch)
      }.map(\.id))
    } else {
      try? database?.matchingArticleIDs(query: normalizedSearch)
    }

    return articleHeaders
      .filter { header in
        switch scope {
        case .all:
          true
        case .unread:
          !header.isRead
        case .starred:
          header.isStarred
        case let .feed(feedID):
          header.feedID == feedID
        }
      }
      .filter { header in
        guard unreadOnly else { return true }
        return !header.isRead
      }
      .filter { header in
        guard !normalizedSearch.isEmpty else { return true }
        if let searchIDs { return searchIDs.contains(header.id) }
        return header.title.localizedCaseInsensitiveContains(normalizedSearch)
          || header.readableSummary.localizedCaseInsensitiveContains(normalizedSearch)
      }
      .sorted { lhs, rhs in
        let leftDate = lhs.publishedAt ?? lhs.fetchedAt
        let rightDate = rhs.publishedAt ?? rhs.fetchedAt
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.id < rhs.id
      }
  }

  @available(*, deprecated, message: "Use articleHeaders(for:searchText:unreadOnly:) instead")
  public func articles(
    for scope: RSSArticleScope,
    searchText: String = "",
    unreadOnly: Bool = false
  ) -> [RSSArticle] {
    articleHeaders(for: scope, searchText: searchText, unreadOnly: unreadOnly)
      .map(RSSArticle.init(header:))
  }

  public func articleHeader(id: String) -> RSSArticleHeader? {
    articleHeaders.first { $0.id == id }
  }

  public func loadArticle(id: String) async throws -> RSSArticle? {
    guard let expectedHeader = articleHeader(id: id) else { return nil }
    if var cached = payloadCache.article(id: id), cached.fetchedAt == expectedHeader.fetchedAt {
      cached.apply(header: expectedHeader)
      payloadCache.insert(cached)
      return cached
    }
    payloadCache.remove(id: id)

    if database == nil {
      guard var article = legacyArticles.first(where: { $0.id == id }) else { return nil }
      article.apply(header: expectedHeader)
      payloadCache.insert(article)
      return article
    }
    guard let payloadLoader else { return nil }

    let task: Task<RSSArticle?, Error>
    if let pending = articleLoadTasks[id] {
      task = pending
    } else {
      let pending = Task { try await payloadLoader.article(id: id) }
      articleLoadTasks[id] = pending
      task = pending
    }

    var loaded: RSSArticle?
    do {
      loaded = try await task.value
    } catch {
      articleLoadTasks[id] = nil
      // A second SQLite connection can briefly observe a busy or just-closed
      // WAL while a refresh is committing. The store's already-open handle is
      // the authoritative fallback and avoids turning a valid header into a
      // blank reader pane.
      loaded = try database?.article(id: id)
    }
    articleLoadTasks[id] = nil
    if loaded == nil {
      loaded = try database?.article(id: id)
    }
    guard var loaded else { return nil }
    guard let currentHeader = articleHeader(id: id) else { return nil }
    guard Self.persistedDatesMatch(loaded.fetchedAt, currentHeader.fetchedAt) else {
      return try await loadFreshArticleAfterRevisionChange(id: id)
    }
    loaded.apply(header: currentHeader)
    payloadCache.insert(loaded)
    return loaded
  }

  var cachedArticleIDs: Set<String> { payloadCache.cachedIDs }
  var cachedArticleCount: Int { payloadCache.count }

  @discardableResult
  public func addFeed(url: URL, title: String? = nil) throws -> UUID {
    try validateFeedURL(url)

    if let existing = feeds.first(where: { $0.url.absoluteString == url.absoluteString }) {
      return existing.id
    }

    let feed = RSSFeed(
      title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? url.host
        ?? url.absoluteString,
      url: url
    )
    let updatedFeeds = feeds + [feed]
    do {
      try database?.upsertFeed(feed)
      try persistLegacySnapshotIfNeeded(
        feeds: updatedFeeds,
        articles: legacyArticles,
        highlights: highlights
      )
    } catch { throw error }
    feeds = updatedFeeds
    lastRefreshSummary = nil
    statusMessage = "已添加订阅，正在读取最新文章。"
    bumpMutationRevision()
    return feed.id
  }

  public func updateFeedURL(feedID: UUID, newURL: URL) throws {
    try validateFeedURL(newURL)
    guard let index = feeds.firstIndex(where: { $0.id == feedID }) else {
      throw RSSReaderError.persistence("找不到要修改的订阅。")
    }
    if feeds.contains(where: { $0.id != feedID && $0.url.absoluteString == newURL.absoluteString }) {
      throw RSSReaderError.issue(
        RSSFeedIssue(
          stage: .validation,
          category: .invalidAddress,
          retryStrategy: .requiresAction,
          userMessage: "该地址已经在订阅列表中。"
        )
      )
    }
    guard feeds[index].url != newURL else { return }

    var updatedFeed = feeds[index]
    updatedFeed.url = newURL
    updatedFeed.lastUpdatedAt = nil
    updatedFeed.etag = nil
    updatedFeed.lastModified = nil
    updatedFeed.lastError = nil
    updatedFeed.lastIssue = nil
    updatedFeed.lastRefreshAttemptAt = nil
    updatedFeed.refreshFailureCount = 0
    updatedFeed.nextRetryAt = nil
    updatedFeed.lastRefreshDuration = nil
    var updatedFeeds = feeds
    updatedFeeds[index] = updatedFeed

    try database?.upsertFeed(updatedFeed)
    try persistLegacySnapshotIfNeeded(
      feeds: updatedFeeds,
      articles: legacyArticles,
      highlights: highlights
    )
    feeds = updatedFeeds
    lastRefreshSummary = nil
    lastError = nil
    statusMessage = "订阅地址已更新；本地文章、收藏和高亮均已保留。"
    bumpMutationRevision()
    rescheduleRetryTimer()
  }

  public func isFeedRefreshing(_ feedID: UUID) -> Bool {
    refreshingFeedIDs.contains(feedID)
  }

  public var nextScheduledRefreshAt: Date? {
    feeds.compactMap { feed in
      guard feed.lastIssue?.shouldRetryAutomatically == true else { return nil }
      return feed.nextRetryAt ?? feed.lastIssue?.retryAt
    }.min()
  }

  @discardableResult
  public func importOPML(data: Data) throws -> [UUID] {
    let subscriptions = try RSSOPMLParser.parse(data: data)
    for subscription in subscriptions {
      try validateFeedURL(subscription.url)
      if let siteURL = subscription.siteURL,
         RSSSubscriptionURLPrivacy.containsUserInfo(siteURL) {
        throw RSSReaderError.invalidOPML("站点地址不得包含 URL 用户名或密码。")
      }
    }
    let originalFeeds = feeds
    var importedIDs: [UUID] = []
    var importedFeeds: [RSSFeed] = []
    for subscription in subscriptions {
      if let existing = feeds.first(where: { $0.url.absoluteString == subscription.url.absoluteString }) {
        importedIDs.append(existing.id)
        continue
      }
      let feed = RSSFeed(
        title: subscription.title,
        url: subscription.url,
        siteURL: subscription.siteURL
      )
      feeds.append(feed)
      importedFeeds.append(feed)
      importedIDs.append(feed.id)
    }
    do {
      try database?.upsertFeeds(importedFeeds)
      try persistLegacyIfNeeded()
    } catch {
      feeds = originalFeeds
      throw error
    }
    lastRefreshSummary = nil
    statusMessage = "已导入 \(importedIDs.count) 个订阅，正在读取最新文章。"
    bumpMutationRevision()
    return importedIDs
  }

  public func exportOPMLData(
    title: String = "RepoPress Studio RSS 订阅",
    privacyAction: RSSOPMLExportPrivacyAction = .redactCredentialQueryValues
  ) throws -> Data {
    try RSSOPMLWriter.makeDocument(
      subscriptions: feeds.map {
        RSSOPMLSubscription(title: $0.displayTitle, url: $0.url, siteURL: $0.siteURL)
      },
      title: title,
      privacyAction: privacyAction
    )
  }

  public func removeFeed(id: UUID) {
    guard let feed = feeds.first(where: { $0.id == id }) else { return }
    let deletedArticles: [RSSArticle]
    do {
      deletedArticles = if let database {
        try database.articles(feedID: id)
      } else {
        legacyArticles.filter { $0.feedID == id }
      }
    } catch {
      lastError = error.localizedDescription
      return
    }
    let deletedHeaders = articleHeaders.filter { $0.feedID == id }
    let deletedArticleIDs = Set(deletedArticles.map(\.id))
    let deletedHighlights = highlights.filter { deletedArticleIDs.contains($0.articleID) }
    let deletedMediaAssets = mediaAssets.filter { deletedArticleIDs.contains($0.articleID) }
    let feedIndex = feeds.firstIndex { $0.id == id }
    feeds.removeAll { $0.id == id }
    articleHeaders.removeAll { $0.feedID == id }
    legacyArticles.removeAll { $0.feedID == id }
    payloadCache.remove(ids: deletedArticleIDs)
    for articleID in deletedArticleIDs {
      articleLoadTasks.removeValue(forKey: articleID)?.cancel()
    }
    highlights.removeAll { deletedArticleIDs.contains($0.articleID) }
    mediaAssets.removeAll { deletedArticleIDs.contains($0.articleID) }
    do {
      try database?.deleteFeed(id: id)
      try persistLegacyIfNeeded()
      lastDeletedFeedSnapshot = DeletedFeedSnapshot(
        feed: feed,
        articles: deletedArticles,
        highlights: deletedHighlights,
        mediaAssets: deletedMediaAssets
      )
      canUndoLastDeletion = true
      lastRefreshSummary = nil
      bumpMutationRevision()
      statusMessage = "已删除“\(feed.displayTitle)”及 \(deletedArticles.count) 篇本地缓存，可立即撤销。"
      rescheduleRetryTimer()
    } catch {
      if let feedIndex, !feeds.contains(where: { $0.id == id }) {
        feeds.insert(feed, at: min(feedIndex, feeds.count))
      }
      articleHeaders.append(contentsOf: deletedHeaders)
      if database == nil { legacyArticles.append(contentsOf: deletedArticles) }
      highlights.append(contentsOf: deletedHighlights)
      mediaAssets.append(contentsOf: deletedMediaAssets)
      lastError = error.localizedDescription
    }
  }

  public func undoLastDeletion() {
    guard let snapshot = lastDeletedFeedSnapshot else { return }
    guard !feeds.contains(where: { $0.id == snapshot.feed.id }) else {
      clearDeletionUndo()
      return
    }
    feeds.append(snapshot.feed)
    articleHeaders.append(contentsOf: snapshot.articles.map(RSSArticleHeader.init(article:)))
    if database == nil { legacyArticles.append(contentsOf: snapshot.articles) }
    highlights.append(contentsOf: snapshot.highlights)
    do {
      try database?.restoreFeed(
        snapshot.feed,
        articles: snapshot.articles,
        highlights: snapshot.highlights,
        mediaAssets: snapshot.mediaAssets
      )
      mediaAssets.append(contentsOf: snapshot.mediaAssets)
      try persistLegacyIfNeeded()
      clearDeletionUndo()
      lastRefreshSummary = nil
      bumpMutationRevision()
      statusMessage = "已撤销删除，恢复“\(snapshot.feed.displayTitle)”及 \(snapshot.articles.count) 篇本地缓存。"
      rescheduleRetryTimer()
    } catch {
      feeds.removeAll { $0.id == snapshot.feed.id }
      articleHeaders.removeAll { $0.feedID == snapshot.feed.id }
      legacyArticles.removeAll { $0.feedID == snapshot.feed.id }
      let articleIDs = Set(snapshot.articles.map(\.id))
      highlights.removeAll { articleIDs.contains($0.articleID) }
      mediaAssets.removeAll { articleIDs.contains($0.articleID) }
      lastError = error.localizedDescription
    }
  }

  public func markRead(_ articleID: String, isRead: Bool = true) {
    guard let index = articleHeaders.firstIndex(where: { $0.id == articleID }) else { return }
    let nextReadAt = isRead ? (articleHeaders[index].readAt ?? Date()) : nil
    guard articleHeaders[index].readAt != nextReadAt else { return }
    let previous = articleHeaders[index].readAt
    articleHeaders[index].readAt = nextReadAt
    mutateLegacyAndCachedArticle(id: articleID) { $0.readAt = nextReadAt }
    do {
      try database?.updateRead(articleID: articleID, readAt: nextReadAt)
      try persistLegacyIfNeeded()
      lastError = nil
      bumpMutationRevision()
    } catch {
      articleHeaders[index].readAt = previous
      mutateLegacyAndCachedArticle(id: articleID) { $0.readAt = previous }
      lastError = error.localizedDescription
    }
  }

  public func toggleStarred(_ articleID: String) {
    guard let index = articleHeaders.firstIndex(where: { $0.id == articleID }) else { return }
    let nextValue = !articleHeaders[index].isStarred
    articleHeaders[index].isStarred = nextValue
    mutateLegacyAndCachedArticle(id: articleID) { $0.isStarred = nextValue }
    do {
      try database?.updateStarred(articleID: articleID, isStarred: nextValue)
      try persistLegacyIfNeeded()
      lastError = nil
      bumpMutationRevision()
      if nextValue {
        scheduleMediaArchive(for: articleID)
      }
    } catch {
      articleHeaders[index].isStarred.toggle()
      mutateLegacyAndCachedArticle(id: articleID) { $0.isStarred.toggle() }
      lastError = error.localizedDescription
    }
  }

  public func setArticleTags(_ tags: [String], for articleID: String) {
    guard let index = articleHeaders.firstIndex(where: { $0.id == articleID }) else { return }
    let normalized = RSSArticle.normalizedTags(tags)
    let previous = articleHeaders[index].tags
    guard previous != normalized else { return }
    articleHeaders[index].tags = normalized
    mutateLegacyAndCachedArticle(id: articleID) { $0.tags = normalized }
    do {
      try database?.updateTags(articleID: articleID, tags: normalized)
      try persistLegacyIfNeeded()
      lastError = nil
      bumpMutationRevision()
    } catch {
      articleHeaders[index].tags = previous
      mutateLegacyAndCachedArticle(id: articleID) { $0.tags = previous }
      lastError = error.localizedDescription
    }
  }

  @discardableResult
  public func saveHighlight(
    articleID: String,
    text: String,
    note: String = "",
    tags: [String] = [],
    existingID: UUID? = nil
  ) throws -> RSSArticleHighlight {
    guard articleHeaders.contains(where: { $0.id == articleID }) else {
      throw RSSReaderError.persistence("找不到要标注的文章。")
    }
    let now = Date()
    let id = existingID ?? UUID()
    let previous = highlights.first { $0.id == id }
    let highlight = RSSArticleHighlight(
      id: id,
      articleID: articleID,
      text: text,
      note: note,
      tags: tags,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now
    )
    if let index = highlights.firstIndex(where: { $0.id == id }) {
      highlights[index] = highlight
    } else {
      highlights.append(highlight)
    }
    do {
      if let database, try !database.containsArticle(id: articleID) {
        guard let article = payloadCache.article(id: articleID)
          ?? legacyArticles.first(where: { $0.id == articleID }) else {
          throw RSSReaderError.persistence("文章正文尚未写入本地数据库。")
        }
        try database.upsertArticles([article])
      }
      try database?.saveHighlight(highlight)
      try persistLegacyIfNeeded()
      lastError = nil
      bumpMutationRevision()
      scheduleMediaArchive(for: articleID)
      return highlight
    } catch {
      if let previous, let index = highlights.firstIndex(where: { $0.id == id }) {
        highlights[index] = previous
      } else {
        highlights.removeAll { $0.id == id }
      }
      throw error
    }
  }

  public func deleteHighlight(_ highlightID: UUID) {
    guard let index = highlights.firstIndex(where: { $0.id == highlightID }) else { return }
    let removed = highlights.remove(at: index)
    do {
      try database?.deleteHighlight(id: highlightID)
      try persistLegacyIfNeeded()
      lastError = nil
      bumpMutationRevision()
    } catch {
      highlights.insert(removed, at: min(index, highlights.count))
      lastError = error.localizedDescription
    }
  }

  public func markAllRead(for scope: RSSArticleScope) {
    let ids = Set(articleHeaders(for: scope).map(\.id))
    markAllRead(articleIDs: ids)
  }

  @discardableResult
  public func markAllRead(articleIDs: Set<String>) -> Int {
    guard !articleIDs.isEmpty else { return 0 }
    let now = Date()
    let previousStates = articleHeaders.compactMap { header -> BatchReadState? in
      guard articleIDs.contains(header.id), header.readAt == nil else { return nil }
      return BatchReadState(articleID: header.id, readAt: header.readAt)
    }
    guard !previousStates.isEmpty else {
      statusMessage = "当前列表中的文章已经全部标为已读。"
      return 0
    }
    let changedIDs = Set(previousStates.map(\.articleID))
    var updatedHeaders = articleHeaders
    for index in updatedHeaders.indices where changedIDs.contains(updatedHeaders[index].id) {
      updatedHeaders[index].readAt = now
    }
    var updatedLegacyArticles = legacyArticles
    for index in updatedLegacyArticles.indices where changedIDs.contains(updatedLegacyArticles[index].id) {
      updatedLegacyArticles[index].readAt = now
    }
    do {
      try database?.updateReadStates(
        previousStates.map { ($0.articleID, now) }
      )
      try persistLegacySnapshotIfNeeded(
        feeds: feeds,
        articles: updatedLegacyArticles,
        highlights: highlights
      )
      articleHeaders = updatedHeaders
      legacyArticles = updatedLegacyArticles
      for articleID in changedIDs {
        mutateCachedArticle(id: articleID) { $0.readAt = now }
      }
      lastBatchReadSnapshot = BatchReadSnapshot(states: previousStates)
      canUndoLastBatchRead = true
      lastError = nil
      bumpMutationRevision()
      statusMessage = "已标记当前列表中的 \(changedIDs.count) 篇文章为已读。"
      return changedIDs.count
    } catch {
      lastError = error.localizedDescription
      return 0
    }
  }

  @discardableResult
  public func undoLastBatchRead() -> Int {
    guard let snapshot = lastBatchReadSnapshot, !snapshot.states.isEmpty else { return 0 }
    let statesByID = Dictionary(
      snapshot.states.map { ($0.articleID, $0.readAt) },
      uniquingKeysWith: { first, _ in first }
    )
    var updatedHeaders = articleHeaders
    var updatedLegacyArticles = legacyArticles
    var restoredStates: [(articleID: String, readAt: Date?)] = []
    for index in updatedHeaders.indices {
      guard let wrappedReadAt = statesByID[updatedHeaders[index].id] else { continue }
      updatedHeaders[index].readAt = wrappedReadAt
      restoredStates.append((updatedHeaders[index].id, wrappedReadAt))
    }
    for index in updatedLegacyArticles.indices {
      guard let wrappedReadAt = statesByID[updatedLegacyArticles[index].id] else { continue }
      updatedLegacyArticles[index].readAt = wrappedReadAt
    }
    guard !restoredStates.isEmpty else {
      clearBatchReadUndo()
      return 0
    }
    do {
      try database?.updateReadStates(restoredStates)
      try persistLegacySnapshotIfNeeded(
        feeds: feeds,
        articles: updatedLegacyArticles,
        highlights: highlights
      )
      articleHeaders = updatedHeaders
      legacyArticles = updatedLegacyArticles
      for state in restoredStates {
        mutateCachedArticle(id: state.articleID) { $0.readAt = state.readAt }
      }
      clearBatchReadUndo()
      lastError = nil
      bumpMutationRevision()
      statusMessage = "已撤销批量已读，恢复 \(restoredStates.count) 篇文章的阅读状态。"
      return restoredStates.count
    } catch {
      lastError = error.localizedDescription
      return 0
    }
  }

  public func refreshAll(force: Bool = true) async {
    guard !feeds.isEmpty else {
      statusMessage = "还没有订阅，请先添加一个 RSS 或 Atom 地址。"
      return
    }
    await refreshFeeds(feeds, force: force, now: Date())
  }

  public func refreshFailedFeeds() async {
    let now = Date()
    let failedFeeds = feeds.filter { feed in
      switch feed.healthStatus(now: now) {
      case .failing, .backingOff:
        true
      case .never, .healthy:
        false
      }
    }
    guard !failedFeeds.isEmpty else {
      statusMessage = "没有需要重试的失败订阅。"
      return
    }
    await refreshFeeds(failedFeeds, force: true, now: Date())
  }

  public func refresh(feedID: UUID, force: Bool = true) async {
    guard let feed = feeds.first(where: { $0.id == feedID }) else { return }
    guard !refreshingFeedIDs.contains(feedID) else {
      lastRefreshSummary = RSSRefreshSummary(skippedCount: 1)
      statusMessage = "该订阅正在刷新。"
      return
    }
    await refreshFeeds([feed], force: force, now: Date())
  }

  public func refreshStaleFeeds(
    maxAge: TimeInterval = 30 * 60,
    now: Date = Date()
  ) async {
    // Let SwiftUI render the cached headers before an automatic refresh starts.
    // Entering RSS must remain useful even when several stale feeds need work.
    await Task.yield()
    guard !Task.isCancelled else { return }
    let threshold = max(0, maxAge)
    let staleFeeds = feeds.filter { feed in
      guard let lastUpdatedAt = feed.lastUpdatedAt else { return true }
      return now.timeIntervalSince(lastUpdatedAt) >= threshold
    }
    guard !staleFeeds.isEmpty else { return }
    await refreshFeeds(staleFeeds, force: false, now: now)
  }

  public func refreshStaleFeeds(
    staleAfter interval: TimeInterval,
    now: Date = Date()
  ) async {
    await refreshStaleFeeds(maxAge: interval, now: now)
  }

  public func startBackgroundRefresh(interval: TimeInterval = 30 * 60) {
    guard backgroundRefreshTimer == nil else { return }
    let normalizedInterval = max(60, interval)
    backgroundRefreshInterval = normalizedInterval
    runAutomaticMaintenanceIfNeeded()
    scheduleMediaArchiveForProtectedArticles()
    let timer = Timer(timeInterval: normalizedInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        await self.refreshStaleFeeds(maxAge: normalizedInterval)
        self.runAutomaticMaintenanceIfNeeded()
      }
    }
    backgroundRefreshTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    rescheduleRetryTimer()
  }

  public func stopBackgroundRefresh() {
    backgroundRefreshTimer?.invalidate()
    backgroundRefreshTimer = nil
    retryTimer?.invalidate()
    retryTimer = nil
    backgroundRefreshInterval = nil
  }

  func merge(_ parsedArticles: [RSSParsedArticle], into feed: RSSFeed) {
    do {
      let existingPayloads = try existingPayloads(for: parsedArticles, in: feed)
      let result = mergedContent(
        parsedArticles,
        into: feed,
        baseHeaders: articleHeaders,
        existingPayloads: existingPayloads,
        baseHighlights: highlights,
        now: Date()
      )
      try database?.upsertFeedAndArticles(feed, articles: result.articlesToUpsert)
      let updatedLegacyArticles = mergingLegacyArticles(
        legacyArticles,
        changedArticles: result.articlesToUpsert
      )
      try persistLegacySnapshotIfNeeded(
        feeds: feeds,
        articles: updatedLegacyArticles,
        highlights: result.highlights
      )
      articleHeaders = result.headers
      legacyArticles = updatedLegacyArticles
      highlights = result.highlights
      invalidatePayloads(for: result.articlesToUpsert.map(\.id))
      lastError = nil
      bumpMutationRevision()
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func refreshFeeds(_ targetFeeds: [RSSFeed], force: Bool, now: Date) async {
    lastRefreshSummary = nil
    statusMessage = nil
    lastError = nil
    let requests = targetFeeds.compactMap { feed -> RefreshRequest? in
      guard !refreshingFeedIDs.contains(feed.id),
            isEligibleForRefresh(feed, force: force, now: now) else { return nil }
      return RefreshRequest(
        feedID: feed.id,
        url: feed.url,
        etag: feed.etag,
        lastModified: feed.lastModified,
        startedAt: now
      )
    }
    let initiallySkippedCount = targetFeeds.count - requests.count
    let outcomes = await refreshRequests(requests)
    let successCount = outcomes.filter(\.succeeded).count
    let outcomeSkippedCount = outcomes.filter(\.skipped).count
    let failureCount = outcomes.filter { !$0.succeeded && !$0.skipped }.count
    let skippedCount = initiallySkippedCount + outcomeSkippedCount
    lastRefreshSummary = RSSRefreshSummary(
      successCount: successCount,
      failureCount: failureCount,
      skippedCount: skippedCount
    )
    statusMessage = lastRefreshSummary?.statusText
    if skippedCount > 0, !force {
      statusMessage = "\(statusMessage ?? "")；\(skippedCount) 个订阅尚未到刷新时间或需要处理。"
    }
    let errors = outcomes.compactMap(\.message).filter { !$0.isEmpty }
    lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    rescheduleRetryTimer()
  }

  private func isEligibleForRefresh(_ feed: RSSFeed, force: Bool, now: Date) -> Bool {
    guard !force else { return true }
    if let issue = feed.lastIssue {
      switch issue.retryStrategy {
      case .automatic:
        return feed.nextRetryAt == nil || feed.nextRetryAt! <= now
      case .afterDate:
        return (feed.nextRetryAt ?? issue.retryAt).map { $0 <= now } ?? true
      case .manual, .requiresAction, .none:
        return false
      }
    }
    return feed.nextRetryAt == nil || feed.nextRetryAt! <= now
  }

  private func refreshRequests(_ requests: [RefreshRequest]) async -> [RefreshOutcome] {
    guard !requests.isEmpty else { return [] }
    refreshingFeedIDs.formUnion(requests.map(\.feedID))
    isRefreshing = !refreshingFeedIDs.isEmpty
    defer {
      refreshingFeedIDs.subtract(requests.map(\.feedID))
      isRefreshing = !refreshingFeedIDs.isEmpty
    }

    let concurrencyLimit = min(Self.maximumRefreshConcurrency, requests.count)
    var outcomes: [RefreshOutcome] = []
    await withTaskGroup(of: RefreshFetchOutcome.self) { group in
      var nextIndex = 0
      func addNextRequest() {
        guard nextIndex < requests.count else { return }
        let request = requests[nextIndex]
        nextIndex += 1
        let fetchOperation = self.fetchOperation
        group.addTask {
          do {
            let result = try await fetchOperation(request.url, request.etag, request.lastModified)
            return RefreshFetchOutcome(request: request, result: result, issue: nil)
          } catch {
            return RefreshFetchOutcome(
              request: request,
              result: nil,
              issue: RSSFeedIssue.from(error: error)
            )
          }
        }
      }

      for _ in 0..<concurrencyLimit { addNextRequest() }
      while let fetchOutcome = await group.next() {
        outcomes.append(apply(fetchOutcome))
        addNextRequest()
      }
    }
    return outcomes
  }

  private func apply(_ fetchOutcome: RefreshFetchOutcome) -> RefreshOutcome {
    guard let fetchResult = fetchOutcome.result else {
      return failRefresh(
        feedID: fetchOutcome.request.feedID,
        startedAt: fetchOutcome.request.startedAt,
        issue: fetchOutcome.issue ?? RSSFeedIssue(
          stage: .transport,
          category: .unknown,
          retryStrategy: .automatic,
          userMessage: "订阅读取暂时失败，请稍后重试。"
        )
      )
    }
    guard let feedIndex = feeds.firstIndex(where: { $0.id == fetchOutcome.request.feedID }) else {
      return RefreshOutcome(succeeded: false, skipped: true, message: nil, issue: nil)
    }
    guard feeds[feedIndex].url == fetchOutcome.request.url else {
      return RefreshOutcome(succeeded: false, skipped: true, message: nil, issue: nil)
    }
    let completedAt = Date()
    var updatedFeed = feeds[feedIndex]
    updatedFeed.lastUpdatedAt = completedAt
    updatedFeed.lastRefreshAttemptAt = fetchOutcome.request.startedAt
    updatedFeed.lastRefreshDuration = max(
      0,
      completedAt.timeIntervalSince(fetchOutcome.request.startedAt)
    )
    updatedFeed.refreshFailureCount = 0
    updatedFeed.nextRetryAt = nil
    updatedFeed.etag = fetchResult.etag
    updatedFeed.lastModified = fetchResult.lastModified
    updatedFeed.lastError = nil
    updatedFeed.lastIssue = nil
    if let responseURL = fetchResult.responseURL, updatedFeed.siteURL == nil {
      updatedFeed.siteURL = responseURL
    }
    var updatedHeaders = articleHeaders
    var updatedLegacyArticles = legacyArticles
    var updatedHighlights = highlights
    var articlesToUpsert: [RSSArticle] = []
    do {
      if let parsedFeed = fetchResult.parsedFeed {
        updatedFeed.title = parsedFeed.title.nilIfEmpty ?? updatedFeed.displayTitle
        updatedFeed.siteURL = parsedFeed.siteURL ?? updatedFeed.siteURL
        updatedFeed.iconURL = parsedFeed.iconURL ?? updatedFeed.iconURL
        let existingPayloads = try existingPayloads(for: parsedFeed.articles, in: updatedFeed)
        let mergeResult = mergedContent(
          parsedFeed.articles,
          into: updatedFeed,
          baseHeaders: articleHeaders,
          existingPayloads: existingPayloads,
          baseHighlights: highlights,
          now: completedAt
        )
        updatedHeaders = mergeResult.headers
        updatedHighlights = mergeResult.highlights
        articlesToUpsert = mergeResult.articlesToUpsert
        updatedLegacyArticles = mergingLegacyArticles(
          legacyArticles,
          changedArticles: articlesToUpsert
        )
      }
      var updatedFeeds = feeds
      updatedFeeds[feedIndex] = updatedFeed
      if let database {
        if fetchResult.parsedFeed == nil {
          try database.upsertFeed(updatedFeed)
        } else {
          try database.upsertFeedAndArticles(
            updatedFeed,
            articles: articlesToUpsert
          )
        }
      }
      try persistLegacySnapshotIfNeeded(
        feeds: updatedFeeds,
        articles: updatedLegacyArticles,
        highlights: updatedHighlights
      )
      feeds = updatedFeeds
      articleHeaders = updatedHeaders
      legacyArticles = updatedLegacyArticles
      highlights = updatedHighlights
      invalidatePayloads(for: articlesToUpsert.map(\.id))
      lastError = nil
      bumpMutationRevision()
      return RefreshOutcome(succeeded: true, skipped: false, message: nil, issue: nil)
    } catch {
      return failRefresh(
        feedID: updatedFeed.id,
        startedAt: fetchOutcome.request.startedAt,
        issue: RSSReaderError.persistence(error.localizedDescription).asFeedIssue()
      )
    }
  }

  private func failRefresh(
    feedID: UUID,
    startedAt: Date,
    issue: RSSFeedIssue
  ) -> RefreshOutcome {
    if issue.category == .cancelled {
      return RefreshOutcome(succeeded: false, skipped: true, message: nil, issue: issue)
    }
    guard let feedIndex = feeds.firstIndex(where: { $0.id == feedID }) else {
      return RefreshOutcome(
        succeeded: false,
        skipped: false,
        message: issue.userMessage,
        issue: issue
      )
    }
    let completedAt = Date()
    var failedFeed = feeds[feedIndex]
    failedFeed.lastError = issue.userMessage
    failedFeed.lastIssue = issue
    failedFeed.lastRefreshAttemptAt = startedAt
    failedFeed.lastRefreshDuration = max(0, completedAt.timeIntervalSince(startedAt))
    failedFeed.refreshFailureCount += 1
    switch issue.retryStrategy {
    case .afterDate:
      failedFeed.nextRetryAt = issue.retryAt.map { max($0, completedAt) }
    case .automatic:
      let delay = min(
        6 * 60 * 60,
        60 * pow(2, Double(max(0, failedFeed.refreshFailureCount - 1)))
      )
      failedFeed.nextRetryAt = completedAt.addingTimeInterval(delay)
    case .manual, .requiresAction, .none:
      failedFeed.nextRetryAt = nil
    }
    var updatedFeeds = feeds
    updatedFeeds[feedIndex] = failedFeed
    do {
      try database?.updateFeedHealth(failedFeed)
      try persistLegacySnapshotIfNeeded(
        feeds: updatedFeeds,
        articles: legacyArticles,
        highlights: highlights
      )
    } catch {
      let persistenceIssue = RSSReaderError.persistence(error.localizedDescription).asFeedIssue()
      return RefreshOutcome(
        succeeded: false,
        skipped: false,
        message: "\(issue.userMessage)；同时无法保存错误状态：\(persistenceIssue.userMessage)",
        issue: persistenceIssue
      )
    }
    feeds = updatedFeeds
    bumpMutationRevision()
    return RefreshOutcome(
      succeeded: false,
      skipped: false,
      message: "\(failedFeed.displayTitle)：\(issue.userMessage)",
      issue: issue
    )
  }

  private func mergedContent(
    _ parsedArticles: [RSSParsedArticle],
    into feed: RSSFeed,
    baseHeaders: [RSSArticleHeader],
    existingPayloads: [String: RSSArticle],
    baseHighlights: [RSSArticleHighlight],
    now: Date
  ) -> MergeResult {
    let existingHeaders = baseHeaders.filter { $0.feedID == feed.id }
    var headersByID = Dictionary(
      existingHeaders.map { ($0.id, $0) },
      uniquingKeysWith: { newer, _ in newer }
    )
    var articlesToUpsertByID: [String: RSSArticle] = [:]
    for parsed in parsedArticles {
      let articleID = "\(feed.id.uuidString):\(parsed.id)"
      let existingHeader = headersByID[articleID]
      let incoming = RSSArticle(
        id: articleID,
        feedID: feed.id,
        title: parsed.title,
        link: parsed.link,
        author: parsed.author,
        publishedAt: parsed.publishedAt,
        summaryHTML: parsed.summaryHTML,
        contentHTML: parsed.contentHTML,
        fetchedAt: now,
        readAt: existingHeader?.readAt,
        isStarred: existingHeader?.isStarred ?? false,
        tags: existingHeader?.tags ?? []
      )
      guard existingPayloads[articleID]?.hasSameRemoteContent(as: incoming) != true else { continue }
      headersByID[articleID] = RSSArticleHeader(article: incoming)
      articlesToUpsertByID[articleID] = incoming
    }
    let merged = headersByID.values.sorted { lhs, rhs in
      let leftDate = lhs.publishedAt ?? lhs.fetchedAt
      let rightDate = rhs.publishedAt ?? rhs.fetchedAt
      if leftDate != rightDate { return leftDate > rightDate }
      return lhs.id < rhs.id
    }
    let articlesToUpsert = articlesToUpsertByID.values.sorted { lhs, rhs in
      let leftDate = lhs.publishedAt ?? lhs.fetchedAt
      let rightDate = rhs.publishedAt ?? rhs.fetchedAt
      if leftDate != rightDate { return leftDate > rightDate }
      return lhs.id < rhs.id
    }
    return MergeResult(
      headers: baseHeaders.filter { $0.feedID != feed.id } + merged,
      articlesToUpsert: articlesToUpsert,
      highlights: baseHighlights
    )
  }

  private func load() {
    if let database {
      do {
        if database.isEmpty, fileManager.fileExists(atPath: legacyURL.path) {
          let snapshot = try loadLegacySnapshot()
          feeds = snapshot.feeds
          articleHeaders = snapshot.articles.map(RSSArticleHeader.init(article:))
          legacyArticles = []
          highlights = snapshot.highlights
          mediaAssets = snapshot.mediaAssets
          try database.upsertFeeds(snapshot.feeds)
          try database.upsertArticles(snapshot.articles)
          for highlight in snapshot.highlights { try database.saveHighlight(highlight) }
          try database.upsertMediaAssets(snapshot.mediaAssets)
          statusMessage = "已将旧版 RSS 缓存迁移到 SQLite，原 JSON 已保留为备份。"
        } else {
          feeds = try database.feeds()
          articleHeaders = try database.articleHeaders()
          legacyArticles = []
          highlights = try database.highlights()
          mediaAssets = try database.mediaAssets()
        }
        if lastError == nil { lastError = nil }
        return
      } catch {
        self.database = nil
        self.payloadLoader = nil
        payloadCache.removeAll()
        for task in articleLoadTasks.values { task.cancel() }
        articleLoadTasks.removeAll()
        lastError = "RSS SQLite 缓存读取失败，将尝试兼容 JSON：\(error.localizedDescription)"
      }
    }
    loadLegacyFallback()
  }

  private func loadLegacyFallback() {
    guard fileManager.fileExists(atPath: legacyURL.path) else { return }
    do {
      let snapshot = try loadLegacySnapshot()
      feeds = snapshot.feeds
      legacyArticles = snapshot.articles
      articleHeaders = snapshot.articles.map(RSSArticleHeader.init(article:))
      highlights = snapshot.highlights
      mediaAssets = snapshot.mediaAssets
    } catch {
      lastError = "RSS 本地缓存读取失败：\(error.localizedDescription)"
    }
  }

  private func loadLegacySnapshot() throws -> RSSReaderSnapshot {
    let data = try Data(contentsOf: legacyURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(RSSReaderSnapshot.self, from: data)
    guard snapshot.schemaVersion <= RSSReaderSnapshot.currentSchemaVersion else {
      throw RSSReaderError.persistence("缓存版本 \(snapshot.schemaVersion) 高于当前支持版本")
    }
    return snapshot
  }

  private func existingPayloads(
    for parsedArticles: [RSSParsedArticle],
    in feed: RSSFeed
  ) throws -> [String: RSSArticle] {
    let articleIDs = Set(parsedArticles.map { "\(feed.id.uuidString):\($0.id)" })
    guard !articleIDs.isEmpty else { return [:] }
    let articles: [RSSArticle]
    if let database {
      articles = try database.articles(ids: articleIDs)
    } else {
      articles = legacyArticles.filter { articleIDs.contains($0.id) }
    }
    return Dictionary(
      articles.map { ($0.id, $0) },
      uniquingKeysWith: { newer, _ in newer }
    )
  }

  private func mergingLegacyArticles(
    _ baseArticles: [RSSArticle],
    changedArticles: [RSSArticle]
  ) -> [RSSArticle] {
    guard database == nil else { return [] }
    var articlesByID = Dictionary(
      baseArticles.map { ($0.id, $0) },
      uniquingKeysWith: { newer, _ in newer }
    )
    for article in changedArticles { articlesByID[article.id] = article }
    return articlesByID.values.sorted { lhs, rhs in
      let leftDate = lhs.publishedAt ?? lhs.fetchedAt
      let rightDate = rhs.publishedAt ?? rhs.fetchedAt
      if leftDate != rightDate { return leftDate > rightDate }
      return lhs.id < rhs.id
    }
  }

  private func invalidatePayloads<S: Sequence>(for articleIDs: S) where S.Element == String {
    let ids = Set(articleIDs)
    guard !ids.isEmpty else { return }
    payloadCache.remove(ids: ids)
    for articleID in ids {
      articleLoadTasks.removeValue(forKey: articleID)?.cancel()
    }
  }

  private func mutateLegacyAndCachedArticle(
    id: String,
    _ mutation: (inout RSSArticle) -> Void
  ) {
    if let index = legacyArticles.firstIndex(where: { $0.id == id }) {
      mutation(&legacyArticles[index])
    }
    mutateCachedArticle(id: id, mutation)
  }

  private func mutateCachedArticle(
    id: String,
    _ mutation: (inout RSSArticle) -> Void
  ) {
    guard var article = payloadCache.article(id: id) else { return }
    mutation(&article)
    payloadCache.insert(article)
  }

  private func loadFreshArticleAfterRevisionChange(id: String) async throws -> RSSArticle? {
    guard database != nil || payloadLoader != nil else { return nil }
    for _ in 0..<2 {
      guard let expectedHeader = articleHeader(id: id) else { return nil }
      let article = try await authoritativeArticle(id: id)
      guard var article else {
        return nil
      }
      guard let currentHeader = articleHeader(id: id) else { return nil }
      guard Self.persistedDatesMatch(currentHeader.fetchedAt, expectedHeader.fetchedAt) else {
        continue
      }
      guard Self.persistedDatesMatch(article.fetchedAt, currentHeader.fetchedAt) else {
        continue
      }
      article.apply(header: currentHeader)
      payloadCache.insert(article)
      return article
    }
    return nil
  }

  private func authoritativeArticle(id: String) async throws -> RSSArticle? {
    if let database {
      return try database.article(id: id)
    }
    return try await payloadLoader?.article(id: id)
  }

  private func scheduleMediaArchive(for articleID: String) {
    guard mediaArchiveArticleIDs.insert(articleID).inserted else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.mediaArchiveArticleIDs.remove(articleID) }
      let article: RSSArticle?
      do {
        article = try await self.loadArticle(id: articleID)
      } catch {
        self.lastError = "RSS 图片缓存读取失败：\(error.localizedDescription)"
        return
      }
      guard let article else { return }
      let result = await self.mediaArchiver.archive(article: article)
      guard !result.assets.isEmpty else {
        if !result.failedURLs.isEmpty {
          self.statusMessage = "已尝试缓存文章图片，但有 \(result.failedURLs.count) 张图片暂时不可用。"
        }
        return
      }
      do {
        try self.database?.upsertMediaAssets(result.assets)
        var assetsByID = Dictionary(
          self.mediaAssets.map { ($0.id, $0) },
          uniquingKeysWith: { existing, _ in existing }
        )
        for asset in result.assets { assetsByID[asset.id] = asset }
        self.mediaAssets = assetsByID.values.sorted {
          $0.archivedAt > $1.archivedAt
        }
        try self.persistLegacyIfNeeded()
        self.lastError = nil
        self.bumpMutationRevision()
        let failureSuffix = result.failedURLs.isEmpty
          ? ""
          : "，另有 \(result.failedURLs.count) 张暂时不可用"
        self.statusMessage = "已将 \(result.assets.count) 张图片保存到本机缓存\(failureSuffix)。"
      } catch {
        self.lastError = "RSS 图片缓存保存失败：\(error.localizedDescription)"
      }
    }
  }

  private func scheduleMediaArchiveForProtectedArticles() {
    let protectedIDs = Set(
      articleHeaders.filter { $0.isStarred }.map(\.id)
        + highlights.map(\.articleID)
    )
    for articleID in protectedIDs {
      scheduleMediaArchive(for: articleID)
    }
  }

  private func runAutomaticMaintenanceIfNeeded(now: Date = Date()) {
    guard automaticPruningEnabled else { return }
    if let lastRun = userDefaults.object(forKey: Self.lastPruneDateDefaultsKey) as? Date,
       now.timeIntervalSince(lastRun) < 24 * 60 * 60 {
      return
    }
    _ = pruneReadArticles(olderThanDays: retentionDays, now: now)
  }

  private func validateFeedURL(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), !url.absoluteString.isEmpty else {
      throw RSSReaderError.invalidFeedURL
    }
    guard scheme == "http" || scheme == "https" else {
      throw RSSReaderError.unsupportedFeedURL
    }
    guard let host = url.host,
          !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw RSSReaderError.invalidFeedURL
    }
    guard !RSSSubscriptionURLPrivacy.containsUserInfo(url) else {
      throw RSSReaderError.issue(
        RSSFeedIssue(
          stage: .validation,
          category: .invalidAddress,
          retryStrategy: .requiresAction,
          userMessage: "订阅地址不得包含 URL 用户名或密码。"
        )
      )
    }
  }

  private static func normalizedRetentionDays(_ value: Int) -> Int {
    min(3_650, max(1, value))
  }

  private func rescheduleRetryTimer() {
    retryTimer?.invalidate()
    retryTimer = nil
    guard backgroundRefreshInterval != nil,
          let scheduledAt = feeds.compactMap({ feed -> Date? in
            guard !refreshingFeedIDs.contains(feed.id),
                  feed.lastIssue?.shouldRetryAutomatically == true
            else { return nil }
            return feed.nextRetryAt ?? feed.lastIssue?.retryAt
          }).min()
    else { return }

    let timer = Timer(
      timeInterval: max(0.1, scheduledAt.timeIntervalSinceNow),
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.retryTimer = nil
        let now = Date()
        let dueFeeds = self.feeds.filter { feed in
          guard !self.refreshingFeedIDs.contains(feed.id),
                feed.lastIssue?.shouldRetryAutomatically == true,
                let retryAt = feed.nextRetryAt ?? feed.lastIssue?.retryAt
          else { return false }
          return retryAt <= now
        }
        guard !dueFeeds.isEmpty else {
          self.rescheduleRetryTimer()
          return
        }
        await self.refreshFeeds(dueFeeds, force: false, now: now)
      }
    }
    retryTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func persistLegacyIfNeeded() throws {
    try persistLegacySnapshotIfNeeded(
      feeds: feeds,
      articles: legacyArticles,
      highlights: highlights,
      mediaAssets: mediaAssets
    )
  }

  private func persistLegacySnapshotIfNeeded(
    feeds: [RSSFeed],
    articles: [RSSArticle],
    highlights: [RSSArticleHighlight],
    mediaAssets: [RSSMediaAsset]? = nil
  ) throws {
    guard database == nil else { return }
    try saveLegacy(
      RSSReaderSnapshot(
        feeds: feeds,
        articles: articles,
        highlights: highlights,
        mediaAssets: mediaAssets ?? self.mediaAssets
      )
    )
  }

  private func saveLegacy(_ snapshot: RSSReaderSnapshot) throws {
    do {
      try fileManager.createDirectory(
        at: legacyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(snapshot)
      try data.write(to: legacyURL, options: .atomic)
    } catch {
      throw RSSReaderError.persistence(error.localizedDescription)
    }
  }

  private func clearDeletionUndo() {
    lastDeletedFeedSnapshot = nil
    canUndoLastDeletion = false
  }

  private func clearBatchReadUndo() {
    lastBatchReadSnapshot = nil
    canUndoLastBatchRead = false
  }

  private func bumpMutationRevision() {
    mutationRevision &+= 1
  }
}

private extension RSSArticle {
  func hasSameRemoteContent(as other: RSSArticle) -> Bool {
    id == other.id
      && feedID == other.feedID
      && title == other.title
      && link == other.link
      && author == other.author
      && publishedAt == other.publishedAt
      && summaryHTML == other.summaryHTML
      && contentHTML == other.contentHTML
  }
}
