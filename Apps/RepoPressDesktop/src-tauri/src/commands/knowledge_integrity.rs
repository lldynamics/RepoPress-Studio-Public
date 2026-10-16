use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeIntegrityRecheck, KnowledgeIntegrityReport,
};
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_integrity_task_failed","The read-only knowledge inspection could not be completed. Explicitly inspect again; no data was exported or cleaned up.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_knowledge_integrity(
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeIntegrityReport> {
    let store = state.knowledge_integrity.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect())
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn recheck_knowledge_integrity(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeIntegrityRecheck> {
    let store = state.knowledge_integrity.clone();
    tauri::async_runtime::spawn_blocking(move || store.recheck(&report_id))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_integrity(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_integrity.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&report_id))
        .await
        .map_err(|_| task_error())?
}
