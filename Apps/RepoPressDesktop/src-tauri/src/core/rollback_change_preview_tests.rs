use super::*;
use crate::core::capture_review_target;
use std::fs;
use std::io::Write;
use std::process::{Command, Stdio};
use uuid::Uuid;

fn git(root: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(output.status.success(), "fixture Git failed: {args:?}");
    String::from_utf8(output.stdout).unwrap().trim().into()
}
fn git_input(root: &Path, args: &[&str], bytes: &[u8]) -> String {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(bytes).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap().trim().into()
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
    fs::write(repo.path().join("changed.md"), "old\n").unwrap();
    fs::write(repo.path().join("removed.md"), "restore secret text\n").unwrap();
    fs::write(repo.path().join("rename-old.md"), "renamed\n").unwrap();
    commit(repo.path());
    git(
        repo.path(),
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/fixture/preview.git",
        ],
    );
    let ledger = PublishLedgerStore::new(data.path().into());
    Fixture {
        repo,
        _data: data,
        ledger,
    }
}
fn record(f: &Fixture, verified: bool) -> PublishRecord {
    let e = capture_review_target(f.repo.path(), "origin").unwrap();
    let id = Uuid::new_v4().to_string();
    let a = f.ledger.begin(&id, e.clone()).unwrap();
    if verified {
        a.finish(Some(e.expected_sha)).unwrap()
    } else {
        drop(a);
        f.ledger.get(f.repo.path(), &id).unwrap()
    }
}
fn preview(f: &Fixture, r: &PublishRecord) -> RollbackChangePreview {
    inspect_rollback_changes(
        "session",
        f.repo.path(),
        &f.ledger,
        &r.record_id,
        r.revision,
    )
    .unwrap()
}
fn mixed_commit(f: &Fixture) {
    fs::write(f.repo.path().join("changed.md"), "new\n").unwrap();
    fs::remove_file(f.repo.path().join("removed.md")).unwrap();
    fs::rename(
        f.repo.path().join("rename-old.md"),
        f.repo.path().join("rename-new.md"),
    )
    .unwrap();
    fs::write(f.repo.path().join("新增.bin"), [0, 1, 255, 2]).unwrap();
    commit(f.repo.path());
}
fn object_path(root: &Path, oid: &str) -> std::path::PathBuf {
    root.join(".git/objects").join(&oid[..2]).join(&oid[2..])
}
fn corrupt_object(root: &Path, oid: &str, kind: &str, bytes: &[u8]) {
    let other = git_input(root, &["hash-object", "-w", "-t", kind, "--stdin"], bytes);
    let target = object_path(root, oid);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
    }
    fs::copy(object_path(root, &other), target).unwrap();
}
fn inspection(root: &Path) -> Inspection<'_> {
    Inspection {
        root,
        sha_width: 20,
        cache: HashMap::new(),
        trees: 0,
        bytes: 0,
        deadline: Instant::now() + INSPECTION_TIME,
        rows: vec![],
        omitted: Some(0),
        warnings: vec![],
    }
}

#[test]
fn inverse_directions_binary_and_rename_split_preserve_all_user_state() {
    let f = fixture("sha1");
    mixed_commit(&f);
    let r = record(&f, true);
    let head = git(f.repo.path(), &["rev-parse", "HEAD"]);
    let index = fs::read(f.repo.path().join(".git/index")).unwrap();
    fs::write(f.repo.path().join("changed.md"), "unsaved external edit\n").unwrap();
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Complete);
    assert_eq!(v.omitted_paths, Some(0));
    assert_eq!(v.changes.len(), 5);
    let rows: HashMap<_, _> = v.changes.iter().map(|r| (r.path.as_str(), r)).collect();
    assert_eq!(rows["changed.md"].action, InverseAction::Replace);
    assert_eq!(rows["removed.md"].action, InverseAction::Restore);
    assert_eq!(rows["rename-old.md"].action, InverseAction::Restore);
    assert_eq!(rows["rename-new.md"].action, InverseAction::Delete);
    assert_eq!(rows["新增.bin"].action, InverseAction::Delete);
    assert!(rows["removed.md"].published.is_none());
    assert!(rows["新增.bin"].restore.is_none());
    assert_eq!(
        rows["新增.bin"].published.as_ref().unwrap().byte_size,
        Some(4)
    );
    assert_eq!(v.summary.verified_files, 5);
    assert_eq!(git(f.repo.path(), &["rev-parse", "HEAD"]), head);
    assert_eq!(fs::read(f.repo.path().join(".git/index")).unwrap(), index);
    assert_eq!(
        fs::read_to_string(f.repo.path().join("changed.md")).unwrap(),
        "unsaved external edit\n"
    );
    assert_eq!(f.ledger.get(f.repo.path(), &r.record_id).unwrap(), r);
    let json = serde_json::to_string(&v).unwrap();
    assert!(!json.contains("restore secret text"));
    assert!(!json.contains("unsaved external edit"));
}

#[test]
fn sha256_and_empty_blobs_use_correct_git_object_headers() {
    let f = fixture("sha256");
    fs::write(f.repo.path().join("empty.md"), []).unwrap();
    commit(f.repo.path());
    let r = record(&f, true);
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Complete);
    assert_eq!(v.identity.expected_sha.len(), 64);
    let side = v.changes[0].published.as_ref().unwrap();
    assert_eq!(side.object_id.len(), 64);
    assert_eq!(side.byte_size, Some(0));
}

#[test]
fn empty_tree_change_is_complete_but_root_merge_unconfirmed_are_blocked() {
    let f = fixture("sha1");
    let root_record = record(&f, true);
    assert_eq!(
        preview(&f, &root_record).blockers,
        vec![RollbackBlocker::RootCommit]
    );
    commit(f.repo.path());
    let r = record(&f, true);
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Complete);
    assert!(v.changes.is_empty());
    assert_eq!(v.omitted_paths, Some(0));
    let r = record(&f, false);
    assert_eq!(
        preview(&f, &r).blockers,
        vec![RollbackBlocker::RecordUnconfirmed]
    );
    git(f.repo.path(), &["checkout", "-b", "side", "HEAD^"]);
    fs::write(f.repo.path().join("side.md"), "side").unwrap();
    commit(f.repo.path());
    git(f.repo.path(), &["checkout", "main"]);
    git(f.repo.path(), &["merge", "--no-ff", "side", "-m", "merge"]);
    let r = record(&f, true);
    assert_eq!(preview(&f, &r).blockers, vec![RollbackBlocker::MergeCommit]);
}

#[test]
fn missing_changed_blob_stays_missing_even_with_promisor_configuration() {
    let f = fixture("sha1");
    mixed_commit(&f);
    let r = record(&f, true);
    let oid = git(f.repo.path(), &["rev-parse", "HEAD^:removed.md"]);
    let path = object_path(f.repo.path(), &oid);
    git(
        f.repo.path(),
        &["config", "extensions.partialClone", "origin"],
    );
    git(f.repo.path(), &["config", "remote.origin.promisor", "true"]);
    fs::remove_file(&path).unwrap();
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Partial);
    let row = v.changes.iter().find(|r| r.path == "removed.md").unwrap();
    assert_eq!(row.verification, ObjectVerification::Unavailable);
    assert_eq!(row.issues, vec![FileIssue::ObjectMissing]);
    assert!(!path.exists());
}

#[test]
fn oversized_blob_and_corrupt_blob_or_root_tree_cannot_be_complete() {
    let f = fixture("sha1");
    fs::write(
        f.repo.path().join("large.bin"),
        vec![1u8; MAX_OBJECT_BYTES + 1],
    )
    .unwrap();
    commit(f.repo.path());
    let r = record(&f, true);
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Partial);
    assert_eq!(v.changes[0].issues, vec![FileIssue::ObjectTooLarge]);
    let f = fixture("sha1");
    fs::write(f.repo.path().join("new.md"), "abcd").unwrap();
    commit(f.repo.path());
    let r = record(&f, true);
    let oid = git(f.repo.path(), &["rev-parse", "HEAD:new.md"]);
    corrupt_object(f.repo.path(), &oid, "blob", b"efgh");
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Partial);
    assert_eq!(v.changes[0].issues, vec![FileIssue::ObjectHashMismatch]);
    let f = fixture("sha1");
    mixed_commit(&f);
    let r = record(&f, true);
    let tree = git(f.repo.path(), &["rev-parse", "HEAD^{tree}"]);
    corrupt_object(f.repo.path(), &tree, "tree", b"");
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Blocked);
    assert_eq!(v.blockers, vec![RollbackBlocker::ObjectsUnavailable]);
    assert!(v.changes.is_empty());
}

#[test]
fn unsafe_unicode_bytes_and_portable_reserved_paths_are_omitted_not_echoed() {
    let f = fixture("sha1");
    for path in ["bad:name.md", "CON.md", "bad?.md", "tail.", "tail "] {
        fs::write(f.repo.path().join(path), "unsafe").unwrap();
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStringExt;
        fs::write(
            f.repo
                .path()
                .join(std::ffi::OsString::from_vec(vec![0xff, b'.', b'm', b'd'])),
            "invalid UTF8",
        )
        .unwrap();
    }
    fs::write(f.repo.path().join("合法 中文.md"), "safe").unwrap();
    commit(f.repo.path());
    let r = record(&f, true);
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Partial);
    assert!(v.warnings.contains(&PreviewWarning::UnsafePathsOmitted));
    assert_eq!(v.changes.len(), 1);
    assert_eq!(v.changes[0].path, "合法 中文.md");
    let json = serde_json::to_string(&v).unwrap();
    assert!(!json.contains("bad:name"));
    assert!(!json.contains("invalid UTF8"));
    assert!(!json.contains("CON.md"));
}

#[test]
fn symlink_gitlink_file_directory_and_mode_changes_have_explicit_types() {
    let f = fixture("sha1");
    fs::remove_file(f.repo.path().join("removed.md")).unwrap();
    fs::create_dir(f.repo.path().join("removed.md")).unwrap();
    fs::write(f.repo.path().join("removed.md/inside.md"), "inside").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::{symlink, PermissionsExt};
        symlink("/outside/never-follow", f.repo.path().join("link")).unwrap();
        fs::set_permissions(
            f.repo.path().join("changed.md"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
    }
    git(f.repo.path(), &["add", "--all"]);
    let base = git(f.repo.path(), &["rev-parse", "HEAD"]);
    git(
        f.repo.path(),
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            "160000",
            &base,
            "submodule",
        ],
    );
    git(f.repo.path(), &["commit", "-m", "types"]);
    let r = record(&f, true);
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Partial);
    assert!(v.warnings.contains(&PreviewWarning::UnsupportedTypes));
    let rows: HashMap<_, _> = v.changes.iter().map(|r| (r.path.as_str(), r)).collect();
    assert_eq!(rows["removed.md"].action, InverseAction::Unsupported);
    assert_eq!(
        rows["removed.md"].published.as_ref().unwrap().mode,
        "040000"
    );
    assert_eq!(
        rows["submodule"].verification,
        ObjectVerification::Unsupported
    );
    #[cfg(unix)]
    {
        assert_eq!(rows["link"].action, InverseAction::Unsupported);
        assert_eq!(rows["changed.md"].action, InverseAction::Replace);
        assert_eq!(
            rows["changed.md"].published.as_ref().unwrap().mode,
            "100755"
        );
        assert_eq!(
            rows["changed.md"].verification,
            ObjectVerification::Verified
        );
    }
    assert!(!serde_json::to_string(&v)
        .unwrap()
        .contains("/outside/never-follow"));
}

#[test]
fn exactly_two_hundred_rows_are_complete_but_extra_rows_report_unknown_omissions() {
    for count in [200, 201] {
        let f = fixture("sha1");
        for n in 0..count {
            fs::write(f.repo.path().join(format!("new-{n:03}.md")), "same").unwrap();
        }
        commit(f.repo.path());
        let r = record(&f, true);
        let v = preview(&f, &r);
        assert_eq!(v.changes.len(), 200);
        if count == 200 {
            assert_eq!(v.status, PreviewStatus::Complete);
            assert_eq!(v.omitted_paths, Some(0));
        } else {
            assert_eq!(v.status, PreviewStatus::Partial);
            assert_eq!(v.omitted_paths, None);
            assert!(v.warnings.contains(&PreviewWarning::EntryLimit));
        }
    }
}

#[test]
fn depth_tree_time_and_byte_budgets_never_present_complete_empty_success() {
    let f = fixture("sha1");
    let nested = f.repo.path().join(
        (0..MAX_DEPTH + 2)
            .map(|_| "d")
            .collect::<Vec<_>>()
            .join("/"),
    );
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("deep.md"), "deep").unwrap();
    commit(f.repo.path());
    let r = record(&f, true);
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Partial);
    assert_eq!(v.omitted_paths, None);
    assert!(v.warnings.contains(&PreviewWarning::TreeLimit));
    let tree = git(f.repo.path(), &["rev-parse", "HEAD^{tree}"]);
    for mode in ["trees", "time", "bytes"] {
        let mut i = inspection(f.repo.path());
        match mode {
            "trees" => i.trees = MAX_TREES,
            "time" => i.deadline = Instant::now(),
            _ => i.bytes = MAX_TOTAL_BYTES,
        };
        i.walk("", Some(&tree), None, 0);
        assert_eq!(i.omitted, None);
        assert!(!i.warnings.is_empty());
    }
    let f = fixture("sha1");
    for n in 0..70 {
        let mut bytes = vec![b'x'; MAX_OBJECT_BYTES];
        bytes[..4].copy_from_slice(&(n as u32).to_be_bytes());
        fs::write(f.repo.path().join(format!("large-{n}.bin")), bytes).unwrap();
    }
    commit(f.repo.path());
    let r = record(&f, true);
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Partial);
    assert!(v.warnings.contains(&PreviewWarning::ByteLimit));
    assert!(v
        .changes
        .iter()
        .any(|r| r.issues.contains(&FileIssue::BudgetLimit)));
}

#[test]
fn strict_raw_tree_parser_rejects_duplicate_truncated_and_unknown_mode_data() {
    for width in [20, 32] {
        let mut one = b"100644 a.md\0".to_vec();
        one.extend(vec![0x12; width]);
        assert_eq!(parse_tree(&one, width).unwrap().len(), 1);
        let mut dup = one.clone();
        dup.extend(&one);
        assert!(parse_tree(&dup, width).is_err());
        assert!(parse_tree(&one[..one.len() - 1], width).is_err());
        assert!(parse_tree(b"unknown a\0", width).is_err());
    }
}

#[test]
fn final_revalidation_rejects_destination_drift_recovery_and_record_revision_change() {
    let f = fixture("sha1");
    mixed_commit(&f);
    let r = record(&f, true);
    let before = local_conditions(f.repo.path(), &r);
    let _ = preview_record("session", f.repo.path(), &r, before.clone()).unwrap();
    git(
        f.repo.path(),
        &[
            "remote",
            "set-url",
            "origin",
            "https://github.com/changed/preview.git",
        ],
    );
    assert!(validate_final_preview(f.repo.path(), &f.ledger, &r, &before).is_err());
    let blocked = local_conditions(f.repo.path(), &r);
    assert_eq!(blocked.1, vec![RollbackBlocker::TargetChanged]);
    let _ = preview_record("session", f.repo.path(), &r, blocked.clone()).unwrap();
    git(
        f.repo.path(),
        &[
            "remote",
            "set-url",
            "origin",
            "https://github.com/fixture/preview.git",
        ],
    );
    assert!(validate_final_preview(f.repo.path(), &f.ledger, &r, &blocked).is_err());
    f.ledger
        .verify(&r, || Ok(Some(r.evidence.expected_sha.clone())))
        .unwrap();
    assert!(validate_final_preview(f.repo.path(), &f.ledger, &r, &before).is_err());
    assert!(inspect_rollback_changes(
        "session",
        f.repo.path(),
        &f.ledger,
        &r.record_id,
        r.revision
    )
    .is_err());
}

#[test]
fn replaced_and_missing_root_objects_are_blocked_without_remote_queries() {
    let f = fixture("sha1");
    mixed_commit(&f);
    let r = record(&f, true);
    let parent = git(f.repo.path(), &["rev-parse", "HEAD^"]);
    git(
        f.repo.path(),
        &["replace", &r.evidence.expected_sha, &parent],
    );
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Blocked);
    assert!(v.changes.is_empty());
    let f = fixture("sha1");
    mixed_commit(&f);
    let r = record(&f, true);
    let oid = git(f.repo.path(), &["rev-parse", "HEAD^{tree}"]);
    fs::remove_file(object_path(f.repo.path(), &oid)).unwrap();
    let v = preview(&f, &r);
    assert_eq!(v.status, PreviewStatus::Blocked);
    assert!(v.changes.is_empty());
}
