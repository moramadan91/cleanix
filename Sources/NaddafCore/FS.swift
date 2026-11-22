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
        // fts, not FileManager's enumerator: same files counted (symlinks never followed), ~2x faster
        // because it skips building a URL and resource-value lookup per file.
        var total: Int64 = 0
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let copy = strdup(path) else { return }
            defer { free(copy) }
            var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(fts) }
            while let entry = fts_read(fts) {
                if Task.isCancelled { break }
                if entry.pointee.fts_info == FTS_F, let stat = entry.pointee.fts_statp {
                    total += Int64(stat.pointee.st_size)
                }
            }
        }
        return total
    }
}
