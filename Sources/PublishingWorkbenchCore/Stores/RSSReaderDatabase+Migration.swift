import Foundation
import SQLite3

extension RSSReaderDatabase {
  func migrate(from version: Int) throws {
    try withLock {
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
        try executeUnlocked("PRAGMA user_version = \(Self.currentSchemaVersion);")
        try executeUnlocked("COMMIT;")
      } catch {
        try rethrowAfterRollbackUnlocked(error)
      }
    }
  }
}
