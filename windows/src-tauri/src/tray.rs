use crate::{health, settings, AppState};
use std::time::Duration;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager,
};

const ID: &str = "cleanix";

fn menu(app: &AppHandle, lang: &str) -> tauri::Result<Menu<tauri::Wry>> {
    let (boost, open, quit) = if lang == "ar" {
        ("تسريع فوري", "افتح Cleanix", "خروج")
    } else {
        ("Quick Boost", "Open Cleanix", "Quit")
    };
    let boost = MenuItem::with_id(app, "tray-boost", boost, true, None::<&str>)?;
    let open = MenuItem::with_id(app, "tray-open", open, true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "tray-quit", quit, true, None::<&str>)?;
    Menu::with_items(app, &[&boost, &open, &quit])
}

fn show_main(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        let _ = window.emit("window-shown", ());
    }
}

fn tooltip(lang: &str, cpu: u8) -> String {
    let ram = (health::ram().ratio() * 100.0).round() as u8;
    if lang == "ar" {
        let ram = settings::arabic_digits(&format!("{ram}%"));
        let cpu = settings::arabic_digits(&format!("{cpu}%"));
        format!("Cleanix — الرام {ram} · المعالج {cpu}")
    } else {
        format!("Cleanix — RAM {ram}% · CPU {cpu}%")
    }
}

pub fn refresh_menu(app: &AppHandle, lang: &str) -> tauri::Result<()> {
    if let Some(tray) = app.tray_by_id(ID) {
        tray.set_menu(Some(menu(app, lang)?))?;
    }
    Ok(())
}

pub fn setup(app: &AppHandle, lang: &str) -> tauri::Result<()> {
    let mut tray = TrayIconBuilder::with_id(ID)
        .menu(&menu(app, lang)?)
        .tooltip(tooltip(lang, 0))
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "tray-boost" => {
                show_main(app);
                let _ = app.emit_to("main", "tray-boost", ());
            }
            "tray-open" => show_main(app),
            "tray-quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if matches!(event, TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. }) {
                show_main(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;

    let app = app.clone();
    std::thread::spawn(move || {
        let mut prev = health::system_times();
        loop {
            std::thread::sleep(Duration::from_secs(3));
            let now = health::system_times();
            let cpu = prev.zip(now).map_or(0, |(a, b)| health::cpu_percent(a, b));
            prev = now;
            let lang = app.state::<AppState>().settings.lock().unwrap().lang.clone();
            let Some(tray) = app.tray_by_id(ID) else { break };
            let _ = tray.set_tooltip(Some(tooltip(&lang, cpu)));
        }
    });
    Ok(())
}
