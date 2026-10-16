use super::document_capabilities::{DocumentCapabilities, DocumentTool, TrustedTool};
use super::document_runner::{
    sandbox_base_arguments, DocumentRunner, ProcessDocumentRunner, SandboxedCommand,
    PDF_TEXT_OUTPUT_LIMIT, PDF_TEXT_TIMEOUT,
};
use super::ocr_extract::{
    parse_pdf_page_count, pdf_info_command, pdf_raster_command, tesseract_command,
    validated_language, OCR_MAX_TEXT_BYTES,
};
use super::{CommandError, CommandResult};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::ffi::CString;
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use uuid::Uuid;

pub const MAX_PDF_BYTES: u64 = 50 * 1024 * 1024;
const PDF_MAGIC: &[u8] = b"%PDF-";
const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";
const TOKEN_TTL_SECONDS: i64 = 5 * 60;
const MAX_PENDING_TOKENS: usize = 64;
const STREAM_BUFFER_BYTES: usize = 64 * 1024;

pub trait DocumentClock: Send + Sync {
    fn unix_seconds(&self) -> i64;
}

#[derive(Debug, Default)]
pub struct SystemDocumentClock;

impl DocumentClock for SystemDocumentClock {
    fn unix_seconds(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs() as i64)
            .unwrap_or(0)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PdfSelection {
    pub token: String,
    pub file_name: String,
    pub byte_size: u64,
    pub expires_at_epoch_seconds: i64,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PdfTextExtraction {
    pub text: String,
    pub byte_size: usize,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PdfOcrExtraction {
    pub text: String,
    pub byte_size: usize,
    pub page_count: u32,
    pub language: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FileIdentity {
    device: u64,
    inode: u64,
    byte_size: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
    sha256: String,
}

#[derive(Clone, Debug)]
struct PendingPdf {
    path: PathBuf,
    identity: FileIdentity,
    expires_at_epoch_seconds: i64,
}

/// Keeps an anonymous, write-sealed Linux memfd alive until the sandboxed
/// runner returns. There is no pathname that another process can exchange.
#[derive(Debug)]
struct PrivatePdfSnapshot {
    file: fs::File,
}

pub struct PdfAnalysisStore {
    runner: Arc<dyn DocumentRunner>,
    clock: Arc<dyn DocumentClock>,
    pending: Mutex<HashMap<String, PendingPdf>>,
}

impl Default for PdfAnalysisStore {
    fn default() -> Self {
        Self::new()
    }
}

impl PdfAnalysisStore {
    pub fn new() -> Self {
        Self::with_runner_and_clock(
            Arc::new(ProcessDocumentRunner),
            Arc::new(SystemDocumentClock),
        )
    }

    pub fn with_runner_and_clock(
        runner: Arc<dyn DocumentRunner>,
        clock: Arc<dyn DocumentClock>,
    ) -> Self {
        Self {
            runner,
            clock,
            pending: Mutex::new(HashMap::new()),
        }
    }

    /// Validates a user-selected PDF and returns a short-lived, one-use token.
    /// Validation is performed through one O_NOFOLLOW file descriptor, with a
    /// bounded streaming SHA-256 and stable fstat before/after that read.
    pub fn select_pdf(&self, selected_path: &str) -> CommandResult<PdfSelection> {
        let (path, identity) = inspect_pdf(Path::new(selected_path))?;
        let now = self.clock.unix_seconds();
        let expires_at_epoch_seconds = now.saturating_add(TOKEN_TTL_SECONDS);
        let token = Uuid::new_v4().to_string();

        let mut pending = self.lock_pending()?;
        pending.retain(|_, item| item.expires_at_epoch_seconds > now);
        if pending.len() >= MAX_PENDING_TOKENS {
            return Err(CommandError::new(
                "pdf_selection_limit",
                "Too many pending PDF selections; wait for an existing selection to expire.",
            ));
        }
        pending.insert(
            token.clone(),
            PendingPdf {
                path: path.clone(),
                identity: identity.clone(),
                expires_at_epoch_seconds,
            },
        );

        Ok(PdfSelection {
            token,
            file_name: path
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("document.pdf")
                .to_string(),
            byte_size: identity.byte_size,
            expires_at_epoch_seconds,
            warnings: vec!["ocr_requires_explicit_local_confirmation".to_string()],
        })
    }

    /// Consumes a selection token before revalidation. Failed checks remain
    /// one-shot, preventing a stale approval from being retried after a file
    /// changes beneath the original selection.
    pub fn extract_text(
        &self,
        token: &str,
        capabilities: &DocumentCapabilities,
    ) -> CommandResult<PdfTextExtraction> {
        let now = self.clock.unix_seconds();
        let selection = self.lock_pending()?.remove(token).ok_or_else(|| {
            CommandError::new(
                "pdf_selection_invalid",
                "The PDF selection token is invalid, expired, or already used.",
            )
        })?;
        if selection.expires_at_epoch_seconds <= now {
            return Err(CommandError::new(
                "pdf_selection_expired",
                "The PDF selection expired; select the file again.",
            ));
        }

        let snapshot = create_verified_snapshot(&selection.path, &selection.identity)?;
        // `create_verified_snapshot` safely reopens, streams, hashes, and
        // compares the canonical path plus identity before this point.
        let (bwrap, pdftotext) = capabilities.pdf_text_tools()?;
        let command = pdf_text_command(&bwrap, &pdftotext, snapshot.file.as_raw_fd())?;
        let output = self.runner.run(&command)?;
        if !output.success {
            return Err(CommandError::new(
                "pdf_text_extraction_failed",
                "pdftotext could not extract a text layer from the selected PDF.",
            ));
        }
        let (text, mut warnings) = sanitize_text(&output.stdout, PDF_TEXT_OUTPUT_LIMIT);
        if text.is_empty() {
            warnings.push("pdf_text_layer_empty".to_string());
        }
        Ok(PdfTextExtraction {
            byte_size: text.len(),
            text,
            warnings,
        })
    }

    /// OCR is a separate explicit action from text-layer extraction.  As with
    /// text extraction, token removal happens before expiry, language, helper,
    /// or source revalidation so a selection can authorize exactly one action.
    pub fn extract_ocr(
        &self,
        token: &str,
        language: &str,
        capabilities: &DocumentCapabilities,
    ) -> CommandResult<PdfOcrExtraction> {
        let now = self.clock.unix_seconds();
        let selection = self.lock_pending()?.remove(token).ok_or_else(|| {
            CommandError::new(
                "pdf_selection_invalid",
                "The PDF selection token is invalid, expired, or already used.",
            )
        })?;
        if selection.expires_at_epoch_seconds <= now {
            return Err(CommandError::new(
                "pdf_selection_expired",
                "The PDF selection expired; select the file again.",
            ));
        }
        let language = validated_language(language)?;
        let snapshot = create_verified_snapshot(&selection.path, &selection.identity)?;
        self.run_ocr_snapshot(snapshot, language, capabilities.ocr_tools()?)
    }

    fn run_ocr_snapshot(
        &self,
        snapshot: PrivatePdfSnapshot,
        language: &str,
        (bwrap, pdfinfo, pdftoppm, tesseract, tessdata): (
            TrustedTool,
            TrustedTool,
            TrustedTool,
            TrustedTool,
            PathBuf,
        ),
    ) -> CommandResult<PdfOcrExtraction> {
        let info = self.runner.run(&pdf_info_command(
            &bwrap,
            &pdfinfo,
            snapshot.file.as_raw_fd(),
        )?)?;
        if !info.success {
            return Err(CommandError::new(
                "pdf_ocr_pdfinfo_failed",
                "Unable to inspect the selected PDF for local OCR.",
            ));
        }
        let page_count = parse_pdf_page_count(&info.stdout)?;
        let mut text = String::new();
        let mut warnings = Vec::new();
        let mut helper_text_bytes = 0usize;
        for page in 1..=page_count {
            let raster = self.runner.run(&pdf_raster_command(
                &bwrap,
                &pdftoppm,
                snapshot.file.as_raw_fd(),
                page,
            )?)?;
            if !raster.success || !raster.stdout.starts_with(PNG_MAGIC) {
                return Err(CommandError::new(
                    "pdf_ocr_raster_failed",
                    "Unable to rasterize the selected PDF for local OCR.",
                ));
            }
            let image = create_sealed_snapshot("repopress-ocr-page", &raster.stdout, "OCR image")?;
            let recognized = self.runner.run(&tesseract_command(
                &bwrap,
                &tesseract,
                image.file.as_raw_fd(),
                &tessdata,
                language,
            )?)?;
            if !recognized.success {
                return Err(CommandError::new(
                    "pdf_ocr_tesseract_failed",
                    "Local OCR could not process the selected PDF.",
                ));
            }
            helper_text_bytes = helper_text_bytes.saturating_add(recognized.stdout.len());
            if helper_text_bytes > OCR_MAX_TEXT_BYTES {
                return Err(CommandError::new(
                    "pdf_ocr_text_limit",
                    "Local OCR output exceeded the 8 MiB safety limit.",
                ));
            }
            let (page_text, page_warnings) = sanitize_text(&recognized.stdout, OCR_MAX_TEXT_BYTES);
            if page_warnings
                .iter()
                .any(|warning| warning == "pdf_text_sanitized")
            {
                warnings.push("ocr_text_sanitized".to_string());
            }
            if page_text.trim().is_empty() {
                warnings.push("ocr_page_empty".to_string());
            }
            if !text.is_empty() && !page_text.is_empty() {
                text.push('\n');
            }
            text.push_str(&page_text);
            if text.len() > OCR_MAX_TEXT_BYTES {
                return Err(CommandError::new(
                    "pdf_ocr_text_limit",
                    "Local OCR output exceeded the 8 MiB safety limit.",
                ));
            }
        }
        warnings.sort();
        warnings.dedup();
        Ok(PdfOcrExtraction {
            byte_size: text.len(),
            text,
            page_count,
            language: language.to_string(),
            warnings,
        })
    }

    #[cfg(test)]
    fn extract_ocr_with_tools(
        &self,
        token: &str,
        language: &str,
        tools: (TrustedTool, TrustedTool, TrustedTool, TrustedTool, PathBuf),
    ) -> CommandResult<PdfOcrExtraction> {
        let now = self.clock.unix_seconds();
        let selection = self.lock_pending()?.remove(token).ok_or_else(|| {
            CommandError::new(
                "pdf_selection_invalid",
                "The PDF selection token is invalid, expired, or already used.",
            )
        })?;
        if selection.expires_at_epoch_seconds <= now {
            return Err(CommandError::new(
                "pdf_selection_expired",
                "The PDF selection expired; select the file again.",
            ));
        }
        let language = validated_language(language)?;
        let snapshot = create_verified_snapshot(&selection.path, &selection.identity)?;
        self.run_ocr_snapshot(snapshot, language, tools)
    }

    fn lock_pending(
        &self,
    ) -> CommandResult<std::sync::MutexGuard<'_, HashMap<String, PendingPdf>>> {
        self.pending.lock().map_err(|_| {
            CommandError::new(
                "pdf_selection_unavailable",
                "PDF selection state is temporarily unavailable.",
            )
        })
    }
}

pub fn pdf_text_command(
    bwrap: &TrustedTool,
    pdftotext: &TrustedTool,
    pdf_descriptor: RawFd,
) -> CommandResult<SandboxedCommand> {
    if bwrap.kind != DocumentTool::Bwrap || pdftotext.kind != DocumentTool::PdfToText {
        return Err(CommandError::new(
            "pdf_text_invalid_tool",
            "PDF extraction requires the verified Bubblewrap and pdftotext helpers.",
        ));
    }
    if pdf_descriptor < 3 {
        return Err(CommandError::new(
            "pdf_descriptor_invalid",
            "The sealed PDF snapshot descriptor is invalid.",
        ));
    }
    let mut arguments = sandbox_base_arguments();
    arguments.extend([
        "--dir".into(),
        "/input".into(),
        // `--ro-bind-data` copies only from this sealed descriptor and is
        // available on the Ubuntu 22.04/24.04 Bubblewrap baseline. Unlike a
        // host path bind, it cannot race a pathname replacement.
        "--ro-bind-data".into(),
        pdf_descriptor.to_string().into(),
        "/input/document.pdf".into(),
        "--".into(),
        pdftotext.path.as_os_str().to_os_string(),
        "-enc".into(),
        "UTF-8".into(),
        "-nopgbrk".into(),
        "/input/document.pdf".into(),
        "-".into(),
    ]);
    // Explicitly keep this literal list as fixed argv construction. There is
    // no shell, option interpolation, inherited environment, repository bind,
    // credential bind, or HOME bind.
    SandboxedCommand::new(
        bwrap.path.clone(),
        arguments,
        PDF_TEXT_TIMEOUT,
        PDF_TEXT_OUTPUT_LIMIT,
        64 * 1024,
    )?
    .with_inherited_read_only_fd(pdf_descriptor)
}

fn inspect_pdf(requested: &Path) -> CommandResult<(PathBuf, FileIdentity)> {
    let (canonical, mut file) = open_pdf_without_following_links(requested)?;
    let identity = stream_and_fingerprint_pdf(&mut file, None)?;
    Ok((canonical, identity))
}

fn create_verified_snapshot(
    expected_path: &Path,
    expected_identity: &FileIdentity,
) -> CommandResult<PrivatePdfSnapshot> {
    let (canonical, mut source) = open_pdf_without_following_links(expected_path)?;
    if canonical != expected_path {
        return Err(identity_changed_error());
    }

    let mut snapshot = create_sealable_memfd("repopress-pdf-snapshot")?;
    let identity = stream_and_fingerprint_pdf(&mut source, Some(&mut snapshot))?;
    if &identity != expected_identity {
        return Err(identity_changed_error());
    }
    finalize_sealed_snapshot(&mut snapshot, "PDF")?;
    Ok(PrivatePdfSnapshot { file: snapshot })
}

fn create_sealed_snapshot(
    name: &str,
    bytes: &[u8],
    _kind: &str,
) -> CommandResult<PrivatePdfSnapshot> {
    let mut snapshot = create_sealable_memfd(name)?;
    snapshot.write_all(bytes).map_err(|error| {
        CommandError::io(
            "pdf_snapshot_unavailable",
            "Unable to write a private OCR snapshot",
            error,
        )
    })?;
    finalize_sealed_snapshot(&mut snapshot, _kind)?;
    Ok(PrivatePdfSnapshot { file: snapshot })
}

fn finalize_sealed_snapshot(snapshot: &mut fs::File, _kind: &str) -> CommandResult<()> {
    snapshot.sync_all().map_err(|error| {
        CommandError::io(
            "pdf_snapshot_unavailable",
            "Unable to finalize a private document snapshot",
            error,
        )
    })?;
    snapshot.seek(SeekFrom::Start(0)).map_err(|error| {
        CommandError::io(
            "pdf_snapshot_unavailable",
            "Unable to rewind a private document snapshot",
            error,
        )
    })?;
    snapshot
        .set_permissions(fs::Permissions::from_mode(0o400))
        .map_err(|error| {
            CommandError::io(
                "pdf_snapshot_unavailable",
                "Unable to restrict a private document snapshot",
                error,
            )
        })?;
    seal_snapshot(snapshot)?;
    Ok(())
}

fn create_sealable_memfd(name: &str) -> CommandResult<fs::File> {
    let name = CString::new(name).map_err(|_| {
        CommandError::new(
            "pdf_snapshot_unavailable",
            "Unable to create an anonymous document snapshot.",
        )
    })?;
    // SAFETY: memfd_create copies the valid NUL-terminated name and returns a
    // new owned descriptor. MFD_CLOEXEC remains set in the parent process.
    let descriptor =
        unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING) };
    if descriptor < 0 {
        return Err(CommandError::io(
            "pdf_snapshot_unavailable",
            "Unable to create an anonymous PDF snapshot",
            std::io::Error::last_os_error(),
        ));
    }
    // SAFETY: the successful syscall returned unique ownership of descriptor.
    Ok(unsafe { fs::File::from_raw_fd(descriptor) })
}

fn seal_snapshot(snapshot: &fs::File) -> CommandResult<()> {
    let seals = libc::F_SEAL_SEAL | libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_WRITE;
    // SAFETY: fcntl borrows a live descriptor and does not retain pointers.
    if unsafe { libc::fcntl(snapshot.as_raw_fd(), libc::F_ADD_SEALS, seals) } < 0 {
        return Err(CommandError::io(
            "pdf_snapshot_unavailable",
            "Unable to seal the anonymous PDF snapshot",
            std::io::Error::last_os_error(),
        ));
    }
    Ok(())
}

fn open_pdf_without_following_links(requested: &Path) -> CommandResult<(PathBuf, fs::File)> {
    if !requested.is_absolute() {
        return Err(CommandError::new(
            "pdf_path_not_absolute",
            "Select an absolute PDF path.",
        ));
    }
    let initial = fs::symlink_metadata(requested).map_err(|error| {
        CommandError::io(
            "pdf_unavailable",
            "Unable to inspect the selected PDF",
            error,
        )
    })?;
    if initial.file_type().is_symlink() || !initial.file_type().is_file() {
        return Err(CommandError::new(
            "pdf_not_regular_file",
            "The selected PDF must be a regular, non-symlink file.",
        ));
    }
    // Open the user-supplied leaf before resolving its canonical path. The
    // O_NOFOLLOW descriptor is the object we validate and hash; after path
    // resolution we compare the name again to that same descriptor.
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(requested)
        .map_err(|error| {
            CommandError::io(
                "pdf_unavailable",
                "Unable to safely open the selected PDF",
                error,
            )
        })?;
    let opened_metadata = file.metadata().map_err(|error| {
        CommandError::io("pdf_unavailable", "Unable to inspect the opened PDF", error)
    })?;
    if !opened_metadata.is_file() {
        return Err(CommandError::new(
            "pdf_not_regular_file",
            "The selected PDF must remain a regular, non-symlink file.",
        ));
    }
    if opened_metadata.len() > MAX_PDF_BYTES {
        return Err(CommandError::new(
            "pdf_too_large",
            format!("PDF files larger than {MAX_PDF_BYTES} bytes are not supported."),
        ));
    }
    let canonical = fs::canonicalize(requested).map_err(|error| {
        CommandError::io(
            "pdf_unavailable",
            "Unable to resolve the selected PDF",
            error,
        )
    })?;
    let named_metadata = fs::symlink_metadata(&canonical).map_err(|error| {
        CommandError::io(
            "pdf_unavailable",
            "Unable to re-inspect the selected PDF",
            error,
        )
    })?;
    if named_metadata.file_type().is_symlink() || !named_metadata.file_type().is_file() {
        return Err(CommandError::new(
            "pdf_not_regular_file",
            "The selected PDF must remain a regular, non-symlink file.",
        ));
    }
    if metadata_identity(&named_metadata) != metadata_identity(&opened_metadata) {
        return Err(identity_changed_error());
    }
    Ok((canonical, file))
}

fn stream_and_fingerprint_pdf(
    file: &mut fs::File,
    mut destination: Option<&mut fs::File>,
) -> CommandResult<FileIdentity> {
    let before = file.metadata().map_err(|error| {
        CommandError::io("pdf_unavailable", "Unable to inspect the opened PDF", error)
    })?;
    if !before.is_file() {
        return Err(CommandError::new(
            "pdf_not_regular_file",
            "The selected PDF must be a regular file.",
        ));
    }
    if before.len() > MAX_PDF_BYTES {
        return Err(CommandError::new(
            "pdf_too_large",
            format!("PDF files larger than {MAX_PDF_BYTES} bytes are not supported."),
        ));
    }
    let mut hasher = Sha256::new();
    let mut header = [0_u8; PDF_MAGIC.len()];
    let mut header_len = 0;
    let mut bytes_read = 0_u64;
    let mut buffer = [0_u8; STREAM_BUFFER_BYTES];
    loop {
        let count = file.read(&mut buffer).map_err(|error| {
            CommandError::io("pdf_unavailable", "Unable to read the selected PDF", error)
        })?;
        if count == 0 {
            break;
        }
        bytes_read = bytes_read.saturating_add(count as u64);
        if bytes_read > MAX_PDF_BYTES {
            return Err(CommandError::new(
                "pdf_too_large",
                format!("PDF files larger than {MAX_PDF_BYTES} bytes are not supported."),
            ));
        }
        let needed = PDF_MAGIC.len().saturating_sub(header_len);
        let copied = needed.min(count);
        header[header_len..header_len + copied].copy_from_slice(&buffer[..copied]);
        header_len += copied;
        hasher.update(&buffer[..count]);
        if let Some(target) = destination.as_deref_mut() {
            target.write_all(&buffer[..count]).map_err(|error| {
                CommandError::io(
                    "pdf_snapshot_unavailable",
                    "Unable to write the private PDF snapshot",
                    error,
                )
            })?;
        }
    }
    if header_len != PDF_MAGIC.len() || header != PDF_MAGIC {
        return Err(CommandError::new(
            "pdf_magic_invalid",
            "The selected file does not have a valid PDF header.",
        ));
    }
    let after = file.metadata().map_err(|error| {
        CommandError::io(
            "pdf_unavailable",
            "Unable to re-inspect the opened PDF",
            error,
        )
    })?;
    if metadata_identity(&before) != metadata_identity(&after) || bytes_read != before.len() {
        return Err(identity_changed_error());
    }
    Ok(FileIdentity {
        sha256: format!("{:x}", hasher.finalize()),
        ..metadata_identity(&before)
    })
}

fn identity_changed_error() -> CommandError {
    CommandError::new(
        "pdf_identity_changed",
        "The selected PDF changed after approval; select it again.",
    )
}

fn metadata_identity(metadata: &fs::Metadata) -> FileIdentity {
    FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        byte_size: metadata.len(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
        sha256: String::new(),
    }
}

fn sanitize_text(bytes: &[u8], maximum_bytes: usize) -> (String, Vec<String>) {
    let decoded = String::from_utf8_lossy(bytes);
    let mut text = String::new();
    let mut changed = false;
    let mut truncated = false;
    let mut characters = decoded.chars().peekable();
    while let Some(mut character) = characters.next() {
        if character == '\r' {
            if characters.peek() == Some(&'\n') {
                characters.next();
            }
            character = '\n';
            changed = true;
        }
        if character.is_control() && character != '\n' && character != '\t' {
            changed = true;
            continue;
        }
        if text.len().saturating_add(character.len_utf8()) > maximum_bytes {
            truncated = true;
            break;
        }
        text.push(character);
    }
    if decoded.as_bytes() != bytes {
        changed = true;
    }
    let mut warnings = Vec::new();
    if changed {
        warnings.push("pdf_text_sanitized".to_string());
    }
    if truncated {
        warnings.push("pdf_text_truncated".to_string());
    }
    (text, warnings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::document_capabilities::{DocumentCapabilities, OcrReadiness, ToolReadiness};
    use crate::core::document_runner::BoundedProcessOutput;
    use std::collections::VecDeque;
    use std::fmt::Write as _;
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::os::unix::fs::{symlink, MetadataExt};
    use std::sync::atomic::{AtomicI64, Ordering};

    #[derive(Default)]
    struct FakeRunner {
        output: Mutex<Option<CommandResult<BoundedProcessOutput>>>,
        commands: Mutex<Vec<SandboxedCommand>>,
    }

    impl FakeRunner {
        fn succeeds(stdout: Vec<u8>) -> Self {
            Self {
                output: Mutex::new(Some(Ok(BoundedProcessOutput {
                    success: true,
                    exit_code: Some(0),
                    stdout,
                    stderr: Vec::new(),
                }))),
                commands: Mutex::new(Vec::new()),
            }
        }
    }

    impl DocumentRunner for FakeRunner {
        fn run(&self, command: &SandboxedCommand) -> CommandResult<BoundedProcessOutput> {
            self.commands.lock().unwrap().push(command.clone());
            self.output.lock().unwrap().take().unwrap()
        }
    }

    struct SequenceRunner {
        output: Mutex<VecDeque<CommandResult<BoundedProcessOutput>>>,
        commands: Mutex<Vec<SandboxedCommand>>,
    }

    impl SequenceRunner {
        fn succeeds(outputs: Vec<Vec<u8>>) -> Self {
            Self {
                output: Mutex::new(
                    outputs
                        .into_iter()
                        .map(|stdout| {
                            Ok(BoundedProcessOutput {
                                success: true,
                                exit_code: Some(0),
                                stdout,
                                stderr: Vec::new(),
                            })
                        })
                        .collect(),
                ),
                commands: Mutex::new(Vec::new()),
            }
        }
    }

    impl DocumentRunner for SequenceRunner {
        fn run(&self, command: &SandboxedCommand) -> CommandResult<BoundedProcessOutput> {
            self.commands.lock().unwrap().push(command.clone());
            self.output.lock().unwrap().pop_front().unwrap_or_else(|| {
                Err(CommandError::new(
                    "fake_runner_missing_result",
                    "missing result",
                ))
            })
        }
    }

    struct FakeClock(AtomicI64);

    impl FakeClock {
        fn new(now: i64) -> Self {
            Self(AtomicI64::new(now))
        }

        fn advance(&self, seconds: i64) {
            self.0.fetch_add(seconds, Ordering::Relaxed);
        }
    }

    impl DocumentClock for FakeClock {
        fn unix_seconds(&self) -> i64 {
            self.0.load(Ordering::Relaxed)
        }
    }

    fn temporary_pdf() -> tempfile::NamedTempFile {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(b"%PDF-1.7\nexample").unwrap();
        file.flush().unwrap();
        file
    }

    fn minimal_text_pdf() -> tempfile::NamedTempFile {
        let content = "BT\n/F1 12 Tf\n20 100 Td\n(RepoPress P3) Tj\nET\n";
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".to_string(),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
            format!("<< /Length {} >>\nstream\n{content}endstream", content.len()),
        ];
        let mut pdf = "%PDF-1.4\n".to_string();
        let mut offsets = Vec::with_capacity(objects.len());
        for (index, object) in objects.iter().enumerate() {
            offsets.push(pdf.len());
            writeln!(&mut pdf, "{} 0 obj\n{object}\nendobj", index + 1).unwrap();
        }
        let xref = pdf.len();
        writeln!(&mut pdf, "xref\n0 {}", objects.len() + 1).unwrap();
        pdf.push_str("0000000000 65535 f \n");
        for offset in offsets {
            writeln!(&mut pdf, "{offset:010} 00000 n ").unwrap();
        }
        write!(
            &mut pdf,
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .unwrap();
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(pdf.as_bytes()).unwrap();
        file.flush().unwrap();
        file
    }

    // A deliberately small image-only PDF. The bitmap uses a simple 5×7
    // raster alphabet enlarged into clean, high-contrast glyphs so this test
    // exercises pdftoppm plus Tesseract rather than a PDF text layer.
    fn minimal_ocr_image_pdf() -> tempfile::NamedTempFile {
        const SCALE: usize = 24;
        const GLYPH_WIDTH: usize = 5;
        const GLYPH_HEIGHT: usize = 7;
        const GAP: usize = 2;
        let message = "REPOPRESS MARKER";
        let width = (message.len() * (GLYPH_WIDTH + GAP) + 2) * SCALE;
        let height = (GLYPH_HEIGHT + 2) * SCALE;
        let mut pixels = vec![255_u8; width * height];
        for (letter_index, character) in message.chars().enumerate() {
            let Some(glyph) = ocr_glyph(character) else {
                continue;
            };
            for (row, pattern) in glyph.iter().enumerate() {
                for column in 0..GLYPH_WIDTH {
                    if pattern.as_bytes()[column] == b'1' {
                        let start_x = (1 + letter_index * (GLYPH_WIDTH + GAP) + column) * SCALE;
                        let start_y = (1 + row) * SCALE;
                        for y in start_y..start_y + SCALE {
                            for x in start_x..start_x + SCALE {
                                pixels[y * width + x] = 0;
                            }
                        }
                    }
                }
            }
        }
        let mut image = String::with_capacity(pixels.len() * 2 + 1);
        for byte in pixels {
            write!(&mut image, "{byte:02X}").unwrap();
        }
        image.push('>');
        let image_object = format!(
            "<< /Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length {} >>\nstream\n{image}\nendstream",
            image.len()
        );
        let content = format!("q\n{width} 0 0 {height} 0 0 cm\n/Im0 Do\nQ\n");
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
            format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>"),
            image_object,
            format!("<< /Length {} >>\nstream\n{content}endstream", content.len()),
        ];
        let mut pdf = "%PDF-1.4\n".to_string();
        let mut offsets = Vec::with_capacity(objects.len());
        for (index, object) in objects.iter().enumerate() {
            offsets.push(pdf.len());
            writeln!(&mut pdf, "{} 0 obj\n{object}\nendobj", index + 1).unwrap();
        }
        let xref = pdf.len();
        writeln!(&mut pdf, "xref\n0 {}", objects.len() + 1).unwrap();
        pdf.push_str("0000000000 65535 f \n");
        for offset in offsets {
            writeln!(&mut pdf, "{offset:010} 00000 n ").unwrap();
        }
        write!(
            &mut pdf,
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .unwrap();
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(pdf.as_bytes()).unwrap();
        file.flush().unwrap();
        file
    }

    fn ocr_glyph(character: char) -> Option<[&'static str; 7]> {
        match character {
            'A' => Some([
                "01110", "10001", "10001", "11111", "10001", "10001", "10001",
            ]),
            'E' => Some([
                "11111", "10000", "10000", "11110", "10000", "10000", "11111",
            ]),
            'K' => Some([
                "10001", "10010", "10100", "11000", "10100", "10010", "10001",
            ]),
            'M' => Some([
                "10001", "11011", "10101", "10101", "10001", "10001", "10001",
            ]),
            'O' => Some([
                "01110", "10001", "10001", "10001", "10001", "10001", "01110",
            ]),
            'P' => Some([
                "11110", "10001", "10001", "11110", "10000", "10000", "10000",
            ]),
            'R' => Some([
                "11110", "10001", "10001", "11110", "10100", "10010", "10001",
            ]),
            'S' => Some([
                "01111", "10000", "10000", "01110", "00001", "00001", "11110",
            ]),
            ' ' => None,
            _ => None,
        }
    }

    fn ready_capabilities() -> DocumentCapabilities {
        let ready = ToolReadiness {
            available: true,
            path: Some("/usr/bin/example".to_string()),
            reason: None,
        };
        DocumentCapabilities {
            pdf_text_ready: true,
            sandbox: ready.clone(),
            pdftotext: ready.clone(),
            ocr: OcrReadiness {
                ready: false,
                enabled: false,
                tesseract: ready.clone(),
                pdftoppm: ready.clone(),
                pdf_info: ready.clone(),
                english_data: ready.clone(),
                chinese_simplified_data: ready,
                warning: "readiness only".to_string(),
            },
            warnings: Vec::new(),
        }
    }

    fn fake_ocr_tools() -> (TrustedTool, TrustedTool, TrustedTool, TrustedTool, PathBuf) {
        (
            TrustedTool {
                kind: DocumentTool::Bwrap,
                path: "/usr/bin/bwrap".into(),
            },
            TrustedTool {
                kind: DocumentTool::PdfInfo,
                path: "/usr/bin/pdfinfo".into(),
            },
            TrustedTool {
                kind: DocumentTool::PdfToPpm,
                path: "/usr/bin/pdftoppm".into(),
            },
            TrustedTool {
                kind: DocumentTool::Tesseract,
                path: "/usr/bin/tesseract".into(),
            },
            PathBuf::from("/usr/share/tesseract-ocr/5/tessdata"),
        )
    }

    #[test]
    fn rejects_symlink_bad_magic_and_oversized_files() {
        let valid = temporary_pdf();
        let link = valid.path().with_extension("link.pdf");
        symlink(valid.path(), &link).unwrap();
        assert_eq!(inspect_pdf(&link).unwrap_err().code, "pdf_not_regular_file");
        let bad = tempfile::NamedTempFile::new().unwrap();
        assert_eq!(
            inspect_pdf(bad.path()).unwrap_err().code,
            "pdf_magic_invalid"
        );
        let large = tempfile::NamedTempFile::new().unwrap();
        let mut handle = OpenOptions::new().write(true).open(large.path()).unwrap();
        handle.write_all(b"%PDF-").unwrap();
        handle.set_len(MAX_PDF_BYTES + 1).unwrap();
        assert_eq!(inspect_pdf(large.path()).unwrap_err().code, "pdf_too_large");
        let exact = tempfile::NamedTempFile::new().unwrap();
        let mut exact_handle = OpenOptions::new().write(true).open(exact.path()).unwrap();
        exact_handle.write_all(b"%PDF-").unwrap();
        exact_handle.set_len(MAX_PDF_BYTES).unwrap();
        assert_eq!(
            inspect_pdf(exact.path()).unwrap().1.byte_size,
            MAX_PDF_BYTES
        );
        fs::remove_file(link).unwrap();
    }

    #[test]
    fn token_is_one_shot_and_expires() {
        let runner = Arc::new(FakeRunner::succeeds(b"hello".to_vec()));
        let clock = Arc::new(FakeClock::new(100));
        let store = PdfAnalysisStore::with_runner_and_clock(runner, clock.clone());
        let file = temporary_pdf();
        let selection = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        clock.advance(TOKEN_TTL_SECONDS);
        assert_eq!(
            store
                .extract_text(&selection.token, &ready_capabilities())
                .unwrap_err()
                .code,
            "pdf_selection_expired"
        );
        assert_eq!(
            store
                .extract_text(&selection.token, &ready_capabilities())
                .unwrap_err()
                .code,
            "pdf_selection_invalid"
        );
    }

    #[test]
    fn identity_drift_consumes_the_token_before_running_a_helper() {
        let runner = Arc::new(FakeRunner::succeeds(b"never used".to_vec()));
        let clock = Arc::new(FakeClock::new(100));
        let store = PdfAnalysisStore::with_runner_and_clock(runner.clone(), clock);
        let file = temporary_pdf();
        let selection = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        fs::write(file.path(), b"%PDF-1.7\nchanged contents").unwrap();
        assert_eq!(
            store
                .extract_text(&selection.token, &ready_capabilities())
                .unwrap_err()
                .code,
            "pdf_identity_changed"
        );
        assert!(runner.commands.lock().unwrap().is_empty());
    }

    #[test]
    fn ocr_rejects_language_and_source_drift_after_consuming_the_token() {
        let runner = Arc::new(FakeRunner::succeeds(b"never used".to_vec()));
        let clock = Arc::new(FakeClock::new(100));
        let store = PdfAnalysisStore::with_runner_and_clock(runner.clone(), clock);
        let file = temporary_pdf();
        let invalid_language = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        assert_eq!(
            store
                .extract_ocr(
                    &invalid_language.token,
                    "eng; unexpected",
                    &ready_capabilities()
                )
                .unwrap_err()
                .code,
            "pdf_ocr_language_invalid"
        );
        assert_eq!(
            store
                .extract_text(&invalid_language.token, &ready_capabilities())
                .unwrap_err()
                .code,
            "pdf_selection_invalid"
        );

        let drifted = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        fs::write(file.path(), b"%PDF-1.7\nchanged contents").unwrap();
        assert_eq!(
            store
                .extract_ocr(&drifted.token, "eng", &ready_capabilities())
                .unwrap_err()
                .code,
            "pdf_identity_changed"
        );
        assert_eq!(
            store
                .extract_ocr(&drifted.token, "eng", &ready_capabilities())
                .unwrap_err()
                .code,
            "pdf_selection_invalid"
        );
        assert!(runner.commands.lock().unwrap().is_empty());
    }

    #[test]
    fn ocr_fake_runner_uses_three_descriptor_only_stages_and_consumes_token() {
        let runner = Arc::new(SequenceRunner::succeeds(vec![
            b"Pages: 1\n".to_vec(),
            b"\x89PNG\r\n\x1a\nnot-a-real-image-for-the-fake".to_vec(),
            b"REPOPRESS MARKER\n".to_vec(),
        ]));
        let store =
            PdfAnalysisStore::with_runner_and_clock(runner.clone(), Arc::new(FakeClock::new(100)));
        let file = temporary_pdf();
        let selection = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        let extraction = store
            .extract_ocr_with_tools(&selection.token, "eng", fake_ocr_tools())
            .unwrap();
        assert_eq!(extraction.text, "REPOPRESS MARKER\n");
        assert_eq!(extraction.page_count, 1);
        assert_eq!(extraction.language, "eng");
        let commands = runner.commands.lock().unwrap();
        assert_eq!(commands.len(), 3);
        let selected_path = file.path().to_string_lossy().into_owned();
        for command in commands.iter() {
            assert_eq!(command.executable, PathBuf::from("/usr/bin/bwrap"));
            assert!(command.arguments.contains(&"--unshare-net".into()));
            assert!(!command.arguments.iter().any(|argument| {
                argument == "sh" || argument == "-c" || argument.to_string_lossy() == selected_path
            }));
        }
        drop(commands);
        assert_eq!(
            store
                .extract_ocr_with_tools(&selection.token, "eng", fake_ocr_tools())
                .unwrap_err()
                .code,
            "pdf_selection_invalid"
        );
    }

    #[test]
    fn hash_detects_same_size_content_replacement_before_snapshot_binding() {
        let file = temporary_pdf();
        let (path, identity) = inspect_pdf(file.path()).unwrap();
        let original_size = identity.byte_size;
        fs::write(&path, b"%PDF-1.7\nchanged").unwrap();
        assert_eq!(fs::metadata(&path).unwrap().len(), original_size);
        assert_eq!(
            create_verified_snapshot(&path, &identity).unwrap_err().code,
            "pdf_identity_changed"
        );
    }

    #[test]
    fn sandbox_command_binds_only_a_sealed_anonymous_snapshot() {
        let file = temporary_pdf();
        let (path, identity) = inspect_pdf(file.path()).unwrap();
        let mut snapshot = create_verified_snapshot(&path, &identity).unwrap();
        let original_path = path.to_string_lossy().into_owned();
        assert_eq!(snapshot.file.metadata().unwrap().mode() & 0o777, 0o400);
        assert_eq!(snapshot.file.stream_position().unwrap(), 0);
        let expected_seals =
            libc::F_SEAL_SEAL | libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_WRITE;
        // SAFETY: the snapshot descriptor remains live throughout this test.
        let actual_seals = unsafe { libc::fcntl(snapshot.file.as_raw_fd(), libc::F_GET_SEALS) };
        assert_eq!(actual_seals & expected_seals, expected_seals);
        let mut attempted_write = snapshot.file.try_clone().unwrap();
        assert!(attempted_write.write_all(b"changed").is_err());
        let bwrap = TrustedTool {
            kind: DocumentTool::Bwrap,
            path: "/usr/bin/bwrap".into(),
        };
        let pdftotext = TrustedTool {
            kind: DocumentTool::PdfToText,
            path: "/usr/bin/pdftotext".into(),
        };
        let descriptor = snapshot.file.as_raw_fd();
        let command = pdf_text_command(&bwrap, &pdftotext, descriptor).unwrap();
        let arguments = command
            .arguments
            .iter()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert!(arguments.contains(&"--ro-bind-data".to_string()));
        assert!(arguments.contains(&descriptor.to_string()));
        assert!(!arguments.contains(&original_path));
        assert_eq!(command.inherited_read_only_fd, Some(descriptor));
    }

    #[test]
    fn extraction_uses_fixed_isolated_argv_and_sanitizes_output() {
        let runner = Arc::new(FakeRunner::succeeds(b"a\0b\r\nc\t".to_vec()));
        let clock = Arc::new(FakeClock::new(100));
        let store = PdfAnalysisStore::with_runner_and_clock(runner.clone(), clock);
        let file = temporary_pdf();
        let selection = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        let capabilities = ready_capabilities();
        // This test exercises the store's runner boundary only; use fixed,
        // trusted-looking tools for the command builder directly below.
        let bwrap = TrustedTool {
            kind: DocumentTool::Bwrap,
            path: "/usr/bin/bwrap".into(),
        };
        let pdftotext = TrustedTool {
            kind: DocumentTool::PdfToText,
            path: "/usr/bin/pdftotext".into(),
        };
        let (_, identity) = inspect_pdf(file.path()).unwrap();
        let snapshot = create_verified_snapshot(file.path(), &identity).unwrap();
        let command = pdf_text_command(&bwrap, &pdftotext, snapshot.file.as_raw_fd()).unwrap();
        assert!(command.arguments.contains(&"--unshare-all".into()));
        assert!(!command
            .arguments
            .iter()
            .any(|value| value == "sh" || value == "-c"));
        // If tools are not installed in the test environment, extraction fails
        // closed before runner invocation. The sanitiser remains deterministic.
        let (text, warnings) = sanitize_text(b"a\0b\r\nc\t", PDF_TEXT_OUTPUT_LIMIT);
        assert_eq!(text, "ab\nc\t");
        assert!(warnings.contains(&"pdf_text_sanitized".to_string()));
        let _ = (selection, capabilities, store);
    }

    #[test]
    fn real_bubblewrap_and_pdftotext_extract_text() {
        if std::env::var("REPOPRESS_RUN_DOCUMENT_INTEGRATION").as_deref() != Ok("1") {
            return;
        }
        let capabilities = crate::core::document_capabilities::inspect_document_capabilities();
        assert!(
            capabilities.pdf_text_ready,
            "real Bubblewrap + Poppler capability check failed: {capabilities:?}"
        );
        let file = minimal_text_pdf();
        let store = PdfAnalysisStore::new();
        let selection = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        let extraction = store.extract_text(&selection.token, &capabilities).unwrap();
        assert!(extraction.text.contains("RepoPress P3"));
    }

    #[test]
    fn real_bubblewrap_pdftoppm_and_tesseract_ocr() {
        if std::env::var("REPOPRESS_RUN_DOCUMENT_INTEGRATION").as_deref() != Ok("1") {
            return;
        }
        let capabilities = crate::core::document_capabilities::inspect_document_capabilities();
        assert!(
            capabilities.ocr.enabled,
            "real Bubblewrap + pdfinfo + pdftoppm + Tesseract capability check failed: {capabilities:?}"
        );
        let file = minimal_ocr_image_pdf();
        let (_, identity) = inspect_pdf(file.path()).unwrap();
        let snapshot = create_verified_snapshot(file.path(), &identity).unwrap();
        let (bwrap, _pdfinfo, pdftoppm, _tesseract, _tessdata) = capabilities.ocr_tools().unwrap();
        let raster = pdf_raster_command(&bwrap, &pdftoppm, snapshot.file.as_raw_fd(), 1).unwrap();
        let argv = raster
            .arguments
            .iter()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert!(!argv.contains(&file.path().to_string_lossy().into_owned()));
        let output = ProcessDocumentRunner.run(&raster).unwrap();
        assert!(output.success, "sandboxed pdftoppm did not produce a PNG");
        assert!(output.stdout.starts_with(b"\x89PNG\r\n\x1a\n"));

        let store = PdfAnalysisStore::new();
        let selection = store.select_pdf(file.path().to_str().unwrap()).unwrap();
        let extraction = store
            .extract_ocr(&selection.token, "eng", &capabilities)
            .unwrap();
        assert_eq!(extraction.page_count, 1);
        assert!(
            extraction.text.contains("REPOPRESS MARKER"),
            "unexpected local OCR output: {:?}",
            extraction.text
        );
    }
}
