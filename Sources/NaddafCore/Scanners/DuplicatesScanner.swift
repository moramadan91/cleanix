import Foundation
import CryptoKit

public struct DuplicateGroup: Sendable {
    public let keep: ScanItem
    public let extras: [ScanItem]
}

/// Finds identical files: group by size, drop hardlinks (same inode), then compare SHA-256.
public struct DuplicatesScanner: Sendable {
    private let roots: [URL]

    public init(roots: [URL]) { self.roots = roots }

    private struct Entry { let url: URL; let size: Int64; let created: Date }

    public func groups() async throws -> [DuplicateGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey]
        var bySize: [Int64: [Entry]] = [:]
        var seenInodes = Set<String>()

        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = walker.nextObject() as? URL {
                try Task.checkCancellation()
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.fileSize, size > 0,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
                let inode = "\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
                guard seenInodes.insert(inode).inserted else { continue }
                bySize[Int64(size), default: []].append(Entry(url: url, size: Int64(size), created: v.creationDate ?? .distantFuture))
            }
        }

        var result: [DuplicateGroup] = []
        for (_, entries) in bySize where entries.count > 1 {
            var byHash: [String: [Entry]] = [:]
            for entry in entries {
                try Task.checkCancellation()
                if let hash = Self.sha256(of: entry.url) { byHash[hash, default: []].append(entry) }
            }
            for (_, same) in byHash where same.count > 1 {
                let sorted = same.sorted { ($0.created, $0.url.path) < ($1.created, $1.url.path) }
                let name = sorted[0].url.lastPathComponent
                func item(_ e: Entry) -> ScanItem {
                    ScanItem(url: e.url, bytes: e.size, reason: "Duplicate of \(name)", safety: .review, group: name)
                }
                result.append(DuplicateGroup(keep: item(sorted[0]), extras: sorted.dropFirst().map(item)))
            }
        }
        return result.sorted { $0.keep.bytes > $1.keep.bytes }
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
