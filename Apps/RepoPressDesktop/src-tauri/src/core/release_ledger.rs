//! Local-only projection of P31/P32/P38. No credentials, transport or new persistence.
use super::publish_ledger::{PublishOutcome, PushOperation};
use super::remote_review_ledger::ReviewOutcome;
use super::rollback_ledger::{RollbackLedgerDiagnostics, RollbackOutcome, RollbackRecord};
use super::RollbackTransactionStore;
use super::{
    CommandResult, PublishLedgerStore, PublishRecord, RemoteReviewLedgerStore, RemoteReviewRecord,
    ReviewVerification,
};
use serde::Serialize;
use std::collections::HashSet;
use std::path::Path;

const MAX_SOURCE_RECORDS: usize = 200;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReleaseLedgerSource {
    GitPush,
    RemoteReview,
    Rollback,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReleaseLedgerStatus {
    PushVerified,
    ReviewVerified,
    Unconfirmed,
    RemoteDifferent,
    TargetChanged,
    EvidenceMismatch,
    RollbackCandidateObserved,
    RollbackOtherHeadObserved,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReleaseLedgerOperation {
    Push,
    PushRetry,
    GithubReview,
    GitlabReview,
    RollbackAppend,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseLedgerEntry {
    pub source: ReleaseLedgerSource,
    pub record_id: String,
    pub revision: u64,
    pub operation: ReleaseLedgerOperation,
    pub branch: String,
    pub target_branch: Option<String>,
    pub expected_sha: String,
    pub remote_url: String,
    pub started_at_epoch_ms: u64,
    pub checked_at_epoch_ms: Option<u64>,
    pub status: ReleaseLedgerStatus,
    pub rollback: Option<RollbackHistoryDetail>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackHistoryDetail {
    pub source_record_id: String,
    pub source_revision: u64,
    pub source_sha: String,
    pub parent_sha: String,
    pub source_tree_sha: String,
    pub target_tree_sha: String,
    pub changed_paths: usize,
    pub target_files: usize,
    pub latest_observation: RollbackOutcome,
    pub observed_remote_sha: Option<String>,
    pub candidate_observed_at_epoch_ms: Option<u64>,
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseLedgerSummary {
    pub total: usize,
    pub verified_pushes: usize,
    pub verified_reviews: usize,
    pub needs_attention: usize,
    pub rollback_transactions: usize,
    pub historical_candidate_observations: usize,
    pub unresolved_rollback_transactions: usize,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseLedgerSnapshot {
    pub session_id: String,
    pub entries: Vec<ReleaseLedgerEntry>,
    pub partial_sources: Vec<ReleaseLedgerSource>,
    pub warnings: Vec<String>,
    pub summary: ReleaseLedgerSummary,
    pub rollback_diagnostics: RollbackLedgerDiagnostics,
}

pub fn read_release_ledger(
    session_id: &str,
    root: &Path,
    pushes: &PublishLedgerStore,
    reviews: &RemoteReviewLedgerStore,
    rollbacks: &RollbackTransactionStore,
) -> ReleaseLedgerSnapshot {
    let pushes = bounded_source(pushes.list(root), |r| &r.record_id)
        .ok_or_else(super::rollback_ledger::unavailable);
    let targets: Vec<_> = pushes
        .as_ref()
        .map(|rows| {
            rows.iter()
                .map(|r| (r.evidence.remote_url.clone(), r.evidence.branch.clone()))
                .collect()
        })
        .unwrap_or_default();
    let rollback_snapshot = rollbacks.inspect_local(root, &targets, pushes.is_err());
    project_with_rollbacks(
        session_id,
        pushes,
        reviews.list(root),
        rollback_snapshot,
        |record| super::validate_recorded_push_target(root, record),
        |record| {
            if Path::new(&record.evidence.repository_path) != root {
                return Err(super::CommandError::new(
                    "publish_record_target_changed",
                    "Recorded repository differs.",
                ));
            }
            super::validate_review_repository(&record.evidence, false)
        },
        |record| super::validate_recorded_push_target(root, &record.source),
    )
}

fn bounded_source<T>(result: CommandResult<Vec<T>>, id: impl Fn(&T) -> &str) -> Option<Vec<T>> {
    let records = result.ok()?;
    let mut ids = HashSet::new();
    if records.len() > MAX_SOURCE_RECORDS || records.iter().any(|r| !ids.insert(id(r))) {
        return None;
    }
    drop(ids);
    Some(records)
}

fn target_failure(result: CommandResult<()>) -> Option<ReleaseLedgerStatus> {
    result.err().map(|error| {
        if error.code == "publish_record_target_changed" {
            ReleaseLedgerStatus::TargetChanged
        } else {
            ReleaseLedgerStatus::EvidenceMismatch
        }
    })
}

fn project_with_rollbacks(
    session_id: &str,
    pushes: CommandResult<Vec<PublishRecord>>,
    reviews: CommandResult<Vec<RemoteReviewRecord>>,
    rollbacks: CommandResult<(Vec<RollbackRecord>, RollbackLedgerDiagnostics)>,
    push_target: impl Fn(&PublishRecord) -> CommandResult<()>,
    review_target: impl Fn(&RemoteReviewRecord) -> CommandResult<()>,
    rollback_target: impl Fn(&RollbackRecord) -> CommandResult<()>,
) -> ReleaseLedgerSnapshot {
    let mut snapshot = ReleaseLedgerSnapshot {
        session_id: session_id.into(),
        entries: Vec::new(),
        partial_sources: Vec::new(),
        warnings: Vec::new(),
        summary: ReleaseLedgerSummary::default(),
        rollback_diagnostics: RollbackLedgerDiagnostics::unavailable(),
    };
    if let Some(records) = bounded_source(pushes, |r| &r.record_id) {
        for record in records {
            let checked = record.checked_at_epoch_ms.is_some();
            let status = if let Some(failure) = target_failure(push_target(&record)) {
                failure
            } else {
                match record.outcome {
                    PublishOutcome::Verified
                        if checked
                            && record.observed_remote_sha.as_deref()
                                == Some(&record.evidence.expected_sha) =>
                    {
                        ReleaseLedgerStatus::PushVerified
                    }
                    PublishOutcome::Different
                        if checked
                            && record
                                .observed_remote_sha
                                .as_deref()
                                .is_some_and(|s| s != record.evidence.expected_sha) =>
                    {
                        ReleaseLedgerStatus::RemoteDifferent
                    }
                    PublishOutcome::Unconfirmed => ReleaseLedgerStatus::Unconfirmed,
                    _ => ReleaseLedgerStatus::EvidenceMismatch,
                }
            };
            snapshot.entries.push(ReleaseLedgerEntry {
                source: ReleaseLedgerSource::GitPush,
                record_id: record.record_id,
                revision: record.revision,
                operation: match record.evidence.operation {
                    PushOperation::Push => ReleaseLedgerOperation::Push,
                    PushOperation::PushRetry => ReleaseLedgerOperation::PushRetry,
                },
                branch: record.evidence.branch,
                target_branch: None,
                expected_sha: record.evidence.expected_sha,
                remote_url: record.evidence.remote_url,
                started_at_epoch_ms: record.started_at_epoch_ms,
                checked_at_epoch_ms: record.checked_at_epoch_ms,
                status,
                rollback: None,
            });
        }
    } else {
        snapshot.partial_sources.push(ReleaseLedgerSource::GitPush);
        snapshot
            .warnings
            .push("推送记录来源不可用或不完整；当前台账仅展示其他已读取来源。".into());
    }
    if let Some(records) = bounded_source(reviews, |r| &r.record_id) {
        for record in records {
            let matched_receipt = record
                .review_number
                .zip(record.web_url.as_deref())
                .is_some_and(|(number, url)| {
                    super::remote_publish::validate_review_url(&record.evidence, number, url)
                        .is_ok()
                });
            let status = if let Some(failure) = target_failure(review_target(&record)) {
                failure
            } else if record.outcome == ReviewOutcome::Verified
                && record.verification == ReviewVerification::Matched
                && record.checked_at_epoch_ms.is_some()
                && matched_receipt
            {
                ReleaseLedgerStatus::ReviewVerified
            } else if record.outcome == ReviewOutcome::Unconfirmed
                && record.verification != ReviewVerification::Matched
            {
                ReleaseLedgerStatus::Unconfirmed
            } else {
                ReleaseLedgerStatus::EvidenceMismatch
            };
            snapshot.entries.push(ReleaseLedgerEntry {
                source: ReleaseLedgerSource::RemoteReview,
                record_id: record.record_id,
                revision: record.revision,
                operation: match record.evidence.provider {
                    super::RemoteProvider::Github => ReleaseLedgerOperation::GithubReview,
                    super::RemoteProvider::Gitlab => ReleaseLedgerOperation::GitlabReview,
                },
                branch: record.evidence.source_branch,
                target_branch: Some(record.evidence.target_branch),
                expected_sha: record.evidence.source_sha,
                remote_url: record.evidence.remote_url,
                started_at_epoch_ms: record.started_at_epoch_ms,
                checked_at_epoch_ms: record.checked_at_epoch_ms,
                status,
                rollback: None,
            });
        }
    } else {
        snapshot
            .partial_sources
            .push(ReleaseLedgerSource::RemoteReview);
        snapshot
            .warnings
            .push("PR/MR 记录来源不可用或不完整；当前台账仅展示其他已读取来源。".into());
    }
    let rollback_source = rollbacks.ok().and_then(|(rows, diagnostics)| {
        bounded_source(Ok(rows), |r| &r.record_id).map(|rows| (rows, diagnostics))
    });
    if let Some((records, diagnostics)) = rollback_source {
        snapshot.rollback_diagnostics = diagnostics;
        for record in records {
            let status = target_failure(rollback_target(&record)).unwrap_or(match record.outcome {
                RollbackOutcome::CandidateObserved => {
                    ReleaseLedgerStatus::RollbackCandidateObserved
                }
                RollbackOutcome::OtherHeadObserved => {
                    ReleaseLedgerStatus::RollbackOtherHeadObserved
                }
                RollbackOutcome::Unconfirmed => ReleaseLedgerStatus::Unconfirmed,
            });
            snapshot.summary.rollback_transactions += 1;
            if record.candidate_observed_at_epoch_ms.is_some() {
                snapshot.summary.historical_candidate_observations += 1;
            } else {
                snapshot.summary.unresolved_rollback_transactions += 1;
            }
            snapshot.entries.push(ReleaseLedgerEntry {
                source: ReleaseLedgerSource::Rollback,
                record_id: record.record_id,
                revision: record.revision,
                operation: ReleaseLedgerOperation::RollbackAppend,
                branch: record.source.evidence.branch,
                target_branch: None,
                expected_sha: record.candidate_sha,
                remote_url: record.source.evidence.remote_url,
                started_at_epoch_ms: record.started_at_epoch_ms,
                checked_at_epoch_ms: record.checked_at_epoch_ms,
                status,
                rollback: Some(RollbackHistoryDetail {
                    source_record_id: record.source.record_id,
                    source_revision: record.source.revision,
                    source_sha: record.source.evidence.expected_sha,
                    parent_sha: record.parent_sha,
                    source_tree_sha: record.source_tree_sha,
                    target_tree_sha: record.target_tree_sha,
                    changed_paths: record.changed_paths,
                    target_files: record.target_files,
                    latest_observation: record.outcome,
                    observed_remote_sha: record.observed_remote_sha,
                    candidate_observed_at_epoch_ms: record.candidate_observed_at_epoch_ms,
                }),
            });
        }
    } else {
        snapshot.partial_sources.push(ReleaseLedgerSource::Rollback);
        snapshot.warnings.push(
            "恢复记录来源不可用或不完整；容量和未决诊断不可用，读取失败不等于没有记录。".into(),
        );
    }
    snapshot.entries.sort_by(|a, b| {
        b.started_at_epoch_ms
            .cmp(&a.started_at_epoch_ms)
            .then(a.source.cmp(&b.source))
            .then(a.record_id.cmp(&b.record_id))
    });
    for entry in &snapshot.entries {
        snapshot.summary.total += 1;
        match entry.status {
            ReleaseLedgerStatus::PushVerified => snapshot.summary.verified_pushes += 1,
            ReleaseLedgerStatus::ReviewVerified => snapshot.summary.verified_reviews += 1,
            ReleaseLedgerStatus::RollbackCandidateObserved => {}
            _ => snapshot.summary.needs_attention += 1,
        }
    }
    snapshot
}

#[cfg(test)]
#[path = "release_ledger_tests.rs"]
mod tests;

#[cfg(test)]
fn project_release_ledger(
    session_id: &str,
    pushes: CommandResult<Vec<PublishRecord>>,
    reviews: CommandResult<Vec<RemoteReviewRecord>>,
    push_target: impl Fn(&PublishRecord) -> CommandResult<()>,
    review_target: impl Fn(&RemoteReviewRecord) -> CommandResult<()>,
) -> ReleaseLedgerSnapshot {
    let mut diagnostics = RollbackLedgerDiagnostics::unavailable();
    diagnostics.status = "available";
    diagnostics.capacity = "available";
    diagnostics.global_records = Some(0);
    diagnostics.payload_bytes = Some(0);
    diagnostics.remaining_payload_bytes = Some(4 * 1024 * 1024 - 51200);
    diagnostics.local_records = Some(0);
    diagnostics.local_unresolved = Some(0);
    diagnostics.scope_partial = pushes.is_err();
    project_with_rollbacks(
        session_id,
        pushes,
        reviews,
        Ok((vec![], diagnostics)),
        push_target,
        review_target,
        |_| Ok(()),
    )
}
