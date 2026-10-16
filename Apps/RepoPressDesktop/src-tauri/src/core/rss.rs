//! Bounded, local RSS/Atom storage. Network access is deliberately kept here.
use super::{CommandError, CommandResult};
use chrono::{DateTime, Utc};
use quick_xml::{events::Event, NsReader, Reader};
use reqwest::{
    blocking::Client,
    header::{IF_MODIFIED_SINCE, IF_NONE_MATCH, LOCATION},
    StatusCode,
};
use rusqlite::{params, types::Value, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::Read,
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use url::{Host, Url};
use uuid::Uuid;

const MAX_XML: usize = 20 * 1024 * 1024;
const MAX_ITEMS: usize = 10_000;
const MAX_DISCOVERY: usize = 10;
const MAX_DEPTH: usize = 256;
const MAX_FULL_TEXT_HTML: usize = 1024 * 1024;
const MAX_FULL_TEXT_PLAIN: usize = 1024 * 1024;
const MAX_FULL_TEXT_PREFETCH_PER_REFRESH: usize = 32;
const MAX_FILTER_FACETS: usize = 1_000;
const MAX_COVER_IMAGE: usize = 2 * 1024 * 1024;
const MAX_COVER_DIMENSION: u32 = 8_192;
const MAX_COVER_PIXELS: u64 = 20_000_000;
const SCHEMA_VERSION: i64 = 4;
#[path = "rss_opml_privacy.rs"]
mod opml_privacy;
pub use opml_privacy::{RssOpmlExecution, RssOpmlReview};
#[path = "rss_feed_body.rs"]
mod feed_body;
#[path = "rss_history.rs"]
mod history;
pub use history::{
    RssHistoryCheckpointSummary, RssHistoryDiscoverInput, RssHistoryJob, RssHistoryResumeInput,
    RssHistoryRetryInput, RssHistoryStepInput,
};
const OFFLINE_TRANSLATION_FINGERPRINT_VERSION: u8 = 1;
const MAX_OFFLINE_TRANSLATION_SOURCE_BYTES: usize = 1024 * 1024;
const MAX_OFFLINE_TRANSLATION_OUTPUT_BYTES: usize = 1024 * 1024;
const MAX_OFFLINE_TRANSLATION_ENDPOINT_BYTES: usize = 4096;
const MAX_OFFLINE_TRANSLATION_MODEL_BYTES: usize = 512;
const MAX_OFFLINE_TRANSLATION_GLOSSARY_ENTRIES: usize = 128;
const MAX_OFFLINE_TRANSLATION_GLOSSARY_FIELD_BYTES: usize = 512;

type CachedFullTextRow = (
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    i64,
    i64,
    i64,
    Option<String>,
);
type DiscoveryLink = (Url, Option<String>, Option<String>);
type DiscoveryResult = (Option<String>, Vec<DiscoveryLink>);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssFeed {
    pub id: String,
    pub url: String,
    pub title: String,
    pub site_url: Option<String>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub last_refreshed_at: i64,
    pub next_refresh_at: i64,
    pub issue: Option<RssIssue>,
    pub unread_count: u32,
    pub added_at: i64,
    pub refresh_failure_count: u32,
    pub next_retry_at: Option<i64>,
}

#[cfg(test)]
mod backup_tests {
    use super::*;
    #[test]
    fn backup_rejects_future_schema() {
        let value = serde_json::json!({"schemaVersion":99,"databaseSchemaVersion":2,"feeds":[],"articles":[],"highlights":[],"readingProgress":[],"fullTextCache":[],"preferences":{},"meta":[]});
        assert_eq!(
            parse_backup(&value.to_string()).unwrap_err().code,
            "rss_backup_version_unsupported"
        );
    }
    #[test]
    fn backup_rejects_dangling_article() {
        let value = serde_json::json!({"schemaVersion":1,"databaseSchemaVersion":2,"feeds":[],"articles":[{"id":"a","feed_id":"missing","identity":"x"}],"highlights":[],"readingProgress":[],"fullTextCache":[],"preferences":{},"meta":[]});
        assert!(validate_backup(&serde_json::from_value(value).unwrap()).is_err());
    }
    #[test]
    fn backup_rejects_invalid_progress() {
        let value = serde_json::json!({"schemaVersion":1,"databaseSchemaVersion":2,"feeds":[],"articles":[{"id":"a","feed_id":"f","identity":"x"}],"highlights":[],"readingProgress":[{"article_id":"a","progress":2.0}],"fullTextCache":[],"preferences":{},"meta":[]});
        assert!(validate_backup(&serde_json::from_value(value).unwrap()).is_err());
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssIssue {
    pub stage: String,
    pub category: String,
    pub retry_strategy: String,
    pub retry_at: Option<i64>,
    pub user_message: String,
    pub technical_detail: String,
    pub occurred_at: i64,
    pub code: String,
    pub message: String,
    pub at: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssArticle {
    pub id: String,
    pub feed_id: String,
    pub guid: String,
    pub title: String,
    pub url: Option<String>,
    pub cover_url: Option<String>,
    pub author: Option<String>,
    pub summary: String,
    pub content: String,
    pub published_at: i64,
    pub fetched_at: i64,
    pub read: bool,
    pub read_at: Option<i64>,
    pub starred: bool,
    pub tags: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssArticlePage {
    pub articles: Vec<RssArticle>,
    pub total: u32,
    pub has_more: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssSnapshot {
    pub feeds: Vec<RssFeed>,
    pub unread_count: u32,
    pub starred_count: u32,
    pub authors: Vec<String>,
    pub tags: Vec<String>,
    pub fetched_at: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssPreferences {
    pub refresh_interval_seconds: u64,
    pub max_articles_per_feed: u32,
    pub refresh_interval_minutes: u32,
    pub retention_days: u32,
    pub automatic_pruning_enabled: bool,
    pub feed_body_offline_cache_enabled: bool,
    pub background_refresh_enabled: bool,
    pub background_refresh_interval_minutes: u32,
    pub automatic_mark_read_at_end_enabled: bool,
    pub automatic_full_text_extraction_enabled: bool,
    pub offline_cache_full_text_on_refresh_enabled: bool,
    pub remote_images_enabled: bool,
    pub private_network_access_enabled: bool,
    #[serde(default)]
    pub offline_translation_cache_enabled: bool,
    #[serde(default = "default_offline_translation_retention_days")]
    pub offline_translation_retention_days: u32,
    #[serde(
        default = "default_offline_translation_max_mib",
        rename = "offlineTranslationMaxMiB",
        alias = "offlineTranslationMaxMib"
    )]
    pub offline_translation_max_mib: u32,
    #[serde(default)]
    pub automatic_local_pretranslation_on_refresh_enabled: bool,
}
fn default_offline_translation_retention_days() -> u32 {
    30
}
fn default_offline_translation_max_mib() -> u32 {
    100
}

/// Input used solely to derive an opaque, local cache key. None of the source
/// text, glossary, or endpoint fields are persisted.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RssOfflineTranslationRequest {
    pub article_id: String,
    pub provider: String,
    pub endpoint: String,
    pub model: String,
    pub source_language: String,
    pub target_language: String,
    #[serde(default)]
    pub glossary: Vec<RssOfflineTranslationGlossaryEntry>,
    pub source_text: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RssOfflineTranslationGlossaryEntry {
    pub source: String,
    pub target: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RssOfflineTranslationResult {
    pub translated_text: String,
    pub detected_source_language: Option<String>,
    pub provider: String,
    pub model: String,
    pub target_language: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssOfflineTranslationRecord {
    pub article_id: String,
    pub translated_text: String,
    pub detected_source_language: Option<String>,
    pub provider: String,
    pub model: String,
    pub target_language: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub byte_size: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssOfflineTranslationCacheStatus {
    pub entry_count: u32,
    pub total_bytes: u64,
    pub max_bytes: u64,
    pub expired_count: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssOfflineTranslationCleanup {
    pub removed_count: u32,
    pub freed_bytes: u64,
    pub remaining_count: u32,
    pub remaining_bytes: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssDiscoveryCandidate {
    pub url: String,
    pub title: Option<String>,
    pub content_type: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssDiscovery {
    pub url: String,
    pub title: Option<String>,
    pub feed_url: Option<String>,
    pub candidates: Vec<RssDiscoveryCandidate>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssArticleQuery {
    pub query: Option<String>,
    pub scope: String,
    pub sort: String,
    pub feed_id: Option<String>,
    pub author: Option<String>,
    pub tag: Option<String>,
    pub offset: u32,
    pub limit: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssArticleState {
    pub read: Option<bool>,
    pub starred: Option<bool>,
    pub tags: Option<Vec<String>>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssRefreshResult {
    pub feed_id: String,
    pub fetched: u32,
    pub inserted: u32,
    pub not_modified: bool,
    pub issue: Option<RssIssue>,
    pub updated: u32,
    pub failed: bool,
    pub summary: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssOpmlImportResult {
    pub imported_count: u32,
    pub skipped_count: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssHighlight {
    pub id: String,
    pub article_id: String,
    pub text: String,
    pub note: String,
    pub tags: Vec<String>,
    pub created_at: i64,
    pub updated_at: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RssReadingProgress {
    pub article_id: String,
    pub progress: f64,
    pub revision: i64,
    pub updated_at: i64,
}
const BACKUP_MAX_BYTES: usize = 64 * 1024 * 1024;
const BACKUP_SCHEMA_VERSION: i64 = 1;
const UNDO_TTL_SECONDS: i64 = 10 * 60;
const MAX_BACKUP_ROWS: usize = MAX_ITEMS * 8;
const MAX_BACKUP_TEXT: usize = 1_048_576;
const MAX_BACKUP_HTML: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RssBackupSummary {
    pub database_schema_version: i64,
    pub feed_count: u32,
    pub article_count: u32,
    pub highlight_count: u32,
    pub indexed_article_count: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RssBackup {
    schema_version: i64,
    database_schema_version: i64,
    feeds: Vec<serde_json::Value>,
    articles: Vec<serde_json::Value>,
    highlights: Vec<serde_json::Value>,
    reading_progress: Vec<serde_json::Value>,
    full_text_cache: Vec<serde_json::Value>,
    preferences: serde_json::Value,
    meta: Vec<serde_json::Value>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct RemovedFeedUndo {
    feed_id: String,
    feeds: Vec<serde_json::Value>,
    articles: Vec<serde_json::Value>,
    highlights: Vec<serde_json::Value>,
    reading_progress: Vec<serde_json::Value>,
    full_text_cache: Vec<serde_json::Value>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct MarkReadUndo {
    applied_at: i64,
    articles: Vec<MarkReadUndoArticle>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct MarkReadUndoArticle {
    id: String,
    read: bool,
    read_at: Option<i64>,
}

pub struct RssReaderStore {
    db: Mutex<Connection>,
    path: Option<PathBuf>,
    snapshot_identity: Option<[u64; 2]>,
    history_busy: Mutex<HashSet<String>>,
    history_cancelled: Mutex<std::collections::HashMap<String, std::time::Instant>>,
    #[cfg(test)]
    test_feed_transport: Mutex<Option<std::sync::Arc<TestFeedTransport>>>,
}
impl Default for RssReaderStore {
    fn default() -> Self {
        match Self::open(None) {
            Ok(store) => store,
            Err(error) => panic!("in-memory RSS database unavailable: {error}"),
        }
    }
}

impl RssReaderStore {
    pub fn new(app_data_dir: PathBuf) -> CommandResult<Self> {
        reject_symlink(&app_data_dir)?;
        let dir = app_data_dir.join("RSSReader");
        if dir.exists() {
            reject_symlink(&dir)?;
        } else {
            fs::create_dir(&dir).map_err(|e| {
                CommandError::io("rss_storage_unavailable", "create RSS storage", e)
            })?;
        }
        set_private_dir(&dir)?;
        let file = dir.join("reader.sqlite");
        if file.exists() {
            reject_symlink(&file)?;
        }
        let store = Self::open(Some(file))?;
        if let Some(path) = &store.path {
            set_private_file(path)?;
        }
        Ok(store)
    }
    fn open(path: Option<PathBuf>) -> CommandResult<Self> {
        let connection = match path.as_ref() {
            Some(value) => Connection::open(value),
            None => Connection::open_in_memory(),
        }
        .map_err(db_err)?;
        connection
            .pragma_update(None, "foreign_keys", "ON")
            .map_err(db_err)?;
        connection
            .pragma_update(None, "journal_mode", "WAL")
            .map_err(db_err)?;
        migrate(&connection)?;
        history::recover_interrupted(&connection)?;
        #[cfg(unix)]
        let snapshot_identity = path.as_ref().and_then(|p| {
            use std::os::unix::fs::MetadataExt;
            fs::symlink_metadata(p).ok().map(|m| [m.dev(), m.ino()])
        });
        #[cfg(not(unix))]
        let snapshot_identity = None;
        Ok(Self {
            db: Mutex::new(connection),
            path,
            snapshot_identity,
            history_busy: Mutex::new(HashSet::new()),
            history_cancelled: Mutex::new(std::collections::HashMap::new()),
            #[cfg(test)]
            test_feed_transport: Mutex::new(None),
        })
    }
    /// Snapshot export uses only the existing durable connection under this mutex.
    pub(super) fn with_snapshot_source<T>(
        &self,
        action: impl FnOnce(&Connection, &Path, [u64; 2]) -> CommandResult<T>,
    ) -> CommandResult<T> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let path = self.path.as_deref().ok_or_else(|| {
            CommandError::new(
                "rss_snapshot_backup_invalid",
                "A durable RSS database is required.",
            )
        })?;
        let identity = self.snapshot_identity.ok_or_else(|| {
            CommandError::new(
                "rss_snapshot_backup_invalid",
                "A durable RSS database is required.",
            )
        })?;
        action(&connection, path, identity)
    }
    pub fn snapshot(&self) -> CommandResult<RssSnapshot> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let unread: i64 = connection
            .query_row("SELECT count(*) FROM articles WHERE read=0", [], |row| {
                row.get(0)
            })
            .map_err(db_err)?;
        let starred: i64 = connection
            .query_row("SELECT count(*) FROM articles WHERE starred=1", [], |row| {
                row.get(0)
            })
            .map_err(db_err)?;
        let mut author_statement = connection
            .prepare("SELECT DISTINCT author FROM articles WHERE author IS NOT NULL AND trim(author)<>'' ORDER BY author LIMIT ?")
            .map_err(db_err)?;
        let authors = author_statement
            .query_map([MAX_FILTER_FACETS as i64], |row| row.get::<_, String>(0))
            .map_err(db_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_err)?;
        drop(author_statement);
        let mut tag_statement = connection
            .prepare("SELECT tags FROM articles ORDER BY id")
            .map_err(db_err)?;
        let tag_rows = tag_statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(db_err)?;
        let mut tag_set = HashSet::new();
        for row in tag_rows {
            let raw = row.map_err(db_err)?;
            for tag in serde_json::from_str::<Vec<String>>(&raw).unwrap_or_default() {
                if tag_set.len() >= MAX_FILTER_FACETS {
                    break;
                }
                if !tag.is_empty() {
                    tag_set.insert(tag);
                }
            }
            if tag_set.len() >= MAX_FILTER_FACETS {
                break;
            }
        }
        let mut tags = tag_set.into_iter().collect::<Vec<_>>();
        tags.sort();
        Ok(RssSnapshot {
            feeds: load_feeds(&connection)?,
            unread_count: unread as u32,
            starred_count: starred as u32,
            authors,
            tags,
            fetched_at: now(),
        })
    }
    pub fn preferences(&self) -> CommandResult<RssPreferences> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        preferences_from(&connection)
    }
    pub fn update_preferences(
        &self,
        mut preferences: RssPreferences,
    ) -> CommandResult<RssPreferences> {
        if preferences.refresh_interval_minutes > 0 {
            preferences.refresh_interval_seconds =
                u64::from(preferences.refresh_interval_minutes) * 60;
        }
        if !(60..=21_600).contains(&preferences.refresh_interval_seconds)
            || preferences.max_articles_per_feed == 0
            || preferences.max_articles_per_feed > MAX_ITEMS as u32
            || preferences.retention_days == 0
            || preferences.retention_days > 3650
            || !(1..=3650).contains(&preferences.offline_translation_retention_days)
            || !(16..=2048).contains(&preferences.offline_translation_max_mib)
            || (preferences.automatic_local_pretranslation_on_refresh_enabled
                && !preferences.offline_translation_cache_enabled)
        {
            return Err(CommandError::new(
                "rss_preferences_invalid",
                "RSS preferences are outside supported bounds.",
            ));
        }
        preferences.refresh_interval_minutes = (preferences.refresh_interval_seconds / 60) as u32;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        set_meta(
            &tx,
            "refresh_interval",
            &preferences.refresh_interval_seconds.to_string(),
        )?;
        set_meta(
            &tx,
            "max_articles",
            &preferences.max_articles_per_feed.to_string(),
        )?;
        set_meta(
            &tx,
            "retention_days",
            &preferences.retention_days.to_string(),
        )?;
        set_meta(
            &tx,
            "automatic_pruning",
            if preferences.automatic_pruning_enabled {
                "1"
            } else {
                "0"
            },
        )?;
        set_meta(
            &tx,
            "feed_body_offline_cache",
            if preferences.feed_body_offline_cache_enabled {
                "1"
            } else {
                "0"
            },
        )?;
        for (key, enabled) in [
            ("background_refresh", preferences.background_refresh_enabled),
            (
                "automatic_mark_read_end",
                preferences.automatic_mark_read_at_end_enabled,
            ),
            (
                "automatic_full_text",
                preferences.automatic_full_text_extraction_enabled,
            ),
            (
                "offline_full_text_refresh",
                preferences.offline_cache_full_text_on_refresh_enabled,
            ),
            ("remote_images", preferences.remote_images_enabled),
        ] {
            set_meta(&tx, key, if enabled { "1" } else { "0" })?;
        }
        set_meta(
            &tx,
            "background_refresh_minutes",
            &preferences
                .background_refresh_interval_minutes
                .clamp(1, 360)
                .to_string(),
        )?;
        set_meta(
            &tx,
            "private_network_access",
            if preferences.private_network_access_enabled {
                "1"
            } else {
                "0"
            },
        )?;
        for (key, value) in [
            (
                "offline_translation_cache",
                bool_meta(preferences.offline_translation_cache_enabled),
            ),
            (
                "offline_translation_retention_days",
                preferences.offline_translation_retention_days.to_string(),
            ),
            (
                "offline_translation_max_mib",
                preferences.offline_translation_max_mib.to_string(),
            ),
            (
                "automatic_local_pretranslation_on_refresh",
                bool_meta(preferences.automatic_local_pretranslation_on_refresh_enabled),
            ),
        ] {
            set_meta(&tx, key, &value)?;
        }
        prune_expired_offline_translations(&tx, now())?;
        enforce_offline_translation_quota(
            &tx,
            "",
            "",
            0,
            offline_translation_max_bytes(&preferences),
        )?;
        // Feed bodies can be quite large.  Turning this off is also a request to
        // remove bodies that were retained under the old preference, while
        // leaving summaries intact for the normal list/detail experience.
        if !preferences.feed_body_offline_cache_enabled {
            tx.execute("UPDATE articles SET content='' WHERE content<>''", [])
                .map_err(db_err)?;
        }
        tx.commit().map_err(db_err)?;
        Ok(preferences)
    }
    pub fn get_offline_translation(
        &self,
        request: RssOfflineTranslationRequest,
    ) -> CommandResult<Option<RssOfflineTranslationRecord>> {
        validate_offline_translation_request(&request)?;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let preferences = preferences_from(&connection)?;
        if !preferences.offline_translation_cache_enabled {
            return Ok(None);
        }
        ensure_offline_translation_article(&connection, &request.article_id)?;
        let timestamp = now();
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        prune_expired_offline_translations(&tx, timestamp)?;
        let fingerprint = offline_translation_fingerprint(&request);
        let record = tx
            .query_row(
                "SELECT article_id,translated_text,detected_source_language,provider,model,target_language,created_at,expires_at,byte_size FROM offline_translation_cache WHERE article_id=? AND request_fingerprint=?",
                params![request.article_id, fingerprint],
                offline_translation_record_from_row,
            )
            .optional()
            .map_err(db_err)?;
        if record.is_some() {
            tx.execute(
                "UPDATE offline_translation_cache SET last_accessed_at=? WHERE article_id=? AND request_fingerprint=?",
                params![timestamp, request.article_id, fingerprint],
            )
            .map_err(db_err)?;
        }
        tx.commit().map_err(db_err)?;
        Ok(record)
    }
    pub fn save_offline_translation(
        &self,
        request: RssOfflineTranslationRequest,
        result: RssOfflineTranslationResult,
    ) -> CommandResult<RssOfflineTranslationRecord> {
        validate_offline_translation_request(&request)?;
        validate_offline_translation_result(&request, &result)?;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let preferences = preferences_from(&connection)?;
        if !preferences.offline_translation_cache_enabled {
            return Err(CommandError::new(
                "rss_offline_translation_cache_disabled",
                "Enable the offline translation cache before saving translations.",
            ));
        }
        ensure_offline_translation_article(&connection, &request.article_id)?;
        let max_bytes = offline_translation_max_bytes(&preferences);
        let byte_size = offline_translation_record_size(&result);
        if byte_size > max_bytes {
            return Err(CommandError::new(
                "rss_offline_translation_too_large",
                "Translated output exceeds the offline translation cache limit.",
            ));
        }
        let timestamp = now();
        let expires_at =
            timestamp + i64::from(preferences.offline_translation_retention_days) * 86_400;
        let fingerprint = offline_translation_fingerprint(&request);
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        prune_expired_offline_translations(&tx, timestamp)?;
        enforce_offline_translation_quota(
            &tx,
            &request.article_id,
            &fingerprint,
            byte_size,
            max_bytes,
        )?;
        tx.execute(
            "INSERT INTO offline_translation_cache(article_id,request_fingerprint,translated_text,detected_source_language,provider,model,target_language,created_at,last_accessed_at,expires_at,byte_size) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(article_id,request_fingerprint) DO UPDATE SET translated_text=excluded.translated_text,detected_source_language=excluded.detected_source_language,provider=excluded.provider,model=excluded.model,target_language=excluded.target_language,created_at=excluded.created_at,last_accessed_at=excluded.last_accessed_at,expires_at=excluded.expires_at,byte_size=excluded.byte_size",
            params![request.article_id, fingerprint, result.translated_text, result.detected_source_language, result.provider, result.model, result.target_language, timestamp, timestamp, expires_at, byte_size as i64],
        )
        .map_err(db_err)?;
        tx.commit().map_err(db_err)?;
        Ok(RssOfflineTranslationRecord {
            article_id: request.article_id,
            translated_text: result.translated_text,
            detected_source_language: result.detected_source_language,
            provider: result.provider,
            model: result.model,
            target_language: result.target_language,
            created_at: timestamp,
            expires_at,
            byte_size,
        })
    }
    pub fn delete_offline_translation(
        &self,
        request: RssOfflineTranslationRequest,
    ) -> CommandResult<()> {
        validate_offline_translation_request(&request)?;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        ensure_offline_translation_article(&connection, &request.article_id)?;
        connection
            .execute(
                "DELETE FROM offline_translation_cache WHERE article_id=? AND request_fingerprint=?",
                params![request.article_id, offline_translation_fingerprint(&request)],
            )
            .map_err(db_err)?;
        Ok(())
    }
    pub fn offline_translation_cache_status(
        &self,
    ) -> CommandResult<RssOfflineTranslationCacheStatus> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let timestamp = now();
        let (entry_count, total_bytes, expired_count): (i64, i64, i64) = connection
            .query_row(
                "SELECT count(*),coalesce(sum(byte_size),0),coalesce(sum(CASE WHEN expires_at<=? THEN 1 ELSE 0 END),0) FROM offline_translation_cache",
                [timestamp],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(db_err)?;
        Ok(RssOfflineTranslationCacheStatus {
            entry_count: entry_count.max(0) as u32,
            total_bytes: total_bytes.max(0) as u64,
            max_bytes: offline_translation_max_bytes(&preferences_from(&connection)?),
            expired_count: expired_count.max(0) as u32,
        })
    }
    pub fn prune_offline_translations(&self) -> CommandResult<RssOfflineTranslationCleanup> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let preferences = preferences_from(&connection)?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let before = offline_translation_totals(&tx)?;
        prune_expired_offline_translations(&tx, now())?;
        enforce_offline_translation_quota(
            &tx,
            "",
            "",
            0,
            offline_translation_max_bytes(&preferences),
        )?;
        let after = offline_translation_totals(&tx)?;
        tx.commit().map_err(db_err)?;
        Ok(offline_translation_cleanup(before, after))
    }
    pub fn clear_offline_translations(
        &self,
        feed_id: Option<String>,
    ) -> CommandResult<RssOfflineTranslationCleanup> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        if let Some(ref id) = feed_id {
            let exists: Option<i64> = connection
                .query_row("SELECT 1 FROM feeds WHERE id=?", [id], |row| row.get(0))
                .optional()
                .map_err(db_err)?;
            if exists.is_none() {
                return Err(CommandError::new(
                    "rss_feed_not_found",
                    "RSS feed not found.",
                ));
            }
        }
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let before = offline_translation_totals(&tx)?;
        match feed_id {
            Some(id) => {
                tx.execute(
                    "DELETE FROM offline_translation_cache WHERE article_id IN (SELECT id FROM articles WHERE feed_id=?)",
                    [id],
                )
                .map_err(db_err)?;
            }
            None => {
                tx.execute("DELETE FROM offline_translation_cache", [])
                    .map_err(db_err)?;
            }
        }
        let after = offline_translation_totals(&tx)?;
        tx.commit().map_err(db_err)?;
        Ok(offline_translation_cleanup(before, after))
    }
    pub fn discover(&self, raw_url: String) -> CommandResult<RssDiscovery> {
        let private = self.preferences()?.private_network_access_enabled;
        let url = validate_url(&raw_url, private)?;
        let (final_url, status, headers, body) = fetch_bounded(&url, private, None, None)?;
        if !status.is_success() {
            return Err(CommandError::new(
                "rss_response_error",
                format!("Feed discovery returned HTTP {status}."),
            ));
        }
        if parse_xml(&body, &final_url).is_ok() {
            return Ok(RssDiscovery {
                url: final_url.to_string(),
                title: None,
                feed_url: Some(final_url.to_string()),
                candidates: vec![candidate(
                    &final_url,
                    None,
                    header_text(&headers, "content-type"),
                )],
            });
        }
        let (title, links) = discover_html(&body, &final_url, private)?;
        let candidates = links
            .into_iter()
            .take(MAX_DISCOVERY)
            .map(|(url, title, content_type)| RssDiscoveryCandidate {
                url: url.to_string(),
                title,
                content_type,
            })
            .collect::<Vec<_>>();
        Ok(RssDiscovery {
            url: final_url.to_string(),
            title,
            feed_url: candidates.first().map(|item| item.url.clone()),
            candidates,
        })
    }
    pub fn add_feed(&self, raw_url: String, title: Option<String>) -> CommandResult<RssFeed> {
        let private = self.preferences()?.private_network_access_enabled;
        let url = validate_url(&raw_url, private)?;
        let feed_title =
            clean_text(title.unwrap_or_else(|| url.host_str().unwrap_or("RSS feed").to_owned()));
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let id = Uuid::new_v4().to_string();
        let changed = connection
            .execute(
                "INSERT INTO feeds(id,url,title,added_at) VALUES(?,?,?,?)",
                params![
                    id,
                    url.as_str(),
                    nonempty_or(&feed_title, "RSS feed"),
                    now()
                ],
            )
            .map_err(|error| {
                if is_constraint(&error) {
                    CommandError::new("rss_feed_exists", "This feed is already subscribed.")
                } else {
                    db_err(error)
                }
            })?;
        if changed != 1 {
            return Err(CommandError::new(
                "rss_storage_error",
                "Feed was not created.",
            ));
        }
        load_feed(&connection, &id)
    }
    pub fn update_feed_site_url(
        &self,
        id: &str,
        site_url: Option<String>,
    ) -> CommandResult<RssFeed> {
        let private = self.preferences()?.private_network_access_enabled;
        if let Some(value) = &site_url {
            validate_url(value, private)?;
        }
        let connection = self.db.lock().map_err(|_| lock_err())?;
        require_changed(
            connection
                .execute(
                    "UPDATE feeds SET site_url=? WHERE id=?",
                    params![site_url, id],
                )
                .map_err(db_err)?,
            "rss_feed_not_found",
            "RSS feed not found.",
        )?;
        load_feed(&connection, id)
    }
    pub fn update_feed_url(&self, id: String, raw_url: String) -> CommandResult<RssFeed> {
        let private = self.preferences()?.private_network_access_enabled;
        let url = validate_url(&raw_url, private)?;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        require_changed(connection.execute("UPDATE feeds SET url=?,etag=NULL,last_modified=NULL,next_retry=0,refresh_failure_count=0 WHERE id=?", params![url.as_str(), id]).map_err(db_err)?, "rss_feed_not_found", "RSS feed not found.")?;
        load_feed(&connection, &id)
    }
    pub fn remove_feed(&self, id: String) -> CommandResult<Option<String>> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let feeds = filter_rows(
            dump_table(&connection, "feeds")?,
            "id",
            &HashSet::from([id.clone()]),
        );
        if feeds.is_empty() {
            return Err(CommandError::new(
                "rss_feed_not_found",
                "RSS feed not found.",
            ));
        }
        let articles = filter_rows(
            dump_table(&connection, "articles")?,
            "feed_id",
            &HashSet::from([id.clone()]),
        );
        let article_ids = articles
            .iter()
            .map(|row| string_field(row, "id"))
            .collect::<CommandResult<HashSet<_>>>()?;
        let highlights = filter_rows(
            dump_table(&connection, "highlights")?,
            "article_id",
            &article_ids,
        );
        let reading_progress = filter_rows(
            dump_table(&connection, "reading_progress")?,
            "article_id",
            &article_ids,
        );
        let full_text_cache = filter_rows(
            dump_table(&connection, "full_text_cache")?,
            "article_id",
            &article_ids,
        );
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let payload = serde_json::to_string(&RemovedFeedUndo {
            feed_id: id.clone(),
            feeds,
            articles,
            highlights,
            reading_progress,
            full_text_cache,
        })
        .map_err(json_err)?;
        let token = Uuid::new_v4().to_string();
        tx.execute(
            "INSERT INTO undo_actions(token,kind,payload,expires_at) VALUES(?,?,?,?)",
            params![token, "remove_feed", payload, now() + UNDO_TTL_SECONDS],
        )
        .map_err(db_err)?;
        require_changed(
            tx.execute("DELETE FROM feeds WHERE id=?", [&id])
                .map_err(db_err)?,
            "rss_feed_not_found",
            "RSS feed not found.",
        )?;
        tx.commit().map_err(db_err)?;
        Ok(Some(token))
    }
    pub fn article(&self, id: String) -> CommandResult<Option<RssArticle>> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        load_article(&connection, &id)
    }
    pub fn list_articles(&self, query: RssArticleQuery) -> CommandResult<RssArticlePage> {
        if !matches!(query.scope.as_str(), "all" | "unread" | "starred" | "feed") {
            return Err(CommandError::new(
                "rss_query_invalid",
                "Unknown article scope.",
            ));
        }
        if !matches!(query.sort.as_str(), "newest" | "oldest")
            || query.limit == 0
            || query.limit > 500
            || (query.scope == "feed" && query.feed_id.is_none())
        {
            return Err(CommandError::new(
                "rss_query_invalid",
                "Invalid article sort, limit, or feed scope.",
            ));
        }
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let (where_sql, mut values) = article_filter(&query)?;
        let total: i64 = connection
            .query_row(
                &format!("SELECT count(*) FROM articles {where_sql}"),
                rusqlite::params_from_iter(values.clone()),
                |row| row.get(0),
            )
            .map_err(db_err)?;
        values.push(Value::Integer(i64::from(query.limit) + 1));
        values.push(Value::Integer(i64::from(query.offset)));
        let direction = if query.sort == "oldest" {
            "ASC"
        } else {
            "DESC"
        };
        let mut statement = connection.prepare(&format!("SELECT id FROM articles {where_sql} ORDER BY published {direction}, fetched {direction}, id {direction} LIMIT ? OFFSET ?")).map_err(db_err)?;
        let ids = statement
            .query_map(rusqlite::params_from_iter(values), |row| {
                row.get::<_, String>(0)
            })
            .map_err(db_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_err)?;
        let has_more = ids.len() > query.limit as usize;
        let mut articles = Vec::new();
        for id in ids.into_iter().take(query.limit as usize) {
            if let Some(article) = load_article(&connection, &id)? {
                articles.push(article);
            }
        }
        Ok(RssArticlePage {
            articles,
            total: total as u32,
            has_more,
        })
    }
    pub fn update_article_state(
        &self,
        id: String,
        state: RssArticleState,
    ) -> CommandResult<RssArticle> {
        if let Some(tags) = &state.tags {
            if tags.len() > 64
                || tags
                    .iter()
                    .any(|tag| tag.trim().is_empty() || tag.len() > 128)
            {
                return Err(CommandError::new(
                    "rss_article_state_invalid",
                    "Article tags are invalid.",
                ));
            }
        }
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let exists: i64 = tx
            .query_row("SELECT count(*) FROM articles WHERE id=?", [&id], |row| {
                row.get(0)
            })
            .map_err(db_err)?;
        if exists != 1 {
            return Err(CommandError::new(
                "rss_article_not_found",
                "RSS article not found.",
            ));
        }
        if let Some(value) = state.read {
            require_changed(
                tx.execute(
                    "UPDATE articles SET read=?,read_at=? WHERE id=?",
                    params![
                        i64::from(value),
                        if value { Some(now()) } else { None },
                        &id
                    ],
                )
                .map_err(db_err)?,
                "rss_article_not_found",
                "RSS article not found.",
            )?;
        }
        if let Some(value) = state.starred {
            require_changed(
                tx.execute(
                    "UPDATE articles SET starred=? WHERE id=?",
                    params![i64::from(value), &id],
                )
                .map_err(db_err)?,
                "rss_article_not_found",
                "RSS article not found.",
            )?;
        }
        if let Some(tags) = state.tags {
            let json = serde_json::to_string(&normalise_tags(tags)).map_err(|error| {
                CommandError::new("rss_article_state_invalid", error.to_string())
            })?;
            require_changed(
                tx.execute("UPDATE articles SET tags=? WHERE id=?", params![json, &id])
                    .map_err(db_err)?,
                "rss_article_not_found",
                "RSS article not found.",
            )?;
        }
        tx.commit().map_err(db_err)?;
        load_article(&connection, &id)?
            .ok_or_else(|| CommandError::new("rss_article_not_found", "RSS article not found."))
    }
    #[cfg(test)]
    pub fn mark_all_read(&self, feed_id: Option<String>) -> CommandResult<(u32, Option<String>)> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let changed_articles = match feed_id {
            Some(value) => {
                let exists: i64 = tx
                    .query_row("SELECT count(*) FROM feeds WHERE id=?", [&value], |row| {
                        row.get(0)
                    })
                    .map_err(db_err)?;
                if exists != 1 {
                    return Err(CommandError::new(
                        "rss_feed_not_found",
                        "RSS feed not found.",
                    ));
                }
                load_unread_for_undo(&tx, Some(&value), None)?
            }
            None => load_unread_for_undo(&tx, None, None)?,
        };
        let result = apply_mark_read(&tx, changed_articles)?;
        tx.commit().map_err(db_err)?;
        Ok(result)
    }
    pub fn mark_articles_read(&self, ids: Vec<String>) -> CommandResult<(u32, Option<String>)> {
        if ids.is_empty() || ids.len() > 500 || ids.iter().any(|id| id.is_empty() || id.len() > 128)
        {
            return Err(CommandError::new(
                "rss_query_invalid",
                "Article selection is invalid.",
            ));
        }
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let changed = load_unread_for_undo(&tx, None, Some(&ids))?;
        let result = apply_mark_read(&tx, changed)?;
        tx.commit().map_err(db_err)?;
        Ok(result)
    }
    /// Mark every unread article matching the same safe predicate used by the
    /// article list.  Pagination is intentionally ignored: selecting only the
    /// visible page would produce a misleading bulk-read action.
    pub fn mark_filtered_read(
        &self,
        query: RssArticleQuery,
    ) -> CommandResult<(u32, Option<String>)> {
        if !matches!(query.scope.as_str(), "all" | "unread" | "starred" | "feed")
            || (query.scope == "feed" && query.feed_id.is_none())
        {
            return Err(CommandError::new(
                "rss_query_invalid",
                "Unknown article scope or missing feed scope.",
            ));
        }
        let (where_sql, values) = article_filter(&query)?;
        let unread_where = if where_sql.is_empty() {
            " WHERE read=0".to_owned()
        } else {
            format!("{where_sql} AND read=0")
        };
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let mut statement = tx
            .prepare(&format!(
                "SELECT id,read,read_at FROM articles {unread_where} ORDER BY id LIMIT {}",
                MAX_ITEMS + 1
            ))
            .map_err(db_err)?;
        let rows = statement
            .query_map(rusqlite::params_from_iter(values), |row| {
                Ok(MarkReadUndoArticle {
                    id: row.get(0)?,
                    read: row.get::<_, i64>(1)? != 0,
                    read_at: row.get(2)?,
                })
            })
            .map_err(db_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_err)?;
        drop(statement);
        if rows.len() > MAX_ITEMS {
            return Err(CommandError::new(
                "rss_mark_read_too_large",
                "Too many articles match this bulk read action.",
            ));
        }
        let result = apply_mark_read(&tx, rows)?;
        tx.commit().map_err(db_err)?;
        Ok(result)
    }
    pub fn undo_remove_feed(&self, token: String) -> CommandResult<()> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let payload = consume_undo(&tx, &token, "remove_feed")?;
        let undo: RemovedFeedUndo = serde_json::from_str(&payload).map_err(json_err)?;
        validate_removed_feed_undo(&undo, preferences_from(&tx)?.private_network_access_enabled)?;
        if exists_id(&tx, "feeds", &undo.feed_id)?
            || any_rows_exist(&tx, "articles", &undo.articles)?
            || any_rows_exist(&tx, "highlights", &undo.highlights)?
            || any_rows_exist(&tx, "reading_progress", &undo.reading_progress)?
            || any_rows_exist(&tx, "full_text_cache", &undo.full_text_cache)?
        {
            return Err(CommandError::new(
                "rss_undo_conflict",
                "RSS data changed after the feed was removed.",
            ));
        }
        insert_rows(&tx, "feeds", &undo.feeds)?;
        insert_rows(&tx, "articles", &undo.articles)?;
        insert_rows(&tx, "highlights", &undo.highlights)?;
        insert_rows(&tx, "reading_progress", &undo.reading_progress)?;
        insert_rows(&tx, "full_text_cache", &undo.full_text_cache)?;
        tx.commit().map_err(db_err)
    }
    pub fn undo_mark_all_read(&self, token: String) -> CommandResult<()> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let payload = consume_undo(&tx, &token, "mark_all_read")?;
        let undo: MarkReadUndo = serde_json::from_str(&payload).map_err(json_err)?;
        if undo.articles.len() > MAX_ITEMS
            || undo
                .articles
                .iter()
                .any(|row| row.id.is_empty() || row.id.len() > 128)
        {
            return Err(CommandError::new(
                "rss_undo_invalid",
                "RSS undo data is invalid.",
            ));
        }
        for row in &undo.articles {
            let changed = tx
                .execute(
                    "UPDATE articles SET read=?,read_at=? WHERE id=? AND read=1 AND read_at=?",
                    params![i64::from(row.read), row.read_at, row.id, undo.applied_at],
                )
                .map_err(db_err)?;
            if changed != 1 {
                return Err(CommandError::new(
                    "rss_undo_conflict",
                    "An article changed after it was marked read.",
                ));
            }
        }
        tx.commit().map_err(db_err)
    }
    pub fn refresh_feed_forced(&self, id: String, force: bool) -> CommandResult<RssRefreshResult> {
        let (url, etag, last_modified, private) = {
            let connection = self.db.lock().map_err(|_| lock_err())?;
            let feed = connection
                .query_row(
                    "SELECT url,etag,last_modified,next_refresh,next_retry FROM feeds WHERE id=?",
                    [&id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, Option<String>>(1)?,
                            row.get::<_, Option<String>>(2)?,
                            row.get::<_, i64>(3)?,
                            row.get::<_, i64>(4)?,
                        ))
                    },
                )
                .optional()
                .map_err(db_err)?
                .ok_or_else(|| CommandError::new("rss_feed_not_found", "RSS feed not found."))?;
            if !force && (feed.3 > now() || feed.4 > now()) {
                return Ok(RssRefreshResult {
                    feed_id: id,
                    fetched: 0,
                    inserted: 0,
                    not_modified: false,
                    issue: None,
                    updated: 0,
                    failed: false,
                    summary: "Refresh skipped until its next scheduled attempt.".to_owned(),
                });
            }
            (
                feed.0,
                feed.1,
                feed.2,
                preferences_from(&connection)?.private_network_access_enabled,
            )
        };
        match self.refresh_feed_inner(
            &id,
            &url,
            private,
            etag.as_deref(),
            last_modified.as_deref(),
        ) {
            Ok(value) => Ok(value),
            Err(error) => {
                let issue = self.record_failure(&id, &error)?;
                Ok(RssRefreshResult {
                    feed_id: id,
                    fetched: 0,
                    inserted: 0,
                    not_modified: false,
                    issue: Some(issue),
                    updated: 0,
                    failed: true,
                    summary: "Feed refresh failed; retry has been scheduled.".to_owned(),
                })
            }
        }
    }
    fn refresh_feed_inner(
        &self,
        id: &str,
        raw_url: &str,
        private: bool,
        etag: Option<&str>,
        last_modified: Option<&str>,
    ) -> CommandResult<RssRefreshResult> {
        let url = validate_url(raw_url, private)?;
        #[cfg(test)]
        let test_transport = self
            .test_feed_transport
            .lock()
            .map_err(|_| lock_err())?
            .clone();
        #[cfg(test)]
        let response = match test_transport {
            Some(fetch) => fetch(&url, private, etag, last_modified)?,
            None => fetch_bounded(&url, private, etag, last_modified)?,
        };
        #[cfg(not(test))]
        let response = fetch_bounded(&url, private, etag, last_modified)?;
        self.apply_feed_response(id, raw_url, response)
    }
    fn apply_feed_response(
        &self,
        id: &str,
        raw_url: &str,
        response: (Url, StatusCode, reqwest::header::HeaderMap, Vec<u8>),
    ) -> CommandResult<RssRefreshResult> {
        let (final_url, status, headers, body) = response;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        if status == StatusCode::NOT_MODIFIED {
            let changed = connection.execute("UPDATE feeds SET last_refreshed=?,last_refresh_attempt=?,next_refresh=?,next_retry=0,refresh_failure_count=0,issue_stage=NULL,issue_category=NULL,issue_detail=NULL,issue_at=0 WHERE id=?", params![now(), now(), now() + refresh_interval(&connection)?, id]).map_err(db_err)?;
            require_changed(changed, "rss_feed_not_found", "RSS feed not found.")?;
            return Ok(RssRefreshResult {
                feed_id: id.to_owned(),
                fetched: 0,
                inserted: 0,
                not_modified: true,
                issue: None,
                updated: 0,
                failed: false,
                summary: "Feed was not modified.".to_owned(),
            });
        }
        if !status.is_success() {
            return Err(CommandError::new(
                "rss_response_error",
                format!("Feed returned HTTP {status}."),
            ));
        }
        let parsed = parse_xml(&body, &final_url)?;
        let fetched = parsed.len() as u32;
        let preferences = preferences_from(&connection)?;
        let cache_feed_bodies = preferences.feed_body_offline_cache_enabled;
        let cache_full_text = preferences.offline_cache_full_text_on_refresh_enabled;
        let automatic_pruning = preferences.automatic_pruning_enabled;
        let tx = connection.unchecked_transaction().map_err(db_err)?;
        let mut inserted = 0_u32;
        let mut updated = 0_u32;
        let mut full_text_article_ids = Vec::new();
        for mut item in parsed {
            let fallback_url = item
                .url
                .clone()
                .or_else(|| validate_url(&item.guid, false).ok().map(|u| u.to_string()));
            let found: Option<(String, bool)> = tx
                .query_row(
                    "SELECT id,identity LIKE 'history:%' FROM articles WHERE feed_id=? AND (identity=? OR (identity LIKE 'history:%' AND url=?)) ORDER BY identity=? DESC LIMIT 1",
                    params![id, item.identity, fallback_url, item.identity],
                    |row| Ok((row.get(0)?,row.get(1)?)),
                )
                .optional()
                .map_err(db_err)?;
            match found {
                Some((article_id, historical)) => {
                    let preserved = if historical {
                        let (content, published, url, author): (
                            String,
                            i64,
                            Option<String>,
                            Option<String>,
                        ) = tx
                            .query_row(
                                "SELECT content,published,url,author FROM articles WHERE id=?",
                                [&article_id],
                                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                            )
                            .map_err(db_err)?;
                        if item.url.is_none() {
                            item.url = url;
                        }
                        if !item.published_provided {
                            item.published = published;
                        }
                        if item.author.is_none() {
                            item.author = author;
                        }
                        Some(content)
                    } else {
                        None
                    };
                    let cacheable_url = item.url.is_some();
                    let content = preserved.unwrap_or_else(|| {
                        feed_content_for_storage(cache_feed_bodies, item.content)
                    });
                    require_changed(tx.execute("UPDATE articles SET guid=?,title=?,url=?,cover_url=?,author=?,summary=?,content=?,published=?,fetched=? WHERE id=?", params![item.guid, item.title, item.url, item.cover_url, item.author, item.summary, content, item.published, now(), article_id]).map_err(db_err)?, "rss_article_not_found", "RSS article not found.")?;
                    if should_cache_full_text_on_refresh(cache_full_text, cacheable_url) {
                        full_text_article_ids.push(article_id);
                    }
                    updated += 1;
                }
                None => {
                    let article_id = Uuid::new_v4().to_string();
                    let cacheable_url = item.url.is_some();
                    let content = feed_content_for_storage(cache_feed_bodies, item.content);
                    let changed = tx.execute("INSERT INTO articles(id,feed_id,identity,guid,title,url,cover_url,author,summary,content,published,fetched) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", params![article_id, id, item.identity, item.guid, item.title, item.url, item.cover_url, item.author, item.summary, content, item.published, now()]).map_err(db_err)?;
                    if changed != 1 {
                        return Err(CommandError::new(
                            "rss_storage_error",
                            "Article was not stored.",
                        ));
                    }
                    if should_cache_full_text_on_refresh(cache_full_text, cacheable_url) {
                        full_text_article_ids.push(article_id);
                    }
                    inserted += 1;
                }
            }
        }
        let title = feed_title_from(&body).unwrap_or_default();
        let changed = tx.execute("UPDATE feeds SET url=?,title=CASE WHEN ?='' THEN title ELSE ? END,etag=?,last_modified=?,last_refreshed=?,last_refresh_attempt=?,next_refresh=?,next_retry=0,refresh_failure_count=0,issue_stage=NULL,issue_category=NULL,issue_detail=NULL,issue_at=0 WHERE id=? AND url=?", params![final_url.as_str(), title, title, header_text(&headers, "etag"), header_text(&headers, "last-modified"), now(), now(), now() + refresh_interval(&tx)?, id, raw_url]).map_err(db_err)?;
        require_changed(
            changed,
            "rss_feed_changed",
            "RSS feed URL changed while refresh was in progress.",
        )?;
        tx.commit().map_err(db_err)?;
        drop(connection);
        self.enforce_feed_limit(id)?;
        if cache_full_text {
            self.cache_full_text_articles(full_text_article_ids);
        }
        if automatic_pruning {
            let _ = self.prune();
        }
        Ok(RssRefreshResult {
            feed_id: id.to_owned(),
            fetched,
            inserted,
            not_modified: false,
            issue: None,
            updated,
            failed: false,
            summary: format!("Fetched {fetched} articles."),
        })
    }
    fn record_failure(&self, id: &str, error: &CommandError) -> CommandResult<RssIssue> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let previous: i64 = connection
            .query_row(
                "SELECT refresh_failure_count FROM feeds WHERE id=?",
                [id],
                |row| row.get(0),
            )
            .optional()
            .map_err(db_err)?
            .ok_or_else(|| CommandError::new("rss_feed_not_found", "RSS feed not found."))?;
        let count = previous.saturating_add(1).min(20);
        let delay =
            (60_i64.saturating_mul(1_i64 << (count.saturating_sub(1) as u32))).min(6 * 60 * 60);
        let retry_at = now() + delay;
        let (stage, category) = classify_issue(&error.code);
        let issue = make_issue(stage, category, retry_at, error);
        require_changed(connection.execute("UPDATE feeds SET refresh_failure_count=?,next_retry=?,last_refresh_attempt=?,issue_stage=?,issue_category=?,issue_detail=?,issue_at=? WHERE id=?", params![count, retry_at, now(), issue.stage, issue.category, issue.technical_detail, issue.occurred_at, id]).map_err(db_err)?, "rss_feed_not_found", "RSS feed not found.")?;
        Ok(issue)
    }
    pub fn refresh_all_forced(&self, force: bool) -> CommandResult<Vec<RssRefreshResult>> {
        let ids = {
            let connection = self.db.lock().map_err(|_| lock_err())?;
            let mut statement = connection
                .prepare("SELECT id FROM feeds ORDER BY id")
                .map_err(db_err)?;
            let rows = statement
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(db_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(db_err)?
        };
        let mut output = Vec::new();
        for batch in ids.chunks(6) {
            let batch_results = std::thread::scope(|scope| {
                let tasks = batch
                    .iter()
                    .cloned()
                    .map(|id| scope.spawn(move || self.refresh_feed_forced(id, force)))
                    .collect::<Vec<_>>();
                tasks
                    .into_iter()
                    .map(|task| {
                        task.join().map_err(|_| {
                            CommandError::new("rss_task_failed", "RSS refresh worker panicked.")
                        })?
                    })
                    .collect::<CommandResult<Vec<_>>>()
            });
            output.extend(batch_results?);
        }
        Ok(output)
    }
    pub fn import_opml(&self, xml: String) -> CommandResult<RssOpmlImportResult> {
        let review = self.review_opml("import".into(), Some(xml.clone()))?;
        if review.affected_count > 0 || review.blocked_count > 0 {
            return Err(CommandError::new(
                "rss_opml_review_required",
                "Review subscription URL privacy before importing.",
            ));
        }
        let result = self.execute_opml(
            "import".into(),
            Some(xml),
            review.fingerprint,
            "redact".into(),
        )?;
        Ok(RssOpmlImportResult {
            imported_count: result.imported_count,
            skipped_count: result.skipped_count,
        })
    }
    pub fn export_opml(&self) -> CommandResult<String> {
        let review = self.review_opml("export".into(), None)?;
        if review.affected_count > 0 || review.blocked_count > 0 {
            return Err(CommandError::new(
                "rss_opml_review_required",
                "Review subscription URL privacy before exporting.",
            ));
        }
        Ok(self
            .execute_opml("export".into(), None, review.fingerprint, "redact".into())?
            .opml
            .unwrap_or_default())
    }

    pub fn export_backup(&self) -> CommandResult<String> {
        let c = self.db.lock().map_err(|_| lock_err())?;
        let backup = RssBackup {
            schema_version: BACKUP_SCHEMA_VERSION,
            database_schema_version: SCHEMA_VERSION,
            feeds: dump_table(&c, "feeds")?,
            articles: dump_table(&c, "articles")?,
            highlights: dump_table(&c, "highlights")?,
            reading_progress: dump_table(&c, "reading_progress")?,
            full_text_cache: dump_table(&c, "full_text_cache")?,
            preferences: serde_json::to_value(preferences_from(&c)?).map_err(json_err)?,
            meta: dump_table(&c, "meta")?,
        };
        let text = serde_json::to_string(&backup).map_err(json_err)?;
        if text.len() > BACKUP_MAX_BYTES {
            return Err(CommandError::new(
                "rss_backup_too_large",
                "RSS backup exceeds 64 MiB.",
            ));
        }
        Ok(text)
    }

    pub fn inspect_backup(&self, text: String) -> CommandResult<RssBackupSummary> {
        let backup = parse_backup(&text)?;
        validate_backup(&backup)?;
        Ok(backup_summary(&backup))
    }

    pub fn restore_backup(&self, text: String) -> CommandResult<RssBackupSummary> {
        let backup = parse_backup(&text)?;
        validate_backup(&backup)?;
        let c = self.db.lock().map_err(|_| lock_err())?;
        let tx = c.unchecked_transaction().map_err(db_err)?;
        tx.execute_batch("DELETE FROM full_text_cache; DELETE FROM reading_progress; DELETE FROM highlights; DELETE FROM articles; DELETE FROM feeds; DELETE FROM meta; DELETE FROM undo_actions;").map_err(db_err)?;
        for (table, rows) in [
            ("meta", &backup.meta),
            ("feeds", &backup.feeds),
            ("articles", &backup.articles),
            ("highlights", &backup.highlights),
            ("reading_progress", &backup.reading_progress),
            ("full_text_cache", &backup.full_text_cache),
        ] {
            insert_rows(&tx, table, rows)?;
        }
        set_meta(&tx, "schema_version", &SCHEMA_VERSION.to_string())?;
        write_backup_preferences(&tx, &backup.preferences)?;
        tx.commit().map_err(db_err)?;
        Ok(backup_summary(&backup))
    }
    pub fn list_highlights(&self, article_id: String) -> CommandResult<Vec<RssHighlight>> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let mut statement = connection.prepare("SELECT id,article_id,text,note,tags,created_at,updated_at FROM highlights WHERE article_id=? ORDER BY created_at,id").map_err(db_err)?;
        let rows = statement
            .query_map([article_id], |row| {
                Ok(RssHighlight {
                    id: row.get(0)?,
                    article_id: row.get(1)?,
                    text: row.get(2)?,
                    note: row.get(3)?,
                    tags: serde_json::from_str(&row.get::<_, String>(4)?).unwrap_or_default(),
                    created_at: row.get(5)?,
                    updated_at: row.get(6)?,
                })
            })
            .map_err(db_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db_err)
    }
    pub fn save_highlight(&self, mut value: RssHighlight) -> CommandResult<RssHighlight> {
        value.text = clean_text(value.text);
        value.note = clean_text(value.note);
        value.tags = normalise_tags(value.tags);
        if value.article_id.is_empty() || value.text.is_empty() || value.text.len() > 16_384 {
            return Err(CommandError::new(
                "rss_highlight_invalid",
                "Highlight text is invalid.",
            ));
        }
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let exists: i64 = connection
            .query_row(
                "SELECT count(*) FROM articles WHERE id=?",
                [&value.article_id],
                |row| row.get(0),
            )
            .map_err(db_err)?;
        if exists != 1 {
            return Err(CommandError::new(
                "rss_article_not_found",
                "RSS article not found.",
            ));
        }
        let timestamp = now();
        if value.id.is_empty() {
            value.id = Uuid::new_v4().to_string();
            value.created_at = timestamp;
        }
        value.updated_at = timestamp;
        let tags = serde_json::to_string(&value.tags)
            .map_err(|error| CommandError::new("rss_highlight_invalid", error.to_string()))?;
        connection.execute("INSERT INTO highlights(id,article_id,text,note,tags,created_at,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET text=excluded.text,note=excluded.note,tags=excluded.tags,updated_at=excluded.updated_at", params![value.id,value.article_id,value.text,value.note,tags,value.created_at,value.updated_at]).map_err(db_err)?;
        Ok(value)
    }
    pub fn delete_highlight(&self, id: String) -> CommandResult<()> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        require_changed(
            connection
                .execute("DELETE FROM highlights WHERE id=?", [id])
                .map_err(db_err)?,
            "rss_highlight_not_found",
            "RSS highlight not found.",
        )
    }
    pub fn list_highlights_json(&self, article_id: String) -> CommandResult<serde_json::Value> {
        serde_json::to_value(self.list_highlights(article_id)?)
            .map_err(|error| CommandError::new("rss_storage_error", error.to_string()))
    }
    pub fn save_highlight_json(
        &self,
        article_id: String,
        id: Option<String>,
        text: String,
        note: Option<String>,
        tags: Option<Vec<String>>,
    ) -> CommandResult<serde_json::Value> {
        let value = self.save_highlight(RssHighlight {
            id: id.unwrap_or_default(),
            article_id,
            text,
            note: note.unwrap_or_default(),
            tags: tags.unwrap_or_default(),
            created_at: 0,
            updated_at: 0,
        })?;
        serde_json::to_value(value)
            .map_err(|error| CommandError::new("rss_storage_error", error.to_string()))
    }
    pub fn get_reading_progress(
        &self,
        article_id: String,
    ) -> CommandResult<Option<RssReadingProgress>> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        connection
            .query_row(
                "SELECT article_id,progress,revision,updated_at FROM reading_progress WHERE article_id=?",
                [article_id],
                |row| {
                    Ok(RssReadingProgress {
                        article_id: row.get(0)?,
                        progress: row.get(1)?,
                        revision: row.get(2)?, updated_at: row.get(3)?,
                    })
                },
            )
            .optional()
            .map_err(db_err)
    }
    pub fn save_reading_progress(
        &self,
        article_id: String,
        progress: f64,
        revision: i64,
    ) -> CommandResult<RssReadingProgress> {
        if !progress.is_finite() || !(0.0..=1.0).contains(&progress) || revision < 1 {
            return Err(CommandError::new(
                "rss_progress_invalid",
                "Reading progress or revision is invalid.",
            ));
        }
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let previous: Option<RssReadingProgress> = connection
            .query_row(
                "SELECT article_id,progress,revision,updated_at FROM reading_progress WHERE article_id=?",
                [&article_id],
                |row| Ok(RssReadingProgress { article_id: row.get(0)?, progress: row.get(1)?, revision: row.get(2)?, updated_at: row.get(3)? }),
            )
            .optional()
            .map_err(db_err)?;
        if let Some(previous) = &previous {
            if revision <= previous.revision {
                return Ok(previous.clone());
            }
        }
        let persisted_progress = previous
            .as_ref()
            .filter(|value| {
                (value.progress - progress).abs() < 0.01 && progress != 0.0 && progress != 1.0
            })
            .map_or(progress, |value| value.progress);
        connection.execute("INSERT INTO reading_progress(article_id,progress,revision,updated_at) VALUES(?,?,?,?) ON CONFLICT(article_id) DO UPDATE SET progress=excluded.progress,revision=excluded.revision,updated_at=excluded.updated_at", params![article_id,persisted_progress,revision,now()]).map_err(db_err)?;
        connection.execute("DELETE FROM reading_progress WHERE article_id IN (SELECT article_id FROM reading_progress ORDER BY updated_at DESC LIMIT -1 OFFSET 512)", []).map_err(db_err)?;
        connection.query_row("SELECT article_id,progress,revision,updated_at FROM reading_progress WHERE article_id=?", [&article_id], |row| Ok(RssReadingProgress { article_id: row.get(0)?, progress: row.get(1)?, revision: row.get(2)?, updated_at: row.get(3)? })).map_err(db_err)
    }
    pub fn get_reading_progress_json(
        &self,
        article_id: String,
    ) -> CommandResult<serde_json::Value> {
        serde_json::to_value(self.get_reading_progress(article_id)?)
            .map_err(|error| CommandError::new("rss_storage_error", error.to_string()))
    }
    pub fn save_reading_progress_json(
        &self,
        article_id: String,
        progress: f64,
        revision: i64,
    ) -> CommandResult<serde_json::Value> {
        serde_json::to_value(self.save_reading_progress(article_id, progress, revision)?)
            .map_err(|error| CommandError::new("rss_storage_error", error.to_string()))
    }
    pub fn fetch_full_text_json(
        &self,
        article_id: String,
        force: bool,
    ) -> CommandResult<serde_json::Value> {
        let (url, private) = {
            let connection = self.db.lock().map_err(|_| lock_err())?;
            let url: Option<String> = connection
                .query_row(
                    "SELECT url FROM articles WHERE id=?",
                    [&article_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(db_err)?
                .flatten();
            let url = url.ok_or_else(|| {
                CommandError::new(
                    "rss_full_text_rejected",
                    "This article has no safe web URL.",
                )
            })?;
            (
                url,
                preferences_from(&connection)?.private_network_access_enabled,
            )
        };
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let cached: Option<CachedFullTextRow> = connection.query_row("SELECT status,content_html,plain_text,resolved_url,source_etag,source_last_modified,source_content_hash,confidence,attempted_at,retry_after,failure_message FROM full_text_cache WHERE article_id=?", [&article_id], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?,row.get(5)?,row.get(6)?,row.get(7)?,row.get(8)?,row.get(9)?,row.get(10)?))).optional().map_err(db_err)?;
        let cached_source_url = if cached.is_some() {
            connection
                .query_row(
                    "SELECT source_url FROM full_text_cache WHERE article_id=?",
                    [&article_id],
                    |row| row.get::<_, Option<String>>(0),
                )
                .optional()
                .map_err(db_err)?
                .flatten()
        } else {
            None
        };
        let cache_matches_source = cached_source_url.as_deref() == Some(url.as_str());
        if !force {
            if let Some((
                status,
                html,
                text,
                resolved,
                etag,
                last_modified,
                hash,
                confidence,
                attempted,
                retry,
                failure,
            )) = &cached
            {
                if cache_matches_source
                    && (matches!(status.as_str(), "ready" | "rejected") || *retry > now())
                {
                    let mut result = full_text_json(
                        &article_id,
                        status,
                        html.clone(),
                        text.clone(),
                        Some(url.clone()),
                        resolved.clone(),
                        etag.clone(),
                        last_modified.clone(),
                        *confidence as f64 / 1000.0,
                        *retry,
                        failure.clone(),
                    );
                    result["sourceContentHash"] = hash
                        .clone()
                        .map(serde_json::Value::String)
                        .unwrap_or(serde_json::Value::Null);
                    result["attemptedAt"] = serde_json::Value::from(*attempted);
                    return Ok(result);
                }
            }
        }
        drop(connection);
        let source = validate_url(&url, private)?;
        let validators = cached
            .as_ref()
            .filter(|_| cache_matches_source)
            .map(|value| (value.4.as_deref(), value.5.as_deref()))
            .unwrap_or((None, None));
        let result = fetch_bounded(&source, private, validators.0, validators.1);
        let value = match result {
            Ok((_resolved, StatusCode::NOT_MODIFIED, _headers, _body)) => {
                if cache_matches_source {
                    if let Some((
                        status,
                        html,
                        text,
                        resolved,
                        etag,
                        last_modified,
                        hash,
                        confidence,
                        _attempted,
                        retry,
                        failure,
                    )) = cached
                    {
                        let connection = self.db.lock().map_err(|_| lock_err())?;
                        connection
                            .execute(
                                "UPDATE full_text_cache SET attempted_at=? WHERE article_id=?",
                                params![now(), article_id],
                            )
                            .map_err(db_err)?;
                        let mut result = full_text_json(
                            &article_id,
                            &status,
                            html,
                            text,
                            Some(url.clone()),
                            resolved,
                            etag,
                            last_modified,
                            confidence as f64 / 1000.0,
                            retry,
                            failure,
                        );
                        result["sourceContentHash"] = hash
                            .map(serde_json::Value::String)
                            .unwrap_or(serde_json::Value::Null);
                        result["attemptedAt"] = serde_json::Value::from(now());
                        result
                    } else {
                        cache_full_text_state(
                            &self.db,
                            &article_id,
                            "failed",
                            &url,
                            now() + 60,
                            "Received 304 without a cached article body.",
                        )?
                    }
                } else {
                    cache_full_text_state(
                        &self.db,
                        &article_id,
                        "failed",
                        &url,
                        now() + 60,
                        "Received 304 for a different article source.",
                    )?
                }
            }
            Ok((resolved, status, headers, body))
                if status.is_success()
                    && header_text(&headers, "content-type")
                        .is_some_and(|value| value.to_ascii_lowercase().contains("text/html"))
                    && body.len() <= 5 * 1024 * 1024 =>
            {
                let Ok(html) = String::from_utf8(body) else {
                    return cache_full_text_state(
                        &self.db,
                        &article_id,
                        "rejected",
                        &url,
                        0,
                        "Article HTML is not UTF-8.",
                    );
                };
                let (content_html, text, confidence) = extract_readable_html(&html);
                if text.len() < 200 || confidence < 0.2 {
                    cache_full_text_state(
                        &self.db,
                        &article_id,
                        "rejected",
                        &url,
                        0,
                        "Article extraction did not meet the quality threshold.",
                    )?
                } else {
                    let mut hash = Sha256::new();
                    hash.update(content_html.as_bytes());
                    let hash = format!("{:x}", hash.finalize());
                    let mut json = full_text_json(
                        &article_id,
                        "ready",
                        Some(content_html),
                        Some(text.clone()),
                        Some(url.clone()),
                        Some(resolved.to_string()),
                        header_text(&headers, "etag"),
                        header_text(&headers, "last-modified"),
                        confidence,
                        0,
                        None,
                    );
                    json["sourceContentHash"] = serde_json::Value::String(hash.clone());
                    let connection = self.db.lock().map_err(|_| lock_err())?;
                    connection.execute("INSERT INTO full_text_cache(article_id,status,content_html,plain_text,source_url,resolved_url,source_etag,source_last_modified,source_content_hash,confidence,attempted_at,retry_after,failure_message) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(article_id) DO UPDATE SET status=excluded.status,content_html=excluded.content_html,plain_text=excluded.plain_text,source_url=excluded.source_url,resolved_url=excluded.resolved_url,source_etag=excluded.source_etag,source_last_modified=excluded.source_last_modified,source_content_hash=excluded.source_content_hash,confidence=excluded.confidence,attempted_at=excluded.attempted_at,retry_after=0,failure_message=NULL", params![article_id,"ready",json["contentHtml"].as_str(),text,url,resolved.as_str(),header_text(&headers,"etag"),header_text(&headers,"last-modified"),hash,(confidence * 1000.0).round() as i64,now(),0_i64,Option::<String>::None]).map_err(db_err)?;
                    json
                }
            }
            Ok(_) => cache_full_text_state(
                &self.db,
                &article_id,
                "rejected",
                &url,
                0,
                "Article response was not HTML or exceeded 5 MiB.",
            )?,
            Err(error) => cache_full_text_state(
                &self.db,
                &article_id,
                "failed",
                &url,
                now() + 60,
                &error.message,
            )?,
        };
        Ok(value)
    }
    pub fn fetch_cover_data_url(&self, article_id: String) -> CommandResult<Option<String>> {
        let (raw_url, private, enabled) = {
            let connection = self.db.lock().map_err(|_| lock_err())?;
            let raw_url = connection
                .query_row(
                    "SELECT cover_url FROM articles WHERE id=?",
                    [&article_id],
                    |row| row.get::<_, Option<String>>(0),
                )
                .optional()
                .map_err(db_err)?
                .flatten();
            let preferences = preferences_from(&connection)?;
            (
                raw_url,
                preferences.private_network_access_enabled,
                preferences.remote_images_enabled,
            )
        };
        if !enabled {
            return Err(CommandError::new(
                "rss_remote_images_disabled",
                "Remote RSS images are disabled.",
            ));
        }
        let Some(raw_url) = raw_url else {
            return Ok(None);
        };
        let url = validate_url(&raw_url, private)?;
        let (_resolved, status, headers, body) = fetch_bounded_with_limit(
            &url,
            private,
            None,
            None,
            MAX_COVER_IMAGE,
            "RSS cover image exceeds 2 MiB.",
        )?;
        if !status.is_success() || body.is_empty() {
            return Err(CommandError::new(
                "rss_cover_response_invalid",
                format!("RSS cover image returned HTTP {status}."),
            ));
        }
        let mime = header_text(&headers, "content-type")
            .as_deref()
            .and_then(supported_cover_mime)
            .ok_or_else(|| {
                CommandError::new(
                    "rss_cover_type_rejected",
                    "RSS cover response is not a supported raster image.",
                )
            })?;
        if !valid_cover_image(mime, &body) {
            return Err(CommandError::new(
                "rss_cover_content_rejected",
                "RSS cover bytes or image dimensions are invalid.",
            ));
        }
        let encoded = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, body);
        Ok(Some(format!("data:{mime};base64,{encoded}")))
    }
    /// Populate the optional offline reader cache only after the feed transaction
    /// has committed.  `fetch_full_text_json` takes and releases the database
    /// mutex before opening a socket, so this deliberately remains serial.
    fn cache_full_text_articles(&self, article_ids: Vec<String>) {
        let mut seen = HashSet::new();
        for article_id in article_ids
            .into_iter()
            .filter(|article_id| seen.insert(article_id.clone()))
            .take(MAX_FULL_TEXT_PREFETCH_PER_REFRESH)
        {
            // A per-article extraction failure has its own persisted retry state;
            // it must not turn an otherwise successful feed refresh into failure.
            let _ = self.fetch_full_text_json(article_id, false);
        }
    }
    pub fn prune(&self) -> CommandResult<u32> {
        let preferences = self.preferences()?;
        let cutoff = now() - i64::from(preferences.retention_days) * 86_400;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        Ok(connection
            .execute(
                "DELETE FROM articles WHERE published < ? AND read=1 AND starred=0 AND tags='[]' AND NOT EXISTS (SELECT 1 FROM highlights h WHERE h.article_id=articles.id)",
                [cutoff],
            )
            .map_err(db_err)? as u32)
    }
    fn enforce_feed_limit(&self, feed_id: &str) -> CommandResult<u32> {
        let limit = self.preferences()?.max_articles_per_feed;
        let connection = self.db.lock().map_err(|_| lock_err())?;
        Ok(connection.execute("DELETE FROM articles WHERE feed_id=? AND read=1 AND starred=0 AND tags='[]' AND id NOT IN (SELECT id FROM articles WHERE feed_id=? ORDER BY published DESC,fetched DESC LIMIT ?) AND NOT EXISTS (SELECT 1 FROM highlights h WHERE h.article_id=articles.id)", params![feed_id, feed_id, limit]).map_err(db_err)? as u32)
    }
}

fn validate_offline_translation_request(
    request: &RssOfflineTranslationRequest,
) -> CommandResult<()> {
    if request.article_id.is_empty()
        || !matches!(
            request.provider.as_str(),
            "libretranslate_local" | "ollama_local" | "openai_compatible"
        )
        || request.endpoint.trim().is_empty()
        || request.endpoint.len() > MAX_OFFLINE_TRANSLATION_ENDPOINT_BYTES
        || request.model.len() > MAX_OFFLINE_TRANSLATION_MODEL_BYTES
        || !valid_translation_language(&request.source_language)
        || !valid_translation_language(&request.target_language)
        || request.source_text.is_empty()
        || request.source_text.len() > MAX_OFFLINE_TRANSLATION_SOURCE_BYTES
        || request.glossary.len() > MAX_OFFLINE_TRANSLATION_GLOSSARY_ENTRIES
        || request.glossary.iter().any(|entry| {
            entry.source.is_empty()
                || entry.target.is_empty()
                || entry.source.len() > MAX_OFFLINE_TRANSLATION_GLOSSARY_FIELD_BYTES
                || entry.target.len() > MAX_OFFLINE_TRANSLATION_GLOSSARY_FIELD_BYTES
        })
    {
        return Err(CommandError::new(
            "rss_offline_translation_invalid",
            "Offline translation request is outside supported bounds.",
        ));
    }
    Ok(())
}
fn validate_offline_translation_result(
    request: &RssOfflineTranslationRequest,
    result: &RssOfflineTranslationResult,
) -> CommandResult<()> {
    if result.translated_text.is_empty()
        || result.translated_text.len() > MAX_OFFLINE_TRANSLATION_OUTPUT_BYTES
        || result.provider != request.provider
        || result.model != request.model
        || result.target_language != request.target_language
        || result
            .detected_source_language
            .as_deref()
            .is_some_and(|value| !valid_translation_language(value))
    {
        return Err(CommandError::new(
            "rss_offline_translation_invalid",
            "Offline translation result is outside supported bounds.",
        ));
    }
    Ok(())
}
fn valid_translation_language(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}
fn fingerprint_component(hasher: &mut Sha256, value: &str) {
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value.as_bytes());
}
fn offline_translation_fingerprint(request: &RssOfflineTranslationRequest) -> String {
    let mut hasher = Sha256::new();
    hasher.update([OFFLINE_TRANSLATION_FINGERPRINT_VERSION]);
    for value in [
        request.provider.as_str(),
        request.endpoint.as_str(),
        request.model.as_str(),
        request.source_language.as_str(),
        request.target_language.as_str(),
    ] {
        fingerprint_component(&mut hasher, value);
    }
    hasher.update((request.glossary.len() as u64).to_be_bytes());
    for entry in &request.glossary {
        fingerprint_component(&mut hasher, &entry.source);
        fingerprint_component(&mut hasher, &entry.target);
    }
    fingerprint_component(&mut hasher, &request.source_text);
    format!("{:x}", hasher.finalize())
}
fn offline_translation_record_size(result: &RssOfflineTranslationResult) -> u64 {
    (result.translated_text.len()
        + result
            .detected_source_language
            .as_deref()
            .map_or(0, str::len)
        + result.provider.len()
        + result.model.len()
        + result.target_language.len()) as u64
}
fn offline_translation_max_bytes(preferences: &RssPreferences) -> u64 {
    u64::from(preferences.offline_translation_max_mib) * 1024 * 1024
}
fn ensure_offline_translation_article(
    connection: &Connection,
    article_id: &str,
) -> CommandResult<()> {
    let exists: Option<i64> = connection
        .query_row("SELECT 1 FROM articles WHERE id=?", [article_id], |row| {
            row.get(0)
        })
        .optional()
        .map_err(db_err)?;
    if exists.is_none() {
        return Err(CommandError::new(
            "rss_article_not_found",
            "RSS article not found.",
        ));
    }
    Ok(())
}
fn offline_translation_record_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<RssOfflineTranslationRecord> {
    Ok(RssOfflineTranslationRecord {
        article_id: row.get(0)?,
        translated_text: row.get(1)?,
        detected_source_language: row.get(2)?,
        provider: row.get(3)?,
        model: row.get(4)?,
        target_language: row.get(5)?,
        created_at: row.get(6)?,
        expires_at: row.get(7)?,
        byte_size: row.get::<_, i64>(8)?.max(0) as u64,
    })
}
fn offline_translation_totals(connection: &Connection) -> CommandResult<(u64, u64)> {
    let (count, bytes): (i64, i64) = connection
        .query_row(
            "SELECT count(*),coalesce(sum(byte_size),0) FROM offline_translation_cache",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(db_err)?;
    Ok((count.max(0) as u64, bytes.max(0) as u64))
}
fn offline_translation_cleanup(
    before: (u64, u64),
    after: (u64, u64),
) -> RssOfflineTranslationCleanup {
    RssOfflineTranslationCleanup {
        removed_count: before.0.saturating_sub(after.0).min(u64::from(u32::MAX)) as u32,
        freed_bytes: before.1.saturating_sub(after.1),
        remaining_count: after.0.min(u64::from(u32::MAX)) as u32,
        remaining_bytes: after.1,
    }
}
fn prune_expired_offline_translations(
    connection: &Connection,
    timestamp: i64,
) -> CommandResult<()> {
    connection
        .execute(
            "DELETE FROM offline_translation_cache WHERE expires_at<=?",
            [timestamp],
        )
        .map_err(db_err)?;
    Ok(())
}
fn enforce_offline_translation_quota(
    connection: &Connection,
    retained_article_id: &str,
    retained_fingerprint: &str,
    incoming_bytes: u64,
    max_bytes: u64,
) -> CommandResult<()> {
    let (_, existing_bytes) = if retained_article_id.is_empty() {
        offline_translation_totals(connection)?
    } else {
        let (count, bytes): (i64, i64) = connection
            .query_row(
                "SELECT count(*),coalesce(sum(byte_size),0) FROM offline_translation_cache WHERE NOT (article_id=? AND request_fingerprint=?)",
                params![retained_article_id, retained_fingerprint],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(db_err)?;
        (count.max(0) as u64, bytes.max(0) as u64)
    };
    let mut total = existing_bytes.saturating_add(incoming_bytes);
    if total <= max_bytes {
        return Ok(());
    }
    let mut statement = if retained_article_id.is_empty() {
        connection
            .prepare("SELECT article_id,request_fingerprint,byte_size FROM offline_translation_cache ORDER BY last_accessed_at,created_at,article_id,request_fingerprint")
            .map_err(db_err)?
    } else {
        connection
            .prepare("SELECT article_id,request_fingerprint,byte_size FROM offline_translation_cache WHERE NOT (article_id=? AND request_fingerprint=?) ORDER BY last_accessed_at,created_at,article_id,request_fingerprint")
            .map_err(db_err)?
    };
    let mut candidates = Vec::new();
    if retained_article_id.is_empty() {
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })
            .map_err(db_err)?;
        for row in rows {
            candidates.push(row.map_err(db_err)?);
        }
    } else {
        let rows = statement
            .query_map(params![retained_article_id, retained_fingerprint], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })
            .map_err(db_err)?;
        for row in rows {
            candidates.push(row.map_err(db_err)?);
        }
    }
    drop(statement);
    for (article_id, fingerprint, byte_size) in candidates {
        if total <= max_bytes {
            break;
        }
        connection
            .execute(
                "DELETE FROM offline_translation_cache WHERE article_id=? AND request_fingerprint=?",
                params![article_id, fingerprint],
            )
            .map_err(db_err)?;
        total = total.saturating_sub(byte_size.max(0) as u64);
    }
    Ok(())
}

pub(super) fn migrate(connection: &Connection) -> CommandResult<()> {
    let has_meta: bool = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta')",
            [],
            |r| r.get(0),
        )
        .map_err(db_err)?;
    if has_meta {
        let version: Option<String> = connection
            .query_row(
                "SELECT value FROM meta WHERE key='schema_version'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_err)?;
        if version.is_some_and(|v| !matches!(v.as_str(), "1" | "2" | "3" | "4")) {
            return Err(CommandError::new(
                "rss_storage_version_unsupported",
                "This RSS database version is unsupported; no migration was applied.",
            ));
        }
    }
    let transaction = connection.unchecked_transaction().map_err(db_err)?;
    let connection = &transaction;
    connection.execute_batch("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS feeds (id TEXT PRIMARY KEY,url TEXT NOT NULL UNIQUE,title TEXT NOT NULL,site_url TEXT,etag TEXT,last_modified TEXT,last_refreshed INTEGER NOT NULL DEFAULT 0,next_refresh INTEGER NOT NULL DEFAULT 0,added_at INTEGER NOT NULL DEFAULT 0,last_refresh_attempt INTEGER NOT NULL DEFAULT 0,refresh_failure_count INTEGER NOT NULL DEFAULT 0,next_retry INTEGER NOT NULL DEFAULT 0,issue_stage TEXT,issue_category TEXT,issue_detail TEXT,issue_at INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS articles (id TEXT PRIMARY KEY,feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,identity TEXT NOT NULL DEFAULT '',guid TEXT NOT NULL,title TEXT NOT NULL,url TEXT,cover_url TEXT,author TEXT,summary TEXT NOT NULL,content TEXT NOT NULL,published INTEGER NOT NULL,fetched INTEGER NOT NULL,read INTEGER NOT NULL DEFAULT 0,read_at INTEGER,starred INTEGER NOT NULL DEFAULT 0,tags TEXT NOT NULL DEFAULT '[]',UNIQUE(feed_id,identity)); CREATE TABLE IF NOT EXISTS highlights (id TEXT PRIMARY KEY,article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,text TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',tags TEXT NOT NULL DEFAULT '[]',created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS reading_progress (article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,progress REAL NOT NULL,revision INTEGER NOT NULL DEFAULT 0,updated_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS undo_actions (token TEXT PRIMARY KEY,kind TEXT NOT NULL,payload TEXT NOT NULL,expires_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS full_text_cache (article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,status TEXT NOT NULL,content_html TEXT,plain_text TEXT,source_url TEXT,resolved_url TEXT,source_etag TEXT,source_last_modified TEXT,source_content_hash TEXT,confidence INTEGER NOT NULL DEFAULT 0,attempted_at INTEGER NOT NULL DEFAULT 0,retry_after INTEGER NOT NULL DEFAULT 0,failure_message TEXT); CREATE TABLE IF NOT EXISTS offline_translation_cache (article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,request_fingerprint TEXT NOT NULL,translated_text TEXT NOT NULL,detected_source_language TEXT,provider TEXT NOT NULL,model TEXT NOT NULL,target_language TEXT NOT NULL,created_at INTEGER NOT NULL,last_accessed_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,byte_size INTEGER NOT NULL,PRIMARY KEY(article_id,request_fingerprint)); CREATE INDEX IF NOT EXISTS articles_feed_published ON articles(feed_id,published DESC); CREATE INDEX IF NOT EXISTS articles_state ON articles(read,starred,published DESC); CREATE INDEX IF NOT EXISTS offline_translation_cache_expiry ON offline_translation_cache(expires_at); CREATE INDEX IF NOT EXISTS offline_translation_cache_access ON offline_translation_cache(last_accessed_at,created_at);").map_err(db_err)?;
    history::migrate(connection)?;
    for (table, column, definition) in [
        ("feeds", "added_at", "INTEGER NOT NULL DEFAULT 0"),
        (
            "feeds",
            "last_refresh_attempt",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "feeds",
            "refresh_failure_count",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        ("feeds", "next_retry", "INTEGER NOT NULL DEFAULT 0"),
        ("feeds", "issue_stage", "TEXT"),
        ("feeds", "issue_category", "TEXT"),
        ("feeds", "issue_detail", "TEXT"),
        ("articles", "identity", "TEXT NOT NULL DEFAULT ''"),
        ("articles", "read_at", "INTEGER"),
        ("articles", "cover_url", "TEXT"),
        ("reading_progress", "revision", "INTEGER NOT NULL DEFAULT 0"),
    ] {
        ensure_column(connection, table, column, definition)?;
    }
    set_meta(connection, "schema_version", &SCHEMA_VERSION.to_string())?;
    for (key, value) in [
        ("refresh_interval", "1800"),
        ("max_articles", "1000"),
        ("retention_days", "30"),
        ("automatic_pruning", "0"),
        ("feed_body_offline_cache", "1"),
        ("background_refresh", "1"),
        ("background_refresh_minutes", "30"),
        ("automatic_mark_read_end", "0"),
        ("automatic_full_text", "0"),
        ("offline_full_text_refresh", "0"),
        ("remote_images", "0"),
        ("private_network_access", "0"),
        ("offline_translation_cache", "0"),
        ("offline_translation_retention_days", "30"),
        ("offline_translation_max_mib", "100"),
        ("automatic_local_pretranslation_on_refresh", "0"),
    ] {
        connection
            .execute(
                "INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)",
                params![key, value],
            )
            .map_err(db_err)?;
    }
    transaction.commit().map_err(db_err)?;
    Ok(())
}
fn ensure_column(
    connection: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> CommandResult<()> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(db_err)?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(db_err)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_err)?;
    if !names.iter().any(|name| name == column) {
        connection
            .execute_batch(&format!(
                "ALTER TABLE {table} ADD COLUMN {column} {definition}"
            ))
            .map_err(db_err)?;
    }
    Ok(())
}
fn set_meta(connection: &Connection, key: &str, value: &str) -> CommandResult<()> {
    connection.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key, value]).map_err(db_err)?;
    Ok(())
}
fn meta(connection: &Connection, key: &str, fallback: &str) -> CommandResult<String> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key=?", [key], |row| {
            row.get(0)
        })
        .optional()
        .map_err(db_err)?
        .unwrap_or_else(|| fallback.to_owned()))
}
fn preferences_from(connection: &Connection) -> CommandResult<RssPreferences> {
    let seconds = meta(connection, "refresh_interval", "1800")?
        .parse::<u64>()
        .unwrap_or(1800)
        .clamp(60, 21_600);
    let max = meta(connection, "max_articles", "1000")?
        .parse::<u32>()
        .unwrap_or(1000)
        .clamp(1, MAX_ITEMS as u32);
    let retention = meta(connection, "retention_days", "30")?
        .parse::<u32>()
        .unwrap_or(30)
        .clamp(1, 3650);
    Ok(RssPreferences {
        refresh_interval_seconds: seconds,
        max_articles_per_feed: max,
        refresh_interval_minutes: (seconds / 60) as u32,
        retention_days: retention,
        automatic_pruning_enabled: meta(connection, "automatic_pruning", "0")? == "1",
        feed_body_offline_cache_enabled: meta(connection, "feed_body_offline_cache", "1")? == "1",
        background_refresh_enabled: meta(connection, "background_refresh", "1")? == "1",
        background_refresh_interval_minutes: meta(connection, "background_refresh_minutes", "30")?
            .parse::<u32>()
            .unwrap_or(30)
            .clamp(1, 360),
        automatic_mark_read_at_end_enabled: meta(connection, "automatic_mark_read_end", "0")?
            == "1",
        automatic_full_text_extraction_enabled: meta(connection, "automatic_full_text", "0")?
            == "1",
        offline_cache_full_text_on_refresh_enabled: meta(
            connection,
            "offline_full_text_refresh",
            "0",
        )? == "1",
        remote_images_enabled: meta(connection, "remote_images", "0")? == "1",
        private_network_access_enabled: meta(connection, "private_network_access", "0")? == "1",
        offline_translation_cache_enabled: meta(connection, "offline_translation_cache", "0")?
            == "1",
        offline_translation_retention_days: meta(
            connection,
            "offline_translation_retention_days",
            "30",
        )?
        .parse::<u32>()
        .unwrap_or(30)
        .clamp(1, 3650),
        offline_translation_max_mib: meta(connection, "offline_translation_max_mib", "100")?
            .parse::<u32>()
            .unwrap_or(100)
            .clamp(16, 2048),
        automatic_local_pretranslation_on_refresh_enabled: meta(
            connection,
            "automatic_local_pretranslation_on_refresh",
            "0",
        )? == "1",
    })
}
fn refresh_interval(connection: &Connection) -> CommandResult<i64> {
    Ok(preferences_from(connection)?.refresh_interval_seconds as i64)
}
fn require_changed(changed: usize, code: &str, message: &str) -> CommandResult<()> {
    if changed == 1 {
        Ok(())
    } else {
        Err(CommandError::new(code, message))
    }
}
fn lock_err() -> CommandError {
    CommandError::new(
        "rss_storage_unavailable",
        "RSS storage is temporarily unavailable.",
    )
}
fn db_err(error: rusqlite::Error) -> CommandError {
    CommandError::new("rss_storage_error", error.to_string())
}
fn json_err(error: serde_json::Error) -> CommandError {
    CommandError::new("rss_backup_invalid", error.to_string())
}

fn dump_table(c: &Connection, table: &str) -> CommandResult<Vec<serde_json::Value>> {
    let sql = match table {
        "meta" => "SELECT key,value FROM meta",
        "feeds" => "SELECT id,url,title,site_url,etag,last_modified,last_refreshed,next_refresh,added_at,last_refresh_attempt,refresh_failure_count,next_retry,issue_stage,issue_category,issue_detail,issue_at FROM feeds",
        "articles" => "SELECT id,feed_id,identity,guid,title,url,cover_url,author,summary,content,published,fetched,read,read_at,starred,tags FROM articles",
        "highlights" => "SELECT id,article_id,text,note,tags,created_at,updated_at FROM highlights",
        "reading_progress" => "SELECT article_id,progress,revision,updated_at FROM reading_progress",
        "full_text_cache" => "SELECT article_id,status,content_html,plain_text,source_url,resolved_url,source_etag,source_last_modified,source_content_hash,confidence,attempted_at,retry_after,failure_message FROM full_text_cache",
        _ => return Err(CommandError::new("rss_backup_invalid", "Unknown RSS backup table.")),
    };
    let mut statement = c.prepare(sql).map_err(db_err)?;
    let columns: Vec<String> = statement
        .column_names()
        .iter()
        .map(|v| v.to_string())
        .collect();
    let mut rows = statement.query([]).map_err(db_err)?;
    let mut output = Vec::new();
    while let Some(row) = rows.next().map_err(db_err)? {
        let mut object = serde_json::Map::new();
        for (index, name) in columns.iter().enumerate() {
            let value: Value = row.get(index).map_err(db_err)?;
            object.insert(
                name.clone(),
                match value {
                    Value::Null => serde_json::Value::Null,
                    Value::Integer(v) => serde_json::Value::from(v),
                    Value::Real(v) => serde_json::Value::from(v),
                    Value::Text(v) => serde_json::Value::String(v),
                    Value::Blob(v) => serde_json::Value::String(base64::Engine::encode(
                        &base64::engine::general_purpose::STANDARD,
                        v,
                    )),
                },
            );
        }
        output.push(serde_json::Value::Object(object));
    }
    Ok(output)
}
fn load_unread_for_undo(
    tx: &rusqlite::Transaction<'_>,
    feed_id: Option<&str>,
    ids: Option<&Vec<String>>,
) -> CommandResult<Vec<MarkReadUndoArticle>> {
    let mut sql = "SELECT id,read,read_at FROM articles WHERE read=0".to_owned();
    let mut values = Vec::<Value>::new();
    if let Some(feed_id) = feed_id {
        sql.push_str(" AND feed_id=?");
        values.push(Value::Text(feed_id.to_owned()));
    }
    if let Some(ids) = ids {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        sql.push_str(&format!(
            " AND id IN ({})",
            std::iter::repeat_n("?", ids.len())
                .collect::<Vec<_>>()
                .join(",")
        ));
        values.extend(ids.iter().cloned().map(Value::Text));
    }
    let mut statement = tx.prepare(&sql).map_err(db_err)?;
    let rows = statement
        .query_map(rusqlite::params_from_iter(values), |row| {
            Ok(MarkReadUndoArticle {
                id: row.get(0)?,
                read: row.get::<_, i64>(1)? != 0,
                read_at: row.get(2)?,
            })
        })
        .map_err(db_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db_err)
}
fn apply_mark_read(
    tx: &rusqlite::Transaction<'_>,
    rows: Vec<MarkReadUndoArticle>,
) -> CommandResult<(u32, Option<String>)> {
    if rows.is_empty() {
        return Ok((0, None));
    }
    let applied_at = now();
    for row in &rows {
        require_changed(
            tx.execute(
                "UPDATE articles SET read=1,read_at=? WHERE id=? AND read=0",
                params![applied_at, row.id],
            )
            .map_err(db_err)?,
            "rss_undo_conflict",
            "Article changed while marking read.",
        )?;
    }
    let payload = serde_json::to_string(&MarkReadUndo {
        applied_at,
        articles: rows,
    })
    .map_err(json_err)?;
    let token = Uuid::new_v4().to_string();
    tx.execute(
        "INSERT INTO undo_actions(token,kind,payload,expires_at) VALUES(?,?,?,?)",
        params![token, "mark_all_read", payload, now() + UNDO_TTL_SECONDS],
    )
    .map_err(db_err)?;
    Ok((payload_article_count(&payload)?, Some(token)))
}
fn payload_article_count(payload: &str) -> CommandResult<u32> {
    Ok(serde_json::from_str::<MarkReadUndo>(payload)
        .map_err(json_err)?
        .articles
        .len() as u32)
}
fn consume_undo(tx: &rusqlite::Transaction<'_>, token: &str, kind: &str) -> CommandResult<String> {
    if Uuid::parse_str(token).is_err() {
        return Err(CommandError::new(
            "rss_undo_not_found",
            "RSS undo action was not found.",
        ));
    }
    let row: Option<(String, i64)> = tx
        .query_row(
            "SELECT payload,expires_at FROM undo_actions WHERE token=? AND kind=?",
            params![token, kind],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(db_err)?;
    let (payload, expires) = row
        .ok_or_else(|| CommandError::new("rss_undo_not_found", "RSS undo action was not found."))?;
    if expires < now() {
        return Err(CommandError::new(
            "rss_undo_expired",
            "RSS undo action has expired.",
        ));
    }
    require_changed(
        tx.execute(
            "DELETE FROM undo_actions WHERE token=? AND kind=?",
            params![token, kind],
        )
        .map_err(db_err)?,
        "rss_undo_not_found",
        "RSS undo action was not found.",
    )?;
    Ok(payload)
}
fn exists_id(tx: &rusqlite::Transaction<'_>, table: &str, id: &str) -> CommandResult<bool> {
    let sql = match table {
        "feeds" => "SELECT count(*) FROM feeds WHERE id=?",
        "articles" => "SELECT count(*) FROM articles WHERE id=?",
        "highlights" => "SELECT count(*) FROM highlights WHERE id=?",
        "reading_progress" => "SELECT count(*) FROM reading_progress WHERE article_id=?",
        "full_text_cache" => "SELECT count(*) FROM full_text_cache WHERE article_id=?",
        _ => {
            return Err(CommandError::new(
                "rss_undo_invalid",
                "Unknown RSS undo table.",
            ))
        }
    };
    tx.query_row(sql, [id], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .map_err(db_err)
}
fn any_rows_exist(
    tx: &rusqlite::Transaction<'_>,
    table: &str,
    rows: &[serde_json::Value],
) -> CommandResult<bool> {
    for row in rows {
        if exists_id(
            tx,
            table,
            &string_field(
                row,
                if matches!(table, "reading_progress" | "full_text_cache") {
                    "article_id"
                } else {
                    "id"
                },
            )?,
        )? {
            return Ok(true);
        }
    }
    Ok(false)
}
fn validate_removed_feed_undo(undo: &RemovedFeedUndo, allow_private: bool) -> CommandResult<()> {
    if undo.feeds.len() != 1 || undo.feed_id.is_empty() || undo.articles.len() > MAX_ITEMS {
        return Err(CommandError::new(
            "rss_undo_invalid",
            "RSS undo data is invalid.",
        ));
    }
    for (table, rows) in [
        ("feeds", &undo.feeds),
        ("articles", &undo.articles),
        ("highlights", &undo.highlights),
        ("reading_progress", &undo.reading_progress),
        ("full_text_cache", &undo.full_text_cache),
    ] {
        validate_backup_rows(table, rows, allow_private)?;
    }
    if string_field(&undo.feeds[0], "id")? != undo.feed_id {
        return Err(CommandError::new(
            "rss_undo_invalid",
            "RSS undo feed identifier is invalid.",
        ));
    }
    let articles = unique_values(&undo.articles, "id")?;
    for row in &undo.articles {
        if string_field(row, "feed_id")? != undo.feed_id {
            return Err(CommandError::new(
                "rss_undo_invalid",
                "RSS undo article has an unexpected feed.",
            ));
        }
    }
    for rows in [
        &undo.highlights,
        &undo.reading_progress,
        &undo.full_text_cache,
    ] {
        for row in rows {
            if !articles.contains(&string_field(row, "article_id")?) {
                return Err(CommandError::new(
                    "rss_undo_invalid",
                    "RSS undo has a dangling article reference.",
                ));
            }
        }
    }
    Ok(())
}

fn parse_backup(text: &str) -> CommandResult<RssBackup> {
    if text.len() > BACKUP_MAX_BYTES {
        return Err(CommandError::new(
            "rss_backup_too_large",
            "RSS backup exceeds 64 MiB.",
        ));
    }
    let backup: RssBackup = serde_json::from_str(text).map_err(json_err)?;
    if backup.schema_version != BACKUP_SCHEMA_VERSION
        || !matches!(backup.database_schema_version, 2..=4)
    {
        return Err(CommandError::new(
            "rss_backup_version_unsupported",
            "Unsupported RSS backup version.",
        ));
    }
    Ok(backup)
}

fn validate_backup(backup: &RssBackup) -> CommandResult<()> {
    if backup.schema_version != BACKUP_SCHEMA_VERSION
        || !matches!(backup.database_schema_version, 2..=4)
    {
        return Err(CommandError::new(
            "rss_backup_version_unsupported",
            "Unsupported RSS backup version.",
        ));
    }
    let preferences = validate_backup_preferences(&backup.preferences)?;
    for (table, rows) in [
        ("meta", &backup.meta),
        ("feeds", &backup.feeds),
        ("articles", &backup.articles),
        ("highlights", &backup.highlights),
        ("reading_progress", &backup.reading_progress),
        ("full_text_cache", &backup.full_text_cache),
    ] {
        validate_backup_rows(table, rows, preferences.private_network_access_enabled)?;
    }
    let ids = unique_values(&backup.feeds, "id")?;
    unique_values(&backup.feeds, "url")?;
    let article_ids = unique_values(&backup.articles, "id")?;
    unique_article_identities(&backup.articles)?;
    unique_values(&backup.highlights, "id")?;
    unique_values(&backup.reading_progress, "article_id")?;
    unique_values(&backup.full_text_cache, "article_id")?;
    unique_values(&backup.meta, "key")?;
    for article in &backup.articles {
        let feed_id = string_field(article, "feed_id")?;
        if !ids.contains(&feed_id) {
            return Err(CommandError::new(
                "rss_backup_dangling_reference",
                "Article references a missing feed.",
            ));
        }
    }
    for highlight in &backup.highlights {
        if !article_ids.contains(&string_field(highlight, "article_id")?) {
            return Err(CommandError::new(
                "rss_backup_dangling_reference",
                "Highlight references a missing article.",
            ));
        }
    }
    for progress in &backup.reading_progress {
        if !article_ids.contains(&string_field(progress, "article_id")?) {
            return Err(CommandError::new(
                "rss_backup_dangling_reference",
                "Reading progress references a missing article.",
            ));
        }
        let value = progress
            .get("progress")
            .and_then(|v| v.as_f64())
            .ok_or_else(|| {
                CommandError::new(
                    "rss_backup_invalid_progress",
                    "Reading progress is invalid.",
                )
            })?;
        if !value.is_finite() || !(0.0..=1.0).contains(&value) {
            return Err(CommandError::new(
                "rss_backup_invalid_progress",
                "Reading progress is outside 0..1.",
            ));
        }
    }
    for cache in &backup.full_text_cache {
        if !article_ids.contains(&string_field(cache, "article_id")?) {
            return Err(CommandError::new(
                "rss_backup_dangling_reference",
                "Full-text cache references a missing article.",
            ));
        }
    }
    Ok(())
}
fn unique_article_identities(rows: &[serde_json::Value]) -> CommandResult<()> {
    let mut values = HashSet::new();
    for row in rows {
        let key = (
            string_field(row, "feed_id")?,
            string_field(row, "identity")?,
        );
        if !values.insert(key) {
            return Err(CommandError::new(
                "rss_backup_duplicate",
                "RSS backup contains duplicate article identities.",
            ));
        }
    }
    Ok(())
}
fn unique_values(rows: &[serde_json::Value], field: &str) -> CommandResult<HashSet<String>> {
    let mut values = HashSet::new();
    for row in rows {
        let value = string_field(row, field)?;
        if !values.insert(value) {
            return Err(CommandError::new(
                "rss_backup_duplicate",
                "RSS backup contains duplicate identifiers.",
            ));
        }
    }
    Ok(values)
}
fn string_field(row: &serde_json::Value, field: &str) -> CommandResult<String> {
    row.get(field)
        .and_then(|v| v.as_str())
        .filter(|v| !v.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            CommandError::new("rss_backup_structure_invalid", format!("Missing {field}."))
        })
}
fn validate_json_url(value: Option<&serde_json::Value>, allow_private: bool) -> CommandResult<()> {
    let raw = value
        .and_then(|v| v.as_str())
        .ok_or_else(|| CommandError::new("rss_backup_structure_invalid", "Feed URL is missing."))?;
    validate_url(raw, allow_private).map(|_| ())
}
fn backup_summary(backup: &RssBackup) -> RssBackupSummary {
    RssBackupSummary {
        database_schema_version: backup.database_schema_version,
        feed_count: backup.feeds.len() as u32,
        article_count: backup.articles.len() as u32,
        highlight_count: backup.highlights.len() as u32,
        indexed_article_count: backup.articles.len() as u32,
    }
}
fn insert_rows(
    c: &rusqlite::Transaction<'_>,
    table: &str,
    rows: &[serde_json::Value],
) -> CommandResult<()> {
    let (columns, sql) = backup_table_definition(table)?;
    for row in rows {
        let object = row.as_object().ok_or_else(|| {
            CommandError::new(
                "rss_backup_structure_invalid",
                "Backup row is not an object.",
            )
        })?;
        let values: Vec<Value> = columns
            .iter()
            .map(|key| json_to_value(object.get(*key).expect("validated backup key")))
            .collect();
        c.execute(sql, rusqlite::params_from_iter(values))
            .map_err(db_err)?;
    }
    Ok(())
}
fn json_to_value(value: &serde_json::Value) -> Value {
    match value {
        serde_json::Value::Null => Value::Null,
        serde_json::Value::Bool(v) => Value::Integer(i64::from(*v)),
        serde_json::Value::Number(v) => v
            .as_i64()
            .map(Value::Integer)
            .or_else(|| v.as_f64().map(Value::Real))
            .unwrap_or(Value::Null),
        serde_json::Value::String(v) => Value::Text(v.clone()),
        _ => Value::Text(value.to_string()),
    }
}

fn backup_table_definition(table: &str) -> CommandResult<(&'static [&'static str], &'static str)> {
    match table {
        "meta" => Ok((&["key", "value"], "INSERT INTO meta(key,value) VALUES(?,?)")),
        "feeds" => Ok((&["id","url","title","site_url","etag","last_modified","last_refreshed","next_refresh","added_at","last_refresh_attempt","refresh_failure_count","next_retry","issue_stage","issue_category","issue_detail","issue_at"], "INSERT INTO feeds(id,url,title,site_url,etag,last_modified,last_refreshed,next_refresh,added_at,last_refresh_attempt,refresh_failure_count,next_retry,issue_stage,issue_category,issue_detail,issue_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")),
        "articles" => Ok((&["id","feed_id","identity","guid","title","url","cover_url","author","summary","content","published","fetched","read","read_at","starred","tags"], "INSERT INTO articles(id,feed_id,identity,guid,title,url,cover_url,author,summary,content,published,fetched,read,read_at,starred,tags) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")),
        "highlights" => Ok((&["id","article_id","text","note","tags","created_at","updated_at"], "INSERT INTO highlights(id,article_id,text,note,tags,created_at,updated_at) VALUES(?,?,?,?,?,?,?)")),
        "reading_progress" => Ok((&["article_id","progress","revision","updated_at"], "INSERT INTO reading_progress(article_id,progress,revision,updated_at) VALUES(?,?,?,?)")),
        "full_text_cache" => Ok((&["article_id","status","content_html","plain_text","source_url","resolved_url","source_etag","source_last_modified","source_content_hash","confidence","attempted_at","retry_after","failure_message"], "INSERT INTO full_text_cache(article_id,status,content_html,plain_text,source_url,resolved_url,source_etag,source_last_modified,source_content_hash,confidence,attempted_at,retry_after,failure_message) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)")),
        _ => Err(CommandError::new("rss_backup_structure_invalid", "Unknown RSS backup table.")),
    }
}

fn filter_rows(
    rows: Vec<serde_json::Value>,
    field: &str,
    ids: &HashSet<String>,
) -> Vec<serde_json::Value> {
    rows.into_iter()
        .filter(|row| {
            row.get(field)
                .and_then(|value| value.as_str())
                .is_some_and(|id| ids.contains(id))
        })
        .collect()
}

fn validate_backup_rows(
    table: &str,
    rows: &[serde_json::Value],
    allow_private: bool,
) -> CommandResult<()> {
    let (columns, _) = backup_table_definition(table)?;
    if rows.len() > MAX_BACKUP_ROWS {
        return Err(CommandError::new(
            "rss_backup_too_large",
            "RSS backup contains too many rows.",
        ));
    }
    let nullable = [
        "site_url",
        "etag",
        "last_modified",
        "issue_stage",
        "issue_category",
        "issue_detail",
        "url",
        "cover_url",
        "author",
        "read_at",
        "content_html",
        "plain_text",
        "source_url",
        "resolved_url",
        "source_etag",
        "source_last_modified",
        "source_content_hash",
        "failure_message",
    ];
    let integers = [
        "last_refreshed",
        "next_refresh",
        "added_at",
        "last_refresh_attempt",
        "refresh_failure_count",
        "next_retry",
        "issue_at",
        "published",
        "fetched",
        "read",
        "read_at",
        "starred",
        "created_at",
        "updated_at",
        "revision",
        "confidence",
        "attempted_at",
        "retry_after",
    ];
    for row in rows {
        let object = row.as_object().ok_or_else(|| {
            CommandError::new(
                "rss_backup_structure_invalid",
                "Backup row is not an object.",
            )
        })?;
        if object.len() != columns.len()
            || columns.iter().any(|column| !object.contains_key(*column))
            || object.keys().any(|key| !columns.contains(&key.as_str()))
        {
            return Err(CommandError::new(
                "rss_backup_structure_invalid",
                "Backup row has unknown or missing fields.",
            ));
        }
        for column in columns {
            let value = object.get(*column).expect("checked backup key");
            if nullable.contains(column) && value.is_null() {
                continue;
            }
            if integers.contains(column) {
                let number = value.as_i64().ok_or_else(|| {
                    CommandError::new("rss_backup_structure_invalid", "Backup number is invalid.")
                })?;
                if number < 0
                    || matches!(*column, "read" | "starred") && number > 1
                    || *column == "confidence" && number > 1000
                {
                    return Err(CommandError::new(
                        "rss_backup_structure_invalid",
                        "Backup number is outside supported bounds.",
                    ));
                }
            } else if *column == "progress" {
                let progress = value.as_f64().ok_or_else(|| {
                    CommandError::new(
                        "rss_backup_invalid_progress",
                        "Reading progress is invalid.",
                    )
                })?;
                if !progress.is_finite() || !(0.0..=1.0).contains(&progress) {
                    return Err(CommandError::new(
                        "rss_backup_invalid_progress",
                        "Reading progress is outside 0..1.",
                    ));
                }
            } else {
                let text = value.as_str().ok_or_else(|| {
                    CommandError::new("rss_backup_structure_invalid", "Backup text is invalid.")
                })?;
                let limit = if matches!(
                    *column,
                    "summary" | "content" | "content_html" | "plain_text"
                ) {
                    MAX_BACKUP_HTML
                } else {
                    MAX_BACKUP_TEXT
                };
                if text.len() > limit {
                    return Err(CommandError::new(
                        "rss_backup_too_large",
                        "RSS backup text field is too large.",
                    ));
                }
            }
        }
        if table == "feeds" {
            validate_json_url(object.get("url"), allow_private)?;
            validate_optional_backup_url(object.get("site_url"), allow_private)?;
        }
        if table == "articles" {
            validate_optional_backup_url(object.get("url"), allow_private)?;
            validate_optional_backup_url(object.get("cover_url"), allow_private)?;
        }
        if table == "full_text_cache" {
            if !matches!(
                object.get("status").and_then(|v| v.as_str()),
                Some("ready") | Some("failed") | Some("rejected")
            ) {
                return Err(CommandError::new(
                    "rss_backup_invalid_full_text",
                    "Full-text cache status is invalid.",
                ));
            }
            validate_optional_backup_url(object.get("source_url"), allow_private)?;
            validate_optional_backup_url(object.get("resolved_url"), allow_private)?;
        }
        if matches!(table, "articles" | "highlights") {
            validate_tags(object.get("tags").and_then(|value| value.as_str()))?;
        }
        if table == "meta"
            && !matches!(
                object.get("key").and_then(|v| v.as_str()),
                Some(
                    "schema_version"
                        | "refresh_interval"
                        | "max_articles"
                        | "retention_days"
                        | "automatic_pruning"
                        | "feed_body_offline_cache"
                        | "background_refresh"
                        | "background_refresh_minutes"
                        | "automatic_mark_read_end"
                        | "automatic_full_text"
                        | "offline_full_text_refresh"
                        | "remote_images"
                        | "private_network_access"
                        | "offline_translation_cache"
                        | "offline_translation_retention_days"
                        | "offline_translation_max_mib"
                        | "automatic_local_pretranslation_on_refresh"
                )
            )
        {
            return Err(CommandError::new(
                "rss_backup_structure_invalid",
                "Backup preference key is unknown.",
            ));
        }
    }
    Ok(())
}

fn validate_tags(value: Option<&str>) -> CommandResult<()> {
    let tags: Vec<String> =
        serde_json::from_str(value.ok_or_else(|| {
            CommandError::new("rss_backup_structure_invalid", "Tags are missing.")
        })?)
        .map_err(json_err)?;
    if tags.len() > 64 || tags.iter().any(|tag| tag.is_empty() || tag.len() > 128) {
        return Err(CommandError::new(
            "rss_backup_structure_invalid",
            "Tags are invalid.",
        ));
    }
    Ok(())
}
fn validate_optional_backup_url(
    value: Option<&serde_json::Value>,
    allow_private: bool,
) -> CommandResult<()> {
    match value {
        None | Some(serde_json::Value::Null) => Ok(()),
        Some(serde_json::Value::String(value)) => validate_url(value, allow_private).map(|_| ()),
        _ => Err(CommandError::new(
            "rss_backup_structure_invalid",
            "Backup URL is invalid.",
        )),
    }
}
fn validate_backup_preferences(value: &serde_json::Value) -> CommandResult<RssPreferences> {
    let object = value.as_object().ok_or_else(|| {
        CommandError::new(
            "rss_backup_structure_invalid",
            "Backup preferences are invalid.",
        )
    })?;
    let legacy_fields = [
        "refreshIntervalSeconds",
        "maxArticlesPerFeed",
        "refreshIntervalMinutes",
        "retentionDays",
        "automaticPruningEnabled",
        "feedBodyOfflineCacheEnabled",
        "backgroundRefreshEnabled",
        "backgroundRefreshIntervalMinutes",
        "automaticMarkReadAtEndEnabled",
        "automaticFullTextExtractionEnabled",
        "offlineCacheFullTextOnRefreshEnabled",
        "remoteImagesEnabled",
        "privateNetworkAccessEnabled",
    ];
    let fields = [
        "refreshIntervalSeconds",
        "maxArticlesPerFeed",
        "refreshIntervalMinutes",
        "retentionDays",
        "automaticPruningEnabled",
        "feedBodyOfflineCacheEnabled",
        "backgroundRefreshEnabled",
        "backgroundRefreshIntervalMinutes",
        "automaticMarkReadAtEndEnabled",
        "automaticFullTextExtractionEnabled",
        "offlineCacheFullTextOnRefreshEnabled",
        "remoteImagesEnabled",
        "privateNetworkAccessEnabled",
        "offlineTranslationCacheEnabled",
        "offlineTranslationRetentionDays",
        "offlineTranslationMaxMiB",
        "automaticLocalPretranslationOnRefreshEnabled",
    ];
    let is_legacy = object.len() == legacy_fields.len()
        && legacy_fields
            .iter()
            .all(|field| object.contains_key(*field))
        && object
            .keys()
            .all(|key| legacy_fields.contains(&key.as_str()));
    let is_current = object.len() == fields.len()
        && fields.iter().all(|field| object.contains_key(*field))
        && object.keys().all(|key| fields.contains(&key.as_str()));
    if !is_legacy && !is_current {
        return Err(CommandError::new(
            "rss_backup_structure_invalid",
            "Backup preferences have unknown or missing fields.",
        ));
    }
    let preferences: RssPreferences = serde_json::from_value(value.clone()).map_err(json_err)?;
    if !(60..=21_600).contains(&preferences.refresh_interval_seconds)
        || preferences.max_articles_per_feed == 0
        || preferences.max_articles_per_feed > MAX_ITEMS as u32
        || preferences.retention_days == 0
        || preferences.retention_days > 3650
        || !(1..=360).contains(&preferences.background_refresh_interval_minutes)
        || !(1..=3650).contains(&preferences.offline_translation_retention_days)
        || !(16..=2048).contains(&preferences.offline_translation_max_mib)
        || (preferences.automatic_local_pretranslation_on_refresh_enabled
            && !preferences.offline_translation_cache_enabled)
    {
        return Err(CommandError::new(
            "rss_preferences_invalid",
            "Backup preferences are outside supported bounds.",
        ));
    }
    Ok(preferences)
}
fn write_backup_preferences(
    connection: &Connection,
    value: &serde_json::Value,
) -> CommandResult<()> {
    let preferences: RssPreferences = serde_json::from_value(value.clone()).map_err(json_err)?;
    for (key, value) in [
        (
            "refresh_interval",
            preferences.refresh_interval_seconds.to_string(),
        ),
        (
            "max_articles",
            preferences.max_articles_per_feed.to_string(),
        ),
        ("retention_days", preferences.retention_days.to_string()),
        (
            "automatic_pruning",
            bool_meta(preferences.automatic_pruning_enabled),
        ),
        (
            "feed_body_offline_cache",
            bool_meta(preferences.feed_body_offline_cache_enabled),
        ),
        (
            "background_refresh",
            bool_meta(preferences.background_refresh_enabled),
        ),
        (
            "background_refresh_minutes",
            preferences.background_refresh_interval_minutes.to_string(),
        ),
        (
            "automatic_mark_read_end",
            bool_meta(preferences.automatic_mark_read_at_end_enabled),
        ),
        (
            "automatic_full_text",
            bool_meta(preferences.automatic_full_text_extraction_enabled),
        ),
        (
            "offline_full_text_refresh",
            bool_meta(preferences.offline_cache_full_text_on_refresh_enabled),
        ),
        (
            "remote_images",
            bool_meta(preferences.remote_images_enabled),
        ),
        (
            "private_network_access",
            bool_meta(preferences.private_network_access_enabled),
        ),
        (
            "offline_translation_cache",
            bool_meta(preferences.offline_translation_cache_enabled),
        ),
        (
            "offline_translation_retention_days",
            preferences.offline_translation_retention_days.to_string(),
        ),
        (
            "offline_translation_max_mib",
            preferences.offline_translation_max_mib.to_string(),
        ),
        (
            "automatic_local_pretranslation_on_refresh",
            bool_meta(preferences.automatic_local_pretranslation_on_refresh_enabled),
        ),
        ("schema_version", SCHEMA_VERSION.to_string()),
    ] {
        set_meta(connection, key, &value)?;
    }
    Ok(())
}
fn bool_meta(value: bool) -> String {
    if value { "1" } else { "0" }.to_owned()
}
fn is_constraint(error: &rusqlite::Error) -> bool {
    matches!(error, rusqlite::Error::SqliteFailure(code, _) if code.code == rusqlite::ErrorCode::ConstraintViolation)
}
fn now() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs() as i64,
        Err(_) => 0,
    }
}
fn feed_content_for_storage(enabled: bool, content: String) -> String {
    if enabled {
        content
    } else {
        String::new()
    }
}
fn should_cache_full_text_on_refresh(enabled: bool, has_safe_candidate_url: bool) -> bool {
    enabled && has_safe_candidate_url
}
fn nonempty_or<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.is_empty() {
        fallback
    } else {
        value
    }
}
fn clean_text(value: String) -> String {
    value.trim().chars().take(4096).collect()
}
fn normalise_tags(tags: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    tags.into_iter()
        .map(clean_text)
        .filter(|tag| !tag.is_empty() && seen.insert(tag.to_lowercase()))
        .collect()
}
fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('\"', "&quot;")
        .replace('\'', "&apos;")
}
fn extract_readable_html(html: &str) -> (String, String, f64) {
    let cleaned = remove_reader_chrome(html);
    let (candidate, structural_bonus) = find_html_element(&cleaned, "article")
        .map(|value| (value, 0.25))
        .or_else(|| find_html_element(&cleaned, "main").map(|value| (value, 0.15)))
        .unwrap_or((&cleaned, 0.0));
    let content_html = truncate_utf8(reader_safe_html(candidate), MAX_FULL_TEXT_HTML);
    let plain_text = truncate_utf8(html_text(&content_html), MAX_FULL_TEXT_PLAIN);
    let word_score = (plain_text.split_whitespace().count() as f64 / 300.0).min(0.75);
    let density = if content_html.is_empty() {
        0.0
    } else {
        (plain_text.len() as f64 / content_html.len() as f64).min(1.0) * 0.05
    };
    (
        content_html,
        plain_text,
        (word_score + structural_bonus + density).min(1.0),
    )
}
fn remove_reader_chrome(html: &str) -> String {
    let mut cleaned = html.to_owned();
    for tag in [
        "script", "style", "noscript", "template", "svg", "nav", "header", "footer", "aside",
        "form", "iframe", "object", "embed",
    ] {
        cleaned = remove_html_element(&cleaned, tag);
    }
    cleaned
}
fn reader_safe_html(html: &str) -> String {
    let cleaned = remove_reader_chrome(html);
    let allowed = [
        "p",
        "br",
        "hr",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "blockquote",
        "pre",
        "code",
        "ul",
        "ol",
        "li",
        "strong",
        "em",
        "b",
        "i",
        "table",
        "thead",
        "tbody",
        "tr",
        "th",
        "td",
        "figure",
        "figcaption",
    ];
    let mut output = String::with_capacity(cleaned.len().min(MAX_FULL_TEXT_HTML));
    let mut cursor = 0;
    while let Some(offset) = cleaned[cursor..].find('<') {
        let start = cursor + offset;
        output.push_str(&cleaned[cursor..start]);
        let Some(end_offset) = cleaned[start..].find('>') else {
            output.push_str(&cleaned[start..]);
            cursor = cleaned.len();
            break;
        };
        let end = start + end_offset;
        let raw = cleaned[start + 1..end].trim();
        let closing = raw.starts_with('/');
        let name = raw
            .trim_start_matches('/')
            .trim_start_matches('!')
            .trim_start_matches('?')
            .chars()
            .take_while(|character| character.is_ascii_alphanumeric())
            .collect::<String>()
            .to_ascii_lowercase();
        if allowed.contains(&name.as_str()) {
            if closing {
                output.push_str("</");
                output.push_str(&name);
                output.push('>');
            } else if name == "br" || name == "hr" {
                output.push('<');
                output.push_str(&name);
                output.push_str(">\n");
            } else {
                // Attributes are intentionally discarded.  This also drops event
                // handlers, javascript: links, and remote-image URLs.
                output.push('<');
                output.push_str(&name);
                output.push('>');
            }
        }
        cursor = end + 1;
    }
    if cursor < cleaned.len() {
        output.push_str(&cleaned[cursor..]);
    }
    output
}
fn html_text(html: &str) -> String {
    let mut output = String::new();
    let mut inside = false;
    for character in html.chars() {
        match character {
            '<' => {
                inside = true;
                output.push(' ');
            }
            '>' => inside = false,
            _ if !inside => output.push(character),
            _ => {}
        }
    }
    output.split_whitespace().collect::<Vec<_>>().join(" ")
}
fn find_html_element<'a>(input: &'a str, tag: &str) -> Option<&'a str> {
    let lower = input.to_ascii_lowercase();
    let needle = format!("<{tag}");
    let mut cursor = 0;
    let start = loop {
        let start = cursor + lower[cursor..].find(&needle)?;
        let next = lower.as_bytes().get(start + needle.len()).copied();
        if next.is_none_or(|byte| byte == b'>' || byte == b'/' || byte.is_ascii_whitespace()) {
            break start;
        }
        cursor = start + needle.len();
    };
    let opening_end = start + lower[start..].find('>')?;
    let after_open = opening_end + 1;
    let close = after_open + lower[after_open..].find(&format!("</{tag}>"))?;
    Some(&input[start..close + tag.len() + 3])
}
fn truncate_utf8(mut value: String, maximum: usize) -> String {
    if value.len() <= maximum {
        return value;
    }
    let mut end = maximum;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value.truncate(end);
    value
}
fn remove_html_element(input: &str, tag: &str) -> String {
    let lower = input.to_ascii_lowercase();
    let mut output = String::new();
    let mut cursor = 0;
    while let Some(offset) = lower[cursor..].find(&format!("<{tag}")) {
        let start = cursor + offset;
        output.push_str(&input[cursor..start]);
        let Some(close_offset) = lower[start..].find(&format!("</{tag}>")) else {
            return output;
        };
        cursor = start + close_offset + tag.len() + 3;
    }
    output.push_str(&input[cursor..]);
    output
}
// This adapter mirrors the fixed full-text cache columns in the renderer contract.
#[allow(clippy::too_many_arguments)]
fn full_text_json(
    article_id: &str,
    status: &str,
    html: Option<String>,
    text: Option<String>,
    source_url: Option<String>,
    resolved_url: Option<String>,
    etag: Option<String>,
    last_modified: Option<String>,
    confidence: f64,
    retry_after: i64,
    failure: Option<String>,
) -> serde_json::Value {
    serde_json::json!({"articleId":article_id,"status":status,"contentHtml":html.unwrap_or_default(),"plainText":text.unwrap_or_default(),"sourceUrl":source_url,"resolvedUrl":resolved_url,"extractorIdentifier":"builtin-html","extractorVersion":"1","sourceEtag":etag,"sourceLastModified":last_modified,"sourceContentHash":serde_json::Value::Null,"confidence":confidence,"attemptedAt":now(),"retryAfter":if retry_after>0 {serde_json::Value::from(retry_after)} else {serde_json::Value::Null},"failureMessage":failure})
}
fn cache_full_text_state(
    db: &Mutex<Connection>,
    article_id: &str,
    status: &str,
    source_url: &str,
    retry_after: i64,
    failure: &str,
) -> CommandResult<serde_json::Value> {
    let connection = db.lock().map_err(|_| lock_err())?;
    connection.execute("INSERT INTO full_text_cache(article_id,status,source_url,confidence,attempted_at,retry_after,failure_message) VALUES(?,?,?,?,?,?,?) ON CONFLICT(article_id) DO UPDATE SET status=excluded.status,source_url=excluded.source_url,content_html=NULL,plain_text=NULL,confidence=0,attempted_at=excluded.attempted_at,retry_after=excluded.retry_after,failure_message=excluded.failure_message", params![article_id,status,source_url,0_i64,now(),retry_after,failure]).map_err(db_err)?;
    Ok(full_text_json(
        article_id,
        status,
        None,
        None,
        Some(source_url.to_owned()),
        None,
        None,
        None,
        0.0,
        retry_after,
        Some(failure.to_owned()),
    ))
}
fn header_text(headers: &reqwest::header::HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned)
}
fn candidate(
    url: &Url,
    title: Option<String>,
    content_type: Option<String>,
) -> RssDiscoveryCandidate {
    RssDiscoveryCandidate {
        url: url.to_string(),
        title,
        content_type,
    }
}
fn reject_symlink(path: &Path) -> CommandResult<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CommandError::io("rss_storage_unavailable", "inspect RSS storage", error)
    })?;
    if metadata.file_type().is_symlink() {
        return Err(CommandError::new(
            "rss_storage_rejected",
            "RSS storage symlinks are not allowed.",
        ));
    }
    Ok(())
}
#[cfg(unix)]
fn set_private_dir(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
        CommandError::io(
            "rss_storage_unavailable",
            "secure RSS storage directory",
            error,
        )
    })
}
#[cfg(not(unix))]
fn set_private_dir(_path: &Path) -> CommandResult<()> {
    Ok(())
}
#[cfg(unix)]
fn set_private_file(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        CommandError::io("rss_storage_unavailable", "secure RSS storage file", error)
    })
}
#[cfg(not(unix))]
fn set_private_file(_path: &Path) -> CommandResult<()> {
    Ok(())
}

fn validate_url(raw: &str, allow_private: bool) -> CommandResult<Url> {
    if raw.len() > 8192 || raw.chars().any(char::is_control) {
        return Err(CommandError::new("rss_url_invalid", "RSS URL is invalid."));
    }
    let url =
        Url::parse(raw).map_err(|_| CommandError::new("rss_url_invalid", "RSS URL is invalid."))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(CommandError::new(
            "rss_url_rejected",
            "Only credential-free HTTP(S) feed URLs are allowed.",
        ));
    }
    if let Some(host) = url.host() {
        let address = match host {
            Host::Ipv4(value) => Some(IpAddr::V4(value)),
            Host::Ipv6(value) => Some(IpAddr::V6(value)),
            Host::Domain(_) => None,
        };
        if let Some(address) = address {
            if unsafe_address(address, allow_private) {
                return Err(CommandError::new(
                    "rss_url_rejected",
                    "This RSS host resolves to a disallowed network address.",
                ));
            }
        }
    }
    Ok(url)
}
fn safe_socket_addresses(url: &Url, allow_private: bool) -> CommandResult<Vec<SocketAddr>> {
    let host = url
        .host_str()
        .ok_or_else(|| CommandError::new("rss_url_invalid", "RSS URL has no host."))?;
    let port = url.port_or_known_default().unwrap_or(80);
    let addresses = match url.host() {
        Some(Host::Ipv4(address)) => vec![SocketAddr::new(IpAddr::V4(address), port)],
        Some(Host::Ipv6(address)) => vec![SocketAddr::new(IpAddr::V6(address), port)],
        _ => (host, port)
            .to_socket_addrs()
            .map_err(|_| CommandError::new("rss_dns_failed", "RSS host could not be resolved."))?
            .collect::<Vec<_>>(),
    };
    if addresses.is_empty() {
        return Err(CommandError::new(
            "rss_dns_failed",
            "RSS host could not be resolved.",
        ));
    }
    if addresses
        .iter()
        .any(|address| unsafe_address(address.ip(), allow_private))
    {
        return Err(CommandError::new(
            "rss_url_rejected",
            "This RSS host resolves to a disallowed network address.",
        ));
    }
    Ok(addresses)
}
fn normalize_address(address: IpAddr) -> IpAddr {
    match address {
        IpAddr::V6(value) => value.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(address),
        _ => address,
    }
}
fn unsafe_address(address: IpAddr, allow_private: bool) -> bool {
    match normalize_address(address) {
        IpAddr::V4(value) => {
            value.is_loopback()
                || value.is_unspecified()
                || value.is_multicast()
                || (!allow_private && (value.is_private() || value.is_link_local()))
        }
        IpAddr::V6(value) => {
            value.is_loopback()
                || value.is_unspecified()
                || value.is_multicast()
                || (!allow_private && (value.is_unique_local() || value.is_unicast_link_local()))
        }
    }
}
#[cfg(test)]
type RssFetchResponse = (Url, StatusCode, reqwest::header::HeaderMap, Vec<u8>);
#[cfg(test)]
type TestFeedTransport =
    dyn Fn(&Url, bool, Option<&str>, Option<&str>) -> CommandResult<RssFetchResponse> + Send + Sync;

fn fetch_bounded(
    initial: &Url,
    private: bool,
    etag: Option<&str>,
    modified: Option<&str>,
) -> CommandResult<(Url, StatusCode, reqwest::header::HeaderMap, Vec<u8>)> {
    fetch_bounded_with_limit(
        initial,
        private,
        etag,
        modified,
        MAX_XML,
        "RSS response exceeds 20 MiB.",
    )
}
fn fetch_bounded_with_limit(
    initial: &Url,
    private: bool,
    etag: Option<&str>,
    modified: Option<&str>,
    maximum_bytes: usize,
    limit_message: &str,
) -> CommandResult<(Url, StatusCode, reqwest::header::HeaderMap, Vec<u8>)> {
    fetch_bounded_scoped(
        initial,
        private,
        etag,
        modified,
        maximum_bytes,
        limit_message,
        None,
    )
}
struct RssFetchScope<'a> {
    origin: &'a Url,
    robots: Option<&'a str>,
    check_active: Option<&'a dyn Fn() -> CommandResult<()>>,
}

fn fetch_bounded_scoped(
    initial: &Url,
    private: bool,
    etag: Option<&str>,
    modified: Option<&str>,
    maximum_bytes: usize,
    limit_message: &str,
    origin: Option<&RssFetchScope<'_>>,
) -> CommandResult<(Url, StatusCode, reqwest::header::HeaderMap, Vec<u8>)> {
    let mut target = initial.clone();
    let redirect_limit = if origin.is_some() { 2 } else { 5 };
    for hop in 0..=redirect_limit {
        if let Some(scope) = origin {
            if let Some(check) = scope.check_active {
                check()?;
            }
            history::check_history_url(&target, scope.origin)?;
            if scope
                .robots
                .is_some_and(|rules| !history::robots_allowed(rules, &target))
            {
                return Err(CommandError::new(
                    "rss_history_policy",
                    "History redirect disallowed by robots policy.",
                ));
            }
            if hop > 0 {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        // Resolve once, validate every candidate, and pin this hop to those exact
        // addresses. This closes the DNS-rebinding window between policy check
        // and reqwest's connection lookup. Environment proxies are disabled so
        // the destination cannot be swapped outside this resolver override.
        let addresses = safe_socket_addresses(&target, private)?;
        if let Some(check) = origin.and_then(|scope| scope.check_active) {
            check()?;
        }
        let host = target
            .host_str()
            .ok_or_else(|| CommandError::new("rss_url_invalid", "RSS URL has no host."))?;
        let mut builder = Client::builder()
            .timeout(Duration::from_secs(if origin.is_some() { 20 } else { 60 }))
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy();
        if origin.is_some() {
            builder = builder.user_agent("RepoPress/0.1 RSS History Import");
        }
        if matches!(target.host(), Some(Host::Domain(_))) {
            builder = builder.resolve_to_addrs(host, &addresses);
        }
        let client = builder
            .build()
            .map_err(|error| CommandError::new("rss_transport_error", error.to_string()))?;
        let mut request = client.get(target.clone());
        if hop == 0 {
            if let Some(value) = etag {
                request = request.header(IF_NONE_MATCH, value);
            }
            if let Some(value) = modified {
                request = request.header(IF_MODIFIED_SINCE, value);
            }
        }
        let mut response = request
            .send()
            .map_err(|error| CommandError::new("rss_transport_error", error.to_string()))?;
        let peer = response.remote_addr().ok_or_else(|| {
            CommandError::new(
                "rss_peer_unverified",
                "RSS connection peer address could not be verified.",
            )
        })?;
        if unsafe_address(peer.ip(), private)
            || !addresses
                .iter()
                .any(|address| normalize_address(address.ip()) == normalize_address(peer.ip()))
        {
            return Err(CommandError::new(
                "rss_url_rejected",
                "RSS connection reached an unapproved network address.",
            ));
        }
        let status = response.status();
        let headers = response.headers().clone();
        if status.is_redirection() {
            if hop == redirect_limit {
                return Err(CommandError::new(
                    "rss_redirect_rejected",
                    "RSS redirect limit was exceeded.",
                ));
            }
            let location = header_text(&headers, LOCATION.as_str()).ok_or_else(|| {
                CommandError::new("rss_redirect_rejected", "RSS redirect had no destination.")
            })?;
            let next = target.join(&location).map_err(|_| {
                CommandError::new(
                    "rss_redirect_rejected",
                    "RSS redirect destination was invalid.",
                )
            })?;
            target = validate_url(next.as_str(), private)?;
            continue;
        }
        let mut body = Vec::new();
        let mut chunk = [0_u8; 16 * 1024];
        loop {
            let read = response
                .read(&mut chunk)
                .map_err(|error| CommandError::new("rss_transport_error", error.to_string()))?;
            if read == 0 {
                break;
            }
            if body.len().saturating_add(read) > maximum_bytes {
                return Err(CommandError::new("rss_response_too_large", limit_message));
            }
            body.extend_from_slice(&chunk[..read]);
        }
        return Ok((target, status, headers, body));
    }
    Err(CommandError::new(
        "rss_redirect_rejected",
        "RSS redirect limit was exceeded.",
    ))
}

fn supported_cover_mime(value: &str) -> Option<&'static str> {
    match value
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "image/jpeg" | "image/jpg" => Some("image/jpeg"),
        "image/png" => Some("image/png"),
        "image/webp" => Some("image/webp"),
        "image/x-icon" | "image/vnd.microsoft.icon" => Some("image/x-icon"),
        _ => None,
    }
}

fn valid_cover_image(mime: &str, body: &[u8]) -> bool {
    cover_dimensions(mime, body).is_some_and(|(width, height)| {
        width > 0
            && height > 0
            && width <= MAX_COVER_DIMENSION
            && height <= MAX_COVER_DIMENSION
            && u64::from(width) * u64::from(height) <= MAX_COVER_PIXELS
    })
}

fn cover_dimensions(mime: &str, body: &[u8]) -> Option<(u32, u32)> {
    match mime {
        "image/png"
            if body.starts_with(b"\x89PNG\r\n\x1a\n")
                && body.len() >= 24
                && &body[12..16] == b"IHDR"
                && !body.windows(4).any(|window| window == b"acTL") =>
        {
            Some((
                u32::from_be_bytes(body[16..20].try_into().ok()?),
                u32::from_be_bytes(body[20..24].try_into().ok()?),
            ))
        }
        "image/jpeg" => jpeg_dimensions(body),
        "image/webp" => webp_dimensions(body),
        "image/x-icon" if body.len() >= 8 && body[..4] == [0, 0, 1, 0] && body[4..6] != [0, 0] => {
            Some((
                if body[6] == 0 {
                    256
                } else {
                    u32::from(body[6])
                },
                if body[7] == 0 {
                    256
                } else {
                    u32::from(body[7])
                },
            ))
        }
        _ => None,
    }
}

fn jpeg_dimensions(body: &[u8]) -> Option<(u32, u32)> {
    if !body.starts_with(&[0xff, 0xd8, 0xff]) {
        return None;
    }
    let mut index = 2;
    while index + 3 < body.len() {
        if body[index] != 0xff {
            index += 1;
            continue;
        }
        while index < body.len() && body[index] == 0xff {
            index += 1;
        }
        let marker = *body.get(index)?;
        index += 1;
        if marker == 0xd9 || marker == 0xda {
            return None;
        }
        if marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        let length = usize::from(u16::from_be_bytes([
            *body.get(index)?,
            *body.get(index + 1)?,
        ]));
        if length < 2 || index.checked_add(length)? > body.len() {
            return None;
        }
        if matches!(
            marker,
            0xc0 | 0xc1
                | 0xc2
                | 0xc3
                | 0xc5
                | 0xc6
                | 0xc7
                | 0xc9
                | 0xca
                | 0xcb
                | 0xcd
                | 0xce
                | 0xcf
        ) && length >= 7
        {
            let height = u32::from(u16::from_be_bytes([body[index + 3], body[index + 4]]));
            let width = u32::from(u16::from_be_bytes([body[index + 5], body[index + 6]]));
            return Some((width, height));
        }
        index += length;
    }
    None
}

fn webp_dimensions(body: &[u8]) -> Option<(u32, u32)> {
    if body.len() < 20
        || !body.starts_with(b"RIFF")
        || &body[8..12] != b"WEBP"
        || body
            .windows(4)
            .any(|window| window == b"ANIM" || window == b"ANMF")
    {
        return None;
    }
    let mut offset = 12_usize;
    while offset + 8 <= body.len() {
        let chunk = &body[offset..offset + 4];
        let length = u32::from_le_bytes(body[offset + 4..offset + 8].try_into().ok()?) as usize;
        let data = offset + 8;
        let end = data.checked_add(length)?;
        if end > body.len() {
            return None;
        }
        let dimensions = match chunk {
            b"VP8X" if length >= 10 && body[data] & 0x02 == 0 => Some((
                1 + u32::from(body[data + 4])
                    + (u32::from(body[data + 5]) << 8)
                    + (u32::from(body[data + 6]) << 16),
                1 + u32::from(body[data + 7])
                    + (u32::from(body[data + 8]) << 8)
                    + (u32::from(body[data + 9]) << 16),
            )),
            b"VP8L" if length >= 5 && body[data] == 0x2f => Some((
                1 + u32::from(body[data + 1]) + (u32::from(body[data + 2] & 0x3f) << 8),
                1 + (u32::from(body[data + 2]) >> 6)
                    + (u32::from(body[data + 3]) << 2)
                    + (u32::from(body[data + 4] & 0x0f) << 10),
            )),
            b"VP8 " if length >= 10 && body[data + 3..data + 6] == [0x9d, 0x01, 0x2a] => Some((
                u32::from(u16::from_le_bytes([body[data + 6], body[data + 7]]) & 0x3fff),
                u32::from(u16::from_le_bytes([body[data + 8], body[data + 9]]) & 0x3fff),
            )),
            _ => None,
        };
        if dimensions.is_some() {
            return dimensions;
        }
        offset = end.checked_add(length & 1)?;
    }
    None
}

fn load_feeds(connection: &Connection) -> CommandResult<Vec<RssFeed>> {
    let mut statement = connection.prepare("SELECT id,url,title,site_url,etag,last_modified,last_refreshed,next_refresh,issue_stage,issue_category,issue_detail,issue_at,next_retry,(SELECT count(*) FROM articles a WHERE a.feed_id=f.id AND a.read=0),added_at,refresh_failure_count FROM feeds f ORDER BY title,id").map_err(db_err)?;
    let rows = statement
        .query_map([], |row| {
            let stage: Option<String> = row.get(8)?;
            let detail: Option<String> = row.get(10)?;
            let at: i64 = row.get(11)?;
            let retry: i64 = row.get(12)?;
            Ok(RssFeed {
                id: row.get(0)?,
                url: row.get(1)?,
                title: row.get(2)?,
                site_url: row.get(3)?,
                etag: row.get(4)?,
                last_modified: row.get(5)?,
                last_refreshed_at: row.get(6)?,
                next_refresh_at: row.get(7)?,
                issue: stage.map(|stage| {
                    let category = row
                        .get::<_, Option<String>>(9)
                        .ok()
                        .flatten()
                        .unwrap_or_else(|| "unknown".to_owned());
                    let detail = detail.unwrap_or_else(|| "Feed refresh failed.".to_owned());
                    RssIssue {
                        stage,
                        category,
                        retry_strategy: "afterDate".to_owned(),
                        retry_at: if retry > 0 { Some(retry) } else { None },
                        user_message: "This feed could not be refreshed.".to_owned(),
                        technical_detail: detail.clone(),
                        occurred_at: at,
                        code: "rss_refresh_failed".to_owned(),
                        message: detail,
                        at,
                    }
                }),
                unread_count: row.get::<_, i64>(13)? as u32,
                added_at: row.get(14)?,
                refresh_failure_count: row.get::<_, i64>(15)? as u32,
                next_retry_at: if retry > 0 { Some(retry) } else { None },
            })
        })
        .map_err(db_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db_err)
}
fn load_feed(connection: &Connection, id: &str) -> CommandResult<RssFeed> {
    load_feeds(connection)?
        .into_iter()
        .find(|feed| feed.id == id)
        .ok_or_else(|| CommandError::new("rss_feed_not_found", "RSS feed not found."))
}
fn load_article(connection: &Connection, id: &str) -> CommandResult<Option<RssArticle>> {
    connection.query_row("SELECT id,feed_id,guid,title,url,cover_url,author,summary,content,published,fetched,read,read_at,starred,tags FROM articles WHERE id=?", [id], |row| { let tags: String = row.get(14)?; Ok(RssArticle { id: row.get(0)?, feed_id: row.get(1)?, guid: row.get(2)?, title: row.get(3)?, url: row.get(4)?, cover_url: row.get(5)?, author: row.get(6)?, summary: row.get(7)?, content: row.get(8)?, published_at: row.get(9)?, fetched_at: row.get(10)?, read: row.get::<_, i64>(11)? != 0, read_at: row.get(12)?, starred: row.get::<_, i64>(13)? != 0, tags: serde_json::from_str(&tags).unwrap_or_default() }) }).optional().map_err(db_err)
}
fn article_filter(query: &RssArticleQuery) -> CommandResult<(String, Vec<Value>)> {
    let mut conditions: Vec<String> = Vec::new();
    let mut values = Vec::new();
    match query.scope.as_str() {
        "unread" => conditions.push("read=0".to_owned()),
        "starred" => conditions.push("starred=1".to_owned()),
        "feed" => {
            conditions.push("feed_id=?".to_owned());
            values.push(Value::Text(query.feed_id.clone().unwrap_or_default()));
        }
        _ => {}
    }
    if query.scope != "feed" {
        if let Some(feed_id) = &query.feed_id {
            conditions.push("feed_id=?".to_owned());
            values.push(Value::Text(feed_id.clone()));
        }
    }
    for (column, value) in [
        ("coalesce(author,'')", query.author.as_deref()),
        ("tags", query.tag.as_deref()),
    ] {
        if let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) {
            conditions.push(format!("{column} LIKE ? ESCAPE '\\'"));
            values.push(Value::Text(like_pattern(value)));
        }
    }
    if let Some(text) = query
        .query
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if text.len() > 512 {
            return Err(CommandError::new(
                "rss_query_invalid",
                "Article search text is too long.",
            ));
        }
        conditions.push("(title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' OR coalesce(author,'') LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\')".to_owned());
        let pattern = like_pattern(text);
        for _ in 0..5 {
            values.push(Value::Text(pattern.clone()));
        }
    }
    let where_sql = if conditions.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", conditions.join(" AND "))
    };
    Ok((where_sql, values))
}
fn like_pattern(value: &str) -> String {
    format!(
        "%{}%",
        value
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    )
}

#[derive(Default, Clone)]
struct Parsed {
    identity: String,
    guid: String,
    title: String,
    url: Option<String>,
    cover_url: Option<String>,
    author: Option<String>,
    summary: String,
    content: String,
    summary_priority: u8,
    content_priority: u8,
    published: i64,
    published_provided: bool,
}
fn local_name(name: &[u8]) -> String {
    String::from_utf8_lossy(name)
        .rsplit(':')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
}
fn parse_xml(bytes: &[u8], base: &Url) -> CommandResult<Vec<Parsed>> {
    if bytes.len() > MAX_XML {
        return Err(CommandError::new(
            "rss_response_too_large",
            "RSS response exceeds 20 MiB.",
        ));
    }
    let invalid_xml = || CommandError::new("rss_xml_invalid", "RSS feed XML is invalid.");
    let mut reader = NsReader::from_reader(bytes);
    // Captured bodies need whitespace between text runs and nested inline elements.
    reader.config_mut().trim_text(false);
    reader.config_mut().expand_empty_elements = true;
    let mut buffer = Vec::new();
    let mut stack: Vec<feed_body::Element> = Vec::new();
    let mut kind: Option<&str> = None;
    let mut core_namespace = None;
    let mut item: Option<Parsed> = None;
    let mut item_depth = None;
    let mut body: Option<feed_body::Capture> = None;
    let mut items = Vec::new();
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::DocType(_)) => {
                return Err(CommandError::new(
                    "rss_xml_rejected",
                    "RSS feeds may not contain DTDs or entity references.",
                ));
            }
            Ok(Event::Start(event)) => {
                if stack.len() >= MAX_DEPTH {
                    return Err(CommandError::new(
                        "rss_xml_rejected",
                        "RSS XML nesting is too deep.",
                    ));
                }
                let (namespace, name) = reader.resolve_element(event.name());
                let key = feed_body::Element::resolved(namespace, name.as_ref())?;
                // Validate even attributes that are not product fields.
                for value in event.attributes() {
                    value
                        .map_err(|_| invalid_xml())?
                        .unescape_value()
                        .map_err(|_| invalid_xml())?;
                }
                if let Some(capture) = body.as_mut() {
                    capture.start(&key, &event)?;
                } else {
                    if stack.is_empty() {
                        if kind.is_some() {
                            return Err(invalid_xml());
                        }
                        kind = match key.name.as_str() {
                            "rss" => {
                                core_namespace = key.namespace.clone();
                                Some("rss")
                            }
                            "feed"
                                if matches!(
                                    key.namespace.as_deref(),
                                    None | Some(feed_body::ATOM)
                                ) =>
                            {
                                core_namespace = key.namespace.clone();
                                Some("atom")
                            }
                            "rdf" => {
                                core_namespace = Some(feed_body::RSS1.to_owned());
                                Some("rdf")
                            }
                            _ => {
                                return Err(CommandError::new(
                                    "rss_feed_invalid",
                                    "Document is not an RSS 2, Atom, or RDF feed.",
                                ))
                            }
                        };
                    }
                    let atom = kind == Some("atom");
                    let core = key.core(atom, core_namespace.as_deref());
                    let article_parent = if atom {
                        stack.len() == 1 && stack[0].name == "feed"
                    } else {
                        stack.len() == 2
                            && stack[1].name == "channel"
                            && stack[1].core(false, core_namespace.as_deref())
                            || kind == Some("rdf") && stack.len() == 1
                    };
                    if core && article_parent && matches!(key.name.as_str(), "item" | "entry") {
                        if (atom && key.name != "entry") || (!atom && key.name != "item") {
                            return Err(CommandError::new(
                                "rss_feed_invalid",
                                "Feed contains an invalid item type.",
                            ));
                        }
                        item = Some(Parsed::default());
                        item_depth = Some(stack.len() + 1);
                    } else if item.is_some() && item_depth == Some(stack.len()) {
                        body = feed_body::Capture::new(
                            &key,
                            &event,
                            stack.len() + 1,
                            atom,
                            core_namespace.as_deref(),
                        )?;
                        if body.is_none() {
                            let article = item.as_mut().ok_or_else(invalid_xml)?;
                            if core && key.name == "link" {
                                let relation = feed_body::value(&event, b"rel")?
                                    .unwrap_or_else(|| "alternate".into());
                                if relation == "alternate" || relation.is_empty() {
                                    if let Some(href) = feed_body::value(&event, b"href")? {
                                        article.url = resolve_article_url(base, &href);
                                    }
                                }
                            }
                            let media = key.namespace.as_deref() == Some(feed_body::MEDIA);
                            if (media || !atom && core)
                                && matches!(
                                    key.name.as_str(),
                                    "enclosure" | "content" | "thumbnail" | "image"
                                )
                                && article.cover_url.is_none()
                            {
                                if let Some(value) = feed_body::value(&event, b"url")?
                                    .or(feed_body::value(&event, b"href")?)
                                {
                                    article.cover_url = resolve_article_url(base, &value);
                                }
                            }
                        }
                    }
                }
                stack.push(key);
            }
            Ok(Event::Text(event)) => {
                let value = event.unescape().map_err(|_| invalid_xml())?;
                if let Some(capture) = body.as_mut() {
                    capture.text(&value)?;
                } else if let Some(field) = feed_metadata_field(
                    &stack,
                    item_depth,
                    kind == Some("atom"),
                    core_namespace.as_deref(),
                ) {
                    assign_field(item.as_mut(), field, &value);
                }
            }
            Ok(Event::CData(event)) => {
                let value = std::str::from_utf8(event.as_ref()).map_err(|_| invalid_xml())?;
                if let Some(capture) = body.as_mut() {
                    capture.text(value)?;
                } else if let Some(field) = feed_metadata_field(
                    &stack,
                    item_depth,
                    kind == Some("atom"),
                    core_namespace.as_deref(),
                ) {
                    assign_field(item.as_mut(), field, value);
                }
            }
            Ok(Event::End(_)) => {
                let depth = stack.len();
                if body.as_ref().is_some_and(|capture| capture.depth == depth) {
                    let capture = body.take().ok_or_else(invalid_xml)?;
                    let summary = capture.summary;
                    let priority = capture.priority;
                    if let Some(html) = capture.finish() {
                        let article = item.as_mut().ok_or_else(invalid_xml)?;
                        if summary
                            && (article.summary.is_empty() || priority > article.summary_priority)
                        {
                            article.summary = html;
                            article.summary_priority = priority;
                        } else if !summary
                            && (article.content.is_empty() || priority > article.content_priority)
                        {
                            article.content = html;
                            article.content_priority = priority;
                        }
                    }
                } else if let Some(capture) = body.as_mut() {
                    capture.end()?;
                } else if item_depth == Some(depth) {
                    if let Some(mut article) = item.take() {
                        article.title = clean_text(article.title);
                        if !article.title.is_empty() {
                            if article.content.is_empty() {
                                article.content = article.summary.clone();
                            }
                            article.published_provided = article.published > 0;
                            if article.published == 0 {
                                article.published = now();
                            }
                            let discriminator =
                                article.url.clone().unwrap_or_else(|| article.title.clone());
                            if article.guid.is_empty() {
                                article.guid = discriminator.clone();
                            }
                            article.identity = format!("{}\u{0}{}", article.guid, discriminator);
                            items.push(article);
                            if items.len() > MAX_ITEMS {
                                return Err(CommandError::new(
                                    "rss_feed_too_large",
                                    "RSS feed has too many articles.",
                                ));
                            }
                        }
                    }
                    item_depth = None;
                }
                stack.pop().ok_or_else(invalid_xml)?;
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err(invalid_xml()),
            _ => {}
        }
        buffer.clear();
    }
    if kind.is_none() || !stack.is_empty() || body.is_some() || item.is_some() {
        return Err(CommandError::new(
            "rss_feed_invalid",
            "Document is not a complete RSS feed.",
        ));
    }
    Ok(items)
}
fn feed_metadata_field<'a>(
    stack: &'a [feed_body::Element],
    item_depth: Option<usize>,
    atom: bool,
    core_namespace: Option<&str>,
) -> Option<&'a str> {
    let depth = item_depth?;
    let key = stack.last()?;
    if stack.len() == depth + 1 {
        if key.core(atom, core_namespace) {
            return Some(&key.name);
        }
        if !atom
            && matches!(
                key.namespace.as_deref(),
                Some(feed_body::DC | feed_body::DC_TERMS)
            )
            && matches!(key.name.as_str(), "creator" | "date")
        {
            return Some(&key.name);
        }
    }
    if atom && stack.len() == depth + 2 && key.name == "name" && key.core(true, core_namespace) {
        let parent = &stack[stack.len() - 2];
        if parent.name == "author" && parent.core(true, core_namespace) {
            return Some("name");
        }
    }
    None
}

fn attribute(
    event: &quick_xml::events::BytesStart<'_>,
    wanted: &[u8],
) -> CommandResult<Option<String>> {
    for attribute in event.attributes() {
        let attribute = attribute
            .map_err(|_| CommandError::new("rss_xml_invalid", "RSS attribute was invalid."))?;
        if attribute.key.as_ref().eq_ignore_ascii_case(wanted) {
            return String::from_utf8(attribute.value.into_owned())
                .map(Some)
                .map_err(|_| CommandError::new("rss_xml_invalid", "RSS attribute was not UTF-8."));
        }
    }
    Ok(None)
}
fn assign_field(item: Option<&mut Parsed>, field: &str, value: &str) {
    let Some(article) = item else { return };
    let value = value.trim();
    if value.is_empty() {
        return;
    }
    match field {
        "title" => article.title.push_str(value),
        "guid" | "id" => article.guid.push_str(value),
        "link" if article.url.is_none() => {
            article.url = Url::parse(value).ok().and_then(|url| {
                if matches!(url.scheme(), "http" | "https")
                    && url.username().is_empty()
                    && url.password().is_none()
                {
                    Some(url.to_string())
                } else {
                    None
                }
            })
        }
        "description" | "summary" => article.summary.push_str(value),
        "encoded" | "content" => article.content.push_str(value),
        "author" | "creator" | "name" => {
            if article.author.is_none() {
                article.author = Some(clean_text(value.to_owned()));
            }
        }
        "pubdate" | "published" | "updated" | "date" => {
            if article.published == 0 {
                article.published = parse_date(value).unwrap_or(0);
            }
        }
        _ => {}
    }
}
fn resolve_article_url(base: &Url, raw: &str) -> Option<String> {
    let url = base.join(raw).ok()?;
    if matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none()
    {
        Some(url.to_string())
    } else {
        None
    }
}
fn parse_date(value: &str) -> Option<i64> {
    DateTime::parse_from_rfc2822(value)
        .ok()
        .or_else(|| DateTime::parse_from_rfc3339(value).ok())
        .map(|date| date.with_timezone(&Utc).timestamp())
}
fn feed_title_from(bytes: &[u8]) -> Option<String> {
    let text = String::from_utf8(bytes.to_vec()).ok()?;
    let lower = text.to_ascii_lowercase();
    let start = lower.find("<title")?;
    let close = lower[start..].find('>')? + start + 1;
    let end = lower[close..].find("</title>")? + close;
    let value = clean_text(text[close..end].to_owned());
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}
fn discover_html(bytes: &[u8], base: &Url, private: bool) -> CommandResult<DiscoveryResult> {
    let html = String::from_utf8(bytes.to_vec())
        .map_err(|_| CommandError::new("rss_discovery_invalid", "Discovery page is not UTF-8."))?;
    let title = html_title(&html);
    let mut links = Vec::new();
    let mut seen = HashSet::new();
    for tag in html.match_indices("<").filter_map(|(offset, _)| {
        html[offset..]
            .find('>')
            .map(|end| &html[offset + 1..offset + end])
    }) {
        let lower = tag.to_ascii_lowercase();
        if !lower.trim_start().starts_with("link") && !lower.trim_start().starts_with("a") {
            continue;
        }
        let href = html_attribute(tag, "href");
        let rel = html_attribute(tag, "rel")
            .unwrap_or_default()
            .to_ascii_lowercase();
        let type_hint = html_attribute(tag, "type");
        let looks_like_feed = rel.split_whitespace().any(|part| part == "alternate")
            && type_hint.as_deref().is_some_and(|type_hint| {
                type_hint.contains("rss") || type_hint.contains("atom") || type_hint.contains("xml")
            })
            || href.as_deref().is_some_and(|value| {
                let value = value.to_ascii_lowercase();
                value.contains("rss")
                    || value.contains("atom")
                    || value.ends_with(".xml")
                    || value.ends_with(".rss")
            });
        if !looks_like_feed {
            continue;
        }
        let Some(href) = href else { continue };
        let Ok(url) = base.join(&href) else { continue };
        if validate_url(url.as_str(), private).is_err() || !seen.insert(url.to_string()) {
            continue;
        }
        links.push((url, html_attribute(tag, "title"), type_hint));
        if links.len() == MAX_DISCOVERY {
            break;
        }
    }
    Ok((title, links))
}
fn html_attribute(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let needle = format!("{name}=");
    let start = lower.find(&needle)? + needle.len();
    let rest = &tag[start..];
    let quote = rest.chars().next()?;
    if quote == '\"' || quote == '\'' {
        let end = rest[1..].find(quote)? + 1;
        Some(rest[1..end].to_owned())
    } else {
        Some(rest.split_whitespace().next()?.to_owned())
    }
}
fn html_title(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let start = lower.find("<title")?;
    let open = lower[start..].find('>')? + start + 1;
    let end = lower[open..].find("</title>")? + open;
    let title = clean_text(html[open..end].to_owned());
    if title.is_empty() {
        None
    } else {
        Some(title)
    }
}
#[cfg(test)]
fn parse_opml(xml: &str) -> CommandResult<Vec<(String, Option<String>)>> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut depth = 0_usize;
    let mut root = false;
    let mut body_depth: Option<usize> = None;
    let mut output = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::DocType(_)) => {
                return Err(CommandError::new(
                    "rss_opml_invalid",
                    "OPML may not contain DTDs or entity references.",
                ))
            }
            Ok(Event::Start(event)) => {
                depth += 1;
                if depth > MAX_DEPTH {
                    return Err(CommandError::new(
                        "rss_opml_invalid",
                        "OPML nesting is too deep.",
                    ));
                }
                let name = local_name(event.name().as_ref());
                if depth == 1 {
                    if name != "opml" {
                        return Err(CommandError::new(
                            "rss_opml_invalid",
                            "OPML root must be opml.",
                        ));
                    }
                    root = true;
                } else if name == "body" && depth == 2 {
                    body_depth = Some(depth);
                } else if name == "outline" {
                    collect_opml_outline(&event, body_depth.is_some(), &mut output)?;
                }
            }
            Ok(Event::Empty(event)) => {
                let name = local_name(event.name().as_ref());
                if name == "outline" {
                    collect_opml_outline(&event, body_depth.is_some(), &mut output)?;
                }
            }
            Ok(Event::End(_)) => {
                if depth == 0 {
                    return Err(CommandError::new(
                        "rss_opml_invalid",
                        "OPML tags are unbalanced.",
                    ));
                }
                if body_depth == Some(depth) {
                    body_depth = None;
                }
                depth -= 1;
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err(CommandError::new("rss_opml_invalid", "Invalid OPML XML.")),
            _ => {}
        }
    }
    if !root || depth != 0 || output.len() > MAX_ITEMS {
        return Err(CommandError::new(
            "rss_opml_invalid",
            "OPML must have a root, body, and at most 10,000 feeds.",
        ));
    }
    Ok(output)
}
#[cfg(test)]
fn collect_opml_outline(
    event: &quick_xml::events::BytesStart<'_>,
    in_body: bool,
    output: &mut Vec<(String, Option<String>)>,
) -> CommandResult<()> {
    if !in_body {
        return Ok(());
    }
    let url = attribute(event, b"xmlUrl")?;
    if let Some(url) = url {
        let title = attribute(event, b"text")?.or(attribute(event, b"title")?);
        output.push((url, title));
        if output.len() > MAX_ITEMS {
            return Err(CommandError::new(
                "rss_opml_too_large",
                "OPML contains too many feeds.",
            ));
        }
    }
    Ok(())
}
fn classify_issue(code: &str) -> (&'static str, &'static str) {
    if code.contains("url") || code.contains("dns") || code.contains("redirect") {
        ("validation", "url")
    } else if code.contains("transport") {
        ("transport", "network")
    } else if code.contains("response") {
        ("response", "http")
    } else if code.contains("xml") || code.contains("feed") {
        ("parsing", "feed")
    } else {
        ("persistence", "storage")
    }
}
fn make_issue(stage: &str, category: &str, retry_at: i64, error: &CommandError) -> RssIssue {
    RssIssue {
        stage: stage.to_owned(),
        category: category.to_owned(),
        retry_strategy: "afterDate".to_owned(),
        retry_at: Some(retry_at),
        user_message: "This feed could not be refreshed.".to_owned(),
        technical_detail: error.message.clone(),
        occurred_at: now(),
        code: error.code.clone(),
        message: error.message.clone(),
        at: now(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn feed() -> RssReaderStore {
        RssReaderStore::default()
    }
    fn article(store: &RssReaderStore, feed_id: &str, id: &str) {
        let connection = store.db.lock().expect("lock");
        connection.execute("INSERT INTO articles(id,feed_id,identity,guid,title,url,summary,content,published,fetched,tags) VALUES(?,?,?,'guid','title','https://example.com/article','summary','<p>content</p>',1,2,'[\"rust\"]')", params![id, feed_id, format!("identity-{id}")]).expect("insert article");
    }
    fn cache(store: &RssReaderStore, article_id: &str) {
        let connection = store.db.lock().expect("lock");
        connection.execute("INSERT INTO full_text_cache(article_id,status,content_html,plain_text,source_url,resolved_url,confidence,attempted_at,retry_after) VALUES(?,'ready','<main>full</main>','full','https://example.com/article','https://example.com/article',700,3,0)", [article_id]).expect("cache");
    }
    fn offline_request(article_id: &str, source_text: &str) -> RssOfflineTranslationRequest {
        RssOfflineTranslationRequest {
            article_id: article_id.to_owned(),
            provider: "libretranslate_local".to_owned(),
            endpoint: "http://127.0.0.1:5000".to_owned(),
            model: String::new(),
            source_language: "auto".to_owned(),
            target_language: "zh".to_owned(),
            glossary: vec![RssOfflineTranslationGlossaryEntry {
                source: "hello".to_owned(),
                target: "你好".to_owned(),
            }],
            source_text: source_text.to_owned(),
        }
    }
    fn offline_result(text: &str) -> RssOfflineTranslationResult {
        RssOfflineTranslationResult {
            translated_text: text.to_owned(),
            detected_source_language: Some("en".to_owned()),
            provider: "libretranslate_local".to_owned(),
            model: String::new(),
            target_language: "zh".to_owned(),
        }
    }
    fn enable_offline_cache(store: &RssReaderStore) {
        let mut preferences = store.preferences().expect("preferences");
        preferences.offline_translation_cache_enabled = true;
        store.update_preferences(preferences).expect("enable cache");
    }
    #[test]
    fn rejects_private_urls() {
        assert!(validate_url("http://127.0.0.1/feed", false).is_err());
    }
    #[test]
    fn mapped_ipv4_obeys_the_same_network_policy() {
        for ip in [
            "::ffff:127.0.0.1",
            "::ffff:7f00:1",
            "::ffff:0.0.0.0",
            "::ffff:224.0.0.1",
        ] {
            assert!(unsafe_address(ip.parse().unwrap(), false), "accepted {ip}");
            assert!(
                unsafe_address(ip.parse().unwrap(), true),
                "accepted {ip} with private access"
            );
            assert!(validate_url(&format!("http://[{ip}]/feed"), true).is_err());
        }
        for ip in ["::ffff:10.0.0.7", "::ffff:169.254.1.2"] {
            assert!(unsafe_address(ip.parse().unwrap(), false));
            assert!(!unsafe_address(ip.parse().unwrap(), true));
            assert!(safe_socket_addresses(
                &Url::parse(&format!("http://[{ip}]/feed")).unwrap(),
                false
            )
            .is_err());
            assert!(safe_socket_addresses(
                &Url::parse(&format!("http://[{ip}]/feed")).unwrap(),
                true
            )
            .is_ok());
        }
        assert!(!unsafe_address("::ffff:8.8.8.8".parse().unwrap(), false));
        assert_eq!(
            normalize_address("::ffff:8.8.8.8".parse().unwrap()),
            "8.8.8.8".parse::<IpAddr>().unwrap()
        );
        assert!(safe_socket_addresses(
            &Url::parse("https://[::ffff:8.8.8.8]/feed").unwrap(),
            false
        )
        .is_ok());
    }
    #[test]
    fn offline_translation_cache_is_opt_in_and_never_persists_request_content() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&store, &added.id, "article");
        let request = offline_request("article", "private source content");
        assert!(store
            .get_offline_translation(request.clone())
            .expect("lookup")
            .is_none());
        assert_eq!(
            store
                .save_offline_translation(request.clone(), offline_result("译文"))
                .unwrap_err()
                .code,
            "rss_offline_translation_cache_disabled"
        );
        enable_offline_cache(&store);
        let saved = store
            .save_offline_translation(request.clone(), offline_result("译文"))
            .expect("save");
        assert_eq!(saved.article_id, "article");
        assert_eq!(
            store
                .get_offline_translation(request.clone())
                .expect("hit")
                .expect("record")
                .translated_text,
            "译文"
        );
        let connection = store.db.lock().expect("lock");
        let schema: String = connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='offline_translation_cache'",
                [],
                |row| row.get(0),
            )
            .expect("schema");
        assert!(!schema.contains("source_text"));
        assert!(!schema.contains("endpoint"));
        assert_eq!(
            connection
                .query_row(
                    "SELECT count(*) FROM offline_translation_cache WHERE translated_text LIKE '%private source content%'",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .expect("content count"),
            0
        );
        drop(connection);
        store
            .delete_offline_translation(request.clone())
            .expect("delete");
        assert!(store
            .get_offline_translation(request)
            .expect("miss")
            .is_none());
    }
    #[test]
    fn offline_translation_expiry_clear_quota_and_article_cascade_work() {
        let store = feed();
        let first_feed = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("first feed");
        let second_feed = store
            .add_feed("https://example.org/rss".to_owned(), None)
            .expect("second feed");
        article(&store, &first_feed.id, "first");
        article(&store, &second_feed.id, "second");
        enable_offline_cache(&store);
        let first = offline_request("first", "one");
        let second = offline_request("second", "two");
        store
            .save_offline_translation(first.clone(), offline_result("一"))
            .expect("save first");
        store
            .save_offline_translation(second.clone(), offline_result("二"))
            .expect("save second");
        {
            let connection = store.db.lock().expect("lock");
            connection
                .execute(
                    "UPDATE offline_translation_cache SET expires_at=0 WHERE article_id='first'",
                    [],
                )
                .expect("expire");
        }
        assert!(store
            .get_offline_translation(first)
            .expect("expired")
            .is_none());
        let cleanup = store
            .clear_offline_translations(Some(second_feed.id.clone()))
            .expect("clear feed");
        assert_eq!(cleanup.remaining_count, 0);
        {
            let connection = store.db.lock().expect("lock");
            connection
                .execute(
                    "INSERT INTO offline_translation_cache(article_id,request_fingerprint,translated_text,detected_source_language,provider,model,target_language,created_at,last_accessed_at,expires_at,byte_size) VALUES('first','old','old',NULL,'libretranslate_local','','zh',1,1,9999999999,?)",
                    [101_i64 * 1024 * 1024],
                )
                .expect("large old cache row");
        }
        store
            .save_offline_translation(second.clone(), offline_result("二"))
            .expect("save second again");
        assert!(store
            .get_offline_translation(offline_request("first", "one"))
            .expect("quota eviction")
            .is_none());
        assert_eq!(
            store
                .prune_offline_translations()
                .expect("manual prune")
                .remaining_count,
            1
        );
        store.remove_feed(second_feed.id).expect("remove feed");
        assert_eq!(
            store
                .offline_translation_cache_status()
                .expect("status")
                .entry_count,
            0
        );
    }
    #[test]
    fn legacy_backup_preferences_restore_safe_offline_translation_defaults() {
        let store = feed();
        let mut value = serde_json::to_value(store.preferences().expect("preferences"))
            .expect("serialize preferences");
        let object = value.as_object_mut().expect("preference object");
        object.remove("offlineTranslationCacheEnabled");
        object.remove("offlineTranslationRetentionDays");
        object.remove("offlineTranslationMaxMiB");
        object.remove("automaticLocalPretranslationOnRefreshEnabled");
        let restored = validate_backup_preferences(&value).expect("legacy preferences");
        assert!(!restored.offline_translation_cache_enabled);
        assert_eq!(restored.offline_translation_retention_days, 30);
        assert_eq!(restored.offline_translation_max_mib, 100);
        assert!(!restored.automatic_local_pretranslation_on_refresh_enabled);
    }
    #[test]
    fn accepts_public_url() {
        assert!(validate_url("https://example.com/feed.xml", false).is_ok());
    }
    #[test]
    fn private_preference_allows_rfc1918() {
        assert!(validate_url("http://10.0.0.7/feed", true).is_ok());
        assert!(
            safe_socket_addresses(&Url::parse("http://10.0.0.7/feed").expect("url"), true).is_ok()
        );
        assert!(
            safe_socket_addresses(&Url::parse("http://10.0.0.7/feed").expect("url"), false)
                .is_err()
        );
    }
    #[test]
    fn entities_are_rejected() {
        assert!(parse_xml(
            b"<!DOCTYPE rss [<!ENTITY x 'x'>]><rss><channel/></rss>",
            &Url::parse("https://example.com/").expect("url")
        )
        .is_err());
    }
    #[test]
    fn empty_rss_is_valid() {
        assert_eq!(
            parse_xml(
                b"<rss version='2.0'><channel><title>x</title></channel></rss>",
                &Url::parse("https://example.com/").expect("url")
            )
            .expect("parse")
            .len(),
            0
        );
    }
    #[test]
    fn atom_href_and_date_parse() {
        let parsed = parse_xml(b"<feed xmlns='http://www.w3.org/2005/Atom'><entry><id>g</id><title>T</title><link href='/x'/><published>2024-01-02T03:04:05Z</published><content><![CDATA[Hi]]></content></entry></feed>", &Url::parse("https://example.com/a").expect("url")).expect("parse");
        assert_eq!(parsed[0].url.as_deref(), Some("https://example.com/x"));
        assert!(parsed[0].published > 0);
    }
    #[test]
    fn rss_guid_reuse_with_new_link_is_distinct() {
        let parsed = parse_xml(b"<rss><channel><item><guid>x</guid><title>a</title><link>https://e/a</link></item><item><guid>x</guid><title>b</title><link>https://e/b</link></item></channel></rss>", &Url::parse("https://example.com/").expect("url")).expect("parse");
        assert_ne!(parsed[0].identity, parsed[1].identity);
    }
    #[test]
    fn parses_safe_enclosure_cover_url() {
        let parsed = parse_xml(b"<rss><channel><item><guid>x</guid><title>a</title><enclosure url='https://cdn.example/a.jpg'/></item></channel></rss>", &Url::parse("https://example.com/").expect("url")).expect("parse");
        assert_eq!(
            parsed[0].cover_url.as_deref(),
            Some("https://cdn.example/a.jpg")
        );
    }
    #[test]
    fn state_and_search_tags_work() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("add");
        {
            let connection = store.db.lock().expect("lock");
            connection.execute("INSERT INTO articles(id,feed_id,identity,guid,title,summary,content,published,fetched,tags) VALUES('a',?,'i','g','title','s','c',1,1,'[\"rust\"]')", [&added.id]).expect("insert");
        }
        let page = store
            .list_articles(RssArticleQuery {
                query: Some("rust".to_owned()),
                scope: "all".to_owned(),
                sort: "newest".to_owned(),
                feed_id: None,
                author: None,
                tag: None,
                offset: 0,
                limit: 10,
            })
            .expect("list");
        assert_eq!(page.total, 1);
    }
    #[test]
    fn query_scope_is_strict() {
        assert!(feed()
            .list_articles(RssArticleQuery {
                query: None,
                scope: "bad".to_owned(),
                sort: "newest".to_owned(),
                feed_id: None,
                author: None,
                tag: None,
                offset: 0,
                limit: 1
            })
            .is_err());
    }
    #[test]
    fn prune_keeps_unread_and_starred() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("add");
        {
            let connection = store.db.lock().expect("lock");
            for (id, read, starred) in [("old", 1, 0), ("unread", 0, 0), ("star", 1, 1)] {
                connection.execute("INSERT INTO articles(id,feed_id,identity,guid,title,summary,content,published,fetched,read,starred) VALUES(?,?,?,'g',?,'','',0,0,?,?)", params![id, added.id, id, id, read, starred]).expect("insert");
            }
        }
        assert_eq!(store.prune().expect("prune"), 1);
        assert!(store
            .article("unread".to_owned())
            .expect("article")
            .is_some());
        assert!(store.article("star".to_owned()).expect("article").is_some());
    }
    #[test]
    fn opml_requires_root_and_dedupes() {
        assert!(parse_opml("<body/>").is_err());
        let entries = parse_opml("<opml><body><outline xmlUrl='https://e/a' text='A'/><outline xmlUrl='https://e/a'/></body></opml>").expect("opml");
        assert_eq!(entries.len(), 2);
    }
    #[test]
    fn xml_escaping_is_complete() {
        assert_eq!(escape_xml("<&>\"'"), "&lt;&amp;&gt;&quot;&apos;");
    }
    #[test]
    fn backoff_is_bounded() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("add");
        let issue = store
            .record_failure(&added.id, &CommandError::new("rss_transport_error", "nope"))
            .expect("failure");
        assert!(issue.retry_at.expect("retry") - now() >= 60);
    }
    #[test]
    fn discovery_finds_relative_alternate() {
        let (title, links) = discover_html(b"<html><title>X</title><link rel='alternate' type='application/rss+xml' href='/feed'></html>", &Url::parse("https://example.com/a").expect("url"), false).expect("discovery");
        assert_eq!(title.as_deref(), Some("X"));
        assert_eq!(links[0].0.as_str(), "https://example.com/feed");
    }
    #[test]
    fn backup_round_trip_preserves_highlights_progress_and_full_text() {
        let source = feed();
        let added = source
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&source, &added.id, "article");
        source
            .save_highlight(RssHighlight {
                id: String::new(),
                article_id: "article".to_owned(),
                text: "quoted".to_owned(),
                note: "note".to_owned(),
                tags: vec!["rust".to_owned()],
                created_at: 0,
                updated_at: 0,
            })
            .expect("highlight");
        source
            .save_reading_progress("article".to_owned(), 0.5, 1)
            .expect("progress");
        cache(&source, "article");
        let backup = source.export_backup().expect("export");
        let restored = feed();
        let summary = restored.restore_backup(backup).expect("restore");
        assert_eq!(summary.article_count, 1);
        assert_eq!(
            restored
                .list_highlights("article".to_owned())
                .expect("highlights")
                .len(),
            1
        );
        assert_eq!(
            restored
                .get_reading_progress("article".to_owned())
                .expect("progress")
                .expect("present")
                .progress,
            0.5
        );
        let connection = restored.db.lock().expect("lock");
        let count: i64 = connection.query_row("SELECT count(*) FROM full_text_cache WHERE article_id='article' AND content_html='<main>full</main>'", [], |row| row.get(0)).expect("full text");
        assert_eq!(count, 1);
    }
    #[test]
    fn reading_progress_rejects_stale_revisions_and_advances_deduped_updates() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&store, &added.id, "article");

        let first = store
            .save_reading_progress("article".to_owned(), 0.5, 1)
            .expect("initial progress");
        assert_eq!(first.progress, 0.5);
        assert_eq!(first.revision, 1);

        let deduped = store
            .save_reading_progress("article".to_owned(), 0.505, 2)
            .expect("deduped progress");
        assert_eq!(deduped.progress, 0.5);
        assert_eq!(deduped.revision, 2);

        let stale = store
            .save_reading_progress("article".to_owned(), 0.1, 1)
            .expect("stale progress");
        assert_eq!(stale.progress, 0.5);
        assert_eq!(stale.revision, 2);
    }
    #[test]
    fn backup_rejects_malicious_columns_dangling_rows_limits_and_versions_without_mutation() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&store, &added.id, "article");
        let original = store.export_backup().expect("export");
        let mut malicious: serde_json::Value = serde_json::from_str(&original).expect("json");
        malicious["feeds"][0]["id); DROP TABLE feeds;--"] =
            serde_json::Value::String("x".to_owned());
        assert!(store.restore_backup(malicious.to_string()).is_err());
        let mut dangling: serde_json::Value = serde_json::from_str(&original).expect("json");
        dangling["highlights"] = serde_json::json!([{"id":"h","article_id":"missing","text":"x","note":"","tags":"[]","created_at":1,"updated_at":1}]);
        assert!(store.restore_backup(dangling.to_string()).is_err());
        let mut unsupported: serde_json::Value = serde_json::from_str(&original).expect("json");
        unsupported["schemaVersion"] = serde_json::Value::from(99);
        assert!(store.restore_backup(unsupported.to_string()).is_err());
        assert!(store
            .restore_backup("x".repeat(BACKUP_MAX_BYTES + 1))
            .is_err());
        assert_eq!(store.export_backup().expect("unchanged"), original);
    }
    #[test]
    fn remove_feed_undo_restores_all_related_records_once() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&store, &added.id, "article");
        store
            .save_highlight(RssHighlight {
                id: String::new(),
                article_id: "article".to_owned(),
                text: "quoted".to_owned(),
                note: String::new(),
                tags: vec![],
                created_at: 0,
                updated_at: 0,
            })
            .expect("highlight");
        store
            .save_reading_progress("article".to_owned(), 0.3, 1)
            .expect("progress");
        cache(&store, "article");
        let token = store
            .remove_feed(added.id.clone())
            .expect("remove")
            .expect("token");
        assert!(store
            .article("article".to_owned())
            .expect("article")
            .is_none());
        store.undo_remove_feed(token.clone()).expect("undo");
        assert!(store
            .article("article".to_owned())
            .expect("article")
            .is_some());
        assert_eq!(
            store
                .list_highlights("article".to_owned())
                .expect("highlights")
                .len(),
            1
        );
        assert!(store
            .get_reading_progress("article".to_owned())
            .expect("progress")
            .is_some());
        assert!(store.undo_remove_feed(token).is_err());
    }
    #[test]
    fn mark_read_undo_replays_neither_expired_nor_consumed_tokens() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&store, &added.id, "article");
        let (changed, token) = store.mark_all_read(None).expect("mark");
        assert_eq!(changed, 1);
        let token = token.expect("token");
        store.undo_mark_all_read(token.clone()).expect("undo");
        assert!(
            !store
                .article("article".to_owned())
                .expect("article")
                .expect("present")
                .read
        );
        assert!(store.undo_mark_all_read(token).is_err());
        let (_, expired) = store.mark_all_read(None).expect("mark again");
        let expired = expired.expect("token");
        store
            .db
            .lock()
            .expect("lock")
            .execute(
                "UPDATE undo_actions SET expires_at=0 WHERE token=?",
                [&expired],
            )
            .expect("expire");
        assert!(store.undo_mark_all_read(expired).is_err());
    }
    #[test]
    fn disabling_feed_body_cache_clears_old_bodies_but_keeps_summaries() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&store, &added.id, "article");
        let mut preferences = store.preferences().expect("preferences");
        preferences.feed_body_offline_cache_enabled = false;
        store
            .update_preferences(preferences)
            .expect("disable cache");
        let article = store
            .article("article".to_owned())
            .expect("article")
            .expect("present");
        assert_eq!(article.content, "");
        assert_eq!(article.summary, "summary");
        assert_eq!(feed_content_for_storage(false, "body".to_owned()), "");
        assert_eq!(feed_content_for_storage(true, "body".to_owned()), "body");
    }
    #[test]
    fn full_text_refresh_cache_is_explicit_and_requires_a_url_candidate() {
        assert!(!should_cache_full_text_on_refresh(false, true));
        assert!(!should_cache_full_text_on_refresh(true, false));
        assert!(should_cache_full_text_on_refresh(true, true));
    }
    #[test]
    fn cover_loader_accepts_only_bounded_raster_mime_types() {
        assert_eq!(
            supported_cover_mime("image/png; charset=binary"),
            Some("image/png")
        );
        assert_eq!(supported_cover_mime("IMAGE/JPG"), Some("image/jpeg"));
        assert_eq!(supported_cover_mime("image/svg+xml"), None);
        assert_eq!(supported_cover_mime("image/gif"), None);
        assert_eq!(supported_cover_mime("image/avif"), None);
        assert_eq!(supported_cover_mime("text/html"), None);

        let mut png = vec![0_u8; 24];
        png[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
        png[12..16].copy_from_slice(b"IHDR");
        png[16..20].copy_from_slice(&1200_u32.to_be_bytes());
        png[20..24].copy_from_slice(&800_u32.to_be_bytes());
        assert!(valid_cover_image("image/png", &png));
        assert!(!valid_cover_image("image/jpeg", &png));
        png[16..20].copy_from_slice(&9000_u32.to_be_bytes());
        assert!(!valid_cover_image("image/png", &png));
    }
    #[test]
    fn readable_extraction_prefers_article_and_removes_active_or_chrome_markup() {
        let prose = std::iter::repeat_n("useful prose", 180)
            .collect::<Vec<_>>()
            .join(" ");
        let document = format!(
            "<html><header>masthead</header><nav>navigation</nav><main>short main</main><article onclick='bad()'><script>evil()</script><p>{prose}</p><footer>footer</footer></article></html>"
        );
        let (content_html, plain_text, confidence) = extract_readable_html(&document);
        assert!(content_html.contains("<p>"));
        assert!(!content_html.contains("script"));
        assert!(!content_html.contains("onclick"));
        assert!(!plain_text.contains("navigation"));
        assert!(!plain_text.contains("evil"));
        assert!(plain_text.contains("useful prose"));
        assert!(confidence >= 0.7);
    }
    #[test]
    fn filtered_mark_read_only_changes_matches_and_undo_restores_all() {
        let store = feed();
        let added = store
            .add_feed("https://example.com/rss".to_owned(), None)
            .expect("feed");
        article(&store, &added.id, "matching");
        article(&store, &added.id, "other");
        store
            .update_article_state(
                "other".to_owned(),
                RssArticleState {
                    read: None,
                    starred: None,
                    tags: Some(vec!["other".to_owned()]),
                },
            )
            .expect("tag");
        let (changed, token) = store
            .mark_filtered_read(RssArticleQuery {
                query: None,
                scope: "all".to_owned(),
                sort: "newest".to_owned(),
                feed_id: None,
                author: None,
                tag: Some("rust".to_owned()),
                offset: 0,
                limit: 1,
            })
            .expect("mark matching");
        assert_eq!(changed, 1);
        assert!(
            store
                .article("matching".to_owned())
                .expect("article")
                .expect("present")
                .read
        );
        assert!(
            !store
                .article("other".to_owned())
                .expect("article")
                .expect("present")
                .read
        );
        store
            .undo_mark_all_read(token.expect("token"))
            .expect("undo");
        assert!(
            !store
                .article("matching".to_owned())
                .expect("article")
                .expect("present")
                .read
        );
    }
}

#[cfg(test)]
#[path = "rss_feed_body_tests.rs"]
mod feed_body_tests;

#[cfg(test)]
#[path = "rss_refresh_policy_tests.rs"]
mod refresh_policy_tests;
