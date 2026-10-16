use commands::{
    discard_draft_snapshot_backup, discard_knowledge_merge_projection,
    discard_knowledge_restore_qualification, execute_draft_snapshot_backup,
    plan_draft_snapshot_backup, plan_knowledge_merge_projection,
    plan_knowledge_restore_qualification, preflight_knowledge_merge_projection,
    recheck_knowledge_restore_qualification,
};
use commands::{discard_knowledge_backup, execute_knowledge_backup, plan_knowledge_backup};
use commands::{
    discard_knowledge_candidate_check, inspect_knowledge_candidate, recheck_knowledge_candidate,
};
use commands::{
    discard_knowledge_integrity, inspect_knowledge_integrity, recheck_knowledge_integrity,
};
use commands::{
    discard_knowledge_package_check, inspect_knowledge_package, preflight_knowledge_package,
};
use commands::{
    discard_knowledge_package_stage, execute_knowledge_package_stage, plan_knowledge_package_stage,
};
use commands::{
    discard_knowledge_restore_archive, execute_knowledge_restore_archive,
    inspect_knowledge_restore_archive, plan_knowledge_restore_archive,
};
use commands::{
    discard_knowledge_restore_cleanup, execute_knowledge_restore_cleanup,
    inspect_knowledge_restore_cleanup, plan_knowledge_restore_cleanup,
};
use commands::{
    discard_knowledge_restore_history_export, execute_knowledge_restore_history_export,
    inspect_knowledge_restore_history_export, plan_knowledge_restore_history_export,
};
use commands::{
    discard_knowledge_restore_install, execute_knowledge_restore_install,
    execute_knowledge_restore_recovery, inspect_knowledge_restore, plan_knowledge_restore_install,
    plan_knowledge_restore_recovery,
};
use commands::{discard_rollback_archive, execute_rollback_archive, plan_rollback_archive};
use commands::{
    discard_rollback_transaction, execute_rollback_transaction, list_rollback_records,
    plan_rollback_transaction, verify_rollback_record,
};
use commands::{
    discard_rss_snapshot_backup, execute_rss_snapshot_backup, plan_rss_snapshot_backup,
};
use commands::{discard_workspace_backup, inspect_workspace_backup, recheck_workspace_backup};
use commands::{
    discard_workspace_config_backup, execute_workspace_config_backup, plan_workspace_config_backup,
};
use commands::{
    execute_publish_verification, list_publish_records, plan_publish_verification,
    remove_publish_record,
};
use commands::{
    execute_remote_review_verification, list_remote_review_records,
    plan_remote_review_verification, remove_remote_review_record,
};
mod commands;
mod core;
use commands::get_release_ledger;
use commands::inspect_rollback_changes;
use commands::{check_rollback_qualification, plan_rollback_qualification};
use commands::{discard_rollback_candidate, generate_rollback_candidate, plan_rollback_candidate};

use commands::{clear_operation_log, get_operation_log};
use commands::{complete_editor_exit, prepare_editor_exit, EditorExitRuntime};
use commands::{
    get_site_profiles, open_site_profile, register_site_profile, remove_site_profile,
    rename_site_profile,
};
use commands::{inspect_repository_images, read_repository_image};
use tauri::{Emitter, Manager};

use commands::{
    ai_credential_status, apply_ai_edits, browser_capture_status, browser_protocol_status,
    cancel_ai_chat_stream, check_app_update, check_deployment, check_site_preview_page,
    clear_recovery_draft, create_ai_conversation, create_knowledge_folder,
    create_markdown_document, credential_status, delete_ai_chat_vault, delete_ai_conversation,
    delete_ai_credential, delete_ai_provider_profile, delete_knowledge_item,
    delete_markdown_document, delete_recycled_draft, delete_repository_credential,
    document_capabilities, execute_ai_chat, execute_ai_connection, execute_ai_edit,
    execute_general_draft_transfer, execute_git_index_update, execute_git_operation,
    execute_git_push_retry, execute_knowledge_archive_export, execute_knowledge_export,
    execute_metadata_batch, execute_remote_review, execute_structured_text_translation,
    execute_text_translation, export_markdown_document, extract_pdf_ocr, extract_pdf_text,
    get_ai_chat_vault_status, get_capabilities, get_draft_version, get_general_draft,
    get_knowledge_item, get_knowledge_revision, get_recycled_draft, get_workspace_state,
    git_file_diff, git_status, import_knowledge_text, import_writing_image,
    initialize_ai_chat_vault, inspect_content_health_sources, inspect_markdown_link_metadata,
    inspect_site_preview, install_app_update, knowledge_library_status, list_ai_conversations,
    list_ai_provider_profiles, list_draft_versions, list_general_drafts, list_knowledge_folders,
    list_knowledge_items, list_knowledge_revisions, list_markdown_files, list_recycled_drafts,
    lock_ai_chat_vault, move_knowledge_item, open_document, open_repository, plan_ai_chat,
    plan_ai_connection, plan_ai_edit, plan_general_draft_transfer, plan_git_index_update,
    plan_git_operation, plan_git_push_retry, plan_knowledge_archive_export, plan_knowledge_export,
    plan_metadata_batch, plan_remote_review, plan_site_preview, plan_structured_text_translation,
    plan_text_translation, poll_ai_chat_stream, rebuild_semantic_index, rename_markdown_document,
    restore_draft_version, restore_recycled_draft, rotate_browser_capture_token, rss_add_feed,
    rss_clear_offline_translations, rss_delete_highlight, rss_delete_offline_translation,
    rss_discover, rss_execute_opml, rss_export_backup, rss_export_opml, rss_fetch_cover,
    rss_fetch_full_text, rss_get_article, rss_get_offline_translation, rss_get_preferences,
    rss_get_reading_progress, rss_history_cancel_discovery, rss_history_clear,
    rss_history_discover, rss_history_list, rss_history_pause, rss_history_prepare_retry,
    rss_history_resume_discovery, rss_history_status, rss_history_step, rss_import_opml,
    rss_inspect_backup, rss_list_articles, rss_list_highlights, rss_mark_all_read,
    rss_offline_translation_cache_status, rss_prune, rss_prune_offline_translations,
    rss_refresh_all, rss_refresh_feed, rss_remove_feed, rss_restore_backup, rss_review_opml,
    rss_save_highlight, rss_save_offline_translation, rss_save_reading_progress, rss_snapshot,
    rss_undo_mark_all_read, rss_undo_remove_feed, rss_update_article_state, rss_update_feed_url,
    rss_update_preferences, save_ai_provider_profile, save_document, save_general_draft,
    save_recovery_draft, search_knowledge_items, search_markdown_files, select_pdf,
    semantic_index_status, semantic_search, set_knowledge_remote_ai_permission,
    start_ai_chat_stream, start_site_preview, stop_site_preview, store_ai_credential,
    store_repository_credential, take_knowledge_open_request, undo_general_draft_transfer,
    unlock_ai_chat_vault, update_knowledge_progress, update_readiness,
    update_workspace_preferences, AppState,
};

pub use core::git_askpass_response_from_environment;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(EditorExitRuntime::default())
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" && !window.state::<EditorExitRuntime>().permitted() {
                    api.prevent_close();
                    let _ = window.emit("repopress://close-requested", ());
                }
            }
        })
        .setup(|app| {
            let app_data_dir = app.path().app_data_dir()?;
            app.manage(AppState::new(app_data_dir)?);
            Ok(())
        })
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            inspect_knowledge_restore_history_export,
            plan_knowledge_restore_history_export,
            execute_knowledge_restore_history_export,
            discard_knowledge_restore_history_export,
            inspect_knowledge_restore_cleanup,
            plan_knowledge_restore_cleanup,
            execute_knowledge_restore_cleanup,
            discard_knowledge_restore_cleanup,
            inspect_knowledge_restore_archive,
            plan_knowledge_restore_archive,
            execute_knowledge_restore_archive,
            discard_knowledge_restore_archive,
            plan_knowledge_restore_install,
            execute_knowledge_restore_install,
            inspect_knowledge_restore,
            plan_knowledge_restore_recovery,
            execute_knowledge_restore_recovery,
            discard_knowledge_restore_install,
            plan_knowledge_merge_projection,
            preflight_knowledge_merge_projection,
            discard_knowledge_merge_projection,
            plan_knowledge_restore_qualification,
            recheck_knowledge_restore_qualification,
            discard_knowledge_restore_qualification,
            inspect_knowledge_candidate,
            recheck_knowledge_candidate,
            discard_knowledge_candidate_check,
            plan_knowledge_package_stage,
            execute_knowledge_package_stage,
            discard_knowledge_package_stage,
            inspect_knowledge_package,
            preflight_knowledge_package,
            discard_knowledge_package_check,
            plan_knowledge_backup,
            execute_knowledge_backup,
            discard_knowledge_backup,
            inspect_knowledge_integrity,
            recheck_knowledge_integrity,
            discard_knowledge_integrity,
            plan_draft_snapshot_backup,
            execute_draft_snapshot_backup,
            discard_draft_snapshot_backup,
            plan_rss_snapshot_backup,
            execute_rss_snapshot_backup,
            discard_rss_snapshot_backup,
            plan_workspace_config_backup,
            execute_workspace_config_backup,
            discard_workspace_config_backup,
            list_publish_records,
            get_release_ledger,
            inspect_rollback_changes,
            inspect_workspace_backup,
            recheck_workspace_backup,
            discard_workspace_backup,
            plan_rollback_archive,
            execute_rollback_archive,
            discard_rollback_archive,
            plan_rollback_transaction,
            execute_rollback_transaction,
            discard_rollback_transaction,
            list_rollback_records,
            verify_rollback_record,
            plan_rollback_candidate,
            generate_rollback_candidate,
            discard_rollback_candidate,
            plan_rollback_qualification,
            check_rollback_qualification,
            list_remote_review_records,
            plan_remote_review_verification,
            execute_remote_review_verification,
            remove_remote_review_record,
            remove_publish_record,
            plan_publish_verification,
            execute_publish_verification,
            prepare_editor_exit,
            complete_editor_exit,
            get_capabilities,
            plan_metadata_batch,
            execute_metadata_batch,
            get_site_profiles,
            register_site_profile,
            rename_site_profile,
            remove_site_profile,
            open_site_profile,
            get_operation_log,
            clear_operation_log,
            open_repository,
            list_markdown_files,
            inspect_content_health_sources,
            inspect_repository_images,
            read_repository_image,
            search_markdown_files,
            open_document,
            inspect_markdown_link_metadata,
            save_document,
            create_markdown_document,
            rename_markdown_document,
            delete_markdown_document,
            list_draft_versions,
            get_draft_version,
            restore_draft_version,
            list_recycled_drafts,
            get_recycled_draft,
            restore_recycled_draft,
            delete_recycled_draft,
            list_general_drafts,
            get_general_draft,
            save_general_draft,
            plan_general_draft_transfer,
            execute_general_draft_transfer,
            undo_general_draft_transfer,
            import_writing_image,
            git_status,
            git_file_diff,
            plan_site_preview,
            check_site_preview_page,
            inspect_site_preview,
            start_site_preview,
            stop_site_preview,
            credential_status,
            store_repository_credential,
            delete_repository_credential,
            plan_git_operation,
            plan_git_push_retry,
            execute_git_push_retry,
            execute_git_operation,
            plan_git_index_update,
            execute_git_index_update,
            plan_remote_review,
            execute_remote_review,
            check_deployment,
            browser_protocol_status,
            update_readiness,
            check_app_update,
            install_app_update,
            semantic_index_status,
            rebuild_semantic_index,
            semantic_search,
            document_capabilities,
            export_markdown_document,
            select_pdf,
            extract_pdf_text,
            extract_pdf_ocr,
            plan_ai_connection,
            execute_ai_connection,
            ai_credential_status,
            store_ai_credential,
            delete_ai_credential,
            list_ai_conversations,
            create_ai_conversation,
            delete_ai_conversation,
            get_ai_chat_vault_status,
            initialize_ai_chat_vault,
            unlock_ai_chat_vault,
            lock_ai_chat_vault,
            delete_ai_chat_vault,
            list_ai_provider_profiles,
            save_ai_provider_profile,
            delete_ai_provider_profile,
            plan_ai_chat,
            execute_ai_chat,
            start_ai_chat_stream,
            poll_ai_chat_stream,
            cancel_ai_chat_stream,
            plan_ai_edit,
            execute_ai_edit,
            plan_text_translation,
            execute_text_translation,
            plan_structured_text_translation,
            execute_structured_text_translation,
            apply_ai_edits,
            get_workspace_state,
            update_workspace_preferences,
            save_recovery_draft,
            clear_recovery_draft,
            knowledge_library_status,
            list_knowledge_items,
            list_knowledge_folders,
            create_knowledge_folder,
            move_knowledge_item,
            get_knowledge_item,
            list_knowledge_revisions,
            get_knowledge_revision,
            take_knowledge_open_request,
            import_knowledge_text,
            search_knowledge_items,
            update_knowledge_progress,
            set_knowledge_remote_ai_permission,
            delete_knowledge_item,
            plan_knowledge_export,
            execute_knowledge_export,
            plan_knowledge_archive_export,
            execute_knowledge_archive_export,
            browser_capture_status,
            rotate_browser_capture_token,
            rss_snapshot,
            rss_discover,
            rss_add_feed,
            rss_update_feed_url,
            rss_remove_feed,
            rss_undo_remove_feed,
            rss_refresh_feed,
            rss_refresh_all,
            rss_list_articles,
            rss_get_article,
            rss_update_article_state,
            rss_mark_all_read,
            rss_undo_mark_all_read,
            rss_review_opml,
            rss_execute_opml,
            rss_history_cancel_discovery,
            rss_history_discover,
            rss_history_resume_discovery,
            rss_history_list,
            rss_history_clear,
            rss_history_status,
            rss_history_step,
            rss_history_pause,
            rss_history_prepare_retry,
            rss_import_opml,
            rss_export_opml,
            rss_export_backup,
            rss_inspect_backup,
            rss_restore_backup,
            rss_get_preferences,
            rss_update_preferences,
            rss_prune,
            rss_get_offline_translation,
            rss_save_offline_translation,
            rss_delete_offline_translation,
            rss_offline_translation_cache_status,
            rss_prune_offline_translations,
            rss_clear_offline_translations,
            rss_fetch_full_text,
            rss_fetch_cover,
            rss_list_highlights,
            rss_save_highlight,
            rss_delete_highlight,
            rss_get_reading_progress,
            rss_save_reading_progress
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                if !app.state::<EditorExitRuntime>().permitted() {
                    api.prevent_exit();
                    let _ = app.emit("repopress://close-requested", ());
                }
            }
        });
}
