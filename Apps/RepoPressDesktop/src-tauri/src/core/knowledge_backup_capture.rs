//! Strict saved-file capture. Does not initialize the library, migrate it or collect garbage.
use super::{hash, invalid, CommandResult, MANIFEST_BYTES, RESOURCE_BYTES, RESOURCE_FILES, TIME};
use crate::core::{knowledge_library::knowledge_integrity_manifest, workspace_backup};
use knowledge_integrity_manifest::IntegrityReference;
use serde_json::Value;
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

#[derive(Clone, Debug, Eq, PartialEq)]
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
fn private(s: &Stamp, directory: bool) -> bool {
    s.uid == unsafe { libc::geteuid() }
        && s.mode & 0o777 == if directory { 0o700 } else { 0o600 }
        && s.mode & libc::S_IFMT
            == if directory {
                libc::S_IFDIR
            } else {
                libc::S_IFREG
            }
        && (directory || s.links == 1)
}
pub(super) struct Root {
    pub path: PathBuf,
    file: File,
    identity: (u64, u64, u32, u32),
}
impl Root {
    pub fn new(path: PathBuf) -> Option<Self> {
        let file = workspace_backup::root_handle(&path).ok()?;
        let identity = identity(&stamp(file.metadata().ok()?));
        Some(Self {
            path,
            file,
            identity,
        })
    }
    pub fn verify(&self) -> CommandResult<()> {
        let current = workspace_backup::root_handle(&self.path).map_err(|_| invalid())?;
        if identity(&stamp(current.metadata().map_err(|_| invalid())?)) != self.identity {
            return Err(invalid());
        }
        Ok(())
    }
}
fn bounded(started: Instant) -> CommandResult<()> {
    if started.elapsed() >= TIME {
        return Err(invalid());
    }
    Ok(())
}
fn observe(base: &File, name: &str) -> CommandResult<Stamp> {
    let f = workspace_backup::walk(base, Path::new(name), false).map_err(|_| invalid())?;
    Ok(stamp(f.metadata().map_err(|_| invalid())?))
}
fn directory(base: &File, name: &str) -> CommandResult<(File, Stamp)> {
    let f = workspace_backup::walk(base, Path::new(name), true).map_err(|_| invalid())?;
    let s = stamp(f.metadata().map_err(|_| invalid())?);
    if !private(&s, true) {
        return Err(invalid());
    }
    Ok((f, s))
}
fn read(
    base: &File,
    name: &str,
    limit: u64,
    budget: &mut u64,
    started: Instant,
) -> CommandResult<(Vec<u8>, Stamp)> {
    bounded(started)?;
    let path = workspace_backup::walk(base, Path::new(name), false).map_err(|_| invalid())?;
    let before = stamp(path.metadata().map_err(|_| invalid())?);
    if !private(&before, false) || before.len > limit || before.len > *budget {
        return Err(invalid());
    }
    // O_PATH classified the held inode before any content open, including FIFO/device rejection.
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", path.as_raw_fd()))
        .map_err(|_| invalid())?;
    if stamp(file.metadata().map_err(|_| invalid())?) != before {
        return Err(invalid());
    }
    let mut bytes = Vec::with_capacity(before.len as usize);
    let mut chunk = [0u8; 64 * 1024];
    loop {
        bounded(started)?;
        if *budget == 0 && bytes.len() as u64 == before.len {
            break;
        }
        let remaining = before
            .len
            .saturating_add(1)
            .saturating_sub(bytes.len() as u64)
            .min(*budget)
            .min(chunk.len() as u64) as usize;
        if remaining == 0 {
            return Err(invalid());
        }
        let n = file.read(&mut chunk[..remaining]).map_err(|_| invalid())?;
        if n == 0 {
            break;
        }
        *budget -= n as u64;
        bytes.extend_from_slice(&chunk[..n]);
        if bytes.len() as u64 > before.len {
            return Err(invalid());
        }
    }
    if bytes.len() as u64 != before.len
        || stamp(file.metadata().map_err(|_| invalid())?) != before
        || observe(base, name)? != before
    {
        return Err(invalid());
    }
    Ok((bytes, before))
}
#[derive(Clone)]
struct FileWitness {
    reference: IntegrityReference,
    stamp: Stamp,
}
pub(super) struct Witness {
    directory: Stamp,
    bodies: Stamp,
    archives: Stamp,
    manifest: Stamp,
    pub manifest_sha256: String,
    files: Vec<FileWitness>,
}
pub(super) struct CapturedFile {
    pub reference: IntegrityReference,
    pub bytes: Vec<u8>,
}
pub(super) struct Capture {
    pub witness: Witness,
    pub manifest: Value,
    pub files: Vec<CapturedFile>,
    pub item_count: u64,
    pub revision_count: u64,
    pub resource_bytes: u64,
}
struct Opened {
    library: File,
    bodies: File,
    archives: File,
}
fn open_expected(root: &Root, witness: &Witness) -> CommandResult<Opened> {
    root.verify()?;
    let (library, library_stamp) = directory(&root.file, "knowledge-v1")?;
    let (bodies, bodies_stamp) = directory(&library, "blobs")?;
    let (archives, archives_stamp) = directory(&library, "archives")?;
    if library_stamp != witness.directory
        || bodies_stamp != witness.bodies
        || archives_stamp != witness.archives
    {
        return Err(invalid());
    }
    Ok(Opened {
        library,
        bodies,
        archives,
    })
}
fn verify_names(root: &Root, witness: &Witness, started: Instant) -> CommandResult<()> {
    let opened = open_expected(root, witness)?;
    if observe(&opened.library, "manifest.json")? != witness.manifest {
        return Err(invalid());
    }
    for expected in &witness.files {
        bounded(started)?;
        let dir = if expected.reference.kind == "body" {
            &opened.bodies
        } else {
            &opened.archives
        };
        if observe(dir, &expected.reference.digest)? != expected.stamp {
            return Err(invalid());
        }
    }
    // Re-observe directories/manifest after all file observations. This remains sequential, not atomic.
    open_expected(root, witness)?;
    if observe(&opened.library, "manifest.json")? != witness.manifest {
        return Err(invalid());
    }
    bounded(started)
}
pub(super) fn capture(root: &Root, mut hook: impl FnMut(u8)) -> CommandResult<Capture> {
    let started = Instant::now();
    root.verify()?;
    let (library, library_stamp) = directory(&root.file, "knowledge-v1")?;
    let mut manifest_budget = MANIFEST_BYTES + 1;
    let (bytes, manifest_stamp) = read(
        &library,
        "manifest.json",
        MANIFEST_BYTES,
        &mut manifest_budget,
        started,
    )?;
    let projected = knowledge_integrity_manifest::project(&bytes).map_err(|_| invalid())?;
    knowledge_integrity_manifest::validate_completed_operations(&bytes).map_err(|_| invalid())?;
    if projected.files.len() > RESOURCE_FILES
        || projected.files.iter().map(|f| f.byte_size).sum::<u64>() > RESOURCE_BYTES
    {
        return Err(invalid());
    }
    if projected.missing_archives > 0
        || projected.truncated_archives > 0
        || projected.unknown_archives > 0
    {
        return Err(crate::core::CommandError::new("knowledge_backup_incomplete", "Saved archives have missing, truncated or unknown resources. A complete saved-file package cannot be planned."));
    }
    let mut manifest: Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    manifest["completedOperations"] = Value::Array(Vec::new());
    let (bodies, bodies_stamp) = directory(&library, "blobs")?;
    let (archives, archives_stamp) = directory(&library, "archives")?;
    let mut witness = Witness {
        directory: library_stamp,
        bodies: bodies_stamp,
        archives: archives_stamp,
        manifest: manifest_stamp,
        manifest_sha256: hash(&bytes),
        files: Vec::new(),
    };
    let mut files = Vec::new();
    let mut budget = RESOURCE_BYTES;
    hook(0);
    for reference in projected.files {
        let dir = if reference.kind == "body" {
            &bodies
        } else {
            &archives
        };
        let max = if reference.kind == "body" {
            5 * 1024 * 1024
        } else {
            24 * 1024 * 1024
        };
        let (bytes, s) = read(dir, &reference.digest, max, &mut budget, started)?;
        if !knowledge_integrity_manifest::content_matches(&reference, &bytes) {
            return Err(invalid());
        }
        witness.files.push(FileWitness {
            reference: reference.clone(),
            stamp: s,
        });
        files.push(CapturedFile { reference, bytes });
    }
    hook(1);
    verify_names(root, &witness, started)?;
    Ok(Capture {
        witness,
        manifest,
        files,
        item_count: projected.items,
        revision_count: projected.revisions,
        resource_bytes: RESOURCE_BYTES - budget,
    })
}
pub(super) fn revalidate(root: &Root, witness: &Witness) -> CommandResult<()> {
    let started = Instant::now();
    let opened = open_expected(root, witness)?;
    let mut manifest_budget = MANIFEST_BYTES + 1;
    let (bytes, s) = read(
        &opened.library,
        "manifest.json",
        MANIFEST_BYTES,
        &mut manifest_budget,
        started,
    )?;
    if s != witness.manifest || hash(&bytes) != witness.manifest_sha256 {
        return Err(invalid());
    }
    let mut budget = RESOURCE_BYTES;
    for expected in &witness.files {
        let r = &expected.reference;
        let dir = if r.kind == "body" {
            &opened.bodies
        } else {
            &opened.archives
        };
        let max = if r.kind == "body" {
            5 * 1024 * 1024
        } else {
            24 * 1024 * 1024
        };
        let (bytes, s) = read(dir, &r.digest, max, &mut budget, started)?;
        if s != expected.stamp || !knowledge_integrity_manifest::content_matches(r, &bytes) {
            return Err(invalid());
        }
    }
    verify_names(root, witness, started)
}
#[cfg(test)]
mod limits_tests {
    use super::*;
    #[test]
    fn reader_byte_and_expired_time_budgets_refuse_without_partial_success() {
        use std::{fs, os::unix::fs::PermissionsExt};
        let temp = tempfile::tempdir().unwrap();
        let p = temp.path().join("body");
        fs::write(&p, b"body").unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o600)).unwrap();
        let base = File::open(temp.path()).unwrap();
        assert!(read(&base, "body", 5, &mut 3, Instant::now()).is_err());
        assert!(read(&base, "body", 5, &mut 10, Instant::now() - TIME).is_err());
        assert_eq!(fs::read(p).unwrap(), b"body");
    }
}
