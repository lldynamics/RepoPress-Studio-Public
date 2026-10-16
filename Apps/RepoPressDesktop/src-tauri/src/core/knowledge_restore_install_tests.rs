use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_backup::KnowledgeBackupStore,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
    knowledge_package_stage::KnowledgePackageStageStore,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    os::unix::fs::{symlink, PermissionsExt},
    path::{Path, PathBuf},
};

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
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&export, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
        KnowledgeLibraryStore::new(root.clone())
            .unwrap()
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Web,
                    title: "install fixture title".into(),
                    source_name: "install fixture source".into(),
                    source_url: Some("https://private.example/install".into()),
                    text: "install fixture body".into(),
                    allows_local_semantic_index: true,
                    allows_remote_ai_use: true,
                },
                Some(&BrowserCaptureArchive {
                    format: "html".into(),
                    bytes: b"<html>install</html>".to_vec(),
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

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn add_candidate_item(candidate: &Path, id: &str) {
    let path = candidate.join("knowledge-v1/manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let mut item = manifest["items"][0].clone();
    item["summary"]["itemId"] = json!(id);
    item["summary"]["allowsRemoteAiUse"] = json!(true);
    item["summary"]["allowsLocalSemanticIndex"] = json!(true);
    manifest["items"].as_array_mut().unwrap().push(item);
    let bytes = serde_json::to_vec(&manifest).unwrap();
    fs::write(&path, &bytes).unwrap();
    let marker = candidate.join("candidate.json");
    let mut marker_value: Value = serde_json::from_slice(&fs::read(&marker).unwrap()).unwrap();
    marker_value["manifestSha256"] = json!(hash(&bytes));
    fs::write(marker, serde_json::to_vec(&marker_value).unwrap()).unwrap();
}

#[test]
fn install_adds_new_item_resets_permissions_and_retains_private_rollback_snapshot() {
    let f = Fixture::new();
    add_candidate_item(&f.candidate, "11111111-1111-4111-8111-111111111111");
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let value = serde_json::to_value(&plan).unwrap();
    assert_eq!(value["writesCurrentLibrary"], true);
    assert_eq!(value["preservesRollbackSnapshot"], true);
    assert_eq!(value["importedPermissionsDisabled"], true);
    assert!(store.execute(&plan.plan_id, false).is_err());
    assert!(
        store.execute(&plan.plan_id, true).is_err(),
        "consent refusal consumes the one-shot plan"
    );
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(store.execute(&plan.plan_id, true).is_ok());
    let diagnosis = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert!(matches!(
        diagnosis["state"].as_str(),
        Some("committed") | Some("installed")
    ));
    assert!(f.root.join("knowledge-v1/manifest.json").is_file());
    assert_eq!(diagnosis["snapshotRetained"], true);
    let manifest: Value =
        serde_json::from_slice(&fs::read(f.root.join("knowledge-v1/manifest.json")).unwrap())
            .unwrap();
    let items = manifest["items"].as_array().unwrap();
    assert!(items
        .iter()
        .any(|item| { item["summary"]["itemId"] == "11111111-1111-4111-8111-111111111111" }));
    let imported = items
        .iter()
        .find(|item| item["summary"]["itemId"] == "11111111-1111-4111-8111-111111111111")
        .unwrap();
    assert_eq!(imported["summary"]["allowsRemoteAiUse"], false);
    assert_eq!(imported["summary"]["allowsLocalSemanticIndex"], false);
    assert_eq!(items[0]["summary"]["allowsRemoteAiUse"], true);
    assert_eq!(items[0]["summary"]["allowsLocalSemanticIndex"], true);
    assert_eq!(items[0]["summary"]["title"], "install fixture title");
    assert!(
        fs::read_dir(f.root.join("knowledge-v1/archives"))
            .unwrap()
            .count()
            >= 1
    );
    assert_eq!(
        fs::metadata(f.root.join("knowledge-v1/manifest.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}

#[test]
fn injection_leaves_durable_journal_and_recovery_can_cancel_or_finalize() {
    let f = Fixture::new();
    add_candidate_item(&f.candidate, "22222222-2222-4222-8222-222222222222");
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let error = store.execute_checked(&plan.plan_id, true, |hook| {
        if hook == 0 {
            return Err(crate::core::CommandError::new("injected", "injected"));
        }
        Ok(())
    });
    assert!(error.is_err());
    let diagnosis = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert_eq!(diagnosis["state"], "preparing");
    let restarted = KnowledgeRestoreInstallStore::new(f.root.clone());
    let restarted_diagnosis = serde_json::to_value(restarted.inspect().unwrap()).unwrap();
    assert_eq!(restarted_diagnosis["state"], "preparing");
    assert_eq!(restarted_diagnosis["libraryAccessBlocked"], true);
    let recovery = store
        .plan_recovery(
            diagnosis["transactionId"].as_str().unwrap(),
            KnowledgeRestoreRecoveryAction::Cancel,
        )
        .unwrap();
    assert!(store.execute_recovery(&recovery.plan_id, true).is_ok());
    assert!(store.execute_recovery(&recovery.plan_id, true).is_err());
    assert_eq!(
        serde_json::to_value(store.inspect().unwrap()).unwrap()["state"],
        "cancelled"
    );
}

#[test]
fn injection_after_intent_is_prepared_and_can_be_cancelled() {
    let f = Fixture::new();
    add_candidate_item(&f.candidate, "44444444-4444-4444-8444-444444444444");
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(store
        .execute_checked(&plan.plan_id, true, |hook| {
            if hook == 1 {
                return Err(crate::core::CommandError::new("injected", "injected"));
            }
            Ok(())
        })
        .is_err());
    let diagnosis = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert_eq!(diagnosis["state"], "prepared");
    let recovery = store
        .plan_recovery(
            diagnosis["transactionId"].as_str().unwrap(),
            KnowledgeRestoreRecoveryAction::Cancel,
        )
        .unwrap();
    assert!(store.execute_recovery(&recovery.plan_id, true).is_ok());
    assert_eq!(
        serde_json::to_value(store.inspect().unwrap()).unwrap()["state"],
        "cancelled"
    );
}

#[test]
fn injection_after_exchange_is_installed_and_can_be_finalized_or_rolled_back() {
    let f = Fixture::new();
    add_candidate_item(&f.candidate, "55555555-5555-4555-8555-555555555555");
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(store
        .execute_checked(&plan.plan_id, true, |hook| {
            if hook == 2 {
                return Err(crate::core::CommandError::new("injected", "injected"));
            }
            Ok(())
        })
        .is_err());
    let diagnosis = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert_eq!(diagnosis["state"], "installed");
    let recovery = store
        .plan_recovery(
            diagnosis["transactionId"].as_str().unwrap(),
            KnowledgeRestoreRecoveryAction::Finalize,
        )
        .unwrap();
    assert!(store.execute_recovery(&recovery.plan_id, true).is_ok());
    assert_eq!(
        serde_json::to_value(store.inspect().unwrap()).unwrap()["state"],
        "committed"
    );
}

#[test]
fn candidate_drift_is_rejected_before_intent_and_consumes_install_plan() {
    let f = Fixture::new();
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    fs::write(f.candidate.join("candidate.json"), b"{}").unwrap();
    assert!(store.execute(&plan.plan_id, true).is_err());
    assert!(store.execute(&plan.plan_id, true).is_err());
}

#[test]
fn post_commit_mutation_is_allowed_but_rollback_rejects_changed_generation() {
    let f = Fixture::new();
    add_candidate_item(&f.candidate, "33333333-3333-4333-8333-333333333333");
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let receipt = store.execute(&plan.plan_id, true).unwrap();
    fs::write(f.root.join("knowledge-v1/manifest.json"), b"{} ").unwrap();
    let changed = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert_eq!(changed["state"], "changed");
    assert_eq!(changed["libraryAccessBlocked"], false);
    assert!(store
        .plan_recovery(
            &receipt.transaction_id,
            KnowledgeRestoreRecoveryAction::Rollback
        )
        .is_err());
}

#[test]
fn committed_install_can_be_rolled_back_and_restores_previous_manifest() {
    let f = Fixture::new();
    add_candidate_item(&f.candidate, "66666666-6666-4666-8666-666666666666");
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let receipt = store.execute(&plan.plan_id, true).unwrap();
    let recovery = store
        .plan_recovery(
            &receipt.transaction_id,
            KnowledgeRestoreRecoveryAction::Rollback,
        )
        .unwrap();
    assert!(store.execute_recovery(&recovery.plan_id, true).is_ok());
    let manifest: Value =
        serde_json::from_slice(&fs::read(f.root.join("knowledge-v1/manifest.json")).unwrap())
            .unwrap();
    assert!(!manifest["items"]
        .as_array()
        .unwrap()
        .iter()
        .any(|item| { item["summary"]["itemId"] == "66666666-6666-4666-8666-666666666666" }));
    let diagnosis = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert_eq!(diagnosis["state"], "rolledBack");
    assert_eq!(diagnosis["libraryAccessBlocked"], false);
}

#[test]
fn root_flock_busy_and_unknown_current_entries_fail_before_writes() {
    let f = Fixture::new();
    let before = fs::read(f.root.join("knowledge-v1/manifest.json")).unwrap();
    let _lease = crate::core::knowledge_restore_gate::KnowledgeRootLease::acquire(&f.root).unwrap();
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    assert!(store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
    drop(_lease);
    let extra = f.root.join("knowledge-v1/blobs").join("a".repeat(64));
    fs::write(&extra, b"unreferenced").unwrap();
    fs::set_permissions(&extra, fs::Permissions::from_mode(0o600)).unwrap();
    assert!(store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
    assert_eq!(
        before,
        fs::read(f.root.join("knowledge-v1/manifest.json")).unwrap()
    );
}

#[test]
fn current_symlink_hardlink_and_fifo_entries_are_rejected() {
    for kind in ["symlink", "hardlink", "fifo"] {
        let f = Fixture::new();
        let blobs = f.root.join("knowledge-v1/blobs");
        let extra = blobs.join("b".repeat(64));
        match kind {
            "symlink" => symlink("missing-target", &extra).unwrap(),
            "hardlink" => {
                let existing = fs::read_dir(&blobs)
                    .unwrap()
                    .next()
                    .unwrap()
                    .unwrap()
                    .path();
                fs::hard_link(existing, &extra).unwrap();
            }
            "fifo" => {
                let path = std::ffi::CString::new(extra.to_str().unwrap()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
            }
            _ => unreachable!(),
        }
        let store = KnowledgeRestoreInstallStore::new(f.root.clone());
        assert!(
            store
                .plan(
                    &f.candidate,
                    KnowledgeRestoreStrategy::KeepCurrentIdentities
                )
                .is_err(),
            "{kind} current entry must fail closed"
        );
    }
}

#[test]
fn cached_library_refreshes_after_install_and_allows_a_second_ordinary_mutation() {
    let f = Fixture::new();
    let cached = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    add_candidate_item(&f.candidate, "77777777-7777-4777-8777-777777777777");
    let restore = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = restore
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    restore.execute(&plan.plan_id, true).unwrap();
    let listed = cached.list(100).unwrap();
    assert!(listed
        .items
        .iter()
        .any(|item| item.item_id == "77777777-7777-4777-8777-777777777777"));
    cached
        .import(KnowledgeImportRequest {
            source_kind: KnowledgeSourceKind::Text,
            title: "post install mutation".into(),
            source_name: "ordinary mutation".into(),
            source_url: None,
            text: "post install body".into(),
            allows_local_semantic_index: false,
            allows_remote_ai_use: false,
        })
        .unwrap();
    let fresh = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    assert_eq!(fresh.list(100).unwrap().items.len(), listed.items.len() + 1);
}

#[test]
fn root_replacement_and_non_private_knowledge_directories_fail_closed() {
    let f = Fixture::new();
    let cached = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    let restore = KnowledgeRestoreInstallStore::new(f.root.clone());
    let moved = f.root.with_extension("moved");
    fs::rename(&f.root, &moved).unwrap();
    fs::create_dir(&f.root).unwrap();
    fs::set_permissions(&f.root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::rename(moved.join("knowledge-v1"), f.root.join("knowledge-v1")).unwrap();
    assert!(cached.list(100).is_err());
    let diagnosis = serde_json::to_value(restore.inspect().unwrap()).unwrap();
    assert_eq!(diagnosis["state"], "unavailable");

    let active = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    fs::set_permissions(
        f.root.join("knowledge-v1"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    assert!(active.list(100).is_err());
    assert!(KnowledgeLibraryStore::new(f.root.clone()).is_err());
    assert_eq!(
        fs::metadata(f.root.join("knowledge-v1"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o755
    );
    fs::set_permissions(
        f.root.join("knowledge-v1"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    fs::set_permissions(
        f.root.join("knowledge-v1/blobs"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    assert!(active.list(100).is_err());
    assert!(KnowledgeLibraryStore::new(f.root.clone()).is_err());
    fs::set_permissions(
        f.root.join("knowledge-v1/blobs"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    fs::set_permissions(
        f.root.join("knowledge-v1/archives"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    assert!(active.list(100).is_err());
    assert!(KnowledgeLibraryStore::new(f.root.clone()).is_err());
}

#[test]
fn install_capacity_expiry_and_same_byte_inode_replacement_never_write_intent() {
    let f = Fixture::new();
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let a = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let b = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
    store.discard(&a.plan_id).unwrap();
    {
        let mut plans = store.plans.lock().unwrap();
        let Pending::Install { stored, .. } = plans.get_mut(&b.plan_id).unwrap() else {
            panic!()
        };
        stored.observation.created = Instant::now() - TTL;
    }
    assert!(store.execute(&b.plan_id, true).is_err());
    assert!(store.execute(&b.plan_id, true).is_err());
    assert!(!f.root.join(JOURNAL).exists());
    for path in [
        f.candidate.join("knowledge-v1/manifest.json"),
        f.root.join("knowledge-v1/manifest.json"),
    ] {
        let plan = store
            .plan(
                &f.candidate,
                KnowledgeRestoreStrategy::KeepCurrentIdentities,
            )
            .unwrap();
        let bytes = fs::read(&path).unwrap();
        let other = path.with_extension("replacement");
        fs::write(&other, &bytes).unwrap();
        fs::set_permissions(&other, fs::Permissions::from_mode(0o600)).unwrap();
        fs::rename(&other, &path).unwrap();
        assert!(store.execute(&plan.plan_id, true).is_err());
        assert!(!f.root.join(JOURNAL).exists());
    }
}
#[test]
fn invalid_journal_restart_blocks_without_initializing_or_garbage_collection() {
    let f = Fixture::new();
    let unreferenced = f.root.join("knowledge-v1/blobs").join("a".repeat(64));
    fs::write(&unreferenced, b"must remain while restore state is unknown").unwrap();
    fs::set_permissions(&unreferenced, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(f.root.join(JOURNAL), b"{ invalid intent").unwrap();
    fs::set_permissions(f.root.join(JOURNAL), fs::Permissions::from_mode(0o600)).unwrap();
    let library = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    assert!(library.status().is_err());
    assert!(library.list(100).is_err());
    assert_eq!(
        fs::read(&unreferenced).unwrap(),
        b"must remain while restore state is unknown"
    );
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    assert_eq!(store.inspect().unwrap().state, "invalid");
    assert!(store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
}
#[test]
fn recovery_consent_expiry_and_replay_consume_only_memory_plan() {
    let f = Fixture::new();
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let install = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(store
        .execute_checked(&install.plan_id, true, |stage| if stage == 1 {
            Err(invalid())
        } else {
            Ok(())
        })
        .is_err());
    let diagnosis = store.inspect().unwrap();
    let id = diagnosis.transaction_id.unwrap();
    let cancelled = store
        .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Cancel)
        .unwrap();
    assert!(store.execute_recovery(&cancelled.plan_id, false).is_err());
    assert!(store.execute_recovery(&cancelled.plan_id, true).is_err());
    let expired = store
        .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Cancel)
        .unwrap();
    {
        let mut plans = store.plans.lock().unwrap();
        let Pending::Recovery { expires, .. } = plans.get_mut(&expired.plan_id).unwrap() else {
            panic!()
        };
        *expires = now().unwrap() - 1;
    }
    assert!(store.execute_recovery(&expired.plan_id, true).is_err());
    assert_eq!(store.inspect().unwrap().state, "prepared");
    let fresh = store
        .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Cancel)
        .unwrap();
    assert!(
        store
            .execute_recovery(&fresh.plan_id, true)
            .unwrap()
            .snapshot_retained
    );
    assert!(store.execute_recovery(&fresh.plan_id, true).is_err());
}

#[test]
fn install_invalidates_export_and_open_requests_and_external_store_updates_reload() {
    let f = Fixture::new();
    let cached = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    let original = cached.list(100).unwrap().items[0].item_id.clone();
    let export_root = f._temp.path().join("repository");
    fs::create_dir(&export_root).unwrap();
    let export = cached
        .plan_export("session", &export_root, &original, "old.md")
        .unwrap();
    let archive = cached
        .plan_archive_export("session", &export_root, &original, "old.html")
        .unwrap();
    cached.request_open(&original).unwrap();
    add_candidate_item(&f.candidate, "88888888-8888-4888-8888-888888888888");
    let store = KnowledgeRestoreInstallStore::new(f.root.clone());
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    store.execute(&plan.plan_id, true).unwrap();
    assert!(cached
        .execute_export("session", &export_root, &export.plan_id)
        .is_err());
    assert!(cached
        .execute_archive_export("session", &export_root, &archive.plan_id)
        .is_err());
    assert_eq!(cached.take_open_request().unwrap(), None);
    assert_eq!(fs::read_dir(&export_root).unwrap().count(), 0);
    let external = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    external
        .import(KnowledgeImportRequest {
            source_kind: KnowledgeSourceKind::Text,
            title: "another store".into(),
            source_name: "test".into(),
            source_url: None,
            text: "another store content".into(),
            allows_local_semantic_index: false,
            allows_remote_ai_use: false,
        })
        .unwrap();
    assert_eq!(cached.list(100).unwrap().items.len(), 3);
    cached.create_folder("after external write").unwrap();
    assert_eq!(external.list_folders().unwrap().len(), 1);
    assert_eq!(external.list(100).unwrap().items.len(), 3);
}
