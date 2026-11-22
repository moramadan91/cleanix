//! Scanners and the delete gate. Pure std code that takes its folders from `Places`, so tests run
//! against a temp folder and never touch a real profile.

use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Safety {
    Safe,
    Review,
    Risky,
}

#[derive(Serialize, Clone, Debug)]
pub struct ScanItem {
    pub path: String,
    pub name: String,
    pub bytes: u64,
    /// Group key: translated by the UI when it knows it ("temp", "downloads"...), shown as is otherwise
    /// (app names such as "Chrome").
    pub group: String,
    pub safety: Safety,
}

#[derive(Serialize, Clone, Debug)]
pub struct DiskNode {
    pub path: String,
    pub name: String,
    pub bytes: u64,
    pub dir: bool,
    pub safety: Safety,
}

#[derive(Serialize, Default, Debug)]
pub struct CleanResult {
    pub freed: u64,
    pub removed: Vec<String>,
    pub failed: Vec<String>,
}

/// The user's folders. On Windows they come from the environment; tests build their own.
#[derive(Clone, Debug)]
pub struct Places {
    pub home: PathBuf,
    pub local: PathBuf,
    pub roaming: PathBuf,
    pub temp: PathBuf,
    /// C:\Windows\Temp, when known.
    pub win_temp: Option<PathBuf>,
}

impl Places {
    pub fn from_env() -> Places {
        let var = |k: &str| std::env::var_os(k).map(PathBuf::from);
        let home = var("USERPROFILE").or_else(|| var("HOME")).unwrap_or_else(|| PathBuf::from("."));
        let local = var("LOCALAPPDATA").unwrap_or_else(|| home.join("AppData/Local"));
        let roaming = var("APPDATA").unwrap_or_else(|| home.join("AppData/Roaming"));
        let temp = var("TEMP").filter(|_| cfg!(windows)).unwrap_or_else(|| local.join("Temp"));
        let win_temp = var("WINDIR").map(|w| w.join("Temp"));
        Places { home, local, roaming, temp, win_temp }
    }

    fn user_roots(&self) -> [&Path; 3] {
        [&self.home, &self.local, &self.roaming]
    }

    /// Folders a removal may ever reach into.
    fn roots(&self) -> impl Iterator<Item = &Path> {
        self.user_roots().into_iter().chain(self.win_temp.as_deref())
    }

    fn contains_unlinked(&self, path: &Path) -> bool {
        self.roots().filter(|root| path.starts_with(root))
            .min_by_key(|root| root.components().count())
            .is_some_and(|root| within_user_folder(path, root))
    }
}

/// Symlinks and junctions are never followed: they can point anywhere, including system folders.
pub(crate) fn is_link(md: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        if md.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return true;
        }
    }
    md.file_type().is_symlink()
}

/// Size on disk of a file or a folder tree (unreadable parts count as 0).
pub fn size_of(path: &Path) -> u64 {
    let Ok(md) = fs::symlink_metadata(path) else { return 0 };
    if is_link(&md) {
        return 0;
    }
    if !md.is_dir() {
        return md.len();
    }
    let mut total = 0;
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let Ok(md) = fs::symlink_metadata(e.path()) else { continue };
            if is_link(&md) {
                continue;
            }
            if md.is_dir() {
                stack.push(e.path());
            } else {
                total += md.len();
            }
        }
    }
    total
}

fn name_of(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| p.display().to_string())
}

fn item(path: PathBuf, bytes: u64, group: &str, safety: Safety) -> ScanItem {
    ScanItem { name: name_of(&path), path: path.to_string_lossy().into_owned(), bytes, group: group.into(), safety }
}

pub(crate) fn children(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir).map(|r| r.flatten().map(|e| e.path()).collect()).unwrap_or_default()
}

/// Everything inside temp and crash-report folders, one row per entry.
pub fn scan_junk(p: &Places) -> Vec<ScanItem> {
    let roots = [
        (p.temp.clone(), "temp"),
        (p.local.join("Temp"), "temp"),
        (p.local.join("CrashDumps"), "crash"),
        (p.local.join("Microsoft/Windows/WER"), "crash"),
        (p.local.join("Microsoft/Windows/INetCache"), "inet"),
    ];
    let mut seen = std::collections::HashSet::new();
    let mut out = vec![];
    let win_temp = p.win_temp.iter().map(|root| (root.clone(), "winTemp"));
    for (root, group) in roots.into_iter().chain(win_temp) {
        if p.user_roots().iter().any(|user_root| user_root.starts_with(&root))
            || !p.contains_unlinked(&root)
            || !seen.insert(root.clone())
        {
            continue;
        }
        for c in children(&root) {
            let bytes = size_of(&c);
            if bytes > 0 {
                out.push(item(c, bytes, group, Safety::Safe));
            }
        }
    }
    out
}

/// Cache folders of browsers and common apps. Each folder is rebuilt by its app when needed.
pub fn scan_caches(p: &Places) -> Vec<ScanItem> {
    let mut out = vec![];
    let mut add = |dir: PathBuf, group: &str| {
        if !p.contains_unlinked(&dir) {
            return;
        }
        let bytes = size_of(&dir);
        if bytes > 0 {
            out.push(item(dir, bytes, group, Safety::Safe));
        }
    };
    // Chromium browsers keep one cache set per profile ("Default", "Profile 1"...).
    let chromium = [
        ("Chrome", p.local.join("Google/Chrome/User Data")),
        ("Edge", p.local.join("Microsoft/Edge/User Data")),
        ("Brave", p.local.join("BraveSoftware/Brave-Browser/User Data")),
        ("Vivaldi", p.local.join("Vivaldi/User Data")),
    ];
    for (name, data) in chromium {
        for profile in children(&data) {
            let n = name_of(&profile);
            if n != "Default" && !n.starts_with("Profile ") {
                continue;
            }
            for sub in ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"] {
                add(profile.join(sub), name);
            }
        }
    }
    for profile in children(&p.local.join("Mozilla/Firefox/Profiles")) {
        add(profile.join("cache2"), "Firefox");
    }
    let apps: [(&str, PathBuf, &[&str]); 6] = [
        ("Discord", p.roaming.join("discord"), &["Cache", "Code Cache", "GPUCache"]),
        ("Slack", p.roaming.join("Slack"), &["Cache", "Code Cache", "GPUCache"]),
        ("Teams", p.roaming.join("Microsoft/Teams"), &["Cache", "Code Cache", "GPUCache"]),
        ("VS Code", p.roaming.join("Code"), &["Cache", "CachedData", "Code Cache", "GPUCache"]),
        ("Spotify", p.local.join("Spotify"), &["Data"]),
        ("DirectX", p.local.clone(), &["D3DSCache", "NVIDIA/DXCache", "AMD/DxCache"]),
    ];
    for (name, base, subs) in apps {
        for sub in subs {
            add(base.join(sub), name);
        }
    }
    for (dir, group) in extra_cache_paths(p) {
        add(dir, group);
    }
    for root in backup_roots(p) {
        if !p.contains_unlinked(&root) {
            continue;
        }
        for dir in children(&root) {
            let Ok(md) = fs::symlink_metadata(&dir) else { continue };
            if !md.is_dir() || is_link(&md) {
                continue;
            }
            let info = dir.join("Info.plist");
            let name = fs::symlink_metadata(&info).ok()
                .filter(|m| m.is_file() && !is_link(m))
                .and_then(|_| fs::read_to_string(info).ok())
                .and_then(|xml| device_name(&xml));
            let bytes = size_of(&dir);
            let mut backup = item(dir, bytes, "iosBackups", Safety::Review);
            if let (Some(name), Some(date)) = (name, md.modified().ok().and_then(date_string)) {
                backup.name = format!("{name} · {date}");
            }
            out.push(backup);
        }
    }
    out
}

fn extra_cache_paths(p: &Places) -> [(PathBuf, &'static str); 5] {
    [
        (p.local.join("npm-cache"), "npm"),
        (p.local.join("pip/Cache"), "pip"),
        (p.local.join("Yarn/Cache"), "Yarn"),
        (p.local.join("NuGet/v3-cache"), "NuGet"),
        (p.roaming.join("Apple Computer/iTunes/iPhone Software Updates"), "iosUpdates"),
    ]
}

fn backup_roots(p: &Places) -> [PathBuf; 2] {
    [p.roaming.join("Apple Computer/MobileSync/Backup"), p.home.join("Apple/MobileSync/Backup")]
}

pub fn device_name(xml: &str) -> Option<String> {
    let mut tail = xml;
    while let Some((_, key)) = tail.split_once("<key>") {
        let (label, rest) = key.split_once("</key>")?;
        tail = rest;
        if label.trim() != "Device Name" {
            continue;
        }
        let (mut text, _) = rest.trim_start().strip_prefix("<string>")?.split_once("</string>")?;
        let mut name = String::new();
        while let Some((plain, entity)) = text.split_once('&') {
            name.push_str(plain);
            let (entity, rest) = entity.split_once(';')?;
            name.push(match entity {
                "amp" => '&', "lt" => '<', "gt" => '>', "quot" => '"', "apos" => '\'',
                n if n.starts_with("#x") => char::from_u32(u32::from_str_radix(&n[2..], 16).ok()?)?,
                n if n.starts_with('#') => char::from_u32(n[1..].parse().ok()?)?,
                _ => return None,
            });
            text = rest;
        }
        name.push_str(text);
        let name = name.trim();
        return (!name.is_empty()).then(|| name.to_string());
    }
    None
}

fn date_string(time: SystemTime) -> Option<String> {
    let seconds = time.duration_since(SystemTime::UNIX_EPOCH).ok()?.as_secs();
    let mut days = seconds / 86_400;
    // 400 Gregorian years contain 146,097 days.
    let mut year = 1970 + (days / 146_097) * 400;
    days %= 146_097;
    let leap = |y| y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    loop {
        let length = 365 + u64::from(leap(year));
        if days < length { break; }
        days -= length;
        year += 1;
    }
    for (month, length) in [31, 28 + u64::from(leap(year)), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].into_iter().enumerate() {
        if days < length { return Some(format!("{year:04}-{:02}-{:02}", month + 1, days + 1)); }
        days -= length;
    }
    None
}

/// Downloads untouched for `days`: the user decides, so they start unticked.
pub fn scan_old_downloads(p: &Places, days: u64, now: SystemTime) -> Vec<ScanItem> {
    let limit = Duration::from_secs(days * 86_400);
    children(&p.home.join("Downloads"))
        .into_iter()
        .filter(|c| {
            fs::symlink_metadata(c)
                .and_then(|m| m.modified())
                .map(|t| now.duration_since(t).unwrap_or_default() >= limit)
                .unwrap_or(false)
        })
        .map(|c| {
            let b = size_of(&c);
            item(c, b, "downloads", Safety::Review)
        })
        .filter(|i| i.bytes > 0)
        .collect()
}

/// Every regular file in the user's own folders (AppData and dot-folders are apps' business, skipped).
fn user_files(p: &Places, mut f: impl FnMut(PathBuf, &fs::Metadata)) {
    let mut stack = vec![p.home.clone()];
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let Ok(md) = fs::symlink_metadata(e.path()) else { continue };
            if is_link(&md) {
                continue;
            }
            let path = e.path();
            if md.is_dir() {
                let n = name_of(&path);
                if path != p.local && path != p.roaming && n != "AppData" && !n.starts_with('.') {
                    stack.push(path);
                }
            } else {
                f(path, &md);
            }
        }
    }
}

/// Single files of at least `min` bytes in the user's folders.
pub fn scan_large(p: &Places, min: u64) -> Vec<ScanItem> {
    let mut out = vec![];
    user_files(p, |path, md| {
        if md.len() >= min {
            out.push(item(path, md.len(), "large", Safety::Review));
        }
    });
    out
}

/// Exact copies (same size, then same content) of files of at least `min` bytes.
/// The oldest copy stays off the list; the others are offered, grouped under the kept file's name.
pub fn scan_duplicates(p: &Places, min: u64) -> Vec<ScanItem> {
    use std::hash::{DefaultHasher, Hasher};
    let mut by_size: HashMap<u64, Vec<(PathBuf, SystemTime)>> = HashMap::new();
    user_files(p, |path, md| {
        if md.len() >= min {
            by_size.entry(md.len()).or_default().push((path, md.modified().unwrap_or(SystemTime::UNIX_EPOCH)));
        }
    });
    let hash = |path: &Path| -> Option<u64> {
        let mut f = fs::File::open(path).ok()?;
        let mut h = DefaultHasher::new();
        let mut buf = vec![0u8; 1 << 16];
        loop {
            let n = std::io::Read::read(&mut f, &mut buf).ok()?;
            if n == 0 {
                return Some(h.finish());
            }
            h.write(&buf[..n]);
        }
    };
    let mut out = vec![];
    for (size, files) in by_size {
        if files.len() < 2 {
            continue;
        }
        let mut by_hash: HashMap<u64, Vec<(PathBuf, SystemTime)>> = HashMap::new();
        for (path, t) in files {
            if let Some(h) = hash(&path) {
                by_hash.entry(h).or_default().push((path, t));
            }
        }
        for (_, mut same) in by_hash {
            if same.len() < 2 {
                continue;
            }
            same.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
            let keep = name_of(&same[0].0);
            out.extend(same.into_iter().skip(1).map(|(path, _)| item(path, size, &keep, Safety::Review)));
        }
    }
    out
}

/// Browser history and cookies. Removing cookies signs you out of sites, so both need the user's eye.
pub fn scan_privacy(p: &Places) -> Vec<ScanItem> {
    let mut out = vec![];
    let chromium = [
        ("Chrome", p.local.join("Google/Chrome/User Data")),
        ("Edge", p.local.join("Microsoft/Edge/User Data")),
        ("Brave", p.local.join("BraveSoftware/Brave-Browser/User Data")),
        ("Vivaldi", p.local.join("Vivaldi/User Data")),
    ];
    for (name, data) in chromium {
        for profile in children(&data) {
            let n = name_of(&profile);
            if n != "Default" && !n.starts_with("Profile ") {
                continue;
            }
            for f in ["History", "Network/Cookies", "Cookies"] {
                let path = profile.join(f);
                if let Ok(md) = fs::metadata(&path) {
                    out.push(item(path, md.len(), name, Safety::Review));
                }
            }
        }
    }
    // Firefox keeps bookmarks in places.sqlite, so only its cookies are offered.
    for profile in children(&p.roaming.join("Mozilla/Firefox/Profiles")) {
        let path = profile.join("cookies.sqlite");
        if let Ok(md) = fs::metadata(&path) {
            out.push(item(path, md.len(), "Firefox", Safety::Review));
        }
    }
    out
}

/// Lowercase letters and digits only, for loose name matching.
fn squash(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// Folders Windows and common runtimes own; never called leftovers.
const KEEP_DIRS: &[&str] = &[
    "microsoft", "packages", "temp", "programs", "crashdumps", "connecteddevicesplatform", "comms", "d3dscache",
    "virtualstore", "publishers", "history", "packagecache", "windows", "nvidia", "amd", "intel", "pip", "npmcache",
    "npm", "fontcache", "identityservices", "peernetworking", "elevateddiagnostics", "placeholdertilelogofolder",
    "squirreltemp", "mozilla", "google", "apple", "adobe", "java", "sun", "oracle",
];

/// A folder name that matches no installed program's name or publisher (and is not Windows' own).
pub fn is_leftover(folder: &str, installed: &[String]) -> bool {
    let f = squash(folder);
    if f.len() < 3 || KEEP_DIRS.contains(&f.as_str()) {
        return false;
    }
    !installed.iter().map(|n| squash(n)).any(|n| n.len() >= 3 && (n.contains(&f) || f.contains(&n)))
}

/// AppData folders untouched for `days` that belong to no installed program.
pub fn scan_leftovers(p: &Places, installed: &[String], days: u64, now: SystemTime) -> Vec<ScanItem> {
    let limit = Duration::from_secs(days * 86_400);
    let mut out = vec![];
    for (group, base) in [("local", &p.local), ("roaming", &p.roaming)] {
        for dir in children(base) {
            let Ok(md) = fs::symlink_metadata(&dir) else { continue };
            let old = md.modified().map(|t| now.duration_since(t).unwrap_or_default() >= limit).unwrap_or(false);
            if !md.is_dir() || is_link(&md) || !old || !is_leftover(&name_of(&dir), installed) {
                continue;
            }
            let bytes = size_of(&dir);
            if bytes > 0 {
                out.push(item(dir, bytes, group, Safety::Review));
            }
        }
    }
    out
}

/// How safe removing something is, for the disk map.
pub fn advise(path: &Path, p: &Places) -> Safety {
    if p.roots().any(|root| path == root) {
        return Safety::Risky;
    }
    if backup_roots(p).iter().any(|root| path.starts_with(root) && path != root) {
        return Safety::Review;
    }
    if extra_cache_paths(p).iter().any(|(root, _)| path.starts_with(root)) {
        return Safety::Safe;
    }
    if !path.starts_with(&p.home) {
        return Safety::Risky;
    }
    // AppData itself and its first level hold app settings and data: not for a quick delete.
    let appdata = p.home.join("AppData");
    let parent = path.parent();
    if path == appdata || path == p.local || path == p.roaming
        || parent == Some(appdata.as_path()) || parent == Some(p.local.as_path()) || parent == Some(p.roaming.as_path())
        || name_of(path).to_lowercase().starts_with("ntuser")
    {
        return Safety::Risky;
    }
    // Only names below home count: home itself may sit under a "Temp" folder (tests do).
    let rel = path.strip_prefix(&p.home).unwrap_or(path);
    let cache_like = rel.components().any(|c| {
        let s = c.as_os_str().to_string_lossy().to_lowercase();
        matches!(s.as_str(), "cache" | "cache2" | "code cache" | "gpucache" | "temp" | "tmp" | "crashdumps" | "npm-cache")
    });
    if cache_like || (path.starts_with(&p.temp) && path != p.temp) {
        return Safety::Safe;
    }
    Safety::Review
}

/// One level of the disk map: the entries of `dir`, largest first, each sized in parallel.
pub fn disk_children(dir: &Path, p: &Places) -> Vec<DiskNode> {
    let entries = children(dir);
    let sizes: Vec<u64> = std::thread::scope(|s| {
        let handles: Vec<_> = entries.iter().map(|e| s.spawn(move || size_of(e))).collect();
        handles.into_iter().map(|h| h.join().unwrap_or(0)).collect()
    });
    let mut nodes: Vec<DiskNode> = entries
        .into_iter()
        .zip(sizes)
        .filter(|(_, b)| *b > 0)
        .map(|(e, bytes)| {
            let dir = fs::symlink_metadata(&e).map(|m| m.is_dir() && !is_link(&m)).unwrap_or(false);
            DiskNode { name: name_of(&e), safety: advise(&e, p), path: e.to_string_lossy().into_owned(), bytes, dir }
        })
        .collect();
    nodes.sort_by(|a, b| b.bytes.cmp(&a.bytes));
    nodes
}

/// What the UI was shown. A removal is only accepted for a path listed here and not marked risky,
/// so the page can never ask to delete a path the app did not offer.
#[derive(Default)]
pub struct Offered(pub HashMap<PathBuf, Safety>);

impl Offered {
    pub fn add_items(&mut self, items: &[ScanItem]) {
        for i in items {
            self.0.insert(PathBuf::from(&i.path), i.safety);
        }
    }
    pub fn add_nodes(&mut self, nodes: &[DiskNode]) {
        for n in nodes {
            self.0.insert(PathBuf::from(&n.path), n.safety);
        }
    }
}

// Check each step below a user root so a junction cannot take disposal outside it.
fn within_user_folder(path: &Path, root: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(root) else { return false };
    let mut current = root.to_path_buf();
    let unlinked = |p: &Path| fs::symlink_metadata(p).is_ok_and(|m| !is_link(&m));
    if !unlinked(current.as_path()) {
        return false;
    }
    relative.components().all(|part| {
        let std::path::Component::Normal(name) = part else { return false };
        current.push(name);
        unlinked(current.as_path())
    })
}

/// Removes `paths` with `dispose` (the Recycle Bin in the app) after checking each one:
/// offered by a scan, not risky, strictly inside an allowed root, not a link.
pub fn remove(
    paths: &[String],
    offered: &Offered,
    places: &Places,
    dispose: impl Fn(&Path) -> Result<(), String>,
) -> CleanResult {
    let mut r = CleanResult::default();
    for raw in paths {
        let path = PathBuf::from(raw);
        let allowed = matches!(offered.0.get(&path), Some(Safety::Safe | Safety::Review))
            && !places.roots().any(|root| path == root)
            && places.contains_unlinked(&path);
        if !allowed {
            r.failed.push(raw.clone());
            continue;
        }
        let bytes = size_of(&path);
        if !places.contains_unlinked(&path) {
            r.failed.push(raw.clone());
            continue;
        }
        match dispose(&path) {
            Ok(()) => {
                r.freed += bytes;
                r.removed.push(raw.clone());
            }
            Err(_) => r.failed.push(raw.clone()),
        }
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    fn places(root: &Path) -> Places {
        let home = root.join("home");
        let local = home.join("AppData/Local");
        let roaming = home.join("AppData/Roaming");
        Places { temp: local.join("Temp"), home, local, roaming, win_temp: None }
    }

    fn write(path: &Path, bytes: usize) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![0u8; bytes]).unwrap();
    }

    fn rm(p: &Path) -> Result<(), String> {
        if p.is_dir() { fs::remove_dir_all(p) } else { fs::remove_file(p) }.map_err(|e| e.to_string())
    }

    #[test]
    fn junk_lists_temp_entries_once() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        write(&p.temp.join("a.tmp"), 100);
        write(&p.temp.join("dir/b.tmp"), 50);
        write(&p.local.join("CrashDumps/x.dmp"), 10);
        let items = scan_junk(&p);
        assert_eq!(items.len(), 3, "temp is listed once even though TEMP == Local\\Temp");
        assert_eq!(items.iter().map(|i| i.bytes).sum::<u64>(), 160);
        assert!(items.iter().all(|i| i.safety == Safety::Safe));
    }

    #[test]
    fn windows_temp_offers_entries_but_cannot_remove_the_root() {
        let t = tempfile::tempdir().unwrap();
        let mut p = places(t.path());
        let root = t.path().join("Windows/Temp");
        let junk = root.join("setup.log");
        let sibling = root.with_file_name("keep.log");
        write(&junk, 12);
        write(&sibling, 8);
        p.win_temp = Some(root.clone());

        let items = scan_junk(&p);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].group, "winTemp");
        assert_eq!(items[0].safety, Safety::Safe);
        assert_eq!(advise(&junk, &p), Safety::Risky);

        let mut offered = Offered::default();
        offered.add_items(&items);
        offered.0.insert(root.clone(), Safety::Safe);
        offered.0.insert(sibling.clone(), Safety::Safe);
        let path = |p: &Path| p.to_string_lossy().into_owned();
        let result = remove(&[path(&junk), path(&root), path(&sibling)], &offered, &p, rm);
        assert_eq!(result.removed, vec![path(&junk)]);
        assert_eq!(result.freed, 12);
        assert_eq!(result.failed, vec![path(&root), path(&sibling)]);
        assert!(root.is_dir() && sibling.is_file());
    }

    #[test]
    fn caches_find_chromium_profiles_and_apps() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        let ud = p.local.join("Google/Chrome/User Data");
        write(&ud.join("Default/Cache/data_0"), 30);
        write(&ud.join("Profile 2/Code Cache/js"), 20);
        write(&ud.join("Default/Bookmarks"), 999); // not a cache
        write(&p.roaming.join("discord/Cache/f"), 5);
        let items = scan_caches(&p);
        assert_eq!(items.iter().map(|i| i.bytes).sum::<u64>(), 55);
        assert!(items.iter().any(|i| i.group == "Discord"));
    }

    #[test]
    fn extra_caches_and_backups_are_offered_with_the_right_safety() {
        let t = tempfile::tempdir().unwrap();
        let mut p = places(t.path());
        p.roaming = t.path().join("redirected-roaming");
        for (root, _) in extra_cache_paths(&p) {
            write(&root.join("cache.db"), 8);
        }
        let [roaming, home] = backup_roots(&p);
        let named = roaming.join("old-phone");
        fs::create_dir_all(&named).unwrap();
        fs::write(named.join("Info.plist"), "<plist><dict><key>Device Name</key><string>My &amp; your iPhone</string></dict></plist>").unwrap();
        let fallback = home.join("new-phone");
        write(&fallback.join("file"), 4);
        write(&home.join("file-not-a-backup"), 4);
        let rows = scan_caches(&p);
        assert_eq!(rows.len(), 7);
        for (dir, group) in extra_cache_paths(&p) {
            assert!(rows.iter().any(|r| Path::new(&r.path) == dir && r.safety == Safety::Safe && r.group == group));
            assert_eq!(advise(&dir, &p), Safety::Safe);
        }
        assert!(rows.iter().any(|r| r.name.starts_with("My & your iPhone · ") && r.group == "iosBackups" && r.safety == Safety::Review));
        assert!(rows.iter().any(|r| r.name == "new-phone" && r.group == "iosBackups" && r.safety == Safety::Review));
        assert_eq!(advise(&named, &p), Safety::Review);
        assert_eq!(advise(&fallback, &p), Safety::Review);
        let paths: Vec<_> = rows.iter().map(|r| r.path.clone()).collect();
        let mut offered = Offered::default();
        offered.add_items(&rows);
        let result = remove(&paths, &offered, &p, |_| Ok(()));
        assert_eq!(result.removed, paths);
        assert!(result.failed.is_empty());
    }

    #[test]
    fn backup_names_decode_xml_and_ignore_other_keys() {
        assert_eq!(device_name("<key>Other</key><string>Other</string>
<key>Device Name</key>
 <string>&lt;iPhone&gt; &quot;علي&quot; &#x2605; &#38; &apos;</string>"),
            Some("<iPhone> \"علي\" ★ & '".into()));
        assert_eq!(device_name("<key>Device Name</key><string></string>"), None);
        assert_eq!(device_name("<key>Other</key><string>iPhone</string>"), None);
        let leap_day = SystemTime::UNIX_EPOCH + Duration::from_secs(1_709_164_800);
        assert_eq!(date_string(leap_day).as_deref(), Some("2024-02-29"));
    }

    #[test]
    fn junk_skips_temp_outside_user_folders_and_the_profile_root() {
        let t = tempfile::tempdir().unwrap();
        let mut p = places(t.path());
        p.temp = t.path().join("other-temp");
        write(&p.temp.join("system-file"), 4);
        write(&p.home.join("Documents/personal-file"), 4);
        assert!(scan_junk(&p).is_empty());
        let mut offered = Offered::default();
        let outside_file = p.temp.join("system-file");
        offered.0.insert(outside_file.clone(), Safety::Safe);
        let result = remove(&[outside_file.to_string_lossy().into_owned()], &offered, &p, |_| panic!("outside path reached disposal"));
        assert_eq!(result.failed.len(), 1);
        p.temp = p.home.clone();
        assert!(scan_junk(&p).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn deletion_rechecks_ancestor_links() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        let outside = t.path().join("outside");
        write(&outside.join("keep"), 1);
        fs::create_dir_all(&p.temp).unwrap();
        let link = p.temp.join("link");
        std::os::unix::fs::symlink(outside, &link).unwrap();
        let path = link.join("keep");
        let mut offered = Offered::default();
        offered.0.insert(path.clone(), Safety::Safe);
        let result = remove(&[path.to_string_lossy().into_owned()], &offered, &p, |_| panic!("link reached disposal"));
        assert_eq!(result.failed.len(), 1);
        assert!(scan_junk(&p).is_empty());
    }

    #[test]
    fn large_skips_appdata() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        write(&p.home.join("Videos/big.mp4"), 2000);
        write(&p.local.join("huge.bin"), 5000);
        write(&p.home.join("small.txt"), 10);
        let items = scan_large(&p, 1000);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].name, "big.mp4");
    }

    #[test]
    fn old_downloads_by_age() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        write(&p.home.join("Downloads/setup.exe"), 10);
        let later = SystemTime::now() + Duration::from_secs(100 * 86_400);
        assert_eq!(scan_old_downloads(&p, 90, later).len(), 1);
        assert_eq!(scan_old_downloads(&p, 90, SystemTime::now()).len(), 0);
    }

    #[test]
    fn remove_only_takes_offered_safe_paths_inside_roots() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        write(&p.temp.join("a.tmp"), 100);
        write(&p.home.join("Documents/keep.docx"), 10);
        let outside = t.path().join("outside.txt");
        write(&outside, 10);
        let mut offered = Offered::default();
        offered.add_items(&scan_junk(&p));
        offered.0.insert(outside.clone(), Safety::Safe); // offered but outside the user's folders
        offered.0.insert(p.home.clone(), Safety::Safe); // a root itself
        let risky = p.home.join("Documents");
        offered.0.insert(risky.clone(), Safety::Risky);

        let s = |x: &Path| x.to_string_lossy().into_owned();
        let asked = vec![
            s(&p.temp.join("a.tmp")),
            s(&outside),
            s(&p.home),
            s(&risky),
            s(&p.home.join("Documents/keep.docx")), // never offered
        ];
        let r = remove(&asked, &offered, &p, rm);
        assert_eq!(r.removed, vec![s(&p.temp.join("a.tmp"))]);
        assert_eq!(r.freed, 100);
        assert_eq!(r.failed.len(), 4);
        assert!(outside.exists() && p.home.join("Documents/keep.docx").exists());
    }

    #[test]
    fn advice_for_disk_map() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        assert_eq!(advise(&p.home, &p), Safety::Risky);
        assert_eq!(advise(t.path(), &p), Safety::Risky);
        assert_eq!(advise(&p.home.join("AppData"), &p), Safety::Risky);
        assert_eq!(advise(&p.roaming.join("Slack"), &p), Safety::Risky);
        assert_eq!(advise(&p.roaming.join("Slack/Cache"), &p), Safety::Safe);
        assert_eq!(advise(&p.home.join("Videos"), &p), Safety::Review);
        assert_eq!(advise(&p.home.join("NTUSER.DAT"), &p), Safety::Risky);
    }

    #[test]
    fn disk_children_sorted() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        write(&p.home.join("Videos/a.mp4"), 300);
        write(&p.home.join("Music/b.mp3"), 100);
        let nodes = disk_children(&p.home, &p);
        assert_eq!(nodes[0].name, "Videos");
        assert!(nodes[0].dir);
    }
    #[test]
    fn duplicates_keep_the_oldest_copy() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        fs::create_dir_all(p.home.join("Docs")).unwrap();
        fs::write(p.home.join("Docs/a.bin"), b"same content here").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        fs::write(p.home.join("Docs/b.bin"), b"same content here").unwrap();
        fs::write(p.home.join("Docs/c.bin"), b"diff content here").unwrap();
        write(&p.local.join("x/a.bin"), 17); // AppData is skipped
        let items = scan_duplicates(&p, 1);
        assert_eq!(items.len(), 1);
        assert!(items[0].path.ends_with("b.bin"));
        assert_eq!(items[0].group, "a.bin");
    }

    #[test]
    fn privacy_finds_history_and_cookies_not_bookmarks() {
        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        write(&p.local.join("Google/Chrome/User Data/Default/History"), 30);
        write(&p.local.join("Google/Chrome/User Data/Default/Network/Cookies"), 20);
        write(&p.local.join("Google/Chrome/User Data/System Profile/History"), 9);
        write(&p.roaming.join("Mozilla/Firefox/Profiles/x.default/places.sqlite"), 9);
        write(&p.roaming.join("Mozilla/Firefox/Profiles/x.default/cookies.sqlite"), 5);
        let items = scan_privacy(&p);
        assert_eq!(items.iter().map(|i| i.bytes).sum::<u64>(), 55);
        assert!(items.iter().all(|i| i.safety == Safety::Review));
    }

    #[test]
    fn leftovers_skip_installed_windows_and_recent() {
        let installed = vec!["Zoom Workplace".to_string(), "Valve Corporation".to_string(), "Spotify".to_string()];
        assert!(!is_leftover("Zoom", &installed));
        assert!(!is_leftover("Valve", &installed));
        assert!(!is_leftover("Microsoft", &installed));
        assert!(!is_leftover("ab", &installed));
        assert!(is_leftover("OldGameStudio", &installed));

        let t = tempfile::tempdir().unwrap();
        let p = places(t.path());
        write(&p.roaming.join("OldGameStudio/save.dat"), 40);
        write(&p.local.join("Spotify/x"), 40);
        let now = SystemTime::now();
        assert!(scan_leftovers(&p, &installed, 30, now).is_empty(), "fresh folders are not leftovers");
        let later = now + Duration::from_secs(40 * 86_400);
        let items = scan_leftovers(&p, &installed, 30, later);
        assert_eq!(items.len(), 1);
        assert!(items[0].path.ends_with("OldGameStudio"));
    }

}
