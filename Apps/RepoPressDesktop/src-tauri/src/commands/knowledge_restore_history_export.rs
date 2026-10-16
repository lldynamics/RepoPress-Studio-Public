use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeRestoreHistoryExportPlan,
    KnowledgeRestoreHistoryExportReceipt, KnowledgeRestoreHistoryExportStatus,
};
use std::path::PathBuf;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_restore_history_export_task_failed", "History export outcome is unknown. Inspect the reviewed destination before preparing a new plan.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_knowledge_restore_history_export(
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreHistoryExportStatus> {
    let store = state.knowledge_restore_history_export.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect())
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_restore_history_export(
    transaction_id: String,
    destination_path: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreHistoryExportPlan> {
    let store = state.knowledge_restore_history_export.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.plan(&transaction_id, &PathBuf::from(destination_path))
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_knowledge_restore_history_export(
    plan_id: String,
    confirm_sensitive_plaintext: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreHistoryExportReceipt> {
    let store = state.knowledge_restore_history_export.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.execute(&plan_id, confirm_sensitive_plaintext)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_restore_history_export(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_restore_history_export.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
