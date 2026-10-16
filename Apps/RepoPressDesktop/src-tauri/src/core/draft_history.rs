//! Private, bounded Markdown version history. Repository paths are never accepted as authority:
//! callers must derive a root and a live document binding from `RepositoryStore` first.
use super::{CommandError, CommandResult};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const MAX_TEXT_BYTES: usize = 4 * 1024 * 1024;
const MAX_VERSIONS_PER_DRAFT: i64 = 32;
const MAX_RECYCLED_ENTRIES: i64 = 100;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DraftVersionReason {
    BeforeSave,
    BeforeRestore,
    Deleted,
}
impl DraftVersionReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::BeforeSave => "beforeSave",
            Self::BeforeRestore => "beforeRestore",
            Self::Deleted => "deleted",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftVersionSummary {
    pub version_id: String,
    pub relative_path: String,
    pub reason: String,
    pub created_at_epoch_seconds: i64,
    pub byte_size: u64,
    pub content_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftVersion {
    #[serde(flatten)]
    pub summary: DraftVersionSummary,
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftVersionSnapshot {
    pub document_id: String,
    pub relative_path: String,
    pub versions: Vec<DraftVersionSummary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecycledDraftSummary {
    pub recycle_id: String,
    pub relative_path: String,
    pub deleted_at_epoch_seconds: i64,
    pub byte_size: u64,
    pub content_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecycledDraft {
    #[serde(flatten)]
    pub summary: RecycledDraftSummary,
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecycledDraftSnapshot {
    pub entries: Vec<RecycledDraftSummary>,
    pub total: u64,
    pub truncated: bool,
}

#[derive(Clone, Debug)]
pub struct DeletedDraftReceipt {
    pub recycle_id: String,
    version_id: Option<String>,
    draft_id: String,
}

pub struct DraftHistoryStore {
    db: Mutex<Connection>,
    path: Option<PathBuf>,
    snapshot_identity: Option<[u64; 2]>,
}
impl Default for DraftHistoryStore {
    fn default() -> Self {
        Self::open(None).expect("in-memory draft history database unavailable")
    }
}

impl DraftHistoryStore {
    pub fn new(app_data_dir: PathBuf) -> CommandResult<Self> {
        reject_symlink(&app_data_dir)?;
        let directory = app_data_dir.join("DraftHistory");
        if directory.exists() {
            reject_symlink(&directory)?;
        } else {
            fs::create_dir(&directory).map_err(|e| {
                CommandError::io(
                    "draft_history_storage_unavailable",
                    "create draft history storage",
                    e,
                )
            })?;
        }
        set_private_dir(&directory)?;
        let file = directory.join("history.sqlite");
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
        let db = match &path {
            Some(path) => Connection::open(path),
            None => Connection::open_in_memory(),
        }
        .map_err(db_err)?;
        db.pragma_update(None, "foreign_keys", "ON")
            .map_err(db_err)?;
        db.pragma_update(None, "journal_mode", "WAL")
            .map_err(db_err)?;
        initialize_snapshot_schema(&db)?;
        #[cfg(unix)]
        let snapshot_identity = path.as_ref().and_then(|p| {
            use std::os::unix::fs::MetadataExt;
            fs::symlink_metadata(p).ok().map(|m| [m.dev(), m.ino()])
        });
        #[cfg(not(unix))]
        let snapshot_identity = None;
        Ok(Self {
            db: Mutex::new(db),
            path,
            snapshot_identity,
        })
    }

    pub(super) fn with_snapshot_source<T>(
        &self,
        action: impl FnOnce(&Connection, &Path, [u64; 2]) -> CommandResult<T>,
    ) -> CommandResult<T> {
        let db = self.db.lock().map_err(|_| {
            CommandError::new(
                "draft_snapshot_backup_invalid",
                "The durable draft database could not be confirmed.",
            )
        })?;
        let path = self.path.as_deref().ok_or_else(|| {
            CommandError::new(
                "draft_snapshot_backup_invalid",
                "A durable draft database is required.",
            )
        })?;
        let identity = self.snapshot_identity.ok_or_else(|| {
            CommandError::new(
                "draft_snapshot_backup_invalid",
                "A durable draft database is required.",
            )
        })?;
        action(&db, path, identity)
    }
    pub fn record_version(
        &self,
        root: &Path,
        relative_path: &str,
        text: &str,
        sha: &str,
        reason: DraftVersionReason,
    ) -> CommandResult<()> {
        validate_text(text)?;
        let repository_key = repository_key(root);
        let mut db = self.lock()?;
        let transaction = db.transaction().map_err(db_err)?;
        let draft_id = ensure_draft(&transaction, &repository_key, relative_path)?;
        let duplicate: Option<String> = transaction.query_row("SELECT content_sha256 FROM versions WHERE repository_key=?1 AND draft_id=?2 ORDER BY created_at DESC, rowid DESC LIMIT 1", params![repository_key, draft_id], |r| r.get(0)).optional().map_err(db_err)?;
        if duplicate.as_deref() != Some(sha) {
            transaction.execute("INSERT INTO versions(version_id,repository_key,draft_id,relative_path,reason,created_at,byte_size,content_sha256,text) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)", params![Uuid::new_v4().to_string(), repository_key, draft_id, relative_path, reason.as_str(), now(), text.len() as i64, sha, text]).map_err(db_err)?;
            transaction.execute("DELETE FROM versions WHERE version_id IN (SELECT version_id FROM versions WHERE repository_key=?1 AND draft_id=?2 ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET ?3)", params![repository_key, draft_id, MAX_VERSIONS_PER_DRAFT]).map_err(db_err)?;
        }
        transaction.commit().map_err(db_err)
    }

    pub fn record_deleted(
        &self,
        root: &Path,
        relative_path: &str,
        text: &str,
        sha: &str,
    ) -> CommandResult<DeletedDraftReceipt> {
        validate_text(text)?;
        let repository_key = repository_key(root);
        let mut db = self.lock()?;
        let transaction = db.transaction().map_err(db_err)?;
        let draft_id = ensure_draft(&transaction, &repository_key, relative_path)?;
        let duplicate: Option<String> = transaction.query_row("SELECT content_sha256 FROM versions WHERE repository_key=?1 AND draft_id=?2 ORDER BY created_at DESC, rowid DESC LIMIT 1", params![repository_key, draft_id], |r| r.get(0)).optional().map_err(db_err)?;
        let version_id = if duplicate.as_deref() == Some(sha) {
            None
        } else {
            let version_id = Uuid::new_v4().to_string();
            transaction.execute("INSERT INTO versions(version_id,repository_key,draft_id,relative_path,reason,created_at,byte_size,content_sha256,text) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)", params![version_id, repository_key, draft_id, relative_path, DraftVersionReason::Deleted.as_str(), now(), text.len() as i64, sha, text]).map_err(db_err)?;
            Some(version_id)
        };
        let recycle_id = Uuid::new_v4().to_string();
        transaction.execute("INSERT INTO recycled_drafts(recycle_id,repository_key,draft_id,relative_path,deleted_at,byte_size,content_sha256,text) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)", params![recycle_id, repository_key, draft_id, relative_path, now(), text.len() as i64, sha, text]).map_err(db_err)?;
        transaction.commit().map_err(db_err)?;
        Ok(DeletedDraftReceipt {
            recycle_id,
            version_id,
            draft_id,
        })
    }
    pub fn rollback_deleted(
        &self,
        root: &Path,
        receipt: &DeletedDraftReceipt,
    ) -> CommandResult<()> {
        let repository_key = repository_key(root);
        let db = self.lock()?;
        db.execute(
            "DELETE FROM recycled_drafts WHERE recycle_id=?1 AND repository_key=?2",
            params![receipt.recycle_id, repository_key],
        )
        .map_err(db_err)?;
        if let Some(version_id) = &receipt.version_id {
            db.execute(
                "DELETE FROM versions WHERE version_id=?1 AND repository_key=?2",
                params![version_id, repository_key],
            )
            .map_err(db_err)?;
        }
        Ok(())
    }
    pub fn finalize_deleted(
        &self,
        root: &Path,
        receipt: &DeletedDraftReceipt,
    ) -> CommandResult<()> {
        let repository_key = repository_key(root);
        let db = self.lock()?;
        db.execute("DELETE FROM versions WHERE version_id IN (SELECT version_id FROM versions WHERE repository_key=?1 AND draft_id=?2 ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET ?3)", params![repository_key, receipt.draft_id, MAX_VERSIONS_PER_DRAFT]).map_err(db_err)?;
        Ok(())
    }
    pub fn rename_draft(
        &self,
        root: &Path,
        old_relative_path: &str,
        new_relative_path: &str,
    ) -> CommandResult<()> {
        let key = repository_key(root);
        let mut db = self.lock()?;
        let transaction = db.transaction().map_err(db_err)?;
        transaction
            .execute(
                "UPDATE drafts SET relative_path=?1 WHERE repository_key=?2 AND relative_path=?3",
                params![new_relative_path, key, old_relative_path],
            )
            .map_err(db_err)?;
        transaction
            .execute(
                "UPDATE versions SET relative_path=?1 WHERE repository_key=?2 AND relative_path=?3",
                params![new_relative_path, key, old_relative_path],
            )
            .map_err(db_err)?;
        transaction.commit().map_err(db_err)
    }
    pub fn list_versions(
        &self,
        root: &Path,
        document_id: &str,
        relative_path: &str,
    ) -> CommandResult<DraftVersionSnapshot> {
        let key = repository_key(root);
        let db = self.lock()?;
        let Some(draft_id) = find_draft(&db, &key, relative_path)? else {
            return Ok(DraftVersionSnapshot {
                document_id: document_id.into(),
                relative_path: relative_path.into(),
                versions: Vec::new(),
            });
        };
        let mut statement = db.prepare("SELECT version_id,relative_path,reason,created_at,byte_size,content_sha256 FROM versions WHERE repository_key=?1 AND draft_id=?2 ORDER BY created_at DESC,rowid DESC LIMIT ?3").map_err(db_err)?;
        let versions = statement
            .query_map(
                params![key, draft_id, MAX_VERSIONS_PER_DRAFT],
                version_summary_row,
            )
            .map_err(db_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_err)?;
        Ok(DraftVersionSnapshot {
            document_id: document_id.into(),
            relative_path: relative_path.into(),
            versions,
        })
    }
    pub fn get_version(
        &self,
        root: &Path,
        relative_path: &str,
        version_id: &str,
    ) -> CommandResult<DraftVersion> {
        let key = repository_key(root);
        let db = self.lock()?;
        let expected = find_draft(&db, &key, relative_path)?.ok_or_else(not_found)?;
        db.query_row("SELECT version_id,relative_path,reason,created_at,byte_size,content_sha256,text FROM versions WHERE repository_key=?1 AND draft_id=?2 AND version_id=?3", params![key,expected,version_id], version_row).map_err(|e| if matches!(e, rusqlite::Error::QueryReturnedNoRows) { not_found() } else { db_err(e) })
    }
    pub fn list_recycled(&self, root: &Path) -> CommandResult<RecycledDraftSnapshot> {
        let key = repository_key(root);
        let db = self.lock()?;
        let total: i64 = db
            .query_row(
                "SELECT count(*) FROM recycled_drafts WHERE repository_key=?1",
                [key.clone()],
                |r| r.get(0),
            )
            .map_err(db_err)?;
        let mut statement = db.prepare("SELECT recycle_id,relative_path,deleted_at,byte_size,content_sha256 FROM recycled_drafts WHERE repository_key=?1 ORDER BY deleted_at DESC,rowid DESC LIMIT ?2").map_err(db_err)?;
        let entries = statement
            .query_map(params![key, MAX_RECYCLED_ENTRIES], recycle_summary_row)
            .map_err(db_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_err)?;
        Ok(RecycledDraftSnapshot {
            truncated: total > MAX_RECYCLED_ENTRIES,
            total: total as u64,
            entries,
        })
    }
    pub fn get_recycled(&self, root: &Path, recycle_id: &str) -> CommandResult<RecycledDraft> {
        let key = repository_key(root);
        let db = self.lock()?;
        db.query_row("SELECT recycle_id,relative_path,deleted_at,byte_size,content_sha256,text FROM recycled_drafts WHERE repository_key=?1 AND recycle_id=?2", params![key,recycle_id], recycle_row).map_err(|e| if matches!(e, rusqlite::Error::QueryReturnedNoRows) { not_found() } else { db_err(e) })
    }
    pub fn restore_recycled(
        &self,
        root: &Path,
        recycle_id: &str,
        relative_path: &str,
    ) -> CommandResult<()> {
        let key = repository_key(root);
        let mut db = self.lock()?;
        let transaction = db.transaction().map_err(db_err)?;
        let changed = transaction.execute("UPDATE drafts SET relative_path=?1 WHERE repository_key=?2 AND draft_id=(SELECT draft_id FROM recycled_drafts WHERE repository_key=?2 AND recycle_id=?3)", params![relative_path,key,recycle_id]).map_err(db_err)?;
        if changed == 0 {
            return Err(not_found());
        }
        transaction
            .execute(
                "DELETE FROM recycled_drafts WHERE repository_key=?1 AND recycle_id=?2",
                params![repository_key(root), recycle_id],
            )
            .map_err(db_err)?;
        transaction.commit().map_err(db_err)
    }
    pub fn delete_recycled(
        &self,
        root: &Path,
        recycle_id: &str,
    ) -> CommandResult<RecycledDraftSnapshot> {
        let key = repository_key(root);
        let mut db = self.lock()?;
        let draft_id: Option<String> = db
            .query_row(
                "SELECT draft_id FROM recycled_drafts WHERE repository_key=?1 AND recycle_id=?2",
                params![key, recycle_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(db_err)?;
        let Some(draft_id) = draft_id else {
            return Err(not_found());
        };
        let transaction = db.transaction().map_err(db_err)?;
        // Permanently deleting a recycle item deletes only private records: every snapshot and
        // recycle copy tied to that stable identity, never any repository file.
        transaction
            .execute(
                "DELETE FROM recycled_drafts WHERE repository_key=?1 AND draft_id=?2",
                params![repository_key(root), draft_id],
            )
            .map_err(db_err)?;
        transaction
            .execute(
                "DELETE FROM versions WHERE repository_key=?1 AND draft_id=?2",
                params![repository_key(root), draft_id],
            )
            .map_err(db_err)?;
        transaction
            .execute(
                "DELETE FROM drafts WHERE repository_key=?1 AND draft_id=?2",
                params![repository_key(root), draft_id],
            )
            .map_err(db_err)?;
        transaction.commit().map_err(db_err)?;
        drop(db);
        self.list_recycled(root)
    }
    fn lock(&self) -> CommandResult<std::sync::MutexGuard<'_, Connection>> {
        self.db.lock().map_err(|_| {
            CommandError::new(
                "draft_history_unavailable",
                "Draft history is temporarily unavailable.",
            )
        })
    }
}

pub(super) fn initialize_snapshot_schema(db: &Connection) -> CommandResult<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS drafts (repository_key TEXT NOT NULL, draft_id TEXT NOT NULL, relative_path TEXT NOT NULL, PRIMARY KEY(repository_key,draft_id), UNIQUE(repository_key,relative_path));
            CREATE TABLE IF NOT EXISTS versions (version_id TEXT PRIMARY KEY, repository_key TEXT NOT NULL, draft_id TEXT NOT NULL, relative_path TEXT NOT NULL, reason TEXT NOT NULL, created_at INTEGER NOT NULL, byte_size INTEGER NOT NULL, content_sha256 TEXT NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS versions_by_draft ON versions(repository_key,draft_id,created_at DESC);
            CREATE TABLE IF NOT EXISTS recycled_drafts (recycle_id TEXT PRIMARY KEY, repository_key TEXT NOT NULL, draft_id TEXT NOT NULL, relative_path TEXT NOT NULL, deleted_at INTEGER NOT NULL, byte_size INTEGER NOT NULL, content_sha256 TEXT NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS recycled_by_repository ON recycled_drafts(repository_key,deleted_at DESC);").map_err(db_err)
}

fn ensure_draft(
    db: &rusqlite::Transaction<'_>,
    key: &str,
    relative_path: &str,
) -> CommandResult<String> {
    if let Some(id) = db
        .query_row(
            "SELECT draft_id FROM drafts WHERE repository_key=?1 AND relative_path=?2",
            params![key, relative_path],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_err)?
    {
        return Ok(id);
    }
    let id = Uuid::new_v4().to_string();
    db.execute(
        "INSERT INTO drafts(repository_key,draft_id,relative_path) VALUES(?1,?2,?3)",
        params![key, id, relative_path],
    )
    .map_err(db_err)?;
    Ok(id)
}
fn find_draft(db: &Connection, key: &str, relative_path: &str) -> CommandResult<Option<String>> {
    db.query_row(
        "SELECT draft_id FROM drafts WHERE repository_key=?1 AND relative_path=?2",
        params![key, relative_path],
        |r| r.get(0),
    )
    .optional()
    .map_err(db_err)
}
fn version_summary_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DraftVersionSummary> {
    Ok(DraftVersionSummary {
        version_id: row.get(0)?,
        relative_path: row.get(1)?,
        reason: row.get(2)?,
        created_at_epoch_seconds: row.get(3)?,
        byte_size: row.get::<_, i64>(4)? as u64,
        content_sha256: row.get(5)?,
    })
}
fn version_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DraftVersion> {
    Ok(DraftVersion {
        summary: DraftVersionSummary {
            version_id: row.get(0)?,
            relative_path: row.get(1)?,
            reason: row.get(2)?,
            created_at_epoch_seconds: row.get(3)?,
            byte_size: row.get::<_, i64>(4)? as u64,
            content_sha256: row.get(5)?,
        },
        text: row.get(6)?,
    })
}
fn recycle_summary_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RecycledDraftSummary> {
    Ok(RecycledDraftSummary {
        recycle_id: row.get(0)?,
        relative_path: row.get(1)?,
        deleted_at_epoch_seconds: row.get(2)?,
        byte_size: row.get::<_, i64>(3)? as u64,
        content_sha256: row.get(4)?,
    })
}
fn recycle_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RecycledDraft> {
    Ok(RecycledDraft {
        summary: RecycledDraftSummary {
            recycle_id: row.get(0)?,
            relative_path: row.get(1)?,
            deleted_at_epoch_seconds: row.get(2)?,
            byte_size: row.get::<_, i64>(3)? as u64,
            content_sha256: row.get(4)?,
        },
        text: row.get(5)?,
    })
}
fn repository_key(root: &Path) -> String {
    let mut h = Sha256::new();
    h.update(root.to_string_lossy().as_bytes());
    format!("{:x}", h.finalize())
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn validate_text(text: &str) -> CommandResult<()> {
    if text.len() > MAX_TEXT_BYTES {
        Err(CommandError::new(
            "draft_history_too_large",
            "Draft history only stores documents up to 4 MiB.",
        ))
    } else {
        Ok(())
    }
}
fn not_found() -> CommandError {
    CommandError::new(
        "draft_history_not_found",
        "The requested draft history entry was not found in this repository.",
    )
}
fn db_err(e: rusqlite::Error) -> CommandError {
    CommandError::new(
        "draft_history_unavailable",
        format!("Draft history storage is unavailable: {e}"),
    )
}
fn reject_symlink(path: &Path) -> CommandResult<()> {
    if fs::symlink_metadata(path)
        .map_err(|e| {
            CommandError::io(
                "draft_history_storage_unavailable",
                "inspect draft history storage",
                e,
            )
        })?
        .file_type()
        .is_symlink()
    {
        Err(CommandError::new(
            "draft_history_storage_rejected",
            "Draft history storage symlinks are not allowed.",
        ))
    } else {
        Ok(())
    }
}
#[cfg(unix)]
fn set_private_dir(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|e| {
        CommandError::io(
            "draft_history_storage_unavailable",
            "secure draft history directory",
            e,
        )
    })
}
#[cfg(not(unix))]
fn set_private_dir(_: &Path) -> CommandResult<()> {
    Ok(())
}
#[cfg(unix)]
fn set_private_file(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|e| {
        CommandError::io(
            "draft_history_storage_unavailable",
            "secure draft history database",
            e,
        )
    })
}
#[cfg(not(unix))]
fn set_private_file(_: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repository(temp: &tempfile::TempDir, name: &str) -> PathBuf {
        let root = temp.path().join(name);
        fs::create_dir(&root).unwrap();
        root
    }

    #[test]
    fn persists_deduplicates_trims_and_rejects_other_repository_identity() {
        let temp = tempfile::tempdir().unwrap();
        let root = repository(&temp, "first");
        let other_root = repository(&temp, "second");
        let store = DraftHistoryStore::new(temp.path().to_path_buf()).unwrap();
        for index in 0..34 {
            let text = format!("version {index}");
            store
                .record_version(
                    &root,
                    "content/post.md",
                    &text,
                    &format!("sha-{index}"),
                    DraftVersionReason::BeforeSave,
                )
                .unwrap();
        }
        // The immediate duplicate does not consume one of the bounded entries.
        store
            .record_version(
                &root,
                "content/post.md",
                "version 33",
                "sha-33",
                DraftVersionReason::BeforeSave,
            )
            .unwrap();
        let snapshot = store
            .list_versions(&root, "document", "content/post.md")
            .unwrap();
        assert_eq!(snapshot.versions.len(), 32);
        assert_eq!(snapshot.versions[0].content_sha256, "sha-33");
        assert_eq!(snapshot.versions[31].content_sha256, "sha-2");
        let version_id = snapshot.versions[0].version_id.clone();
        assert_eq!(
            store
                .get_version(&other_root, "content/post.md", &version_id)
                .unwrap_err()
                .code,
            "draft_history_not_found"
        );
        drop(store);
        let reopened = DraftHistoryStore::new(temp.path().to_path_buf()).unwrap();
        assert_eq!(
            reopened
                .list_versions(&root, "new-document", "content/post.md")
                .unwrap()
                .versions
                .len(),
            32
        );
    }

    #[test]
    fn failed_delete_rollback_does_not_prune_existing_versions() {
        let temp = tempfile::tempdir().unwrap();
        let root = repository(&temp, "repository");
        let store = DraftHistoryStore::default();
        for index in 0..32 {
            store
                .record_version(
                    &root,
                    "content/post.md",
                    &format!("version {index}"),
                    &format!("sha-{index}"),
                    DraftVersionReason::BeforeSave,
                )
                .unwrap();
        }
        let receipt = store
            .record_deleted(&root, "content/post.md", "deleted", "deleted-sha")
            .unwrap();
        let raw_count: i64 = store
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM versions", [], |row| row.get(0))
            .unwrap();
        assert_eq!(raw_count, 33);
        store.rollback_deleted(&root, &receipt).unwrap();
        let versions = store
            .list_versions(&root, "document", "content/post.md")
            .unwrap()
            .versions;
        assert_eq!(versions.len(), 32);
        assert_eq!(versions.last().unwrap().content_sha256, "sha-0");
        assert!(store.list_recycled(&root).unwrap().entries.is_empty());
    }

    #[test]
    fn rename_preserves_the_stable_draft_identity() {
        let temp = tempfile::tempdir().unwrap();
        let root = repository(&temp, "repository");
        let store = DraftHistoryStore::default();
        store
            .record_version(
                &root,
                "content/original.md",
                "first",
                "sha-first",
                DraftVersionReason::BeforeSave,
            )
            .unwrap();

        store
            .rename_draft(&root, "content/original.md", "content/renamed.md")
            .unwrap();

        assert!(store
            .list_versions(&root, "old-document", "content/original.md")
            .unwrap()
            .versions
            .is_empty());
        let renamed = store
            .list_versions(&root, "new-document", "content/renamed.md")
            .unwrap();
        assert_eq!(renamed.versions.len(), 1);
        assert_eq!(renamed.versions[0].relative_path, "content/renamed.md");
        assert_eq!(renamed.versions[0].content_sha256, "sha-first");
    }

    #[test]
    fn rejects_versions_larger_than_the_document_history_limit() {
        let temp = tempfile::tempdir().unwrap();
        let root = repository(&temp, "repository");
        let store = DraftHistoryStore::default();
        let oversized = "x".repeat(MAX_TEXT_BYTES + 1);

        let error = store
            .record_version(
                &root,
                "content/oversized.md",
                &oversized,
                "sha-oversized",
                DraftVersionReason::BeforeSave,
            )
            .unwrap_err();

        assert_eq!(error.code, "draft_history_too_large");
        assert!(store
            .list_versions(&root, "document", "content/oversized.md")
            .unwrap()
            .versions
            .is_empty());
    }

    #[test]
    fn restoring_removes_recycle_and_permanent_delete_removes_private_identity() {
        let temp = tempfile::tempdir().unwrap();
        let root = repository(&temp, "repository");
        let store = DraftHistoryStore::default();
        store
            .record_version(
                &root,
                "content/post.md",
                "first",
                "sha-first",
                DraftVersionReason::BeforeSave,
            )
            .unwrap();
        let receipt = store
            .record_deleted(&root, "content/post.md", "second", "sha-second")
            .unwrap();
        store.finalize_deleted(&root, &receipt).unwrap();
        store
            .restore_recycled(&root, &receipt.recycle_id, "content/restored.md")
            .unwrap();
        assert!(store.list_recycled(&root).unwrap().entries.is_empty());
        assert_eq!(
            store
                .list_versions(&root, "document", "content/restored.md")
                .unwrap()
                .versions
                .len(),
            2
        );
        let recycle = store
            .record_deleted(&root, "content/restored.md", "third", "sha-third")
            .unwrap();
        store.finalize_deleted(&root, &recycle).unwrap();
        let after = store.delete_recycled(&root, &recycle.recycle_id).unwrap();
        assert_eq!(after.total, 0);
        assert!(store
            .list_versions(&root, "document", "content/restored.md")
            .unwrap()
            .versions
            .is_empty());
    }
}
