//! Consistent, bounded RSS-only SQLite export. Never copies live WAL files or restores data.
use super::{
    rollback_archive::Destination,
    rss,
    sqlite_snapshot::{self, SnapshotRoot, SourceWitness, TableSummary as RssSnapshotTableSummary},
    workspace_config_backup::reject_git_ancestors,
    CommandError, CommandResult, RssReaderStore,
};
use rusqlite::Connection;
use serde::Serialize;
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
const TABLES: [&str; 10] = [
    "meta",
    "feeds",
    "articles",
    "highlights",
    "reading_progress",
    "undo_actions",
    "full_text_cache",
    "offline_translation_cache",
    "history_jobs",
    "history_failures",
];
const EXCLUSIONS: [&str; 3] = [
    "credentialStores",
    "otherWorkspaceSources",
    "externalAttachments",
];
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RssSnapshotBackupPlan {
    pub plan_id: String,
    pub scope: &'static str,
    pub format: &'static str,
    pub schema_version: u8,
    pub database_schema_version: u8,
    pub destination_path: String,
    pub tables: Vec<RssSnapshotTableSummary>,
    pub exclusions: Vec<&'static str>,
    pub structure_verified: bool,
    pub consistent_snapshot: bool,
    pub includes_credential_stores: bool,
    pub includes_undo_actions: bool,
    pub compacted_copy: bool,
    pub byte_size: usize,
    pub sha256: String,
    pub created_at_epoch_ms: u64,
    pub expires_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RssSnapshotBackupResult {
    pub plan_id: String,
    pub destination_path: String,
    pub byte_size: usize,
    pub sha256: String,
}
struct Binding {
    preview: RssSnapshotBackupPlan,
    source: SourceWitness,
    destination: Destination,
    bytes: Vec<u8>,
    created: Instant,
}
#[derive(Default)]
pub struct RssSnapshotBackupStore {
    root: Option<SnapshotRoot>,
    plans: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("rss_snapshot_backup_invalid", "RSS snapshot source, schema, consent, preview or destination is unavailable, unsafe, expired, too large or changed. Review a new snapshot and new filename; no existing file will be overwritten.")
}
fn failed() -> CommandError {
    CommandError::new("rss_snapshot_backup_unconfirmed", "RSS snapshot export could not be confirmed. A private file may already exist at the destination; inspect it before selecting a new filename. The source was not restored or cleaned up.")
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
impl RssSnapshotBackupStore {
    pub fn new(path: PathBuf) -> Self {
        let root = SnapshotRoot::new(path);
        Self {
            root,
            plans: Mutex::new(HashMap::new()),
        }
    }
    fn root(&self) -> CommandResult<&SnapshotRoot> {
        let root = self.root.as_ref().ok_or_else(invalid)?;
        root.verify().map_err(|_| invalid())?;
        Ok(root)
    }
    fn source(
        &self,
        c: &Connection,
        path: &Path,
        opened: [u64; 2],
    ) -> CommandResult<SourceWitness> {
        self.root()?
            .witness(c, path, opened, ("RSSReader", "reader.sqlite"))
            .map_err(|_| invalid())
    }
    pub fn plan(&self, rss: &RssReaderStore, path: &Path) -> CommandResult<RssSnapshotBackupPlan> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, b| b.created.elapsed() < TTL);
        if plans.len() >= MAX_PLANS {
            return Err(invalid());
        }
        let root = self.root()?;
        reject_git_ancestors(path.parent().ok_or_else(invalid)?).map_err(|_| invalid())?;
        let destination = Destination::sqlite_snapshot(path, &root.path).map_err(|_| invalid())?;
        let (source, bytes, tables) = rss
            .with_snapshot_source(|c, p, opened| {
                let before = self.source(c, p, opened)?;
                let tx = c.unchecked_transaction().map_err(|_| invalid())?;
                // Acquire a read snapshot before backup and keep all ten tables coherent.
                let _: i64 = tx
                    .query_row("SELECT count(*) FROM meta", [], |r| r.get(0))
                    .map_err(|_| invalid())?;
                if before.revision != sqlite_snapshot::revision(&tx)? {
                    return Err(invalid());
                }
                let (bytes, tables) = sqlite_snapshot::capture(&tx, &TABLES, validate)?;
                tx.rollback().map_err(|_| invalid())?;
                if self.source(c, p, opened)? != before {
                    return Err(invalid());
                }
                Ok((before, bytes, tables))
            })
            .map_err(|_| invalid())?;
        let created_at_epoch_ms = now()?;
        let preview = RssSnapshotBackupPlan {
            plan_id: Uuid::new_v4().to_string(),
            scope: "applicationRssDatabase",
            format: "sqlite3",
            schema_version: 1,
            database_schema_version: 4,
            destination_path: path.to_str().ok_or_else(invalid)?.into(),
            tables,
            exclusions: EXCLUSIONS.to_vec(),
            structure_verified: true,
            consistent_snapshot: true,
            includes_credential_stores: false,
            includes_undo_actions: true,
            compacted_copy: true,
            byte_size: bytes.len(),
            sha256: format!("{:x}", Sha256::digest(&bytes)),
            created_at_epoch_ms,
            expires_at_epoch_ms: created_at_epoch_ms + 300_000,
        };
        plans.insert(
            preview.plan_id.clone(),
            Binding {
                preview: preview.clone(),
                source,
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
        rss: &RssReaderStore,
        id: &str,
        consent: bool,
    ) -> CommandResult<RssSnapshotBackupResult> {
        self.execute_checked(rss, id, consent, |_| {})
    }
    fn execute_checked(
        &self,
        rss: &RssReaderStore,
        id: &str,
        consent: bool,
        mut hook: impl FnMut(bool),
    ) -> CommandResult<RssSnapshotBackupResult> {
        let binding = self
            .plans
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        if !consent
            || binding.created.elapsed() >= TTL
            || now()? >= binding.preview.expires_at_epoch_ms
        {
            return Err(invalid());
        }
        rss.with_snapshot_source(|c, p, opened| {
            let check = || {
                if binding.created.elapsed() >= TTL
                    || now()? >= binding.preview.expires_at_epoch_ms
                    || self.source(c, p, opened)? != binding.source
                {
                    return Err(invalid());
                }
                reject_git_ancestors(
                    Path::new(&binding.preview.destination_path)
                        .parent()
                        .ok_or_else(invalid)?,
                )
                .map_err(|_| invalid())
            };
            check()?;
            let tx = c.unchecked_transaction().map_err(|_| invalid())?;
            let _: i64 = tx
                .query_row("SELECT count(*) FROM meta", [], |r| r.get(0))
                .map_err(|_| invalid())?;
            check()?;
            hook(false);
            let write = binding.destination.write(&binding.bytes, &mut || {
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
        Ok(RssSnapshotBackupResult {
            plan_id: binding.preview.plan_id,
            destination_path: binding.preview.destination_path,
            byte_size: binding.preview.byte_size,
            sha256: binding.preview.sha256,
        })
    }
}
fn validate(c: &Connection) -> CommandResult<()> {
    sqlite_snapshot::check_integrity(c)?;
    let version: String = c
        .query_row(
            "SELECT value FROM meta WHERE key='schema_version'",
            [],
            |r| r.get(0),
        )
        .map_err(|_| invalid())?;
    if version != "4" {
        return Err(invalid());
    }
    let expected = Connection::open_in_memory().map_err(|_| invalid())?;
    rss::migrate(&expected).map_err(|_| invalid())?;
    if sqlite_snapshot::schema(c)? != sqlite_snapshot::schema(&expected)? {
        return Err(invalid());
    }
    Ok(())
}
#[cfg(test)]
#[path = "rss_snapshot_backup_tests.rs"]
mod tests;
