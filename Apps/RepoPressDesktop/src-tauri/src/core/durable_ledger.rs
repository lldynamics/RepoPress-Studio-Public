//! Shared private SQLite file lifecycle; preserves the P31 on-disk schema.
use super::{publish_ledger::unavailable, CommandResult};
use rusqlite::{Connection, OpenFlags};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub(super) struct Storage {
    pub(super) connection: Connection,
    // Held for this store's lifetime: another app instance must not verify or
    // delete an attempt while the owning instance is still pushing.
    pub(super) _process_lock: StorageLock,
    pub(super) directory: PathBuf,
    file: PathBuf,
    directory_identity: (u64, u64),
    file_identity: (u64, u64),
}
pub(super) struct StorageLock(pub(super) File);
impl Drop for StorageLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            // SAFETY: the descriptor is owned and still open. Explicit unlock
            // releases the shared flock even if a concurrently forked helper
            // has not yet reached exec and closed its CLOEXEC copy.
            unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
        }
    }
}
#[cfg(unix)]
fn identity(path: &Path, directory: bool) -> CommandResult<(u64, u64)> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let metadata = fs::symlink_metadata(path).map_err(|_| unavailable())?;
    if metadata.file_type().is_symlink()
        || (if directory {
            !metadata.is_dir()
        } else {
            !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > 32 * 1024 * 1024
        })
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(unavailable());
    }
    Ok((metadata.dev(), metadata.ino()))
}
#[cfg(not(unix))]
fn identity(_path: &Path, _directory: bool) -> CommandResult<(u64, u64)> {
    Err(unavailable())
}
pub(super) fn validate_storage(storage: &Storage) -> CommandResult<()> {
    if identity(&storage.directory, true)? != storage.directory_identity
        || identity(&storage.file, false)? != storage.file_identity
    {
        return Err(unavailable());
    }
    Ok(())
}
#[cfg(unix)]
fn lock_storage(file: &Path) -> CommandResult<StorageLock> {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let lock = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(file)
        .map_err(|_| unavailable())?;
    // SAFETY: the owned File keeps this descriptor valid for the call and its
    // lifetime; the nonblocking flock cannot stall application startup.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(unavailable());
    }
    Ok(StorageLock(lock))
}
#[cfg(not(unix))]
fn lock_storage(_file: &Path) -> CommandResult<StorageLock> {
    Err(unavailable())
}
pub(super) fn open_storage(
    app_data: &Path,
    directory_name: &str,
    file_name: &str,
) -> CommandResult<Storage> {
    fs::create_dir_all(app_data).map_err(|_| unavailable())?;
    let directory = app_data.join(directory_name);
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    match builder.create(&directory) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(unavailable()),
    }
    let directory_identity = identity(&directory, true)?;
    let file = directory.join(file_name);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let created = match options.open(&file) {
        Ok(file) => {
            file.sync_all().map_err(|_| unavailable())?;
            true
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => false,
        Err(_) => return Err(unavailable()),
    };
    let file_identity = identity(&file, false)?;
    let process_lock = lock_storage(&file)?;
    let connection = Connection::open_with_flags(
        &file,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_NOFOLLOW
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| unavailable())?;
    connection
        .busy_timeout(Duration::from_secs(2))
        .map_err(|_| unavailable())?;
    connection
        .execute_batch(
            "PRAGMA trusted_schema=OFF; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;",
        )
        .map_err(|_| unavailable())?;
    if created {
        connection.execute_batch("BEGIN IMMEDIATE; CREATE TABLE pushes (id TEXT PRIMARY KEY NOT NULL, repository_path TEXT NOT NULL, payload TEXT NOT NULL); PRAGMA user_version=1; COMMIT;").map_err(|_| unavailable())?;
    }
    let version: u32 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|_| unavailable())?;
    let integrity: String = connection
        .query_row("PRAGMA quick_check", [], |row| row.get(0))
        .map_err(|_| unavailable())?;
    if version != 1 || integrity != "ok" {
        return Err(unavailable());
    }
    let storage = Storage {
        connection,
        _process_lock: process_lock,
        directory,
        file,
        directory_identity,
        file_identity,
    };
    validate_storage(&storage)?;
    File::open(&storage.directory)
        .and_then(|file| file.sync_all())
        .map_err(|_| unavailable())?;
    // Persist the new publish-ledger directory entry in its parent as well.
    File::open(app_data)
        .and_then(|file| file.sync_all())
        .map_err(|_| unavailable())?;
    Ok(storage)
}
