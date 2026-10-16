use super::*;
use crate::core::{capture_review_target, observe_recorded_push};
use std::cell::Cell;
use std::fs;
use std::process::Command;

fn git(root: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(output.status.success(), "fixture git failed: {:?}", args);
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}
fn commit(root: &Path, body: &str) {
    fs::write(root.join("article.md"), body).unwrap();
    git(root, &["add", "article.md"]);
    git(root, &["commit", "-m", "fixture"]);
}
struct Fixture {
    repo: tempfile::TempDir,
    remote: tempfile::TempDir,
    _data: tempfile::TempDir,
    ledger: PublishLedgerStore,
}
fn fixture(single_parent: bool) -> Fixture {
    let repo = tempfile::tempdir().unwrap();
    let remote = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    git(repo.path(), &["init", "-b", "main"]);
    git(repo.path(), &["config", "user.name", "Fixture"]);
    git(
        repo.path(),
        &["config", "user.email", "fixture@example.test"],
    );
    commit(repo.path(), "base\n");
    if single_parent {
        commit(repo.path(), "published\n");
    }
    git(remote.path(), &["init", "--bare"]);
    git(
        repo.path(),
        &[
            "remote",
            "add",
            "origin",
            &format!("file://{}", remote.path().display()),
        ],
    );
    git(repo.path(), &["push", "origin", "main"]);
    let ledger = PublishLedgerStore::new(data.path().to_path_buf());
    Fixture {
        repo,
        remote,
        _data: data,
        ledger,
    }
}
fn record(f: &Fixture, verified: bool) -> PublishRecord {
    let evidence = capture_review_target(f.repo.path(), "origin").unwrap();
    let attempt = f
        .ledger
        .begin(&Uuid::new_v4().to_string(), evidence.clone())
        .unwrap();
    if verified {
        attempt.finish(Some(evidence.expected_sha)).unwrap()
    } else {
        let id = f.ledger.list(f.repo.path()).unwrap()[0].record_id.clone();
        drop(attempt);
        f.ledger.get(f.repo.path(), &id).unwrap()
    }
}
fn plan(
    store: &RollbackQualificationStore,
    f: &Fixture,
    r: &PublishRecord,
) -> RollbackQualificationPlan {
    store
        .plan(
            "session",
            f.repo.path(),
            &f.ledger,
            &r.record_id,
            r.revision,
        )
        .unwrap()
}
fn check(
    store: &RollbackQualificationStore,
    f: &Fixture,
    p: &RollbackQualificationPlan,
    obs: impl FnOnce(&PublishRecord) -> CommandResult<Option<String>>,
) -> CommandResult<RollbackQualificationReport> {
    store.check(
        "session",
        Ok(f.repo.path().to_path_buf()),
        &f.ledger,
        p.plan_id.as_deref().unwrap(),
        obs,
    )
}

#[test]
fn historical_single_parent_checks_remote_without_mutating_worktree_or_ledger() {
    let f = fixture(true);
    let r = record(&f, true);
    let store = RollbackQualificationStore::default();
    let p = plan(&store, &f, &r);
    assert_eq!(p.local_status, LocalQualification::Candidate);
    assert_eq!(
        p.identity.parent_sha.as_deref(),
        Some(git(f.repo.path(), &["rev-parse", "HEAD^"]).as_str())
    );
    // Subsequent dirty local state does not turn the historical source into HEAD.
    commit(f.repo.path(), "later\n");
    fs::write(f.repo.path().join("article.md"), "dirty\n").unwrap();
    let head = git(f.repo.path(), &["rev-parse", "HEAD"]);
    let index = fs::read(f.repo.path().join(".git/index")).unwrap();
    let remote_head = git(f.remote.path(), &["rev-parse", "refs/heads/main"]);
    let report = check(&store, &f, &p, |r| {
        observe_recorded_push(f.repo.path(), r, None)
    })
    .unwrap();
    assert_eq!(report.status, QualificationStatus::Qualified);
    assert_eq!(
        report.remote_sha.as_deref(),
        Some(r.evidence.expected_sha.as_str())
    );
    assert!(report.blockers.is_empty());
    assert_eq!(git(f.repo.path(), &["rev-parse", "HEAD"]), head);
    assert_eq!(fs::read(f.repo.path().join(".git/index")).unwrap(), index);
    assert_eq!(
        fs::read_to_string(f.repo.path().join("article.md")).unwrap(),
        "dirty\n"
    );
    assert_eq!(
        git(f.remote.path(), &["rev-parse", "refs/heads/main"]),
        remote_head
    );
    assert_eq!(f.ledger.get(f.repo.path(), &r.record_id).unwrap(), r);
    assert!(check(&store, &f, &p, |_| panic!("replay must not observe")).is_err());
    let json = serde_json::to_value(report).unwrap();
    assert_eq!(json["recordId"], r.record_id);
    assert_eq!(json["status"], "qualified");
}

#[test]
fn unconfirmed_and_root_records_never_create_query_plans() {
    for verified in [false, true] {
        let f = fixture(false);
        let r = record(&f, verified);
        let store = RollbackQualificationStore::default();
        let p = plan(&store, &f, &r);
        assert_eq!(p.local_status, LocalQualification::Blocked);
        assert_eq!(
            p.blockers,
            vec![if verified {
                RollbackBlocker::RootCommit
            } else {
                RollbackBlocker::RecordUnconfirmed
            }]
        );
        assert!(p.plan_id.is_none() && p.expires_at_epoch_ms.is_none());
        assert!(store.plans.lock().unwrap().is_empty());
    }
}

#[test]
fn merge_and_replacement_objects_are_blocked() {
    let f = fixture(true);
    git(f.repo.path(), &["checkout", "-b", "side", "HEAD^"]);
    fs::write(f.repo.path().join("side.md"), "side").unwrap();
    git(f.repo.path(), &["add", "side.md"]);
    git(f.repo.path(), &["commit", "-m", "side"]);
    git(f.repo.path(), &["checkout", "main"]);
    git(f.repo.path(), &["merge", "--no-ff", "side", "-m", "merge"]);
    let r = record(&f, true);
    let store = RollbackQualificationStore::default();
    assert_eq!(
        plan(&store, &f, &r).blockers,
        vec![RollbackBlocker::MergeCommit]
    );
    let f = fixture(true);
    let r = record(&f, true);
    git(
        f.repo.path(),
        &[
            "replace",
            &r.evidence.expected_sha,
            &git(f.repo.path(), &["rev-parse", "HEAD^"]),
        ],
    );
    assert_eq!(
        plan(&store, &f, &r).blockers,
        vec![RollbackBlocker::ObjectsUnavailable]
    );
}

#[test]
fn missing_objects_are_not_hydrated_from_promisor_remote() {
    for object in ["HEAD", "HEAD^", "HEAD^{tree}", "HEAD^^{tree}"] {
        let f = fixture(true);
        let r = record(&f, true);
        let sha = git(f.repo.path(), &["rev-parse", object]);
        let path = f
            .repo
            .path()
            .join(".git/objects")
            .join(&sha[..2])
            .join(&sha[2..]);
        // A real populated file remote could supply the object, but planning must
        // stay local even in a partial clone. Check that the object stays absent.
        git(
            f.repo.path(),
            &["config", "extensions.partialClone", "origin"],
        );
        git(f.repo.path(), &["config", "remote.origin.promisor", "true"]);
        fs::remove_file(&path).unwrap();
        let p = plan(&RollbackQualificationStore::default(), &f, &r);
        assert_eq!(
            p.blockers,
            vec![RollbackBlocker::ObjectsUnavailable],
            "{object}"
        );
        assert!(!path.exists());
        assert!(p.plan_id.is_none());
    }
}

#[test]
fn different_and_unavailable_observations_never_qualify_or_write_receipts() {
    let f = fixture(true);
    let r = record(&f, true);
    let store = RollbackQualificationStore::default();
    for observed in [
        Ok(Some("a".repeat(40))),
        Ok(None),
        Err(CommandError::new("raw", "secret diagnostic")),
        Ok(Some("invalid".into())),
    ] {
        let p = plan(&store, &f, &r);
        let report = check(&store, &f, &p, |_| observed).unwrap();
        assert_ne!(report.status, QualificationStatus::Qualified);
        if report.remote_sha.is_some() {
            assert_eq!(report.blockers, vec![RollbackBlocker::RemoteDifferent]);
            assert_eq!(report.status, QualificationStatus::Blocked);
        } else {
            assert_eq!(report.blockers, vec![RollbackBlocker::RemoteUnavailable]);
            assert_eq!(report.status, QualificationStatus::Unknown);
        }
        assert!(!serde_json::to_string(&report).unwrap().contains("secret"));
        assert_eq!(f.ledger.get(f.repo.path(), &r.record_id).unwrap(), r);
    }
}

#[test]
fn changed_destination_before_or_during_query_cannot_qualify() {
    for change_during in [false, true] {
        let f = fixture(true);
        let r = record(&f, true);
        let store = RollbackQualificationStore::default();
        let p = plan(&store, &f, &r);
        let calls = Cell::new(0);
        let change = || {
            git(
                f.repo.path(),
                &[
                    "remote",
                    "set-url",
                    "origin",
                    "https://github.com/changed/repo.git",
                ],
            );
        };
        if !change_during {
            change();
        }
        let report = check(&store, &f, &p, |_| {
            calls.set(calls.get() + 1);
            change();
            Ok(Some(r.evidence.expected_sha.clone()))
        })
        .unwrap();
        assert_eq!(report.status, QualificationStatus::Blocked);
        assert_eq!(report.blockers, vec![RollbackBlocker::TargetChanged]);
        assert!(report.remote_sha.is_none());
        assert_eq!(calls.get(), usize::from(change_during));
    }
}

#[test]
fn changed_record_before_or_after_query_invalidates_whole_frozen_binding() {
    for change_during in [false, true] {
        let f = fixture(true);
        let r = record(&f, true);
        let store = RollbackQualificationStore::default();
        let p = plan(&store, &f, &r);
        let calls = Cell::new(0);
        let change = || {
            f.ledger
                .verify(&r, || Ok(Some(r.evidence.expected_sha.clone())))
                .unwrap();
        };
        if !change_during {
            change();
        }
        assert!(check(&store, &f, &p, |_| {
            calls.set(calls.get() + 1);
            change();
            Ok(Some(r.evidence.expected_sha.clone()))
        })
        .is_err());
        assert_eq!(calls.get(), usize::from(change_during));
        assert!(check(&store, &f, &p, |_| panic!("consumed plan")).is_err());
    }
}

#[test]
fn expiry_wrong_session_missing_root_and_capacity_fail_closed() {
    let f = fixture(true);
    let r = record(&f, true);
    let store = RollbackQualificationStore::default();
    assert!(store
        .plan(
            "session",
            f.repo.path(),
            &f.ledger,
            &r.record_id,
            r.revision + 1
        )
        .is_err());
    for mode in ["expired", "wrong-session", "missing-root"] {
        let p = plan(&store, &f, &r);
        let id = p.plan_id.as_deref().unwrap();
        if mode == "expired" {
            store.plans.lock().unwrap().get_mut(id).unwrap().created = Instant::now() - LIFETIME;
        }
        let root = if mode == "missing-root" {
            Err(unavailable())
        } else {
            Ok(f.repo.path().to_path_buf())
        };
        assert!(store
            .check(
                if mode == "wrong-session" {
                    "other"
                } else {
                    "session"
                },
                root,
                &f.ledger,
                id,
                |_| panic!("invalid binding must not observe")
            )
            .is_err());
        assert!(check(&store, &f, &p, |_| panic!("consumed binding")).is_err());
    }
    for _ in 0..MAX_PLANS {
        plan(&store, &f, &r);
    }
    assert!(store
        .plan(
            "session",
            f.repo.path(),
            &f.ledger,
            &r.record_id,
            r.revision
        )
        .is_err());
    for b in store.plans.lock().unwrap().values_mut() {
        b.created = Instant::now() - LIFETIME;
    }
    assert_eq!(
        plan(&store, &f, &r).local_status,
        LocalQualification::Candidate
    );
}
