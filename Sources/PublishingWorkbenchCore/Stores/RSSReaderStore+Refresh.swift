import Combine
import CryptoKit
import Foundation

/// The value-only result produced by a refresh merge.  Keeping this outside
/// `RSSReaderStore` makes it safe to build on a detached task before the
/// main-actor observable state is touched.
struct RSSRefreshMergeResult: Sendable {
  let headers: [RSSArticleHeader]
  let articlesToUpsert: [RSSArticle]
  let highlights: [RSSArticleHighlight]
}

struct RSSRefreshWorkerResult: Sendable {
  let request: RSSReaderStore.RefreshRequest
  let updatedFeed: RSSFeed
  let mergeResult: RSSRefreshMergeResult?
  let succeeded: Bool
  let skipped: Bool
  let issue: RSSFeedIssue?
  let persistenceError: String?
  let persisted: Bool
  let didExecuteOffMainActor: Bool
}

/// Foundation marks `Thread.isMainThread` unavailable when referenced
/// directly from an async context. Keep the synchronous probe in this small
/// helper so the regression signal remains available without actor hopping.
private func rssRefreshIsMainThread() -> Bool {
  Thread.isMainThread
}

/// Pure refresh planning shared by the synchronous compatibility path and
/// the detached refresh worker.  It deliberately receives all state as value
/// inputs so no `@MainActor` store or ObservableObject can leak into the
/// background phase.
enum RSSRefreshMergeSupport {
  static func mergedContent(
    _ parsedArticles: [RSSParsedArticle],
    into feed: RSSFeed,
    baseHeaders: [RSSArticleHeader],
    existingPayloads: [String: RSSArticle],
    baseHighlights: [RSSArticleHighlight],
    feedBodyOfflineCacheEnabled: Bool,
    now: Date
  ) -> RSSRefreshMergeResult {
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
    return RSSRefreshMergeResult(
      headers: baseHeaders.filter { $0.feedID != feed.id } + merged,
      articlesToUpsert: articlesToUpsert,
      highlights: baseHighlights
    )
  }

  static func articleStorageID(
    feedID: UUID,
    parsedID: String,
    link: URL?,
    incomingLinksByParsedID: [String: Set<String>],
    firstIncomingLinkByParsedID: [String: String],
    existingCollisionIDsByLink: [String: String],
    existingBaseLinkByBaseID: [String: String]
  ) -> String {
    let baseID = "\(feedID.uuidString):\(parsedID)"
    guard let link else { return baseID }
    let normalizedLink = normalizedArticleLink(link)
    if let existingCollision = existingCollisionIDsByLink["\(baseID)|\(normalizedLink)"] {
      return existingCollision
    }

    let incomingLinks = incomingLinksByParsedID[parsedID] ?? []
    guard incomingLinks.count > 1 else {
      // A single item whose URL moved is treated as a normal publisher update.
      // A collision is only provable when the same feed snapshot contains
      // multiple different URLs for the same GUID.
      return baseID
    }

    let existingBaseLink = existingBaseLinkByBaseID[baseID]
    if existingBaseLink == normalizedLink
      || (existingBaseLink == nil && firstIncomingLinkByParsedID[parsedID] == normalizedLink)
    {
      return baseID
    }
    return collisionArticleID(baseID: baseID, normalizedLink: normalizedLink)
  }

  static func normalizedArticleLink(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    return components?.url?.absoluteString ?? url.absoluteString
  }

  static func collisionArticleID(baseID: String, normalizedLink: String) -> String {
    let digest = SHA256.hash(data: Data(normalizedLink.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(baseID):link-\(String(digest.prefix(24)))"
  }

  static func offlineSummaryHTML(for parsed: RSSParsedArticle) -> String {
    let summary = parsed.summaryHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    guard summary.isEmpty else { return parsed.summaryHTML }
    let readableText = RSSHTMLTextSanitizer.plainText(from: parsed.contentHTML)
    return String(readableText.prefix(1_000))
  }
}

/// Performs payload reads, merge planning, and SQLite writes away from the
/// main actor.  The conditional database methods prevent a removed or
/// URL-changed feed from being resurrected by an old network response.
enum RSSRefreshWorker {
  static func run(
    request: RSSReaderStore.RefreshRequest,
    feed: RSSFeed,
    fetchOutcome: RSSReaderStore.RefreshFetchOutcome,
    baseHeaders: [RSSArticleHeader],
    baseHighlights: [RSSArticleHighlight],
    legacyArticles: [RSSArticle],
    feedBodyOfflineCacheEnabled: Bool,
    database: RSSReaderDatabase?,
    beforePersistenceHook: (@Sendable () async -> Void)?
  ) async -> RSSRefreshWorkerResult {
    let didExecuteOffMainActor = !rssRefreshIsMainThread()
    guard !Task.isCancelled else {
      return cancelledResult(
        request: request,
        feed: feed,
        didExecuteOffMainActor: didExecuteOffMainActor
      )
    }
    guard let fetchResult = fetchOutcome.result else {
      let issue = fetchOutcome.issue
        ?? RSSFeedIssue(
          stage: .transport,
          category: .unknown,
          retryStrategy: .automatic,
          userMessage: "订阅读取暂时失败，请稍后重试。"
        )
      if issue.category == .cancelled {
        return RSSRefreshWorkerResult(
          request: request,
          updatedFeed: feed,
          mergeResult: nil,
          succeeded: false,
          skipped: true,
          issue: issue,
          persistenceError: nil,
          persisted: true,
          didExecuteOffMainActor: didExecuteOffMainActor
        )
      }
      let failedFeed = failedFeed(feed, startedAt: request.startedAt, issue: issue)
      if let database {
        do {
          let persisted = try database.updateFeedHealthIfURLMatches(
            failedFeed,
            expectedURL: request.url
          )
          return RSSRefreshWorkerResult(
            request: request,
            updatedFeed: failedFeed,
            mergeResult: nil,
            succeeded: false,
            skipped: !persisted,
            issue: issue,
            persistenceError: nil,
            persisted: persisted,
            didExecuteOffMainActor: didExecuteOffMainActor
          )
        } catch {
          return RSSRefreshWorkerResult(
            request: request,
            updatedFeed: failedFeed,
            mergeResult: nil,
            succeeded: false,
            skipped: false,
            issue: issue,
            persistenceError: error.localizedDescription,
            persisted: false,
            didExecuteOffMainActor: didExecuteOffMainActor
          )
        }
      }
      return RSSRefreshWorkerResult(
        request: request,
        updatedFeed: failedFeed,
        mergeResult: nil,
        succeeded: false,
        skipped: false,
        issue: issue,
        persistenceError: nil,
        persisted: true,
        didExecuteOffMainActor: didExecuteOffMainActor
      )
    }

    guard !Task.isCancelled else {
      return cancelledResult(
        request: request,
        feed: feed,
        didExecuteOffMainActor: didExecuteOffMainActor
      )
    }
    let completedAt = Date()
    var updatedFeed = feed
    updatedFeed.lastUpdatedAt = completedAt
    updatedFeed.lastRefreshAttemptAt = request.startedAt
    updatedFeed.lastRefreshDuration = max(
      0,
      completedAt.timeIntervalSince(request.startedAt)
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

    var mergeResult: RSSRefreshMergeResult?
    do {
      if let parsedFeed = fetchResult.parsedFeed {
        updatedFeed.title = parsedFeed.title.nilIfEmpty ?? updatedFeed.displayTitle
        updatedFeed.siteURL = parsedFeed.siteURL ?? updatedFeed.siteURL
        updatedFeed.iconURL = parsedFeed.iconURL ?? updatedFeed.iconURL
        guard !Task.isCancelled else {
          return cancelledResult(
            request: request,
            feed: feed,
            didExecuteOffMainActor: didExecuteOffMainActor
          )
        }
        let existingPayloads: [String: RSSArticle]
        if let database {
          existingPayloads = Dictionary(
            try database.articles(feedID: updatedFeed.id).map { ($0.id, $0) },
            uniquingKeysWith: { newer, _ in newer }
          )
        } else {
          existingPayloads = Dictionary(
            legacyArticles.filter { $0.feedID == updatedFeed.id }.map { ($0.id, $0) },
            uniquingKeysWith: { newer, _ in newer }
          )
        }
        guard !Task.isCancelled else {
          return cancelledResult(
            request: request,
            feed: feed,
            didExecuteOffMainActor: didExecuteOffMainActor
          )
        }
        mergeResult = RSSRefreshMergeSupport.mergedContent(
          parsedFeed.articles,
          into: updatedFeed,
          baseHeaders: baseHeaders,
          existingPayloads: existingPayloads,
          baseHighlights: baseHighlights,
          feedBodyOfflineCacheEnabled: feedBodyOfflineCacheEnabled,
          now: completedAt
        )
      }

      if let beforePersistenceHook {
        await beforePersistenceHook()
      }
      guard !Task.isCancelled else {
        return cancelledResult(
          request: request,
          feed: feed,
          didExecuteOffMainActor: didExecuteOffMainActor
        )
      }
      if let database {
        guard let persistedArticles = try database.upsertFeedAndArticlesIfURLMatches(
          updatedFeed,
          articles: mergeResult?.articlesToUpsert ?? [],
          expectedURL: request.url
        ) else {
          return RSSRefreshWorkerResult(
            request: request,
            updatedFeed: updatedFeed,
            mergeResult: mergeResult,
            succeeded: false,
            skipped: true,
            issue: nil,
            persistenceError: nil,
            persisted: false,
            didExecuteOffMainActor: didExecuteOffMainActor
          )
        }
        let persistedMergeResult = mergeResult.map { result in
          let persistedByID = Dictionary(
            persistedArticles.map { ($0.id, $0) },
            uniquingKeysWith: { newer, _ in newer }
          )
          let rebasedHeaders = result.headers.map { header in
            persistedByID[header.id].map(RSSArticleHeader.init(article:)) ?? header
          }
          return RSSRefreshMergeResult(
            headers: rebasedHeaders,
            articlesToUpsert: persistedArticles,
            highlights: result.highlights
          )
        }
        return RSSRefreshWorkerResult(
          request: request,
          updatedFeed: updatedFeed,
          mergeResult: persistedMergeResult,
          succeeded: true,
          skipped: false,
          issue: nil,
          persistenceError: nil,
          persisted: true,
          didExecuteOffMainActor: didExecuteOffMainActor
        )
      }
      return RSSRefreshWorkerResult(
        request: request,
        updatedFeed: updatedFeed,
        mergeResult: mergeResult,
        succeeded: true,
        skipped: false,
        issue: nil,
        persistenceError: nil,
        persisted: true,
        didExecuteOffMainActor: didExecuteOffMainActor
      )
    } catch {
      // The article/feed transaction has already rolled back. Report the
      // failure from the pre-refresh feed so a failed remote payload cannot
      // leak its title or timestamps into observable state. Persisting the
      // health update separately retains the old rollback semantics while
      // keeping that SQLite work off the main actor.
      let issue = RSSReaderError.persistence(error.localizedDescription).asFeedIssue()
      let failedFeed = failedFeed(feed, startedAt: request.startedAt, issue: issue)
      guard let database else {
        return RSSRefreshWorkerResult(
          request: request,
          updatedFeed: failedFeed,
          mergeResult: nil,
          succeeded: false,
          skipped: false,
          issue: issue,
          persistenceError: nil,
          persisted: true,
          didExecuteOffMainActor: didExecuteOffMainActor
        )
      }
      do {
        let persisted = try database.updateFeedHealthIfURLMatches(
          failedFeed,
          expectedURL: request.url
        )
        return RSSRefreshWorkerResult(
          request: request,
          updatedFeed: failedFeed,
          mergeResult: nil,
          succeeded: false,
          skipped: !persisted,
          issue: issue,
          persistenceError: nil,
          persisted: persisted,
          didExecuteOffMainActor: didExecuteOffMainActor
        )
      } catch {
        return RSSRefreshWorkerResult(
          request: request,
          updatedFeed: failedFeed,
          mergeResult: nil,
          succeeded: false,
          skipped: false,
          issue: issue,
          persistenceError: error.localizedDescription,
          persisted: false,
          didExecuteOffMainActor: didExecuteOffMainActor
        )
      }
    }
  }

  private static func cancelledResult(
    request: RSSReaderStore.RefreshRequest,
    feed: RSSFeed,
    didExecuteOffMainActor: Bool
  ) -> RSSRefreshWorkerResult {
    RSSRefreshWorkerResult(
      request: request,
      updatedFeed: feed,
      mergeResult: nil,
      succeeded: false,
      skipped: true,
      issue: RSSFeedIssue.cancelled(),
      persistenceError: nil,
      persisted: true,
      didExecuteOffMainActor: didExecuteOffMainActor
    )
  }

  static func failedFeed(
    _ feed: RSSFeed,
    startedAt: Date,
    issue: RSSFeedIssue,
    completedAt: Date = Date()
  ) -> RSSFeed {
    var failedFeed = feed
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
    return failedFeed
  }
}

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
      self.legacyArticles = updatedLegacyArticles
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
    var outcomesByFeedID: [UUID: RefreshOutcome] = [:]
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
        // Fetch completion order is intentionally decoupled from merge order.
        // `apply` snapshots current actor state, then performs payload reads,
        // merge planning and SQLite persistence on a detached utility task.
        outcomesByFeedID[fetchOutcome.request.feedID] = await apply(fetchOutcome)
        addNextRequest()
      }
    }
    // Keep status/error aggregation deterministic even when network responses
    // complete in a different order from the request list.
    return requests.compactMap { outcomesByFeedID[$0.feedID] }
  }

  func apply(_ fetchOutcome: RefreshFetchOutcome) async -> RefreshOutcome {
    guard !Task.isCancelled else {
      return RefreshOutcome(succeeded: false, skipped: true, message: nil, issue: nil)
    }
    guard let feedIndex = feeds.firstIndex(where: { $0.id == fetchOutcome.request.feedID }) else {
      return RefreshOutcome(succeeded: false, skipped: true, message: nil, issue: nil)
    }
    guard feeds[feedIndex].url == fetchOutcome.request.url else {
      return RefreshOutcome(succeeded: false, skipped: true, message: nil, issue: nil)
    }
    let feed = feeds[feedIndex]
    let baseHeaders = articleHeaders
    let baseHighlights = highlights
    let legacyArticles = database == nil ? self.legacyArticles : []
    let database = self.database
    let feedBodyOfflineCacheEnabled = self.feedBodyOfflineCacheEnabled
    let beforePersistenceHook = self.refreshWorkerBeforePersistenceHook
    let workerTask = Task.detached(priority: .utility) {
      await RSSRefreshWorker.run(
        request: fetchOutcome.request,
        feed: feed,
        fetchOutcome: fetchOutcome,
        baseHeaders: baseHeaders,
        baseHighlights: baseHighlights,
        legacyArticles: legacyArticles,
        feedBodyOfflineCacheEnabled: feedBodyOfflineCacheEnabled,
        database: database,
        beforePersistenceHook: beforePersistenceHook
      )
    }
    let workerResult = await withTaskCancellationHandler {
      await workerTask.value
    } onCancel: {
      workerTask.cancel()
    }
    lastRefreshWorkRanOffMainActor = workerResult.didExecuteOffMainActor
    guard !Task.isCancelled else {
      return RefreshOutcome(
        succeeded: false,
        skipped: true,
        message: nil,
        issue: workerResult.issue
      )
    }

    // The conditional SQLite write already rejected a deleted or URL-changed
    // feed. Re-check the observable source of truth before publishing the
    // detached plan, so an old response cannot resurrect UI state either.
    guard let currentFeedIndex = feeds.firstIndex(where: { $0.id == feed.id }),
      feeds[currentFeedIndex].url == fetchOutcome.request.url
    else {
      return RefreshOutcome(succeeded: false, skipped: true, message: nil, issue: nil)
    }
    if !workerResult.persisted, workerResult.persistenceError == nil {
      return RefreshOutcome(
        succeeded: false,
        skipped: true,
        message: nil,
        issue: workerResult.issue
      )
    }

    guard !Task.isCancelled else {
      return RefreshOutcome(
        succeeded: false,
        skipped: true,
        message: nil,
        issue: workerResult.issue
      )
    }

    if workerResult.succeeded {
      let articlesToUpsert = workerResult.mergeResult?.articlesToUpsert ?? []
      var updatedFeeds = feeds
      updatedFeeds[currentFeedIndex] = workerResult.updatedFeed
      let currentHeaders = articleHeaders
      let updatedHeaders: [RSSArticleHeader]
      let updatedLegacyArticles: [RSSArticle]
      let updatedHighlights = highlights
      if let mergeResult = workerResult.mergeResult {
        // Preserve mutations that happened while the detached merge was
        // running (read/star/tag/highlight changes and other feed results).
        let currentHeadersByID = Dictionary(
          currentHeaders.filter { $0.feedID == feed.id }.map { ($0.id, $0) },
          uniquingKeysWith: { newer, _ in newer }
        )
        let rebasedFeedHeaders = mergeResult.headers
          .filter { $0.feedID == feed.id }
          .map { header in
            guard let currentHeader = currentHeadersByID[header.id] else { return header }
            var rebased = header
            rebased.readAt = currentHeader.readAt
            rebased.isStarred = currentHeader.isStarred
            rebased.tags = currentHeader.tags
            return rebased
          }
        updatedHeaders = currentHeaders.filter { $0.feedID != feed.id }
          + rebasedFeedHeaders
        updatedLegacyArticles = mergingLegacyArticles(
          self.legacyArticles,
          changedArticles: articlesToUpsert
        )
      } else {
        updatedHeaders = currentHeaders
        updatedLegacyArticles = self.legacyArticles
      }
      do {
        try persistLegacySnapshotIfNeeded(
          feeds: updatedFeeds,
          articles: updatedLegacyArticles,
          highlights: updatedHighlights
        )
      } catch {
        return RefreshOutcome(
          succeeded: false,
          skipped: false,
          message: "\(workerResult.updatedFeed.displayTitle)：无法保存刷新结果：\(error.localizedDescription)",
          issue: RSSReaderError.persistence(error.localizedDescription).asFeedIssue()
        )
      }
      feeds = updatedFeeds
      articleHeaders = updatedHeaders
      self.legacyArticles = updatedLegacyArticles
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
    }

    if workerResult.skipped || workerResult.issue?.category == .cancelled {
      return RefreshOutcome(
        succeeded: false,
        skipped: true,
        message: nil,
        issue: workerResult.issue
      )
    }
    let issue = workerResult.issue
      ?? RSSFeedIssue(
        stage: .transport,
        category: .unknown,
        retryStrategy: .automatic,
        userMessage: "订阅读取暂时失败，请稍后重试。"
      )
    var updatedFeeds = feeds
    updatedFeeds[currentFeedIndex] = workerResult.updatedFeed
    do {
      try persistLegacySnapshotIfNeeded(
        feeds: updatedFeeds,
        articles: legacyArticles,
        highlights: highlights
      )
    } catch {
      return RefreshOutcome(
        succeeded: false,
        skipped: false,
        message: "\(issue.userMessage)；同时无法保存错误状态：\(error.localizedDescription)",
        issue: RSSReaderError.persistence(error.localizedDescription).asFeedIssue()
      )
    }
    feeds = updatedFeeds
    bumpMutationRevision()
    let message: String
    if let persistenceError = workerResult.persistenceError {
      message = "\(workerResult.updatedFeed.displayTitle)：\(issue.userMessage)；同时无法保存错误状态：\(persistenceError)"
    } else {
      message = "\(workerResult.updatedFeed.displayTitle)：\(issue.userMessage)"
    }
    return RefreshOutcome(
      succeeded: false,
      skipped: false,
      message: message,
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
  ) -> RSSRefreshMergeResult {
    RSSRefreshMergeSupport.mergedContent(
      parsedArticles,
      into: feed,
      baseHeaders: baseHeaders,
      existingPayloads: existingPayloads,
      baseHighlights: baseHighlights,
      feedBodyOfflineCacheEnabled: feedBodyOfflineCacheEnabled,
      now: now
    )
  }

  func offlineSummaryHTML(for parsed: RSSParsedArticle) -> String {
    RSSRefreshMergeSupport.offlineSummaryHTML(for: parsed)
  }
}
