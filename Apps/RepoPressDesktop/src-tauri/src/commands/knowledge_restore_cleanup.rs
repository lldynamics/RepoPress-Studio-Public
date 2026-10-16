use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeRestoreCleanupAction, KnowledgeRestoreCleanupPlan,
    KnowledgeRestoreCleanupReceipt, KnowledgeRestoreCleanupStatus,
};
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new(
        "knowledge_restore_cleanup_task_failed",
        "Cleanup outcome is unknown. Inspect persistent cleanup state before retrying.",
    )
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_knowledge_restore_cleanup(
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreCleanupStatus> {
    let store = state.knowledge_restore_cleanup.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect())
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_restore_cleanup(
    transaction_id: String,
    action: KnowledgeRestoreCleanupAction,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreCleanupPlan> {
    let store = state.knowledge_restore_cleanup.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(&transaction_id, action))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_knowledge_restore_cleanup(
    plan_id: String,
    acknowledge_deletion: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreCleanupReceipt> {
    let store = state.knowledge_restore_cleanup.clone();
    tauri::async_runtime::spawn_blocking(move || store.execute(&plan_id, acknowledge_deletion))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_restore_cleanup(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_restore_cleanup.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
