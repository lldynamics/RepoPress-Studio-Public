mod knowledge_restore_history_export;
pub use knowledge_restore_history_export::{
    discard_knowledge_restore_history_export, execute_knowledge_restore_history_export,
    inspect_knowledge_restore_history_export, plan_knowledge_restore_history_export,
};
mod knowledge_restore_cleanup;
pub use knowledge_restore_cleanup::{
    discard_knowledge_restore_cleanup, execute_knowledge_restore_cleanup,
    inspect_knowledge_restore_cleanup, plan_knowledge_restore_cleanup,
};
mod knowledge_restore_archive;
pub use knowledge_restore_archive::{
    discard_knowledge_restore_archive, execute_knowledge_restore_archive,
    inspect_knowledge_restore_archive, plan_knowledge_restore_archive,
};
mod knowledge_restore_install;
pub use knowledge_restore_install::{
    discard_knowledge_restore_install, execute_knowledge_restore_install,
    execute_knowledge_restore_recovery, inspect_knowledge_restore, plan_knowledge_restore_install,
    plan_knowledge_restore_recovery,
};
mod knowledge_merge_projection;
pub use knowledge_merge_projection::{
    discard_knowledge_merge_projection, plan_knowledge_merge_projection,
    preflight_knowledge_merge_projection,
};
mod knowledge_restore_qualification;
pub use knowledge_restore_qualification::{
    discard_knowledge_restore_qualification, plan_knowledge_restore_qualification,
    recheck_knowledge_restore_qualification,
};
mod knowledge_candidate_check;
pub use knowledge_candidate_check::{
    discard_knowledge_candidate_check, inspect_knowledge_candidate, recheck_knowledge_candidate,
};
mod knowledge_package_stage;
pub use knowledge_package_stage::{
    discard_knowledge_package_stage, execute_knowledge_package_stage, plan_knowledge_package_stage,
};
mod knowledge_package_check;
pub use knowledge_package_check::{
    discard_knowledge_package_check, inspect_knowledge_package, preflight_knowledge_package,
};
mod knowledge_backup;
pub use knowledge_backup::{
    discard_knowledge_backup, execute_knowledge_backup, plan_knowledge_backup,
};
mod knowledge_integrity;
pub use knowledge_integrity::{
    discard_knowledge_integrity, inspect_knowledge_integrity, recheck_knowledge_integrity,
};
mod draft_snapshot_backup;
pub use draft_snapshot_backup::{
    discard_draft_snapshot_backup, execute_draft_snapshot_backup, plan_draft_snapshot_backup,
};
mod rss_snapshot_backup;
pub use rss_snapshot_backup::{
    discard_rss_snapshot_backup, execute_rss_snapshot_backup, plan_rss_snapshot_backup,
};
mod workspace_config_backup;
pub use workspace_config_backup::{
    discard_workspace_config_backup, execute_workspace_config_backup, plan_workspace_config_backup,
};
mod workspace_backup;
pub use workspace_backup::{
    discard_workspace_backup, inspect_workspace_backup, recheck_workspace_backup,
};
mod rollback_archive;
pub use publish::{
    discard_rollback_candidate, execute_remote_review_verification, generate_rollback_candidate,
    inspect_rollback_changes, list_remote_review_records, plan_remote_review_verification,
    plan_rollback_candidate, remove_remote_review_record,
};
pub use publish::{
    discard_rollback_transaction, execute_rollback_transaction, list_rollback_records,
    plan_rollback_transaction, verify_rollback_record,
};
pub use rollback_archive::{
    discard_rollback_archive, execute_rollback_archive, plan_rollback_archive,
};
mod editor_exit;
mod release_ledger;
pub use editor_exit::{complete_editor_exit, prepare_editor_exit, EditorExitRuntime};
pub use release_ledger::get_release_ledger;
mod ai;
mod document;
mod draft_history;
mod general_drafts;
mod git_index;
mod images;
mod knowledge;
mod metadata_batch;
mod operation_log;
mod publish;
mod rss;
mod semantic;
mod site_profiles;
mod update;
mod workspace;

use crate::core::{
    git_is_available, inspect_site_preview as inspect_site_preview_at, read_content_health_sources,
    read_git_diff, read_git_status, search_markdown_files as search_markdown_files_at,
    CapabilitySnapshot, CommandError, CommandResult, ContentHealthSourceSnapshot,
    DeleteMarkdownDocumentResult, DocumentSnapshot, DraftHistoryStore, DraftVersionReason,
    GeneralDraftStore, GitDiffSnapshot, GitStatusSnapshot, MarkdownFileEntry, MarkdownLinkMetadata,
    MarkdownSearchSnapshot, RepositorySessionSnapshot, RepositoryStore, SitePreviewPageSnapshot,
    SitePreviewPageTarget, SitePreviewPlan, SitePreviewPlanRequest, SitePreviewReadiness,
    SitePreviewSnapshot, SitePreviewStore, WorkspaceStateStore, WritingImageImportResult,
};
use std::sync::Arc;
use tauri::State;

pub use ai::{
    ai_credential_status, apply_ai_edits, cancel_ai_chat_stream, create_ai_conversation,
    delete_ai_chat_vault, delete_ai_conversation, delete_ai_credential, delete_ai_provider_profile,
    execute_ai_chat, execute_ai_connection, execute_ai_edit, execute_structured_text_translation,
    execute_text_translation, get_ai_chat_vault_status, initialize_ai_chat_vault,
    list_ai_conversations, list_ai_provider_profiles, lock_ai_chat_vault, plan_ai_chat,
    plan_ai_connection, plan_ai_edit, plan_structured_text_translation, plan_text_translation,
    poll_ai_chat_stream, save_ai_provider_profile, start_ai_chat_stream, store_ai_credential,
    unlock_ai_chat_vault,
};
pub use document::{
    document_capabilities, export_markdown_document, extract_pdf_ocr, extract_pdf_text, select_pdf,
};
pub use draft_history::{
    delete_recycled_draft, get_draft_version, get_recycled_draft, list_draft_versions,
    list_recycled_drafts, restore_draft_version, restore_recycled_draft,
};
pub use general_drafts::{
    execute_general_draft_transfer, get_general_draft, list_general_drafts,
    plan_general_draft_transfer, save_general_draft, undo_general_draft_transfer,
};
pub use git_index::{execute_git_index_update, plan_git_index_update};
pub use images::{inspect_repository_images, read_repository_image};
pub use knowledge::{
    browser_capture_status, create_knowledge_folder, delete_knowledge_item,
    execute_knowledge_archive_export, execute_knowledge_export, get_knowledge_item,
    get_knowledge_revision, import_knowledge_text, knowledge_library_status,
    list_knowledge_folders, list_knowledge_items, list_knowledge_revisions, move_knowledge_item,
    plan_knowledge_archive_export, plan_knowledge_export, rotate_browser_capture_token,
    search_knowledge_items, set_knowledge_remote_ai_permission, take_knowledge_open_request,
    update_knowledge_progress,
};
pub use operation_log::{clear_operation_log, get_operation_log};
pub use publish::{
    browser_protocol_status, check_deployment, check_rollback_qualification, credential_status,
    delete_repository_credential, execute_git_operation, execute_git_push_retry,
    execute_publish_verification, execute_remote_review, list_publish_records, plan_git_operation,
    plan_git_push_retry, plan_publish_verification, plan_remote_review,
    plan_rollback_qualification, remove_publish_record, store_repository_credential,
    update_readiness,
};
pub use rss::{
    rss_add_feed, rss_clear_offline_translations, rss_delete_highlight,
    rss_delete_offline_translation, rss_discover, rss_execute_opml, rss_export_backup,
    rss_export_opml, rss_fetch_cover, rss_fetch_full_text, rss_get_article,
    rss_get_offline_translation, rss_get_preferences, rss_get_reading_progress,
    rss_history_cancel_discovery, rss_history_clear, rss_history_discover, rss_history_list,
    rss_history_pause, rss_history_prepare_retry, rss_history_resume_discovery, rss_history_status,
    rss_history_step, rss_import_opml, rss_inspect_backup, rss_list_articles, rss_list_highlights,
    rss_mark_all_read, rss_offline_translation_cache_status, rss_prune,
    rss_prune_offline_translations, rss_refresh_all, rss_refresh_feed, rss_remove_feed,
    rss_restore_backup, rss_review_opml, rss_save_highlight, rss_save_offline_translation,
    rss_save_reading_progress, rss_snapshot, rss_undo_mark_all_read, rss_undo_remove_feed,
    rss_update_article_state, rss_update_feed_url, rss_update_preferences,
};
pub use semantic::{rebuild_semantic_index, semantic_index_status, semantic_search};
pub use site_profiles::{
    get_site_profiles, open_site_profile, register_site_profile, remove_site_profile,
    rename_site_profile,
};
pub use update::{check_app_update, install_app_update};
pub use workspace::{
    clear_recovery_draft, get_workspace_state, save_recovery_draft, update_workspace_preferences,
};

pub use metadata_batch::{execute_metadata_batch, plan_metadata_batch};

pub struct AppState {
    knowledge_restore_history_export: Arc<crate::core::KnowledgeRestoreHistoryExportStore>,
    knowledge_restore_cleanup: Arc<crate::core::KnowledgeRestoreCleanupStore>,
    knowledge_restore_archive: Arc<crate::core::KnowledgeRestoreArchiveStore>,
    knowledge_restore_install: Arc<crate::core::KnowledgeRestoreInstallStore>,
    knowledge_merge_projection: Arc<crate::core::KnowledgeMergeProjectionStore>,
    knowledge_restore_qualification: Arc<crate::core::KnowledgeRestoreQualificationStore>,
    knowledge_candidate_check: Arc<crate::core::KnowledgeCandidateCheckStore>,
    knowledge_package_stage: Arc<crate::core::KnowledgePackageStageStore>,
    knowledge_package_check: Arc<crate::core::KnowledgePackageCheckStore>,
    knowledge_backup: Arc<crate::core::KnowledgeBackupStore>,
    knowledge_integrity: Arc<crate::core::KnowledgeIntegrityStore>,
    draft_snapshot_backup: Arc<crate::core::DraftSnapshotBackupStore>,
    rss_snapshot_backup: Arc<crate::core::RssSnapshotBackupStore>,
    config_backup: Arc<crate::core::WorkspaceConfigBackupStore>,
    backup_preflight: Arc<crate::core::WorkspaceBackupStore>,
    rollback_archive: Arc<crate::core::RollbackArchiveStore>,
    rollback_transaction: Arc<crate::core::RollbackTransactionStore>,
    rollback_candidate: Arc<crate::core::RollbackCandidateStore>,
    rollback_qualification: Arc<crate::core::RollbackQualificationStore>,
    publish_ledger: Arc<crate::core::PublishLedgerStore>,
    remote_review_ledger: Arc<crate::core::RemoteReviewLedgerStore>,
    metadata_batch: Arc<crate::core::MetadataBatchStore>,
    repositories: Arc<RepositoryStore>,
    site_previews: Arc<SitePreviewStore>,
    publish: Arc<publish::PublishState>,
    git_index: Arc<crate::core::GitIndexStore>,
    semantic: Arc<crate::core::SemanticIndexStore>,
    documents: Arc<crate::core::PdfAnalysisStore>,
    ai: Arc<ai::AiState>,
    workspace: Arc<WorkspaceStateStore>,
    draft_history: Arc<DraftHistoryStore>,
    general_drafts: Arc<GeneralDraftStore>,
    updater: Arc<crate::core::UpdateStore>,
    knowledge: Arc<crate::core::KnowledgeLibraryStore>,
    browser_capture: Option<Arc<crate::core::BrowserCaptureService>>,
    browser_capture_warning: Option<String>,
    rss: Arc<crate::core::RssReaderStore>,
    operation_log: Arc<crate::core::OperationLogStore>,
    site_profiles: Arc<crate::core::SiteProfileStore>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            knowledge_restore_history_export: Arc::new(
                crate::core::KnowledgeRestoreHistoryExportStore::default(),
            ),
            knowledge_restore_cleanup: Arc::new(
                crate::core::KnowledgeRestoreCleanupStore::default(),
            ),
            knowledge_restore_archive: Arc::new(
                crate::core::KnowledgeRestoreArchiveStore::default(),
            ),
            knowledge_restore_install: Arc::new(
                crate::core::KnowledgeRestoreInstallStore::default(),
            ),
            knowledge_merge_projection: Arc::new(
                crate::core::KnowledgeMergeProjectionStore::default(),
            ),
            knowledge_restore_qualification: Arc::new(
                crate::core::KnowledgeRestoreQualificationStore::default(),
            ),
            knowledge_candidate_check: Arc::new(
                crate::core::KnowledgeCandidateCheckStore::default(),
            ),
            knowledge_package_stage: Arc::new(crate::core::KnowledgePackageStageStore::default()),
            knowledge_package_check: Arc::new(crate::core::KnowledgePackageCheckStore::default()),
            knowledge_backup: Arc::new(crate::core::KnowledgeBackupStore::default()),
            knowledge_integrity: Arc::new(crate::core::KnowledgeIntegrityStore::default()),
            draft_snapshot_backup: Arc::new(crate::core::DraftSnapshotBackupStore::default()),
            rss_snapshot_backup: Arc::new(crate::core::RssSnapshotBackupStore::default()),
            config_backup: Arc::new(crate::core::WorkspaceConfigBackupStore::default()),
            backup_preflight: Arc::new(crate::core::WorkspaceBackupStore::default()),
            rollback_archive: Arc::new(crate::core::RollbackArchiveStore::default()),
            rollback_transaction: Arc::new(crate::core::RollbackTransactionStore::default()),
            rollback_qualification: Arc::new(crate::core::RollbackQualificationStore::default()),
            rollback_candidate: Arc::new(crate::core::RollbackCandidateStore::default()),
            publish_ledger: Arc::new(crate::core::PublishLedgerStore::default()),
            remote_review_ledger: Arc::new(crate::core::RemoteReviewLedgerStore::default()),
            metadata_batch: Arc::new(crate::core::MetadataBatchStore::default()),
            repositories: Arc::new(RepositoryStore::default()),
            site_previews: Arc::new(SitePreviewStore::default()),
            publish: Arc::new(publish::PublishState::default()),
            git_index: Arc::new(crate::core::GitIndexStore::default()),
            semantic: Arc::new(crate::core::SemanticIndexStore::default()),
            documents: Arc::new(crate::core::PdfAnalysisStore::default()),
            ai: Arc::new(ai::AiState::default()),
            workspace: Arc::new(WorkspaceStateStore::default()),
            draft_history: Arc::new(DraftHistoryStore::default()),
            general_drafts: Arc::new(GeneralDraftStore::default()),
            updater: Arc::new(crate::core::UpdateStore::default()),
            knowledge: Arc::new(crate::core::KnowledgeLibraryStore::default()),
            browser_capture: None,
            browser_capture_warning: Some(
                "Browser capture is not initialized in this application state.".to_string(),
            ),
            rss: Arc::new(crate::core::RssReaderStore::default()),
            operation_log: Arc::new(crate::core::OperationLogStore::default()),
            site_profiles: Arc::new(crate::core::SiteProfileStore::default()),
        }
    }
}

impl AppState {
    pub fn new(app_data_dir: std::path::PathBuf) -> CommandResult<Self> {
        let rollback_transaction = Arc::new(crate::core::RollbackTransactionStore::new(
            app_data_dir.clone(),
        ));
        let publish_ledger = Arc::new(crate::core::PublishLedgerStore::new(app_data_dir.clone()));
        let remote_review_ledger = Arc::new(crate::core::RemoteReviewLedgerStore::new(
            app_data_dir.clone(),
        ));
        let site_profiles = Arc::new(crate::core::SiteProfileStore::new(app_data_dir.clone()));
        let operation_log = Arc::new(crate::core::OperationLogStore::new(app_data_dir.clone()));
        let ai = Arc::new(ai::AiState::new(app_data_dir.clone()));
        let workspace = Arc::new(WorkspaceStateStore::new(app_data_dir.clone())?);
        let draft_history = Arc::new(DraftHistoryStore::new(app_data_dir.clone())?);
        let general_drafts = Arc::new(GeneralDraftStore::new(app_data_dir.clone())?);
        let rss = Arc::new(crate::core::RssReaderStore::new(app_data_dir.clone())?);
        let knowledge = Arc::new(crate::core::KnowledgeLibraryStore::new(
            app_data_dir.clone(),
        )?);
        let config_backup = Arc::new(crate::core::WorkspaceConfigBackupStore::new(
            app_data_dir.clone(),
        ));
        let rss_snapshot_backup = Arc::new(crate::core::RssSnapshotBackupStore::new(
            app_data_dir.clone(),
        ));
        let knowledge_restore_history_export = Arc::new(
            crate::core::KnowledgeRestoreHistoryExportStore::new(app_data_dir.clone()),
        );
        let knowledge_restore_cleanup = Arc::new(crate::core::KnowledgeRestoreCleanupStore::new(
            app_data_dir.clone(),
        ));
        let knowledge_restore_archive = Arc::new(crate::core::KnowledgeRestoreArchiveStore::new(
            app_data_dir.clone(),
        ));
        let knowledge_restore_install = Arc::new(crate::core::KnowledgeRestoreInstallStore::new(
            app_data_dir.clone(),
        ));
        let knowledge_merge_projection = Arc::new(crate::core::KnowledgeMergeProjectionStore::new(
            app_data_dir.clone(),
        ));
        let knowledge_restore_qualification = Arc::new(
            crate::core::KnowledgeRestoreQualificationStore::new(app_data_dir.clone()),
        );
        let knowledge_candidate_check = Arc::new(crate::core::KnowledgeCandidateCheckStore::new(
            app_data_dir.clone(),
        ));
        let knowledge_package_stage = Arc::new(crate::core::KnowledgePackageStageStore::new(
            app_data_dir.clone(),
        ));
        let knowledge_backup =
            Arc::new(crate::core::KnowledgeBackupStore::new(app_data_dir.clone()));
        let knowledge_integrity = Arc::new(crate::core::KnowledgeIntegrityStore::new(
            app_data_dir.clone(),
        ));
        let draft_snapshot_backup = Arc::new(crate::core::DraftSnapshotBackupStore::new(
            app_data_dir.clone(),
        ));
        let backup_preflight = Arc::new(crate::core::WorkspaceBackupStore::new(app_data_dir));
        let (browser_capture, browser_capture_warning) =
            match knowledge::start_browser_capture(Arc::clone(&knowledge)) {
                Ok(service) => (Some(Arc::new(service)), None),
                Err(error) => (
                    None,
                    Some(format!(
                        "Browser capture could not start ({}). Restart the app after the local port becomes available.",
                        error.code
                    )),
                ),
            };
        Ok(Self {
            knowledge_restore_history_export,
            knowledge_restore_cleanup,
            knowledge_restore_archive,
            knowledge_restore_install,
            knowledge_merge_projection,
            knowledge_restore_qualification,
            knowledge_candidate_check,
            knowledge_package_stage,
            knowledge_package_check: Arc::new(crate::core::KnowledgePackageCheckStore::default()),
            knowledge_backup,
            knowledge_integrity,
            draft_snapshot_backup,
            rss_snapshot_backup,
            config_backup,
            backup_preflight,
            rollback_transaction,
            publish_ledger,
            remote_review_ledger,
            operation_log,
            site_profiles,
            workspace,
            draft_history,
            general_drafts,
            ai,
            knowledge,
            browser_capture,
            browser_capture_warning,
            rss,
            ..Self::default()
        })
    }
}

#[tauri::command]
pub async fn get_capabilities() -> CapabilitySnapshot {
    let git_available = tauri::async_runtime::spawn_blocking(git_is_available)
        .await
        .unwrap_or(false);
    CapabilitySnapshot::from_git_availability(git_available)
}

#[tauri::command]
pub async fn open_repository(
    path: String,
    state: State<'_, AppState>,
) -> CommandResult<RepositorySessionSnapshot> {
    open_repository_at_path(path, &state).await
}

async fn open_repository_at_path(
    path: String,
    state: &AppState,
) -> CommandResult<RepositorySessionSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    let semantic = Arc::clone(&state.semantic);
    let workspace = Arc::clone(&state.workspace);
    tauri::async_runtime::spawn_blocking(move || {
        let mut snapshot = repositories.open_repository(&path)?;
        if semantic.activate_session(&snapshot.session_id).is_err() {
            snapshot
                .warnings
                .push("无法切换会话内语义索引；请重新启动应用。".to_string());
        }
        if workspace
            .record_repository_opened(
                std::path::Path::new(&snapshot.root_path),
                &snapshot.display_name,
            )
            .is_err()
        {
            snapshot
                .warnings
                .push("workspace_state_record_failed".to_string());
        }
        Ok(snapshot)
    })
    .await
    .map_err(|_| blocking_task_failed("repository_open_task_failed", "open the repository"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn list_markdown_files(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Vec<MarkdownFileEntry>> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || repositories.list_markdown_files(&session_id))
        .await
        .map_err(|_| blocking_task_failed("repository_scan_task_failed", "scan the repository"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_content_health_sources(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<ContentHealthSourceSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let (root, scan_root) = repositories.search_roots_for_session(&session_id)?;
        read_content_health_sources(&root, &scan_root)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "content_health_task_failed",
            "inspect repository content health sources",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn search_markdown_files(
    session_id: String,
    query: String,
    limit: Option<usize>,
    state: State<'_, AppState>,
) -> CommandResult<MarkdownSearchSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let (root, scan_root) = repositories.search_roots_for_session(&session_id)?;
        search_markdown_files_at(&root, &scan_root, &query, limit.unwrap_or(100))
    })
    .await
    .map_err(|_| blocking_task_failed("search_task_failed", "search Markdown files"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn open_document(
    session_id: String,
    relative_path: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    let workspace = Arc::clone(&state.workspace);
    tauri::async_runtime::spawn_blocking(move || {
        let document = repositories.open_document(&session_id, &relative_path)?;
        let root = repositories.root_for_session(&session_id)?;
        // Opening a document must remain available if optional workspace history cannot be
        // persisted. Crash recovery will report its own error if the user later edits it.
        let _ = workspace.record_document_opened(&root, &document.relative_path);
        Ok(document)
    })
    .await
    .map_err(|_| blocking_task_failed("document_open_task_failed", "open the document"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_markdown_link_metadata(
    session_id: String,
    relative_path: String,
    state: State<'_, AppState>,
) -> CommandResult<MarkdownLinkMetadata> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        repositories.inspect_markdown_link_metadata(&session_id, &relative_path)
    })
    .await
    .map_err(|_| {
        blocking_task_failed("document_metadata_task_failed", "inspect document metadata")
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn save_document(
    session_id: String,
    document_id: String,
    text: String,
    expected_sha256: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let scope = operation_log::repository_scope(&state, Some(&session_id));
    operation_log::run_logged(
        log,
        crate::core::OperationKind::SaveDocument,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let workspace = Arc::clone(&state.workspace);
            let draft_history = Arc::clone(&state.draft_history);
            tauri::async_runtime::spawn_blocking(move || {
                let _operation = repositories.lock_recovery_operation()?;
                let context = repositories.history_context_for_session(
                    &session_id,
                    &document_id,
                    &expected_sha256,
                )?;
                // History persistence is deliberately before the document replacement: if private
                // storage is unavailable, the original remains the authoritative on-disk version.
                draft_history.record_version(
                    &context.root,
                    &context.relative_path,
                    &context.text,
                    &context.baseline_sha256,
                    DraftVersionReason::BeforeSave,
                )?;
                let document = repositories.save_document(
                    &session_id,
                    &document_id,
                    &text,
                    &expected_sha256,
                )?;
                // Saving the document is already durable. State cleanup is deliberately best-effort so a
                // local workspace-state failure never turns a successful document write into an error.
                let _ = workspace.clear_matching_recovery(
                    &context.root,
                    &context.relative_path,
                    &context.baseline_sha256,
                );
                Ok(document)
            })
            .await
            .map_err(|_| blocking_task_failed("document_save_task_failed", "save the document"))?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn create_markdown_document(
    session_id: String,
    relative_path: String,
    initial_text: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let scope = operation_log::repository_scope(&state, Some(&session_id));
    operation_log::run_logged(
        log,
        crate::core::OperationKind::CreateDocument,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let workspace = Arc::clone(&state.workspace);
            tauri::async_runtime::spawn_blocking(move || {
                let document = repositories.create_markdown_document(
                    &session_id,
                    &relative_path,
                    &initial_text,
                )?;
                let root = repositories.root_for_session(&session_id)?;
                let _ = workspace.record_document_opened(&root, &document.relative_path);
                Ok(document)
            })
            .await
            .map_err(|_| {
                blocking_task_failed("document_create_task_failed", "create the document")
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn rename_markdown_document(
    session_id: String,
    document_id: String,
    new_relative_path: String,
    expected_sha256: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let scope = operation_log::repository_scope(&state, Some(&session_id));
    operation_log::run_logged(
        log,
        crate::core::OperationKind::RenameDocument,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let workspace = Arc::clone(&state.workspace);
            let draft_history = Arc::clone(&state.draft_history);
            tauri::async_runtime::spawn_blocking(move || {
                let _operation = repositories.lock_recovery_operation()?;
                let (root, old_relative_path, baseline_sha256, _) =
                    repositories.recovery_context_for_session(&session_id, &document_id)?;
                let document = repositories.rename_markdown_document(
                    &session_id,
                    &document_id,
                    &new_relative_path,
                    &expected_sha256,
                )?;
                // The file move has already succeeded. A temporary failure in private history must not
                // report the successful user-visible rename as failed; the old path remains recoverable.
                let _ =
                    draft_history.rename_draft(&root, &old_relative_path, &document.relative_path);
                let _ =
                    workspace.clear_matching_recovery(&root, &old_relative_path, &baseline_sha256);
                let _ = workspace.record_document_opened(&root, &document.relative_path);
                Ok(document)
            })
            .await
            .map_err(|_| {
                blocking_task_failed("document_rename_task_failed", "rename the document")
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn delete_markdown_document(
    session_id: String,
    document_id: String,
    expected_sha256: String,
    state: State<'_, AppState>,
) -> CommandResult<DeleteMarkdownDocumentResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = operation_log::repository_scope(&state, Some(&session_id));
    operation_log::run_logged(
        log,
        crate::core::OperationKind::DeleteDocument,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let workspace = Arc::clone(&state.workspace);
            let draft_history = Arc::clone(&state.draft_history);
            tauri::async_runtime::spawn_blocking(move || {
                let _operation = repositories.lock_recovery_operation()?;
                let context = repositories.history_context_for_session(
                    &session_id,
                    &document_id,
                    &expected_sha256,
                )?;
                // The recycle copy is committed first. If unlink fails, remove that just-created copy;
                // a crash in this narrow interval intentionally leaves a duplicate rather than losing it.
                let receipt = draft_history.record_deleted(
                    &context.root,
                    &context.relative_path,
                    &context.text,
                    &context.baseline_sha256,
                )?;
                let mut result = match repositories.delete_markdown_document(
                    &session_id,
                    &document_id,
                    &expected_sha256,
                ) {
                    Ok(result) => result,
                    Err(error) => {
                        let _ = draft_history.rollback_deleted(&context.root, &receipt);
                        return Err(error);
                    }
                };
                let _ = draft_history.finalize_deleted(&context.root, &receipt);
                result.recycle_id = receipt.recycle_id;
                let _ = workspace.clear_matching_recovery(
                    &context.root,
                    &context.relative_path,
                    &context.baseline_sha256,
                );
                Ok(result)
            })
            .await
            .map_err(|_| {
                blocking_task_failed("document_delete_task_failed", "delete the document")
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn import_writing_image(
    session_id: String,
    source_path: String,
    document_id: String,
    state: State<'_, AppState>,
) -> CommandResult<WritingImageImportResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = operation_log::repository_scope(&state, Some(&session_id));
    operation_log::run_logged(
        log,
        crate::core::OperationKind::ImportWritingImage,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            tauri::async_runtime::spawn_blocking(move || {
                repositories.import_writing_image(&session_id, &source_path, &document_id)
            })
            .await
            .map_err(|_| blocking_task_failed("image_import_task_failed", "import the image"))?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn git_status(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GitStatusSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        read_git_status(&root)
    })
    .await
    .map_err(|_| blocking_task_failed("git_status_task_failed", "read Git status"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn git_file_diff(
    session_id: String,
    relative_path: String,
    state: State<'_, AppState>,
) -> CommandResult<GitDiffSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        read_git_diff(&root, &relative_path)
    })
    .await
    .map_err(|_| blocking_task_failed("git_diff_task_failed", "read Git diff"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_site_preview(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<SitePreviewReadiness> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let (root, site_kind) = repositories.site_context_for_session(&session_id)?;
        inspect_site_preview_at(&root, &site_kind)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "preview_inspection_task_failed",
            "inspect the site preview runtime",
        )
    })?
}

fn validate_preview_document(
    repositories: &RepositoryStore,
    session_id: &str,
    request: &SitePreviewPlanRequest,
) -> CommandResult<Option<String>> {
    let Some(binding) = &request.document else {
        return Ok(None);
    };
    let (root, path, sha, _) =
        repositories.recovery_context_for_session(session_id, &binding.document_id)?;
    let (live_root, revision, _) =
        repositories.document_context_for_session(session_id, &binding.document_id)?;
    if root != live_root || sha != binding.expected_sha256 || revision != binding.revision {
        return Err(CommandError::new(
            "preview_context_changed",
            "Preview document changed. Prepare a new plan.",
        ));
    }
    Ok(Some(path))
}

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_site_preview(
    session_id: String,
    request: SitePreviewPlanRequest,
    state: State<'_, AppState>,
) -> CommandResult<SitePreviewPlan> {
    let repositories = Arc::clone(&state.repositories);
    let previews = Arc::clone(&state.site_previews);
    tauri::async_runtime::spawn_blocking(move || {
        let (root, site_kind) = repositories.site_context_for_session(&session_id)?;
        let path = validate_preview_document(&repositories, &session_id, &request)?;
        previews.plan_preview(&session_id, &root, &site_kind, request, path.as_deref())
    })
    .await
    .map_err(|_| blocking_task_failed("preview_plan_task_failed", "prepare site preview"))?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn start_site_preview(
    session_id: String,
    plan_id: String,
    confirmed_trusted_repository: bool,
    state: State<'_, AppState>,
) -> CommandResult<SitePreviewSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    let previews = Arc::clone(&state.site_previews);
    tauri::async_runtime::spawn_blocking(move || {
        previews.start_preview(
            &session_id,
            &plan_id,
            confirmed_trusted_repository,
            || repositories.site_context_for_session(&session_id),
            |request| validate_preview_document(&repositories, &session_id, request).map(|_| ()),
        )
    })
    .await
    .map_err(|_| blocking_task_failed("preview_start_task_failed", "start site preview"))?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn check_site_preview_page(
    session_id: String,
    preview_id: String,
    target: SitePreviewPageTarget,
    state: State<'_, AppState>,
) -> CommandResult<SitePreviewPageSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    let previews = Arc::clone(&state.site_previews);
    tauri::async_runtime::spawn_blocking(move || {
        previews.check_page(&session_id, &preview_id, target, |request| {
            repositories.root_for_session(&session_id)?;
            validate_preview_document(&repositories, &session_id, request).map(|_| ())
        })
    })
    .await
    .map_err(|_| blocking_task_failed("preview_page_task_failed", "verify site preview page"))?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn stop_site_preview(
    session_id: String,
    preview_id: String,
    state: State<'_, AppState>,
) -> CommandResult<SitePreviewSnapshot> {
    let previews = Arc::clone(&state.site_previews);
    tauri::async_runtime::spawn_blocking(move || {
        previews.stop_preview(&session_id, Some(&preview_id))
    })
    .await
    .map_err(|_| blocking_task_failed("preview_stop_task_failed", "stop site preview"))?
}

pub(super) fn blocking_task_failed(code: &str, operation: &str) -> CommandError {
    CommandError::new(code, format!("Unable to {operation}."))
}

#[cfg(test)]
mod preview_binding_tests {
    use super::*;
    use crate::core::SitePreviewDocumentBinding;
    #[test]
    fn preview_binding_rejects_saved_revision_and_sha_drift() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::create_dir(temp.path().join("content")).unwrap();
        std::fs::write(temp.path().join("hugo.toml"), b"title='test'").unwrap();
        std::fs::write(temp.path().join("content/a.md"), b"# Test").unwrap();
        let repositories = RepositoryStore::default();
        let session = repositories
            .open_repository(temp.path().to_str().unwrap())
            .unwrap();
        let document = repositories
            .open_document(&session.session_id, "content/a.md")
            .unwrap();
        let request = SitePreviewPlanRequest {
            document: Some(SitePreviewDocumentBinding {
                document_id: document.document_id.clone(),
                expected_sha256: document.baseline_sha256.clone(),
                revision: document.revision,
            }),
            article_path: Some("/a/".into()),
        };
        assert_eq!(
            validate_preview_document(&repositories, &session.session_id, &request).unwrap(),
            Some("content/a.md".into())
        );
        repositories
            .save_document(
                &session.session_id,
                &document.document_id,
                "# Saved",
                &document.baseline_sha256,
            )
            .unwrap();
        assert!(validate_preview_document(&repositories, &session.session_id, &request).is_err());
    }
    #[test]
    fn preview_binding_rejects_cross_session_document_and_forged_revision() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::create_dir(temp.path().join("content")).unwrap();
        std::fs::write(temp.path().join("content/a.md"), b"# Test").unwrap();
        let repositories = RepositoryStore::default();
        let session = repositories
            .open_repository(temp.path().to_str().unwrap())
            .unwrap();
        let other = repositories
            .open_repository(temp.path().to_str().unwrap())
            .unwrap();
        let document = repositories
            .open_document(&session.session_id, "content/a.md")
            .unwrap();
        let mut request = SitePreviewPlanRequest {
            document: Some(SitePreviewDocumentBinding {
                document_id: document.document_id.clone(),
                expected_sha256: document.baseline_sha256.clone(),
                revision: document.revision,
            }),
            article_path: Some("/a/".into()),
        };
        assert!(validate_preview_document(&repositories, &other.session_id, &request).is_err());
        request.document.as_mut().unwrap().revision += 1;
        assert!(validate_preview_document(&repositories, &session.session_id, &request).is_err());
    }
}
