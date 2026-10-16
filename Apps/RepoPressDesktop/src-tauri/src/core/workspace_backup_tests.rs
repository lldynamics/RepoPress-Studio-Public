use super::*;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};

fn dir(path: &Path) {
    fs::create_dir_all(path).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}
fn file(path: &Path, bytes: &[u8]) {
    dir(path.parent().unwrap());
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn source_file(root: &Path, source: BackupSource) -> PathBuf {
    let (d, f) = source.location();
    root.join(d).join(f)
}
fn row(report: &WorkspaceBackupReport) -> &BackupSourceInventory {
    &report.sources[0]
}
fn selected() -> Vec<BackupSource> {
    vec![
        BackupSource::Knowledge,
        BackupSource::Rss,
        BackupSource::GeneralDrafts,
        BackupSource::DraftHistory,
        BackupSource::Workspace,
        BackupSource::SiteProfiles,
        BackupSource::AiProfiles,
    ]
}
#[test]
fn allowlisted_seven_source_metadata_is_private_bounded_and_not_backup_authority() {
    let root = tempfile::tempdir().unwrap();
    for source in selected() {
        file(
            &source_file(root.path(), source),
            b"private invalid payload",
        );
    }
    let store = WorkspaceBackupStore::new(root.path().into());
    let report = store
        .inspect(selected().into_iter().rev().collect())
        .unwrap();
    assert_eq!(report.selected_sources, selected());
    assert!(!report.content_verified);
    assert!(!report.consistent_snapshot);
    assert_eq!(
        report.expires_at_epoch_ms - report.checked_at_epoch_ms,
        300_000
    );
    for r in &report.sources {
        assert_eq!(r.status, InventoryStatus::MetadataOnly);
        assert_eq!(r.file_count, Some(1));
        assert_eq!(r.byte_count, Some(23));
        assert_eq!(r.requires_database_snapshot, r.source.database());
    }
    let public = serde_json::to_string(&report).unwrap();
    assert!(!public.contains(root.path().to_str().unwrap()));
    assert!(!public.contains("private invalid payload"));
    assert!(!public.contains("reader.sqlite"));
    assert!(!public.contains("manifest.json"));
    assert_eq!(report.exclusions, EXCLUSIONS);
}
#[test]
fn knowledge_inventory_neither_reads_body_nor_cleans_orphan_blobs() {
    let root = tempfile::tempdir().unwrap();
    let blob = root.path().join("knowledge-v1/blobs").join("a".repeat(64));
    file(&blob, b"orphan private body");
    file(
        &source_file(root.path(), BackupSource::Knowledge),
        b"malformed JSON body must not parse or migrate",
    );
    let before = fs::metadata(&blob).unwrap();
    let store = WorkspaceBackupStore::new(root.path().into());
    let r = store.inspect(vec![BackupSource::Knowledge]).unwrap();
    let after = fs::metadata(&blob).unwrap();
    assert_eq!(row(&r).file_count, Some(2));
    assert_eq!(row(&r).status, InventoryStatus::MetadataOnly);
    assert_eq!(before.atime(), after.atime());
    assert_eq!(before.atime_nsec(), after.atime_nsec());
    assert_eq!(stamp(&before), stamp(&after));
    assert_eq!(fs::read(&blob).unwrap(), b"orphan private body");
}
#[test]
fn exclusions_unknown_files_and_unselected_sources_are_never_opened() {
    let root = tempfile::tempdir().unwrap();
    file(&source_file(root.path(), BackupSource::Workspace), b"state");
    let forbidden = root.path().join("ai-chat-v1");
    dir(&forbidden);
    let sentinel = forbidden.join("history.vault");
    file(&sentinel, b"private encrypted data");
    fs::set_permissions(&forbidden, fs::Permissions::from_mode(0o000)).unwrap();
    let unknown = root.path().join("workspace/private-token-secret");
    symlink("/nonexistent", &unknown).unwrap();
    symlink("/nonexistent", root.path().join("RSSReader")).unwrap();
    let store = WorkspaceBackupStore::new(root.path().into());
    let r = store.inspect(vec![BackupSource::Workspace]).unwrap();
    assert_eq!(r.sources.len(), 1);
    assert_eq!(row(&r).status, InventoryStatus::Limited);
    assert_eq!(row(&r).omitted_entries, Some(1));
    assert!(row(&r).issues.contains(&InventoryIssue::UnknownEntries));
    let public = serde_json::to_string(&r).unwrap();
    assert!(!public.contains("private-token-secret"));
    assert!(!public.contains("history.vault"));
    fs::set_permissions(&forbidden, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(fs::read(sentinel).unwrap(), b"private encrypted data");
}
#[test]
fn not_found_is_distinct_from_unavailable_and_memory_defaults() {
    let root = tempfile::tempdir().unwrap();
    let store = WorkspaceBackupStore::new(root.path().into());
    let r = store.inspect(vec![BackupSource::Rss]).unwrap();
    assert_eq!(row(&r).status, InventoryStatus::NotFound);
    assert_eq!(row(&r).file_count, Some(0));
    let r = WorkspaceBackupStore::default()
        .inspect(vec![BackupSource::Rss])
        .unwrap();
    assert_eq!(row(&r).status, InventoryStatus::Unavailable);
    assert_eq!(row(&r).file_count, None);
    assert_eq!(row(&r).byte_count, None);
    assert_eq!(row(&r).omitted_entries, None);
    let missing = WorkspaceBackupStore::new(root.path().join("does-not-exist"));
    assert_eq!(
        row(&missing.inspect(vec![BackupSource::Workspace]).unwrap()).status,
        InventoryStatus::Unavailable
    );
    assert!(!root.path().join("does-not-exist").exists());
}
#[test]
fn recheck_detects_same_size_content_metadata_change_and_burns_old_report() {
    let root = tempfile::tempdir().unwrap();
    let path = source_file(root.path(), BackupSource::Workspace);
    file(&path, b"aaaa");
    let store = WorkspaceBackupStore::new(root.path().into());
    let first = store.inspect(vec![BackupSource::Workspace]).unwrap();
    let same = store.recheck(&first.report_id).unwrap();
    assert!(matches!(same.comparison, BackupComparison::Unchanged));
    assert_ne!(same.report.report_id, first.report_id);
    assert!(store.recheck(&first.report_id).is_err());
    let original = fs::metadata(&path).unwrap();
    fs::write(&path, b"bbbb").unwrap();
    // Even restoring mtime cannot restore ctime; metadata equality never claims byte equality.
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let p = CString::new(path.as_os_str().as_bytes()).unwrap();
    let times = [
        libc::timespec {
            tv_sec: original.atime(),
            tv_nsec: original.atime_nsec(),
        },
        libc::timespec {
            tv_sec: original.mtime(),
            tv_nsec: original.mtime_nsec(),
        },
    ];
    assert_eq!(
        unsafe { libc::utimensat(libc::AT_FDCWD, p.as_ptr(), times.as_ptr(), 0) },
        0
    );
    let changed = store.recheck(&same.report.report_id).unwrap();
    assert!(matches!(changed.comparison, BackupComparison::Changed));
    assert!(!changed.report.content_verified);
}
#[test]
fn missing_storage_addition_deletion_and_file_replacement_are_detected() {
    let root = tempfile::tempdir().unwrap();
    let store = WorkspaceBackupStore::new(root.path().into());
    let absent = store.inspect(vec![BackupSource::Workspace]).unwrap();
    let path = source_file(root.path(), BackupSource::Workspace);
    file(&path, b"one");
    let added = store.recheck(&absent.report_id).unwrap();
    assert!(matches!(added.comparison, BackupComparison::Changed));
    let alternate = path.with_extension("tmp");
    file(&alternate, b"one");
    fs::rename(&alternate, &path).unwrap();
    let replaced = store.recheck(&added.report.report_id).unwrap();
    assert!(matches!(replaced.comparison, BackupComparison::Changed));
    fs::remove_file(path).unwrap();
    let removed = store.recheck(&replaced.report.report_id).unwrap();
    assert!(matches!(removed.comparison, BackupComparison::Changed));
    assert_eq!(row(&removed.report).status, InventoryStatus::NotFound);
}
#[test]
fn known_symlink_fifo_hardlink_and_insecure_modes_fail_closed_without_body_access() {
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    file(&outside.path().join("private"), b"outside");
    let path = source_file(root.path(), BackupSource::Workspace);
    dir(path.parent().unwrap());
    let store = WorkspaceBackupStore::new(root.path().into());
    symlink(outside.path().join("private"), &path).unwrap();
    let r = store.inspect(vec![BackupSource::Workspace]).unwrap();
    assert_eq!(row(&r).status, InventoryStatus::Unavailable);
    fs::remove_file(&path).unwrap();
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(path.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Workspace]).unwrap()).status,
        InventoryStatus::Unavailable
    );
    fs::remove_file(&path).unwrap();
    fs::hard_link(outside.path().join("private"), &path).unwrap();
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Workspace]).unwrap()).status,
        InventoryStatus::Unavailable
    );
    fs::remove_file(&path).unwrap();
    file(&path, b"local");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Workspace]).unwrap()).status,
        InventoryStatus::Unavailable
    );
}
#[test]
fn source_directory_alias_or_appdata_replacement_cannot_redirect_scan() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("app");
    dir(&root);
    let external = temp.path().join("external");
    dir(&external);
    file(&source_file(&external, BackupSource::Workspace), b"outside");
    let store = WorkspaceBackupStore::new(root.clone());
    symlink(external.join("workspace"), root.join("workspace")).unwrap();
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Workspace]).unwrap()).status,
        InventoryStatus::Unavailable
    );
    fs::rename(&root, temp.path().join("original")).unwrap();
    symlink(&external, &root).unwrap();
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Workspace]).unwrap()).status,
        InventoryStatus::Unavailable
    );
    fs::remove_file(&root).unwrap();
    dir(&root);
    file(&source_file(&root, BackupSource::Workspace), b"new");
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Workspace]).unwrap()).status,
        InventoryStatus::Unavailable
    );
}
#[test]
fn sqlite_sidecars_are_counted_without_database_open_or_checkpoint() {
    let root = tempfile::tempdir().unwrap();
    let main = source_file(root.path(), BackupSource::Rss);
    for name in [
        "reader.sqlite",
        "reader.sqlite-wal",
        "reader.sqlite-shm",
        "reader.sqlite-journal",
    ] {
        file(&main.parent().unwrap().join(name), b"not a database");
    }
    let store = WorkspaceBackupStore::new(root.path().into());
    let r = store.inspect(vec![BackupSource::Rss]).unwrap();
    assert_eq!(row(&r).status, InventoryStatus::MetadataOnly);
    assert_eq!(row(&r).file_count, Some(4));
    assert!(row(&r).requires_database_snapshot);
    assert_eq!(fs::read_dir(main.parent().unwrap()).unwrap().count(), 4);
    assert_eq!(fs::read(main).unwrap(), b"not a database");
}
#[test]
fn missing_primary_payload_is_partial_and_recheck_can_never_claim_unchanged() {
    let root = tempfile::tempdir().unwrap();
    dir(&root.path().join("knowledge-v1"));
    file(
        &root.path().join("knowledge-v1/blobs").join("c".repeat(64)),
        b"orphan",
    );
    let store = WorkspaceBackupStore::new(root.path().into());
    let first = store.inspect(vec![BackupSource::Knowledge]).unwrap();
    assert_eq!(row(&first).status, InventoryStatus::Limited);
    assert!(row(&first).issues.contains(&InventoryIssue::PrimaryMissing));
    assert!(matches!(
        store.recheck(&first.report_id).unwrap().comparison,
        BackupComparison::Inconclusive
    ));
    let first = WorkspaceBackupStore::default()
        .inspect(vec![BackupSource::Rss])
        .unwrap();
    assert_eq!(row(&first).status, InventoryStatus::Unavailable);
}
#[test]
fn entry_and_sparse_file_byte_limits_preserve_lower_bound_and_all_files() {
    let root = tempfile::tempdir().unwrap();
    let dirpath = root.path().join("knowledge-v1/blobs");
    dir(&dirpath);
    file(
        &source_file(root.path(), BackupSource::Knowledge),
        b"manifest",
    );
    for i in 0..MAX_ENTRIES + 1 {
        file(&dirpath.join(format!("{i:064x}")), b"x");
    }
    let store = WorkspaceBackupStore::new(root.path().into());
    let r = store.inspect(vec![BackupSource::Knowledge]).unwrap();
    assert_eq!(row(&r).status, InventoryStatus::Limited);
    assert!(row(&r).issues.contains(&InventoryIssue::EntryLimit));
    assert!(row(&r).file_count.unwrap() <= MAX_ENTRIES);
    assert_eq!(fs::read_dir(&dirpath).unwrap().count(), MAX_ENTRIES + 1);
    let state = source_file(root.path(), BackupSource::Workspace);
    file(&state, b"");
    File::options()
        .write(true)
        .open(&state)
        .unwrap()
        .set_len(MAX_FILE_BYTES + 1)
        .unwrap();
    let r = store.inspect(vec![BackupSource::Workspace]).unwrap();
    assert_eq!(row(&r).status, InventoryStatus::Limited);
    assert!(row(&r).issues.contains(&InventoryIssue::ByteLimit));
    assert_eq!(row(&r).byte_count, Some(0));
}
#[test]
fn explicit_budget_timeout_and_metadata_drift_proofs_are_not_complete() {
    let root = tempfile::tempdir().unwrap();
    file(&source_file(root.path(), BackupSource::Workspace), b"a");
    let handle = root_handle(root.path()).unwrap();
    let mut budget = Budget {
        entries: 0,
        bytes: 0,
        started: Instant::now() - SCAN_TIME,
    };
    let (r, _) = scan_source(&handle, BackupSource::Workspace, &mut budget);
    assert_eq!(r.status, InventoryStatus::Limited);
    assert!(r.issues.contains(&InventoryIssue::TimeLimit));
    let mut budget = Budget {
        entries: MAX_GLOBAL_ENTRIES,
        bytes: 0,
        started: Instant::now(),
    };
    let (r, _) = scan_source(&handle, BackupSource::Workspace, &mut budget);
    assert_eq!(r.status, InventoryStatus::Limited);
    assert!(r.issues.contains(&InventoryIssue::EntryLimit));
}
#[test]
fn unchanged_selected_scope_does_not_inspect_unselected_category_changes() {
    let root = tempfile::tempdir().unwrap();
    file(&source_file(root.path(), BackupSource::Workspace), b"state");
    let store = WorkspaceBackupStore::new(root.path().into());
    let p = store.inspect(vec![BackupSource::Workspace]).unwrap();
    file(
        &source_file(root.path(), BackupSource::AiProfiles),
        b"secret endpoint",
    );
    let r = store.recheck(&p.report_id).unwrap();
    assert!(matches!(r.comparison, BackupComparison::Unchanged));
    assert_eq!(r.report.sources.len(), 1);
}
#[test]
fn empty_duplicate_expired_discarded_and_capacity_reports_are_bounded() {
    let root = tempfile::tempdir().unwrap();
    let store = WorkspaceBackupStore::new(root.path().into());
    assert!(store.inspect(vec![]).is_err());
    assert!(store
        .inspect(vec![BackupSource::Rss, BackupSource::Rss])
        .is_err());
    let p = store.inspect(vec![BackupSource::Workspace]).unwrap();
    store
        .reports
        .lock()
        .unwrap()
        .get_mut(&p.report_id)
        .unwrap()
        .created -= TTL;
    assert!(store.recheck(&p.report_id).is_err());
    assert!(store.recheck(&p.report_id).is_err());
    let p = store.inspect(vec![BackupSource::Workspace]).unwrap();
    store.discard(&p.report_id).unwrap();
    assert!(store.recheck(&p.report_id).is_err());
    for _ in 0..MAX_REPORTS {
        store.inspect(vec![BackupSource::Workspace]).unwrap();
    }
    assert!(store.inspect(vec![BackupSource::Workspace]).is_err());
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
}

#[test]
fn changes_during_enumeration_invalidate_metadata_instead_of_showing_complete_counts() {
    let root = tempfile::tempdir().unwrap();
    let path = source_file(root.path(), BackupSource::Workspace);
    file(&path, b"state");
    let handle = root_handle(root.path()).unwrap();
    let mut budget = Budget {
        entries: 0,
        bytes: 0,
        started: Instant::now(),
    };
    let (r, _) = scan_source_checked(&handle, BackupSource::Workspace, &mut budget, || {
        fs::write(&path, b"other").unwrap();
    });
    assert_eq!(r.status, InventoryStatus::Unavailable);
    assert_eq!(r.file_count, None);
    assert!(r.issues.contains(&InventoryIssue::ChangedDuringRead));
    let mut budget = Budget {
        entries: 0,
        bytes: 0,
        started: Instant::now(),
    };
    let folder = path.parent().unwrap().to_owned();
    let moved = root.path().join("old-workspace");
    let (r, _) = scan_source_checked(&handle, BackupSource::Workspace, &mut budget, || {
        fs::rename(&folder, &moved).unwrap();
        dir(&folder);
        file(&path, b"replacement");
    });
    assert_eq!(r.status, InventoryStatus::Unavailable);
    assert_eq!(r.byte_count, None);
    assert!(r.issues.contains(&InventoryIssue::ChangedDuringRead));
}

#[test]
fn live_initialized_database_stores_can_be_inventoried_without_checkpoint_or_payload_queries() {
    let root = tempfile::tempdir().unwrap();
    let _rss = crate::core::RssReaderStore::new(root.path().into()).unwrap();
    let _general = crate::core::GeneralDraftStore::new(root.path().into()).unwrap();
    let _history = crate::core::DraftHistoryStore::new(root.path().into()).unwrap();
    let store = WorkspaceBackupStore::new(root.path().into());
    let r = store
        .inspect(vec![
            BackupSource::Rss,
            BackupSource::GeneralDrafts,
            BackupSource::DraftHistory,
        ])
        .unwrap();
    for row in &r.sources {
        assert_eq!(row.status, InventoryStatus::MetadataOnly, "{row:?}");
        assert!(row.file_count.unwrap() > 0);
        assert!(row.requires_database_snapshot);
    }
}

#[test]
fn sqlite_readable_sidecars_require_private_directory_and_reject_shared_writes() {
    let root = tempfile::tempdir().unwrap();
    let primary = source_file(root.path(), BackupSource::Rss);
    file(&primary, b"database");
    let sidecar = primary.with_file_name("reader.sqlite-wal");
    file(&sidecar, b"wal");
    fs::set_permissions(&sidecar, fs::Permissions::from_mode(0o644)).unwrap();
    let store = WorkspaceBackupStore::new(root.path().into());
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Rss]).unwrap()).status,
        InventoryStatus::MetadataOnly
    );
    for mode in [0o664, 0o666, 0o744] {
        fs::set_permissions(&sidecar, fs::Permissions::from_mode(mode)).unwrap();
        assert_eq!(
            row(&store.inspect(vec![BackupSource::Rss]).unwrap()).status,
            InventoryStatus::Unavailable
        );
    }
    fs::set_permissions(&sidecar, fs::Permissions::from_mode(0o644)).unwrap();
    fs::set_permissions(primary.parent().unwrap(), fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(
        row(&store.inspect(vec![BackupSource::Rss]).unwrap()).status,
        InventoryStatus::Unavailable
    );
}
