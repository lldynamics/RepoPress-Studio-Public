use super::{CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Component, Path, PathBuf};

const MAX_CONFIG_FILES: usize = 256;
const MAX_CONFIG_BYTES: usize = 4 * 1024 * 1024;
const MAX_CONFIG_FILE_BYTES: usize = 1024 * 1024;
const CONFIG_FILES: &[&str] = &[
    "zola.toml",
    "hugo.toml",
    "hugo.yaml",
    "hugo.yml",
    "hugo.json",
    "config.toml",
    "config.yaml",
    "config.yml",
    "config.json",
];

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SitePreviewDocumentBinding {
    pub document_id: String,
    pub expected_sha256: String,
    pub revision: u64,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SitePreviewPlanRequest {
    pub document: Option<SitePreviewDocumentBinding>,
    pub article_path: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SitePreviewPlan {
    pub plan_id: String,
    pub site_kind: String,
    pub executable: String,
    pub expires_at_epoch_ms: u64,
    pub config_fingerprint: String,
    pub document: Option<SitePreviewDocumentBinding>,
    pub article_path: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct PreviewGuard {
    pub root: PathBuf,
    pub executable: PathBuf,
    pub fingerprint: String,
    pub config_fingerprint: String,
    pub document_path: Option<String>,
    pub document: Option<SitePreviewDocumentBinding>,
}

fn invalid() -> CommandError {
    CommandError::new(
        "preview_context_invalid",
        "Preview source cannot be safely verified.",
    )
}
fn stale() -> CommandError {
    CommandError::new(
        "preview_context_changed",
        "Preview source changed. Prepare a new preview plan.",
    )
}

fn identity(metadata: &fs::Metadata) -> CommandResult<String> {
    let modified = metadata
        .modified()
        .map_err(|_| invalid())?
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_nanos();
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(format!(
            "{}:{}:{}:{modified}",
            metadata.dev(),
            metadata.ino(),
            metadata.len()
        ))
    }
    #[cfg(not(unix))]
    {
        Ok(format!("{}:{modified}", metadata.len()))
    }
}
fn directory_identity(path: &Path) -> CommandResult<String> {
    let metadata = fs::symlink_metadata(path).map_err(|_| invalid())?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(invalid());
    }
    // Directory mtime changes when the generator creates an output directory.
    // Only object identity belongs to the repository/config containment guard.
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(format!("{}:{}", metadata.dev(), metadata.ino()))
    }
    #[cfg(not(unix))]
    {
        Ok(path.to_string_lossy().into_owned())
    }
}
fn open_regular(path: &Path) -> CommandResult<File> {
    let before = fs::symlink_metadata(path).map_err(|_| invalid())?;
    if !before.is_file() || before.file_type().is_symlink() {
        return Err(invalid());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(|_| invalid())?;
    if identity(&before)? != identity(&file.metadata().map_err(|_| invalid())?)? {
        return Err(stale());
    }
    Ok(file)
}
fn hash_file(path: &Path, maximum: usize) -> CommandResult<(String, usize)> {
    let mut file = open_regular(path)?;
    let before = file.metadata().map_err(|_| invalid())?;
    if before.len() > maximum as u64 {
        return Err(invalid());
    }
    let mut digest = Sha256::new();
    let mut total = 0usize;
    let mut buffer = [0u8; 8192];
    loop {
        let count = file.read(&mut buffer).map_err(|_| invalid())?;
        if count == 0 {
            break;
        }
        total = total.checked_add(count).ok_or_else(invalid)?;
        if total > maximum {
            return Err(invalid());
        }
        digest.update(&buffer[..count]);
    }
    if identity(&before)? != identity(&file.metadata().map_err(|_| invalid())?)?
        || identity(&before)? != identity(&fs::symlink_metadata(path).map_err(|_| invalid())?)?
    {
        return Err(stale());
    }
    Ok((
        format!("{}:{:x}", identity(&before)?, digest.finalize()),
        total,
    ))
}

fn document_file(root: &Path, relative: &str) -> CommandResult<PathBuf> {
    if relative.is_empty()
        || relative.contains('\\')
        || relative.chars().any(char::is_control)
        || Path::new(relative)
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(invalid());
    }
    let mut path = root.to_path_buf();
    let parts: Vec<_> = Path::new(relative).components().collect();
    for (index, part) in parts.iter().enumerate() {
        path.push(part.as_os_str());
        let metadata = fs::symlink_metadata(&path).map_err(|_| invalid())?;
        if metadata.file_type().is_symlink() || (index + 1 < parts.len() && !metadata.is_dir()) {
            return Err(invalid());
        }
    }
    if !path.starts_with(root) {
        return Err(invalid());
    }
    Ok(path)
}

pub(super) fn safe_article_path(value: Option<&str>) -> CommandResult<Option<String>> {
    let Some(value) = value else {
        return Ok(None);
    };
    if value.len() > 4096
        || value.is_empty()
        || value.contains(['?', '#', '\\'])
        || value.chars().any(char::is_control)
    {
        return Err(invalid());
    }
    let mut decoded = value.to_string();
    for _ in 0..32 {
        if decoded.contains('\\')
            || decoded.chars().any(char::is_control)
            || decoded.starts_with("//")
            || decoded.contains(':')
            || decoded
                .split('/')
                .any(|segment| segment == "." || segment == "..")
        {
            return Err(invalid());
        }
        let next = percent_encoding::percent_decode_str(&decoded)
            .decode_utf8()
            .map_err(|_| invalid())?
            .into_owned();
        if next == decoded {
            let path = if value.starts_with('/') {
                value.to_string()
            } else {
                format!("/{value}")
            };
            let parsed =
                url::Url::parse(&format!("http://127.0.0.1:1234{path}")).map_err(|_| invalid())?;
            if parsed.host_str() != Some("127.0.0.1") || parsed.port() != Some(1234) {
                return Err(invalid());
            }
            return Ok(Some(parsed.path().to_string()));
        }
        decoded = next;
    }
    Err(invalid())
}

impl PreviewGuard {
    pub fn capture(
        root: &Path,
        executable: &Path,
        document_path: Option<&str>,
        document: Option<&SitePreviewDocumentBinding>,
    ) -> CommandResult<Self> {
        let root_identity = directory_identity(root)?;
        if root.canonicalize().map_err(|_| invalid())? != root {
            return Err(invalid());
        }
        let mut config = Sha256::new();
        let mut count = 0;
        let mut bytes = 0;
        for name in CONFIG_FILES {
            config.update(name.as_bytes());
            match fs::symlink_metadata(root.join(name)) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    config.update(b"absent")
                }
                Err(_) => return Err(invalid()),
                Ok(_) => {
                    let (hash, size) = hash_file(&root.join(name), MAX_CONFIG_FILE_BYTES)?;
                    count += 1;
                    bytes += size;
                    config.update(hash.as_bytes());
                }
            }
        }
        fn walk(
            path: &Path,
            depth: usize,
            count: &mut usize,
            bytes: &mut usize,
            digest: &mut Sha256,
        ) -> CommandResult<()> {
            if depth > 8 {
                return Err(invalid());
            }
            let before = identity(&fs::symlink_metadata(path).map_err(|_| invalid())?)?;
            directory_identity(path)?;
            digest.update(before.as_bytes());
            let mut entries: Vec<_> = fs::read_dir(path)
                .map_err(|_| invalid())?
                .take(MAX_CONFIG_FILES + 1)
                .collect::<Result<_, _>>()
                .map_err(|_| invalid())?;
            if entries.len() > MAX_CONFIG_FILES {
                return Err(invalid());
            }
            entries.sort_by_key(|entry| entry.file_name());
            for entry in entries {
                *count += 1;
                if *count > MAX_CONFIG_FILES || *bytes > MAX_CONFIG_BYTES {
                    return Err(invalid());
                }
                digest.update((entry.file_name().as_encoded_bytes().len() as u64).to_le_bytes());
                digest.update(entry.file_name().as_encoded_bytes());
                let kind = entry.file_type().map_err(|_| invalid())?;
                if kind.is_symlink() {
                    return Err(invalid());
                }
                if kind.is_dir() {
                    digest.update(b"dir");
                    walk(&entry.path(), depth + 1, count, bytes, digest)?;
                } else if kind.is_file() {
                    let (hash, size) = hash_file(&entry.path(), MAX_CONFIG_FILE_BYTES)?;
                    *bytes += size;
                    digest.update(hash.as_bytes());
                } else {
                    return Err(invalid());
                }
            }
            if before != identity(&fs::symlink_metadata(path).map_err(|_| invalid())?)? {
                return Err(stale());
            }
            Ok(())
        }
        config.update(b"config/");
        match fs::symlink_metadata(root.join("config")) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => config.update(b"absent"),
            Err(_) => return Err(invalid()),
            Ok(_) => walk(&root.join("config"), 0, &mut count, &mut bytes, &mut config)?,
        }
        if count > MAX_CONFIG_FILES || bytes > MAX_CONFIG_BYTES {
            return Err(invalid());
        }
        let config_fingerprint = format!("{:x}", config.finalize());
        let mut fingerprint = Sha256::new();
        fingerprint.update(root_identity.as_bytes());
        fingerprint.update(config_fingerprint.as_bytes());
        let (executable_hash, _) = hash_file(executable, 256 * 1024 * 1024)?;
        fingerprint.update(executable.as_os_str().as_encoded_bytes());
        fingerprint.update(executable_hash.as_bytes());
        match (document_path, document) {
            (Some(path), Some(binding)) => {
                let file = document_file(root, path)?;
                let (hash, _) = hash_file(&file, 4 * 1024 * 1024)?;
                let digest = hash.rsplit(':').next().ok_or_else(invalid)?;
                if digest != binding.expected_sha256 {
                    return Err(stale());
                }
                fingerprint.update(path.as_bytes());
                fingerprint.update(hash.as_bytes());
                fingerprint.update(serde_json::to_vec(binding).map_err(|_| invalid())?);
            }
            (None, None) => {}
            _ => return Err(invalid()),
        }
        if directory_identity(root)? != root_identity {
            return Err(stale());
        }
        Ok(Self {
            root: root.to_path_buf(),
            executable: executable.to_path_buf(),
            fingerprint: format!("{:x}", fingerprint.finalize()),
            config_fingerprint,
            document_path: document_path.map(str::to_owned),
            document: document.cloned(),
        })
    }
    pub fn revalidate(&self) -> CommandResult<()> {
        let next = Self::capture(
            &self.root,
            &self.executable,
            self.document_path.as_deref(),
            self.document.as_ref(),
        )?;
        if next != *self {
            return Err(stale());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let executable = root.join("tool");
        fs::write(&executable, b"fixed tool").unwrap();
        (dir, root, executable)
    }
    #[test]
    fn detects_config_add_modify_delete_and_nested_changes() {
        let (_dir, root, executable) = fixture();
        let initial = PreviewGuard::capture(&root, &executable, None, None).unwrap();
        fs::write(root.join("hugo.toml"), b"title='a'").unwrap();
        assert!(initial.revalidate().is_err());
        let existing = PreviewGuard::capture(&root, &executable, None, None).unwrap();
        fs::write(root.join("hugo.toml"), b"title='b'").unwrap();
        assert!(existing.revalidate().is_err());
        let existing = PreviewGuard::capture(&root, &executable, None, None).unwrap();
        fs::remove_file(root.join("hugo.toml")).unwrap();
        assert!(existing.revalidate().is_err());
        fs::create_dir(root.join("config")).unwrap();
        fs::create_dir(root.join("config/_default")).unwrap();
        fs::write(root.join("config/_default/config.toml"), b"language='zh'").unwrap();
        let nested = PreviewGuard::capture(&root, &executable, None, None).unwrap();
        fs::write(root.join("config/_default/extra.toml"), b"title='new'").unwrap();
        assert!(nested.revalidate().is_err());
    }
    #[test]
    fn rejects_document_disk_drift_and_retains_binding() {
        let (_dir, root, executable) = fixture();
        fs::create_dir(root.join("content")).unwrap();
        let text = b"# Article";
        fs::write(root.join("content/a.md"), text).unwrap();
        let binding = SitePreviewDocumentBinding {
            document_id: "doc".into(),
            expected_sha256: format!("{:x}", Sha256::digest(text)),
            revision: 1,
        };
        let guard = PreviewGuard::capture(&root, &executable, Some("content/a.md"), Some(&binding))
            .unwrap();
        assert_eq!(guard.document, Some(binding));
        assert!(guard.revalidate().is_ok());
        fs::write(root.join("content/a.md"), b"# Changed").unwrap();
        assert!(guard.revalidate().is_err());
    }
    #[test]
    fn rejects_oversized_config_and_runtime_drift() {
        let (_dir, root, executable) = fixture();
        let guard = PreviewGuard::capture(&root, &executable, None, None).unwrap();
        fs::write(&executable, b"replaced tool").unwrap();
        assert!(guard.revalidate().is_err());
        fs::write(
            root.join("hugo.toml"),
            vec![b'x'; MAX_CONFIG_FILE_BYTES + 1],
        )
        .unwrap();
        assert!(PreviewGuard::capture(&root, &executable, None, None).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn rejects_config_and_document_symlinks() {
        let (_dir, root, executable) = fixture();
        std::os::unix::fs::symlink(&executable, root.join("hugo.toml")).unwrap();
        assert!(PreviewGuard::capture(&root, &executable, None, None).is_err());
        assert!(document_file(&root, "hugo.toml").is_err());
    }
    #[test]
    fn constrains_article_paths_before_url_normalization() {
        for path in [
            "//evil/a",
            "../a",
            "/%252e%252e/a",
            "/%0d%0aHost:evil",
            "/a\\b",
            "https://evil/a",
            "/a?secret=1",
        ] {
            assert!(safe_article_path(Some(path)).is_err(), "{path}");
        }
        assert_eq!(
            safe_article_path(Some("/中文/带 空格/")).unwrap(),
            Some("/%E4%B8%AD%E6%96%87/%E5%B8%A6%20%E7%A9%BA%E6%A0%BC/".into())
        );
    }
    #[test]
    fn rejects_config_file_count_aggregate_and_depth_limits() {
        let (_dir, root, executable) = fixture();
        fs::create_dir(root.join("config")).unwrap();
        for index in 0..257 {
            fs::write(root.join(format!("config/{index}.toml")), b"x").unwrap();
        }
        assert!(PreviewGuard::capture(&root, &executable, None, None).is_err());
        let (_dir, root, executable) = fixture();
        fs::create_dir(root.join("config")).unwrap();
        for index in 0..5 {
            fs::write(
                root.join(format!("config/{index}.toml")),
                vec![b'x'; MAX_CONFIG_FILE_BYTES],
            )
            .unwrap();
        }
        assert!(PreviewGuard::capture(&root, &executable, None, None).is_err());
        let (_dir, root, executable) = fixture();
        let mut path = root.join("config");
        fs::create_dir(&path).unwrap();
        for _ in 0..9 {
            path = path.join("nested");
            fs::create_dir(&path).unwrap();
        }
        assert!(PreviewGuard::capture(&root, &executable, None, None).is_err());
    }
    #[test]
    fn oversized_runtime_is_rejected_without_reading_the_sparse_file() {
        let (_dir, root, executable) = fixture();
        File::options()
            .write(true)
            .open(&executable)
            .unwrap()
            .set_len(256 * 1024 * 1024 + 1)
            .unwrap();
        assert!(PreviewGuard::capture(&root, &executable, None, None).is_err());
    }
}
