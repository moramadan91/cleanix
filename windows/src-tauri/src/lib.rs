mod apps;
mod core;
mod extensions;
mod health;
mod processes;
mod settings;
mod startup;
mod system;
#[cfg(windows)]
mod tray;

use core::{CleanResult, DiskNode, Offered, Places, ScanItem};
use serde::Serialize;
use settings::Settings;
use tauri::{Emitter, Manager};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

/// Paths the UI was shown (the delete gate), shared by every command.
struct AppState {
    places: Places,
    offered: Mutex<Offered>,
    /// Program id -> its uninstall command, from the last listing (the UI only sends ids).
    apps: Mutex<HashMap<String, String>>,
    /// Start-up entry ids from the last listing.
    startup: Mutex<HashSet<String>>,
    boost: Mutex<Option<Vec<String>>>,
    heavy: Mutex<HashMap<String, Vec<(u32, u64)>>>,
    settings_path: PathBuf,
    settings: Mutex<Settings>,
}

#[derive(Default, Serialize)]
struct DiskInfo {
    total: u64,
    free: u64,
}

#[derive(Serialize)]
struct BinInfo {
    bytes: u64,
    items: u64,
}

/// Slow file work runs off the UI thread.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn scan(kind: String, state: tauri::State<'_, AppState>) -> Result<Vec<ScanItem>, String> {
    let p = state.places.clone();
    let counts_as_scan = matches!(kind.as_str(), "junk" | "caches");
    let items = blocking(move || match kind.as_str() {
        "junk" => core::scan_junk(&p),
        "caches" => core::scan_caches(&p),
        "downloads" => core::scan_old_downloads(&p, 90, SystemTime::now()),
        "large" => core::scan_large(&p, 500 * 1024 * 1024),
        "duplicates" => core::scan_duplicates(&p, 1024 * 1024),
        "privacy" => core::scan_privacy(&p),
        "leftovers" => {
            let names: Vec<String> = apps::list().into_iter().flat_map(|a| [a.name, a.publisher]).collect();
            core::scan_leftovers(&p, &names, 30, SystemTime::now())
        }
        _ => vec![],
    })
    .await?;
    state.offered.lock().unwrap().add_items(&items);
    if counts_as_scan { record_scan(&state); }
    Ok(items)
}

#[tauri::command]
async fn disk_children(path: Option<String>, state: tauri::State<'_, AppState>) -> Result<Vec<DiskNode>, String> {
    let p = state.places.clone();
    let dir = path.map(PathBuf::from).unwrap_or_else(|| p.home.clone());
    let nodes = blocking(move || core::disk_children(&dir, &p)).await?;
    state.offered.lock().unwrap().add_nodes(&nodes);
    Ok(nodes)
}

#[tauri::command]
fn home(state: tauri::State<'_, AppState>) -> String {
    state.places.home.to_string_lossy().into_owned()
}

/// Moves the chosen items to the Recycle Bin (recoverable).
#[tauri::command]
async fn clean(paths: Vec<String>, state: tauri::State<'_, AppState>) -> Result<CleanResult, String> {
    let offered = Offered(state.offered.lock().unwrap().0.clone());
    let p = state.places.clone();
    blocking(move || core::remove(&paths, &offered, &p, to_recycle_bin)).await
}

#[cfg(windows)]
fn to_recycle_bin(path: &Path) -> Result<(), String> {
    trash::delete(path).map_err(|e| e.to_string())
}

/// Removal is Windows-only: a development run on another system never deletes anything.
#[cfg(not(windows))]
fn to_recycle_bin(_: &Path) -> Result<(), String> {
    Err("removal runs on Windows only".into())
}

#[tauri::command]
async fn list_apps(state: tauri::State<'_, AppState>) -> Result<Vec<apps::InstalledApp>, String> {
    let list = blocking(apps::list).await?;
    *state.apps.lock().unwrap() = list.iter().map(|a| (a.id.clone(), a.command.clone())).collect();
    Ok(list)
}

/// Opens the program's own uninstaller; only for ids from the last listing.
#[tauri::command]
fn uninstall(id: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let cmd = state.apps.lock().unwrap().get(&id).cloned().ok_or("unknown program")?;
    apps::launch(&cmd)
}

#[tauri::command]
async fn startup_list(state: tauri::State<'_, AppState>) -> Result<Vec<startup::StartupItem>, String> {
    let p = state.places.clone();
    let list = blocking(move || startup::list(&p)).await?;
    *state.startup.lock().unwrap() = list.iter().map(|i| i.id.clone()).collect();
    Ok(list)
}

/// Switches a start-up entry on or off (reversible); only ids from the last listing.
#[tauri::command]
fn startup_set(id: String, enabled: bool, state: tauri::State<'_, AppState>) -> Result<(), String> {
    if !state.startup.lock().unwrap().contains(&id) {
        return Err("unknown entry".into());
    }
    startup::set_enabled(&id, enabled)
}

#[tauri::command]
async fn privacy_access() -> Result<Vec<system::Access>, String> {
    blocking(system::access).await
}

#[tauri::command]
async fn run_task(id: String) -> Result<(), String> {
    blocking(move || system::run_task(&id)).await?
}

#[tauri::command]
fn open_settings(page: String) -> Result<(), String> {
    apps::launch(system::settings_page(&page).ok_or("unknown page")?)
}

/// Opens a Cleanix for Windows release page in the browser (update notice); nothing else.
#[tauri::command]
fn open_release(tag: String) -> Result<(), String> {
    if !tag.starts_with("win-v") || !tag[5..].chars().all(|c| c.is_ascii_digit() || c == '.') {
        return Err("bad tag".into());
    }
    apps::launch(&format!("https://github.com/moramadan91/cleanix/releases/tag/{tag}"))
}

#[tauri::command]
fn disk_info() -> Option<DiskInfo> {
    win::disk_info()
}

#[tauri::command]
fn recycle_info() -> Option<BinInfo> {
    win::recycle_info()
}

#[tauri::command]
async fn downloads_size(app: tauri::AppHandle, state: tauri::State<'_, AppState>) -> Result<u64, String> {
    let dir = app.path().download_dir().unwrap_or_else(|_| state.places.home.join("Downloads"));
    blocking(move || core::size_of(&dir)).await
}

#[tauri::command]
fn open_recycle_bin() -> Result<(), String> {
    #[cfg(windows)]
    system::hidden_command("explorer.exe")
        .arg("shell:RecycleBinFolder")
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Empties the Recycle Bin for good. The UI asks for an explicit confirmation first.
#[tauri::command]
async fn empty_recycle(confirmed: bool) -> Result<(), String> {
    if !confirmed {
        return Err("not confirmed".into());
    }
    blocking(win::empty_recycle).await?
}

#[derive(Serialize)]
struct Health {
    score: u8,
    issues: Vec<&'static str>,
    disk: DiskInfo,
    ram: health::Ram,
    startup: usize,
    junk: u64,
    battery: Option<health::Battery>,
}

fn record_scan(state: &AppState) {
    let mut settings = state.settings.lock().unwrap();
    settings.last_scan = settings::now();
    let _ = settings.save(&state.settings_path);
}

#[tauri::command]
async fn health(state: tauri::State<'_, AppState>) -> Result<Health, String> {
    let p = state.places.clone();
    let report = blocking(move || {
        let disk = win::disk_info().unwrap_or_default();
        let ram = health::ram();
        let startup = startup::list(&p).into_iter().filter(|i| i.enabled).count();
        let junk = core::scan_junk(&p).iter().map(|i| i.bytes).sum();
        let (score, issues) = health::health_score(disk.free, disk.total, ram.ratio(), startup, junk);
        Health { score, issues, disk, ram, startup, junk, battery: health::battery() }
    }).await?;
    record_scan(&state);
    Ok(report)
}

#[derive(Serialize)]
struct BoostPreview {
    bytes: u64,
    ram_used: u64,
    ram_total: u64,
}

#[tauri::command]
async fn boost_preview(state: tauri::State<'_, AppState>) -> Result<BoostPreview, String> {
    let p = state.places.clone();
    let (items, ram) = blocking(move || (core::scan_junk(&p), health::ram())).await?;
    let mut boost = state.boost.lock().unwrap();
    state.offered.lock().unwrap().add_items(&items);
    *boost = Some(items.iter().map(|i| i.path.clone()).collect());
    Ok(BoostPreview { bytes: items.iter().map(|i| i.bytes).sum(), ram_used: ram.used, ram_total: ram.total })
}

#[derive(Serialize)]
struct BoostResult {
    freed: u64,
    failed: Vec<String>,
    ram_before: u8,
    ram_after: u8,
}

#[tauri::command]
async fn boost_run(state: tauri::State<'_, AppState>) -> Result<BoostResult, String> {
    let (paths, offered) = {
        let mut boost = state.boost.lock().unwrap();
        let paths = boost.take().ok_or("no boost preview")?;
        let offered = Offered(state.offered.lock().unwrap().0.clone());
        (paths, offered)
    };
    let p = state.places.clone();
    blocking(move || {
        let ram_before = (health::ram().ratio() * 100.0).round() as u8;
        let result = core::remove(&paths, &offered, &p, to_recycle_bin);
        processes::trim_memory();
        let ram_after = (health::ram().ratio() * 100.0).round() as u8;
        BoostResult { freed: result.freed, failed: result.failed, ram_before, ram_after }
    }).await
}

#[tauri::command]
async fn heavy_apps(state: tauri::State<'_, AppState>) -> Result<Vec<processes::HeavyApp>, String> {
    let list = blocking(processes::heavy_apps).await?;
    *state.heavy.lock().unwrap() = list.iter().map(|a| (a.id.clone(), a.members.clone())).collect();
    Ok(list)
}

#[tauri::command]
async fn quit_app(id: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let members = state.heavy.lock().unwrap().get(&id).cloned().ok_or("unknown program")?;
    blocking(move || processes::quit_app(&id, &members)).await?
}

#[tauri::command]
async fn extensions(state: tauri::State<'_, AppState>) -> Result<Vec<extensions::Extension>, String> {
    let p = state.places.clone();
    blocking(move || extensions::list(&p)).await
}

#[tauri::command]
fn settings_get(state: tauri::State<'_, AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
fn settings_set(open_at_login: bool, alert_low_space: bool, alert_weekly: bool, state: tauri::State<'_, AppState>) -> Result<Settings, String> {
    let mut current = state.settings.lock().unwrap();
    let next = Settings { open_at_login, alert_low_space, alert_weekly, ..current.clone() };
    let login_changed = open_at_login != current.open_at_login;
    if login_changed {
        startup::set_open_at_login(open_at_login)?;
    }
    if let Err(e) = next.save(&state.settings_path) {
        if login_changed {
            let _ = startup::set_open_at_login(current.open_at_login);
        }
        return Err(e.to_string());
    }
    *current = next.clone();
    Ok(next)
}

#[tauri::command]
fn set_lang(lang: String, app: tauri::AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    if lang != "en" && lang != "ar" {
        return Err("unknown language".into());
    }
    {
        let mut current = state.settings.lock().unwrap();
        if current.lang == lang {
            return Ok(());
        }
        let next = Settings { lang: lang.clone(), ..current.clone() };
        next.save(&state.settings_path).map_err(|e| e.to_string())?;
        *current = next;
    }
    #[cfg(windows)]
    tray::refresh_menu(&app, &lang).map_err(|e| e.to_string())?;
    let _ = app;
    Ok(())
}

#[cfg(windows)]
fn start_alerts(app: tauri::AppHandle, start_hidden: bool) {
    let interval = std::time::Duration::from_secs(30 * 60);
    std::thread::spawn(move || {
        // A due toast should not appear during a tray-only login start.
        if start_hidden {
            std::thread::sleep(interval);
        }
        loop {
            let state = app.state::<AppState>();
            let disk = win::disk_info();
            let (free, total) = disk.as_ref().map_or((u64::MAX, 0), |d| (d.free, d.total));
            for alert in [settings::Alert::LowSpace, settings::Alert::Weekly] {
                let lang = {
                    let current = state.settings.lock().unwrap();
                    settings::due_alerts(settings::now(), &current, free, total)
                        .contains(&alert).then(|| current.lang.clone())
                };
                if let Some(lang) = lang {
                    if settings::show_alert(alert, free, &lang).is_ok() {
                        let mut current = state.settings.lock().unwrap();
                        match alert {
                            settings::Alert::LowSpace => current.last_low_space_alert = settings::now(),
                            settings::Alert::Weekly => current.last_weekly_alert = settings::now(),
                        }
                        let _ = current.save(&state.settings_path);
                    }
                }
            }
            std::thread::sleep(interval);
        }
    });
}

#[tauri::command]
fn reveal(path: String) {
    #[cfg(windows)]
    {
        let _ = system::hidden_command("explorer.exe").arg(format!("/select,{path}")).spawn();
    }
    #[cfg(not(windows))]
    let _ = path;
}

#[cfg(windows)]
mod win {
    use super::{BinInfo, DiskInfo};
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    use windows_sys::Win32::UI::Shell::{
        SHEmptyRecycleBinW, SHQueryRecycleBinW, SHERB_NOCONFIRMATION, SHERB_NOPROGRESSUI, SHERB_NOSOUND,
        SHQUERYRBINFO,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn system_drive() -> String {
        std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into()) + "\\"
    }

    pub fn disk_info() -> Option<DiskInfo> {
        let root = wide(&system_drive());
        let (mut free, mut total, mut total_free) = (0u64, 0u64, 0u64);
        // SAFETY: valid NUL-terminated path and out-pointers to live u64s.
        let ok = unsafe { GetDiskFreeSpaceExW(root.as_ptr(), &mut free, &mut total, &mut total_free) };
        (ok != 0).then_some(DiskInfo { total, free })
    }

    /// All drives' bins (null root).
    pub fn recycle_info() -> Option<BinInfo> {
        let mut info: SHQUERYRBINFO = unsafe { std::mem::zeroed() };
        info.cbSize = std::mem::size_of::<SHQUERYRBINFO>() as u32;
        // SAFETY: info is a correctly sized, writable SHQUERYRBINFO.
        let hr = unsafe { SHQueryRecycleBinW(std::ptr::null(), &mut info) };
        (hr >= 0).then_some(BinInfo { bytes: info.i64Size as u64, items: info.i64NumItems as u64 })
    }

    pub fn empty_recycle() -> Result<(), String> {
        // SAFETY: null window and null root (all bins) are documented valid arguments.
        let hr = unsafe {
            SHEmptyRecycleBinW(
                std::ptr::null_mut(),
                std::ptr::null(),
                SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND,
            )
        };
        // An already empty bin reports an error code; treat it as done.
        if hr >= 0 || recycle_info().is_some_and(|b| b.items == 0) {
            Ok(())
        } else {
            Err(format!("HRESULT {hr:#x}"))
        }
    }
}

/// Development stand-ins for other systems: nothing to show, nothing emptied.
#[cfg(not(windows))]
mod win {
    use super::{BinInfo, DiskInfo};
    pub fn disk_info() -> Option<DiskInfo> {
        None
    }
    pub fn recycle_info() -> Option<BinInfo> {
        None
    }
    pub fn empty_recycle() -> Result<(), String> {
        Err("Windows only".into())
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let settings_path = app.path().app_config_dir()?.join("settings.json");
            let settings = Settings::load(&settings_path);
            #[cfg(windows)]
            let lang = settings.lang.clone();
            app.manage(AppState {
                places: Places::from_env(), offered: Mutex::default(), apps: Mutex::default(),
                startup: Mutex::default(), boost: Mutex::default(), heavy: Mutex::default(),
                settings_path, settings: Mutex::new(settings),
            });
            #[cfg(windows)]
            {
                let start_hidden = std::env::args_os().any(|arg| arg == "--hidden");
                tray::setup(app.handle(), &lang)?;
                start_alerts(app.handle().clone(), start_hidden);
                if let Some(w) = app.get_webview_window("main") {
                    // Mica on Windows 11, acrylic on 10; the page keeps its own dark tint either way.
                    if window_vibrancy::apply_mica(&w, Some(true)).is_err() {
                        let _ = window_vibrancy::apply_acrylic(&w, Some((20, 16, 28, 200)));
                    }
                }
                if !start_hidden {
                    tray::show_main(app.handle())?;
                }
            }
            #[cfg(not(windows))]
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_skip_taskbar(false);
                window.show()?;
                window.emit("window-shown", ())?;
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            #[cfg(windows)]
            if window.label() == "main" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    if window.state::<AppState>().settings.lock().unwrap().stay_in_tray() {
                        api.prevent_close();
                        let _ = window.hide();
                        let _ = window.set_skip_taskbar(true);
                    }
                }
            }
            #[cfg(not(windows))]
            let _ = (window, event);
        })
        .invoke_handler(tauri::generate_handler![
            scan,
            disk_children,
            home,
            clean,
            disk_info,
            recycle_info,
            downloads_size,
            open_recycle_bin,
            empty_recycle,
            health,
            boost_preview,
            boost_run,
            heavy_apps,
            quit_app,
            extensions,
            settings_get,
            settings_set,
            set_lang,
            reveal,
            list_apps,
            uninstall,
            startup_list,
            startup_set,
            privacy_access,
            run_task,
            open_settings,
            open_release
        ])
        .run(tauri::generate_context!())
        .expect("error while running Cleanix");
}
