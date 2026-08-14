import Combine
import CryptoKit
import Foundation

extension RSSReaderStore {
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
    let normalizedInterval = max(60, interval)

    // Re-starting with a different interval is an explicit reconfiguration,
    // not a no-op. This is used by the app-wide RSS settings and also keeps
    // retry scheduling aligned with the currently selected cadence.
    if backgroundRefreshTimer != nil {
      guard backgroundRefreshInterval != normalizedInterval else { return }
      stopBackgroundRefresh()
    }

    backgroundRefreshInterval = normalizedInterval
    runAutomaticMaintenanceIfNeeded()
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

  /// Applies the persisted app-wide RSS automation policy to this store.
  /// Manual refresh APIs do not call this method and remain available while
  /// automatic refresh is disabled.
  public func configureBackgroundRefresh(enabled: Bool, interval: TimeInterval) {
    if enabled {
      startBackgroundRefresh(interval: interval)
    } else {
      stopBackgroundRefresh()
    }
  }

  /// Read-only diagnostics for settings/tests without exposing the timer
  /// implementation itself.
  public var configuredBackgroundRefreshInterval: TimeInterval? {
    backgroundRefreshInterval
  }

  public var isBackgroundRefreshRunning: Bool {
    backgroundRefreshTimer != nil
  }

  public func stopBackgroundRefresh() {
    backgroundRefreshTimer?.invalidate()
    backgroundRefreshTimer = nil
    retryTimer?.invalidate()
    retryTimer = nil
    backgroundRefreshInterval = nil
  }

  func merge(_ parsedArticles: [RSSParsedArticle], into feed: RSSFeed) {
    guard requireCompleteArticleIndex() else { return }
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

  func refreshFeeds(_ targetFeeds: [RSSFeed], force: Bool, now: Date) async {
    // Merge and collision resolution need the complete current ID/link index.
    // Finish a bounded bootstrap before touching the article hot path; the
    // initial window remains available to the UI while this utility read runs.
    await loadRemainingArticleHeadersIfNeeded()
    guard requireCompleteArticleIndex() else {
      lastRefreshSummary = RSSRefreshSummary(failureCount: targetFeeds.count)
      return
    }
    lastRefreshSummary = nil
    statusMessage = nil
    lastError = nil
    let requests = targetFeeds.compactMap { feed -> RefreshRequest? in
      guard !refreshingFeedIDs.contains(feed.id),
        isEligibleForRefresh(feed, force: force, now: now)
      else { return nil }
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

  func isEligibleForRefresh(_ feed: RSSFeed, force: Bool, now: Date) -> Bool {
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

  func refreshRequests(_ requests: [RefreshRequest]) async -> [RefreshOutcome] {
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

  func apply(_ fetchOutcome: RefreshFetchOutcome) -> RefreshOutcome {
    guard let fetchResult = fetchOutcome.result else {
      return failRefresh(
        feedID: fetchOutcome.request.feedID,
        startedAt: fetchOutcome.request.startedAt,
        issue: fetchOutcome.issue
          ?? RSSFeedIssue(
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
      if isOfflineCacheFullTextEnabled && !articlesToUpsert.isEmpty {
        let candidateIDs = articlesToUpsert.map(\.id)
        Task(priority: .utility) { [weak self] in
          await self?.prefetchFullTextForOfflineCache(articleIDs: candidateIDs)
        }
      }
      return RefreshOutcome(succeeded: true, skipped: false, message: nil, issue: nil)
    } catch {
      return failRefresh(
        feedID: updatedFeed.id,
        startedAt: fetchOutcome.request.startedAt,
        issue: RSSReaderError.persistence(error.localizedDescription).asFeedIssue()
      )
    }
  }

  func failRefresh(
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

  func mergedContent(
    _ parsedArticles: [RSSParsedArticle],
    into feed: RSSFeed,
    baseHeaders: [RSSArticleHeader],
    existingPayloads: [String: RSSArticle],
    baseHighlights: [RSSArticleHighlight],
    now: Date
  ) -> MergeResult {
    let existingHeaders = baseHeaders.filter { $0.feedID == feed.id }
    var existingCollisionIDsByLink: [String: String] = [:]
    var existingBaseLinkByBaseID: [String: String] = [:]
    existingCollisionIDsByLink.reserveCapacity(existingHeaders.count)
    existingBaseLinkByBaseID.reserveCapacity(existingHeaders.count)
    for header in existingHeaders {
      if header.id.hasPrefix("\(feed.id.uuidString):"),
        let link = header.link
      {
        let normalizedLink = normalizedArticleLink(link)
        if let marker = header.id.range(of: ":link-", options: .backwards) {
          let baseID = String(header.id[..<marker.lowerBound])
          existingCollisionIDsByLink["\(baseID)|\(normalizedLink)"] = header.id
        } else {
          existingBaseLinkByBaseID[header.id] = normalizedLink
        }
      }
    }
    var headersByID = Dictionary(
      existingHeaders.map { ($0.id, $0) },
      uniquingKeysWith: { newer, _ in newer }
    )
    let incomingLinksByParsedID = Dictionary(
      grouping: parsedArticles.compactMap { parsed -> (String, String)? in
        guard let link = parsed.link else { return nil }
        return (parsed.id, normalizedArticleLink(link))
      },
      by: \.0
    ).mapValues { values in
      Set(values.map(\.1))
    }
    let firstIncomingLinkByParsedID = Dictionary(
      parsedArticles.compactMap { parsed -> (String, String)? in
        guard let link = parsed.link else { return nil }
        return (parsed.id, normalizedArticleLink(link))
      },
      uniquingKeysWith: { first, _ in first }
    )
    var articlesToUpsertByID: [String: RSSArticle] = [:]
    for parsed in parsedArticles {
      let articleID = articleStorageID(
        feedID: feed.id,
        parsedID: parsed.id,
        link: parsed.link,
        existingHeaders: existingHeaders,
        incomingLinksByParsedID: incomingLinksByParsedID,
        firstIncomingLinkByParsedID: firstIncomingLinkByParsedID,
        existingCollisionIDsByLink: existingCollisionIDsByLink,
        existingBaseLinkByBaseID: existingBaseLinkByBaseID
      )
      let existingHeader = headersByID[articleID]
      let existingPayload = existingPayloads[articleID]
      let summaryHTML =
        feedBodyOfflineCacheEnabled
        ? parsed.summaryHTML
        : existingPayload?.summaryHTML ?? offlineSummaryHTML(for: parsed)
      let contentHTML =
        feedBodyOfflineCacheEnabled
        ? parsed.contentHTML
        : existingPayload?.contentHTML ?? ""
      let incoming = RSSArticle(
        id: articleID,
        feedID: feed.id,
        title: parsed.title,
        link: parsed.link,
        coverURL: parsed.coverURL ?? existingPayload?.coverURL,
        author: parsed.author,
        publishedAt: parsed.publishedAt,
        summaryHTML: summaryHTML,
        contentHTML: contentHTML,
        webPageSnapshotHTML: existingPayload?.webPageSnapshotHTML,
        fetchedAt: now,
        readAt: existingHeader?.readAt,
        isStarred: existingHeader?.isStarred ?? false,
        tags: existingHeader?.tags ?? []
      )
      guard existingPayload?.hasSameRemoteContent(as: incoming) != true else { continue }
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

  func offlineSummaryHTML(for parsed: RSSParsedArticle) -> String {
    let summary = parsed.summaryHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    guard summary.isEmpty else { return parsed.summaryHTML }
    let readableText = RSSHTMLTextSanitizer.plainText(from: parsed.contentHTML)
    return String(readableText.prefix(1_000))
  }
}
