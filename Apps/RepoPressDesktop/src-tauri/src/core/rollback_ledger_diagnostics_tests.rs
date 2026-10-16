use super::*;
use crate::core::{publish_ledger::PushOperation, PublishEvidence};

fn record(root: &str, remote: &str, branch: &str) -> RollbackRecord {
    RollbackRecord {
        record_id: uuid::Uuid::new_v4().to_string(),
        plan_id: uuid::Uuid::new_v4().to_string(),
        session_id: "fixture-session".into(),
        revision: 1,
        source: PublishRecord {
            record_id: uuid::Uuid::new_v4().to_string(),
            revision: 1,
            evidence: PublishEvidence {
                repository_path: root.into(),
                repository_identity: "a".repeat(64),
                operation: PushOperation::Push,
                remote: "origin".into(),
                remote_url: remote.into(),
                branch: branch.into(),
                expected_sha: "a".repeat(40),
                observed_before_sha: None,
                changed_paths: vec![],
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
const URL: &str = "https://github.com/fixture/project.git";

#[test]
fn local_snapshot_has_global_capacity_but_never_exposes_foreign_identifiers_or_unknown_targets() {
    let data = tempfile::tempdir().unwrap();
    let store = RollbackLedgerStore::new(data.path().to_path_buf());
    let local = record("/local", URL, "main");
    let foreign = record("/private-foreign-path", URL, "main");
    let hidden = record(
        "/private-hidden-path",
        "https://github.com/private/hidden.git",
        "secret-branch",
    );
    for r in [&local, &foreign, &hidden] {
        store.insert(r).unwrap();
    }
    let (rows, d) = store
        .inspect_local(Path::new("/local"), &[], false)
        .unwrap();
    assert_eq!(rows, vec![local.clone()]);
    assert_eq!(d.global_records, Some(3));
    assert_eq!(d.local_records, Some(1));
    assert_eq!(d.local_unresolved, Some(1));
    assert_eq!(d.blocked_targets.len(), 1);
    assert_eq!(d.blocked_targets[0].local_unresolved, 1);
    assert!(d.blocked_targets[0].pending_elsewhere);
    let serialized = serde_json::to_string(&(rows, d)).unwrap();
    for private in [
        &foreign.source.evidence.repository_path,
        &foreign.record_id,
        &foreign.plan_id,
        &foreign.source.record_id,
        &hidden.source.evidence.remote_url,
        &hidden.source.evidence.branch,
    ] {
        assert!(!serialized.contains(private));
    }
    let (_, empty) = store.inspect_local(Path::new("/third"), &[], true).unwrap();
    assert!(empty.scope_partial);
    assert!(empty.blocked_targets.is_empty());
    let (_, visible) = store
        .inspect_local(Path::new("/third"), &[(URL.into(), "main".into())], false)
        .unwrap();
    assert_eq!(visible.blocked_targets.len(), 1);
    assert_eq!(visible.blocked_targets[0].local_unresolved, 0);
    assert!(visible.blocked_targets[0].pending_elsewhere);
}

#[test]
fn historical_first_observation_removes_pending_hint_even_after_later_unknown_or_other_head() {
    let data = tempfile::tempdir().unwrap();
    let store = RollbackLedgerStore::new(data.path().to_path_buf());
    let r = record("/local", URL, "main");
    store.insert(&r).unwrap();
    let candidate = store
        .observe(&r, Some(r.candidate_sha.clone()), 40)
        .unwrap();
    let other = store
        .observe(&candidate, Some(r.source.evidence.expected_sha.clone()), 50)
        .unwrap();
    let unknown = store.observe(&other, None, 60).unwrap();
    let (rows, d) = store
        .inspect_local(Path::new("/local"), &[], false)
        .unwrap();
    assert_eq!(rows[0], unknown);
    assert_eq!(rows[0].candidate_observed_at_epoch_ms, Some(40));
    assert_eq!(d.local_unresolved, Some(0));
    assert!(d.blocked_targets.is_empty());
}

#[test]
fn padded_json_uses_actual_storage_bytes_and_refuses_over_capacity_insert_without_changing_old_evidence(
) {
    let data = tempfile::tempdir().unwrap();
    let store = RollbackLedgerStore::new(data.path().to_path_buf());
    let records: Vec<_> = (0..64).map(|_| record("/local", URL, "main")).collect();
    // Coherent legacy/noncanonical JSON must not be estimated by re-encoding.
    store
        .storage(|s| {
            let tx = s.connection.transaction().unwrap();
            for r in &records {
                let text = encode(r).unwrap();
                let payload = format!("{text}{}", " ".repeat(MAX_ROW - text.len()));
                tx.execute(
                    "INSERT INTO pushes(id,repository_path,payload) VALUES(?1,?2,?3)",
                    params![r.record_id, r.source.evidence.repository_path, payload],
                )
                .unwrap();
            }
            tx.commit().unwrap();
            Ok(())
        })
        .unwrap();
    let (before, d) = store
        .inspect_local(Path::new("/local"), &[], false)
        .unwrap();
    assert_eq!(d.payload_bytes, Some(MAX_TOTAL));
    assert_eq!(d.capacity, "full");
    assert_eq!(d.remaining_payload_bytes, Some(0));
    assert!(store.insert(&record("/local", URL, "new-branch")).is_err());
    assert_eq!(store.list(Path::new("/local")).unwrap(), before);
    let observed = store
        .observe(&records[0], Some(records[0].candidate_sha.clone()), 40)
        .unwrap();
    let (_, d) = store
        .inspect_local(Path::new("/local"), &[], false)
        .unwrap();
    assert_eq!(
        d.payload_bytes,
        Some(MAX_TOTAL - MAX_ROW + encode(&observed).unwrap().len())
    );
    assert_eq!(
        d.remaining_payload_bytes,
        Some(MAX_ROW - encode(&observed).unwrap().len() - OBSERVATION_RESERVE)
    );
    assert_eq!(d.capacity, "limited");
}

#[test]
fn corrupt_foreign_row_fails_the_entire_local_diagnostic_snapshot_closed() {
    let data = tempfile::tempdir().unwrap();
    let store = RollbackLedgerStore::new(data.path().to_path_buf());
    let local = record("/local", URL, "main");
    store.insert(&local).unwrap();
    store.storage(|s| {
        s.connection.execute("INSERT INTO pushes(id,repository_path,payload) VALUES('bad','/foreign','broken-private-content')", []).unwrap(); Ok(())
    }).unwrap();
    let error = store
        .inspect_local(Path::new("/local"), &[], false)
        .unwrap_err();
    assert_eq!(error.code, "rollback_ledger_unavailable");
    assert!(!error.message.contains("broken-private-content"));
}

#[test]
fn global_record_limit_and_invalid_row_byte_limit_are_fail_closed() {
    let data = tempfile::tempdir().unwrap();
    let store = RollbackLedgerStore::new(data.path().to_path_buf());
    store
        .storage(|s| {
            let tx = s.connection.transaction().unwrap();
            for _ in 0..200 {
                let r = record("/foreign", URL, "main");
                tx.execute(
                    "INSERT INTO pushes(id,repository_path,payload) VALUES(?1,?2,?3)",
                    params![
                        r.record_id,
                        r.source.evidence.repository_path,
                        encode(&r).unwrap()
                    ],
                )
                .unwrap();
            }
            tx.commit().unwrap();
            Ok(())
        })
        .unwrap();
    let (rows, d) = store
        .inspect_local(Path::new("/local"), &[], false)
        .unwrap();
    assert!(rows.is_empty());
    assert_eq!(d.global_records, Some(200));
    assert_eq!(d.capacity, "full");
    assert!(store.insert(&record("/local", URL, "main")).is_err());
    store
        .storage(|s| {
            let r = record("/foreign", URL, "main");
            s.connection
                .execute(
                    "INSERT INTO pushes(id,repository_path,payload) VALUES(?1,?2,?3)",
                    params![
                        r.record_id,
                        r.source.evidence.repository_path,
                        encode(&r).unwrap()
                    ],
                )
                .unwrap();
            Ok(())
        })
        .unwrap();
    assert!(store
        .inspect_local(Path::new("/local"), &[], false)
        .is_err());
    let data2 = tempfile::tempdir().unwrap();
    let invalid = RollbackLedgerStore::new(data2.path().to_path_buf());
    invalid
        .storage(|s| {
            let r = record("/local", URL, "main");
            let text = encode(&r).unwrap();
            s.connection
                .execute(
                    "INSERT INTO pushes(id,repository_path,payload) VALUES(?1,?2,?3)",
                    params![
                        r.record_id,
                        r.source.evidence.repository_path,
                        format!("{text}{}", " ".repeat(MAX_ROW + 1 - text.len()))
                    ],
                )
                .unwrap();
            Ok(())
        })
        .unwrap();
    assert!(invalid
        .inspect_local(Path::new("/local"), &[], false)
        .is_err());
}
