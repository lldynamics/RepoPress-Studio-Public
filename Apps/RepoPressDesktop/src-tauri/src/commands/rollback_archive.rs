use super::AppState;
use crate::core::{CommandError, CommandResult, RollbackArchivePlan, RollbackArchiveResult};
use std::path::Path;
use tauri::State;

fn changed() -> CommandError {
    CommandError::new(
        "rollback_archive_invalid",
        "Repository session changed. A private file may already exist at the selected destination; inspect it before reviewing a new archive plan. The ledger was retained.",
    )
}
fn task_failed() -> CommandError {
    CommandError::new("rollback_archive_task_failed", "Archive task could not be confirmed. Inspect the selected filename before creating a new plan; the ledger was retained.")
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_rollback_archive(
    session_id: String,
    destination_path: String,
    state: State<'_, AppState>,
) -> CommandResult<RollbackArchivePlan> {
    let repositories = state.repositories.clone();
    let transactions = state.rollback_transaction.clone();
    let archives = state.rollback_archive.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let plan = archives.plan(
            &session_id,
            &root,
            Path::new(&destination_path),
            &transactions,
        )?;
        if repositories.root_for_session(&session_id).ok().as_ref() != Some(&root) {
            archives.discard(&session_id, &plan.plan_id)?;
            return Err(changed());
        }
        Ok(plan)
    })
    .await
    .map_err(|_| task_failed())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_rollback_archive(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RollbackArchiveResult> {
    let repositories = state.repositories.clone();
    let transactions = state.rollback_transaction.clone();
    let archives = state.rollback_archive.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = match repositories.root_for_session(&session_id) {
            Ok(root) => root,
            Err(_) => {
                archives.discard(&session_id, &plan_id)?;
                return Err(changed());
            }
        };
        archives.execute(&session_id, &root, &plan_id, &transactions, || {
            if repositories.root_for_session(&session_id).ok().as_ref() != Some(&root) {
                return Err(changed());
            }
            Ok(())
        })
    })
    .await
    .map_err(|_| task_failed())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_rollback_archive(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    state.rollback_archive.discard(&session_id, &plan_id)
}
