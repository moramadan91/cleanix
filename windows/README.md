# Cleanix for Windows

Tauri 2 app: a plain HTML/JS page (`src/`) on top of Rust (`src-tauri/`).

- `src-tauri/src/core.rs`: scanners and the delete gate (only paths a scan offered, never risky ones,
  only inside the user's folders). Removal goes to the Recycle Bin and runs on Windows only.
- `src/mock.js`: fake data so the page can be designed in any browser (`python3 -m http.server -d src`).

Tests: `cargo test --manifest-path src-tauri/Cargo.toml`
Installer: built by `.github/workflows/windows.yml` on every push to `windows/` (Actions → artifact).
