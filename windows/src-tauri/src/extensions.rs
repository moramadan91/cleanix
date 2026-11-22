use crate::core::{children, is_link, size_of, Places};
use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

#[derive(Serialize, Debug)]
pub struct Extension {
    pub browser: &'static str,
    pub profile: String,
    pub id: String,
    pub name: String,
    pub version: String,
    pub path: String,
    pub bytes: u64,
}

#[derive(Deserialize)]
struct Manifest {
    name: Option<String>,
    version: Option<String>,
    default_locale: Option<String>,
}

fn directory(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && !is_link(&m))
}

fn local_name(dir: &Path, locale: &str, key: &str) -> Option<String> {
    if locale.is_empty() || !locale.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
        return None;
    }
    let json = fs::read(dir.join("_locales").join(locale).join("messages.json")).ok()?;
    let messages: serde_json::Value = serde_json::from_slice(&json).ok()?;
    let (_, message) = messages.as_object()?.iter().find(|(k, _)| k.eq_ignore_ascii_case(key))?;
    Some(message.get("message")?.as_str()?.to_string())
}

fn read_extension(dir: &Path, browser: &'static str, profile: &str, id: &str) -> Option<Extension> {
    let manifest: Manifest = serde_json::from_slice(&fs::read(dir.join("manifest.json")).ok()?).ok()?;
    let name = manifest.name.and_then(|name| {
        if let Some(key) = name.strip_prefix("__MSG_").and_then(|s| s.strip_suffix("__")) {
            local_name(dir, manifest.default_locale.as_deref()?, key)
        } else {
            Some(name)
        }
    }).filter(|name| !name.trim().is_empty()).unwrap_or_else(|| id.into());
    Some(Extension {
        browser, profile: profile.into(), id: id.into(), name,
        version: manifest.version.unwrap_or_else(|| dir.file_name().unwrap_or_default().to_string_lossy().into_owned()),
        path: dir.to_string_lossy().into_owned(), bytes: size_of(dir),
    })
}

pub fn list(p: &Places) -> Vec<Extension> {
    let browsers = [
        ("Chrome", "Google/Chrome/User Data"),
        ("Edge", "Microsoft/Edge/User Data"),
        ("Brave", "BraveSoftware/Brave-Browser/User Data"),
    ];
    let mut out = vec![];
    for (browser, root) in browsers {
        for profile in children(&p.local.join(root)).into_iter().filter(|p| directory(p)) {
            let name = profile.file_name().unwrap_or_default().to_string_lossy();
            if name != "Default" && !name.starts_with("Profile ") {
                continue;
            }
            let extensions = profile.join("Extensions");
            if !directory(&extensions) {
                continue;
            }
            for id in children(&extensions).into_iter().filter(|p| directory(p)) {
                let key = id.file_name().unwrap_or_default().to_string_lossy();
                for version in children(&id).into_iter().filter(|p| directory(p)) {
                    out.extend(read_extension(&version, browser, &name, &key));
                }
            }
        }
    }
    out.sort_by(|a, b| (a.browser, &a.name, &a.profile, &a.path).cmp(&(b.browser, &b.name, &b.profile, &b.path)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_plain_localized_and_missing_locale_in_supported_profiles() {
        let tmp = tempfile::tempdir().unwrap();
        let p = Places { home: tmp.path().into(), local: tmp.path().join("Local"),
            roaming: tmp.path().join("Roaming"), temp: tmp.path().join("Temp"), win_temp: None };
        let chrome = p.local.join("Google/Chrome/User Data");
        let plain = chrome.join("Default/Extensions/plain/1.0_0");
        let localized = chrome.join("Profile 2/Extensions/local/2.0_0");
        let missing = chrome.join("Profile 2/Extensions/missing/3.0_0");
        let ignored = chrome.join("Guest Profile/Extensions/ignored/1.0_0");
        let locale = localized.join("_locales/ar");
        fs::create_dir_all(&locale).unwrap();
        fs::write(locale.join("messages.json"), r#"{"TitLE":{"message":"أهلاً"}}"#).unwrap();
        for (dir, manifest) in [
            (plain, r#"{"name":"Plain","version":"1.0"}"#),
            (localized, r#"{"name":"__MSG_title__","default_locale":"ar","version":"2.0"}"#),
            (missing, r#"{"name":"__MSG_title__","default_locale":"ar","version":"3.0"}"#),
            (ignored, r#"{"name":"Ignored"}"#),
        ] {
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("manifest.json"), manifest).unwrap();
        }
        let found = list(&p);
        assert_eq!(found.len(), 3);
        assert!(found.iter().any(|e| e.name == "Plain" && e.version == "1.0" && e.bytes > 0));
        assert!(found.iter().any(|e| e.name == "أهلاً" && e.profile == "Profile 2"));
        assert!(found.iter().any(|e| e.name == "missing"));
    }
}
