use super::*;
use crate::core::publish_ledger::{PublishOutcome, PushOperation};
use crate::core::rollback_ledger::{RollbackLedgerStore, RollbackOutcome};
use crate::core::{PublishEvidence, PublishRecord};
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};

fn record(root: &Path) -> RollbackRecord {
    RollbackRecord {
        record_id: Uuid::new_v4().to_string(),
        plan_id: Uuid::new_v4().to_string(),
        session_id: "old-session".into(),
        revision: 1,
        source: PublishRecord {
            record_id: Uuid::new_v4().to_string(),
            revision: 1,
            evidence: PublishEvidence {
                repository_path: root.to_str().unwrap().into(),
                repository_identity: "a".repeat(64),
                operation: PushOperation::Push,
                remote: "origin".into(),
                remote_url: "https://github.com/fixture/project.git".into(),
                branch: "main".into(),
                expected_sha: "a".repeat(40),
                observed_before_sha: None,
                changed_paths: vec!["private/draft.md".into()],
            },
            outcome: PublishOutcome::Verified,
            observed_remote_sha: Some("a".repeat(40)),
            started_at_epoch_ms: 10,
            checked_at_epoch_ms: Some(20),
        },
        parent_sha: "b".repeat(40),
        source_tree_sha: "c".repeat(40),
        target_tree_sha: "d".repeat(40),
        candidate_sha: "e".repeat(40),
        changed_paths: 1,
        target_files: 1,
        outcome: RollbackOutcome::Unconfirmed,
        observed_remote_sha: None,
        started_at_epoch_ms: 30,
        checked_at_epoch_ms: None,
        candidate_observed_at_epoch_ms: None,
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    data: PathBuf,
    root: PathBuf,
    output: PathBuf,
    records: Vec<RollbackRecord>,
    transactions: RollbackTransactionStore,
    archive: RollbackArchiveStore,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let data = temp.path().join("data");
        let root = temp.path().join("repository");
        let output = temp.path().join("exports");
        fs::create_dir(&root).unwrap();
        fs::create_dir(&output).unwrap();
        let ledger = RollbackLedgerStore::new(data.clone());
        let a = record(&root);
        let mut b = record(&root);
        b.outcome = RollbackOutcome::OtherHeadObserved;
        b.observed_remote_sha = Some("f".repeat(40));
        b.checked_at_epoch_ms = Some(50);
        b.candidate_observed_at_epoch_ms = Some(40);
        let foreign = record(&temp.path().join("private-foreign"));
        for row in [&a, &b, &foreign] {
            ledger.insert(row).unwrap();
        }
        let records = ledger.list(&root).unwrap();
        drop(ledger);
        Self {
            _temp: temp,
            data: data.clone(),
            root,
            output,
            records,
            transactions: RollbackTransactionStore::new(data),
            archive: RollbackArchiveStore::default(),
        }
    }
    fn target(&self) -> PathBuf {
        self.output.join("evidence.json")
    }
    fn plan(&self) -> RollbackArchivePlan {
        self.archive
            .plan(
                "current-session",
                &self.root,
                &self.target(),
                &self.transactions,
            )
            .unwrap()
    }
    fn execute(&self, p: &RollbackArchivePlan) -> CommandResult<RollbackArchiveResult> {
        self.archive.execute(
            "current-session",
            &self.root,
            &p.plan_id,
            &self.transactions,
            || Ok(()),
        )
    }
}
#[test]
fn preview_and_export_only_current_root_frozen_evidence_keep_ledger_and_private_bytes() {
    let f = Fixture::new();
    let p = f.plan();
    assert!(!f.target().exists());
    assert_eq!(p.record_count, 2);
    assert_eq!(p.unresolved_count, 1);
    assert_eq!(p.historical_observation_count, 1);
    assert_eq!(p.expires_at_epoch_ms - p.created_at_epoch_ms, 300_000);
    assert!(!serde_json::to_string(&p).unwrap().contains("draft.md"));
    let result = f.execute(&p).unwrap();
    let bytes = fs::read(f.target()).unwrap();
    assert_eq!(bytes.len(), p.byte_size);
    assert_eq!(format!("{:x}", Sha256::digest(&bytes)), result.sha256);
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["format"], "repopress-rollback-evidence");
    assert_eq!(json["schemaVersion"], 1);
    assert_eq!(json["capturedAtEpochMs"], p.created_at_epoch_ms);
    assert!(json.get("exportedAtEpochMs").is_none());
    assert_eq!(
        serde_json::from_value::<Vec<RollbackRecord>>(json["records"].clone()).unwrap(),
        f.records
    );
    assert!(!String::from_utf8(bytes)
        .unwrap()
        .contains("private-foreign"));
    let m = fs::metadata(f.target()).unwrap();
    assert_eq!(m.mode() & 0o777, 0o600);
    assert_eq!(m.nlink(), 1);
    assert_eq!(f.transactions.list(&f.root).unwrap(), f.records);
    assert!(f.execute(&p).is_err());
    // Archiving unresolved evidence does not remove the safety latch.
    assert!(
        f.transactions
            .inspect_local(&f.root, &[], false)
            .unwrap()
            .1
            .blocked_targets[0]
            .local_unresolved
            > 0
    );
    assert_eq!(fs::read_dir(&f.output).unwrap().count(), 1);
}
#[test]
fn existing_destination_or_collision_never_overwrites_and_consumes_execution() {
    let f = Fixture::new();
    fs::write(f.target(), "user-owned").unwrap();
    assert!(f
        .archive
        .plan("current-session", &f.root, &f.target(), &f.transactions)
        .is_err());
    assert_eq!(fs::read(f.target()).unwrap(), b"user-owned");
    let second = f.output.join("second.json");
    let p = f
        .archive
        .plan("current-session", &f.root, &second, &f.transactions)
        .unwrap();
    fs::write(&second, "arrived-after-preview").unwrap();
    assert!(f.execute(&p).is_err());
    assert_eq!(fs::read(&second).unwrap(), b"arrived-after-preview");
    fs::remove_file(&second).unwrap();
    assert!(f.execute(&p).is_err());
}
#[test]
fn unsafe_paths_symlinks_shared_parent_and_repository_destination_are_rejected() {
    let f = Fixture::new();
    let alias = f._temp.path().join("alias");
    symlink(&f.output, &alias).unwrap();
    symlink(f.output.join("absent"), f.target()).unwrap();
    for destination in [
        f.target(),
        alias.join("export.json"),
        f.root.join("private.json"),
        f.output.join("../escape.json"),
        PathBuf::from("relative.json"),
        f.output.join("report.txt"),
    ] {
        assert!(
            f.archive
                .plan("current-session", &f.root, &destination, &f.transactions)
                .is_err(),
            "{destination:?}"
        );
    }
    fs::set_permissions(&f.output, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(f
        .archive
        .plan(
            "current-session",
            &f.root,
            &f.output.join("shared.json"),
            &f.transactions
        )
        .is_err());
}
#[test]
fn replaced_destination_directory_after_preview_cannot_redirect_output() {
    let f = Fixture::new();
    let p = f.plan();
    let moved = f._temp.path().join("original");
    fs::rename(&f.output, &moved).unwrap();
    fs::create_dir(&f.output).unwrap();
    assert!(f.execute(&p).is_err());
    assert_eq!(fs::read_dir(&f.output).unwrap().count(), 0);
    assert_eq!(fs::read_dir(&moved).unwrap().count(), 0);
}
#[test]
fn replacement_at_precommit_check_does_not_publish_file_or_leave_temporary_copy() {
    let f = Fixture::new();
    let p = f.plan();
    let moved = f._temp.path().join("original");
    let mut checks = 0;
    assert!(f
        .archive
        .execute(
            "current-session",
            &f.root,
            &p.plan_id,
            &f.transactions,
            || {
                checks += 1;
                if checks == 2 {
                    fs::rename(&f.output, &moved).unwrap();
                    fs::create_dir(&f.output).unwrap();
                }
                Ok(())
            }
        )
        .is_err());
    assert_eq!(checks, 2);
    assert_eq!(fs::read_dir(&f.output).unwrap().count(), 0);
    assert_eq!(fs::read_dir(&moved).unwrap().count(), 0);
    assert!(f.execute(&p).is_err());
}
#[test]
fn concurrent_collision_at_precommit_cannot_replace_user_file() {
    let f = Fixture::new();
    let p = f.plan();
    let mut checks = 0;
    assert!(f
        .archive
        .execute(
            "current-session",
            &f.root,
            &p.plan_id,
            &f.transactions,
            || {
                checks += 1;
                if checks == 2 {
                    fs::write(f.target(), b"new user file").unwrap();
                }
                Ok(())
            }
        )
        .is_err());
    assert_eq!(fs::read(f.target()).unwrap(), b"new user file");
    assert_eq!(fs::read_dir(&f.output).unwrap().count(), 1);
}
#[test]
fn local_evidence_revision_drift_invalidates_copy_without_unlocking() {
    let f = Fixture::new();
    let p = f.plan();
    let mut changed = f.records[0].clone();
    changed.revision += 1;
    changed.checked_at_epoch_ms = Some(60);
    let db = rusqlite::Connection::open(f.data.join("rollback-ledger/rollbacks.sqlite3")).unwrap();
    db.execute(
        "UPDATE pushes SET payload=?1 WHERE id=?2",
        rusqlite::params![serde_json::to_string(&changed).unwrap(), changed.record_id],
    )
    .unwrap();
    assert!(f.execute(&p).is_err());
    assert!(!f.target().exists());
    assert_eq!(f.transactions.list(&f.root).unwrap()[0], changed);
    assert!(f.execute(&p).is_err());
}
#[test]
fn valid_foreign_revision_change_does_not_expand_or_invalidate_local_archive() {
    let f = Fixture::new();
    let p = f.plan();
    let db = rusqlite::Connection::open(f.data.join("rollback-ledger/rollbacks.sqlite3")).unwrap();
    let (id, payload): (String, String) = db
        .query_row(
            "SELECT id,payload FROM pushes WHERE repository_path != ?1",
            [f.root.to_str().unwrap()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    let mut r: RollbackRecord = serde_json::from_str(&payload).unwrap();
    r.revision += 1;
    r.checked_at_epoch_ms = Some(60);
    db.execute(
        "UPDATE pushes SET payload=?1 WHERE id=?2",
        rusqlite::params![serde_json::to_string(&r).unwrap(), id],
    )
    .unwrap();
    f.execute(&p).unwrap();
    assert!(!fs::read_to_string(f.target())
        .unwrap()
        .contains("private-foreign"));
}
#[test]
fn corruption_is_not_salvaged_as_empty_or_partial_export() {
    let f = Fixture::new();
    let p = f.plan();
    let db = rusqlite::Connection::open(f.data.join("rollback-ledger/rollbacks.sqlite3")).unwrap();
    db.execute(
        "UPDATE pushes SET payload='{}' WHERE repository_path != ?1",
        [f.root.to_str().unwrap()],
    )
    .unwrap();
    assert!(f.execute(&p).is_err());
    assert!(!f.target().exists());
    assert!(f
        .archive
        .plan("new-session", &f.root, &f.target(), &f.transactions)
        .is_err());
}
#[test]
fn wrong_session_root_expiry_and_discard_are_terminal() {
    let f = Fixture::new();
    let p = f.plan();
    assert!(f
        .archive
        .execute("wrong", &f.root, &p.plan_id, &f.transactions, || Ok(()))
        .is_err());
    assert!(f.execute(&p).is_err());
    let p = f.plan();
    assert!(f
        .archive
        .execute(
            "current-session",
            &f.output,
            &p.plan_id,
            &f.transactions,
            || Ok(())
        )
        .is_err());
    assert!(f.execute(&p).is_err());
    let p = f.plan();
    f.archive
        .plans
        .lock()
        .unwrap()
        .get_mut(&p.plan_id)
        .unwrap()
        .created -= LIFETIME;
    assert!(f.execute(&p).is_err());
    let p = f.plan();
    f.archive.discard("current-session", &p.plan_id).unwrap();
    assert!(f.execute(&p).is_err());
    assert!(!f.target().exists());
}
#[test]
fn new_preview_attempt_invalidates_prior_consent_even_when_new_path_is_invalid() {
    let f = Fixture::new();
    let p = f.plan();
    assert!(f
        .archive
        .plan(
            "current-session",
            &f.root,
            &f.root.join("forbidden.json"),
            &f.transactions
        )
        .is_err());
    assert!(f.execute(&p).is_err());
    assert!(!f.target().exists());
}
#[test]
fn empty_unavailable_and_plan_budget_fail_without_writing() {
    let f = Fixture::new();
    assert!(f
        .archive
        .plan("empty", &f.output, &f.target(), &f.transactions)
        .is_err());
    assert!(f
        .archive
        .plan(
            "unavailable",
            &f.root,
            &f.target(),
            &RollbackTransactionStore::default()
        )
        .is_err());
    for i in 0..MAX_PLANS {
        f.archive
            .plan(
                &format!("session-{i}"),
                &f.root,
                &f.target(),
                &f.transactions,
            )
            .unwrap();
    }
    assert!(f
        .archive
        .plan("ninth", &f.root, &f.target(), &f.transactions)
        .is_err());
    assert!(!f.target().exists());
}
#[test]
fn session_change_after_publication_reports_failure_with_private_copy_and_ledger_retained() {
    let f = Fixture::new();
    let p = f.plan();
    let mut checks = 0;
    assert!(f
        .archive
        .execute(
            "current-session",
            &f.root,
            &p.plan_id,
            &f.transactions,
            || {
                checks += 1;
                if checks == 3 {
                    Err(invalid())
                } else {
                    Ok(())
                }
            }
        )
        .is_err());
    assert_eq!(fs::read(f.target()).unwrap().len(), p.byte_size);
    assert_eq!(f.transactions.list(&f.root).unwrap(), f.records);
    assert!(f.execute(&p).is_err());
}
