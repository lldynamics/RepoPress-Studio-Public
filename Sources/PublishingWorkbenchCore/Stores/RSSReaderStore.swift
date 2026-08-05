import Combine
import CryptoKit
import Foundation

actor RSSReaderNetworkAccessState {
  var value: Bool

  init(_ value: Bool) {
    self.value = value
  }

  func get() -> Bool {
    value
  }

  func set(_ value: Bool) {
    self.value = value
  }
}

public struct RSSReaderSnapshot: Codable, Sendable {
  public static let currentSchemaVersion = 5

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

  enum CodingKeys: String, CodingKey {
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

struct RSSArticlePayloadLRU {
  let capacity: Int
  var articlesByID: [String: RSSArticle] = [:]
  var idsByRecency: [String] = []

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

actor RSSArticlePayloadLoader {
  let databaseURL: URL
  var database: RSSReaderDatabase?

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

enum RSSArticleSearchSupport {
  static func articleHeaders(
    _ headers: [RSSArticleHeader],
    scope: RSSArticleScope,
    searchText: String,
    unreadOnly: Bool,
    database: RSSReaderDatabase?,
    legacyArticles: [RSSArticle]
  ) -> [RSSArticleHeader] {
    let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let searchIDs: Set<String>?
    do {
      searchIDs = try matchingArticleIDs(
        query: normalizedSearch,
        database: database,
        legacyArticles: legacyArticles
      )
    } catch is CancellationError {
      return []
    } catch {
      // Preserve the previous graceful fallback when an FTS query fails.
      searchIDs = nil
    }

    return headers
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

  static func matchingArticleIDs(
    query: String,
    database: RSSReaderDatabase?,
    legacyArticles: [RSSArticle]
  ) throws -> Set<String>? {
    guard !query.isEmpty else { return nil }
    if let database {
      return try database.matchingArticleIDs(query: query)
    }
    return Set(legacyArticles.lazy.filter { article in
      article.title.localizedCaseInsensitiveContains(query)
        || article.readableText.localizedCaseInsensitiveContains(query)
    }.map(\.id))
  }
}

@MainActor
public final class RSSReaderStore: ObservableObject {
  public static let retentionDaysDefaultsKey = "rssArticleRetentionDays"
  public static let automaticPruningDefaultsKey = "rssAutomaticPruningEnabled"
  public static let feedBodyOfflineCacheDefaultsKey = "rssFeedBodyOfflineCacheEnabled"
  /// Kept for migration from the old single offline-cache switch.
  public static let automaticOfflineCacheDefaultsKey = "rssAutomaticOfflineCacheEnabled"
  public static let privateNetworkAccessDefaultsKey = "rssPrivateNetworkAccessEnabled"
  public static let lastPruneDateDefaultsKey = "rssLastAutomaticPruneDate"
  public static let defaultRetentionDays = 60
  public static let defaultFeedBodyOfflineCacheEnabled = true
  @available(*, deprecated, message: "Use defaultFeedBodyOfflineCacheEnabled")
  public static let defaultAutomaticOfflineCacheEnabled = true
  public static let defaultPrivateNetworkAccessEnabled = false
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

  /// Legacy cache location retained so old backups and already archived
  /// media remain readable. New RSS refreshes never write to this directory.
  nonisolated public static func mediaCacheDirectoryURL(for fileURL: URL) -> URL {
    databaseFileURL(for: fileURL)
      .deletingLastPathComponent()
      .appendingPathComponent("RSSMedia", isDirectory: true)
  }

  @Published public internal(set) var feeds: [RSSFeed] = []
  @Published public internal(set) var articleHeaders: [RSSArticleHeader] = []
  @Published public internal(set) var highlights: [RSSArticleHighlight] = []
  /// Legacy media metadata loaded for backward-compatible rendering only.
  @Published internal var mediaAssets: [RSSMediaAsset] = []
  @Published public internal(set) var isRefreshing = false
  @Published public internal(set) var refreshingFeedIDs: Set<UUID> = []
  @Published public internal(set) var statusMessage: String?
  @Published public internal(set) var lastError: String?
  @Published public internal(set) var lastRefreshSummary: RSSRefreshSummary?
  @Published public internal(set) var mutationRevision: UInt64 = 0
  @Published public internal(set) var canUndoLastDeletion = false
  @Published public internal(set) var canUndoLastBatchRead = false
  @Published public internal(set) var retentionDays: Int
  @Published public internal(set) var automaticPruningEnabled: Bool
  @Published public internal(set) var feedBodyOfflineCacheEnabled: Bool
  @Published public internal(set) var privateNetworkAccessEnabled: Bool
  @Published public internal(set) var lastPruneSummary: RSSArticlePruneSummary?

  @available(*, deprecated, message: "Use feedBodyOfflineCacheEnabled")
  public var automaticOfflineCacheEnabled: Bool { feedBodyOfflineCacheEnabled }

  public let fileURL: URL

  public typealias FeedFetchOperation = @Sendable (
    _ feedURL: URL,
    _ etag: String?,
    _ lastModified: String?
  ) async throws -> RSSFeedFetchResult

  let fetchOperation: FeedFetchOperation
  let fileManager: FileManager
  let userDefaults: UserDefaults
  let networkAccessState: RSSReaderNetworkAccessState
  let databaseURL: URL
  let legacyURL: URL
  var database: RSSReaderDatabase?
  var payloadLoader: RSSArticlePayloadLoader?
  var payloadCache = RSSArticlePayloadLRU(capacity: 16)
  var articleLoadTasks: [String: Task<RSSArticle?, Error>] = [:]
  var legacyArticles: [RSSArticle] = []
  var deletedFeedSnapshots: [DeletedFeedSnapshot] = []
  var lastBatchReadSnapshot: BatchReadSnapshot?
  var backgroundRefreshTimer: Timer?
  var retryTimer: Timer?
  var backgroundRefreshInterval: TimeInterval?

  struct DeletedFeedSnapshot {
    var feed: RSSFeed
    var articles: [RSSArticle]
    var highlights: [RSSArticleHighlight]
    var mediaAssets: [RSSMediaAsset]
  }

  static let maximumDeletionUndoSnapshots = 8

  struct RefreshRequest: Sendable {
    var feedID: UUID
    var url: URL
    var etag: String?
    var lastModified: String?
    var startedAt: Date
  }

  struct RefreshFetchOutcome: Sendable {
    var request: RefreshRequest
    var result: RSSFeedFetchResult?
    var issue: RSSFeedIssue?
  }

  struct RefreshOutcome: Sendable {
    var succeeded: Bool
    var skipped: Bool
    var message: String?
    var issue: RSSFeedIssue?
  }

  struct BatchReadState {
    var articleID: String
    var readAt: Date?
  }

  struct BatchReadSnapshot {
    var states: [BatchReadState]
  }

  struct MergeResult {
    var headers: [RSSArticleHeader]
    var articlesToUpsert: [RSSArticle]
    var highlights: [RSSArticleHighlight]
  }

  static let articlePayloadCacheCapacity = 16
  static let persistedDateComparisonTolerance: TimeInterval = 0.000001

  static func persistedDatesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
    abs(lhs.timeIntervalSince(rhs)) <= persistedDateComparisonTolerance
  }

  public init(
    fileURL: URL? = nil,
    client: RSSFeedClient = RSSFeedClient(),
    fileManager: FileManager = .default,
    fetchOperation: FeedFetchOperation? = nil,
    userDefaults: UserDefaults = .standard
  ) {
    let requestedFileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    self.fileURL = requestedFileURL
    let resolvedPrivateNetworkAccessEnabled = userDefaults.object(
      forKey: Self.privateNetworkAccessDefaultsKey
    ) as? Bool ?? client.allowsPrivateNetworkAccess
    let networkAccessState = RSSReaderNetworkAccessState(resolvedPrivateNetworkAccessEnabled)
    self.networkAccessState = networkAccessState
    self.fetchOperation = fetchOperation ?? { feedURL, etag, lastModified in
      return try await client.fetch(
        feedURL: feedURL,
        etag: etag,
        lastModified: lastModified,
        allowsPrivateNetworkAccess: await networkAccessState.get()
      )
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
    self.feedBodyOfflineCacheEnabled = userDefaults.object(
      forKey: Self.feedBodyOfflineCacheDefaultsKey
    ) as? Bool
      ?? userDefaults.object(forKey: Self.automaticOfflineCacheDefaultsKey) as? Bool
      ?? Self.defaultFeedBodyOfflineCacheEnabled
    self.privateNetworkAccessEnabled = resolvedPrivateNetworkAccessEnabled

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

  public func updateRetentionSettings(enabled: Bool, days: Int) {
    automaticPruningEnabled = enabled
    retentionDays = Self.normalizedRetentionDays(days)
    userDefaults.set(automaticPruningEnabled, forKey: Self.automaticPruningDefaultsKey)
    userDefaults.set(retentionDays, forKey: Self.retentionDaysDefaultsKey)
    if enabled {
      _ = pruneReadArticles(olderThanDays: retentionDays)
    }
  }

  public func updateFeedBodyOfflineCacheSettings(enabled: Bool) {
    feedBodyOfflineCacheEnabled = enabled
    userDefaults.set(enabled, forKey: Self.feedBodyOfflineCacheDefaultsKey)
    userDefaults.set(enabled, forKey: Self.automaticOfflineCacheDefaultsKey)
  }

  @available(*, deprecated, message: "Use updateFeedBodyOfflineCacheSettings(enabled:)")
  public func updateAutomaticOfflineCacheSettings(enabled: Bool) {
    updateFeedBodyOfflineCacheSettings(enabled: enabled)
  }

  public func updatePrivateNetworkAccessSettings(enabled: Bool) {
    privateNetworkAccessEnabled = enabled
    Task { await networkAccessState.set(enabled) }
    userDefaults.set(enabled, forKey: Self.privateNetworkAccessDefaultsKey)
  }

  @discardableResult
  public func pruneReadArticles(
    olderThanDays days: Int? = nil,
    now: Date = Date()
  ) -> RSSArticlePruneSummary {
    let normalizedDays = Self.normalizedRetentionDays(days ?? retentionDays)
    let cutoff = now.addingTimeInterval(-TimeInterval(normalizedDays) * 86_400)
    lastError = nil
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
    let nextHeaders = articleHeaders.filter { !candidateIDs.contains($0.id) }
    let nextLegacyArticles = legacyArticles.filter { !candidateIDs.contains($0.id) }
    let nextHighlights = highlights.filter { !candidateIDs.contains($0.articleID) }
    let nextMediaAssets = mediaAssets.filter { !candidateIDs.contains($0.articleID) }
    do {
      if let database {
        try database.deleteArticles(ids: candidateIDs)
      } else {
        try persistLegacySnapshotIfNeeded(
          feeds: feeds,
          articles: nextLegacyArticles,
          highlights: nextHighlights,
          mediaAssets: nextMediaAssets
        )
      }
      articleHeaders = nextHeaders
      legacyArticles = nextLegacyArticles
      highlights = nextHighlights
      mediaAssets = nextMediaAssets
      payloadCache.remove(ids: candidateIDs)
      for articleID in candidateIDs {
        articleLoadTasks[articleID]?.cancel()
        articleLoadTasks[articleID] = nil
      }
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
      return summary
    } catch {
      lastError = "RSS 历史清理失败：\(error.localizedDescription)"
      let summary = RSSArticlePruneSummary(cutoffDate: cutoff)
      lastPruneSummary = summary
      return summary
    }
  }

  /// Synchronous compatibility API for non-interactive callers. RSS list
  /// preparation uses `articleHeadersAsync` so FTS never blocks the main actor.
  public func articleHeaders(
    for scope: RSSArticleScope,
    searchText: String = "",
    unreadOnly: Bool = false
  ) -> [RSSArticleHeader] {
    RSSArticleSearchSupport.articleHeaders(
      articleHeaders,
      scope: scope,
      searchText: searchText,
      unreadOnly: unreadOnly,
      database: database,
      legacyArticles: legacyArticles
    )
  }

  /// Performs the RSS FTS query and list filtering away from the main actor.
  /// The store remains the source of truth; this method snapshots its
  /// value-semantic inputs before the detached read begins.
  public func articleHeadersAsync(
    for scope: RSSArticleScope,
    searchText: String = "",
    unreadOnly: Bool = false
  ) async -> [RSSArticleHeader] {
    let headers = articleHeaders
    let database = self.database
    let legacyArticles = database == nil ? self.legacyArticles : []
    let task = Task.detached(priority: .userInitiated) {
      RSSArticleSearchSupport.articleHeaders(
        headers,
        scope: scope,
        searchText: searchText,
        unreadOnly: unreadOnly,
        database: database,
        legacyArticles: legacyArticles
      )
    }

    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
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

}
