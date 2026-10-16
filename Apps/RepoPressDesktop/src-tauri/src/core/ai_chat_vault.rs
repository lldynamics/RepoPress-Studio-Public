//! Explicit, passphrase-protected persistence for AI chat history.
//!
//! The vault stores an opaque byte payload so this module never needs to know
//! the chat schema. Creating or unlocking the vault is an explicit action; a
//! constructed vault never decrypts data and never creates storage.

use ring::{
    aead, pbkdf2,
    rand::{SecureRandom, SystemRandom},
};
use serde::Serialize;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    num::NonZeroU32,
    path::{Path, PathBuf},
};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};

use super::ai_provider::AiError;

pub const MAX_VAULT_PLAINTEXT_BYTES: usize = 20 * 1024 * 1024;
pub const MAX_VAULT_ENVELOPE_BYTES: u64 = 24 * 1024 * 1024;
pub const VAULT_PBKDF2_ITERATIONS: u32 = 600_000;

const VAULT_DIRECTORY_NAME: &str = "ai-chat-v1";
const VAULT_FILE_NAME: &str = "history.vault";
const VAULT_VERSION: u32 = 1;
const VAULT_KDF: &str = "pbkdf2-hmac-sha256";
const VAULT_CIPHER: &str = "aes-256-gcm";
const VAULT_SALT_BYTES: usize = 16;
const VAULT_NONCE_BYTES: usize = 12;
const VAULT_TAG_BYTES: usize = 16;
const VAULT_MAGIC: &[u8; 8] = b"RPCHATV1";
const MAX_ALGORITHM_NAME_BYTES: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AiChatVaultState {
    Disabled,
    Locked,
    Unlocked,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiChatVaultStatus {
    pub state: AiChatVaultState,
    pub has_vault: bool,
}

struct VaultEnvelope {
    version: u32,
    kdf: String,
    cipher: String,
    iterations: u32,
    salt: [u8; VAULT_SALT_BYTES],
    nonce: [u8; VAULT_NONCE_BYTES],
    ciphertext: Vec<u8>,
}

struct UnlockedVault {
    key: Zeroizing<[u8; 32]>,
    salt: [u8; VAULT_SALT_BYTES],
    iterations: u32,
}

pub struct AiChatVault {
    app_data_directory: PathBuf,
    storage_directory: PathBuf,
    vault_file: PathBuf,
    unlocked: Option<UnlockedVault>,
}

impl AiChatVault {
    pub fn new(app_data_directory: PathBuf) -> Self {
        let storage_directory = app_data_directory.join(VAULT_DIRECTORY_NAME);
        let vault_file = storage_directory.join(VAULT_FILE_NAME);
        Self {
            app_data_directory,
            storage_directory,
            vault_file,
            unlocked: None,
        }
    }

    #[cfg(test)]
    pub fn vault_path(&self) -> &Path {
        &self.vault_file
    }

    /// Reads only filesystem metadata. It never creates or decrypts a vault.
    pub fn status(&mut self) -> Result<AiChatVaultStatus, AiError> {
        if !inspect_vault_storage(&self.app_data_directory, &self.storage_directory)? {
            self.lock();
            return Ok(AiChatVaultStatus {
                state: AiChatVaultState::Disabled,
                has_vault: false,
            });
        }
        match inspect_optional_regular_file(&self.vault_file, MAX_VAULT_ENVELOPE_BYTES)? {
            Some(_) => Ok(AiChatVaultStatus {
                state: if self.unlocked.is_some() {
                    AiChatVaultState::Unlocked
                } else {
                    AiChatVaultState::Locked
                },
                has_vault: true,
            }),
            None => {
                self.lock();
                Ok(AiChatVaultStatus {
                    state: AiChatVaultState::Disabled,
                    has_vault: false,
                })
            }
        }
    }

    pub fn initialize(&mut self, passphrase: &str, plaintext: &[u8]) -> Result<(), AiError> {
        validate_passphrase(passphrase)?;
        validate_plaintext(plaintext)?;
        ensure_private_storage_directory(
            &self.app_data_directory,
            &self.storage_directory,
            "ai_chat_vault_write_failed",
        )?;
        if inspect_optional_regular_file(&self.vault_file, MAX_VAULT_ENVELOPE_BYTES)?.is_some() {
            return Err(AiError::new(
                "ai_chat_vault_exists",
                "An AI chat vault already exists.",
            ));
        }

        let random = SystemRandom::new();
        let mut salt = [0_u8; VAULT_SALT_BYTES];
        random.fill(&mut salt).map_err(|_| {
            AiError::new(
                "ai_chat_vault_crypto_failed",
                "Unable to initialize encrypted AI chat storage.",
            )
        })?;
        let key = derive_key(passphrase, &salt, VAULT_PBKDF2_ITERATIONS);
        let envelope = encrypt_envelope(&random, &key, &salt, VAULT_PBKDF2_ITERATIONS, plaintext)?;
        let serialized = serialize_envelope(&envelope)?;
        atomic_write_new(&self.storage_directory, &self.vault_file, &serialized)?;
        self.unlocked = Some(UnlockedVault {
            key,
            salt,
            iterations: VAULT_PBKDF2_ITERATIONS,
        });
        Ok(())
    }

    /// Unlocks the vault and returns its opaque plaintext payload.
    ///
    /// Authentication, malformed envelopes, and unsupported envelopes use the
    /// same public error so callers cannot distinguish a wrong passphrase from
    /// tampering.
    pub fn unlock(&mut self, passphrase: &str) -> Result<Vec<u8>, AiError> {
        validate_passphrase(passphrase)?;
        if !inspect_vault_storage(&self.app_data_directory, &self.storage_directory)
            .map_err(|_| unlock_failed())?
        {
            return Err(unlock_failed());
        }
        let serialized =
            read_private_regular_file(&self.vault_file, MAX_VAULT_ENVELOPE_BYTES, unlock_failed)?;
        let envelope = parse_envelope(&serialized)?;
        let salt = envelope.salt;
        let key = derive_key(passphrase, &salt, envelope.iterations);
        let plaintext = decrypt_envelope_with_key(&envelope, &key)?;
        let result = plaintext.to_vec();
        self.unlocked = Some(UnlockedVault {
            key,
            salt,
            iterations: envelope.iterations,
        });
        Ok(result)
    }

    /// Replaces an existing vault using the in-memory key. A fresh nonce is
    /// generated for every replacement.
    pub fn save(&mut self, plaintext: &[u8]) -> Result<(), AiError> {
        validate_plaintext(plaintext)?;
        let unlocked = self.unlocked.as_ref().ok_or_else(|| {
            AiError::new(
                "ai_chat_vault_locked",
                "Unlock AI chat storage before saving.",
            )
        })?;
        ensure_private_storage_directory(
            &self.app_data_directory,
            &self.storage_directory,
            "ai_chat_vault_write_failed",
        )?;
        if inspect_optional_regular_file(&self.vault_file, MAX_VAULT_ENVELOPE_BYTES)?.is_none() {
            return Err(AiError::new(
                "ai_chat_vault_locked",
                "Unlock AI chat storage before saving.",
            ));
        }
        authenticate_existing_vault(&self.vault_file, unlocked)?;
        let random = SystemRandom::new();
        let envelope = encrypt_envelope(
            &random,
            &unlocked.key,
            &unlocked.salt,
            unlocked.iterations,
            plaintext,
        )?;
        let serialized = serialize_envelope(&envelope)?;
        atomic_replace(&self.storage_directory, &self.vault_file, &serialized)
    }

    pub fn lock(&mut self) {
        if let Some(mut unlocked) = self.unlocked.take() {
            unlocked.salt.zeroize();
            unlocked.iterations.zeroize();
            // `Zeroizing` clears the key when `unlocked` is dropped.
        }
    }

    /// Deletes only the exact vault file and clears the in-memory key.
    /// Repeated deletion is successful and returns `false`.
    pub fn delete(&mut self) -> Result<bool, AiError> {
        if !inspect_vault_storage(&self.app_data_directory, &self.storage_directory)? {
            self.lock();
            return Ok(false);
        }
        match inspect_optional_regular_file(&self.vault_file, MAX_VAULT_ENVELOPE_BYTES)? {
            None => {
                self.lock();
                Ok(false)
            }
            Some(_) => {
                fs::remove_file(&self.vault_file).map_err(|_| {
                    AiError::new(
                        "ai_chat_vault_delete_failed",
                        "Unable to delete encrypted AI chat storage.",
                    )
                })?;
                self.lock();
                // The unlink is already complete; directory fsync is a
                // best-effort durability hardening and must not report a
                // transactional failure after state has changed.
                let _ = sync_directory(&self.storage_directory, "ai_chat_vault_delete_failed");
                Ok(true)
            }
        }
    }
}

impl Drop for AiChatVault {
    fn drop(&mut self) {
        self.lock();
    }
}

fn validate_passphrase(passphrase: &str) -> Result<(), AiError> {
    if !(12..=1024).contains(&passphrase.len()) || passphrase.as_bytes().contains(&0) {
        return Err(AiError::new(
            "ai_chat_vault_passphrase_invalid",
            "The AI chat vault passphrase must contain 12 to 1024 UTF-8 bytes.",
        ));
    }
    Ok(())
}

fn validate_plaintext(plaintext: &[u8]) -> Result<(), AiError> {
    if plaintext.len() > MAX_VAULT_PLAINTEXT_BYTES {
        return Err(AiError::new(
            "ai_chat_vault_too_large",
            "AI chat history exceeded the encrypted storage limit.",
        ));
    }
    Ok(())
}

fn derive_key(
    passphrase: &str,
    salt: &[u8; VAULT_SALT_BYTES],
    iterations: u32,
) -> Zeroizing<[u8; 32]> {
    let mut key = Zeroizing::new([0_u8; 32]);
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        NonZeroU32::new(iterations).expect("the supported iteration count is non-zero"),
        salt,
        passphrase.as_bytes(),
        key.as_mut(),
    );
    key
}

fn encrypt_envelope(
    random: &SystemRandom,
    key: &[u8; 32],
    salt: &[u8; VAULT_SALT_BYTES],
    iterations: u32,
    plaintext: &[u8],
) -> Result<VaultEnvelope, AiError> {
    let mut nonce = [0_u8; VAULT_NONCE_BYTES];
    random.fill(&mut nonce).map_err(|_| {
        AiError::new(
            "ai_chat_vault_crypto_failed",
            "Unable to encrypt AI chat history.",
        )
    })?;
    let aad = envelope_aad(
        VAULT_VERSION,
        VAULT_KDF,
        VAULT_CIPHER,
        iterations,
        salt,
        &nonce,
    );
    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, key).map_err(|_| {
        AiError::new(
            "ai_chat_vault_crypto_failed",
            "Unable to encrypt AI chat history.",
        )
    })?;
    let sealing_key = aead::LessSafeKey::new(unbound);
    let mut ciphertext = Zeroizing::new(plaintext.to_vec());
    sealing_key
        .seal_in_place_append_tag(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::from(aad.as_slice()),
            &mut *ciphertext,
        )
        .map_err(|_| {
            AiError::new(
                "ai_chat_vault_crypto_failed",
                "Unable to encrypt AI chat history.",
            )
        })?;
    Ok(VaultEnvelope {
        version: VAULT_VERSION,
        kdf: VAULT_KDF.to_string(),
        cipher: VAULT_CIPHER.to_string(),
        iterations,
        salt: *salt,
        nonce,
        ciphertext: ciphertext.to_vec(),
    })
}

fn decrypt_envelope_with_key(
    envelope: &VaultEnvelope,
    key: &[u8; 32],
) -> Result<Zeroizing<Vec<u8>>, AiError> {
    let salt = envelope.salt;
    let nonce = envelope.nonce;
    let mut plaintext = Zeroizing::new(envelope.ciphertext.clone());
    if !(VAULT_TAG_BYTES..=MAX_VAULT_PLAINTEXT_BYTES + VAULT_TAG_BYTES).contains(&plaintext.len()) {
        return Err(unlock_failed());
    }
    let aad = envelope_aad(
        envelope.version,
        &envelope.kdf,
        &envelope.cipher,
        envelope.iterations,
        &salt,
        &nonce,
    );
    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, key).map_err(|_| unlock_failed())?;
    let opening_key = aead::LessSafeKey::new(unbound);
    let plaintext_length = opening_key
        .open_in_place(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::from(aad.as_slice()),
            plaintext.as_mut(),
        )
        .map_err(|_| unlock_failed())?
        .len();
    if plaintext_length > MAX_VAULT_PLAINTEXT_BYTES {
        return Err(unlock_failed());
    }
    plaintext.truncate(plaintext_length);
    Ok(plaintext)
}

fn authenticate_existing_vault(path: &Path, unlocked: &UnlockedVault) -> Result<(), AiError> {
    let serialized =
        read_private_regular_file(path, MAX_VAULT_ENVELOPE_BYTES, invalid_vault_store)?;
    let envelope = parse_envelope(&serialized).map_err(|_| invalid_vault_store())?;
    if envelope.salt != unlocked.salt || envelope.iterations != unlocked.iterations {
        return Err(invalid_vault_store());
    }
    decrypt_envelope_with_key(&envelope, &unlocked.key).map_err(|_| invalid_vault_store())?;
    Ok(())
}

fn serialize_envelope(envelope: &VaultEnvelope) -> Result<Vec<u8>, AiError> {
    if envelope.kdf.len() > MAX_ALGORITHM_NAME_BYTES
        || envelope.cipher.len() > MAX_ALGORITHM_NAME_BYTES
        || envelope.ciphertext.len() > MAX_VAULT_PLAINTEXT_BYTES + VAULT_TAG_BYTES
    {
        return Err(AiError::new(
            "ai_chat_vault_write_failed",
            "Unable to encode encrypted AI chat storage.",
        ));
    }
    let mut serialized = Vec::with_capacity(64 + envelope.ciphertext.len());
    serialized.extend_from_slice(VAULT_MAGIC);
    serialized.extend_from_slice(&envelope.version.to_be_bytes());
    serialized.extend_from_slice(&(envelope.kdf.len() as u16).to_be_bytes());
    serialized.extend_from_slice(envelope.kdf.as_bytes());
    serialized.extend_from_slice(&(envelope.cipher.len() as u16).to_be_bytes());
    serialized.extend_from_slice(envelope.cipher.as_bytes());
    serialized.extend_from_slice(&envelope.iterations.to_be_bytes());
    serialized.extend_from_slice(&(VAULT_SALT_BYTES as u16).to_be_bytes());
    serialized.extend_from_slice(&envelope.salt);
    serialized.extend_from_slice(&(VAULT_NONCE_BYTES as u16).to_be_bytes());
    serialized.extend_from_slice(&envelope.nonce);
    serialized.extend_from_slice(&(envelope.ciphertext.len() as u64).to_be_bytes());
    serialized.extend_from_slice(&envelope.ciphertext);
    if serialized.len() as u64 > MAX_VAULT_ENVELOPE_BYTES {
        return Err(AiError::new(
            "ai_chat_vault_too_large",
            "AI chat history exceeded the encrypted storage limit.",
        ));
    }
    Ok(serialized)
}

fn parse_envelope(serialized: &[u8]) -> Result<VaultEnvelope, AiError> {
    if serialized.len() as u64 > MAX_VAULT_ENVELOPE_BYTES {
        return Err(unlock_failed());
    }
    let mut cursor = 0_usize;
    if take_array::<8>(serialized, &mut cursor).ok_or_else(unlock_failed)? != *VAULT_MAGIC {
        return Err(unlock_failed());
    }
    let version =
        u32::from_be_bytes(take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?);
    let kdf_length =
        u16::from_be_bytes(take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?) as usize;
    if kdf_length == 0 || kdf_length > MAX_ALGORITHM_NAME_BYTES {
        return Err(unlock_failed());
    }
    let kdf = std::str::from_utf8(
        take_slice(serialized, &mut cursor, kdf_length).ok_or_else(unlock_failed)?,
    )
    .map_err(|_| unlock_failed())?
    .to_string();
    let cipher_length =
        u16::from_be_bytes(take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?) as usize;
    if cipher_length == 0 || cipher_length > MAX_ALGORITHM_NAME_BYTES {
        return Err(unlock_failed());
    }
    let cipher = std::str::from_utf8(
        take_slice(serialized, &mut cursor, cipher_length).ok_or_else(unlock_failed)?,
    )
    .map_err(|_| unlock_failed())?
    .to_string();
    let iterations =
        u32::from_be_bytes(take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?);
    let salt_length =
        u16::from_be_bytes(take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?) as usize;
    if salt_length != VAULT_SALT_BYTES {
        return Err(unlock_failed());
    }
    let salt = take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?;
    let nonce_length =
        u16::from_be_bytes(take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?) as usize;
    if nonce_length != VAULT_NONCE_BYTES {
        return Err(unlock_failed());
    }
    let nonce = take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?;
    let ciphertext_length_u64 =
        u64::from_be_bytes(take_array(serialized, &mut cursor).ok_or_else(unlock_failed)?);
    let ciphertext_length = usize::try_from(ciphertext_length_u64).map_err(|_| unlock_failed())?;
    if !(VAULT_TAG_BYTES..=MAX_VAULT_PLAINTEXT_BYTES + VAULT_TAG_BYTES).contains(&ciphertext_length)
    {
        return Err(unlock_failed());
    }
    let ciphertext = take_slice(serialized, &mut cursor, ciphertext_length)
        .ok_or_else(unlock_failed)?
        .to_vec();
    if cursor != serialized.len() {
        return Err(unlock_failed());
    }
    let envelope = VaultEnvelope {
        version,
        kdf,
        cipher,
        iterations,
        salt,
        nonce,
        ciphertext,
    };
    if envelope.version != VAULT_VERSION
        || envelope.kdf != VAULT_KDF
        || envelope.cipher != VAULT_CIPHER
        || envelope.iterations != VAULT_PBKDF2_ITERATIONS
    {
        return Err(unlock_failed());
    }
    Ok(envelope)
}

fn take_array<const LENGTH: usize>(bytes: &[u8], cursor: &mut usize) -> Option<[u8; LENGTH]> {
    take_slice(bytes, cursor, LENGTH)?.try_into().ok()
}

fn take_slice<'a>(bytes: &'a [u8], cursor: &mut usize, length: usize) -> Option<&'a [u8]> {
    let end = cursor.checked_add(length)?;
    let slice = bytes.get(*cursor..end)?;
    *cursor = end;
    Some(slice)
}

fn envelope_aad(
    version: u32,
    kdf: &str,
    cipher: &str,
    iterations: u32,
    salt: &[u8; VAULT_SALT_BYTES],
    nonce: &[u8; VAULT_NONCE_BYTES],
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(96);
    aad.extend_from_slice(b"RepoPress AI chat vault\0");
    aad.extend_from_slice(&version.to_be_bytes());
    aad.extend_from_slice(&(kdf.len() as u32).to_be_bytes());
    aad.extend_from_slice(kdf.as_bytes());
    aad.extend_from_slice(&(cipher.len() as u32).to_be_bytes());
    aad.extend_from_slice(cipher.as_bytes());
    aad.extend_from_slice(&iterations.to_be_bytes());
    aad.extend_from_slice(salt);
    aad.extend_from_slice(nonce);
    aad
}

fn unlock_failed() -> AiError {
    AiError::new(
        "ai_chat_vault_unlock_failed",
        "Unable to unlock AI chat storage.",
    )
}

fn invalid_vault_store() -> AiError {
    AiError::new(
        "ai_chat_vault_storage_unsafe",
        "Encrypted AI chat storage changed or is invalid.",
    )
}

/// Returns `false` only when the app-data or dedicated vault directory is
/// cleanly absent. Existing path components must be real private directories.
fn inspect_vault_storage(
    app_data_directory: &Path,
    storage_directory: &Path,
) -> Result<bool, AiError> {
    if !app_data_directory.is_absolute() {
        return Err(AiError::new(
            "ai_chat_vault_storage_unsafe",
            "AI chat storage path is invalid.",
        ));
    }
    match fs::symlink_metadata(app_data_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(AiError::new(
                "ai_chat_vault_storage_unsafe",
                "AI chat storage path is not safe.",
            ))
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => {
            return Err(AiError::new(
                "ai_chat_vault_storage_unsafe",
                "AI chat storage path could not be inspected safely.",
            ))
        }
    }
    match fs::symlink_metadata(storage_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(AiError::new(
                "ai_chat_vault_storage_unsafe",
                "AI chat storage path is not safe.",
            ))
        }
        Ok(metadata) => {
            #[cfg(unix)]
            if metadata.mode() & 0o077 != 0 {
                return Err(AiError::new(
                    "ai_chat_vault_storage_unsafe",
                    "AI chat storage directory is not private.",
                ));
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(AiError::new(
            "ai_chat_vault_storage_unsafe",
            "AI chat storage path could not be inspected safely.",
        )),
    }
}

fn inspect_optional_regular_file(path: &Path, maximum: u64) -> Result<Option<u64>, AiError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => {
            return Err(AiError::new(
                "ai_chat_vault_storage_unsafe",
                "AI chat storage could not be inspected safely.",
            ))
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > maximum {
        return Err(AiError::new(
            "ai_chat_vault_storage_unsafe",
            "AI chat storage is not a safe regular file.",
        ));
    }
    #[cfg(unix)]
    if metadata.mode() & 0o077 != 0 {
        return Err(AiError::new(
            "ai_chat_vault_storage_unsafe",
            "AI chat storage is not private.",
        ));
    }
    Ok(Some(metadata.len()))
}

fn read_private_regular_file(
    path: &Path,
    maximum: u64,
    error: fn() -> AiError,
) -> Result<Vec<u8>, AiError> {
    let expected = inspect_optional_regular_file(path, maximum)
        .map_err(|_| error())?
        .ok_or_else(error)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let mut file = options.open(path).map_err(|_| error())?;
    let metadata = file.metadata().map_err(|_| error())?;
    if !metadata.is_file() || metadata.len() != expected || metadata.len() > maximum {
        return Err(error());
    }
    #[cfg(unix)]
    if metadata.mode() & 0o077 != 0 {
        return Err(error());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes).map_err(|_| error())?;
    if bytes.len() as u64 != metadata.len() {
        return Err(error());
    }
    Ok(bytes)
}

fn ensure_private_storage_directory(
    app_data_directory: &Path,
    storage_directory: &Path,
    error_code: &'static str,
) -> Result<(), AiError> {
    if !app_data_directory.is_absolute() {
        return Err(AiError::new(error_code, "AI storage path is invalid."));
    }
    match fs::symlink_metadata(app_data_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(AiError::new(error_code, "AI storage path is not safe."))
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(app_data_directory)
                .map_err(|_| AiError::new(error_code, "Unable to create AI storage."))?;
            let metadata = fs::symlink_metadata(app_data_directory)
                .map_err(|_| AiError::new(error_code, "Unable to inspect AI storage."))?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(AiError::new(error_code, "AI storage path is not safe."));
            }
        }
        Err(_) => return Err(AiError::new(error_code, "Unable to inspect AI storage.")),
    }
    match fs::symlink_metadata(storage_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(AiError::new(error_code, "AI storage path is not safe."))
        }
        Ok(metadata) =>
        {
            #[cfg(unix)]
            if metadata.mode() & 0o077 != 0 {
                return Err(AiError::new(error_code, "AI storage path is not private."));
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            #[cfg(unix)]
            builder.mode(0o700);
            builder
                .create(storage_directory)
                .or_else(|create_error| {
                    if create_error.kind() == std::io::ErrorKind::AlreadyExists {
                        Ok(())
                    } else {
                        Err(create_error)
                    }
                })
                .map_err(|_| AiError::new(error_code, "Unable to create AI storage."))?;
            let metadata = fs::symlink_metadata(storage_directory)
                .map_err(|_| AiError::new(error_code, "Unable to inspect AI storage."))?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(AiError::new(error_code, "AI storage path is not safe."));
            }
            #[cfg(unix)]
            if metadata.mode() & 0o077 != 0 {
                return Err(AiError::new(error_code, "AI storage path is not private."));
            }
        }
        Err(_) => return Err(AiError::new(error_code, "Unable to inspect AI storage.")),
    }
    Ok(())
}

fn atomic_write_new(directory: &Path, target: &Path, bytes: &[u8]) -> Result<(), AiError> {
    let (temporary, mut file) = create_temporary_file(directory, "ai_chat_vault_write_failed")?;
    let result = (|| {
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| {
                AiError::new(
                    "ai_chat_vault_write_failed",
                    "Unable to write encrypted AI chat storage.",
                )
            })?;
        drop(file);
        rename_noreplace(&temporary, target).map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                AiError::new("ai_chat_vault_exists", "An AI chat vault already exists.")
            } else {
                AiError::new(
                    "ai_chat_vault_write_failed",
                    "Unable to install encrypted AI chat storage.",
                )
            }
        })?;
        let _ = sync_directory(directory, "ai_chat_vault_write_failed");
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn atomic_replace(directory: &Path, target: &Path, bytes: &[u8]) -> Result<(), AiError> {
    inspect_optional_regular_file(target, MAX_VAULT_ENVELOPE_BYTES)?.ok_or_else(|| {
        AiError::new(
            "ai_chat_vault_locked",
            "Unlock AI chat storage before saving.",
        )
    })?;
    let (temporary, mut file) = create_temporary_file(directory, "ai_chat_vault_write_failed")?;
    let result = (|| {
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| {
                AiError::new(
                    "ai_chat_vault_write_failed",
                    "Unable to write encrypted AI chat storage.",
                )
            })?;
        drop(file);
        inspect_optional_regular_file(target, MAX_VAULT_ENVELOPE_BYTES)?.ok_or_else(|| {
            AiError::new(
                "ai_chat_vault_write_failed",
                "Encrypted AI chat storage changed before replacement.",
            )
        })?;
        fs::rename(&temporary, target).map_err(|_| {
            AiError::new(
                "ai_chat_vault_write_failed",
                "Unable to replace encrypted AI chat storage.",
            )
        })?;
        let _ = sync_directory(directory, "ai_chat_vault_write_failed");
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn create_temporary_file(
    directory: &Path,
    error_code: &'static str,
) -> Result<(PathBuf, File), AiError> {
    for _ in 0..8 {
        let path = directory.join(format!(".vault-{}.tmp", Uuid::new_v4()));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        match options.open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => {
                return Err(AiError::new(
                    error_code,
                    "Unable to create temporary AI storage.",
                ))
            }
        }
    }
    Err(AiError::new(
        error_code,
        "Unable to create temporary AI storage.",
    ))
}

#[cfg(target_os = "linux")]
fn rename_noreplace(source: &Path, target: &Path) -> std::io::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let target = CString::new(target.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    // Linux renameat2 provides the only atomic no-replace installation needed
    // by first-time vault creation.
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "linux"))]
fn rename_noreplace(source: &Path, target: &Path) -> std::io::Result<()> {
    if target.try_exists()? {
        return Err(std::io::Error::from(std::io::ErrorKind::AlreadyExists));
    }
    fs::rename(source, target)
}

fn sync_directory(directory: &Path, error_code: &'static str) -> Result<(), AiError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    options
        .open(directory)
        .and_then(|file| file.sync_all())
        .map_err(|_| AiError::new(error_code, "Unable to synchronize AI storage."))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASSPHRASE: &str = "correct horse battery staple";

    fn vault() -> (tempfile::TempDir, AiChatVault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = AiChatVault::new(directory.path().join("app-data"));
        (directory, vault)
    }

    #[test]
    fn ciphertext_hides_plaintext_and_round_trips_after_restart() {
        let (_directory, mut vault) = self::vault();
        let plaintext = b"distinct private conversation text 739195";
        assert_eq!(vault.status().unwrap().state, AiChatVaultState::Disabled);
        assert!(!vault.app_data_directory.exists());
        vault.initialize(PASSPHRASE, plaintext).unwrap();
        let raw = fs::read(vault.vault_path()).unwrap();
        assert!(!raw
            .windows(plaintext.len())
            .any(|window| window == plaintext));
        assert_eq!(vault.status().unwrap().state, AiChatVaultState::Unlocked);

        let mut restarted = AiChatVault::new(vault.app_data_directory.clone());
        assert_eq!(restarted.status().unwrap().state, AiChatVaultState::Locked);
        assert_eq!(restarted.unlock(PASSPHRASE).unwrap(), plaintext);
    }

    #[test]
    fn wrong_passphrase_and_tampering_share_one_error_code() {
        let (_directory, mut vault) = self::vault();
        vault.initialize(PASSPHRASE, b"secret").unwrap();
        let wrong = vault.unlock("this password is wrong").unwrap_err();
        // A failed re-unlock must not discard an already authenticated key.
        vault.save(b"still unlocked").unwrap();
        let mut envelope = parse_envelope(&fs::read(vault.vault_path()).unwrap()).unwrap();
        envelope.ciphertext[0] ^= 0x80;
        fs::write(vault.vault_path(), serialize_envelope(&envelope).unwrap()).unwrap();
        let tampered = vault.unlock(PASSPHRASE).unwrap_err();
        assert_eq!(wrong.code, "ai_chat_vault_unlock_failed");
        assert_eq!(tampered.code, wrong.code);
        assert_eq!(tampered.message, wrong.message);
        let tampered_bytes = fs::read(vault.vault_path()).unwrap();
        assert_eq!(
            vault
                .save(b"must not overwrite tampering")
                .unwrap_err()
                .code,
            "ai_chat_vault_storage_unsafe"
        );
        assert_eq!(fs::read(vault.vault_path()).unwrap(), tampered_bytes);
    }

    #[test]
    fn rejects_unknown_version_and_oversized_plaintext() {
        let (_directory, mut vault) = vault();
        vault.initialize(PASSPHRASE, b"secret").unwrap();
        let raw = fs::read(vault.vault_path()).unwrap();
        assert_eq!(
            parse_envelope(&raw[..raw.len() - 1])
                .err()
                .expect("truncated envelope must fail")
                .code,
            "ai_chat_vault_unlock_failed"
        );
        let mut trailing = raw.clone();
        trailing.push(0);
        assert_eq!(
            parse_envelope(&trailing)
                .err()
                .expect("trailing bytes must fail")
                .code,
            "ai_chat_vault_unlock_failed"
        );
        let mut envelope = parse_envelope(&raw).unwrap();
        envelope.version = 99;
        fs::write(vault.vault_path(), serialize_envelope(&envelope).unwrap()).unwrap();
        assert_eq!(
            vault.unlock(PASSPHRASE).unwrap_err().code,
            "ai_chat_vault_unlock_failed"
        );

        let (_directory, mut vault) = self::vault();
        let oversized = vec![0_u8; MAX_VAULT_PLAINTEXT_BYTES + 1];
        assert_eq!(
            vault.initialize(PASSPHRASE, &oversized).unwrap_err().code,
            "ai_chat_vault_too_large"
        );

        // Binary framing leaves enough room for the documented maximum
        // plaintext without base64 expansion.
        let maximum_envelope = VaultEnvelope {
            version: VAULT_VERSION,
            kdf: VAULT_KDF.to_string(),
            cipher: VAULT_CIPHER.to_string(),
            iterations: VAULT_PBKDF2_ITERATIONS,
            salt: [1; VAULT_SALT_BYTES],
            nonce: [2; VAULT_NONCE_BYTES],
            ciphertext: vec![0; MAX_VAULT_PLAINTEXT_BYTES + VAULT_TAG_BYTES],
        };
        assert!(
            serialize_envelope(&maximum_envelope).unwrap().len() as u64 <= MAX_VAULT_ENVELOPE_BYTES
        );
    }

    #[test]
    fn lock_blocks_save_and_every_save_uses_a_fresh_nonce() {
        let (_directory, mut vault) = vault();
        vault.initialize(PASSPHRASE, b"first").unwrap();
        let first = parse_envelope(&fs::read(vault.vault_path()).unwrap()).unwrap();
        vault.save(b"second").unwrap();
        let second = parse_envelope(&fs::read(vault.vault_path()).unwrap()).unwrap();
        assert_ne!(first.nonce, second.nonce);
        vault.lock();
        assert_eq!(
            vault.save(b"third").unwrap_err().code,
            "ai_chat_vault_locked"
        );
    }

    #[test]
    fn initialize_never_overwrites_and_delete_is_exact_and_idempotent() {
        let (_directory, mut vault) = vault();
        vault.initialize(PASSPHRASE, b"first").unwrap();
        let original = fs::read(vault.vault_path()).unwrap();
        assert_eq!(
            vault
                .initialize(PASSPHRASE, b"replacement")
                .unwrap_err()
                .code,
            "ai_chat_vault_exists"
        );
        assert_eq!(fs::read(vault.vault_path()).unwrap(), original);
        // A duplicate initialize is also transactional: the old unlocked key
        // remains usable.
        vault.save(b"saved after duplicate initialize").unwrap();
        let sibling = vault.storage_directory.join("keep-me");
        fs::write(&sibling, b"keep").unwrap();
        assert!(vault.delete().unwrap());
        assert!(sibling.exists());
        assert!(!vault.delete().unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn creates_private_storage_and_rejects_symlinks() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let (directory, mut vault) = vault();
        vault.initialize(PASSPHRASE, b"secret").unwrap();
        assert_eq!(
            fs::metadata(&vault.storage_directory)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(vault.vault_path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );

        let target = directory.path().join("target");
        fs::write(&target, b"not a vault").unwrap();
        let linked_root = directory.path().join("linked-root");
        symlink(directory.path(), &linked_root).unwrap();
        let mut linked = AiChatVault::new(linked_root);
        assert_eq!(
            linked.status().unwrap_err().code,
            "ai_chat_vault_storage_unsafe"
        );
        assert_eq!(
            linked.initialize(PASSPHRASE, b"secret").unwrap_err().code,
            "ai_chat_vault_write_failed"
        );

        vault.delete().unwrap();
        symlink(&target, vault.vault_path()).unwrap();
        assert_eq!(
            vault.status().unwrap_err().code,
            "ai_chat_vault_storage_unsafe"
        );
    }

    #[cfg(unix)]
    #[test]
    fn unsafe_delete_failure_preserves_the_unlocked_key() {
        use std::os::unix::fs::symlink;

        let (directory, mut vault) = vault();
        vault.initialize(PASSPHRASE, b"secret").unwrap();
        let backup = directory.path().join("vault-backup");
        fs::rename(vault.vault_path(), &backup).unwrap();
        let target = directory.path().join("target");
        fs::write(&target, b"not a vault").unwrap();
        symlink(&target, vault.vault_path()).unwrap();
        assert_eq!(
            vault.delete().unwrap_err().code,
            "ai_chat_vault_storage_unsafe"
        );

        fs::remove_file(vault.vault_path()).unwrap();
        fs::rename(backup, vault.vault_path()).unwrap();
        vault.save(b"key survived failed delete").unwrap();
        vault.lock();
        assert_eq!(
            vault.unlock(PASSPHRASE).unwrap(),
            b"key survived failed delete"
        );
    }
}
