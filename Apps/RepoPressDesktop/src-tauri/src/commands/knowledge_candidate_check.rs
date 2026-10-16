use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeCandidateCheckReport, KnowledgeCandidateRecheck,
};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("knowledge_candidate_check_task_failed",
    "The read-only candidate check could not be confirmed. Inspect the selected candidate again; no restore or filesystem write was performed.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_knowledge_candidate(
    candidate_path: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeCandidateCheckReport> {
    let store = state.knowledge_candidate_check.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect(Path::new(&candidate_path)))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn recheck_knowledge_candidate(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeCandidateRecheck> {
    let store = state.knowledge_candidate_check.clone();
    tauri::async_runtime::spawn_blocking(move || store.recheck(&report_id))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_candidate_check(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_candidate_check.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&report_id))
        .await
        .map_err(|_| task_error())?
}
