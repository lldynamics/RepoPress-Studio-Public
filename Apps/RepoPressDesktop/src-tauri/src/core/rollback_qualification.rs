//! P35: read-only, ephemeral checks of basic conditions. Never a mutation plan.
use super::git_publish::{inspect_recorded_rollback_objects, RecordedCommitShape};
use super::publish_ledger::PublishOutcome;
use super::{CommandError, CommandResult, PublishLedgerStore, PublishRecord};
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const LIFETIME: Duration = Duration::from_secs(300);
const MAX_PLANS: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RollbackBlocker {
    RecordUnconfirmed,
    ObjectsUnavailable,
    RootCommit,
    MergeCommit,
    TargetChanged,
    EvidenceMismatch,
    RemoteDifferent,
    RemoteUnavailable,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LocalQualification {
    Candidate,
    Blocked,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum QualificationStatus {
    Qualified,
    Blocked,
    Unknown,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QualificationIdentity {
    pub session_id: String,
    pub record_id: String,
    pub revision: u64,
    pub branch: String,
    pub remote_url: String,
    pub expected_sha: String,
    pub parent_sha: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackQualificationPlan {
    #[serde(flatten)]
    pub identity: QualificationIdentity,
    pub local_status: LocalQualification,
    pub blockers: Vec<RollbackBlocker>,
    pub plan_id: Option<String>,
    pub expires_at_epoch_ms: Option<u64>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackQualificationReport {
    #[serde(flatten)]
    pub identity: QualificationIdentity,
    pub status: QualificationStatus,
    pub blockers: Vec<RollbackBlocker>,
    pub remote_sha: Option<String>,
    pub checked_at_epoch_ms: u64,
}
struct Binding {
    session_id: String,
    root: PathBuf,
    record: PublishRecord,
    parent: String,
    created: Instant,
}
#[derive(Default)]
pub struct RollbackQualificationStore {
    plans: Mutex<HashMap<String, Binding>>,
}

fn unavailable() -> CommandError {
    CommandError::new(
        "rollback_qualification_unavailable",
        "Unable to inspect rollback conditions.",
    )
}
fn invalid_plan() -> CommandError {
    CommandError::new(
        "rollback_qualification_plan_invalid",
        "The read-only qualification plan expired or changed; inspect again.",
    )
}
fn now_ms() -> CommandResult<u64> {
    let value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| unavailable())?
        .as_millis();
    if value == 0 || value > 9_007_199_254_440_991 {
        return Err(unavailable());
    }
    Ok(value as u64)
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
pub(super) fn local_conditions(
    root: &Path,
    record: &PublishRecord,
) -> (Option<String>, Vec<RollbackBlocker>) {
    if let Err(error) = super::validate_recorded_push_target(root, record) {
        return (
            None,
            vec![if error.code == "publish_record_target_changed" {
                RollbackBlocker::TargetChanged
            } else {
                RollbackBlocker::EvidenceMismatch
            }],
        );
    }
    if record.outcome != PublishOutcome::Verified
        || record.checked_at_epoch_ms.is_none()
        || record.observed_remote_sha.as_deref() != Some(record.evidence.expected_sha.as_str())
    {
        return (None, vec![RollbackBlocker::RecordUnconfirmed]);
    }
    match inspect_recorded_rollback_objects(root, &record.evidence.expected_sha) {
        Ok(RecordedCommitShape::SingleParent(parent)) => (Some(parent), vec![]),
        Ok(RecordedCommitShape::Root) => (None, vec![RollbackBlocker::RootCommit]),
        Ok(RecordedCommitShape::Merge) => (None, vec![RollbackBlocker::MergeCommit]),
        Err(_) => (None, vec![RollbackBlocker::ObjectsUnavailable]),
    }
}
impl RollbackQualificationStore {
    pub fn plan(
        &self,
        session: &str,
        root: &Path,
        ledger: &PublishLedgerStore,
        id: &str,
        revision: u64,
    ) -> CommandResult<RollbackQualificationPlan> {
        let record = ledger.get(root, id)?;
        if record.revision != revision {
            return Err(invalid_plan());
        }
        let (parent, blockers) = local_conditions(root, &record);
        // Local facts and the durable row must remain the same while planning.
        if ledger.get(root, id)? != record {
            return Err(invalid_plan());
        }
        if blockers.is_empty() {
            let again = local_conditions(root, &record);
            if again.0 != parent || !again.1.is_empty() {
                return Err(invalid_plan());
            }
        }
        let mut view = RollbackQualificationPlan {
            identity: identity(session, &record, parent.clone()),
            local_status: LocalQualification::Blocked,
            blockers,
            plan_id: None,
            expires_at_epoch_ms: None,
        };
        if let Some(parent) = parent.filter(|_| view.blockers.is_empty()) {
            let mut plans = self.plans.lock().map_err(|_| unavailable())?;
            plans.retain(|_, b| b.created.elapsed() < LIFETIME);
            if plans.len() >= MAX_PLANS {
                return Err(unavailable());
            }
            let id = Uuid::new_v4().to_string();
            view.local_status = LocalQualification::Candidate;
            view.plan_id = Some(id.clone());
            view.expires_at_epoch_ms = Some(now_ms()? + LIFETIME.as_millis() as u64);
            plans.insert(
                id,
                Binding {
                    session_id: session.into(),
                    root: root.into(),
                    record,
                    parent,
                    created: Instant::now(),
                },
            );
        }
        Ok(view)
    }

    /// Consume first, including wrong session, expired plan, missing root and errors.
    /// The observer is called only after all local facts have been revalidated.
    pub fn check(
        &self,
        session: &str,
        root: CommandResult<PathBuf>,
        ledger: &PublishLedgerStore,
        plan_id: &str,
        observe: impl FnOnce(&PublishRecord) -> CommandResult<Option<String>>,
    ) -> CommandResult<RollbackQualificationReport> {
        let binding = self
            .plans
            .lock()
            .map_err(|_| unavailable())?
            .remove(plan_id)
            .ok_or_else(invalid_plan)?;
        let root = root?;
        if binding.session_id != session
            || binding.root != root
            || binding.created.elapsed() >= LIFETIME
        {
            return Err(invalid_plan());
        }
        let mut report = RollbackQualificationReport {
            identity: identity(session, &binding.record, Some(binding.parent.clone())),
            status: QualificationStatus::Blocked,
            blockers: vec![],
            remote_sha: None,
            checked_at_epoch_ms: now_ms()?,
        };
        let check_local = || -> CommandResult<Vec<RollbackBlocker>> {
            if ledger.get(&root, &binding.record.record_id)? != binding.record {
                return Err(invalid_plan());
            }
            let (parent, mut reasons) = local_conditions(&root, &binding.record);
            if reasons.is_empty() && parent.as_deref() != Some(binding.parent.as_str()) {
                reasons.push(RollbackBlocker::ObjectsUnavailable);
            }
            Ok(reasons)
        };
        report.blockers = check_local()?;
        if !report.blockers.is_empty() {
            return Ok(report);
        }
        let observed = observe(&binding.record);
        report.blockers = check_local()?;
        report.checked_at_epoch_ms = now_ms()?;
        if !report.blockers.is_empty() {
            return Ok(report);
        }
        match observed {
            Ok(Some(sha)) if super::publish_ledger::valid_sha(&sha) => {
                if sha == binding.record.evidence.expected_sha {
                    report.status = QualificationStatus::Qualified;
                } else {
                    report.blockers.push(RollbackBlocker::RemoteDifferent);
                }
                report.remote_sha = Some(sha);
            }
            _ => {
                report.status = QualificationStatus::Unknown;
                report.blockers.push(RollbackBlocker::RemoteUnavailable);
            }
        }
        Ok(report)
    }
}

#[cfg(test)]
#[path = "rollback_qualification_tests.rs"]
mod tests;
