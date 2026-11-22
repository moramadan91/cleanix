//! Programs that start with Windows (Run keys and Startup folders), switched on and off the same way
//! Task Manager does: through the StartupApproved flags. Nothing is deleted, so every switch is reversible.

use crate::core::Places;
use serde::Serialize;
use std::path::Path;

#[derive(Serialize, Clone, Debug)]
pub struct StartupItem {
    pub id: String,
    pub name: String,
    pub command: String,
    pub enabled: bool,
    pub suspicious: bool,
}

/// StartupApproved stores 12 bytes; an odd first byte means "disabled". Missing means enabled.
pub fn approved_enabled(flag: Option<&[u8]>) -> bool {
    flag.and_then(|b| b.first()).is_none_or(|b| b % 2 == 0)
}

pub fn flag_bytes(enabled: bool) -> Vec<u8> {
    let mut b = vec![0u8; 12];
    b[0] = if enabled { 2 } else { 3 };
    b
}

/// A start-up command whose program sits in a temp or downloads folder, or no longer exists.
pub fn is_suspicious(command: &str, p: &Places, exists: impl Fn(&Path) -> bool) -> bool {
    let Some((program, _)) = crate::apps::split_command(command) else { return true };
    let program = crate::apps::expand(&program, |v| std::env::var(v).ok());
    let path = Path::new(&program);
    if !path.is_absolute() {
        return false; // resolved through PATH (rundll32, cmd…), nothing to check
    }
    let lower = program.to_lowercase();
    let under = |dir: &Path| lower.starts_with(&dir.to_string_lossy().to_lowercase());
    under(&p.temp) || under(&p.home.join("Downloads")) || lower.contains("\\temp\\") || !exists(path)
}

/// Where each kind of entry lives and where its on/off flag is kept.
/// The id is "<entry source>|<value name>"; the UI only sends ids back from the last listing.
#[cfg(windows)]
mod reg {
    use winreg::{enums::*, RegKey, HKEY};
    pub const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const APPROVED: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved";

    pub struct Source {
        pub tag: &'static str,
        pub hive: HKEY,
        pub view: u32,
        pub approved_hive: HKEY,
        pub approved_key: &'static str,
    }

    pub const SOURCES: [Source; 3] = [
        Source { tag: "cu", hive: HKEY_CURRENT_USER, view: 0, approved_hive: HKEY_CURRENT_USER, approved_key: "Run" },
        Source { tag: "lm64", hive: HKEY_LOCAL_MACHINE, view: KEY_WOW64_64KEY, approved_hive: HKEY_LOCAL_MACHINE, approved_key: "Run" },
        Source { tag: "lm32", hive: HKEY_LOCAL_MACHINE, view: KEY_WOW64_32KEY, approved_hive: HKEY_LOCAL_MACHINE, approved_key: "Run32" },
    ];

    pub fn approved(hive: HKEY, key: &str) -> Option<RegKey> {
        RegKey::predef(hive).open_subkey(format!(r"{APPROVED}\{key}")).ok()
    }

    pub fn flag(hive: HKEY, key: &str, name: &str) -> Option<Vec<u8>> {
        approved(hive, key)?.get_raw_value(name).ok().map(|v| v.bytes)
    }

    pub fn set_flag(hive: HKEY, key: &str, name: &str, bytes: Vec<u8>) -> std::io::Result<()> {
        let (k, _) = RegKey::predef(hive).create_subkey(format!(r"{APPROVED}\{key}"))?;
        k.set_raw_value(name, &winreg::RegValue { bytes, vtype: REG_BINARY })
    }
}

#[cfg(windows)]
pub fn list(p: &Places) -> Vec<StartupItem> {
    use winreg::{enums::*, RegKey};
    let mut out = vec![];
    for s in &reg::SOURCES {
        let Ok(run) = RegKey::predef(s.hive).open_subkey_with_flags(reg::RUN, KEY_READ | s.view) else { continue };
        for (name, _) in run.enum_values().flatten() {
            let Ok(command) = run.get_value::<String, _>(&name) else { continue };
            let enabled = approved_enabled(reg::flag(s.approved_hive, s.approved_key, &name).as_deref());
            let suspicious = is_suspicious(&command, p, |x| x.exists());
            out.push(StartupItem { id: format!("{}|{name}", s.tag), name, command, enabled, suspicious });
        }
    }
    // Shortcuts in the user's and everyone's Startup folders.
    let program_data = std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into());
    let folders = [
        ("fu", p.roaming.join(r"Microsoft\Windows\Start Menu\Programs\Startup"), HKEY_CURRENT_USER),
        ("fa", Path::new(&program_data).join(r"Microsoft\Windows\Start Menu\Programs\Startup"), HKEY_LOCAL_MACHINE),
    ];
    for (tag, dir, hive) in folders {
        for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let file = e.file_name().to_string_lossy().into_owned();
            if file.eq_ignore_ascii_case("desktop.ini") {
                continue;
            }
            let enabled = approved_enabled(reg::flag(hive, "StartupFolder", &file).as_deref());
            let name = file.trim_end_matches(".lnk").to_string();
            let command = e.path().to_string_lossy().into_owned();
            out.push(StartupItem { id: format!("{tag}|{file}"), name, command, enabled, suspicious: false });
        }
    }
    out
}

/// Machine-wide entries need admin rights; the error says so and the switch stays as it was.
#[cfg(windows)]
pub fn set_enabled(id: &str, enabled: bool) -> Result<(), String> {
    use winreg::enums::*;
    let (tag, name) = id.split_once('|').ok_or("bad id")?;
    let (hive, key) = match tag {
        "fu" => (HKEY_CURRENT_USER, "StartupFolder"),
        "fa" => (HKEY_LOCAL_MACHINE, "StartupFolder"),
        _ => {
            let s = reg::SOURCES.iter().find(|s| s.tag == tag).ok_or("bad id")?;
            (s.approved_hive, s.approved_key)
        }
    };
    reg::set_flag(hive, key, name, flag_bytes(enabled)).map_err(|e| {
        if e.kind() == std::io::ErrorKind::PermissionDenied { "admin".to_string() } else { e.to_string() }
    })
}

#[cfg(not(windows))]
pub fn list(_: &Places) -> Vec<StartupItem> {
    vec![]
}

#[cfg(not(windows))]
pub fn set_enabled(_: &str, _: bool) -> Result<(), String> {
    Err("Windows only".into())
}

#[cfg(windows)]
pub fn set_open_at_login(enabled: bool) -> Result<(), String> {
    use winreg::{enums::{HKEY_CURRENT_USER, KEY_SET_VALUE}, RegKey};

    fn update(enabled: bool) -> std::io::Result<()> {
        let user = RegKey::predef(HKEY_CURRENT_USER);
        if enabled {
            let exe = std::env::current_exe()?;
            let command = format!(r#""{}" --hidden"#, exe.display());
            let (run, _) = user.create_subkey(reg::RUN)?;
            reg::set_flag(HKEY_CURRENT_USER, "Run", "Cleanix", flag_bytes(true))?;
            run.set_value("Cleanix", &command)
        } else {
            let result = user.open_subkey_with_flags(reg::RUN, KEY_SET_VALUE)
                .and_then(|run| run.delete_value("Cleanix"));
            match result {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                other => other,
            }
        }
    }
    update(enabled).map_err(|e| e.to_string())
}

#[cfg(not(windows))]
pub fn set_open_at_login(_: bool) -> Result<(), String> { Ok(()) }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn approved_flags_follow_task_manager() {
        assert!(approved_enabled(None));
        assert!(approved_enabled(Some(&[2, 0, 0])));
        assert!(approved_enabled(Some(&[6])));
        assert!(!approved_enabled(Some(&[3, 0])));
        assert!(!approved_enabled(Some(&[7])));
        assert!(approved_enabled(Some(&flag_bytes(true))));
        assert!(!approved_enabled(Some(&flag_bytes(false))));
        assert_eq!(flag_bytes(false).len(), 12);
    }

    #[test]
    fn suspicious_temp_downloads_or_missing() {
        let home = std::path::PathBuf::from(r"C:\Users\Demo");
        let local = home.join(r"AppData\Local");
        let p = Places { temp: local.join("Temp"), roaming: home.join(r"AppData\Roaming"), local, home };
        let yes = |_: &Path| true;
        if cfg!(windows) {
            assert!(is_suspicious(r#""C:\Users\Demo\AppData\Local\Temp\x.exe" /run"#, &p, yes));
            assert!(is_suspicious(r"C:\Users\Demo\Downloads\tool.exe", &p, yes));
            assert!(is_suspicious(r#""C:\Program Files\Gone\gone.exe""#, &p, |_| false));
            assert!(!is_suspicious(r#""C:\Program Files\Zoom\zoom.exe" --autostart"#, &p, yes));
        }
        assert!(!is_suspicious("rundll32 shell32.dll,Control_RunDLL", &p, |_| false));
        assert!(is_suspicious("   ", &p, yes));
    }
}
