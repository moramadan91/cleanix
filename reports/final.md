# Final report (Tasks 14 to 16)

Status: every section has a working screen; 83 tests pass (`swift test`); `scripts/bundle.sh` builds `build/Naddaf.app`. Idle CPU 0.0 to 1.5%.

## Done
- Cleanup: Sweep, App Caches (per-app ticks, running apps unticked, system apps hidden), Trash Bins (second confirmation), Mail Attachments, Shredder.
- Protection: Privacy (browser caches ticked, history/cookies unticked), App Permissions (read-only), Needs Review (unsigned or not notarized; listed only).
- Performance: Maintenance (5 tasks, admin prompt), Login Items (user agents to Quarantine; system ones read-only).
- Apps: Uninstall (app + leftovers to Trash), Leftovers, Unused (90 days).
- Clutter: Large & Old, Duplicates, Similar Images, Downloads (personal folders only).
- Disk Map: folder list with safe / review / do-not-delete labels and "safe inside" totals, bubble view, removal via PreviewSheet (do-not-delete entries cannot be ticked). Rules in `SpaceAdvice` (tested).
- Cloud: detected folders, largest files, free up iCloud files.
- Smart Scan (Sweep + app caches + browser caches, to Quarantine) and Overview (storage bar, quick sizes).
- `LocalizationTests`: every key has ar + en, every literal key used in code exists.
- `--demo-home <path>` swaps the home folder for a fake one.

## Deviations
- Uninstall and Disk Map send items to the Trash, not Quarantine (apps and large folders).
- Maintenance runs real system commands even in demo mode.
- SMAppService helper not built (AdminPromptRunner instead). No App Updater (needs network).

## Not verified
- Screens were not seen or clicked by me (no Screen Recording permission); the human must test each one.
- On the real home, Trash, TCC and other apps' containers need Full Disk Access; without it they show empty or fail per item.
