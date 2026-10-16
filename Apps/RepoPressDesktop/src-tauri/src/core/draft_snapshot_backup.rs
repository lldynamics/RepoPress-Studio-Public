//! Explicit one-database backup. All saved rows, never repository files or runtime transfer state.
use super::{
    draft_history, general_drafts,
    rollback_archive::Destination,
    sqlite_snapshot::{self, SnapshotRoot, SourceWitness, TableSummary},
    workspace_config_backup::reject_git_ancestors,
    CommandError, CommandResult, DraftHistoryStore, GeneralDraftStore,
};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
const TTL: Duration = Duration::from_secs(300);
const MAX_PLANS: usize = 2;
const MAX_TEXT_BYTES: usize = 4 * 1024 * 1024;
const EXCLUSIONS: [&str; 5] = [
    "credentialStores",
    "otherWorkspaceSources",
    "repositoryFiles",
    "externalAttachments",
    "runtimeTransferState",
];
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DraftSnapshotSource {
    GeneralDrafts,
    DraftHistory,
}
impl DraftSnapshotSource {
    fn location(self) -> (&'static str, &'static str) {
        match self {
            Self::GeneralDrafts => ("GeneralDrafts", "general-drafts.sqlite"),
            Self::DraftHistory => ("DraftHistory", "history.sqlite"),
        }
    }
    fn tables(self) -> &'static [&'static str] {
        match self {
            Self::GeneralDrafts => &["general_drafts"],
            Self::DraftHistory => &["drafts", "versions", "recycled_drafts"],
        }
    }
    fn with_connection<T>(
        self,
        general: &GeneralDraftStore,
        history: &DraftHistoryStore,
        action: impl FnOnce(&Connection, &Path, [u64; 2]) -> CommandResult<T>,
    ) -> CommandResult<T> {
        match self {
            Self::GeneralDrafts => general.with_snapshot_source(action),
            Self::DraftHistory => history.with_snapshot_source(action),
        }
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftSnapshotBackupPlan {
    pub plan_id: String,
    pub scope: &'static str,
    pub format: &'static str,
    pub schema_version: u8,
    pub source: DraftSnapshotSource,
    pub source_schema: &'static str,
    pub destination_path: String,
    pub tables: Vec<TableSummary>,
    pub exclusions: Vec<&'static str>,
    pub structure_verified: bool,
    pub content_verified: bool,
    pub consistent_snapshot: bool,
    pub multi_database_snapshot: bool,
    pub includes_credential_stores: bool,
    pub includes_recycled_drafts: bool,
    pub compacted_copy: bool,
    pub byte_size: usize,
    pub sha256: String,
    pub created_at_epoch_ms: u64,
    pub expires_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftSnapshotBackupResult {
    pub plan_id: String,
    pub source: DraftSnapshotSource,
    pub destination_path: String,
    pub byte_size: usize,
    pub sha256: String,
}
struct Binding {
    preview: DraftSnapshotBackupPlan,
    source: SourceWitness,
    destination: Destination,
    bytes: Vec<u8>,
    created: Instant,
}
#[derive(Default)]
pub struct DraftSnapshotBackupStore {
    root: Option<SnapshotRoot>,
    plans: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("draft_snapshot_backup_invalid","Draft database source, layout, contents, consent, preview or destination is unavailable, unsafe, expired, too large or changed. Review a new snapshot and filename; no existing file will be overwritten.")
}
fn failed() -> CommandError {
    CommandError::new("draft_snapshot_backup_unconfirmed","Draft snapshot export could not be confirmed. A private file may already exist at the destination; inspect it before selecting a new filename. Source drafts were not restored or cleaned up.")
}
fn now() -> CommandResult<u64> {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_millis();
    if ms == 0 || ms > 8_639_999_999_700_000 {
        return Err(invalid());
    }
    Ok(ms as u64)
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
impl DraftSnapshotBackupStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            root: SnapshotRoot::new(path),
            plans: Mutex::new(HashMap::new()),
        }
    }
    fn root(&self) -> CommandResult<&SnapshotRoot> {
        let root = self.root.as_ref().ok_or_else(invalid)?;
        root.verify().map_err(|_| invalid())?;
        Ok(root)
    }
    fn witness(
        &self,
        source: DraftSnapshotSource,
        c: &Connection,
        path: &Path,
        opened: [u64; 2],
    ) -> CommandResult<SourceWitness> {
        self.root()?
            .witness(c, path, opened, source.location())
            .map_err(|_| invalid())
    }
    pub fn plan(
        &self,
        general: &GeneralDraftStore,
        history: &DraftHistoryStore,
        source: DraftSnapshotSource,
        path: &Path,
    ) -> CommandResult<DraftSnapshotBackupPlan> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, b| b.created.elapsed() < TTL);
        if plans.len() >= MAX_PLANS {
            return Err(invalid());
        }
        let root = self.root()?;
        reject_git_ancestors(path.parent().ok_or_else(invalid)?).map_err(|_| invalid())?;
        let destination = Destination::sqlite_snapshot(path, &root.path).map_err(|_| invalid())?;
        let (witness, bytes, tables) = source
            .with_connection(general, history, |c, p, opened| {
                let before = self.witness(source, c, p, opened)?;
                let tx = c.unchecked_transaction().map_err(|_| invalid())?;
                let _: i64 = tx
                    .query_row(
                        &format!("SELECT count(*) FROM {}", source.tables()[0]),
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| invalid())?;
                if before.revision != sqlite_snapshot::revision(&tx)? {
                    return Err(invalid());
                }
                let (bytes, tables) =
                    sqlite_snapshot::capture(&tx, source.tables(), |copy| validate(copy, source))?;
                tx.rollback().map_err(|_| invalid())?;
                if self.witness(source, c, p, opened)? != before {
                    return Err(invalid());
                }
                Ok((before, bytes, tables))
            })
            .map_err(|_| invalid())?;
        let created_at_epoch_ms = now()?;
        let preview = DraftSnapshotBackupPlan {
            plan_id: Uuid::new_v4().to_string(),
            scope: "applicationDraftDatabase",
            format: "sqlite3",
            schema_version: 1,
            source,
            source_schema: "unversionedInstalledLayout",
            destination_path: path.to_str().ok_or_else(invalid)?.into(),
            tables,
            exclusions: EXCLUSIONS.to_vec(),
            structure_verified: true,
            content_verified: true,
            consistent_snapshot: true,
            multi_database_snapshot: false,
            includes_credential_stores: false,
            includes_recycled_drafts: source == DraftSnapshotSource::DraftHistory,
            compacted_copy: true,
            byte_size: bytes.len(),
            sha256: hash(&bytes),
            created_at_epoch_ms,
            expires_at_epoch_ms: created_at_epoch_ms + 300_000,
        };
        plans.insert(
            preview.plan_id.clone(),
            Binding {
                preview: preview.clone(),
                source: witness,
                destination,
                bytes,
                created: Instant::now(),
            },
        );
        Ok(preview)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.plans.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn execute(
        &self,
        general: &GeneralDraftStore,
        history: &DraftHistoryStore,
        id: &str,
        consent: bool,
    ) -> CommandResult<DraftSnapshotBackupResult> {
        self.execute_checked(general, history, id, consent, |_| {})
    }
    fn execute_checked(
        &self,
        general: &GeneralDraftStore,
        history: &DraftHistoryStore,
        id: &str,
        consent: bool,
        mut hook: impl FnMut(bool),
    ) -> CommandResult<DraftSnapshotBackupResult> {
        let b = self
            .plans
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        if !consent || b.created.elapsed() >= TTL || now()? >= b.preview.expires_at_epoch_ms {
            return Err(invalid());
        }
        b.preview
            .source
            .with_connection(general, history, |c, p, opened| {
                let check = || {
                    if b.created.elapsed() >= TTL
                        || now()? >= b.preview.expires_at_epoch_ms
                        || self.witness(b.preview.source, c, p, opened)? != b.source
                    {
                        return Err(invalid());
                    }
                    reject_git_ancestors(
                        Path::new(&b.preview.destination_path)
                            .parent()
                            .ok_or_else(invalid)?,
                    )
                    .map_err(|_| invalid())
                };
                check()?;
                let tx = c.unchecked_transaction().map_err(|_| invalid())?;
                let _: i64 = tx
                    .query_row(
                        &format!("SELECT count(*) FROM {}", b.preview.source.tables()[0]),
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| invalid())?;
                check()?;
                hook(false);
                let write = b.destination.write(&b.bytes, &mut || {
                    check()?;
                    hook(false);
                    check()
                });
                tx.rollback().map_err(|_| failed())?;
                write.map_err(|_| failed())?;
                hook(true);
                check().map_err(|_| failed())?;
                Ok(())
            })?;
        Ok(DraftSnapshotBackupResult {
            plan_id: b.preview.plan_id,
            source: b.preview.source,
            destination_path: b.preview.destination_path,
            byte_size: b.preview.byte_size,
            sha256: b.preview.sha256,
        })
    }
}
fn valid_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value)
}
fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn valid_path(value: &str) -> bool {
    !value.is_empty()
        && !value.contains(['\0', '\\'])
        && !Path::new(value).is_absolute()
        && value.split('/').all(|part| {
            !part.is_empty() && part != "." && part != ".." && !part.eq_ignore_ascii_case(".git")
        })
        && Path::new(value)
            .extension()
            .and_then(|s| s.to_str())
            .is_some_and(|ext| {
                ["md", "markdown", "mdx"]
                    .iter()
                    .any(|e| ext.eq_ignore_ascii_case(e))
            })
}
fn validate(c: &Connection, source: DraftSnapshotSource) -> CommandResult<()> {
    sqlite_snapshot::check_integrity(c)?;
    for pragma in ["user_version", "application_id"] {
        let v: i64 = c
            .query_row(&format!("PRAGMA {pragma}"), [], |r| r.get(0))
            .map_err(|_| invalid())?;
        if v != 0 {
            return Err(invalid());
        }
    }
    let expected = Connection::open_in_memory().map_err(|_| invalid())?;
    match source {
        DraftSnapshotSource::GeneralDrafts => general_drafts::initialize_snapshot_schema(&expected),
        DraftSnapshotSource::DraftHistory => draft_history::initialize_snapshot_schema(&expected),
    }
    .map_err(|_| invalid())?;
    if sqlite_snapshot::schema(c)? != sqlite_snapshot::schema(&expected)? {
        return Err(invalid());
    }
    match source {
        DraftSnapshotSource::GeneralDrafts => {
            let mut stmt=c.prepare("SELECT draft_id,source_relative_path,created_at,updated_at,revision,title,source_repository_name FROM general_drafts").map_err(|_|invalid())?;
            let mut rows = stmt.query([]).map_err(|_| invalid())?;
            while let Some(row) = rows.next().map_err(|_| invalid())? {
                let id: String = row.get(0).map_err(|_| invalid())?;
                let path: Option<String> = row.get(1).map_err(|_| invalid())?;
                let created: i64 = row.get(2).map_err(|_| invalid())?;
                let updated: i64 = row.get(3).map_err(|_| invalid())?;
                let revision: i64 = row.get(4).map_err(|_| invalid())?;
                let _: String = row.get(5).map_err(|_| invalid())?;
                let _: Option<String> = row.get(6).map_err(|_| invalid())?;
                if !valid_uuid(&id)
                    || path.as_deref().is_some_and(|p| !valid_path(p))
                    || created < 0
                    || updated < 0
                    || revision <= 0
                {
                    return Err(invalid());
                }
            }
            validate_text_rows(c, "general_drafts", true)?;
        }
        DraftSnapshotSource::DraftHistory => {
            let mut stmt = c
                .prepare("SELECT repository_key,draft_id,relative_path FROM drafts")
                .map_err(|_| invalid())?;
            let mut rows = stmt.query([]).map_err(|_| invalid())?;
            while let Some(row) = rows.next().map_err(|_| invalid())? {
                let key: String = row.get(0).map_err(|_| invalid())?;
                let id: String = row.get(1).map_err(|_| invalid())?;
                let path: String = row.get(2).map_err(|_| invalid())?;
                if !valid_hash(&key) || !valid_uuid(&id) || !valid_path(&path) {
                    return Err(invalid());
                }
            }
            for (table, id, time) in [
                ("versions", "version_id", "created_at"),
                ("recycled_drafts", "recycle_id", "deleted_at"),
            ] {
                let orphan:i64=c.query_row(&format!("SELECT count(*) FROM {table} v LEFT JOIN drafts d ON d.repository_key=v.repository_key AND d.draft_id=v.draft_id WHERE d.draft_id IS NULL"),[],|r|r.get(0)).map_err(|_|invalid())?;
                if orphan != 0 {
                    return Err(invalid());
                }
                let mut stmt = c
                    .prepare(&format!("SELECT {id},relative_path,{time} FROM {table}"))
                    .map_err(|_| invalid())?;
                let mut rows = stmt.query([]).map_err(|_| invalid())?;
                while let Some(row) = rows.next().map_err(|_| invalid())? {
                    let id: String = row.get(0).map_err(|_| invalid())?;
                    let path: String = row.get(1).map_err(|_| invalid())?;
                    let time: i64 = row.get(2).map_err(|_| invalid())?;
                    if !valid_uuid(&id) || !valid_path(&path) || time < 0 {
                        return Err(invalid());
                    }
                }
                validate_text_rows(c, table, false)?;
            }
            let invalid_reason:i64=c.query_row("SELECT count(*) FROM versions WHERE reason NOT IN ('beforeSave','beforeRestore','deleted')",[],|r|r.get(0)).map_err(|_|invalid())?;
            if invalid_reason != 0 {
                return Err(invalid());
            }
        }
    }
    Ok(())
}
fn validate_text_rows(c: &Connection, table: &str, general: bool) -> CommandResult<()> {
    let mut stmt = c
        .prepare(&format!(
            "SELECT byte_size,content_sha256,text FROM {table}"
        ))
        .map_err(|_| invalid())?;
    let mut rows = stmt.query([]).map_err(|_| invalid())?;
    while let Some(row) = rows.next().map_err(|_| invalid())? {
        let bytes: i64 = row.get(0).map_err(|_| invalid())?;
        let sha: String = row.get(1).map_err(|_| invalid())?;
        let text: String = row.get(2).map_err(|_| invalid())?;
        if text.len() > MAX_TEXT_BYTES
            || bytes != text.len() as i64
            || !valid_hash(&sha)
            || !body_hash_matches(&text, &sha, general)
            || (general && text.contains('\r'))
        {
            return Err(invalid());
        }
    }
    Ok(())
}
fn body_hash_matches(text: &str, expected: &str, general: bool) -> bool {
    if hash(text.as_bytes()) == expected {
        return true;
    }
    if general {
        return false;
    }
    // History keeps decoded LF text, but its baseline digest identifies the original
    // repository bytes. The writable reader accepts LF/CRLF and an optional UTF-8 BOM.
    // Preserve that digest; encoding information itself is not stored in history.
    let with_bom_matches = |bytes: &[u8]| {
        let mut digest = Sha256::new();
        digest.update([0xef, 0xbb, 0xbf]);
        digest.update(bytes);
        format!("{:x}", digest.finalize()) == expected
    };
    if with_bom_matches(text.as_bytes()) {
        return true;
    }
    if text.contains('\r') || !text.contains('\n') {
        return false;
    }
    let crlf = text.replace('\n', "\r\n");
    hash(crlf.as_bytes()) == expected || with_bom_matches(crlf.as_bytes())
}
#[cfg(test)]
#[path = "draft_snapshot_backup_tests.rs"]
mod tests;
