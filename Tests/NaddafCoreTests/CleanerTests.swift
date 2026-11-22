import Testing
import Foundation
@testable import NaddafCore

private func item(_ url: URL, bytes: Int64 = 10) -> ScanItem {
    ScanItem(url: url, bytes: bytes, reason: "test", safety: .safe, group: "g")
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func add(_ u: URL) { lock.lock(); _urls.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
}

@Test func quarantineMovesFileAndRestoreBringsItBack() throws {
    try withTempDir { dir in
        let file = dir.appendingPathComponent("data/a.txt")
        try makeFile(file, bytes: 5)
        let q = Quarantine(root: dir.appendingPathComponent("q"))
        let rec = try q.stash(file, now: Date())
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: rec.stored.path))
        #expect(q.records().count == 1)
        try q.restore(rec)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(q.records().isEmpty)
    }
}

@Test func purgeExpiredRemovesOnlyOlderThan30Days() throws {
    try withTempDir { dir in
        let old = dir.appendingPathComponent("old.txt")
        let fresh = dir.appendingPathComponent("fresh.txt")
        try makeFile(old)
        try makeFile(fresh)
        let q = Quarantine(root: dir.appendingPathComponent("q"), retentionDays: 30)
        let now = Date()
        let oldRec = try q.stash(old, now: now.addingTimeInterval(-31 * 86400))
        let freshRec = try q.stash(fresh, now: now.addingTimeInterval(-29 * 86400))
        try q.purgeExpired(now: now)
        #expect(!FileManager.default.fileExists(atPath: oldRec.stored.path))
        #expect(FileManager.default.fileExists(atPath: freshRec.stored.path))
        #expect(q.records().map(\.original) == [fresh])
    }
}

@Test func itemOutsidePolicyIsFailedAndUntouched() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("allowed")
    let outside = dir.appendingPathComponent("other/keep.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try makeFile(outside)
    let cleaner = Cleaner(policy: PathPolicy(allowedRoots: [root]),
                          quarantine: Quarantine(root: dir.appendingPathComponent("q")))
    let result = await cleaner.clean([item(outside)], disposal: .quarantine)
    #expect(result.removed.isEmpty)
    #expect(result.failed.count == 1)
    #expect(result.freedBytes == 0)
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test func unreadableFileGoesToFailedAndOthersContinue() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-tests-\(UUID().uuidString)")
    let root = dir.appendingPathComponent("allowed")
    let locked = root.appendingPathComponent("locked/stuck.txt")
    let free = root.appendingPathComponent("free/ok.txt")
    try makeFile(locked)
    try makeFile(free)
    let lockedDir = locked.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let cleaner = Cleaner(policy: PathPolicy(allowedRoots: [root]),
                          quarantine: Quarantine(root: dir.appendingPathComponent("q")))
    let result = await cleaner.clean([item(locked), item(free, bytes: 7)], disposal: .quarantine)
    #expect(result.failed.map(\.url) == [locked])
    #expect(result.removed == [free])
    #expect(result.freedBytes == 7)
}

@Test func vanishedFileGoesToFailed() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("allowed")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ghost = root.appendingPathComponent("gone.txt")
    let cleaner = Cleaner(policy: PathPolicy(allowedRoots: [root]),
                          quarantine: Quarantine(root: dir.appendingPathComponent("q")))
    let result = await cleaner.clean([item(ghost)], disposal: .quarantine)
    #expect(result.failed.map(\.url) == [ghost])
    #expect(result.removed.isEmpty)
}

@Test func trashDisposalCallsInjectedTrasher() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("allowed")
    let file = root.appendingPathComponent("x.txt")
    try makeFile(file)
    let calls = Calls()
    let cleaner = Cleaner(policy: PathPolicy(allowedRoots: [root]),
                          quarantine: Quarantine(root: dir.appendingPathComponent("q")),
                          trasher: { calls.add($0) })
    let result = await cleaner.clean([item(file, bytes: 3)], disposal: .trash)
    #expect(calls.urls == [file])
    #expect(result.removed == [file])
    #expect(result.freedBytes == 3)
}
