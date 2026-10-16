use super::super::metadata_field::MetadataBatchOperationKind;
use super::*;
use std::fs;

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    data: PathBuf,
    repositories: RepositoryStore,
    history: DraftHistoryStore,
    batch: MetadataBatchStore,
    session: String,
}
impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("repo");
        let data = dir.path().join("app");
        fs::create_dir(&root).unwrap();
        fs::create_dir(&data).unwrap();
        let repositories = RepositoryStore::default();
        let session = repositories
            .open_repository(root.to_str().unwrap())
            .unwrap()
            .session_id;
        let history = DraftHistoryStore::new(data.clone()).unwrap();
        Self {
            _dir: dir,
            root,
            data,
            repositories,
            history,
            batch: MetadataBatchStore::default(),
            session,
        }
    }
    fn write(&self, path: &str, text: &str) {
        fs::write(self.root.join(path), text).unwrap();
    }
    fn plan(&self, paths: &[&str]) -> MetadataBatchPlan {
        self.batch
            .plan(
                &self.repositories,
                &self.session,
                &paths.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
                MetadataBatchField::Tags,
                MetadataBatchOperation {
                    kind: MetadataBatchOperationKind::Add,
                    value: "new".into(),
                    replacement: None,
                },
            )
            .unwrap()
    }
    fn execute(&self, plan: &MetadataBatchPlan) -> CommandResult<MetadataBatchResult> {
        self.batch.execute(
            &self.repositories,
            &self.history,
            &self.session,
            &plan.plan_id,
        )
    }
}
const ORIGINAL: &str = "---\ntags: [\"old\"]\ntitle: Original # keep\n---\nOriginal body\n";

#[test]
fn preview_is_read_only_and_execution_preserves_fresh_body_and_persists_recovery() {
    let f = Fixture::new();
    f.write("a.md", ORIGINAL);
    let plan = f.plan(&["a.md"]);
    assert_eq!(fs::read_to_string(f.root.join("a.md")).unwrap(), ORIGINAL);
    assert!(f
        .history
        .list_versions(&f.root, "unused", "a.md")
        .unwrap()
        .versions
        .is_empty());
    let fresh = ORIGINAL.replace("Original", "External latest");
    f.write("a.md", &fresh);
    let result = f.execute(&plan).unwrap();
    assert_eq!(result.results[0].status, "applied");
    assert_eq!(
        fs::read_to_string(f.root.join("a.md")).unwrap(),
        fresh.replace("[\"old\"]", "[\"old\",\"new\"]")
    );
    let reopened_history = DraftHistoryStore::new(f.data.clone()).unwrap();
    let versions = reopened_history
        .list_versions(&f.root, "unused", "a.md")
        .unwrap();
    assert_eq!(versions.versions.len(), 1);
    assert_eq!(
        reopened_history
            .get_version(&f.root, "a.md", &versions.versions[0].version_id)
            .unwrap()
            .text,
        fresh
    );
}

#[test]
fn reports_per_file_conflicts_and_consumes_the_plan_before_writes() {
    let f = Fixture::new();
    f.write("a.md", ORIGINAL);
    f.write("b.md", ORIGINAL);
    let plan = f.plan(&["a.md", "b.md"]);
    let raced = ORIGINAL.replace("old", "raced");
    f.write("a.md", &raced);
    let result = f.execute(&plan).unwrap();
    assert_eq!(
        result
            .results
            .iter()
            .map(|r| r.status.as_str())
            .collect::<Vec<_>>(),
        ["conflict", "applied"]
    );
    assert_eq!(fs::read_to_string(f.root.join("a.md")).unwrap(), raced);
    assert!(fs::read_to_string(f.root.join("b.md"))
        .unwrap()
        .contains("\"new\""));
    assert_eq!(f.execute(&plan).unwrap_err().code, "metadata_plan_expired");
}

#[test]
fn wrong_session_cannot_consume_a_plan_and_expired_plans_cannot_write() {
    let f = Fixture::new();
    f.write("a.md", ORIGINAL);
    let plan = f.plan(&["a.md"]);
    let other = f
        .repositories
        .open_repository(f.root.to_str().unwrap())
        .unwrap();
    assert_eq!(
        f.batch
            .execute(
                &f.repositories,
                &f.history,
                &other.session_id,
                &plan.plan_id
            )
            .unwrap_err()
            .code,
        "metadata_plan_session"
    );
    assert_eq!(f.execute(&plan).unwrap().results[0].status, "applied");
    f.write("a.md", ORIGINAL);
    let plan = f.plan(&["a.md"]);
    f.batch
        .plans
        .lock()
        .unwrap()
        .get_mut(&plan.plan_id)
        .unwrap()
        .expires = Instant::now() - Duration::from_secs(1);
    assert_eq!(f.execute(&plan).unwrap_err().code, "metadata_plan_expired");
    assert_eq!(fs::read_to_string(f.root.join("a.md")).unwrap(), ORIGINAL);
}

#[test]
fn rejects_replaced_root_and_unsupported_or_escaping_targets() {
    let f = Fixture::new();
    f.write("a.md", ORIGINAL);
    f.write("no-header.md", "Body");
    let unavailable = f.plan(&["no-header.md", "../escape.md"]);
    assert!(unavailable
        .previews
        .iter()
        .all(|p| p.status == "unavailable"));
    assert!(f
        .execute(&unavailable)
        .unwrap()
        .results
        .iter()
        .all(|r| r.status == "failed"));
    let plan = f.plan(&["a.md"]);
    fs::rename(&f.root, f.root.with_file_name("old-repo")).unwrap();
    fs::create_dir(&f.root).unwrap();
    f.write("a.md", ORIGINAL);
    assert_eq!(f.execute(&plan).unwrap_err().code, "metadata_root_changed");
    assert_eq!(fs::read_to_string(f.root.join("a.md")).unwrap(), ORIGINAL);
}

#[test]
fn preserves_bom_crlf_and_refuses_read_only_mixed_endings() {
    let f = Fixture::new();
    let crlf = format!("\u{feff}{}", ORIGINAL.replace('\n', "\r\n"));
    f.write("a.md", &crlf);
    f.write("mixed.md", "---\r\ntags: [\"old\"]\n---\nbody");
    let plan = f.plan(&["a.md", "mixed.md"]);
    assert_eq!(plan.previews[1].status, "unavailable");
    let result = f.execute(&plan).unwrap();
    assert_eq!(result.results[0].status, "applied");
    assert_eq!(
        fs::read_to_string(f.root.join("a.md")).unwrap(),
        crlf.replace("[\"old\"]", "[\"old\",\"new\"]")
    );
}

#[test]
fn bounds_targets_and_replaces_old_plans_for_the_same_session() {
    let f = Fixture::new();
    f.write("a.md", ORIGINAL);
    let first = f.plan(&["a.md"]);
    let second = f.plan(&["a.md"]);
    assert_eq!(f.execute(&first).unwrap_err().code, "metadata_plan_expired");
    assert_eq!(f.execute(&second).unwrap().results[0].status, "applied");
    assert!(f
        .batch
        .plan(
            &f.repositories,
            &f.session,
            &["a.md".into(), "a.md".into()],
            MetadataBatchField::Tags,
            MetadataBatchOperation {
                kind: MetadataBatchOperationKind::Add,
                value: "x".into(),
                replacement: None
            }
        )
        .is_err());
}

#[test]
fn history_write_failure_prevents_the_document_write() {
    let f = Fixture::new();
    f.write("a.md", ORIGINAL);
    let plan = f.plan(&["a.md"]);
    let db = rusqlite::Connection::open(f.data.join("DraftHistory/history.sqlite")).unwrap();
    db.execute_batch("CREATE TRIGGER reject_batch_history BEFORE INSERT ON versions BEGIN SELECT RAISE(ABORT, 'simulated history persistence failure'); END;").unwrap();
    let result = f.execute(&plan).unwrap();
    assert_eq!(result.results[0].status, "failed");
    assert_eq!(fs::read_to_string(f.root.join("a.md")).unwrap(), ORIGINAL);
    assert!(f
        .history
        .list_versions(&f.root, "unused", "a.md")
        .unwrap()
        .versions
        .is_empty());
}
