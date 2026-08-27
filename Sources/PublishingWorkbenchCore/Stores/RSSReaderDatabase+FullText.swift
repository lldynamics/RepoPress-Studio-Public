import Foundation
import SQLite3

extension RSSReaderDatabase {
  /// Returns the independent original-page extraction record for an article.
  /// RSSArticle's feed payload is intentionally not consulted or modified.
  func fullTextRecord(articleID: String) throws -> RSSArticleFullTextRecord? {
    try withLock {
      let statement = try prepareUnlocked(
        """
        SELECT article_id, status, content_html, plain_text, source_url, resolved_url,
               extractor_identifier, extractor_version, source_etag, source_last_modified,
               source_content_hash, confidence, attempted_at, retry_after, failure_message
        FROM rss_article_full_text
        WHERE article_id = ?
        LIMIT 1;
        """
      )
      defer { sqlite3_finalize(statement) }
      bind(articleID, at: 1, to: statement)
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        return try decodeFullTextRecord(statement)
      case SQLITE_DONE:
        return nil
      default:
        throw databaseErrorUnlocked()
      }
    }
  }

  /// Inserts or replaces an extraction record without changing the RSS
  /// article row. The foreign key makes accidental orphan cache records
  /// impossible and deletion of an article cascades to this record.
  func upsertFullTextRecord(_ record: RSSArticleFullTextRecord) throws {
    try withLock {
      try transactionUnlocked {
        try upsertFullTextRecordUnlocked(record)
      }
    }
  }

  func upsertFullTextRecordUnlocked(_ record: RSSArticleFullTextRecord) throws {
    let statement = try prepareUnlocked(
      """
      INSERT INTO rss_article_full_text (
        article_id, status, content_html, plain_text, source_url, resolved_url,
        extractor_identifier, extractor_version, source_etag, source_last_modified,
        source_content_hash, confidence, attempted_at, retry_after, failure_message
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(article_id) DO UPDATE SET
        status = excluded.status,
        content_html = excluded.content_html,
        plain_text = excluded.plain_text,
        source_url = excluded.source_url,
        resolved_url = excluded.resolved_url,
        extractor_identifier = excluded.extractor_identifier,
        extractor_version = excluded.extractor_version,
        source_etag = excluded.source_etag,
        source_last_modified = excluded.source_last_modified,
        source_content_hash = excluded.source_content_hash,
        confidence = excluded.confidence,
        attempted_at = excluded.attempted_at,
        retry_after = excluded.retry_after,
        failure_message = excluded.failure_message;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(record.articleID, at: 1, to: statement)
    bind(record.status.rawValue, at: 2, to: statement)
    bind(record.contentHTML, at: 3, to: statement)
    bind(record.plainText, at: 4, to: statement)
    bindOptional(record.sourceURL?.absoluteString, at: 5, to: statement)
    bindOptional(record.resolvedURL?.absoluteString, at: 6, to: statement)
    bind(record.extractorIdentifier, at: 7, to: statement)
    bind(record.extractorVersion, at: 8, to: statement)
    bindOptional(record.sourceETag, at: 9, to: statement)
    bindOptional(record.sourceLastModified, at: 10, to: statement)
    bindOptional(record.sourceContentHash, at: 11, to: statement)
    sqlite3_bind_double(statement, 12, record.confidence)
    sqlite3_bind_double(statement, 13, record.attemptedAt.timeIntervalSince1970)
    bindOptional(record.retryAfter?.timeIntervalSince1970, at: 14, to: statement)
    bindOptional(record.failureMessage, at: 15, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
    try reindexArticleFullTextUnlocked(articleID: record.articleID)
  }

  /// Removes the independent extraction record, if one exists.
  func deleteFullTextRecord(articleID: String) throws {
    try withLock {
      try transactionUnlocked {
        let statement = try prepareUnlocked(
          "DELETE FROM rss_article_full_text WHERE article_id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bind(articleID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseErrorUnlocked() }
        try reindexArticleFullTextUnlocked(articleID: articleID)
      }
    }
  }

  func fullTextRecords(feedID: UUID) throws -> [RSSArticleFullTextRecord] {
    try withLock {
      let statement = try prepareUnlocked(
        """
        SELECT full_text.article_id, full_text.status, full_text.content_html,
               full_text.plain_text, full_text.source_url, full_text.resolved_url,
               full_text.extractor_identifier, full_text.extractor_version,
               full_text.source_etag, full_text.source_last_modified,
               full_text.source_content_hash, full_text.confidence,
               full_text.attempted_at, full_text.retry_after, full_text.failure_message
        FROM rss_article_full_text AS full_text
        INNER JOIN rss_articles AS article ON article.id = full_text.article_id
        WHERE article.feed_id = ?
        ORDER BY full_text.attempted_at DESC;
        """
      )
      defer { sqlite3_finalize(statement) }
      bind(feedID.uuidString, at: 1, to: statement)
      var records: [RSSArticleFullTextRecord] = []
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
          records.append(try decodeFullTextRecord(statement))
        case SQLITE_DONE:
          return records
        default:
          throw databaseErrorUnlocked()
        }
      }
    }
  }

  /// Rebuilds the single FTS row from both the feed payload and an accepted
  /// extraction. Refreshing either source therefore cannot erase the other.
  func reindexArticleFullTextUnlocked(articleID: String) throws {
    let deleteStatement = try prepareUnlocked(
      "DELETE FROM rss_articles_fts WHERE article_id = ?;"
    )
    bind(articleID, at: 1, to: deleteStatement)
    guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
      sqlite3_finalize(deleteStatement)
      throw databaseErrorUnlocked()
    }
    sqlite3_finalize(deleteStatement)

    let insertStatement = try prepareUnlocked(
      """
      INSERT INTO rss_articles_fts(article_id, title, summary, content)
      SELECT article.id, article.title, article.summary_html,
             article.content_html || CASE
               WHEN full_text.status = 'ready' AND full_text.plain_text != ''
                 THEN ' ' || full_text.plain_text
               ELSE ''
             END
      FROM rss_articles AS article
      LEFT JOIN rss_article_full_text AS full_text
        ON full_text.article_id = article.id
      WHERE article.id = ?;
      """
    )
    defer { sqlite3_finalize(insertStatement) }
    bind(articleID, at: 1, to: insertStatement)
    guard sqlite3_step(insertStatement) == SQLITE_DONE else {
      throw databaseErrorUnlocked()
    }
  }

  private func decodeFullTextRecord(_ statement: OpaquePointer?) throws -> RSSArticleFullTextRecord {
    guard let articleID = text(statement, 0), !articleID.isEmpty else {
      throw RSSReaderError.persistence("RSS 全文缓存缺少文章 ID")
    }
    guard let rawStatus = text(statement, 1),
          let status = RSSArticleFullTextStatus(rawValue: rawStatus) else {
      throw RSSReaderError.persistence("RSS 全文缓存包含未知状态")
    }

    return RSSArticleFullTextRecord(
      articleID: articleID,
      status: status,
      contentHTML: text(statement, 2) ?? "",
      plainText: text(statement, 3) ?? "",
      sourceURL: try decodeOptionalURL(statement, index: 4, field: "source_url"),
      resolvedURL: try decodeOptionalURL(statement, index: 5, field: "resolved_url"),
      extractorIdentifier: text(statement, 6) ?? RSSArticleFullTextRecord.defaultExtractorIdentifier,
      extractorVersion: text(statement, 7) ?? RSSArticleFullTextRecord.defaultExtractorVersion,
      sourceETag: text(statement, 8),
      sourceLastModified: text(statement, 9),
      sourceContentHash: text(statement, 10),
      confidence: sqlite3_column_double(statement, 11),
      attemptedAt: date(statement, 12),
      retryAfter: optionalDate(statement, 13),
      failureMessage: text(statement, 14)
    )
  }

  private func decodeOptionalURL(
    _ statement: OpaquePointer?,
    index: Int32,
    field: String
  ) throws -> URL? {
    guard let value = text(statement, index) else { return nil }
    guard let url = URL(string: value), RSSNetworkURLPolicy.isSyntacticallyAllowed(url) else {
      throw RSSReaderError.persistence("RSS 全文缓存包含无效 \(field) URL")
    }
    return url
  }
}
