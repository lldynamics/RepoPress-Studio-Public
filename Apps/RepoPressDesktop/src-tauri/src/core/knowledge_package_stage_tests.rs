use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_backup::KnowledgeBackupStore,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::{symlink, PermissionsExt},
    path::PathBuf,
    time::Instant,
};

struct Fixture {
    _temp: tempfile::TempDir,
    app_data: PathBuf,
    library: PathBuf,
    source: PathBuf,
    parent: PathBuf,
}

impl Fixture {
    fn new(empty: bool) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let app_data = temp.path().join("app-data");
        let library = app_data.join("knowledge");
        let out = temp.path().join("export");
        let parent = temp.path().join("stage-parent");
        fs::create_dir_all(&library).unwrap();
        fs::create_dir(&out).unwrap();
        fs::create_dir(&parent).unwrap();
        fs::set_permissions(&app_data, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&library, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&out, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
        let store = KnowledgeLibraryStore::new(library.clone()).unwrap();
        store
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Text,
                    title: "stage test".into(),
                    source_name: "fixture".into(),
                    source_url: None,
                    text: "stage body".into(),
                    allows_local_semantic_index: false,
                    allows_remote_ai_use: false,
                },
                Some(&BrowserCaptureArchive {
                    format: "html".into(),
                    bytes: b"<html>stage</html>".to_vec(),
                    embedded_resource_count: Some(0),
                    missing_resource_count: Some(0),
                    was_truncated: Some(false),
                }),
            )
            .unwrap();
        if empty {
            let manifest_path = library.join("knowledge-v1/manifest.json");
            let mut manifest: serde_json::Value =
                serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
            manifest["items"] = json!([]);
            manifest["folders"] = json!([]);
            manifest["completedOperations"] = json!([]);
            fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        }
        let source = out.join("package.json");
        let backup = KnowledgeBackupStore::new(library.clone());
        let plan = backup.plan(&source).unwrap();
        backup.execute(&plan.plan_id, true).unwrap();
        Self {
            _temp: temp,
            app_data,
            library,
            source,
            parent,
        }
    }
}

fn assert_private_tree(path: &std::path::Path) {
    let metadata = fs::metadata(path).unwrap();
    if metadata.is_dir() {
        assert_eq!(
            metadata.permissions().mode() & 0o777,
            0o700,
            "{}",
            path.display()
        );
        for entry in fs::read_dir(path).unwrap() {
            assert_private_tree(&entry.unwrap().path());
        }
    } else {
        assert_eq!(
            metadata.permissions().mode() & 0o777,
            0o600,
            "{}",
            path.display()
        );
    }
}

fn candidate_inventory(candidate: &std::path::Path) -> (usize, usize, String) {
    fn collect(
        root: &std::path::Path,
        path: &std::path::Path,
        out: &mut BTreeMap<String, Vec<u8>>,
    ) {
        for entry in fs::read_dir(path).unwrap() {
            let entry = entry.unwrap();
            let child = entry.path();
            if child.is_dir() {
                collect(root, &child, out);
            } else {
                let relative = child
                    .strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .replace(std::path::MAIN_SEPARATOR, "/");
                out.insert(relative, fs::read(child).unwrap());
            }
        }
    }
    let mut files = BTreeMap::new();
    collect(candidate, candidate, &mut files);
    let byte_size = files.values().map(Vec::len).sum();
    let inventory: Vec<_> = files
        .iter()
        .map(|(path, bytes)| json!({"path": path, "byteSize": bytes.len(), "sha256": hash(bytes)}))
        .collect();
    let inventory_sha = hash(&serde_json::to_vec(&inventory).unwrap());
    (files.len(), byte_size, inventory_sha)
}

#[test]
fn stage_plan_is_read_only_and_execute_writes_private_candidate_only() {
    let f = Fixture::new(false);
    let before = fs::read(f.library.join("knowledge-v1/manifest.json")).unwrap();
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    assert!(plan
        .candidate_path
        .ends_with(&format!("repopress-knowledge-stage-{}", plan.plan_id)));
    assert!(!PathBuf::from(&plan.candidate_path).exists());
    assert_eq!(
        before,
        fs::read(f.library.join("knowledge-v1/manifest.json")).unwrap()
    );
    assert!(stage.execute(&plan.plan_id, false).is_err());
    assert!(
        stage.execute(&plan.plan_id, true).is_err(),
        "failed consent must consume the one-shot plan"
    );
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let _result = stage.execute(&plan.plan_id, true).unwrap();
    let candidate = PathBuf::from(&plan.candidate_path);
    assert_eq!(candidate, PathBuf::from(&plan.candidate_path));
    assert!(candidate.join("candidate.json").is_file());
    assert!(candidate.join("knowledge-v1/manifest.json").is_file());
    assert!(candidate.join("knowledge-v1/blobs").is_dir());
    assert!(candidate.join("knowledge-v1/archives").is_dir());
    assert_eq!(
        before,
        fs::read(f.library.join("knowledge-v1/manifest.json")).unwrap()
    );
    assert_eq!(
        fs::metadata(&candidate).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_private_tree(&candidate);
}

#[test]
fn empty_real_p46_export_is_accepted_and_discard_is_idempotent() {
    let f = Fixture::new(true);
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    stage.discard(&plan.plan_id).unwrap();
    stage.discard(&plan.plan_id).unwrap();
    assert!(stage.execute(&plan.plan_id, true).is_err());

    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let result = stage.execute(&plan.plan_id, true).unwrap();
    let candidate = PathBuf::from(&plan.candidate_path);
    assert_eq!(result.candidate_file_count, 2);
    assert_eq!(
        fs::read_dir(candidate.join("knowledge-v1/blobs"))
            .unwrap()
            .count(),
        0
    );
    assert_eq!(
        fs::read_dir(candidate.join("knowledge-v1/archives"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn plan_capacity_and_both_expiry_clocks_consume_plans_without_writes() {
    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    let first = stage.plan(&f.source, &f.parent).unwrap();
    let second = stage.plan(&f.source, &f.parent).unwrap();
    assert_ne!(first.plan_id, second.plan_id);
    assert!(stage.plan(&f.source, &f.parent).is_err());
    assert!(!PathBuf::from(&first.candidate_path).exists());
    assert!(!PathBuf::from(&second.candidate_path).exists());

    stage.discard(&first.plan_id).unwrap();
    stage.discard(&second.plan_id).unwrap();
    let monotonic = stage.plan(&f.source, &f.parent).unwrap();
    stage
        .bindings
        .lock()
        .unwrap()
        .get_mut(&monotonic.plan_id)
        .unwrap()
        .created = Instant::now() - TTL;
    assert!(stage.execute(&monotonic.plan_id, true).is_err());

    let wall = stage.plan(&f.source, &f.parent).unwrap();
    stage
        .bindings
        .lock()
        .unwrap()
        .get_mut(&wall.plan_id)
        .unwrap()
        .plan
        .expires_at_epoch_ms = 1;
    assert!(stage.execute(&wall.plan_id, true).is_err());
}

#[test]
fn candidate_inventory_result_and_marker_flags_are_exact_without_sensitive_report_data() {
    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data);
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let package_json = serde_json::to_string(&plan.package).unwrap();
    assert!(!package_json.contains("stage body"));
    assert!(!package_json.contains("stage test"));
    let result = stage.execute(&plan.plan_id, true).unwrap();
    let candidate = PathBuf::from(&plan.candidate_path);
    let (count, bytes, inventory) = candidate_inventory(&candidate);
    assert_eq!(count, plan.candidate_file_count);
    assert_eq!(bytes, plan.candidate_byte_size);
    assert_eq!(inventory, plan.candidate_inventory_sha256);
    assert_eq!(count, result.candidate_file_count);
    assert_eq!(bytes, result.candidate_byte_size);
    assert_eq!(inventory, result.candidate_inventory_sha256);
    let marker: serde_json::Value =
        serde_json::from_slice(&fs::read(candidate.join("candidate.json")).unwrap()).unwrap();
    for key in ["candidateOnly", "currentLibraryChanged", "restoreReady"] {
        assert_eq!(marker[key], json!(matches!(key, "candidateOnly")));
    }
    assert_eq!(marker["includesCredentialStores"], json!(false));
    assert_eq!(marker["includesCompletedOperations"], json!(false));
    assert_eq!(marker["externalReferencesIncluded"], json!(false));
}

#[test]
fn source_swaps_aliases_and_target_collisions_fail_closed_without_overwrite() {
    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let original = fs::read(&f.source).unwrap();
    fs::write(&f.source, [original.as_slice(), b" "].concat()).unwrap();
    assert!(stage.execute(&plan.plan_id, true).is_err());
    assert!(!PathBuf::from(&plan.candidate_path).exists());

    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let candidate = PathBuf::from(&plan.candidate_path);
    fs::create_dir(&candidate).unwrap();
    fs::write(candidate.join("sentinel"), b"keep").unwrap();
    assert!(stage.execute(&plan.plan_id, true).is_err());
    assert_eq!(fs::read(candidate.join("sentinel")).unwrap(), b"keep");

    let link = f.parent.join("source-link.json");
    symlink(&f.source, &link).unwrap();
    assert!(KnowledgePackageStageStore::new(f.app_data)
        .plan(&link, &f.parent)
        .is_err());
}

#[test]
fn malformed_package_is_rejected_before_candidate_creation() {
    let f = Fixture::new(false);
    let mut value: serde_json::Value =
        serde_json::from_slice(&fs::read(&f.source).unwrap()).unwrap();
    value["unexpected"] = json!(true);
    fs::write(&f.source, serde_json::to_vec(&value).unwrap()).unwrap();
    let stage = KnowledgePackageStageStore::new(f.app_data);
    assert!(stage.plan(&f.source, &f.parent).is_err());
    assert_eq!(fs::read_dir(&f.parent).unwrap().count(), 0);
}

#[test]
fn checked_hooks_fail_closed_at_every_write_boundary_and_preserve_partial_output() {
    for phase in 0..=6u8 {
        let f = Fixture::new(false);
        let stage = KnowledgePackageStageStore::new(f.app_data);
        let plan = stage.plan(&f.source, &f.parent).unwrap();
        let candidate = PathBuf::from(&plan.candidate_path);
        let original = fs::read(&f.source).unwrap();
        let mut fired = false;
        let result = stage.execute_checked(&plan.plan_id, true, |seen| {
            if seen != phase || fired {
                return;
            }
            fired = true;
            match phase {
                4 => fs::write(candidate.join("unexpected"), b"tamper").unwrap(),
                5 => fs::write(candidate.join("candidate.json"), b"tamper").unwrap(),
                _ => fs::write(&f.source, [original.as_slice(), b" "].concat()).unwrap(),
            }
        });
        assert!(result.is_err(), "phase {phase} must fail closed");
        assert!(fired, "phase {phase} hook did not run");
        if phase < 2 {
            assert!(!candidate.exists(), "phase {phase} must fail before mkdir");
        } else {
            assert!(
                candidate.exists(),
                "phase {phase} must preserve partial output"
            );
            if phase < 5 {
                assert!(
                    !candidate.join("candidate.json").exists(),
                    "marker must remain last at phase {phase}"
                );
            }
        }
        assert!(
            stage.execute(&plan.plan_id, true).is_err(),
            "phase {phase} plan must not be retryable"
        );
    }
}

#[test]
fn output_same_length_tamper_permissions_and_symlink_fail_after_creation() {
    for mode in ["bytes", "permissions", "symlink"] {
        let f = Fixture::new(false);
        let stage = KnowledgePackageStageStore::new(f.app_data);
        let plan = stage.plan(&f.source, &f.parent).unwrap();
        let candidate = PathBuf::from(&plan.candidate_path);
        let result = stage.execute_checked(&plan.plan_id, true, |phase| {
            if phase == 4 {
                let manifest = candidate.join("knowledge-v1/manifest.json");
                match mode {
                    "bytes" => {
                        let mut bytes = fs::read(&manifest).unwrap();
                        bytes[0] ^= 1;
                        fs::write(manifest, bytes).unwrap();
                    }
                    "permissions" => {
                        fs::set_permissions(&manifest, fs::Permissions::from_mode(0o644)).unwrap()
                    }
                    "symlink" => {
                        fs::remove_file(&manifest).unwrap();
                        symlink(&f.source, manifest).unwrap();
                    }
                    _ => unreachable!(),
                }
            }
        });
        assert!(result.is_err(), "{mode} tamper must fail");
        assert!(candidate.exists());
        assert!(
            !candidate.join("candidate.json").exists(),
            "marker must remain absent after hook 4 tamper"
        );
        assert!(stage.execute(&plan.plan_id, true).is_err());
    }

    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data);
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let candidate = PathBuf::from(&plan.candidate_path);
    let result = stage.execute_checked(&plan.plan_id, true, |phase| {
        if phase == 6 {
            let marker = candidate.join("candidate.json");
            let mut bytes = fs::read(&marker).unwrap();
            bytes[0] ^= 1;
            fs::write(marker, bytes).unwrap();
        }
    });
    assert!(result.is_err());
    assert!(candidate.join("candidate.json").exists());
    assert!(stage.execute(&plan.plan_id, true).is_err());
}

#[test]
fn source_and_parent_identity_changes_are_rejected_without_replacing_current_library() {
    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let moved = f.parent.with_extension("moved");
    fs::rename(&f.parent, &moved).unwrap();
    assert!(stage.execute(&plan.plan_id, true).is_err());
    fs::rename(&moved, &f.parent).unwrap();

    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    let plan = stage.plan(&f.source, &f.parent).unwrap();
    let source_bytes = fs::read(&f.source).unwrap();
    fs::set_permissions(&f.source, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(stage.execute(&plan.plan_id, true).is_err());
    fs::write(&f.source, source_bytes).unwrap();
}

#[test]
fn parent_inside_application_root_is_rejected_before_any_output() {
    let f = Fixture::new(false);
    let stage = KnowledgePackageStageStore::new(f.app_data.clone());
    assert!(stage.plan(&f.source, &f.app_data).is_err());
    assert_eq!(fs::read_dir(&f.parent).unwrap().count(), 0);
}

#[test]
fn initialized_git_parent_is_rejected() {
    let f = Fixture::new(false);
    let git = f.parent.parent().unwrap().join(".git");
    fs::create_dir(&git).unwrap();
    fs::write(git.join("HEAD"), b"ref: refs/heads/main\n").unwrap();
    let stage = KnowledgePackageStageStore::new(f.app_data);
    assert!(stage.plan(&f.source, &f.parent).is_err());
}
