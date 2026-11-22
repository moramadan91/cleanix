# Report: Tasks 1-3 (scaffold, PathPolicy, Cleaner + Quarantine)

Status: complete. `swift test`: 13 tests passed (Swift Testing). STOP point reached: human reviews the safety core before scanners.

## Done
- Task 1: SwiftPM package (`NaddafCore` lib, `Naddaf` app, tests), String Catalog (ar/en), `scripts/bundle.sh` builds an ad-hoc signed `build/Naddaf.app`.
- Task 2: `PathPolicy` (allowlist, resolves symlinks and `..`, rejects roots themselves and same-prefix siblings), `Model.swift` (Safety, ScanItem, Scanner).
- Task 3: `Quarantine` (stash/restore/purgeExpired, JSON index), `Cleaner` (policy check, trash or quarantine, failures recorded and the rest continue).

## Rulings
- Package.swift platform floor is macOS 26.0, not 27: SwiftPM tools 6.2 has no v27 constant, and `glassEffect` exists from 26. Cost if wrong: app would also launch on macOS 26.
- Work was executed in the main chat session, not in the c1 session (user changed the setup). Commands run in Terminal tab c2.
- Test names match the plan; extra tests added: `rejectsSiblingWithSamePrefix`.

## Open questions
- None.
