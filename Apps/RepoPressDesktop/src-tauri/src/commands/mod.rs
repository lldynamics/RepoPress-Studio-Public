use crate::core::{
    read_git_status, CapabilitySnapshot, CommandResult, DocumentSnapshot, GitStatusSnapshot,
    MarkdownFileEntry, RepositorySessionSnapshot, RepositoryStore,
};
use tauri::State;

#[derive(Default, Debug)]
pub struct AppState {
    repositories: RepositoryStore,
}

#[tauri::command]
pub fn get_capabilities() -> CapabilitySnapshot {
    CapabilitySnapshot::default()
}

#[tauri::command]
pub fn open_repository(
    path: String,
    state: State<'_, AppState>,
) -> CommandResult<RepositorySessionSnapshot> {
    state.repositories.open_repository(&path)
}

#[tauri::command(rename_all = "camelCase")]
pub fn list_markdown_files(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Vec<MarkdownFileEntry>> {
    state.repositories.list_markdown_files(&session_id)
}

#[tauri::command(rename_all = "camelCase")]
pub fn open_document(
    session_id: String,
    relative_path: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    state
        .repositories
        .open_document(&session_id, &relative_path)
}

#[tauri::command(rename_all = "camelCase")]
pub fn save_document(
    session_id: String,
    document_id: String,
    text: String,
    expected_sha256: String,
    state: State<'_, AppState>,
) -> CommandResult<DocumentSnapshot> {
    state
        .repositories
        .save_document(&session_id, &document_id, &text, &expected_sha256)
}

#[tauri::command(rename_all = "camelCase")]
pub fn git_status(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GitStatusSnapshot> {
    let root = state.repositories.root_for_session(&session_id)?;
    read_git_status(&root)
}
