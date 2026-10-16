use super::{blocking_task_failed, AppState};
use crate::core::{
    export_document, inspect_document_capabilities, CommandResult, DocumentCapabilities,
    DocumentExportResult, PdfOcrExtraction, PdfSelection, PdfTextExtraction,
};
use tauri::State;

#[tauri::command]
pub async fn document_capabilities() -> CommandResult<DocumentCapabilities> {
    tauri::async_runtime::spawn_blocking(inspect_document_capabilities)
        .await
        .map_err(|_| {
            blocking_task_failed(
                "document_capabilities_task_failed",
                "inspect document analysis capabilities",
            )
        })
}

#[tauri::command]
pub async fn select_pdf(path: String, state: State<'_, AppState>) -> CommandResult<PdfSelection> {
    let documents = state.documents.clone();
    tauri::async_runtime::spawn_blocking(move || documents.select_pdf(&path))
        .await
        .map_err(|_| blocking_task_failed("pdf_select_task_failed", "validate the selected PDF"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn extract_pdf_text(
    token: String,
    state: State<'_, AppState>,
) -> CommandResult<PdfTextExtraction> {
    let documents = state.documents.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let capabilities = inspect_document_capabilities();
        documents.extract_text(&token, &capabilities)
    })
    .await
    .map_err(|_| blocking_task_failed("pdf_extract_task_failed", "extract PDF text"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn extract_pdf_ocr(
    token: String,
    language: String,
    state: State<'_, AppState>,
) -> CommandResult<PdfOcrExtraction> {
    let documents = state.documents.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let capabilities = inspect_document_capabilities();
        documents.extract_ocr(&token, &language, &capabilities)
    })
    .await
    .map_err(|_| blocking_task_failed("pdf_ocr_task_failed", "run local PDF OCR"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn export_markdown_document(
    path: String,
    contents: String,
    format: String,
) -> CommandResult<DocumentExportResult> {
    tauri::async_runtime::spawn_blocking(move || export_document(&path, &contents, &format))
        .await
        .map_err(|_| {
            blocking_task_failed(
                "document_export_task_failed",
                "export the Markdown document",
            )
        })?
}
