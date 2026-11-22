mod core;

use core::{CleanResult, DiskNode, Offered, Places, ScanItem};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

/// Paths the UI was shown (the delete gate), shared by every command.
struct AppState {
    places: Places,
    offered: Mutex<Offered>,
}

#[derive(Serialize)]
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
    let items = blocking(move || match kind.as_str() {
        "junk" => core::scan_junk(&p),
        "caches" => core::scan_caches(&p),
        "downloads" => core::scan_old_downloads(&p, 90, SystemTime::now()),
        "large" => core::scan_large(&p, 500 * 1024 * 1024),
        _ => vec![],
    })
    .await?;
    state.offered.lock().unwrap().add_items(&items);
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
fn disk_info() -> Option<DiskInfo> {
    win::disk_info()
}

#[tauri::command]
fn recycle_info() -> Option<BinInfo> {
    win::recycle_info()
}

/// Empties the Recycle Bin for good. The UI asks for an explicit confirmation first.
#[tauri::command]
async fn empty_recycle(confirmed: bool) -> Result<(), String> {
    if !confirmed {
        return Err("not confirmed".into());
    }
    blocking(win::empty_recycle).await?
}

#[tauri::command]
fn reveal(path: String) {
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("explorer").arg(format!("/select,{path}")).spawn();
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
        .manage(AppState { places: Places::from_env(), offered: Mutex::new(Offered::default()) })
        .setup(|app| {
            #[cfg(windows)]
            {
                use tauri::Manager;
                if let Some(w) = app.get_webview_window("main") {
                    // Mica on Windows 11, acrylic on 10; the page keeps its own dark tint either way.
                    if window_vibrancy::apply_mica(&w, Some(true)).is_err() {
                        let _ = window_vibrancy::apply_acrylic(&w, Some((20, 16, 28, 200)));
                    }
                }
            }
            let _ = app;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            scan,
            disk_children,
            home,
            clean,
            disk_info,
            recycle_info,
            empty_recycle,
            reveal
        ])
        .run(tauri::generate_context!())
        .expect("error while running Cleanix");
}
