import Foundation
import SQLite3

extension RSSReaderDatabase {
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
      let statement = try prepareUnlocked(
        """
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
        try executeUnlocked(
          "DELETE FROM rss_articles_fts WHERE article_id NOT IN (SELECT id FROM rss_articles);")
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
        try executeUnlocked(
          "DELETE FROM rss_articles_fts WHERE article_id NOT IN (SELECT id FROM rss_articles);")
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
      let statement = try prepareUnlocked(
        """
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
      let ftsQuery =
        normalized
        .split(whereSeparator: { $0.isWhitespace })
        .map {
          let term = String($0).replacingOccurrences(of: "\"", with: "")
          return "\"\(term)\"*"
        }
        .joined(separator: " OR ")
      let ftsStatement = try prepareUnlocked(
        "SELECT article_id FROM rss_articles_fts WHERE rss_articles_fts MATCH ?;")
      defer { sqlite3_finalize(ftsStatement) }
      bind(ftsQuery, at: 1, to: ftsStatement)
      while sqlite3_step(ftsStatement) == SQLITE_ROW {
        try Task.checkCancellation()
        if let value = text(ftsStatement, 0) { ids.insert(value) }
      }
      try checkStatementCompletion(ftsStatement)
      // Keep this path bounded by the maintained FTS index. A wildcard LIKE
      // fallback over content_html turns every search into a full scan as the archive grows.
      return ids
    }
  }

}
