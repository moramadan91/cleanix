use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path, time::SystemTime};

const DAY: u64 = 86_400;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
pub struct Settings {
    pub open_at_login: bool,
    pub alert_low_space: bool,
    pub alert_weekly: bool,
    pub last_scan: u64,
    pub last_low_space_alert: u64,
    pub last_weekly_alert: u64,
    pub lang: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            open_at_login: false, alert_low_space: false, alert_weekly: false,
            last_scan: 0, last_low_space_alert: 0, last_weekly_alert: 0, lang: "en".into(),
        }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Self {
        fs::read(path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        fs::rename(&tmp, path)
    }
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alert { LowSpace, Weekly }

pub fn due_alerts(now: u64, settings: &Settings, free: u64, total: u64) -> Vec<Alert> {
    let mut due = vec![];
    let older = |last: u64, days: u64| now.saturating_sub(last) > days * DAY;
    if settings.alert_low_space
        && (free < crate::health::GB * 10 || u128::from(free) * 10 < u128::from(total))
        && older(settings.last_low_space_alert, 1)
    {
        due.push(Alert::LowSpace);
    }
    if settings.alert_weekly && older(settings.last_scan, 7) && older(settings.last_weekly_alert, 7) {
        due.push(Alert::Weekly);
    }
    due
}

pub fn toast_xml(title: &str, body: &str) -> String {
    let escape = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
        .replace('"', "&quot;").replace('\'', "&apos;");
    format!(r#"<toast><visual><binding template="ToastText02"><text id="1">{}</text><text id="2">{}</text></binding></visual></toast>"#,
        escape(title), escape(body))
}

pub fn encode_script(script: &str) -> String {
    const BASE64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes: Vec<_> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let mut encoded = String::new();
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied().unwrap_or(0);
        let c = chunk.get(2).copied().unwrap_or(0);
        encoded.push(BASE64[(a >> 2) as usize] as char);
        encoded.push(BASE64[((a & 3) << 4 | b >> 4) as usize] as char);
        encoded.push(if chunk.len() > 1 { BASE64[((b & 15) << 2 | c >> 6) as usize] as char } else { '=' });
        encoded.push(if chunk.len() > 2 { BASE64[(c & 63) as usize] as char } else { '=' });
    }
    encoded
}

pub fn arabic_digits(text: &str) -> String {
    text.chars().map(|c| match c {
        '0'..='9' => char::from_u32('٠' as u32 + c as u32 - '0' as u32).unwrap_or(c),
        '%' => '٪',
        '.' => '٫',
        _ => c,
    }).collect()
}

#[cfg(windows)]
pub fn show_alert(alert: Alert, free: u64, lang: &str) -> Result<(), String> {
    let ar = lang == "ar";
    let gb = format!("{:.1}", free as f64 / crate::health::GB as f64);
    let (title, body) = match (alert, ar) {
        (Alert::LowSpace, true) => ("المساحة قربت تخلص", format!("فاضل {} جيجا على C:", arabic_digits(&gb))),
        (Alert::LowSpace, false) => ("Disk space is running low", format!("{gb} GB left on C:")),
        (Alert::Weekly, true) => ("وقت التنضيف الأسبوعي", "افتح Cleanix واعمل فحص سريع.".into()),
        (Alert::Weekly, false) => ("Time for your weekly clean-up", "Open Cleanix and run a quick scan.".into()),
    };
    let xml = toast_xml(title, &body);
    let script = format!(r#"
$ErrorActionPreference = 'Stop'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] > $null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime] > $null
$doc = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent('ToastText02')
$doc.LoadXml(@'
{xml}
'@)
$toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('app.cleanix.windows').Show($toast)
"#);
    crate::system::powershell(&script).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::health::GB;

    #[test]
    fn alert_thresholds_and_cooldowns() {
        let mut s = Settings { alert_low_space: true, alert_weekly: true, last_scan: DAY,
            last_low_space_alert: 7 * DAY, last_weekly_alert: DAY, ..Settings::default() };
        let now = 8 * DAY;
        assert!(due_alerts(now, &s, 9*GB, 100*GB).is_empty());
        assert_eq!(due_alerts(now + 1, &s, 9*GB, 100*GB), [Alert::LowSpace, Alert::Weekly]);
        assert_eq!(due_alerts(now + 1, &s, 10*GB, 100*GB), [Alert::Weekly]);
        assert_eq!(due_alerts(now + 1, &s, 10*GB, 100*GB + 1), [Alert::LowSpace, Alert::Weekly]);
        assert_eq!(due_alerts(now + 1, &s, 10*GB - 1, 10*GB), [Alert::LowSpace, Alert::Weekly]);
        s.last_weekly_alert += 1;
        assert!(due_alerts(now + 1, &s, 50*GB, 100*GB).is_empty());
        s.last_scan += 1;
        s.last_weekly_alert = 0;
        assert!(due_alerts(now + 1, &s, 50*GB, 100*GB).is_empty());
        assert!(due_alerts(now, &Settings::default(), 0, 100*GB).is_empty());
    }

    #[test]
    fn xml_and_powershell_encoding() {
        assert!(toast_xml(r#"أهلاً <&"'>"#, "مساحة").contains("أهلاً &lt;&amp;&quot;&apos;&gt;</text><text id=\"2\">مساحة"));
        assert_eq!(encode_script("A"), "QQA=");
        assert_eq!(encode_script("AB"), "QQBCAA==");
        assert_eq!(encode_script("ع"), "OQY=");
        assert_eq!(arabic_digits("61%"), "٦١٪");
    }

    #[test]
    fn reads_old_settings_and_replaces_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        fs::write(&path, r#"{"alert_weekly":true}"#).unwrap();
        let mut s = Settings::load(&path);
        assert!(s.alert_weekly);
        assert!(!s.open_at_login);
        s.last_scan = 123;
        s.save(&path).unwrap();
        assert_eq!(Settings::load(&path).last_scan, 123);
    }
}
