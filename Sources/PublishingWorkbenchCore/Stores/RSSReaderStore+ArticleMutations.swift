import Combine
import CryptoKit
import Foundation

extension RSSReaderStore {
  @discardableResult
  public func addFeed(
    url: URL,
    title: String? = nil,
    siteURL: URL? = nil
  ) throws -> UUID {
    try validateFeedURL(url)

    if let existing = feeds.first(where: { $0.url.absoluteString == url.absoluteString }) {
      return existing.id
    }

    let feed = RSSFeed(
      title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? url.host
        ?? url.absoluteString,
      url: url,
      siteURL: siteURL
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
    if feeds.contains(where: { $0.id != feedID && $0.url.absoluteString == newURL.absoluteString })
    {
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

  public func removeFeed(id: UUID) {
    guard requireCompleteArticleIndex() else { return }
    guard let feed = feeds.first(where: { $0.id == id }) else { return }
    let deletedArticles: [RSSArticle]
    let deletedFullTextRecords: [RSSArticleFullTextRecord]
    do {
      if let database {
        deletedArticles = try database.articles(feedID: id)
        deletedFullTextRecords = try database.fullTextRecords(feedID: id)
      } else {
        deletedArticles = legacyArticles.filter { $0.feedID == id }
        deletedFullTextRecords = []
      }
    } catch {
      lastError = error.localizedDescription
      return
    }
    let deletedArticleIDs = Set(deletedArticles.map(\.id))
    let deletedHighlights = highlights.filter { deletedArticleIDs.contains($0.articleID) }
    let deletedMediaAssets = mediaAssets.filter { deletedArticleIDs.contains($0.articleID) }
    let nextFeeds = feeds.filter { $0.id != id }
    let nextHeaders = articleHeaders.filter { $0.feedID != id }
    let nextLegacyArticles = legacyArticles.filter { $0.feedID != id }
    let nextHighlights = highlights.filter { !deletedArticleIDs.contains($0.articleID) }
    let nextMediaAssets = mediaAssets.filter { !deletedArticleIDs.contains($0.articleID) }
    do {
      if let database {
        try database.deleteFeed(id: id)
      } else {
        try persistLegacySnapshotIfNeeded(
          feeds: nextFeeds,
          articles: nextLegacyArticles,
          highlights: nextHighlights,
          mediaAssets: nextMediaAssets
        )
      }
      feeds = nextFeeds
      articleHeaders = nextHeaders
      legacyArticles = nextLegacyArticles
      highlights = nextHighlights
      mediaAssets = nextMediaAssets
      payloadCache.remove(ids: deletedArticleIDs)
      for articleID in deletedArticleIDs {
        articleLoadTasks.removeValue(forKey: articleID)?.cancel()
      }
      let snapshot = DeletedFeedSnapshot(
        feed: feed,
        articles: deletedArticles,
        highlights: deletedHighlights,
        mediaAssets: deletedMediaAssets,
        fullTextRecords: deletedFullTextRecords
      )
      deletedFeedSnapshots.append(snapshot)
      if deletedFeedSnapshots.count > Self.maximumDeletionUndoSnapshots {
        _ = deletedFeedSnapshots.removeFirst()
      }
      canUndoLastDeletion = !deletedFeedSnapshots.isEmpty
      lastRefreshSummary = nil
      bumpMutationRevision()
      statusMessage = "已删除“\(feed.displayTitle)”及 \(deletedArticles.count) 篇本地缓存，可立即撤销。"
      rescheduleRetryTimer()
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func undoLastDeletion() {
    guard requireCompleteArticleIndex() else { return }
    guard let snapshot = deletedFeedSnapshots.popLast() else { return }
    guard !feeds.contains(where: { $0.id == snapshot.feed.id }) else {
      canUndoLastDeletion = !deletedFeedSnapshots.isEmpty
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
        mediaAssets: snapshot.mediaAssets,
        fullTextRecords: snapshot.fullTextRecords
      )
      mediaAssets.append(contentsOf: snapshot.mediaAssets)
      try persistLegacyIfNeeded()
      canUndoLastDeletion = !deletedFeedSnapshots.isEmpty
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
      deletedFeedSnapshots.append(snapshot)
      canUndoLastDeletion = true
      lastError = error.localizedDescription
    }
  }

  public func markRead(_ articleID: String, isRead: Bool = true) {
    guard requireCompleteArticleIndex() else { return }
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
    guard requireCompleteArticleIndex() else { return }
    guard let index = articleHeaders.firstIndex(where: { $0.id == articleID }) else { return }
    let nextValue = !articleHeaders[index].isStarred
    articleHeaders[index].isStarred = nextValue
    mutateLegacyAndCachedArticle(id: articleID) { $0.isStarred = nextValue }
    do {
      try database?.updateStarred(articleID: articleID, isStarred: nextValue)
      try persistLegacyIfNeeded()
      lastError = nil
      bumpMutationRevision()
    } catch {
      articleHeaders[index].isStarred.toggle()
      mutateLegacyAndCachedArticle(id: articleID) { $0.isStarred.toggle() }
      lastError = error.localizedDescription
    }
  }

  public func setArticleTags(_ tags: [String], for articleID: String) {
    guard requireCompleteArticleIndex() else { return }
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
    guard requireCompleteArticleIndex() else {
      throw RSSReaderError.persistence("RSS 文章索引仍在加载，请稍后重试。")
    }
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
        guard
          let article = payloadCache.article(id: articleID)
            ?? legacyArticles.first(where: { $0.id == articleID })
        else {
          throw RSSReaderError.persistence("文章正文尚未写入本地数据库。")
        }
        try database.upsertArticles([article])
      }
      try database?.saveHighlight(highlight)
      try persistLegacyIfNeeded()
      lastError = nil
      bumpMutationRevision()
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
    guard requireCompleteArticleIndex() else { return }
    let ids = Set(articleHeaders(for: scope).map(\.id))
    markAllRead(articleIDs: ids)
  }

  @discardableResult
  public func markAllRead(articleIDs: Set<String>) -> Int {
    guard requireCompleteArticleIndex() else { return 0 }
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
    for index in updatedLegacyArticles.indices
    where changedIDs.contains(updatedLegacyArticles[index].id) {
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
    guard requireCompleteArticleIndex() else { return 0 }
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

  public func updateArticlePayload(_ updatedArticle: RSSArticle) throws {
    if let feed = feeds.first(where: { $0.id == updatedArticle.feedID }) {
      try database?.upsertFeedAndArticles(feed, articles: [updatedArticle])
    }
    mutateCachedArticle(id: updatedArticle.id) { cached in
      cached.contentHTML = updatedArticle.contentHTML
      cached.webPageSnapshotHTML = updatedArticle.webPageSnapshotHTML
      if !updatedArticle.summaryHTML.isEmpty {
        cached.summaryHTML = updatedArticle.summaryHTML
      }
      if !updatedArticle.title.isEmpty {
        cached.title = updatedArticle.title
      }
    }
    bumpMutationRevision()
  }

  /// Returns the original-page extraction without mutating the feed payload.
  public func fullTextRecord(articleID: String) throws -> RSSArticleFullTextRecord? {
    try database?.fullTextRecord(articleID: articleID)
  }

  public func saveFullTextRecord(_ record: RSSArticleFullTextRecord) throws {
    guard let database else {
      throw RSSReaderError.persistence("全文缓存需要可用的 SQLite 数据库。")
    }
    try database.upsertFullTextRecord(record)
    bumpMutationRevision()
  }

  /// Persists and reindexes a potentially large extracted page away from the
  /// main actor, then publishes the lightweight store revision update.
  public func saveFullTextRecordAsync(_ record: RSSArticleFullTextRecord) async throws {
    guard let database else {
      throw RSSReaderError.persistence("全文缓存需要可用的 SQLite 数据库。")
    }
    let task = Task.detached(priority: .utility) {
      try database.upsertFullTextRecord(record)
    }
    try await task.value
    bumpMutationRevision()
  }

  public func deleteFullTextRecord(articleID: String) throws {
    try database?.deleteFullTextRecord(articleID: articleID)
    bumpMutationRevision()
  }

  @discardableResult
  public func prefetchFullTextForOfflineCache(articleIDs: [String]) async -> Int {
    let service = RSSArticleFullTextService()
    let broker = RSSArticleFullTextRequestBroker.shared
    let now = Date()
    var candidates: [(RSSArticle, RSSArticleFullTextRecord?)] = []
    for articleID in articleIDs {
      do {
        guard let article = try await loadArticle(id: articleID) else { continue }
        guard service.isTruncatedCandidate(article) else { continue }
        let storedRecord = try fullTextRecord(articleID: articleID)
        let cachedRecord: RSSArticleFullTextRecord? = storedRecord.flatMap { record in
          guard record.articleID == article.id,
                record.sourceURL?.absoluteString == article.link?.absoluteString else {
            return nil
          }
          return record
        }
        if cachedRecord?.status == .ready { continue }
        if let retryAfter = cachedRecord?.retryAfter, retryAfter > now { continue }
        candidates.append((article, cachedRecord))
      } catch {
        continue
      }
    }

    let allowsPrivateNetworkAccess = privateNetworkAccessEnabled
    let extractionOperation: @Sendable (
      RSSArticle,
      RSSArticleFullTextRecord?
    ) async -> RSSArticleFullTextRecord = { article, cachedRecord in
      do {
        return try await broker.fetch(
          article: article,
          cachedRecord: cachedRecord,
          allowsPrivateNetworkAccess: allowsPrivateNetworkAccess,
          service: service
        )
      } catch {
        return service.failureRecord(
          for: article,
          cachedRecord: cachedRecord,
          error: error
        )
      }
    }
    return await withTaskGroup(of: RSSArticleFullTextRecord.self) { group in
      var nextCandidateIndex = 0
      for _ in 0..<min(2, candidates.count) {
        let (article, cachedRecord) = candidates[nextCandidateIndex]
        nextCandidateIndex += 1
        group.addTask {
          await extractionOperation(article, cachedRecord)
        }
      }

      var successfulCount = 0
      while let record = await group.next() {
        do {
          try await saveFullTextRecordAsync(record)
          if record.status == .ready { successfulCount += 1 }
        } catch {
          // Keep draining the bounded queue even if one persistence fails.
        }
        if nextCandidateIndex < candidates.count {
          let (article, cachedRecord) = candidates[nextCandidateIndex]
          nextCandidateIndex += 1
          group.addTask {
            await extractionOperation(article, cachedRecord)
          }
        }
      }
      return successfulCount
    }
  }
}
