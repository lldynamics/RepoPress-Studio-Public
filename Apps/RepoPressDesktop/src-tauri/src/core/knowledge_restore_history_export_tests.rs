use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_backup::KnowledgeBackupStore,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
    knowledge_package_check::KnowledgePackageCheckStore,
    knowledge_package_stage::KnowledgePackageStageStore,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    os::unix::{ffi::OsStrExt, fs::PermissionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    candidate: PathBuf,
    export: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("app-data");
        let export = temp.path().join("export");
        let parent = temp.path().join("candidate-parent");
        for p in [&root, &export, &parent] {
            fs::create_dir_all(p).unwrap();
            fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
        }
        KnowledgeLibraryStore::new(root.clone())
            .unwrap()
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Web,
                    title: "history export fixture".into(),
                    source_name: "source".into(),
                    source_url: Some("https://private.example/history".into()),
                    text: "private history body".into(),
                    allows_local_semantic_index: true,
                    allows_remote_ai_use: true,
                },
                Some(&BrowserCaptureArchive {
                    format: "html".into(),
                    bytes: b"<html>private</html>".to_vec(),
                    embedded_resource_count: Some(0),
                    missing_resource_count: Some(0),
                    was_truncated: Some(false),
                }),
            )
            .unwrap();
        let source = export.join("saved.json");
        let backup = KnowledgeBackupStore::new(root.clone());
        let p = backup.plan(&source).unwrap();
        backup.execute(&p.plan_id, true).unwrap();
        let stage = KnowledgePackageStageStore::new(root.clone());
        let p = stage.plan(&source, &parent).unwrap();
        stage.execute(&p.plan_id, true).unwrap();
        Self {
            _temp: temp,
            root,
            candidate: p.candidate_path.into(),
            export,
        }
    }
}

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn tree_bytes(root: &Path) -> Vec<(String, Vec<u8>)> {
    fn visit(root: &Path, path: &Path, out: &mut Vec<(String, Vec<u8>)>) {
        for entry in fs::read_dir(path).unwrap() {
            let entry = entry.unwrap();
            let p = entry.path();
            if p.is_dir() {
                visit(root, &p, out);
            } else {
                out.push((
                    p.strip_prefix(root).unwrap().display().to_string(),
                    fs::read(&p).unwrap(),
                ));
            }
        }
    }
    let mut out = vec![];
    visit(root, root, &mut out);
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn add_candidate_item(candidate: &Path) {
    let path = candidate.join("knowledge-v1/manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let mut item = manifest["items"][0].clone();
    item["summary"]["itemId"] = json!("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee");
    manifest["items"].as_array_mut().unwrap().push(item);
    let bytes = serde_json::to_vec(&manifest).unwrap();
    fs::write(&path, &bytes).unwrap();
    let marker = candidate.join("candidate.json");
    let mut m: Value = serde_json::from_slice(&fs::read(&marker).unwrap()).unwrap();
    m["manifestSha256"] = json!(hash(&bytes));
    fs::write(marker, serde_json::to_vec(&m).unwrap()).unwrap();
}

fn closed_fixture() -> (Fixture, String) {
    let f = Fixture::new();
    add_candidate_item(&f.candidate);
    let install = KnowledgeRestoreInstallStore::new(f.root.clone());
    let p = install
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    install.execute(&p.plan_id, true).unwrap();
    let d: Value = serde_json::to_value(install.inspect().unwrap()).unwrap();
    let id: String = d["transactionId"].as_str().unwrap().into();
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let archive_plan = archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    archive.execute(&archive_plan.plan_id, true).unwrap();
    (f, id)
}

fn journal_only_cancelled_fixture() -> (Fixture, String) {
    let f = Fixture::new();
    let install = KnowledgeRestoreInstallStore::new(f.root.clone());
    let p = install
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert!(install
        .execute_checked(&p.plan_id, true, |hook| {
            if hook == 0 {
                return Err(crate::core::CommandError::new("injected", "injected"));
            }
            Ok(())
        })
        .is_err());
    let d: Value = serde_json::to_value(install.inspect().unwrap()).unwrap();
    let id: String = d["transactionId"].as_str().unwrap().into();
    let recovery = install
        .plan_recovery(&id, KnowledgeRestoreRecoveryAction::Cancel)
        .unwrap();
    install.execute_recovery(&recovery.plan_id, true).unwrap();
    let archive = KnowledgeRestoreArchiveStore::new(f.root.clone());
    let ap = archive
        .plan(&id, KnowledgeRestoreArchiveAction::Archive)
        .unwrap();
    archive.execute(&ap.plan_id, true).unwrap();
    (f, id)
}

#[test]
fn empty_history_export_is_read_only_and_unknown_transactions_are_rejected() {
    let f = Fixture::new();
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let status: Value = serde_json::to_value(store.inspect().unwrap()).unwrap();
    assert_eq!(status["scope"], "knowledgeRestoreHistoryExportStatus");
    assert!(matches!(
        status["state"].as_str(),
        Some("none") | Some("unavailable")
    ));
    assert!(store
        .plan("missing-transaction", &f.export.join("out.json"))
        .is_err());
}

#[test]
fn closed_history_exports_to_private_package_without_mutating_source_or_current_library() {
    let (f, id) = closed_fixture();
    let current_before = fs::read(f.root.join("knowledge-v1/manifest.json")).unwrap();
    let history_before = fs::read_dir(&f.root).unwrap().count();
    let destination = f.export.join("history-export.json");
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let plan = store.plan(&id, &destination).unwrap();
    let planned = serde_json::to_value(&plan).unwrap();
    assert_eq!(planned["requiresSensitivePlaintextConsent"], true);
    assert_eq!(planned["includesCompletedOperations"], false);
    assert_eq!(planned["consistentSnapshot"], false);
    assert!(store.execute(&plan.plan_id, false).is_err());
    assert!(
        store.execute(&plan.plan_id, true).is_err(),
        "consent refusal consumes plan"
    );
    let plan = store.plan(&id, &destination).unwrap();
    let receipt = store.execute(&plan.plan_id, true).unwrap();
    let result: Value = serde_json::to_value(receipt).unwrap();
    assert_eq!(result["sourceRevalidated"], true);
    assert_eq!(result["contentsVerified"], true);
    assert_eq!(result["privatePermissionsVerified"], true);
    assert_eq!(
        fs::read(f.root.join("knowledge-v1/manifest.json")).unwrap(),
        current_before
    );
    assert_eq!(fs::read_dir(&f.root).unwrap().count(), history_before);
    let mode = fs::metadata(&destination).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);

    // Compatibility chain: P47 validation/memory preflight -> P48 candidate -> P52 prepare
    // (with the P49–P51 checks performed inside the candidate preparation flow).
    let check = KnowledgePackageCheckStore::default();
    let report = check.inspect(&destination).unwrap();
    let preflight = check.preflight(&report.report_id).unwrap();
    assert_eq!(
        serde_json::to_value(preflight).unwrap()["restoreReady"],
        false
    );
    let stage_parent = f.export.join("stage-parent");
    fs::create_dir(&stage_parent).unwrap();
    let stage = KnowledgePackageStageStore::new(f.root.clone());
    let stage_plan = stage.plan(&destination, &stage_parent).unwrap();
    stage.execute(&stage_plan.plan_id, true).unwrap();
    let restore = KnowledgeRestoreInstallStore::new(f.root.clone());
    let candidate = PathBuf::from(&stage_plan.candidate_path);
    let restore_plan = restore.plan(&candidate, KnowledgeRestoreStrategy::KeepCurrentIdentities);
    assert!(restore_plan.is_ok());
}

#[test]
fn export_plan_is_single_use_and_rejects_unsafe_destinations() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    for destination in [
        f.root.join("inside.json"),
        f.root.join("existing.json"),
        f.root.join("link.json"),
        f.export.join("wrong.txt"),
    ] {
        assert!(store.plan(&id, &destination).is_err());
    }
    let destination = f.export.join("valid.json");
    let p = store.plan(&id, &destination).unwrap();
    assert!(store.discard(&p.plan_id).is_ok());
    assert!(store.execute(&p.plan_id, true).is_err());
}

#[test]
fn export_preserves_every_private_source_byte_and_plan_capacity_is_two() {
    let (f, id) = closed_fixture();
    let before = tree_bytes(&f.root);
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let mut plans = vec![];
    for n in 0..2 {
        plans.push(
            store
                .plan(&id, &f.export.join(format!("p{n}.json")))
                .unwrap(),
        );
    }
    assert!(store.plan(&id, &f.export.join("p2.json")).is_err());
    store.discard(&plans[0].plan_id).unwrap();
    let p = store.plan(&id, &f.export.join("replacement.json")).unwrap();
    store.discard(&p.plan_id).unwrap();
    assert_eq!(tree_bytes(&f.root), before);
}

#[test]
fn expiry_and_source_drift_consume_plan_before_any_output() {
    let (f, id) = closed_fixture();
    let destination = f.export.join("expired.json");
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let expired = store.plan(&id, &destination).unwrap();
    store
        .plans
        .lock()
        .unwrap()
        .get_mut(&expired.plan_id)
        .unwrap()
        .created -= Duration::from_secs(301);
    assert!(store.execute(&expired.plan_id, true).is_err());
    assert!(!destination.exists());
    let destination = f.export.join("drift.json");
    let plan = store.plan(&id, &destination).unwrap();
    fs::write(f.root.join(history_name(&id)).join(RECORD), b"drift").unwrap();
    assert!(store.execute(&plan.plan_id, true).is_err());
    assert!(!destination.exists());
    assert!(store.execute(&plan.plan_id, true).is_err());
}

#[test]
fn post_package_hook_failure_keeps_private_output_but_consumes_plan() {
    let (f, id) = closed_fixture();
    let destination = f.export.join("hook2.json");
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let plan = store.plan(&id, &destination).unwrap();
    assert!(store
        .execute_checked(&plan.plan_id, true, |hook| {
            if hook == 2 {
                return Err(crate::core::CommandError::new("injected", "injected"));
            }
            Ok(())
        })
        .is_err());
    assert!(destination.exists());
    assert!(store.execute(&plan.plan_id, true).is_err());
}

#[test]
fn destination_existing_symlink_fifo_and_git_ancestor_are_rejected() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let existing = f.export.join("existing.json");
    fs::write(&existing, b"keep").unwrap();
    assert!(store.plan(&id, &existing).is_err());
    let symlink_path = f.export.join("link.json");
    std::os::unix::fs::symlink(&existing, &symlink_path).unwrap();
    assert!(store.plan(&id, &symlink_path).is_err());
    let fifo = f.export.join("fifo.json");
    let fifo_c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
    unsafe {
        libc::mkfifo(fifo_c.as_ptr(), 0o600);
    }
    assert!(store.plan(&id, &fifo).is_err());
    let git = f.export.join("repo/.git");
    fs::create_dir_all(&git).unwrap();
    fs::write(git.join("HEAD"), b"ref: refs/heads/main\n").unwrap();
    assert!(store.plan(&id, &f.export.join("repo/out.json")).is_err());
}

#[test]
fn journal_only_cancelled_history_is_not_exportable() {
    let (f, id) = journal_only_cancelled_fixture();
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    assert!(store.plan(&id, &f.export.join("cancelled.json")).is_err());
}

fn archive_install(f: &Fixture) -> String {
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

#[test]
fn older_closed_snapshot_can_be_exported_and_receipts_are_excluded_without_history_mutation() {
    let f = Fixture::new();
    let path = f.root.join("knowledge-v1/manifest.json");
    let mut m: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    m["completedOperations"] = json!([{
        "operationId":Uuid::new_v4().to_string(),"fingerprint":"b".repeat(64),"completedAtEpochSeconds":1,
        "receipt":{"documentId":Uuid::new_v4().to_string(),"title":"RECEIPT SECRET ONLY","action":"inserted","folderId":null,"fileSizeBytes":1,"archiveType":"none","allowsLocalSemanticIndex":false,"allowsRemoteAiUse":false,"savedAtEpochSeconds":1,"replayed":false}
    }]);
    fs::write(&path, serde_json::to_vec(&m).unwrap()).unwrap();
    add_candidate_item(&f.candidate);
    let older = archive_install(&f);
    let latest = archive_install(&f);
    assert_ne!(older, latest);
    let before = tree_bytes(&f.root);
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let p = store.plan(&older, &f.export.join("older.json")).unwrap();
    assert_ne!(p.manifest_sha256, p.source_manifest_sha256);
    let r = store.execute(&p.plan_id, true).unwrap();
    assert_eq!(r.selected.transaction_id, older);
    let bytes = fs::read(f.export.join("older.json")).unwrap();
    let package: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(package["manifest"]["completedOperations"], json!([]));
    assert!(!String::from_utf8(bytes.clone())
        .unwrap()
        .contains("RECEIPT SECRET ONLY"));
    knowledge_package_check::validate(&bytes, Instant::now()).unwrap();
    assert_eq!(tree_bytes(&f.root), before);
}

#[test]
fn wall_expiry_and_clock_rollback_consume_capabilities_without_output() {
    for rollback in [false, true] {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
        let path = f.export.join("clock.json");
        let p = store.plan(&id, &path).unwrap();
        {
            let mut plans = store.plans.lock().unwrap();
            let p = plans.get_mut(&p.plan_id).unwrap();
            if rollback {
                p.plan.checked_at_epoch_ms += 3600000;
                p.plan.expires_at_epoch_ms += 3600000;
            } else {
                p.plan.expires_at_epoch_ms = now().unwrap() - 1;
            }
        }
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!path.exists());
        assert!(store.execute(&p.plan_id, true).is_err());
    }
}

#[test]
fn root_replacement_and_exclusive_lock_preserve_all_sources_and_consume_plan() {
    for replace in [false, true] {
        let (f, id) = closed_fixture();
        let before = tree_bytes(&f.root);
        let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
        let path = f.export.join("root.json");
        let p = store.plan(&id, &path).unwrap();
        if replace {
            let old = f.root.with_extension("original");
            fs::rename(&f.root, &old).unwrap();
            fs::create_dir(&f.root).unwrap();
            fs::set_permissions(&f.root, fs::Permissions::from_mode(0o700)).unwrap();
            assert!(store.execute(&p.plan_id, true).is_err());
            assert_eq!(tree_bytes(&old), before);
            assert_eq!(store.inspect().unwrap().state, "unavailable");
        } else {
            let lease = KnowledgeRootLease::acquire(&f.root).unwrap();
            assert!(store.execute(&p.plan_id, true).is_err());
            assert_eq!(store.inspect().unwrap().state, "unavailable");
            drop(lease);
            assert_eq!(tree_bytes(&f.root), before);
        }
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!path.exists());
    }
}

#[test]
fn unresolved_restore_and_archive_cleanup_markers_block_read_and_export_without_initialization() {
    for marker in [JOURNAL, INTENT, "knowledge-restore-cleanup-intent.json"] {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
        let output = f.export.join("pending.json");
        let p = store.plan(&id, &output).unwrap();
        fs::write(f.root.join(marker), b"unresolved evidence").unwrap();
        fs::set_permissions(f.root.join(marker), fs::Permissions::from_mode(0o600)).unwrap();
        let before = tree_bytes(&f.root);
        let status = store.inspect().unwrap();
        assert_eq!(status.state, "blocked");
        assert!(status.library_access_blocked);
        assert!(store.plan(&id, &output).is_err());
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!output.exists());
        assert_eq!(tree_bytes(&f.root), before);
    }
}

#[test]
fn prefix_and_selected_resource_drift_cannot_publish_a_package() {
    for prefix in [false, true] {
        let (f, older) = closed_fixture();
        let latest = archive_install(&f);
        let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
        let output = f.export.join("source.json");
        let p = store.plan(&latest, &output).unwrap();
        if prefix {
            fs::rename(
                f.root.join(history_name(&older)),
                f.export.join("moved-history"),
            )
            .unwrap();
        } else {
            let file = fs::read_dir(f.root.join(history_name(&latest)).join("snapshot/blobs"))
                .unwrap()
                .next()
                .unwrap()
                .unwrap()
                .path();
            fs::hard_link(&file, f.export.join("hardlink-body")).unwrap();
        }
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!output.exists());
        assert!(store.execute(&p.plan_id, true).is_err());
    }
}

#[test]
fn changed_parent_and_destination_collision_during_write_are_never_overwritten() {
    for parent_change in [false, true] {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
        let output = f.export.join("conflict.json");
        let p = store.plan(&id, &output).unwrap();
        assert!(store
            .execute_checked(&p.plan_id, true, |h| {
                if parent_change && h == 0 {
                    fs::rename(&f.export, f.export.with_extension("original")).unwrap();
                    fs::create_dir(&f.export).unwrap();
                    fs::set_permissions(&f.export, fs::Permissions::from_mode(0o700)).unwrap();
                } else if !parent_change && h == 1 {
                    fs::write(&output, b"unrelated existing file").unwrap();
                }
                Ok(())
            })
            .is_err());
        if parent_change {
            assert!(!output.exists());
        } else {
            assert_eq!(fs::read(&output).unwrap(), b"unrelated existing file");
        }
        assert!(store.execute(&p.plan_id, true).is_err());
    }
}

#[test]
fn output_byte_inode_permission_and_link_drift_after_publication_are_unconfirmed_and_preserved() {
    for mode in 0..4 {
        let (f, id) = closed_fixture();
        let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
        let output = f.export.join("result.json");
        let p = store.plan(&id, &output).unwrap();
        let e = store
            .execute_checked(&p.plan_id, true, |h| {
                if h == 2 {
                    match mode {
                        0 => fs::write(&output, b"externally changed").unwrap(),
                        1 => {
                            let bytes = fs::read(&output).unwrap();
                            fs::rename(&output, f.export.join("original-output.json")).unwrap();
                            fs::write(&output, bytes).unwrap();
                            fs::set_permissions(&output, fs::Permissions::from_mode(0o600))
                                .unwrap();
                        }
                        2 => {
                            fs::set_permissions(&output, fs::Permissions::from_mode(0o644)).unwrap()
                        }
                        _ => fs::hard_link(&output, f.export.join("output-alias.json")).unwrap(),
                    }
                }
                Ok(())
            })
            .unwrap_err();
        assert_eq!(e.code, "knowledge_restore_history_export_unconfirmed");
        assert!(output.exists());
        assert!(store.execute(&p.plan_id, true).is_err());
    }
}

#[test]
fn source_changed_after_publication_keeps_output_without_a_success_receipt() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let output = f.export.join("late.json");
    let p = store.plan(&id, &output).unwrap();
    assert!(store
        .execute_checked(&p.plan_id, true, |h| {
            if h == 2 {
                fs::write(
                    f.root.join(history_name(&id)).join(RECORD),
                    b"external source drift",
                )
                .unwrap();
            }
            Ok(())
        })
        .is_err());
    assert!(output.exists());
    assert!(store.execute(&p.plan_id, true).is_err());
}

#[test]
fn unrelated_current_library_edits_do_not_change_exported_historical_scope() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let output = f.export.join("edited.json");
    let p = store.plan(&id, &output).unwrap();
    let library = KnowledgeLibraryStore::new(f.root.clone()).unwrap();
    library
        .import(KnowledgeImportRequest {
            source_kind: KnowledgeSourceKind::Text,
            title: "new current item".into(),
            source_name: "current".into(),
            source_url: None,
            text: "new current body".into(),
            allows_local_semantic_index: false,
            allows_remote_ai_use: false,
        })
        .unwrap();
    let current = tree_bytes(&f.root.join("knowledge-v1"));
    store.execute(&p.plan_id, true).unwrap();
    assert_eq!(current, tree_bytes(&f.root.join("knowledge-v1")));
}

#[test]
fn mount_alias_policy_and_package_limits_fail_closed_without_writes() {
    let (f, id) = closed_fixture();
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let lease = store.install.unrestricted_lease().unwrap();
    assert!(output_parent(&lease, &f.root.join("out.json")).is_err());
    assert_ne!(
        mount_id(&lease.file).unwrap(),
        mount_id(&File::open("/proc").unwrap()).unwrap()
    );
    assert!(output_parent(&lease, Path::new("/proc/p55-read-only-check.json")).is_err());
    let many = (0..1025)
        .map(|n| (n.to_string(), Vec::new()))
        .collect::<BTreeMap<_, _>>();
    assert!(knowledge_backup::saved_snapshot_package(b"{}", &many, now().unwrap()).is_err());
    assert!(knowledge_backup::saved_snapshot_package(
        &vec![b' '; 2 * 1024 * 1024 + 1],
        &BTreeMap::new(),
        now().unwrap()
    )
    .is_err());
    let snapshot = f.root.join(history_name(&id)).join(SNAPSHOT);
    let manifest = fs::read(snapshot.join("manifest.json")).unwrap();
    let mut files = BTreeMap::new();
    for kind in ["blobs", "archives"] {
        for entry in fs::read_dir(snapshot.join(kind)).unwrap() {
            let e = entry.unwrap();
            files.insert(
                format!("{}/{}", kind, e.file_name().to_str().unwrap()),
                fs::read(e.path()).unwrap(),
            );
        }
    }
    *files.values_mut().next().unwrap() = vec![b'a'; 32 * 1024 * 1024 + 1];
    assert!(knowledge_backup::saved_snapshot_package(&manifest, &files, now().unwrap()).is_err());
}

#[test]
fn completed_active_restore_and_rollback_evidence_are_retained_while_exporting_an_older_history() {
    let (f, older) = closed_fixture();
    let install = KnowledgeRestoreInstallStore::new(f.root.clone());
    let p = install
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let active = install.execute(&p.plan_id, true).unwrap().transaction_id;
    let before = tree_bytes(&f.root);
    let store = KnowledgeRestoreHistoryExportStore::new(f.root.clone());
    let p = store
        .plan(&older, &f.export.join("with-active.json"))
        .unwrap();
    store.execute(&p.plan_id, true).unwrap();
    assert_eq!(tree_bytes(&f.root), before);
    install
        .plan_recovery(&active, KnowledgeRestoreRecoveryAction::Rollback)
        .unwrap();
}
