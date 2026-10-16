use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeRestoreArchiveAction, KnowledgeRestoreArchivePlan,
    KnowledgeRestoreArchiveReceipt, KnowledgeRestoreArchiveStatus,
};
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new(
        "knowledge_restore_archive_task_failed",
        "Archive outcome is unknown. Inspect persistent archive state before retrying.",
    )
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_knowledge_restore_archive(
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreArchiveStatus> {
    let store = state.knowledge_restore_archive.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect())
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_restore_archive(
    transaction_id: String,
    action: KnowledgeRestoreArchiveAction,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreArchivePlan> {
    let store = state.knowledge_restore_archive.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(&transaction_id, action))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_knowledge_restore_archive(
    plan_id: String,
    acknowledge_archive: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreArchiveReceipt> {
    let store = state.knowledge_restore_archive.clone();
    tauri::async_runtime::spawn_blocking(move || store.execute(&plan_id, acknowledge_archive))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_restore_archive(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_restore_archive.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
