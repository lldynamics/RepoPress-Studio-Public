import Foundation
import SQLite3

private let rssSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct RSSReaderDatabaseStatistics: Equatable, Sendable {
  var feedCount: Int
  var articleCount: Int
  var highlightCount: Int
}

final class RSSReaderDatabase {
  static let currentSchemaVersion = 5

  let fileURL: URL
  private var handle: OpaquePointer?
  private let lock = NSLock()

  init(fileURL: URL, fileManager: FileManager = .default) throws {
    self.fileURL = fileURL
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
        ?? "无法打开 RSS SQLite 数据库"
      if let database { sqlite3_close(database) }
      throw RSSReaderError.persistence(message)
    }
    handle = database

    do {
      try execute("PRAGMA foreign_keys = ON;")
      try execute("PRAGMA journal_mode = WAL;")
      try execute("PRAGMA synchronous = NORMAL;")
      let version = try scalarInt("PRAGMA user_version;")
      guard version <= Self.currentSchemaVersion else {
        throw RSSReaderError.persistence(
          "RSS SQLite 缓存版本 \(version) 高于当前支持版本 \(Self.currentSchemaVersion)"
        )
      }
      try migrate(from: version)
    } catch {
      sqlite3_close(database)
      handle = nil
      throw error
    }
  }

  deinit {
    if let handle { sqlite3_close(handle) }
  }

  var isEmpty: Bool {
    guard let statistics = try? statistics() else { return true }
    return statistics.feedCount == 0 && statistics.articleCount == 0
  }

  func statistics() throws -> RSSReaderDatabaseStatistics {
    try withLock {
      RSSReaderDatabaseStatistics(
        feedCount: try scalarIntUnlocked("SELECT COUNT(*) FROM rss_feeds;"),
        articleCount: try scalarIntUnlocked("SELECT COUNT(*) FROM rss_articles;"),
        highlightCount: try scalarIntUnlocked("SELECT COUNT(*) FROM rss_article_highlights;")
      )
    }
  }

  func feeds() throws -> [RSSFeed] {
    try withLock {
      let statement = try prepareUnlocked("""
      SELECT id, title, url, site_url, icon_url, added_at, last_updated_at,
             etag, last_modified, last_error, last_refresh_attempt_at,
             refresh_failure_count, next_retry_at, last_refresh_duration,
             last_issue_json
      FROM rss_feeds
      ORDER BY added_at ASC, title COLLATE NOCASE ASC;
      """)
      defer { sqlite3_finalize(statement) }
      var output: [RSSFeed] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(try decodeFeed(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func articles() throws -> [RSSArticle] {
    try withLock {
      let statement = try prepareUnlocked(articleSelectSQL + " ORDER BY COALESCE(published_at, fetched_at) DESC, id ASC;")
      defer { sqlite3_finalize(statement) }
      var output: [RSSArticle] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(try decodeArticle(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func articleHeaders() throws -> [RSSArticleHeader] {
    try withLock {
      let statement = try prepareUnlocked(
        articleHeaderSelectSQL
          + " ORDER BY COALESCE(published_at, fetched_at) DESC, id ASC;"
      )
      defer { sqlite3_finalize(statement) }
      var output: [RSSArticleHeader] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(try decodeArticleHeader(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func article(id: String) throws -> RSSArticle? {
    try withLock {
      let statement = try prepareUnlocked(articleSelectSQL + " WHERE id = ? LIMIT 1;")
      defer { sqlite3_finalize(statement) }
      bind(id, at: 1, to: statement)
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        return try decodeArticle(statement)
      case SQLITE_DONE:
        return nil
      default:
        throw databaseErrorUnlocked()
      }
    }
  }

  func articles(ids: Set<String>) throws -> [RSSArticle] {
    guard !ids.isEmpty else { return [] }
    return try withLock {
      let statement = try prepareUnlocked(articleSelectSQL + " WHERE id = ? LIMIT 1;")
      defer { sqlite3_finalize(statement) }
      var output: [RSSArticle] = []
      output.reserveCapacity(ids.count)
      for id in ids {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(id, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
          output.append(try decodeArticle(statement))
        case SQLITE_DONE:
          continue
        default:
          throw databaseErrorUnlocked()
        }
      }
      return output
    }
  }

  func articles(feedID: UUID) throws -> [RSSArticle] {
    try withLock {
      let statement = try prepareUnlocked(
        articleSelectSQL
          + " WHERE feed_id = ? ORDER BY COALESCE(published_at, fetched_at) DESC, id ASC;"
      )
      defer { sqlite3_finalize(statement) }
      bind(feedID.uuidString, at: 1, to: statement)
      var output: [RSSArticle] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(try decodeArticle(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func containsArticle(id: String) throws -> Bool {
    try withLock {
      let statement = try prepareUnlocked("SELECT 1 FROM rss_articles WHERE id = ? LIMIT 1;")
      defer { sqlite3_finalize(statement) }
      bind(id, at: 1, to: statement)
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        return true
      case SQLITE_DONE:
        return false
      default:
        throw databaseErrorUnlocked()
      }
    }
  }

  func highlights(articleID: String? = nil) throws -> [RSSArticleHighlight] {
    try withLock {
      let sql: String
      if articleID == nil {
        sql = """
        SELECT id, article_id, text, note, tags_json, created_at, updated_at
        FROM rss_article_highlights
        ORDER BY updated_at DESC, created_at DESC;
        """
      } else {
        sql = """
        SELECT id, article_id, text, note, tags_json, created_at, updated_at
        FROM rss_article_highlights
        WHERE article_id = ?
        ORDER BY updated_at DESC, created_at DESC;
        """
      }
      let statement = try prepareUnlocked(sql)
      defer { sqlite3_finalize(statement) }
      if let articleID { bind(articleID, at: 1, to: statement) }
      var output: [RSSArticleHighlight] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(try decodeHighlight(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func mediaAssets(articleID: String? = nil) throws -> [RSSMediaAsset] {
    try withLock {
      let sql: String
      if articleID == nil {
        sql = """
        SELECT article_id, remote_url, relative_path, content_type, byte_count, archived_at
        FROM rss_media_assets
        ORDER BY archived_at DESC, article_id ASC, remote_url ASC;
        """
      } else {
        sql = """
        SELECT article_id, remote_url, relative_path, content_type, byte_count, archived_at
        FROM rss_media_assets
        WHERE article_id = ?
        ORDER BY remote_url ASC;
        """
      }
      let statement = try prepareUnlocked(sql)
      defer { sqlite3_finalize(statement) }
      if let articleID { bind(articleID, at: 1, to: statement) }
      var output: [RSSMediaAsset] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        output.append(try decodeMediaAsset(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func upsertFeed(_ feed: RSSFeed) throws {
    try withLock { try upsertFeedUnlocked(feed) }
  }

  func upsertFeeds(_ feeds: [RSSFeed]) throws {
    guard !feeds.isEmpty else { return }
    try withLock {
      try transactionUnlocked {
        for feed in feeds { try upsertFeedUnlocked(feed) }
      }
    }
  }

  func upsertArticles(_ articles: [RSSArticle]) throws {
    guard !articles.isEmpty else { return }
    try withLock {
      try transactionUnlocked {
        for article in articles { try upsertArticleUnlocked(article) }
      }
    }
  }

  func upsertMediaAssets(_ assets: [RSSMediaAsset]) throws {
    guard !assets.isEmpty else { return }
    try withLock {
      try transactionUnlocked {
        for asset in assets { try upsertMediaAssetUnlocked(asset) }
      }
    }
  }

  /// Replaces the compatibility JSON snapshot in one SQLite transaction.
  ///
  /// The old migration wrote each table independently. A process stop between
  /// those writes made the database look migrated even when highlights or
  /// media were still missing. Keeping the delete and all inserts inside the
  /// same transaction makes the migration retryable after any interruption.
  func replaceSnapshot(_ snapshot: RSSReaderSnapshot) throws {
    try withLock {
      try transactionUnlocked {
        try executeUnlocked("DELETE FROM rss_feeds;")
        try executeUnlocked("DELETE FROM rss_articles_fts;")
        for feed in snapshot.feeds { try upsertFeedUnlocked(feed) }
        for article in snapshot.articles { try upsertArticleUnlocked(article) }
        for highlight in snapshot.highlights { try saveHighlightUnlocked(highlight) }
        for asset in snapshot.mediaAssets { try upsertMediaAssetUnlocked(asset) }
      }
    }
  }

  func eligibleArticleIDsForPruning(before cutoff: Date) throws -> Set<String> {
    try withLock {
      let statement = try prepareUnlocked("""
      SELECT a.id
      FROM rss_articles AS a
      WHERE COALESCE(a.published_at, a.fetched_at) < ?
        AND a.read_at IS NOT NULL
        AND a.is_starred = 0
        AND NOT EXISTS (
          SELECT 1 FROM rss_article_highlights AS h WHERE h.article_id = a.id
        );
      """)
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
      var output = Set<String>()
      while sqlite3_step(statement) == SQLITE_ROW {
        if let articleID = text(statement, 0) { output.insert(articleID) }
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func deleteArticles(ids: Set<String>) throws {
    guard !ids.isEmpty else { return }
    try withLock {
      try transactionUnlocked {
        let statement = try prepareUnlocked("DELETE FROM rss_articles WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        for id in ids {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          bind(id, at: 1, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
        }
        try executeUnlocked("DELETE FROM rss_articles_fts WHERE article_id NOT IN (SELECT id FROM rss_articles);")
      }
    }
  }

  func upsertFeedAndArticles(_ feed: RSSFeed, articles: [RSSArticle]) throws {
    try withLock {
      try transactionUnlocked {
        try upsertFeedUnlocked(feed)
        // A feed response is usually a rolling window, not a complete history.
        // Items absent from this response therefore remain in the local archive.
        for article in articles { try upsertArticleUnlocked(article) }
      }
    }
  }

  func updateReadStates(_ states: [(articleID: String, readAt: Date?)]) throws {
    guard !states.isEmpty else { return }
    try withLock {
      try transactionUnlocked {
        let statement = try prepareUnlocked("UPDATE rss_articles SET read_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        for state in states {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          bindOptional(state.readAt?.timeIntervalSince1970, at: 1, to: statement)
          bind(state.articleID, at: 2, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
        }
      }
    }
  }

  func deleteFeed(id: UUID) throws {
    try withLock {
      try transactionUnlocked {
        let statement = try prepareUnlocked("DELETE FROM rss_feeds WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
        try executeUnlocked("DELETE FROM rss_articles_fts WHERE article_id NOT IN (SELECT id FROM rss_articles);")
      }
    }
  }

  func restoreFeed(
    _ feed: RSSFeed,
    articles: [RSSArticle],
    highlights: [RSSArticleHighlight],
    mediaAssets: [RSSMediaAsset] = []
  ) throws {
    try withLock {
      try transactionUnlocked {
        try upsertFeedUnlocked(feed)
        for article in articles { try upsertArticleUnlocked(article) }
        for highlight in highlights { try saveHighlightUnlocked(highlight) }
        for asset in mediaAssets { try upsertMediaAssetUnlocked(asset) }
      }
    }
  }

  func updateRead(articleID: String, readAt: Date?) throws {
    try withLock {
      let statement = try prepareUnlocked("UPDATE rss_articles SET read_at = ? WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      bindOptional(readAt?.timeIntervalSince1970, at: 1, to: statement)
      bind(articleID, at: 2, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
    }
  }

  func updateRead(articleIDs: Set<String>, readAt: Date) throws {
    guard !articleIDs.isEmpty else { return }
    try withLock {
      try transactionUnlocked {
        let statement = try prepareUnlocked("UPDATE rss_articles SET read_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        for articleID in articleIDs {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          sqlite3_bind_double(statement, 1, readAt.timeIntervalSince1970)
          bind(articleID, at: 2, to: statement)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
        }
      }
    }
  }

  func updateStarred(articleID: String, isStarred: Bool) throws {
    try withLock {
      let statement = try prepareUnlocked("UPDATE rss_articles SET is_starred = ? WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int(statement, 1, isStarred ? 1 : 0)
      bind(articleID, at: 2, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
    }
  }

  func updateTags(articleID: String, tags: [String]) throws {
    try withLock {
      let statement = try prepareUnlocked("UPDATE rss_articles SET tags_json = ? WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      bind(json(tags), at: 1, to: statement)
      bind(articleID, at: 2, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
    }
  }

  func updateFeedHealth(_ feed: RSSFeed) throws {
    try withLock {
      let statement = try prepareUnlocked("""
      UPDATE rss_feeds SET last_updated_at = ?, last_error = ?,
        last_refresh_attempt_at = ?, refresh_failure_count = ?, next_retry_at = ?,
        last_refresh_duration = ?, etag = ?, last_modified = ?, title = ?,
        site_url = ?, icon_url = ?, last_issue_json = ? WHERE id = ?;
      """)
      defer { sqlite3_finalize(statement) }
      bindOptional(feed.lastUpdatedAt?.timeIntervalSince1970, at: 1, to: statement)
      bindOptional(feed.lastError, at: 2, to: statement)
      bindOptional(feed.lastRefreshAttemptAt?.timeIntervalSince1970, at: 3, to: statement)
      sqlite3_bind_int(statement, 4, Int32(feed.refreshFailureCount))
      bindOptional(feed.nextRetryAt?.timeIntervalSince1970, at: 5, to: statement)
      bindOptional(feed.lastRefreshDuration, at: 6, to: statement)
      bindOptional(feed.etag, at: 7, to: statement)
      bindOptional(feed.lastModified, at: 8, to: statement)
      bind(feed.title, at: 9, to: statement)
      bindOptional(feed.siteURL?.absoluteString, at: 10, to: statement)
      bindOptional(feed.iconURL?.absoluteString, at: 11, to: statement)
      bindOptional(try encodeIssue(feed.lastIssue), at: 12, to: statement)
      bind(feed.id.uuidString, at: 13, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
    }
  }

  func saveHighlight(_ highlight: RSSArticleHighlight) throws {
    try withLock {
      try saveHighlightUnlocked(highlight)
    }
  }

  func deleteHighlight(id: UUID) throws {
    try withLock {
      let statement = try prepareUnlocked("DELETE FROM rss_article_highlights WHERE id = ?;")
      defer { sqlite3_finalize(statement) }
      bind(id.uuidString, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
    }
  }

  func matchingArticleIDs(query: String) throws -> Set<String> {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    return try withLock {
      var ids = Set<String>()
      let ftsQuery = normalized
        .split(whereSeparator: { $0.isWhitespace })
        .map {
          let term = String($0).replacingOccurrences(of: "\"", with: "")
          return "\"\(term)\"*"
        }
        .joined(separator: " OR ")
      let ftsStatement = try prepareUnlocked("SELECT article_id FROM rss_articles_fts WHERE rss_articles_fts MATCH ?;")
      defer { sqlite3_finalize(ftsStatement) }
      bind(ftsQuery, at: 1, to: ftsStatement)
      while sqlite3_step(ftsStatement) == SQLITE_ROW {
        if let value = text(ftsStatement, 0) { ids.insert(value) }
      }
      try checkStatementCompletion(ftsStatement)
      // Keep this path bounded by the maintained FTS index. A wildcard LIKE
      // fallback over content_html turns every search into a full scan as the archive grows.
      return ids
    }
  }

  private let articleSelectSQL = """
  SELECT id, feed_id, title, link, cover_url, author, published_at, summary_html,
         content_html, web_page_snapshot_html, fetched_at, read_at,
         is_starred, tags_json
  FROM rss_articles
  """

  private let articleHeaderSelectSQL = """
  SELECT id, feed_id, title, link, cover_url, author, published_at,
         CASE
           WHEN TRIM(summary_html) != '' THEN SUBSTR(summary_html, 1, 8192)
           WHEN TRIM(content_html) != '' THEN SUBSTR(content_html, 1, 8192)
           ELSE SUBSTR(web_page_snapshot_html, 1, 8192)
         END AS preview_html,
         fetched_at, read_at, is_starred, tags_json
  FROM rss_articles
  """

  private func migrate(from version: Int) throws {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS rss_feeds (
          id TEXT PRIMARY KEY NOT NULL,
          title TEXT NOT NULL,
          url TEXT NOT NULL UNIQUE,
          site_url TEXT,
          icon_url TEXT,
          added_at REAL NOT NULL,
          last_updated_at REAL,
          etag TEXT,
          last_modified TEXT,
          last_error TEXT,
          last_refresh_attempt_at REAL,
          refresh_failure_count INTEGER NOT NULL DEFAULT 0,
          next_retry_at REAL,
          last_refresh_duration REAL,
          last_issue_json TEXT
        );
        CREATE TABLE IF NOT EXISTS rss_articles (
          id TEXT PRIMARY KEY NOT NULL,
          feed_id TEXT NOT NULL REFERENCES rss_feeds(id) ON DELETE CASCADE,
          title TEXT NOT NULL,
          link TEXT,
          cover_url TEXT,
          author TEXT,
          published_at REAL,
          summary_html TEXT NOT NULL DEFAULT '',
          content_html TEXT NOT NULL DEFAULT '',
          web_page_snapshot_html TEXT,
          fetched_at REAL NOT NULL,
          read_at REAL,
          is_starred INTEGER NOT NULL DEFAULT 0,
          tags_json TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX IF NOT EXISTS rss_articles_feed_idx
          ON rss_articles(feed_id, published_at DESC, fetched_at DESC);
        DROP INDEX IF EXISTS rss_articles_read_idx;
        CREATE INDEX IF NOT EXISTS rss_articles_scope_idx
          ON rss_articles(
            feed_id, read_at, is_starred, published_at DESC, fetched_at DESC
          );
        CREATE INDEX IF NOT EXISTS rss_articles_order_idx
          ON rss_articles(COALESCE(published_at, fetched_at) DESC, id ASC);
        CREATE TABLE IF NOT EXISTS rss_article_highlights (
          id TEXT PRIMARY KEY NOT NULL,
          article_id TEXT NOT NULL REFERENCES rss_articles(id) ON DELETE CASCADE,
          text TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT '',
          tags_json TEXT NOT NULL DEFAULT '[]',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS rss_article_highlights_article_idx
          ON rss_article_highlights(article_id, updated_at DESC);
        CREATE TABLE IF NOT EXISTS rss_media_assets (
          article_id TEXT NOT NULL REFERENCES rss_articles(id) ON DELETE CASCADE,
          remote_url TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          content_type TEXT,
          byte_count INTEGER NOT NULL DEFAULT 0,
          archived_at REAL NOT NULL,
          PRIMARY KEY(article_id, remote_url)
        );
        CREATE INDEX IF NOT EXISTS rss_media_assets_article_idx
          ON rss_media_assets(article_id, archived_at DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS rss_articles_fts USING fts5(
          article_id UNINDEXED,
          title,
          summary,
          content,
          tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
        if version < 2,
           try !columnExistsUnlocked(table: "rss_feeds", column: "last_issue_json") {
          try executeUnlocked("ALTER TABLE rss_feeds ADD COLUMN last_issue_json TEXT;")
        }
        if version < 2 {
          try migrateLegacyFeedIssuesUnlocked()
        }
        if version < 4,
           try !columnExistsUnlocked(table: "rss_articles", column: "web_page_snapshot_html") {
          try executeUnlocked(
            "ALTER TABLE rss_articles ADD COLUMN web_page_snapshot_html TEXT;"
          )
        }
        if version < 5,
           try !columnExistsUnlocked(table: "rss_articles", column: "cover_url") {
          try executeUnlocked(
            "ALTER TABLE rss_articles ADD COLUMN cover_url TEXT;"
          )
        }
        if version == 0 {
          try executeUnlocked("""
          INSERT OR IGNORE INTO rss_articles_fts(article_id, title, summary, content)
          SELECT id, title, summary_html, content_html FROM rss_articles;
          """)
        }
        try executeUnlocked("PRAGMA user_version = \(Self.currentSchemaVersion);")
        try executeUnlocked("COMMIT;")
      } catch {
        try? executeUnlocked("ROLLBACK;")
        throw error
      }
    }
  }

  private func upsertFeedUnlocked(_ feed: RSSFeed) throws {
    let statement = try prepareUnlocked("""
    INSERT INTO rss_feeds (
      id, title, url, site_url, icon_url, added_at, last_updated_at,
      etag, last_modified, last_error, last_refresh_attempt_at,
      refresh_failure_count, next_retry_at, last_refresh_duration, last_issue_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      title = excluded.title,
      url = excluded.url,
      site_url = excluded.site_url,
      icon_url = excluded.icon_url,
      added_at = excluded.added_at,
      last_updated_at = excluded.last_updated_at,
      etag = excluded.etag,
      last_modified = excluded.last_modified,
      last_error = excluded.last_error,
      last_refresh_attempt_at = excluded.last_refresh_attempt_at,
      refresh_failure_count = excluded.refresh_failure_count,
      next_retry_at = excluded.next_retry_at,
      last_refresh_duration = excluded.last_refresh_duration,
      last_issue_json = excluded.last_issue_json;
    """)
    defer { sqlite3_finalize(statement) }
    bind(feed.id.uuidString, at: 1, to: statement)
    bind(feed.title, at: 2, to: statement)
    bind(feed.url.absoluteString, at: 3, to: statement)
    bindOptional(feed.siteURL?.absoluteString, at: 4, to: statement)
    bindOptional(feed.iconURL?.absoluteString, at: 5, to: statement)
    sqlite3_bind_double(statement, 6, feed.addedAt.timeIntervalSince1970)
    bindOptional(feed.lastUpdatedAt?.timeIntervalSince1970, at: 7, to: statement)
    bindOptional(feed.etag, at: 8, to: statement)
    bindOptional(feed.lastModified, at: 9, to: statement)
    bindOptional(feed.lastError, at: 10, to: statement)
    bindOptional(feed.lastRefreshAttemptAt?.timeIntervalSince1970, at: 11, to: statement)
    sqlite3_bind_int(statement, 12, Int32(feed.refreshFailureCount))
    bindOptional(feed.nextRetryAt?.timeIntervalSince1970, at: 13, to: statement)
    bindOptional(feed.lastRefreshDuration, at: 14, to: statement)
    bindOptional(try encodeIssue(feed.lastIssue), at: 15, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
  }

  private func upsertArticleUnlocked(_ article: RSSArticle) throws {
    let statement = try prepareUnlocked("""
    INSERT INTO rss_articles (
      id, feed_id, title, link, cover_url, author, published_at, summary_html,
      content_html, web_page_snapshot_html, fetched_at, read_at, is_starred, tags_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      feed_id = excluded.feed_id,
      title = excluded.title,
      link = excluded.link,
      cover_url = COALESCE(excluded.cover_url, rss_articles.cover_url),
      author = excluded.author,
      published_at = excluded.published_at,
      summary_html = excluded.summary_html,
      content_html = excluded.content_html,
      web_page_snapshot_html = COALESCE(
        excluded.web_page_snapshot_html,
        rss_articles.web_page_snapshot_html
      ),
      fetched_at = excluded.fetched_at,
      read_at = excluded.read_at,
      is_starred = excluded.is_starred,
      tags_json = excluded.tags_json;
    """)
    defer { sqlite3_finalize(statement) }
    bind(article.id, at: 1, to: statement)
    bind(article.feedID.uuidString, at: 2, to: statement)
    bind(article.title, at: 3, to: statement)
    bindOptional(article.link?.absoluteString, at: 4, to: statement)
    bindOptional(article.coverURL?.absoluteString, at: 5, to: statement)
    bindOptional(article.author, at: 6, to: statement)
    bindOptional(article.publishedAt?.timeIntervalSince1970, at: 7, to: statement)
    bind(article.summaryHTML, at: 8, to: statement)
    bind(article.contentHTML, at: 9, to: statement)
    bindOptional(article.webPageSnapshotHTML, at: 10, to: statement)
    sqlite3_bind_double(statement, 11, article.fetchedAt.timeIntervalSince1970)
    bindOptional(article.readAt?.timeIntervalSince1970, at: 12, to: statement)
    sqlite3_bind_int(statement, 13, article.isStarred ? 1 : 0)
    bind(json(article.tags), at: 14, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }

    let deleteFTS = try prepareUnlocked("DELETE FROM rss_articles_fts WHERE article_id = ?;")
    bind(article.id, at: 1, to: deleteFTS)
    guard sqlite3_step(deleteFTS) == SQLITE_DONE else {
      sqlite3_finalize(deleteFTS)
      throw databaseErrorUnlocked()
    }
    sqlite3_finalize(deleteFTS)
    let insertFTS = try prepareUnlocked("INSERT INTO rss_articles_fts(article_id, title, summary, content) VALUES (?, ?, ?, ?);")
    defer { sqlite3_finalize(insertFTS) }
    bind(article.id, at: 1, to: insertFTS)
    bind(article.title, at: 2, to: insertFTS)
    bind(article.summaryHTML, at: 3, to: insertFTS)
    bind(article.contentHTML, at: 4, to: insertFTS)
    guard sqlite3_step(insertFTS) == SQLITE_DONE else { throw databaseErrorUnlocked() }
  }

  private func upsertMediaAssetUnlocked(_ asset: RSSMediaAsset) throws {
    let statement = try prepareUnlocked("""
    INSERT INTO rss_media_assets (
      article_id, remote_url, relative_path, content_type, byte_count, archived_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(article_id, remote_url) DO UPDATE SET
      relative_path = excluded.relative_path,
      content_type = excluded.content_type,
      byte_count = excluded.byte_count,
      archived_at = excluded.archived_at;
    """)
    defer { sqlite3_finalize(statement) }
    bind(asset.articleID, at: 1, to: statement)
    bind(asset.remoteURL.absoluteString, at: 2, to: statement)
    bind(asset.relativePath, at: 3, to: statement)
    bindOptional(asset.contentType, at: 4, to: statement)
    sqlite3_bind_int64(statement, 5, sqlite3_int64(asset.byteCount))
    sqlite3_bind_double(statement, 6, asset.archivedAt.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
  }

  private func saveHighlightUnlocked(_ highlight: RSSArticleHighlight) throws {
    let statement = try prepareUnlocked("""
    INSERT INTO rss_article_highlights (
      id, article_id, text, note, tags_json, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      article_id = excluded.article_id,
      text = excluded.text,
      note = excluded.note,
      tags_json = excluded.tags_json,
      updated_at = excluded.updated_at;
    """)
    defer { sqlite3_finalize(statement) }
    bind(highlight.id.uuidString, at: 1, to: statement)
    bind(highlight.articleID, at: 2, to: statement)
    bind(highlight.text, at: 3, to: statement)
    bind(highlight.note, at: 4, to: statement)
    bind(json(highlight.tags), at: 5, to: statement)
    sqlite3_bind_double(statement, 6, highlight.createdAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 7, highlight.updatedAt.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
  }

  private func decodeFeed(_ statement: OpaquePointer?) throws -> RSSFeed {
    let legacyError = text(statement, 9)
    let lastRefreshAttemptAt = optionalDate(statement, 10)
    let decodedIssue = decodeIssue(text(statement, 14))
    let migratedIssue = decodedIssue ?? legacyError.map { message in
      RSSFeedIssue(
        stage: .transport,
        category: .unknown,
        retryStrategy: .automatic,
        userMessage: message,
        technicalDetail: "由旧版 SQLite last_error 迁移",
        occurredAt: lastRefreshAttemptAt ?? Date()
      )
    }
    return RSSFeed(
      id: try requiredUUID(statement, 0, field: "rss_feeds.id"),
      title: text(statement, 1) ?? "未命名订阅",
      url: try requiredURL(statement, 2, field: "rss_feeds.url"),
      siteURL: optionalURL(statement, 3),
      iconURL: optionalURL(statement, 4),
      addedAt: date(statement, 5),
      lastUpdatedAt: optionalDate(statement, 6),
      etag: text(statement, 7),
      lastModified: text(statement, 8),
      lastError: legacyError,
      lastIssue: migratedIssue,
      lastRefreshAttemptAt: lastRefreshAttemptAt,
      refreshFailureCount: max(0, Int(sqlite3_column_int(statement, 11))),
      nextRetryAt: optionalDate(statement, 12),
      lastRefreshDuration: optionalDouble(statement, 13)
    )
  }

  private func decodeArticle(_ statement: OpaquePointer?) throws -> RSSArticle {
    RSSArticle(
      id: text(statement, 0) ?? "",
      feedID: try requiredUUID(statement, 1, field: "rss_articles.feed_id"),
      title: text(statement, 2) ?? "未命名文章",
      link: optionalURL(statement, 3),
      coverURL: optionalURL(statement, 4),
      author: text(statement, 5),
      publishedAt: optionalDate(statement, 6),
      summaryHTML: text(statement, 7) ?? "",
      contentHTML: text(statement, 8) ?? "",
      webPageSnapshotHTML: text(statement, 9),
      fetchedAt: date(statement, 10),
      readAt: optionalDate(statement, 11),
      isStarred: sqlite3_column_int(statement, 12) != 0,
      tags: decodeStringArray(text(statement, 13))
    )
  }

  private func decodeArticleHeader(_ statement: OpaquePointer?) throws -> RSSArticleHeader {
    RSSArticleHeader(
      id: text(statement, 0) ?? "",
      feedID: try requiredUUID(statement, 1, field: "rss_articles.feed_id"),
      title: text(statement, 2) ?? "未命名文章",
      link: optionalURL(statement, 3),
      coverURL: optionalURL(statement, 4),
      author: text(statement, 5),
      publishedAt: optionalDate(statement, 6),
      readableSummary: RSSHTMLTextSanitizer.previewText(from: text(statement, 7) ?? ""),
      fetchedAt: date(statement, 8),
      readAt: optionalDate(statement, 9),
      isStarred: sqlite3_column_int(statement, 10) != 0,
      tags: decodeStringArray(text(statement, 11))
    )
  }

  private func decodeHighlight(_ statement: OpaquePointer?) throws -> RSSArticleHighlight {
    RSSArticleHighlight(
      id: try requiredUUID(statement, 0, field: "rss_article_highlights.id"),
      articleID: text(statement, 1) ?? "",
      text: text(statement, 2) ?? "",
      note: text(statement, 3) ?? "",
      tags: decodeStringArray(text(statement, 4)),
      createdAt: date(statement, 5),
      updatedAt: date(statement, 6)
    )
  }

  private func decodeMediaAsset(_ statement: OpaquePointer?) throws -> RSSMediaAsset {
    guard let remoteURL = optionalURL(statement, 1) else {
      throw RSSReaderError.persistence("RSS 媒体缓存包含无效远程地址")
    }
    return RSSMediaAsset(
      articleID: text(statement, 0) ?? "",
      remoteURL: remoteURL,
      relativePath: text(statement, 2) ?? "",
      contentType: text(statement, 3),
      byteCount: max(0, Int(sqlite3_column_int64(statement, 4))),
      archivedAt: date(statement, 5)
    )
  }

  private func decodeStringArray(_ value: String?) -> [String] {
    guard let value, let data = value.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return RSSArticle.normalizedTags(decoded)
  }

  private func json(_ values: [String]) -> String {
    guard let data = try? JSONEncoder().encode(values), let value = String(data: data, encoding: .utf8)
    else { return "[]" }
    return value
  }

  private func encodeIssue(_ issue: RSSFeedIssue?) throws -> String? {
    guard let issue else { return nil }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(issue)
    guard let value = String(data: data, encoding: .utf8) else {
      throw RSSReaderError.persistence("RSS 错误状态无法编码")
    }
    return value
  }

  private func decodeIssue(_ value: String?) -> RSSFeedIssue? {
    guard let value, let data = value.data(using: .utf8) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try? decoder.decode(RSSFeedIssue.self, from: data)
  }

  private func columnExistsUnlocked(table: String, column: String) throws -> Bool {
    let statement = try prepareUnlocked("PRAGMA table_info(\(table));")
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if text(statement, 1)?.caseInsensitiveCompare(column) == .orderedSame {
        return true
      }
    }
    try checkStatementCompletion(statement)
    return false
  }

  private func migrateLegacyFeedIssuesUnlocked() throws {
    let selectStatement = try prepareUnlocked("""
    SELECT id, last_error, last_refresh_attempt_at
    FROM rss_feeds
    WHERE last_issue_json IS NULL AND last_error IS NOT NULL AND last_error != '';
    """)
    var migratedValues: [(id: String, issueJSON: String)] = []
    while sqlite3_step(selectStatement) == SQLITE_ROW {
      guard let id = text(selectStatement, 0),
            let message = text(selectStatement, 1)
      else { continue }
      let issue = RSSFeedIssue(
        stage: .transport,
        category: .unknown,
        retryStrategy: .automatic,
        userMessage: message,
        technicalDetail: "由旧版 SQLite last_error 迁移",
        occurredAt: optionalDate(selectStatement, 2) ?? Date()
      )
      if let issueJSON = try encodeIssue(issue) {
        migratedValues.append((id, issueJSON))
      }
    }
    try checkStatementCompletion(selectStatement)
    sqlite3_finalize(selectStatement)

    guard !migratedValues.isEmpty else { return }
    let updateStatement = try prepareUnlocked(
      "UPDATE rss_feeds SET last_issue_json = ? WHERE id = ?;"
    )
    defer { sqlite3_finalize(updateStatement) }
    for value in migratedValues {
      sqlite3_reset(updateStatement)
      sqlite3_clear_bindings(updateStatement)
      bind(value.issueJSON, at: 1, to: updateStatement)
      bind(value.id, at: 2, to: updateStatement)
      guard sqlite3_step(updateStatement) == SQLITE_DONE else {
        throw databaseErrorUnlocked()
      }
    }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func transactionUnlocked(_ body: () throws -> Void) throws {
    try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
    do {
      try body()
      try executeUnlocked("COMMIT;")
    } catch {
      try? executeUnlocked("ROLLBACK;")
      throw error
    }
  }

  private func execute(_ sql: String) throws {
    try withLock { try executeUnlocked(sql) }
  }

  private func executeUnlocked(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<Int8>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message: String
      if let errorMessage {
        message = String(cString: errorMessage)
      } else {
        message = databaseErrorUnlocked().localizedDescription
      }
      sqlite3_free(errorMessage)
      throw RSSReaderError.persistence(message)
    }
  }

  private func scalarInt(_ sql: String) throws -> Int {
    try withLock { try scalarIntUnlocked(sql) }
  }

  private func scalarIntUnlocked(_ sql: String) throws -> Int {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else { throw databaseErrorUnlocked() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func prepareUnlocked(_ sql: String) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw databaseErrorUnlocked()
    }
    return statement
  }

  private func checkStatementCompletion(_ statement: OpaquePointer?) throws {
    let result = sqlite3_errcode(handle)
    guard result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE else {
      throw databaseErrorUnlocked()
    }
    _ = statement
  }

  private func databaseErrorUnlocked() -> RSSReaderError {
    RSSReaderError.persistence(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 操作失败")
  }

  private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
    _ = value.withCString { pointer in
      sqlite3_bind_text(statement, index, pointer, -1, rssSQLiteTransient)
    }
  }

  private func bindOptional(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    bind(value, at: index, to: statement)
  }

  private func bindOptional(_ value: Double?, at index: Int32, to statement: OpaquePointer?) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    sqlite3_bind_double(statement, index, value)
  }

  private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
  }

  private func date(_ statement: OpaquePointer?, _ index: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
  }

  private func optionalDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : date(statement, index)
  }

  private func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
  }

  private func optionalURL(_ statement: OpaquePointer?, _ index: Int32) -> URL? {
    text(statement, index).flatMap(URL.init(string:))
  }

  private func requiredURL(_ statement: OpaquePointer?, _ index: Int32, field: String) throws -> URL {
    guard let value = optionalURL(statement, index) else {
      throw RSSReaderError.persistence("\(field) 缺少有效 URL")
    }
    return value
  }

  private func requiredUUID(_ statement: OpaquePointer?, _ index: Int32, field: String) throws -> UUID {
    guard let value = text(statement, index), let uuid = UUID(uuidString: value) else {
      throw RSSReaderError.persistence("\(field) 缺少有效 UUID")
    }
    return uuid
  }
}
