import Foundation

/// Small filesystem helpers shared by scanners. Sizes are logical file sizes and
/// symlinks are never followed.
public enum FS {
    static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            if Task.isCancelled { break }
            let v = try? file.resourceValues(forKeys: keys)
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
