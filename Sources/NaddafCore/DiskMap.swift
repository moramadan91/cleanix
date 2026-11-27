import Foundation

public final class DiskNode: Sendable {
    public let name: String
    public let url: URL
    public let bytes: Int64
    public let children: [DiskNode]

    init(name: String, url: URL, bytes: Int64, children: [DiskNode] = []) {
        self.name = name
        self.url = url
        self.bytes = bytes
        self.children = children
    }
}

/// Size tree for the Disk Map. `depth` levels of children are kept; entries under 1% of their
/// parent are folded into one "Other" node, except folders on the open navigation trail.
/// Symlinks are never followed.
public func buildDiskTree(root: URL, depth: Int, keepingVisible: Set<URL> = []) async throws -> DiskNode {
    try Task.checkCancellation()
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    let values = try? root.resourceValues(forKeys: keys)
    let name = root.lastPathComponent
    if values?.isSymbolicLink == true { return DiskNode(name: name, url: root, bytes: 0) }
    if values?.isRegularFile == true { return DiskNode(name: name, url: root, bytes: Int64(values?.fileSize ?? 0)) }
    if depth <= 0 { return DiskNode(name: name, url: root, bytes: FS.size(of: root)) }

    // Every child folder is measured at the same time (home, depth 4, 187 GB: ~20 s one by one, ~3.5 s together).
    let kids = try await withThrowingTaskGroup(of: DiskNode.self) { group in
        for child in FS.children(of: root) {
            group.addTask { try await buildDiskTree(root: child, depth: depth - 1, keepingVisible: keepingVisible) }
        }
        var out: [DiskNode] = []
        for try await node in group { out.append(node) }
        return out
    }
    let total = kids.reduce(0) { $0 + $1.bytes }
    let (tiny, big) = kids.reduce(into: ([DiskNode](), [DiskNode]())) { acc, node in
        if total > 0 && node.bytes * 100 < total && !keepingVisible.contains(node.url) {
            acc.0.append(node)
        } else {
            acc.1.append(node)
        }
    }
    var shown = big.sorted { $0.bytes > $1.bytes }
    if !tiny.isEmpty {
        shown.append(DiskNode(name: "Other", url: root, bytes: tiny.reduce(0) { $0 + $1.bytes }))
    }
    return DiskNode(name: name, url: root, bytes: total, children: shown)
}
