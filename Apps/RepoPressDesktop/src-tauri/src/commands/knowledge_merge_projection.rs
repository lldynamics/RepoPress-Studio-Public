use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeMergeProjectionPlan, KnowledgeMergeProjectionReceipt,
    KnowledgeRestoreStrategy,
};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_merge_projection_task_failed", "The read-only merged projection could not be confirmed. No filesystem write or restore was performed.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_merge_projection(
    candidate_path: String,
    strategy: KnowledgeRestoreStrategy,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeMergeProjectionPlan> {
    let store = state.knowledge_merge_projection.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(Path::new(&candidate_path), strategy))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn preflight_knowledge_merge_projection(
    plan_id: String,
    acknowledge_privacy_reset: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeMergeProjectionReceipt> {
    let store = state.knowledge_merge_projection.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.preflight(&plan_id, acknowledge_privacy_reset)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_merge_projection(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_merge_projection.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
