import Foundation

/// One item per trash bin that has content. Emptying is permanent, so it needs `confirmed: true`.
public struct TrashScanner: Scanner {
    private let trashRoots: [URL]
    private let allowFinder: Bool

    public init(trashRoots: [URL], allowFinder: Bool = true) {
        self.trashRoots = trashRoots
        self.allowFinder = allowFinder
    }

    @concurrent
    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for root in trashRoots where FS.exists(root) {
            try Task.checkCancellation()
            let count: Int
            let size: Int64?
            if let children = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                count = children.filter { $0 != ".DS_Store" }.count
                size = count > 0 ? FS.size(of: root) : 0
            } else if allowFinder, root.lastPathComponent == ".Trash", let summary = FinderTrash.summary() {
                count = summary.count
                size = summary.bytes
            } else {
                continue
            }
            try Task.checkCancellation()
            guard count > 0 else { continue }
            items.append(ScanItem(url: root, bytes: size ?? 0, reason: "Trash bin", safety: .review,
                                  group: root.lastPathComponent, itemCount: count, hasMeasuredSize: size != nil))
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
/// just looks empty. Then it is measured and emptied through Finder, which asks once to let Cleanix
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

    static func summary() -> (count: Int, bytes: Int64?)? {
        // Finder's Apple event properties: trsh = trash, ptsz = size, phys = physical size.
        let script = """
        tell application "Finder"
            with timeout of 10 seconds
                set itemCount to count items of «property trsh»
            end timeout
            if itemCount is 0 then return {0, 0}
            try
                with timeout of 10 seconds
                    set itemSizes to «property ptsz» of every item of «property trsh»
                    if (count of itemSizes) is not itemCount then return {itemCount}
                    if missing value is in itemSizes then
                        set physicalSizes to «property phys» of every item of «property trsh»
                        repeat with i from 1 to count of itemSizes
                            if item i of itemSizes is missing value then set item i of itemSizes to item i of physicalSizes
                        end repeat
                    end if
                    if missing value is in itemSizes then
                        repeat with i from 1 to count of itemSizes
                            if item i of itemSizes is missing value then
                                set item i of itemSizes to my sizeForAlias(item i of «property trsh» as alias)
                            end if
                        end repeat
                    end if
                    set totalBytes to 0.0
                    repeat with itemSize in itemSizes
                        if contents of itemSize is missing value then return {itemCount}
                        set totalBytes to totalBytes + itemSize
                    end repeat
                    return {itemCount, totalBytes}
                end timeout
            on error
                return {itemCount}
            end try
        end tell

        on sizeForAlias(itemAlias)
            return size of (info for itemAlias)
        end sizeForAlias
        """
        guard let values = run([script])?.components(separatedBy: ", ").map({ $0.trimmingCharacters(in: .whitespaces) }),
              let first = values.first, let count = Int(first) else { return nil }
        let bytes = values.dropFirst().first.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.flatMap { Int64(exactly: $0) }
        return (count, bytes)
    }

    static func empty() -> Bool {
        run(["with timeout of 3600 seconds", #"tell application "Finder" to empty trash"#, "end timeout"]) != nil
    }

    /// What emptying freed, measured on the volume.
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
