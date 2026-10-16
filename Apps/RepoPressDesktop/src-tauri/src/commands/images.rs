use super::{blocking_task_failed, AppState};
use crate::core::{CommandResult, RepositoryImagePreview, RepositoryImageSnapshot};
use std::sync::Arc;
use tauri::State;

#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_repository_images(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RepositoryImageSnapshot> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        crate::core::inspect_repository_images(&root)
    })
    .await
    .map_err(|_| blocking_task_failed("image_scan_task_failed", "scan repository images"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn read_repository_image(
    session_id: String,
    relative_path: String,
    expected_sha256: String,
    state: State<'_, AppState>,
) -> CommandResult<RepositoryImagePreview> {
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        crate::core::read_repository_image(&root, &relative_path, &expected_sha256)
    })
    .await
    .map_err(|_| blocking_task_failed("image_read_task_failed", "read a repository image"))?
}
