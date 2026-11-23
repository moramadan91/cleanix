import Foundation

/// One item per trash bin that has content. Emptying is permanent, so it needs `confirmed: true`.
public struct TrashScanner: Scanner {
    private let trashRoots: [URL]

    public init(trashRoots: [URL]) { self.trashRoots = trashRoots }

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for root in trashRoots where FS.exists(root) {
            try Task.checkCancellation()
            if FinderTrash.needed(for: root) {
                // Finder can count the bin but not size it, so the item carries 0 bytes.
                let count = FinderTrash.count()
                if count > 0 {
                    items.append(ScanItem(url: root, bytes: 0, reason: "\(count) items", safety: .review, group: root.lastPathComponent))
                }
                continue
            }
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
public func emptyTrash(
    _ items: [ScanItem], confirmed: Bool, policy: PathPolicy, progress: CleanProgress? = nil
) async throws -> CleanResult {
    guard confirmed else { throw NaddafError.confirmationRequired }
    var result = CleanResult()
    for (binIndex, bin) in items.enumerated() {
        if FinderTrash.needed(for: bin.url) {
            guard FinderTrash.mayEmpty(bin.url, policy: policy) else {
                result.failed.append((bin.url, "path is not allowed"))
                continue
            }
            await progress?(bin.title ?? bin.url.lastPathComponent, nil)
            let before = FinderTrash.freeSpace(near: bin.url)
            if FinderTrash.empty() {
                result.removed.append(bin.url)
                result.freedBytes += max(0, FinderTrash.freeSpace(near: bin.url) - before)
            } else {
                result.failed.append((bin.url, "Finder could not empty the Trash"))
            }
            continue
        }
        let children = FS.children(of: bin.url)
        for (index, child) in children.enumerated() {
            let fraction: Double? = if items.count > 1 || children.count > 1 {
                (Double(binIndex) + Double(index) / Double(children.count)) / Double(items.count)
            } else {
                nil
            }
            await progress?(child.lastPathComponent, fraction)
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

/// ~/.Trash can be read only with Full Disk Access, and macOS never asks for it: without it the bin
/// just looks empty. Then it is counted and emptied through Finder, which asks once to let Cleanix
/// control it. shortcut: Finder's empty clears every bin (external drives too), as the Finder menu does.
enum FinderTrash {
    /// The user's own bin, unreadable to us right now.
    static func needed(for root: URL) -> Bool {
        root.lastPathComponent == ".Trash"
            && (try? FileManager.default.contentsOfDirectory(atPath: root.path)) == nil
    }

    /// The policy allows what is inside a chosen bin, never the bin itself, so ask about its contents
    /// (asking about the bin refused every Finder empty in 0.1.8).
    static func mayEmpty(_ bin: URL, policy: PathPolicy) -> Bool {
        policy.isAllowed(bin.appendingPathComponent("item"))
    }

    static func count() -> Int { Int(run([#"tell application "Finder" to return count items of trash"#]) ?? "") ?? 0 }

    static func empty() -> Bool {
        run(["with timeout of 3600 seconds", #"tell application "Finder" to empty trash"#, "end timeout"]) != nil
    }

    /// What emptying freed, measured on the volume, since Finder cannot size the bin.
    static func freeSpace(near url: URL) -> Int64 {
        let home = url.deletingLastPathComponent()
        return Int64((try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
    }

    /// osascript rather than NSAppleScript: safe off the main thread; macOS still asks in Cleanix's name.
    private static func run(_ lines: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
