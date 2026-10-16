use super::AppState;
use crate::core::{CommandError, CommandResult, KnowledgeBackupPlan, KnowledgeBackupResult};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_backup_task_failed", "Saved-file package task could not be confirmed. Inspect the selected filename before preparing another plan; source knowledge was not restored or cleaned up.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_backup(
    destination_path: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeBackupPlan> {
    let store = state.knowledge_backup.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(Path::new(&destination_path)))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_knowledge_backup(
    plan_id: String,
    confirm_sensitive_plaintext: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeBackupResult> {
    let store = state.knowledge_backup.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.execute(&plan_id, confirm_sensitive_plaintext)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_backup(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_backup.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
