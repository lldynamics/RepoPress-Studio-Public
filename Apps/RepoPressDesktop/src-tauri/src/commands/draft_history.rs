use super::{blocking_task_failed, AppState};
use crate::core::{
    CommandResult, DocumentSnapshot, DraftVersion, DraftVersionReason, DraftVersionSnapshot,
    RecycledDraft, RecycledDraftSnapshot,
};
use std::sync::Arc;
use tauri::State;

#[tauri::command(rename_all = "camelCase")]
pub async fn list_draft_versions(
    session_id: String,
    document_id: String,
    state: State<'_, AppState>,
) -> CommandResult<DraftVersionSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    let history = Arc::clone(&state.draft_history);
    tauri::async_runtime::spawn_blocking(move || {
        let (root, relative_path, _, _) =
            repositories.recovery_context_for_session(&session_id, &document_id)?;
        history.list_versions(&root, &document_id, &relative_path)
    })
    .await
    .map_err(|_| blocking_task_failed("draft_history_list_task_failed", "list draft versions"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn get_draft_version(
    session_id: String,
    document_id: String,
    version_id: String,
    state: State<'_, AppState>,
) -> CommandResult<DraftVersion> {
    let repositories = Arc::clone(&state.repositories);
    let history = Arc::clone(&state.draft_history);
    tauri::async_runtime::spawn_blocking(move || {
        let (root, relative_path, _, _) =
            repositories.recovery_context_for_session(&session_id, &document_id)?;
        history.get_version(&root, &relative_path, &version_id)
    })
    .await
    .map_err(|_| blocking_task_failed("draft_history_get_task_failed", "get a draft version"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn restore_draft_version(
    session_id: String,
    document_id: String,
    version_id: String,
    expected_sha256: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::RestoreDraftVersion,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let history = Arc::clone(&state.draft_history);
            tauri::async_runtime::spawn_blocking(move || {
                let _operation = repositories.lock_recovery_operation()?;
                let context = repositories.history_context_for_session(
                    &session_id,
                    &document_id,
                    &expected_sha256,
                )?;
                let version =
                    history.get_version(&context.root, &context.relative_path, &version_id)?;
                history.record_version(
                    &context.root,
                    &context.relative_path,
                    &context.text,
                    &context.baseline_sha256,
                    DraftVersionReason::BeforeRestore,
                )?;
                repositories.save_document(
                    &session_id,
                    &document_id,
                    &version.text,
                    &expected_sha256,
                )
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "draft_history_restore_task_failed",
                    "restore a draft version",
                )
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn list_recycled_drafts(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RecycledDraftSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    let history = Arc::clone(&state.draft_history);
    tauri::async_runtime::spawn_blocking(move || {
        history.list_recycled(&repositories.root_for_session(&session_id)?)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "draft_history_recycle_list_task_failed",
            "list recycled drafts",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn get_recycled_draft(
    session_id: String,
    recycle_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RecycledDraft> {
    let repositories = Arc::clone(&state.repositories);
    let history = Arc::clone(&state.draft_history);
    tauri::async_runtime::spawn_blocking(move || {
        history.get_recycled(&repositories.root_for_session(&session_id)?, &recycle_id)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "draft_history_recycle_get_task_failed",
            "get a recycled draft",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn restore_recycled_draft(
    session_id: String,
    recycle_id: String,
    relative_path: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::RestoreRecycledDraft,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let history = Arc::clone(&state.draft_history);
            tauri::async_runtime::spawn_blocking(move || {
                let root = repositories.root_for_session(&session_id)?;
                let recycled = history.get_recycled(&root, &recycle_id)?;
                let document = repositories.create_markdown_document(
                    &session_id,
                    &relative_path,
                    &recycled.text,
                )?;
                // File creation has no-clobber semantics and succeeded. Keep it successful even if a
                // private metadata update is temporarily unavailable; the recycle copy remains retryable.
                let _ = history.restore_recycled(&root, &recycle_id, &document.relative_path);
                Ok(document)
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "draft_history_recycle_restore_task_failed",
                    "restore a recycled draft",
                )
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn delete_recycled_draft(
    session_id: String,
    recycle_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RecycledDraftSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::DeleteRecycledDraft,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let history = Arc::clone(&state.draft_history);
            tauri::async_runtime::spawn_blocking(move || {
                history.delete_recycled(&repositories.root_for_session(&session_id)?, &recycle_id)
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "draft_history_recycle_delete_task_failed",
                    "permanently delete a recycled draft",
                )
            })?
        },
    )
    .await
}
