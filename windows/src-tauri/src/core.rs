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

    /// Folders a removal may ever reach into.
    fn roots(&self) -> Vec<&Path> {
        let mut r = vec![self.home.as_path(), self.local.as_path(), self.roaming.as_path(), self.temp.as_path()];
        if let Some(w) = &self.win_temp {
            r.push(w);
        }
        r
    }
}

/// Symlinks and junctions are never followed: they can point anywhere, including system folders.
fn is_link(md: &fs::Metadata) -> bool {
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
            let Ok(md) = e.metadata() else { continue };
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

fn children(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir).map(|r| r.flatten().map(|e| e.path()).collect()).unwrap_or_default()
}

/// Everything inside temp and crash-report folders, one row per entry.
pub fn scan_junk(p: &Places) -> Vec<ScanItem> {
    let mut roots: Vec<(PathBuf, &str)> = vec![
        (p.temp.clone(), "temp"),
        (p.local.join("Temp"), "temp"),
        (p.local.join("CrashDumps"), "crash"),
        (p.local.join("Microsoft/Windows/WER"), "crash"),
        (p.local.join("Microsoft/Windows/INetCache"), "inet"),
    ];
    if let Some(w) = &p.win_temp {
        roots.push((w.clone(), "winTemp"));
    }
    let mut seen = std::collections::HashSet::new();
    let mut out = vec![];
    for (root, group) in roots {
        if !seen.insert(root.clone()) {
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
    let apps: [(&str, PathBuf, &[&str]); 8] = [
        ("Discord", p.roaming.join("discord"), &["Cache", "Code Cache", "GPUCache"]),
        ("Slack", p.roaming.join("Slack"), &["Cache", "Code Cache", "GPUCache"]),
        ("Teams", p.roaming.join("Microsoft/Teams"), &["Cache", "Code Cache", "GPUCache"]),
        ("VS Code", p.roaming.join("Code"), &["Cache", "CachedData", "Code Cache", "GPUCache"]),
        ("Spotify", p.local.join("Spotify"), &["Data"]),
        ("npm", p.local.clone(), &["npm-cache"]),
        ("pip", p.local.join("pip"), &["cache"]),
        ("DirectX", p.local.clone(), &["D3DSCache", "NVIDIA/DXCache", "AMD/DxCache"]),
    ];
    for (name, base, subs) in apps {
        for sub in subs {
            add(base.join(sub), name);
        }
    }
    out
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

/// Single files of at least `min` bytes in the user's folders (AppData is apps' business, skipped).
pub fn scan_large(p: &Places, min: u64) -> Vec<ScanItem> {
    let mut out = vec![];
    let mut stack = vec![p.home.clone()];
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let Ok(md) = e.metadata() else { continue };
            if is_link(&md) {
                continue;
            }
            let path = e.path();
            if md.is_dir() {
                let n = name_of(&path);
                if path != p.local && path != p.roaming && n != "AppData" && !n.starts_with('.') {
                    stack.push(path);
                }
            } else if md.len() >= min {
                out.push(item(path, md.len(), "large", Safety::Review));
            }
        }
    }
    out
}

/// How safe removing something is, for the disk map.
pub fn advise(path: &Path, p: &Places) -> Safety {
    let in_any = |dirs: &[PathBuf]| dirs.iter().any(|d| path.starts_with(d) && path != d);
    let cache_like = path.components().any(|c| {
        let s = c.as_os_str().to_string_lossy().to_lowercase();
        matches!(s.as_str(), "cache" | "cache2" | "code cache" | "gpucache" | "temp" | "tmp" | "crashdumps" | "npm-cache")
    });
    if !path.starts_with(&p.home) || path == p.home {
        return Safety::Risky;
    }
    if cache_like || in_any(&[p.temp.clone()]) {
        return Safety::Safe;
    }
    // AppData itself and its first level hold app settings and data: not for a quick delete.
    let appdata = p.home.join("AppData");
    if path == appdata || path.parent() == Some(&appdata) || path.parent() == Some(p.local.as_path())
        || path.parent() == Some(p.roaming.as_path()) || path == p.local || path == p.roaming
    {
        return Safety::Risky;
    }
    let n = name_of(path).to_lowercase();
    if n.starts_with("ntuser") {
        return Safety::Risky;
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

/// Removes `paths` with `dispose` (the Recycle Bin in the app) after checking each one:
/// offered by a scan, not risky, strictly inside one of the user's folders, not a link.
pub fn remove(
    paths: &[String],
    offered: &Offered,
    places: &Places,
    dispose: impl Fn(&Path) -> Result<(), String>,
) -> CleanResult {
    let mut r = CleanResult::default();
    let roots = places.roots();
    for raw in paths {
        let path = PathBuf::from(raw);
        let allowed = matches!(offered.0.get(&path), Some(Safety::Safe | Safety::Review))
            && roots.iter().any(|root| path.starts_with(root) && path.as_path() != *root)
            && !roots.contains(&path.as_path())
            && !path.components().any(|c| matches!(c, std::path::Component::ParentDir));
        if !allowed {
            r.failed.push(raw.clone());
            continue;
        }
        let bytes = size_of(&path);
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
}
