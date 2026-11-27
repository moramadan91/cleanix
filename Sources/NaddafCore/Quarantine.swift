import Foundation

public struct QuarantineRecord: Codable, Hashable, Sendable {
    public let original: URL
    public let stored: URL
    public let date: Date
}

/// Holds removed files for `retentionDays` so a clean can be undone.
/// Layout: root/<uuid>/<original file name>, plus root/index.json.
public final class Quarantine: @unchecked Sendable {
    private let root: URL
    private let indexedRootPath: String
    private let home: URL
    public let retentionDays: Int
    private let lock = NSLock()
    private var all: [QuarantineRecord]

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    public init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, retentionDays: Int = 30) {
        indexedRootPath = root.path
        self.root = Self.canonicalPath(root)
        self.home = Self.canonicalPath(home)
        self.retentionDays = retentionDays
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        all = (try? Data(contentsOf: self.root.appendingPathComponent("index.json")))
            .flatMap { try? decoder.decode([QuarantineRecord].self, from: $0) } ?? []
    }

    public func records() -> [QuarantineRecord] {
        lock.lock(); defer { lock.unlock() }
        return all
    }

    public func stash(_ url: URL, now: Date = Date()) throws -> QuarantineRecord {
        lock.lock(); defer { lock.unlock() }
        let slot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let stored = slot.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: stored)
        } catch {
            try? FileManager.default.removeItem(at: slot)
            throw error
        }
        let record = QuarantineRecord(original: url, stored: stored, date: now)
        all.append(record)
        try save()
        return record
    }

    /// The validated location to use when reading entry metadata.
    public func storedURL(for record: QuarantineRecord) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return validatedSlot(for: record)?.appendingPathComponent(record.stored.lastPathComponent)
    }

    public func restore(_ record: QuarantineRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = all.firstIndex(of: record) else { return }
        guard let slot = validatedSlot(for: record) else {
            try drop(at: index)
            return
        }
        let original = record.original
        let name = original.lastPathComponent
        guard Self.localPath(original) != nil, !name.isEmpty, name != ".", name != ".." else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let parent = Self.canonicalPath(original.deletingLastPathComponent())
        let destination = parent.appendingPathComponent(name)
        guard destination.path.hasPrefix(home.path == "/" ? "/" : home.path + "/"),
              destination.path != root.path, !destination.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(at: slot.appendingPathComponent(record.stored.lastPathComponent), to: destination)
        try? fm.removeItem(at: slot)
        try drop(at: index)
    }

    public func delete(_ record: QuarantineRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = all.firstIndex(where: { $0.stored == record.stored }) else { return }
        if let slot = validatedSlot(for: all[index]) {
            try removeSlot(slot)
        }
        try drop(at: index)
    }

    public func purgeExpired(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        var remaining: [QuarantineRecord] = []
        var failure: (any Error)?
        for record in all {
            guard let slot = validatedSlot(for: record) else { continue }
            guard record.date <= cutoff else {
                remaining.append(record)
                continue
            }
            do {
                try removeSlot(slot)
            } catch {
                remaining.append(record)
                if failure == nil { failure = error }
            }
        }
        if remaining != all {
            let previous = all
            all = remaining
            do { try save() } catch {
                all = previous
                throw error
            }
        }
        if let failure { throw failure }
    }

    private func validatedSlot(for record: QuarantineRecord) -> URL? {
        guard let path = Self.localPath(record.stored) else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return nil }
        let rootPath = components.dropLast(2).joined(separator: "/")
        let id = String(components[components.count - 2])
        let name = components[components.count - 1]
        guard rootPath == root.path || rootPath == indexedRootPath,
              UUID(uuidString: id) != nil, !name.isEmpty, name != ".", name != ".." else { return nil }

        let slot = root.appendingPathComponent(id, isDirectory: true)
        guard let values = try? slot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink == false,
              Self.canonicalPath(slot).path == slot.path else { return nil }
        return slot
    }

    private static func localPath(_ url: URL) -> String? {
        guard url.isFileURL, url.host == nil || url.host == "localhost" else { return nil }
        let path = url.path
        let decoded = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              decoded == path || decoded == path + "/" else { return nil }
        return path
    }

    /// Resolve the existing prefix even when the quarantine or restore directories have yet to be created.
    private static func canonicalPath(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        let resolved = url.withUnsafeFileSystemRepresentation { path in
            path.flatMap { realpath($0, nil) }
        }
        if let path = resolved {
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path))
        }
        if url.path == "/" { return url }
        return canonicalPath(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }

    private func removeSlot(_ slot: URL) throws {
        do {
            try FileManager.default.removeItem(at: slot)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A missing slot still needs its index entry removed.
        }
    }

    private func drop(at index: Int) throws {
        let removed = all.remove(at: index)
        do { try save() } catch {
            all.insert(removed, at: index)
            throw error
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(all).write(to: indexURL, options: .atomic)
    }
}
