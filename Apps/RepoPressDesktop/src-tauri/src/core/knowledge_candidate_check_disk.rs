//! Read-only descriptor-relative inspection; no initialization, repair, or cleanup.
use super::{bounded, invalid, CommandResult, MAX_FILES};
use crate::core::{
    rollback_archive, workspace_backup, workspace_config_backup::reject_git_ancestors,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, Metadata, OpenOptions},
    io::Read,
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    time::Instant,
};
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Stamp {
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
pub(super) fn identity(s: &Stamp) -> (u64, u64, u32, u32) {
    (s.dev, s.ino, s.mode, s.uid)
}
pub(super) fn byte_size(s: &Stamp) -> u64 {
    s.len
}
// Moving a regular file changes ctime. Preserve every other identity/content stamp.
pub(super) fn same_renamed_file(a: &Stamp, b: &Stamp) -> bool {
    a.dev == b.dev
        && a.ino == b.ino
        && a.mode == b.mode
        && a.uid == b.uid
        && a.links == b.links
        && a.len == b.len
        && a.mtime == b.mtime
        && a.mtime_ns == b.mtime_ns
}
pub(super) fn file_stamp(f: &File) -> CommandResult<Stamp> {
    f.metadata().map(stamp).map_err(|_| invalid())
}
fn private(s: &Stamp, dir: bool) -> bool {
    s.uid == unsafe { libc::geteuid() }
        && s.mode & 0o7777 == if dir { 0o700 } else { 0o600 }
        && s.mode & libc::S_IFMT == if dir { libc::S_IFDIR } else { libc::S_IFREG }
        && (dir || s.links == 1)
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub(super) enum Observation {
    Found(Stamp),
    Missing,
    Failed,
}
pub(super) fn observe(base: &File, name: &str, dir: bool) -> Observation {
    match workspace_backup::walk(base, Path::new(name), dir).and_then(|f| f.metadata()) {
        Ok(m) => Observation::Found(stamp(m)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Observation::Missing,
        Err(_) => Observation::Failed,
    }
}
pub(super) struct Dir {
    pub file: File,
    pub before: Stamp,
}
pub(super) fn directory(base: &File, name: &str) -> Result<Dir, &'static str> {
    let file = workspace_backup::walk(base, Path::new(name), true).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            "missing"
        } else {
            "unsafe"
        }
    })?;
    let before = stamp(file.metadata().map_err(|_| "unreadable")?);
    if !private(&before, true) {
        return Err("unsafe");
    }
    Ok(Dir { file, before })
}
pub(super) fn verify_dir(base: &File, name: &str, dir: &Dir) -> bool {
    observe(base, name, true) == Observation::Found(dir.before.clone())
        && file_stamp(&dir.file).ok().as_ref() == Some(&dir.before)
}
pub(super) struct Witness {
    held: File,
    pub before: Stamp,
}
impl Witness {
    pub fn verify(&self, base: &File, name: &str) -> bool {
        file_stamp(&self.held).ok().as_ref() == Some(&self.before)
            && observe(base, name, false) == Observation::Found(self.before.clone())
    }
}
pub(super) struct ReadFile {
    pub bytes: Vec<u8>,
    pub witness: Witness,
}
pub(super) fn read(
    base: &File,
    name: &str,
    max: usize,
    started: Instant,
) -> Result<ReadFile, &'static str> {
    let held = workspace_backup::walk(base, Path::new(name), false).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            "missing"
        } else {
            "unsafe"
        }
    })?;
    let before = stamp(held.metadata().map_err(|_| "unreadable")?);
    if !private(&before, false) {
        return Err("unsafe");
    }
    if before.len > max as u64 {
        return Err("invalid");
    }
    bounded(started).map_err(|_| "unreadable")?;
    // Validate the O_PATH inode before opening content: never content-open FIFO/device/symlink.
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(format!("/proc/self/fd/{}", held.as_raw_fd()))
        .map_err(|_| "unreadable")?;
    if file_stamp(&file).ok().as_ref() != Some(&before) {
        return Err("changed");
    }
    let mut bytes = Vec::with_capacity(before.len as usize);
    let mut chunk = [0u8; 65536];
    loop {
        bounded(started).map_err(|_| "unreadable")?;
        let take = (before.len as usize + 1 - bytes.len()).min(chunk.len());
        let n = file.read(&mut chunk[..take]).map_err(|_| "unreadable")?;
        if n == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..n]);
        if bytes.len() > before.len as usize {
            return Err("changed");
        }
    }
    if bytes.len() != before.len as usize
        || file_stamp(&file).ok().as_ref() != Some(&before)
        || observe(base, name, false) != Observation::Found(before.clone())
    {
        return Err("changed");
    }
    Ok(ReadFile {
        bytes,
        witness: Witness { held, before },
    })
}
fn names(dir: &File) -> CommandResult<BTreeSet<String>> {
    bounded_names(dir, MAX_FILES)
}
pub(super) fn bounded_names(dir: &File, max: usize) -> CommandResult<BTreeSet<String>> {
    let mut names = BTreeSet::new();
    for e in fs::read_dir(format!("/proc/self/fd/{}", dir.as_raw_fd())).map_err(|_| invalid())? {
        if names.len() >= max {
            return Err(invalid());
        }
        let name = e
            .map_err(|_| invalid())?
            .file_name()
            .into_string()
            .map_err(|_| invalid())?;
        if !names.insert(name) {
            return Err(invalid());
        }
    }
    Ok(names)
}
pub(super) fn valid_path(path: &Path) -> bool {
    path.to_str().is_some_and(|s| {
        path.is_absolute()
            && s.len() <= 4096
            && !s.contains('\0')
            && !s
                .split('/')
                .skip(1)
                .any(|c| c.is_empty() || c == "." || c == "..")
    })
}
pub(super) fn valid_id(s: &str) -> bool {
    uuid::Uuid::parse_str(s)
        .ok()
        .is_some_and(|u| u.get_version_num() == 4 && u.to_string() == s)
}
pub(super) struct Tree {
    pub path: PathBuf,
    pub stage_id: String,
    parent_path: PathBuf,
    parent: File,
    parent_identity: (u64, u64, u32, u32),
    name: String,
    root: Dir,
    knowledge: Dir,
    bodies: Dir,
    archives: Dir,
    witnesses: BTreeMap<String, Witness>,
}
impl Tree {
    pub fn open(path: &Path, app_root: &Path) -> CommandResult<Self> {
        if !cfg!(target_os = "linux") || !valid_path(path) || path.starts_with(app_root) {
            return Err(invalid());
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(invalid)?;
        let stage_id = name
            .strip_prefix("repopress-knowledge-stage-")
            .filter(|s| valid_id(s))
            .ok_or_else(invalid)?;
        let parent_path = path.parent().ok_or_else(invalid)?;
        reject_git_ancestors(parent_path).map_err(|_| invalid())?;
        let parent = rollback_archive::directory(parent_path).map_err(|_| invalid())?;
        let parent_stamp = file_stamp(&parent)?;
        if parent_stamp.mode & 0o7000 != 0 {
            return Err(invalid());
        }
        let root = directory(&parent, name).map_err(|_| invalid())?;
        if names(&root.file)?
            != ["candidate.json", "knowledge-v1"]
                .into_iter()
                .map(String::from)
                .collect()
        {
            return Err(invalid());
        }
        let knowledge = directory(&root.file, "knowledge-v1").map_err(|_| invalid())?;
        if names(&knowledge.file)?
            != ["manifest.json", "blobs", "archives"]
                .into_iter()
                .map(String::from)
                .collect()
        {
            return Err(invalid());
        }
        let bodies = directory(&knowledge.file, "blobs").map_err(|_| invalid())?;
        let archives = directory(&knowledge.file, "archives").map_err(|_| invalid())?;
        let tree = Self {
            path: path.into(),
            stage_id: stage_id.into(),
            parent_path: parent_path.into(),
            parent,
            parent_identity: identity(&parent_stamp),
            name: name.into(),
            root,
            knowledge,
            bodies,
            archives,
            witnesses: BTreeMap::new(),
        };
        tree.verify()?;
        Ok(tree)
    }
    fn base<'a>(&'a self, path: &'a str) -> CommandResult<(&'a File, &'a str)> {
        if path == "candidate.json" {
            return Ok((&self.root.file, "candidate.json"));
        }
        if path == "knowledge-v1/manifest.json" {
            return Ok((&self.knowledge.file, "manifest.json"));
        }
        for (prefix, dir) in [
            ("knowledge-v1/blobs/", &self.bodies),
            ("knowledge-v1/archives/", &self.archives),
        ] {
            if let Some(digest) = path.strip_prefix(prefix) {
                if super::digest(digest) {
                    return Ok((&dir.file, digest));
                }
            }
        }
        Err(invalid())
    }
    pub fn read(&mut self, path: &str, max: usize, started: Instant) -> CommandResult<Vec<u8>> {
        let (base, name) = self.base(path)?;
        let read = read(base, name, max, started).map_err(|_| invalid())?;
        self.witnesses.insert(path.into(), read.witness);
        Ok(read.bytes)
    }
    pub fn check_resources(&self, expected: &BTreeSet<String>) -> CommandResult<()> {
        for (prefix, dir) in [
            ("knowledge-v1/blobs/", &self.bodies),
            ("knowledge-v1/archives/", &self.archives),
        ] {
            let names_expected = expected
                .iter()
                .filter_map(|p| p.strip_prefix(prefix).map(String::from))
                .collect();
            if names(&dir.file)? != names_expected {
                return Err(invalid());
            }
        }
        Ok(())
    }
    pub fn verify(&self) -> CommandResult<()> {
        let current = rollback_archive::directory(&self.parent_path).map_err(|_| invalid())?;
        if identity(&file_stamp(&current)?) != self.parent_identity
            || identity(&file_stamp(&self.parent)?) != self.parent_identity
            || !verify_dir(&self.parent, &self.name, &self.root)
            || !verify_dir(&self.root.file, "knowledge-v1", &self.knowledge)
            || !verify_dir(&self.knowledge.file, "blobs", &self.bodies)
            || !verify_dir(&self.knowledge.file, "archives", &self.archives)
        {
            return Err(invalid());
        }
        reject_git_ancestors(&self.parent_path).map_err(|_| invalid())?;
        for (path, s) in &self.witnesses {
            let (base, name) = self.base(path)?;
            if !s.verify(base, name) {
                return Err(invalid());
            }
        }
        Ok(())
    }
    pub fn fingerprint(&self) -> CommandResult<String> {
        Ok(super::hash(
            &serde_json::to_vec(&(
                &self.parent_identity,
                &self.root.before,
                &self.knowledge.before,
                &self.bodies.before,
                &self.archives.before,
                self.witnesses
                    .iter()
                    .map(|(path, w)| (path, &w.before))
                    .collect::<Vec<_>>(),
            ))
            .map_err(|_| invalid())?,
        ))
    }
}
