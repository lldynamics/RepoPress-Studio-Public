import CryptoKit
import Foundation
import PublishingCoreSupport

extension RSSReaderStore {
  public var isHistoryBackfillRunning: Bool { historyBackfillTask != nil }

  public func loadHistoryBackfillProgress(feedID: UUID) throws {
    guard historyBackfillTask == nil else { return }
    var saved = try database?.historyBackfillProgress(feedID: feedID)
    if saved?.isRunning == true {
      saved?.status = .paused
      saved?.message = CoreL10n.text("上次补齐已中断，可以继续。")
    }
    historyBackfillProgress = saved
  }

  /// This is intentionally absent from refresh, launch and background timers.
  /// Only an explicit per-subscription user action starts history work.
  public func startHistoryBackfill(
    feedID: UUID, directoryURL: URL,
    service: RSSHistoryBackfillService = RSSHistoryBackfillService(),
    retryFailures: Bool = false
  ) {
    guard historyBackfillTask == nil else { return }
    historyBackfillTask = Task { [weak self] in
      guard let self else { return }
      await self.runHistoryBackfill(
        feedID: feedID, directoryURL: directoryURL, service: service, retryFailures: retryFailures
      )
      self.historyBackfillTask = nil
      self.objectWillChange.send()
    }
    objectWillChange.send()
  }

  public func cancelHistoryBackfill() { historyBackfillTask?.cancel() }

  func runHistoryBackfill(
    feedID: UUID, directoryURL: URL, service: RSSHistoryBackfillService,
    retryFailures: Bool = false
  ) async {
    var progress: RSSHistoryBackfillProgress?
    do {
      guard let database, let feed = feeds.first(where: { $0.id == feedID }) else {
        throw RSSHistoryBackfillError.unavailable(CoreL10n.text("历史补齐需要可用的订阅与 SQLite 数据库。"))
      }
      guard let siteURL = feed.siteURL,
        RSSHistoryURLIdentity.sameOrigin(directoryURL, siteURL)
      else {
        throw RSSHistoryBackfillError.unavailable(CoreL10n.text("请填写该订阅网站内的公开目录地址。"))
      }
      _ = try RSSNetworkURLPolicy.syntacticallyValidatedURL(directoryURL)
      await loadRemainingArticleHeadersIfNeeded()
      guard requireCompleteArticleIndex() else {
        throw RSSHistoryBackfillError.unavailable(CoreL10n.text("文章索引尚未加载完成，请稍后重试。"))
      }
      let saved = try database.historyBackfillProgress(feedID: feedID)
      let matches = saved?.feedURL == feed.url && saved?.directoryURL == directoryURL
      var current: RSSHistoryBackfillProgress
      if matches, let saved,
        (saved.status != .completed && saved.status != .unavailable) || retryFailures
      {
        current = saved
      } else {
        current = RSSHistoryBackfillProgress(
          feedID: feedID, feedURL: feed.url, directoryURL: directoryURL)
      }
      if matches, retryFailures, current.nextIndex == current.candidates.count {
        // Migrate legacy failed indices before querying the durable failure list.
        try database.saveHistoryBackfillProgress(current)
        current.failureLedgerInitialized = true
        let failures = try database.historyFailedCandidates(current)
        current.failureRetryAfterURLKey = failures.last.map { RSSHistoryURLIdentity.key($0.url) }
        if current.retryingFailures != true {
          current.completedDiscoveryCount = current.discoveredCount
        }
        current.candidates = failures
        current.nextIndex = 0
        current.failedIndices = []
        current.retryingFailures = true
      } else if current.nextIndex == current.candidates.count, current.hasMoreDiscovery {
        if current.retryingFailures != true {
          current.completedDiscoveryCount = current.discoveredCount
        }
        current.candidates = []
        current.nextIndex = 0
        current.failedIndices = []
        current.retryingFailures = false
      }
      progress = current
      if let retryAt = current.retryAt, retryAt > Date() {
        current.status = .paused
        current.message = CoreL10n.text("网站要求等待，稍后可以继续。")
        try publishHistoryProgress(&current, database: database)
        return
      }
      current.retryAt = nil
      current.status = current.pendingPages.isEmpty ? .fetching : .discovering
      current.message = CoreL10n.text("正在读取网站访问规则。")
      try publishHistoryProgress(&current, database: database)
      progress = current
      let policy = try await service.robotsPolicy(origin: directoryURL)
      try Task.checkCancellation()
      if current.candidates.isEmpty, current.retryingFailures != true {
        try await discoverHistorySegment(
          progress: &current, database: database, service: service, policy: policy)
        progress = current
      }
      guard !current.candidates.isEmpty else {
        throw RSSHistoryBackfillError.unavailable(CoreL10n.text("未找到可识别的公开文章目录；该来源目前无法补齐历史。"))
      }
      current.status = .fetching
      current.message = CoreL10n.text("正在补齐文章与正文。")
      try publishHistoryProgress(&current, database: database)
      progress = current
      let batchEnd = min(current.nextIndex + service.limits.batchSize, current.candidates.count)
      while current.nextIndex < batchEnd {
        try checkHistoryFeedIsCurrent(current)
        let candidate = current.candidates[current.nextIndex]
        let item = try await prepareHistoryItem(
          candidate, feed: feed, service: service, policy: policy, origin: directoryURL)
        try checkHistoryFeedIsCurrent(current)
        let snapshot = current
        let commitTask = Task.detached(priority: .utility) {
          try database.commitHistoryItem(
            progress: snapshot, proposedArticle: item.article,
            verifiedAliases: item.aliases, record: item.record
          )
        }
        let committed = try await withTaskCancellationHandler {
          try await commitTask.value
        } onCancel: {
          commitTask.cancel()
        }
        current = committed.progress
        progress = current
        // A commit may have completed just before cancellation. Publish its
        // durable queue position before marking the operation paused.
        if !articleHeaders.contains(where: { $0.id == committed.header.id }) {
          articleHeaders.append(committed.header)
          articleHeaderCount += 1
        }
        historyBackfillProgress = current
        bumpMutationRevision()
      }
      try Task.checkCancellation()
      current.status =
        current.nextIndex == current.candidates.count && !current.hasMoreDiscovery
        ? .completed : .paused
      current.message =
        current.status == .completed
        ? CoreL10n.text("已处理发现的链接；正文失败项可以重试，不代表全站历史已齐全。")
        : CoreL10n.text("本批已结束，可以继续处理剩余链接。")
      if current.nextIndex == current.candidates.count, current.hasMoreDiscovery {
        current.message = CoreL10n.text("本段已处理，可以继续发现下一段历史链接。")
      }
      if current.reachedDiscoveryLimit {
        current.message += " " + CoreL10n.text("已达到本段发现上限，续查位置已保存。")
      }
      try publishHistoryProgress(&current, database: database)
    } catch {
      if var current = progress {
        // Read the committed checkpoint rather than rewinding a transaction
        // that won the cancellation race.
        do {
          if let durable = try database?.historyBackfillProgress(feedID: current.feedID),
            durable.id == current.id
          {
            current = durable
          }
        } catch {
          // An unreadable checkpoint must not be overwritten with a guessed cursor.
          current.status = .paused
          current.message = CoreL10n.text("历史补齐检查点无法读取。")
          historyBackfillProgress = current
          lastError = error.localizedDescription
          return
        }
        current.status = .paused
        if Task.isCancelled || error is CancellationError {
          current.message = CoreL10n.text("已取消；成功保存的结果保留，可以继续。")
        } else {
          current.message = error.localizedDescription
          let issue = RSSFeedIssue.from(error: error)
          if issue.category == .rateLimited || issue.category == .serverUnavailable {
            current.retryAt = issue.retryAt ?? Date().addingTimeInterval(60)
            current.message = CoreL10n.text("网站暂时不允许继续读取，等待后可手动继续。")
          }
          if case RSSHistoryBackfillError.unavailable = error, current.candidates.isEmpty {
            current.status = .unavailable
          }
        }
        historyBackfillProgress = current
        do { try database?.saveHistoryBackfillProgress(current) } catch {
          lastError = error.localizedDescription
        }
      } else {
        var unavailable = RSSHistoryBackfillProgress(
          feedID: feedID, feedURL: directoryURL, directoryURL: directoryURL)
        unavailable.status = .unavailable
        unavailable.message = error.localizedDescription
        historyBackfillProgress = unavailable
      }
    }
  }

  func publishHistoryProgress(
    _ progress: inout RSSHistoryBackfillProgress, database: RSSReaderDatabase
  ) throws {
    try database.saveHistoryBackfillProgress(progress)
    progress.failureLedgerInitialized = true
    historyBackfillProgress = progress
  }

  func checkHistoryFeedIsCurrent(_ progress: RSSHistoryBackfillProgress) throws {
    try Task.checkCancellation()
    guard feeds.contains(where: { $0.id == progress.feedID && $0.url == progress.feedURL }) else {
      throw RSSHistoryBackfillError.sourceChanged
    }
  }

  private func historyParse(_ download: RSSArticlePageDownload, origin: URL) async throws
    -> RSSHistoryDirectoryPage
  {
    let task = Task.detached(priority: .utility) {
      try RSSHistoryDirectoryParser.parse(
        data: download.data, responseURL: download.resolvedURL, origin: origin)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func prepareHistoryItem(
    _ candidate: RSSHistoryBackfillCandidate, feed: RSSFeed,
    service: RSSHistoryBackfillService, policy: RSSHistoryRobotsPolicy, origin: URL
  ) async throws -> (article: RSSArticle, aliases: Set<String>, record: RSSArticleFullTextRecord?) {
    var aliases: Set<String> = [RSSHistoryURLIdentity.key(candidate.url)]
    let exact = articleHeaders.first { header in
      header.feedID == feed.id
        && header.link.map { aliases.contains(RSSHistoryURLIdentity.key($0)) } == true
    }
    let digest = SHA256.hash(data: Data(RSSHistoryURLIdentity.key(candidate.url).utf8))
      .map { String(format: "%02x", $0) }.joined()
    var article = RSSArticle(
      id: "\(feed.id.uuidString):history-\(digest)", feedID: feed.id,
      title: candidate.title.isEmpty ? candidate.url.lastPathComponent : candidate.title,
      link: candidate.url
    )
    if let exact, let existing = try await loadArticle(id: exact.id) {
      article = existing
      if try historyHasReusableFullText(existing)
        || (!existing.contentHTML.isEmpty
          && !RSSArticleFullTextService().isTruncatedCandidate(existing))
      {
        return (article, aliases, nil)
      }
    }
    do {
      let download = try await service.download(candidate.url, origin: origin, policy: policy)
      let metadata = try await historyParse(download, origin: origin)
      if exact == nil, candidate.title.isEmpty {
        article.title = metadata.articleTitle ?? candidate.url.lastPathComponent
      }
      guard !metadata.forbidsArchiving else {
        throw RSSHistoryBackfillError.unavailable(CoreL10n.text("原文页面不允许保存内容。"))
      }
      aliases.insert(RSSHistoryURLIdentity.key(download.resolvedURL))
      if let canonical = metadata.canonicalURL {
        aliases.insert(RSSHistoryURLIdentity.key(canonical))
      }
      // Do not normalize // to / globally. For the observed feed variant,
      // request the old URL and demand an explicit shared identity first.
      let possibleAliases = articleHeaders.filter {
        $0.feedID == feed.id
          && $0.link.map {
            RSSHistoryURLIdentity.mayBeSlashAlias($0, candidate.url)
              && !aliases.contains(RSSHistoryURLIdentity.key($0))
          } == true
      }
      for header in possibleAliases.prefix(2) {
        guard let oldURL = header.link else { continue }
        let oldDownload = try await service.download(oldURL, origin: origin, policy: policy)
        let oldMetadata = try await historyParse(oldDownload, origin: origin)
        let declared = [oldDownload.resolvedURL, oldMetadata.canonicalURL].compactMap { $0 }
        if declared.contains(where: { aliases.contains(RSSHistoryURLIdentity.key($0)) }) {
          aliases.insert(RSSHistoryURLIdentity.key(oldURL))
          if let existing = try await loadArticle(id: header.id) { article = existing }
          break
        }
      }
      if let header = articleHeaders.first(where: {
        $0.feedID == feed.id
          && $0.link.map { aliases.contains(RSSHistoryURLIdentity.key($0)) } == true
      }), let existing = try await loadArticle(id: header.id) {
        article = existing
        if try historyHasReusableFullText(existing) {
          return (article, aliases, nil)
        }
      }
      var target = article
      target.title = candidate.title
      let extractionArticle = target
      let task = Task.detached(priority: .utility) {
        try RSSArticleFullTextService().extractFullTextRecord(
          for: extractionArticle, download: download)
      }
      let record = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      return (article, aliases, record)
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      let issue = RSSFeedIssue.from(error: error)
      if [.rateLimited, .serverUnavailable, .authenticationRequired, .permissionDenied].contains(
        issue.category)
      {
        throw error
      }
      // One unavailable or rejected article does not erase successful work.
      return (article, aliases, nil)
    }
  }

  private func historyHasReusableFullText(_ article: RSSArticle) throws -> Bool {
    guard let record = try fullTextRecord(articleID: article.id) else { return false }
    return record.status == .ready && record.sourceURL == article.link
  }
}
