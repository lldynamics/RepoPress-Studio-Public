//! Shared bounded SQLite snapshot mechanics. Only feature-owned fixed layouts are accepted.
use super::{workspace_backup, CommandError, CommandResult};
use rusqlite::{
    backup::{Backup, StepResult},
    Connection, DatabaseName,
};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    fs::File,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
const MAX_BYTES: usize = 32 * 1024 * 1024;
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TableSummary {
    pub table: &'static str,
    pub row_count: u64,
}
fn invalid() -> CommandError {
    CommandError::new(
        "sqlite_snapshot_invalid",
        "The durable database snapshot or file identity could not be validated.",
    )
}
#[derive(Clone, Debug, Eq, PartialEq)]
struct Identity([u64; 4]);
fn identity(f: &File) -> CommandResult<Identity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let m = f.metadata().map_err(|_| invalid())?;
        Ok(Identity([
            m.dev(),
            m.ino(),
            m.mode().into(),
            m.uid().into(),
        ]))
    }
    #[cfg(not(unix))]
    {
        let _ = f;
        Err(invalid())
    }
}
pub(super) struct SnapshotRoot {
    pub(super) path: PathBuf,
    handle: File,
    identity: Identity,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct SourceWitness {
    directory: Identity,
    file: Identity,
    pub(super) revision: [i64; 3],
    primary_stamp: [u64; 5],
    wal_stamp: Option<[u64; 7]>,
}
pub(super) fn revision(c: &Connection) -> CommandResult<[i64; 3]> {
    Ok([
        c.query_row("PRAGMA data_version", [], |r| r.get(0))
            .map_err(|_| invalid())?,
        c.query_row("SELECT total_changes()", [], |r| r.get(0))
            .map_err(|_| invalid())?,
        c.query_row("PRAGMA schema_version", [], |r| r.get(0))
            .map_err(|_| invalid())?,
    ])
}
impl SnapshotRoot {
    pub(super) fn new(path: PathBuf) -> Option<Self> {
        let handle = workspace_backup::root_handle(&path).ok()?;
        let identity = identity(&handle).ok()?;
        Some(Self {
            path,
            handle,
            identity,
        })
    }
    pub(super) fn verify(&self) -> CommandResult<()> {
        if identity(&workspace_backup::root_handle(&self.path).map_err(|_| invalid())?)?
            != self.identity
        {
            return Err(invalid());
        }
        Ok(())
    }
    pub(super) fn witness(
        &self,
        connection: &Connection,
        path: &Path,
        opened: [u64; 2],
        location: (&str, &str),
    ) -> CommandResult<SourceWitness> {
        self.verify()?;
        let root = self;
        let (directory_name, file_name) = location;
        if path != root.path.join(directory_name).join(file_name) {
            return Err(invalid());
        }
        let dir = workspace_backup::walk(&root.handle, Path::new(directory_name), true)
            .map_err(|_| invalid())?;
        let file =
            workspace_backup::walk(&dir, Path::new(file_name), false).map_err(|_| invalid())?;
        private(&dir, true, false)?;
        private(&file, false, false)?;
        let file_id = identity(&file)?;
        if file_id.0[..2] != opened {
            return Err(invalid());
        }
        let mut wal_stamp = None;
        // Sidecars are inspected as metadata only. SQLite remains their sole reader.
        for name in [
            format!("{file_name}-wal"),
            format!("{file_name}-shm"),
            format!("{file_name}-journal"),
        ] {
            match workspace_backup::walk(&dir, Path::new(&name), false) {
                Ok(f) => {
                    private(&f, false, true)?;
                    if name == format!("{file_name}-wal") {
                        let i = identity(&f)?;
                        let t = stamp(&f)?;
                        wal_stamp = Some([i.0[0], i.0[1], t[0], t[1], t[2], t[3], t[4]]);
                    }
                }
                Err(_) => {
                    use std::os::fd::AsRawFd;
                    let anchored =
                        PathBuf::from(format!("/proc/self/fd/{}", dir.as_raw_fd())).join(name);
                    match std::fs::symlink_metadata(anchored) {
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                        _ => return Err(invalid()),
                    }
                }
            }
        }
        Ok(SourceWitness {
            directory: identity(&dir)?,
            file: file_id,
            revision: revision(connection)?,
            primary_stamp: stamp(&file)?,
            wal_stamp,
        })
    }
}
fn stamp(f: &File) -> CommandResult<[u64; 5]> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let m = f.metadata().map_err(|_| invalid())?;
        Ok([
            m.len(),
            m.mtime() as u64,
            m.mtime_nsec() as u64,
            m.ctime() as u64,
            m.ctime_nsec() as u64,
        ])
    }
    #[cfg(not(unix))]
    {
        let _ = f;
        Err(invalid())
    }
}
fn private(f: &File, dir: bool, sidecar: bool) -> CommandResult<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let m = f.metadata().map_err(|_| invalid())?;
        let mode = m.mode() & 0o777;
        if m.uid() != unsafe { libc::geteuid() }
            || if dir {
                !m.is_dir() || mode != 0o700
            } else {
                !m.is_file()
                    || m.nlink() != 1
                    || if sidecar {
                        mode & 0o133 != 0 || m.len() > 128 * 1024 * 1024
                    } else {
                        mode != 0o600 || m.len() > MAX_BYTES as u64
                    }
            }
        {
            return Err(invalid());
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = (f, dir, sidecar);
        Err(invalid())
    }
}
fn database_bytes(c: &Connection) -> CommandResult<usize> {
    let pages: i64 = c
        .query_row("PRAGMA page_count", [], |r| r.get(0))
        .map_err(|_| invalid())?;
    let size: i64 = c
        .query_row("PRAGMA page_size", [], |r| r.get(0))
        .map_err(|_| invalid())?;
    let bytes = pages
        .checked_mul(size)
        .filter(|v| *v > 0 && *v <= MAX_BYTES as i64)
        .ok_or_else(invalid)?;
    Ok(bytes as usize)
}
pub(super) fn capture(
    source: &Connection,
    tables: &[&'static str],
    validate: impl Fn(&Connection) -> CommandResult<()>,
) -> CommandResult<(Vec<u8>, Vec<TableSummary>)> {
    database_bytes(source)?;
    let mut copy = Connection::open_in_memory().map_err(|_| invalid())?;
    {
        let backup = Backup::new(source, &mut copy).map_err(|_| invalid())?;
        let started = Instant::now();
        loop {
            if started.elapsed() > Duration::from_secs(5) {
                return Err(invalid());
            }
            match backup.step(256).map_err(|_| invalid())? {
                StepResult::Done => break,
                StepResult::More => {}
                _ => return Err(invalid()),
            }
        }
    }
    database_bytes(&copy)?;
    validate(&copy)?;
    // Compact only the isolated copy: deleted freelist pages do not enter the export.
    copy.execute_batch("PRAGMA trusted_schema=OFF; PRAGMA journal_mode=DELETE; VACUUM;")
        .map_err(|_| invalid())?;
    validate(&copy)?;
    let tables = tables
        .iter()
        .map(|table| {
            let n: i64 = copy
                .query_row(&format!("SELECT count(*) FROM \"{table}\""), [], |r| {
                    r.get(0)
                })
                .map_err(|_| invalid())?;
            if n < 0 {
                return Err(invalid());
            }
            Ok(TableSummary {
                table,
                row_count: n as u64,
            })
        })
        .collect::<CommandResult<Vec<_>>>()?;
    database_bytes(&copy)?;
    let data = copy.serialize(DatabaseName::Main).map_err(|_| invalid())?;
    if data.is_empty()
        || data.len() > MAX_BYTES
        || !data.starts_with(b"SQLite format 3\0")
        || data[18] != 1
        || data[19] != 1
    {
        return Err(invalid());
    }
    Ok((data.to_vec(), tables))
}
// Compare objects, column attributes, foreign keys and index columns to the installed
// feature schema, allowing migrated column order. No unknown tables, views or triggers.
pub(super) fn schema(c: &Connection) -> CommandResult<BTreeMap<String, Vec<String>>> {
    let mut result = BTreeMap::new();
    let mut q = c
        .prepare("SELECT type,name,tbl_name FROM sqlite_schema ORDER BY name")
        .map_err(|_| invalid())?;
    let rows = q
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .map_err(|_| invalid())?;
    for row in rows {
        let (kind, name, table) = row.map_err(|_| invalid())?;
        if name
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
            || !["table", "index"].contains(&kind.as_str())
        {
            return Err(invalid());
        }
        let mut description = vec![kind.clone(), table];
        let queries = if kind == "table" {
            vec![
                format!("PRAGMA table_xinfo('{name}')"),
                format!("PRAGMA foreign_key_list('{name}')"),
                format!("PRAGMA index_list('{name}')"),
            ]
        } else {
            vec![format!("PRAGMA index_xinfo('{name}')")]
        };
        for (idx, sql) in queries.iter().enumerate() {
            let mut stmt = c.prepare(sql).map_err(|_| invalid())?;
            let columns = stmt.column_count();
            let list = stmt
                .query_map([], |r| {
                    let mut values = Vec::new();
                    for n in 0..columns {
                        // cid/seq/index-list sequence may differ after ALTER TABLE.
                        if n == 0 || (kind == "index" && n == 1) {
                            continue;
                        }
                        values.push(format!("{:?}", r.get_ref(n)?));
                    }
                    Ok(values.join("|"))
                })
                .map_err(|_| invalid())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|_| invalid())?;
            let mut list = list;
            if kind == "table" {
                list.sort();
            }
            description.push(format!("{idx}:{list:?}"));
        }
        result.insert(name, description);
    }
    Ok(result)
}
pub(super) fn check_integrity(c: &Connection) -> CommandResult<()> {
    let mut checks = c.prepare("PRAGMA quick_check").map_err(|_| invalid())?;
    let checks = checks
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|_| invalid())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| invalid())?;
    if checks != ["ok"] {
        return Err(invalid());
    }
    let mut fks = c
        .prepare("PRAGMA foreign_key_check")
        .map_err(|_| invalid())?;
    if fks
        .query([])
        .map_err(|_| invalid())?
        .next()
        .map_err(|_| invalid())?
        .is_some()
    {
        return Err(invalid());
    }
    Ok(())
}
