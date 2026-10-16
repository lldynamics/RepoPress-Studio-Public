// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    if repopress_desktop_lib::git_askpass_response_from_environment() {
        return;
    }
    repopress_desktop_lib::run()
}
