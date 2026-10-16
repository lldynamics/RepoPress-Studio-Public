use super::*;
use std::fs;
use std::path::PathBuf;

fn store() -> (tempfile::TempDir, PublishLedgerStore, PathBuf) {
    let directory = tempfile::tempdir().unwrap();
    let root = PathBuf::from("/tmp/repository");
    let ledger = PublishLedgerStore::new(directory.path().to_path_buf());
    (directory, ledger, root)
}

fn evidence() -> PublishEvidence {
    PublishEvidence {
        repository_path: "/tmp/repository".into(),
        repository_identity: "a".repeat(64),
        operation: PushOperation::Push,
        remote: "origin".into(),
        remote_url: "https://github.com/example/repository.git".into(),
        branch: "main".into(),
        expected_sha: "0123456789abcdef0123456789abcdef01234567".into(),
        observed_before_sha: None,
        changed_paths: Vec::new(),
    }
}

fn id(number: usize) -> String {
    format!("00000000-0000-4000-8000-{number:012x}")
}

fn expect_error<T>(result: CommandResult<T>) -> CommandError {
    match result {
        Ok(_) => panic!("expected command to fail"),
        Err(error) => error,
    }
}

#[test]
fn begin_persists_unconfirmed_and_reload_retains_it() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(&id(1), evidence()).unwrap();
    assert_eq!(attempt.record.outcome, PublishOutcome::Unconfirmed);
    drop(attempt);
    assert_eq!(
        ledger.list(&root).unwrap()[0].outcome,
        PublishOutcome::Unconfirmed
    );
    drop(ledger);
    let reloaded = PublishLedgerStore::new(directory.path().to_path_buf());
    let records = reloaded.list(&root).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].record_id, id(1));
    assert_eq!(records[0].outcome, PublishOutcome::Unconfirmed);
}

#[test]
fn another_instance_cannot_mutate_records_until_owner_exits() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(&id(22), evidence()).unwrap();
    // A forked child briefly inherits the same open file description until
    // exec. A cloned descriptor reproduces that lock-lifetime condition.
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
    let second = PublishLedgerStore::new(directory.path().to_path_buf());
    assert_eq!(
        second.list(&root).unwrap_err().code,
        "publish_ledger_unavailable"
    );
    assert_eq!(
        expect_error(second.begin(&id(23), evidence())).code,
        "publish_ledger_unavailable"
    );
    drop(attempt);
    drop(ledger);
    let restarted = PublishLedgerStore::new(directory.path().to_path_buf());
    let record = restarted.get(&root, &id(22)).unwrap();
    assert_eq!(record.outcome, PublishOutcome::Unconfirmed);
    assert_eq!(
        restarted
            .verify(&record, || Ok(Some(record.evidence.expected_sha.clone())))
            .unwrap()
            .outcome,
        PublishOutcome::Verified
    );
    drop(inherited_lock);
}

#[test]
fn finish_maps_exact_different_and_unknown_observations() {
    for (number, observed, expected) in [
        (
            2,
            Some("0123456789abcdef0123456789abcdef01234567".to_string()),
            PublishOutcome::Verified,
        ),
        (
            3,
            Some("fedcba9876543210fedcba9876543210fedcba98".to_string()),
            PublishOutcome::Different,
        ),
        (4, None, PublishOutcome::Unconfirmed),
    ] {
        let (_directory, ledger, _root) = store();
        let attempt = ledger.begin(&id(number), evidence()).unwrap();
        let result = attempt.finish(observed).unwrap();
        assert_eq!(result.outcome, expected);
        assert_eq!(result.revision, 2);
    }
}

#[test]
fn replay_and_stale_revision_are_rejected_without_observing_again() {
    let (_directory, ledger, root) = store();
    let attempt = ledger.begin(&id(5), evidence()).unwrap();
    let expected = attempt.record.clone();
    drop(attempt);
    let verified = ledger
        .verify(&expected, || {
            Ok(Some(expected.evidence.expected_sha.clone()))
        })
        .unwrap();
    assert_eq!(verified.outcome, PublishOutcome::Verified);
    assert!(ledger.begin(&id(5), evidence()).is_err());
    let mut observed = false;
    let error = ledger
        .verify(&expected, || {
            observed = true;
            Ok(None)
        })
        .unwrap_err();
    assert_eq!(error.code, "publish_record_changed");
    assert!(!observed);
    assert_eq!(
        ledger.get(&root, &id(5)).unwrap().outcome,
        PublishOutcome::Verified
    );
}

#[test]
fn active_attempt_blocks_verification() {
    let (_directory, ledger, _root) = store();
    let attempt = ledger.begin(&id(6), evidence()).unwrap();
    let expected = attempt.record.clone();
    let mut observed = false;
    let error = ledger
        .verify(&expected, || {
            observed = true;
            Ok(None)
        })
        .unwrap_err();
    assert_eq!(error.code, "publish_record_busy");
    assert!(!observed);
    drop(attempt);
}

#[test]
fn begin_without_storage_and_invalid_evidence_fail_closed() {
    assert_eq!(
        expect_error(PublishLedgerStore::default().begin(&id(7), evidence())).code,
        "publish_ledger_unavailable"
    );
    let (_directory, ledger, _root) = store();
    let mut invalid = evidence();
    invalid.remote_url = "https://user:secret@github.com/org/repo.git".into();
    assert!(ledger.begin(&id(8), invalid).is_err());
}

#[cfg(unix)]
#[test]
fn storage_is_private_and_corrupt_replaced_or_symlinked_paths_fail_closed() {
    use std::os::unix::fs::{symlink, PermissionsExt};

    let (directory, ledger, root) = store();
    let attempt = ledger.begin(&id(9), evidence()).unwrap();
    drop(attempt);
    let storage_dir = directory.path().join("publish-ledger");
    let database = storage_dir.join("pushes.sqlite3");
    assert_eq!(
        fs::metadata(&storage_dir).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&database).unwrap().permissions().mode() & 0o777,
        0o600
    );
    fs::write(&database, b"not sqlite").unwrap();
    assert!(ledger.list(&root).is_err());

    let (_directory, ledger, root) = store();
    let attempt = ledger.begin(&id(10), evidence()).unwrap();
    drop(attempt);
    let storage_dir = _directory.path().join("publish-ledger");
    let moved = _directory.path().join("publish-ledger-real");
    fs::rename(&storage_dir, &moved).unwrap();
    symlink(&moved, &storage_dir).unwrap();
    assert!(ledger.list(&root).is_err());

    let (_directory, ledger, root) = store();
    let attempt = ledger.begin(&id(11), evidence()).unwrap();
    drop(attempt);
    let database = _directory.path().join("publish-ledger/pushes.sqlite3");
    let backup = _directory.path().join("pushes-copy.sqlite3");
    fs::copy(&database, &backup).unwrap();
    fs::remove_file(&database).unwrap();
    symlink(&backup, &database).unwrap();
    assert!(ledger.list(&root).is_err());
}

#[test]
fn failed_finish_leaves_initial_unconfirmed_record_on_disk() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(&id(12), evidence()).unwrap();
    let database = directory.path().join("publish-ledger/pushes.sqlite3");
    let backup = directory.path().join("pushes-copy.sqlite3");
    fs::copy(&database, &backup).unwrap();
    fs::remove_file(&database).unwrap();
    fs::copy(&backup, &database).unwrap();
    assert!(attempt.finish(Some(evidence().expected_sha)).is_err());
    drop(ledger);
    let reloaded = PublishLedgerStore::new(directory.path().to_path_buf());
    assert_eq!(
        reloaded.list(&root).unwrap()[0].outcome,
        PublishOutcome::Unconfirmed
    );
}

#[test]
fn ledger_is_bounded_and_payload_contains_no_credentials() {
    let (directory, ledger, root) = store();
    for number in 0..MAX_RECORDS {
        drop(ledger.begin(&id(100 + number), evidence()).unwrap());
    }
    assert_eq!(ledger.list(&root).unwrap().len(), MAX_RECORDS);
    assert!(ledger.begin(&id(999), evidence()).is_err());
    let connection =
        Connection::open(directory.path().join("publish-ledger/pushes.sqlite3")).unwrap();
    let payload: String = connection
        .query_row("SELECT payload FROM pushes LIMIT 1", [], |row| row.get(0))
        .unwrap();
    assert!(payload.contains("expectedSha"));
    assert!(!payload.contains("token"));
    assert!(!payload.contains("password"));
    drop(connection);
    // A reviewed result can free capacity; unknown attempts are never evicted.
    let record = ledger.get(&root, &id(100)).unwrap();
    let observed = ledger
        .verify(&record, || Ok(Some(record.evidence.expected_sha.clone())))
        .unwrap();
    assert_eq!(
        ledger
            .remove_checked(&root, &observed.record_id, observed.revision)
            .unwrap()
            .len(),
        MAX_RECORDS - 1
    );
    drop(ledger.begin(&id(999), evidence()).unwrap());
    assert_eq!(ledger.list(&root).unwrap().len(), MAX_RECORDS);
}

#[test]
fn local_cleanup_requires_observed_inactive_record_and_exact_root_revision() {
    let (directory, ledger, root) = store();
    let attempt = ledger.begin(&id(21), evidence()).unwrap();
    assert_eq!(
        ledger.remove_checked(&root, &id(21), 1).unwrap_err().code,
        "publish_record_busy"
    );
    drop(attempt);
    assert_eq!(
        ledger.remove_checked(&root, &id(21), 1).unwrap_err().code,
        "publish_record_changed"
    );
    let record = ledger.get(&root, &id(21)).unwrap();
    let observed = ledger.verify(&record, || Ok(Some("f".repeat(40)))).unwrap();
    assert_eq!(observed.outcome, PublishOutcome::Different);
    assert_eq!(
        ledger.remove_checked(&root, &id(21), 1).unwrap_err().code,
        "publish_record_changed"
    );
    assert_eq!(
        ledger
            .remove_checked(
                Path::new("/tmp/another-repository"),
                &id(21),
                observed.revision
            )
            .unwrap_err()
            .code,
        "publish_record_changed"
    );
    assert_eq!(ledger.get(&root, &id(21)).unwrap(), observed);
    assert!(ledger
        .remove_checked(&root, &id(21), observed.revision)
        .unwrap()
        .is_empty());
    assert!(ledger
        .remove_checked(&root, &id(21), observed.revision)
        .is_err());
    drop(ledger);
    assert!(PublishLedgerStore::new(directory.path().to_path_buf())
        .list(&root)
        .unwrap()
        .is_empty());
}
