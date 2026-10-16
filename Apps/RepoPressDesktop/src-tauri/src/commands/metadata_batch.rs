use super::{blocking_task_failed, AppState};
use crate::core::{
    CommandResult, MetadataBatchField, MetadataBatchOperation, MetadataBatchPlan,
    MetadataBatchResult, OperationKind, OperationOutcome,
};
use std::sync::Arc;
use std::time::Instant;
use tauri::State;

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_metadata_batch(
    session_id: String,
    paths: Vec<String>,
    field: MetadataBatchField,
    operation: MetadataBatchOperation,
    state: State<'_, AppState>,
) -> CommandResult<MetadataBatchPlan> {
    let repositories = Arc::clone(&state.repositories);
    let batch = Arc::clone(&state.metadata_batch);
    tauri::async_runtime::spawn_blocking(move || {
        batch.plan(&repositories, &session_id, &paths, field, operation)
    })
    .await
    .map_err(|_| blocking_task_failed("metadata_plan_task_failed", "preview metadata changes"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn execute_metadata_batch(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<MetadataBatchResult> {
    let repositories = Arc::clone(&state.repositories);
    let batch = Arc::clone(&state.metadata_batch);
    let history = Arc::clone(&state.draft_history);
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    let started = Instant::now();
    let result = tauri::async_runtime::spawn_blocking(move || {
        batch.execute(&repositories, &history, &session_id, &plan_id)
    })
    .await
    .map_err(|_| blocking_task_failed("metadata_execute_task_failed", "apply metadata changes"))?;
    let outcome = if result.as_ref().is_ok_and(|r| {
        r.results
            .iter()
            .all(|item| item.status == "applied" || item.status == "unchanged")
    }) {
        OperationOutcome::Succeeded
    } else {
        OperationOutcome::Failed
    };
    let duration = started.elapsed().as_millis().min(86_400_000) as u64;
    let _ = tauri::async_runtime::spawn_blocking(move || {
        log.record(OperationKind::MetadataBatch, outcome, scope, duration)
    })
    .await;
    result
}
