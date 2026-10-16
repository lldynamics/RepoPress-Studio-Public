//! Durable evidence for PR/MR attempts. Contains hashes, never request prose or tokens.
use super::durable_ledger::{open_storage, validate_storage, Storage};
use super::publish_ledger::{unavailable, valid_sha};
use super::remote_publish::{RemoteProvider, RemotePublishReceipt};
use super::{CommandError, CommandResult};
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_RECORDS: usize = 200;
const MAX_PAYLOAD: usize = 32 * 1024;
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteReviewEvidence {
    pub repository_path: String,
    pub repository_identity: String,
    pub remote: String,
    pub remote_url: String,
    pub provider: RemoteProvider,
    pub owner: String,
    pub project: String,
    pub remote_project_id: u64,
    pub source_branch: String,
    pub target_branch: String,
    pub source_sha: String,
    pub title_sha256: String,
    pub body_sha256: String,
    pub marker: String,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ReviewOutcome {
    Unconfirmed,
    Verified,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ReviewVerification {
    NotChecked,
    Matched,
    NoMatch,
    Ambiguous,
    Unavailable,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteReviewRecord {
    pub record_id: String,
    pub revision: u64,
    pub evidence: RemoteReviewEvidence,
    pub outcome: ReviewOutcome,
    pub verification: ReviewVerification,
    pub review_number: Option<u64>,
    pub web_url: Option<String>,
    pub started_at_epoch_ms: u64,
    pub checked_at_epoch_ms: Option<u64>,
}
#[derive(Default)]
pub struct RemoteReviewLedgerStore {
    storage: Mutex<Option<Storage>>,
    active: Mutex<HashSet<String>>,
}
pub struct RemoteReviewLease<'a> {
    store: &'a RemoteReviewLedgerStore,
    pub record: RemoteReviewRecord,
}
impl Drop for RemoteReviewLease<'_> {
    fn drop(&mut self) {
        if let Ok(mut active) = self.store.active.lock() {
            active.remove(&self.record.record_id);
        }
    }
}
impl RemoteReviewLease<'_> {
    pub fn finish(
        self,
        status: ReviewVerification,
        receipt: Option<RemotePublishReceipt>,
    ) -> CommandResult<RemoteReviewRecord> {
        if (status == ReviewVerification::Matched) != receipt.is_some()
            || receipt
                .as_ref()
                .is_some_and(|value| value.provider != self.record.evidence.provider)
        {
            return Err(unavailable());
        }
        let mut next = self.record.clone();
        next.revision = next.revision.checked_add(1).ok_or_else(unavailable)?;
        next.verification = status;
        next.outcome = if status == ReviewVerification::Matched {
            ReviewOutcome::Verified
        } else {
            ReviewOutcome::Unconfirmed
        };
        if let Some(receipt) = receipt {
            next.review_number = Some(receipt.review_number);
            next.web_url = Some(receipt.web_url);
        }
        next.checked_at_epoch_ms = Some(now_ms());
        let payload = encode(&next)?;
        self.store.with_storage(|storage| {
            let transaction = storage
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            if read(&transaction, &self.record.record_id)? != self.record {
                return Err(changed());
            }
            transaction
                .execute(
                    "UPDATE pushes SET payload=?1 WHERE id=?2",
                    params![payload, next.record_id],
                )
                .map_err(|_| unavailable())?;
            transaction.commit().map_err(|_| unavailable())?;
            sync_readback(storage, &next)
        })?;
        Ok(next)
    }
}
impl RemoteReviewLedgerStore {
    pub fn new(app_data: PathBuf) -> Self {
        Self {
            storage: Mutex::new(
                open_storage(&app_data, "remote-review-ledger", "records.sqlite3").ok(),
            ),
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
        validate_rows(&storage.connection)?;
        let result = operation(storage);
        validate_storage(storage)?;
        result
    }
    pub fn list(&self, root: &Path) -> CommandResult<Vec<RemoteReviewRecord>> {
        let root = root.to_str().ok_or_else(unavailable)?;
        self.with_storage(|storage| {
            let mut query = storage.connection.prepare("SELECT CASE WHEN length(CAST(payload AS BLOB)) <= 32768 THEN payload ELSE NULL END FROM pushes WHERE repository_path=?1 ORDER BY rowid DESC LIMIT 201").map_err(|_| unavailable())?;
            let rows = query.query_map([root], |row| row.get::<_, String>(0)).map_err(|_| unavailable())?;
            rows.map(|row| decode(&row.map_err(|_| unavailable())?)).collect()
        })
    }
    pub fn get(&self, root: &Path, id: &str) -> CommandResult<RemoteReviewRecord> {
        self.with_storage(|storage| {
            let record = read(&storage.connection, id)?;
            if Path::new(&record.evidence.repository_path) != root {
                return Err(changed());
            }
            Ok(record)
        })
    }
    fn reserve(&self, record: RemoteReviewRecord) -> CommandResult<RemoteReviewLease<'_>> {
        if !self
            .active
            .lock()
            .map_err(|_| unavailable())?
            .insert(record.record_id.clone())
        {
            return Err(CommandError::new(
                "remote_review_record_busy",
                "The recorded request is still running.",
            ));
        }
        Ok(RemoteReviewLease {
            store: self,
            record,
        })
    }
    pub fn begin(&self, evidence: RemoteReviewEvidence) -> CommandResult<RemoteReviewLease<'_>> {
        let record = RemoteReviewRecord {
            record_id: evidence.marker.clone(),
            revision: 1,
            evidence,
            outcome: ReviewOutcome::Unconfirmed,
            verification: ReviewVerification::NotChecked,
            review_number: None,
            web_url: None,
            started_at_epoch_ms: now_ms(),
            checked_at_epoch_ms: None,
        };
        let payload = encode(&record)?;
        let lease = self.reserve(record)?;
        self.with_storage(|storage| {
            let transaction = storage
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            let count: usize = transaction
                .query_row("SELECT count(*) FROM pushes", [], |row| row.get(0))
                .map_err(|_| unavailable())?;
            if count >= MAX_RECORDS {
                return Err(CommandError::new(
                    "remote_review_ledger_full",
                    "The PR/MR record limit was reached; creation was not started.",
                ));
            }
            transaction
                .execute(
                    "INSERT INTO pushes (id, repository_path, payload) VALUES (?1, ?2, ?3)",
                    params![
                        lease.record.record_id,
                        lease.record.evidence.repository_path,
                        payload
                    ],
                )
                .map_err(|_| unavailable())?;
            transaction.commit().map_err(|_| unavailable())?;
            sync_readback(storage, &lease.record)
        })?;
        Ok(lease)
    }
    pub fn acquire(&self, expected: &RemoteReviewRecord) -> CommandResult<RemoteReviewLease<'_>> {
        let lease = self.reserve(expected.clone())?;
        if self.get(
            Path::new(&expected.evidence.repository_path),
            &expected.record_id,
        )? != *expected
        {
            return Err(changed());
        }
        Ok(lease)
    }
    pub fn remove(
        &self,
        root: &Path,
        id: &str,
        revision: u64,
    ) -> CommandResult<Vec<RemoteReviewRecord>> {
        let record = self.get(root, id)?;
        if record.revision != revision || record.outcome != ReviewOutcome::Verified {
            return Err(changed());
        }
        let _lease = self.acquire(&record)?;
        self.with_storage(|storage| {
            let transaction = storage
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            if read(&transaction, id)? != record {
                return Err(changed());
            }
            transaction
                .execute("DELETE FROM pushes WHERE id=?1", [id])
                .map_err(|_| unavailable())?;
            transaction.commit().map_err(|_| unavailable())?;
            sync_directory(storage)
        })?;
        self.list(root)
    }
}
fn validate_rows(connection: &rusqlite::Connection) -> CommandResult<()> {
    let mut query = connection.prepare("SELECT id, repository_path, CASE WHEN length(CAST(payload AS BLOB)) <= 32768 THEN payload ELSE NULL END FROM pushes LIMIT 201").map_err(|_| unavailable())?;
    let rows = query
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|_| unavailable())?;
    for (index, row) in rows.enumerate() {
        if index >= MAX_RECORDS {
            return Err(unavailable());
        }
        let (id, path, payload) = row.map_err(|_| unavailable())?;
        let record = decode(&payload)?;
        if record.record_id != id || record.evidence.repository_path != path {
            return Err(unavailable());
        }
    }
    Ok(())
}
fn read(connection: &rusqlite::Connection, id: &str) -> CommandResult<RemoteReviewRecord> {
    let payload: String = connection.query_row("SELECT CASE WHEN length(CAST(payload AS BLOB)) <= 32768 THEN payload ELSE NULL END FROM pushes WHERE id=?1", [id], |row| row.get(0)).optional().map_err(|_| unavailable())?.ok_or_else(changed)?;
    let record = decode(&payload)?;
    if record.record_id != id {
        return Err(unavailable());
    }
    Ok(record)
}
fn encode(record: &RemoteReviewRecord) -> CommandResult<String> {
    validate(record)?;
    let payload = serde_json::to_string(record).map_err(|_| unavailable())?;
    if payload.len() > MAX_PAYLOAD {
        return Err(unavailable());
    }
    Ok(payload)
}
fn decode(payload: &str) -> CommandResult<RemoteReviewRecord> {
    if payload.len() > MAX_PAYLOAD {
        return Err(unavailable());
    }
    let record = serde_json::from_str(payload).map_err(|_| unavailable())?;
    validate(&record)?;
    Ok(record)
}
fn validate(record: &RemoteReviewRecord) -> CommandResult<()> {
    super::remote_publish::validate_review_evidence(&record.evidence).map_err(|_| unavailable())?;
    if record.evidence.remote_project_id == 0 {
        return Err(unavailable());
    }
    if record.record_id != record.evidence.marker
        || record.revision == 0
        || record.revision > 9_007_199_254_740_991
        || record.started_at_epoch_ms == 0
        || record.started_at_epoch_ms > 9_007_199_254_740_991
        || record
            .checked_at_epoch_ms
            .is_some_and(|time| time > 9_007_199_254_740_991)
    {
        return Err(unavailable());
    }
    let matched = record.verification == ReviewVerification::Matched;
    if matched != (record.outcome == ReviewOutcome::Verified)
        || (record.verification == ReviewVerification::NotChecked)
            != record.checked_at_epoch_ms.is_none()
    {
        return Err(unavailable());
    }
    match (&record.review_number, &record.web_url) {
        (Some(number), Some(url)) => {
            super::remote_publish::validate_review_url(&record.evidence, *number, url)
                .map_err(|_| unavailable())?;
        }
        (None, None) if !matched => {}
        _ => return Err(unavailable()),
    }
    if !valid_sha(&record.evidence.source_sha) {
        return Err(unavailable());
    }
    Ok(())
}
fn sync_directory(storage: &Storage) -> CommandResult<()> {
    File::open(&storage.directory)
        .and_then(|file| file.sync_all())
        .map_err(|_| unavailable())
}
fn sync_readback(storage: &Storage, expected: &RemoteReviewRecord) -> CommandResult<()> {
    sync_directory(storage)?;
    if read(&storage.connection, &expected.record_id)? != *expected {
        return Err(unavailable());
    }
    Ok(())
}
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn changed() -> CommandError {
    CommandError::new(
        "remote_review_record_changed",
        "The PR/MR record changed or belongs to another repository; review it again.",
    )
}

#[cfg(test)]
#[path = "remote_review_ledger_tests.rs"]
mod tests;
