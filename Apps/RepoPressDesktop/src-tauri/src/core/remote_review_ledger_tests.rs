use super::*;
use std::fs;
use std::path::{Path, PathBuf};

fn store() -> (tempfile::TempDir, RemoteReviewLedgerStore, PathBuf) {
    let directory = tempfile::tempdir().unwrap();
    let root = PathBuf::from("/tmp/repository");
    let ledger = RemoteReviewLedgerStore::new(directory.path().to_path_buf());
    (directory, ledger, root)
}

fn id(number: usize) -> String {
    format!("00000000-0000-4000-8000-{number:012x}")
}

fn evidence(number: usize) -> RemoteReviewEvidence {
    RemoteReviewEvidence {
        repository_path: "/tmp/repository".into(),
        repository_identity: "a".repeat(64),
        remote: "origin".into(),
        remote_url: "https://github.com/example/repository.git".into(),
        provider: RemoteProvider::Github,
        owner: "example".into(),
        project: "repository".into(),
        remote_project_id: 42,
        source_branch: format!("feature-{number}"),
        target_branch: "main".into(),
        source_sha: "0123456789abcdef0123456789abcdef01234567".into(),
        title_sha256: "b".repeat(64),
        body_sha256: "c".repeat(64),
        marker: id(number),
    }
}

fn receipt(number: u64) -> RemotePublishReceipt {
    RemotePublishReceipt {
        provider: RemoteProvider::Github,
        review_number: number,
        web_url: format!("https://github.com/example/repository/pull/{number}"),
    }
}

#[test]
fn begin_persists_unknown_and_reload_retains_it() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(evidence(1)).unwrap();
    assert_eq!(attempt.record.outcome, ReviewOutcome::Unconfirmed);
    assert_eq!(attempt.record.verification, ReviewVerification::NotChecked);
    drop(attempt);
    drop(ledger);
    let reloaded = RemoteReviewLedgerStore::new(directory.path().to_path_buf());
    let records = reloaded.list(&root).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].record_id, id(1));
}

#[test]
fn active_acquire_and_remove_are_blocked() {
    let (_directory, ledger, root) = store();
    let attempt = ledger.begin(evidence(2)).unwrap();
    let expected = attempt.record.clone();
    match ledger.acquire(&expected) {
        Ok(_) => panic!("active record was acquired twice"),
        Err(error) => assert_eq!(error.code, "remote_review_record_busy"),
    }
    assert_eq!(
        ledger
            .remove(&root, &expected.record_id, expected.revision)
            .unwrap_err()
            .code,
        "remote_review_record_changed"
    );
    drop(attempt);
    assert_eq!(
        ledger
            .remove(&root, &expected.record_id, expected.revision)
            .unwrap_err()
            .code,
        "remote_review_record_changed"
    );
}

#[test]
fn matched_requires_valid_receipt_and_unknown_cannot_be_deleted() {
    let (_directory, ledger, root) = store();
    let attempt = ledger.begin(evidence(3)).unwrap();
    let expected = attempt.record.clone();
    assert!(attempt.finish(ReviewVerification::Matched, None).is_err());
    let attempt = ledger.acquire(&expected).unwrap();
    let unknown = attempt.finish(ReviewVerification::NoMatch, None).unwrap();
    assert_eq!(unknown.outcome, ReviewOutcome::Unconfirmed);
    assert_eq!(
        ledger
            .remove(&root, &unknown.record_id, unknown.revision)
            .unwrap_err()
            .code,
        "remote_review_record_changed"
    );
}

#[test]
fn root_and_revision_drift_are_rejected() {
    let (_directory, ledger, root) = store();
    let attempt = ledger.begin(evidence(4)).unwrap();
    drop(attempt);
    let record = ledger.get(&root, &id(4)).unwrap();
    assert_eq!(
        ledger
            .get(Path::new("/tmp/other-repository"), &id(4))
            .unwrap_err()
            .code,
        "remote_review_record_changed"
    );
    assert_eq!(
        ledger
            .remove(&root, &id(4), record.revision + 1)
            .unwrap_err()
            .code,
        "remote_review_record_changed"
    );
}

#[test]
fn matched_delete_is_durable() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(evidence(5)).unwrap();
    let expected = attempt.record.clone();
    let verified = attempt
        .finish(ReviewVerification::Matched, Some(receipt(5)))
        .unwrap();
    assert_eq!(verified.outcome, ReviewOutcome::Verified);
    assert!(ledger
        .remove(&root, &expected.record_id, verified.revision)
        .unwrap()
        .is_empty());
    drop(ledger);
    assert!(RemoteReviewLedgerStore::new(directory.path().to_path_buf())
        .list(&root)
        .unwrap()
        .is_empty());
}

#[test]
fn two_hundred_records_are_not_evicted() {
    let (_directory, ledger, root) = store();
    for number in 10..210 {
        drop(ledger.begin(evidence(number)).unwrap());
    }
    assert_eq!(ledger.list(&root).unwrap().len(), 200);
    assert!(ledger.begin(evidence(999)).is_err());
    assert!(ledger
        .list(&root)
        .unwrap()
        .iter()
        .any(|record| record.record_id == id(10)));
    assert!(ledger
        .list(&root)
        .unwrap()
        .iter()
        .any(|record| record.record_id == id(209)));
}

#[test]
fn persisted_records_contain_hashes_but_no_request_content_or_credentials() {
    let (directory, ledger, _root) = store();
    drop(ledger.begin(evidence(19)).unwrap());
    let connection = rusqlite::Connection::open(
        directory
            .path()
            .join("remote-review-ledger/records.sqlite3"),
    )
    .unwrap();
    let payload: String = connection
        .query_row("SELECT payload FROM pushes LIMIT 1", [], |row| row.get(0))
        .unwrap();
    assert!(payload.contains("titleSha256"));
    assert!(payload.contains("bodySha256"));
    assert!(!payload.contains("request prose"));
    assert!(!payload.contains("token"));
    assert!(!payload.contains("password"));
}

#[cfg(unix)]
#[test]
fn schema_replacement_and_permissions_fail_closed() {
    use std::os::unix::fs::{symlink, PermissionsExt};

    let (directory, ledger, root) = store();
    drop(ledger.begin(evidence(20)).unwrap());
    let database = directory
        .path()
        .join("remote-review-ledger/records.sqlite3");
    fs::write(&database, b"not sqlite").unwrap();
    assert!(ledger.list(&root).is_err());

    let (_directory, ledger, root) = store();
    drop(ledger.begin(evidence(21)).unwrap());
    let storage_dir = _directory.path().join("remote-review-ledger");
    let moved = _directory.path().join("remote-review-ledger-real");
    fs::rename(&storage_dir, &moved).unwrap();
    symlink(&moved, &storage_dir).unwrap();
    assert!(ledger.list(&root).is_err());

    let (_directory, ledger, root) = store();
    drop(ledger.begin(evidence(22)).unwrap());
    let database = _directory
        .path()
        .join("remote-review-ledger/records.sqlite3");
    fs::set_permissions(&database, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(ledger.list(&root).is_err());
}

#[test]
fn second_instance_is_rejected_while_first_holds_lock() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(evidence(23)).unwrap();
    let inherited_lock = ledger
        .storage
        .lock()
        .unwrap()
        .as_ref()
        .unwrap()
        ._process_lock
        .0
        .try_clone()
        .unwrap();
    let second = RemoteReviewLedgerStore::new(directory.path().to_path_buf());
    assert_eq!(
        second.list(&root).unwrap_err().code,
        "publish_ledger_unavailable"
    );
    drop(attempt);
    drop(ledger);
    assert_eq!(
        RemoteReviewLedgerStore::new(directory.path().to_path_buf())
            .list(&root)
            .unwrap()
            .len(),
        1
    );
    drop(inherited_lock);
}

#[test]
fn failed_finish_leaves_pending_unknown_record() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(evidence(24)).unwrap();
    let database = directory
        .path()
        .join("remote-review-ledger/records.sqlite3");
    let backup = directory.path().join("records-copy.sqlite3");
    fs::copy(&database, &backup).unwrap();
    fs::remove_file(&database).unwrap();
    fs::copy(&backup, &database).unwrap();
    assert!(attempt
        .finish(ReviewVerification::Matched, Some(receipt(24)))
        .is_err());
    drop(ledger);
    let reloaded = RemoteReviewLedgerStore::new(directory.path().to_path_buf());
    let records = reloaded.list(&root).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].verification, ReviewVerification::NotChecked);
}
