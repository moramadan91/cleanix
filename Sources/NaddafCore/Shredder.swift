import Foundation

/// Removes items immediately (no Trash), clearing the "locked" flag first.
/// No overwrite passes: on SSD and APFS they do not guarantee anything, so none are promised.
public func shred(_ urls: [URL], policy: PathPolicy) async -> CleanResult {
    var result = CleanResult()
    let fm = FileManager.default
    for url in urls {
        guard policy.isAllowed(url) else {
            result.failed.append((url, "path is not allowed"))
            continue
        }
        guard fm.fileExists(atPath: url.path) else {
            result.failed.append((url, "file no longer exists"))
            continue
        }
        let bytes = FS.size(of: url)
        unlock(url)
        do {
            try fm.removeItem(at: url)
            result.removed.append(url)
            result.freedBytes += bytes
        } catch {
            result.failed.append((url, error.localizedDescription))
        }
    }
    return result
}

private func unlock(_ url: URL) {
    let fm = FileManager.default
    try? fm.setAttributes([.immutable: false], ofItemAtPath: url.path)
    if let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
        while let child = walker.nextObject() as? URL {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: child.path)
        }
    }
}
