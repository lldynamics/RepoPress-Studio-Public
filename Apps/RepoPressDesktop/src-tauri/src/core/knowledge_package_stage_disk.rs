//! Fixed-parent, exclusive private creation. No rename, overwrite or cleanup of partial outputs.
use super::{bounded, hash, invalid, CommandResult, Layout};
use crate::core::{
    rollback_archive, workspace_backup, workspace_config_backup::reject_git_ancestors,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::CString,
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
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
        && s.mode & 0o7777 == if directory { 0o700 } else { 0o600 }
        && s.mode & libc::S_IFMT
            == if directory {
                libc::S_IFDIR
            } else {
                libc::S_IFREG
            }
        && (directory || s.links == 1)
}
fn path_valid(path: &Path) -> bool {
    path.to_str().is_some_and(|s| {
        path.is_absolute()
            && s.len() <= 4000
            && !s.contains('\0')
            && (s == "/"
                || !s
                    .split('/')
                    .skip(1)
                    .any(|c| c.is_empty() || c == "." || c == ".."))
    })
}
fn absent(base: &File, name: &str) -> CommandResult<()> {
    match workspace_backup::walk(base, Path::new(name), false) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(invalid()),
    }
}
pub(super) struct Target {
    pub path: PathBuf,
    parent_path: PathBuf,
    parent: File,
    parent_identity: (u64, u64, u32, u32),
    name: String,
}
impl Target {
    pub fn new(parent: &Path, root: &Path, id: &str) -> CommandResult<Self> {
        if !cfg!(target_os = "linux")
            || !path_valid(parent)
            || parent.starts_with(root)
            || UuidCheck::invalid(id)
        {
            return Err(invalid());
        }
        reject_git_ancestors(parent).map_err(|_| invalid())?;
        let file = rollback_archive::directory(parent).map_err(|_| invalid())?;
        let s = stamp(file.metadata().map_err(|_| invalid())?);
        if s.mode & 0o7000 != 0 {
            return Err(invalid());
        }
        let name = format!("repopress-knowledge-stage-{id}");
        let path = parent.join(&name);
        if path.starts_with(root) || path.to_str().is_none_or(|s| s.len() > 4096) {
            return Err(invalid());
        }
        let target = Self {
            path,
            parent_path: parent.into(),
            parent: file,
            parent_identity: identity(&s),
            name,
        };
        target.verify()?;
        target.absent()?;
        Ok(target)
    }
    pub fn verify(&self) -> CommandResult<()> {
        let current = rollback_archive::directory(&self.parent_path).map_err(|_| invalid())?;
        if identity(&stamp(current.metadata().map_err(|_| invalid())?)) != self.parent_identity
            || identity(&stamp(self.parent.metadata().map_err(|_| invalid())?))
                != self.parent_identity
        {
            return Err(invalid());
        }
        reject_git_ancestors(&self.parent_path).map_err(|_| invalid())?;
        Ok(())
    }
    pub fn absent(&self) -> CommandResult<()> {
        absent(&self.parent, &self.name)
    }
    pub fn create(&self) -> CommandResult<Candidate<'_>> {
        self.verify()?;
        self.absent()?;
        let root = create_dir(&self.parent, &self.name)?;
        let c = Candidate {
            target: self,
            root,
            knowledge: None,
            bodies: None,
            archives: None,
            witnesses: std::sync::Mutex::new(BTreeMap::new()),
        };
        c.verify()?;
        self.parent.sync_all().map_err(|_| invalid())?;
        Ok(c)
    }
}
struct UuidCheck;
impl UuidCheck {
    fn invalid(s: &str) -> bool {
        uuid::Uuid::parse_str(s).is_err()
            || s.len() != 36
            || s.bytes().any(|b| b.is_ascii_uppercase())
    }
}
struct Directory {
    file: File,
    identity: (u64, u64, u32, u32),
}
fn create_dir(base: &File, name: &str) -> CommandResult<Directory> {
    let c = CString::new(name).map_err(|_| invalid())?;
    if unsafe { libc::mkdirat(base.as_raw_fd(), c.as_ptr(), 0o700) } != 0 {
        return Err(invalid());
    }
    let file = open_dir(base, name)?;
    let s = stamp(file.metadata().map_err(|_| invalid())?);
    if !private(&s, true) || !names(&file)?.is_empty() {
        return Err(invalid());
    }
    base.sync_all().map_err(|_| invalid())?;
    Ok(Directory {
        file,
        identity: identity(&s),
    })
}
fn open_dir(base: &File, name: &str) -> CommandResult<File> {
    let c = CString::new(name).map_err(|_| invalid())?;
    let fd = unsafe {
        libc::openat(
            base.as_raw_fd(),
            c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(invalid());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn verify_dir(base: &File, name: &str, dir: &Directory) -> CommandResult<()> {
    let current = open_dir(base, name)?;
    let s = stamp(current.metadata().map_err(|_| invalid())?);
    let held = stamp(dir.file.metadata().map_err(|_| invalid())?);
    if !private(&s, true)
        || !private(&held, true)
        || identity(&s) != dir.identity
        || identity(&held) != dir.identity
    {
        return Err(invalid());
    }
    Ok(())
}
fn names(file: &File) -> CommandResult<BTreeSet<String>> {
    let mut result = BTreeSet::new();
    for item in
        fs::read_dir(format!("/proc/self/fd/{}", file.as_raw_fd())).map_err(|_| invalid())?
    {
        let name = item
            .map_err(|_| invalid())?
            .file_name()
            .into_string()
            .map_err(|_| invalid())?;
        if result.len() > super::FILES || !result.insert(name) {
            return Err(invalid());
        }
    }
    Ok(result)
}
pub(super) struct Candidate<'a> {
    target: &'a Target,
    root: Directory,
    knowledge: Option<Directory>,
    bodies: Option<Directory>,
    archives: Option<Directory>,
    witnesses: std::sync::Mutex<BTreeMap<String, Stamp>>,
}
impl Candidate<'_> {
    pub fn verify(&self) -> CommandResult<()> {
        self.target.verify()?;
        verify_dir(&self.target.parent, &self.target.name, &self.root)?;
        if let Some(k) = &self.knowledge {
            verify_dir(&self.root.file, "knowledge-v1", k)?;
            if let Some(b) = &self.bodies {
                verify_dir(&k.file, "blobs", b)?;
            }
            if let Some(a) = &self.archives {
                verify_dir(&k.file, "archives", a)?;
            }
        }
        Ok(())
    }
    fn base<'a>(&'a self, path: &'a str) -> CommandResult<(&'a File, &'a str)> {
        // Only these three generated layout prefixes reach filesystem APIs.
        if path == "candidate.json" {
            return Ok((&self.root.file, "candidate.json"));
        }
        if path == "knowledge-v1/manifest.json" {
            return Ok((
                &self.knowledge.as_ref().ok_or_else(invalid)?.file,
                "manifest.json",
            ));
        }
        if let Some(digest) = path.strip_prefix("knowledge-v1/blobs/") {
            if address(digest) {
                return Ok((&self.bodies.as_ref().ok_or_else(invalid)?.file, digest));
            }
        }
        if let Some(digest) = path.strip_prefix("knowledge-v1/archives/") {
            if address(digest) {
                return Ok((&self.archives.as_ref().ok_or_else(invalid)?.file, digest));
            }
        }
        Err(invalid())
    }
    fn put(&self, path: &str, bytes: &[u8]) -> CommandResult<()> {
        self.verify()?;
        let (base, name) = self.base(path)?;
        let c = CString::new(name).map_err(|_| invalid())?;
        let fd = unsafe {
            libc::openat(
                base.as_raw_fd(),
                c.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(invalid());
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        if !private(&stamp(file.metadata().map_err(|_| invalid())?), false) {
            return Err(invalid());
        }
        file.write_all(bytes).map_err(|_| invalid())?;
        file.sync_all().map_err(|_| invalid())?;
        base.sync_all().map_err(|_| invalid())?;
        let s = stamp(file.metadata().map_err(|_| invalid())?);
        if !private(&s, false) || s.len != bytes.len() as u64 {
            return Err(invalid());
        }
        let current =
            workspace_backup::walk(base, Path::new(name), false).map_err(|_| invalid())?;
        if stamp(current.metadata().map_err(|_| invalid())?) != s {
            return Err(invalid());
        }
        self.witnesses
            .lock()
            .map_err(|_| invalid())?
            .insert(path.into(), s);
        self.verify()?;
        Ok(())
    }
    pub fn write(
        mut self,
        layout: &Layout,
        started: Instant,
        check: &mut impl FnMut() -> CommandResult<()>,
        hook: &mut impl FnMut(u8),
    ) -> CommandResult<Self> {
        check()?;
        self.verify()?;
        self.knowledge = Some(create_dir(&self.root.file, "knowledge-v1")?);
        check()?;
        self.verify()?;
        self.bodies = Some(create_dir(
            &self.knowledge.as_ref().ok_or_else(invalid)?.file,
            "blobs",
        )?);
        check()?;
        self.verify()?;
        self.archives = Some(create_dir(
            &self.knowledge.as_ref().ok_or_else(invalid)?.file,
            "archives",
        )?);
        for (path, bytes) in &layout.files {
            if path == "candidate.json" {
                continue;
            }
            check()?;
            self.put(path, bytes)?;
            hook(3);
        }
        hook(4);
        check()?;
        self.verify_contents_inner(layout, started, false)?;
        check()?;
        self.put(
            "candidate.json",
            layout.files.get("candidate.json").ok_or_else(invalid)?,
        )?;
        hook(5);
        check()?;
        self.verify_contents_inner(layout, started, true)?;
        Ok(self)
    }
    pub fn verify_contents(&self, layout: &Layout, started: Instant) -> CommandResult<()> {
        self.verify_contents_inner(layout, started, true)
    }
    fn verify_contents_inner(
        &self,
        layout: &Layout,
        started: Instant,
        marker: bool,
    ) -> CommandResult<()> {
        bounded(started)?;
        self.verify()?;
        let knowledge = self.knowledge.as_ref().ok_or_else(invalid)?;
        let bodies = self.bodies.as_ref().ok_or_else(invalid)?;
        let archives = self.archives.as_ref().ok_or_else(invalid)?;
        let root_expected: BTreeSet<_> = if marker {
            vec!["candidate.json".into(), "knowledge-v1".into()]
        } else {
            vec!["knowledge-v1".into()]
        }
        .into_iter()
        .collect();
        if names(&self.root.file)? != root_expected
            || names(&knowledge.file)?
                != ["manifest.json", "blobs", "archives"]
                    .into_iter()
                    .map(String::from)
                    .collect()
        {
            return Err(invalid());
        }
        for (dir, prefix) in [
            (&bodies.file, "knowledge-v1/blobs/"),
            (&archives.file, "knowledge-v1/archives/"),
        ] {
            let expected = layout
                .files
                .keys()
                .filter_map(|p| p.strip_prefix(prefix).map(String::from))
                .collect();
            if names(dir)? != expected {
                return Err(invalid());
            }
        }
        let witnesses = self.witnesses.lock().map_err(|_| invalid())?;
        for (path, expected) in &layout.files {
            if path == "candidate.json" && !marker {
                continue;
            }
            bounded(started)?;
            let witness = witnesses.get(path).ok_or_else(invalid)?;
            let (base, name) = self.base(path)?;
            let held =
                workspace_backup::walk(base, Path::new(name), false).map_err(|_| invalid())?;
            if stamp(held.metadata().map_err(|_| invalid())?) != *witness
                || !private(witness, false)
            {
                return Err(invalid());
            }
            let mut file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
                .open(format!("/proc/self/fd/{}", held.as_raw_fd()))
                .map_err(|_| invalid())?;
            if stamp(file.metadata().map_err(|_| invalid())?) != *witness {
                return Err(invalid());
            }
            let mut bytes = Vec::with_capacity(expected.len());
            let mut chunk = [0u8; 65536];
            loop {
                bounded(started)?;
                let take = (expected.len() + 1 - bytes.len()).min(chunk.len());
                let n = file.read(&mut chunk[..take]).map_err(|_| invalid())?;
                if n == 0 {
                    break;
                }
                bytes.extend_from_slice(&chunk[..n]);
                if bytes.len() > expected.len() {
                    return Err(invalid());
                }
            }
            let current =
                workspace_backup::walk(base, Path::new(name), false).map_err(|_| invalid())?;
            if bytes != *expected
                || hash(&bytes) != hash(expected)
                || stamp(file.metadata().map_err(|_| invalid())?) != *witness
                || stamp(current.metadata().map_err(|_| invalid())?) != *witness
            {
                return Err(invalid());
            }
        }
        self.verify()?;
        bounded(started)
    }
}
fn address(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
