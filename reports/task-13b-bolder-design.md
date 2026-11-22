# Report: Task 13b (bolder design, live icons, hover pill sidebar)

Status: built and running. Core tests untouched (76 pass); app target builds.

## Done
- Bolder background: each section has a vivid hue pair (`tint`, `tint2`) fading into the dusk base, plus a soft spotlight behind the hero. Still fully static.
- Bigger hero (460pt): glow, two rings, three glass satellites, a 250pt glass orb with a 116pt symbol. Larger type (title 58 bold) and glass feature chips.
- Live icons: each section's symbol plays a built-in SF Symbols effect (hand: wiggle, trash/apps/cloud: bounce, bolt/disk map: pulse, sparkles/overview: variable color).
- Sidebar: icons are 62pt (were 44pt). Hovering an icon expands it into a glass pill tinted with the section color, showing the icon and the full name (spring, 0.3s). Reads RTL correctly by construction (leading alignment).
- Strings unchanged.

## Idle CPU (acceptance: under 1%) — findings
- Looping `symbolEffect(.repeat(.periodic))`: about 21 to 23% idle CPU. Moving the glass out from behind the symbol did not help (still about 20%).
- One-shot every 9 seconds: 0.0 most samples but a burst of 11.8% per play, about 4% averaged. Rejected.
- FINAL: the symbol plays once when a section opens and once on hover. Idle: 0.0, 0.0, 0.0 (and 0.0 earlier).

## Rulings
- "Live" icons therefore animate on section open and on hover, not continuously. A continuous loop would break the lightness goal. If the user wants a periodic loop anyway, it costs real CPU (see above).
- The Promptory web skill (GSAP, Lenis, React Bits) is web-only and was not usable in a native SwiftUI app. Only its principles were applied: motion under 500ms, Reduce Motion respected (no animation when on), no animation when the window is inactive, one orchestrated moment.
- Section hues are more saturated than in Task 13 (user asked for a stronger design). They remain different from the original app's color-per-section mapping.

## Not verified
- Visual result and hover animation were NOT seen by me (no Screen Recording permission). The human must check how it looks and that the pill does not clip.
- Only measured CPU for the default (smartScan) section.
