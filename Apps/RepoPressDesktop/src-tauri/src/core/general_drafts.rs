//! App-private general Markdown drafts and deliberately narrow repository transfer plans.
//!
//! A renderer never supplies repository paths or file contents to this layer. Repository text is
//! always re-read through a live `RepositoryStore` document binding; imports use its no-clobber
//! document creation API.  The private copy is intentionally preferred over a clever cross-device
//! transaction: a crash can leave a recoverable duplicate, never the only copy of a draft gone.
use super::{CommandError, CommandResult, DraftHistoryStore, RepositoryStore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const MAX_TEXT_BYTES: usize = 4 * 1024 * 1024;
const MAX_LIST_ENTRIES: i64 = 500;
const PLAN_LIFETIME_SECONDS: i64 = 5 * 60;
const MAX_PLANS: usize = 64;
const MAX_UNDOS: usize = 8;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftSummary {
    pub draft_id: String,
    pub title: String,
    pub source_repository_name: Option<String>,
    pub source_relative_path: Option<String>,
    pub created_at_epoch_seconds: i64,
    pub updated_at_epoch_seconds: i64,
    pub byte_size: u64,
    pub content_sha256: String,
    pub revision: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraft {
    #[serde(flatten)]
    pub summary: GeneralDraftSummary,
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftSnapshot {
    pub entries: Vec<GeneralDraftSummary>,
    pub total: u64,
    pub truncated: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TransferOperation {
    CopyCurrentToGeneral,
    MoveCurrentToGeneral,
    CopyGeneralToRepository,
    MoveGeneralToRepository,
}

impl TransferOperation {
    fn moves_source(self) -> bool {
        matches!(
            self,
            Self::MoveCurrentToGeneral | Self::MoveGeneralToRepository
        )
    }
    fn current_to_general(self) -> bool {
        matches!(
            self,
            Self::CopyCurrentToGeneral | Self::MoveCurrentToGeneral
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftTransferTarget {
    pub draft_id: String,
    pub relative_path: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)] // Contract variants also describe execute-time conflicts, returned as errors.
pub enum GeneralDraftTransferConflictKind {
    UnavailableSource,
    TargetPathOccupied,
    DuplicateTargetPath,
    SourceChanged,
    SameDestination,
    UnavailableTarget,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftTransferConflict {
    pub id: String,
    pub kind: GeneralDraftTransferConflictKind,
    pub draft_id: Option<String>,
    pub title: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftTransferPlanItem {
    pub draft_id: Option<String>,
    pub title: String,
    pub source_label: String,
    pub source_relative_path: Option<String>,
    pub target_label: String,
    pub target_relative_path: Option<String>,
    pub content_sha256: String,
    pub revision: Option<u64>,
    pub conflicts: Vec<GeneralDraftTransferConflict>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftTransferPlan {
    pub plan_id: String,
    pub operation: TransferOperation,
    pub items: Vec<GeneralDraftTransferPlanItem>,
    pub conflicts: Vec<GeneralDraftTransferConflict>,
    pub can_apply: bool,
    pub expires_at_epoch_seconds: i64,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftTransferResult {
    pub operation: TransferOperation,
    pub affected_general_draft_ids: Vec<String>,
    pub affected_relative_paths: Vec<String>,
    pub undo_id: String,
    pub summary: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralDraftTransferUndoResult {
    pub restored_general_draft_ids: Vec<String>,
    pub restored_relative_paths: Vec<String>,
    pub summary: String,
}

#[derive(Clone, Debug)]
struct StoredPlan {
    session_id: String,
    public: GeneralDraftTransferPlan,
    source: PlanSource,
}

#[derive(Clone, Debug)]
enum PlanSource {
    Current {
        document_id: String,
        expected_sha256: String,
        text: String,
        relative_path: String,
        repository_name: String,
    },
    General(Vec<GeneralTargetSource>),
}

#[derive(Clone, Debug)]
struct GeneralTargetSource {
    draft: GeneralDraft,
    relative_path: String,
}

#[derive(Clone, Debug)]
struct StoredUndo {
    undo_id: String,
    session_id: String,
    state: UndoState,
}

#[derive(Clone, Debug)]
enum UndoState {
    CurrentToGeneral {
        draft: GeneralDraft,
        source_relative_path: String,
        moved: bool,
    },
    GeneralToRepository {
        drafts: Vec<GeneralTargetSource>,
        created: Vec<CreatedRepositoryDraft>,
        moved: bool,
    },
}

#[derive(Clone, Debug)]
struct CreatedRepositoryDraft {
    document_id: String,
    relative_path: String,
    content_sha256: String,
}

pub struct GeneralDraftStore {
    db: Mutex<Connection>,
    path: Option<PathBuf>,
    snapshot_identity: Option<[u64; 2]>,
    plans: Mutex<HashMap<String, StoredPlan>>,
    undos: Mutex<VecDeque<StoredUndo>>,
}

impl Default for GeneralDraftStore {
    fn default() -> Self {
        Self::open(None).expect("in-memory general draft database unavailable")
    }
}

impl GeneralDraftStore {
    pub fn new(app_data_dir: PathBuf) -> CommandResult<Self> {
        reject_symlink(&app_data_dir)?;
        let directory = app_data_dir.join("GeneralDrafts");
        if directory.exists() {
            reject_symlink(&directory)?;
        } else {
            fs::create_dir(&directory).map_err(|error| {
                CommandError::io(
                    "general_drafts_storage_unavailable",
                    "create general draft storage",
                    error,
                )
            })?;
        }
        set_private_dir(&directory)?;
        let file = directory.join("general-drafts.sqlite");
        if file.exists() {
            reject_symlink(&file)?;
        }
        let store = Self::open(Some(file))?;
        if let Some(path) = &store.path {
            set_private_file(path)?;
        }
        Ok(store)
    }

    fn open(path: Option<PathBuf>) -> CommandResult<Self> {
        let db = match &path {
            Some(path) => Connection::open(path),
            None => Connection::open_in_memory(),
        }
        .map_err(db_error)?;
        db.pragma_update(None, "foreign_keys", "ON")
            .map_err(db_error)?;
        db.pragma_update(None, "journal_mode", "WAL")
            .map_err(db_error)?;
        initialize_snapshot_schema(&db)?;
        #[cfg(unix)]
        let snapshot_identity = path.as_ref().and_then(|p| {
            use std::os::unix::fs::MetadataExt;
            fs::symlink_metadata(p).ok().map(|m| [m.dev(), m.ino()])
        });
        #[cfg(not(unix))]
        let snapshot_identity = None;
        Ok(Self {
            db: Mutex::new(db),
            path,
            snapshot_identity,
            plans: Mutex::new(HashMap::new()),
            undos: Mutex::new(VecDeque::new()),
        })
    }

    pub(super) fn with_snapshot_source<T>(
        &self,
        action: impl FnOnce(&Connection, &Path, [u64; 2]) -> CommandResult<T>,
    ) -> CommandResult<T> {
        let db = self.db.lock().map_err(|_| {
            CommandError::new(
                "draft_snapshot_backup_invalid",
                "The durable draft database could not be confirmed.",
            )
        })?;
        let path = self.path.as_deref().ok_or_else(|| {
            CommandError::new(
                "draft_snapshot_backup_invalid",
                "A durable draft database is required.",
            )
        })?;
        let identity = self.snapshot_identity.ok_or_else(|| {
            CommandError::new(
                "draft_snapshot_backup_invalid",
                "A durable draft database is required.",
            )
        })?;
        action(&db, path, identity)
    }
    pub fn list(&self) -> CommandResult<GeneralDraftSnapshot> {
        let db = self.lock_db()?;
        let total: i64 = db
            .query_row("SELECT count(*) FROM general_drafts", [], |row| row.get(0))
            .map_err(db_error)?;
        let mut statement = db
            .prepare("SELECT draft_id,title,source_repository_name,source_relative_path,created_at,updated_at,byte_size,content_sha256,revision FROM general_drafts ORDER BY updated_at DESC,rowid DESC LIMIT ?1")
            .map_err(db_error)?;
        let entries = statement
            .query_map([MAX_LIST_ENTRIES], summary_row)
            .map_err(db_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_error)?;
        Ok(GeneralDraftSnapshot {
            truncated: total > MAX_LIST_ENTRIES,
            total: total as u64,
            entries,
        })
    }

    pub fn get(&self, draft_id: &str) -> CommandResult<GeneralDraft> {
        let db = self.lock_db()?;
        db.query_row("SELECT draft_id,title,source_repository_name,source_relative_path,created_at,updated_at,byte_size,content_sha256,revision,text FROM general_drafts WHERE draft_id=?1", [draft_id], draft_row)
            .map_err(map_not_found)
    }

    /// Saves a new draft when `draft_id` is absent. Existing drafts require both optimistic
    /// concurrency values; the client cannot accidentally overwrite a later local edit.
    pub fn save(
        &self,
        draft_id: Option<&str>,
        text: &str,
        expected_revision: Option<u64>,
        expected_sha256: Option<&str>,
    ) -> CommandResult<GeneralDraft> {
        validate_text(text)?;
        let sha = sha256(text);
        let timestamp = now();
        let mut db = self.lock_db()?;
        if let Some(draft_id) = draft_id.filter(|value| !value.is_empty()) {
            let current = get_from(&db, draft_id)?;
            if expected_revision != Some(current.summary.revision)
                || expected_sha256 != Some(current.summary.content_sha256.as_str())
            {
                return Err(edit_conflict());
            }
            let title = derive_title(text, current.summary.source_relative_path.as_deref());
            let revision = current.summary.revision.saturating_add(1);
            db.execute("UPDATE general_drafts SET title=?1,updated_at=?2,byte_size=?3,content_sha256=?4,revision=?5,text=?6 WHERE draft_id=?7 AND revision=?8 AND content_sha256=?9", params![title, timestamp, text.len() as i64, sha, revision as i64, text, draft_id, current.summary.revision as i64, current.summary.content_sha256])
                .map_err(db_error)?;
            return self.get_after_unlock(db, draft_id);
        }
        let draft = GeneralDraft {
            summary: GeneralDraftSummary {
                draft_id: Uuid::new_v4().to_string(),
                title: derive_title(text, None),
                source_repository_name: None,
                source_relative_path: None,
                created_at_epoch_seconds: timestamp,
                updated_at_epoch_seconds: timestamp,
                byte_size: text.len() as u64,
                content_sha256: sha,
                revision: 1,
            },
            text: text.to_string(),
        };
        insert_draft(&mut db, &draft)?;
        Ok(draft)
    }

    pub fn plan(
        &self,
        repositories: &RepositoryStore,
        session_id: &str,
        operation: TransferOperation,
        document_id: Option<&str>,
        expected_sha256: Option<&str>,
        target_items: Option<&[GeneralDraftTransferTarget]>,
    ) -> CommandResult<GeneralDraftTransferPlan> {
        let expires_at_epoch_seconds = now() + PLAN_LIFETIME_SECONDS;
        let plan_id = Uuid::new_v4().to_string();
        let (items, conflicts, source) = if operation.current_to_general() {
            let document_id = document_id
                .filter(|value| !value.is_empty())
                .ok_or_else(|| {
                    CommandError::new(
                        "general_draft_document_required",
                        "A current document is required.",
                    )
                })?;
            let expected_sha256 = expected_sha256
                .filter(|value| !value.is_empty())
                .ok_or_else(|| {
                    CommandError::new(
                        "general_draft_expected_sha_required",
                        "The current document checksum is required.",
                    )
                })?;
            let context = repositories.history_context_for_session(
                session_id,
                document_id,
                expected_sha256,
            )?;
            let repository_name = context
                .root
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("Repository")
                .to_string();
            let item = GeneralDraftTransferPlanItem {
                draft_id: None,
                title: derive_title(&context.text, Some(&context.relative_path)),
                source_label: repository_name.clone(),
                source_relative_path: Some(context.relative_path.clone()),
                target_label: "通用草稿库".to_string(),
                target_relative_path: None,
                content_sha256: sha256(&context.text),
                revision: None,
                conflicts: Vec::new(),
            };
            (
                vec![item],
                Vec::new(),
                PlanSource::Current {
                    document_id: document_id.to_string(),
                    expected_sha256: expected_sha256.to_string(),
                    text: context.text,
                    relative_path: context.relative_path,
                    repository_name,
                },
            )
        } else {
            let targets = target_items
                .filter(|items| !items.is_empty())
                .ok_or_else(|| {
                    CommandError::new(
                        "general_draft_targets_required",
                        "At least one general draft target is required.",
                    )
                })?;
            let root = repositories.root_for_session(session_id)?;
            let repository_name = root
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("Repository")
                .to_string();
            let mut used_paths = HashMap::<String, usize>::new();
            let mut items = Vec::with_capacity(targets.len());
            let mut sources = Vec::with_capacity(targets.len());
            let mut all_conflicts = Vec::new();
            for target in targets {
                let mut item_conflicts = Vec::new();
                let draft = match self.get(&target.draft_id) {
                    Ok(draft) => draft,
                    Err(error) if error.code == "general_draft_not_found" => {
                        let draft = placeholder_draft(&target.draft_id);
                        let conflict = transfer_conflict(
                            GeneralDraftTransferConflictKind::UnavailableSource,
                            &draft,
                            Some(&target.relative_path),
                        );
                        item_conflicts.push(conflict.clone());
                        all_conflicts.push(conflict);
                        draft
                    }
                    Err(error) => return Err(error),
                };
                let prior = used_paths.insert(target.relative_path.clone(), items.len());
                if prior.is_some() {
                    let conflict = transfer_conflict(
                        GeneralDraftTransferConflictKind::DuplicateTargetPath,
                        &draft,
                        Some(&target.relative_path),
                    );
                    item_conflicts.push(conflict.clone());
                    all_conflicts.push(conflict);
                }
                match repositories
                    .markdown_import_target_available(session_id, &target.relative_path)
                {
                    Ok(true) => {}
                    Ok(false) => {
                        let conflict = transfer_conflict(
                            GeneralDraftTransferConflictKind::TargetPathOccupied,
                            &draft,
                            Some(&target.relative_path),
                        );
                        item_conflicts.push(conflict.clone());
                        all_conflicts.push(conflict);
                    }
                    Err(error) => {
                        let conflict = transfer_conflict(
                            GeneralDraftTransferConflictKind::UnavailableTarget,
                            &draft,
                            Some(&target.relative_path),
                        );
                        item_conflicts.push(conflict.clone());
                        all_conflicts.push(conflict);
                        // A malformed or symlinked target is intentionally described as an
                        // unavailable target rather than exposing filesystem detail to a plan.
                        let _ = error;
                    }
                }
                let item = GeneralDraftTransferPlanItem {
                    draft_id: Some(draft.summary.draft_id.clone()),
                    title: draft.summary.title.clone(),
                    source_label: "通用草稿库".to_string(),
                    source_relative_path: draft.summary.source_relative_path.clone(),
                    target_label: repository_name.clone(),
                    target_relative_path: Some(target.relative_path.clone()),
                    content_sha256: draft.summary.content_sha256.clone(),
                    revision: Some(draft.summary.revision),
                    conflicts: item_conflicts,
                };
                sources.push(GeneralTargetSource {
                    draft,
                    relative_path: target.relative_path.clone(),
                });
                items.push(item);
            }
            (
                items,
                unique_conflicts(all_conflicts),
                PlanSource::General(sources),
            )
        };
        let public = GeneralDraftTransferPlan {
            plan_id: plan_id.clone(),
            operation,
            items,
            can_apply: conflicts.is_empty(),
            conflicts,
            expires_at_epoch_seconds,
            warnings: vec!["跨站点需先切换目标仓库；当前版本不注册任意仓库路径。".to_string()],
        };
        let mut plans = self.lock_plans()?;
        let timestamp = now();
        plans.retain(|_, stored| stored.public.expires_at_epoch_seconds >= timestamp);
        while plans.len() >= MAX_PLANS {
            let oldest = plans
                .iter()
                .min_by_key(|(_, stored)| stored.public.expires_at_epoch_seconds)
                .map(|(id, _)| id.clone());
            if let Some(oldest) = oldest {
                plans.remove(&oldest);
            } else {
                break;
            }
        }
        plans.insert(
            plan_id,
            StoredPlan {
                session_id: session_id.to_string(),
                public: public.clone(),
                source,
            },
        );
        Ok(public)
    }

    pub fn execute(
        &self,
        repositories: &RepositoryStore,
        history: &DraftHistoryStore,
        session_id: &str,
        plan_id: &str,
    ) -> CommandResult<GeneralDraftTransferResult> {
        let plan = self.claim_plan(session_id, plan_id)?;
        if !plan.public.can_apply {
            return Err(CommandError::new(
                "general_draft_plan_conflicted",
                "This transfer plan has conflicts and cannot be applied.",
            ));
        }
        let _gate = repositories.lock_recovery_operation()?;
        match plan.source {
            PlanSource::Current {
                document_id,
                expected_sha256,
                text,
                relative_path,
                repository_name,
            } => {
                let context = repositories
                    .history_context_for_session(session_id, &document_id, &expected_sha256)
                    .map_err(as_source_changed)?;
                if context.text != text || context.relative_path != relative_path {
                    return Err(source_changed());
                }
                let draft = self.insert_transfer_draft(
                    &text,
                    Some(repository_name),
                    Some(relative_path.clone()),
                )?;
                let moved = plan.public.operation.moves_source();
                if moved {
                    // Persist both private copies before unlinking the sole repository copy. The
                    // recycle receipt uses the same safe ordering as normal document deletion.
                    let receipt = history.record_deleted(
                        &context.root,
                        &context.relative_path,
                        &context.text,
                        &context.baseline_sha256,
                    )?;
                    if let Err(error) = repositories.delete_markdown_document(
                        session_id,
                        &document_id,
                        &expected_sha256,
                    ) {
                        let _ = history.rollback_deleted(&context.root, &receipt);
                        let _ = self.delete_if_unchanged(
                            &draft.summary.draft_id,
                            draft.summary.revision,
                            &draft.summary.content_sha256,
                        );
                        return Err(error);
                    }
                    let _ = history.finalize_deleted(&context.root, &receipt);
                }
                let undo_id = self.push_undo(StoredUndo {
                    undo_id: Uuid::new_v4().to_string(),
                    session_id: session_id.to_string(),
                    state: UndoState::CurrentToGeneral {
                        draft: draft.clone(),
                        source_relative_path: relative_path.clone(),
                        moved,
                    },
                })?;
                Ok(GeneralDraftTransferResult {
                    operation: plan.public.operation,
                    affected_general_draft_ids: vec![draft.summary.draft_id],
                    affected_relative_paths: if moved {
                        vec![relative_path]
                    } else {
                        Vec::new()
                    },
                    undo_id,
                    summary: if moved {
                        "草稿已移入通用草稿库。"
                    } else {
                        "草稿已复制到通用草稿库。"
                    }
                    .to_string(),
                })
            }
            PlanSource::General(sources) => self.execute_general_to_repository(
                repositories,
                session_id,
                plan.public.operation,
                sources,
            ),
        }
    }

    fn execute_general_to_repository(
        &self,
        repositories: &RepositoryStore,
        session_id: &str,
        operation: TransferOperation,
        sources: Vec<GeneralTargetSource>,
    ) -> CommandResult<GeneralDraftTransferResult> {
        // Complete source and target revalidation before creating the first destination.
        let mut paths = HashMap::new();
        for source in &sources {
            let current = self
                .get(&source.draft.summary.draft_id)
                .map_err(as_source_changed)?;
            if current.summary.revision != source.draft.summary.revision
                || current.summary.content_sha256 != source.draft.summary.content_sha256
            {
                return Err(source_changed());
            }
            if paths.insert(source.relative_path.clone(), ()).is_some() {
                return Err(CommandError::new(
                    "general_draft_duplicate_target",
                    "The transfer has duplicate target paths.",
                ));
            }
            match repositories.markdown_import_target_available(session_id, &source.relative_path) {
                Ok(true) => {}
                Ok(false) => {
                    return Err(CommandError::new(
                        "general_draft_target_occupied",
                        "A target document already exists.",
                    ))
                }
                Err(_) => {
                    return Err(CommandError::new(
                        "general_draft_target_unavailable",
                        "A target document is unavailable.",
                    ))
                }
            }
        }
        let mut created = Vec::with_capacity(sources.len());
        for source in &sources {
            match repositories.create_markdown_document(
                session_id,
                &source.relative_path,
                &source.draft.text,
            ) {
                Ok(document) => created.push(CreatedRepositoryDraft {
                    document_id: document.document_id,
                    relative_path: document.relative_path,
                    content_sha256: document.baseline_sha256,
                }),
                Err(error) => {
                    self.rollback_created(repositories, session_id, &created);
                    return Err(error);
                }
            }
        }
        let moved = operation.moves_source();
        if moved {
            // Delete only after every no-clobber creation succeeds. A private DB failure leaves
            // duplicate copies, which is deliberately recoverable.
            if let Err(error) = self.delete_sources_if_unchanged(&sources) {
                self.rollback_created(repositories, session_id, &created);
                return Err(error);
            }
        }
        let undo_id = self.push_undo(StoredUndo {
            undo_id: Uuid::new_v4().to_string(),
            session_id: session_id.to_string(),
            state: UndoState::GeneralToRepository {
                drafts: sources.clone(),
                created: created.clone(),
                moved,
            },
        })?;
        Ok(GeneralDraftTransferResult {
            operation,
            affected_general_draft_ids: if moved {
                sources
                    .iter()
                    .map(|source| source.draft.summary.draft_id.clone())
                    .collect()
            } else {
                Vec::new()
            },
            affected_relative_paths: created
                .into_iter()
                .map(|entry| entry.relative_path)
                .collect(),
            undo_id,
            summary: if moved {
                "通用草稿已移入当前仓库。"
            } else {
                "通用草稿已复制到当前仓库。"
            }
            .to_string(),
        })
    }

    pub fn undo(
        &self,
        repositories: &RepositoryStore,
        session_id: &str,
        undo_id: &str,
    ) -> CommandResult<GeneralDraftTransferUndoResult> {
        let undo = self.claim_undo(session_id, undo_id)?;
        let _gate = repositories.lock_recovery_operation()?;
        match undo.state {
            UndoState::CurrentToGeneral {
                draft,
                source_relative_path,
                moved,
            } => {
                self.require_unchanged(&draft)?;
                if !moved {
                    self.delete_if_unchanged(
                        &draft.summary.draft_id,
                        draft.summary.revision,
                        &draft.summary.content_sha256,
                    )?;
                    return Ok(GeneralDraftTransferUndoResult {
                        restored_general_draft_ids: Vec::new(),
                        restored_relative_paths: Vec::new(),
                        summary: "已撤销复制到通用草稿库。".to_string(),
                    });
                }
                if !repositories
                    .markdown_import_target_available(session_id, &source_relative_path)?
                {
                    return Err(CommandError::new(
                        "general_draft_undo_target_occupied",
                        "The original repository path is now occupied.",
                    ));
                }
                repositories.create_markdown_document(
                    session_id,
                    &source_relative_path,
                    &draft.text,
                )?;
                // If this private deletion fails, retain the duplicate rather than report file
                // restoration as a failure or delete its only durable copy.
                self.delete_if_unchanged(
                    &draft.summary.draft_id,
                    draft.summary.revision,
                    &draft.summary.content_sha256,
                )?;
                Ok(GeneralDraftTransferUndoResult {
                    restored_general_draft_ids: Vec::new(),
                    restored_relative_paths: vec![source_relative_path],
                    summary: "已恢复原仓库草稿。".to_string(),
                })
            }
            UndoState::GeneralToRepository {
                drafts,
                created,
                moved,
            } => {
                for created_entry in &created {
                    let context = repositories
                        .history_context_for_session(
                            session_id,
                            &created_entry.document_id,
                            &created_entry.content_sha256,
                        )
                        .map_err(as_source_changed)?;
                    if context.relative_path != created_entry.relative_path {
                        return Err(source_changed());
                    }
                }
                if moved {
                    for draft in &drafts {
                        if self.get_optional(&draft.draft.summary.draft_id)?.is_some() {
                            return Err(CommandError::new(
                                "general_draft_undo_same_destination",
                                "A general draft with the original identity already exists.",
                            ));
                        }
                    }
                    for draft in &drafts {
                        self.restore_exact(&draft.draft)?;
                    }
                }
                for created_entry in &created {
                    repositories.delete_markdown_document(
                        session_id,
                        &created_entry.document_id,
                        &created_entry.content_sha256,
                    )?;
                }
                Ok(GeneralDraftTransferUndoResult {
                    restored_general_draft_ids: if moved {
                        drafts
                            .iter()
                            .map(|draft| draft.draft.summary.draft_id.clone())
                            .collect()
                    } else {
                        Vec::new()
                    },
                    restored_relative_paths: Vec::new(),
                    summary: if moved {
                        "已恢复通用草稿并移除仓库副本。"
                    } else {
                        "已撤销复制到仓库。"
                    }
                    .to_string(),
                })
            }
        }
    }

    fn insert_transfer_draft(
        &self,
        text: &str,
        repository_name: Option<String>,
        relative_path: Option<String>,
    ) -> CommandResult<GeneralDraft> {
        validate_text(text)?;
        let timestamp = now();
        let draft = GeneralDraft {
            summary: GeneralDraftSummary {
                draft_id: Uuid::new_v4().to_string(),
                title: derive_title(text, relative_path.as_deref()),
                source_repository_name: repository_name,
                source_relative_path: relative_path,
                created_at_epoch_seconds: timestamp,
                updated_at_epoch_seconds: timestamp,
                byte_size: text.len() as u64,
                content_sha256: sha256(text),
                revision: 1,
            },
            text: text.to_string(),
        };
        let mut db = self.lock_db()?;
        insert_draft(&mut db, &draft)?;
        Ok(draft)
    }

    fn delete_sources_if_unchanged(&self, sources: &[GeneralTargetSource]) -> CommandResult<()> {
        let mut db = self.lock_db()?;
        let transaction = db.transaction().map_err(db_error)?;
        for source in sources {
            let changed = transaction.execute("DELETE FROM general_drafts WHERE draft_id=?1 AND revision=?2 AND content_sha256=?3", params![source.draft.summary.draft_id, source.draft.summary.revision as i64, source.draft.summary.content_sha256]).map_err(db_error)?;
            if changed != 1 {
                return Err(source_changed());
            }
        }
        transaction.commit().map_err(db_error)
    }

    fn rollback_created(
        &self,
        repositories: &RepositoryStore,
        session_id: &str,
        created: &[CreatedRepositoryDraft],
    ) {
        for created_entry in created.iter().rev() {
            let _ = repositories.delete_markdown_document(
                session_id,
                &created_entry.document_id,
                &created_entry.content_sha256,
            );
        }
    }

    fn require_unchanged(&self, expected: &GeneralDraft) -> CommandResult<()> {
        let current = self
            .get(&expected.summary.draft_id)
            .map_err(as_source_changed)?;
        if current.summary.revision != expected.summary.revision
            || current.summary.content_sha256 != expected.summary.content_sha256
        {
            return Err(source_changed());
        }
        Ok(())
    }
    fn delete_if_unchanged(&self, draft_id: &str, revision: u64, sha: &str) -> CommandResult<()> {
        let db = self.lock_db()?;
        let changed = db.execute("DELETE FROM general_drafts WHERE draft_id=?1 AND revision=?2 AND content_sha256=?3", params![draft_id, revision as i64, sha]).map_err(db_error)?;
        if changed == 1 {
            Ok(())
        } else {
            Err(source_changed())
        }
    }
    fn restore_exact(&self, draft: &GeneralDraft) -> CommandResult<()> {
        let mut db = self.lock_db()?;
        insert_draft(&mut db, draft)
    }
    fn get_optional(&self, draft_id: &str) -> CommandResult<Option<GeneralDraft>> {
        let db = self.lock_db()?;
        db.query_row("SELECT draft_id,title,source_repository_name,source_relative_path,created_at,updated_at,byte_size,content_sha256,revision,text FROM general_drafts WHERE draft_id=?1", [draft_id], draft_row).optional().map_err(db_error)
    }
    fn get_after_unlock(
        &self,
        db: std::sync::MutexGuard<'_, Connection>,
        draft_id: &str,
    ) -> CommandResult<GeneralDraft> {
        drop(db);
        self.get(draft_id)
    }
    fn claim_plan(&self, session_id: &str, plan_id: &str) -> CommandResult<StoredPlan> {
        let mut plans = self.lock_plans()?;
        let plan = plans.remove(plan_id).ok_or_else(plan_not_found)?;
        if plan.session_id != session_id || plan.public.expires_at_epoch_seconds < now() {
            return Err(plan_not_found());
        }
        Ok(plan)
    }
    fn push_undo(&self, mut undo: StoredUndo) -> CommandResult<String> {
        let id = undo.undo_id.clone();
        let mut undos = self.lock_undos()?;
        // Keep only bounded, one-shot receipts. Any older receipt that falls out is invalid.
        while undos.len() >= MAX_UNDOS {
            undos.pop_front();
        }
        undo.undo_id = id.clone();
        undos.push_back(undo);
        Ok(id)
    }
    fn claim_undo(&self, session_id: &str, undo_id: &str) -> CommandResult<StoredUndo> {
        let mut undos = self.lock_undos()?;
        let index = undos
            .iter()
            .position(|undo| undo.undo_id == undo_id)
            .ok_or_else(undo_not_found)?;
        let undo = undos.remove(index).ok_or_else(undo_not_found)?;
        if undo.session_id != session_id {
            return Err(undo_not_found());
        }
        Ok(undo)
    }
    fn lock_db(&self) -> CommandResult<std::sync::MutexGuard<'_, Connection>> {
        self.db.lock().map_err(|_| {
            CommandError::new(
                "general_drafts_unavailable",
                "General drafts are temporarily unavailable.",
            )
        })
    }
    fn lock_plans(&self) -> CommandResult<std::sync::MutexGuard<'_, HashMap<String, StoredPlan>>> {
        self.plans.lock().map_err(|_| {
            CommandError::new(
                "general_draft_plan_unavailable",
                "General draft transfer planning is temporarily unavailable.",
            )
        })
    }
    fn lock_undos(&self) -> CommandResult<std::sync::MutexGuard<'_, VecDeque<StoredUndo>>> {
        self.undos.lock().map_err(|_| {
            CommandError::new(
                "general_draft_undo_unavailable",
                "General draft undo is temporarily unavailable.",
            )
        })
    }
}

pub(super) fn initialize_snapshot_schema(db: &Connection) -> CommandResult<()> {
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS general_drafts (
                draft_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                source_repository_name TEXT,
                source_relative_path TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                byte_size INTEGER NOT NULL,
                content_sha256 TEXT NOT NULL,
                revision INTEGER NOT NULL,
                text TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS general_drafts_updated ON general_drafts(updated_at DESC);",
    )
    .map_err(db_error)
}

fn get_from(db: &Connection, draft_id: &str) -> CommandResult<GeneralDraft> {
    db.query_row("SELECT draft_id,title,source_repository_name,source_relative_path,created_at,updated_at,byte_size,content_sha256,revision,text FROM general_drafts WHERE draft_id=?1", [draft_id], draft_row).map_err(map_not_found)
}
fn insert_draft(db: &mut Connection, draft: &GeneralDraft) -> CommandResult<()> {
    db.execute("INSERT INTO general_drafts(draft_id,title,source_repository_name,source_relative_path,created_at,updated_at,byte_size,content_sha256,revision,text) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)", params![draft.summary.draft_id, draft.summary.title, draft.summary.source_repository_name, draft.summary.source_relative_path, draft.summary.created_at_epoch_seconds, draft.summary.updated_at_epoch_seconds, draft.summary.byte_size as i64, draft.summary.content_sha256, draft.summary.revision as i64, draft.text]).map_err(db_error)?;
    Ok(())
}
fn summary_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GeneralDraftSummary> {
    Ok(GeneralDraftSummary {
        draft_id: row.get(0)?,
        title: row.get(1)?,
        source_repository_name: row.get(2)?,
        source_relative_path: row.get(3)?,
        created_at_epoch_seconds: row.get(4)?,
        updated_at_epoch_seconds: row.get(5)?,
        byte_size: row.get::<_, i64>(6)? as u64,
        content_sha256: row.get(7)?,
        revision: row.get::<_, i64>(8)? as u64,
    })
}
fn draft_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GeneralDraft> {
    Ok(GeneralDraft {
        summary: GeneralDraftSummary {
            draft_id: row.get(0)?,
            title: row.get(1)?,
            source_repository_name: row.get(2)?,
            source_relative_path: row.get(3)?,
            created_at_epoch_seconds: row.get(4)?,
            updated_at_epoch_seconds: row.get(5)?,
            byte_size: row.get::<_, i64>(6)? as u64,
            content_sha256: row.get(7)?,
            revision: row.get::<_, i64>(8)? as u64,
        },
        text: row.get(9)?,
    })
}
fn placeholder_draft(draft_id: &str) -> GeneralDraft {
    GeneralDraft {
        summary: GeneralDraftSummary {
            draft_id: draft_id.to_string(),
            title: "Unavailable draft".to_string(),
            source_repository_name: None,
            source_relative_path: None,
            created_at_epoch_seconds: 0,
            updated_at_epoch_seconds: 0,
            byte_size: 0,
            content_sha256: String::new(),
            revision: 0,
        },
        text: String::new(),
    }
}
fn derive_title(text: &str, fallback_path: Option<&str>) -> String {
    for line in text.lines().take(80) {
        if let Some(value) = line
            .strip_prefix("title:")
            .or_else(|| line.strip_prefix("Title:"))
        {
            let value = value.trim().trim_matches(['\'', '"']);
            if !value.is_empty() {
                return value.chars().take(160).collect();
            }
        }
        if let Some(value) = line.strip_prefix("# ") {
            let value = value.trim();
            if !value.is_empty() {
                return value.chars().take(160).collect();
            }
        }
    }
    fallback_path
        .and_then(|path| Path::new(path).file_stem())
        .and_then(|name| name.to_str())
        .filter(|value| !value.is_empty())
        .map(|value| value.chars().take(160).collect())
        .unwrap_or_else(|| "Untitled draft".to_string())
}
fn transfer_conflict(
    kind: GeneralDraftTransferConflictKind,
    draft: &GeneralDraft,
    target_path: Option<&str>,
) -> GeneralDraftTransferConflict {
    let kind_name = match kind {
        GeneralDraftTransferConflictKind::UnavailableSource => "unavailableSource",
        GeneralDraftTransferConflictKind::TargetPathOccupied => "targetPathOccupied",
        GeneralDraftTransferConflictKind::DuplicateTargetPath => "duplicateTargetPath",
        GeneralDraftTransferConflictKind::SourceChanged => "sourceChanged",
        GeneralDraftTransferConflictKind::SameDestination => "sameDestination",
        GeneralDraftTransferConflictKind::UnavailableTarget => "unavailableTarget",
    };
    let target = target_path.unwrap_or("");
    let message = match kind {
        GeneralDraftTransferConflictKind::UnavailableSource => "源通用草稿已不可用。",
        GeneralDraftTransferConflictKind::TargetPathOccupied => {
            "目标路径已有文档，转移不会覆盖它。"
        }
        GeneralDraftTransferConflictKind::DuplicateTargetPath => {
            "批量转移中有多个草稿使用同一目标路径。"
        }
        GeneralDraftTransferConflictKind::SourceChanged => "源草稿在计划生成后已变更。",
        GeneralDraftTransferConflictKind::SameDestination => "源和目标相同，无法执行移动。",
        GeneralDraftTransferConflictKind::UnavailableTarget => {
            "目标路径不可用，可能不是安全的 Markdown 位置。"
        }
    };
    GeneralDraftTransferConflict {
        id: format!("{kind_name}:{}:{target}", draft.summary.draft_id),
        kind,
        draft_id: (!draft.summary.draft_id.is_empty()).then(|| draft.summary.draft_id.clone()),
        title: draft.summary.title.clone(),
        message: message.to_string(),
    }
}
fn unique_conflicts(
    values: Vec<GeneralDraftTransferConflict>,
) -> Vec<GeneralDraftTransferConflict> {
    let mut seen = HashMap::new();
    values
        .into_iter()
        .filter(|value| seen.insert(value.id.clone(), ()).is_none())
        .collect()
}
fn sha256(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn validate_text(text: &str) -> CommandResult<()> {
    if text.len() > MAX_TEXT_BYTES {
        Err(CommandError::new(
            "general_draft_too_large",
            "General drafts are limited to 4 MiB.",
        ))
    } else if text.contains('\r') {
        Err(CommandError::new(
            "invalid_document_line_endings",
            "General draft text must use normalized LF line endings.",
        ))
    } else {
        Ok(())
    }
}
fn db_error(error: rusqlite::Error) -> CommandError {
    CommandError::new(
        "general_drafts_unavailable",
        format!("General draft storage is unavailable: {error}"),
    )
}
fn map_not_found(error: rusqlite::Error) -> CommandError {
    if matches!(error, rusqlite::Error::QueryReturnedNoRows) {
        CommandError::new(
            "general_draft_not_found",
            "The requested general draft was not found.",
        )
    } else {
        db_error(error)
    }
}
fn edit_conflict() -> CommandError {
    CommandError::new(
        "general_draft_conflict",
        "This general draft changed since it was opened. Refresh it before saving.",
    )
}
fn source_changed() -> CommandError {
    CommandError::new(
        "general_draft_source_changed",
        "A transfer source changed after the plan was created; nothing was overwritten.",
    )
}
fn as_source_changed(_: CommandError) -> CommandError {
    source_changed()
}
fn plan_not_found() -> CommandError {
    CommandError::new(
        "general_draft_plan_not_found",
        "This transfer plan expired, was already used, or is unavailable.",
    )
}
fn undo_not_found() -> CommandError {
    CommandError::new(
        "general_draft_undo_not_found",
        "This transfer undo receipt was already used or is unavailable.",
    )
}
fn reject_symlink(path: &Path) -> CommandResult<()> {
    if fs::symlink_metadata(path)
        .map_err(|error| {
            CommandError::io(
                "general_drafts_storage_unavailable",
                "inspect general draft storage",
                error,
            )
        })?
        .file_type()
        .is_symlink()
    {
        Err(CommandError::new(
            "general_drafts_storage_rejected",
            "General draft storage symlinks are not allowed.",
        ))
    } else {
        Ok(())
    }
}
#[cfg(unix)]
fn set_private_dir(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
        CommandError::io(
            "general_drafts_storage_unavailable",
            "secure general draft directory",
            error,
        )
    })
}
#[cfg(not(unix))]
fn set_private_dir(_: &Path) -> CommandResult<()> {
    Ok(())
}
#[cfg(unix)]
fn set_private_file(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        CommandError::io(
            "general_drafts_storage_unavailable",
            "secure general draft database",
            error,
        )
    })
}
#[cfg(not(unix))]
fn set_private_file(_: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn repository_fixture() -> (tempfile::TempDir, RepositoryStore, String) {
        let temporary = tempfile::tempdir().unwrap();
        fs::create_dir(temporary.path().join("content")).unwrap();
        fs::write(temporary.path().join("content/current.md"), "# Current\n").unwrap();
        let repositories = RepositoryStore::default();
        let session = repositories
            .open_repository(temporary.path().to_str().unwrap())
            .unwrap();
        (temporary, repositories, session.session_id)
    }

    #[test]
    fn persists_and_rejects_oversized_or_stale_saves() {
        let temp = tempfile::tempdir().unwrap();
        let store = GeneralDraftStore::new(temp.path().to_path_buf()).unwrap();
        let draft = store.save(None, "# First\n", None, None).unwrap();
        let reopened = GeneralDraftStore::new(temp.path().to_path_buf()).unwrap();
        assert_eq!(
            reopened.get(&draft.summary.draft_id).unwrap().text,
            "# First\n"
        );
        assert_eq!(
            store
                .save(
                    Some(&draft.summary.draft_id),
                    "# Second\n",
                    Some(9),
                    Some(&draft.summary.content_sha256)
                )
                .unwrap_err()
                .code,
            "general_draft_conflict"
        );
        assert_eq!(
            store
                .save(None, &"x".repeat(MAX_TEXT_BYTES + 1), None, None)
                .unwrap_err()
                .code,
            "general_draft_too_large"
        );
    }

    #[cfg(unix)]
    #[test]
    fn private_storage_has_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let _ = GeneralDraftStore::new(temp.path().to_path_buf()).unwrap();
        assert_eq!(
            fs::metadata(temp.path().join("GeneralDrafts"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(temp.path().join("GeneralDrafts/general-drafts.sqlite"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn supports_four_operations_with_one_shot_undo() {
        let (_temporary, repositories, session_id) = repository_fixture();
        let store = GeneralDraftStore::default();
        let history = DraftHistoryStore::default();

        let current = repositories
            .open_document(&session_id, "content/current.md")
            .unwrap();
        let copy_current = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::CopyCurrentToGeneral,
                Some(&current.document_id),
                Some(&current.baseline_sha256),
                None,
            )
            .unwrap();
        let copied = store
            .execute(&repositories, &history, &session_id, &copy_current.plan_id)
            .unwrap();
        assert_eq!(store.list().unwrap().total, 1);
        store
            .undo(&repositories, &session_id, &copied.undo_id)
            .unwrap();
        assert_eq!(store.list().unwrap().total, 0);
        assert_eq!(
            store
                .undo(&repositories, &session_id, &copied.undo_id)
                .unwrap_err()
                .code,
            "general_draft_undo_not_found"
        );

        let current = repositories
            .open_document(&session_id, "content/current.md")
            .unwrap();
        let move_current = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::MoveCurrentToGeneral,
                Some(&current.document_id),
                Some(&current.baseline_sha256),
                None,
            )
            .unwrap();
        let moved = store
            .execute(&repositories, &history, &session_id, &move_current.plan_id)
            .unwrap();
        assert!(repositories
            .markdown_import_target_available(&session_id, "content/current.md")
            .unwrap());
        store
            .undo(&repositories, &session_id, &moved.undo_id)
            .unwrap();
        assert!(!repositories
            .markdown_import_target_available(&session_id, "content/current.md")
            .unwrap());

        let copied_general = store.save(None, "# Library copy\n", None, None).unwrap();
        let copy_targets = [GeneralDraftTransferTarget {
            draft_id: copied_general.summary.draft_id.clone(),
            relative_path: "content/library-copy.md".to_string(),
        }];
        let copy_to_repository = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::CopyGeneralToRepository,
                None,
                None,
                Some(&copy_targets),
            )
            .unwrap();
        let imported = store
            .execute(
                &repositories,
                &history,
                &session_id,
                &copy_to_repository.plan_id,
            )
            .unwrap();
        assert!(store.get(&copied_general.summary.draft_id).is_ok());
        store
            .undo(&repositories, &session_id, &imported.undo_id)
            .unwrap();
        assert!(repositories
            .markdown_import_target_available(&session_id, "content/library-copy.md")
            .unwrap());

        let moved_general = store.save(None, "# Library move\n", None, None).unwrap();
        let move_targets = [GeneralDraftTransferTarget {
            draft_id: moved_general.summary.draft_id.clone(),
            relative_path: "content/library-move.md".to_string(),
        }];
        let move_to_repository = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::MoveGeneralToRepository,
                None,
                None,
                Some(&move_targets),
            )
            .unwrap();
        let moved_to_repository = store
            .execute(
                &repositories,
                &history,
                &session_id,
                &move_to_repository.plan_id,
            )
            .unwrap();
        assert!(store.get(&moved_general.summary.draft_id).is_err());
        store
            .undo(&repositories, &session_id, &moved_to_repository.undo_id)
            .unwrap();
        assert_eq!(
            store
                .get(&moved_general.summary.draft_id)
                .unwrap()
                .summary
                .revision,
            moved_general.summary.revision
        );
    }

    #[test]
    fn reports_batch_conflicts_and_rejects_changed_sources_at_execute_time() {
        let (_temporary, repositories, session_id) = repository_fixture();
        let store = GeneralDraftStore::default();
        let history = DraftHistoryStore::default();
        let first = store.save(None, "# First\n", None, None).unwrap();
        let second = store.save(None, "# Second\n", None, None).unwrap();
        let duplicates = [
            GeneralDraftTransferTarget {
                draft_id: first.summary.draft_id.clone(),
                relative_path: "content/same.md".to_string(),
            },
            GeneralDraftTransferTarget {
                draft_id: second.summary.draft_id.clone(),
                relative_path: "content/same.md".to_string(),
            },
        ];
        let duplicate_plan = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::CopyGeneralToRepository,
                None,
                None,
                Some(&duplicates),
            )
            .unwrap();
        assert!(!duplicate_plan.can_apply);
        assert!(duplicate_plan.conflicts.iter().any(|conflict| matches!(
            conflict.kind,
            GeneralDraftTransferConflictKind::DuplicateTargetPath
        )));

        let occupied = [GeneralDraftTransferTarget {
            draft_id: second.summary.draft_id.clone(),
            relative_path: "content/current.md".to_string(),
        }];
        let occupied_plan = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::CopyGeneralToRepository,
                None,
                None,
                Some(&occupied),
            )
            .unwrap();
        assert!(occupied_plan.conflicts.iter().any(|conflict| matches!(
            conflict.kind,
            GeneralDraftTransferConflictKind::TargetPathOccupied
        )));

        let source = [GeneralDraftTransferTarget {
            draft_id: first.summary.draft_id.clone(),
            relative_path: "content/stale.md".to_string(),
        }];
        let stale_plan = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::CopyGeneralToRepository,
                None,
                None,
                Some(&source),
            )
            .unwrap();
        store
            .save(
                Some(&first.summary.draft_id),
                "# Changed\n",
                Some(first.summary.revision),
                Some(&first.summary.content_sha256),
            )
            .unwrap();
        assert_eq!(
            store
                .execute(&repositories, &history, &session_id, &stale_plan.plan_id)
                .unwrap_err()
                .code,
            "general_draft_source_changed"
        );

        let undo_targets = [GeneralDraftTransferTarget {
            draft_id: second.summary.draft_id.clone(),
            relative_path: "content/undo-changed.md".to_string(),
        }];
        let undo_plan = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::CopyGeneralToRepository,
                None,
                None,
                Some(&undo_targets),
            )
            .unwrap();
        let executed = store
            .execute(&repositories, &history, &session_id, &undo_plan.plan_id)
            .unwrap();
        let changed_target = repositories
            .open_document(&session_id, "content/undo-changed.md")
            .unwrap();
        repositories
            .save_document(
                &session_id,
                &changed_target.document_id,
                "# Subsequent edit\n",
                &changed_target.baseline_sha256,
            )
            .unwrap();
        assert_eq!(
            store
                .undo(&repositories, &session_id, &executed.undo_id)
                .unwrap_err()
                .code,
            "general_draft_source_changed"
        );

        let expiry_targets = [GeneralDraftTransferTarget {
            draft_id: second.summary.draft_id.clone(),
            relative_path: "content/expired.md".to_string(),
        }];
        let expired = store
            .plan(
                &repositories,
                &session_id,
                TransferOperation::CopyGeneralToRepository,
                None,
                None,
                Some(&expiry_targets),
            )
            .unwrap();
        store
            .lock_plans()
            .unwrap()
            .get_mut(&expired.plan_id)
            .unwrap()
            .public
            .expires_at_epoch_seconds = now() - 1;
        assert_eq!(
            store
                .execute(&repositories, &history, &session_id, &expired.plan_id)
                .unwrap_err()
                .code,
            "general_draft_plan_not_found"
        );
    }
}
