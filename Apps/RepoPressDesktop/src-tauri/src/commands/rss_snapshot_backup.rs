use super::AppState;
use crate::core::{CommandError, CommandResult, RssSnapshotBackupPlan, RssSnapshotBackupResult};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("rss_snapshot_backup_task_failed","RSS snapshot task could not be confirmed. Inspect the selected filename before preparing another plan; source RSS data was not restored or cleaned up.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_rss_snapshot_backup(
    destination_path: String,
    state: State<'_, AppState>,
) -> CommandResult<RssSnapshotBackupPlan> {
    let store = state.rss_snapshot_backup.clone();
    let rss = state.rss.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(&rss, Path::new(&destination_path)))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_rss_snapshot_backup(
    plan_id: String,
    confirm_sensitive_plaintext: bool,
    state: State<'_, AppState>,
) -> CommandResult<RssSnapshotBackupResult> {
    let store = state.rss_snapshot_backup.clone();
    let rss = state.rss.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.execute(&rss, &plan_id, confirm_sensitive_plaintext)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_rss_snapshot_backup(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    state.rss_snapshot_backup.discard(&plan_id)
}
