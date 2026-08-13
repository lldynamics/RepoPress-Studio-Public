import Foundation

/// Value-semantic data prepared before the main-actor RSS store is created.
///
/// Opening SQLite can include directory creation, schema migration and WAL
/// setup.  The app launch coordinator prepares this value on a utility task,
/// then hands the already-open, lock-serialised database to
/// ``RSSReaderStore``.  The first header page is intentionally bounded; the
/// store can request the remaining pages after its first render.
public struct RSSReaderBootstrap: Sendable {
  public static let defaultPageSize = 200

  public let databaseURL: URL
  public let legacyURL: URL
  public let feeds: [RSSFeed]
  public let articleHeaders: [RSSArticleHeader]
  public let highlights: [RSSArticleHighlight]
  public let mediaAssets: [RSSMediaAsset]
  public let legacyArticles: [RSSArticle]
  public let articleCount: Int
  public let loadedAllArticleHeaders: Bool
  public let statusMessage: String?
  public let errorMessage: String?

  // The database stays behind the public value boundary so callers cannot
  // accidentally use it from the wrong actor. RSSReaderDatabase serialises
  // all access with its lock and is already explicitly Sendable for this
  // purpose.
  let database: RSSReaderDatabase?

  init(
    databaseURL: URL,
    legacyURL: URL,
    feeds: [RSSFeed],
    articleHeaders: [RSSArticleHeader],
    highlights: [RSSArticleHighlight],
    mediaAssets: [RSSMediaAsset],
    legacyArticles: [RSSArticle],
    articleCount: Int,
    loadedAllArticleHeaders: Bool,
    statusMessage: String?,
    errorMessage: String?,
    database: RSSReaderDatabase?
  ) {
    self.databaseURL = databaseURL
    self.legacyURL = legacyURL
    self.feeds = feeds
    self.articleHeaders = articleHeaders
    self.highlights = highlights
    self.mediaAssets = mediaAssets
    self.legacyArticles = legacyArticles
    self.articleCount = max(0, articleCount)
    self.loadedAllArticleHeaders = loadedAllArticleHeaders
    self.statusMessage = statusMessage
    self.errorMessage = errorMessage
    self.database = database
  }

  /// Prepares the persistent RSS state away from the main actor.
  ///
  /// Opening or migrating SQLite is deliberately best-effort. A malformed or
  /// unavailable database falls back to the legacy JSON snapshot, matching the
  /// store's historical recovery behaviour while retaining the error for UI
  /// diagnostics.
  @MainActor
  public static func prepare(
    fileURL: URL,
    fileManager: FileManager = .default,
    pageSize: Int = RSSReaderBootstrap.defaultPageSize
  ) async -> RSSReaderBootstrap {
    let requestedFileURL = fileURL
    let normalizedPageSize = max(1, pageSize)
    // Preserve the injected file-system contract for tests and callers that
    // deliberately provide a custom manager. The normal production manager
    // takes the detached path below; custom managers stay on their owning
    // actor because Foundation's FileManager itself is not Sendable.
    if fileManager !== FileManager.default {
      return prepareSynchronously(
        fileURL: requestedFileURL,
        fileManager: fileManager,
        pageSize: normalizedPageSize
      )
    }
    // FileManager is reference-based and not Sendable. The production launch
    // path uses the process-wide default manager; keeping that lookup inside
    // the utility task avoids crossing a mutable manager between actors.
    _ = fileManager
    return await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      let databaseURL = RSSReaderStore.databaseFileURL(for: requestedFileURL)
      let legacyURL = RSSReaderStore.legacyFileURL(for: requestedFileURL)

      do {
        let database = try RSSReaderDatabase(fileURL: databaseURL, fileManager: fileManager)
        if try database.isEmpty, fileManager.fileExists(atPath: legacyURL.path) {
          let snapshot = try loadLegacySnapshot(at: legacyURL)
          try database.replaceSnapshot(snapshot)
          let headers = try database.articleHeaders(limit: normalizedPageSize)
          let articleCount = try database.articleHeaderCount()
          return RSSReaderBootstrap(
            databaseURL: databaseURL,
            legacyURL: legacyURL,
            feeds: try database.feeds(),
            articleHeaders: headers,
            highlights: try database.highlights(),
            mediaAssets: try database.mediaAssets(),
            legacyArticles: [],
            articleCount: articleCount,
            loadedAllArticleHeaders: headers.count >= articleCount,
            statusMessage: "已将旧版 RSS 缓存迁移到 SQLite，原 JSON 已保留为备份。",
            errorMessage: nil,
            database: database
          )
        }

        let headers = try database.articleHeaders(limit: normalizedPageSize)
        let articleCount = try database.articleHeaderCount()
        return RSSReaderBootstrap(
          databaseURL: databaseURL,
          legacyURL: legacyURL,
          feeds: try database.feeds(),
          articleHeaders: headers,
          highlights: try database.highlights(),
          mediaAssets: try database.mediaAssets(),
          legacyArticles: [],
          articleCount: articleCount,
          loadedAllArticleHeaders: headers.count >= articleCount,
          statusMessage: nil,
          errorMessage: nil,
          database: database
        )
      } catch {
        let databaseError = "RSS SQLite 缓存读取失败，将尝试兼容 JSON：\(error.localizedDescription)"
        do {
          let snapshot = try loadLegacySnapshot(at: legacyURL)
          let sortedArticles = snapshot.articles.sorted(by: articleSort)
          let headers =
            sortedArticles
            .prefix(normalizedPageSize)
            .map(RSSArticleHeader.init(article:))
          return RSSReaderBootstrap(
            databaseURL: databaseURL,
            legacyURL: legacyURL,
            feeds: snapshot.feeds,
            articleHeaders: headers,
            highlights: snapshot.highlights,
            mediaAssets: snapshot.mediaAssets,
            legacyArticles: sortedArticles,
            articleCount: sortedArticles.count,
            loadedAllArticleHeaders: headers.count >= sortedArticles.count,
            statusMessage: nil,
            errorMessage: databaseError,
            database: nil
          )
        } catch {
          return RSSReaderBootstrap(
            databaseURL: databaseURL,
            legacyURL: legacyURL,
            feeds: [],
            articleHeaders: [],
            highlights: [],
            mediaAssets: [],
            legacyArticles: [],
            articleCount: 0,
            loadedAllArticleHeaders: true,
            statusMessage: nil,
            errorMessage: "\(databaseError)\nRSS 本地缓存读取失败：\(error.localizedDescription)",
            database: nil
          )
        }
      }
    }.value
  }

  @MainActor
  private static func prepareSynchronously(
    fileURL: URL,
    fileManager: FileManager,
    pageSize: Int
  ) -> RSSReaderBootstrap {
    let databaseURL = RSSReaderStore.databaseFileURL(for: fileURL)
    let legacyURL = RSSReaderStore.legacyFileURL(for: fileURL)
    do {
      let database = try RSSReaderDatabase(fileURL: databaseURL, fileManager: fileManager)
      if try database.isEmpty, fileManager.fileExists(atPath: legacyURL.path) {
        let snapshot = try loadLegacySnapshot(at: legacyURL)
        try database.replaceSnapshot(snapshot)
        let headers = try database.articleHeaders(limit: pageSize)
        let articleCount = try database.articleHeaderCount()
        return RSSReaderBootstrap(
          databaseURL: databaseURL,
          legacyURL: legacyURL,
          feeds: try database.feeds(),
          articleHeaders: headers,
          highlights: try database.highlights(),
          mediaAssets: try database.mediaAssets(),
          legacyArticles: [],
          articleCount: articleCount,
          loadedAllArticleHeaders: headers.count >= articleCount,
          statusMessage: "已将旧版 RSS 缓存迁移到 SQLite，原 JSON 已保留为备份。",
          errorMessage: nil,
          database: database
        )
      }
      let headers = try database.articleHeaders(limit: pageSize)
      let articleCount = try database.articleHeaderCount()
      return RSSReaderBootstrap(
        databaseURL: databaseURL,
        legacyURL: legacyURL,
        feeds: try database.feeds(),
        articleHeaders: headers,
        highlights: try database.highlights(),
        mediaAssets: try database.mediaAssets(),
        legacyArticles: [],
        articleCount: articleCount,
        loadedAllArticleHeaders: headers.count >= articleCount,
        statusMessage: nil,
        errorMessage: nil,
        database: database
      )
    } catch {
      let databaseError = "RSS SQLite 缓存读取失败，将尝试兼容 JSON：\(error.localizedDescription)"
      do {
        let snapshot = try loadLegacySnapshot(at: legacyURL)
        let sortedArticles = snapshot.articles.sorted(by: articleSort)
        let headers = sortedArticles.prefix(pageSize).map(RSSArticleHeader.init(article:))
        return RSSReaderBootstrap(
          databaseURL: databaseURL,
          legacyURL: legacyURL,
          feeds: snapshot.feeds,
          articleHeaders: headers,
          highlights: snapshot.highlights,
          mediaAssets: snapshot.mediaAssets,
          legacyArticles: sortedArticles,
          articleCount: sortedArticles.count,
          loadedAllArticleHeaders: headers.count >= sortedArticles.count,
          statusMessage: nil,
          errorMessage: databaseError,
          database: nil
        )
      } catch {
        return RSSReaderBootstrap(
          databaseURL: databaseURL,
          legacyURL: legacyURL,
          feeds: [],
          articleHeaders: [],
          highlights: [],
          mediaAssets: [],
          legacyArticles: [],
          articleCount: 0,
          loadedAllArticleHeaders: true,
          statusMessage: nil,
          errorMessage: "\(databaseError)\nRSS 本地缓存读取失败：\(error.localizedDescription)",
          database: nil
        )
      }
    }
  }

  private static func loadLegacySnapshot(at url: URL) throws -> RSSReaderSnapshot {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(RSSReaderSnapshot.self, from: data)
    guard snapshot.schemaVersion <= RSSReaderSnapshot.currentSchemaVersion else {
      throw RSSReaderError.persistence(
        "缓存版本 \(snapshot.schemaVersion) 高于当前支持版本"
      )
    }
    return snapshot
  }

  private static func articleSort(_ lhs: RSSArticle, _ rhs: RSSArticle) -> Bool {
    let leftDate = lhs.publishedAt ?? lhs.fetchedAt
    let rightDate = rhs.publishedAt ?? rhs.fetchedAt
    if leftDate != rightDate { return leftDate > rightDate }
    return lhs.id < rhs.id
  }
}
