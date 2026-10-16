use super::*;
use crate::core::capture_review_target;
use std::cell::RefCell;
use std::fs;
use std::io::Write;
use std::process::{Command, Stdio};

fn git(root: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "fixture Git failed {args:?}");
    String::from_utf8(out.stdout).unwrap().trim().into()
}
fn raw_object(root: &Path, kind: &str, bytes: &[u8]) -> String {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["hash-object", "-w", "-t", kind, "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(bytes).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout).unwrap().trim().into()
}
fn commit(root: &Path) {
    git(root, &["add", "--all"]);
    git(root, &["commit", "--allow-empty", "-m", "fixture"]);
}
struct Fixture {
    repo: tempfile::TempDir,
    _data: tempfile::TempDir,
    ledger: PublishLedgerStore,
}
fn fixture(format: &str) -> Fixture {
    let repo = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    git(
        repo.path(),
        &["init", "-b", "main", &format!("--object-format={format}")],
    );
    git(repo.path(), &["config", "user.name", "Fixture"]);
    git(
        repo.path(),
        &["config", "user.email", "fixture@example.test"],
    );
    git(
        repo.path(),
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/fixture/preview.git",
        ],
    );
    fs::write(repo.path().join("changed.md"), "old\n").unwrap();
    fs::write(repo.path().join("unchanged.md"), "private unchanged body\n").unwrap();
    commit(repo.path());
    let ledger = PublishLedgerStore::new(data.path().into());
    Fixture {
        repo,
        _data: data,
        ledger,
    }
}
fn record(f: &Fixture) -> PublishRecord {
    let e = capture_review_target(f.repo.path(), "origin").unwrap();
    f.ledger
        .begin(&Uuid::new_v4().to_string(), e.clone())
        .unwrap()
        .finish(Some(e.expected_sha))
        .unwrap()
}
fn change(f: &Fixture) -> PublishRecord {
    fs::write(f.repo.path().join("changed.md"), "new\n").unwrap();
    commit(f.repo.path());
    record(f)
}
fn plan(store: &RollbackCandidateStore, f: &Fixture, r: &PublishRecord) -> RollbackCandidatePlan {
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
fn root(f: &Fixture) -> CommandResult<PathBuf> {
    Ok(f.repo.path().into())
}
fn loose(root: &Path, oid: &str) -> PathBuf {
    root.join(".git/objects").join(&oid[..2]).join(&oid[2..])
}

#[test]
fn candidate_is_exact_parent_tree_with_frozen_parent_and_private_cleaned_objects() {
    let f = fixture("sha1");
    let r = change(&f);
    let store = RollbackCandidateStore::default();
    // Subsequent HEAD and staged/dirty content are not rollback inputs.
    fs::write(f.repo.path().join("later.md"), "later").unwrap();
    commit(f.repo.path());
    fs::write(f.repo.path().join("changed.md"), "unsaved external content").unwrap();
    git(f.repo.path(), &["add", "changed.md"]);
    let head = git(f.repo.path(), &["rev-parse", "HEAD"]);
    let index = fs::read(f.repo.path().join(".git/index")).unwrap();
    let p = plan(&store, &f, &r);
    assert_eq!(p.status, CandidatePlanStatus::Ready);
    assert_eq!(p.target_files, 2);
    let seen = RefCell::new(None);
    let found = RefCell::new(None);
    let report = store
        .generate_with(
            "session",
            root(&f),
            &f.ledger,
            p.plan_id.as_ref().unwrap(),
            |dir| {
                *seen.borrow_mut() = Some(dir.to_path_buf());
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    assert_eq!(
                        fs::metadata(dir).unwrap().permissions().mode() & 0o777,
                        0o700
                    );
                }
                assert!(!dir.join("objects/info/alternates").exists());
                assert!(!dir.join("index").exists());
                assert!(fs::read_dir(dir.join("refs/heads"))
                    .unwrap()
                    .next()
                    .is_none());
                for prefix in fs::read_dir(dir.join("objects"))
                    .unwrap()
                    .flatten()
                    .filter(|e| e.file_name().len() == 2)
                {
                    for suffix in fs::read_dir(prefix.path()).unwrap().flatten() {
                        let oid = format!(
                            "{}{}",
                            prefix.file_name().to_str().unwrap(),
                            suffix.file_name().to_str().unwrap()
                        );
                        if git(dir, &["cat-file", "-t", &oid]) == "commit" {
                            let body = git(dir, &["cat-file", "-p", &oid]);
                            if body.contains(&format!("parent {}\n", r.evidence.expected_sha)) {
                                *found.borrow_mut() = Some((oid, body));
                            }
                        }
                    }
                }
                Ok(())
            },
        )
        .unwrap();
    let (oid, body) = found.into_inner().unwrap();
    assert_eq!(report.candidate_sha, oid);
    assert!(body.starts_with(&format!(
        "tree {}\nparent {}\n",
        p.target_tree_sha.unwrap(),
        r.evidence.expected_sha
    )));
    assert!(body.contains("Review-only inverse"));
    assert!(!seen.into_inner().unwrap().exists());
    assert!(report.temporary_objects_removed);
    assert_eq!(git(f.repo.path(), &["rev-parse", "HEAD"]), head);
    assert_eq!(fs::read(f.repo.path().join(".git/index")).unwrap(), index);
    assert_eq!(
        fs::read_to_string(f.repo.path().join("changed.md")).unwrap(),
        "unsaved external content"
    );
    assert_eq!(f.ledger.get(f.repo.path(), &r.record_id).unwrap(), r);
    let json = serde_json::to_string(&report).unwrap();
    assert!(!json.contains("private unchanged body"));
    assert!(!json.contains("unsaved external content"));
    assert!(store
        .generate("session", root(&f), &f.ledger, p.plan_id.as_ref().unwrap())
        .is_err());
}
#[test]
fn sha256_empty_target_and_binary_objects_generate_without_hydration() {
    let f = fixture("sha256");
    let r = change(&f);
    let store = RollbackCandidateStore::default();
    let p = plan(&store, &f, &r);
    assert_eq!(
        store
            .generate("session", root(&f), &f.ledger, p.plan_id.as_ref().unwrap())
            .unwrap()
            .candidate_sha
            .len(),
        64
    );
    let f = fixture("sha1");
    fs::remove_file(f.repo.path().join("changed.md")).unwrap();
    fs::remove_file(f.repo.path().join("unchanged.md")).unwrap();
    commit(f.repo.path());
    fs::write(f.repo.path().join("binary.bin"), [0, 255, 1]).unwrap();
    let r = {
        commit(f.repo.path());
        record(&f)
    };
    let p = plan(&store, &f, &r);
    assert_eq!(p.target_files, 0);
    assert!(store
        .generate("session", root(&f), &f.ledger, p.plan_id.as_ref().unwrap())
        .is_ok());
}
#[test]
fn unchanged_missing_or_corrupt_blob_blocks_full_target_snapshot() {
    for corrupt in [false, true] {
        let f = fixture("sha1");
        let r = change(&f);
        let oid = git(f.repo.path(), &["rev-parse", "HEAD:unchanged.md"]);
        if corrupt {
            let replacement = raw_object(f.repo.path(), "blob", b"incorrect");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(
                    loose(f.repo.path(), &oid),
                    fs::Permissions::from_mode(0o600),
                )
                .unwrap();
            }
            fs::copy(
                loose(f.repo.path(), &replacement),
                loose(f.repo.path(), &oid),
            )
            .unwrap();
        } else {
            fs::remove_file(loose(f.repo.path(), &oid)).unwrap();
        }
        git(f.repo.path(), &["config", "remote.origin.promisor", "true"]);
        let p = plan(&RollbackCandidateStore::default(), &f, &r);
        assert_eq!(p.status, CandidatePlanStatus::Blocked);
        assert!(p.plan_id.is_none());
        assert_eq!(p.target_files, 0);
        assert_eq!(
            p.blockers,
            vec![CandidateBlocker::Snapshot(
                SnapshotProblem::ObjectsUnavailable
            )]
        );
        if !corrupt {
            assert!(!loose(f.repo.path(), &oid).exists());
        }
    }
}
#[test]
fn unchanged_special_types_and_unsafe_paths_are_not_accepted() {
    #[cfg(unix)]
    {
        let f = fixture("sha1");
        std::os::unix::fs::symlink("/outside/secret", f.repo.path().join("link")).unwrap();
        commit(f.repo.path());
        let r = change(&f);
        let p = plan(&RollbackCandidateStore::default(), &f, &r);
        assert_eq!(
            p.blockers,
            vec![CandidateBlocker::Snapshot(
                SnapshotProblem::TargetSnapshotUnsupported
            )]
        );
    }
    for name in ["CON.txt", "question?.md"] {
        let f = fixture("sha1");
        fs::write(f.repo.path().join(name), "private").unwrap();
        commit(f.repo.path());
        let r = change(&f);
        let p = plan(&RollbackCandidateStore::default(), &f, &r);
        assert_eq!(
            p.blockers,
            vec![CandidateBlocker::Snapshot(
                SnapshotProblem::TargetSnapshotUnsafe
            )]
        );
        assert!(!serde_json::to_string(&p).unwrap().contains(name));
    }
}
#[test]
fn snapshot_count_byte_and_depth_limits_fail_closed() {
    let f = fixture("sha1");
    for n in 0..198 {
        fs::write(f.repo.path().join(format!("f{n}")), "same").unwrap();
    }
    commit(f.repo.path());
    let r = change(&f);
    let p = plan(&RollbackCandidateStore::default(), &f, &r);
    assert_eq!(p.status, CandidatePlanStatus::Ready);
    assert_eq!(p.target_files, 200);
    let f = fixture("sha1");
    for n in 0..199 {
        fs::write(f.repo.path().join(format!("f{n}")), "same").unwrap();
    }
    commit(f.repo.path());
    let r = change(&f);
    assert_eq!(
        plan(&RollbackCandidateStore::default(), &f, &r).blockers,
        vec![CandidateBlocker::Snapshot(SnapshotProblem::SnapshotLimit)]
    );
    let f = fixture("sha1");
    for n in 0..70 {
        fs::write(
            f.repo.path().join(format!("f{n}")),
            vec![n as u8; 64 * 1024],
        )
        .unwrap();
    }
    commit(f.repo.path());
    let r = change(&f);
    assert_eq!(
        plan(&RollbackCandidateStore::default(), &f, &r).blockers,
        vec![CandidateBlocker::Snapshot(SnapshotProblem::SnapshotLimit)]
    );
    let f = fixture("sha1");
    let path = (0..34).fold(f.repo.path().to_path_buf(), |p, _| p.join("a"));
    fs::create_dir_all(&path).unwrap();
    fs::write(path.join("deep"), "unchanged").unwrap();
    commit(f.repo.path());
    let r = change(&f);
    assert_eq!(
        plan(&RollbackCandidateStore::default(), &f, &r).blockers,
        vec![CandidateBlocker::Snapshot(SnapshotProblem::SnapshotLimit)]
    );
}
#[test]
fn partial_preview_and_no_change_are_blocked_not_empty_ready() {
    let f = fixture("sha1");
    commit(f.repo.path());
    let r = record(&f);
    let store = RollbackCandidateStore::default();
    assert_eq!(
        plan(&store, &f, &r).blockers,
        vec![CandidateBlocker::Snapshot(SnapshotProblem::NoChanges)]
    );
    fs::write(f.repo.path().join("big"), vec![3u8; 65537]).unwrap();
    commit(f.repo.path());
    let r = record(&f);
    assert_eq!(
        plan(&store, &f, &r).blockers,
        vec![CandidateBlocker::Snapshot(
            SnapshotProblem::PreviewIncomplete
        )]
    );
}

#[test]
fn empty_subtree_only_difference_is_no_changes_not_ready() {
    let f = fixture("sha1");
    let parent = git(f.repo.path(), &["rev-parse", "HEAD"]);
    let target = git(f.repo.path(), &["rev-parse", "HEAD^{tree}"]);
    let empty = raw_object(f.repo.path(), "tree", b"");
    let listing = format!(
        "040000 tree {empty}\tempty\n{}",
        git(f.repo.path(), &["ls-tree", &target])
    );
    let mut child = Command::new("git")
        .arg("-C")
        .arg(f.repo.path())
        .arg("mktree")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(listing.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let tree = String::from_utf8(output.stdout).unwrap().trim().to_string();
    let bytes = format!("tree {tree}\nparent {parent}\nauthor Fixture <fixture@example.test> 1700000000 +0000\ncommitter Fixture <fixture@example.test> 1700000000 +0000\n\nempty subtree\n");
    let source = raw_object(f.repo.path(), "commit", bytes.as_bytes());
    git(f.repo.path(), &["update-ref", "refs/heads/main", &source]);
    let r = record(&f);
    let p = plan(&RollbackCandidateStore::default(), &f, &r);
    assert_eq!(
        p.blockers,
        vec![CandidateBlocker::Snapshot(SnapshotProblem::NoChanges)]
    );
    assert!(p.plan_id.is_none());
}
#[test]
fn wrong_session_root_expiry_and_missing_root_consume_plans() {
    let f = fixture("sha1");
    let r = change(&f);
    let store = RollbackCandidateStore::default();
    for mode in 0..4 {
        let p = plan(&store, &f, &r);
        let id = p.plan_id.unwrap();
        if mode == 2 {
            store.plans.lock().unwrap().get_mut(&id).unwrap().created -= LIFETIME;
        }
        let target = if mode == 1 {
            Ok(PathBuf::from("/does/not/exist"))
        } else if mode == 3 {
            Err(unavailable())
        } else {
            root(&f)
        };
        assert!(store
            .generate(
                if mode == 0 { "other" } else { "session" },
                target,
                &f.ledger,
                &id
            )
            .is_err());
        assert!(store.generate("session", root(&f), &f.ledger, &id).is_err());
    }
}
#[test]
fn discard_dedup_blocked_replan_and_capacity_release_memory() {
    let f = fixture("sha1");
    let r = change(&f);
    let store = RollbackCandidateStore::default();
    let first = plan(&store, &f, &r);
    let second = plan(&store, &f, &r);
    assert_eq!(store.plans.lock().unwrap().len(), 1);
    assert!(store
        .generate(
            "session",
            root(&f),
            &f.ledger,
            first.plan_id.as_ref().unwrap()
        )
        .is_err());
    assert!(store
        .discard("other", second.plan_id.as_ref().unwrap())
        .is_err());
    assert_eq!(store.plans.lock().unwrap().len(), 1);
    store
        .discard("session", second.plan_id.as_ref().unwrap())
        .unwrap();
    store
        .discard("session", second.plan_id.as_ref().unwrap())
        .unwrap();
    for _ in 0..MAX_PLANS {
        let r = record(&f);
        plan(&store, &f, &r);
    }
    let r = record(&f);
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
        b.created -= LIFETIME;
    }
    assert_eq!(plan(&store, &f, &r).status, CandidatePlanStatus::Ready);
    let oid = git(f.repo.path(), &["rev-parse", "HEAD:unchanged.md"]);
    fs::remove_file(loose(f.repo.path(), &oid)).unwrap();
    assert_eq!(plan(&store, &f, &r).status, CandidatePlanStatus::Blocked);
    assert!(store.plans.lock().unwrap().is_empty());
}
#[test]
fn object_record_and_destination_drift_reject_before_writes_and_after_readback() {
    let f = fixture("sha1");
    let r = change(&f);
    let store = RollbackCandidateStore::default();
    let p = plan(&store, &f, &r);
    let oid = git(f.repo.path(), &["rev-parse", "HEAD:unchanged.md"]);
    fs::remove_file(loose(f.repo.path(), &oid)).unwrap();
    assert!(store
        .generate_with(
            "session",
            root(&f),
            &f.ledger,
            p.plan_id.as_ref().unwrap(),
            |_| panic!("must not construct stale snapshot")
        )
        .is_err());
    let f = fixture("sha1");
    let r = change(&f);
    let p = plan(&store, &f, &r);
    let seen = RefCell::new(None);
    assert!(store
        .generate_with(
            "session",
            root(&f),
            &f.ledger,
            p.plan_id.as_ref().unwrap(),
            |dir| {
                *seen.borrow_mut() = Some(dir.to_path_buf());
                git(
                    f.repo.path(),
                    &[
                        "remote",
                        "set-url",
                        "origin",
                        "https://github.com/fixture/other.git",
                    ],
                );
                Ok(())
            }
        )
        .is_err());
    assert!(!seen.into_inner().unwrap().exists());
    let f = fixture("sha1");
    let r = change(&f);
    let p = plan(&store, &f, &r);
    f.ledger
        .verify(&r, || Ok(Some(r.evidence.expected_sha.clone())))
        .unwrap();
    assert!(store
        .generate("session", root(&f), &f.ledger, p.plan_id.as_ref().unwrap())
        .is_err());
}
#[test]
fn isolated_readback_corruption_or_callback_failure_never_report_success_and_cleanup() {
    for corrupt in [true, false] {
        let f = fixture("sha1");
        let r = change(&f);
        let store = RollbackCandidateStore::default();
        let p = plan(&store, &f, &r);
        let seen = RefCell::new(None);
        assert!(store
            .generate_with(
                "session",
                root(&f),
                &f.ledger,
                p.plan_id.as_ref().unwrap(),
                |dir| {
                    *seen.borrow_mut() = Some(dir.to_path_buf());
                    if !corrupt {
                        return Err(unavailable());
                    }
                    let oid = git(f.repo.path(), &["rev-parse", "HEAD:unchanged.md"]);
                    fs::remove_file(dir.join("objects").join(&oid[..2]).join(&oid[2..])).unwrap();
                    Ok(())
                }
            )
            .is_err());
        assert!(!seen.into_inner().unwrap().exists());
        assert!(store.plans.lock().unwrap().is_empty());
    }
}
