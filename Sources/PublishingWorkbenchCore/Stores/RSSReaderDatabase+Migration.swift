import Foundation
import SQLite3

extension RSSReaderDatabase {
  func migrate(from version: Int) throws {
    guard version <= Self.currentSchemaVersion else {
      throw RSSReaderError.persistence(
        "RSS SQLite 缓存版本 \(version) 高于当前支持版本 \(Self.currentSchemaVersion)"
      )
    }
    try withLock {
      guard version < Self.currentSchemaVersion else {
        try validateSchemaContractUnlocked()
        return
      }
      try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
      do {
        try executeUnlocked(
          """
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
          CREATE TABLE IF NOT EXISTS rss_article_full_text (
            article_id TEXT PRIMARY KEY NOT NULL REFERENCES rss_articles(id) ON DELETE CASCADE,
            status TEXT NOT NULL CHECK (status IN ('ready', 'rejected', 'failed')),
            content_html TEXT NOT NULL DEFAULT '',
            plain_text TEXT NOT NULL DEFAULT '',
            source_url TEXT,
            resolved_url TEXT,
            extractor_identifier TEXT NOT NULL DEFAULT '',
            extractor_version TEXT NOT NULL DEFAULT '',
            source_etag TEXT,
            source_last_modified TEXT,
            source_content_hash TEXT,
            confidence REAL NOT NULL DEFAULT 0.0
              CHECK (confidence >= 0.0 AND confidence <= 1.0),
            attempted_at REAL NOT NULL,
            retry_after REAL,
            failure_message TEXT
          );
          CREATE INDEX IF NOT EXISTS rss_article_full_text_status_idx
            ON rss_article_full_text(status, attempted_at DESC);
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
          try !columnExistsUnlocked(table: "rss_feeds", column: "last_issue_json")
        {
          try executeUnlocked("ALTER TABLE rss_feeds ADD COLUMN last_issue_json TEXT;")
        }
        if version < 2 {
          try migrateLegacyFeedIssuesUnlocked()
        }
        if version < 4,
          try !columnExistsUnlocked(table: "rss_articles", column: "web_page_snapshot_html")
        {
          try executeUnlocked(
            "ALTER TABLE rss_articles ADD COLUMN web_page_snapshot_html TEXT;"
          )
        }
        if version < 5,
          try !columnExistsUnlocked(table: "rss_articles", column: "cover_url")
        {
          try executeUnlocked(
            "ALTER TABLE rss_articles ADD COLUMN cover_url TEXT;"
          )
        }
        if version == 0 {
          try executeUnlocked(
            """
            INSERT OR IGNORE INTO rss_articles_fts(article_id, title, summary, content)
            SELECT id, title, summary_html, content_html FROM rss_articles;
            """)
        }
        try validateSchemaContractUnlocked()
        try validateMigrationIntegrityUnlocked()
        try executeUnlocked("PRAGMA user_version = \(Self.currentSchemaVersion);")
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }

  func validateSchemaContractUnlocked() throws {
    let requiredTables = [
      "rss_feeds",
      "rss_articles",
      "rss_article_full_text",
      "rss_article_highlights",
      "rss_media_assets",
      "rss_articles_fts",
    ]
    let tableList = requiredTables.map { "'\($0)'" }.joined(separator: ", ")
    let tableCount = try scalarIntUnlocked(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN (\(tableList));"
    )
    guard tableCount == requiredTables.count else {
      throw RSSReaderError.persistence("RSS 数据库结构不完整：缺少必需数据表")
    }

    let requiredIndexes = [
      "rss_article_full_text_status_idx",
      "rss_articles_feed_idx",
      "rss_articles_scope_idx",
      "rss_articles_order_idx",
      "rss_article_highlights_article_idx",
      "rss_media_assets_article_idx",
    ]
    let indexList = requiredIndexes.map { "'\($0)'" }.joined(separator: ", ")
    let indexCount = try scalarIntUnlocked(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN (\(indexList));"
    )
    guard indexCount == requiredIndexes.count else {
      throw RSSReaderError.persistence("RSS 数据库结构不完整：缺少必需索引")
    }

    let requiredColumns = [
      ("rss_feeds", "last_issue_json"),
      ("rss_articles", "cover_url"),
      ("rss_articles", "web_page_snapshot_html"),
      ("rss_article_full_text", "status"),
      ("rss_article_full_text", "content_html"),
      ("rss_article_full_text", "plain_text"),
      ("rss_article_full_text", "source_url"),
      ("rss_article_full_text", "resolved_url"),
      ("rss_article_full_text", "extractor_identifier"),
      ("rss_article_full_text", "extractor_version"),
      ("rss_article_full_text", "source_etag"),
      ("rss_article_full_text", "source_last_modified"),
      ("rss_article_full_text", "source_content_hash"),
      ("rss_article_full_text", "confidence"),
      ("rss_article_full_text", "attempted_at"),
      ("rss_article_full_text", "retry_after"),
      ("rss_article_full_text", "failure_message"),
    ]
    for (table, column) in requiredColumns
    where try !columnExistsUnlocked(table: table, column: column) {
      throw RSSReaderError.persistence("RSS 数据库结构不完整：\(table) 缺少 \(column) 列")
    }
  }

  private func validateMigrationIntegrityUnlocked() throws {
    let quickCheck = try prepareUnlocked("PRAGMA quick_check;")
    defer { sqlite3_finalize(quickCheck) }
    guard sqlite3_step(quickCheck) == SQLITE_ROW,
      text(quickCheck, 0)?.lowercased() == "ok",
      sqlite3_step(quickCheck) == SQLITE_DONE
    else {
      throw RSSReaderError.persistence(
        text(quickCheck, 0) ?? "RSS 数据库迁移后的 quick_check 未通过"
      )
    }

    let foreignKeyCheck = try prepareUnlocked("PRAGMA foreign_key_check;")
    defer { sqlite3_finalize(foreignKeyCheck) }
    guard sqlite3_step(foreignKeyCheck) == SQLITE_DONE else {
      throw RSSReaderError.persistence("RSS 数据库迁移后存在外键约束错误")
    }
  }
}
