use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_backup::KnowledgeBackupStore,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
};
use serde_json::{json, Value};
use std::{
    ffi::CString,
    fs,
    os::unix::fs::{symlink, PermissionsExt},
    path::PathBuf,
    time::{Duration, Instant},
};

struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    source: PathBuf,
    out: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("library");
        let out = temp.path().join("out");
        fs::create_dir(&root).unwrap();
        fs::create_dir(&out).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&out, fs::Permissions::from_mode(0o700)).unwrap();
        let library = KnowledgeLibraryStore::new(root.clone()).unwrap();
        library
            .import_with_archive(
                KnowledgeImportRequest {
                    source_kind: KnowledgeSourceKind::Text,
                    title: "test title".into(),
                    source_name: "test source".into(),
                    source_url: None,
                    text: "test body".into(),
                    allows_local_semantic_index: false,
                    allows_remote_ai_use: false,
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
        let source = out.join("package.json");
        let backup = KnowledgeBackupStore::new(root.clone());
        let plan = backup.plan(&source).unwrap();
        backup.execute(&plan.plan_id, true).unwrap();
        Self {
            _temp: temp,
            root,
            source,
            out,
        }
    }
    fn bytes(&self) -> Vec<u8> {
        fs::read(&self.source).unwrap()
    }
    fn value(&self) -> Value {
        serde_json::from_slice(&self.bytes()).unwrap()
    }
    fn manifest_path(&self) -> PathBuf {
        self.root.join("knowledge-v1/manifest.json")
    }
    fn edit_manifest(&self, change: impl FnOnce(&mut Value)) {
        let mut value: Value =
            serde_json::from_slice(&fs::read(self.manifest_path()).unwrap()).unwrap();
        change(&mut value);
        fs::write(self.manifest_path(), serde_json::to_vec(&value).unwrap()).unwrap();
    }
}

#[test]
fn real_backup_export_is_accepted_and_inspection_does_not_write() {
    let f = Fixture::new();
    let before = fs::read_dir(&f.out).unwrap().count();
    let store = KnowledgePackageCheckStore::default();
    let report = store.inspect(&f.source).unwrap();
    assert!(report.structure_verified && report.content_verified);
    assert!(!report.filesystem_writes && !report.current_library_changed && !report.restore_ready);
    assert_eq!(fs::read_dir(&f.out).unwrap().count(), before);
}

#[test]
fn empty_real_backup_export_is_valid_and_has_no_resources() {
    let f = Fixture::new();
    f.edit_manifest(|v| {
        v["items"] = json!([]);
        v["folders"] = json!([]);
        v["completedOperations"] = json!([]);
    });
    let source = f.out.join("empty.json");
    let backup = KnowledgeBackupStore::new(f.root.clone());
    let plan = backup.plan(&source).unwrap();
    backup.execute(&plan.plan_id, true).unwrap();
    let report = KnowledgePackageCheckStore::default()
        .inspect(&source)
        .unwrap();
    assert_eq!(report.body_file_count, 0);
    assert_eq!(report.archive_file_count, 0);
    assert_eq!(report.resource_byte_size, 0);
}

#[test]
fn malformed_structure_hash_and_limits_fail_closed_before_decode() {
    let f = Fixture::new();
    let original = f.value();
    let mut cases = Vec::new();
    let mut path = original.clone();
    path["files"][0]["path"] = json!("../escape");
    cases.push(path);
    let mut hash = original.clone();
    hash["files"][0]["sha256"] = json!("0".repeat(64));
    cases.push(hash);
    let mut huge = original.clone();
    huge["files"][0]["byteSize"] = json!(48_u64 * 1024 * 1024 + 1);
    cases.push(huge);
    let mut unknown = original.clone();
    unknown["unexpected"] = json!(true);
    cases.push(unknown);
    for key in [
        "format",
        "schemaVersion",
        "sourceManifestSchemaVersion",
        "scope",
        "capturedAtEpochMs",
        "manifestSha256",
        "sourceManifestSha256",
        "exclusions",
        "allSavedReferencesIncluded",
        "consistentSnapshot",
        "includesCredentialStores",
        "includesCompletedOperations",
        "externalReferencesIncluded",
    ] {
        let mut changed = original.clone();
        changed[key] = match key {
            "format" => json!("wrong"),
            "schemaVersion" => json!(2),
            "sourceManifestSchemaVersion" => json!(3),
            "scope" => json!("wrong"),
            "capturedAtEpochMs" => json!(0),
            "manifestSha256" | "sourceManifestSha256" => json!("0"),
            "exclusions" => json!([]),
            "allSavedReferencesIncluded" => json!(false),
            "consistentSnapshot"
            | "includesCredentialStores"
            | "includesCompletedOperations"
            | "externalReferencesIncluded" => json!(true),
            _ => json!(null),
        };
        cases.push(changed);
    }
    let mut completed = original.clone();
    completed["manifest"]["completedOperations"] = json!([{"operationId":"unexpected"}]);
    cases.push(completed);
    let mut missing = original.clone();
    missing["files"] = json!([]);
    cases.push(missing);
    let mut extra = original.clone();
    extra["files"]
        .as_array_mut()
        .unwrap()
        .push(original["files"][0].clone());
    cases.push(extra);
    let mut same_length_duplicate = original.clone();
    same_length_duplicate["files"][1] = original["files"][0].clone();
    cases.push(same_length_duplicate);
    let mut invalid_base64 = original.clone();
    invalid_base64["files"][0]["data"] = json!("!");
    cases.push(invalid_base64);
    let mut noncanonical = original.clone();
    noncanonical["files"][0]["data"] = json!(" ");
    cases.push(noncanonical);
    for value in cases {
        let bytes = serde_json::to_vec(&value).unwrap();
        assert!(validate(&bytes, Instant::now()).is_err());
    }
    assert!(validate(br#"\xff"#, Instant::now()).is_err());
}

#[test]
fn duplicate_keys_at_any_json_depth_are_rejected() {
    let f = Fixture::new();
    let value = f.value();
    let text = serde_json::to_string(&value).unwrap();
    let nested = text.replace(
        "\"manifest\":{",
        "\"manifest\":{\"schemaVersion\":4,\"schemaVersion\":4,",
    );
    assert!(validate(nested.as_bytes(), Instant::now()).is_err());
    let nested = br#"{"format":"repopress-knowledge-saved-files","format":"repopress-knowledge-saved-files"}"#;
    assert!(validate(nested, Instant::now()).is_err());
}

#[test]
fn inspect_revalidates_source_and_rejects_links_hardlinks_and_non_regular_files() {
    let f = Fixture::new();
    let store = KnowledgePackageCheckStore::default();
    let first = store.inspect(&f.source).unwrap();
    assert_eq!(first.source_path, f.source.to_string_lossy());
    let original = f.bytes();
    fs::write(
        &f.source,
        original
            .iter()
            .chain([b' '].iter())
            .copied()
            .collect::<Vec<_>>(),
    )
    .unwrap();
    assert!(store.preflight(&first.report_id).is_err());
    fs::write(&f.source, original).unwrap();
    let link = f.out.join("link.json");
    symlink(&f.source, &link).unwrap();
    assert!(store.inspect(&link).is_err());
    let hard = f.out.join("hard.json");
    fs::hard_link(&f.source, &hard).unwrap();
    assert!(store.inspect(&hard).is_err());
    let fifo = f.out.join("fifo.json");
    let fifo_name = CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
    assert!(store.inspect(&fifo).is_err());
    let mode = fs::metadata(&f.source).unwrap().permissions();
    fs::set_permissions(&f.source, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(store.inspect(&f.source).is_err());
    fs::set_permissions(&f.source, mode).unwrap();
}

#[test]
fn inspect_rejects_path_aliases_and_phase_mutations() {
    let f = Fixture::new();
    let store = KnowledgePackageCheckStore::default();
    assert!(store
        .inspect(
            PathBuf::from(f.source.to_string_lossy().replace("/out/", "/out/../out/")).as_path()
        )
        .is_err());
    for phase in 0..=2 {
        let fixture = Fixture::new();
        let bytes = fixture.bytes();
        let result = store.inspect_checked(&fixture.source, |seen| {
            if seen == phase {
                fs::write(&fixture.source, &bytes).unwrap();
            }
        });
        assert!(
            result.is_err(),
            "source mutation at phase {phase} must fail"
        );
    }
    let fixture = Fixture::new();
    let parent = fixture.source.parent().unwrap().to_path_buf();
    let moved = parent.with_extension("moved");
    fs::rename(&parent, &moved).unwrap();
    assert!(store.inspect(&fixture.source).is_err());
    fs::rename(&moved, &parent).unwrap();
    let parent_link = fixture.out.join("parent-link");
    symlink(&parent, &parent_link).unwrap();
    assert!(store.inspect(&parent_link.join("package.json")).is_err());
}

#[test]
fn validation_budget_and_preflight_inode_swap_fail_closed() {
    assert!(validate(b"{}", Instant::now() - Duration::from_secs(6)).is_err());
    assert!(validate(&vec![b' '; 48 * 1024 * 1024 + 1], Instant::now()).is_err());
    let f = Fixture::new();
    let store = KnowledgePackageCheckStore::default();
    let report = store.inspect(&f.source).unwrap();
    let replacement = f.out.join("replacement.json");
    fs::copy(&f.source, &replacement).unwrap();
    fs::set_permissions(&replacement, fs::Permissions::from_mode(0o600)).unwrap();
    let result = store.preflight_checked(&report.report_id, |phase| {
        if phase == 0 {
            fs::rename(&replacement, &f.source).unwrap();
        }
    });
    assert!(result.is_err());
}

#[test]
fn preflight_is_one_shot_ephemeral_and_discardable() {
    let f = Fixture::new();
    let store = KnowledgePackageCheckStore::default();
    let report = store.inspect(&f.source).unwrap();
    let before = fs::read_dir(&f.out).unwrap().count();
    let staged = store.preflight(&report.report_id).unwrap();
    assert_eq!(staged.report_id, report.report_id);
    assert_eq!(staged.staging, "ephemeralMemory");
    assert!(!staged.filesystem_writes && !staged.current_library_changed && !staged.restore_ready);
    assert_eq!(fs::read_dir(&f.out).unwrap().count(), before);
    assert!(store.preflight(&report.report_id).is_err());
    store.discard(&report.report_id).unwrap();
    assert!(store.preflight(&report.report_id).is_err());
    store.discard(&report.report_id).unwrap();
}

#[test]
fn report_capacity_expiry_and_replay_are_bounded() {
    let f = Fixture::new();
    let store = KnowledgePackageCheckStore::default();
    let first = store.inspect(&f.source).unwrap();
    let second = store.inspect(&f.source).unwrap();
    assert!(store.inspect(&f.source).is_err());
    store
        .bindings
        .lock()
        .unwrap()
        .get_mut(&first.report_id)
        .unwrap()
        .created -= Duration::from_secs(301);
    assert!(store.preflight(&first.report_id).is_err());
    assert!(store.preflight(&first.report_id).is_err());
    let wallclock = store.inspect(&f.source).unwrap();
    store
        .bindings
        .lock()
        .unwrap()
        .get_mut(&wallclock.report_id)
        .unwrap()
        .report
        .expires_at_epoch_ms = 0;
    assert!(store.preflight(&wallclock.report_id).is_err());
    assert!(store.preflight(&wallclock.report_id).is_err());
    store.discard(&second.report_id).unwrap();
}

// Rebuild a valid closure first so each negative case reaches content/semantic validation.
fn replace_body(p: &mut Value, bytes: &[u8]) {
    let index = p["files"]
        .as_array()
        .unwrap()
        .iter()
        .position(|f| f["kind"] == "body")
        .unwrap();
    let old = p["files"][index]["sha256"].as_str().unwrap().to_owned();
    let new = hash(bytes);
    p["files"][index]["sha256"] = json!(new);
    p["files"][index]["path"] = json!(format!("blobs/{new}"));
    p["files"][index]["byteSize"] = json!(bytes.len());
    p["files"][index]["data"] = json!(STANDARD.encode(bytes));
    for item in p["manifest"]["items"].as_array_mut().unwrap() {
        if item["contentSha256"] == old {
            item["contentSha256"] = json!(new);
            item["summary"]["byteSize"] = json!(bytes.len());
        }
        for revision in item["revisions"].as_array_mut().unwrap() {
            if revision["contentSha256"] == old {
                revision["contentSha256"] = json!(new);
                revision["byteSize"] = json!(bytes.len());
            }
        }
    }
    refresh_manifest_hash(p);
}
fn refresh_manifest_hash(p: &mut Value) {
    p["manifestSha256"] = json!(hash(&serde_json::to_vec(&p["manifest"]).unwrap()));
}
#[test]
fn content_stage_rejects_invalid_utf8_padding_bits_and_partial_archive_semantics() {
    let f = Fixture::new();
    let mut valid = f.value();
    replace_body(&mut valid, b"f");
    assert!(validate(&serde_json::to_vec(&valid).unwrap(), Instant::now()).is_ok());
    let mut wrong_bits = valid.clone();
    let index = wrong_bits["files"]
        .as_array()
        .unwrap()
        .iter()
        .position(|f| f["kind"] == "body")
        .unwrap();
    wrong_bits["files"][index]["data"] = json!("Zh==");
    assert!(validate(&serde_json::to_vec(&wrong_bits).unwrap(), Instant::now()).is_err());
    let mut invalid_utf8 = valid.clone();
    replace_body(&mut invalid_utf8, &[0xff]);
    assert!(validate(&serde_json::to_vec(&invalid_utf8).unwrap(), Instant::now()).is_err());
    for (key, value) in [
        ("missingResourceCount", json!(1)),
        ("embeddedResourceCount", Value::Null),
        ("missingResourceCount", Value::Null),
        ("wasTruncated", json!(true)),
    ] {
        let mut partial = f.value();
        for item in partial["manifest"]["items"].as_array_mut().unwrap() {
            item["summary"]["archive"][key] = value.clone();
            for revision in item["revisions"].as_array_mut().unwrap() {
                revision["archive"][key] = value.clone();
            }
        }
        refresh_manifest_hash(&mut partial);
        assert!(
            validate(&serde_json::to_vec(&partial).unwrap(), Instant::now()).is_err(),
            "archive semantic {key}"
        );
    }
}
#[test]
fn original_manifest_digest_is_unverifiable_and_dtos_omit_saved_content() {
    let f = Fixture::new();
    let mut p = f.value();
    p["sourceManifestSha256"] = json!("a".repeat(64));
    let raw = serde_json::to_vec(&p).unwrap();
    assert!(validate(&raw, Instant::now()).is_ok());
    fs::write(&f.source, &raw).unwrap();
    let store = KnowledgePackageCheckStore::default();
    let report = store.inspect(&f.source).unwrap();
    assert!(!report.source_manifest_hash_verified);
    assert_eq!(report.sha256, hash(&raw));
    let result = store.preflight(&report.report_id).unwrap();
    for dto in [
        serde_json::to_string(&report).unwrap(),
        serde_json::to_string(&result).unwrap(),
    ] {
        for secret in [
            "test title",
            "test source",
            "test body",
            "<html>archive</html>",
            "sourceManifestSha256",
            "\"manifest\":",
            "\"files\":",
            "\"data\":",
        ] {
            assert!(!dto.contains(secret), "DTO leaked {secret}");
        }
    }
    assert_eq!(fs::read(&f.source).unwrap(), raw);
}
#[test]
fn duplicate_valid_fields_and_json_depth_node_budgets_are_rejected() {
    let f = Fixture::new();
    let original = String::from_utf8(f.bytes()).unwrap();
    for key in [
        "\"schemaVersion\":4",
        "\"title\":\"test title\"",
        "\"kind\":\"body\"",
    ] {
        let duplicated = original.replacen(key, &format!("{key},{key}"), 1);
        assert_ne!(duplicated, original);
        // The collapsed Value is identical and valid; rejection must come from duplicate detection.
        let collapsed: Value = serde_json::from_str(&duplicated).unwrap();
        assert!(validate(&serde_json::to_vec(&collapsed).unwrap(), Instant::now()).is_ok());
        assert!(validate(duplicated.as_bytes(), Instant::now()).is_err());
    }
    let mut deserializer = serde_json::Deserializer::from_str("[null,null]");
    assert!(Seed(&mut Budget {
        nodes: JSON_NODES - 1,
        started: Instant::now()
    })
    .deserialize(&mut deserializer)
    .is_err());
    let nested = format!("{}0{}", "[".repeat(129), "]".repeat(129));
    let mut deserializer = serde_json::Deserializer::from_str(&nested);
    assert!(Seed(&mut Budget {
        nodes: 0,
        started: Instant::now()
    })
    .deserialize(&mut deserializer)
    .is_err());
}
#[test]
fn selected_file_permission_and_parent_identity_are_independently_enforced() {
    let f = Fixture::new();
    let store = KnowledgePackageCheckStore::default();
    fs::set_permissions(&f.source, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(store.inspect(&f.source).is_err());
    fs::set_permissions(&f.source, fs::Permissions::from_mode(0o600)).unwrap();
    let report = store.inspect(&f.source).unwrap();
    let moved = f.out.with_extension("moved");
    let result = store.preflight_checked(&report.report_id, |phase| {
        if phase == 1 {
            fs::rename(&f.out, &moved).unwrap();
            fs::create_dir(&f.out).unwrap();
            fs::set_permissions(&f.out, fs::Permissions::from_mode(0o700)).unwrap();
            fs::copy(moved.join("package.json"), &f.source).unwrap();
            fs::set_permissions(&f.source, fs::Permissions::from_mode(0o600)).unwrap();
        }
    });
    assert!(result.is_err());
    assert!(store.preflight(&report.report_id).is_err());
}
