//! Per-operation root lease. All persistent library operations and restore use it.
//! Never initializes, repairs, or removes user files.
use super::{rollback_archive, CommandError, CommandResult};
use std::{
    fs::File,
    os::{fd::AsRawFd, unix::fs::MetadataExt},
    path::{Path, PathBuf},
};
#[derive(Debug)]
pub(crate) struct KnowledgeRootLease {
    pub file: File,
    path: PathBuf,
    identity: (u64, u64, u32, u32),
}
fn identity(file: &File) -> CommandResult<(u64, u64, u32, u32)> {
    let m = file.metadata().map_err(|_| blocked())?;
    if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o7022 != 0 {
        return Err(blocked());
    }
    Ok((m.dev(), m.ino(), m.mode(), m.uid()))
}
pub(crate) fn blocked() -> CommandError {
    CommandError::new("knowledge_restore_blocked","Knowledge storage is busy or requires restore recovery. Inspect restore state before retrying.")
}
pub(crate) fn verify_anchor(path: &Path, file: &File) -> CommandResult<()> {
    let named = rollback_archive::directory(path).map_err(|_| blocked())?;
    if identity(&named)? != identity(file)? {
        return Err(blocked());
    }
    Ok(())
}
impl KnowledgeRootLease {
    pub fn acquire(path: &Path) -> CommandResult<Self> {
        let file = rollback_archive::directory(path).map_err(|_| blocked())?;
        let id = identity(&file)?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(blocked());
        }
        let lease = Self {
            file,
            path: path.into(),
            identity: id,
        };
        lease.verify()?;
        Ok(lease)
    }
    pub fn verify(&self) -> CommandResult<()> {
        let current = rollback_archive::directory(&self.path).map_err(|_| blocked())?;
        if identity(&current)? != self.identity || identity(&self.file)? != self.identity {
            return Err(blocked());
        }
        Ok(())
    }
}
impl Drop for KnowledgeRootLease {
    fn drop(&mut self) {
        unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}
