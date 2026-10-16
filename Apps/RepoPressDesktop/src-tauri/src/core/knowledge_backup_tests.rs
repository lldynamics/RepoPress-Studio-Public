use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
};
use serde_json::{json, Value};
use std::{
    fs,
    fs::OpenOptions,
    os::unix::fs::{symlink, MetadataExt, PermissionsExt},
};
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    out: PathBuf,
    store: KnowledgeBackupStore,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("data");
        let out = temp.path().join("exports");
        for p in [&root, &out] {
            fs::create_dir(p).unwrap();
            fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let library = KnowledgeLibraryStore::new(root.clone()).unwrap();
        for text in [
            "PRIVATE OLD BODY https://external.invalid/private",
            "PRIVATE NEW BODY",
        ] {
            library
                .import_with_archive(
                    KnowledgeImportRequest {
                        source_kind: KnowledgeSourceKind::Text,
                        title: "PRIVATE TITLE".into(),
                        source_name: "PRIVATE SOURCE/path".into(),
                        source_url: None,
                        text: text.into(),
                        allows_local_semantic_index: false,
                        allows_remote_ai_use: false,
                    },
                    Some(&BrowserCaptureArchive {
                        format: "html".into(),
                        bytes: b"<html>PRIVATE ARCHIVE</html>".to_vec(),
                        embedded_resource_count: Some(1),
                        missing_resource_count: Some(0),
                        was_truncated: Some(false),
                    }),
                )
                .unwrap();
        }
        let f = Self {
            store: KnowledgeBackupStore::new(root.clone()),
            root,
            out,
            _temp: temp,
        };
        // Merge two imported current records into one real two-revision history.
        f.edit(|v| {
            let first = v["items"][0].clone();
            let mut latest = v["items"][1].clone();
            latest["summary"]["itemId"] = first["summary"]["itemId"].clone();
            latest["summary"]["revisionNumber"] = json!(2);
            latest["summary"]["revisionCount"] = json!(2);
            let mut newest = latest["revisions"][0].clone();
            newest["revisionNumber"] = json!(2);
            latest["revisions"] = json!([first["revisions"][0].clone(), newest]);
            v["items"] = json!([latest]);
        });
        f
    }
    fn manifest_path(&self) -> PathBuf {
        self.root.join("knowledge-v1/manifest.json")
    }
    fn manifest(&self) -> Value {
        serde_json::from_slice(&fs::read(self.manifest_path()).unwrap()).unwrap()
    }
    fn edit(&self, change: impl FnOnce(&mut Value)) {
        let mut v = self.manifest();
        change(&mut v);
        fs::write(self.manifest_path(), serde_json::to_vec(&v).unwrap()).unwrap();
    }
    fn blob(&self) -> PathBuf {
        self.root.join("knowledge-v1/blobs").join(
            self.manifest()["items"][0]["contentSha256"]
                .as_str()
                .unwrap(),
        )
    }
    fn archive(&self) -> PathBuf {
        self.root.join("knowledge-v1/archives").join(
            self.manifest()["items"][0]["summary"]["archive"]["sha256"]
                .as_str()
                .unwrap(),
        )
    }
    fn destination(&self) -> PathBuf {
        self.out.join("saved.json")
    }
    fn plan(&self) -> KnowledgeBackupPlan {
        self.store.plan(&self.destination()).unwrap()
    }
    fn no_output(&self) {
        assert_eq!(fs::read_dir(&self.out).unwrap().count(), 0);
    }
}
#[test]
fn all_history_exact_file_closure_private_package_and_receipt_exclusion() {
    let f = Fixture::new();
    let folder = Uuid::new_v4().to_string();
    f.edit(|v| {
        v["folders"] = json!([{"folderId":folder,"name":"PRIVATE FOLDER","createdAtEpochSeconds":1}]);
        v["items"][0]["summary"]["folderId"] = json!(folder);
        v["completedOperations"] = json!([{
            "operationId":Uuid::new_v4().to_string(),"fingerprint":"b".repeat(64),"completedAtEpochSeconds":1,
            "receipt":{"documentId":Uuid::new_v4().to_string(),"title":"RECEIPT ONLY SECRET","action":"inserted","folderId":null,"fileSizeBytes":1,"archiveType":"none","allowsLocalSemanticIndex":false,"allowsRemoteAiUse":false,"savedAtEpochSeconds":1,"replayed":false}
        }]);
    });
    let orphan = f.root.join("knowledge-v1/blobs").join("c".repeat(64));
    fs::write(&orphan, b"UNREFERENCED SECRET").unwrap();
    fs::set_permissions(&orphan, fs::Permissions::from_mode(0o600)).unwrap();
    let source = fs::read(f.manifest_path()).unwrap();
    let source_mode = fs::metadata(f.manifest_path()).unwrap().mode();
    let plan = f.plan();
    f.no_output();
    assert_eq!(
        (
            plan.item_count,
            plan.revision_count,
            plan.body_file_count,
            plan.archive_file_count
        ),
        (1, 2, 2, 1)
    );
    let dto = serde_json::to_string(&plan).unwrap();
    assert!(!dto.contains("PRIVATE"));
    assert!(!dto.contains("RECEIPT ONLY"));
    assert!(!plan.consistent_snapshot);
    assert!(plan.all_saved_references_included);
    let result = f.store.execute(&plan.plan_id, true).unwrap();
    assert_eq!(result.sha256, plan.sha256);
    let bytes = fs::read(f.destination()).unwrap();
    assert_eq!(hash(&bytes), plan.sha256);
    assert_eq!(bytes.len(), plan.byte_size);
    let m = fs::metadata(f.destination()).unwrap();
    assert_eq!(m.mode() & 0o777, 0o600);
    assert_eq!(m.nlink(), 1);
    assert_eq!(m.uid(), unsafe { libc::geteuid() });
    let package: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(package["format"], FORMAT);
    assert_eq!(package["schemaVersion"], 1);
    assert_eq!(package["sourceManifestSchemaVersion"], 4);
    assert_eq!(package["manifest"]["completedOperations"], json!([]));
    assert!(!String::from_utf8_lossy(&bytes).contains("RECEIPT ONLY SECRET"));
    assert_eq!(
        package["manifestSha256"],
        hash(&serde_json::to_vec(&package["manifest"]).unwrap())
    );
    assert_eq!(package["sourceManifestSha256"], hash(&source));
    let projected = crate::core::knowledge_library::knowledge_integrity_manifest::project(
        &serde_json::to_vec(&package["manifest"]).unwrap(),
    )
    .unwrap();
    let files = package["files"].as_array().unwrap();
    assert_eq!(files.len(), projected.files.len());
    for reference in projected.files {
        let path = format!(
            "{}/{}",
            if reference.kind == "body" {
                "blobs"
            } else {
                "archives"
            },
            reference.digest
        );
        let entry = files.iter().find(|e| e["path"] == path).unwrap();
        let data = STANDARD.decode(entry["data"].as_str().unwrap()).unwrap();
        assert_eq!(entry["encoding"], "base64");
        assert_eq!(entry["sha256"], reference.digest);
        assert_eq!(entry["byteSize"], data.len());
        assert!(
            crate::core::knowledge_library::knowledge_integrity_manifest::content_matches(
                &reference, &data
            )
        );
        assert_eq!(
            data,
            fs::read(f.root.join("knowledge-v1").join(path)).unwrap()
        );
    }
    assert_eq!(fs::read(f.manifest_path()).unwrap(), source);
    assert_eq!(fs::metadata(f.manifest_path()).unwrap().mode(), source_mode);
    assert_eq!(fs::read(orphan).unwrap(), b"UNREFERENCED SECRET");
    assert!(f.store.execute(&plan.plan_id, true).is_err());
}
#[test]
fn false_consent_and_discard_are_terminal_without_writes() {
    let f = Fixture::new();
    let plan = f.plan();
    assert!(f.store.execute(&plan.plan_id, false).is_err());
    assert!(f.store.execute(&plan.plan_id, true).is_err());
    f.no_output();
    let plan = f.plan();
    f.store.discard(&plan.plan_id).unwrap();
    f.store.discard(&plan.plan_id).unwrap();
    assert!(f.store.execute(&plan.plan_id, true).is_err());
    f.no_output();
}
#[test]
fn capacity_and_monotonic_or_wall_expiry_never_write() {
    let f = Fixture::new();
    let a = f.plan();
    let b = f.store.plan(&f.out.join("other.json")).unwrap();
    assert!(f.store.plan(&f.out.join("third.json")).is_err());
    f.store
        .plans
        .lock()
        .unwrap()
        .get_mut(&a.plan_id)
        .unwrap()
        .created = Instant::now() - TTL;
    assert!(f.store.execute(&a.plan_id, true).is_err());
    f.store
        .plans
        .lock()
        .unwrap()
        .get_mut(&b.plan_id)
        .unwrap()
        .preview
        .expires_at_epoch_ms = 1;
    assert!(f.store.execute(&b.plan_id, true).is_err());
    f.no_output();
    assert!(f.store.execute("unknown", true).is_err());
}
#[test]
fn missing_root_or_manifest_never_initializes_a_library() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("not-created");
    let store = KnowledgeBackupStore::new(path.clone());
    assert!(store.plan(&temp.path().join("new.json")).is_err());
    assert!(!path.exists());
    let f = Fixture::new();
    fs::remove_file(f.manifest_path()).unwrap();
    assert!(f.store.plan(&f.destination()).is_err());
    assert!(!f.manifest_path().exists());
    f.no_output();
}
#[test]
fn empty_valid_v4_is_a_saved_empty_library_not_a_missing_manifest() {
    let f = Fixture::new();
    f.edit(|v| {
        v["items"] = json!([]);
        v["folders"] = json!([]);
        v["completedOperations"] = json!([]);
    });
    let p = f.plan();
    assert_eq!(
        (
            p.item_count,
            p.revision_count,
            p.body_file_count,
            p.archive_file_count,
            p.resource_byte_size
        ),
        (0, 0, 0, 0, 0)
    );
    f.store.execute(&p.plan_id, true).unwrap();
    let package: Value = serde_json::from_slice(&fs::read(f.destination()).unwrap()).unwrap();
    assert_eq!(package["files"], json!([]));
}
#[test]
fn old_future_and_malformed_manifests_are_rejected_without_repair() {
    for version in [0, 1, 2, 3, 5, u32::MAX as u64 + 1, u64::MAX] {
        let f = Fixture::new();
        f.edit(|v| v["schemaVersion"] = json!(version));
        let before = fs::read(f.manifest_path()).unwrap();
        assert!(f.store.plan(&f.destination()).is_err());
        assert_eq!(fs::read(f.manifest_path()).unwrap(), before);
        f.no_output();
    }
    for case in 0..4 {
        let f = Fixture::new();
        match case {
            0 => f.edit(|v| v["unknown"] = json!("secret")),
            1 => f.edit(|v| v["items"][0]["contentSha256"] = json!("../outside")),
            2 => f.edit(|v| v["items"][0]["summary"]["revisionCount"] = json!(1)),
            _ => {
                let text = String::from_utf8(fs::read(f.manifest_path()).unwrap()).unwrap();
                fs::write(
                    f.manifest_path(),
                    text.replacen(
                        "\"schemaVersion\":4",
                        "\"schemaVersion\":4,\"schemaVersion\":4",
                        1,
                    ),
                )
                .unwrap();
            }
        }
        let before = fs::read(f.manifest_path()).unwrap();
        assert!(f.store.plan(&f.destination()).is_err());
        assert_eq!(fs::read(f.manifest_path()).unwrap(), before);
        f.no_output();
    }
}
#[test]
fn missing_tampered_invalid_utf8_and_wrong_archive_format_refuse_complete_package() {
    for case in 0..5 {
        let f = Fixture::new();
        match case {
            0 => fs::remove_file(f.blob()).unwrap(),
            1 => fs::write(f.blob(), b"TAMPERED").unwrap(),
            2 => {
                let bytes = [0xff];
                let digest = hash(&bytes);
                let p = f.root.join("knowledge-v1/blobs").join(&digest);
                fs::write(&p, bytes).unwrap();
                fs::set_permissions(p, fs::Permissions::from_mode(0o600)).unwrap();
                f.edit(|v| {
                    v["items"][0]["contentSha256"] = json!(digest);
                    v["items"][0]["summary"]["byteSize"] = json!(1);
                    v["items"][0]["revisions"][1]["contentSha256"] =
                        v["items"][0]["contentSha256"].clone();
                    v["items"][0]["revisions"][1]["byteSize"] = json!(1);
                });
            }
            3 => fs::remove_file(f.archive()).unwrap(),
            _ => f.edit(|v| {
                v["items"][0]["summary"]["archive"]["format"] = json!("mhtml");
                for rev in v["items"][0]["revisions"].as_array_mut().unwrap() {
                    rev["archive"]["format"] = json!("mhtml");
                }
            }),
        }
        assert!(f.store.plan(&f.destination()).is_err());
        f.no_output();
    }
}
#[test]
fn known_missing_truncated_and_unknown_archive_completeness_are_not_exportable() {
    for case in 0..3 {
        let f = Fixture::new();
        f.edit(|v| {
            let a = &mut v["items"][0]["summary"]["archive"];
            match case {
                0 => a["missingResourceCount"] = json!(1),
                1 => a["wasTruncated"] = json!(true),
                _ => a["embeddedResourceCount"] = Value::Null,
            };
            let a = a.clone();
            for r in v["items"][0]["revisions"].as_array_mut().unwrap() {
                r["archive"] = a.clone();
            }
        });
        assert_eq!(
            f.store.plan(&f.destination()).unwrap_err().code,
            "knowledge_backup_incomplete"
        );
        f.no_output();
    }
}
fn operation() -> Value {
    json!({"operationId":Uuid::new_v4().to_string(),"fingerprint":"b".repeat(64),"completedAtEpochSeconds":2,
        "receipt":{"documentId":Uuid::new_v4().to_string(),"title":"RECEIPT SECRET","action":"inserted","folderId":null,"fileSizeBytes":1,"archiveType":"none","allowsLocalSemanticIndex":false,"allowsRemoteAiUse":false,"savedAtEpochSeconds":1,"replayed":false}})
}
#[test]
fn excluded_operation_receipts_are_strictly_validated_before_sanitizing() {
    for case in 0..11 {
        let f = Fixture::new();
        f.edit(|v| {
            let mut o = operation();
            match case {
                0 => o["fingerprint"] = json!("invalid"),
                1 => o["completedAtEpochSeconds"] = json!(0),
                2 => o["receipt"]["action"] = json!("execute"),
                3 => o["receipt"]["replayed"] = json!(true),
                4 => o["receipt"]["unknownSecret"] = json!("never export"),
                5 => o["unknownState"] = json!("never export"),
                7 => o["receipt"]["savedAtEpochSeconds"] = json!(3),
                8 => o["receipt"]["folderId"] = json!(Uuid::new_v4().to_string()),
                9 => o["receipt"]["fileSizeBytes"] = json!(0),
                _ => {}
            }
            v["completedOperations"] = if case == 6 {
                json!([o.clone(), o])
            } else {
                json!([o])
            };
        });
        if case == 10 {
            let source = String::from_utf8(fs::read(f.manifest_path()).unwrap()).unwrap();
            fs::write(
                f.manifest_path(),
                source.replacen(
                    "\"replayed\":false",
                    "\"replayed\":false,\"replayed\":false",
                    1,
                ),
            )
            .unwrap();
        }
        let before = fs::read(f.manifest_path()).unwrap();
        assert!(f.store.plan(&f.destination()).is_err());
        assert_eq!(fs::read(f.manifest_path()).unwrap(), before);
        f.no_output();
    }
}
#[test]
fn pdf_saved_extraction_and_metadata_are_included_but_original_pdf_is_not_opened_or_packaged() {
    let f = Fixture::new();
    f.edit(|v| {
        v["items"][0]["summary"]["sourceKind"] = json!("pdf");
        v["items"][0]["summary"]["sourceName"] = json!("PRIVATE ORIGINAL.pdf");
    });
    let original = f.root.parent().unwrap().join("PRIVATE ORIGINAL.pdf");
    fs::write(&original, b"%PDF-1.7 ORIGINAL PDF SECRET").unwrap();
    fs::set_permissions(&original, fs::Permissions::from_mode(0o000)).unwrap();
    let p = f.plan();
    assert!(p.exclusions.contains(&"sourcePdfFiles"));
    assert!(p.exclusions.contains(&"attachmentFiles"));
    f.store.execute(&p.plan_id, true).unwrap();
    let package: Value = serde_json::from_slice(&fs::read(f.destination()).unwrap()).unwrap();
    assert_eq!(
        package["manifest"]["items"][0]["summary"]["sourceKind"],
        "pdf"
    );
    assert_eq!(
        package["manifest"]["items"][0]["summary"]["sourceName"],
        "PRIVATE ORIGINAL.pdf"
    );
    for entry in package["files"].as_array().unwrap() {
        let data = STANDARD.decode(entry["data"].as_str().unwrap()).unwrap();
        assert!(!String::from_utf8_lossy(&data).contains("ORIGINAL PDF SECRET"));
    }
    assert_eq!(fs::metadata(original).unwrap().mode() & 0o777, 0o000);
}
#[test]
fn permissions_hardlinks_symlinks_fifo_and_directory_redirects_never_open_outside_contents() {
    for case in 0..7 {
        let f = Fixture::new();
        let outside = f.out.join("outside");
        fs::write(&outside, b"OUTSIDE SECRET").unwrap();
        let path = f.blob();
        match case {
            0 => fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap(),
            1 => fs::hard_link(&path, f.out.join("linked")).unwrap(),
            2 => {
                fs::remove_file(&path).unwrap();
                symlink(&outside, &path).unwrap();
            }
            3 => {
                fs::remove_file(&path).unwrap();
                let name = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            }
            4 => {
                let p = f.root.join("knowledge-v1/blobs");
                fs::rename(&p, f.out.join("old-blobs")).unwrap();
                symlink(&f.out, &p).unwrap();
            }
            5 => fs::set_permissions(
                f.root.join("knowledge-v1"),
                fs::Permissions::from_mode(0o755),
            )
            .unwrap(),
            _ => {
                fs::remove_file(f.manifest_path()).unwrap();
                symlink(&outside, f.manifest_path()).unwrap();
            }
        }
        let start = Instant::now();
        assert!(f.store.plan(&f.destination()).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(fs::read(outside).unwrap(), b"OUTSIDE SECRET");
        assert!(!f.destination().exists());
    }
}
#[test]
fn manifest_and_per_file_caps_reject_sparse_oversize_without_export() {
    for case in 0..3 {
        let f = Fixture::new();
        let (p, n) = match case {
            0 => (f.manifest_path(), MANIFEST_BYTES + 1),
            1 => (f.blob(), 5 * 1024 * 1024 + 1),
            _ => (f.archive(), 24 * 1024 * 1024 + 1),
        };
        OpenOptions::new()
            .write(true)
            .open(p)
            .unwrap()
            .set_len(n)
            .unwrap();
        assert!(f.store.plan(&f.destination()).is_err());
        f.no_output();
    }
}
#[test]
fn total_declared_file_and_resource_caps_fail_before_missing_files_can_be_omitted() {
    for case in 0..2 {
        let f = Fixture::new();
        let mut template = f.manifest()["items"][0].clone();
        template["summary"]["revisionNumber"] = json!(1);
        template["summary"]["revisionCount"] = json!(1);
        template["summary"]["archive"] = Value::Null;
        let mut rev = template["revisions"][0].clone();
        rev["archive"] = Value::Null;
        template["revisions"] = json!([rev]);
        let mut items = Vec::new();
        for i in 0..if case == 0 { 1025 } else { 7 } {
            let mut item = template.clone();
            item["summary"]["itemId"] = json!(Uuid::new_v4().to_string());
            let digest = format!("{i:064x}");
            item["contentSha256"] = json!(digest);
            item["revisions"][0]["contentSha256"] = item["contentSha256"].clone();
            let size = if case == 0 { 1 } else { 5 * 1024 * 1024 };
            item["summary"]["byteSize"] = json!(size);
            item["revisions"][0]["byteSize"] = json!(size);
            items.push(item);
        }
        f.edit(|v| v["items"] = json!(items));
        assert!(f.store.plan(&f.destination()).is_err());
        f.no_output();
    }
}
#[test]
fn capture_phase_drift_does_not_issue_a_plan_or_write_output() {
    for phase in 0..2 {
        let f = Fixture::new();
        assert!(f
            .store
            .plan_checked(&f.destination(), |p| if p == phase {
                if phase == 0 {
                    f.edit(|v| v["items"][0]["summary"]["title"] = json!("CHANGED"));
                } else {
                    let bytes = fs::read(f.blob()).unwrap();
                    fs::write(f.blob(), bytes).unwrap();
                }
            })
            .is_err());
        f.no_output();
    }
}
#[test]
fn execution_revalidates_excluded_receipts_manifest_body_and_inode_identity() {
    for case in 0..4 {
        let f = Fixture::new();
        let p = f.plan();
        match case {
            0 => f.edit(|v| v["items"][0]["summary"]["title"] = json!("CHANGED")),
            1 => fs::write(f.blob(), b"CHANGED").unwrap(),
            2 => f.edit(|v| v["completedOperations"] = json!([{}])),
            _ => {
                let bytes = fs::read(f.blob()).unwrap();
                fs::remove_file(f.blob()).unwrap();
                fs::write(f.blob(), bytes).unwrap();
                fs::set_permissions(f.blob(), fs::Permissions::from_mode(0o600)).unwrap();
            }
        };
        assert!(f.store.execute(&p.plan_id, true).is_err());
        assert!(f.store.execute(&p.plan_id, true).is_err());
        f.no_output();
    }
}
#[test]
fn root_and_resource_directory_replacement_invalidate_frozen_bindings() {
    for case in 0..2 {
        let f = Fixture::new();
        let p = f.plan();
        let path = if case == 0 {
            f.root.clone()
        } else {
            f.root.join("knowledge-v1/blobs")
        };
        fs::rename(&path, f.out.join("old")).unwrap();
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(f.store.execute(&p.plan_id, true).is_err());
        assert!(!f.destination().exists());
    }
}
#[test]
fn target_scope_existing_file_extensions_git_and_aliases_fail_closed() {
    let f = Fixture::new();
    let target = f.destination();
    fs::write(&target, b"EXISTING").unwrap();
    assert!(f.store.plan(&target).is_err());
    assert_eq!(fs::read(&target).unwrap(), b"EXISTING");
    for p in [
        PathBuf::from("relative.json"),
        f.out.join("upper.JSON"),
        f.out.join("wrong.sqlite"),
        f.root.join("inside.json"),
        f.out.join("../escape.json"),
    ] {
        assert!(f.store.plan(&p).is_err());
    }
    let alias = f.out.join("alias");
    symlink(&f.out, &alias).unwrap();
    assert!(f.store.plan(&alias.join("new.json")).is_err());
    let writable = f.out.join("shared");
    fs::create_dir(&writable).unwrap();
    fs::set_permissions(&writable, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(f.store.plan(&writable.join("new.json")).is_err());
    for case in 0..3 {
        let p = f.out.join(format!("repository-{case}"));
        fs::create_dir(&p).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
        if case == 0 {
            fs::create_dir(p.join(".git")).unwrap();
            fs::write(p.join(".git/HEAD"), b"ref: refs/heads/main").unwrap();
        } else if case == 1 {
            fs::write(p.join(".git"), b"gitdir: /outside").unwrap();
        } else {
            fs::write(p.join("HEAD"), b"ref").unwrap();
            fs::write(p.join("config"), b"config").unwrap();
            fs::create_dir(p.join("objects")).unwrap();
        }
        assert!(f.store.plan(&p.join("new.json")).is_err());
        assert!(!p.join("new.json").exists());
    }
}
#[test]
fn collision_and_precommit_source_drift_preserve_files_and_remove_temporary_output() {
    for case in 0..3 {
        let f = Fixture::new();
        let p = f.plan();
        let result = f.store.execute_checked(&p.plan_id, true, |phase| {
            if phase == if case == 2 { 1 } else { 0 } {
                if case == 0 {
                    fs::write(f.destination(), b"COLLISION").unwrap();
                } else {
                    fs::write(f.blob(), b"CHANGED").unwrap();
                }
            }
        });
        assert!(result.is_err());
        assert!(f.store.execute(&p.plan_id, true).is_err());
        if case == 0 {
            assert_eq!(fs::read(f.destination()).unwrap(), b"COLLISION");
            assert_eq!(fs::read_dir(&f.out).unwrap().count(), 1);
        } else {
            f.no_output();
        }
    }
}
#[test]
fn precommit_destination_replacement_cannot_redirect_package_or_leave_temp_file() {
    let f = Fixture::new();
    let p = f.plan();
    let old = f.root.parent().unwrap().join("old-exports");
    let outside = f.root.parent().unwrap().join("outside");
    fs::create_dir(&outside).unwrap();
    fs::set_permissions(&outside, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(f
        .store
        .execute_checked(&p.plan_id, true, |phase| if phase == 1 {
            fs::rename(&f.out, &old).unwrap();
            symlink(&outside, &f.out).unwrap();
        })
        .is_err());
    assert_eq!(fs::read_dir(old).unwrap().count(), 0);
    assert_eq!(fs::read_dir(outside).unwrap().count(), 0);
}
#[test]
fn final_git_marker_appearance_rejects_publication() {
    let f = Fixture::new();
    let p = f.plan();
    assert!(f
        .store
        .execute_checked(&p.plan_id, true, |phase| if phase == 1 {
            fs::create_dir(f.out.join(".git")).unwrap();
            fs::write(f.out.join(".git/HEAD"), b"ref").unwrap();
        })
        .is_err());
    assert!(!f.destination().exists());
    assert!(f.store.execute(&p.plan_id, true).is_err());
}
#[test]
fn post_publication_drift_is_unconfirmed_with_private_frozen_copy_retained() {
    let f = Fixture::new();
    let p = f.plan();
    let e = f
        .store
        .execute_checked(&p.plan_id, true, |phase| {
            if phase == 2 {
                fs::write(f.blob(), b"AFTER PUBLICATION").unwrap();
            }
        })
        .unwrap_err();
    assert_eq!(e.code, "knowledge_backup_unconfirmed");
    let bytes = fs::read(f.destination()).unwrap();
    assert_eq!(hash(&bytes), p.sha256);
    assert_eq!(fs::metadata(f.destination()).unwrap().mode() & 0o777, 0o600);
    assert!(f.store.execute(&p.plan_id, true).is_err());
}
