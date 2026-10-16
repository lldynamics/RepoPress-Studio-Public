use super::{CommandError, CommandResult, GitChangedFile, GitStatusSnapshot};
use serde::Serialize;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::Duration;

const GIT_TIMEOUT: Duration = Duration::from_secs(10);
const GIT_PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_GIT_OUTPUT_BYTES: u64 = 8 * 1024 * 1024;
const MAX_DIFF_OUTPUT_BYTES: usize = 512 * 1024;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitDiffSnapshot {
    pub relative_path: String,
    pub staged_patch: String,
    pub working_tree_patch: String,
    pub binary: bool,
    pub truncated: bool,
    pub warnings: Vec<String>,
}

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

    let status_output = run_git_at(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    ensure_success(&status_output, "git_status_failed")?;
    let changed_files = parse_porcelain_v1_z(&status_output.stdout)?;

    let branch_output = run_git_at(root, &["symbolic-ref", "--short", "-q", "HEAD"])?;
    let branch = if branch_output.status.success() {
        trimmed_utf8(&branch_output.stdout, "invalid_git_branch")?
    } else {
        None
    };
    let detached = branch.is_none();

    let upstream_output = run_git_at(
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
        let counts = run_git_at(
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

/// Reads the staged and working-tree patch for one safe, repository-relative path.
/// The returned patch text is bounded and never invokes Git's external diff or text
/// conversion hooks.
pub fn read_git_diff(root: &Path, relative_path: &str) -> CommandResult<GitDiffSnapshot> {
    validate_git_repository_root(root)?;
    let relative = validate_git_relative_path(relative_path)?;
    let staged = run_git_at(
        root,
        &[
            "diff",
            "--cached",
            "--no-ext-diff",
            "--no-textconv",
            "--unified=3",
            "--",
            relative_path,
        ],
    )?;
    ensure_diff_success(&staged)?;
    let working_tree = run_git_at(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--unified=3",
            "--",
            relative_path,
        ],
    )?;
    ensure_diff_success(&working_tree)?;

    let (staged_patch, staged_truncated) = bounded_diff_text(&staged.stdout, MAX_DIFF_OUTPUT_BYTES);
    let remaining = MAX_DIFF_OUTPUT_BYTES.saturating_sub(staged_patch.len());
    let (working_tree_patch, working_tree_truncated) =
        bounded_diff_text(&working_tree.stdout, remaining);
    let binary = diff_mentions_binary(&staged.stdout) || diff_mentions_binary(&working_tree.stdout);
    let mut warnings = Vec::new();
    if is_untracked_path(root, relative_path)? {
        // Do not read untracked content here. In particular, this avoids following a
        // symlink that changed between validation and inspection.
        let candidate = root.join(&relative);
        if candidate
            .symlink_metadata()
            .map(|metadata| metadata.file_type().is_symlink())
            .unwrap_or(false)
        {
            warnings.push("untracked_symlink_not_previewed".to_string());
        } else {
            warnings.push("untracked_file_has_no_git_patch".to_string());
        }
    }
    if staged_truncated || working_tree_truncated {
        warnings.push("diff_output_truncated".to_string());
    }

    Ok(GitDiffSnapshot {
        relative_path: relative_path.to_string(),
        staged_patch,
        working_tree_patch,
        binary,
        truncated: staged_truncated || working_tree_truncated,
        warnings,
    })
}

fn validate_git_repository_root(root: &Path) -> CommandResult<()> {
    let metadata = std::fs::symlink_metadata(root).map_err(|_| {
        CommandError::new(
            "git_repository_root_invalid",
            "Repository root is unavailable for Git diff.",
        )
    })?;
    let canonical = root.canonicalize().map_err(|_| {
        CommandError::new(
            "git_repository_root_invalid",
            "Repository root is unavailable for Git diff.",
        )
    })?;
    let git_metadata = root.join(".git").symlink_metadata().ok();
    if metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || canonical != root
        || !matches!(git_metadata, Some(ref metadata) if !metadata.file_type().is_symlink() && (metadata.is_dir() || metadata.is_file()))
    {
        return Err(CommandError::new(
            "git_repository_root_invalid",
            "Repository root is unavailable for Git diff.",
        ));
    }
    super::git_boundary::validate_git_metadata(root)
}

/// Probes only the executable. It never receives a repository path or mutates repository state.
pub fn git_is_available() -> bool {
    git_availability_from_probe(run_git(&["--version"]).map(|output| output.status.success()))
}

fn git_availability_from_probe(probe: CommandResult<bool>) -> bool {
    probe.unwrap_or(false)
}

fn run_git_at(root: &Path, arguments: &[&str]) -> CommandResult<GitOutput> {
    run_git_with_root(arguments, Some(root), GIT_TIMEOUT)
}

fn run_git(arguments: &[&str]) -> CommandResult<GitOutput> {
    run_git_with_root(arguments, None, GIT_PROBE_TIMEOUT)
}

fn run_git_with_root(
    arguments: &[&str],
    root: Option<&Path>,
    timeout: Duration,
) -> CommandResult<GitOutput> {
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

    let mut command = Command::new("git");
    // Treat every caller-provided path as a literal. `--` only terminates
    // option parsing; without this global flag a filename such as `[1].md`
    // would still be interpreted as Git pathspec syntax.
    command
        .arg("--literal-pathspecs")
        .arg("-c")
        .arg("core.fsmonitor=false");
    if let Some(root) = root {
        super::git_boundary::validate_git_metadata(root)?;
        command.arg("-C").arg(root);
    }
    let mut child = command
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout_writer))
        .stderr(Stdio::from(stderr_writer))
        .spawn()
        .map_err(|_| CommandError::new("git_unavailable", "Git executable is unavailable."))?;

    let status = match wait_for_git(&mut child, timeout)? {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(CommandError::new(
                "git_timeout",
                format!("Git did not finish within {} seconds.", timeout.as_secs()),
            ));
        }
    };

    Ok(GitOutput {
        status,
        stdout: read_limited(&mut stdout_file)?,
        stderr: read_limited(&mut stderr_file)?,
    })
}

fn wait_for_git(
    child: &mut std::process::Child,
    timeout: Duration,
) -> CommandResult<Option<ExitStatus>> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(Some(status)),
            Ok(None) if std::time::Instant::now() >= deadline => return Ok(None),
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(error) => {
                return Err(CommandError::io(
                    "git_wait_failed",
                    "Unable to wait for Git",
                    error,
                ))
            }
        }
    }
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

fn ensure_diff_success(output: &GitOutput) -> CommandResult<()> {
    if output.status.success() {
        Ok(())
    } else {
        // Git stderr can contain local paths, hook details, or environment-derived
        // diagnostics. Diff consumers only need a stable failure classification.
        Err(CommandError::new(
            "git_diff_failed",
            "Unable to read Git diff.",
        ))
    }
}

fn validate_git_relative_path(value: &str) -> CommandResult<PathBuf> {
    if value.is_empty()
        || value.contains('\0')
        || value.contains('\\')
        || value.starts_with('/')
        || value.split('/').any(str::is_empty)
    {
        return Err(CommandError::new(
            "invalid_git_diff_path",
            "Path must be a portable repository-relative path.",
        ));
    }
    // Drive prefixes are not portable repository-relative paths, including on Unix.
    if value.as_bytes().get(1) == Some(&b':') {
        return Err(CommandError::new(
            "invalid_git_diff_path",
            "Path must be a portable repository-relative path.",
        ));
    }
    let path = Path::new(value);
    if path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::CurDir
                    | Component::ParentDir
                    | Component::RootDir
                    | Component::Prefix(_)
            ) || matches!(component, Component::Normal(part) if part.eq_ignore_ascii_case(".git"))
        })
    {
        return Err(CommandError::new(
            "invalid_git_diff_path",
            "Path must be a portable repository-relative path.",
        ));
    }
    Ok(path.to_path_buf())
}

fn bounded_diff_text(bytes: &[u8], limit: usize) -> (String, bool) {
    if bytes.len() <= limit {
        return (String::from_utf8_lossy(bytes).into_owned(), false);
    }
    // Lossy decoding makes arbitrary Git output valid UTF-8; popping whole chars
    // afterwards also bounds the encoded response if replacement chars expanded it.
    let mut text = String::from_utf8_lossy(&bytes[..limit]).into_owned();
    while text.len() > limit {
        let _ = text.pop();
    }
    (text, true)
}

fn diff_mentions_binary(bytes: &[u8]) -> bool {
    bytes
        .windows(b"Binary files ".len())
        .any(|window| window == b"Binary files ")
        || bytes
            .windows(b"GIT binary patch".len())
            .any(|window| window == b"GIT binary patch")
}

fn is_untracked_path(root: &Path, relative_path: &str) -> CommandResult<bool> {
    let output = run_git_at(
        root,
        &[
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            relative_path,
        ],
    )?;
    ensure_diff_success(&output)?;
    Ok(output
        .stdout
        .split(|byte| *byte == 0)
        .any(|entry| entry == relative_path.as_bytes()))
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
    use std::sync::Mutex;

    static GIT_FIXTURE_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn reports_git_available_from_a_successful_probe_without_running_git() {
        assert!(git_availability_from_probe(Ok(true)));
    }

    #[test]
    fn reports_git_unavailable_when_the_probe_cannot_start() {
        let error = CommandError::new("git_unavailable", "Git executable is unavailable.");

        assert!(!git_availability_from_probe(Err(error)));
        assert!(!git_availability_from_probe(Ok(false)));
    }

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
        let _guard = GIT_FIXTURE_LOCK.lock().expect("fixture lock");
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

    #[test]
    fn rejects_non_portable_diff_paths() {
        for value in [
            "",
            "../article.md",
            "./article.md",
            ".git/config",
            "a\\b.md",
            "/tmp/a",
            "C:/a",
            "a//b",
        ] {
            assert!(
                validate_git_relative_path(value).is_err(),
                "accepted {value:?}"
            );
        }
        assert_eq!(
            validate_git_relative_path("posts/文章.md")
                .expect("portable path")
                .to_string_lossy(),
            "posts/文章.md"
        );
    }

    #[test]
    fn requires_a_canonical_root_that_owns_git_metadata() {
        let temporary = tempfile::tempdir().expect("temporary root");
        fs::create_dir(temporary.path().join(".git")).expect("git metadata");
        let canonical = temporary.path().canonicalize().expect("canonical root");
        assert!(validate_git_repository_root(&canonical).is_ok());
        assert!(validate_git_repository_root(Path::new(".")).is_err());
        let without_git = tempfile::tempdir().expect("non repository");
        assert!(validate_git_repository_root(without_git.path()).is_err());
    }

    #[test]
    fn reads_staged_and_working_tree_patches_for_a_unicode_path() {
        let _guard = GIT_FIXTURE_LOCK.lock().expect("fixture lock");
        let temporary = fixture_repository();
        let path = "文章.md";
        fs::write(temporary.path().join(path), "before\n").expect("fixture article");
        run_fixture_git(temporary.path(), &["add", path]);
        run_fixture_git(temporary.path(), &["commit", "-q", "-m", "fixture"]);
        fs::write(temporary.path().join(path), "staged\n").expect("staged edit");
        run_fixture_git(temporary.path(), &["add", path]);
        fs::write(temporary.path().join(path), "working\n").expect("working edit");

        let snapshot = read_git_diff(temporary.path(), path).expect("read diff");
        assert_eq!(snapshot.relative_path, path);
        assert!(snapshot.staged_patch.contains("-before"));
        assert!(snapshot.staged_patch.contains("+staged"));
        assert!(snapshot.working_tree_patch.contains("-staged"));
        assert!(snapshot.working_tree_patch.contains("+working"));
        assert!(!snapshot.binary);
        assert!(!snapshot.truncated);
    }

    #[test]
    fn treats_diff_paths_as_literal_git_paths() {
        let _guard = GIT_FIXTURE_LOCK.lock().expect("fixture lock");
        let temporary = fixture_repository();
        let path = "topic[1].md";
        fs::write(temporary.path().join(path), "before\n").expect("fixture article");
        run_fixture_git(temporary.path(), &["add", path]);
        run_fixture_git(temporary.path(), &["commit", "-q", "-m", "fixture"]);
        fs::write(temporary.path().join(path), "after\n").expect("edit article");

        let snapshot = read_git_diff(temporary.path(), path).expect("read literal diff");
        assert!(snapshot.working_tree_patch.contains("-before"));
        assert!(snapshot.working_tree_patch.contains("+after"));
    }

    #[test]
    fn warns_for_untracked_file_and_marks_tracked_binary_diff() {
        let _guard = GIT_FIXTURE_LOCK.lock().expect("fixture lock");
        let temporary = fixture_repository();
        fs::write(temporary.path().join("untracked.md"), "new\n").expect("untracked file");
        let untracked = read_git_diff(temporary.path(), "untracked.md").expect("untracked diff");
        assert!(untracked.staged_patch.is_empty());
        assert!(untracked.working_tree_patch.is_empty());
        assert!(untracked
            .warnings
            .iter()
            .any(|warning| warning == "untracked_file_has_no_git_patch"));

        fs::write(temporary.path().join("image.bin"), [0_u8, 1, 2]).expect("binary fixture");
        run_fixture_git(temporary.path(), &["add", "image.bin"]);
        run_fixture_git(temporary.path(), &["commit", "-q", "-m", "binary fixture"]);
        fs::write(temporary.path().join("image.bin"), [0_u8, 4, 5]).expect("binary edit");
        let binary = read_git_diff(temporary.path(), "image.bin").expect("binary diff");
        assert!(binary.binary);
    }

    #[test]
    fn truncates_combined_diff_output_at_a_utf8_boundary() {
        let _guard = GIT_FIXTURE_LOCK.lock().expect("fixture lock");
        let temporary = fixture_repository();
        let path = temporary.path().join("large.md");
        fs::write(&path, "before\n").expect("fixture article");
        run_fixture_git(temporary.path(), &["add", "large.md"]);
        run_fixture_git(temporary.path(), &["commit", "-q", "-m", "large fixture"]);
        fs::write(&path, format!("{}\n", "界".repeat(MAX_DIFF_OUTPUT_BYTES))).expect("large edit");

        let snapshot = read_git_diff(temporary.path(), "large.md").expect("large diff");
        assert!(snapshot.truncated);
        assert!(
            snapshot.staged_patch.len() + snapshot.working_tree_patch.len()
                <= MAX_DIFF_OUTPUT_BYTES
        );
        assert!(std::str::from_utf8(snapshot.working_tree_patch.as_bytes()).is_ok());
    }

    fn fixture_repository() -> tempfile::TempDir {
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
        temporary
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
