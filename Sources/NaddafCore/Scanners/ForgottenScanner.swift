import Foundation

/// Large files not modified for a long time. Packages such as .app count as one item.
public struct ForgottenScanner: Scanner {
    private let root: URL
    private let minBytes: Int64
    private let olderThanDays: Int
    private let now: Date

    public init(root: URL, minBytes: Int64, olderThanDays: Int, now: Date = Date()) {
        self.root = root
        self.minBytes = minBytes
        self.olderThanDays = olderThanDays
        self.now = now
    }

    public func scan() async throws -> [ScanItem] {
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86400)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }

        var items: [ScanItem] = []
        while let url = walker.nextObject() as? URL {
            try Task.checkCancellation()
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = v.contentModificationDate, modified < cutoff else { continue }
            let bytes: Int64
            if v.isRegularFile == true {
                bytes = Int64(v.fileSize ?? 0)
            } else if v.isPackage == true {
                bytes = FS.size(of: url)
            } else {
                continue
            }
            if bytes >= minBytes {
                items.append(ScanItem(url: url, bytes: bytes, reason: "Not modified for \(olderThanDays)+ days",
                                      safety: .review, group: url.deletingLastPathComponent().lastPathComponent))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
}
