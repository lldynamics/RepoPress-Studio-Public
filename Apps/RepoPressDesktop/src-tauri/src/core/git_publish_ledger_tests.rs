use super::*;
use crate::core::publish_ledger::PublishOutcome;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;
use uuid::Uuid;

static LEDGER_FIXTURE_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn recorded_ordinary_push_persists_exact_remote_sha() {
    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, remote) = ledger_fixture();
    commit_file_for_ledger(repo.path(), "pending.md", "pending\n", "pending");
    let store = GitPublishStore::default();
    let session = Uuid::new_v4().to_string();
    let plan = store.plan_push(&session, repo.path(), "origin").unwrap();
    let data = tempfile::tempdir().unwrap();
    let ledger = PublishLedgerStore::new(data.path().to_path_buf());

    let receipt = store
        .execute_recorded(&plan.plan_id, &session, true, None, &ledger)
        .unwrap();
    let records = ledger.list(repo.path()).unwrap();

    assert_eq!(
        receipt.revision.as_deref(),
        Some(plan.summary.head.as_str())
    );
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].record_id, plan.plan_id);
    assert_eq!(records[0].evidence.operation, PushOperation::Push);
    assert_eq!(records[0].evidence.expected_sha, plan.summary.head);
    assert_eq!(records[0].outcome, PublishOutcome::Verified);
    assert_eq!(
        ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
        records[0].evidence.expected_sha
    );
}

#[test]
fn unavailable_ledger_consumes_ordinary_plan_before_any_remote_write() {
    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, remote) = ledger_fixture();
    commit_file_for_ledger(repo.path(), "pending.md", "pending\n", "pending");
    let before = ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]);
    let store = GitPublishStore::default();
    let session = Uuid::new_v4().to_string();
    let plan = store.plan_push(&session, repo.path(), "origin").unwrap();
    let unavailable = PublishLedgerStore::default();

    assert_eq!(
        store
            .execute_recorded(&plan.plan_id, &session, true, None, &unavailable)
            .unwrap_err()
            .code,
        "publish_ledger_unavailable"
    );
    assert_eq!(
        ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
        before
    );
    assert_eq!(
        store
            .execute_recorded(&plan.plan_id, &session, true, None, &unavailable)
            .unwrap_err()
            .code,
        "git_publish_plan_not_found"
    );
}

#[test]
fn recorded_push_retry_persists_reviewed_evidence() {
    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, remote) = ledger_fixture();
    commit_file_for_ledger(repo.path(), "pending.md", "pending\n", "pending");
    let store = GitPublishStore::default();
    let session = Uuid::new_v4().to_string();
    let plan = store
        .plan_push_retry(&session, repo.path(), "origin", None)
        .unwrap();
    let data = tempfile::tempdir().unwrap();
    let ledger = PublishLedgerStore::new(data.path().to_path_buf());

    let receipt = store
        .execute_push_retry_recorded(&plan.plan_id, &session, None, &ledger)
        .unwrap();
    let record = ledger.list(repo.path()).unwrap().pop().unwrap();

    assert_eq!(receipt.head, plan.head);
    assert_eq!(record.evidence.operation, PushOperation::PushRetry);
    assert_eq!(record.evidence.changed_paths, plan.changed_paths);
    assert_eq!(
        record.evidence.observed_before_sha.as_deref(),
        Some(plan.observed_remote_sha.as_str())
    );
    assert_eq!(record.outcome, PublishOutcome::Verified);
    assert_eq!(
        ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
        receipt.head
    );
}

#[test]
fn reopened_pending_record_observes_only_and_allows_local_drift() {
    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, remote) = ledger_fixture();
    let expected = ledger_git_text(repo.path(), &["rev-parse", "HEAD"]);
    let baseline = network_baseline(repo.path(), "origin", &expected, "main").unwrap();
    let evidence = push_evidence(
        repo.path(),
        "origin",
        &baseline,
        PushOperation::Push,
        Vec::new(),
    );
    let record_id = Uuid::new_v4().to_string();
    let data = tempfile::tempdir().unwrap();
    {
        let ledger = PublishLedgerStore::new(data.path().to_path_buf());
        let pending = ledger.begin(&record_id, evidence).unwrap();
        // Simulate termination after the durable pre-push record, before either
        // the push or the terminal state write. Dropping does not finish it.
        drop(pending);
    }
    commit_file_for_ledger(repo.path(), "later.md", "later\n", "later");
    fs::write(repo.path().join("uncommitted.md"), "dirty\n").unwrap();
    let remote_before = ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]);
    let head_before = ledger_git_text(repo.path(), &["rev-parse", "HEAD"]);
    let index_before = fs::read(repo.path().join(".git/index")).unwrap();

    let ledger = PublishLedgerStore::new(data.path().to_path_buf());
    let pending = ledger.get(repo.path(), &record_id).unwrap();
    assert_eq!(pending.outcome, PublishOutcome::Unconfirmed);
    let verified = ledger
        .verify(&pending, || {
            observe_recorded_push(repo.path(), &pending, None)
        })
        .unwrap();

    assert_eq!(verified.outcome, PublishOutcome::Verified);
    assert_eq!(
        verified.observed_remote_sha.as_deref(),
        Some(expected.as_str())
    );
    assert_eq!(
        ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
        remote_before
    );
    assert_eq!(
        ledger_git_text(repo.path(), &["rev-parse", "HEAD"]),
        head_before
    );
    assert_eq!(
        fs::read(repo.path().join(".git/index")).unwrap(),
        index_before
    );
}

#[test]
fn verification_rejects_changed_destination_without_contacting_either_remote() {
    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, original) = ledger_fixture();
    let expected = ledger_git_text(repo.path(), &["rev-parse", "HEAD"]);
    let baseline = network_baseline(repo.path(), "origin", &expected, "main").unwrap();
    let evidence = push_evidence(
        repo.path(),
        "origin",
        &baseline,
        PushOperation::Push,
        Vec::new(),
    );
    let data = tempfile::tempdir().unwrap();
    let ledger = PublishLedgerStore::new(data.path().to_path_buf());
    let record_id = Uuid::new_v4().to_string();
    let attempt = ledger.begin(&record_id, evidence).unwrap();
    drop(attempt);
    let record = ledger.get(repo.path(), &record_id).unwrap();
    let replacement = bare_remote_for_ledger();
    let original_before = ledger_git_text(original.path(), &["rev-parse", "refs/heads/main"]);
    let replacement_ref = "refs/heads/main".to_string();
    assert!(!ledger_git_status(
        replacement.path(),
        &["show-ref", "--verify", &replacement_ref]
    ));
    ledger_git(
        repo.path(),
        &[
            "remote",
            "set-url",
            "--push",
            "origin",
            &format!("file://{}", replacement.path().display()),
        ],
    );

    assert_eq!(
        observe_recorded_push(repo.path(), &record, None)
            .unwrap_err()
            .code,
        "publish_record_target_changed"
    );
    assert_eq!(
        ledger_git_text(original.path(), &["rev-parse", "refs/heads/main"]),
        original_before
    );
    assert!(!ledger_git_status(
        replacement.path(),
        &["show-ref", "--verify", &replacement_ref]
    ));
}

#[test]
fn verification_rejects_a_replaced_repository_before_remote_observation() {
    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, remote) = ledger_fixture();
    let root = repo.path().to_path_buf();
    let expected = ledger_git_text(&root, &["rev-parse", "HEAD"]);
    let baseline = network_baseline(&root, "origin", &expected, "main").unwrap();
    let evidence = push_evidence(&root, "origin", &baseline, PushOperation::Push, Vec::new());
    let data = tempfile::tempdir().unwrap();
    let ledger = PublishLedgerStore::new(data.path().to_path_buf());
    let record_id = Uuid::new_v4().to_string();
    let attempt = ledger.begin(&record_id, evidence).unwrap();
    drop(attempt);
    let record = ledger.get(&root, &record_id).unwrap();
    let remote_before = ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]);
    let holder = tempfile::tempdir().unwrap();
    let original = holder.path().join("original-repository");
    fs::rename(&root, &original).unwrap();
    ledger_git(
        holder.path(),
        &[
            "clone",
            "-q",
            "-b",
            "main",
            &format!("file://{}", original.display()),
            root.to_str().unwrap(),
        ],
    );
    ledger_git(
        &root,
        &[
            "remote",
            "set-url",
            "--push",
            "origin",
            &format!("file://{}", remote.path().display()),
        ],
    );

    assert_eq!(
        observe_recorded_push(&root, &record, None)
            .unwrap_err()
            .code,
        "publish_record_target_changed"
    );
    assert_eq!(
        ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
        remote_before
    );
}

#[test]
fn different_remote_outcome_is_recorded_without_mutating_git_state() {
    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, remote) = ledger_fixture();
    commit_file_for_ledger(repo.path(), "pending.md", "pending\n", "pending");
    let expected = ledger_git_text(repo.path(), &["rev-parse", "HEAD"]);
    let baseline = network_baseline(repo.path(), "origin", &expected, "main").unwrap();
    let evidence = push_evidence(
        repo.path(),
        "origin",
        &baseline,
        PushOperation::Push,
        Vec::new(),
    );
    let data = tempfile::tempdir().unwrap();
    let ledger = PublishLedgerStore::new(data.path().to_path_buf());
    let record_id = Uuid::new_v4().to_string();
    let attempt = ledger.begin(&record_id, evidence).unwrap();
    drop(attempt);
    let record = ledger.get(repo.path(), &record_id).unwrap();
    let remote_before = ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]);
    let head_before = ledger_git_text(repo.path(), &["rev-parse", "HEAD"]);
    let index_before = fs::read(repo.path().join(".git/index")).unwrap();

    let observed = ledger
        .verify(&record, || {
            observe_recorded_push(repo.path(), &record, None)
        })
        .unwrap();

    assert_eq!(observed.outcome, PublishOutcome::Different);
    assert_eq!(
        observed.observed_remote_sha.as_deref(),
        Some(remote_before.as_str())
    );
    assert_ne!(observed.evidence.expected_sha, remote_before);
    assert_eq!(
        ledger_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
        remote_before
    );
    assert_eq!(
        ledger_git_text(repo.path(), &["rev-parse", "HEAD"]),
        head_before
    );
    assert_eq!(
        fs::read(repo.path().join(".git/index")).unwrap(),
        index_before
    );
}

#[cfg(unix)]
#[test]
fn final_record_write_failure_keeps_the_durable_attempt_unconfirmed() {
    use std::os::unix::fs::PermissionsExt;

    let _lock = LEDGER_FIXTURE_LOCK.lock().unwrap();
    let (repo, _remote) = ledger_fixture();
    let expected = ledger_git_text(repo.path(), &["rev-parse", "HEAD"]);
    let baseline = network_baseline(repo.path(), "origin", &expected, "main").unwrap();
    let evidence = push_evidence(
        repo.path(),
        "origin",
        &baseline,
        PushOperation::Push,
        Vec::new(),
    );
    let record_id = Uuid::new_v4().to_string();
    let data = tempfile::tempdir().unwrap();
    let file = data.path().join("publish-ledger/pushes.sqlite3");
    let ledger = PublishLedgerStore::new(data.path().to_path_buf());
    let attempt = ledger.begin(&record_id, evidence.clone()).unwrap();
    fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();

    assert_eq!(
        attempt.finish(Some(expected)).unwrap_err().code,
        "publish_ledger_unavailable"
    );
    fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
    drop(ledger);

    let reopened = PublishLedgerStore::new(data.path().to_path_buf());
    assert_eq!(
        reopened.get(repo.path(), &record_id).unwrap().outcome,
        PublishOutcome::Unconfirmed
    );
}

fn ledger_fixture() -> (tempfile::TempDir, tempfile::TempDir) {
    let repo = tempfile::tempdir().unwrap();
    ledger_git(repo.path(), &["init", "-q", "-b", "main"]);
    ledger_git(repo.path(), &["config", "user.name", "Ledger tests"]);
    ledger_git(
        repo.path(),
        &["config", "user.email", "ledger@example.invalid"],
    );
    fs::write(repo.path().join("a.md"), "initial\n").unwrap();
    ledger_git(repo.path(), &["add", "a.md"]);
    ledger_git(repo.path(), &["commit", "-q", "-m", "initial"]);
    let remote = bare_remote_for_ledger();
    let remote_url = format!("file://{}", remote.path().display());
    ledger_git(repo.path(), &["remote", "add", "origin", &remote_url]);
    ledger_git(
        repo.path(),
        &["push", "-q", "origin", "main:refs/heads/main"],
    );
    (repo, remote)
}

fn bare_remote_for_ledger() -> tempfile::TempDir {
    let remote = tempfile::tempdir().unwrap();
    ledger_git(remote.path(), &["init", "--bare", "-q"]);
    remote
}

fn commit_file_for_ledger(root: &Path, path: &str, content: &str, message: &str) {
    fs::write(root.join(path), content).unwrap();
    ledger_git(root, &["add", path]);
    ledger_git(root, &["commit", "-q", "-m", message]);
}

fn ledger_git_text(root: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {:?}: {:?}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn ledger_git_status(root: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .unwrap()
        .status
        .success()
}

fn ledger_git(root: &Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {:?}: {:?}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
}
