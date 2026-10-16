//! Validate Git's metadata indirection before invoking Git on a selected worktree.
use super::{CommandError, CommandResult};
use std::os::unix::fs::OpenOptionsExt;
use std::{
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

fn invalid() -> CommandError {
    CommandError::new(
        "git_repository_root_invalid",
        "Repository Git metadata does not belong to this worktree.",
    )
}

fn directory(path: &Path) -> CommandResult<()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| invalid())?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(invalid());
    }
    Ok(())
}

fn bounded_text(path: &Path, limit: u64) -> CommandResult<String> {
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| invalid())?;
    let metadata = file.metadata().map_err(|_| invalid())?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(invalid());
    }
    let mut text = String::new();
    Read::by_ref(&mut file)
        .take(limit + 1)
        .read_to_string(&mut text)
        .map_err(|_| invalid())?;
    if text.len() as u64 > limit {
        return Err(invalid());
    }
    Ok(text)
}

fn pointer(path: &Path) -> CommandResult<String> {
    let text = bounded_text(path, 8192)?;
    let text = text.strip_suffix('\n').unwrap_or(&text);
    let text = text.strip_suffix('\r').unwrap_or(text);
    if text.is_empty() || text.chars().any(char::is_control) {
        return Err(invalid());
    }
    Ok(text.to_owned())
}

fn resolve(base: &Path, value: &str) -> CommandResult<PathBuf> {
    base.join(value).canonicalize().map_err(|_| invalid())
}

fn validate_writable_metadata(admin: &Path) -> CommandResult<()> {
    let mut pending = Vec::new();
    for entry in fs::read_dir(admin).map_err(|_| invalid())? {
        let entry = entry.map_err(|_| invalid())?;
        let kind = entry.file_type().map_err(|_| invalid())?;
        // Hooks are disabled by every runner; a user's shared hooks link never
        // grants Git authority to write another repository's administrative data.
        if kind.is_symlink() && entry.file_name() != "hooks" {
            return Err(invalid());
        }
        if matches!(
            entry.file_name().to_str(),
            Some("objects" | "refs" | "logs")
        ) {
            if !kind.is_dir() {
                return Err(invalid());
            }
            pending.push((entry.path(), 0));
        }
    }
    let mut remaining = 100_000usize;
    while let Some((path, depth)) = pending.pop() {
        if depth > 64 {
            return Err(invalid());
        }
        for entry in fs::read_dir(path).map_err(|_| invalid())? {
            remaining = remaining.checked_sub(1).ok_or_else(invalid)?;
            let entry = entry.map_err(|_| invalid())?;
            let kind = entry.file_type().map_err(|_| invalid())?;
            if kind.is_symlink() || (!kind.is_file() && !kind.is_dir()) {
                return Err(invalid());
            }
            if kind.is_dir() {
                pending.push((entry.path(), depth + 1));
            }
        }
    }
    Ok(())
}

fn configured_worktree(admin: &Path) -> CommandResult<PathBuf> {
    // Use Git's own quoting/escape parser, with bounded captured input rather
    // than opening the supplied repository or honoring config include files.
    let config = bounded_text(&admin.join("config"), 64 * 1024)?;
    let mut output = tempfile::tempfile().map_err(|_| invalid())?;
    let errors = tempfile::tempfile().map_err(|_| invalid())?;
    let mut child = Command::new("/usr/bin/git")
        .args([
            "config",
            "--file",
            "-",
            "--no-includes",
            "--null",
            "--get",
            "core.worktree",
        ])
        .current_dir("/")
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::piped())
        .stdout(output.try_clone().map_err(|_| invalid())?)
        .stderr(errors)
        .spawn()
        .map_err(|_| invalid())?;
    let write_result = child
        .stdin
        .take()
        .ok_or_else(invalid)?
        .write_all(config.as_bytes());
    if write_result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(invalid());
    }
    let started = Instant::now();
    loop {
        match child.try_wait().map_err(|_| invalid())? {
            Some(status) if status.success() => break,
            Some(_) => return Err(invalid()),
            None if started.elapsed() > Duration::from_secs(2) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(invalid());
            }
            None => std::thread::sleep(Duration::from_millis(5)),
        }
    }
    output.seek(SeekFrom::Start(0)).map_err(|_| invalid())?;
    let mut value = String::new();
    output
        .take(8193)
        .read_to_string(&mut value)
        .map_err(|_| invalid())?;
    if value.len() > 8192 {
        return Err(invalid());
    }
    let value = value.strip_suffix('\0').ok_or_else(invalid)?;
    if value.is_empty() || value.chars().any(char::is_control) {
        return Err(invalid());
    }
    resolve(admin, value)
}

pub(super) fn validate_git_metadata(root: &Path) -> CommandResult<()> {
    directory(root)?;
    if root.canonicalize().map_err(|_| invalid())? != root {
        return Err(invalid());
    }
    let entry = root.join(".git");
    let metadata = fs::symlink_metadata(&entry).map_err(|_| invalid())?;
    if metadata.file_type().is_symlink() {
        return Err(invalid());
    }
    if metadata.is_dir() {
        // A normal repository owns its common directory locally. Only verified
        // linked-worktree entries below may select a different common directory.
        if fs::symlink_metadata(entry.join("commondir")).is_ok() {
            return Err(invalid());
        }
        return validate_writable_metadata(&entry);
    }
    if !metadata.is_file() {
        return Err(invalid());
    }
    let value = pointer(&entry)?;
    let path = value
        .strip_prefix("gitdir: ")
        .filter(|value| !value.is_empty())
        .ok_or_else(invalid)?;
    let admin = resolve(root, path)?;
    directory(&root.join(path))?;
    directory(&admin)?;
    validate_writable_metadata(&admin)?;
    if !admin
        .join("commondir")
        .try_exists()
        .map_err(|_| invalid())?
    {
        // Submodules (and explicitly bound separate gitdirs) record the
        // checkout path in their administrative config instead of a backlink.
        if configured_worktree(&admin)? != root {
            return Err(invalid());
        }
        directory(&admin.join("objects"))?;
        directory(&admin.join("refs"))?;
        return Ok(());
    }
    let common = resolve(&admin, &pointer(&admin.join("commondir"))?)?;
    directory(&common)?;
    validate_writable_metadata(&common)?;
    let worktrees = common.join("worktrees");
    directory(&worktrees)?;
    if admin.parent() != Some(worktrees.as_path())
        || worktrees.canonicalize().map_err(|_| invalid())? != worktrees
    {
        return Err(invalid());
    }
    let backlink = resolve(&admin, &pointer(&admin.join("gitdir"))?)?;
    if backlink != entry {
        return Err(invalid());
    }
    directory(&common.join("objects"))?;
    directory(&common.join("refs"))?;
    Ok(())
}

/// Internal publish isolation uses fresh bare directories without a `.git`
/// entry. Public worktree validators separately require that entry to exist.
pub(super) fn validate_git_metadata_if_present(root: &Path) -> CommandResult<()> {
    match fs::symlink_metadata(root.join(".git")) {
        Ok(_) => validate_git_metadata(root),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn linked() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("linked");
        let common = temp.path().join("repository/.git");
        let admin = common.join("worktrees/linked");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(&admin).unwrap();
        fs::create_dir_all(common.join("objects")).unwrap();
        fs::create_dir_all(common.join("refs")).unwrap();
        fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
        fs::write(admin.join("commondir"), "../..\n").unwrap();
        fs::write(
            admin.join("gitdir"),
            format!("{}\n", root.join(".git").display()),
        )
        .unwrap();
        (temp, root, admin)
    }

    #[test]
    fn rejects_aliases_to_another_linked_worktree() {
        let (_temp, root, admin) = linked();
        assert!(validate_git_metadata(&root).is_ok());
        let forged = root.parent().unwrap().join("forged");
        fs::create_dir(&forged).unwrap();
        fs::write(
            forged.join(".git"),
            format!("gitdir: {}\n", admin.display()),
        )
        .unwrap();
        assert!(validate_git_metadata(&forged).is_err());
    }

    #[test]
    fn rejects_normal_directory_writable_subtree_links() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("supplied");
        let victim = temp.path().join("victim");
        fs::create_dir_all(root.join(".git")).unwrap();
        fs::create_dir_all(&victim).unwrap();
        for name in ["objects", "refs", "logs", "index"] {
            symlink(&victim, root.join(".git").join(name)).unwrap();
            assert!(validate_git_metadata(&root).is_err(), "accepted {name}");
            fs::remove_file(root.join(".git").join(name)).unwrap();
        }
        fs::create_dir_all(root.join(".git/refs/heads")).unwrap();
        symlink(&victim, root.join(".git/refs/heads/redirected")).unwrap();
        assert!(validate_git_metadata(&root).is_err());
    }

    #[test]
    fn rejects_wrong_common_directory_and_malformed_pointers() {
        let (_temp, root, admin) = linked();
        fs::write(admin.join("commondir"), "../../..\n").unwrap();
        assert!(validate_git_metadata(&root).is_err());
        fs::write(admin.join("commondir"), "../..\n").unwrap();
        for text in ["gitdir: /tmp/missing\nextra".to_owned(), "x".repeat(8193)] {
            fs::write(root.join(".git"), text).unwrap();
            assert!(validate_git_metadata(&root).is_err());
        }
    }

    #[test]
    fn rejects_symlink_backlink_and_normal_directory_commondir() {
        let (_temp, root, admin) = linked();
        let saved = admin.join("gitdir-saved");
        fs::rename(admin.join("gitdir"), &saved).unwrap();
        symlink(saved, admin.join("gitdir")).unwrap();
        assert!(validate_git_metadata(&root).is_err());
        let normal = root.parent().unwrap().join("normal");
        fs::create_dir_all(normal.join(".git")).unwrap();
        assert!(validate_git_metadata(&normal).is_ok());
        fs::write(normal.join(".git/commondir"), "../../repository/.git\n").unwrap();
        assert!(validate_git_metadata(&normal).is_err());
    }
}
