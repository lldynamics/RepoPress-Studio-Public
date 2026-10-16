use super::{blocking_task_failed, AppState};
use crate::core::{CommandResult, GitIndexAction, GitIndexPlan, GitIndexUpdateResult};
use std::sync::Arc;
use tauri::State;

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_git_index_update(
    session_id: String,
    action: String,
    paths: Vec<String>,
    state: State<'_, AppState>,
) -> CommandResult<GitIndexPlan> {
    let repositories = Arc::clone(&state.repositories);
    let index = Arc::clone(&state.git_index);
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        index.plan(&session_id, &root, GitIndexAction::parse(&action)?, &paths)
    })
    .await
    .map_err(|_| blocking_task_failed("git_index_plan_task_failed", "plan the Git index update"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn execute_git_index_update(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GitIndexUpdateResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::GitIndexUpdate,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let index = Arc::clone(&state.git_index);
            tauri::async_runtime::spawn_blocking(move || {
                // Resolve this session first so an expired session cannot be used to
                // consume a plan belonging to another live repository.
                repositories.root_for_session(&session_id)?;
                index.execute(&session_id, &plan_id)
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "git_index_execute_task_failed",
                    "execute the Git index update",
                )
            })?
        },
    )
    .await
}
