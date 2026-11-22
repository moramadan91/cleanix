# Report: Task 13 (UI shell and Liquid Glass theme)

Status: built and running; STOP for design review. Core tests unchanged (76 pass); the app target builds with `swift build`.

## Done
- `Theme.swift` (Amber Dusk colors, 9 sections with a low-saturation tint each, `L()` for localized strings), `Components.swift` (`AuroraBackground`, `GlassCard`, `SectionHero`), `RootView.swift` (icon-only glass sidebar with tooltips + one page per section), `PreviewSheet.swift` (review-before-clean sheet, the only path to `Cleaner`), String Catalog with 49 ar/en keys.
- Run it: `./scripts/bundle.sh && open build/Naddaf.app --args -AppleLanguages '(ar)'` (use `'(en)'` for English).

## Idle CPU (acceptance: under 1%)
- App open and idle, `top -l 4 -s 3`: 0.0, 0.0, 0.4, 0.0 percent.

## Rulings
- The slow drifting glow in the background was REMOVED. With it, idle CPU measured 3.9%, because SwiftUI redraws every frame for it. The background is now static and only fades when the section changes.
- Pages are placeholders (title, subtitle, feature list, hero, Scan button that does nothing yet). Real screens come in Tasks 14, 15, 15A.

## Not verified
- NO screenshots: `screencapture` and the computer-use capture both returned black/no picture (the host has no Screen Recording permission). Arabic/RTL layout was therefore not checked by me visually; the human must look at the running app.
- `glassEffect`, `GlassEffectContainer` and `.glassProminent` compiled on Xcode 27.2 SDK, but how they look is unchecked.
