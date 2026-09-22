import Combine
import Foundation

extension RSSReaderStore {
  @discardableResult
  func load() -> Bool {
    if let database {
      do {
        if try database.isEmpty, fileManager.fileExists(atPath: legacyURL.path) {
          let snapshot = try loadLegacySnapshot()
          try database.replaceSnapshot(snapshot)
          feeds = snapshot.feeds
          articleHeaders = snapshot.articles.map(RSSArticleHeader.init(article:))
          articleHeaderCount = articleHeaders.count
          articleHeadersAreComplete = true
          legacyArticles = []
          highlights = snapshot.highlights
          mediaAssets = snapshot.mediaAssets
          statusMessage = "已将旧版 RSS 缓存迁移到 SQLite，原 JSON 已保留为备份。"
        } else {
          feeds = try database.feeds()
          articleHeaders = try database.articleHeaders()
          articleHeaderCount = articleHeaders.count
          articleHeadersAreComplete = true
          legacyArticles = []
          highlights = try database.highlights()
          mediaAssets = try database.mediaAssets()
        }
        if lastError == nil { lastError = nil }
        return true
      } catch {
        self.database = nil
        self.payloadLoader = nil
        payloadCache.removeAll()
        for task in articleLoadTasks.values { task.cancel() }
        articleLoadTasks.removeAll()
        lastError = "RSS SQLite 缓存读取失败，将尝试兼容 JSON：\(error.localizedDescription)"
      }
    }
    return loadLegacyFallback()
  }

  func loadLegacyFallback() -> Bool {
    guard fileManager.fileExists(atPath: legacyURL.path) else { return false }
    do {
      let snapshot = try loadLegacySnapshot()
      feeds = snapshot.feeds
      legacyArticles = snapshot.articles
      articleHeaders = snapshot.articles.map(RSSArticleHeader.init(article:))
      articleHeaderCount = articleHeaders.count
      articleHeadersAreComplete = true
      highlights = snapshot.highlights
      mediaAssets = snapshot.mediaAssets
      return true
    } catch {
      lastError = "RSS 本地缓存读取失败：\(error.localizedDescription)"
      return false
    }
  }

  func loadLegacySnapshot() throws -> RSSReaderSnapshot {
    let data = try Data(contentsOf: legacyURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(RSSReaderSnapshot.self, from: data)
    guard snapshot.schemaVersion <= RSSReaderSnapshot.currentSchemaVersion else {
      throw RSSReaderError.persistence("缓存版本 \(snapshot.schemaVersion) 高于当前支持版本")
    }
    return snapshot
  }

  func existingPayloads(
    for parsedArticles: [RSSParsedArticle],
    in feed: RSSFeed
  ) throws -> [String: RSSArticle] {
    let articles: [RSSArticle]
    if let database {
      // A reused GUID can resolve to a link-specific collision ID. Loading
      // the current feed's payloads lets the merge preserve the correct
      // read/star/tag state for both the original and the collision record.
      articles = try database.articles(feedID: feed.id)
    } else {
      articles = legacyArticles.filter { $0.feedID == feed.id }
    }
    return Dictionary(
      articles.map { ($0.id, $0) },
      uniquingKeysWith: { newer, _ in newer }
    )
  }

  func mergingLegacyArticles(
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

  func invalidatePayloads<S: Sequence>(for articleIDs: S) where S.Element == String {
    let ids = Set(articleIDs)
    guard !ids.isEmpty else { return }
    payloadCache.remove(ids: ids)
    for articleID in ids {
      articleLoadTasks.removeValue(forKey: articleID)?.cancel()
    }
  }

  func mutateLegacyAndCachedArticle(
    id: String,
    _ mutation: (inout RSSArticle) -> Void
  ) {
    if let index = legacyArticles.firstIndex(where: { $0.id == id }) {
      mutation(&legacyArticles[index])
    }
    mutateCachedArticle(id: id, mutation)
  }

  func mutateCachedArticle(
    id: String,
    _ mutation: (inout RSSArticle) -> Void
  ) {
    guard var article = payloadCache.article(id: id) else { return }
    mutation(&article)
    payloadCache.insert(article)
  }

  func loadFreshArticleAfterRevisionChange(id: String) async throws -> RSSArticle? {
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

  func authoritativeArticle(id: String) async throws -> RSSArticle? {
    if let database {
      return try database.article(id: id)
    }
    return try await payloadLoader?.article(id: id)
  }

  func runAutomaticMaintenanceIfNeeded(now: Date = Date()) {
    guard automaticPruningEnabled else { return }
    if let lastRun = userDefaults.object(forKey: Self.lastPruneDateDefaultsKey) as? Date,
      now.timeIntervalSince(lastRun) < 24 * 60 * 60
    {
      return
    }
    _ = pruneReadArticles(olderThanDays: retentionDays, now: now)
  }

  func validateFeedURL(_ url: URL) throws {
    do {
      _ = try RSSNetworkURLPolicy.syntacticallyValidatedURL(
        url,
        allowsPrivateNetworkAccess: privateNetworkAccessEnabled
      )
    } catch let error as RSSReaderError {
      throw error
    } catch {
      throw RSSReaderError.invalidFeedURL
    }
  }

  static func normalizedRetentionDays(_ value: Int) -> Int {
    min(3_650, max(1, value))
  }

  func rescheduleRetryTimer() {
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

  func persistLegacyIfNeeded() throws {
    try persistLegacySnapshotIfNeeded(
      feeds: feeds,
      articles: legacyArticles,
      highlights: highlights,
      mediaAssets: mediaAssets
    )
  }

  func persistLegacySnapshotIfNeeded(
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

  func saveLegacy(_ snapshot: RSSReaderSnapshot) throws {
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

  func clearBatchReadUndo() {
    lastBatchReadSnapshot = nil
    canUndoLastBatchRead = false
  }

  /// Mutations that derive their target set from the in-memory headers must
  /// not run against a bounded bootstrap page. The launch coordinator waits
  /// for completion before exposing the UI; this guard also keeps direct
  /// callers fail-closed during the short bootstrap window.
  @discardableResult
  func requireCompleteArticleIndex() -> Bool {
    guard articleHeadersAreComplete else {
      statusMessage = "RSS 文章索引仍在加载，请稍后重试。"
      return false
    }
    return true
  }

  func bumpMutationRevision() {
    if articleHeadersAreComplete {
      articleHeaderCount = articleHeaders.count
    }
    mutationRevision &+= 1
  }

  public func maintainDatabase() async {
    guard let database else { return }
    await Task.detached(priority: .utility) {
      do {
        try database.checkpointWAL(mode: .passive)
        try database.optimizeDatabase()
      } catch {
        // Passive database maintenance is best-effort.
      }
    }.value
  }
}

extension RSSArticle {
  func hasSameRemoteContent(as other: RSSArticle) -> Bool {
    id == other.id
      && feedID == other.feedID
      && title == other.title
      && link == other.link
      && coverURL == other.coverURL
      && author == other.author
      && publishedAt == other.publishedAt
      && summaryHTML == other.summaryHTML
      && contentHTML == other.contentHTML
  }
}
