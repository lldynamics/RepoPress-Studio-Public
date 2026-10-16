use super::AppState;
use crate::core::{
    CommandError, CommandResult, ConfigBackupSource, WorkspaceConfigBackupPlan,
    WorkspaceConfigBackupResult,
};
use std::path::Path;
use tauri::State;

fn task_error() -> CommandError {
    CommandError::new("workspace_config_backup_task_failed", "Configuration backup task could not be confirmed. Inspect the selected filename before preparing a new plan; source configuration was not modified.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_workspace_config_backup(
    sources: Vec<ConfigBackupSource>,
    destination_path: String,
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceConfigBackupPlan> {
    let store = state.config_backup.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(sources, Path::new(&destination_path)))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_workspace_config_backup(
    plan_id: String,
    confirm_sensitive_plaintext: bool,
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceConfigBackupResult> {
    let store = state.config_backup.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.execute(&plan_id, confirm_sensitive_plaintext)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_workspace_config_backup(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    state.config_backup.discard(&plan_id)
}
