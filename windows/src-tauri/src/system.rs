//! Read-only privacy report (which apps may use the camera, microphone and location) and
//! Windows' own maintenance tools. Permissions are changed in Windows Settings, never here.

use serde::Serialize;

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Access {
    pub capability: String,
    pub app: String,
    pub allowed: bool,
    /// Unix seconds of the last use, 0 when unknown.
    pub last_used: u64,
}

/// ConsentStore key names: packaged apps are "Publisher.App_hash", desktop apps are paths with '#' for '\'.
pub fn app_label(key: &str, packaged: bool) -> String {
    if packaged {
        let base = key.split('_').next().unwrap_or(key);
        base.rsplit('.').next().unwrap_or(base).to_string()
    } else {
        key.rsplit('#').next().unwrap_or(key).trim_end_matches(".exe").trim_end_matches(".EXE").to_string()
    }
}

/// Windows FILETIME (100 ns since 1601) to Unix seconds.
pub fn filetime_to_unix(ft: u64) -> u64 {
    (ft / 10_000_000).saturating_sub(11_644_473_600)
}

pub const CAPABILITIES: [&str; 3] = ["webcam", "microphone", "location"];

#[cfg(windows)]
pub fn access() -> Vec<Access> {
    use winreg::{enums::*, RegKey};
    const BASE: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore";
    let mut out = vec![];
    for cap in CAPABILITIES {
        let Ok(root) = RegKey::predef(HKEY_CURRENT_USER).open_subkey(format!(r"{BASE}\{cap}")) else { continue };
        let mut add = |k: &RegKey, key: &str, packaged: bool| {
            let value: String = k.get_value("Value").unwrap_or_default();
            let last: u64 = k.get_value("LastUsedTimeStart").unwrap_or_default();
            out.push(Access {
                capability: cap.into(),
                app: app_label(key, packaged),
                allowed: value.eq_ignore_ascii_case("Allow"),
                last_used: if last > 0 { filetime_to_unix(last) } else { 0 },
            });
        };
        for key in root.enum_keys().flatten() {
            let Ok(k) = root.open_subkey(&key) else { continue };
            if key == "NonPackaged" {
                for sub in k.enum_keys().flatten() {
                    if let Ok(s) = k.open_subkey(&sub) {
                        add(&s, &sub, false);
                    }
                }
            } else {
                add(&k, &key, true);
            }
        }
    }
    out
}

#[cfg(not(windows))]
pub fn access() -> Vec<Access> {
    vec![]
}

/// Runs one of Windows' own maintenance tools. Each id maps to a fixed command; nothing else runs.
#[cfg(windows)]
pub fn run_task(id: &str) -> Result<(), String> {
    let quiet = |prog: &str, args: &[&str]| -> Result<(), String> {
        let ok = hidden_command(prog).args(args).status().map_err(|e| e.to_string())?.success();
        ok.then_some(()).ok_or_else(|| format!("{prog} failed"))
    };
    match id {
        "dns" => quiet("ipconfig", &["/flushdns"]),
        "explorer" => {
            // Explorer restarts itself on most systems; start it if it did not.
            let _ = quiet("taskkill", &["/f", "/im", "explorer.exe"]);
            std::thread::sleep(std::time::Duration::from_millis(1500));
            let running = hidden_command("tasklist")
                .args(["/fi", "imagename eq explorer.exe", "/nh"])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase().contains("explorer.exe"))
                .unwrap_or(false);
            if !running {
                hidden_command("explorer.exe").spawn().map_err(|e| e.to_string())?;
            }
            Ok(())
        }
        "diskCleanup" => crate::apps::launch("cleanmgr.exe"),
        "storageSense" => crate::apps::launch("ms-settings:storagesense"),
        "defender" => crate::apps::launch("windowsdefender:"),
        _ => Err("unknown task".into()),
    }
}

/// Opens a Windows Settings privacy page; only these pages.
pub fn settings_page(cap: &str) -> Option<&'static str> {
    match cap {
        "webcam" => Some("ms-settings:privacy-webcam"),
        "microphone" => Some("ms-settings:privacy-microphone"),
        "location" => Some("ms-settings:privacy-location"),
        "startup" => Some("ms-settings:startupapps"),
        _ => None,
    }
}

#[cfg(not(windows))]
pub fn run_task(_: &str) -> Result<(), String> {
    Err("Windows only".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_and_times() {
        assert_eq!(app_label("Microsoft.WindowsCamera_8wekyb3d8bbwe", true), "WindowsCamera");
        assert_eq!(app_label("C:#Program Files#Zoom#bin#Zoom.exe", false), "Zoom");
        assert_eq!(filetime_to_unix(116_444_736_000_000_000), 0);
        assert_eq!(filetime_to_unix(116_444_736_000_000_000 + 10_000_000 * 60), 60);
        assert_eq!(settings_page("webcam"), Some("ms-settings:privacy-webcam"));
        assert_eq!(settings_page("calc.exe"), None);
    }
}

#[cfg(windows)]
pub fn hidden_command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    use std::os::windows::process::CommandExt;
    let mut command = std::process::Command::new(program);
    command.creation_flags(0x0800_0000);
    command
}

#[cfg(windows)]
pub fn powershell(script: &str) -> Result<Vec<u8>, String> {
    let output = hidden_command("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &crate::settings::encode_script(script)])
        .output()
        .map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

#[cfg(windows)]
pub fn filetime(time: windows_sys::Win32::Foundation::FILETIME) -> u64 {
    (u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime)
}
