use crate::core::{CommandError, CommandResult};
use serde::Serialize;
use std::fs;
use std::io::Write;
use std::path::Path;
use tempfile::Builder;

const MAX_EXPORT_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentExportResult {
    pub path: String,
    pub byte_size: u64,
}

/// Writes a user-confirmed document export outside the repository.
///
/// The renderer supplies a path returned by the native save dialog. The core still validates
/// the format, canonicalises the parent directory, refuses symlink targets, and replaces the
/// selected file atomically so a partial export is never presented as complete.
pub fn export_document(
    path: &str,
    contents: &str,
    format: &str,
) -> CommandResult<DocumentExportResult> {
    if contents.len() > MAX_EXPORT_BYTES {
        return Err(CommandError::new(
            "document_export_too_large",
            "Document export exceeds the 16 MiB safety limit.",
        ));
    }

    let requested = Path::new(path);
    if !requested.is_absolute() || requested.file_name().is_none() {
        return Err(CommandError::new(
            "invalid_document_export_path",
            "Document export path must be an absolute file path selected by the user.",
        ));
    }
    validate_extension(requested, format)?;

    let parent = requested.parent().ok_or_else(|| {
        CommandError::new(
            "invalid_document_export_path",
            "Document export path has no parent directory.",
        )
    })?;
    let parent = fs::canonicalize(parent).map_err(|error| {
        CommandError::io(
            "document_export_unavailable",
            "Unable to access the selected export directory",
            error,
        )
    })?;
    if !parent.is_dir() {
        return Err(CommandError::new(
            "document_export_unavailable",
            "The selected export directory is not a directory.",
        ));
    }
    let target = parent.join(requested.file_name().expect("file name checked above"));
    reject_unsafe_target(&target)?;

    let mut temporary = Builder::new()
        .prefix(".repopress-export-")
        .tempfile_in(&parent)
        .map_err(|error| {
            CommandError::io(
                "document_export_failed",
                "Unable to create the temporary export file",
                error,
            )
        })?;
    temporary.write_all(contents.as_bytes()).map_err(|error| {
        CommandError::io(
            "document_export_failed",
            "Unable to write the document export",
            error,
        )
    })?;
    temporary.as_file_mut().sync_all().map_err(|error| {
        CommandError::io(
            "document_export_failed",
            "Unable to flush the document export",
            error,
        )
    })?;
    temporary.persist(&target).map_err(|error| {
        CommandError::io(
            "document_export_failed",
            "Unable to atomically replace the selected export file",
            error.error,
        )
    })?;
    sync_directory(&parent)?;

    Ok(DocumentExportResult {
        path: path_to_string(&target)?,
        byte_size: contents.len() as u64,
    })
}

fn validate_extension(path: &Path, format: &str) -> CommandResult<()> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let valid = match format {
        "markdown" => matches!(extension.as_str(), "md" | "markdown"),
        "html" => matches!(extension.as_str(), "html" | "htm"),
        _ => {
            return Err(CommandError::new(
                "invalid_document_export_format",
                "Document export format must be markdown or html.",
            ))
        }
    };
    if !valid {
        return Err(CommandError::new(
            "invalid_document_export_extension",
            "The selected file extension does not match the document export format.",
        ));
    }
    Ok(())
}

fn reject_unsafe_target(path: &Path) -> CommandResult<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(CommandError::new(
                "unsafe_document_export_target",
                "The selected export target must be a regular file and cannot be a symbolic link.",
            ))
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CommandError::io(
            "document_export_unavailable",
            "Unable to inspect the selected export target",
            error,
        )),
    }
}

fn path_to_string(path: &Path) -> CommandResult<String> {
    path.to_str().map(str::to_owned).ok_or_else(|| {
        CommandError::new(
            "invalid_document_export_path",
            "Document export paths must be valid UTF-8.",
        )
    })
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> CommandResult<()> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            CommandError::io(
                "document_export_failed",
                "Unable to flush the export directory",
                error,
            )
        })
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_and_atomically_replaces_supported_exports() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("文章.md");
        fs::write(&target, "old").unwrap();

        let result = export_document(target.to_str().unwrap(), "# 新内容\n", "markdown").unwrap();

        assert_eq!(fs::read_to_string(&target).unwrap(), "# 新内容\n");
        assert_eq!(result.byte_size, "# 新内容\n".len() as u64);
        assert_eq!(std::path::PathBuf::from(result.path), target);
    }

    #[test]
    fn rejects_relative_paths_unknown_formats_and_mismatched_extensions() {
        assert_eq!(
            export_document("article.md", "body", "markdown")
                .unwrap_err()
                .code,
            "invalid_document_export_path"
        );
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("article.txt");
        assert_eq!(
            export_document(target.to_str().unwrap(), "body", "markdown")
                .unwrap_err()
                .code,
            "invalid_document_export_extension"
        );
        assert_eq!(
            export_document(target.to_str().unwrap(), "body", "pdf")
                .unwrap_err()
                .code,
            "invalid_document_export_format"
        );
    }

    #[test]
    fn bounds_export_size() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("large.html");
        let contents = "x".repeat(MAX_EXPORT_BYTES + 1);
        assert_eq!(
            export_document(target.to_str().unwrap(), &contents, "html")
                .unwrap_err()
                .code,
            "document_export_too_large"
        );
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symbolic_link_targets() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let real = directory.path().join("real.md");
        let link = directory.path().join("link.md");
        fs::write(&real, "safe").unwrap();
        symlink(&real, &link).unwrap();

        let error = export_document(link.to_str().unwrap(), "replace", "markdown").unwrap_err();
        assert_eq!(error.code, "unsafe_document_export_target");
        assert_eq!(fs::read_to_string(real).unwrap(), "safe");
    }
}
