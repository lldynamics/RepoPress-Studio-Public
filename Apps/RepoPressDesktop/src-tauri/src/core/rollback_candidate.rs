//! Ephemeral, isolated local inverse candidates. No user-repository or remote writes.
use super::git_publish::{
    initialize_local_candidate, read_local_rollback_object, write_local_candidate_object,
};
use super::rollback_change_preview::{
    candidate_snapshot, commit_tree, digest_matches, validate_final_preview, CandidateSnapshot,
    SnapshotProblem,
};
use super::rollback_qualification::{local_conditions, QualificationIdentity, RollbackBlocker};
use super::{CommandError, CommandResult, PublishLedgerStore, PublishRecord};
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const LIFETIME: Duration = Duration::from_secs(300);
const MAX_PLANS: usize = 8;
const MAX_RETAINED_BYTES: usize = 32 * 1024 * 1024;
const BUILD_TIME: Duration = Duration::from_secs(20);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CandidatePlanStatus {
    Ready,
    Blocked,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum CandidateBlocker {
    Local(RollbackBlocker),
    Snapshot(SnapshotProblem),
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackCandidatePlan {
    #[serde(flatten)]
    pub identity: QualificationIdentity,
    pub status: CandidatePlanStatus,
    pub plan_id: Option<String>,
    pub source_tree_sha: Option<String>,
    pub target_tree_sha: Option<String>,
    pub changed_paths: usize,
    pub target_files: usize,
    pub blockers: Vec<CandidateBlocker>,
    pub checked_at_epoch_ms: u64,
    pub expires_at_epoch_ms: Option<u64>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackCandidateReport {
    #[serde(flatten)]
    pub identity: QualificationIdentity,
    pub plan_id: String,
    pub source_tree_sha: String,
    pub target_tree_sha: String,
    pub candidate_sha: String,
    pub changed_paths: usize,
    pub target_files: usize,
    pub generated_at_epoch_ms: u64,
    pub temporary_objects_removed: bool,
}
struct Binding {
    session: String,
    root: PathBuf,
    record: PublishRecord,
    parent: String,
    snapshot: CandidateSnapshot,
    created: Instant,
    checked_at: u64,
}
#[derive(Default)]
pub struct RollbackCandidateStore {
    plans: Mutex<HashMap<String, Binding>>,
    // Bound transient snapshot memory and avoid competing preparations/builds.
    preparation: Mutex<()>,
}
fn invalid() -> CommandError {
    CommandError::new(
        "rollback_candidate_changed",
        "The local candidate plan expired or changed; prepare again.",
    )
}
fn unavailable() -> CommandError {
    CommandError::new(
        "rollback_candidate_unavailable",
        "Unable to prepare or verify the temporary local candidate.",
    )
}
fn now_ms() -> CommandResult<u64> {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| unavailable())?
        .as_millis();
    if n == 0 || n > 9_007_199_254_440_991 {
        return Err(unavailable());
    }
    Ok(n as u64)
}
fn identity(
    session: &str,
    record: &PublishRecord,
    parent: Option<String>,
) -> QualificationIdentity {
    QualificationIdentity {
        session_id: session.into(),
        record_id: record.record_id.clone(),
        revision: record.revision,
        branch: record.evidence.branch.clone(),
        remote_url: record.evidence.remote_url.clone(),
        expected_sha: record.evidence.expected_sha.clone(),
        parent_sha: parent,
    }
}
impl RollbackCandidateStore {
    pub fn plan(
        &self,
        session: &str,
        root: &Path,
        ledger: &PublishLedgerStore,
        id: &str,
        revision: u64,
    ) -> CommandResult<RollbackCandidatePlan> {
        let _preparation = self.preparation.lock().map_err(|_| unavailable())?;
        {
            let mut plans = self.plans.lock().map_err(|_| unavailable())?;
            plans.retain(|_, b| {
                b.created.elapsed() < LIFETIME
                    && !(b.session == session && b.record.record_id == id)
            });
        }
        let record = ledger.get(root, id)?;
        if record.revision != revision {
            return Err(invalid());
        }
        let before = local_conditions(root, &record);
        let mut view = RollbackCandidatePlan {
            identity: identity(session, &record, before.0.clone()),
            status: CandidatePlanStatus::Blocked,
            plan_id: None,
            source_tree_sha: None,
            target_tree_sha: None,
            changed_paths: 0,
            target_files: 0,
            blockers: before
                .1
                .iter()
                .copied()
                .map(CandidateBlocker::Local)
                .collect(),
            checked_at_epoch_ms: now_ms()?,
            expires_at_epoch_ms: None,
        };
        let snapshot = if let Some(parent) = before.0.as_deref().filter(|_| before.1.is_empty()) {
            match candidate_snapshot(root, &record, parent) {
                Ok(snapshot) => Some(snapshot),
                Err(problem) => {
                    view.blockers.push(CandidateBlocker::Snapshot(problem));
                    None
                }
            }
        } else {
            None
        };
        validate_final_preview(root, ledger, &record, &before).map_err(|_| invalid())?;
        view.checked_at_epoch_ms = now_ms()?;
        if let Some(snapshot) = snapshot {
            let mut plans = self.plans.lock().map_err(|_| unavailable())?;
            plans.retain(|_, b| b.created.elapsed() < LIFETIME);
            let bytes: usize = snapshot.objects.iter().map(|o| o.bytes.len()).sum();
            let retained: usize = plans
                .values()
                .flat_map(|b| &b.snapshot.objects)
                .map(|o| o.bytes.len())
                .sum();
            if plans.len() >= MAX_PLANS || bytes > MAX_RETAINED_BYTES.saturating_sub(retained) {
                return Err(unavailable());
            }
            let plan_id = Uuid::new_v4().to_string();
            view.status = CandidatePlanStatus::Ready;
            view.plan_id = Some(plan_id.clone());
            view.source_tree_sha = Some(snapshot.source_tree.clone());
            view.target_tree_sha = Some(snapshot.target_tree.clone());
            view.changed_paths = snapshot.changed_paths;
            view.target_files = snapshot.target_files;
            view.expires_at_epoch_ms = Some(view.checked_at_epoch_ms + LIFETIME.as_millis() as u64);
            plans.insert(
                plan_id,
                Binding {
                    session: session.into(),
                    root: root.into(),
                    record,
                    parent: before.0.ok_or_else(invalid)?,
                    snapshot,
                    created: Instant::now(),
                    checked_at: view.checked_at_epoch_ms,
                },
            );
        }
        Ok(view)
    }
    /// Idempotent cancellation may only remove this session's plans.
    pub fn discard(&self, session: &str, id: &str) -> CommandResult<()> {
        let mut plans = self.plans.lock().map_err(|_| unavailable())?;
        if plans.get(id).is_some_and(|b| b.session != session) {
            return Err(invalid());
        }
        plans.remove(id);
        Ok(())
    }
    pub fn generate(
        &self,
        session: &str,
        root: CommandResult<PathBuf>,
        ledger: &PublishLedgerStore,
        id: &str,
    ) -> CommandResult<RollbackCandidateReport> {
        self.generate_with(session, root, ledger, id, |_| Ok(()))
    }
    fn generate_with(
        &self,
        session: &str,
        root: CommandResult<PathBuf>,
        ledger: &PublishLedgerStore,
        id: &str,
        inspect: impl FnOnce(&Path) -> CommandResult<()>,
    ) -> CommandResult<RollbackCandidateReport> {
        // Serialize before moving a snapshot out of storage, keeping retained and
        // in-flight snapshot memory bounded. No caller facts are checked yet.
        let _preparation = self.preparation.lock().map_err(|_| unavailable())?;
        // Remove before validation: wrong session, missing root and expiry consume it.
        let binding = self
            .plans
            .lock()
            .map_err(|_| unavailable())?
            .remove(id)
            .ok_or_else(invalid)?;
        let root = root?;
        if binding.session != session || binding.root != root {
            return Err(invalid());
        }
        let revalidate = || -> CommandResult<()> {
            if binding.created.elapsed() >= LIFETIME {
                return Err(invalid());
            }
            validate_final_preview(
                &root,
                ledger,
                &binding.record,
                &(Some(binding.parent.clone()), vec![]),
            )
            .map_err(|_| invalid())?;
            let again = candidate_snapshot(&root, &binding.record, &binding.parent)
                .map_err(|_| invalid())?;
            if again != binding.snapshot {
                return Err(invalid());
            }
            // Object rereads can take time; close that window for target/row drift.
            validate_final_preview(
                &root,
                ledger,
                &binding.record,
                &(Some(binding.parent.clone()), vec![]),
            )
            .map_err(|_| invalid())?;
            Ok(())
        };
        revalidate()?;
        let generated = now_ms()?;
        if generated < binding.checked_at
            || generated >= binding.checked_at + LIFETIME.as_millis() as u64
        {
            return Err(invalid());
        }
        let candidate = build_isolated(
            &binding.record.evidence.expected_sha,
            &binding.snapshot,
            generated / 1000,
            inspect,
        )?;
        revalidate()?;
        let finished = now_ms()?;
        if finished < generated || finished >= binding.checked_at + LIFETIME.as_millis() as u64 {
            return Err(invalid());
        }
        let sha = candidate.sha.clone();
        // Only an explicit successful close can assert cleanup in the report.
        candidate.directory.close().map_err(|_| unavailable())?;
        Ok(RollbackCandidateReport {
            identity: identity(session, &binding.record, Some(binding.parent)),
            plan_id: id.into(),
            source_tree_sha: binding.snapshot.source_tree,
            target_tree_sha: binding.snapshot.target_tree,
            candidate_sha: sha,
            changed_paths: binding.snapshot.changed_paths,
            target_files: binding.snapshot.target_files,
            generated_at_epoch_ms: finished,
            temporary_objects_removed: true,
        })
    }
}
pub(super) struct IsolatedCandidate {
    pub(super) directory: tempfile::TempDir,
    pub(super) sha: String,
}
pub(super) fn build_isolated(
    source: &str,
    snapshot: &CandidateSnapshot,
    seconds: u64,
    inspect: impl FnOnce(&Path) -> CommandResult<()>,
) -> CommandResult<IsolatedCandidate> {
    build_isolated_message(source, snapshot, seconds, true, inspect)
}
pub(super) fn build_isolated_message(
    source: &str,
    snapshot: &CandidateSnapshot,
    seconds: u64,
    review_only: bool,
    inspect: impl FnOnce(&Path) -> CommandResult<()>,
) -> CommandResult<IsolatedCandidate> {
    let directory = tempfile::Builder::new()
        .prefix("repopress-rollback-candidate-")
        .tempdir()
        .map_err(|_| unavailable())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
            .map_err(|_| unavailable())?;
        let meta = std::fs::symlink_metadata(directory.path()).map_err(|_| unavailable())?;
        if !meta.is_dir()
            || meta.file_type().is_symlink()
            || meta.mode() & 0o077 != 0
            || meta.uid() != unsafe { libc::geteuid() }
        {
            return Err(unavailable());
        }
    }
    let deadline = Instant::now() + BUILD_TIME;
    let remaining = || {
        deadline
            .checked_duration_since(Instant::now())
            .filter(|v| !v.is_zero())
            .ok_or_else(unavailable)
    };
    initialize_local_candidate(
        directory.path(),
        if source.len() == 40 { "sha1" } else { "sha256" },
        remaining()?,
    )?;
    for object in &snapshot.objects {
        if !digest_matches(object.kind, &object.bytes, &object.oid)
            || write_local_candidate_object(
                directory.path(),
                object.kind,
                &object.bytes,
                remaining()?,
            )? != object.oid
        {
            return Err(unavailable());
        }
    }
    let message = if review_only {
        "Review-only inverse"
    } else {
        "Restore parent snapshot"
    };
    let bytes = format!("tree {}\nparent {source}\nauthor RepoPress Review <review@repopress.invalid> {seconds} +0000\ncommitter RepoPress Review <review@repopress.invalid> {seconds} +0000\n\n{message} of {source}\n", snapshot.target_tree).into_bytes();
    let sha = write_local_candidate_object(directory.path(), "commit", &bytes, remaining()?)?;
    inspect(directory.path())?;
    for object in &snapshot.objects {
        let read = read_local_rollback_object(
            directory.path(),
            object.kind,
            &object.oid,
            64 * 1024,
            remaining()?,
        )?;
        if read != object.bytes || !digest_matches(object.kind, &read, &object.oid) {
            return Err(unavailable());
        }
    }
    let read =
        read_local_rollback_object(directory.path(), "commit", &sha, 64 * 1024, remaining()?)?;
    let (tree, parents) = commit_tree(&read, source.len() / 2).map_err(|_| unavailable())?;
    if read != bytes
        || !digest_matches("commit", &read, &sha)
        || tree != snapshot.target_tree
        || parents != vec![source.to_string()]
    {
        return Err(unavailable());
    }
    Ok(IsolatedCandidate { directory, sha })
}

#[cfg(test)]
#[path = "rollback_candidate_tests.rs"]
mod tests;
