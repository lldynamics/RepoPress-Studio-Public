import Foundation
import SQLite3

extension RSSReaderDatabase {
  func upsertFeedUnlocked(_ feed: RSSFeed) throws {
    let statement = try prepareUnlocked(
      """
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

  func upsertArticleUnlocked(_ article: RSSArticle) throws {
    let statement = try prepareUnlocked(
      """
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

    try reindexArticleFullTextUnlocked(articleID: article.id)
  }

  func upsertMediaAssetUnlocked(_ asset: RSSMediaAsset) throws {
    let statement = try prepareUnlocked(
      """
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

  func saveHighlightUnlocked(_ highlight: RSSArticleHighlight) throws {
    let statement = try prepareUnlocked(
      """
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

  func decodeFeed(_ statement: OpaquePointer?) throws -> RSSFeed {
    let legacyError = text(statement, 9)
    let lastRefreshAttemptAt = optionalDate(statement, 10)
    let decodedIssue = decodeIssue(text(statement, 14))
    let migratedIssue =
      decodedIssue
      ?? legacyError.map { message in
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

  func decodeArticle(_ statement: OpaquePointer?) throws -> RSSArticle {
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

  func decodeArticleHeader(_ statement: OpaquePointer?) throws -> RSSArticleHeader {
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

  func decodeHighlight(_ statement: OpaquePointer?) throws -> RSSArticleHighlight {
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

  func decodeMediaAsset(_ statement: OpaquePointer?) throws -> RSSMediaAsset {
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

  func decodeStringArray(_ value: String?) -> [String] {
    guard let value, let data = value.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return RSSArticle.normalizedTags(decoded)
  }

  func json(_ values: [String]) -> String {
    guard let data = try? JSONEncoder().encode(values),
      let value = String(data: data, encoding: .utf8)
    else { return "[]" }
    return value
  }

  func encodeIssue(_ issue: RSSFeedIssue?) throws -> String? {
    guard let issue else { return nil }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(issue)
    guard let value = String(data: data, encoding: .utf8) else {
      throw RSSReaderError.persistence("RSS 错误状态无法编码")
    }
    return value
  }

  func decodeIssue(_ value: String?) -> RSSFeedIssue? {
    guard let value, let data = value.data(using: .utf8) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try? decoder.decode(RSSFeedIssue.self, from: data)
  }
}
