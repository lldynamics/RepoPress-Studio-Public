use super::*;
use crate::core::{
    browser_capture::BrowserCaptureArchive,
    knowledge_library::{KnowledgeImportRequest, KnowledgeLibraryStore, KnowledgeSourceKind},
};
use serde_json::{json, Value};
use std::{
    fs,
    os::unix::fs::{symlink, PermissionsExt},
};
struct Fixture {
    temp: tempfile::TempDir,
    root: PathBuf,
    store: KnowledgeIntegrityStore,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("data");
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let library = KnowledgeLibraryStore::new(root.clone()).unwrap();
        for text in ["PRIVATE BODY ONE", "PRIVATE BODY TWO"] {
            library
                .import_with_archive(
                    KnowledgeImportRequest {
                        source_kind: KnowledgeSourceKind::Text,
                        title: "PRIVATE TITLE".into(),
                        source_name: "PRIVATE SOURCE/secret/path".into(),
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
        Self {
            store: KnowledgeIntegrityStore::new(root.clone()),
            temp,
            root,
        }
    }
    fn manifest_path(&self) -> PathBuf {
        self.root.join("knowledge-v1/manifest.json")
    }
    fn manifest(&self) -> Value {
        serde_json::from_slice(&fs::read(self.manifest_path()).unwrap()).unwrap()
    }
    fn edit(&self, action: impl FnOnce(&mut Value)) {
        let mut v = self.manifest();
        action(&mut v);
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
    fn inspect(&self) -> KnowledgeIntegrityReport {
        self.store.inspect().unwrap()
    }
    fn write_body(&self, bytes: &[u8]) {
        let digest = hash(bytes);
        let path = self.root.join("knowledge-v1/blobs").join(&digest);
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        self.edit(|v| {
            v["items"][0]["contentSha256"] = json!(digest);
            v["items"][0]["summary"]["byteSize"] = json!(bytes.len());
            v["items"][0]["revisions"][0]["byteSize"] = json!(bytes.len());
            v["items"][0]["revisions"][0]["contentSha256"] = v["items"][0]["contentSha256"].clone();
        });
    }
}
fn inventory(root: &Path) -> Vec<(PathBuf, Vec<u8>, u32)> {
    let mut result = Vec::new();
    for d in [
        "knowledge-v1",
        "knowledge-v1/blobs",
        "knowledge-v1/archives",
    ] {
        for entry in fs::read_dir(root.join(d)).unwrap() {
            let p = entry.unwrap().path();
            let m = fs::symlink_metadata(&p).unwrap();
            if m.is_file() {
                result.push((p.clone(), fs::read(p).unwrap(), m.mode()));
            }
        }
    }
    result.sort_by(|a, b| a.0.cmp(&b.0));
    result
}
#[test]
fn all_history_and_shared_archives_verified_without_gc_or_sensitive_output() {
    let f = Fixture::new();
    let orphan = f.root.join("knowledge-v1/blobs/unreferenced");
    fs::write(&orphan, b"DO NOT COLLECT").unwrap();
    fs::set_permissions(&orphan, fs::Permissions::from_mode(0o600)).unwrap();
    let before = inventory(&f.root);
    let first = f.inspect();
    assert_eq!(first.status, "checked");
    assert!(first.all_referenced_files_verified);
    assert_eq!(first.revision_count, Some(2));
    assert_eq!(first.resources[1].reference_count, 2);
    assert_eq!(first.resources[1].unique_files, 1);
    assert_eq!(first.resources[1].verified, 1);
    let j = serde_json::to_string(&first).unwrap();
    for sensitive in [
        "PRIVATE",
        "secret/path",
        "DO NOT COLLECT",
        f.root.to_str().unwrap(),
    ] {
        assert!(!j.contains(sensitive));
    }
    assert!(j.contains("\"unsafe\":0"));
    assert!(!first.consistent_snapshot && !first.backup_ready);
    assert_eq!(inventory(&f.root), before);
    f.store.discard(&first.report_id).unwrap();
    // Historical revisions must remain in the reference set after current content changes.
    let text = b"NEW HISTORICAL CURRENT";
    let sha = hash(text);
    let path = f.root.join("knowledge-v1/blobs").join(&sha);
    fs::write(&path, text).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    f.edit(|v| {
        let item = &mut v["items"][0];
        let mut revision = item["revisions"][0].clone();
        revision["revisionNumber"] = json!(2);
        revision["byteSize"] = json!(text.len());
        revision["contentSha256"] = json!(sha);
        item["revisions"].as_array_mut().unwrap().push(revision);
        item["contentSha256"] = json!(sha);
        item["summary"]["byteSize"] = json!(text.len());
        item["summary"]["revisionNumber"] = json!(2);
        item["summary"]["revisionCount"] = json!(2);
    });
    let r = f.inspect();
    assert_eq!(r.status, "checked");
    assert_eq!(r.revision_count, Some(3));
    assert_eq!(r.resources[0].unique_files, 3);
    assert_eq!(r.resources[1].reference_count, 3);
    f.store.discard(&r.report_id).unwrap();
    let older = f.manifest()["items"][0]["revisions"][0]["contentSha256"]
        .as_str()
        .unwrap()
        .to_string();
    fs::remove_file(f.root.join("knowledge-v1/blobs").join(older)).unwrap();
    let r = f.inspect();
    assert_eq!(r.status, "partial");
    assert_eq!(r.resources[0].missing, 1);
}
#[test]
fn missing_manifest_and_default_are_unavailable_without_creating_files() {
    let temp = tempfile::tempdir().unwrap();
    let store = KnowledgeIntegrityStore::new(temp.path().into());
    let r = store.inspect().unwrap();
    assert_eq!(r.manifest_state, "missing");
    assert_eq!(r.item_count, None);
    assert!(r.resources.is_empty());
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 0);
    let r = KnowledgeIntegrityStore::default().inspect().unwrap();
    assert_eq!(r.status, "unavailable");
    assert!(!r.all_referenced_files_verified);
    let f = Fixture::new();
    fs::remove_file(f.manifest_path()).unwrap();
    let before = inventory(&f.root);
    assert_eq!(f.inspect().manifest_state, "missing");
    assert_eq!(inventory(&f.root), before);
}
#[test]
fn empty_known_manifest_is_checked_but_unsupported_versions_not_migrated() {
    let f = Fixture::new();
    f.edit(|v| {
        v["items"] = json!([]);
    });
    let before = inventory(&f.root);
    let r = f.inspect();
    assert_eq!(r.status, "checked");
    assert_eq!(r.item_count, Some(0));
    assert!(r.all_referenced_files_verified);
    assert_eq!(inventory(&f.root), before);
    for version in [
        0,
        1,
        2,
        3,
        5,
        u32::MAX as u64,
        u32::MAX as u64 + 1,
        u64::MAX,
    ] {
        let f = Fixture::new();
        f.edit(|v| v["schemaVersion"] = json!(version));
        let before = inventory(&f.root);
        let r = f.inspect();
        assert_eq!(r.manifest_state, "unsupported");
        assert_eq!(r.resources.len(), 0);
        assert_eq!(inventory(&f.root), before);
    }
}
#[test]
fn malformed_duplicate_unknown_and_inconsistent_manifest_are_rejected_without_body_reads() {
    for case in 0..10 {
        let f = Fixture::new();
        f.edit(|v| match case {
            0 => v["items"][0]["contentSha256"] = json!("../../outside"),
            1 => v["items"][0]["summary"]["itemId"] = json!("bad"),
            2 => v["items"][0]["summary"]["folderId"] = json!(Uuid::new_v4().to_string()),
            3 => v["items"][0]["summary"]["revisionCount"] = json!(10),
            4 => v["items"][0]["revisions"] = json!([]),
            5 => v["items"][0]["revisions"][0]["path"] = json!("PRIVATE unknown path"),
            6 => v["unknown"] = json!(true),
            7 => {
                let copy = v["items"][0].clone();
                v["items"].as_array_mut().unwrap().push(copy);
            }
            8 => v["items"][0]["summary"]["sourceUrl"] = json!("https://example.test"),
            _ => v["items"][0]["revisions"][0]["contentSha256"] = json!("A".repeat(64)),
        });
        let r = f.inspect();
        assert_eq!(r.manifest_state, "invalid", "case {case}");
        assert!(r.resources.is_empty());
    }
    let f = Fixture::new();
    let bytes = fs::read_to_string(f.manifest_path()).unwrap().replacen(
        "\"schemaVersion\":4",
        "\"schemaVersion\":4,\"schemaVersion\":4",
        1,
    );
    fs::write(f.manifest_path(), bytes).unwrap();
    assert_eq!(f.inspect().manifest_state, "invalid");
}
#[test]
fn missing_corrupt_utf8_and_wrong_format_are_partitioned() {
    for case in 0..5 {
        let f = Fixture::new();
        match case {
            0 => {
                fs::remove_file(f.blob()).unwrap();
            }
            1 => {
                fs::write(f.blob(), b"TAMPERED BODY").unwrap();
            }
            2 => f.write_body(&[0xff]),
            3 => {
                fs::remove_file(f.archive()).unwrap();
            }
            _ => {
                f.edit(|v| {
                    for item in v["items"].as_array_mut().unwrap() {
                        item["summary"]["archive"]["format"] = json!("mhtml");
                        item["revisions"][0]["archive"]["format"] = json!("mhtml");
                    }
                });
            }
        };
        let r = f.inspect();
        assert_eq!(r.status, "partial");
        assert!(!r.all_referenced_files_verified);
        assert!(r.resources.iter().any(|row| row.missing + row.invalid > 0));
        for row in &r.resources {
            assert_eq!(
                row.unique_files,
                row.verified
                    + row.missing
                    + row.unsafe_
                    + row.unreadable
                    + row.invalid
                    + row.changed
                    + row.omitted
            );
        }
    }
}
#[test]
fn archive_capture_missing_truncated_unknown_are_partial_even_when_file_verified() {
    for case in 0..3 {
        let f = Fixture::new();
        f.edit(|v| {
            for item in v["items"].as_array_mut().unwrap() {
                {
                    let a = &mut item["summary"]["archive"];
                    match case {
                        0 => a["missingResourceCount"] = json!(2),
                        1 => a["wasTruncated"] = json!(true),
                        _ => a["embeddedResourceCount"] = Value::Null,
                    };
                }
                item["revisions"][0]["archive"] = item["summary"]["archive"].clone();
            }
        });
        let r = f.inspect();
        assert_eq!(r.status, "partial");
        assert!(r.all_referenced_files_verified);
        assert_eq!(r.resources[1].verified, 1);
        assert!(r.issues.contains(&if case == 2 {
            "unknownArchiveCompleteness"
        } else {
            "incompleteArchive"
        }));
    }
}
#[test]
fn private_modes_links_fifo_and_directory_swaps_never_follow_or_write() {
    for case in 0..7 {
        let f = Fixture::new();
        let path = f.blob();
        let outside = f.temp.path().join("outside");
        fs::write(&outside, b"OUTSIDE SECRET").unwrap();
        match case {
            0 => {
                fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            }
            1 => {
                fs::hard_link(&path, f.temp.path().join("linked")).unwrap();
            }
            2 => {
                fs::remove_file(&path).unwrap();
                symlink(&outside, &path).unwrap();
            }
            3 => {
                fs::remove_file(&path).unwrap();
                use std::ffi::CString;
                let name = CString::new(path.to_str().unwrap()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            }
            4 => {
                let dir = f.root.join("knowledge-v1/blobs");
                fs::rename(&dir, f.temp.path().join("old-blobs")).unwrap();
                symlink(f.temp.path(), dir).unwrap();
            }
            5 => {
                fs::set_permissions(
                    f.root.join("knowledge-v1"),
                    fs::Permissions::from_mode(0o755),
                )
                .unwrap();
            }
            _ => {
                fs::remove_file(f.manifest_path()).unwrap();
                symlink(&outside, f.manifest_path()).unwrap();
            }
        };
        let started = Instant::now();
        let r = f.inspect();
        assert!(started.elapsed() < Duration::from_secs(2));
        assert_ne!(r.status, "checked");
        assert!(!r.all_referenced_files_verified);
        assert_eq!(fs::read(outside).unwrap(), b"OUTSIDE SECRET");
    }
}
#[test]
fn manifest_and_file_byte_caps_refuse_without_large_allocation() {
    let f = Fixture::new();
    OpenOptions::new()
        .write(true)
        .open(f.manifest_path())
        .unwrap()
        .set_len(MAX_MANIFEST + 1)
        .unwrap();
    assert_eq!(f.inspect().manifest_state, "tooLarge");
    let f = Fixture::new();
    OpenOptions::new()
        .write(true)
        .open(f.blob())
        .unwrap()
        .set_len(5 * 1024 * 1024 + 1)
        .unwrap();
    let r = f.inspect();
    assert_eq!(r.resources[0].invalid, 1);
    assert_eq!(r.status, "partial");
    let f = Fixture::new();
    let mut budget = 0;
    let start = Instant::now();
    let dir = workspace_backup::walk(
        &f.store.root.as_ref().unwrap().file,
        Path::new("knowledge-v1/blobs"),
        true,
    )
    .unwrap();
    let name = f.blob().file_name().unwrap().to_str().unwrap().to_string();
    let e = read(&dir, &name, 5 * 1024 * 1024, &mut budget, start).unwrap_err();
    assert_eq!(e.issue, "byteLimit");
    let mut budget = MAX_BYTES;
    let e = read(&dir, &name, 5 * 1024 * 1024, &mut budget, start - TIME).unwrap_err();
    assert_eq!(e.issue, "timeLimit");
}
#[test]
fn full_reference_count_exceeding_file_limit_is_preserved_as_omitted() {
    let f = Fixture::new();
    let template = f.manifest()["items"][0].clone();
    let mut items = Vec::new();
    for n in 0..MAX_FILES + 1 {
        let mut item = template.clone();
        item["summary"]["itemId"] = json!(Uuid::new_v4().to_string());
        let sha = hash(format!("body {n}").as_bytes());
        item["contentSha256"] = json!(sha);
        item["summary"]["byteSize"] = json!(1);
        item["revisions"][0]["contentSha256"] = json!(sha);
        item["revisions"][0]["byteSize"] = json!(1);
        item["summary"]["archive"] = Value::Null;
        item["revisions"][0]["archive"] = Value::Null;
        items.push(item);
    }
    f.edit(|v| v["items"] = json!(items));
    let r = f.inspect();
    assert_eq!(r.manifest_state, "verified");
    assert_eq!(r.item_count, Some(1025));
    assert_eq!(r.resources[0].unique_files, 1025);
    assert_eq!(r.resources[0].missing, 1024);
    assert_eq!(r.resources[0].omitted, 1);
    assert!(r.issues.contains(&"fileLimit"));
    assert_eq!(r.status, "partial");
}
#[test]
fn resource_budget_omissions_are_explicit_after_dedup_projection() {
    let f = Fixture::new();
    let bytes = vec![b'x'; 5 * 1024 * 1024];
    let template = f.manifest()["items"][0].clone();
    let mut items = Vec::new();
    // 64 MiB body capacity plus an archive can still exceed the per-inspection read budget.
    for n in 0..13 {
        let mut bytes = bytes.clone();
        bytes[0] = b'a' + n;
        let sha = hash(&bytes);
        let path = f.root.join("knowledge-v1/blobs").join(&sha);
        fs::write(&path, &bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let mut item = template.clone();
        item["summary"]["itemId"] = json!(Uuid::new_v4().to_string());
        item["contentSha256"] = json!(sha);
        item["summary"]["byteSize"] = json!(bytes.len());
        item["revisions"][0]["contentSha256"] = json!(sha);
        item["revisions"][0]["byteSize"] = json!(bytes.len());
        items.push(item);
    }
    // Twelve 5 MiB blobs + one 4 MiB blob reach the allowed library 64 MiB.
    let last = items.last_mut().unwrap();
    let body = vec![b'z'; 4 * 1024 * 1024];
    let sha = hash(&body);
    let p = f.root.join("knowledge-v1/blobs").join(&sha);
    fs::write(&p, &body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o600)).unwrap();
    last["contentSha256"] = json!(sha);
    last["summary"]["byteSize"] = json!(body.len());
    last["revisions"][0]["contentSha256"] = json!(sha);
    last["revisions"][0]["byteSize"] = json!(body.len());
    f.edit(|v| v["items"] = json!(items));
    let r = f.inspect();
    assert_eq!(r.manifest_state, "verified");
    assert_eq!(r.resources[0].verified_bytes, MAX_BYTES);
    assert_eq!(r.resources[1].omitted, 1);
    assert!(r.issues.contains(&"byteLimit"));
    assert_eq!(r.status, "partial");
}
#[test]
fn internal_drift_during_final_checks_is_partial_with_old_success_removed() {
    for phase in [0, 1, 2] {
        let f = Fixture::new();
        let path = f.blob();
        let mut reports = f.store.reports.lock().unwrap();
        let r = f
            .store
            .capture_with_hook(&mut reports, |p| {
                if p == phase {
                    if phase == 2 {
                        fs::write(f.manifest_path(), b"{late manifest}").unwrap();
                    } else {
                        fs::write(&path, b"LATE PRIVATE BODY").unwrap();
                    }
                }
            })
            .unwrap()
            .0;
        assert_eq!(r.status, "partial");
        assert!(!r.all_referenced_files_verified);
        assert!(r.issues.contains(&"invalidContent") || r.issues.contains(&"changedDuringRead"));
        if phase == 1 {
            assert_eq!(r.resources[0].changed, 1);
        }
    }
}
#[test]
fn root_manifest_and_missing_reference_change_invalidate_report_comparison() {
    let f = Fixture::new();
    let first = f.inspect();
    let second = f.store.recheck(&first.report_id).unwrap();
    assert_eq!(second.comparison, "unchanged");
    assert_ne!(first.report_id, second.report.report_id);
    assert!(f.store.recheck(&first.report_id).is_err());
    f.edit(|v| v["items"][0]["summary"]["title"] = json!("Changed title"));
    let third = f.store.recheck(&second.report.report_id).unwrap();
    assert_eq!(third.comparison, "changed");
    fs::remove_file(f.blob()).unwrap();
    let partial = f.store.recheck(&third.report.report_id).unwrap();
    assert_eq!(partial.comparison, "inconclusive");
    assert_eq!(partial.report.status, "partial");
    let f = Fixture::new();
    let first = f.inspect();
    fs::rename(&f.root, f.temp.path().join("old-root")).unwrap();
    fs::create_dir(&f.root).unwrap();
    fs::set_permissions(&f.root, fs::Permissions::from_mode(0o700)).unwrap();
    let r = f.store.recheck(&first.report_id).unwrap();
    assert_eq!(r.comparison, "inconclusive");
    assert_eq!(r.report.status, "unavailable");
}
#[test]
fn capacity_expiry_discard_and_once_only_recheck_are_bounded() {
    let f = Fixture::new();
    let a = f.inspect();
    let b = f.inspect();
    assert!(f.store.inspect().is_err());
    f.store.discard(&a.report_id).unwrap();
    f.store.discard(&a.report_id).unwrap();
    assert!(f.store.recheck(&a.report_id).is_err());
    let c = f.inspect();
    f.store
        .reports
        .lock()
        .unwrap()
        .get_mut(&b.report_id)
        .unwrap()
        .created = Instant::now() - TTL;
    assert!(f.store.recheck(&b.report_id).is_err());
    let next = f.store.recheck(&c.report_id).unwrap();
    assert!(f.store.recheck(&c.report_id).is_err());
    assert_eq!(next.comparison, "unchanged");
    f.store.discard(&next.report.report_id).unwrap();
    assert!(f.store.recheck("unknown").is_err());
    assert!(f.store.inspect().is_ok());
}

#[test]
fn repeated_content_address_with_conflicting_size_is_invalid_manifest() {
    for archive in [false, true] {
        let f = Fixture::new();
        f.edit(|v| {
            if archive {
                let mut a = v["items"][0]["summary"]["archive"].clone();
                a["byteSize"] = json!(a["byteSize"].as_u64().unwrap() + 1);
                v["items"][1]["summary"]["archive"] = a.clone();
                v["items"][1]["revisions"][0]["archive"] = a;
            } else {
                let digest = v["items"][0]["contentSha256"].clone();
                let size = v["items"][0]["summary"]["byteSize"].as_u64().unwrap() + 1;
                v["items"][1]["contentSha256"] = digest.clone();
                v["items"][1]["summary"]["byteSize"] = json!(size);
                v["items"][1]["revisions"][0]["contentSha256"] = digest;
                v["items"][1]["revisions"][0]["byteSize"] = json!(size);
            }
        });
        let r = f.inspect();
        assert_eq!(r.manifest_state, "invalid");
        assert!(r.resources.is_empty());
    }
}
