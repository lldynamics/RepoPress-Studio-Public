use super::AppState;
use crate::core::{
    CommandError, CommandResult, DraftSnapshotBackupPlan, DraftSnapshotBackupResult,
    DraftSnapshotSource,
};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new("draft_snapshot_backup_task_failed","Draft snapshot task could not be confirmed. Inspect the selected filename before preparing another plan; source drafts were not restored or cleaned up.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_draft_snapshot_backup(
    source: DraftSnapshotSource,
    destination_path: String,
    state: State<'_, AppState>,
) -> CommandResult<DraftSnapshotBackupPlan> {
    let store = state.draft_snapshot_backup.clone();
    let general = state.general_drafts.clone();
    let history = state.draft_history.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.plan(&general, &history, source, Path::new(&destination_path))
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_draft_snapshot_backup(
    plan_id: String,
    confirm_sensitive_plaintext: bool,
    state: State<'_, AppState>,
) -> CommandResult<DraftSnapshotBackupResult> {
    let store = state.draft_snapshot_backup.clone();
    let general = state.general_drafts.clone();
    let history = state.draft_history.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.execute(&general, &history, &plan_id, confirm_sensitive_plaintext)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_draft_snapshot_backup(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    state.draft_snapshot_backup.discard(&plan_id)
}
