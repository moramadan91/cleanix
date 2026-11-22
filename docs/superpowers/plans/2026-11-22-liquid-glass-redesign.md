# Liquid Glass Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac app's glass read as 3D, add a round main button, and open scan results on group cards.

**Architecture:** One shared `depthGlass` modifier and a static light-blob background carry the look; a
`RoundActionButton` replaces the big capsule; `ScanListView` gains a cards phase driven by a pure
`groupSummaries` function in NaddafCore (tested).

**Tech Stack:** SwiftUI on macOS 26 (`glassEffect`, `GlassEffectContainer`), Swift Testing.

**Spec:** docs/superpowers/specs/2026-11-22-liquid-glass-redesign-design.md

## Global Constraints
- Clear, untinted glass; section colours in the background only.
- Lists max 560pt, centred; title top-centre; Arabic RTL.
- Idle CPU ~0: nothing animates continuously except the existing `LiveSymbol`.
- No `.interactive()` glass on buttons; no glass on focused TextFields.
- Every new string in both `ar.lproj` and `en.lproj` (LocalizationTests checks).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus
- One group only (Trash): list shows directly, no cards.
- Reveal mode (no deletion): cards have no tick box; button is Scan again.
- Group tick box when some items in the group are ticked: shows mixed, click selects all.
- Arabic: cards grid and Back button mirror correctly.
- Long list scroll stays smooth (no per-row glass in file lists).

---

### Task 1: Depth glass kit and background
**Files:** Modify `Sources/Naddaf/Components.swift` (AuroraBackground), `Sources/Naddaf/Screens/ScreenParts.swift`, `Sources/Naddaf/RootView.swift` (TabStrip).
- [ ] Add `extension View { func depthGlass<S: Shape>(_ shape: S, lift: CGFloat = 1) -> some View }`: `.glassEffect(.clear, in: shape)` + rim stroke (white 0.45 top → 0.03 bottom, 1pt) + shadow (black 0.25, radius 10·lift, y 6·lift).
- [ ] Use it in GlassPanel, TabStrip, LiquidButtonStyle, GlassCheckStyle (on state), GlassBadge, DoneView tick.
- [ ] AuroraBackground: add 3 static blurred blobs (tint, tint2, white 0.10), mirrored in RTL.
- [ ] `swift build`; Expected: Build complete.

### Task 2: Round main button
**Files:** Modify `ScreenParts.swift` (ActionButton, DoneView), `RootView.swift` (IntroHero).
- [ ] `struct RoundActionButton: View { title, tint: Color, disabled, action }`: 120pt depthGlass circle, static ring (tint 0.35, 1.5pt, 140pt), label 17 bold, press 0.96.
- [ ] ActionButton gains `tint` (default `.white`) and draws RoundActionButton; IntroHero and DoneView main action use it with `section.tint` where a section is known.
- [ ] `swift build`; Expected: Build complete.

### Task 3: Glass rows for short lists
**Files:** Modify `ScreenParts.swift` (RowBackground), `PerformanceViews.swift`, `PermissionsView.swift`, `CloudView.swift`.
- [ ] RowBackground gets `glass: Bool = false`: glass → `depthGlass(RoundedRectangle(12), lift: 0.4)`; otherwise current fill + rim stroke only.
- [ ] Short lists (maintenance, startup, permissions, cloud) pass `glass: true` and wrap rows in `GlassEffectContainer`.
- [ ] `swift build`; Expected: Build complete.

### Task 4: Result cards
**Files:** Create `Sources/NaddafCore/GroupSummary.swift`; Test `Tests/NaddafCoreTests/GroupSummaryTests.swift`; Modify `ScanListView.swift`, `Resources/*/Localizable.strings`.
**Interfaces:** Produces `public struct GroupSummary { group: String; bytes: Int64; count: Int }` and `public func groupSummaries(_ items: [ScanItem]) -> [GroupSummary]` (first-seen order; UI sorts).
- [ ] Test: two groups → totals and counts right, first-seen order; empty → `[]`.
- [ ] Run `swift test --filter groupSummar`; Expected: FAIL (not defined).
- [ ] Implement; run again; Expected: PASS.
- [ ] ScanListView: new `@State reviewing: String?`. Results with 2+ groups and `reviewing == nil` → 2-column `LazyVGrid` of depthGlass cards (symbol, title, size, count, group tick box unless reveal, "Review" capsule) + round main button. `reviewing != nil` → existing list filtered to that group + Back capsule. 1 group → list as today.
- [ ] Strings `common.review`, `common.back`, `common.itemCount` in ar + en.
- [ ] `swift test`; Expected: all pass.

### Task 5: Smart Scan and check
- [ ] SmartScanView cards: swap their `glassEffect(.regular.tint…)` for `depthGlass` (keep layout).
- [ ] `./scripts/bundle.sh`, open demo (`--demo-home` fake home), screenshot overview, cleanup intro, cleanup cards, review list, performance maintenance, in Arabic and English. Look; fix worst issues.
- [ ] Idle CPU of the demo app ~0 (`ps -o %cpu`) after 10s idle.
- [ ] Quit the demo app. Commit.
