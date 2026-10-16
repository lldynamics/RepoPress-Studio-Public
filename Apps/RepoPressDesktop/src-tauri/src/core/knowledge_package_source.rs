//! Selected source only: descriptor-relative, no aliases, private regular inode, bounded reads.
use super::{bounded, invalid, CommandResult, PACKAGE_BYTES};
use crate::core::{rollback_archive, workspace_backup};
use std::{
    fs::{File, Metadata, OpenOptions},
    io::Read,
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    time::Instant,
};
#[derive(Clone, Debug, PartialEq, Eq)]
struct Stamp {
    dev: u64,
    ino: u64,
    mode: u32,
    uid: u32,
    links: u64,
    len: u64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
fn stamp(m: Metadata) -> Stamp {
    Stamp {
        dev: m.dev(),
        ino: m.ino(),
        mode: m.mode(),
        uid: m.uid(),
        links: m.nlink(),
        len: m.len(),
        mtime: m.mtime(),
        mtime_ns: m.mtime_nsec(),
        ctime: m.ctime(),
        ctime_ns: m.ctime_nsec(),
    }
}
fn identity(s: &Stamp) -> (u64, u64, u32, u32) {
    (s.dev, s.ino, s.mode, s.uid)
}
pub(in crate::core) struct Source {
    pub path: PathBuf,
    parent: File,
    file: File,
    parent_identity: (u64, u64, u32, u32),
    before: Stamp,
}
impl Source {
    pub fn open(path: &Path) -> CommandResult<Self> {
        let text = path.to_str().ok_or_else(invalid)?;
        if !cfg!(target_os = "linux")
            || !path.is_absolute()
            || text.len() > 4096
            || text.contains('\0')
            || text
                .split('/')
                .skip(1)
                .any(|c| c.is_empty() || c == "." || c == "..")
            || path.extension().and_then(|s| s.to_str()) != Some("json")
        {
            return Err(invalid());
        }
        let parent = rollback_archive::directory(path.parent().ok_or_else(invalid)?)
            .map_err(|_| invalid())?;
        let parent_identity = identity(&stamp(parent.metadata().map_err(|_| invalid())?));
        let file = workspace_backup::walk(
            &parent,
            Path::new(path.file_name().ok_or_else(invalid)?),
            false,
        )
        .map_err(|_| invalid())?;
        let before = stamp(file.metadata().map_err(|_| invalid())?);
        if before.uid != unsafe { libc::geteuid() }
            || before.mode & libc::S_IFMT != libc::S_IFREG
            || before.mode & 0o7777 != 0o600
            || before.links != 1
            || before.len == 0
            || before.len > PACKAGE_BYTES as u64
        {
            return Err(invalid());
        }
        let source = Self {
            path: path.into(),
            parent,
            file,
            parent_identity,
            before,
        };
        source.verify()?;
        Ok(source)
    }
    pub fn verify(&self) -> CommandResult<()> {
        let parent = rollback_archive::directory(self.path.parent().ok_or_else(invalid)?)
            .map_err(|_| invalid())?;
        let current = workspace_backup::walk(
            &self.parent,
            Path::new(self.path.file_name().ok_or_else(invalid)?),
            false,
        )
        .map_err(|_| invalid())?;
        if identity(&stamp(parent.metadata().map_err(|_| invalid())?)) != self.parent_identity
            || stamp(self.file.metadata().map_err(|_| invalid())?) != self.before
            || stamp(current.metadata().map_err(|_| invalid())?) != self.before
        {
            return Err(invalid());
        }
        Ok(())
    }
    pub fn read(&self, started: Instant) -> CommandResult<Vec<u8>> {
        bounded(started)?;
        self.verify()?;
        // Classify O_PATH before content open; never block on a FIFO or open a substituted name.
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(format!("/proc/self/fd/{}", self.file.as_raw_fd()))
            .map_err(|_| invalid())?;
        if stamp(file.metadata().map_err(|_| invalid())?) != self.before {
            return Err(invalid());
        }
        let mut bytes = Vec::with_capacity(self.before.len as usize);
        let mut chunk = [0u8; 64 * 1024];
        loop {
            bounded(started)?;
            let available =
                (self.before.len + 1 - bytes.len() as u64).min(chunk.len() as u64) as usize;
            let n = file.read(&mut chunk[..available]).map_err(|_| invalid())?;
            if n == 0 {
                break;
            }
            bytes.extend_from_slice(&chunk[..n]);
            if bytes.len() as u64 > self.before.len {
                return Err(invalid());
            }
        }
        if bytes.len() as u64 != self.before.len
            || stamp(file.metadata().map_err(|_| invalid())?) != self.before
        {
            return Err(invalid());
        }
        self.verify()?;
        Ok(bytes)
    }
}
