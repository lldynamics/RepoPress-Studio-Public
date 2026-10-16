use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_backup::KnowledgeBackupStore,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
    knowledge_package_stage::KnowledgePackageStageStore,
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::PathBuf,
    time::Instant,
};

struct Fixture {
    _temp: tempfile::TempDir,
    app_root: PathBuf,
    candidate: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let app_root = temp.path().join("app-data");
        let export = temp.path().join("export");
        let parent = temp.path().join("candidate-parent");
        fs::create_dir(&app_root).unwrap();
        fs::create_dir(&export).unwrap();
        fs::create_dir(&parent).unwrap();
        for path in [&app_root, &export, &parent] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let library = KnowledgeLibraryStore::new(app_root.clone()).unwrap();
        library
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Web,
                    title: "candidate check title".into(),
                    source_name: "candidate check source".into(),
                    source_url: Some("https://private.example/source".into()),
                    text: "candidate check body".into(),
                    allows_local_semantic_index: false,
                    allows_remote_ai_use: false,
                },
                Some(&BrowserCaptureArchive {
                    format: "html".into(),
                    bytes: b"<html>candidate</html>".to_vec(),
                    embedded_resource_count: Some(0),
                    missing_resource_count: Some(0),
                    was_truncated: Some(false),
                }),
            )
            .unwrap();
        let source = export.join("package.json");
        let backup = KnowledgeBackupStore::new(app_root.clone());
        let backup_plan = backup.plan(&source).unwrap();
        backup.execute(&backup_plan.plan_id, true).unwrap();
        let stage = KnowledgePackageStageStore::new(app_root.clone());
        let stage_plan = stage.plan(&source, &parent).unwrap();
        stage.execute(&stage_plan.plan_id, true).unwrap();
        Self {
            _temp: temp,
            app_root,
            candidate: stage_plan.candidate_path.into(),
        }
    }
}

fn report_id<T: serde::Serialize>(report: &T) -> String {
    serde_json::to_value(report).unwrap()["reportId"]
        .as_str()
        .unwrap()
        .into()
}

fn tree_snapshot(root: &std::path::Path) -> BTreeMap<String, (Vec<u8>, u32)> {
    fn walk(
        root: &std::path::Path,
        path: &std::path::Path,
        out: &mut BTreeMap<String, (Vec<u8>, u32)>,
    ) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            let relative = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            let metadata = fs::symlink_metadata(&path).unwrap();
            if metadata.is_dir() {
                walk(root, &path, out);
            } else {
                out.insert(
                    relative,
                    (fs::read(&path).unwrap(), metadata.mode() & 0o777),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

fn candidate_inventory(root: &std::path::Path) -> (usize, usize, String) {
    let files = tree_snapshot(root);
    let byte_size = files.values().map(|(bytes, _)| bytes.len()).sum();
    let entries: Vec<_> = files
        .iter()
        .map(|(path, (bytes, _))| json!({"path": path, "byteSize": bytes.len(), "sha256": hash(bytes)}))
        .collect();
    (
        files.len(),
        byte_size,
        hash(&serde_json::to_vec(&entries).unwrap()),
    )
}

fn first_resource(candidate: &std::path::Path) -> PathBuf {
    fs::read_dir(candidate.join("knowledge-v1/blobs"))
        .unwrap()
        .next()
        .or_else(|| {
            fs::read_dir(candidate.join("knowledge-v1/archives"))
                .unwrap()
                .next()
        })
        .map(|entry| entry.unwrap().path())
        .unwrap()
}

#[test]
fn inspect_and_recheck_are_read_only_and_report_omits_saved_content() {
    let f = Fixture::new();
    let before_current = tree_snapshot(&f.app_root);
    let before_candidate = tree_snapshot(&f.candidate);
    let store = KnowledgeCandidateCheckStore::new(f.app_root.clone());
    let report = store.inspect(&f.candidate).unwrap();
    let value = serde_json::to_value(&report).unwrap();
    assert_eq!(value["candidateStructureVerified"], json!(true));
    assert_eq!(value["candidateContentsVerified"], json!(true));
    assert_eq!(value["privatePermissionsVerified"], json!(true));
    assert_eq!(value["filesystemWrites"], json!(false));
    assert_eq!(value["currentLibraryChanged"], json!(false));
    assert_eq!(value["conflicts"]["identicalItems"], json!(1));
    assert_eq!(value["conflicts"]["changedItems"], json!(0));
    for key in [
        "sourcePackageHashVerified",
        "candidateAuthenticityVerified",
        "currentLibraryResourcesVerified",
        "restoreReady",
    ] {
        assert_eq!(value[key], json!(false));
    }
    let text = serde_json::to_string(&report).unwrap();
    assert!(!text.contains("candidate check title"));
    assert!(!text.contains("candidate check body"));
    assert!(!text.contains("private.example"));
    let (file_count, byte_size, inventory) = candidate_inventory(&f.candidate);
    assert_eq!(value["candidateFileCount"], json!(file_count));
    assert_eq!(value["candidateByteSize"], json!(byte_size));
    assert_eq!(value["candidateInventorySha256"], json!(inventory));
    let checked = store.recheck(&report_id(&report)).unwrap();
    assert_eq!(
        serde_json::to_value(&checked).unwrap()["comparison"],
        json!("unchanged")
    );
    assert_eq!(before_current, tree_snapshot(&f.app_root));
    assert_eq!(before_candidate, tree_snapshot(&f.candidate));
    assert!(f.candidate.join("candidate.json").is_file());
}

#[test]
fn current_manifest_change_is_reported_without_candidate_or_library_mutation() {
    let f = Fixture::new();
    let store = KnowledgeCandidateCheckStore::new(f.app_root.clone());
    let report = store.inspect(&f.candidate).unwrap();
    let candidate_manifest_before =
        fs::read(f.candidate.join("knowledge-v1/manifest.json")).unwrap();
    let original = fs::read(f.app_root.join("knowledge-v1/manifest.json")).unwrap();
    let mut manifest: serde_json::Value = serde_json::from_slice(&original).unwrap();
    manifest["items"][0]["summary"]["title"] = json!("changed locally");
    fs::write(
        f.app_root.join("knowledge-v1/manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    let checked = store.recheck(&report_id(&report)).unwrap();
    assert_eq!(
        serde_json::to_value(&checked).unwrap()["comparison"],
        json!("changed")
    );
    assert_eq!(
        serde_json::to_value(&checked).unwrap()["report"]["conflicts"]["changedItems"],
        json!(1)
    );
    assert_eq!(
        candidate_manifest_before,
        fs::read(f.candidate.join("knowledge-v1/manifest.json")).unwrap()
    );
}

#[test]
fn discard_is_idempotent_and_two_reports_are_the_capacity() {
    let f = Fixture::new();
    let store = KnowledgeCandidateCheckStore::new(f.app_root);
    let first = store.inspect(&f.candidate).unwrap();
    let second = store.inspect(&f.candidate).unwrap();
    assert!(store.inspect(&f.candidate).is_err());
    let first_id = report_id(&first);
    let second_id = report_id(&second);
    store.discard(&first_id).unwrap();
    store.discard(&first_id).unwrap();
    store.discard(&second_id).unwrap();
}

#[test]
fn expired_reports_are_consumed_for_monotonic_and_wall_clock_expiry() {
    for clock in ["monotonic", "wall"] {
        let f = Fixture::new();
        let store = KnowledgeCandidateCheckStore::new(f.app_root);
        let report = store.inspect(&f.candidate).unwrap();
        let id = report_id(&report);
        let mut reports = store.reports.lock().unwrap();
        let stored = reports.get_mut(&id).unwrap();
        if clock == "monotonic" {
            stored.created = Instant::now() - TTL;
        } else {
            stored.expires = now().unwrap();
        }
        drop(reports);
        assert!(store.recheck(&id).is_err(), "{clock} expiry must reject");
        assert!(
            store.recheck(&id).is_err(),
            "{clock} expiry must consume report"
        );
    }
}

#[test]
fn duplicate_json_and_resource_closure_errors_leave_candidate_untouched() {
    let f = Fixture::new();
    let marker = f.candidate.join("candidate.json");
    let original_marker = fs::read_to_string(&marker).unwrap();
    let duplicate_marker = original_marker.replacen(
        "\"format\":\"repopress-knowledge-isolated-candidate\"",
        "\"format\":\"repopress-knowledge-isolated-candidate\",\"format\":\"repopress-knowledge-isolated-candidate\"",
        1,
    );
    fs::write(&marker, duplicate_marker).unwrap();
    assert!(KnowledgeCandidateCheckStore::new(f.app_root.clone())
        .inspect(&f.candidate)
        .is_err());

    let f = Fixture::new();
    let manifest = f.candidate.join("knowledge-v1/manifest.json");
    let original_manifest = fs::read_to_string(&manifest).unwrap();
    let duplicate_manifest = original_manifest.replacen(
        "\"summary\":{",
        "\"summary\":{\"summary\":{},\"summary\":{} ,",
        1,
    );
    fs::write(&manifest, duplicate_manifest).unwrap();
    assert!(KnowledgeCandidateCheckStore::new(f.app_root.clone())
        .inspect(&f.candidate)
        .is_err());

    for operation in ["extra", "missing", "corrupt"] {
        let f = Fixture::new();
        let resource = first_resource(&f.candidate);
        match operation {
            "extra" => fs::write(
                f.candidate.join("knowledge-v1/blobs/").join("0".repeat(64)),
                b"extra",
            )
            .unwrap(),
            "missing" => fs::remove_file(&resource).unwrap(),
            "corrupt" => {
                let mut bytes = fs::read(&resource).unwrap();
                bytes[0] ^= 1;
                fs::write(&resource, bytes).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(
            KnowledgeCandidateCheckStore::new(f.app_root)
                .inspect(&f.candidate)
                .is_err(),
            "{operation} resource must fail"
        );
        assert!(f.candidate.exists());
    }
}

#[test]
fn candidate_unknown_marker_and_hook_tampering_fail_without_cleanup() {
    let f = Fixture::new();
    let marker = f.candidate.join("candidate.json");
    let original = fs::read(&marker).unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
    value["unexpected"] = json!(true);
    fs::write(&marker, serde_json::to_vec(&value).unwrap()).unwrap();
    let store = KnowledgeCandidateCheckStore::new(f.app_root);
    assert!(store.inspect(&f.candidate).is_err());
    fs::write(&marker, original).unwrap();
}

#[test]
fn inspect_checked_rejects_candidate_drift_at_each_boundary_and_current_drift_is_inconclusive() {
    for phase in 0..=4u8 {
        let f = Fixture::new();
        let store = KnowledgeCandidateCheckStore::new(f.app_root);
        let manifest = f.candidate.join("knowledge-v1/manifest.json");
        let resource = fs::read_dir(f.candidate.join("knowledge-v1/blobs"))
            .unwrap()
            .next()
            .or_else(|| {
                fs::read_dir(f.candidate.join("knowledge-v1/archives"))
                    .unwrap()
                    .next()
            })
            .map(|e| e.unwrap().path())
            .unwrap();
        let result = store.inspect_checked(&f.candidate, |seen| {
            if seen == phase {
                match phase {
                    0 => fs::remove_file(f.candidate.join("candidate.json")).unwrap(),
                    2 => {
                        let mut bytes = fs::read(&resource).unwrap();
                        bytes[0] ^= 1;
                        fs::write(&resource, bytes).unwrap();
                    }
                    _ => {
                        let mut bytes = fs::read(&manifest).unwrap();
                        bytes[0] ^= 1;
                        fs::write(&manifest, bytes).unwrap();
                    }
                }
            }
        });
        assert!(
            result.is_err(),
            "candidate drift at phase {phase} must fail"
        );
    }

    let f = Fixture::new();
    let store = KnowledgeCandidateCheckStore::new(f.app_root.clone());
    let report = store.inspect(&f.candidate).unwrap();
    let current = f.app_root.join("knowledge-v1/manifest.json");
    let original = fs::read(&current).unwrap();
    let replacement = f.app_root.join("replacement-manifest.json");
    fs::write(&replacement, &original).unwrap();
    fs::set_permissions(&replacement, fs::Permissions::from_mode(0o600)).unwrap();
    fs::rename(&replacement, &current).unwrap();
    let checked = store.recheck(&report_id(&report)).unwrap();
    assert_eq!(
        serde_json::to_value(&checked).unwrap()["comparison"],
        json!("changed")
    );
}

#[test]
fn hook_three_current_drift_is_inconclusive_and_missing_state_stays_missing() {
    let f = Fixture::new();
    let store = KnowledgeCandidateCheckStore::new(f.app_root.clone());
    let current = f.app_root.join("knowledge-v1/manifest.json");
    let report = store
        .inspect_checked(&f.candidate, |phase| {
            if phase == 3 {
                let mut bytes = fs::read(&current).unwrap();
                bytes[0] ^= 1;
                fs::write(&current, bytes).unwrap();
            }
        })
        .unwrap();
    let value = serde_json::to_value(&report).unwrap();
    assert_eq!(value["currentLibrary"]["state"], json!("changed"));
    assert!(value["currentLibrary"]["manifestSha256"].is_null());
    assert!(value["currentLibrary"]["itemCount"].is_null());
    assert!(value["conflicts"].is_null());
    let checked = store.recheck(&report_id(&report)).unwrap();
    assert_eq!(
        serde_json::to_value(checked).unwrap()["comparison"],
        json!("inconclusive")
    );

    let f = Fixture::new();
    let current = f.app_root.join("knowledge-v1");
    fs::rename(&current, f.app_root.join("knowledge-v1-missing")).unwrap();
    let store = KnowledgeCandidateCheckStore::new(f.app_root.clone());
    let report = store.inspect(&f.candidate).unwrap();
    let checked = store.recheck(&report_id(&report)).unwrap();
    let value = serde_json::to_value(checked).unwrap();
    assert_eq!(value["comparison"], json!("inconclusive"));
    assert_eq!(value["report"]["currentLibrary"]["state"], json!("missing"));
    assert!(
        !current.exists(),
        "check must not initialize missing current library"
    );
}

#[test]
fn current_resource_removal_keeps_manifest_comparison_and_marks_resources_unverified() {
    let f = Fixture::new();
    let resource = f.app_root.join("knowledge-v1/blobs");
    let resource = fs::read_dir(resource)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    fs::remove_file(resource).unwrap();
    let value = serde_json::to_value(
        KnowledgeCandidateCheckStore::new(f.app_root)
            .inspect(&f.candidate)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(value["currentLibrary"]["state"], json!("checked"));
    assert_eq!(value["currentLibraryResourcesVerified"], json!(false));
}

#[test]
fn missing_unsafe_and_invalid_current_library_are_inconclusive_with_null_conflicts() {
    let f = Fixture::new();
    let current = f.app_root.join("knowledge-v1");
    fs::rename(&current, f.app_root.join("knowledge-v1-missing")).unwrap();
    let report = KnowledgeCandidateCheckStore::new(f.app_root.clone())
        .inspect(&f.candidate)
        .unwrap();
    let value = serde_json::to_value(report).unwrap();
    assert_eq!(value["currentLibrary"]["state"], json!("missing"));
    assert!(value["conflicts"].is_null());
    assert!(value["currentLibrary"]["manifestSha256"].is_null());
    fs::rename(f.app_root.join("knowledge-v1-missing"), &current).unwrap();

    let f = Fixture::new();
    fs::set_permissions(
        f.app_root.join("knowledge-v1"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let value = serde_json::to_value(
        KnowledgeCandidateCheckStore::new(f.app_root)
            .inspect(&f.candidate)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(value["currentLibrary"]["state"], json!("unsafe"));
    assert!(value["conflicts"].is_null());

    let f = Fixture::new();
    fs::write(f.app_root.join("knowledge-v1/manifest.json"), b"{}\n").unwrap();
    let value = serde_json::to_value(
        KnowledgeCandidateCheckStore::new(f.app_root)
            .inspect(&f.candidate)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(value["currentLibrary"]["state"], json!("invalid"));
    assert!(value["conflicts"].is_null());
}

#[test]
fn candidate_alias_symlink_hardlink_and_fifo_are_rejected() {
    let f = Fixture::new();
    let alias = f.candidate.parent().unwrap().join("alias");
    std::os::unix::fs::symlink(&f.candidate, &alias).unwrap();
    let store = KnowledgeCandidateCheckStore::new(f.app_root.clone());
    assert!(store.inspect(&alias).is_err());

    let f = Fixture::new();
    let marker = f.candidate.join("candidate.json");
    let saved = f.candidate.parent().unwrap().join("marker-copy");
    fs::rename(&marker, &saved).unwrap();
    fs::hard_link(&saved, &marker).unwrap();
    assert!(KnowledgeCandidateCheckStore::new(f.app_root.clone())
        .inspect(&f.candidate)
        .is_err());

    let f = Fixture::new();
    let marker = f.candidate.join("candidate.json");
    fs::remove_file(&marker).unwrap();
    let name = std::ffi::CString::new(marker.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(KnowledgeCandidateCheckStore::new(f.app_root)
        .inspect(&f.candidate)
        .is_err());

    let f = Fixture::new();
    let parent = f.candidate.parent().unwrap();
    let alias_parent = parent.parent().unwrap().join("candidate-parent-link");
    std::os::unix::fs::symlink(parent, &alias_parent).unwrap();
    let aliased = alias_parent.join(f.candidate.file_name().unwrap());
    assert!(KnowledgeCandidateCheckStore::new(f.app_root)
        .inspect(&aliased)
        .is_err());
}

#[test]
fn valid_manifests_partition_items_and_folders_without_choosing_a_restore_policy() {
    let f = Fixture::new();
    let library = KnowledgeLibraryStore::new(f.app_root.clone()).unwrap();
    library.create_folder("Shared folder").unwrap();
    library.create_folder("Same folder").unwrap();
    library.create_folder("Current only folder").unwrap();
    let current_path = f.app_root.join("knowledge-v1/manifest.json");
    let candidate_path = f.candidate.join("knowledge-v1/manifest.json");
    let mut current: Value = serde_json::from_slice(&fs::read(&current_path).unwrap()).unwrap();
    let mut candidate: Value = serde_json::from_slice(&fs::read(&candidate_path).unwrap()).unwrap();
    let original = current["items"][0].clone();
    let changed_id = Uuid::new_v4().to_string();
    let mut current_changed = original.clone();
    current_changed["summary"]["itemId"] = json!(changed_id);
    current_changed["summary"]["title"] = json!("Current changed metadata");
    let mut candidate_changed = current_changed.clone();
    candidate_changed["summary"]["title"] = json!("Candidate changed metadata");
    let mut current_only = original.clone();
    current_only["summary"]["itemId"] = json!(Uuid::new_v4().to_string());
    let mut candidate_only = original.clone();
    candidate_only["summary"]["itemId"] = json!(Uuid::new_v4().to_string());
    current["items"] = json!([original.clone(), current_changed, current_only]);
    candidate["items"] = json!([original, candidate_changed, candidate_only]);

    let folders = current["folders"].as_array().unwrap();
    let folder = |name: &str| folders.iter().find(|f| f["name"] == name).unwrap().clone();
    let mut changed_folder = folder("Shared folder");
    changed_folder["name"] = json!("Candidate changed folder");
    let mut candidate_only_folder = folder("Current only folder");
    candidate_only_folder["folderId"] = json!(Uuid::new_v4().to_string());
    candidate_only_folder["name"] = json!("Candidate only folder");
    candidate["folders"] = json!([changed_folder, folder("Same folder"), candidate_only_folder]);
    fs::write(&current_path, serde_json::to_vec(&current).unwrap()).unwrap();
    let candidate_bytes = serde_json::to_vec(&candidate).unwrap();
    fs::write(&candidate_path, &candidate_bytes).unwrap();
    let marker_path = f.candidate.join("candidate.json");
    let mut marker: Value = serde_json::from_slice(&fs::read(&marker_path).unwrap()).unwrap();
    marker["manifestSha256"] = json!(hash(&candidate_bytes));
    fs::write(marker_path, serde_json::to_vec(&marker).unwrap()).unwrap();

    let before_candidate = tree_snapshot(&f.candidate);
    let before_current = tree_snapshot(&f.app_root);
    let store = KnowledgeCandidateCheckStore::new(f.app_root.clone());
    let report = serde_json::to_value(store.inspect(&f.candidate).unwrap()).unwrap();
    assert_eq!(report["currentLibrary"]["state"], "checked");
    for key in [
        "candidateOnlyItems",
        "currentOnlyItems",
        "identicalItems",
        "changedItems",
        "candidateOnlyFolders",
        "currentOnlyFolders",
        "identicalFolders",
        "changedFolders",
    ] {
        assert_eq!(report["conflicts"][key], 1, "{key}");
    }
    assert_eq!(report["itemCount"], 3);
    assert_eq!(report["folderCount"], 3);
    assert_eq!(report["currentLibrary"]["itemCount"], 3);
    assert_eq!(report["currentLibrary"]["folderCount"], 3);
    assert_eq!(report["restoreReady"], false);
    assert_eq!(report["candidateAuthenticityVerified"], false);
    assert_eq!(before_candidate, tree_snapshot(&f.candidate));
    assert_eq!(before_current, tree_snapshot(&f.app_root));
}
