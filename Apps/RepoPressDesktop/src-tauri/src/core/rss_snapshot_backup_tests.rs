use super::*;
use std::fs;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    dest: PathBuf,
    rss: RssReaderStore,
    store: RssSnapshotBackupStore,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("data");
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let rss = RssReaderStore::new(root.clone()).unwrap();
        let store = RssSnapshotBackupStore::new(root.clone());
        let dest = temp.path().join("out.sqlite");
        Self {
            _temp: temp,
            root,
            dest,
            rss,
            store,
        }
    }
    fn write(&self, sql: &str) {
        self.rss
            .with_snapshot_source(|c, _, _| {
                c.execute_batch(sql).unwrap();
                Ok(())
            })
            .unwrap();
    }
    fn plan(&self) -> RssSnapshotBackupPlan {
        self.store.plan(&self.rss, &self.dest).unwrap()
    }
    fn fixture_data(&self) {
        self.write("PRAGMA wal_autocheckpoint=0; INSERT INTO feeds(id,url,title) VALUES('f','https://private.example/feed?token=SECRET','title'); INSERT INTO articles(id,feed_id,identity,guid,title,summary,content,published,fetched) VALUES('a','f','id','g','title','summary','PRIVATE BODY',1,1); INSERT INTO highlights(id,article_id,text,note,created_at,updated_at) VALUES('h','a','PRIVATE HIGHLIGHT','NOTE',1,1); INSERT INTO reading_progress(article_id,progress,revision,updated_at) VALUES('a',0.25,2,1); INSERT INTO full_text_cache(article_id,status,plain_text) VALUES('a','ready','PRIVATE FULL'); INSERT INTO offline_translation_cache VALUES('a','fingerprint','PRIVATE TRANSLATION',NULL,'provider','model','zh',1,2,99999,19); INSERT INTO undo_actions VALUES('undo','removeFeed','PRIVATE UNDO',99999); INSERT INTO history_jobs VALUES('job','f','PRIVATE HISTORY'); INSERT INTO history_failures(job_id,url,candidate_json) VALUES('job','https://private.example/story','{\"title\":\"PRIVATE FAILED CANDIDATE\"}');");
    }
}
#[test]
fn wal_snapshot_is_standalone_and_preserves_all_tables_without_touching_source() {
    let f = Fixture::new();
    f.write("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA wal_autocheckpoint=0;");
    f.fixture_data();
    let main = f.root.join("RSSReader/reader.sqlite");
    let wal = f.root.join("RSSReader/reader.sqlite-wal");
    let before = (fs::read(&main).unwrap(), fs::read(&wal).unwrap());
    let raw = f.dest.with_file_name("raw-main.sqlite");
    fs::write(&raw, &before.0).unwrap();
    let raw_db =
        Connection::open_with_flags(&raw, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        raw_db
            .query_row("SELECT count(*) FROM articles", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    drop(raw_db);
    let p = f.plan();
    assert_eq!(p.database_schema_version, 4);
    assert_eq!(
        p.tables.iter().map(|table| table.table).collect::<Vec<_>>(),
        RSS_SNAPSHOT_TABLE_NAMES
    );
    assert_eq!(p.tables.len(), 10);
    assert!(p.tables.iter().all(|t| t.row_count >= 1));
    assert!(p.includes_undo_actions);
    assert!(p.compacted_copy);
    assert!(p.consistent_snapshot);
    let r = f.store.execute(&f.rss, &p.plan_id, true).unwrap();
    let bytes = fs::read(&f.dest).unwrap();
    assert_eq!(format!("{:x}", Sha256::digest(&bytes)), p.sha256);
    assert_eq!(r.byte_size, bytes.len());
    assert_eq!((fs::read(&main).unwrap(), fs::read(&wal).unwrap()), before);
    assert_eq!(fs::metadata(&f.dest).unwrap().mode() & 0o777, 0o600);
    let c =
        Connection::open_with_flags(&f.dest, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        c.query_row("PRAGMA quick_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    for (table, col, text) in [
        ("articles", "content", "PRIVATE BODY"),
        ("highlights", "note", "NOTE"),
        ("full_text_cache", "plain_text", "PRIVATE FULL"),
        (
            "offline_translation_cache",
            "translated_text",
            "PRIVATE TRANSLATION",
        ),
        ("undo_actions", "payload", "PRIVATE UNDO"),
        ("history_jobs", "payload", "PRIVATE HISTORY"),
        (
            "history_failures",
            "candidate_json",
            "{\"title\":\"PRIVATE FAILED CANDIDATE\"}",
        ),
    ] {
        assert_eq!(
            c.query_row(&format!("SELECT {col} FROM {table}"), [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            text
        );
    }
    assert!(!f.dest.with_extension("sqlite-wal").exists());
    let serialized = serde_json::to_string(&p).unwrap();
    assert!(!serialized.contains("SECRET"));
    assert!(!serialized.contains("PRIVATE BODY"));
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
}

const RSS_SNAPSHOT_TABLE_NAMES: [&str; 10] = [
    "meta",
    "feeds",
    "articles",
    "highlights",
    "reading_progress",
    "undo_actions",
    "full_text_cache",
    "offline_translation_cache",
    "history_jobs",
    "history_failures",
];
#[test]
fn empty_durable_database_allowed_but_memory_missing_and_unrelated_ids_rejected() {
    let f = Fixture::new();
    let p = f.plan();
    assert_eq!(
        p.tables
            .iter()
            .find(|t| t.table == "articles")
            .unwrap()
            .row_count,
        0
    );
    f.store.discard(&p.plan_id).unwrap();
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert!(f.store.plan(&RssReaderStore::default(), &f.dest).is_err());
    assert!(RssSnapshotBackupStore::default()
        .plan(&f.rss, &f.dest)
        .is_err());
    assert!(f
        .store
        .execute(&f.rss, &Uuid::new_v4().to_string(), true)
        .is_err());
    fs::remove_file(f.root.join("RSSReader/reader.sqlite")).unwrap();
    assert!(f.store.plan(&f.rss, &f.dest).is_err());
}
#[test]
fn consent_expiry_capacity_discard_and_once_only_are_enforced() {
    let f = Fixture::new();
    let p = f.plan();
    assert!(f.store.execute(&f.rss, &p.plan_id, false).is_err());
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert!(!f.dest.exists());
    let p = f.plan();
    f.store
        .plans
        .lock()
        .unwrap()
        .get_mut(&p.plan_id)
        .unwrap()
        .created = Instant::now() - TTL;
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    let p = f.plan();
    f.store
        .plans
        .lock()
        .unwrap()
        .get_mut(&p.plan_id)
        .unwrap()
        .preview
        .expires_at_epoch_ms = 1;
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    let a = f.plan();
    let b = f
        .store
        .plan(&f.rss, &f.dest.with_file_name("two.sqlite"))
        .unwrap();
    assert!(f
        .store
        .plan(&f.rss, &f.dest.with_file_name("three.sqlite"))
        .is_err());
    f.store.discard(&a.plan_id).unwrap();
    f.store.discard(&b.plan_id).unwrap();
    assert!(f.store.plan(&f.rss, &f.dest).is_ok());
}
#[test]
fn source_changes_inside_and_outside_connection_invalidate_frozen_plan() {
    let f = Fixture::new();
    let p = f.plan();
    f.write("UPDATE meta SET value='2000' WHERE key='max_articles'");
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert!(!f.dest.exists());
    let p = f.plan();
    let external = Connection::open(f.root.join("RSSReader/reader.sqlite")).unwrap();
    external
        .execute("UPDATE meta SET value='3000' WHERE key='max_articles'", [])
        .unwrap();
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert!(!f.dest.exists());
    let p = f.plan();
    f.write("CREATE INDEX extra ON feeds(title)");
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert!(!f.dest.exists());
}
#[test]
fn concurrent_external_commit_before_publish_fails_without_success_claim() {
    let f = Fixture::new();
    let p = f.plan();
    let ext = Connection::open(f.root.join("RSSReader/reader.sqlite")).unwrap();
    let mut fired = false;
    let result = f.store.execute_checked(&f.rss, &p.plan_id, true, |after| {
        if !after && !fired {
            fired = true;
            ext.execute("UPDATE meta SET value='4000' WHERE key='max_articles'", [])
                .unwrap();
        }
    });
    assert!(result.is_err());
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    // WAL writers can commit while our read transaction is open. If published, bytes
    // remain the coherent frozen preview, while the result is explicitly unconfirmed.
    if f.dest.exists() {
        assert_eq!(
            format!("{:x}", Sha256::digest(fs::read(&f.dest).unwrap())),
            p.sha256
        );
    }
}
#[test]
fn post_publish_drift_reports_unconfirmed_with_private_file_retained() {
    let f = Fixture::new();
    let p = f.plan();
    let ext = Connection::open(f.root.join("RSSReader/reader.sqlite")).unwrap();
    assert!(f
        .store
        .execute_checked(&f.rss, &p.plan_id, true, |after| {
            if after {
                ext.execute("UPDATE meta SET value='5000' WHERE key='max_articles'", [])
                    .unwrap();
            }
        })
        .is_err());
    assert!(f.dest.exists());
    assert_eq!(fs::metadata(&f.dest).unwrap().mode() & 0o777, 0o600);
}
#[test]
fn unknown_schema_version_objects_columns_and_broken_references_are_rejected() {
    for sql in ["UPDATE meta SET value='99' WHERE key='schema_version'","CREATE TABLE surprise(secret TEXT)","ALTER TABLE feeds ADD COLUMN surprise TEXT","CREATE TRIGGER surprise AFTER INSERT ON meta BEGIN SELECT 1; END;","CREATE VIEW surprise AS SELECT value FROM meta","PRAGMA foreign_keys=OFF; INSERT INTO articles(id,feed_id,guid,title,summary,content,published,fetched) VALUES('bad','missing','g','t','s','c',1,1)"] {
  let f=Fixture::new();f.write(sql);assert!(f.store.plan(&f.rss,&f.dest).is_err(),"accepted {sql}");assert!(!f.dest.exists());
 }
}

#[test]
fn history_failures_table_is_required_and_must_reference_history_jobs() {
    for sql in [
        "DROP TABLE history_failures",
        "PRAGMA foreign_keys=OFF; DROP TABLE history_failures; CREATE TABLE history_failures(job_id TEXT NOT NULL,url TEXT NOT NULL,candidate_json TEXT NOT NULL,PRIMARY KEY(job_id,url))",
    ] {
        let f = Fixture::new();
        f.write(sql);
        assert!(f.store.plan(&f.rss, &f.dest).is_err(), "accepted {sql}");
        assert!(!f.dest.exists());
    }
}
#[test]
fn compacted_copy_excludes_deleted_freelist_content_and_preserves_original() {
    let f = Fixture::new();
    f.write("PRAGMA secure_delete=OFF;");
    let marker = "DELETED_PRIVATE_PAYLOAD_XYZ_".repeat(12000);
    f.rss
        .with_snapshot_source(|c, _, _| {
            c.execute(
                "INSERT INTO undo_actions VALUES('deleted','kind',?1,1)",
                [marker],
            )
            .unwrap();
            c.execute("DELETE FROM undo_actions WHERE token='deleted'", [])
                .unwrap();
            Ok(())
        })
        .unwrap();
    let p = f.plan();
    f.store.execute(&f.rss, &p.plan_id, true).unwrap();
    let bytes = fs::read(&f.dest).unwrap();
    assert!(!bytes
        .windows(26)
        .any(|w| w == b"DELETED_PRIVATE_PAYLOAD_XYZ_"));
}
#[test]
fn limits_checked_before_backup_and_legacy_destination_caps_preserved() {
    let f = Fixture::new();
    f.write("INSERT INTO undo_actions VALUES('large','kind',zeroblob(33554432),1)");
    assert!(f.store.plan(&f.rss, &f.dest).is_err());
    assert!(!f.dest.exists());
    let f = Fixture::new();
    assert!(Destination::new(&f.dest, &f.root).is_err());
    assert!(Destination::sqlite_snapshot(&f.dest.with_extension("json"), &f.root).is_err());
    let json = f.dest.with_extension("json");
    let d = Destination::new(&json, &f.root).unwrap();
    assert!(d
        .write(&vec![0; 8 * 1024 * 1024 + 1], &mut || Ok(()))
        .is_err());
    assert!(!json.exists());
}
#[test]
fn source_identity_permissions_hardlinks_symlinks_and_sidecar_special_files_rejected() {
    for mode in [0o644, 0o620] {
        let f = Fixture::new();
        fs::set_permissions(
            f.root.join("RSSReader/reader.sqlite"),
            fs::Permissions::from_mode(mode),
        )
        .unwrap();
        assert!(f.store.plan(&f.rss, &f.dest).is_err());
    }
    let f = Fixture::new();
    fs::hard_link(
        f.root.join("RSSReader/reader.sqlite"),
        f.dest.with_extension("link"),
    )
    .unwrap();
    assert!(f.store.plan(&f.rss, &f.dest).is_err());
    let f = Fixture::new();
    let p = f.plan();
    let main = f.root.join("RSSReader/reader.sqlite");
    fs::rename(&main, main.with_extension("old")).unwrap();
    fs::write(&main, b"other").unwrap();
    fs::set_permissions(&main, fs::Permissions::from_mode(0o600)).unwrap();
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    let f = Fixture::new();
    let dir = f.root.join("RSSReader");
    fs::rename(&dir, f.root.join("original")).unwrap();
    symlink(f.root.join("original"), &dir).unwrap();
    assert!(f.store.plan(&f.rss, &f.dest).is_err());
    let f = Fixture::new();
    let shm = f.root.join("RSSReader/reader.sqlite-shm");
    fs::remove_file(&shm).unwrap();
    symlink(f.dest.with_extension("missing"), &shm).unwrap();
    assert!(f.store.plan(&f.rss, &f.dest).is_err());
}
#[test]
fn unsafe_destination_collision_git_appdata_and_parent_swap_rejected() {
    let f = Fixture::new();
    for p in [
        PathBuf::from("relative.sqlite"),
        f.root.join("out.sqlite"),
        f.dest.with_extension("json"),
    ] {
        assert!(f.store.plan(&f.rss, &p).is_err());
    }
    let p = f.plan();
    fs::write(&f.dest, b"KEEP").unwrap();
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert_eq!(fs::read(&f.dest).unwrap(), b"KEEP");
    let f = Fixture::new();
    let p = f.plan();
    fs::create_dir(f.dest.parent().unwrap().join(".git")).unwrap();
    fs::write(
        f.dest.parent().unwrap().join(".git/HEAD"),
        "ref: refs/heads/main",
    )
    .unwrap();
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert!(!f.dest.exists());
    let f = Fixture::new();
    let export = f.dest.parent().unwrap().join("export");
    fs::create_dir(&export).unwrap();
    let d = export.join("out.sqlite");
    let p = f.store.plan(&f.rss, &d).unwrap();
    fs::rename(&export, export.with_extension("old")).unwrap();
    fs::create_dir(&export).unwrap();
    assert!(f.store.execute(&f.rss, &p.plan_id, true).is_err());
    assert!(!d.exists());
}
