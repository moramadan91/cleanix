//! 30-day Quarantine: removed junk waits here before it is gone for good, so a clean can be undone.
//! Layout: `<root>/<uuid>/<original file name>`, plus `<root>/index.json` with
//! records of `{original, stored, date}` (date is RFC3339). The index is
//! mutex-protected and written atomically (temporary file, then rename).
//! Everything here is plain std code that takes its root and folders as
//! arguments, so tests run against a temp folder on any system.

use crate::core::{path_starts_with, paths_equal, Places};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How long a stashed item is kept before `purge_expired` removes it for good.
pub const RETENTION_DAYS: u64 = 30;
pub const DAY_SECS: u64 = 86_400;
/// Save temp files younger than this are a live writer's, not orphans.
const TMP_SWEEP_SECS: u64 = 10 * 60;
/// Brief cross-process lock retries before reporting busy (20 x 50 ms).
const LOCK_RETRIES: u32 = 20;
const LOCK_RETRY_WAIT: Duration = Duration::from_millis(50);

/// One stashed file or folder. `id` is the uuid slot directory name (the
/// parent of `stored`) and is derived, never accepted from the UI. `pending`
/// marks a cross-volume copy whose source removal is not yet confirmed (see
/// `stash`); it is cleared once the source is gone.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Record {
    pub original: String,
    pub stored: String,
    pub date: String,
    #[serde(default)]
    pub pending: bool,
}

impl Record {
    pub fn id(&self) -> Option<String> {
        slot_id(Path::new(&self.stored))
    }
}

/// `%LOCALAPPDATA%\Cleanix\Quarantine` on Windows; a home-relative fallback elsewhere
/// (development runs and tests pass an explicit root instead).
pub fn app_root() -> PathBuf {
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        return PathBuf::from(local).join("Cleanix/Quarantine");
    }
    let home = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join("AppData/Local/Cleanix/Quarantine")
}

pub struct Quarantine {
    root: PathBuf,
    retention_days: u64,
    lock: Mutex<Vec<Record>>,
    /// Restore destinations must sit under one of these (the user profile and
    /// the other scanner roots). Defaults come from the environment; tests add
    /// their own temp dir.
    allowed: Vec<PathBuf>,
}

impl Quarantine {
    pub fn with_root(root: PathBuf) -> Self {
        Self::with_allowed_list(root, Places::from_env().restore_roots())
    }

    fn with_allowed_list(root: PathBuf, allowed: Vec<PathBuf>) -> Self {
        let records = fs::read(root.join("index.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let q = Quarantine { root, retention_days: RETENTION_DAYS, lock: Mutex::new(records), allowed };
        q.startup_cleanup();
        q
    }

    pub fn records(&self) -> Vec<Record> {
        self.lock.lock().map(|g| g.clone()).unwrap_or_default()
    }

    /// One startup pass under the exclusive lock: reconcile crash-window
    /// pending records, then sweep orphaned save temp files. When the lock is
    /// busy another process owns the quarantine and does this instead.
    fn startup_cleanup(&self) {
        let Ok(_guard) = self.acquire_lock() else { return };
        self.reconcile_pending_locked();
        self.sweep_tmps_locked();
    }

    /// Best-effort removal of temp index files a crashed save may have left.
    /// Only files older than 10 minutes go: a live writer's temp may still be
    /// mid-save, and files of unknown age are left alone.
    fn sweep_tmps_locked(&self) {
        if let Ok(entries) = fs::read_dir(&self.root) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if !name.starts_with("index.json.tmp.") {
                    continue;
                }
                let old = fs::symlink_metadata(entry.path())
                    .and_then(|md| md.modified())
                    .map(|t| t.elapsed().is_ok_and(|age| age.as_secs() > TMP_SWEEP_SECS))
                    .unwrap_or(false);
                if old {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
    }

    /// Settles cross-volume stash records left `pending` by a crash between
    /// the copy commit and the source removal: a source that still exists
    /// means the removal never ran, so its copy is redundant and goes; a
    /// source that is gone means the removal ran, so the record becomes a
    /// normal one. Caller holds the exclusive lock.
    fn reconcile_pending_locked(&self) {
        let mut records = match self.lock.lock() {
            Ok(guard) => guard,
            Err(_) => return,
        };
        if !records.iter().any(|r| r.pending) {
            return;
        }
        let mut kept = Vec::with_capacity(records.len());
        for mut record in records.drain(..) {
            if record.pending {
                if fs::symlink_metadata(&record.original).is_ok() {
                    if let Some(id) = record.id() {
                        let stored = PathBuf::from(&record.stored);
                        if check_slot(&self.root, &stored, &id).is_ok() {
                            if let Some(slot) = stored.parent() {
                                let _ = fs::remove_dir_all(slot);
                            }
                        }
                    }
                    continue;
                }
                record.pending = false;
            }
            kept.push(record);
        }
        *records = kept;
        let _ = self.save_locked(&records);
    }

    fn save_locked(&self, records: &[Record]) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(records).map_err(|e| e.to_string())?;
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        // Atomic write with a per-process unique temp name: a half-written
        // index must never replace a good one.
        let tmp = self.root.join(format!("index.json.tmp.{}-{}", std::process::id(), SAVE_COUNTER.fetch_add(1, Ordering::Relaxed)));
        fs::write(&tmp, &bytes).map_err(|e| e.to_string())?;
        if let Err(e) = fs::rename(&tmp, self.root.join("index.json")) {
            let _ = fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        Ok(())
    }

    fn locked(&self) -> Result<std::sync::MutexGuard<'_, Vec<Record>>, String> {
        self.lock.lock().map_err(|e| e.to_string())
    }

    /// Runs `op` with the quarantine held across processes: the exclusive
    /// `.lock` file is taken (retrying briefly), the index is reloaded from
    /// disk so another process's commits are visible, then `op` mutates and
    /// commits before the lock is released.
    fn under_lock<R>(&self, op: impl FnOnce() -> Result<R, String>) -> Result<R, String> {
        let _guard = self.acquire_lock()?;
        if let Ok(bytes) = fs::read(self.root.join("index.json")) {
            if let Ok(fresh) = serde_json::from_slice::<Vec<Record>>(&bytes) {
                if let Ok(mut records) = self.lock.lock() {
                    *records = fresh;
                }
            }
        }
        op()
    }

    /// Exclusive cross-process lock: `<root>/.lock` opened with share mode 0
    /// on Windows (no other opener while held). Retried briefly; a lock held
    /// by a live process reports busy instead of blocking the UI.
    fn acquire_lock(&self) -> Result<fs::File, String> {
        let _ = fs::create_dir_all(&self.root);
        let path = self.root.join(".lock");
        for _ in 0..LOCK_RETRIES {
            match open_lock(&path) {
                Ok(file) => return Ok(file),
                Err(_) => std::thread::sleep(LOCK_RETRY_WAIT),
            }
        }
        open_lock(&path).map_err(|e| format!("busy: {e}"))
    }

    /// Moves `path` into a fresh uuid slot, then commits the index. A
    /// cross-volume move copies completely, commits a `pending` record, and
    /// only then removes the source; trees holding reparse points are refused
    /// (Recycle Bin fallback) so a copy can never silently drop a link. The
    /// cross-process lock is held from the reservation through the commit with
    /// the index reloaded first, and the slot is never removed while it holds
    /// the only copy: when the index save fails the item is moved back to its
    /// original location with a no-replace move, or the slot and record are
    /// kept when the way back is gone.
    pub fn stash(&self, path: &Path) -> Result<Record, String> {
        let md = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
        if crate::core::is_link(&md) || (md.is_dir() && contains_link(path)) {
            return Err("reparse".into());
        }
        let name = path
            .file_name()
            .ok_or_else(|| "no file name".to_string())?
            .to_string_lossy()
            .into_owned();
        self.under_lock(|| {
            let mut records = self.locked()?;
            let mut id = new_id();
            while records.iter().any(|r| r.id().as_deref() == Some(&id)) {
                id = new_id();
            }
            let slot = self.root.join(&id);
            fs::create_dir_all(&slot).map_err(|e| e.to_string())?;
            let stored = slot.join(&name);
            match move_no_replace(path, &stored) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::CrossesDevices => {
                    if let Err(e) = copy_all(path, &stored) {
                        let _ = fs::remove_dir_all(&slot);
                        return Err(e.to_string());
                    }
                    if fs::symlink_metadata(&stored).is_err() {
                        let _ = fs::remove_dir_all(&slot);
                        return Err("copy incomplete".into());
                    }
                    // The copy is complete: commit a pending record first, so
                    // a crash before the source removal reconciles on startup
                    // (source present drops the copy, source gone keeps it).
                    let mut record = Record {
                        original: path.to_string_lossy().into_owned(),
                        stored: stored.to_string_lossy().into_owned(),
                        date: format_time(SystemTime::now()),
                        pending: true,
                    };
                    records.push(record.clone());
                    if let Err(e) = self.save_locked(&records) {
                        records.pop();
                        let _ = fs::remove_dir_all(&slot);
                        return Err(e);
                    }
                    // The copy is the good one now: a partial source removal
                    // keeps the record (marked complete) and reports an error.
                    if let Err(e) = remove_all(path) {
                        record.pending = false;
                        if let Some(entry) = records.iter_mut().find(|r| r.stored == record.stored) {
                            entry.pending = false;
                        }
                        let _ = self.save_locked(&records);
                        return Err(format!("remove incomplete: {e}"));
                    }
                    record.pending = false;
                    if let Some(entry) = records.iter_mut().find(|r| r.stored == record.stored) {
                        entry.pending = false;
                    }
                    if let Err(e) = self.save_locked(&records) {
                        return Err(e);
                    }
                    return Ok(record);
                }
                Err(e) => {
                    let _ = fs::remove_dir_all(&slot);
                    return Err(e.to_string());
                }
            }
            let record = Record {
                original: path.to_string_lossy().into_owned(),
                stored: stored.to_string_lossy().into_owned(),
                date: format_time(SystemTime::now()),
                pending: false,
            };
            records.push(record.clone());
            if let Err(e) = self.save_locked(&records) {
                // The slot holds the only copy: move it back when possible
                // (no-replace, so a newcomer there wins), else keep the slot
                // and the record so nothing is lost.
                if move_no_replace(&stored, path).is_ok() {
                    records.pop();
                    let _ = fs::remove_dir_all(&slot);
                }
                return Err(e);
            }
            Ok(record)
        })
    }

    /// Looks a record up by slot id: the id must be uuid-shaped, unique in the
    /// index, and its stored path must sit in this quarantine's slot.
    fn find_in(records: &[Record], root: &Path, id: &str) -> Result<(usize, Record), String> {
        if !is_uuid(id) {
            return Err("unknown item".into());
        }
        let mut found: Option<(usize, Record)> = None;
        for (at, record) in records.iter().enumerate() {
            if record.id().as_deref() == Some(id) {
                if found.is_some() {
                    return Err("unknown item".into());
                }
                found = Some((at, record.clone()));
            }
        }
        let (at, record) = found.ok_or_else(|| "unknown item".to_string())?;
        let stored = PathBuf::from(&record.stored);
        check_slot(root, &stored, id)?;
        Ok((at, record))
    }

    /// Moves a stashed item back to its original path. Fails with "exists" when
    /// something already sits there, so a restore never overwrites user files.
    /// A cross-volume restore copies to a temp sibling on the destination
    /// volume and moves it into place with a no-replace move, then removes the
    /// slot. The destination must be inside the user profile (or another
    /// scanner root), hold no `.`/`..` components, and have no reparse-point
    /// ancestor; anything else is rejected without touching the disk.
    pub fn restore(&self, id: &str) -> Result<Record, String> {
        self.under_lock(|| {
            let mut records = self.locked()?;
            let (at, record) = Self::find_in(&records, &self.root, id)?;
            let original = PathBuf::from(&record.original);
            let stored = PathBuf::from(&record.stored);
            if original == stored || self.root_starts(&original) {
                return Err("unknown item".into());
            }
            // A tampered index could smuggle `..` past the prefix check below
            // while resolving outside the allowed roots.
            if original.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
                return Err("unknown item".into());
            }
            // Any reparse point on the way (junction/symlink) would redirect
            // the restore outside the allowed roots: walk the ancestors that
            // exist, down to the allowed root, and refuse those. Ancestors
            // above the allowed root are trusted system paths, as in
            // `check_slot`. New parents are created only below this chain.
            // Component-wise and case-insensitive, matching Windows.
            let allowed_root = self
                .allowed
                .iter()
                .find(|root| path_starts_with(&original, root))
                .ok_or_else(|| "unknown item".to_string())?;
            for ancestor in original.ancestors().skip(1) {
                if ancestor.as_os_str().is_empty() {
                    break;
                }
                if fs::symlink_metadata(ancestor).is_ok_and(|md| crate::core::is_link(&md)) {
                    return Err("unknown item".into());
                }
                if paths_equal(ancestor, allowed_root) {
                    break;
                }
            }
            if fs::symlink_metadata(&original).is_ok() {
                return Err("exists".into());
            }
            if let Some(parent) = original.parent() {
                if !parent.as_os_str().is_empty() {
                    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
            }
            match move_no_replace(&stored, &original) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    return Err("exists".into());
                }
                Err(e) if e.kind() == std::io::ErrorKind::CrossesDevices => {
                    let parent = original.parent().filter(|p| !p.as_os_str().is_empty()).map(Path::to_path_buf);
                    let tmp = match parent {
                        Some(dir) => dir.join(format!(".cleanix-restore-{}-{}", std::process::id(), RESTORE_COUNTER.fetch_add(1, Ordering::Relaxed))),
                        None => PathBuf::from(format!(".cleanix-restore-{}-{}", std::process::id(), RESTORE_COUNTER.fetch_add(1, Ordering::Relaxed))),
                    };
                    match copy_all(&stored, &tmp).and_then(|_| move_no_replace(&tmp, &original)) {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                            let _ = fs::remove_dir_all(&tmp);
                            let _ = fs::remove_file(&tmp);
                            return Err("exists".into());
                        }
                        Err(e) => {
                            let _ = fs::remove_dir_all(&tmp);
                            let _ = fs::remove_file(&tmp);
                            return Err(e.to_string());
                        }
                    }
                }
                Err(e) => return Err(e.to_string()),
            }
            if let Some(slot) = stored.parent() {
                let _ = fs::remove_dir_all(slot);
            }
            records.remove(at);
            if let Err(e) = self.save_locked(&records) {
                // The file is back where it belongs; keep a retryable record for
                // the missing slot rather than reporting success on a stale index.
                let at = at.min(records.len());
                records.insert(at, record.clone());
                return Err(e);
            }
            Ok(record)
        })
    }

    /// Deletes a stashed item for good (slot directory plus index entry).
    /// Holds the index mutex from lookup through the commit; lock poisoning
    /// surfaces as an error, never a panic.
    pub fn delete(&self, id: &str) -> Result<Record, String> {
        self.under_lock(|| {
            let mut records = self.locked()?;
            let (at, record) = Self::find_in(&records, &self.root, id)?;
            let stored = PathBuf::from(&record.stored);
            let slot = stored.parent().ok_or_else(|| "unknown item".to_string())?.to_path_buf();
            match fs::remove_dir_all(&slot) {
                Ok(()) => {}
                // A missing slot still needs its index entry removed.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.to_string()),
            }
            records.remove(at);
            if let Err(e) = self.save_locked(&records) {
                // Keep the record retryable if the index could not be written.
                let at = at.min(records.len());
                records.insert(at, record.clone());
                return Err(e);
            }
            Ok(record)
        })
    }

    /// Deletes every `id` under one mutex hold, committing once. Slots that
    /// fail validation or removal are skipped; a failed commit keeps every
    /// record so nothing is lost silently.
    pub fn delete_many(&self, ids: &[String]) -> Result<Vec<String>, String> {
        self.under_lock(|| {
            let mut records = self.locked()?;
            let mut removed: Vec<(usize, Record)> = vec![];
            // Collect matches first so index positions stay valid while removing.
            let mut targets: Vec<(usize, Record)> = vec![];
            for id in ids {
                if let Ok((at, record)) = Self::find_in(&records, &self.root, id) {
                    targets.push((at, record));
                }
            }
            targets.sort_by_key(|(at, _)| *at);
            for (at, record) in targets.into_iter().rev() {
                let stored = PathBuf::from(&record.stored);
                let slot = match stored.parent() {
                    Some(slot) => slot.to_path_buf(),
                    None => continue,
                };
                match fs::remove_dir_all(&slot) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(_) => continue,
                }
                records.remove(at);
                removed.push((at, record));
            }
            if removed.is_empty() {
                return Ok(vec![]);
            }
            if let Err(e) = self.save_locked(&records) {
                let mut back = removed;
                back.sort_by_key(|(at, _)| *at);
                for (at, record) in back {
                    let at = at.min(records.len());
                    records.insert(at, record);
                }
                return Err(e);
            }
            let mut ids: Vec<String> = removed.into_iter().filter_map(|(_, r)| r.id()).collect();
            ids.sort();
            Ok(ids)
        })
    }

    fn root_starts(&self, path: &Path) -> bool {
        path_starts_with(path, &self.root)
    }

    /// Deletes only the requested `ids` whose record still exists, whose slot
    /// is still on disk, and whose original location still classifies Safe.
    /// Anything else (moved, reclassified, unknown) is left untouched.
    pub fn delete_safe(&self, ids: &[String], places: &Places, installed: &[String]) -> Result<Vec<String>, String> {
        let safe = safe_ids(&self.records(), ids, places, installed);
        self.delete_many(&safe)
    }

    /// Removes records older than `retention_days`, returning how many went.
    /// Only writes the index when something actually expired.
    pub fn purge_expired(&self, now: SystemTime) -> Result<usize, String> {
        self.under_lock(|| {
        let cutoff = now - Duration::from_secs(self.retention_days * DAY_SECS);
        let expired: Vec<Record> = self
            .locked()?
            .iter()
            .filter(|r| parse_time(&r.date).is_some_and(|t| t <= cutoff))
            .cloned()
            .collect();
        for record in &expired {
            let stored = PathBuf::from(&record.stored);
            if let Some(id) = record.id() {
                if check_slot(&self.root, &stored, &id).is_ok() {
                    if let Some(slot) = stored.parent() {
                        let _ = fs::remove_dir_all(slot);
                    }
                }
            }
        }
        if expired.is_empty() {
            return Ok(0);
        }
        let ids: Vec<Option<String>> = expired.iter().map(|r| r.id()).collect();
        let mut records = self.locked()?;
        records.retain(|r| !ids.contains(&r.id()));
        let removed = expired.len();
        self.save_locked(&records)?;
        Ok(removed)
        })
    }
}

/// The requested `ids` (deduped, in order) whose record still exists, whose
/// slot is still on disk, and whose original location still classifies Safe:
/// the only ones a confirmed delete-safe may remove.
fn safe_ids(records: &[Record], ids: &[String], places: &Places, installed: &[String]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    ids.iter()
        .filter(|id| seen.insert((*id).clone()))
        .filter(|id| {
            records
                .iter()
                .find(|r| r.id().as_deref() == Some(id.as_str()))
                .is_some_and(|r| {
                    fs::symlink_metadata(&r.stored).is_ok()
                        && classify(Path::new(&r.original), places, installed).verdict == Verdict::Safe
                })
        })
        .cloned()
        .collect()
}

/// Uuid-shaped (`8-4-4-4-12` hex) slot ids only.
fn is_uuid(id: &str) -> bool {
    let b = id.as_bytes();
    if b.len() != 36 {
        return false;
    }
    for (i, c) in b.iter().enumerate() {
        let dash = matches!(i, 8 | 13 | 18 | 23);
        if dash != (*c == b'-' as u8) {
            return false;
        }
        if !dash && !c.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

/// The slot must be exactly `<root>/<uuid id>` with no traversal, and neither
/// the quarantine root, the slot, nor the stored item may be a reparse point.
/// Ancestors above the quarantine root are trusted system paths.
fn check_slot(root: &Path, stored: &Path, id: &str) -> Result<(), String> {
    if !is_uuid(id) {
        return Err("unknown item".into());
    }
    let slot = stored.parent().ok_or_else(|| "unknown item".to_string())?;
    if slot.file_name().and_then(|n| n.to_str()) != Some(id) || slot.parent() != Some(root) {
        return Err("unknown item".into());
    }
    for p in [root, slot, stored] {
        if fs::symlink_metadata(p).is_ok_and(|md| crate::core::is_link(&md)) {
            return Err("unknown item".into());
        }
    }
    Ok(())
}

/// True when the tree holds any symlink or junction: such trees are refused
/// by `stash` so a cross-volume copy can never silently drop them.
fn contains_link(path: &Path) -> bool {
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let entry_path = entry.path();
            let Ok(md) = fs::symlink_metadata(&entry_path) else { continue };
            if crate::core::is_link(&md) {
                return true;
            }
            if md.is_dir() {
                stack.push(entry_path);
            }
        }
    }
    false
}

fn slot_id(stored: &Path) -> Option<String> {
    let slot = stored.parent()?;
    let name = slot.file_name()?.to_str()?;
    (!name.is_empty()).then(|| name.to_string())
}

/// Lock-file opener: share mode 0 on Windows means no second opener (in any
/// process) succeeds while the handle is held; elsewhere a plain open.
#[cfg(windows)]
fn open_lock(path: &Path) -> std::io::Result<fs::File> {
    use std::os::windows::fs::OpenOptionsExt;
    fs::OpenOptions::new().create(true).write(true).share_mode(0).open(path)
}

/// Lock-file opener: share mode 0 on Windows means no second opener (in any
/// process) succeeds while the handle is held; elsewhere a plain open.
#[cfg(not(windows))]
fn open_lock(path: &Path) -> std::io::Result<fs::File> {
    fs::OpenOptions::new().create(true).write(true).open(path)
}

/// Same-volume move that never overwrites: flags 0 passes neither
/// MOVEFILE_REPLACE_EXISTING nor MOVEFILE_COPY_ALLOWED, so an existing
/// destination fails instead of being clobbered, and a cross-volume move
/// reports `CrossesDevices` for the copy-to-temp fallback. Error codes are
/// matched by value so the kind never depends on OS-string mapping.
#[cfg(windows)]
fn move_no_replace(src: &Path, dst: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::Storage::FileSystem::MoveFileExW;
    const ERROR_ALREADY_EXISTS: u32 = 183;
    const ERROR_NOT_SAME_DEVICE: u32 = 17;
    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str().encode_wide().chain(Some(0)).collect()
    }
    let (from, to) = (wide(src), wide(dst));
    // SAFETY: both buffers are NUL-terminated and outlive the call.
    let ok = unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), 0) };
    if ok != 0 {
        return Ok(());
    }
    // SAFETY: reading the last-error code of the call above.
    match unsafe { GetLastError() } {
        ERROR_ALREADY_EXISTS => Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "exists")),
        ERROR_NOT_SAME_DEVICE => Err(std::io::Error::new(std::io::ErrorKind::CrossesDevices, "cross-device")),
        code => Err(std::io::Error::from_raw_os_error(code as i32)),
    }
}

/// Same-volume move that never overwrites: flags 0 passes neither
/// MOVEFILE_REPLACE_EXISTING nor MOVEFILE_COPY_ALLOWED, so an existing
/// destination fails instead of being clobbered, and a cross-volume move
/// reports `CrossesDevices` for the copy-to-temp fallback. Error codes are
/// matched by value so the kind never depends on OS-string mapping.
#[cfg(not(windows))]
fn move_no_replace(src: &Path, dst: &Path) -> std::io::Result<()> {
    // No atomic no-replace rename off Windows; callers check existence first.
    fs::rename(src, dst)
}

fn remove_all(path: &Path) -> std::io::Result<()> {
    if fs::symlink_metadata(path)?.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

/// Recursive copy that never follows symlinks or junctions (they stay behind
/// as links are skipped, matching the scanner's policy of never resolving them).
fn copy_all(src: &Path, dst: &Path) -> std::io::Result<()> {
    let md = fs::symlink_metadata(src)?;
    if crate::core::is_link(&md) {
        return Ok(());
    }
    if md.is_dir() {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            copy_all(&entry.path(), &dst.join(entry.file_name()))?;
        }
        Ok(())
    } else if md.is_file() {
        if let Some(parent) = dst.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(src, dst)?;
        Ok(())
    } else {
        Ok(())
    }
}

/* ---------- RFC3339 timestamps (UTC, no new dependency) ---------- */

/// Formats a time as RFC3339 (`2026-01-02T15:04:05Z`).
pub fn format_time(t: SystemTime) -> String {
    let secs = t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let (days, clock) = (secs / DAY_SECS, secs % DAY_SECS);
    let (y, m, d) = ymd(days);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", clock / 3600, clock % 3600 / 60, clock % 60)
}

fn ymd(mut days: u64) -> (u64, u64, u64) {
    // 400 Gregorian years contain 146,097 days.
    let mut year = 1970 + (days / 146_097) * 400;
    days %= 146_097;
    let leap = |y: u64| y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    loop {
        let length = 365 + u64::from(leap(year));
        if days < length {
            break;
        }
        days -= length;
        year += 1;
    }
    let lengths = [31, 28 + u64::from(leap(year)), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for (i, length) in lengths.into_iter().enumerate() {
        if days < length {
            return (year, i as u64 + 1, days + 1);
        }
        days -= length;
    }
    (year, 12, 31)
}

/// Parses RFC3339 (`...Z` or `...+hh:mm`) back to a time; anything else is `None`.
pub fn parse_time(s: &str) -> Option<SystemTime> {
    let (main, offset_secs) = match s.strip_suffix(['Z', 'z']) {
        Some(main) => (main, 0i64),
        None => {
            let at = s.rfind(['+', '-'])?;
            let (main, zone) = s.split_at(at);
            if !main.contains('T') || zone.len() != 6 || zone.as_bytes()[3] != b':' {
                return None;
            }
            let sign: i64 = if zone.starts_with('-') { -1 } else { 1 };
            let hours: i64 = zone[1..3].parse().ok()?;
            let mins: i64 = zone[4..6].parse().ok()?;
            (main, sign * (hours * 3600 + mins * 60))
        }
    };
    let (date, time) = main.split_once('T')?;
    let date: Vec<u64> = date.split('-').map(|n| n.parse().unwrap_or(u64::MAX)).collect();
    let time: Vec<u64> = time.split(':').map(|n| n.parse().unwrap_or(u64::MAX)).collect();
    if date.len() != 3 || time.len() < 2 || date.iter().chain(time.iter()).any(|&n| n == u64::MAX) {
        return None;
    }
    if !(1..=12).contains(&date[1]) || date[2] == 0 || date[2] > 31 || time[0] > 23 || time[1] > 59 {
        return None;
    }
    let secs: u64 = time.get(2).copied().unwrap_or(0);
    if secs > 60 {
        return None;
    }
    let leap = |y: u64| y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    if date[0] < 1970 {
        return None;
    }
    let mut days = (1970..date[0]).map(|y| 365 + u64::from(leap(y))).sum::<u64>();
    let lengths = [31, 28 + u64::from(leap(date[0])), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if date[2] > lengths[date[1] as usize - 1] {
        return None;
    }
    days += lengths[..date[1] as usize - 1].iter().sum::<u64>() + date[2] - 1;
    let total = days as i64 * DAY_SECS as i64 + time[0] as i64 * 3600 + time[1] as i64 * 60 + secs as i64 - offset_secs;
    u64::try_from(total).ok().map(|s| UNIX_EPOCH + Duration::from_secs(s))
}

/* ---------- verdict classifier ---------- */

/// How safe the original location says a quarantined item is to delete for good.
#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Safe,
    Review,
    Unsafe,
}

/// What kind of data the original location held.
#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Cache,
    Logs,
    Settings,
    AppData,
    Document,
    Media,
    Download,
    Other,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Classification {
    pub verdict: Verdict,
    pub kind: Kind,
    /// Full i18n key, e.g. `quarantine.reason.rebuild`.
    pub reason_key: &'static str,
    /// Owning program when one is known (browser caches, installed matches).
    pub app: Option<String>,
}

fn squash(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// Loose folder-to-program match (mirrors `core::is_leftover`): either side may
/// contain the other, with short names ignored.
fn matches_installed(folder: &str, installed: &[String]) -> Option<String> {
    let f = squash(folder);
    if f.len() < 3 {
        return None;
    }
    installed.iter().find_map(|name| {
        let n = squash(name);
        (n.len() >= 3 && (n.contains(&f) || f.contains(&n))).then(|| name.clone())
    })
}

fn result(verdict: Verdict, kind: Kind, reason: &'static str, app: Option<String>) -> Classification {
    Classification { verdict, kind, reason_key: reason, app }
}

/// Classifies a quarantined path by where it came from. Personal Known Folders
/// and every OneDrive root come first (`unsafe`/`review`): a relocated folder
/// must not slip through on its fallback name. Only specific known rebuildable
/// locations are `safe`; generic "Cache"/"Logs" components inside an installed
/// program's own data need a look first.
pub fn classify(original: &Path, places: &Places, installed_names: &[String]) -> Classification {
    let lower = original.to_string_lossy().replace('\\', "/").to_lowercase();
    let parts: Vec<&str> = lower.split('/').filter(|p| !p.is_empty()).collect();
    let file = original.file_name().and_then(|n| n.to_str()).unwrap_or("").to_lowercase();

    // Known Folders, Downloads, and OneDrive roots come only from `places`
    // (resolved once by `Places::from_env`, or a temp profile in tests), so a
    // fake profile classifies the same on every OS. Component-wise and
    // case-insensitive, matching Windows (`C:\Users\Ann` vs `c:\users\ann`).
    let under = |root: &Path| path_starts_with(original, root);

    // Personal Known Folders first: never safe to delete for good.
    if places.document_dirs().iter().any(|d| under(d)) {
        return result(Verdict::Unsafe, Kind::Document, "quarantine.reason.personal", None);
    }
    if places.media_dirs().iter().any(|d| under(d)) {
        return result(Verdict::Unsafe, Kind::Media, "quarantine.reason.personal", None);
    }
    // Every OneDrive root (env vars and "OneDrive - *" profile folders), plus
    // any path component carrying the name, in case the root moved.
    if places.onedrive_roots().iter().any(|d| under(d))
        || parts.iter().any(|p| *p == "onedrive" || p.starts_with("onedrive - "))
    {
        return result(Verdict::Unsafe, Kind::Document, "quarantine.reason.personal", None);
    }
    if under(&places.downloads_dir()) {
        return result(Verdict::Review, Kind::Download, "quarantine.reason.downloads", None);
    }

    let starts_with = under;

    // Temporary folders.
    if starts_with(&places.temp) || places.win_temp.as_ref().is_some_and(|w| starts_with(w)) {
        return result(Verdict::Safe, Kind::Other, "quarantine.reason.temporary", None);
    }

    // Windows Update download cache: redownloadable.
    if lower.contains("softwaredistribution/download") {
        return result(Verdict::Safe, Kind::Download, "quarantine.reason.redownload", None);
    }

    // Crash dumps.
    if file.ends_with(".dmp") || file.ends_with(".mdmp")
        || parts.iter().any(|p| *p == "crashdumps" || *p == "wer")
    {
        return result(Verdict::Safe, Kind::Logs, "quarantine.reason.rebuild", None);
    }

    // Thumbnail caches: Explorer rebuilds them.
    if file.starts_with("thumbcache") || file == "ehthumbs.db" || parts.iter().any(|p| *p == "thumbcachetodelete") {
        return result(Verdict::Safe, Kind::Cache, "quarantine.reason.rebuild", None);
    }

    // Browser and app cache folders, each rebuilt by its app when needed.
    if let Some(found) = browser_cache(&parts) {
        return result(Verdict::Safe, Kind::Cache, "quarantine.reason.rebuild", Some(found));
    }
    if let Some(found) = app_cache(&parts) {
        return result(Verdict::Safe, Kind::Cache, "quarantine.reason.rebuild", Some(found));
    }
    // Package-manager and driver caches, plus iPhone updates (redownloadable).
    if parts.iter().any(|p| ["npm-cache", "d3dscache", "dxcache"].contains(p))
        || lower.contains("pip/cache")
        || lower.contains("yarn/cache")
        || lower.contains("nuget/v3-cache")
        || lower.contains("iphone software updates")
    {
        let app = ["npm-cache", "pip", "yarn", "nuget", "d3dscache", "dxcache"]
            .into_iter()
            .find(|k| lower.contains(k))
            .map(str::to_string);
        return result(Verdict::Safe, Kind::Download, "quarantine.reason.redownload", app);
    }
    // Anything else cache- or log-shaped (a generic "Cache"/"Logs" component
    // inside an installed program's own data) needs a look first: only the
    // specific rebuildable locations above are safe.

    // AppData that is not a known cache: unsafe when it belongs to a
    // still-installed program, review otherwise (settings files are called
    // out as settings). Generic cache/log-shaped content inside an installed
    // program's own data only needs a look first.
    if starts_with(&places.local) || starts_with(&places.roaming) {
        let folder = folder_under_appdata(original, places);
        if let Some(name) = folder.as_deref().and_then(|f| matches_installed(f, installed_names)) {
            if is_generic_cache_or_logs(&parts) {
                return result(Verdict::Review, Kind::AppData, "quarantine.reason.appData", Some(name));
            }
            return result(Verdict::Unsafe, Kind::AppData, "quarantine.reason.installed", Some(name));
        }
        if [".ini", ".cfg", ".conf", ".config", ".plist", ".json", ".xml"].iter().any(|e| file.ends_with(*e)) {
            return result(Verdict::Review, Kind::Settings, "quarantine.reason.settings", folder.clone());
        }
        return result(Verdict::Review, Kind::AppData, "quarantine.reason.appData", folder);
    }

    result(Verdict::Review, Kind::Other, "quarantine.reason.unknown", None)
}

/// Generic cache/log-shaped components: only the specific rebuildable
/// locations are safe, so these need a look first.
fn is_generic_cache_or_logs(parts: &[&str]) -> bool {
    parts.iter().any(|p| ["cache", "caches", "cache2", "code cache", "gpucache", "cacheddata", "logs"].contains(p))
}

fn folder_under_appdata(original: &Path, places: &Places) -> Option<String> {
    // AppData/<Local|Roaming>/<first folder> is the owning folder, in
    // original case for display. Anchored to the stored AppData roots: the
    // test tempdir itself may sit under a real `AppData\...` prefix (Windows
    // CI runs under the real %TEMP%), so a blind search for the first
    // "appdata" component would return the outer "Temp" instead of the
    // owning folder.
    for root in [&places.local, &places.roaming] {
        if path_starts_with(original, root) {
            let depth = root.components().count();
            return original.components().nth(depth).and_then(|c| match c {
                Component::Normal(n) => n.to_str().map(str::to_string),
                _ => None,
            });
        }
    }
    None
}

/// Chromium/Firefox profile cache subfolders, with the owning browser name.
fn browser_cache(parts: &[&str]) -> Option<String> {
    const BROWSERS: &[(&str, &str, &[&str])] = &[
        ("google", "Chrome", &["chrome"]),
        ("microsoft", "Edge", &["edge", "edgemac"]),
        ("bravesoftware", "Brave", &["brave-browser", "brave"]),
        ("vivaldi", "Vivaldi", &["vivaldi"]),
    ];
    const PROFILE_CACHE: &[&str] = &["cache", "code cache", "gpucache", "cachestorage"];
    let lower: Vec<String> = parts.iter().map(|p| p.to_lowercase()).collect();
    for (vendor, name, slugs) in BROWSERS {
        if lower.iter().any(|p| p == vendor || slugs.contains(&p.as_str())) {
            if lower.iter().any(|p| PROFILE_CACHE.contains(&p.as_str()) || *p == "service worker") {
                return Some(name.to_string());
            }
        }
    }
    if lower.contains(&"cache2".to_string()) && lower.contains(&"profiles".to_string()) {
        return Some("Firefox".to_string());
    }
    None
}

/// Known app cache subfolders (mirrors the folders `core::scan_caches` offers).
fn app_cache(parts: &[&str]) -> Option<String> {
    const APPS: &[(&str, &str)] = &[
        ("discord", "Discord"),
        ("slack", "Slack"),
        ("teams", "Teams"),
        ("npm-cache", "npm"),
        ("pip", "pip"),
        ("yarn", "Yarn"),
        ("nuget", "NuGet"),
    ];
    let lower: Vec<String> = parts.iter().map(|p| p.to_lowercase()).collect();
    for (slug, name) in APPS {
        if lower.iter().any(|p| p == slug)
            && lower.iter().any(|p| ["cache", "code cache", "gpucache", "cacheddata"].contains(&p.as_str()))
        {
            return Some(name.to_string());
        }
    }
    if lower.contains(&"code".to_string())
        && lower.iter().any(|p| ["cache", "cacheddata", "code cache", "gpucache"].contains(&p.as_str()))
    {
        return Some("VS Code".to_string());
    }
    if lower.contains(&"spotify".to_string()) && lower.contains(&"data".to_string()) {
        return Some("Spotify".to_string());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn places(root: &Path) -> Places {
        let home = root.join("home");
        let local = home.join("AppData/Local");
        let roaming = home.join("AppData/Roaming");
        Places::test_profile(home, local, roaming, Some(root.join("win-temp")))
    }

    fn write(path: &Path, bytes: usize) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![0u8; bytes]).unwrap();
    }

    /// A quarantine whose restore destinations may be this test's temp dir.
    /// Allowed roots come from the fake profile only: the real environment
    /// (which on Windows covers the temp dir through `TEMP`) must not leak in.
    fn quarantined(root: &Path) -> Quarantine {
        let mut allowed = places(root).restore_roots();
        allowed.push(root.to_path_buf());
        Quarantine::with_allowed_list(root.join("q"), allowed)
    }

    #[test]
    fn stash_restore_roundtrip() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("victim.txt");
        write(&file, 11);
        let record = q.stash(&file).unwrap();
        assert!(!file.exists(), "stash moves the original away");
        assert!(Path::new(&record.stored).is_file());
        assert_eq!(q.records().len(), 1);
        // The index survives a reload.
        assert_eq!(quarantined(t.path()).records(), vec![record.clone()]);
        let id = record.id().expect("slot id");
        assert_eq!(id.len(), 36, "uuid-shaped slot name");
        q.restore(&id).unwrap();
        assert_eq!(fs::read(&file).unwrap().len(), 11);
        assert!(q.records().is_empty());
    }

    #[test]
    fn stash_moves_folders_and_restore_recreates_parents() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let dir = t.path().join("cache-dir");
        write(&dir.join("sub/file.bin"), 40);
        let id = q.stash(&dir).unwrap().id().unwrap();
        assert!(!dir.exists());
        // Original parents deleted in the meantime come back on restore.
        fs::remove_dir_all(dir.parent().unwrap().join("cache-dir")).ok();
        q.restore(&id).unwrap();
        assert_eq!(fs::read(dir.join("sub/file.bin")).unwrap().len(), 40);
    }

    #[test]
    fn restore_refuses_to_overwrite() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("busy.txt");
        write(&file, 3);
        let id = q.stash(&file).unwrap().id().unwrap();
        write(&file, 9);
        assert_eq!(q.restore(&id).unwrap_err(), "exists");
        assert_eq!(q.records().len(), 1, "failed restore keeps the record");
    }

    #[test]
    fn delete_removes_slot_and_record_once() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("gone.txt");
        write(&file, 5);
        let record = q.stash(&file).unwrap();
        let id = record.id().unwrap();
        q.delete(&id).unwrap();
        assert!(!Path::new(&record.stored).exists());
        assert!(!Path::new(&record.stored).parent().unwrap().exists());
        assert!(q.records().is_empty());
        assert!(q.delete(&id).is_err(), "no second delete by id");
    }

    #[test]
    fn unknown_ids_never_touch_the_filesystem() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        for bad in ["", "../index", "a/b", "no-such-id"] {
            assert!(q.restore(bad).is_err());
            assert!(q.delete(bad).is_err());
        }
        assert!(q.records().is_empty());
    }

    #[test]
    fn purge_expired_keeps_fresh_items() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let old = t.path().join("old.txt");
        let fresh = t.path().join("fresh.txt");
        write(&old, 4);
        write(&fresh, 6);
        let old_record = q.stash(&old).unwrap();
        let fresh_id = q.stash(&fresh).unwrap().id().unwrap();
        // Backdate the old record past the 30-day retention.
        {
            let mut records = q.lock.lock().unwrap();
            let entry = records.iter_mut().find(|r| r.original == old_record.original).unwrap();
            entry.date = format_time(SystemTime::now() - Duration::from_secs(31 * DAY_SECS));
            q.save_locked(&records).unwrap();
        }
        assert_eq!(q.purge_expired(SystemTime::now()).unwrap(), 1);
        assert!(!Path::new(&old_record.stored).exists());
        assert_eq!(q.records().len(), 1);
        assert_eq!(q.records()[0].id().unwrap(), fresh_id);
        assert_eq!(q.purge_expired(SystemTime::now()).unwrap(), 0, "second purge writes nothing");
    }

    #[test]
    fn timestamps_roundtrip() {
        let now = SystemTime::now();
        let text = format_time(now);
        assert!(text.ends_with('Z') && text.contains('T'), "{text}");
        let back = parse_time(&text).unwrap();
        assert!(now.duration_since(back).unwrap() < Duration::from_secs(2));
        assert_eq!(parse_time("2024-02-29T00:00:00Z"), Some(UNIX_EPOCH + Duration::from_secs(1_709_164_800)));
        assert_eq!(parse_time("2024-02-29T02:00:00+02:00"), parse_time("2024-02-29T00:00:00Z"));
        for bad in ["", "yesterday", "2024-13-01T00:00:00Z", "2024-02-30T00:00:00Z", "2024-01-01"] {
            assert_eq!(parse_time(bad), None, "{bad}");
        }
    }

    #[test]
    fn ids_are_unique_uuid_shaped() {
        let ids: Vec<String> = (0..50).map(|_| new_id()).collect();
        assert!(ids.iter().all(|id| {
            id.len() == 36 && id.chars().filter(|&c| c == '-').count() == 4 && id.chars().all(|c| c == '-' || c.is_ascii_hexdigit())
        }));
        let mut sorted = ids.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), ids.len());
    }

    fn classified(path: &str, installed: &[&str]) -> Classification {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        let owned: Vec<String> = installed.iter().map(|s| s.to_string()).collect();
        let full = if Path::new(path).is_absolute() { PathBuf::from(path) } else { p.home.join(path) };
        classify(&full, &p, &owned)
    }

    #[test]
    fn safe_cache_like_locations() {
        let p = |s: &str| s.to_string();
        let t = tempfile::tempdir().unwrap();
        let places = places(t.path());
        let join = |base: &Path, rest: &str| base.join(rest.split('/').collect::<Vec<_>>().join("/"));
        let cases = [
            (join(&places.temp, "setup_1/blob.bin"), Verdict::Safe, Kind::Other),
            (join(places.win_temp.as_ref().unwrap(), "MpCmdRun.log"), Verdict::Safe, Kind::Other),
            (places.home.join("AppData/Local/Google/Chrome/User Data/Default/Cache/data_0"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Local/Microsoft/Edge/User Data/Default/Code Cache/js"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Local/BraveSoftware/Brave-Browser/User Data/Default/GPUCache/f"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Roaming/Mozilla/Firefox/Profiles/x.default/cache2/entries"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Roaming/discord/Cache/f"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Roaming/Code/CachedData/x"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Local/Spotify/Data/cache"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Local/Microsoft/Windows/Explorer/thumbcache_256.db"), Verdict::Safe, Kind::Cache),
            (places.home.join("AppData/Local/CrashDumps/app.exe.123.dmp"), Verdict::Safe, Kind::Logs),
            (places.home.join("AppData/Local/Microsoft/Windows/WER/ReportArchive/x"), Verdict::Safe, Kind::Logs),
            (PathBuf::from("C:/Windows/SoftwareDistribution/Download/kb123.cab"), Verdict::Safe, Kind::Download),
        ];
        for (path, verdict, kind) in cases {
            let c = classify(&path, &places, &[]);
            assert_eq!((c.verdict, c.kind), (verdict, kind), "{}", path.display());
        }
        let chrome = classify(
            &places.home.join("AppData/Local/Google/Chrome/User Data/Default/Cache/f"),
            &places,
            &["Google Chrome".into()],
        );
        assert_eq!((chrome.verdict, chrome.app), (Verdict::Safe, Some(p("Chrome"))));
    }

    #[test]
    fn review_appdata_downloads_and_settings() {
        let c = classified("AppData/Roaming/OldGameStudio/save.dat", &[]);
        assert_eq!((c.verdict, c.kind, c.reason_key), (Verdict::Review, Kind::AppData, "quarantine.reason.appData"));
        let c = classified("AppData/Roaming/SomeApp/prefs.ini", &[]);
        assert_eq!((c.verdict, c.kind, c.reason_key), (Verdict::Review, Kind::Settings, "quarantine.reason.settings"));
        let c = classified("Downloads/old-setup.exe", &[]);
        assert_eq!((c.verdict, c.kind, c.reason_key), (Verdict::Review, Kind::Download, "quarantine.reason.downloads"));
        let c = classified("AppData/Roaming/TotallyUnknown/data.bin", &["Zoom Workplace".into()]);
        assert_eq!(c.app.as_deref(), Some("TotallyUnknown"));
    }

    #[test]
    fn unsafe_personal_and_installed() {
        for path in ["Documents/report.docx", "Desktop/photo.jpg", "Pictures/img.png", "Videos/wedding.mp4", "Music/song.mp3"] {
            let c = classified(path, &[]);
            assert_eq!(c.verdict, Verdict::Unsafe, "{path}");
        }
        let c = classified("OneDrive/Documents/notes.txt", &[]);
        assert_eq!((c.verdict, c.reason_key), (Verdict::Unsafe, "quarantine.reason.personal"));
        let c = classified("AppData/Roaming/Zoom/data.db", &["Zoom Workplace".into()]);
        assert_eq!((c.verdict, c.kind, c.reason_key), (Verdict::Unsafe, Kind::AppData, "quarantine.reason.installed"));
        assert_eq!(c.app.as_deref(), Some("Zoom Workplace"));
    }

    #[test]
    fn caches_win_over_installed_matches() {
        // Chrome is installed, but its cache is still safe: cache rules run first.
        let c = classified("AppData/Local/Google/Chrome/User Data/Default/Cache/f", &["Google Chrome".into()]);
        assert_eq!((c.verdict, c.kind), (Verdict::Safe, Kind::Cache));
    }

    #[test]
    fn unknown_paths_need_review() {
        let c = classified("WeirdFolder/blob.bin", &[]);
        assert_eq!((c.verdict, c.kind, c.reason_key), (Verdict::Review, Kind::Other, "quarantine.reason.unknown"));
    }

    #[test]
    fn generic_cache_and_logs_inside_programs_need_review() {
        // Only the specific rebuildable locations are safe; a generic Cache or
        // Logs component inside an installed program's own data needs a look.
        let c = classified("AppData/Local/SomeApp/Logs/today.log", &["SomeApp".into()]);
        assert_eq!((c.verdict, c.kind), (Verdict::Review, Kind::AppData));
        let c = classified("AppData/Local/SomeApp/Cache/data", &["SomeApp".into()]);
        assert_eq!((c.verdict, c.kind, c.reason_key), (Verdict::Review, Kind::AppData, "quarantine.reason.appData"));
        let c = classified("AppData/Local/Zoom/Cache/data", &["Zoom Workplace".into()]);
        assert_eq!((c.verdict, c.kind), (Verdict::Review, Kind::AppData));
        let c = classified("AppData/Roaming/Zoom/Cache/blob", &["Zoom Workplace".into()]);
        assert_eq!((c.verdict, c.kind), (Verdict::Review, Kind::AppData));
    }

    #[test]
    fn onedrive_roots_are_unsafe_first() {
        let t = tempfile::tempdir().unwrap();
        let mut p = places(t.path());
        let od = t.path().join("od-root-9f3");
        fs::create_dir_all(&od).unwrap();
        // Stored roots only: no env vars, so parallel tests cannot interfere.
        p.onedrive.push(od.clone());
        let c = classify(&od.join("Documents/report.docx"), &p, &[]);
        assert_eq!((c.verdict, c.kind), (Verdict::Unsafe, Kind::Document));
        // A "OneDrive - *" business folder in the profile is unsafe even with
        // no stored root.
        let c = classified("OneDrive - Acme/notes.txt", &[]);
        assert_eq!((c.verdict, c.reason_key), (Verdict::Unsafe, "quarantine.reason.personal"));
    }

    #[test]
    fn restore_outside_allowed_roots_is_rejected() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("victim.txt");
        write(&file, 7);
        let id = q.stash(&file).unwrap().id().unwrap();
        // The same index without the temp dir allowed: the destination is no
        // longer inside an allowed root. Allowed roots come from the fake
        // profile only, never the real environment.
        let strict = Quarantine::with_allowed_list(t.path().join("q"), places(t.path()).restore_roots());
        assert_eq!(strict.restore(&id).unwrap_err(), "unknown item");
        assert!(q.records().iter().any(|r| r.id().as_deref() == Some(&id)), "record kept");
        assert!(Path::new(&q.records()[0].stored).is_file(), "slot untouched");
    }

    #[test]
    fn stash_refuses_reparse_trees() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let dir = t.path().join("treedir");
        write(&dir.join("real.bin"), 5);
        #[cfg(unix)]
        std::os::unix::fs::symlink(t.path().join("elsewhere"), dir.join("link")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(t.path().join("elsewhere"), dir.join("link")).unwrap();
        assert_eq!(q.stash(&dir).unwrap_err(), "reparse");
        assert!(dir.join("real.bin").is_file(), "source left intact");
        assert!(q.records().is_empty());
    }

    #[test]
    fn duplicate_ids_are_rejected() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("dup.txt");
        write(&file, 4);
        let id = q.stash(&file).unwrap().id().unwrap();
        {
            let mut records = q.locked().unwrap();
            let mut clone = records[0].clone();
            clone.date = format_time(SystemTime::now());
            records.push(clone);
            q.save_locked(&records).unwrap();
        }
        assert!(q.restore(&id).is_err());
        assert!(q.delete(&id).is_err());
        assert_eq!(q.records().len(), 2, "nothing removed on ambiguous ids");
    }

    #[test]
    fn restore_rejects_dotdot_destinations() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("victim.txt");
        write(&file, 7);
        let id = q.stash(&file).unwrap().id().unwrap();
        {
            let mut records = q.locked().unwrap();
            let entry = records.iter_mut().find(|r| r.id().as_deref() == Some(&id)).unwrap();
            entry.original = t.path().join("sub/../evil.txt").to_string_lossy().into_owned();
            q.save_locked(&records).unwrap();
        }
        // Lexically still under the allowed root, but `..` escapes it.
        assert_eq!(q.restore(&id).unwrap_err(), "unknown item");
        assert!(Path::new(&q.records()[0].stored).is_file(), "slot untouched");
    }

    #[test]
    fn restore_rejects_reparse_point_ancestors() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let real = t.path().join("real-target");
        fs::create_dir_all(&real).unwrap();
        let file = t.path().join("victim.txt");
        write(&file, 4);
        let id = q.stash(&file).unwrap().id().unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&real, t.path().join("linkdir")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir(&real, t.path().join("linkdir")).unwrap();
        {
            let mut records = q.locked().unwrap();
            let entry = records.iter_mut().find(|r| r.id().as_deref() == Some(&id)).unwrap();
            entry.original = t.path().join("linkdir/restored.txt").to_string_lossy().into_owned();
            q.save_locked(&records).unwrap();
        }
        assert_eq!(q.restore(&id).unwrap_err(), "unknown item");
        assert!(Path::new(&q.records()[0].stored).is_file(), "slot untouched");
    }

    #[test]
    fn pending_without_source_becomes_normal() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("victim.txt");
        write(&file, 6);
        let id = q.stash(&file).unwrap().id().unwrap();
        // Simulate a crash between the pending commit and the source removal
        // where the removal did run: the source is gone.
        {
            let mut records = q.locked().unwrap();
            records.iter_mut().find(|r| r.id().as_deref() == Some(&id)).unwrap().pending = true;
            q.save_locked(&records).unwrap();
        }
        drop(q);
        let again = quarantined(t.path());
        let record = again.records().into_iter().find(|r| r.id().as_deref() == Some(&id)).unwrap();
        assert!(!record.pending, "source gone: kept as a normal record");
        assert!(Path::new(&record.stored).is_file(), "copy kept");
    }

    #[test]
    fn pending_with_source_drops_the_copy() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let file = t.path().join("victim.txt");
        write(&file, 6);
        let record = q.stash(&file).unwrap();
        let id = record.id().unwrap();
        // Simulate a crash between the pending commit and the source removal
        // where the removal never ran: the source is still there.
        write(&file, 6);
        {
            let mut records = q.locked().unwrap();
            records.iter_mut().find(|r| r.id().as_deref() == Some(&id)).unwrap().pending = true;
            q.save_locked(&records).unwrap();
        }
        drop(q);
        let again = quarantined(t.path());
        assert!(again.records().is_empty(), "source present: redundant copy dropped");
        assert!(!Path::new(&record.stored).exists());
        assert!(file.is_file(), "source left alone");
    }

    #[test]
    fn fresh_save_tmps_survive_startup() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("q");
        fs::create_dir_all(&root).unwrap();
        let tmp = root.join("index.json.tmp.1-1");
        fs::write(&tmp, b"[]").unwrap();
        let _ = Quarantine::with_root(root);
        assert!(tmp.is_file(), "a live writer's temp is not swept");
    }

    #[test]
    fn delete_safe_only_removes_live_safe_ids() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        let q = quarantined(t.path());
        let stash_temp = |name: &str| {
            let file = p.temp.join(name);
            write(&file, 9);
            q.stash(&file).unwrap()
        };
        let (ra, rb, rc) = (stash_temp("a.bin"), stash_temp("b.bin"), stash_temp("c.bin"));
        let (ida, idb, idc) = (ra.id().unwrap(), rb.id().unwrap(), rc.id().unwrap());
        // b's slot vanished behind our back: its record must stay.
        fs::remove_dir_all(Path::new(&rb.stored).parent().unwrap()).unwrap();
        // a's original is personal now: reclassified away from Safe.
        {
            let mut records = q.locked().unwrap();
            let entry = records.iter_mut().find(|r| r.id().as_deref() == Some(&ida)).unwrap();
            entry.original = p.home.join("Documents/report.docx").to_string_lossy().into_owned();
            q.save_locked(&records).unwrap();
        }
        let removed = q.delete_safe(&[ida, idb, idc.clone(), "bogus".into()], &p, &[]).unwrap();
        assert_eq!(removed, vec![idc]);
        assert_eq!(q.records().len(), 2, "skipped records stay");
    }

    #[test]
    fn delete_many_removes_each_slot_with_one_commit() {
        let t = tempfile::tempdir().unwrap();
        let q = quarantined(t.path());
        let mut stored = vec![];
        let mut ids = vec![];
        for name in ["a.txt", "b.txt"] {
            let file = t.path().join(name);
            write(&file, 3);
            let record = q.stash(&file).unwrap();
            stored.push(record.stored.clone());
            ids.push(record.id().unwrap());
        }
        let gone = q.delete_many(&ids).unwrap();
        assert_eq!(gone.len(), 2);
        for s in &stored {
            assert!(!Path::new(s).exists());
        }
        assert!(q.records().is_empty());
        assert!(q.delete_many(&ids).unwrap().is_empty(), "second run removes nothing");
    }
}

static ID_COUNTER: AtomicU64 = AtomicU64::new(0);
static SAVE_COUNTER: AtomicU64 = AtomicU64::new(0);
static RESTORE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Unique slot name in uuid shape (8-4-4-4-12 hex) without a new dependency.
fn new_id() -> String {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mix = nanos
        ^ ((std::process::id() as u128) << 64)
        ^ ((ID_COUNTER.fetch_add(1, Ordering::Relaxed) as u128) << 96);
    let h = format!("{mix:032x}");
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}
