//! Durable, bounded push evidence. Unlike the activity log, writes never fall back
//! to memory and an unconfirmed attempt is retained across process restarts.
use super::durable_ledger::{open_storage, validate_storage, Storage};
use super::{CommandError, CommandResult};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_RECORDS: usize = 200;
const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;
const MAX_TOTAL_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublishEvidence {
    pub repository_path: String,
    pub repository_identity: String,
    pub operation: PushOperation,
    pub remote: String,
    pub remote_url: String,
    pub branch: String,
    pub expected_sha: String,
    pub observed_before_sha: Option<String>,
    pub changed_paths: Vec<String>,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PushOperation {
    Push,
    PushRetry,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PublishOutcome {
    Unconfirmed,
    Verified,
    Different,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublishRecord {
    pub record_id: String,
    pub revision: u64,
    pub evidence: PublishEvidence,
    pub outcome: PublishOutcome,
    pub observed_remote_sha: Option<String>,
    pub started_at_epoch_ms: u64,
    pub checked_at_epoch_ms: Option<u64>,
}

#[derive(Default)]
pub struct PublishLedgerStore {
    storage: Mutex<Option<Storage>>,
    active: Mutex<HashSet<String>>,
}
struct ActiveRecord<'a> {
    store: &'a PublishLedgerStore,
    id: String,
}
impl Drop for ActiveRecord<'_> {
    fn drop(&mut self) {
        if let Ok(mut active) = self.store.active.lock() {
            active.remove(&self.id);
        }
    }
}
pub struct PublishAttempt<'a> {
    lease: ActiveRecord<'a>,
    record: PublishRecord,
}
impl PublishAttempt<'_> {
    pub fn finish(self, observed: Option<String>) -> CommandResult<PublishRecord> {
        self.lease.store.update(&self.record, observed)
    }
}

impl PublishLedgerStore {
    /// Hold the source row against concurrent verification or deletion while a
    /// reviewed transaction revalidates it. Git itself is rechecked separately.
    pub(super) fn with_record_lease<T>(
        &self,
        expected: &PublishRecord,
        operation: impl FnOnce() -> CommandResult<T>,
    ) -> CommandResult<T> {
        let _lease = self.reserve(&expected.record_id)?;
        if self.get(
            Path::new(&expected.evidence.repository_path),
            &expected.record_id,
        )? != *expected
        {
            return Err(changed());
        }
        operation()
    }
    pub fn new(app_data: PathBuf) -> Self {
        Self {
            storage: Mutex::new(open_storage(&app_data, "publish-ledger", "pushes.sqlite3").ok()),
            ..Self::default()
        }
    }
    fn with_storage<T>(
        &self,
        operation: impl FnOnce(&mut Storage) -> CommandResult<T>,
    ) -> CommandResult<T> {
        let mut storage = self.storage.lock().map_err(|_| unavailable())?;
        let storage = storage.as_mut().ok_or_else(unavailable)?;
        validate_storage(storage)?;
        validate_payloads(&storage.connection)?;
        let result = operation(storage);
        validate_storage(storage)?;
        result
    }
    pub fn list(&self, root: &Path) -> CommandResult<Vec<PublishRecord>> {
        let root = root.to_str().ok_or_else(unavailable)?;
        self.with_storage(|storage| {
            let mut statement = storage.connection.prepare("SELECT CASE WHEN length(CAST(payload AS BLOB)) <= 4194304 THEN payload ELSE NULL END FROM pushes WHERE repository_path=?1 ORDER BY rowid DESC LIMIT 201").map_err(|_| unavailable())?;
            let rows = statement.query_map([root], |row| row.get::<_, String>(0)).map_err(|_| unavailable())?;
            let mut result = Vec::new();
            for row in rows { let record = decode(&row.map_err(|_| unavailable())?)?; if record.evidence.repository_path != root { return Err(unavailable()); } result.push(record); }
            if result.len() > MAX_RECORDS { return Err(unavailable()); }
            Ok(result)
        })
    }
    pub fn get(&self, root: &Path, id: &str) -> CommandResult<PublishRecord> {
        self.with_storage(|storage| {
            let record = read_record(&storage.connection, id)?;
            if Path::new(&record.evidence.repository_path) != root {
                return Err(changed());
            }
            Ok(record)
        })
    }
    /// Explicit cleanup of one previously observed record. Never erase a
    /// pending/unknown attempt or a record currently being executed/verified.
    pub fn remove_checked(
        &self,
        root: &Path,
        id: &str,
        revision: u64,
    ) -> CommandResult<Vec<PublishRecord>> {
        let _lease = self.reserve(id)?;
        self.with_storage(|storage| {
            let transaction = storage
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            let record = read_record(&transaction, id)?;
            if Path::new(&record.evidence.repository_path) != root
                || record.revision != revision
                || record.outcome == PublishOutcome::Unconfirmed
            {
                return Err(changed());
            }
            transaction
                .execute("DELETE FROM pushes WHERE id=?1", [id])
                .map_err(|_| unavailable())?;
            transaction.commit().map_err(|_| unavailable())?;
            File::open(&storage.directory)
                .and_then(|file| file.sync_all())
                .map_err(|_| unavailable())?;
            Ok(())
        })?;
        self.list(root)
    }
    fn reserve(&self, id: &str) -> CommandResult<ActiveRecord<'_>> {
        let mut active = self.active.lock().map_err(|_| unavailable())?;
        if !active.insert(id.to_string()) {
            return Err(CommandError::new(
                "publish_record_busy",
                "This push attempt is still running.",
            ));
        }
        Ok(ActiveRecord {
            store: self,
            id: id.to_string(),
        })
    }
    pub fn begin(&self, id: &str, evidence: PublishEvidence) -> CommandResult<PublishAttempt<'_>> {
        let lease = self.reserve(id)?;
        let record = PublishRecord {
            record_id: id.to_string(),
            revision: 1,
            evidence,
            outcome: PublishOutcome::Unconfirmed,
            observed_remote_sha: None,
            started_at_epoch_ms: now_ms(),
            checked_at_epoch_ms: None,
        };
        let payload = encode(&record)?;
        self.with_storage(|storage| {
            let transaction = storage
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            let (count, bytes): (usize, usize) = transaction
                .query_row(
                    "SELECT count(*), coalesce(sum(length(CAST(payload AS BLOB))),0) FROM pushes",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(|_| unavailable())?;
            if count >= MAX_RECORDS || bytes + payload.len() + (count + 1) * 512 > MAX_TOTAL_BYTES {
                return Err(CommandError::new(
                    "publish_ledger_full",
                    "The durable publish record limit was reached. Push was not started.",
                ));
            }
            transaction
                .execute(
                    "INSERT INTO pushes (id, repository_path, payload) VALUES (?1, ?2, ?3)",
                    params![id, record.evidence.repository_path, payload],
                )
                .map_err(|_| unavailable())?;
            transaction.commit().map_err(|_| unavailable())?;
            sync_and_readback(storage, &record)
        })?;
        Ok(PublishAttempt { lease, record })
    }
    /// The network operation is explicit, read-only, and runs outside the DB lock.
    pub fn verify(
        &self,
        expected: &PublishRecord,
        observe: impl FnOnce() -> CommandResult<Option<String>>,
    ) -> CommandResult<PublishRecord> {
        let _lease = self.reserve(&expected.record_id)?;
        if self.get(
            Path::new(&expected.evidence.repository_path),
            &expected.record_id,
        )? != *expected
        {
            return Err(changed());
        }
        self.update(expected, observe()?)
    }
    fn update(
        &self,
        expected: &PublishRecord,
        observed: Option<String>,
    ) -> CommandResult<PublishRecord> {
        let mut next = expected.clone();
        next.revision = next.revision.checked_add(1).ok_or_else(unavailable)?;
        next.outcome = match observed.as_deref() {
            Some(sha) if sha == next.evidence.expected_sha => PublishOutcome::Verified,
            Some(_) => PublishOutcome::Different,
            None => PublishOutcome::Unconfirmed,
        };
        next.observed_remote_sha = observed;
        next.checked_at_epoch_ms = Some(now_ms());
        let payload = encode(&next)?;
        self.with_storage(|storage| {
            let transaction = storage
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            if read_record(&transaction, &expected.record_id)? != *expected {
                return Err(changed());
            }
            transaction
                .execute(
                    "UPDATE pushes SET payload=?1 WHERE id=?2",
                    params![payload, next.record_id],
                )
                .map_err(|_| unavailable())?;
            transaction.commit().map_err(|_| unavailable())?;
            sync_and_readback(storage, &next)
        })?;
        Ok(next)
    }
}
fn read_record(connection: &Connection, id: &str) -> CommandResult<PublishRecord> {
    let payload: String = connection.query_row("SELECT CASE WHEN length(CAST(payload AS BLOB)) <= 4194304 THEN payload ELSE NULL END FROM pushes WHERE id=?1", [id], |row| row.get(0)).optional().map_err(|_| unavailable())?.ok_or_else(changed)?;
    let record = decode(&payload)?;
    if record.record_id != id {
        return Err(unavailable());
    }
    Ok(record)
}
fn encode(record: &PublishRecord) -> CommandResult<String> {
    validate_record(record)?;
    let payload = serde_json::to_string(record).map_err(|_| unavailable())?;
    if payload.len() > MAX_RECORD_BYTES {
        return Err(unavailable());
    }
    Ok(payload)
}
fn decode(payload: &str) -> CommandResult<PublishRecord> {
    if payload.len() > MAX_RECORD_BYTES {
        return Err(unavailable());
    }
    let record: PublishRecord = serde_json::from_str(payload).map_err(|_| unavailable())?;
    validate_record(&record)?;
    Ok(record)
}
pub(super) fn validate_record(record: &PublishRecord) -> CommandResult<()> {
    super::git_publish::validate_publish_evidence(&record.evidence)?;
    uuid::Uuid::parse_str(&record.record_id).map_err(|_| unavailable())?;
    if record.revision == 0
        || record.revision > 9_007_199_254_740_991
        || record.started_at_epoch_ms == 0
        || record.started_at_epoch_ms > 9_007_199_254_740_991
        || record
            .checked_at_epoch_ms
            .is_some_and(|time| time > 9_007_199_254_740_991)
        || (record.outcome != PublishOutcome::Unconfirmed && record.checked_at_epoch_ms.is_none())
    {
        return Err(unavailable());
    }
    if let Some(sha) = &record.observed_remote_sha {
        if !valid_sha(sha) {
            return Err(unavailable());
        }
    }
    let expected = match record.observed_remote_sha.as_deref() {
        Some(sha) if sha == record.evidence.expected_sha => PublishOutcome::Verified,
        Some(_) => PublishOutcome::Different,
        None => PublishOutcome::Unconfirmed,
    };
    if record.outcome != expected {
        return Err(unavailable());
    }
    Ok(())
}
pub(super) fn valid_sha(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn changed() -> CommandError {
    CommandError::new(
        "publish_record_changed",
        "The recorded push changed or belongs to another repository. Review it again.",
    )
}
pub(super) fn unavailable() -> CommandError {
    CommandError::new(
        "publish_ledger_unavailable",
        "Durable publishing records are unavailable; no new remote write can start.",
    )
}

fn sync_and_readback(storage: &Storage, expected: &PublishRecord) -> CommandResult<()> {
    File::open(&storage.directory)
        .and_then(|file| file.sync_all())
        .map_err(|_| unavailable())?;
    if read_record(&storage.connection, &expected.record_id)? != *expected {
        return Err(unavailable());
    }
    Ok(())
}

fn validate_payloads(connection: &Connection) -> CommandResult<()> {
    let mut statement = connection.prepare("SELECT id, repository_path, CASE WHEN length(CAST(payload AS BLOB)) <= 4194304 THEN payload ELSE NULL END FROM pushes LIMIT 201").map_err(|_| unavailable())?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|_| unavailable())?;
    let mut count = 0;
    let mut bytes = 0;
    for row in rows {
        let (id, root, payload) = row.map_err(|_| unavailable())?;
        count += 1;
        bytes += payload.len();
        if count > MAX_RECORDS || bytes > MAX_TOTAL_BYTES {
            return Err(unavailable());
        }
        let record = decode(&payload)?;
        if record.record_id != id || record.evidence.repository_path != root {
            return Err(unavailable());
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "publish_ledger_tests.rs"]
mod tests;
