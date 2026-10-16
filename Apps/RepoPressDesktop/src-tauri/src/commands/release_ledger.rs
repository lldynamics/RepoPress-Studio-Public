use super::{blocking_task_failed, AppState};
use crate::core::{read_release_ledger, CommandResult, ReleaseLedgerSnapshot};
use tauri::State;

#[tauri::command(rename_all = "camelCase")]
pub async fn get_release_ledger(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<ReleaseLedgerSnapshot> {
    let repositories = state.repositories.clone();
    let pushes = state.publish_ledger.clone();
    let reviews = state.remote_review_ledger.clone();
    let rollbacks = state.rollback_transaction.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let snapshot = read_release_ledger(&session_id, &root, &pushes, &reviews, &rollbacks);
        if repositories.root_for_session(&session_id)? != root {
            return Err(crate::core::CommandError::new(
                "release_ledger_session_changed",
                "Repository session changed; read the local ledger again.",
            ));
        }
        Ok(snapshot)
    })
    .await
    .map_err(|_| blocking_task_failed("release_ledger_task_failed", "read the release ledger"))?
}
