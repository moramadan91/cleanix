# Cleanix Mac — deeper liquid glass + CleanMyMac-style layout

## Intent
The user feels the Mac app looks flat. They want real "3D liquid glass", in the spirit of the latest
CleanMyMac: deep backgrounds, floating glass, a round main button, results shown as cards.
Inspiration only: no CleanMyMac art, icons, names or exact layouts.

## Goals
- Glass reads as 3D: something behind it to bend, a lit rim on top, a soft shadow under it.
- One round glass main button per screen (Scan / Clean / Scan again).
- Scan results open on a grid of group cards; "Review" opens the existing list for that group.
- Ships together with: update check on every launch (done), `CleanixApp.swift` rename (done).

## Non-goals
- No 3D rendered images or new assets per section (option B, rejected for now).
- No change to scanning, cleaning, safety gates or Windows version.
- No module/target rename (`Naddaf` stays inside).

## Anti-goals (a failure even if it works)
- Tinted or solid-coloured glass, heavy extruded shadows, a glass "tablet" (user rejected all three).
- Idle CPU above ~0: no continuously animating background or glass.
- Slow scrolling in long lists (thousands of files).

## Constraints (existing rules, still binding)
- Clear, untinted glass that takes the colour behind it; section colours live in the background only.
- Lists max 560pt wide, centred, hug content; title top-centre; Arabic RTL works.
- macOS 26 `glassEffect`; no `.interactive()` on buttons (it steals clicks); no glass on focused TextFields.

## Approaches considered
- A — deepen the glass in code only. Low risk, no assets.
- B — A plus a 3D rendered object per section. Closest to CleanMyMac; needs generated art, style
  drift risk; user disliked extruded icons. Not now.
- C — CleanMyMac-style arrangement: round button, cards. Changes how results are browsed.
- **Picked: A + C** (user, 2026-11-22). C = round button and result cards.

## Design

### 1. Background (AuroraBackground)
Keep it static. Add 2–3 large, blurred light blobs per section in `tint`/`tint2`, placed so they sit
behind the hero and the list panel, plus a very faint top highlight. Crossfade on section change as today.

### 2. Depth glass kit (one modifier, used everywhere)
`.depthGlass(shape, lift:)` = `glassEffect(.clear)` + 1pt rim stroke (white 0.45 at top → 0.03 at
bottom) + soft shadow below (black ~0.25, radius by `lift`). Applied to: GlassPanel, tab strip,
LiquidButtonStyle, glass tick box, badges, cards, DoneView tick.

### 3. Rows
- Short lists (maintenance, permissions, startup, cards' review lists under ~40 rows): each row is
  depth glass inside one `GlassEffectContainer`.
- Long lists (`LazyVStack` of files): keep the light fill, add the rim stroke only. No per-row glass.

### 4. Round main button
New `RoundActionButton(title:, tint:)`: ~120pt glass circle, label inside, a static soft ring in the
section tint around it, press scales to 0.96. Replaces the big capsule in IntroHero, ActionButton and
DoneView's main action. Secondary actions (Undo, Select all…) stay capsules.

### 5. Result cards (ScanListView)
After a scan with 2+ groups: a grid (2 columns, max 560pt) of depth-glass cards, one per group:
group icon in a small glass circle, group title, total size, item count, a tick box that selects or
clears the whole group, and a "Review" capsule. Round "Clean" button below the grid.
"Review" shows the existing list filtered to that group, with a Back capsule to the cards.
One group only (e.g. Trash) or reveal mode with one group: skip the cards, show the list as today.
Smart Scan already has summary cards: give them the depth glass, no layout change.

## Left to the builder
- Exact blob positions/sizes, rim and shadow values; tune against screenshots.
- Group icon choice per group (SF Symbol mapping).
- Row-count threshold between glass rows and plain rows (measure scroll and idle CPU).

## Check before showing
Screenshot each section in Arabic and English; idle CPU ~0 in Activity Monitor; scroll a long list;
`swift test` green; quit any `build/Cleanix.app` test copy.
