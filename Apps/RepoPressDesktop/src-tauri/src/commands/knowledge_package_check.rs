use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgePackageCheckReport, KnowledgePackageMemoryPreflight,
};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_package_check_task_failed", "Selected package check could not be confirmed. Select and inspect again; no filesystem staging or restore was performed.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_knowledge_package(
    source_path: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgePackageCheckReport> {
    let store = state.knowledge_package_check.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect(Path::new(&source_path)))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn preflight_knowledge_package(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgePackageMemoryPreflight> {
    let store = state.knowledge_package_check.clone();
    tauri::async_runtime::spawn_blocking(move || store.preflight(&report_id))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_package_check(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_package_check.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&report_id))
        .await
        .map_err(|_| task_error())?
}
