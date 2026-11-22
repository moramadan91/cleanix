import Foundation

/// Tells the Disk Map user how safe a path in the home folder is to delete:
/// `.safe` = cache, logs, build data or trash (rebuilt or already discarded);
/// `.review` = personal files (only the user knows);
/// `.risky` = app data, settings, keys and the folders that hold them (do not delete by hand).
public enum SpaceAdvice {
    private static let safePrefixes: [[String]] = [
        ["Library", "Caches"], ["Library", "Logs"], ["Library", "HTTPStorages"],
        ["Library", "Developer", "Xcode", "DerivedData"], [".Trash"], [".npm", "_cacache"],
    ]
    private static let cacheFolderNames: Set<String> = ["Cache", "Caches", "Code Cache", "GPUCache", "DawnCache", "ShaderCache"]

    public static func safety(of url: URL, home: URL) -> Safety {
        let base = home.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return .risky }
        let rel = Array(parts.dropFirst(base.count))

        if safePrefixes.contains(where: { rel.count >= $0.count && Array(rel.prefix($0.count)) == $0 }) { return .safe }
        // A cache folder inside an app's data (e.g. Application Support/Discord/Cache) is safe; the rest of it is not.
        if rel.first == "Library", rel.dropFirst().contains(where: cacheFolderNames.contains) { return .safe }
        if rel.first == "Library" { return .risky }
        if rel.first?.hasPrefix(".") == true { return .risky }  // .ssh, .config, .zshrc...
        if rel.first == "Applications" { return .risky }        // remove apps with the uninstaller instead
        return .review
    }

    /// Bytes under `node` that are safe to delete, counting each safe subtree once.
    public static func safeBytes(_ node: DiskNode, home: URL) -> Int64 {
        if safety(of: node.url, home: home) == .safe { return node.bytes }
        return node.children.reduce(0) { $0 + safeBytes($1, home: home) }
    }
}
