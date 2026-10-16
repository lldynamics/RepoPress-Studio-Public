use super::{blocking_task_failed, AppState};
use crate::core::{CommandError, CommandResult, WorkspacePreferences, WorkspaceStateSnapshot};
use std::sync::Arc;
use tauri::State;

#[tauri::command]
pub async fn get_workspace_state(
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceStateSnapshot> {
    let workspace = Arc::clone(&state.workspace);
    tauri::async_runtime::spawn_blocking(move || workspace.snapshot())
        .await
        .map_err(|_| blocking_task_failed("workspace_state_task_failed", "read workspace state"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn update_workspace_preferences(
    preferences: WorkspacePreferences,
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceStateSnapshot> {
    let workspace = Arc::clone(&state.workspace);
    tauri::async_runtime::spawn_blocking(move || workspace.update_preferences(preferences))
        .await
        .map_err(|_| {
            blocking_task_failed(
                "workspace_preferences_task_failed",
                "update workspace preferences",
            )
        })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn save_recovery_draft(
    session_id: String,
    document_id: String,
    text: String,
    expected_sha256: String,
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceStateSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    let workspace = Arc::clone(&state.workspace);
    tauri::async_runtime::spawn_blocking(move || {
        let _operation = repositories.lock_recovery_operation()?;
        let (root, relative_path, server_baseline, writable) =
            repositories.recovery_context_for_session(&session_id, &document_id)?;
        if !writable {
            return Err(CommandError::new(
                "document_read_only",
                "Recovery drafts cannot be saved for a read-only document.",
            ));
        }
        if expected_sha256 != server_baseline {
            return Err(CommandError::new(
                "save_conflict",
                "The document changed after it was opened. Reload before saving a recovery draft.",
            ));
        }
        let snapshot =
            workspace.save_recovery_draft(&root, &relative_path, &text, &server_baseline)?;
        let recovery_id = snapshot
            .recovery_draft
            .as_ref()
            .map(|draft| draft.recovery_id.clone());
        let (_, _, current_baseline, _) =
            repositories.recovery_context_for_session(&session_id, &document_id)?;
        if current_baseline != server_baseline {
            if let Some(recovery_id) = recovery_id {
                // Exact identity prevents this stale writer from clearing a newer recovery save.
                let _ = workspace.clear_recovery_draft(&recovery_id);
            }
            return Err(CommandError::new(
                "save_conflict",
                "The document changed while the recovery draft was being saved.",
            ));
        }
        Ok(snapshot)
    })
    .await
    .map_err(|_| blocking_task_failed("recovery_draft_task_failed", "save recovery draft"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn clear_recovery_draft(
    recovery_id: String,
    state: State<'_, AppState>,
) -> CommandResult<WorkspaceStateSnapshot> {
    let workspace = Arc::clone(&state.workspace);
    tauri::async_runtime::spawn_blocking(move || workspace.clear_recovery_draft(&recovery_id))
        .await
        .map_err(|_| blocking_task_failed("recovery_draft_task_failed", "clear recovery draft"))?
}
