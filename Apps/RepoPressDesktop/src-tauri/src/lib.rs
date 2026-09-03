mod commands;
mod core;

use commands::{
    get_capabilities, git_status, list_markdown_files, open_document, open_repository,
    save_document, AppState,
};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState::default())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            get_capabilities,
            open_repository,
            list_markdown_files,
            open_document,
            save_document,
            git_status
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
