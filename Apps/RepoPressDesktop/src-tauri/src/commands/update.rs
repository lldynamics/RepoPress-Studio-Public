use super::AppState;
use crate::core::{
    check_app_update_impl, install_app_update_impl, AppUpdateCheck, AppUpdateInstallResult,
    CommandResult,
};
use std::sync::Arc;
use tauri::State;

#[tauri::command]
pub async fn check_app_update(state: State<'_, AppState>) -> CommandResult<AppUpdateCheck> {
    check_app_update_impl(&Arc::clone(&state.updater)).await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn install_app_update(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<AppUpdateInstallResult> {
    install_app_update_impl(&Arc::clone(&state.updater), plan_id).await
}
