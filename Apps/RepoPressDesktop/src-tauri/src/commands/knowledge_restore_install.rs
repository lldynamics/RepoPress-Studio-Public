use super::AppState;
use crate::core::{
    CommandError, CommandResult, KnowledgeRestoreDiagnosis, KnowledgeRestoreInstallPlan,
    KnowledgeRestoreReceipt, KnowledgeRestoreRecoveryAction, KnowledgeRestoreRecoveryPlan,
    KnowledgeRestoreStrategy,
};
use std::path::Path;
use tauri::State;
fn task_error() -> CommandError {
    CommandError::new(
        "knowledge_restore_task_failed",
        "Restore outcome is unknown. Inspect the persistent transaction before retrying.",
    )
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_restore_install(
    candidate_path: String,
    strategy: KnowledgeRestoreStrategy,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreInstallPlan> {
    let store = state.knowledge_restore_install.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan(Path::new(&candidate_path), strategy))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_knowledge_restore_install(
    plan_id: String,
    acknowledge_install: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreReceipt> {
    let store = state.knowledge_restore_install.clone();
    tauri::async_runtime::spawn_blocking(move || store.execute(&plan_id, acknowledge_install))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_knowledge_restore(
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreDiagnosis> {
    let store = state.knowledge_restore_install.clone();
    tauri::async_runtime::spawn_blocking(move || store.inspect())
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_knowledge_restore_recovery(
    transaction_id: String,
    action: KnowledgeRestoreRecoveryAction,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreRecoveryPlan> {
    let store = state.knowledge_restore_install.clone();
    tauri::async_runtime::spawn_blocking(move || store.plan_recovery(&transaction_id, action))
        .await
        .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_knowledge_restore_recovery(
    plan_id: String,
    acknowledge_recovery: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRestoreReceipt> {
    let store = state.knowledge_restore_install.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.execute_recovery(&plan_id, acknowledge_recovery)
    })
    .await
    .map_err(|_| task_error())?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_knowledge_restore_install(
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let store = state.knowledge_restore_install.clone();
    tauri::async_runtime::spawn_blocking(move || store.discard(&plan_id))
        .await
        .map_err(|_| task_error())?
}
