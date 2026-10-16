use super::*;
use crate::core::capture_review_target;
use crate::core::git_publish::{observe_recorded_push, push_rollback_candidate};
use std::cell::Cell;
use std::fs;
use std::process::Command;

fn git(root: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "fixture failed {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim().into()
}
struct Fixture {
    directory: tempfile::TempDir,
    root: PathBuf,
    remote: PathBuf,
    data: PathBuf,
    pushes: PublishLedgerStore,
    source: PublishRecord,
}
fn fixture(format: &str) -> Fixture {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().join("repo");
    let remote = directory.path().join("remote.git");
    let data = directory.path().join("data");
    fs::create_dir(&root).unwrap();
    fs::create_dir(&remote).unwrap();
    git(
        &root,
        &["init", "-b", "main", &format!("--object-format={format}")],
    );
    git(&root, &["config", "user.name", "Fixture"]);
    git(&root, &["config", "user.email", "fixture@example.test"]);
    for n in 0..5 {
        fs::write(root.join("changed.md"), format!("revision {n}\n")).unwrap();
        fs::write(root.join("unchanged.bin"), [0, 1, 255, 3]).unwrap();
        git(&root, &["add", "."]);
        git(&root, &["commit", "-m", "fixture"]);
    }
    git(
        &remote,
        &["init", "--bare", &format!("--object-format={format}")],
    );
    git(
        &root,
        &[
            "remote",
            "add",
            "origin",
            &format!("file://{}", remote.display()),
        ],
    );
    git(&root, &["push", "origin", "main"]);
    git(&remote, &["config", "receive.denyNonFastForwards", "true"]);
    let pushes = PublishLedgerStore::new(data.clone());
    let e = capture_review_target(&root, "origin").unwrap();
    let source = pushes
        .begin(&Uuid::new_v4().to_string(), e.clone())
        .unwrap()
        .finish(Some(e.expected_sha))
        .unwrap();
    Fixture {
        directory,
        root,
        remote,
        data,
        pushes,
        source,
    }
}
fn plan(s: &RollbackTransactionStore, f: &Fixture) -> RollbackTransactionPlan {
    s.plan(
        "session",
        &f.root,
        &f.pushes,
        &f.source.record_id,
        f.source.revision,
        |r| observe_recorded_push(&f.root, r, None),
    )
    .unwrap()
}
fn execute(
    s: &RollbackTransactionStore,
    f: &Fixture,
    p: &RollbackTransactionPlan,
) -> CommandResult<RollbackRecord> {
    s.execute(
        "session",
        Ok(f.root.clone()),
        &f.pushes,
        p.plan_id.as_ref().unwrap(),
        |r| observe_recorded_push(&f.root, r, None),
        |dir, r, gate| push_rollback_candidate(&f.root, dir, r, None, gate),
    )
}
#[test]
fn real_inverse_append_is_ff_with_exact_tree_and_preserves_dirty_later_head() {
    for format in ["sha1", "sha256"] {
        let f = fixture(format);
        let s = RollbackTransactionStore::new(f.data.clone());
        let p = plan(&s, &f);
        assert_eq!(p.status, CandidatePlanStatus::Ready);
        assert!(s.list(&f.root).unwrap().is_empty());
        assert_eq!(
            git(&f.remote, &["rev-parse", "main"]),
            f.source.evidence.expected_sha
        );
        fs::write(f.root.join("later.md"), "later commit").unwrap();
        git(&f.root, &["add", "."]);
        git(&f.root, &["commit", "-m", "later"]);
        fs::write(f.root.join("changed.md"), "unsaved private work").unwrap();
        git(&f.root, &["add", "changed.md"]);
        fs::write(f.root.join("unchanged.bin"), [4, 5]).unwrap();
        let head = git(&f.root, &["rev-parse", "HEAD"]);
        let index = fs::read(f.root.join(".git/index")).unwrap();
        let temp = std::cell::RefCell::new(None);
        let row = s
            .execute(
                "session",
                Ok(f.root.clone()),
                &f.pushes,
                p.plan_id.as_ref().unwrap(),
                |r| observe_recorded_push(&f.root, r, None),
                |dir, r, gate| {
                    *temp.borrow_mut() = Some(dir.to_path_buf());
                    assert!(!dir.join("objects/info/alternates").exists());
                    let pending = s.list(&f.root).unwrap();
                    assert_eq!(pending.len(), 1);
                    assert_eq!(pending[0].outcome, RollbackOutcome::Unconfirmed);
                    assert!(pending[0].checked_at_epoch_ms.is_none());
                    // Source row remains reserved over the write/final observation window.
                    assert!(f
                        .pushes
                        .verify(&f.source, || Ok(Some(
                            f.source.evidence.expected_sha.clone()
                        )))
                        .is_err());
                    assert!(f
                        .pushes
                        .remove_checked(&f.root, &f.source.record_id, f.source.revision)
                        .is_err());
                    push_rollback_candidate(&f.root, dir, r, None, gate)
                },
            )
            .unwrap();
        assert_eq!(row.candidate_sha, p.candidate_sha.unwrap());
        assert_eq!(row.outcome, RollbackOutcome::CandidateObserved);
        assert_eq!(git(&f.remote, &["rev-parse", "main"]), row.candidate_sha);
        assert_eq!(
            git(&f.remote, &["rev-parse", "main^"]),
            f.source.evidence.expected_sha
        );
        assert_eq!(git(&f.remote, &["rev-parse", "main:"]), row.target_tree_sha);
        git(&f.remote, &["fsck", "--full"]);
        assert!(!temp.into_inner().unwrap().exists());
        assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), head);
        assert_eq!(fs::read(f.root.join(".git/index")).unwrap(), index);
        assert_eq!(
            fs::read_to_string(f.root.join("changed.md")).unwrap(),
            "unsaved private work"
        );
        assert_eq!(fs::read(f.root.join("unchanged.bin")).unwrap(), [4, 5]);
        assert_eq!(
            f.pushes.get(&f.root, &f.source.record_id).unwrap(),
            f.source
        );
        assert!(execute(
            &s,
            &f,
            &RollbackTransactionPlan {
                candidate_sha: None,
                ..p
            }
        )
        .is_err());
        let out = Command::new("git")
            .arg("-C")
            .arg(&f.root)
            .args(["cat-file", "-e", &row.candidate_sha])
            .output()
            .unwrap();
        assert!(!out.status.success());
    }
}
#[test]
fn exact_lease_rejects_remote_ancestor_descendant_or_deleted_branch_races() {
    for mode in ["ancestor", "descendant", "missing"] {
        let f = fixture("sha1");
        let s = RollbackTransactionStore::new(f.data.clone());
        let p = plan(&s, &f);
        let target = if mode == "descendant" {
            fs::write(f.root.join("other.md"), "other").unwrap();
            git(&f.root, &["add", "."]);
            git(&f.root, &["commit", "-m", "other"]);
            git(&f.root, &["push", "origin", "HEAD:refs/heads/other"]);
            git(&f.root, &["rev-parse", "HEAD"])
        } else {
            git(
                &f.root,
                &["rev-parse", &format!("{}^", f.source.evidence.expected_sha)],
            )
        };
        let row = s
            .execute(
                "session",
                Ok(f.root.clone()),
                &f.pushes,
                p.plan_id.as_ref().unwrap(),
                |r| observe_recorded_push(&f.root, r, None),
                |dir, r, gate| {
                    if mode == "missing" {
                        git(&f.remote, &["update-ref", "-d", "refs/heads/main"]);
                    } else {
                        git(&f.remote, &["update-ref", "refs/heads/main", &target]);
                    }
                    let result = push_rollback_candidate(&f.root, dir, r, None, gate);
                    assert!(result.is_err());
                    result
                },
            )
            .unwrap();
        assert_ne!(row.outcome, RollbackOutcome::CandidateObserved);
        if mode == "missing" {
            assert_eq!(row.outcome, RollbackOutcome::Unconfirmed);
            assert!(row.observed_remote_sha.is_none());
        } else {
            assert_eq!(row.observed_remote_sha.as_deref(), Some(target.as_str()));
            assert_eq!(git(&f.remote, &["rev-parse", "main"]), target);
        }
    }
}
#[test]
fn unknown_survives_restart_and_recovers_read_only_after_source_row_removal() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let p = plan(&s, &f);
    let calls = Cell::new(0);
    let row = s
        .execute(
            "session",
            Ok(f.root.clone()),
            &f.pushes,
            p.plan_id.as_ref().unwrap(),
            |r| {
                calls.set(calls.get() + 1);
                if calls.get() == 1 {
                    observe_recorded_push(&f.root, r, None)
                } else {
                    Ok(None)
                }
            },
            |dir, r, gate| {
                push_rollback_candidate(&f.root, dir, r, None, gate)?;
                Err(changed())
            },
        )
        .unwrap();
    assert_eq!(row.outcome, RollbackOutcome::Unconfirmed);
    assert_eq!(git(&f.remote, &["rev-parse", "main"]), row.candidate_sha);
    assert_eq!(plan(&s, &f).status, CandidatePlanStatus::Blocked);
    drop(s);
    f.pushes
        .remove_checked(&f.root, &f.source.record_id, f.source.revision)
        .unwrap();
    let reopened = RollbackTransactionStore::new(f.data.clone());
    assert_eq!(reopened.list(&f.root).unwrap(), vec![row.clone()]);
    let next = reopened
        .verify(&f.root, &row.record_id, row.revision, |r| {
            observe_recorded_push(&f.root, r, None)
        })
        .unwrap();
    assert_eq!(next.outcome, RollbackOutcome::CandidateObserved);
    assert_eq!(next.revision, row.revision + 1);
    assert!(reopened
        .verify(&f.root, &row.record_id, row.revision, |_| panic!(
            "stale must not query"
        ))
        .is_err());
    assert!(reopened.list(f.directory.path()).unwrap().is_empty());
}
#[test]
fn server_rejection_retains_observation_and_blocks_repeat_attempts() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let p = plan(&s, &f);
    let hooks = f.remote.join("hooks");
    fs::write(hooks.join("pre-receive"), "#!/bin/sh\nexit 1\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(hooks.join("pre-receive"), fs::Permissions::from_mode(0o700)).unwrap();
    }
    let row = execute(&s, &f, &p).unwrap();
    assert_eq!(row.outcome, RollbackOutcome::OtherHeadObserved);
    assert_eq!(
        row.observed_remote_sha,
        Some(f.source.evidence.expected_sha.clone())
    );
    let blocked = plan(&s, &f);
    assert_eq!(blocked.status, CandidatePlanStatus::Blocked);
    assert!(blocked.plan_id.is_none());
    assert_eq!(
        git(&f.remote, &["rev-parse", "main"]),
        f.source.evidence.expected_sha
    );
    // A separate publishing receipt does not permit a blind retry on this branch.
    let e = f.source.evidence.clone();
    let second = f
        .pushes
        .begin(&Uuid::new_v4().to_string(), e.clone())
        .unwrap()
        .finish(Some(e.expected_sha))
        .unwrap();
    let blocked = s
        .plan(
            "session",
            &f.root,
            &f.pushes,
            &second.record_id,
            second.revision,
            |_| panic!("prior unresolved receipt must block network"),
        )
        .unwrap();
    assert_eq!(blocked.status, CandidatePlanStatus::Blocked);
}
#[test]
fn plans_consume_on_wrong_context_expiry_or_replay_and_discard_is_session_bound() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    for case in ["session", "root", "missing", "expired", "clock"] {
        let p = plan(&s, &f);
        let id = p.plan_id.unwrap();
        if case == "expired" {
            s.plans.lock().unwrap().get_mut(&id).unwrap().created = Instant::now() - LIFETIME;
        }
        if case == "clock" {
            s.plans.lock().unwrap().get_mut(&id).unwrap().checked_at = now_ms().unwrap() + 10000;
        }
        let root = if case == "root" {
            Ok(f.directory.path().into())
        } else if case == "missing" {
            Err(changed())
        } else {
            Ok(f.root.clone())
        };
        let session = if case == "session" {
            "wrong"
        } else {
            "session"
        };
        assert!(s
            .execute(
                session,
                root,
                &f.pushes,
                &id,
                |_| panic!("invalid must not query"),
                |_, _, _| panic!("invalid must not push")
            )
            .is_err());
        assert!(s
            .execute(
                "session",
                Ok(f.root.clone()),
                &f.pushes,
                &id,
                |_| panic!("replay"),
                |_, _, _| panic!("replay")
            )
            .is_err());
    }
    let p = plan(&s, &f);
    let id = p.plan_id.unwrap();
    assert!(s.discard("wrong", &id).is_err());
    s.discard("session", &id).unwrap();
    s.discard("session", &id).unwrap();
    assert!(s.plans.lock().unwrap().is_empty());
}
#[test]
fn evidence_or_snapshot_drift_refuses_before_any_write_and_prepare_unknown_has_no_token() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let p = plan(&s, &f);
    f.pushes
        .verify(&f.source, || {
            Ok(Some(f.source.evidence.expected_sha.clone()))
        })
        .unwrap();
    assert!(s
        .execute(
            "session",
            Ok(f.root.clone()),
            &f.pushes,
            p.plan_id.as_ref().unwrap(),
            |_| panic!("drift must not query"),
            |_, _, _| panic!("drift must not push")
        )
        .is_err());
    let r = f.pushes.get(&f.root, &f.source.record_id).unwrap();
    let unknown = s
        .plan(
            "session",
            &f.root,
            &f.pushes,
            &r.record_id,
            r.revision,
            |_| Ok(None),
        )
        .unwrap();
    assert_eq!(unknown.status, CandidatePlanStatus::Blocked);
    assert!(unknown.plan_id.is_none());
    let different = s
        .plan(
            "session",
            &f.root,
            &f.pushes,
            &r.record_id,
            r.revision,
            |_| Ok(Some("a".repeat(40))),
        )
        .unwrap();
    assert_eq!(different.observed_remote_sha, Some("a".repeat(40)));
    assert!(different.plan_id.is_none());
    let p = s
        .plan(
            "session",
            &f.root,
            &f.pushes,
            &r.record_id,
            r.revision,
            |_| Ok(Some(r.evidence.expected_sha.clone())),
        )
        .unwrap();
    let blob = git(
        &f.root,
        &[
            "rev-parse",
            &format!("{}:unchanged.bin", r.evidence.expected_sha),
        ],
    );
    fs::remove_file(
        f.root
            .join(".git/objects")
            .join(&blob[..2])
            .join(&blob[2..]),
    )
    .unwrap();
    assert!(execute(&s, &f, &p).is_err());
    assert!(s.list(&f.root).unwrap().is_empty());
}
#[test]
fn unavailable_private_storage_and_process_lock_fail_closed_before_network_or_write() {
    let f = fixture("sha1");
    let unavailable_store = RollbackTransactionStore::default();
    assert!(unavailable_store
        .plan(
            "session",
            &f.root,
            &f.pushes,
            &f.source.record_id,
            f.source.revision,
            |_| panic!("no durable storage must not query")
        )
        .is_err());
    let s = RollbackTransactionStore::new(f.data.clone());
    let duplicate = RollbackTransactionStore::new(f.data.clone());
    assert!(duplicate.list(&f.root).is_err());
    let p = plan(&s, &f);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            f.data.join("rollback-ledger/rollbacks.sqlite3"),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();
    }
    assert!(s
        .execute(
            "session",
            Ok(f.root.clone()),
            &f.pushes,
            p.plan_id.as_ref().unwrap(),
            |_| panic!("storage drift must precede query"),
            |_, _, _| panic!("storage unavailable must not push")
        )
        .is_err());
}
#[test]
fn final_pre_spawn_gate_consumes_and_leaves_unknown_receipt_without_remote_mutation() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let p = plan(&s, &f);
    let row = s
        .execute(
            "session",
            Ok(f.root.clone()),
            &f.pushes,
            p.plan_id.as_ref().unwrap(),
            |r| observe_recorded_push(&f.root, r, None),
            |dir, r, _gate| push_rollback_candidate(&f.root, dir, r, None, || Err(changed())),
        )
        .unwrap();
    assert_eq!(row.outcome, RollbackOutcome::OtherHeadObserved);
    assert_eq!(
        git(&f.remote, &["rev-parse", "main"]),
        f.source.evidence.expected_sha
    );
    assert!(plan(&s, &f).plan_id.is_none());
}

#[test]
fn first_candidate_observation_is_monotonic_when_remote_later_advances() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let p = plan(&s, &f);
    let row = execute(&s, &f, &p).unwrap();
    let first = row.candidate_observed_at_epoch_ms;
    assert!(first.is_some());
    // A subsequent publication can advance the branch; a read-only observation
    // of that head must not erase the earlier exact candidate observation.
    let after = s
        .verify(&f.root, &row.record_id, row.revision, |_| {
            Ok(Some("a".repeat(40)))
        })
        .unwrap();
    assert_eq!(after.outcome, RollbackOutcome::OtherHeadObserved);
    assert_eq!(after.candidate_observed_at_epoch_ms, first);
    let evidence = f.source.evidence.clone();
    let different_source = f
        .pushes
        .begin(&Uuid::new_v4().to_string(), evidence.clone())
        .unwrap()
        .finish(Some(evidence.expected_sha))
        .unwrap();
    assert!(!s.prior(&f.root, &different_source).unwrap());
    assert!(s.prior(&f.root, &f.source).unwrap());
    let unknown = s
        .verify(&f.root, &after.record_id, after.revision, |_| Ok(None))
        .unwrap();
    assert_eq!(unknown.candidate_observed_at_epoch_ms, first);
    drop(s);
    let reopened = RollbackTransactionStore::new(f.data.clone());
    assert_eq!(reopened.list(&f.root).unwrap(), vec![unknown]);
}
#[test]
fn tampered_receipts_fail_closed_and_a_non_ff_candidate_cannot_use_the_lease() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let p = plan(&s, &f);
    let row = s
        .execute(
            "session",
            Ok(f.root.clone()),
            &f.pushes,
            p.plan_id.as_ref().unwrap(),
            |r| observe_recorded_push(&f.root, r, None),
            |dir, r, gate| {
                let mut forged = r.clone();
                forged.candidate_sha = r.source.evidence.expected_sha.clone();
                assert!(push_rollback_candidate(&f.root, dir, &forged, None, gate).is_err());
                Err(changed())
            },
        )
        .unwrap();
    assert_ne!(row.outcome, RollbackOutcome::CandidateObserved);
    drop(s);
    let db = rusqlite::Connection::open(f.data.join("rollback-ledger/rollbacks.sqlite3")).unwrap();
    let mut altered = serde_json::to_value(&row).unwrap();
    altered["outcome"] = serde_json::json!("candidateObserved");
    db.execute(
        "UPDATE pushes SET payload=?1 WHERE id=?2",
        rusqlite::params![altered.to_string(), row.record_id],
    )
    .unwrap();
    drop(db);
    let reopened = RollbackTransactionStore::new(f.data.clone());
    assert!(reopened.list(&f.root).is_err());
    assert!(reopened
        .plan(
            "session",
            &f.root,
            &f.pushes,
            &f.source.record_id,
            f.source.revision,
            |_| panic!("corrupt evidence must not query")
        )
        .is_err());
}
#[test]
fn plan_slots_are_bounded_and_replacing_even_a_blocked_plan_releases_old_permission() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let mut ids = Vec::new();
    for n in 0..MAX_PLANS {
        let p = s
            .plan(
                &format!("session-{n}"),
                &f.root,
                &f.pushes,
                &f.source.record_id,
                f.source.revision,
                |_| Ok(Some(f.source.evidence.expected_sha.clone())),
            )
            .unwrap();
        ids.push(p.plan_id.unwrap());
    }
    assert!(s
        .plan(
            "extra",
            &f.root,
            &f.pushes,
            &f.source.record_id,
            f.source.revision,
            |_| Ok(Some(f.source.evidence.expected_sha.clone()))
        )
        .is_err());
    let blocked = s
        .plan(
            "session-0",
            &f.root,
            &f.pushes,
            &f.source.record_id,
            f.source.revision,
            |_| Ok(None),
        )
        .unwrap();
    assert_eq!(blocked.status, CandidatePlanStatus::Blocked);
    assert!(!s.plans.lock().unwrap().contains_key(&ids[0]));
    let p = s
        .plan(
            "extra",
            &f.root,
            &f.pushes,
            &f.source.record_id,
            f.source.revision,
            |_| Ok(Some(f.source.evidence.expected_sha.clone())),
        )
        .unwrap();
    s.discard("extra", p.plan_id.as_ref().unwrap()).unwrap();
    for b in s.plans.lock().unwrap().values_mut() {
        b.created = Instant::now() - LIFETIME;
    }
    let p = plan(&s, &f);
    assert!(p.plan_id.is_some());
    assert_eq!(s.plans.lock().unwrap().len(), 1);
}

#[test]
fn pending_literal_remote_branch_blocks_another_checkout_without_leaking_its_history() {
    let f = fixture("sha1");
    let s = RollbackTransactionStore::new(f.data.clone());
    let p = plan(&s, &f);
    let row = s
        .execute(
            "session",
            Ok(f.root.clone()),
            &f.pushes,
            p.plan_id.as_ref().unwrap(),
            |r| observe_recorded_push(&f.root, r, None),
            |_, _, _| Err(changed()),
        )
        .unwrap();
    assert!(row.candidate_observed_at_epoch_ms.is_none());
    let second = f.directory.path().join("second-checkout");
    git(
        f.directory.path(),
        &[
            "clone",
            "-b",
            "main",
            &format!("file://{}", f.remote.display()),
            second.to_str().unwrap(),
        ],
    );
    let evidence = capture_review_target(&second, "origin").unwrap();
    let source = f
        .pushes
        .begin(&Uuid::new_v4().to_string(), evidence.clone())
        .unwrap()
        .finish(Some(evidence.expected_sha))
        .unwrap();
    assert_ne!(
        source.evidence.repository_identity,
        f.source.evidence.repository_identity
    );
    assert!(s.list(&second).unwrap().is_empty());
    let blocked = s
        .plan(
            "second-session",
            &second,
            &f.pushes,
            &source.record_id,
            source.revision,
            |_| panic!("other root cannot blindly retry"),
        )
        .unwrap();
    assert_eq!(blocked.status, CandidatePlanStatus::Blocked);
    assert!(blocked.plan_id.is_none());
    assert_eq!(
        git(&f.remote, &["rev-parse", "main"]),
        f.source.evidence.expected_sha
    );
}
