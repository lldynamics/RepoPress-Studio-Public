use super::AppState;
use crate::core::{
    BackupSource, CommandError, CommandResult, WorkspaceBackupRecheck, WorkspaceBackupReport,
};
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("workspace_backup_task_failed", "Metadata inspection could not complete. No backup, restore, cleanup or remote request was performed.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_workspace_backup(
    sources: Vec<BackupSource>,
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceBackupReport> {
    let store = state.backup_preflight.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect(sources))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn recheck_workspace_backup(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceBackupRecheck> {
    let store = state.backup_preflight.clone();
    tauri::async_runtime::spawn_blocking(move || store.recheck(&report_id))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_workspace_backup(
    report_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    state.backup_preflight.discard(&report_id)
}
