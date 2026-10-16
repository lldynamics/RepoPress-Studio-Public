//! AI credentials stored under a distinct Secret Service namespace.
//!
//! `repopress-ai` is intentionally separate from repository/publishing tokens.
//! When Secret Service is not available, callers receive an explicit process-memory
//! status. No fallback ever writes a token to disk.

use super::ai_provider::{validate_endpoint, AiError, AiProviderConfig, AiProviderKind};
use serde::Serialize;
use std::{
    collections::HashMap,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};

const MAX_TOKEN_BYTES: usize = 16 * 1024;
const SECRET_TIMEOUT: Duration = Duration::from_secs(3);
const SECRET_TOOL_PATHS: &[&str] = &["/usr/bin/secret-tool", "/usr/local/bin/secret-tool"];

#[derive(Clone, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiCredentialScope {
    pub provider: AiProviderKind,
    pub endpoint: String,
    pub account: String,
}

impl AiCredentialScope {
    pub fn new(config: &AiProviderConfig, account: &str) -> Result<Self, AiError> {
        if account.is_empty()
            || account.len() > 160
            || account.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err(AiError::new(
                "ai_account_invalid",
                "AI account identity is invalid.",
            ));
        }
        let endpoint = validate_endpoint(config.provider, &config.endpoint)?;
        Ok(Self {
            provider: config.provider,
            endpoint,
            account: account.to_string(),
        })
    }
}

/// The secret has no `Debug`, `Clone`, `Serialize`, or `Display` implementation.
pub struct AiCredential {
    token: String,
}

impl AiCredential {
    pub fn from_token(token: String) -> Result<Self, AiError> {
        if token.is_empty()
            || token.len() > MAX_TOKEN_BYTES
            || token.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err(AiError::new(
                "ai_token_invalid",
                "AI credential is invalid.",
            ));
        }
        Ok(Self { token })
    }

    pub(crate) fn token(&self) -> &str {
        &self.token
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AiCredentialStorage {
    SecretService,
    SessionMemory,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiCredentialStatus {
    pub storage: AiCredentialStorage,
    pub session_only: bool,
    pub warning: Option<String>,
}

struct StoredAiCredential {
    token: AiCredential,
    storage: AiCredentialStorage,
    warning: Option<String>,
}

#[derive(Default)]
pub struct AiCredentialStore {
    memory: Mutex<HashMap<AiCredentialScope, StoredAiCredential>>,
}

impl AiCredentialStore {
    pub fn save(
        &self,
        scope: AiCredentialScope,
        credential: AiCredential,
    ) -> Result<AiCredentialStatus, AiError> {
        let status = match secret_service_context() {
            Some(context) => match secret_store(&context, &scope, credential.token()) {
                Ok(()) => AiCredentialStatus {
                    storage: AiCredentialStorage::SecretService,
                    session_only: false,
                    warning: None,
                },
                Err(_) => AiCredentialStatus {
                    storage: AiCredentialStorage::SessionMemory,
                    session_only: true,
                    warning: Some(
                        "secret_service_failed_session_only_persistent_state_unverified"
                            .to_string(),
                    ),
                },
            },
            None => session_memory_status(),
        };
        self.memory.lock().map_err(|_| store_unavailable())?.insert(
            scope,
            StoredAiCredential {
                token: credential,
                storage: status.storage,
                warning: status.warning.clone(),
            },
        );
        Ok(status)
    }

    pub fn lookup(&self, scope: &AiCredentialScope) -> Result<Option<AiCredential>, AiError> {
        if let Some(token) = self
            .memory
            .lock()
            .map_err(|_| store_unavailable())?
            .get(scope)
            .map(|stored| stored.token.token.clone())
        {
            return Ok(Some(AiCredential { token }));
        }
        if let Some(context) = secret_service_context() {
            return secret_lookup(&context, scope)?
                .map(AiCredential::from_token)
                .transpose();
        }
        Ok(None)
    }

    pub fn status(&self, scope: &AiCredentialScope) -> Result<Option<AiCredentialStatus>, AiError> {
        if let Some(status) = self
            .memory
            .lock()
            .map_err(|_| store_unavailable())?
            .get(scope)
            .map(|stored| AiCredentialStatus {
                storage: stored.storage,
                session_only: stored.storage == AiCredentialStorage::SessionMemory,
                warning: stored.warning.clone(),
            })
        {
            return Ok(Some(status));
        }
        // On a new desktop session, the process map is empty even though a
        // Secret Service credential may persist. Probe it without exposing the
        // returned value to callers of this status-only API.
        if let Some(context) = secret_service_context() {
            return Ok(persistent_status_from_lookup(secret_lookup(
                &context, scope,
            )?));
        }
        Ok(None)
    }

    /// Deletes the active credential. A warning is returned when a session
    /// credential was removed but an inaccessible keyring made the state of a
    /// possible older persistent item impossible to verify.
    pub fn delete(&self, scope: &AiCredentialScope) -> Result<Option<String>, AiError> {
        let in_memory_storage = self
            .memory
            .lock()
            .map_err(|_| store_unavailable())?
            .get(scope)
            .map(|stored| stored.storage);
        let storage = match in_memory_storage {
            Some(storage) => storage,
            None => {
                let context = secret_service_context().ok_or_else(|| {
                    AiError::new("ai_credential_not_found", "AI credential is unavailable.")
                })?;
                if secret_lookup(&context, scope)?.is_some() {
                    AiCredentialStorage::SecretService
                } else {
                    return Err(AiError::new(
                        "ai_credential_not_found",
                        "AI credential is unavailable.",
                    ));
                }
            }
        };
        let cleanup = if storage == AiCredentialStorage::SecretService {
            match secret_service_context() {
                Some(context) => secret_clear(&context, scope).map(|()| None),
                None => Err(AiError::new(
                    "ai_secret_service_unavailable",
                    "Secret Service is unavailable; persistent credential was not deleted.",
                )),
            }
        } else if let Some(context) = secret_service_context() {
            // A session credential may have been created while the keyring was
            // unavailable. Remove any older persisted value for the exact
            // endpoint before claiming deletion.
            match secret_lookup(&context, scope) {
                Ok(Some(_)) => match secret_clear(&context, scope) {
                    Ok(()) => Ok(None),
                    Err(_) => Ok(Some(
                        "session_credential_deleted_persistent_state_unverified".to_string(),
                    )),
                },
                Ok(None) => Ok(None),
                Err(_) => Ok(Some(
                    "session_credential_deleted_persistent_state_unverified".to_string(),
                )),
            }
        } else {
            Ok(Some(
                "session_credential_deleted_persistent_state_unverified".to_string(),
            ))
        };
        // Always forget the process-memory copy, even if an inaccessible
        // keyring prevents us from truthfully claiming that every persisted
        // copy was removed.
        self.memory
            .lock()
            .map_err(|_| store_unavailable())?
            .remove(scope);
        cleanup
    }

    #[cfg(test)]
    fn insert_session_for_test(&self, scope: AiCredentialScope, credential: AiCredential) {
        self.memory.lock().unwrap().insert(
            scope,
            StoredAiCredential {
                token: credential,
                storage: AiCredentialStorage::SessionMemory,
                warning: session_memory_status().warning,
            },
        );
    }
}

pub fn ai_secret_service_available() -> bool {
    secret_service_context().is_some()
}

fn session_memory_status() -> AiCredentialStatus {
    status_for(AiCredentialStorage::SessionMemory)
}

fn status_for(storage: AiCredentialStorage) -> AiCredentialStatus {
    AiCredentialStatus {
        storage,
        session_only: storage == AiCredentialStorage::SessionMemory,
        warning: (storage == AiCredentialStorage::SessionMemory)
            .then(|| "secret_service_unavailable_session_only".to_string()),
    }
}

fn persistent_status_from_lookup(token: Option<String>) -> Option<AiCredentialStatus> {
    // Drop the token immediately. Status callers only learn that a persisted
    // item exists, never anything about its contents.
    token.map(|_| status_for(AiCredentialStorage::SecretService))
}

fn store_unavailable() -> AiError {
    AiError::new(
        "ai_credential_store_unavailable",
        "AI credential state is unavailable.",
    )
}

fn provider_label(provider: AiProviderKind) -> &'static str {
    match provider {
        AiProviderKind::OpenaiCompatible => "openai_compatible",
        AiProviderKind::OllamaLocal => "ollama_local",
    }
}

struct SecretServiceContext {
    secret_tool: &'static str,
    runtime_dir: PathBuf,
    bus_address: String,
}

fn secret_service_context() -> Option<SecretServiceContext> {
    let effective_uid = effective_uid()?;
    let runtime_dir = PathBuf::from("/run/user").join(effective_uid.to_string());
    validate_runtime_bus(&runtime_dir, effective_uid)?;
    let secret_tool = trusted_secret_tool()?;
    let bus_address = format!("unix:path={}", runtime_dir.join("bus").display());
    Some(SecretServiceContext {
        secret_tool,
        runtime_dir,
        bus_address,
    })
}

fn effective_uid() -> Option<u32> {
    // Linux exposes the effective UID from the kernel; unlike `$UID`, it cannot
    // be supplied by an untrusted parent process environment.
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|line| line.starts_with("Uid:"))?;
    line.split_whitespace().nth(2)?.parse().ok()
}

fn validate_runtime_bus(runtime_dir: &Path, effective_uid: u32) -> Option<()> {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        let directory = std::fs::symlink_metadata(runtime_dir).ok()?;
        if !directory.is_dir()
            || directory.file_type().is_symlink()
            || directory.uid() != effective_uid
            || directory.mode() & 0o022 != 0
        {
            return None;
        }
        let bus = std::fs::symlink_metadata(runtime_dir.join("bus")).ok()?;
        if !bus.file_type().is_socket()
            || bus.file_type().is_symlink()
            || bus.uid() != effective_uid
            || bus.mode() & 0o022 != 0
        {
            return None;
        }
        Some(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (runtime_dir, effective_uid);
        None
    }
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
            metadata.uid() == 0
                && metadata.mode() & 0o022 == 0
                && trusted_root_owned_parents(Path::new(path))
        }
        #[cfg(not(target_os = "linux"))]
        {
            false
        }
    })
}

#[cfg(target_os = "linux")]
fn trusted_root_owned_parents(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    let mut parent = path.parent();
    while let Some(directory) = parent {
        let Ok(metadata) = std::fs::symlink_metadata(directory) else {
            return false;
        };
        if !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.mode() & 0o022 != 0
        {
            return false;
        }
        parent = directory.parent();
    }
    true
}

fn secret_store(
    context: &SecretServiceContext,
    scope: &AiCredentialScope,
    token: &str,
) -> Result<(), AiError> {
    let provider = provider_label(scope.provider);
    let output = secret_tool(
        context,
        &[
            "store",
            "--label=RepoPress AI credential",
            "service",
            "repopress-ai",
            "provider",
            provider,
            "endpoint",
            &scope.endpoint,
            "account",
            &scope.account,
        ],
        Some(token),
    )?;
    output.success.then_some(()).ok_or_else(|| {
        AiError::new(
            "ai_secret_service_failed",
            "Secret Service could not store the AI credential.",
        )
    })
}

fn secret_lookup(
    context: &SecretServiceContext,
    scope: &AiCredentialScope,
) -> Result<Option<String>, AiError> {
    let provider = provider_label(scope.provider);
    let output = secret_tool(
        context,
        &[
            "lookup",
            "service",
            "repopress-ai",
            "provider",
            provider,
            "endpoint",
            &scope.endpoint,
            "account",
            &scope.account,
        ],
        None,
    )?;
    parse_secret_lookup_output(output)
}

fn parse_secret_lookup_output(output: SecretOutput) -> Result<Option<String>, AiError> {
    // `secret-tool lookup` exits non-zero for a missing item. That is the
    // expected unconfigured state only for its documented exit code; other
    // failures must not be mistaken for an absent credential.
    if !output.success {
        return if output.exit_code == Some(1) && output.stderr.is_empty() {
            Ok(None)
        } else {
            Err(AiError::new(
                "ai_secret_service_failed",
                "Secret Service could not read the AI credential.",
            ))
        };
    }
    let value = String::from_utf8(output.stdout).map_err(|_| {
        AiError::new(
            "ai_secret_service_invalid",
            "Secret Service returned an invalid credential.",
        )
    })?;
    let token = value.trim_end_matches(['\r', '\n']);
    Ok((!token.is_empty()).then(|| token.to_string()))
}

fn secret_clear(context: &SecretServiceContext, scope: &AiCredentialScope) -> Result<(), AiError> {
    let provider = provider_label(scope.provider);
    let output = secret_tool(
        context,
        &[
            "clear",
            "service",
            "repopress-ai",
            "provider",
            provider,
            "endpoint",
            &scope.endpoint,
            "account",
            &scope.account,
        ],
        None,
    )?;
    output.success.then_some(()).ok_or_else(|| {
        AiError::new(
            "ai_secret_service_delete_failed",
            "Secret Service could not delete the AI credential.",
        )
    })
}

struct SecretOutput {
    success: bool,
    exit_code: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn secret_tool(
    context: &SecretServiceContext,
    args: &[&str],
    input: Option<&str>,
) -> Result<SecretOutput, AiError> {
    let mut command = Command::new(context.secret_tool);
    command
        .args(args)
        .env_clear()
        .env("LC_ALL", "C")
        .env("XDG_RUNTIME_DIR", &context.runtime_dir)
        .env("DBUS_SESSION_BUS_ADDRESS", &context.bus_address)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|_| {
        AiError::new(
            "ai_secret_service_unavailable",
            "Secret Service is unavailable.",
        )
    })?;
    let writer = if let Some(token) = input {
        let mut stdin = child.stdin.take().ok_or_else(|| {
            AiError::new("ai_secret_service_failed", "Secret Service input failed.")
        })?;
        let input = token.as_bytes().to_vec();
        Some(thread::spawn(move || -> Result<(), AiError> {
            stdin.write_all(&input).map_err(|_| {
                AiError::new("ai_secret_service_failed", "Secret Service input failed.")
            })?;
            stdin.write_all(b"\n").map_err(|_| {
                AiError::new("ai_secret_service_failed", "Secret Service input failed.")
            })
        }))
    } else {
        None
    };
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| AiError::new("ai_secret_service_failed", "Secret Service output failed."))?;
    let reader = thread::spawn(move || read_bounded(&mut stdout, MAX_TOKEN_BYTES));
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| AiError::new("ai_secret_service_failed", "Secret Service output failed."))?;
    let stderr_reader = thread::spawn(move || read_bounded(&mut stderr, MAX_TOKEN_BYTES));
    let deadline = Instant::now() + SECRET_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                if let Some(writer) = writer {
                    let _ = writer.join();
                }
                let _ = reader.join();
                let _ = stderr_reader.join();
                return Err(AiError::new(
                    "ai_secret_service_timeout",
                    "Secret Service did not respond in time.",
                ));
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                if let Some(writer) = writer {
                    let _ = writer.join();
                }
                let _ = reader.join();
                let _ = stderr_reader.join();
                return Err(AiError::new(
                    "ai_secret_service_failed",
                    "Secret Service wait failed.",
                ));
            }
        }
    };
    if let Some(writer) = writer {
        writer.join().map_err(|_| {
            AiError::new("ai_secret_service_failed", "Secret Service input failed.")
        })??;
    }
    let stdout = reader
        .join()
        .map_err(|_| AiError::new("ai_secret_service_failed", "Secret Service output failed."))??;
    let stderr = stderr_reader
        .join()
        .map_err(|_| AiError::new("ai_secret_service_failed", "Secret Service output failed."))??;
    Ok(SecretOutput {
        success: status.success(),
        exit_code: status.code(),
        stdout,
        stderr,
    })
}

fn read_bounded(reader: &mut impl Read, limit: usize) -> Result<Vec<u8>, AiError> {
    let mut output = Vec::new();
    reader
        .take((limit + 1) as u64)
        .read_to_end(&mut output)
        .map_err(|_| AiError::new("ai_secret_service_failed", "Secret Service output failed."))?;
    if output.len() > limit {
        return Err(AiError::new(
            "ai_secret_service_invalid",
            "Secret Service returned too much data.",
        ));
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope() -> AiCredentialScope {
        let config = AiProviderConfig::new(
            AiProviderKind::OllamaLocal,
            "http://localhost:11434",
            "llama",
        )
        .unwrap();
        AiCredentialScope::new(&config, "default").unwrap()
    }

    #[test]
    fn session_fallback_is_explicit_and_token_is_not_formattable() {
        let store = AiCredentialStore::default();
        let token = "do-not-leak-this-ai-token";
        let scope = scope();
        store.insert_session_for_test(
            scope.clone(),
            AiCredential::from_token(token.to_string()).unwrap(),
        );
        let status = store.status(&scope).unwrap().unwrap();
        assert!(status.session_only);
        assert!(!format!("{status:?}").contains(token));
        assert_eq!(store.lookup(&scope).unwrap().unwrap().token(), token);
    }

    #[test]
    fn scope_uses_separate_namespace_inputs() {
        let config = AiProviderConfig::new(
            AiProviderKind::OpenaiCompatible,
            "https://api.example.test/v1",
            "gpt",
        )
        .unwrap();
        assert_eq!(
            AiCredentialScope::new(&config, "account").unwrap().endpoint,
            "https://api.example.test/v1"
        );
        let alternate = AiProviderConfig::new(
            AiProviderKind::OpenaiCompatible,
            "https://api.example.test:8443/v1",
            "gpt",
        )
        .unwrap();
        assert!(
            AiCredentialScope::new(&config, "account").unwrap()
                != AiCredentialScope::new(&alternate, "account").unwrap()
        );
        assert!(AiCredential::from_token("bad\nvalue".to_string()).is_err());
    }

    #[test]
    fn persisted_lookup_status_distinguishes_unconfigured_from_present() {
        assert!(persistent_status_from_lookup(None).is_none());
        let status = persistent_status_from_lookup(Some("not-exposed".to_string())).unwrap();
        assert_eq!(status.storage, AiCredentialStorage::SecretService);
        assert!(!status.session_only);
        assert!(!format!("{status:?}").contains("not-exposed"));
    }

    #[test]
    fn lookup_only_treats_exit_one_without_stderr_as_missing() {
        let missing = SecretOutput {
            success: false,
            exit_code: Some(1),
            stdout: Vec::new(),
            stderr: Vec::new(),
        };
        assert_eq!(parse_secret_lookup_output(missing).unwrap(), None);

        for output in [
            SecretOutput {
                success: false,
                exit_code: Some(2),
                stdout: Vec::new(),
                stderr: Vec::new(),
            },
            SecretOutput {
                success: false,
                exit_code: Some(1),
                stdout: Vec::new(),
                stderr: b"locked".to_vec(),
            },
        ] {
            assert_eq!(
                parse_secret_lookup_output(output).unwrap_err().code,
                "ai_secret_service_failed"
            );
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn runtime_bus_policy_rejects_a_regular_file() {
        let directory = tempfile::tempdir().unwrap();
        let bus = directory.path().join("bus");
        std::fs::write(&bus, b"not-a-socket").unwrap();
        use std::os::unix::fs::MetadataExt;
        let owner = std::fs::metadata(directory.path()).unwrap().uid();
        assert!(validate_runtime_bus(directory.path(), owner).is_none());
    }
}
