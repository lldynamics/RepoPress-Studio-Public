//! Tauri boundary for app-private general drafts. Paths and source text remain in the core
//! repository binding; this boundary accepts only session/document identifiers and checksums.
use super::{blocking_task_failed, AppState};
use crate::core::{
    CommandResult, GeneralDraft, GeneralDraftSnapshot, GeneralDraftTransferPlan,
    GeneralDraftTransferResult, GeneralDraftTransferTarget, GeneralDraftTransferUndoResult,
    TransferOperation,
};
use std::sync::Arc;
use tauri::State;

#[tauri::command(rename_all = "camelCase")]
pub async fn list_general_drafts(
    state: State<'_, AppState>,
) -> CommandResult<GeneralDraftSnapshot> {
    let general_drafts = Arc::clone(&state.general_drafts);
    tauri::async_runtime::spawn_blocking(move || general_drafts.list())
        .await
        .map_err(|_| {
            blocking_task_failed("general_draft_list_task_failed", "list general drafts")
        })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn get_general_draft(
    draft_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GeneralDraft> {
    let general_drafts = Arc::clone(&state.general_drafts);
    tauri::async_runtime::spawn_blocking(move || general_drafts.get(&draft_id))
        .await
        .map_err(|_| blocking_task_failed("general_draft_get_task_failed", "get a general draft"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn save_general_draft(
    draft_id: Option<String>,
    text: String,
    expected_revision: Option<u64>,
    expected_sha256: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<GeneralDraft> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, None);
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::SaveGeneralDraft,
        scope,
        async {
            let general_drafts = Arc::clone(&state.general_drafts);
            tauri::async_runtime::spawn_blocking(move || {
                general_drafts.save(
                    draft_id.as_deref(),
                    &text,
                    expected_revision,
                    expected_sha256.as_deref(),
                )
            })
            .await
            .map_err(|_| {
                blocking_task_failed("general_draft_save_task_failed", "save a general draft")
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_general_draft_transfer(
    session_id: String,
    operation: TransferOperation,
    document_id: Option<String>,
    expected_sha256: Option<String>,
    target_items: Option<Vec<GeneralDraftTransferTarget>>,
    state: State<'_, AppState>,
) -> CommandResult<GeneralDraftTransferPlan> {
    let general_drafts = Arc::clone(&state.general_drafts);
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        general_drafts.plan(
            &repositories,
            &session_id,
            operation,
            document_id.as_deref(),
            expected_sha256.as_deref(),
            target_items.as_deref(),
        )
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "general_draft_transfer_plan_task_failed",
            "plan a general draft transfer",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn execute_general_draft_transfer(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GeneralDraftTransferResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::TransferGeneralDraft,
        scope,
        async {
            let general_drafts = Arc::clone(&state.general_drafts);
            let repositories = Arc::clone(&state.repositories);
            let draft_history = Arc::clone(&state.draft_history);
            tauri::async_runtime::spawn_blocking(move || {
                general_drafts.execute(&repositories, &draft_history, &session_id, &plan_id)
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "general_draft_transfer_execute_task_failed",
                    "execute a general draft transfer",
                )
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn undo_general_draft_transfer(
    session_id: String,
    undo_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GeneralDraftTransferUndoResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::UndoGeneralDraftTransfer,
        scope,
        async {
            let general_drafts = Arc::clone(&state.general_drafts);
            let repositories = Arc::clone(&state.repositories);
            tauri::async_runtime::spawn_blocking(move || {
                general_drafts.undo(&repositories, &session_id, &undo_id)
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "general_draft_transfer_undo_task_failed",
                    "undo a general draft transfer",
                )
            })?
        },
    )
    .await
}
