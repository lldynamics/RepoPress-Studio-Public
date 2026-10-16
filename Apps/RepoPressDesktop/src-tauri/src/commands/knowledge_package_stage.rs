use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgePackageStagePlan, KnowledgePackageStageResult,
};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_package_stage_task_failed", "Candidate task could not be confirmed. A private partial directory may remain at the reviewed path. Inspect it; do not retry or automatically clean it. No library was installed or replaced.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_package_stage(
    source_path: String,
    parent_path: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgePackageStagePlan> {
    let store = state.knowledge_package_stage.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.plan(Path::new(&source_path), Path::new(&parent_path))
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_knowledge_package_stage(
    plan_id: String,
    confirm_sensitive_plaintext: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgePackageStageResult> {
    let store = state.knowledge_package_stage.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.execute(&plan_id, confirm_sensitive_plaintext)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_package_stage(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_package_stage.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
