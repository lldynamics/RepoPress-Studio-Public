use super::document_runner::{sandbox_self_test_command, DocumentRunner, ProcessDocumentRunner};
use super::{CommandError, CommandResult};
use serde::Serialize;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

const BWRAP_PATHS: &[&str] = &["/usr/bin/bwrap"];
const PDFTOTEXT_PATHS: &[&str] = &["/usr/bin/pdftotext"];
const PDFINFO_PATHS: &[&str] = &["/usr/bin/pdfinfo"];
const PDFTOPPM_PATHS: &[&str] = &["/usr/bin/pdftoppm"];
const TESSERACT_PATHS: &[&str] = &["/usr/bin/tesseract"];
const TESSDATA_ROOTS: &[&str] = &[
    "/usr/share/tesseract-ocr/5/tessdata",
    "/usr/share/tesseract-ocr/4.00/tessdata",
    "/usr/share/tessdata",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DocumentTool {
    Bwrap,
    PdfToText,
    PdfInfo,
    PdfToPpm,
    Tesseract,
}

impl DocumentTool {
    fn paths(self) -> &'static [&'static str] {
        match self {
            Self::Bwrap => BWRAP_PATHS,
            Self::PdfToText => PDFTOTEXT_PATHS,
            Self::PdfInfo => PDFINFO_PATHS,
            Self::PdfToPpm => PDFTOPPM_PATHS,
            Self::Tesseract => TESSERACT_PATHS,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TrustedTool {
    pub kind: DocumentTool,
    pub path: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolReadiness {
    pub available: bool,
    pub path: Option<String>,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OcrReadiness {
    pub ready: bool,
    pub enabled: bool,
    pub tesseract: ToolReadiness,
    pub pdftoppm: ToolReadiness,
    pub pdf_info: ToolReadiness,
    pub english_data: ToolReadiness,
    pub chinese_simplified_data: ToolReadiness,
    pub warning: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentCapabilities {
    pub pdf_text_ready: bool,
    pub sandbox: ToolReadiness,
    pub pdftotext: ToolReadiness,
    pub ocr: OcrReadiness,
    pub warnings: Vec<String>,
}

impl DocumentCapabilities {
    pub fn pdf_text_tools(&self) -> CommandResult<(TrustedTool, TrustedTool)> {
        if !self.pdf_text_ready {
            return Err(CommandError::new(
                "pdf_text_unavailable",
                "PDF text extraction requires a verified Bubblewrap sandbox and pdftotext.",
            ));
        }
        let bwrap = trusted_tool(DocumentTool::Bwrap)?;
        let pdftotext = trusted_tool(DocumentTool::PdfToText)?;
        Ok((bwrap, pdftotext))
    }

    pub fn ocr_tools(
        &self,
    ) -> CommandResult<(TrustedTool, TrustedTool, TrustedTool, TrustedTool, PathBuf)> {
        if !self.ocr.enabled {
            return Err(CommandError::new(
                "pdf_ocr_unavailable",
                "PDF OCR requires verified local Bubblewrap, Poppler, Tesseract, and language data.",
            ));
        }
        let bwrap = trusted_tool(DocumentTool::Bwrap)?;
        let pdfinfo = trusted_tool(DocumentTool::PdfInfo)?;
        let pdftoppm = trusted_tool(DocumentTool::PdfToPpm)?;
        let tesseract = trusted_tool(DocumentTool::Tesseract)?;
        let tessdata = trusted_tessdata_root()?;
        Ok((bwrap, pdfinfo, pdftoppm, tesseract, tessdata))
    }
}

pub fn inspect_document_capabilities() -> DocumentCapabilities {
    inspect_document_capabilities_with_runner(&ProcessDocumentRunner)
}

pub fn inspect_document_capabilities_with_runner(
    runner: &dyn DocumentRunner,
) -> DocumentCapabilities {
    let bwrap = tool_readiness(DocumentTool::Bwrap);
    let pdftotext = tool_readiness(DocumentTool::PdfToText);
    let pdf_info = tool_readiness(DocumentTool::PdfInfo);
    let pdftoppm = tool_readiness(DocumentTool::PdfToPpm);
    let tesseract = tool_readiness(DocumentTool::Tesseract);
    let english_data = tessdata_readiness("eng.traineddata");
    let chinese_simplified_data = tessdata_readiness("chi_sim.traineddata");

    let sandbox = if bwrap.available {
        match trusted_tool(DocumentTool::Bwrap)
            .and_then(|tool| sandbox_self_test_command(&tool.path))
            .and_then(|command| runner.run(&command))
        {
            Ok(output) if output.success => bwrap.clone(),
            Ok(_) => ToolReadiness {
                available: false,
                path: bwrap.path.clone(),
                reason: Some("sandbox_self_test_failed".to_string()),
            },
            Err(error) => ToolReadiness {
                available: false,
                path: bwrap.path.clone(),
                reason: Some(format!("sandbox_self_test_failed: {}", error.code)),
            },
        }
    } else {
        bwrap.clone()
    };

    let pdf_text_ready = sandbox.available && pdftotext.available;
    let ocr_ready = sandbox.available
        && pdftoppm.available
        && pdf_info.available
        && tesseract.available
        && english_data.available
        && chinese_simplified_data.available;
    let mut warnings = Vec::new();
    if !pdf_text_ready {
        warnings.push("pdf_text_extraction_unavailable".to_string());
    }
    if !ocr_ready {
        warnings.push("ocr_dependencies_unavailable".to_string());
    }

    DocumentCapabilities {
        pdf_text_ready,
        sandbox,
        pdftotext,
        ocr: OcrReadiness {
            ready: ocr_ready,
            enabled: ocr_ready,
            tesseract,
            pdftoppm,
            pdf_info,
            english_data,
            chinese_simplified_data,
            warning: "OCR runs only on this device after explicit confirmation.".to_string(),
        },
        warnings,
    }
}

pub fn trusted_tool(kind: DocumentTool) -> CommandResult<TrustedTool> {
    for candidate in kind.paths() {
        let path = Path::new(candidate);
        if is_trusted_regular_file(path).is_ok() {
            return Ok(TrustedTool {
                kind,
                path: path.to_path_buf(),
            });
        }
    }
    Err(CommandError::new(
        "document_tool_unavailable",
        "A required document helper is unavailable or does not meet the trusted-path policy.",
    ))
}

fn tool_readiness(kind: DocumentTool) -> ToolReadiness {
    match trusted_tool(kind) {
        Ok(tool) => ToolReadiness {
            available: true,
            path: Some(tool.path.to_string_lossy().into_owned()),
            reason: None,
        },
        Err(_) => ToolReadiness {
            available: false,
            path: None,
            reason: Some("missing_or_untrusted_fixed_path".to_string()),
        },
    }
}

fn tessdata_readiness(file_name: &str) -> ToolReadiness {
    for root in TESSDATA_ROOTS {
        let root = Path::new(root);
        if !is_trusted_directory(root) {
            continue;
        }
        let candidate = root.join(file_name);
        if is_trusted_regular_file(&candidate).is_ok() {
            return ToolReadiness {
                available: true,
                path: Some(candidate.to_string_lossy().into_owned()),
                reason: None,
            };
        }
    }
    ToolReadiness {
        available: false,
        path: None,
        reason: Some("missing_or_untrusted_tessdata".to_string()),
    }
}

fn trusted_tessdata_root() -> CommandResult<PathBuf> {
    for root in TESSDATA_ROOTS {
        let root = Path::new(root);
        if !is_trusted_directory(root) {
            continue;
        }
        if is_trusted_regular_file(&root.join("eng.traineddata")).is_ok()
            && is_trusted_regular_file(&root.join("chi_sim.traineddata")).is_ok()
        {
            return Ok(root.to_path_buf());
        }
    }
    Err(CommandError::new(
        "document_tessdata_unavailable",
        "Trusted OCR language data is unavailable.",
    ))
}

fn is_trusted_regular_file(path: &Path) -> CommandResult<()> {
    if !path.is_absolute() || path.parent().is_none() {
        return Err(CommandError::new(
            "document_tool_path_invalid",
            "Document helper paths must be fixed absolute paths.",
        ));
    }
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CommandError::io(
            "document_tool_unavailable",
            "Unable to inspect document helper",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err(CommandError::new(
            "document_tool_untrusted",
            "Document helpers must be regular, non-symlink files.",
        ));
    }
    verify_root_owned_non_writable(&metadata)?;
    verify_trusted_parent_directories(path)
}

fn is_trusted_directory(path: &Path) -> bool {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return false;
    };
    !metadata.file_type().is_symlink()
        && metadata.file_type().is_dir()
        && verify_root_owned_non_writable(&metadata).is_ok()
}

fn verify_root_owned_non_writable(metadata: &fs::Metadata) -> CommandResult<()> {
    if metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
        return Err(CommandError::new(
            "document_tool_untrusted",
            "Document helpers and OCR data must be root-owned and not group/world writable.",
        ));
    }
    Ok(())
}

fn verify_trusted_parent_directories(path: &Path) -> CommandResult<()> {
    let mut current = path.parent();
    while let Some(directory) = current {
        let metadata = fs::symlink_metadata(directory).map_err(|error| {
            CommandError::io(
                "document_tool_unavailable",
                "Unable to inspect a document helper parent directory",
                error,
            )
        })?;
        if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
            return Err(CommandError::new(
                "document_tool_untrusted",
                "Document helper parent directories must be regular trusted directories.",
            ));
        }
        verify_root_owned_non_writable(&metadata)?;
        current = directory.parent();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::document_runner::{BoundedProcessOutput, SandboxedCommand};

    struct FailingRunner;

    impl DocumentRunner for FailingRunner {
        fn run(&self, _command: &SandboxedCommand) -> CommandResult<BoundedProcessOutput> {
            Err(CommandError::new("document_runner_timeout", "timed out"))
        }
    }

    #[test]
    fn untrusted_or_missing_fixed_paths_are_not_available() {
        let readiness = tool_readiness(DocumentTool::Bwrap);
        assert!(
            (readiness.available && readiness.path.as_deref() == Some("/usr/bin/bwrap"))
                || (!readiness.available
                    && readiness.reason.as_deref() == Some("missing_or_untrusted_fixed_path"))
        );
    }

    #[test]
    fn self_test_command_is_bounded_and_fails_closed() {
        let command = sandbox_self_test_command(Path::new("/usr/bin/bwrap")).unwrap();
        assert_eq!(
            command.timeout,
            super::super::document_runner::SELF_TEST_TIMEOUT
        );
        let output = FailingRunner.run(&command);
        assert_eq!(output.unwrap_err().code, "document_runner_timeout");
    }

    #[test]
    fn ocr_remains_disabled_when_the_sandbox_self_test_fails() {
        let capabilities = inspect_document_capabilities_with_runner(&FailingRunner);
        assert!(!capabilities.ocr.enabled);
        assert!(capabilities
            .warnings
            .contains(&"ocr_dependencies_unavailable".to_string()));
    }
}
