use super::{blocking_task_failed, open_repository_at_path, AppState};
use crate::core::{CommandResult, RepositorySessionSnapshot, SiteProfileSnapshot};
use std::sync::Arc;
use tauri::State;

#[tauri::command]
pub async fn get_site_profiles(state: State<'_, AppState>) -> CommandResult<SiteProfileSnapshot> {
    let profiles = Arc::clone(&state.site_profiles);
    tauri::async_runtime::spawn_blocking(move || profiles.snapshot())
        .await
        .map_err(|_| blocking_task_failed("site_profiles_read_failed", "read saved sites"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn register_site_profile(
    session_id: String,
    name: String,
    expected_revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<SiteProfileSnapshot> {
    let profiles = Arc::clone(&state.site_profiles);
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        // A display path supplied by the WebView never grants registration authority.
        let root = repositories.root_for_session(&session_id)?;
        profiles.register(&root, &name, expected_revision)
    })
    .await
    .map_err(|_| {
        blocking_task_failed("site_profiles_register_failed", "register the current site")
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn rename_site_profile(
    profile_id: String,
    name: String,
    expected_revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<SiteProfileSnapshot> {
    let profiles = Arc::clone(&state.site_profiles);
    tauri::async_runtime::spawn_blocking(move || {
        profiles.rename(&profile_id, &name, expected_revision)
    })
    .await
    .map_err(|_| blocking_task_failed("site_profiles_rename_failed", "rename the saved site"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn remove_site_profile(
    profile_id: String,
    expected_revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<SiteProfileSnapshot> {
    let profiles = Arc::clone(&state.site_profiles);
    tauri::async_runtime::spawn_blocking(move || profiles.remove(&profile_id, expected_revision))
        .await
        .map_err(|_| {
            blocking_task_failed(
                "site_profiles_remove_failed",
                "remove the site registration",
            )
        })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn open_site_profile(
    profile_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RepositorySessionSnapshot> {
    open_saved_site(profile_id, &state).await
}

async fn open_saved_site(
    profile_id: String,
    state: &AppState,
) -> CommandResult<RepositorySessionSnapshot> {
    let profiles = Arc::clone(&state.site_profiles);
    let path = tauri::async_runtime::spawn_blocking(move || profiles.resolve_root(&profile_id))
        .await
        .map_err(|_| {
            blocking_task_failed("site_profiles_resolve_failed", "resolve the saved site")
        })??;
    // A stored path is only a locator. Reopen through the normal repository validation,
    // fresh session, semantic-index activation, and workspace persistence path.
    open_repository_at_path(path.to_string_lossy().into_owned(), state).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_site_opens_a_fresh_revalidated_session_and_removal_keeps_documents() {
        let directory = tempfile::tempdir().unwrap();
        let first = directory.path().join("博客甲");
        let second = directory.path().join("博客乙");
        std::fs::create_dir(&first).unwrap();
        std::fs::create_dir(&second).unwrap();
        std::fs::write(first.join("article.md"), "# Original\n").unwrap();
        std::fs::write(second.join("article.md"), "# Another\n").unwrap();
        let state = AppState::default();
        let initial = state
            .repositories
            .open_repository(first.to_str().unwrap())
            .unwrap();
        let verified = state
            .repositories
            .root_for_session(&initial.session_id)
            .unwrap();
        let snapshot = state
            .site_profiles
            .register(&verified, "博客甲", 0)
            .unwrap();
        let first_id = snapshot.profiles[0].profile_id.clone();
        let snapshot = state.site_profiles.register(&second, "博客乙", 1).unwrap();
        let second_id = snapshot.profiles[1].profile_id.clone();
        tauri::async_runtime::block_on(async {
            let opened = open_saved_site(first_id, &state).await.unwrap();
            assert_ne!(opened.session_id, initial.session_id);
            let opened = open_saved_site(second_id.clone(), &state).await.unwrap();
            let files = state
                .repositories
                .list_markdown_files(&opened.session_id)
                .unwrap();
            let document = state
                .repositories
                .open_document(&opened.session_id, &files[0].relative_path)
                .unwrap();
            assert_eq!(document.text, "# Another\n");
            assert_eq!(
                state
                    .workspace
                    .snapshot()
                    .unwrap()
                    .last_repository_path
                    .as_deref(),
                second.to_str()
            );
            state.site_profiles.remove(&second_id, 2).unwrap();
            assert!(open_saved_site(second_id, &state).await.is_err());
            // Removing only the registration does not revoke the already-open document
            // or touch files, history, or drafts.
            assert_eq!(
                std::fs::read_to_string(second.join("article.md")).unwrap(),
                "# Another\n"
            );
            assert!(state
                .repositories
                .root_for_session(&opened.session_id)
                .is_ok());
        });
        assert_eq!(
            std::fs::read_to_string(first.join("article.md")).unwrap(),
            "# Original\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn replacing_a_registered_root_with_a_symlink_cannot_open_the_target() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("site");
        let target = directory.path().join("other");
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(&target).unwrap();
        let state = AppState::default();
        let snapshot = state.site_profiles.register(&root, "博客", 0).unwrap();
        std::fs::rename(&root, directory.path().join("moved")).unwrap();
        std::os::unix::fs::symlink(&target, &root).unwrap();
        let error = tauri::async_runtime::block_on(open_saved_site(
            snapshot.profiles[0].profile_id.clone(),
            &state,
        ))
        .unwrap_err();
        assert_eq!(error.code, "repository_root_is_symlink");
        assert!(state
            .workspace
            .snapshot()
            .unwrap()
            .last_repository_path
            .is_none());
    }
}
