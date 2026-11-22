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
    private let retentionDays: Int
    private let lock = NSLock()
    private var all: [QuarantineRecord]

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    public init(root: URL, retentionDays: Int = 30) {
        self.root = root
        self.retentionDays = retentionDays
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        all = (try? Data(contentsOf: root.appendingPathComponent("index.json")))
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

    public func restore(_ record: QuarantineRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: record.original.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: record.original.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: record.stored, to: record.original)
        try? FileManager.default.removeItem(at: record.stored.deletingLastPathComponent())
        all.removeAll { $0 == record }
        try save()
    }

    public func purgeExpired(now: Date) throws {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        let expired = all.filter { $0.date <= cutoff }
        for record in expired {
            try? FileManager.default.removeItem(at: record.stored.deletingLastPathComponent())
        }
        all.removeAll { $0.date <= cutoff }
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(all).write(to: indexURL, options: .atomic)
    }
}
