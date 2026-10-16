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
        KnowledgeLibraryStore::new(app_root.clone())
            .unwrap()
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Web,
                    title: "merge projection fixture title".into(),
                    source_name: "merge projection fixture source".into(),
                    source_url: Some("https://private.example/merge".into()),
                    text: "merge projection fixture body".into(),
                    allows_local_semantic_index: true,
                    allows_remote_ai_use: true,
                },
                Some(&BrowserCaptureArchive {
                    format: "html".into(),
                    bytes: b"<html>merge</html>".to_vec(),
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

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn snapshot(root: &Path) -> BTreeMap<String, (Vec<u8>, u32, u64)> {
    fn walk(root: &Path, path: &Path, out: &mut BTreeMap<String, (Vec<u8>, u32, u64)>) {
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
                    (
                        fs::read(&path).unwrap(),
                        metadata.mode() & 0o777,
                        metadata.ino(),
                    ),
                );
            }
        }
    }
    let mut result = BTreeMap::new();
    walk(root, root, &mut result);
    result
}

fn update_candidate_manifest(candidate: &Path, mutate: impl FnOnce(&mut Value)) {
    let manifest_path = candidate.join("knowledge-v1/manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    mutate(&mut manifest);
    let bytes = serde_json::to_vec(&manifest).unwrap();
    fs::write(&manifest_path, &bytes).unwrap();
    let marker_path = candidate.join("candidate.json");
    let mut marker: Value = serde_json::from_slice(&fs::read(&marker_path).unwrap()).unwrap();
    marker["manifestSha256"] = json!(hash(&bytes));
    fs::write(marker_path, serde_json::to_vec(&marker).unwrap()).unwrap();
}

fn projection(store: &KnowledgeMergeProjectionStore, f: &Fixture) -> KnowledgeMergeProjectionPlan {
    store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap()
}

fn replace_same_bytes(path: &Path) {
    let bytes = fs::read(path).unwrap();
    let mode = fs::metadata(path).unwrap().permissions().mode() & 0o777;
    let moved = path.with_extension("p51-old");
    fs::rename(path, &moved).unwrap();
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

#[test]
fn knowledge_merge_projection_validates_private_read_only_projection_and_excludes_plaintext() {
    let f = Fixture::new();
    let before_current = snapshot(&f.app_root);
    let before_candidate = snapshot(&f.candidate);
    let p = projection(&KnowledgeMergeProjectionStore::new(f.app_root.clone()), &f);
    let value = serde_json::to_value(&p).unwrap();
    assert_eq!(value["projection"]["state"], "validated");
    assert_eq!(value["projection"]["completedOperationsExcluded"], true);
    assert_eq!(value["privacyMode"], "disableImportedPermissions");
    assert_eq!(value["currentPermissionsPreserved"], true);
    assert_eq!(value["sourcePermissionsCopied"], false);
    assert_eq!(value["filesystemWrites"], false);
    assert_eq!(value["restoreReady"], false);
    assert!(
        value["projection"]["manifestSha256"]
            .as_str()
            .unwrap()
            .len()
            == 64
    );
    let text = serde_json::to_string(&p).unwrap();
    assert!(!text.contains("merge projection fixture title"));
    assert!(!text.contains("merge projection fixture body"));
    assert_eq!(before_current, snapshot(&f.app_root));
    assert_eq!(before_candidate, snapshot(&f.candidate));
}

#[test]
fn knowledge_merge_projection_new_permissions_are_reset_current_values_retained_and_exact_hash_matches(
) {
    let f = Fixture::new();
    let current_path = f.app_root.join("knowledge-v1/manifest.json");
    let mut current: Value = serde_json::from_slice(&fs::read(&current_path).unwrap()).unwrap();
    let mut current_only = current["items"][0].clone();
    current_only["summary"]["itemId"] = json!(uuid::Uuid::new_v4().to_string());
    current["items"].as_array_mut().unwrap().push(current_only);
    fs::write(&current_path, serde_json::to_vec(&current).unwrap()).unwrap();
    let mut imported = Vec::new();
    update_candidate_manifest(&f.candidate, |manifest| {
        let template = manifest["items"][0].clone();
        manifest["items"][0]["summary"]["title"] = json!("changed candidate metadata");
        for (id, remote, local) in [
            ("11111111-1111-4111-8111-111111111111", true, false),
            ("22222222-2222-4222-8222-222222222222", false, true),
            ("33333333-3333-4333-8333-833333333333", false, false),
        ] {
            let mut item = template.clone();
            item["summary"]["itemId"] = json!(id);
            item["summary"]["allowsRemoteAiUse"] = json!(remote);
            item["summary"]["allowsLocalSemanticIndex"] = json!(local);
            imported.push(item);
        }
        manifest["items"]
            .as_array_mut()
            .unwrap()
            .extend(imported.iter().rev().cloned());
    });
    let before_current = snapshot(&f.app_root);
    let before_candidate = snapshot(&f.candidate);
    let store = KnowledgeMergeProjectionStore::new(f.app_root.clone());
    let p = projection(&store, &f);
    let v = serde_json::to_value(&p).unwrap();
    assert_eq!(v["source"]["candidate"]["conflicts"]["changedItems"], 1);
    assert_eq!(v["source"]["candidate"]["conflicts"]["currentOnlyItems"], 1);
    assert_eq!(v["projection"]["state"], "validated");
    assert_eq!(v["projection"]["importedItems"], 3);
    assert_eq!(v["projection"]["resetPermissionItems"], 2);
    assert_eq!(v["projection"]["itemCount"], 5);
    assert_eq!(v["projection"]["revisionCount"], 5);
    assert_eq!(
        v["projection"]["fileCount"], 2,
        "shared body/archive refs are counted once per kind"
    );
    let mut expected_items = current["items"].as_array().unwrap().clone();
    for mut item in imported {
        item["summary"]["allowsRemoteAiUse"] = json!(false);
        item["summary"]["allowsLocalSemanticIndex"] = json!(false);
        expected_items.push(item);
    }
    let expected = serde_json::to_vec(&json!({"schemaVersion":4,"items":expected_items,
        "folders":current["folders"],"completedOperations":[]}))
    .unwrap();
    assert_eq!(v["projection"]["manifestSha256"], hash(&expected));
    assert_eq!(v["projection"]["manifestByteSize"], expected.len());
    let r = serde_json::to_value(store.preflight(&p.plan_id, true).unwrap()).unwrap();
    assert_eq!(r["projectionManifestSha256"], hash(&expected));
    assert_eq!(r["resetPermissionItems"], 2);
    assert_eq!(before_current, snapshot(&f.app_root));
    assert_eq!(before_candidate, snapshot(&f.candidate));
}

#[test]
fn knowledge_merge_projection_same_id_change_strict_blocks_keep_validates_and_hash_is_exact() {
    let strict = Fixture::new();
    update_candidate_manifest(&strict.candidate, |manifest| {
        manifest["items"][0]["summary"]["title"] = json!("candidate changed title");
    });
    let strict_plan = KnowledgeMergeProjectionStore::new(strict.app_root.clone())
        .plan(
            &strict.candidate,
            KnowledgeRestoreStrategy::RequireNoIdentityConflicts,
        )
        .unwrap();
    assert_eq!(
        serde_json::to_value(strict_plan).unwrap()["projection"]["state"],
        "blocked"
    );
    let keep = Fixture::new();
    update_candidate_manifest(&keep.candidate, |manifest| {
        manifest["items"][0]["summary"]["title"] = json!("candidate changed title");
    });
    let store = KnowledgeMergeProjectionStore::new(keep.app_root.clone());
    let plan = store
        .plan(
            &keep.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    let value = serde_json::to_value(&plan).unwrap();
    assert_eq!(value["projection"]["state"], "validated");
    assert_eq!(value["projection"]["importedItems"], 0);
    assert_eq!(value["projection"]["resetPermissionItems"], 0);
    let current: Value = serde_json::from_slice(
        &fs::read(keep.app_root.join("knowledge-v1/manifest.json")).unwrap(),
    )
    .unwrap();
    let expected = serde_json::to_vec(&json!({"schemaVersion":4,"items":current["items"],"folders":current["folders"],"completedOperations":[]})).unwrap();
    assert_eq!(value["projection"]["manifestSha256"], hash(&expected));
}

#[test]
fn knowledge_merge_projection_valid_sources_hit_item_and_folder_capacity_without_fake_resources() {
    let items = Fixture::new();
    update_candidate_manifest(&items.candidate, |manifest| {
        let template = manifest["items"][0].clone();
        let values = manifest["items"].as_array_mut().unwrap();
        for _ in 1..=1000 {
            let mut item = template.clone();
            item["summary"]["itemId"] = json!(uuid::Uuid::new_v4().to_string());
            values.push(item);
        }
    });
    let mut current: Value = serde_json::from_slice(
        &fs::read(items.app_root.join("knowledge-v1/manifest.json")).unwrap(),
    )
    .unwrap();
    let template = current["items"][0].clone();
    for _ in 1..=1000 {
        let mut item = template.clone();
        item["summary"]["itemId"] = json!(uuid::Uuid::new_v4().to_string());
        current["items"].as_array_mut().unwrap().push(item);
    }
    fs::write(
        items.app_root.join("knowledge-v1/manifest.json"),
        serde_json::to_vec(&current).unwrap(),
    )
    .unwrap();
    let plan = projection(
        &KnowledgeMergeProjectionStore::new(items.app_root.clone()),
        &items,
    );
    assert_eq!(
        serde_json::to_value(&plan).unwrap()["source"]["qualification"]["state"],
        "evidenceReady"
    );
    assert_eq!(
        serde_json::to_value(&plan).unwrap()["projection"]["reason"],
        "capacityExceeded"
    );
    let folders = Fixture::new();
    let current_id = uuid::Uuid::new_v4().to_string();
    let mut current: Value = serde_json::from_slice(
        &fs::read(folders.app_root.join("knowledge-v1/manifest.json")).unwrap(),
    )
    .unwrap();
    current["folders"] =
        json!([{"folderId":current_id,"name":"Current","createdAtEpochSeconds":1}]);
    current["items"][0]["summary"]["folderId"] = json!(current_id);
    fs::write(
        folders.app_root.join("knowledge-v1/manifest.json"),
        serde_json::to_vec(&current).unwrap(),
    )
    .unwrap();
    update_candidate_manifest(&folders.candidate, |manifest| {
        let values = manifest["folders"].as_array_mut().unwrap();
        for n in 0..128 {
            values.push(json!({"folderId":uuid::Uuid::new_v4().to_string(),"name":format!("Candidate-{n}"),"createdAtEpochSeconds":1}));
        }
    });
    let plan = projection(
        &KnowledgeMergeProjectionStore::new(folders.app_root.clone()),
        &folders,
    );
    assert_eq!(
        serde_json::to_value(&plan).unwrap()["source"]["qualification"]["state"],
        "evidenceReady"
    );
    assert_eq!(
        serde_json::to_value(&plan).unwrap()["projection"]["reason"],
        "capacityExceeded"
    );
}

#[test]
fn knowledge_merge_projection_missing_current_blocks_and_preflight_consumes() {
    let f = Fixture::new();
    fs::remove_dir_all(f.app_root.join("knowledge-v1")).unwrap();
    let store = KnowledgeMergeProjectionStore::new(f.app_root);
    let plan = store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities,
        )
        .unwrap();
    assert_eq!(
        serde_json::to_value(&plan).unwrap()["projection"]["reason"],
        "qualificationBlocked"
    );
    assert!(store.preflight(&plan.plan_id, true).is_err());
    assert!(store.preflight(&plan.plan_id, true).is_err());
}

#[test]
fn knowledge_merge_projection_capacity_two_discard_release_and_dual_ttl_are_consuming() {
    let f = Fixture::new();
    let store = KnowledgeMergeProjectionStore::new(f.app_root.clone());
    let first = projection(&store, &f);
    let second = projection(&store, &f);
    assert!(store
        .plan(
            &f.candidate,
            KnowledgeRestoreStrategy::KeepCurrentIdentities
        )
        .is_err());
    store.discard(&first.plan_id).unwrap();
    let third = projection(&store, &f);
    store.discard(&second.plan_id).unwrap();
    store.discard(&third.plan_id).unwrap();
    for wall in [false, true] {
        let p = projection(&store, &f);
        let mut plans = store.plans.lock().unwrap();
        let stored = plans.get_mut(&p.plan_id).unwrap();
        if wall {
            stored.observation.expires = 0;
        } else {
            stored.observation.created = Instant::now() - Duration::from_secs(301);
        }
        drop(plans);
        assert!(store.preflight(&p.plan_id, true).is_err());
        assert!(store.preflight(&p.plan_id, true).is_err());
    }
}

#[test]
fn knowledge_merge_projection_preflight_consumes_same_byte_current_inode_replacements() {
    for manifest in [false, true] {
        let f = Fixture::new();
        let store = KnowledgeMergeProjectionStore::new(f.app_root.clone());
        let p = projection(&store, &f);
        let target = if manifest {
            f.app_root.join("knowledge-v1/manifest.json")
        } else {
            {
                let dir = f.app_root.join("knowledge-v1/blobs");
                fs::read_dir(dir).unwrap().next().unwrap().unwrap().path()
            }
        };
        let before = snapshot(&f.app_root);
        replace_same_bytes(&target);
        let after_replacement = snapshot(&f.app_root);
        let candidate_before = snapshot(&f.candidate);
        assert!(store.preflight(&p.plan_id, true).is_err());
        assert!(store.preflight(&p.plan_id, true).is_err());
        assert_ne!(before, after_replacement);
        assert_eq!(
            after_replacement,
            snapshot(&f.app_root),
            "preflight did not write current files"
        );
        assert_eq!(candidate_before, snapshot(&f.candidate));
    }
}

#[test]
fn knowledge_merge_projection_folder_case_collision_blocks_with_null_counts() {
    let f = Fixture::new();
    let current_folder_id = uuid::Uuid::new_v4().to_string();
    let candidate_folder_id = uuid::Uuid::new_v4().to_string();
    let mut current: Value =
        serde_json::from_slice(&fs::read(f.app_root.join("knowledge-v1/manifest.json")).unwrap())
            .unwrap();
    current["folders"] = json!([{
        "folderId": current_folder_id,
        "name": "Research",
        "createdAtEpochSeconds": 1
    }]);
    current["items"][0]["summary"]["folderId"] = json!(current_folder_id);
    fs::write(
        f.app_root.join("knowledge-v1/manifest.json"),
        serde_json::to_vec(&current).unwrap(),
    )
    .unwrap();
    update_candidate_manifest(&f.candidate, |manifest| {
        manifest["folders"] = json!([{
            "folderId": candidate_folder_id,
            "name": "research",
            "createdAtEpochSeconds": 1
        }]);
        manifest["items"][0]["summary"]["folderId"] = json!(candidate_folder_id);
    });
    let p = projection(&KnowledgeMergeProjectionStore::new(f.app_root.clone()), &f);
    let value = serde_json::to_value(&p).unwrap();
    assert_eq!(value["projection"]["state"], "blocked");
    assert_eq!(value["projection"]["reason"], "folderNameCollision");
    for key in [
        "manifestSha256",
        "manifestByteSize",
        "itemCount",
        "revisionCount",
        "folderCount",
        "fileCount",
        "resourceByteSize",
        "bodyByteSize",
        "archiveByteSize",
        "importedItems",
        "importedFolders",
        "resetPermissionItems",
    ] {
        assert_eq!(value["projection"][key], Value::Null, "{key}");
    }
}

#[test]
fn knowledge_merge_projection_hook_drift_blocks_and_preflight_ack_is_one_shot() {
    for phase in [3u8, 4u8] {
        let f = Fixture::new();
        let target = f.app_root.join("knowledge-v1/manifest.json");
        let store = KnowledgeMergeProjectionStore::new(f.app_root.clone());
        let p = store
            .plan_checked(
                &f.candidate,
                KnowledgeRestoreStrategy::KeepCurrentIdentities,
                |point| {
                    if point == phase {
                        let mut bytes = fs::read(&target).unwrap();
                        bytes.push(b'!');
                        fs::write(&target, bytes).unwrap();
                    }
                },
            )
            .unwrap();
        assert_eq!(
            serde_json::to_value(&p).unwrap()["projection"]["state"],
            "blocked"
        );
        assert_eq!(
            serde_json::to_value(&p).unwrap()["projection"]["reason"],
            "qualificationBlocked"
        );
    }
    let f = Fixture::new();
    let store = KnowledgeMergeProjectionStore::new(f.app_root.clone());
    let p = projection(&store, &f);
    assert!(store.preflight(&p.plan_id, false).is_err());
    assert!(
        store.preflight(&p.plan_id, true).is_err(),
        "false acknowledgement consumes plan"
    );
    let p = projection(&store, &f);
    let receipt = store.preflight(&p.plan_id, true).unwrap();
    let value = serde_json::to_value(receipt).unwrap();
    assert_eq!(value["privacyResetAcknowledged"], true);
    assert_eq!(value["importedPermissionsDisabled"], true);
    assert_eq!(value["filesystemWrites"], false);
    assert!(store.preflight(&p.plan_id, true).is_err());
    store.discard(&p.plan_id).unwrap();
    store.discard(&p.plan_id).unwrap();
}
