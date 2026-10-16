//! Fixed-argv, descriptor-only OCR helper commands.
//!
//! This module intentionally contains no pathname supplied by the user.  The
//! only dynamic values are a validated inherited descriptor, a bounded page
//! number, and one of the three literal language choices.
use super::document_capabilities::{DocumentTool, TrustedTool};
use super::document_runner::{sandbox_base_arguments, SandboxedCommand};
use super::{CommandError, CommandResult};
use std::ffi::OsString;
use std::os::fd::RawFd;
use std::path::Path;
use std::time::Duration;

pub const OCR_MAX_PAGES: u32 = 12;
pub const OCR_MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;
pub const OCR_MAX_TEXT_BYTES: usize = 8 * 1024 * 1024;
const OCR_HELPER_STDERR_LIMIT: usize = 64 * 1024;
const PDF_INFO_TIMEOUT: Duration = Duration::from_secs(8);
const PDF_RASTER_TIMEOUT: Duration = Duration::from_secs(20);
const TESSERACT_TIMEOUT: Duration = Duration::from_secs(30);
const OCR_PAGE_TEXT_LIMIT: usize = 1024 * 1024;
const OCR_MAX_RASTER_EDGE: u32 = 2400;

pub fn validated_language(language: &str) -> CommandResult<&'static str> {
    match language {
        "eng" => Ok("eng"),
        "chi_sim" => Ok("chi_sim"),
        "eng+chi_sim" => Ok("eng+chi_sim"),
        _ => Err(CommandError::new(
            "pdf_ocr_language_invalid",
            "OCR language must be eng, chi_sim, or eng+chi_sim.",
        )),
    }
}

pub fn pdf_info_command(
    bwrap: &TrustedTool,
    pdfinfo: &TrustedTool,
    pdf_descriptor: RawFd,
) -> CommandResult<SandboxedCommand> {
    require_tools(bwrap, pdfinfo, DocumentTool::PdfInfo, pdf_descriptor)?;
    let mut arguments = input_sandbox_arguments(pdf_descriptor, "/input/document.pdf");
    arguments.extend([
        "--".into(),
        pdfinfo.path.as_os_str().to_os_string(),
        "/input/document.pdf".into(),
    ]);
    SandboxedCommand::new(
        bwrap.path.clone(),
        arguments,
        PDF_INFO_TIMEOUT,
        64 * 1024,
        OCR_HELPER_STDERR_LIMIT,
    )?
    .with_inherited_read_only_fd(pdf_descriptor)
}

pub fn pdf_raster_command(
    bwrap: &TrustedTool,
    pdftoppm: &TrustedTool,
    pdf_descriptor: RawFd,
    page: u32,
) -> CommandResult<SandboxedCommand> {
    require_tools(bwrap, pdftoppm, DocumentTool::PdfToPpm, pdf_descriptor)?;
    if page == 0 || page > OCR_MAX_PAGES {
        return Err(CommandError::new(
            "pdf_ocr_page_invalid",
            "OCR requested an invalid PDF page.",
        ));
    }
    let mut arguments = input_sandbox_arguments(pdf_descriptor, "/input/document.pdf");
    arguments.extend([
        "--".into(),
        pdftoppm.path.as_os_str().to_os_string(),
        "-f".into(),
        page.to_string().into(),
        "-l".into(),
        page.to_string().into(),
        "-singlefile".into(),
        "-png".into(),
        "-scale-to".into(),
        OCR_MAX_RASTER_EDGE.to_string().into(),
        "/input/document.pdf".into(),
    ]);
    SandboxedCommand::new(
        bwrap.path.clone(),
        arguments,
        PDF_RASTER_TIMEOUT,
        OCR_MAX_IMAGE_BYTES,
        OCR_HELPER_STDERR_LIMIT,
    )?
    .with_inherited_read_only_fd(pdf_descriptor)
}

pub fn tesseract_command(
    bwrap: &TrustedTool,
    tesseract: &TrustedTool,
    image_descriptor: RawFd,
    tessdata: &Path,
    language: &str,
) -> CommandResult<SandboxedCommand> {
    require_tools(bwrap, tesseract, DocumentTool::Tesseract, image_descriptor)?;
    let language = validated_language(language)?;
    if !tessdata.is_absolute() {
        return Err(CommandError::new(
            "pdf_ocr_tessdata_invalid",
            "Trusted OCR language data path is invalid.",
        ));
    }
    let mut arguments = input_sandbox_arguments(image_descriptor, "/input/page.png");
    arguments.extend([
        "--".into(),
        tesseract.path.as_os_str().to_os_string(),
        "/input/page.png".into(),
        "stdout".into(),
        "--tessdata-dir".into(),
        tessdata.as_os_str().to_os_string(),
        "-l".into(),
        language.into(),
        "--psm".into(),
        "6".into(),
    ]);
    SandboxedCommand::new(
        bwrap.path.clone(),
        arguments,
        TESSERACT_TIMEOUT,
        OCR_PAGE_TEXT_LIMIT,
        OCR_HELPER_STDERR_LIMIT,
    )?
    .with_inherited_read_only_fd(image_descriptor)
}

pub fn parse_pdf_page_count(stdout: &[u8]) -> CommandResult<u32> {
    let output = std::str::from_utf8(stdout).map_err(|_| {
        CommandError::new(
            "pdf_ocr_pdfinfo_invalid",
            "PDF metadata could not be safely read.",
        )
    })?;
    let value = output
        .lines()
        .find_map(|line| line.strip_prefix("Pages:"))
        .map(str::trim)
        .ok_or_else(|| {
            CommandError::new(
                "pdf_ocr_pdfinfo_invalid",
                "PDF metadata did not provide a page count.",
            )
        })?;
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(CommandError::new(
            "pdf_ocr_pdfinfo_invalid",
            "PDF metadata contained an invalid page count.",
        ));
    }
    let pages = value.parse::<u32>().map_err(|_| {
        CommandError::new(
            "pdf_ocr_pdfinfo_invalid",
            "PDF metadata contained an invalid page count.",
        )
    })?;
    if pages == 0 {
        return Err(CommandError::new(
            "pdf_ocr_pdfinfo_invalid",
            "PDF metadata contained an invalid page count.",
        ));
    }
    if pages > OCR_MAX_PAGES {
        return Err(CommandError::new(
            "pdf_ocr_page_limit",
            "OCR supports PDFs with at most 12 pages.",
        ));
    }
    Ok(pages)
}

fn require_tools(
    bwrap: &TrustedTool,
    helper: &TrustedTool,
    expected: DocumentTool,
    descriptor: RawFd,
) -> CommandResult<()> {
    if bwrap.kind != DocumentTool::Bwrap || helper.kind != expected || descriptor < 3 {
        return Err(CommandError::new(
            "pdf_ocr_invalid_tool",
            "OCR requires verified local document helpers.",
        ));
    }
    Ok(())
}

fn input_sandbox_arguments(descriptor: RawFd, target: &str) -> Vec<OsString> {
    let mut arguments = sandbox_base_arguments();
    arguments.extend([
        "--dir".into(),
        "/input".into(),
        "--ro-bind-data".into(),
        descriptor.to_string().into(),
        target.into(),
    ]);
    arguments
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tool(kind: DocumentTool, path: &str) -> TrustedTool {
        TrustedTool {
            kind,
            path: PathBuf::from(path),
        }
    }

    #[test]
    fn ocr_commands_have_fixed_argv_and_no_shell_or_network() {
        let bwrap = tool(DocumentTool::Bwrap, "/usr/bin/bwrap");
        let ppm = tool(DocumentTool::PdfToPpm, "/usr/bin/pdftoppm");
        let command = pdf_raster_command(&bwrap, &ppm, 9, 1).unwrap();
        let argv = command
            .arguments
            .iter()
            .map(|value| value.to_string_lossy())
            .collect::<Vec<_>>();
        assert_eq!(command.executable, PathBuf::from("/usr/bin/bwrap"));
        assert!(argv.contains(&"--unshare-all".into()));
        assert!(argv.contains(&"--unshare-net".into()));
        assert!(argv.contains(&"-scale-to".into()));
        assert!(argv.contains(&"2400".into()));
        assert!(!argv.iter().any(|value| *value == "sh" || *value == "-c"));
    }

    #[test]
    fn page_count_and_language_are_strictly_bounded() {
        assert_eq!(parse_pdf_page_count(b"Pages:          12\n").unwrap(), 12);
        assert_eq!(
            parse_pdf_page_count(b"Pages: 13\n").unwrap_err().code,
            "pdf_ocr_page_limit"
        );
        assert_eq!(
            parse_pdf_page_count(b"Pages: 0\n").unwrap_err().code,
            "pdf_ocr_pdfinfo_invalid"
        );
        assert_eq!(validated_language("eng+chi_sim").unwrap(), "eng+chi_sim");
        assert_eq!(
            validated_language("eng;id").unwrap_err().code,
            "pdf_ocr_language_invalid"
        );
    }
}
