import Foundation

/// One item per trash bin that has content. Emptying is permanent, so it needs `confirmed: true`.
public struct TrashScanner: Scanner {
    private let trashRoots: [URL]

    public init(trashRoots: [URL]) { self.trashRoots = trashRoots }

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for root in trashRoots where FS.exists(root) {
            try Task.checkCancellation()
            let bytes = FS.size(of: root)
            if bytes > 0 {
                items.append(ScanItem(url: root, bytes: bytes, reason: "Trash bin",
                                      safety: .review, group: root.lastPathComponent))
            }
        }
        return items
    }
}

/// Deletes the contents of each bin (the bin folder itself stays). Not undoable.
public func emptyTrash(_ items: [ScanItem], confirmed: Bool, policy: PathPolicy) async throws -> CleanResult {
    guard confirmed else { throw NaddafError.confirmationRequired }
    var result = CleanResult()
    for bin in items {
        for child in FS.children(of: bin.url) {
            guard policy.isAllowed(child) else {
                result.failed.append((child, "path is not allowed"))
                continue
            }
            let bytes = FS.size(of: child)
            do {
                try FileManager.default.removeItem(at: child)
                result.removed.append(child)
                result.freedBytes += bytes
            } catch {
                result.failed.append((child, error.localizedDescription))
            }
        }
    }
    return result
}
