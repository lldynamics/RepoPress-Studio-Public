#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  import Foundation

  extension RSSReaderStore {
    /// Loads deterministic RSS data used exclusively by screenshot and UI-test fixtures.
    /// The mutation sequence intentionally matches the prior Workbench fixture so the
    /// reader's persistence and in-memory snapshots remain aligned.
    @MainActor
    package func loadPreviewFeed(
      url: URL,
      title: String,
      siteURL: URL?,
      updatedAt: Date,
      articles: [RSSParsedArticle]
    ) {
      do {
        let feedID = try addFeed(url: url, title: title, siteURL: siteURL)
        guard let feedIndex = feeds.firstIndex(where: { $0.id == feedID }) else {
          return
        }
        var feed = feeds[feedIndex]
        feed.lastUpdatedAt = updatedAt
        try database?.upsertFeed(feed)
        feeds[feedIndex] = feed
        merge(articles, into: feed)
        articleHeaderCount = articleHeaders.count
      } catch {
        lastError = "RSS UI 测试数据准备失败：\(error.localizedDescription)"
      }
    }
  }
#endif
