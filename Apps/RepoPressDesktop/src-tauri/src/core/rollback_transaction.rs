//! Confirmation-bound inverse append, durable before write, never auto-retried.
use super::rollback_candidate::{build_isolated_message, CandidateBlocker, CandidatePlanStatus};
use super::rollback_change_preview::{
    candidate_snapshot, validate_final_preview, CandidateSnapshot,
};
use super::rollback_ledger::{
    changed, unavailable, RollbackLedgerStore, RollbackOutcome, RollbackRecord,
};
use super::rollback_qualification::{local_conditions, QualificationIdentity, RollbackBlocker};
use super::{CommandResult, PublishLedgerStore, PublishRecord};
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const LIFETIME: Duration = Duration::from_secs(300);
const MAX_PLANS: usize = 8;
const MAX_BYTES: usize = 32 * 1024 * 1024;
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TransactionProblem {
    PriorTransaction,
}
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(untagged)]
pub enum TransactionBlocker {
    Candidate(CandidateBlocker),
    Transaction(TransactionProblem),
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackTransactionPlan {
    #[serde(flatten)]
    pub identity: QualificationIdentity,
    pub status: CandidatePlanStatus,
    pub plan_id: Option<String>,
    pub source_tree_sha: Option<String>,
    pub target_tree_sha: Option<String>,
    pub candidate_sha: Option<String>,
    pub observed_remote_sha: Option<String>,
    pub changed_paths: usize,
    pub target_files: usize,
    pub blockers: Vec<TransactionBlocker>,
    pub checked_at_epoch_ms: u64,
    pub expires_at_epoch_ms: Option<u64>,
}
struct Binding {
    session: String,
    root: PathBuf,
    source: PublishRecord,
    parent: String,
    snapshot: CandidateSnapshot,
    candidate: String,
    created: Instant,
    checked_at: u64,
    commit_seconds: u64,
}
#[derive(Default)]
pub struct RollbackTransactionStore {
    ledger: RollbackLedgerStore,
    plans: Mutex<HashMap<String, Binding>>,
    // Serializes preparation/execution/recovery, not the SQLite mutex over I/O.
    operation: Mutex<()>,
}
fn now_ms() -> CommandResult<u64> {
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| unavailable())?
        .as_millis();
    if t == 0 || t > 9_007_199_254_440_991 {
        return Err(unavailable());
    }
    Ok(t as u64)
}
fn blocker(b: RollbackBlocker) -> TransactionBlocker {
    TransactionBlocker::Candidate(CandidateBlocker::Local(b))
}
impl RollbackTransactionStore {
    pub fn new(data: PathBuf) -> Self {
        Self {
            ledger: RollbackLedgerStore::new(data),
            ..Self::default()
        }
    }
    pub fn list(&self, root: &Path) -> CommandResult<Vec<RollbackRecord>> {
        self.ledger.list(root)
    }
    pub(crate) fn with_archive_snapshot<T>(
        &self,
        root: &Path,
        expected: &[RollbackRecord],
        write: impl FnOnce() -> CommandResult<T>,
    ) -> CommandResult<T> {
        self.ledger.with_archive_snapshot(root, expected, write)
    }
    pub(crate) fn inspect_local(
        &self,
        root: &Path,
        targets: &[(String, String)],
        scope_partial: bool,
    ) -> CommandResult<(
        Vec<RollbackRecord>,
        super::rollback_ledger::RollbackLedgerDiagnostics,
    )> {
        self.ledger.inspect_local(root, targets, scope_partial)
    }
    fn prior(&self, root: &Path, source: &PublishRecord) -> CommandResult<bool> {
        self.ledger.has_prior(root, source)
    }
    pub fn plan(
        &self,
        session: &str,
        root: &Path,
        pushes: &PublishLedgerStore,
        id: &str,
        revision: u64,
        mut observe: impl FnMut(&PublishRecord) -> CommandResult<Option<String>>,
    ) -> CommandResult<RollbackTransactionPlan> {
        let _operation = self.operation.lock().map_err(|_| unavailable())?;
        {
            let mut plans = self.plans.lock().map_err(|_| unavailable())?;
            plans.retain(|_, b| {
                b.created.elapsed() < LIFETIME
                    && !(b.session == session && b.source.record_id == id)
            });
        }
        let source = pushes.get(root, id)?;
        if source.revision != revision
            || session.is_empty()
            || session.len() > 160
            || session.chars().any(char::is_control)
        {
            return Err(changed());
        }
        pushes.with_record_lease(&source, || {
            let before = local_conditions(root, &source);
            let mut view = RollbackTransactionPlan {
                identity: QualificationIdentity {
                    session_id: session.into(),
                    record_id: id.into(),
                    revision,
                    branch: source.evidence.branch.clone(),
                    remote_url: source.evidence.remote_url.clone(),
                    expected_sha: source.evidence.expected_sha.clone(),
                    parent_sha: before.0.clone(),
                },
                status: CandidatePlanStatus::Blocked,
                plan_id: None,
                source_tree_sha: None,
                target_tree_sha: None,
                candidate_sha: None,
                observed_remote_sha: None,
                changed_paths: 0,
                target_files: 0,
                blockers: before.1.iter().copied().map(blocker).collect(),
                checked_at_epoch_ms: now_ms()?,
                expires_at_epoch_ms: None,
            };
            if self.prior(root, &source)? {
                view.blockers.push(TransactionBlocker::Transaction(
                    TransactionProblem::PriorTransaction,
                ));
            }
            if !view.blockers.is_empty() {
                validate_final_preview(root, pushes, &source, &before)?;
                return Ok(view);
            }
            let parent = before.0.as_deref().ok_or_else(changed)?;
            let snapshot = match candidate_snapshot(root, &source, parent) {
                Ok(s) => s,
                Err(e) => {
                    view.blockers
                        .push(TransactionBlocker::Candidate(CandidateBlocker::Snapshot(e)));
                    validate_final_preview(root, pushes, &source, &before)?;
                    return Ok(view);
                }
            };
            validate_final_preview(root, pushes, &source, &before)?;
            let seconds = now_ms()? / 1000;
            let candidate = build_isolated_message(
                &source.evidence.expected_sha,
                &snapshot,
                seconds,
                false,
                |_| Ok(()),
            )?;
            let sha = candidate.sha.clone();
            candidate.directory.close().map_err(|_| unavailable())?;
            view.observed_remote_sha = observe(&source)?;
            validate_final_preview(root, pushes, &source, &before)?;
            if candidate_snapshot(root, &source, parent).map_err(|_| changed())? != snapshot {
                return Err(changed());
            }
            validate_final_preview(root, pushes, &source, &before)?;
            if view.observed_remote_sha.as_deref() != Some(&source.evidence.expected_sha) {
                view.blockers
                    .push(blocker(if view.observed_remote_sha.is_some() {
                        RollbackBlocker::RemoteDifferent
                    } else {
                        RollbackBlocker::RemoteUnavailable
                    }));
                view.checked_at_epoch_ms = now_ms()?;
                return Ok(view);
            }
            let mut plans = self.plans.lock().map_err(|_| unavailable())?;
            plans.retain(|_, b| b.created.elapsed() < LIFETIME);
            let retained: usize = plans
                .values()
                .flat_map(|b| &b.snapshot.objects)
                .map(|o| o.bytes.len())
                .sum();
            let bytes: usize = snapshot.objects.iter().map(|o| o.bytes.len()).sum();
            if plans.len() >= MAX_PLANS || bytes > MAX_BYTES.saturating_sub(retained) {
                return Err(unavailable());
            }
            let plan_id = Uuid::new_v4().to_string();
            view.checked_at_epoch_ms = now_ms()?;
            view.status = CandidatePlanStatus::Ready;
            view.plan_id = Some(plan_id.clone());
            view.source_tree_sha = Some(snapshot.source_tree.clone());
            view.target_tree_sha = Some(snapshot.target_tree.clone());
            view.candidate_sha = Some(sha.clone());
            view.changed_paths = snapshot.changed_paths;
            view.target_files = snapshot.target_files;
            view.expires_at_epoch_ms = Some(view.checked_at_epoch_ms + LIFETIME.as_millis() as u64);
            plans.insert(
                plan_id,
                Binding {
                    session: session.into(),
                    root: root.into(),
                    source: source.clone(),
                    parent: parent.into(),
                    snapshot,
                    candidate: sha,
                    created: Instant::now(),
                    checked_at: view.checked_at_epoch_ms,
                    commit_seconds: seconds,
                },
            );
            Ok(view)
        })
    }
    pub fn discard(&self, session: &str, id: &str) -> CommandResult<()> {
        let mut plans = self.plans.lock().map_err(|_| unavailable())?;
        if plans.get(id).is_some_and(|b| b.session != session) {
            return Err(changed());
        }
        plans.remove(id);
        Ok(())
    }
    pub fn execute(
        &self,
        session: &str,
        root: CommandResult<PathBuf>,
        pushes: &PublishLedgerStore,
        id: &str,
        mut observe: impl FnMut(&PublishRecord) -> CommandResult<Option<String>>,
        push: impl FnOnce(&Path, &RollbackRecord, &dyn Fn() -> CommandResult<()>) -> CommandResult<()>,
    ) -> CommandResult<RollbackRecord> {
        let _operation = self.operation.lock().map_err(|_| unavailable())?;
        let binding = self
            .plans
            .lock()
            .map_err(|_| unavailable())?
            .remove(id)
            .ok_or_else(changed)?;
        let root = root?;
        if binding.session != session || binding.root != root {
            return Err(changed());
        }
        let current = || -> CommandResult<()> {
            let t = now_ms()?;
            if binding.created.elapsed() >= LIFETIME
                || t < binding.checked_at
                || t >= binding.checked_at + LIFETIME.as_millis() as u64
            {
                return Err(changed());
            }
            validate_final_preview(
                &root,
                pushes,
                &binding.source,
                &(Some(binding.parent.clone()), vec![]),
            )?;
            Ok(())
        };
        pushes.with_record_lease(&binding.source, || {
            current()?;
            if self.prior(&root, &binding.source)? {
                return Err(changed());
            }
            if candidate_snapshot(&root, &binding.source, &binding.parent).map_err(|_| changed())?
                != binding.snapshot
            {
                return Err(changed());
            }
            current()?;
            let candidate = build_isolated_message(
                &binding.source.evidence.expected_sha,
                &binding.snapshot,
                binding.commit_seconds,
                false,
                |_| Ok(()),
            )?;
            if candidate.sha != binding.candidate {
                return Err(changed());
            }
            // The remote already owns source and its ancestry. Bound pack walking
            // in the isolated sender without lying about raw commit bytes.
            std::fs::write(
                candidate.directory.path().join("shallow"),
                format!("{}\n", binding.source.evidence.expected_sha),
            )
            .map_err(|_| unavailable())?;
            if observe(&binding.source)?.as_deref() != Some(&binding.source.evidence.expected_sha) {
                return Err(changed());
            }
            current()?;
            if candidate_snapshot(&root, &binding.source, &binding.parent).map_err(|_| changed())?
                != binding.snapshot
            {
                return Err(changed());
            }
            current()?;
            let row = RollbackRecord {
                record_id: Uuid::new_v4().to_string(),
                plan_id: id.into(),
                session_id: session.into(),
                revision: 1,
                source: binding.source.clone(),
                parent_sha: binding.parent.clone(),
                source_tree_sha: binding.snapshot.source_tree.clone(),
                target_tree_sha: binding.snapshot.target_tree.clone(),
                candidate_sha: candidate.sha.clone(),
                changed_paths: binding.snapshot.changed_paths,
                target_files: binding.snapshot.target_files,
                outcome: RollbackOutcome::Unconfirmed,
                observed_remote_sha: None,
                started_at_epoch_ms: now_ms()?,
                checked_at_epoch_ms: None,
                candidate_observed_at_epoch_ms: None,
            };
            self.ledger.insert(&row)?;
            // Any failure from here leaves a durable unconfirmed intent. A CLI
            // exit code is not a receipt; always observe once, never retry.
            current()?;
            let _write_result = push(candidate.directory.path(), &row, &current);
            let observed = observe(&row.source).ok().flatten();
            let result = self.ledger.observe(&row, observed, now_ms()?);
            // Never let cleanup errors erase the durable recovery evidence.
            candidate.directory.close().map_err(|_| unavailable())?;
            result
        })
    }
    /// Independent explicit read-only request; works after source record removal
    /// and restart. Only frozen target identity is required, not candidate bodies.
    pub fn verify(
        &self,
        root: &Path,
        id: &str,
        revision: u64,
        mut observe: impl FnMut(&PublishRecord) -> CommandResult<Option<String>>,
    ) -> CommandResult<RollbackRecord> {
        let _operation = self.operation.lock().map_err(|_| unavailable())?;
        let row = self.ledger.get(root, id)?;
        if row.revision != revision {
            return Err(changed());
        }
        super::git_publish::validate_recorded_push_target(root, &row.source)?;
        let observed = observe(&row.source)?;
        super::git_publish::validate_recorded_push_target(root, &row.source)?;
        self.ledger.observe(&row, observed, now_ms()?)
    }
}

#[cfg(test)]
#[path = "rollback_transaction_tests.rs"]
mod tests;
