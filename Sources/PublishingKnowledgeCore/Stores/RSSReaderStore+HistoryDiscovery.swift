import CryptoKit
import Foundation
import PublishingCoreSupport

extension RSSReaderStore {
  /// A user action fills at most one bounded segment. The partially consumed
  /// page stays at the queue head with a verified fingerprint and offset.
  func discoverHistorySegment(
    progress: inout RSSHistoryBackfillProgress, database: RSSReaderDatabase,
    service: RSSHistoryBackfillService, policy: RSSHistoryRobotsPolicy
  ) async throws {
    if progress.sitemapsLoaded != true {
      for sitemap in policy.sitemaps
      where RSSHistoryURLIdentity.sameOrigin(sitemap, progress.directoryURL)
        && policy.allows(sitemap) && !progress.pendingPages.contains(sitemap)
      {
        if progress.pendingPages.count < service.limits.maximumPages {
          progress.pendingPages.append(sitemap)
        } else {
          throw RSSHistoryBackfillError.unavailable(
            CoreL10n.text("目录链接过多，已停止发现历史文章。"))
        }
      }
      progress.sitemapsLoaded = true
      try publishHistoryProgress(&progress, database: database)
    }
    progress.reachedDiscoveryLimit = false
    while let pageURL = progress.pendingPages.first {
      try checkHistoryFeedIsCurrent(progress)
      if progress.visitedPages.contains(pageURL) {
        progress.pendingPages.removeFirst()
        continue
      }
      guard progress.visitedPages.count < service.limits.maximumPages else {
        throw RSSHistoryBackfillError.unavailable(
          CoreL10n.text("已达到目录页面上限；请选择更具体的公开目录。"))
      }
      let download = try await service.download(
        pageURL, origin: progress.directoryURL, policy: policy)
      let directoryURL = progress.directoryURL
      let parseTask = Task.detached(priority: .utility) {
        if ["application/xml", "text/xml", "application/atom+xml"].contains(download.mimeType)
          || String(data: download.data.prefix(500), encoding: .utf8)?
            .contains("sitemaps.org/schemas/sitemap") == true
        {
          return try RSSHistorySitemapParser.parse(
            data: download.data, responseURL: download.resolvedURL, directoryURL: directoryURL)
        }
        return try RSSHistoryDirectoryParser.parse(
          data: download.data, responseURL: download.resolvedURL, origin: directoryURL)
      }
      let page = try await withTaskCancellationHandler {
        try await parseTask.value
      } onCancel: {
        parseTask.cancel()
      }
      try checkHistoryFeedIsCurrent(progress)
      guard !page.forbidsArchiving else {
        throw RSSHistoryBackfillError.unavailable(
          CoreL10n.text("网站声明不允许跟随链接或保存内容，已停止补齐。"))
      }
      let identities = page.articles.map { RSSHistoryURLIdentity.key($0.url) }.joined(
        separator: "\n")
      let fingerprint = SHA256.hash(data: Data(identities.utf8))
        .map { String(format: "%02x", $0) }.joined()
      let cursor = progress.discoveryCursor
      if let cursor,
        cursor.url != pageURL || cursor.fingerprint != fingerprint
          || cursor.articleOffset > page.articles.count
      {
        throw RSSHistoryBackfillError.unavailable(
          CoreL10n.text("目录内容已改变，续查已停止；请重新发现历史链接。"))
      }
      var offset = cursor?.articleOffset ?? 0
      var known = Set(progress.candidates.map { RSSHistoryURLIdentity.key($0.url) })
      while offset < page.articles.count && progress.candidates.count < service.limits.maximumURLs {
        let candidate = page.articles[offset]
        offset += 1
        if !policy.allows(candidate.url) { continue }
        if known.insert(RSSHistoryURLIdentity.key(candidate.url)).inserted {
          progress.candidates.append(candidate)
        }
      }
      if offset < page.articles.count {
        progress.discoveryCursor = RSSHistoryDiscoveryCursor(
          url: pageURL, articleOffset: offset, fingerprint: fingerprint)
        progress.reachedDiscoveryLimit = true
      } else {
        progress.discoveryCursor = nil
        progress.pendingPages.removeFirst()
        progress.visitedPages.append(pageURL)
        for next in page.nextPages
        where policy.allows(next) && !progress.visitedPages.contains(next)
          && !progress.pendingPages.contains(next)
        {
          guard progress.pendingPages.count < service.limits.maximumPages else {
            throw RSSHistoryBackfillError.unavailable(
              CoreL10n.text("目录链接过多，已停止发现历史文章。"))
          }
          progress.pendingPages.append(next)
        }
      }
      progress.message = CoreL10n.text("正在发现公开目录中的文章链接。")
      try publishHistoryProgress(&progress, database: database)
      if progress.candidates.count >= service.limits.maximumURLs {
        progress.reachedDiscoveryLimit = progress.hasMoreDiscovery
        return
      }
    }
  }
}
