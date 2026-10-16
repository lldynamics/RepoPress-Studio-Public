use super::*;
use std::fs;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    dest: PathBuf,
    general: GeneralDraftStore,
    history: DraftHistoryStore,
    store: DraftSnapshotBackupStore,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("data");
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let general = GeneralDraftStore::new(root.clone()).unwrap();
        let history = DraftHistoryStore::new(root.clone()).unwrap();
        let store = DraftSnapshotBackupStore::new(root.clone());
        let dest = temp.path().join("snapshot.sqlite");
        Self {
            _temp: temp,
            root,
            dest,
            general,
            history,
            store,
        }
    }
    fn source_path(&self, s: DraftSnapshotSource) -> PathBuf {
        let (d, f) = s.location();
        self.root.join(d).join(f)
    }
    fn sql(&self, s: DraftSnapshotSource, sql: &str) {
        s.with_connection(&self.general, &self.history, |c, _, _| {
            c.execute_batch(sql).unwrap();
            Ok(())
        })
        .unwrap();
    }
    fn plan(&self, s: DraftSnapshotSource) -> DraftSnapshotBackupPlan {
        self.store
            .plan(&self.general, &self.history, s, &self.dest)
            .unwrap()
    }
    fn execute(&self, id: &str, consent: bool) -> CommandResult<DraftSnapshotBackupResult> {
        self.store
            .execute(&self.general, &self.history, id, consent)
    }
    fn data(&self) {
        self.general
            .save(
                None,
                "# PRIVATE GENERAL\n![image](../private.png?token=SECRET)",
                None,
                None,
            )
            .unwrap();
        for (root, text) in [
            ("repo-one", "PRIVATE HISTORY ONE"),
            ("repo-two", "PRIVATE HISTORY TWO"),
        ] {
            let path = self.root.join(root);
            self.history
                .record_version(
                    &path,
                    "content/secret.md",
                    text,
                    &hash(text.as_bytes()),
                    super::super::draft_history::DraftVersionReason::BeforeSave,
                )
                .unwrap();
            self.history
                .record_deleted(
                    &path,
                    "content/removed.md",
                    "PRIVATE RECYCLED",
                    &hash(b"PRIVATE RECYCLED"),
                )
                .unwrap();
        }
    }
}
const SOURCES: [DraftSnapshotSource; 2] = [
    DraftSnapshotSource::GeneralDrafts,
    DraftSnapshotSource::DraftHistory,
];
#[test]
fn repository_lf_crlf_and_bom_history_preserves_raw_baseline_digest() {
    let f = Fixture::new();
    let repo = f._temp.path().join("repository");
    fs::create_dir(&repo).unwrap();
    let repositories = super::super::RepositoryStore::default();
    let session = repositories
        .open_repository(repo.to_str().unwrap())
        .unwrap();
    let normalized = "# 历史\n正文\n";
    let mut expected = Vec::new();
    for (index, (crlf, bom)) in [(false, false), (true, false), (false, true), (true, true)]
        .into_iter()
        .enumerate()
    {
        let path = format!("encoding-{index}.md");
        let body = if crlf {
            normalized.replace('\n', "\r\n")
        } else {
            normalized.into()
        };
        let mut raw = if bom {
            vec![0xef, 0xbb, 0xbf]
        } else {
            Vec::new()
        };
        raw.extend_from_slice(body.as_bytes());
        fs::write(repo.join(&path), &raw).unwrap();
        let document = repositories
            .open_document(&session.session_id, &path)
            .unwrap();
        assert!(document.writable);
        let context = repositories
            .history_context_for_session(
                &session.session_id,
                &document.document_id,
                &document.baseline_sha256,
            )
            .unwrap();
        assert_eq!(context.text, normalized);
        assert_eq!(context.baseline_sha256, hash(&raw));
        f.history
            .record_version(
                &context.root,
                &context.relative_path,
                &context.text,
                &context.baseline_sha256,
                super::super::draft_history::DraftVersionReason::BeforeSave,
            )
            .unwrap();
        f.history
            .record_deleted(
                &context.root,
                &context.relative_path,
                &context.text,
                &context.baseline_sha256,
            )
            .unwrap();
        expected.push((path, context.baseline_sha256));
    }
    let p = f.plan(SOURCES[1]);
    assert_eq!(
        p.tables.iter().map(|t| t.row_count).collect::<Vec<_>>(),
        vec![4, 4, 4]
    );
    f.execute(&p.plan_id, true).unwrap();
    let c =
        Connection::open_with_flags(&f.dest, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    for (path, digest) in expected {
        for table in ["versions", "recycled_drafts"] {
            let stored: (String, String, i64) = c
                .query_row(
                    &format!(
                        "SELECT text,content_sha256,byte_size FROM {table} WHERE relative_path=?1"
                    ),
                    [&path],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .unwrap();
            assert_eq!(
                stored,
                (normalized.into(), digest.clone(), normalized.len() as i64)
            );
        }
    }
    // General drafts hash their saved text directly; history compatibility must not
    // weaken that independent database's content check.
    let f = Fixture::new();
    f.general.save(None, normalized, None, None).unwrap();
    let mut raw = vec![0xef, 0xbb, 0xbf];
    raw.extend_from_slice(normalized.as_bytes());
    SOURCES[0]
        .with_connection(&f.general, &f.history, |c, _, _| {
            c.execute("UPDATE general_drafts SET content_sha256=?1", [hash(&raw)])
                .unwrap();
            Ok(())
        })
        .unwrap();
    assert!(f
        .store
        .plan(&f.general, &f.history, SOURCES[0], &f.dest)
        .is_err());
}
#[test]
fn each_snapshot_includes_all_committed_wal_rows_and_is_standalone_private() {
    for s in SOURCES {
        let f = Fixture::new();
        f.sql(
            s,
            "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA wal_autocheckpoint=0;",
        );
        f.data();
        let path = f.source_path(s);
        let wal = PathBuf::from(format!("{}-wal", path.display()));
        let before = (fs::read(&path).unwrap(), fs::read(&wal).unwrap());
        let raw = f.dest.with_file_name("raw-main.sqlite");
        fs::write(&raw, &before.0).unwrap();
        let c =
            Connection::open_with_flags(raw, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let n: i64 = c
            .query_row(
                &format!("SELECT count(*) FROM {}", s.tables()[0]),
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 0);
        drop(c);
        let p = f.plan(s);
        assert_eq!(p.source, s);
        assert!(p.content_verified);
        assert!(!p.multi_database_snapshot);
        assert_eq!(
            p.includes_recycled_drafts,
            s == DraftSnapshotSource::DraftHistory
        );
        let preview = serde_json::to_string(&p).unwrap();
        assert!(!preview.contains("PRIVATE"));
        assert!(!preview.contains("SECRET"));
        assert!(!preview.contains("secret.md"));
        let r = f.execute(&p.plan_id, true).unwrap();
        let bytes = fs::read(&f.dest).unwrap();
        assert_eq!(hash(&bytes), p.sha256);
        assert_eq!(r.source, s);
        assert_eq!(r.byte_size, bytes.len());
        assert_eq!(fs::metadata(&f.dest).unwrap().mode() & 0o777, 0o600);
        assert_eq!((fs::read(&path).unwrap(), fs::read(&wal).unwrap()), before);
        let c = Connection::open_with_flags(&f.dest, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
        assert_eq!(
            c.query_row("PRAGMA quick_check", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        for t in &p.tables {
            assert_eq!(
                c.query_row(&format!("SELECT count(*) FROM {}", t.table), [], |r| r
                    .get::<_, i64>(0))
                    .unwrap(),
                t.row_count as i64
            );
        }
        if s == DraftSnapshotSource::GeneralDrafts {
            assert!(c
                .query_row("SELECT text FROM general_drafts", [], |r| r
                    .get::<_, String>(0))
                .unwrap()
                .contains("SECRET"));
            assert_eq!(p.tables.len(), 1);
        } else {
            assert_eq!(p.tables[0].row_count, 4);
            assert_eq!(p.tables[2].row_count, 2);
            assert_eq!(
                c.query_row(
                    "SELECT count(DISTINCT repository_key) FROM drafts",
                    [],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
                2
            );
        }
        assert!(!PathBuf::from(format!("{}-wal", f.dest.display())).exists());
        assert!(f.execute(&p.plan_id, true).is_err());
    }
}
#[test]
fn unselected_missing_or_corrupt_db_and_external_attachment_are_not_read() {
    for s in SOURCES {
        let f = Fixture::new();
        f.data();
        let other = if s == SOURCES[0] {
            SOURCES[1]
        } else {
            SOURCES[0]
        };
        let path = f.source_path(other);
        fs::rename(&path, path.with_extension("old")).unwrap();
        symlink(f.dest.with_extension("missing"), &path).unwrap();
        let external = f.root.join("private.png");
        fs::write(&external, b"DO NOT COPY ATTACHMENT").unwrap();
        let p = f.plan(s);
        f.execute(&p.plan_id, true).unwrap();
        let c = Connection::open(&f.dest).unwrap();
        assert_eq!(
            sqlite_snapshot::schema(&c).unwrap().len(),
            if s == SOURCES[0] { 3 } else { 9 }
        );
        assert_eq!(fs::read(external).unwrap(), b"DO NOT COPY ATTACHMENT");
    }
}
#[test]
fn empty_durable_sources_allowed_and_memory_missing_or_wrong_source_store_rejected() {
    for s in SOURCES {
        let f = Fixture::new();
        let p = f.plan(s);
        assert!(p.tables.iter().all(|t| t.row_count == 0));
        f.store.discard(&p.plan_id).unwrap();
        assert!(f
            .store
            .plan(
                &GeneralDraftStore::default(),
                &DraftHistoryStore::default(),
                s,
                &f.dest
            )
            .is_err());
        assert!(DraftSnapshotBackupStore::default()
            .plan(&f.general, &f.history, s, &f.dest)
            .is_err());
        let path = f.source_path(s);
        fs::rename(&path, path.with_extension("removed")).unwrap();
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
    }
    let f = Fixture::new();
    let p = f.plan(SOURCES[0]);
    assert!(f
        .store
        .execute(&GeneralDraftStore::default(), &f.history, &p.plan_id, true)
        .is_err());
    assert!(f.execute(&p.plan_id, true).is_err());
}
#[test]
fn consent_expiry_capacity_discard_wrong_ids_and_once_only_enforced() {
    let f = Fixture::new();
    let p = f.plan(SOURCES[0]);
    assert!(f.execute(&p.plan_id, false).is_err());
    assert!(!f.dest.exists());
    assert!(f.execute(&p.plan_id, true).is_err());
    let p = f.plan(SOURCES[1]);
    f.store
        .plans
        .lock()
        .unwrap()
        .get_mut(&p.plan_id)
        .unwrap()
        .created = Instant::now() - TTL;
    assert!(f.execute(&p.plan_id, true).is_err());
    let p = f.plan(SOURCES[0]);
    f.store
        .plans
        .lock()
        .unwrap()
        .get_mut(&p.plan_id)
        .unwrap()
        .preview
        .expires_at_epoch_ms = 1;
    assert!(f.execute(&p.plan_id, true).is_err());
    let a = f.plan(SOURCES[0]);
    let b = f
        .store
        .plan(
            &f.general,
            &f.history,
            SOURCES[1],
            &f.dest.with_file_name("second.sqlite"),
        )
        .unwrap();
    assert!(f
        .store
        .plan(
            &f.general,
            &f.history,
            SOURCES[0],
            &f.dest.with_file_name("third.sqlite")
        )
        .is_err());
    f.store.discard(&a.plan_id).unwrap();
    f.store.discard(&b.plan_id).unwrap();
    assert!(f.execute(&a.plan_id, true).is_err());
    // Other stages' IDs have no binding in this store.
    let rss = super::super::RssReaderStore::new(f.root.clone()).unwrap();
    let rs = super::super::RssSnapshotBackupStore::new(f.root.clone());
    let rp = rs.plan(&rss, &f.dest).unwrap();
    assert!(f.execute(&rp.plan_id, true).is_err());
    assert!(f.execute(&Uuid::new_v4().to_string(), true).is_err());
}
#[test]
fn internal_external_and_schema_changes_invalidate_each_source_plan() {
    for s in SOURCES {
        let f = Fixture::new();
        f.data();
        let p = f.plan(s);
        let sql = if s == SOURCES[0] {
            "UPDATE general_drafts SET title='changed'"
        } else {
            "UPDATE versions SET reason='beforeRestore'"
        };
        f.sql(s, sql);
        assert!(f.execute(&p.plan_id, true).is_err());
        assert!(!f.dest.exists());
        let p = f.plan(s);
        let c = Connection::open(f.source_path(s)).unwrap();
        c.execute_batch(if s == SOURCES[0] {
            "UPDATE general_drafts SET title='external'"
        } else {
            "UPDATE versions SET reason='deleted'"
        })
        .unwrap();
        assert!(f.execute(&p.plan_id, true).is_err());
        assert!(!f.dest.exists());
        let p = f.plan(s);
        f.sql(
            s,
            &format!("CREATE INDEX surprise ON {}(rowid)", s.tables()[0]).replace(
                "(rowid)",
                if s == SOURCES[0] {
                    "(title)"
                } else {
                    "(relative_path)"
                },
            ),
        );
        assert!(f.execute(&p.plan_id, true).is_err());
    }
}
#[test]
fn late_commit_before_and_after_publish_has_no_success_or_automatic_retry() {
    for s in SOURCES {
        for after_publish in [false, true] {
            let f = Fixture::new();
            let p = f.plan(s);
            let c = Connection::open(f.source_path(s)).unwrap();
            let mut fired = false;
            let result =
                f.store
                    .execute_checked(&f.general, &f.history, &p.plan_id, true, |after| {
                        if after == after_publish && !fired {
                            fired = true;
                            c.execute_batch("PRAGMA user_version=7").unwrap();
                        }
                    });
            assert!(result.is_err());
            assert!(f.execute(&p.plan_id, true).is_err());
            if after_publish {
                assert!(f.dest.exists());
            }
            if f.dest.exists() {
                assert_eq!(hash(&fs::read(&f.dest).unwrap()), p.sha256);
                assert_eq!(fs::metadata(&f.dest).unwrap().mode() & 0o777, 0o600);
            }
        }
    }
}
#[test]
fn unknown_layout_versions_objects_columns_indices_views_or_triggers_rejected() {
    for s in SOURCES {
        for sql in [
            "PRAGMA user_version=1".to_string(),
            "PRAGMA application_id=123".to_string(),
            "CREATE TABLE unexpected(secret TEXT)".to_string(),
            format!("ALTER TABLE {} ADD COLUMN surprise TEXT", s.tables()[0]),
            format!("CREATE VIEW surprise AS SELECT * FROM {}", s.tables()[0]),
            format!(
                "CREATE TRIGGER surprise AFTER INSERT ON {} BEGIN SELECT 1;END",
                s.tables()[0]
            ),
            format!(
                "CREATE INDEX surprise ON {}({})",
                s.tables()[0],
                if s == SOURCES[0] {
                    "title"
                } else {
                    "relative_path"
                }
            ),
        ] {
            let f = Fixture::new();
            f.sql(s, &sql);
            assert!(
                f.store.plan(&f.general, &f.history, s, &f.dest).is_err(),
                "accepted {s:?} {sql}"
            );
            assert!(!f.dest.exists());
        }
    }
}
#[test]
fn corrupt_content_hash_size_utf8_cr_revision_id_and_metadata_paths_rejected() {
    for sql in [
        "UPDATE general_drafts SET byte_size=999",
        "UPDATE general_drafts SET content_sha256='bad'",
        "UPDATE general_drafts SET text='changed'",
        "UPDATE general_drafts SET revision=0",
        "UPDATE general_drafts SET draft_id='not-uuid'",
        "UPDATE general_drafts SET source_relative_path='../secret.md'",
        "UPDATE general_drafts SET source_relative_path='/secret.md'",
        "UPDATE general_drafts SET text=x'ff'",
        "UPDATE general_drafts SET created_at=-1",
    ] {
        let f = Fixture::new();
        f.data();
        f.sql(SOURCES[0], sql);
        assert!(
            f.store
                .plan(&f.general, &f.history, SOURCES[0], &f.dest)
                .is_err(),
            "accepted {sql}"
        );
    }
    let f = Fixture::new();
    f.data();
    SOURCES[0]
        .with_connection(&f.general, &f.history, |c, _, _| {
            let text = "secret\r\n";
            c.execute(
                "UPDATE general_drafts SET text=?1,byte_size=?2,content_sha256=?3",
                rusqlite::params![text, text.len() as i64, hash(text.as_bytes())],
            )
            .unwrap();
            Ok(())
        })
        .unwrap();
    assert!(f
        .store
        .plan(&f.general, &f.history, SOURCES[0], &f.dest)
        .is_err());
}
#[test]
fn history_orphans_bad_reason_hashes_and_paths_rejected_but_old_rename_path_allowed() {
    for sql in [
        "DELETE FROM drafts",
        "UPDATE drafts SET repository_key='bad' WHERE rowid=(SELECT rowid FROM drafts LIMIT 1)",
        "UPDATE drafts SET draft_id='bad' WHERE rowid=(SELECT rowid FROM drafts LIMIT 1)",
        "UPDATE versions SET content_sha256='bad'",
        "UPDATE versions SET content_sha256='0000000000000000000000000000000000000000000000000000000000000000'",
        "UPDATE recycled_drafts SET byte_size=-1",
        "UPDATE versions SET reason='unknown'",
        "UPDATE recycled_drafts SET relative_path='../secret.md'",
        "UPDATE drafts SET relative_path='.git/secret.md' WHERE relative_path='content/secret.md'",
        "UPDATE recycled_drafts SET deleted_at=-1",
    ] {
        let f = Fixture::new();
        f.data();
        f.sql(SOURCES[1], sql);
        assert!(
            f.store
                .plan(&f.general, &f.history, SOURCES[1], &f.dest)
                .is_err(),
            "accepted {sql}"
        );
    }
    let f = Fixture::new();
    f.data();
    f.history
        .rename_draft(&f.root.join("repo-one"), "content/secret.md", "renamed.md")
        .unwrap();
    assert!(f
        .store
        .plan(&f.general, &f.history, SOURCES[1], &f.dest)
        .is_ok());
}
#[test]
fn body_database_limits_and_deleted_pages_compaction_checked_without_cleanup() {
    for s in SOURCES {
        let f = Fixture::new();
        f.data();
        let table = if s == SOURCES[0] {
            "general_drafts"
        } else {
            "versions"
        };
        let text = "x".repeat(MAX_TEXT_BYTES + 1);
        s.with_connection(&f.general, &f.history, |c, _, _| {
            c.execute(
                &format!("UPDATE {table} SET text=?1,byte_size=?2,content_sha256=?3"),
                rusqlite::params![text, text.len() as i64, hash(text.as_bytes())],
            )
            .unwrap();
            Ok(())
        })
        .unwrap();
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
        let f = Fixture::new();
        f.data();
        f.sql(s, &format!("UPDATE {table} SET text=zeroblob(33554432)"));
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
    }
    let f = Fixture::new();
    f.sql(SOURCES[0], "PRAGMA secure_delete=OFF");
    let text = "DELETED_PRIVATE_MARKER_XYZ".repeat(30000);
    let draft = f.general.save(None, &text, None, None).unwrap();
    f.sql(
        SOURCES[0],
        &format!(
            "DELETE FROM general_drafts WHERE draft_id='{}'",
            draft.summary.draft_id
        ),
    );
    let before = fs::read(PathBuf::from(format!(
        "{}-wal",
        f.source_path(SOURCES[0]).display()
    )))
    .unwrap();
    assert!(before
        .windows(b"DELETED_PRIVATE_MARKER_XYZ".len())
        .any(|w| w == b"DELETED_PRIVATE_MARKER_XYZ"));
    let p = f.plan(SOURCES[0]);
    f.execute(&p.plan_id, true).unwrap();
    let bytes = fs::read(&f.dest).unwrap();
    assert!(!bytes
        .windows(b"DELETED_PRIVATE_MARKER_XYZ".len())
        .any(|w| w == b"DELETED_PRIVATE_MARKER_XYZ"));
    assert_eq!(
        fs::read(PathBuf::from(format!(
            "{}-wal",
            f.source_path(SOURCES[0]).display()
        )))
        .unwrap(),
        before
    );
}
#[test]
fn private_sources_inode_hardlinks_symlinks_fifo_and_sidecars_enforced() {
    for s in SOURCES {
        let f = Fixture::new();
        let file = f.source_path(s);
        fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
        let f = Fixture::new();
        let file = f.source_path(s);
        fs::hard_link(&file, f.dest.with_extension("link")).unwrap();
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
        let f = Fixture::new();
        let p = f.plan(s);
        let file = f.source_path(s);
        fs::rename(&file, file.with_extension("old")).unwrap();
        fs::write(&file, b"replacement").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(f.execute(&p.plan_id, true).is_err());
        let f = Fixture::new();
        let file = f.source_path(s);
        fs::rename(&file, file.with_extension("old")).unwrap();
        let c = std::ffi::CString::new(file.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
        let f = Fixture::new();
        let dir = f.source_path(s).parent().unwrap().to_owned();
        fs::rename(&dir, dir.with_extension("old")).unwrap();
        symlink(dir.with_extension("old"), &dir).unwrap();
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
        let f = Fixture::new();
        let shm = PathBuf::from(format!("{}-shm", f.source_path(s).display()));
        fs::remove_file(&shm).unwrap();
        symlink(f.dest.with_extension("missing"), &shm).unwrap();
        assert!(f.store.plan(&f.general, &f.history, s, &f.dest).is_err());
    }
}
#[test]
fn collision_git_app_root_wrong_extension_and_parent_or_root_swaps_rejected() {
    let f = Fixture::new();
    for p in [
        PathBuf::from("relative.sqlite"),
        f.root.join("out.sqlite"),
        f.dest.with_extension("json"),
    ] {
        assert!(f
            .store
            .plan(&f.general, &f.history, SOURCES[0], &p)
            .is_err());
    }
    let p = f.plan(SOURCES[0]);
    fs::write(&f.dest, b"KEEP").unwrap();
    assert!(f.execute(&p.plan_id, true).is_err());
    assert_eq!(fs::read(&f.dest).unwrap(), b"KEEP");
    let f = Fixture::new();
    let p = f.plan(SOURCES[1]);
    fs::create_dir(f.dest.parent().unwrap().join(".git")).unwrap();
    fs::write(
        f.dest.parent().unwrap().join(".git/HEAD"),
        "ref: refs/heads/main",
    )
    .unwrap();
    assert!(f.execute(&p.plan_id, true).is_err());
    assert!(!f.dest.exists());
    let f = Fixture::new();
    let dir = f.dest.parent().unwrap().join("export");
    fs::create_dir(&dir).unwrap();
    let p = f
        .store
        .plan(&f.general, &f.history, SOURCES[0], &dir.join("out.sqlite"))
        .unwrap();
    fs::rename(&dir, dir.with_extension("old")).unwrap();
    fs::create_dir(&dir).unwrap();
    assert!(f.execute(&p.plan_id, true).is_err());
    let f = Fixture::new();
    let p = f.plan(SOURCES[1]);
    fs::rename(&f.root, f.root.with_extension("old")).unwrap();
    fs::create_dir(&f.root).unwrap();
    fs::set_permissions(&f.root, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(f.execute(&p.plan_id, true).is_err());
}
