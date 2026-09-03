use super::{CommandError, CommandResult, GitChangedFile, GitStatusSnapshot};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::process::{Command, ExitStatus, Stdio};
use std::time::Duration;
use wait_timeout::ChildExt;

const GIT_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_GIT_OUTPUT_BYTES: u64 = 8 * 1024 * 1024;

struct GitOutput {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

pub fn read_git_status(root: &Path) -> CommandResult<GitStatusSnapshot> {
    if !root.join(".git").exists() {
        return Ok(GitStatusSnapshot {
            available: false,
            branch: None,
            upstream: None,
            ahead: 0,
            behind: 0,
            detached: false,
            changed_files: Vec::new(),
            warnings: vec!["not_git_repository".to_string()],
        });
    }

    let status_output = run_git(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    ensure_success(&status_output, "git_status_failed")?;
    let changed_files = parse_porcelain_v1_z(&status_output.stdout)?;

    let branch_output = run_git(root, &["symbolic-ref", "--short", "-q", "HEAD"])?;
    let branch = if branch_output.status.success() {
        trimmed_utf8(&branch_output.stdout, "invalid_git_branch")?
    } else {
        None
    };
    let detached = branch.is_none();

    let upstream_output = run_git(
        root,
        &[
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    )?;
    let upstream = if upstream_output.status.success() {
        trimmed_utf8(&upstream_output.stdout, "invalid_git_upstream")?
    } else {
        None
    };

    let (ahead, behind) = if upstream.is_some() {
        let counts = run_git(
            root,
            &["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
        )?;
        ensure_success(&counts, "git_ahead_behind_failed")?;
        parse_ahead_behind(&counts.stdout)?
    } else {
        (0, 0)
    };

    Ok(GitStatusSnapshot {
        available: true,
        branch,
        upstream,
        ahead,
        behind,
        detached,
        changed_files,
        warnings: Vec::new(),
    })
}

fn run_git(root: &Path, arguments: &[&str]) -> CommandResult<GitOutput> {
    let mut stdout_file = tempfile::tempfile().map_err(|error| {
        CommandError::io(
            "git_output_unavailable",
            "Unable to create Git output storage",
            error,
        )
    })?;
    let mut stderr_file = tempfile::tempfile().map_err(|error| {
        CommandError::io(
            "git_output_unavailable",
            "Unable to create Git error storage",
            error,
        )
    })?;
    let stdout_writer = stdout_file.try_clone().map_err(|error| {
        CommandError::io(
            "git_output_unavailable",
            "Unable to prepare Git output storage",
            error,
        )
    })?;
    let stderr_writer = stderr_file.try_clone().map_err(|error| {
        CommandError::io(
            "git_output_unavailable",
            "Unable to prepare Git error storage",
            error,
        )
    })?;

    let mut child = Command::new("git")
        .arg("-c")
        .arg("core.fsmonitor=false")
        .arg("-C")
        .arg(root)
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout_writer))
        .stderr(Stdio::from(stderr_writer))
        .spawn()
        .map_err(|error| {
            CommandError::io(
                "git_unavailable",
                "Unable to start the Git executable",
                error,
            )
        })?;

    let status = match child
        .wait_timeout(GIT_TIMEOUT)
        .map_err(|error| CommandError::io("git_wait_failed", "Unable to wait for Git", error))?
    {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(CommandError::new(
                "git_timeout",
                format!(
                    "Git did not finish within {} seconds.",
                    GIT_TIMEOUT.as_secs()
                ),
            ));
        }
    };

    Ok(GitOutput {
        status,
        stdout: read_limited(&mut stdout_file)?,
        stderr: read_limited(&mut stderr_file)?,
    })
}

fn read_limited(file: &mut File) -> CommandResult<Vec<u8>> {
    file.seek(SeekFrom::Start(0)).map_err(|error| {
        CommandError::io(
            "git_output_unavailable",
            "Unable to rewind Git output",
            error,
        )
    })?;
    let mut bytes = Vec::new();
    file.take(MAX_GIT_OUTPUT_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            CommandError::io("git_output_unavailable", "Unable to read Git output", error)
        })?;
    if bytes.len() as u64 > MAX_GIT_OUTPUT_BYTES {
        return Err(CommandError::new(
            "git_output_too_large",
            format!("Git produced more than {MAX_GIT_OUTPUT_BYTES} bytes of output."),
        ));
    }
    Ok(bytes)
}

fn ensure_success(output: &GitOutput, code: &str) -> CommandResult<()> {
    if output.status.success() {
        return Ok(());
    }
    let message = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(CommandError::new(
        code,
        if message.is_empty() {
            "Git command failed without an error message.".to_string()
        } else {
            message
        },
    ))
}

fn trimmed_utf8(bytes: &[u8], code: &str) -> CommandResult<Option<String>> {
    let value = std::str::from_utf8(bytes)
        .map_err(|_| CommandError::new(code, "Git returned non-UTF-8 text."))?
        .trim();
    Ok((!value.is_empty()).then(|| value.to_string()))
}

fn parse_ahead_behind(bytes: &[u8]) -> CommandResult<(u32, u32)> {
    let text = std::str::from_utf8(bytes).map_err(|_| {
        CommandError::new(
            "invalid_git_ahead_behind",
            "Git returned non-UTF-8 ahead/behind counts.",
        )
    })?;
    let mut parts = text.split_whitespace();
    let ahead = parts
        .next()
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| {
            CommandError::new(
                "invalid_git_ahead_behind",
                "Git returned an invalid ahead count.",
            )
        })?;
    let behind = parts
        .next()
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| {
            CommandError::new(
                "invalid_git_ahead_behind",
                "Git returned an invalid behind count.",
            )
        })?;
    if parts.next().is_some() {
        return Err(CommandError::new(
            "invalid_git_ahead_behind",
            "Git returned unexpected ahead/behind fields.",
        ));
    }
    Ok((ahead, behind))
}

fn parse_porcelain_v1_z(bytes: &[u8]) -> CommandResult<Vec<GitChangedFile>> {
    let mut fields = bytes.split(|byte| *byte == 0).peekable();
    let mut files = Vec::new();
    while let Some(field) = fields.next() {
        if field.is_empty() {
            continue;
        }
        if field.len() < 4 || field[2] != b' ' {
            return Err(CommandError::new(
                "invalid_git_status",
                "Git returned an invalid porcelain status entry.",
            ));
        }
        let status = std::str::from_utf8(&field[..2])
            .map_err(|_| CommandError::new("invalid_git_status", "Git status was not UTF-8."))?
            .to_string();
        let relative_path = std::str::from_utf8(&field[3..])
            .map_err(|_| {
                CommandError::new("invalid_git_path_encoding", "Git path was not valid UTF-8.")
            })?
            .to_string();
        let source_path = if status.contains('R') || status.contains('C') {
            let source = fields.next().ok_or_else(|| {
                CommandError::new(
                    "invalid_git_status",
                    "Git rename status did not include the source path.",
                )
            })?;
            Some(
                std::str::from_utf8(source)
                    .map_err(|_| {
                        CommandError::new(
                            "invalid_git_path_encoding",
                            "Git rename source path was not valid UTF-8.",
                        )
                    })?
                    .to_string(),
            )
        } else {
            None
        };
        files.push(GitChangedFile {
            status,
            relative_path,
            source_path,
        });
    }
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn parses_rename_destination_and_source_without_arrow_heuristics() {
        let files = parse_porcelain_v1_z(b"R  content/new -> title.md\0content/old.md\0")
            .expect("parse rename");
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].status, "R ");
        assert_eq!(files[0].relative_path, "content/new -> title.md");
        assert_eq!(files[0].source_path.as_deref(), Some("content/old.md"));
    }

    #[test]
    fn reads_branch_and_modified_file_without_mutating_repository() {
        let temporary = tempfile::tempdir().expect("temporary repository");
        run_fixture_git(temporary.path(), &["init", "-q", "-b", "main"]);
        run_fixture_git(
            temporary.path(),
            &["config", "user.name", "RepoPress Tests"],
        );
        run_fixture_git(
            temporary.path(),
            &["config", "user.email", "tests@repopress.invalid"],
        );
        fs::write(temporary.path().join("article.md"), "before\n").expect("fixture article");
        run_fixture_git(temporary.path(), &["add", "article.md"]);
        run_fixture_git(temporary.path(), &["commit", "-q", "-m", "fixture"]);
        fs::write(temporary.path().join("article.md"), "after\n").expect("edit article");

        let snapshot = read_git_status(temporary.path()).expect("read Git status");
        assert!(snapshot.available);
        assert_eq!(snapshot.branch.as_deref(), Some("main"));
        assert!(!snapshot.detached);
        assert_eq!(snapshot.changed_files.len(), 1);
        assert_eq!(snapshot.changed_files[0].relative_path, "article.md");
        assert_eq!(snapshot.changed_files[0].status, " M");
    }

    fn run_fixture_git(root: &Path, arguments: &[&str]) {
        let status = Command::new("git")
            .arg("-c")
            .arg("core.fsmonitor=false")
            .arg("-C")
            .arg(root)
            .args(arguments)
            .env("GIT_TERMINAL_PROMPT", "0")
            .status()
            .expect("start fixture Git");
        assert!(
            status.success(),
            "fixture Git command failed: {arguments:?}"
        );
    }
}
