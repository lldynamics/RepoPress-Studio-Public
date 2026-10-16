use super::{CommandError, CommandResult};
use std::ffi::{OsStr, OsString};
use std::io::{self, Read};
use std::os::fd::RawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread;
use std::time::{Duration, Instant};

pub const SELF_TEST_TIMEOUT: Duration = Duration::from_secs(4);
pub const PDF_TEXT_TIMEOUT: Duration = Duration::from_secs(20);
pub const SELF_TEST_OUTPUT_LIMIT: usize = 64 * 1024;
pub const PDF_TEXT_OUTPUT_LIMIT: usize = 16 * 1024 * 1024;
const STDERR_OUTPUT_LIMIT: usize = 64 * 1024;
const POLL_INTERVAL: Duration = Duration::from_millis(10);
/// Each helper gets a conservative per-process address-space ceiling. The
/// document text itself remains separately capped at 16 MiB on stdout.
#[cfg(target_os = "linux")]
pub const DOCUMENT_HELPER_ADDRESS_SPACE_BYTES: u64 = 512 * 1024 * 1024;
#[cfg(target_os = "linux")]
pub const DOCUMENT_HELPER_CPU_SECONDS: u64 = 25;
#[cfg(target_os = "linux")]
// RLIMIT_NPROC is charged per real UID rather than per sandbox. Keep enough
// headroom for a normal desktop session while still preventing an unbounded
// helper fork storm.
pub const DOCUMENT_HELPER_MAX_PROCESSES: u64 = 256;
#[cfg(target_os = "linux")]
pub const DOCUMENT_HELPER_MAX_OPEN_FILES: u64 = 64;
#[cfg(target_os = "linux")]
// Bubblewrap's compatible `--ro-bind-data` path copies the bounded PDF into
// its private root before mounting it read-only. Leave headroom above the
// 50 MiB PDF input ceiling while still bounding every helper-created file.
pub const DOCUMENT_HELPER_MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;
/// `bwrap --size` is documented by the locally available bwrap as a byte limit
/// for the next `--tmpfs` argument.
pub const DOCUMENT_SANDBOX_TMPFS_BYTES: u64 = 32 * 1024 * 1024;

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ResourceLimit {
    resource: libc::__rlimit_resource_t,
    value: libc::rlim_t,
}

#[cfg(target_os = "linux")]
fn document_helper_limits() -> [ResourceLimit; 6] {
    [
        ResourceLimit {
            resource: libc::RLIMIT_AS,
            value: DOCUMENT_HELPER_ADDRESS_SPACE_BYTES as libc::rlim_t,
        },
        ResourceLimit {
            resource: libc::RLIMIT_CPU,
            value: DOCUMENT_HELPER_CPU_SECONDS as libc::rlim_t,
        },
        ResourceLimit {
            resource: libc::RLIMIT_NPROC,
            value: DOCUMENT_HELPER_MAX_PROCESSES as libc::rlim_t,
        },
        ResourceLimit {
            resource: libc::RLIMIT_NOFILE,
            value: DOCUMENT_HELPER_MAX_OPEN_FILES as libc::rlim_t,
        },
        ResourceLimit {
            resource: libc::RLIMIT_FSIZE,
            value: DOCUMENT_HELPER_MAX_FILE_BYTES as libc::rlim_t,
        },
        ResourceLimit {
            resource: libc::RLIMIT_CORE,
            value: 0,
        },
    ]
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SandboxedCommand {
    pub executable: PathBuf,
    pub arguments: Vec<OsString>,
    pub timeout: Duration,
    pub stdout_limit: usize,
    pub stderr_limit: usize,
    /// A caller-owned descriptor that must survive only this child exec. The
    /// parent keeps FD_CLOEXEC set; `pre_exec` clears it in the forked child.
    pub inherited_read_only_fd: Option<RawFd>,
}

impl SandboxedCommand {
    pub fn new(
        executable: impl Into<PathBuf>,
        arguments: Vec<OsString>,
        timeout: Duration,
        stdout_limit: usize,
        stderr_limit: usize,
    ) -> CommandResult<Self> {
        let command = Self {
            executable: executable.into(),
            arguments,
            timeout,
            stdout_limit,
            stderr_limit,
            inherited_read_only_fd: None,
        };
        command.validate()?;
        Ok(command)
    }

    pub fn with_inherited_read_only_fd(mut self, descriptor: RawFd) -> CommandResult<Self> {
        if descriptor < 3 {
            return Err(CommandError::new(
                "document_runner_unsafe_descriptor",
                "Document input descriptors must not overlap standard I/O.",
            ));
        }
        self.inherited_read_only_fd = Some(descriptor);
        self.validate()?;
        Ok(self)
    }

    fn validate(&self) -> CommandResult<()> {
        if !self.executable.is_absolute() {
            return Err(CommandError::new(
                "document_runner_unsafe_command",
                "Document tools must use an absolute executable path.",
            ));
        }
        if self.timeout.is_zero() || self.stdout_limit == 0 || self.stderr_limit == 0 {
            return Err(CommandError::new(
                "document_runner_invalid_limits",
                "Document tool limits must be positive.",
            ));
        }
        if self.arguments.iter().any(|argument| contains_nul(argument)) {
            return Err(CommandError::new(
                "document_runner_unsafe_argument",
                "Document tool arguments cannot contain NUL bytes.",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BoundedProcessOutput {
    pub success: bool,
    pub exit_code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

pub trait DocumentRunner: Send + Sync {
    fn run(&self, command: &SandboxedCommand) -> CommandResult<BoundedProcessOutput>;
}

/// The sole production process launcher for document helpers. It deliberately
/// has no shell, clears inherited environment variables, bounds both streams,
/// and kills children on every timeout or output-limit path.
#[derive(Clone, Debug, Default)]
pub struct ProcessDocumentRunner;

impl DocumentRunner for ProcessDocumentRunner {
    fn run(&self, command: &SandboxedCommand) -> CommandResult<BoundedProcessOutput> {
        command.validate()?;

        let mut process = Command::new(&command.executable);
        process
            .args(&command.arguments)
            .current_dir("/")
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        configure_child_process(&mut process, command.inherited_read_only_fd);

        let mut child = process.spawn().map_err(|error| {
            CommandError::io(
                "document_runner_spawn_failed",
                "Unable to start the isolated document helper",
                error,
            )
        })?;

        let stdout = child.stdout.take().ok_or_else(|| {
            CommandError::new(
                "document_runner_output_unavailable",
                "Document helper stdout could not be captured.",
            )
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            CommandError::new(
                "document_runner_output_unavailable",
                "Document helper stderr could not be captured.",
            )
        })?;
        let exceeded = Arc::new(AtomicBool::new(false));
        let stdout_reader = spawn_limited_reader(stdout, command.stdout_limit, exceeded.clone());
        let stderr_reader = spawn_limited_reader(stderr, command.stderr_limit, exceeded.clone());

        let deadline = Instant::now() + command.timeout;
        let status = loop {
            if exceeded.load(Ordering::Relaxed) {
                terminate_child(&mut child);
                let _ = join_reader(stdout_reader);
                let _ = join_reader(stderr_reader);
                return Err(CommandError::new(
                    "document_runner_output_limit",
                    "The isolated document helper exceeded its output limit.",
                ));
            }
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if Instant::now() < deadline => thread::sleep(POLL_INTERVAL),
                Ok(None) => {
                    terminate_child(&mut child);
                    let _ = join_reader(stdout_reader);
                    let _ = join_reader(stderr_reader);
                    return Err(CommandError::new(
                        "document_runner_timeout",
                        "The isolated document helper exceeded its time limit.",
                    ));
                }
                Err(error) => {
                    terminate_child(&mut child);
                    let _ = join_reader(stdout_reader);
                    let _ = join_reader(stderr_reader);
                    return Err(CommandError::io(
                        "document_runner_wait_failed",
                        "Unable to wait for the isolated document helper",
                        error,
                    ));
                }
            }
        };

        let stdout = join_reader(stdout_reader)?;
        let stderr = join_reader(stderr_reader)?;
        if exceeded.load(Ordering::Relaxed) {
            return Err(CommandError::new(
                "document_runner_output_limit",
                "The isolated document helper exceeded its output limit.",
            ));
        }

        Ok(BoundedProcessOutput {
            success: status.success(),
            exit_code: status.code(),
            stdout,
            stderr,
        })
    }
}

/// Registers Linux setup for the post-fork child. `pre_exec` is only used for
/// fixed `setrlimit(2)` calls and, when requested, `fcntl(2)` on one validated
/// descriptor; no heap allocation, locking, logging, environment access, or
/// other non-async-signal-safe work is done in its closure. Returning a syscall
/// error makes `Command::spawn` fail closed.
#[cfg(target_os = "linux")]
fn configure_child_process(command: &mut Command, inherited_descriptor: Option<RawFd>) {
    use std::os::unix::process::CommandExt;

    let limits = document_helper_limits();
    // SAFETY: the closure only invokes async-signal-safe `setrlimit`/`fcntl`
    // syscalls using captured Copy values. It performs no Rust allocation or
    // synchronization after fork and before exec.
    unsafe {
        command.pre_exec(move || {
            apply_resource_limits_in_child(&limits)?;
            if let Some(descriptor) = inherited_descriptor {
                clear_close_on_exec_in_child(descriptor)?;
            }
            Ok(())
        });
    }
}

#[cfg(not(target_os = "linux"))]
fn configure_child_process(_command: &mut Command, _inherited_descriptor: Option<RawFd>) {}

#[cfg(target_os = "linux")]
fn apply_resource_limits_in_child(limits: &[ResourceLimit; 6]) -> io::Result<()> {
    for limit in limits {
        let resource_limit = libc::rlimit {
            rlim_cur: limit.value,
            rlim_max: limit.value,
        };
        // SAFETY: the pointer is valid for the call and `setrlimit` is the only
        // operation run in the pre-exec child closure.
        if unsafe { libc::setrlimit(limit.resource, &resource_limit) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn clear_close_on_exec_in_child(descriptor: RawFd) -> io::Result<()> {
    // SAFETY: fcntl is async-signal-safe. The descriptor is caller-owned and
    // remains open in the parent for the duration of Command::spawn.
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags & !libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn contains_nul(value: &OsStr) -> bool {
    value.to_string_lossy().as_bytes().contains(&0)
}

fn spawn_limited_reader<R>(
    file: R,
    limit: usize,
    exceeded: Arc<AtomicBool>,
) -> thread::JoinHandle<io::Result<Vec<u8>>>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut reader = file;
        let mut captured = Vec::with_capacity(limit.min(64 * 1024));
        let mut buffer = [0_u8; 8192];
        loop {
            let read = reader.read(&mut buffer)?;
            if read == 0 {
                return Ok(captured);
            }
            let remaining = limit.saturating_sub(captured.len());
            if read > remaining {
                captured.extend_from_slice(&buffer[..remaining]);
                exceeded.store(true, Ordering::Relaxed);
                return Ok(captured);
            }
            captured.extend_from_slice(&buffer[..read]);
        }
    })
}

fn join_reader(reader: thread::JoinHandle<io::Result<Vec<u8>>>) -> CommandResult<Vec<u8>> {
    reader
        .join()
        .map_err(|_| {
            CommandError::new(
                "document_runner_reader_failed",
                "The isolated document helper output reader stopped unexpectedly.",
            )
        })?
        .map_err(|error| {
            CommandError::io(
                "document_runner_reader_failed",
                "Unable to read isolated document helper output",
                error,
            )
        })
}

fn terminate_child(child: &mut Child) {
    // `kill` is intentionally best-effort: the subsequent `wait` reaps either
    // an already-exited process or the killed child, avoiding a zombie.
    let _ = child.kill();
    let _ = child.wait();
}

pub fn sandbox_self_test_command(bwrap: &Path) -> CommandResult<SandboxedCommand> {
    let mut arguments = sandbox_base_arguments();
    arguments.extend(["--".into(), "/usr/bin/true".into()]);
    SandboxedCommand::new(
        bwrap,
        arguments,
        SELF_TEST_TIMEOUT,
        SELF_TEST_OUTPUT_LIMIT,
        STDERR_OUTPUT_LIMIT,
    )
}

pub fn sandbox_base_arguments() -> Vec<OsString> {
    vec![
        "--unshare-all".into(),
        "--unshare-net".into(),
        "--die-with-parent".into(),
        "--new-session".into(),
        "--ro-bind".into(),
        "/usr".into(),
        "/usr".into(),
        "--ro-bind-try".into(),
        "/lib".into(),
        "/lib".into(),
        "--ro-bind-try".into(),
        "/lib64".into(),
        "/lib64".into(),
        "--proc".into(),
        "/proc".into(),
        "--dev".into(),
        "/dev".into(),
        "--size".into(),
        DOCUMENT_SANDBOX_TMPFS_BYTES.to_string().into(),
        "--tmpfs".into(),
        "/tmp".into(),
        "--chdir".into(),
        "/tmp".into(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStringExt;
    use std::sync::Mutex;

    #[derive(Default)]
    struct FakeRunner {
        calls: Mutex<Vec<SandboxedCommand>>,
        result: Mutex<Option<CommandResult<BoundedProcessOutput>>>,
    }

    impl FakeRunner {
        fn with_result(result: CommandResult<BoundedProcessOutput>) -> Self {
            Self {
                calls: Mutex::new(Vec::new()),
                result: Mutex::new(Some(result)),
            }
        }
    }

    impl DocumentRunner for FakeRunner {
        fn run(&self, command: &SandboxedCommand) -> CommandResult<BoundedProcessOutput> {
            self.calls.lock().unwrap().push(command.clone());
            self.result.lock().unwrap().take().unwrap_or_else(|| {
                Err(CommandError::new(
                    "fake_runner_missing_result",
                    "missing result",
                ))
            })
        }
    }

    #[test]
    fn rejects_non_absolute_and_nul_arguments_before_a_runner_can_see_them() {
        let non_absolute =
            SandboxedCommand::new("bwrap", vec![], Duration::from_secs(1), 1, 1).unwrap_err();
        assert_eq!(non_absolute.code, "document_runner_unsafe_command");

        let malicious = SandboxedCommand::new(
            "/usr/bin/bwrap",
            vec![OsString::from_vec(b"ok\0not-ok".to_vec())],
            Duration::from_secs(1),
            1,
            1,
        )
        .unwrap_err();
        assert_eq!(malicious.code, "document_runner_unsafe_argument");
        assert_eq!(
            sandbox_self_test_command(Path::new("/usr/bin/bwrap"))
                .unwrap()
                .with_inherited_read_only_fd(2)
                .unwrap_err()
                .code,
            "document_runner_unsafe_descriptor"
        );
    }

    #[test]
    fn fake_runner_receives_only_validated_fixed_command() {
        let runner = FakeRunner::with_result(Ok(BoundedProcessOutput {
            success: true,
            exit_code: Some(0),
            stdout: Vec::new(),
            stderr: Vec::new(),
        }));
        let command = sandbox_self_test_command(Path::new("/usr/bin/bwrap")).unwrap();
        runner.run(&command).unwrap();
        let call = runner.calls.lock().unwrap().pop().unwrap();
        assert_eq!(call.executable, PathBuf::from("/usr/bin/bwrap"));
        assert!(call.arguments.contains(&OsString::from("--unshare-all")));
        assert!(!call
            .arguments
            .iter()
            .any(|value| value == "sh" || value == "-c"));
    }

    #[test]
    fn sandbox_tmpfs_has_a_fixed_bwrap_size_before_mounting() {
        let arguments = sandbox_base_arguments();
        let size_index = arguments
            .iter()
            .position(|argument| argument == "--size")
            .unwrap();
        assert_eq!(
            arguments[size_index + 1],
            OsString::from(DOCUMENT_SANDBOX_TMPFS_BYTES.to_string())
        );
        assert_eq!(arguments[size_index + 2], OsString::from("--tmpfs"));
        assert_eq!(arguments[size_index + 3], OsString::from("/tmp"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn helper_resource_limits_are_fixed_and_cover_every_host_boundary() {
        let limits = document_helper_limits();
        assert_eq!(limits.len(), 6);
        assert_eq!(limits[0].resource, libc::RLIMIT_AS);
        assert_eq!(
            limits[0].value,
            DOCUMENT_HELPER_ADDRESS_SPACE_BYTES as libc::rlim_t
        );
        assert_eq!(limits[1].resource, libc::RLIMIT_CPU);
        assert_eq!(limits[1].value, DOCUMENT_HELPER_CPU_SECONDS as libc::rlim_t);
        assert_eq!(limits[2].resource, libc::RLIMIT_NPROC);
        assert_eq!(
            limits[2].value,
            DOCUMENT_HELPER_MAX_PROCESSES as libc::rlim_t
        );
        assert_eq!(limits[3].resource, libc::RLIMIT_NOFILE);
        assert_eq!(
            limits[3].value,
            DOCUMENT_HELPER_MAX_OPEN_FILES as libc::rlim_t
        );
        assert_eq!(limits[4].resource, libc::RLIMIT_FSIZE);
        assert_eq!(
            limits[4].value,
            DOCUMENT_HELPER_MAX_FILE_BYTES as libc::rlim_t
        );
        assert_eq!(limits[5].resource, libc::RLIMIT_CORE);
        assert_eq!(limits[5].value, 0);
    }
}
