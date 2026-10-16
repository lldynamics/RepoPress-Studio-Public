use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeRestoreQualificationPlan,
    KnowledgeRestoreQualificationRecheck, KnowledgeRestoreStrategy,
};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_restore_qualification_task_failed", "Read-only qualification could not be confirmed. No restore or filesystem write was performed.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_restore_qualification(
    candidate_path: String,
    strategy: KnowledgeRestoreStrategy,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreQualificationPlan> {
    let store = state.knowledge_restore_qualification.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(Path::new(&candidate_path), strategy))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn recheck_knowledge_restore_qualification(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreQualificationRecheck> {
    let store = state.knowledge_restore_qualification.clone();
    tauri::async_runtime::spawn_blocking(move || store.recheck(&plan_id))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_restore_qualification(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_restore_qualification.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
