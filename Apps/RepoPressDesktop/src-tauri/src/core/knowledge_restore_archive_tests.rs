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

#[test]
fn empty_store_is_read_only_and_has_no_archive_transaction() {
    let temp = test_root();
    let store = KnowledgeRestoreArchiveStore::new(temp.path().to_path_buf());
    let status = store.inspect().unwrap();
    let value: Value = serde_json::to_value(status).unwrap();
    assert_eq!(value["schemaVersion"], 1);
    assert_eq!(value["scope"], "knowledgeRestoreArchiveStatus");
    assert!(matches!(
        value["state"].as_str(),
        Some("none") | Some("unavailable")
    ));
    assert_eq!(value["filesystemWrites"], false);
    assert_eq!(value["historyLimit"], 4);
    assert!(store.discard("missing-plan").is_ok());
}

#[test]
fn archive_and_resume_plans_require_a_known_completed_transaction() {
    let temp = test_root();
    let store = KnowledgeRestoreArchiveStore::new(temp.path().to_path_buf());
    assert!(store
        .plan(
            "missing-transaction",
            KnowledgeRestoreArchiveAction::Archive
        )
        .is_err());
    assert!(store
        .plan("missing-transaction", KnowledgeRestoreArchiveAction::Resume)
        .is_err());
}

#[test]
fn private_root_permissions_are_rejected_without_writing_an_intent() {
    let temp = tempfile::tempdir().unwrap();
    fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o777)).unwrap();
    let store = KnowledgeRestoreArchiveStore::new(temp.path().to_path_buf());
    let _ = store.inspect();
    assert!(!temp
        .path()
        .join("knowledge-restore-archive-intent.json")
        .exists());
}

#[test]
fn committed_archive_retains_snapshot_and_leaves_current_bytes_unchanged() {
    let (fixture, transaction, before) = committed_fixture();
    let store = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
    let plan = store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    assert!(store.execute(&plan.plan_id, false).is_err());
    assert!(store.execute(&plan.plan_id, true).is_err());
    let plan = store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    let receipt = store.execute(&plan.plan_id, true).unwrap();
    let value: Value = serde_json::to_value(receipt).unwrap();
    assert_eq!(value["state"], "archived");
    assert_eq!(value["snapshotRetained"], true);
    assert_eq!(
        fs::read(fixture.root.join("knowledge-v1/manifest.json")).unwrap(),
        before
    );
    let status: Value = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert_eq!(status["transactionSlotReleased"], true);
}

#[test]
fn interrupted_archive_can_resume_after_restart_at_each_durable_boundary() {
    for boundary in 0..4u8 {
        let (fixture, transaction, before) = committed_fixture();
        let store = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
        let plan = store
            .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        assert!(store
            .execute_checked(&plan.plan_id, true, |hook| {
                if hook == boundary {
                    return Err(crate::core::CommandError::new("injected", "injected"));
                }
                Ok(())
            })
            .is_err());
        let restarted = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
        let resume = restarted
            .plan(&transaction, KnowledgeRestoreArchiveAction::Resume)
            .unwrap_or_else(|error| {
                panic!(
                    "boundary {boundary} resume plan failed: {error:?}; status={:?}",
                    restarted.inspect()
                )
            });
        assert!(
            restarted.execute(&resume.plan_id, true).is_ok(),
            "boundary {boundary}"
        );
        assert_eq!(
            fs::read(fixture.root.join("knowledge-v1/manifest.json")).unwrap(),
            before
        );
    }
}

#[test]
fn interruption_after_intent_removal_is_terminal_history_without_resume() {
    let (fixture, transaction, before) = committed_fixture();
    let store = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
    let plan = store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    assert!(store
        .execute_checked(&plan.plan_id, true, |hook| {
            if hook == 4 {
                return Err(crate::core::CommandError::new("injected", "injected"));
            }
            Ok(())
        })
        .is_err());
    let restarted = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
    let status: Value = serde_json::to_value(restarted.inspect().unwrap()).unwrap();
    assert_eq!(status["state"], "none");
    assert_eq!(status["transactionSlotReleased"], true);
    assert_eq!(status["history"][0]["transactionId"], transaction);
    assert!(restarted
        .plan(&transaction, KnowledgeRestoreArchiveAction::Resume)
        .is_err());
    assert_eq!(
        fs::read(fixture.root.join("knowledge-v1/manifest.json")).unwrap(),
        before
    );
}

#[test]
fn archive_rejects_current_library_drift_before_write() {
    let (fixture, transaction, _) = committed_fixture();
    let store = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
    let plan = store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    fs::write(fixture.root.join("knowledge-v1/manifest.json"), b"drift").unwrap();
    assert!(store.execute(&plan.plan_id, true).is_err());
    assert!(store.execute(&plan.plan_id, true).is_err());
}

#[test]
fn rolled_back_and_cancelled_terminal_journals_are_archivable() {
    {
        let action = KnowledgeRestoreRecoveryAction::Rollback;
        let (fixture, transaction) = terminal_fixture(action);
        let store = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
        let plan = store
            .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        assert!(
            store.execute(&plan.plan_id, true).is_ok(),
            "action {action:?}"
        );
        let status: Value = serde_json::to_value(store.inspect().unwrap()).unwrap();
        assert_eq!(status["state"], "none");
        assert_eq!(
            status["history"][0]["phase"],
            match action {
                KnowledgeRestoreRecoveryAction::Rollback => "rolledBack",
                KnowledgeRestoreRecoveryAction::Cancel => "cancelled",
                _ => unreachable!(),
            }
        );
    }
    let (fixture, transaction) = cancelled_fixture();
    let store = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
    let plan = store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    assert!(store.execute(&plan.plan_id, true).is_ok());
}

#[test]
fn two_live_archive_plans_are_allowed_but_third_is_rejected() {
    let (fixture, transaction, _) = committed_fixture();
    let store = KnowledgeRestoreArchiveStore::new(fixture.root.clone());
    let first = store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    let second = store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    assert!(store
        .plan(&transaction, KnowledgeRestoreArchiveAction::Archive)
        .is_err());
    assert!(store.discard(&first.plan_id).is_ok());
    assert!(store.execute(&second.plan_id, false).is_err());
    let _ = fixture;
}

fn bytes_tree(path: &Path) -> BTreeMap<String, Vec<u8>> {
    fn walk(base: &Path, path: &Path, files: &mut BTreeMap<String, Vec<u8>>) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(base, &path, files);
            } else {
                files.insert(
                    path.strip_prefix(base).unwrap().to_str().unwrap().into(),
                    fs::read(path).unwrap(),
                );
            }
        }
    }
    let mut files = BTreeMap::new();
    walk(path, path, &mut files);
    files
}
fn archive_once(f: &Fixture, transaction: &str) {
    let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let plan = store
        .plan(transaction, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    store.execute(&plan.plan_id, true).unwrap();
}
fn install_again(f: &Fixture) -> String {
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let p = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    store.execute(&p.plan_id, true).unwrap().transaction_id
}
#[test]
fn all_snapshot_and_original_journal_bytes_survive_archive_and_next_install() {
    let (f, id, _) = committed_fixture();
    let stage = f.root.join(format!("{}{}", STAGE_PREFIX, id));
    let previous = bytes_tree(&stage);
    let current = bytes_tree(&f.root.join("knowledge-v1"));
    let journal = fs::read(f.root.join(JOURNAL)).unwrap();
    archive_once(&f, &id);
    let history = f.root.join(history_name(&id));
    assert_eq!(previous, bytes_tree(&history.join(SNAPSHOT)));
    assert_eq!(current, bytes_tree(&f.root.join("knowledge-v1")));
    assert_eq!(journal, fs::read(history.join(JOURNAL)).unwrap());
    assert!(!stage.exists());
    assert!(!f.root.join(JOURNAL).exists());
    assert!(!f.root.join(INTENT).exists());
    assert_eq!(
        history.metadata().unwrap().permissions().mode() & 0o7777,
        0o700
    );
    for name in [RECORD, JOURNAL] {
        assert_eq!(
            history.join(name).metadata().unwrap().permissions().mode() & 0o7777,
            0o600
        );
    }
    let next = install_again(&f);
    assert_ne!(next, id);
    assert_eq!(previous, bytes_tree(&history.join(SNAPSHOT)));
}
#[test]
fn expiry_and_wall_clock_rollback_consume_plans_before_any_write() {
    for mode in 0..3 {
        let (f, id, _) = committed_fixture();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        let plan = store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        {
            let mut plans = store.plans.lock().unwrap();
            let p = plans.get_mut(&plan.plan_id).unwrap();
            match mode {
                0 => p.created = Instant::now() - TTL,
                1 => p.expires = now().unwrap() - 1,
                _ => p.expires = now().unwrap() + 400000,
            }
        }
        assert!(store.execute(&plan.plan_id, true).is_err());
        assert!(store.execute(&plan.plan_id, true).is_err());
        assert!(!f.root.join(INTENT).exists());
    }
}
#[test]
fn journal_snapshot_and_child_directory_drift_reject_execution_before_intent() {
    for mode in 0..4 {
        let (f, id, _) = committed_fixture();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        let stage = f.root.join(format!("{}{}", STAGE_PREFIX, id));
        match mode {
            0 => {
                let path = f.root.join(JOURNAL);
                let mut b = fs::read(&path).unwrap();
                b.push(b' ');
                fs::write(path, b).unwrap();
            }
            1 => {
                let path = stage.join("manifest.json");
                let b = fs::read(&path).unwrap();
                fs::rename(&path, stage.join("original-manifest")).unwrap();
                fs::write(&path, b).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            }
            2 => {
                let path = fs::read_dir(stage.join("blobs"))
                    .unwrap()
                    .next()
                    .unwrap()
                    .unwrap()
                    .path();
                fs::write(path, b"changed").unwrap();
            }
            _ => {
                let dir = f.root.join("knowledge-v1/blobs");
                fs::rename(&dir, f.root.join("old-blobs")).unwrap();
                fs::create_dir(&dir).unwrap();
                fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
            }
        }
        assert!(store.execute(&p.plan_id, true).is_err(), "mode {mode}");
        assert!(!f.root.join(INTENT).exists());
    }
}
#[test]
fn root_replacement_and_exclusive_lease_reject_and_consume_plan() {
    for mode in 0..2 {
        let (f, id, _) = committed_fixture();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        let held = if mode == 0 {
            fs::rename(&f.root, f.root.with_file_name("old-app-data")).unwrap();
            fs::create_dir(&f.root).unwrap();
            fs::set_permissions(&f.root, fs::Permissions::from_mode(0o700)).unwrap();
            None
        } else {
            Some(KnowledgeRootLease::acquire(&f.root).unwrap())
        };
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!f.root.join(INTENT).exists());
        drop(held);
    }
}
#[test]
fn unsafe_nodes_permissions_and_unknown_reserved_paths_stay_untouched() {
    use std::os::unix::fs::symlink;
    for mode in 0..6 {
        let (f, id, _) = committed_fixture();
        let stage = f.root.join(format!("{}{}", STAGE_PREFIX, id));
        match mode {
            0 => fs::set_permissions(&stage, fs::Permissions::from_mode(0o755)).unwrap(),
            1 => {
                let manifest = stage.join("manifest.json");
                fs::rename(&manifest, f.root.join("saved-manifest")).unwrap();
                symlink(f.root.join("saved-manifest"), &manifest).unwrap();
            }
            2 => {
                fs::hard_link(stage.join("manifest.json"), f.root.join("hard-manifest")).unwrap();
            }
            3 => {
                let name = cstring(f.root.join(INTENT).to_str().unwrap()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            }
            4 => {
                fs::create_dir(f.root.join(format!("{}{}", STAGE_PREFIX, Uuid::new_v4()))).unwrap();
            }
            _ => {
                fs::create_dir(f.root.join(format!("{}unknown", HISTORY_PREFIX))).unwrap();
            }
        }
        let before = fs::read(f.root.join(JOURNAL)).unwrap();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        assert_eq!(store.inspect().unwrap().state, "blocked", "mode {mode}");
        assert!(store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .is_err());
        assert_eq!(before, fs::read(f.root.join(JOURNAL)).unwrap());
        assert!(!f.root.join(history_name(&id)).exists());
    }
}
#[test]
fn pending_archive_blocks_live_and_fresh_library_and_p52_recovery_without_gc() {
    for boundary in 0..4 {
        let (f, id, _) = committed_fixture();
        let live = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
        let install = KnowledgeRestoreInstallStore::new(f.root.clone());
        let rollback = install
            .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Rollback)
            .unwrap();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        assert!(store
            .execute_checked(&p.plan_id, true, |h| if h == boundary {
                Err(invalid())
            } else {
                Ok(())
            })
            .is_err());
        let blobs = f.root.join("knowledge-v1/blobs");
        let orphan = blobs.join("f".repeat(64));
        fs::write(&orphan, b"keep unknown saved data").unwrap();
        fs::set_permissions(&orphan, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(live.list(10).is_err());
        let fresh = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
        assert!(fresh.list(10).is_err());
        assert_eq!(fs::read(&orphan).unwrap(), b"keep unknown saved data");
        assert_eq!(install.inspect().unwrap().state, "unavailable");
        assert!(install.execute_recovery(&rollback.plan_id, true).is_err());
        assert!(install
            .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Rollback)
            .is_err());
        assert!(install
            .plan(
                &f.candidate,
                KnowledgeRestoreStrategy::KeepCurrentIdentities
            )
            .is_err());
    }
}
#[test]
fn nonterminal_and_partial_cancelled_transactions_are_not_archived() {
    for boundary in 0..3 {
        let f = Fixture::new();
        let install = KnowledgeRestoreInstallStore::new(f.root.clone());
        let p = install
            .plan(
                &f.candidate,
                KnowledgeRestoreStrategy::KeepCurrentIdentities,
            )
            .unwrap();
        assert!(install
            .execute_checked(&p.plan_id, true, |h| if h == boundary {
                Err(invalid())
            } else {
                Ok(())
            })
            .is_err());
        let id = install.inspect().unwrap().transaction_id.unwrap();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        assert!(store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .is_err());
    }
    let (f, id) = cancelled_fixture();
    let dir = f.root.join(format!("{}{}", STAGE_PREFIX, id));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
    assert!(store
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .is_err());
    assert!(dir.exists());
    assert!(!f.root.join(INTENT).exists());
}
#[test]
fn fully_prepared_cancelled_snapshot_can_be_archived() {
    let f = Fixture::new();
    let install = KnowledgeRestoreInstallStore::new(f.root.clone());
    let p = install
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(install
        .execute_checked(&p.plan_id, true, |h| if h == 1 {
            Err(invalid())
        } else {
            Ok(())
        })
        .is_err());
    let id = install.inspect().unwrap().transaction_id.unwrap();
    let cancel = install
        .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Cancel)
        .unwrap();
    install.execute_recovery(&cancel.plan_id, true).unwrap();
    let stage = f.root.join(format!("{}{}", STAGE_PREFIX, id));
    let bytes = bytes_tree(&stage);
    archive_once(&f, &id);
    assert_eq!(
        bytes,
        bytes_tree(&f.root.join(history_name(&id)).join(SNAPSHOT))
    );
}
#[test]
fn four_histories_allow_normal_access_but_fifth_archive_requires_future_capacity_management() {
    let (f, mut id, _) = committed_fixture();
    for n in 0..4 {
        archive_once(&f, &id);
        let status = KnowledgeRestoreArchiveStore::new(f.root.clone())
            .inspect()
            .unwrap();
        assert_eq!(status.history.len(), n + 1);
        assert!(status.transaction_slot_released);
        assert!(KnowledgeLibraryStore::new(f.root.clone())
            .unwrap()
            .list(10)
            .is_ok());
        id = install_again(&f);
    }
    let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let status = store.inspect().unwrap();
    assert_eq!(status.state, "eligible");
    assert_eq!(status.history.len(), 4);
    assert!(!status.can_archive);
    assert!(store
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .is_err());
    assert!(!f.root.join(INTENT).exists());
    assert!(f.root.join(JOURNAL).exists());
}
#[test]
fn old_history_disappearance_and_content_drift_break_the_predecessor_chain() {
    for mode in 0..3 {
        let (f, id, _) = committed_fixture();
        archive_once(&f, &id);
        let next = install_again(&f);
        archive_once(&f, &next);
        let history = f.root.join(history_name(&id));
        match mode {
            0 => fs::rename(&history, f.root.with_file_name("removed-history")).unwrap(),
            1 => {
                let path = history.join(RECORD);
                let b = fs::read(&path).unwrap();
                fs::write(path, b).unwrap();
            }
            _ => fs::write(history.join(SNAPSHOT).join("manifest.json"), b"changed").unwrap(),
        }
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        assert_eq!(store.inspect().unwrap().state, "blocked", "mode {mode}");
        assert!(!f.root.join(INTENT).exists());
    }
}
#[test]
fn empty_known_destination_resumes_but_unknown_partial_metadata_is_preserved() {
    for mode in 0..3 {
        let (f, id, _) = committed_fixture();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        assert!(store
            .execute_checked(&p.plan_id, true, |h| if h == 0 {
                Err(invalid())
            } else {
                Ok(())
            })
            .is_err());
        let dir = f.root.join(history_name(&id));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let unknown = if mode == 1 {
            Some(dir.join(RECORD))
        } else if mode == 2 {
            Some(dir.join("unknown"))
        } else {
            None
        };
        if let Some(path) = &unknown {
            fs::write(path, b"partial").unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let fresh = KnowledgeRestoreArchiveStore::new(f.root.clone());
        if mode == 0 {
            let resume = fresh
                .plan(&id, KnowledgeRestoreArchiveAction::Resume)
                .unwrap();
            fresh.execute(&resume.plan_id, true).unwrap();
        } else {
            assert_eq!(fresh.inspect().unwrap().state, "blocked");
            assert!(fresh
                .plan(&id, KnowledgeRestoreArchiveAction::Resume)
                .is_err());
            assert_eq!(fs::read(unknown.unwrap()).unwrap(), b"partial");
            assert!(f.root.join(INTENT).exists());
        }
    }
}
#[test]
fn valid_edit_before_archive_is_allowed_and_active_change_at_final_bookend_blocks_release() {
    let (f, id, _) = committed_fixture();
    let lib = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    lib.create_folder("normal edit").unwrap();
    let current = bytes_tree(&f.root.join("knowledge-v1"));
    archive_once(&f, &id);
    assert_eq!(current, bytes_tree(&f.root.join("knowledge-v1")));
    let next = install_again(&f);
    let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let p = store
        .plan(&next, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    assert!(store
        .execute_checked(&p.plan_id, true, |h| {
            if h == 3 {
                fs::write(f.root.join("knowledge-v1/manifest.json"), b"drift").unwrap();
            }
            Ok(())
        })
        .is_err());
    assert!(f.root.join(INTENT).exists());
    assert_eq!(store.inspect().unwrap().state, "blocked");
}

#[test]
fn release_sync_failure_keeps_intent_and_every_byte_for_another_explicit_resume() {
    for failure in 0..2 {
        let (f, id, _) = committed_fixture();
        let store = KnowledgeRestoreArchiveStore::new(f.root.clone());
        let p = store
            .plan(&id, KnowledgeRestoreArchiveAction::Archive)
            .unwrap();
        assert!(store
            .execute_checked(&p.plan_id, true, |h| if h == 3 {
                Err(invalid())
            } else {
                Ok(())
            })
            .is_err());
        let history = f.root.join(history_name(&id));
        let before = bytes_tree(&history);
        let fresh = KnowledgeRestoreArchiveStore::new(f.root.clone());
        let resume = fresh
            .plan(&id, KnowledgeRestoreArchiveAction::Resume)
            .unwrap();
        let mut calls = 0;
        assert!(fresh
            .execute_with_release_sync(
                &resume.plan_id,
                true,
                |_| Ok(()),
                |dir| {
                    let expected = if calls == 0 {
                        File::open(&history).unwrap()
                    } else {
                        File::open(&f.root).unwrap()
                    };
                    assert_eq!(
                        disk::identity(&disk::file_stamp(dir)?),
                        disk::identity(&disk::file_stamp(&expected)?)
                    );
                    let this = calls;
                    calls += 1;
                    if this == failure {
                        Err(invalid())
                    } else {
                        sync_dir(dir)
                    }
                }
            )
            .is_err());
        assert_eq!(calls, failure + 1);
        assert!(f.root.join(INTENT).exists());
        assert_eq!(before, bytes_tree(&history));
        assert_eq!(fresh.inspect().unwrap().state, "archived");
        assert!(fresh.execute(&resume.plan_id, true).is_err());
        let resume = fresh
            .plan(&id, KnowledgeRestoreArchiveAction::Resume)
            .unwrap();
        fresh.execute(&resume.plan_id, true).unwrap();
        assert!(!f.root.join(INTENT).exists());
        assert_eq!(before, bytes_tree(&history));
    }
}
