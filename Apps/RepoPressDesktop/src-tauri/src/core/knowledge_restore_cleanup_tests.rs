use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_backup::KnowledgeBackupStore,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
    knowledge_package_stage::KnowledgePackageStageStore,
};
use serde_json::json;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

fn test_root() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    fs::set_permissions(
        temp.path(),
        std::os::unix::fs::PermissionsExt::from_mode(0o700),
    )
    .unwrap();
    temp
}

struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    candidate: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("app-data");
        let export = temp.path().join("export");
        let parent = temp.path().join("candidate-parent");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir(&export).unwrap();
        fs::create_dir(&parent).unwrap();
        for path in [&root, &export, &parent] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        KnowledgeLibraryStore::new(root.clone())
            .unwrap()
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Web,
                    title: "archive fixture".into(),
                    source_name: "archive source".into(),
                    source_url: Some("https://private.example/archive".into()),
                    text: "archive body".into(),
                    allows_local_semantic_index: true,
                    allows_remote_ai_use: true,
                },
                Some(&BrowserCaptureArchive {
                    format: "html".into(),
                    bytes: b"<html>archive</html>".to_vec(),
                    embedded_resource_count: Some(0),
                    missing_resource_count: Some(0),
                    was_truncated: Some(false),
                }),
            )
            .unwrap();
        let source = export.join("saved.json");
        let backup = KnowledgeBackupStore::new(root.clone());
        let backup_plan = backup.plan(&source).unwrap();
        backup.execute(&backup_plan.plan_id, true).unwrap();
        let stage = KnowledgePackageStageStore::new(root.clone());
        let stage_plan = stage.plan(&source, &parent).unwrap();
        stage.execute(&stage_plan.plan_id, true).unwrap();
        Self {
            _temp: temp,
            root,
            candidate: stage_plan.candidate_path.into(),
        }
    }
}

fn add_candidate_item(candidate: &Path, id: &str) {
    let manifest_path = candidate.join("knowledge-v1/manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    let mut item = manifest["items"][0].clone();
    item["summary"]["itemId"] = json!(id);
    item["summary"]["allowsRemoteAiUse"] = json!(true);
    item["summary"]["allowsLocalSemanticIndex"] = json!(true);
    manifest["items"].as_array_mut().unwrap().push(item);
    let bytes = serde_json::to_vec(&manifest).unwrap();
    fs::write(&manifest_path, &bytes).unwrap();
    let marker = candidate.join("candidate.json");
    let mut marker_value: Value = serde_json::from_slice(&fs::read(&marker).unwrap()).unwrap();
    marker_value["manifestSha256"] = json!(format!("{:x}", Sha256::digest(&bytes)));
    fs::write(marker, serde_json::to_vec(&marker_value).unwrap()).unwrap();
}

fn committed_fixture() -> (Fixture, String, Vec<u8>) {
    let fixture = Fixture::new();
    add_candidate_item(&fixture.candidate, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    let install = KnowledgeRestoreInstallStore::new(fixture.root.clone());
    let plan = install
        .plan(
            &fixture.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    install.execute(&plan.plan_id, true).unwrap();
    let diagnosis: Value = serde_json::to_value(install.inspect().unwrap()).unwrap();
    let transaction = diagnosis["transactionId"].as_str().unwrap().to_owned();
    let current = fs::read(fixture.root.join("knowledge-v1/manifest.json")).unwrap();
    (fixture, transaction, current)
}

fn terminal_fixture(action: KnowledgeRestoreRecoveryAction) -> (Fixture, String) {
    let (fixture, transaction, _) = committed_fixture();
    let install = KnowledgeRestoreInstallStore::new(fixture.root.clone());
    let recovery = install.plan_recovery(&transaction, action).unwrap();
    install.execute_recovery(&recovery.plan_id, true).unwrap();
    (fixture, transaction)
}

fn cancelled_fixture() -> (Fixture, String) {
    let fixture = Fixture::new();
    add_candidate_item(&fixture.candidate, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    let install = KnowledgeRestoreInstallStore::new(fixture.root.clone());
    let plan = install
        .plan(
            &fixture.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(install
        .execute_checked(&plan.plan_id, true, |hook| {
            if hook == 0 {
                return Err(crate::core::CommandError::new("injected", "injected"));
            }
            Ok(())
        })
        .is_err());
    let diagnosis: Value = serde_json::to_value(install.inspect().unwrap()).unwrap();
    let transaction = diagnosis["transactionId"].as_str().unwrap().to_owned();
    let recovery = install
        .plan_recovery(&transaction, KnowledgeRestoreRecoveryAction::Cancel)
        .unwrap();
    install.execute_recovery(&recovery.plan_id, true).unwrap();
    (fixture, transaction)
}

fn closed_fixture() -> (Fixture, String) {
    let (f, id, _) = committed_fixture();
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let p = archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    archive.execute(&p.plan_id, true).unwrap();
    (f, id)
}
fn closed_again(f: &Fixture) -> String {
    let install = KnowledgeRestoreInstallStore::new(f.root.clone());
    let p = install
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let id = install.execute(&p.plan_id, true).unwrap().transaction_id;
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let p = archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    archive.execute(&p.plan_id, true).unwrap();
    id
}
fn tree_bytes(path: &Path) -> BTreeMap<String, Vec<u8>> {
    fn visit(base: &Path, path: &Path, out: &mut BTreeMap<String, Vec<u8>>) {
        for e in fs::read_dir(path).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                visit(base, &p, out);
            } else {
                out.insert(
                    p.strip_prefix(base).unwrap().to_str().unwrap().into(),
                    fs::read(p).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    visit(path, path, &mut out);
    out
}
fn run_cleanup(f: &Fixture, id: &str) -> KnowledgeRestoreCleanupReceipt {
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let p = store
        .plan(id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
    store.execute(&p.plan_id, true).unwrap()
}
#[test]
fn delete_newest_preserves_current_older_history_and_compact_audit_then_allows_new_archive() {
    let (f, older) = closed_fixture();
    let old = tree_bytes(&f.root.join(history_name(&older)));
    let newest = closed_again(&f);
    let current = tree_bytes(&f.root.join("knowledge-v1"));
    let receipt = run_cleanup(&f, &newest);
    assert_eq!(receipt.selected.transaction_id, newest);
    assert!(receipt.removed_file_count > 2);
    assert!(!f.root.join(history_name(&newest)).exists());
    assert!(!f.root.join(CLEAN_INTENT).exists());
    assert_eq!(old, tree_bytes(&f.root.join(history_name(&older))));
    assert_eq!(current, tree_bytes(&f.root.join("knowledge-v1")));
    let name = format!("{}{}.json", RECEIPT_PREFIX, receipt.cleanup_id);
    let root = File::open(&f.root).unwrap();
    let audit = read_audit(&root, &name).unwrap().0;
    assert_eq!(audit.transaction_id, newest);
    assert_eq!(audit.removed_byte_size, receipt.removed_byte_size);
    assert!(audit.physical_space_reclaimed_unknown);
    let raw = fs::read(f.root.join(name)).unwrap();
    assert!(raw.len() < AUDIT_BYTES);
    let text = String::from_utf8(raw).unwrap();
    assert!(!text.contains("archive fixture"));
    assert!(!text.contains("private.example"));
    assert!(!text.contains("archive body"));
    assert!(KnowledgeLibraryStore::new(f.root.clone())
        .unwrap()
        .list(10)
        .is_ok());
    let status = KnowledgeRestoreArchiveStore::new(f.root.clone())
        .inspect()
        .unwrap();
    assert_eq!(status.history.len(), 1);
    closed_again(&f);
    assert_eq!(old, tree_bytes(&f.root.join(history_name(&older))));
}
#[test]
fn only_latest_tail_can_be_selected_and_none_inspection_is_read_only() {
    let (f, old) = closed_fixture();
    let new = closed_again(&f);
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    assert_eq!(
        store.inspect().unwrap().selected.unwrap().transaction_id,
        new
    );
    assert!(store
        .plan(&old, KnowledgeRestoreCleanupAction::Delete)
        .is_err());
    assert!(!f.root.join(CLEAN_INTENT).exists());
    let temp = test_root();
    let empty = KnowledgeRestoreCleanupStore::new(temp.path().into());
    let status = empty.inspect().unwrap();
    assert_eq!(status.state, "none");
    assert_eq!(status.history_count, Some(0));
    assert_eq!(status.receipt_count, Some(0));
    assert!(!status.filesystem_writes);
    assert!(fs::read_dir(temp.path()).unwrap().next().is_none());
}
#[test]
fn no_confirmation_expiry_rollback_and_plan_capacity_are_consumed_before_writes() {
    for mode in 0..4 {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .unwrap();
        if mode > 0 {
            let mut plans = store.plans.lock().unwrap();
            let slot = plans.get_mut(&p.plan_id).unwrap();
            match mode {
                1 => slot.created = Instant::now() - TTL,
                2 => slot.expires = now().unwrap() - 1,
                _ => slot.expires = now().unwrap() + 400000,
            }
        }
        assert!(store.execute(&p.plan_id, mode != 0).is_err());
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!f.root.join(CLEAN_INTENT).exists());
        assert!(f.root.join(history_name(&id)).exists());
    }
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let p = store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
    let q = store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
    assert!(store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .is_err());
    store.discard(&p.plan_id).unwrap();
    store.discard("missing").unwrap();
    assert!(store.execute(&q.plan_id, false).is_err());
    store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
}
#[test]
fn every_known_interrupted_deletion_boundary_resumes_only_after_new_confirmation() {
    for boundary in 0..7 {
        let (f, id) = closed_fixture();
        let before = tree_bytes(&f.root.join("knowledge-v1"));
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .unwrap();
        assert!(
            store
                .execute_checked(
                    &p.plan_id,
                    true,
                    |h| if h == boundary {
                        Err(cleanup_invalid())
                    } else {
                        Ok(())
                    },
                    sync_dir
                )
                .is_err(),
            "boundary {boundary}"
        );
        assert!(f.root.join(CLEAN_INTENT).exists());
        let fresh = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let status = fresh.inspect().unwrap();
        assert!(status.can_resume, "boundary {boundary}: {status:?}");
        assert!(status.library_access_blocked);
        let p = fresh
            .plan(&id, KnowledgeRestoreCleanupAction::Resume)
            .unwrap();
        assert!(fresh.execute(&p.plan_id, false).is_err());
        assert!(f.root.join(CLEAN_INTENT).exists());
        let p = fresh
            .plan(&id, KnowledgeRestoreCleanupAction::Resume)
            .unwrap();
        fresh.execute(&p.plan_id, true).unwrap();
        assert!(!f.root.join(CLEAN_INTENT).exists());
        assert!(!f.root.join(history_name(&id)).exists());
        assert_eq!(before, tree_bytes(&f.root.join("knowledge-v1")));
        assert_eq!(fresh.inspect().unwrap().state, "none");
    }
}
#[test]
fn final_marker_removal_is_completed_without_a_second_delete_or_resume() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let p = store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
    assert!(store
        .execute_checked(
            &p.plan_id,
            true,
            |h| if h == 7 {
                Err(cleanup_invalid())
            } else {
                Ok(())
            },
            sync_dir
        )
        .is_err());
    let fresh = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let s = fresh.inspect().unwrap();
    assert_eq!(s.state, "none");
    assert_eq!(s.receipt_count, Some(1));
    assert!(!s.can_resume);
    assert!(fresh
        .plan(&id, KnowledgeRestoreCleanupAction::Resume)
        .is_err());
    assert!(!f.root.join(CLEAN_INTENT).exists());
}
#[test]
fn pending_cleanup_blocks_live_fresh_library_and_both_restore_stores_without_startup_gc() {
    let (f, id) = closed_fixture();
    let live = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let p = store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
    assert!(store
        .execute_checked(
            &p.plan_id,
            true,
            |h| if h == 1 {
                Err(cleanup_invalid())
            } else {
                Ok(())
            },
            sync_dir
        )
        .is_err());
    let orphan = f.root.join("knowledge-v1/blobs").join("f".repeat(64));
    fs::write(&orphan, b"must not collect while deleting").unwrap();
    fs::set_permissions(&orphan, fs::Permissions::from_mode(0o600)).unwrap();
    assert!(live.list(10).is_err());
    let fresh = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    assert!(fresh.status().is_err());
    assert!(orphan.exists());
    let install = KnowledgeRestoreInstallStore::new(f.root.clone());
    assert_eq!(install.inspect().unwrap().state, "unavailable");
    assert!(install
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
    assert!(install
        .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Rollback)
        .is_err());
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    assert_eq!(archive.inspect().unwrap().state, "blocked");
    assert!(archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .is_err());
}
#[test]
fn source_current_and_prefix_drift_refuse_deletion_without_an_intent() {
    for mode in 0..5 {
        let (f, older) = closed_fixture();
        let id = closed_again(&f);
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .unwrap();
        let history = f.root.join(history_name(&id));
        match mode {
            0 => {
                fs::write(f.root.join("knowledge-v1/manifest.json"), b"changed").unwrap();
            }
            1 => {
                let path = history.join(JOURNAL);
                let mut b = fs::read(&path).unwrap();
                b.push(b' ');
                fs::write(path, b).unwrap();
            }
            2 => {
                fs::write(history.join("unknown"), b"private unknown data").unwrap();
            }
            3 => {
                let path = f.root.join(history_name(&older)).join(RECORD);
                let b = fs::read(&path).unwrap();
                fs::write(path, b).unwrap();
            }
            _ => {
                let path = f.root.join("knowledge-v1/manifest.json");
                let b = fs::read(&path).unwrap();
                fs::rename(&path, f.root.join("old-manifest")).unwrap();
                fs::write(&path, b).unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
            }
        }
        assert!(store.execute(&p.plan_id, true).is_err(), "mode {mode}");
        assert!(!f.root.join(CLEAN_INTENT).exists());
        assert!(history.exists());
    }
}
#[test]
fn root_replacement_exclusive_flock_and_unsafe_root_consume_plan_without_deletion() {
    for mode in 0..3 {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .unwrap();
        let held = match mode {
            0 => {
                fs::rename(&f.root, f.root.with_file_name("old-root")).unwrap();
                fs::create_dir(&f.root).unwrap();
                fs::set_permissions(&f.root, fs::Permissions::from_mode(0o700)).unwrap();
                None
            }
            1 => Some(KnowledgeRootLease::acquire(&f.root).unwrap()),
            _ => {
                fs::set_permissions(&f.root, fs::Permissions::from_mode(0o777)).unwrap();
                None
            }
        };
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!f.root.join(CLEAN_INTENT).exists());
        drop(held);
    }
}
#[test]
fn links_fifo_nonprivate_nodes_and_unknown_quarantine_are_preserved() {
    use std::os::unix::fs::symlink;
    for mode in 0..6 {
        let (f, id) = closed_fixture();
        let history = f.root.join(history_name(&id));
        match mode {
            0 => {
                fs::set_permissions(&history, fs::Permissions::from_mode(0o755)).unwrap();
            }
            1 => {
                fs::hard_link(history.join(JOURNAL), f.root.join("linked-journal")).unwrap();
            }
            2 => {
                fs::rename(history.join(RECORD), f.root.join("moved-record")).unwrap();
                symlink(f.root.join("moved-record"), history.join(RECORD)).unwrap();
            }
            3 => {
                let name = cstring(f.root.join(CLEAN_INTENT).to_str().unwrap()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            }
            4 => {
                fs::create_dir(
                    f.root
                        .join(format!("{}{}", QUARANTINE_PREFIX, Uuid::new_v4())),
                )
                .unwrap();
            }
            _ => {
                fs::write(
                    f.root.join(format!("{}invalid.json", RECEIPT_PREFIX)),
                    b"unknown",
                )
                .unwrap();
            }
        }
        let before = tree_bytes(&f.root.join("knowledge-v1"));
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        assert_eq!(store.inspect().unwrap().state, "blocked");
        assert!(store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .is_err());
        assert_eq!(before, tree_bytes(&f.root.join("knowledge-v1")));
        assert!(history.exists());
    }
}
#[test]
fn changed_or_extra_partial_quarantine_blocks_resume_and_preserves_remaining_data() {
    for mode in 0..3 {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .unwrap();
        assert!(store
            .execute_checked(
                &p.plan_id,
                true,
                |h| if h == 1 {
                    Err(cleanup_invalid())
                } else {
                    Ok(())
                },
                sync_dir
            )
            .is_err());
        let read = read_intent(&File::open(&f.root).unwrap()).unwrap();
        let path = f.root.join(read.intent.quarantine());
        match mode {
            0 => {
                fs::write(path.join(RECORD), b"changed").unwrap();
            }
            1 => {
                fs::write(path.join("unknown"), b"keep this").unwrap();
            }
            _ => {
                fs::set_permissions(
                    path.join("snapshot/blobs"),
                    fs::Permissions::from_mode(0o755),
                )
                .unwrap();
            }
        }
        let bytes = tree_bytes(&path);
        let fresh = KnowledgeRestoreCleanupStore::new(f.root.clone());
        assert_eq!(fresh.inspect().unwrap().state, "blocked");
        assert!(fresh
            .plan(&id, KnowledgeRestoreCleanupAction::Resume)
            .is_err());
        assert_eq!(bytes, tree_bytes(&path));
        assert!(f.root.join(CLEAN_INTENT).exists());
    }
}
#[test]
fn durable_release_sync_failure_preserves_intent_and_receipt_for_explicit_resume() {
    for fail in 0..2 {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .unwrap();
        let mut calls = 0;
        assert!(store
            .execute_checked(
                &p.plan_id,
                true,
                |_| Ok(()),
                |dir| {
                    let n = calls;
                    calls += 1;
                    if n == fail {
                        Err(cleanup_invalid())
                    } else {
                        sync_dir(dir)
                    }
                }
            )
            .is_err());
        assert_eq!(calls, fail + 1);
        assert!(f.root.join(CLEAN_INTENT).exists());
        let fresh = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let status = fresh.inspect().unwrap();
        assert_eq!(status.state, "cleaned");
        let p = fresh
            .plan(&id, KnowledgeRestoreCleanupAction::Resume)
            .unwrap();
        fresh.execute(&p.plan_id, true).unwrap();
        assert!(!f.root.join(CLEAN_INTENT).exists());
        assert_eq!(fresh.inspect().unwrap().receipt_count, Some(1));
    }
}
#[test]
fn journal_only_cancelled_and_fully_prepared_cancelled_histories_can_be_cleaned() {
    let (f, id) = cancelled_fixture();
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let p = archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    archive.execute(&p.plan_id, true).unwrap();
    let receipt = run_cleanup(&f, &id);
    assert_eq!(receipt.removed_file_count, 2);
    assert!(!receipt.selected.snapshot_present);
    let (f, id) = terminal_fixture(KnowledgeRestoreRecoveryAction::Rollback);
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let p = archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    archive.execute(&p.plan_id, true).unwrap();
    let receipt = run_cleanup(&f, &id);
    assert!(receipt.selected.snapshot_present);
    assert_eq!(receipt.selected.phase, "rolledBack");
}
#[test]
fn full_history_capacity_is_reclaimed_while_receipts_have_a_separate_bounded_limit() {
    let (f, mut id) = closed_fixture();
    for _ in 1..4 {
        id = closed_again(&f);
    }
    assert_eq!(
        KnowledgeRestoreArchiveStore::new(f.root.clone())
            .inspect()
            .unwrap()
            .history
            .len(),
        4
    );
    let receipt = run_cleanup(&f, &id);
    assert_eq!(
        KnowledgeRestoreArchiveStore::new(f.root.clone())
            .inspect()
            .unwrap()
            .history
            .len(),
        3
    );
    closed_again(&f);
    let root = File::open(&f.root).unwrap();
    let name = format!("{}{}.json", RECEIPT_PREFIX, receipt.cleanup_id);
    let a = read_audit(&root, &name).unwrap().0;
    for _ in 1..RECEIPT_LIMIT {
        let mut a = a.clone();
        a.cleanup_id = Uuid::new_v4().to_string();
        write_new(
            &root,
            &format!("{}{}.json", RECEIPT_PREFIX, a.cleanup_id),
            &serde_json::to_vec(&a).unwrap(),
        )
        .unwrap();
    }
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let status = store.inspect().unwrap();
    assert_eq!(status.state, "eligible");
    assert_eq!(status.receipt_count, Some(RECEIPT_LIMIT));
    assert!(!status.can_delete);
    assert!(store
        .plan(
            &status.selected.unwrap().transaction_id,
            KnowledgeRestoreCleanupAction::Delete
        )
        .is_err());
    assert!(!f.root.join(CLEAN_INTENT).exists());
}
#[test]
fn active_restore_and_archive_intents_refuse_cleanup_without_adopting_partial_history() {
    let (f, id, _) = committed_fixture();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    assert!(store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .is_err());
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let p = archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    assert!(archive
        .execute_checked(&p.plan_id, true, |h| if h == 1 {
            Err(cleanup_invalid())
        } else {
            Ok(())
        })
        .is_err());
    assert_eq!(store.inspect().unwrap().state, "blocked");
    assert!(!f.root.join(CLEAN_INTENT).exists());
}
#[test]
fn mount_identity_is_required_and_intent_tampering_never_expands_delete_scope() {
    let (f, _id) = closed_fixture();
    let root = File::open(&f.root).unwrap();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let lease = store.install.unrestricted_lease().unwrap();
    let o = observe_cleanup(&lease).unwrap();
    let i = o.material.unwrap();
    assert_eq!(mount_id(&root).unwrap(), i.root_mount_id);
    assert!(i.root_mount_id > 0);
    let mut bad = i.clone();
    bad.root_mount_id += 1;
    assert!(valid_intent(&bad, &root).is_err());
    let mut bad = i.clone();
    bad.files.insert(
        "../knowledge-v1/manifest.json".into(),
        i.files[RECORD].clone(),
    );
    assert!(valid_intent(&bad, &root).is_err());
    let mut bad = i.clone();
    bad.files.remove(RECORD);
    assert!(valid_intent(&bad, &root).is_err());
    let mut bad = i;
    bad.directories
        .insert("snapshot/unexpected".into(), bad.directories[""].clone());
    assert!(valid_intent(&bad, &root).is_err());
    assert!(!f.root.join(CLEAN_INTENT).exists());
}
#[test]
fn new_unknown_data_during_deletion_stops_before_the_next_unlink() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let p = store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
    let mut first = true;
    let mut quarantine = None;
    assert!(store
        .execute_checked(
            &p.plan_id,
            true,
            |hook| {
                if hook == 2 && first {
                    first = false;
                    let read = read_intent(&File::open(&f.root).unwrap())?;
                    let dir = f.root.join(read.intent.quarantine());
                    fs::write(dir.join("unknown"), b"new private data").unwrap();
                    quarantine = Some(dir);
                }
                Ok(())
            },
            sync_dir
        )
        .is_err());
    let dir = quarantine.unwrap();
    assert_eq!(fs::read(dir.join("unknown")).unwrap(), b"new private data");
    assert!(dir.join(RECORD).exists());
    assert!(dir.join(JOURNAL).exists());
    let remaining = tree_bytes(&dir);
    assert!(remaining.len() >= 3);
    assert_eq!(store.inspect().unwrap().state, "blocked");
    assert!(f.root.join(CLEAN_INTENT).exists());
}

#[test]
fn capacity_can_be_reclaimed_with_a_fifth_completed_active_transaction_and_rollback_evidence_preserved(
) {
    let (f, mut latest) = closed_fixture();
    for _ in 1..4 {
        latest = closed_again(&f);
    }
    let install = KnowledgeRestoreInstallStore::new(f.root.clone());
    let p = install
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let active_id = install.execute(&p.plan_id, true).unwrap().transaction_id;
    let journal = fs::read(f.root.join(JOURNAL)).unwrap();
    let stage = f.root.join(format!("{}{}", STAGE_PREFIX, active_id));
    let stage_before = tree_bytes(&stage);
    let current_before = tree_bytes(&f.root.join("knowledge-v1"));
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    assert!(archive
        .plan(&active_id, KnowledgeRestoreArchiveAction::Archive)
        .is_err());
    run_cleanup(&f, &latest);
    assert_eq!(journal, fs::read(f.root.join(JOURNAL)).unwrap());
    assert_eq!(stage_before, tree_bytes(&stage));
    assert_eq!(current_before, tree_bytes(&f.root.join("knowledge-v1")));
    install
        .plan_recovery(&active_id, KnowledgeRestoreRecoveryAction::Rollback)
        .unwrap();
    let p = archive
        .plan(&active_id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    archive.execute(&p.plan_id, true).unwrap();
    assert_eq!(archive.inspect().unwrap().history.len(), 4);
}

#[test]
fn current_resource_inode_or_content_drift_cannot_be_ignored_by_cleanup() {
    for mode in 0..2 {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreCleanupAction::Delete)
            .unwrap();
        let path = fs::read_dir(f.root.join("knowledge-v1/blobs"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        if mode == 0 {
            fs::write(&path, b"current content changed").unwrap();
        } else {
            let b = fs::read(&path).unwrap();
            fs::rename(&path, f.root.join("old-body")).unwrap();
            fs::write(&path, b).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!f.root.join(CLEAN_INTENT).exists());
        assert!(f.root.join(history_name(&id)).exists());
    }
    let (f, _id) = closed_fixture();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let lease = store.install.unrestricted_lease().unwrap();
    let mut i = observe_cleanup(&lease).unwrap().material.unwrap();
    i.active.top = i.directories["snapshot"].clone();
    assert!(valid_intent(&i, &lease.file).is_err());
}

#[test]
fn capability_rejected_after_file_read_leaves_quarantine_untouched() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreCleanupStore::new(f.root.clone());
    let p = store
        .plan(&id, KnowledgeRestoreCleanupAction::Delete)
        .unwrap();
    assert!(store
        .execute_checked(
            &p.plan_id,
            true,
            |step| {
                if step == 1 {
                    return Err(cleanup_invalid());
                }
                Ok(())
            },
            sync_dir
        )
        .is_err());
    {
        let lease = store.install.unrestricted_lease().unwrap();
        let read = read_intent(&lease.file).unwrap();
        let quarantine = f.root.join(read.intent.quarantine());
        let before = tree_bytes(&quarantine);
        let tree = inspect_tree(
            &lease.file,
            &read.intent.quarantine(),
            &read.intent,
            true,
            Instant::now(),
        )
        .unwrap();
        let path = tree
            .files
            .iter()
            .find(|p| p.starts_with("snapshot/"))
            .unwrap();
        let mut checked = false;
        assert!(delete_file(
            &lease.file,
            &tree,
            path,
            &read.intent,
            Instant::now(),
            || {
                checked = true;
                Err(cleanup_invalid())
            }
        )
        .is_err());
        assert!(checked);
        assert_eq!(before, tree_bytes(&quarantine));
        assert!(f.root.join(CLEAN_INTENT).exists());
    }
    let p = store
        .plan(&id, KnowledgeRestoreCleanupAction::Resume)
        .unwrap();
    store.execute(&p.plan_id, true).unwrap();
}
