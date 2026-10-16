//! Repository credentials.  Secrets deliberately have no `Debug` or `Serialize`
//! implementation: callers can observe where a credential lives, never its value.

use super::{CommandError, CommandResult};
use serde::Serialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

const SECRET_TOOL_PATHS: &[&str] = &["/usr/bin/secret-tool", "/usr/local/bin/secret-tool"];
const SECRET_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_SECRET_BYTES: usize = 16 * 1024;
const MAX_ATTRIBUTE_BYTES: usize = 256;

#[derive(Clone, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialScope {
    provider: String,
    host: String,
    account: String,
    username: String,
}

impl CredentialScope {
    pub fn new(provider: &str, host: &str, account: &str, username: &str) -> CommandResult<Self> {
        validate_provider(provider)?;
        validate_host(host)?;
        validate_attribute(account, "credential_account_invalid")?;
        validate_attribute(username, "credential_username_invalid")?;
        Ok(Self {
            provider: provider.to_string(),
            host: host.to_ascii_lowercase(),
            account: account.to_string(),
            username: username.to_string(),
        })
    }
}

/// Secret text is intentionally opaque and cannot be formatted or serialized.
pub struct RepositoryCredential {
    token: String,
}

impl RepositoryCredential {
    pub fn from_token(token: String) -> CommandResult<Self> {
        if token.is_empty()
            || token.len() > MAX_SECRET_BYTES
            || token.contains('\0')
            || token.contains('\n')
        {
            return Err(CommandError::new(
                "credential_token_invalid",
                "Credential token is invalid.",
            ));
        }
        Ok(Self { token })
    }

    pub(crate) fn token(&self) -> &str {
        &self.token
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CredentialStorage {
    SecretService,
    ProcessMemory,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialStorageStatus {
    pub storage: CredentialStorage,
    pub session_only: bool,
    pub warning: Option<String>,
}

struct StoredCredential {
    token: RepositoryCredential,
    storage: CredentialStorage,
}

/// A Secret Service-backed store with a deliberately visible process-memory fallback.
/// The fallback is never persisted and is lost when RepoPress exits.
#[derive(Default)]
pub struct RepositoryCredentialStore {
    memory: Mutex<HashMap<CredentialScope, StoredCredential>>,
}

impl RepositoryCredentialStore {
    pub fn save(
        &self,
        scope: CredentialScope,
        credential: RepositoryCredential,
    ) -> CommandResult<CredentialStorageStatus> {
        let status = match trusted_secret_tool() {
            Some(path) => match secret_store(path, &scope, credential.token()) {
                Ok(()) => CredentialStorageStatus {
                    storage: CredentialStorage::SecretService,
                    session_only: false,
                    warning: None,
                },
                Err(_) => session_fallback_status(),
            },
            None => session_fallback_status(),
        };
        // Keep a session copy after a Secret Service save as well.  This avoids
        // another daemon round trip and preserves a usable session if it locks.
        let mut memory = self.memory.lock().map_err(|_| unavailable())?;
        memory.insert(
            scope,
            StoredCredential {
                token: credential,
                storage: status.storage,
            },
        );
        Ok(status)
    }

    pub fn lookup(&self, scope: &CredentialScope) -> CommandResult<Option<RepositoryCredential>> {
        if let Some(path) = trusted_secret_tool() {
            if let Ok(Some(token)) = secret_lookup(path, scope) {
                return RepositoryCredential::from_token(token).map(Some);
            }
        }
        let memory = self.memory.lock().map_err(|_| unavailable())?;
        Ok(memory.get(scope).map(|stored| RepositoryCredential {
            token: stored.token.token.clone(),
        }))
    }

    pub fn status(
        &self,
        scope: &CredentialScope,
    ) -> CommandResult<Option<CredentialStorageStatus>> {
        let memory = self.memory.lock().map_err(|_| unavailable())?;
        Ok(memory.get(scope).map(|stored| CredentialStorageStatus {
            storage: stored.storage,
            session_only: stored.storage == CredentialStorage::ProcessMemory,
            warning: (stored.storage == CredentialStorage::ProcessMemory)
                .then(|| "secret_service_unavailable_session_only".to_string()),
        }))
    }

    /// Removes an exact credential scope. Persistent deletion must succeed before
    /// the in-memory copy is forgotten, so the UI never reports a false deletion.
    pub fn delete(&self, scope: &CredentialScope) -> CommandResult<()> {
        let storage = {
            let memory = self.memory.lock().map_err(|_| unavailable())?;
            memory.get(scope).map(|stored| stored.storage)
        }
        .ok_or_else(|| {
            CommandError::new(
                "credential_not_found",
                "The repository credential is unavailable.",
            )
        })?;

        if storage == CredentialStorage::SecretService {
            let path = trusted_secret_tool().ok_or_else(|| {
                CommandError::new(
                    "secret_service_unavailable",
                    "Secret Service is unavailable; the persistent credential was not deleted.",
                )
            })?;
            secret_clear(path, scope)?;
        }
        self.memory.lock().map_err(|_| unavailable())?.remove(scope);
        Ok(())
    }
}

pub fn secret_service_available() -> bool {
    trusted_secret_tool().is_some() && trusted_secret_environment().is_some()
}

fn session_fallback_status() -> CredentialStorageStatus {
    CredentialStorageStatus {
        storage: CredentialStorage::ProcessMemory,
        session_only: true,
        warning: Some("secret_service_unavailable_session_only".to_string()),
    }
}

fn unavailable() -> CommandError {
    CommandError::new(
        "credential_store_unavailable",
        "Credential state is temporarily unavailable.",
    )
}

fn trusted_secret_tool() -> Option<&'static str> {
    SECRET_TOOL_PATHS.iter().copied().find(|path| {
        let Ok(metadata) = std::fs::symlink_metadata(path) else {
            return false;
        };
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return false;
        }
        #[cfg(target_os = "linux")]
        {
            use std::os::unix::fs::MetadataExt;
            return metadata.uid() == 0 && metadata.mode() & 0o022 == 0;
        }
        #[allow(unreachable_code)]
        false
    })
}

fn secret_store(path: &str, scope: &CredentialScope, token: &str) -> CommandResult<()> {
    let output = run_secret_tool(
        path,
        &[
            "store",
            "--label=RepoPress repository credential",
            "service",
            "repopress",
            "provider",
            &scope.provider,
            "host",
            &scope.host,
            "account",
            &scope.account,
            "username",
            &scope.username,
        ],
        Some(token),
    )?;
    if output.success {
        Ok(())
    } else {
        // Do not expose daemon diagnostics: some implementations echo request data.
        Err(CommandError::new(
            "secret_service_failed",
            "Secret Service could not store the credential.",
        ))
    }
}

fn secret_lookup(path: &str, scope: &CredentialScope) -> CommandResult<Option<String>> {
    let output = run_secret_tool(
        path,
        &[
            "lookup",
            "service",
            "repopress",
            "provider",
            &scope.provider,
            "host",
            &scope.host,
            "account",
            &scope.account,
            "username",
            &scope.username,
        ],
        None,
    )?;
    if !output.success {
        return Err(CommandError::new(
            "secret_service_failed",
            "Secret Service could not read the credential.",
        ));
    }
    let value = String::from_utf8(output.stdout).map_err(|_| {
        CommandError::new(
            "secret_service_invalid",
            "Secret Service returned invalid credential data.",
        )
    })?;
    let token = value.trim_end_matches(['\r', '\n']);
    Ok((!token.is_empty()).then(|| token.to_string()))
}

fn secret_clear(path: &str, scope: &CredentialScope) -> CommandResult<()> {
    let output = run_secret_tool(
        path,
        &[
            "clear",
            "service",
            "repopress",
            "provider",
            &scope.provider,
            "host",
            &scope.host,
            "account",
            &scope.account,
            "username",
            &scope.username,
        ],
        None,
    )?;
    if output.success {
        Ok(())
    } else {
        Err(CommandError::new(
            "secret_service_delete_failed",
            "Secret Service could not delete the credential.",
        ))
    }
}

struct SecretOutput {
    success: bool,
    stdout: Vec<u8>,
}

fn run_secret_tool(path: &str, args: &[&str], input: Option<&str>) -> CommandResult<SecretOutput> {
    let secret_environment = trusted_secret_environment().ok_or_else(|| {
        CommandError::new(
            "secret_service_unavailable",
            "A trusted Secret Service session bus is unavailable.",
        )
    })?;
    let mut command = Command::new(path);
    command
        .args(args)
        .env_clear()
        .env("LC_ALL", "C")
        .env("DBUS_SESSION_BUS_ADDRESS", &secret_environment.dbus_address)
        .env("XDG_RUNTIME_DIR", &secret_environment.runtime_directory)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = command.spawn().map_err(|_| {
        CommandError::new(
            "secret_service_unavailable",
            "Secret Service is unavailable.",
        )
    })?;
    let input_writer = if let Some(token) = input {
        let mut stdin = child.stdin.take().ok_or_else(|| {
            CommandError::new(
                "secret_service_failed",
                "Secret Service input is unavailable.",
            )
        })?;
        let input = token.as_bytes().to_vec();
        Some(thread::spawn(move || -> CommandResult<()> {
            stdin.write_all(&input).map_err(|_| {
                CommandError::new("secret_service_failed", "Secret Service input failed.")
            })?;
            stdin.write_all(b"\n").map_err(|_| {
                CommandError::new("secret_service_failed", "Secret Service input failed.")
            })
        }))
    } else {
        None
    };
    let mut stdout = child.stdout.take().ok_or_else(|| {
        CommandError::new(
            "secret_service_failed",
            "Secret Service output is unavailable.",
        )
    })?;
    let reader = thread::spawn(move || read_bounded(&mut stdout, MAX_SECRET_BYTES));
    let deadline = Instant::now() + SECRET_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                if let Some(writer) = input_writer {
                    let _ = writer.join();
                }
                return Err(CommandError::new(
                    "secret_service_timeout",
                    "Secret Service did not respond in time.",
                ));
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => {
                return Err(CommandError::new(
                    "secret_service_failed",
                    "Secret Service wait failed.",
                ))
            }
        }
    };
    if let Some(writer) = input_writer {
        writer.join().map_err(|_| {
            CommandError::new("secret_service_failed", "Secret Service input failed.")
        })??;
    }
    let stdout = reader.join().map_err(|_| {
        CommandError::new("secret_service_failed", "Secret Service output failed.")
    })??;
    Ok(SecretOutput {
        success: status.success(),
        stdout,
    })
}

struct SecretEnvironment {
    dbus_address: String,
    runtime_directory: PathBuf,
}

#[cfg(target_os = "linux")]
fn trusted_secret_environment() -> Option<SecretEnvironment> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};

    let effective_uid = std::fs::read_to_string("/proc/self/status")
        .ok()?
        .lines()
        .find_map(|line| {
            line.strip_prefix("Uid:")
                .and_then(|value| value.split_whitespace().nth(1))
                .and_then(|value| value.parse::<u32>().ok())
        })?;
    let runtime_directory = PathBuf::from(format!("/run/user/{effective_uid}"));
    let runtime_metadata = std::fs::symlink_metadata(&runtime_directory).ok()?;
    if runtime_metadata.file_type().is_symlink()
        || !runtime_metadata.is_dir()
        || runtime_metadata.uid() != effective_uid
        || runtime_metadata.mode() & 0o077 != 0
    {
        return None;
    }
    let bus_path = runtime_directory.join("bus");
    let bus_metadata = std::fs::symlink_metadata(&bus_path).ok()?;
    if bus_metadata.file_type().is_symlink()
        || !bus_metadata.file_type().is_socket()
        || bus_metadata.uid() != effective_uid
    {
        return None;
    }
    let dbus_address = format!("unix:path={}", bus_path.to_string_lossy());
    if let Ok(configured) = std::env::var("DBUS_SESSION_BUS_ADDRESS") {
        if configured != dbus_address {
            return None;
        }
    }
    Some(SecretEnvironment {
        dbus_address,
        runtime_directory,
    })
}

#[cfg(not(target_os = "linux"))]
fn trusted_secret_environment() -> Option<SecretEnvironment> {
    None
}

fn read_bounded(reader: &mut impl Read, limit: usize) -> CommandResult<Vec<u8>> {
    let mut output = Vec::new();
    reader
        .take((limit + 1) as u64)
        .read_to_end(&mut output)
        .map_err(|_| CommandError::new("secret_service_failed", "Secret Service output failed."))?;
    if output.len() > limit {
        return Err(CommandError::new(
            "secret_service_output_too_large",
            "Secret Service returned too much data.",
        ));
    }
    Ok(output)
}

fn validate_provider(value: &str) -> CommandResult<()> {
    if matches!(value, "github" | "gitlab") {
        Ok(())
    } else {
        Err(CommandError::new(
            "credential_provider_invalid",
            "Credential provider must be GitHub or GitLab.",
        ))
    }
}

fn validate_host(value: &str) -> CommandResult<()> {
    if matches!(value, "github.com" | "gitlab.com") {
        Ok(())
    } else {
        Err(CommandError::new(
            "credential_host_invalid",
            "Credential host is not permitted.",
        ))
    }
}

fn validate_attribute(value: &str, code: &str) -> CommandResult<()> {
    if value.is_empty()
        || value.len() > MAX_ATTRIBUTE_BYTES
        || value.contains('\0')
        || !value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'@' | b'+')
        })
    {
        Err(CommandError::new(code, "Credential identity is invalid."))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_fallback_is_visible_and_never_echoes_token() {
        let store = RepositoryCredentialStore::default();
        let scope = CredentialScope::new("github", "github.com", "acct", "octo").unwrap();
        let token = "token-that-must-not-appear";
        // An invalid secret-tool path is not injectable; directly exercise the fallback map.
        store.memory.lock().unwrap().insert(
            scope.clone(),
            StoredCredential {
                token: RepositoryCredential::from_token(token.to_string()).unwrap(),
                storage: CredentialStorage::ProcessMemory,
            },
        );
        let status = store.status(&scope).unwrap().unwrap();
        assert!(status.session_only);
        assert!(!format!("{:?}", status).contains(token));
        let found = store.lookup(&scope).unwrap().unwrap();
        assert_eq!(found.token(), token);
    }

    #[test]
    fn rejects_untrusted_credential_identity() {
        assert!(CredentialScope::new("github", "github.com", "a\n", "u").is_err());
        assert!(CredentialScope::new("other", "github.com", "a", "u").is_err());
        assert!(CredentialScope::new("github", "evil.example", "a", "u").is_err());
    }
}
