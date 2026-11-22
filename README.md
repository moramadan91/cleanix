<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Cleanix icon"></p>

# Cleanix

A free, open-source Mac cleaner in Arabic and English. Native SwiftUI, liquid-glass design, no network, no account.

تطبيق مجاني ومفتوح المصدر لتنضيف الماك، بالعربي والإنجليزي. مكتوب بـ SwiftUI، بتصميم زجاجي، من غير إنترنت ومن غير حساب.

## What it does

| Section | Screens |
|---|---|
| Smart Scan | One click: system junk, app caches, browser caches |
| Cleanup | Sweep, App Caches, Trash, Mail Attachments, Shredder |
| Protection | Privacy (browser data), App Permissions, Needs Review (unsigned apps) |
| Performance | Maintenance tasks, Login Items |
| Apps | Uninstall with leftovers, Leftovers, Unused apps |
| Clutter | Large & Old, Duplicates, Similar Images, Downloads |
| Disk Map | What takes space, labelled safe / review / do not delete |
| Cloud | Free up local copies of iCloud files |

Switch between Arabic and English from the button in the bottom corner.

## Safety

- Nothing is deleted without a review sheet that lists every item.
- Cleaned items go to a Quarantine folder for 30 days and can be restored with **Undo**. Uninstalled apps and Disk Map removals go to the Trash.
- Every deletion passes an allowlist of folders (`PathPolicy`); anything outside it is refused.
- Emptying the Trash and the Shredder ask for a second confirmation, because they cannot be undone.
- Admin tasks ask for your password through macOS itself; Cleanix never sees it.

## Install

1. Download `Cleanix-<version>.dmg` from Releases and drag Cleanix to Applications.
2. The app is not notarized yet: the first time, right-click it and choose **Open**.
3. Give it **Full Disk Access** (System Settings → Privacy & Security). Without it the Trash, Mail and app data look empty. The app shows a banner with a button that opens the right page.

Requires macOS 26 or later.

## Build from source

```bash
swift test                 # run the tests
./scripts/bundle.sh        # build/Cleanix.app
./scripts/make_dmg.sh      # build/Cleanix-<version>.dmg
```

Try every screen on fake files, without touching your own:

```bash
open -n build/Cleanix.app --args --demo-home /path/to/a/fake/home
```

The app icon is drawn by `scripts/make_icon.swift`; strings live in `Sources/Naddaf/Resources/Localizable.xcstrings` (add keys with `scripts/add_strings.py`).

## License

MIT. See [LICENSE](LICENSE).
