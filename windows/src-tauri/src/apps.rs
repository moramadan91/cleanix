//! Installed programs (the registry "Uninstall" entries Windows Settings lists) and their own uninstallers.
//! Cleanix never deletes program files itself: it opens the vendor's uninstaller, which asks the user.

use serde::Serialize;
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
};

use crate::core::{children, is_link, size_of, Places};

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct InstalledApp {
    pub id: String,
    pub name: String,
    pub publisher: String,
    pub version: String,
    pub bytes: u64,
    /// Stays on the Rust side: the UI only ever sends back `id`.
    #[serde(skip)]
    pub command: String,
    #[serde(skip)]
    install_location: String,
    #[serde(skip)]
    display_icon: String,
}

/// Raw values of one Uninstall registry entry.
#[derive(Default)]
pub struct Entry {
    pub name: String,
    pub publisher: String,
    pub version: String,
    pub uninstall: String,
    pub parent: String,
    pub release_type: String,
    pub system_component: u32,
    pub size_kb: u32,
    pub install_location: String,
    pub display_icon: String,
}

/// Same filter as Windows Settings: hidden components, updates and entries without an uninstaller are skipped.
pub fn to_app(id: String, e: Entry) -> Option<InstalledApp> {
    let rt = e.release_type.to_lowercase();
    if e.name.trim().is_empty()
        || e.uninstall.trim().is_empty()
        || e.system_component == 1
        || !e.parent.is_empty()
        || rt.contains("update")
        || rt.contains("hotfix")
    {
        return None;
    }
    Some(InstalledApp {
        id,
        name: e.name.trim().to_string(),
        publisher: e.publisher.trim().to_string(),
        version: e.version.trim().to_string(),
        bytes: e.size_kb as u64 * 1024,
        command: e.uninstall,
        install_location: e.install_location,
        display_icon: e.display_icon,
    })
}

/// One row per program even when it is registered in several views (64-bit, 32-bit, per user).
pub fn dedup(mut apps: Vec<InstalledApp>) -> Vec<InstalledApp> {
    let mut seen = HashSet::new();
    apps.retain(|a| seen.insert((a.name.to_lowercase(), a.version.clone())));
    apps
}

/// Expands %VAR% the way the shell does; unknown names stay as written.
pub fn expand(s: &str, var: impl Fn(&str) -> Option<String>) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(a) = rest.find('%') {
        let Some(len) = rest[a + 1..].find('%') else { break };
        let name = &rest[a + 1..a + 1 + len];
        out.push_str(&rest[..a]);
        match var(name) {
            Some(v) if !name.is_empty() => out.push_str(&v),
            _ => out.push_str(&rest[a..a + len + 2]),
        }
        rest = &rest[a + len + 2..];
    }
    out + rest
}

/// Splits an UninstallString into program and arguments. MSI's /I (modify) becomes /X (uninstall).
pub fn split_command(cmd: &str) -> Option<(String, String)> {
    let cmd = cmd.trim();
    let (program, args) = if let Some(rest) = cmd.strip_prefix('"') {
        let end = rest.find('"')?;
        (&rest[..end], &rest[end + 1..])
    } else if let Some(i) = cmd.to_ascii_lowercase().find(".exe") {
        // Unquoted paths with spaces ("C:\Program Files\X\unins.exe /S") end at ".exe".
        cmd.split_at(i + 4)
    } else {
        cmd.split_once(char::is_whitespace).unwrap_or((cmd, ""))
    };
    let program = program.trim();
    if program.is_empty() {
        return None;
    }
    let mut args = args.trim().to_string();
    let file = program.rsplit(['\\', '/']).next().unwrap_or(program).to_ascii_lowercase();
    if (file == "msiexec.exe" || file == "msiexec") && (args.starts_with("/I") || args.starts_with("/i")) {
        args.replace_range(..2, "/X");
    }
    Some((program.to_string(), args))
}

#[derive(Serialize)]
pub struct Footprint {
    pub total: u64,
    pub files: Vec<FolderSize>,
}

#[derive(Serialize)]
pub struct FolderSize {
    path: String,
    bytes: u64,
}

fn folder_key(name: &str) -> Option<String> {
    if name.is_empty() || name.ends_with([' ', '.'])
        || name.chars().any(|c| c.is_control() || r#"\/:*?"<>|"#.contains(c))
    {
        return None;
    }
    Some(name.to_lowercase())
}

fn app_folder_key(name: &str) -> Option<String> {
    let key = folder_key(name)?;
    (name.chars().count() >= 4 && !matches!(key.as_str(),
        "microsoft" | "windows" | "google" | "packages" | "temp" | "programs"
        | "appdata" | "local" | "locallow" | "roaming" | "programdata"
        | "program files" | "program files (x86)" | "common files" | "users"
        | "system32" | "syswow64" | "cache" | "caches" | "common" | "shared"
        | "application data" | "installshield installation information" | "default"
    )).then_some(key)
}

fn matches_install_folder(folder: &str, app: &InstalledApp) -> bool {
    let Some(key) = app_folder_key(folder) else { return false };
    [&app.name, &app.publisher].into_iter().any(|name| folder_key(name).as_ref() == Some(&key))
}

fn directory(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && !is_link(&m))
}

fn path_folder_key(path: &Path) -> Option<String> {
    folder_key(path.file_name()?.to_str()?)
}

/// Index the shallow data folders once per listing, including shared publisher containers.
#[derive(Default)]
pub struct DataFolders(HashMap<String, Vec<PathBuf>>);

impl DataFolders {
    pub fn new<'a>(places: &Places, program_data: Option<PathBuf>, apps: impl Iterator<Item = &'a InstalledApp>) -> Self {
        let mut names = HashSet::new();
        let mut publishers: HashMap<String, HashSet<String>> = HashMap::new();
        for app in apps {
            let Some(name) = app_folder_key(&app.name) else { continue };
            if let Some(publisher) = folder_key(&app.publisher) {
                publishers.entry(publisher).or_default().insert(name.clone());
            }
            names.insert(name);
        }
        let mut folders = HashMap::<String, Vec<PathBuf>>::new();
        let roots = [places.roaming.clone(), places.local.clone(), places.local.join("Programs")];
        for root in roots.into_iter().chain(program_data).filter(|root| root.is_absolute() && directory(root)) {
            for path in children(&root) {
                let Some(key) = path_folder_key(&path) else { continue };
                let published = publishers.get(&key);
                if (names.contains(&key) || published.is_some()) && directory(&path) {
                    if let Some(published) = published {
                        for child in children(&path) {
                            if let Some(name) = path_folder_key(&child).filter(|name| published.contains(name)) {
                                folders.entry(format!("{key}\\{name}")).or_default().push(child);
                            }
                        }
                    }
                    if names.contains(&key) {
                        folders.entry(key).or_default().push(path);
                    }
                }
            }
        }
        Self(folders)
    }
}

fn install_folder(app: &InstalledApp) -> Option<PathBuf> {
    let expand_env = |raw: &str| expand(raw, |v| std::env::var(v).ok());
    if !app.install_location.trim().is_empty() {
        // A bad InstallLocation like "C:\\Program Files" would size a whole shared folder.
        let path = PathBuf::from(expand_env(app.install_location.trim().trim_matches('"')));
        let named = path.file_name().and_then(|n| n.to_str()).and_then(app_folder_key).is_some();
        return named.then_some(path);
    }

    [&app.display_icon, &app.command].into_iter().find_map(|raw| {
        let raw = expand_env(raw);
        let (exe, _) = split_command(&raw)?;
        let path = Path::new(&exe);
        if !path.is_absolute() || !path.extension()?.eq_ignore_ascii_case("exe") {
            return None;
        }
        let folder = path.parent()?;
        (matches_install_folder(folder.file_name()?.to_str()?, app) && directory(folder))
            .then(|| folder.to_path_buf())
    })
}

pub fn footprint(app: &InstalledApp, folders: &DataFolders) -> Footprint {
    let mut roots: Vec<_> = install_folder(app).into_iter().collect();
    if let Some(name) = app_folder_key(&app.name) {
        roots.extend(folders.0.get(&name).into_iter().flatten().cloned());
        if let Some(publisher) = folder_key(&app.publisher) {
            roots.extend(folders.0.get(&format!("{publisher}\\{name}")).into_iter().flatten().cloned());
        }
    }
    let mut unique: Vec<_> = roots.into_iter().filter_map(|path| {
        if !path.is_absolute() || path.file_name().is_none() || !directory(&path) {
            return None;
        }
        // Normalize aliases, casing and path separators before comparing whole components.
        let canonical = fs::canonicalize(&path).ok()?;
        if canonical.file_name().is_none() {
            return None;
        }
        let key: Vec<_> = canonical.components()
            .map(|part| part.as_os_str().to_string_lossy().to_lowercase()).collect();
        Some((key, path))
    }).collect();
    unique.sort_by_key(|(key, _)| key.len());
    let mut counted: Vec<Vec<String>> = vec![];
    let mut files = vec![];
    for (key, path) in unique {
        if counted.iter().any(|parent| key.starts_with(parent)) {
            continue;
        }
        files.push(FolderSize { path: path.to_string_lossy().into_owned(), bytes: size_of(&path) });
        counted.push(key);
    }
    files.sort_unstable_by_key(|file| std::cmp::Reverse(file.bytes));
    Footprint { total: files.iter().map(|file| file.bytes).sum(), files }
}

#[cfg(windows)]
pub fn list() -> Vec<InstalledApp> {
    use winreg::{enums::*, RegKey};
    const PATH: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
    let views = [
        ("lm64", HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY),
        ("lm32", HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY),
        ("cu", HKEY_CURRENT_USER, 0),
    ];
    let mut apps = vec![];
    for (tag, hive, view) in views {
        let Ok(root) = RegKey::predef(hive).open_subkey_with_flags(PATH, KEY_READ | view) else { continue };
        for sub in root.enum_keys().flatten() {
            let Ok(k) = root.open_subkey_with_flags(&sub, KEY_READ | view) else { continue };
            let s = |n: &str| k.get_value::<String, _>(n).unwrap_or_default();
            let d = |n: &str| k.get_value::<u32, _>(n).unwrap_or_default();
            let e = Entry {
                name: s("DisplayName"),
                publisher: s("Publisher"),
                version: s("DisplayVersion"),
                uninstall: s("UninstallString"),
                parent: s("ParentKeyName"),
                release_type: s("ReleaseType"),
                system_component: d("SystemComponent"),
                size_kb: d("EstimatedSize"),
                install_location: s("InstallLocation"),
                display_icon: s("DisplayIcon"),
            };
            apps.extend(to_app(format!("{tag}\\{sub}"), e));
        }
    }
    dedup(apps)
}

/// Opens the program's own uninstaller. ShellExecute (not CreateProcess) so ones that need admin get the UAC prompt.
#[cfg(windows)]
pub fn launch(command: &str) -> Result<(), String> {
    use windows_sys::Win32::{
        System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE},
        UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL},
    };
    let (program, args) =
        split_command(&expand(command, |v| std::env::var(v).ok())).ok_or("empty uninstall command")?;
    let w = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let (verb, program, args) = (w("open"), w(&program), w(&args));
    // Shell extensions may require an STA. Balance every successful initialization on this worker.
    let hr = unsafe { CoInitializeEx(std::ptr::null(), (COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) as u32) };
    if hr < 0 {
        return Err(format!("CoInitializeEx error {hr:#x}"));
    }
    // SAFETY: all strings are NUL-terminated and outlive the call; null window and directory are valid.
    let r = unsafe {
        ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), program.as_ptr(), args.as_ptr(), std::ptr::null(), SW_SHOWNORMAL)
    };
    unsafe { CoUninitialize() };
    if r as isize > 32 {
        Ok(())
    } else {
        Err(format!("ShellExecute error {}", r as isize))
    }
}

/// Development stand-ins for other systems: no programs listed, nothing launched.
#[cfg(not(windows))]
pub fn list() -> Vec<InstalledApp> {
    vec![]
}

#[cfg(not(windows))]
pub fn launch(_: &str) -> Result<(), String> {
    Err("Windows only".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn split(s: &str) -> (String, String) {
        split_command(s).unwrap()
    }

    #[test]
    fn splits_quoted_unquoted_and_msi() {
        assert_eq!(split(r#""C:\Program Files\X\unins000.exe" /SILENT"#), (r"C:\Program Files\X\unins000.exe".into(), "/SILENT".into()));
        assert_eq!(split(r"C:\Program Files\Y\Uninstall.exe /S"), (r"C:\Program Files\Y\Uninstall.exe".into(), "/S".into()));
        assert_eq!(split("MsiExec.exe /I{1234-ABCD}"), ("MsiExec.exe".into(), "/X{1234-ABCD}".into()));
        assert_eq!(split("MsiExec.exe /X{1234}"), ("MsiExec.exe".into(), "/X{1234}".into()));
        assert_eq!(split(r#""C:\a\setup.exe""#), (r"C:\a\setup.exe".into(), "".into()));
        assert_eq!(split("rundll32 foo.dll,Run"), ("rundll32".into(), "foo.dll,Run".into()));
        assert!(split_command("   ").is_none());
        assert!(split_command(r#""C:\unterminated"#).is_none());
    }

    #[test]
    fn expands_known_vars_only() {
        let var = |n: &str| (n == "ProgramFiles").then(|| r"C:\Program Files".to_string());
        assert_eq!(expand(r"%ProgramFiles%\X\u.exe", var), r"C:\Program Files\X\u.exe");
        assert_eq!(expand("%NOPE%\\u.exe 50%", var), "%NOPE%\\u.exe 50%");
        assert_eq!(expand("plain", var), "plain");
    }

    #[test]
    fn fallback_folder_matches_exact_app_or_publisher_case_insensitively() {
        let app = to_app("test".into(), Entry {
            name: "Zoom Workplace".into(), publisher: "Zoom Communications".into(),
            uninstall: "uninstall.exe".into(), ..Default::default()
        }).unwrap();
        assert!(matches_install_folder("zOoM wOrKpLaCe", &app));
        assert!(matches_install_folder("ZOOM COMMUNICATIONS", &app));
        assert!(!matches_install_folder("Zoom", &app));
        assert!(!matches_install_folder("Zoom Workplace Backup", &app));
    }

    #[test]
    fn generic_or_unsafe_names_are_ineligible_for_app_folders() {
        for name in ["", "abc", "éàç", "Microsoft", "WINDOWS", "Google", "Packages",
            "Temp", "Programs", "Program Files", "AppData", "../Zoom", "Zoom\\Data", "C:Zoom", "Zoom."] {
            assert!(app_folder_key(name).is_none(), "{name}");
        }
        assert_eq!(app_folder_key("ÉDIT").as_deref(), Some("édit"));
        let app = to_app("test".into(), Entry {
            name: "Packages".into(), publisher: "Microsoft".into(),
            uninstall: "uninstall.exe".into(), ..Default::default()
        }).unwrap();
        assert!(!matches_install_folder("packages", &app));
        assert!(!matches_install_folder("microsoft", &app));
    }

    #[test]
    fn footprint_matches_data_folders_and_counts_overlapping_roots_once() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().to_path_buf();
        let local = home.join("Local");
        let roaming = home.join("Roaming");
        let program_data = home.join("ProgramData");
        let places = Places::test_profile(home, local, roaming, None);
        let app_root = places.roaming.join("sAmPlE aPp");
        let local_install = places.local.join("Programs").join("SAMPLE APP");
        for (dir, bytes) in [
            (app_root.join("Sample App"), 12),
            (local_install.clone(), 7),
            (program_data.join("sAMple APP").join("Sample APP"), 25),
            (places.local.join("Sample App Backup"), 99),
            (places.local.join("Sample App").join("Other Product"), 4),
            (places.local.join("gOoGlE").join("cHrOmE"), 16),
            (places.local.join("gOoGlE").join("Unrelated"), 100),
        ] {
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("file"), vec![0; bytes]).unwrap();
        }
        let app = to_app("test".into(), Entry {
            name: "Sample App".into(), publisher: "Sample App".into(),
            uninstall: "uninstall.exe".into(), install_location: local_install.display().to_string(),
            ..Default::default()
        }).unwrap();
        let chrome = to_app("chrome".into(), Entry {
            name: "Chrome".into(), publisher: "Google".into(),
            uninstall: "uninstall.exe".into(), ..Default::default()
        }).unwrap();
        let folders = DataFolders::new(&places, Some(program_data), [&app, &chrome].into_iter());
        let measured = footprint(&app, &folders);
        assert_eq!(measured.total, 48);
        assert_eq!(measured.files.iter().map(|f| f.bytes).collect::<Vec<_>>(), [25, 12, 7, 4]);
        assert_eq!(footprint(&chrome, &folders).total, 16);
    }

    #[test]
    fn install_location_precedes_icon_and_uninstall_paths() {
        let temp = tempfile::tempdir().unwrap();
        let app_dir = temp.path().join("Sample App");
        fs::create_dir(&app_dir).unwrap();
        let publisher_dir = temp.path().join("Sample Publisher");
        fs::create_dir(&publisher_dir).unwrap();
        let app = &mut to_app("test".into(), Entry {
            name: "Sample App".into(), publisher: "Sample Publisher".into(),
            install_location: publisher_dir.display().to_string(),
            display_icon: format!("\"{}\",0", app_dir.join("app.exe").display()),
            uninstall: format!("{} /S", publisher_dir.join("uninstall.exe").display()),
            ..Default::default()
        }).unwrap();
        assert_eq!(install_folder(app), Some(publisher_dir.clone()));
        app.install_location.clear();
        assert_eq!(install_folder(app), Some(app_dir));
        app.display_icon = format!("\"{}\",0", temp.path().join("Packages").join("app.exe").display());
        assert_eq!(install_folder(app), Some(publisher_dir));
    }

    #[test]
    fn filters_like_settings_and_dedups() {
        let e = |name: &str, f: fn(&mut Entry)| {
            let mut e = Entry { name: name.into(), uninstall: "u.exe".into(), size_kb: 2, ..Default::default() };
            f(&mut e);
            to_app(name.into(), e)
        };
        assert_eq!(e("App", |_| {}).unwrap().bytes, 2048);
        assert!(e("", |_| {}).is_none());
        assert!(e("NoUninstaller", |e| e.uninstall.clear()).is_none());
        assert!(e("Hidden", |e| e.system_component = 1).is_none());
        assert!(e("Patch", |e| e.parent = "Office".into()).is_none());
        assert!(e("KB123", |e| e.release_type = "Security Update".into()).is_none());

        let a = e("Same", |_| {}).unwrap();
        let mut b = a.clone();
        b.id = "other".into();
        b.name = "SAME".into();
        assert_eq!(dedup(vec![a, b]).len(), 1);
    }
}
