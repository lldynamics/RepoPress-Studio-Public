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
    collections::BTreeMap,
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{Duration, Instant},
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
        for path in [&app_root, &export, &parent] {
            fs::create_dir(path).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let library = KnowledgeLibraryStore::new(app_root.clone()).unwrap();
        library
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Web,
                    title: "qualification fixture title".into(),
                    source_name: "qualification fixture source".into(),
                    source_url: Some("https://private.example/qualification".into()),
                    text: "qualification fixture body".into(),
                    allows_local_semantic_index: false,
                    allows_remote_ai_use: false,
                },
                Some(&BrowserCaptureArchive {
                    format: "html".into(),
                    bytes: b"<html>qualification</html>".to_vec(),
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

fn snapshot(root: &Path) -> BTreeMap<String, (Vec<u8>, u32, u64)> {
    fn walk(root: &Path, path: &Path, out: &mut BTreeMap<String, (Vec<u8>, u32, u64)>) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            let rel = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                walk(root, &path, out);
            } else {
                out.insert(
                    rel,
                    (fs::read(&path).unwrap(), meta.mode() & 0o777, meta.ino()),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

fn plan(
    store: &KnowledgeRestoreQualificationStore,
    f: &Fixture,
) -> KnowledgeRestoreQualificationPlan {
    store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap()
}

fn resource(root: &Path) -> PathBuf {
    for dir in [
        root.join("knowledge-v1/blobs"),
        root.join("knowledge-v1/archives"),
    ] {
        if let Some(entry) = fs::read_dir(dir).unwrap().next() {
            return entry.unwrap().path();
        }
    }
    panic!("fixture has no resource")
}

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn resource_inventory(root: &Path) -> (usize, usize, String) {
    let mut entries = Vec::new();
    for (kind, dir) in [
        ("blobs", root.join("knowledge-v1/blobs")),
        ("archives", root.join("knowledge-v1/archives")),
    ] {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let bytes = fs::read(&path).unwrap();
            entries.push(json!({"path": format!("{kind}/{}", path.file_name().unwrap().to_string_lossy()), "byteSize": bytes.len(), "sha256": hash(&bytes)}));
        }
    }
    entries.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    let byte_size = entries
        .iter()
        .map(|e| e["byteSize"].as_u64().unwrap() as usize)
        .sum();
    (
        entries.len(),
        byte_size,
        hash(&serde_json::to_vec(&entries).unwrap()),
    )
}

fn mark_archive_incomplete(value: &mut Value) {
    match value {
        Value::Object(map) => {
            if map.contains_key("wasTruncated") {
                map.insert("wasTruncated".into(), json!(true));
            }
            if map.contains_key("missingResourceCount") {
                map.insert("missingResourceCount".into(), json!(1));
            }
            for child in map.values_mut() {
                mark_archive_incomplete(child);
            }
        }
        Value::Array(values) => {
            for child in values {
                mark_archive_incomplete(child);
            }
        }
        _ => {}
    }
}

fn assert_blocked(plan: &KnowledgeRestoreQualificationPlan, reason: &str) {
    let value = serde_json::to_value(plan).unwrap();
    assert_eq!(value["qualification"]["state"], "blocked");
    assert_eq!(value["qualification"]["reason"], reason);
    for key in [
        "addItems",
        "retainItems",
        "skipCandidateItems",
        "addFolders",
        "retainFolders",
        "skipCandidateFolders",
    ] {
        assert_eq!(value["qualification"][key], Value::Null, "{key}");
    }
    if reason != "identityConflicts" {
        assert_eq!(value["currentResources"]["inventorySha256"], Value::Null);
    }
    assert_eq!(value["restoreReady"], false);
    assert_eq!(value["filesystemWrites"], false);
}

#[test]
fn knowledge_restore_qualification_valid_plan_reports_real_resource_inventory_and_stays_private_and_read_only(
) {
    let f = Fixture::new();
    let before_current = snapshot(&f.app_root);
    let before_candidate = snapshot(&f.candidate);
    let store = KnowledgeRestoreQualificationStore::new(f.app_root.clone());
    let p = plan(&store, &f);
    let value = serde_json::to_value(&p).unwrap();
    let expected = resource_inventory(&f.app_root);
    assert_eq!(value["currentResources"]["state"], "checked");
    assert_eq!(value["currentResources"]["fileCount"], json!(expected.0));
    assert_eq!(value["currentResources"]["byteSize"], json!(expected.1));
    assert_eq!(
        value["currentResources"]["inventorySha256"],
        json!(expected.2)
    );
    assert_eq!(
        value["currentResources"]["unreferencedFilesVerified"],
        false
    );
    assert_eq!(
        value["currentResources"]["externalReferencesVerified"],
        false
    );
    assert_eq!(value["candidatePermissionsApplied"], false);
    assert_eq!(value["projectedManifestValidated"], false);
    assert_eq!(value["consistentSnapshot"], false);
    assert_eq!(value["filesystemWrites"], false);
    let text = serde_json::to_string(&p).unwrap();
    assert!(!text.contains("qualification fixture title"));
    assert!(!text.contains("qualification fixture body"));
    assert!(!text.contains("private.example"));
    assert_eq!(before_current, snapshot(&f.app_root));
    assert_eq!(before_candidate, snapshot(&f.candidate));
    for path in [
        &f.candidate,
        &f.candidate.join("knowledge-v1"),
        &f.candidate.join("knowledge-v1/blobs"),
        &f.candidate.join("knowledge-v1/archives"),
    ] {
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }
    for entry in fs::read_dir(f.candidate.join("knowledge-v1/blobs"))
        .unwrap()
        .chain(fs::read_dir(f.candidate.join("knowledge-v1/archives")).unwrap())
    {
        assert_eq!(
            fs::metadata(entry.unwrap().path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

#[test]
fn knowledge_restore_qualification_current_resource_failures_and_incomplete_archive_block_with_null_evidence(
) {
    for operation in [
        "missing",
        "malformed",
        "hardlink",
        "symlink",
        "fifo",
        "permissions",
        "archive",
    ] {
        let f = Fixture::new();
        let target = resource(&f.app_root);
        match operation {
            "missing" => fs::remove_file(&target).unwrap(),
            "malformed" => fs::write(&target, b"malformed resource").unwrap(),
            "hardlink" => {
                let copy = target.with_extension("hardlink");
                fs::hard_link(&target, copy).unwrap();
            }
            "symlink" => {
                let bytes = fs::read(&target).unwrap();
                fs::remove_file(&target).unwrap();
                let real = target.with_extension("real");
                fs::write(&real, bytes).unwrap();
                std::os::unix::fs::symlink(&real, &target).unwrap();
            }
            "fifo" => {
                fs::remove_file(&target).unwrap();
                std::process::Command::new("mkfifo")
                    .arg(&target)
                    .status()
                    .unwrap();
            }
            "permissions" => {
                fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap()
            }
            "archive" => {}
            _ => unreachable!(),
        }
        if operation == "archive" {
            let manifest_path = f.app_root.join("knowledge-v1/manifest.json");
            let mut manifest: Value =
                serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
            mark_archive_incomplete(&mut manifest);
            fs::write(manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        }
        let p = plan(
            &KnowledgeRestoreQualificationStore::new(f.app_root.clone()),
            &f,
        );
        assert_blocked(&p, "currentResourcesUnavailable");
    }
}

#[test]
fn knowledge_restore_qualification_current_missing_or_invalid_manifest_and_invalid_candidate_are_rejected(
) {
    let f = Fixture::new();
    fs::remove_file(f.app_root.join("knowledge-v1/manifest.json")).unwrap();
    let p = plan(
        &KnowledgeRestoreQualificationStore::new(f.app_root.clone()),
        &f,
    );
    assert_blocked(&p, "currentManifestUnavailable");

    let f = Fixture::new();
    fs::write(f.app_root.join("knowledge-v1/manifest.json"), b"{}").unwrap();
    let p = plan(
        &KnowledgeRestoreQualificationStore::new(f.app_root.clone()),
        &f,
    );
    assert_blocked(&p, "currentManifestUnavailable");

    let f = Fixture::new();
    fs::write(
        f.candidate.join("candidate.json"),
        br#"{"format":"invalid"}"#,
    )
    .unwrap();
    assert!(KnowledgeRestoreQualificationStore::new(f.app_root)
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
}

#[test]
fn knowledge_restore_qualification_ignores_unreferenced_regular_and_fifo_files() {
    let f = Fixture::new();
    let blobs = f.app_root.join("knowledge-v1/blobs");
    fs::write(blobs.join("unreferenced"), b"ignored").unwrap();
    let fifo = blobs.join("unreferenced-fifo");
    std::process::Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .unwrap();
    let p = plan(
        &KnowledgeRestoreQualificationStore::new(f.app_root.clone()),
        &f,
    );
    let value = serde_json::to_value(p).unwrap();
    assert_eq!(value["currentResources"]["state"], "checked");
    assert_eq!(
        value["currentResources"]["unreferencedFilesVerified"],
        false
    );
    assert_eq!(
        value["currentResources"]["externalReferencesVerified"],
        false
    );
}

#[test]
fn knowledge_restore_qualification_missing_current_library_does_not_initialize_it() {
    let f = Fixture::new();
    let current = f.app_root.join("knowledge-v1");
    fs::remove_dir_all(&current).unwrap();
    let p = plan(
        &KnowledgeRestoreQualificationStore::new(f.app_root.clone()),
        &f,
    );
    assert_blocked(&p, "currentManifestUnavailable");
    assert!(!current.exists());
}

#[test]
fn knowledge_restore_qualification_recheck_missing_then_fixed_remains_inconclusive() {
    let f = Fixture::new();
    let store = KnowledgeRestoreQualificationStore::new(f.app_root.clone());
    let first = plan(&store, &f);
    let target = resource(&f.app_root);
    let bytes = fs::read(&target).unwrap();
    fs::remove_file(&target).unwrap();
    let missing = store.recheck(&first.plan_id).unwrap();
    assert_eq!(missing.comparison, "inconclusive");
    assert_blocked(&missing.plan, "currentResourcesUnavailable");
    fs::write(&target, bytes).unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
    let fixed = store.recheck(&missing.plan.plan_id).unwrap();
    assert_eq!(fixed.comparison, "inconclusive");
    assert_eq!(
        serde_json::to_value(&fixed.plan).unwrap()["currentResources"]["state"],
        "checked"
    );
}

#[test]
fn knowledge_restore_qualification_both_strategies_preserve_current_only_and_identity_conflicts_block_require_strategy(
) {
    let f = Fixture::new();
    let manifest_path = f.candidate.join("knowledge-v1/manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    manifest["items"][0]["summary"]["title"] = json!("candidate conflict");
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    let mut marker: Value =
        serde_json::from_slice(&fs::read(f.candidate.join("candidate.json")).unwrap()).unwrap();
    marker["manifestSha256"] = json!(hash(&fs::read(&manifest_path).unwrap()));
    fs::write(
        f.candidate.join("candidate.json"),
        serde_json::to_vec(&marker).unwrap(),
    )
    .unwrap();
    for strategy in [
        KnowledgeRestoreStrategy::RequireNoIdentityConflicts,
        KnowledgeRestoreStrategy::KeepCurrentIdentities,
    ] {
        let p = KnowledgeRestoreQualificationStore::new(f.app_root.clone())
            .plan(&f.candidate, strategy)
            .unwrap();
        let value = serde_json::to_value(&p).unwrap();
        assert_eq!(value["currentOnlyPreserved"], true);
        assert_eq!(value["filesystemWrites"], false);
        if matches!(
            strategy,
            KnowledgeRestoreStrategy::RequireNoIdentityConflicts
        ) {
            assert_blocked(&p, "identityConflicts");
        } else {
            assert_eq!(value["qualification"]["state"], "evidenceReady");
            assert!(value["qualification"]["retainItems"].as_u64().unwrap() >= 1);
        }
    }
}

#[test]
fn knowledge_restore_qualification_reports_real_current_only_conflict_counts() {
    let f = Fixture::new();
    let manifest_path = f.app_root.join("knowledge-v1/manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    let mut current_only = manifest["items"][0].clone();
    current_only["summary"]["itemId"] = json!(uuid::Uuid::new_v4().to_string());
    manifest["items"].as_array_mut().unwrap().push(current_only);
    fs::write(manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    let p = plan(
        &KnowledgeRestoreQualificationStore::new(f.app_root.clone()),
        &f,
    );
    let value = serde_json::to_value(&p).unwrap();
    assert_eq!(value["candidate"]["conflicts"]["currentOnlyItems"], 1);
    assert_eq!(value["currentOnlyPreserved"], true);
    assert!(value["qualification"]["retainItems"].as_u64().unwrap() >= 2);
}

#[test]
fn knowledge_restore_qualification_stage_three_and_four_resource_drift_yields_changed_blocked_plan()
{
    for stage in [3u8, 4u8] {
        let f = Fixture::new();
        let current = resource(&f.app_root);
        let store = KnowledgeRestoreQualificationStore::new(f.app_root.clone());
        let result = store.plan_checked(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
            |point| {
                if point == stage {
                    let bytes = fs::read(&current).unwrap();
                    fs::write(&current, [bytes, b"drift".to_vec()].concat()).unwrap();
                }
            },
        );
        let p = result.unwrap();
        assert_eq!(
            serde_json::to_value(&p).unwrap()["currentResources"]["state"],
            "changed"
        );
        assert_blocked(&p, "currentResourcesUnavailable");
    }
}

#[test]
fn knowledge_restore_qualification_recheck_consumes_old_plan_and_detects_same_bytes_inode_replacement_with_two_plan_capacity(
) {
    let f = Fixture::new();
    let store = KnowledgeRestoreQualificationStore::new(f.app_root.clone());
    let first = plan(&store, &f);
    let second = plan(&store, &f);
    assert!(store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
    let old = resource(&f.app_root);
    let bytes = fs::read(&old).unwrap();
    let mode = fs::metadata(&old).unwrap().permissions().mode() & 0o777;
    let replacement = old.with_extension("replacement");
    fs::rename(&old, &replacement).unwrap();
    fs::write(&old, bytes).unwrap();
    fs::set_permissions(&old, fs::Permissions::from_mode(mode)).unwrap();
    let checked = store.recheck(&first.plan_id).unwrap();
    assert_eq!(checked.comparison, "changed");
    assert!(store.recheck(&first.plan_id).is_err());
    store.discard(&second.plan_id).unwrap();
    store.discard(&second.plan_id).unwrap();
}

#[test]
fn knowledge_restore_qualification_monotonic_and_wall_ttl_expiry_are_consuming_and_discard_is_idempotent(
) {
    for wall in [false, true] {
        let f = Fixture::new();
        let store = KnowledgeRestoreQualificationStore::new(f.app_root.clone());
        let p = plan(&store, &f);
        let mut plans = store.plans.lock().unwrap();
        let stored = plans.get_mut(&p.plan_id).unwrap();
        if wall {
            stored.observation.expires = 0;
        } else {
            stored.observation.created = Instant::now() - Duration::from_secs(301);
        }
        drop(plans);
        assert!(store.recheck(&p.plan_id).is_err());
        assert!(store.recheck(&p.plan_id).is_err());
    }
}

#[test]
fn knowledge_restore_qualification_failed_reference_observation_detects_late_repair() {
    let f = Fixture::new();
    let target = resource(&f.app_root);
    let bytes = fs::read(&target).unwrap();
    fs::remove_file(&target).unwrap();
    let store = KnowledgeRestoreQualificationStore::new(f.app_root.clone());
    let p = store
        .plan_checked(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
            |stage| {
                if stage == 3 {
                    fs::write(&target, &bytes).unwrap();
                    fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
                }
            },
        )
        .unwrap();
    assert_eq!(
        serde_json::to_value(&p).unwrap()["currentResources"]["state"],
        "changed"
    );
    assert_blocked(&p, "currentResourcesUnavailable");
}
#[test]
fn knowledge_restore_qualification_empty_current_references_are_checked_zero_without_gc() {
    let f = Fixture::new();
    let path = f.app_root.join("knowledge-v1/manifest.json");
    let mut raw: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    raw["items"] = json!([]);
    raw["folders"] = json!([]);
    raw["completedOperations"] = json!([]);
    fs::write(path, serde_json::to_vec(&raw).unwrap()).unwrap();
    let before = snapshot(&f.app_root);
    let p = plan(
        &KnowledgeRestoreQualificationStore::new(f.app_root.clone()),
        &f,
    );
    let v = serde_json::to_value(p).unwrap();
    assert_eq!(v["currentResources"]["state"], "checked");
    assert_eq!(v["currentResources"]["fileCount"], 0);
    assert_eq!(v["currentResources"]["byteSize"], 0);
    assert_eq!(v["currentResources"]["inventorySha256"], hash(b"[]"));
    assert_eq!(v["qualification"]["addItems"], 1);
    assert_eq!(v["qualification"]["retainItems"], 0);
    assert_eq!(snapshot(&f.app_root), before);
}

#[test]
fn knowledge_restore_qualification_current_unique_resource_byte_limit_blocks_without_partial_evidence(
) {
    let f = Fixture::new();
    let manifest_path = f.app_root.join("knowledge-v1/manifest.json");
    let mut raw: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    let original = raw["items"][0].clone();
    for suffix in [b'a', b'b'] {
        let mut content = b"<html>".to_vec();
        content.resize(17 * 1024 * 1024 - 7, suffix);
        content.extend_from_slice(b"</html>");
        let digest = hash(&content);
        let file = f.app_root.join("knowledge-v1/archives").join(&digest);
        fs::write(&file, &content).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        let mut item = original.clone();
        item["summary"]["itemId"] = json!(uuid::Uuid::new_v4().to_string());
        item["summary"]["archive"]["sha256"] = json!(digest);
        item["summary"]["archive"]["byteSize"] = json!(content.len());
        let archive = item["summary"]["archive"].clone();
        for revision in item["revisions"].as_array_mut().unwrap() {
            revision["archive"] = archive.clone();
        }
        raw["items"].as_array_mut().unwrap().push(item);
    }
    fs::write(&manifest_path, serde_json::to_vec(&raw).unwrap()).unwrap();
    let store = KnowledgeRestoreQualificationStore::new(f.app_root.clone());
    let p = plan(&store, &f);
    let v = serde_json::to_value(&p).unwrap();
    assert_eq!(v["candidate"]["currentLibrary"]["state"], "checked");
    assert_eq!(v["currentResources"]["state"], "overLimit");
    assert_blocked(&p, "currentResourcesUnavailable");
}
