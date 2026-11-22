# Report: Tasks 12A-12H (scanners for the merged feature list)

Status: complete. `swift test`: 76 tests passed. Executed in the main session.

## Done
- 12A Mail attachments, 12B Downloads, 12D Privacy check (cache safe; history and cookies need review, separate groups).
- 12C Similar images (Vision feature prints, on-device), 12E App permissions (read-only TCC via SQLite3), 12F Suspicious items (signature check with injectable verifier), 12G Cloud folders (local only, iCloud evict), 12H Smart Scan (concurrent, failures reported per section).

## Rulings
- The enum `NaddafCore` in `Version.swift` shadowed the module name (`NaddafCore.Scanner` failed to resolve). Renamed it to `NaddafInfo`. `Scanner` also exists in Foundation, so tests qualify it as `NaddafCore.Scanner`; app code must do the same.
- Similar-images threshold `maxDistance = 0.5` passed the synthetic stripes/circles test; it is NOT tuned on real photos.
- Smart Scan cancelled scanners report `error == "cancelled"`.
- Suspicious items only says "Not signed" / "Not notarized". It does not claim malware detection.

## Not verified
- `CodesignVerifier` (real `codesign`/`spctl`) and reading the real TCC.db (needs Full Disk Access) were never run.
- `evictUbiquitousItem` was not exercised (needs a real iCloud file).
