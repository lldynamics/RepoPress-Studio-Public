import Foundation
import SQLite3

private let rssArticleSelectSQL = """
  SELECT id, feed_id, title, link, cover_url, author, published_at, summary_html,
         content_html, web_page_snapshot_html, fetched_at, read_at,
         is_starred, tags_json
  FROM rss_articles
  """

private let rssArticleHeaderSelectSQL = """
  SELECT id, feed_id, title, link, cover_url, author, published_at,
         CASE
           WHEN TRIM(summary_html) != '' THEN SUBSTR(summary_html, 1, 8192)
           WHEN TRIM(content_html) != '' THEN SUBSTR(content_html, 1, 8192)
           ELSE SUBSTR(web_page_snapshot_html, 1, 8192)
         END AS preview_html,
         fetched_at, read_at, is_starred, tags_json
  FROM rss_articles
  """

extension RSSReaderDatabase {
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
      let statement = try prepareUnlocked(
        """
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
      let statement = try prepareUnlocked(
        rssArticleSelectSQL + " ORDER BY COALESCE(published_at, fetched_at) DESC, id ASC;")
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
    try articleHeaders(limit: nil, offset: 0)
  }

  /// Reads only the lightweight article projection required by list surfaces.
  /// Keeping the limit/offset at the SQL boundary avoids materialising every
  /// row while the first RSS window is being shown.
  func articleHeaders(limit: Int?, offset: Int = 0) throws -> [RSSArticleHeader] {
    try withLock {
      let normalizedOffset = max(0, offset)
      let pagination =
        if let limit {
          " LIMIT \(max(0, limit)) OFFSET \(normalizedOffset);"
        } else {
          " LIMIT -1 OFFSET \(normalizedOffset);"
        }
      let statement = try prepareUnlocked(
        rssArticleHeaderSelectSQL
          + " ORDER BY COALESCE(published_at, fetched_at) DESC, id ASC"
          + pagination
      )
      defer { sqlite3_finalize(statement) }
      var output: [RSSArticleHeader] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        try Task.checkCancellation()
        output.append(try decodeArticleHeader(statement))
      }
      try checkStatementCompletion(statement)
      return output
    }
  }

  func articleHeader(id: String) throws -> RSSArticleHeader? {
    try withLock {
      let statement = try prepareUnlocked(rssArticleHeaderSelectSQL + " WHERE id = ? LIMIT 1;")
      defer { sqlite3_finalize(statement) }
      bind(id, at: 1, to: statement)
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        return try decodeArticleHeader(statement)
      case SQLITE_DONE:
        return nil
      default:
        throw databaseErrorUnlocked()
      }
    }
  }

  func articleHeaderCount() throws -> Int {
    try withLock {
      try scalarIntUnlocked("SELECT COUNT(*) FROM rss_articles;")
    }
  }

  func unreadArticleCount(feedID: UUID? = nil) throws -> Int {
    try withLock {
      if let feedID {
        let statement = try prepareUnlocked(
          "SELECT COUNT(*) FROM rss_articles WHERE feed_id = ? AND read_at IS NULL;"
        )
        defer { sqlite3_finalize(statement) }
        bind(feedID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
          throw databaseErrorUnlocked()
        }
        return Int(sqlite3_column_int64(statement, 0))
      }
      return try scalarIntUnlocked("SELECT COUNT(*) FROM rss_articles WHERE read_at IS NULL;")
    }
  }

  func article(id: String) throws -> RSSArticle? {
    try withLock {
      let statement = try prepareUnlocked(rssArticleSelectSQL + " WHERE id = ? LIMIT 1;")
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
      let statement = try prepareUnlocked(rssArticleSelectSQL + " WHERE id = ? LIMIT 1;")
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
        rssArticleSelectSQL
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

}
