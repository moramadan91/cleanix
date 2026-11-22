//! Installed programs (the registry "Uninstall" entries Windows Settings lists) and their own uninstallers.
//! Cleanix never deletes program files itself: it opens the vendor's uninstaller, which asks the user.

use serde::Serialize;
use std::collections::HashSet;

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
            };
            apps.extend(to_app(format!("{tag}\\{sub}"), e));
        }
    }
    dedup(apps)
}

/// Opens the program's own uninstaller. ShellExecute (not CreateProcess) so ones that need admin get the UAC prompt.
#[cfg(windows)]
pub fn launch(command: &str) -> Result<(), String> {
    use windows_sys::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};
    let (program, args) =
        split_command(&expand(command, |v| std::env::var(v).ok())).ok_or("empty uninstall command")?;
    let w = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let (verb, program, args) = (w("open"), w(&program), w(&args));
    // SAFETY: all strings are NUL-terminated and outlive the call; null window and directory are valid.
    let r = unsafe {
        ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), program.as_ptr(), args.as_ptr(), std::ptr::null(), SW_SHOWNORMAL)
    };
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
