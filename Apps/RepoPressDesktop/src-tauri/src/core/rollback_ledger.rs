//! Private rollback intent/observation evidence, separate from ordinary pushes.
use super::durable_ledger::{open_storage, validate_storage, Storage};
use super::publish_ledger::{valid_sha, validate_record, PublishOutcome};
use super::{CommandError, CommandResult, PublishRecord};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const MAX_RECORDS: usize = 200;
const MAX_ROW: usize = 64 * 1024;
const MAX_TOTAL: usize = 4 * 1024 * 1024;
const OBSERVATION_RESERVE: usize = MAX_RECORDS * 256;
const MAX_SAFE: u64 = 9_007_199_254_740_991;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RollbackOutcome {
    Unconfirmed,
    CandidateObserved,
    OtherHeadObserved,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RollbackRecord {
    pub record_id: String,
    pub plan_id: String,
    pub session_id: String,
    pub revision: u64,
    pub source: PublishRecord,
    pub parent_sha: String,
    pub source_tree_sha: String,
    pub target_tree_sha: String,
    pub candidate_sha: String,
    pub changed_paths: usize,
    pub target_files: usize,
    pub outcome: RollbackOutcome,
    pub observed_remote_sha: Option<String>,
    pub started_at_epoch_ms: u64,
    pub checked_at_epoch_ms: Option<u64>,
    pub candidate_observed_at_epoch_ms: Option<u64>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackBlockedTarget {
    pub remote_url: String,
    pub branch: String,
    pub local_unresolved: usize,
    pub pending_elsewhere: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackLedgerDiagnostics {
    pub status: &'static str,
    pub capacity: &'static str,
    pub global_records: Option<usize>,
    pub payload_bytes: Option<usize>,
    pub remaining_payload_bytes: Option<usize>,
    pub local_records: Option<usize>,
    pub local_unresolved: Option<usize>,
    pub max_records: usize,
    pub max_payload_bytes: usize,
    pub max_record_bytes: usize,
    pub reserved_observation_bytes: usize,
    pub scope_partial: bool,
    pub blocked_targets: Vec<RollbackBlockedTarget>,
    pub checked_at_epoch_ms: u64,
}
impl RollbackLedgerDiagnostics {
    pub(super) fn unavailable() -> Self {
        Self {
            status: "unavailable",
            capacity: "unavailable",
            global_records: None,
            payload_bytes: None,
            remaining_payload_bytes: None,
            local_records: None,
            local_unresolved: None,
            max_records: MAX_RECORDS,
            max_payload_bytes: MAX_TOTAL,
            max_record_bytes: MAX_ROW,
            reserved_observation_bytes: OBSERVATION_RESERVE,
            scope_partial: true,
            blocked_targets: Vec::new(),
            checked_at_epoch_ms: diagnostic_time(),
        }
    }
}
fn diagnostic_time() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|t| t.as_millis().min(MAX_SAFE as u128) as u64)
        .unwrap_or(1)
        .max(1)
}
#[derive(Default)]
pub(super) struct RollbackLedgerStore {
    storage: Mutex<Option<Storage>>,
}
pub(super) fn unavailable() -> CommandError {
    CommandError::new("rollback_ledger_unavailable", "Durable rollback evidence is unavailable; no remote write can start. Read the local rollback ledger before any further action.")
}
pub(super) fn changed() -> CommandError {
    CommandError::new("rollback_transaction_changed", "Rollback evidence, target or plan changed; review again. An existing attempt must be inspected without retrying.")
}
impl RollbackLedgerStore {
    pub(super) fn new(data: PathBuf) -> Self {
        Self {
            storage: Mutex::new(open_storage(&data, "rollback-ledger", "rollbacks.sqlite3").ok()),
        }
    }
    fn storage<T>(&self, f: impl FnOnce(&mut Storage) -> CommandResult<T>) -> CommandResult<T> {
        let mut lock = self.storage.lock().map_err(|_| unavailable())?;
        let storage = lock.as_mut().ok_or_else(unavailable)?;
        validate_storage(storage).map_err(|_| unavailable())?;
        rows(&storage.connection)?;
        let result = f(storage);
        validate_storage(storage).map_err(|_| unavailable())?;
        result
    }
    pub(super) fn list(&self, root: &Path) -> CommandResult<Vec<RollbackRecord>> {
        self.storage(|s| {
            Ok(rows(&s.connection)?
                .into_iter()
                .filter(|r| Path::new(&r.source.evidence.repository_path) == root)
                .collect())
        })
    }
    /// Keep the evidence mutex during bounded local archive I/O, never network I/O.
    pub(super) fn with_archive_snapshot<T>(
        &self,
        root: &Path,
        expected: &[RollbackRecord],
        write: impl FnOnce() -> CommandResult<T>,
    ) -> CommandResult<T> {
        self.storage(|s| {
            let tx = s.connection.transaction().map_err(|_| unavailable())?;
            let actual: Vec<_> = rows(&tx)?
                .into_iter()
                .filter(|r| Path::new(&r.source.evidence.repository_path) == root)
                .collect();
            if actual != expected {
                return Err(changed());
            }
            write()
        })
    }
    /// One local SQLite snapshot. Only targets already known to this root are
    /// disclosed; a foreign unresolved receipt contributes a boolean, never IDs.
    pub(super) fn inspect_local(
        &self,
        root: &Path,
        visible_targets: &[(String, String)],
        scope_partial: bool,
    ) -> CommandResult<(Vec<RollbackRecord>, RollbackLedgerDiagnostics)> {
        self.storage(|s| {
            let tx = s.connection.transaction().map_err(|_| unavailable())?;
            let all = rows(&tx)?;
            let bytes = payload_bytes(&tx)?;
            let local: Vec<_> = all
                .iter()
                .filter(|r| Path::new(&r.source.evidence.repository_path) == root)
                .cloned()
                .collect();
            let mut targets: BTreeSet<_> = visible_targets.iter().cloned().collect();
            targets.extend(local.iter().map(|r| {
                (
                    r.source.evidence.remote_url.clone(),
                    r.source.evidence.branch.clone(),
                )
            }));
            if targets.len() > MAX_RECORDS * 2 {
                return Err(unavailable());
            }
            let blocked_targets = targets
                .into_iter()
                .filter_map(|(remote_url, branch)| {
                    let pending: Vec<_> = all
                        .iter()
                        .filter(|r| {
                            r.candidate_observed_at_epoch_ms.is_none()
                                && r.source.evidence.remote_url == remote_url
                                && r.source.evidence.branch == branch
                        })
                        .collect();
                    if pending.is_empty() {
                        return None;
                    }
                    Some(RollbackBlockedTarget {
                        remote_url,
                        branch,
                        local_unresolved: pending
                            .iter()
                            .filter(|r| Path::new(&r.source.evidence.repository_path) == root)
                            .count(),
                        pending_elsewhere: pending
                            .iter()
                            .any(|r| Path::new(&r.source.evidence.repository_path) != root),
                    })
                })
                .collect();
            let remaining = MAX_TOTAL.saturating_sub(bytes + OBSERVATION_RESERVE);
            let diagnostics = RollbackLedgerDiagnostics {
                status: "available",
                capacity: if all.len() >= MAX_RECORDS || remaining == 0 {
                    "full"
                } else if remaining < MAX_ROW {
                    "limited"
                } else {
                    "available"
                },
                global_records: Some(all.len()),
                payload_bytes: Some(bytes),
                remaining_payload_bytes: Some(remaining),
                local_records: Some(local.len()),
                local_unresolved: Some(
                    local
                        .iter()
                        .filter(|r| r.candidate_observed_at_epoch_ms.is_none())
                        .count(),
                ),
                max_records: MAX_RECORDS,
                max_payload_bytes: MAX_TOTAL,
                max_record_bytes: MAX_ROW,
                reserved_observation_bytes: OBSERVATION_RESERVE,
                scope_partial,
                blocked_targets,
                checked_at_epoch_ms: diagnostic_time(),
            };
            tx.commit().map_err(|_| unavailable())?;
            Ok((local, diagnostics))
        })
    }
    /// Pending remote transactions are shared across checkouts in this app's
    /// private ledger. A second root must not become a blind-retry path.
    pub(super) fn has_prior(&self, root: &Path, source: &PublishRecord) -> CommandResult<bool> {
        self.storage(|s| {
            Ok(rows(&s.connection)?.iter().any(|r| {
                (Path::new(&r.source.evidence.repository_path) == root
                    && r.source.record_id == source.record_id)
                    || (r.source.evidence.remote_url == source.evidence.remote_url
                        && r.source.evidence.branch == source.evidence.branch
                        && r.candidate_observed_at_epoch_ms.is_none())
            }))
        })
    }
    pub(super) fn get(&self, root: &Path, id: &str) -> CommandResult<RollbackRecord> {
        self.storage(|s| {
            let row = read(&s.connection, id)?;
            if Path::new(&row.source.evidence.repository_path) != root {
                return Err(changed());
            }
            Ok(row)
        })
    }
    pub(super) fn insert(&self, record: &RollbackRecord) -> CommandResult<()> {
        let payload = encode(record)?;
        self.storage(|s| {
            let tx = s
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            let all = rows(&tx)?;
            if all.len() >= MAX_RECORDS
                || all.iter().any(|r| {
                    r.source.record_id == record.source.record_id
                        && r.source.evidence.repository_path
                            == record.source.evidence.repository_path
                })
                || payload_bytes(&tx)? + payload.len() + OBSERVATION_RESERVE > MAX_TOTAL
            {
                return Err(unavailable());
            }
            tx.execute(
                "INSERT INTO pushes(id,repository_path,payload) VALUES(?1,?2,?3)",
                params![
                    record.record_id,
                    record.source.evidence.repository_path,
                    payload
                ],
            )
            .map_err(|_| unavailable())?;
            tx.commit().map_err(|_| unavailable())?;
            sync_read(s, record)
        })
    }
    pub(super) fn observe(
        &self,
        expected: &RollbackRecord,
        observed: Option<String>,
        now: u64,
    ) -> CommandResult<RollbackRecord> {
        let mut next = expected.clone();
        next.revision = next.revision.checked_add(1).ok_or_else(unavailable)?;
        next.outcome = match observed.as_deref() {
            Some(sha) if sha == expected.candidate_sha => RollbackOutcome::CandidateObserved,
            Some(_) => RollbackOutcome::OtherHeadObserved,
            None => RollbackOutcome::Unconfirmed,
        };
        next.observed_remote_sha = observed;
        next.checked_at_epoch_ms = Some(now);
        if next.outcome == RollbackOutcome::CandidateObserved
            && next.candidate_observed_at_epoch_ms.is_none()
        {
            next.candidate_observed_at_epoch_ms = Some(now);
        }
        let payload = encode(&next)?;
        self.storage(|s| {
            let tx = s
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|_| unavailable())?;
            if read(&tx, &expected.record_id)? != *expected {
                return Err(changed());
            }
            rows(&tx)?;
            let total = payload_bytes(&tx)?;
            let old_bytes: usize = tx
                .query_row(
                    "SELECT length(CAST(payload AS BLOB)) FROM pushes WHERE id=?1",
                    [&expected.record_id],
                    |r| r.get(0),
                )
                .map_err(|_| unavailable())?;
            if total.checked_sub(old_bytes).ok_or_else(unavailable)? + payload.len() > MAX_TOTAL {
                return Err(unavailable());
            }
            tx.execute(
                "UPDATE pushes SET payload=?1 WHERE id=?2",
                params![payload, expected.record_id],
            )
            .map_err(|_| unavailable())?;
            tx.commit().map_err(|_| unavailable())?;
            sync_read(s, &next)?;
            Ok(next)
        })
    }
}
fn payload_bytes(c: &Connection) -> CommandResult<usize> {
    let bytes: usize = c
        .query_row(
            "SELECT COALESCE(SUM(length(CAST(payload AS BLOB))),0) FROM pushes",
            [],
            |r| r.get(0),
        )
        .map_err(|_| unavailable())?;
    if bytes > MAX_TOTAL {
        return Err(unavailable());
    }
    Ok(bytes)
}
fn sync_read(storage: &Storage, row: &RollbackRecord) -> CommandResult<()> {
    File::open(&storage.directory)
        .and_then(|f| f.sync_all())
        .map_err(|_| unavailable())?;
    if read(&storage.connection, &row.record_id)? != *row {
        return Err(unavailable());
    }
    Ok(())
}
fn read(c: &Connection, id: &str) -> CommandResult<RollbackRecord> {
    let text = c.query_row("SELECT CASE WHEN length(CAST(payload AS BLOB)) <= 65536 THEN payload ELSE NULL END FROM pushes WHERE id=?1",[id],|r|r.get::<_,String>(0)).optional().map_err(|_| unavailable())?.ok_or_else(changed)?;
    let row = decode(&text)?;
    if row.record_id != id {
        return Err(unavailable());
    }
    Ok(row)
}
fn rows(c: &Connection) -> CommandResult<Vec<RollbackRecord>> {
    let mut q = c.prepare("SELECT id,repository_path,CASE WHEN length(CAST(payload AS BLOB)) <= 65536 THEN payload ELSE NULL END FROM pushes ORDER BY rowid DESC LIMIT 201").map_err(|_| unavailable())?;
    let rows = q
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .map_err(|_| unavailable())?;
    let mut result = Vec::new();
    let mut bytes = 0;
    let mut sources = std::collections::HashSet::new();
    for row in rows {
        let (id, root, text) = row.map_err(|_| unavailable())?;
        bytes += text.len();
        let r = decode(&text)?;
        if result.len() >= MAX_RECORDS
            || bytes > MAX_TOTAL
            || r.record_id != id
            || r.source.evidence.repository_path != root
            || !sources.insert((root, r.source.record_id.clone()))
        {
            return Err(unavailable());
        }
        result.push(r);
    }
    Ok(result)
}
fn encode(row: &RollbackRecord) -> CommandResult<String> {
    validate(row)?;
    let payload = serde_json::to_string(row).map_err(|_| unavailable())?;
    if payload.len() > MAX_ROW {
        return Err(unavailable());
    }
    Ok(payload)
}
fn decode(text: &str) -> CommandResult<RollbackRecord> {
    if text.len() > MAX_ROW {
        return Err(unavailable());
    }
    let row = serde_json::from_str(text).map_err(|_| unavailable())?;
    validate(&row)?;
    Ok(row)
}
fn validate(row: &RollbackRecord) -> CommandResult<()> {
    validate_record(&row.source).map_err(|_| unavailable())?;
    uuid::Uuid::parse_str(&row.record_id).map_err(|_| unavailable())?;
    uuid::Uuid::parse_str(&row.plan_id).map_err(|_| unavailable())?;
    if row.session_id.is_empty()
        || row.session_id.len() > 160
        || row.session_id.chars().any(char::is_control)
    {
        return Err(unavailable());
    }
    let source = &row.source.evidence.expected_sha;
    if row.source.outcome != PublishOutcome::Verified
        || row.source.observed_remote_sha.as_deref() != Some(source)
        || row.source.checked_at_epoch_ms.is_none()
        || row.revision == 0
        || row.revision > MAX_SAFE
        || row.started_at_epoch_ms == 0
        || row.started_at_epoch_ms > MAX_SAFE
        || row
            .checked_at_epoch_ms
            .is_some_and(|t| t < row.started_at_epoch_ms || t > MAX_SAFE)
        || row.changed_paths == 0
        || row.changed_paths > 200
        || row.target_files > 200
        || row.source_tree_sha == row.target_tree_sha
        || row.candidate_sha == *source
        || [
            &row.parent_sha,
            &row.source_tree_sha,
            &row.target_tree_sha,
            &row.candidate_sha,
        ]
        .iter()
        .any(|s| !valid_sha(s) || s.len() != source.len())
        || row
            .observed_remote_sha
            .as_ref()
            .is_some_and(|s| !valid_sha(s) || s.len() != source.len())
    {
        return Err(unavailable());
    }
    let outcome = match row.observed_remote_sha.as_deref() {
        Some(s) if s == row.candidate_sha => RollbackOutcome::CandidateObserved,
        Some(_) => RollbackOutcome::OtherHeadObserved,
        None => RollbackOutcome::Unconfirmed,
    };
    if row.outcome != outcome
        || (row.outcome != RollbackOutcome::Unconfirmed && row.checked_at_epoch_ms.is_none())
        || (row.outcome == RollbackOutcome::CandidateObserved
            && row.candidate_observed_at_epoch_ms.is_none())
        || row.candidate_observed_at_epoch_ms.is_some_and(|t| {
            t < row.started_at_epoch_ms || row.checked_at_epoch_ms.is_none_or(|checked| t > checked)
        })
    {
        return Err(unavailable());
    }
    Ok(())
}

#[cfg(test)]
#[path = "rollback_ledger_diagnostics_tests.rs"]
mod diagnostics_tests;
