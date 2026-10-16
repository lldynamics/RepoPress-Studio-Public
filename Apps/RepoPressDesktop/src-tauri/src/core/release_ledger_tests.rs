use super::*;
use crate::core::{CommandError, PublishEvidence, RemoteProvider, RemoteReviewEvidence};
use std::fs;
use std::process::Command;

fn push(id: &str) -> PublishRecord {
    PublishRecord {
        record_id: id.into(),
        revision: 1,
        evidence: PublishEvidence {
            repository_path: "/repo".into(),
            repository_identity: "c".repeat(64),
            operation: PushOperation::Push,
            remote: "origin".into(),
            remote_url: "https://github.com/owner/project.git".into(),
            branch: "feature".into(),
            expected_sha: "a".repeat(40),
            observed_before_sha: None,
            changed_paths: vec![],
        },
        outcome: PublishOutcome::Verified,
        observed_remote_sha: Some("a".repeat(40)),
        started_at_epoch_ms: 10,
        checked_at_epoch_ms: Some(20),
    }
}
fn review(id: &str) -> RemoteReviewRecord {
    RemoteReviewRecord {
        record_id: id.into(),
        revision: 1,
        evidence: RemoteReviewEvidence {
            repository_path: "/repo".into(),
            repository_identity: "c".repeat(64),
            remote: "origin".into(),
            remote_url: "https://github.com/owner/project.git".into(),
            provider: RemoteProvider::Github,
            owner: "owner".into(),
            project: "project".into(),
            remote_project_id: 1,
            source_branch: "feature".into(),
            target_branch: "main".into(),
            source_sha: "a".repeat(40),
            title_sha256: "a".repeat(64),
            body_sha256: "b".repeat(64),
            marker: id.into(),
        },
        outcome: ReviewOutcome::Verified,
        verification: ReviewVerification::Matched,
        review_number: Some(1),
        web_url: Some("https://github.com/owner/project/pull/1".into()),
        started_at_epoch_ms: 10,
        checked_at_epoch_ms: Some(20),
    }
}
fn project(pushes: Vec<PublishRecord>, reviews: Vec<RemoteReviewRecord>) -> ReleaseLedgerSnapshot {
    project_release_ledger("session", Ok(pushes), Ok(reviews), |_| Ok(()), |_| Ok(()))
}

#[test]
fn preserves_namespaced_attempts_with_same_sha_and_deterministic_order() {
    let result = project(
        vec![push("shared"), push("another")],
        vec![review("shared")],
    );
    assert_eq!(result.summary.total, 3);
    assert_eq!(result.summary.verified_pushes, 2);
    assert_eq!(result.summary.verified_reviews, 1);
    assert_eq!(result.entries[0].record_id, "another");
    assert_eq!(result.entries[1].source, ReleaseLedgerSource::GitPush);
    assert_eq!(result.entries[2].source, ReleaseLedgerSource::RemoteReview);
    let json = serde_json::to_value(result).unwrap();
    assert_eq!(json["entries"][2]["status"], "reviewVerified");
    assert_eq!(json["entries"][2]["targetBranch"], "main");
    assert!(json.get("deployment").is_none());
}

#[test]
fn never_promotes_mismatched_sha_or_missing_check_time() {
    let mut mismatch = push("wrong");
    mismatch.observed_remote_sha = Some("b".repeat(40));
    let mut missing = push("missing");
    missing.checked_at_epoch_ms = None;
    let result = project(vec![mismatch, missing], vec![]);
    assert_eq!(result.summary.verified_pushes, 0);
    assert_eq!(result.summary.needs_attention, 2);
    assert!(result
        .entries
        .iter()
        .all(|r| r.status == ReleaseLedgerStatus::EvidenceMismatch));
}

#[test]
fn review_requires_full_correlated_receipt_not_just_matched_flag() {
    let mut bad_url = review("url");
    bad_url.web_url = Some("https://github.com/other/project/pull/1".into());
    let mut no_number = review("number");
    no_number.review_number = None;
    let mut no_time = review("time");
    no_time.checked_at_epoch_ms = None;
    let mut no_outcome = review("outcome");
    no_outcome.outcome = ReviewOutcome::Unconfirmed;
    let result = project(vec![], vec![bad_url, no_number, no_time, no_outcome]);
    assert_eq!(result.summary.verified_reviews, 0);
    assert_eq!(result.summary.needs_attention, 4);
}

#[test]
fn different_and_unavailable_observations_do_not_mean_failure() {
    let mut different = push("different");
    different.outcome = PublishOutcome::Different;
    different.observed_remote_sha = Some("b".repeat(40));
    let mut unknown = review("unknown");
    unknown.outcome = ReviewOutcome::Unconfirmed;
    unknown.verification = ReviewVerification::Unavailable;
    let result = project(vec![different], vec![unknown]);
    assert_eq!(
        result.entries[0].status,
        ReleaseLedgerStatus::RemoteDifferent
    );
    assert_eq!(result.entries[1].status, ReleaseLedgerStatus::Unconfirmed);
    assert_eq!(result.summary.needs_attention, 2);
}

#[test]
fn current_target_changes_override_historical_verification() {
    let result = project_release_ledger(
        "session",
        Ok(vec![push("push")]),
        Ok(vec![review("review")]),
        |_| {
            Err(CommandError::new(
                "publish_record_target_changed",
                "changed",
            ))
        },
        |_| Err(CommandError::new("local_git_read_failed", "private error")),
    );
    assert_eq!(result.entries[0].status, ReleaseLedgerStatus::TargetChanged);
    assert_eq!(
        result.entries[1].status,
        ReleaseLedgerStatus::EvidenceMismatch
    );
    assert_eq!(result.summary.needs_attention, 2);
    assert!(!serde_json::to_string(&result)
        .unwrap()
        .contains("private error"));
}

#[test]
fn failed_sources_are_partial_instead_of_empty_success() {
    let unavailable = || CommandError::new("store_failed", "private database location");
    let result = project_release_ledger(
        "session",
        Err(unavailable()),
        Ok(vec![review("review")]),
        |_| Ok(()),
        |_| Ok(()),
    );
    assert_eq!(result.partial_sources, vec![ReleaseLedgerSource::GitPush]);
    assert_eq!(result.summary.total, 1);
    let both = project_release_ledger(
        "session",
        Err(unavailable()),
        Err(unavailable()),
        |_| Ok(()),
        |_| Ok(()),
    );
    assert_eq!(both.partial_sources.len(), 2);
    assert_eq!(both.warnings.len(), 2);
    assert_eq!(both.summary.total, 0);
    assert!(!serde_json::to_string(&both)
        .unwrap()
        .contains("private database"));
}

#[test]
fn accepts_400_attempts_but_rejects_overfull_or_duplicate_sources_wholesale() {
    let pushes = (0..200).map(|i| push(&i.to_string())).collect();
    let reviews = (0..200).map(|i| review(&i.to_string())).collect();
    assert_eq!(project(pushes, reviews).summary.total, 400);
    let overfull = (0..201).map(|i| push(&i.to_string())).collect();
    let result = project(overfull, vec![review("keep")]);
    assert_eq!(result.partial_sources, vec![ReleaseLedgerSource::GitPush]);
    assert_eq!(result.summary.total, 1);
    let result = project(vec![push("dup"), push("dup")], vec![]);
    assert_eq!(result.summary.total, 0);
    assert_eq!(result.partial_sources, vec![ReleaseLedgerSource::GitPush]);
}

#[test]
fn reads_persisted_attempt_after_restart_without_contacting_unreachable_remote() {
    let repo = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let git = |args: &[&str]| {
        let out = Command::new("git")
            .args(args)
            .current_dir(repo.path())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{:?}: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
    };
    git(&["init", "-b", "main"]);
    git(&["config", "user.name", "Fixture"]);
    git(&["config", "user.email", "fixture@example.test"]);
    fs::write(repo.path().join("article.md"), "Text").unwrap();
    git(&["add", "article.md"]);
    git(&["commit", "-m", "initial"]);
    git(&[
        "remote",
        "add",
        "origin",
        "https://github.com/repopress-fixture/unreachable.git",
    ]);
    let evidence = super::super::capture_review_target(repo.path(), "origin").unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let expected_sha = evidence.expected_sha.clone();
    {
        let store = PublishLedgerStore::new(data.path().to_path_buf());
        store
            .begin(&id, evidence)
            .unwrap()
            .finish(Some(expected_sha))
            .unwrap();
    }
    let pushes = PublishLedgerStore::new(data.path().to_path_buf());
    let result = read_release_ledger(
        "reopened",
        repo.path(),
        &pushes,
        &RemoteReviewLedgerStore::default(),
        &RollbackTransactionStore::new(data.path().to_path_buf()),
    );
    assert_eq!(result.session_id, "reopened");
    assert_eq!(result.summary.verified_pushes, 1);
    assert_eq!(
        result.partial_sources,
        vec![ReleaseLedgerSource::RemoteReview]
    );
    git(&[
        "remote",
        "set-url",
        "origin",
        "https://github.com/repopress-fixture/changed.git",
    ]);
    let changed = read_release_ledger(
        "reopened",
        repo.path(),
        &pushes,
        &RemoteReviewLedgerStore::default(),
        &RollbackTransactionStore::new(data.path().to_path_buf()),
    );
    assert_eq!(
        changed.entries[0].status,
        ReleaseLedgerStatus::TargetChanged
    );
    assert_eq!(changed.summary.verified_pushes, 0);
}

fn rollback(id: &str) -> RollbackRecord {
    RollbackRecord {
        record_id: id.into(),
        plan_id: uuid::Uuid::new_v4().to_string(),
        session_id: "session".into(),
        revision: 2,
        source: push("source"),
        parent_sha: "b".repeat(40),
        source_tree_sha: "c".repeat(40),
        target_tree_sha: "d".repeat(40),
        candidate_sha: "e".repeat(40),
        changed_paths: 1,
        target_files: 1,
        outcome: RollbackOutcome::CandidateObserved,
        observed_remote_sha: Some("e".repeat(40)),
        started_at_epoch_ms: 30,
        checked_at_epoch_ms: Some(40),
        candidate_observed_at_epoch_ms: Some(40),
    }
}
fn project3(
    records: Vec<RollbackRecord>,
    target: impl Fn(&RollbackRecord) -> CommandResult<()>,
) -> ReleaseLedgerSnapshot {
    project_with_rollbacks(
        "session",
        Ok(vec![push("shared")]),
        Ok(vec![review("shared")]),
        Ok((records, RollbackLedgerDiagnostics::unavailable())),
        |_| Ok(()),
        |_| Ok(()),
        target,
    )
}
#[test]
fn rollback_history_keeps_first_proof_independent_of_latest_unknown_or_other_head() {
    let mut unknown = rollback("unknown");
    unknown.outcome = RollbackOutcome::Unconfirmed;
    unknown.observed_remote_sha = None;
    unknown.checked_at_epoch_ms = Some(50);
    let mut other = rollback("other");
    other.outcome = RollbackOutcome::OtherHeadObserved;
    other.observed_remote_sha = Some(other.source.evidence.expected_sha.clone());
    other.checked_at_epoch_ms = Some(50);
    let result = project3(vec![rollback("shared"), unknown, other], |_| Ok(()));
    assert_eq!(result.summary.total, 5);
    assert_eq!(result.summary.rollback_transactions, 3);
    assert_eq!(result.summary.historical_candidate_observations, 3);
    assert_eq!(result.summary.unresolved_rollback_transactions, 0);
    assert_eq!(result.summary.needs_attention, 2);
    let r = result
        .entries
        .iter()
        .find(|r| r.record_id == "unknown")
        .unwrap();
    assert_eq!(r.status, ReleaseLedgerStatus::Unconfirmed);
    assert_eq!(
        r.rollback.as_ref().unwrap().candidate_observed_at_epoch_ms,
        Some(40)
    );
    assert_eq!(
        result
            .entries
            .iter()
            .filter(|r| r.record_id == "shared")
            .count(),
        3
    );
    assert_eq!(
        result
            .entries
            .iter()
            .find(|r| r.record_id == "other")
            .unwrap()
            .status,
        ReleaseLedgerStatus::RollbackOtherHeadObserved
    );
}
#[test]
fn rollback_target_drift_never_erases_historical_candidate_evidence_or_grants_success() {
    let result = project3(vec![rollback("changed")], |_| {
        Err(CommandError::new(
            "publish_record_target_changed",
            "private",
        ))
    });
    assert_eq!(result.summary.historical_candidate_observations, 1);
    assert_eq!(result.summary.needs_attention, 1);
    assert_eq!(result.entries[0].status, ReleaseLedgerStatus::TargetChanged);
    assert_eq!(
        result.entries[0]
            .rollback
            .as_ref()
            .unwrap()
            .latest_observation,
        RollbackOutcome::CandidateObserved
    );
    assert!(!serde_json::to_string(&result).unwrap().contains("private"));
}
#[test]
fn rollback_source_failure_overfull_and_duplicate_never_become_empty_healthy_diagnostics() {
    let missing = project_with_rollbacks(
        "session",
        Ok(vec![push("keep")]),
        Ok(vec![]),
        Err(CommandError::new("private_db_failed", "secret")),
        |_| Ok(()),
        |_| Ok(()),
        |_| Ok(()),
    );
    assert_eq!(missing.partial_sources, vec![ReleaseLedgerSource::Rollback]);
    assert_eq!(missing.rollback_diagnostics.status, "unavailable");
    assert_eq!(missing.rollback_diagnostics.global_records, None);
    assert!(missing.rollback_diagnostics.blocked_targets.is_empty());
    assert_eq!(missing.summary.rollback_transactions, 0);
    assert_eq!(missing.summary.total, 1);
    let duplicate = project3(vec![rollback("same"), rollback("same")], |_| Ok(()));
    assert_eq!(
        duplicate.partial_sources,
        vec![ReleaseLedgerSource::Rollback]
    );
    assert_eq!(duplicate.summary.total, 2);
    let overfull = project3((0..201).map(|i| rollback(&i.to_string())).collect(), |_| {
        Ok(())
    });
    assert_eq!(
        overfull.partial_sources,
        vec![ReleaseLedgerSource::Rollback]
    );
    assert_eq!(overfull.rollback_diagnostics.capacity, "unavailable");
}
#[test]
fn all_three_sources_can_supply_600_namespaced_attempts() {
    let result = project_with_rollbacks(
        "session",
        Ok((0..200).map(|i| push(&i.to_string())).collect()),
        Ok((0..200).map(|i| review(&i.to_string())).collect()),
        Ok((
            (0..200).map(|i| rollback(&i.to_string())).collect(),
            RollbackLedgerDiagnostics::unavailable(),
        )),
        |_| Ok(()),
        |_| Ok(()),
        |_| Ok(()),
    );
    assert_eq!(result.summary.total, 600);
    assert!(result.partial_sources.is_empty());
    assert_eq!(result.summary.rollback_transactions, 200);
    assert_eq!(result.summary.historical_candidate_observations, 200);
}

#[test]
fn restarted_unified_history_survives_removed_push_source_and_checks_target_without_transport() {
    let repo = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let git = |args: &[&str]| {
        let out = Command::new("git")
            .args(args)
            .current_dir(repo.path())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{:?}: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
    };
    git(&["init", "-b", "main"]);
    git(&["config", "user.name", "Fixture"]);
    git(&["config", "user.email", "fixture@example.test"]);
    fs::write(repo.path().join("article.md"), "Text").unwrap();
    git(&["add", "."]);
    git(&["commit", "-m", "fixture"]);
    git(&[
        "remote",
        "add",
        "origin",
        "https://github.com/fixture/unreachable.git",
    ]);
    let pushes = PublishLedgerStore::new(data.path().to_path_buf());
    let evidence = super::super::capture_review_target(repo.path(), "origin").unwrap();
    let source = pushes
        .begin(&uuid::Uuid::new_v4().to_string(), evidence.clone())
        .unwrap()
        .finish(Some(evidence.expected_sha))
        .unwrap();
    let mut row = rollback(&uuid::Uuid::new_v4().to_string());
    row.source = source.clone();
    row.started_at_epoch_ms = source.checked_at_epoch_ms.unwrap() + 1;
    row.checked_at_epoch_ms = Some(row.started_at_epoch_ms + 2);
    row.candidate_observed_at_epoch_ms = Some(row.started_at_epoch_ms + 1);
    row.outcome = RollbackOutcome::Unconfirmed;
    row.observed_remote_sha = None;
    let ledger = super::super::rollback_ledger::RollbackLedgerStore::new(data.path().to_path_buf());
    ledger.insert(&row).unwrap();
    pushes
        .remove_checked(repo.path(), &source.record_id, source.revision)
        .unwrap();
    drop(ledger);
    drop(pushes);
    let pushes = PublishLedgerStore::new(data.path().to_path_buf());
    let rollbacks = RollbackTransactionStore::new(data.path().to_path_buf());
    let result = read_release_ledger(
        "new-session",
        repo.path(),
        &pushes,
        &RemoteReviewLedgerStore::default(),
        &rollbacks,
    );
    assert_eq!(result.entries.len(), 1);
    assert_eq!(result.entries[0].source, ReleaseLedgerSource::Rollback);
    assert_eq!(result.entries[0].status, ReleaseLedgerStatus::Unconfirmed);
    assert_eq!(result.summary.historical_candidate_observations, 1);
    assert_eq!(result.summary.unresolved_rollback_transactions, 0);
    assert_eq!(result.rollback_diagnostics.local_records, Some(1));
    assert!(result.rollback_diagnostics.blocked_targets.is_empty());
    assert!(!result.rollback_diagnostics.scope_partial);
    git(&[
        "remote",
        "set-url",
        "origin",
        "https://github.com/fixture/changed.git",
    ]);
    let changed = read_release_ledger(
        "new-session",
        repo.path(),
        &pushes,
        &RemoteReviewLedgerStore::default(),
        &rollbacks,
    );
    assert_eq!(
        changed.entries[0].status,
        ReleaseLedgerStatus::TargetChanged
    );
    assert_eq!(changed.summary.historical_candidate_observations, 1);
    assert_eq!(rollbacks.list(repo.path()).unwrap(), vec![row]);
}
