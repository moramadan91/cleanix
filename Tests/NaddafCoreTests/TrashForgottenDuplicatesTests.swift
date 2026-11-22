import Testing
import Foundation
@testable import NaddafCore

private func write(_ url: URL, _ byte: UInt8, count: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: byte, count: count).write(to: url)
}

private func age(_ url: URL, days: Int) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: url.path)
}

// MARK: Trash

@Test func trashReportsOneItemPerBinWithSize() async throws {
    try await withTempDirAsync { dir in
        let a = dir.appendingPathComponent("binA"), b = dir.appendingPathComponent("binB")
        try makeFile(a.appendingPathComponent("x"), bytes: 100)
        try makeFile(a.appendingPathComponent("y"), bytes: 50)
        try makeFile(b.appendingPathComponent("z"), bytes: 200)
        let items = try await TrashScanner(trashRoots: [a, b, dir.appendingPathComponent("missing")]).scan()
        #expect(items.map(\.bytes).sorted() == [150, 200])
    }
}

@Test func emptyTrashWithoutConfirmationThrowsAndKeepsFiles() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appendingPathComponent("bin")
    try makeFile(bin.appendingPathComponent("x"), bytes: 10)
    let item = ScanItem(url: bin, bytes: 10, reason: "", safety: .review, group: "bin")
    await #expect(throws: NaddafError.confirmationRequired) {
        _ = try await emptyTrash([item], confirmed: false, policy: PathPolicy(allowedRoots: [bin]))
    }
    #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent("x").path))
}

@Test func emptyTrashWithConfirmationRemovesContentsKeepsBin() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appendingPathComponent("bin")
    try makeFile(bin.appendingPathComponent("x"), bytes: 100)
    try makeFile(bin.appendingPathComponent("sub/y"), bytes: 50)
    let item = ScanItem(url: bin, bytes: 150, reason: "", safety: .review, group: "bin")
    let result = try await emptyTrash([item], confirmed: true, policy: PathPolicy(allowedRoots: [bin]))
    #expect(result.freedBytes == 150)
    #expect(result.failed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: bin.path))
    #expect(FS.children(of: bin).isEmpty)
}

@Test func emptyTrashRefusesBinOutsidePolicy() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appendingPathComponent("bin")
    let other = dir.appendingPathComponent("other")
    try makeFile(bin.appendingPathComponent("x"), bytes: 10)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let item = ScanItem(url: bin, bytes: 10, reason: "", safety: .review, group: "bin")
    let result = try await emptyTrash([item], confirmed: true, policy: PathPolicy(allowedRoots: [other]))
    #expect(result.failed.count == 1)
    #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent("x").path))
}

// MARK: Forgotten

@Test func forgottenReturnsOnlyFilesAboveSizeAndOlderThanAge() async throws {
    try await withTempDirAsync { dir in
        let bigOld = dir.appendingPathComponent("bigOld.bin")
        try makeFile(bigOld, bytes: 5000); try age(bigOld, days: 400)
        try makeFile(dir.appendingPathComponent("bigNew.bin"), bytes: 5000)
        let smallOld = dir.appendingPathComponent("smallOld.bin")
        try makeFile(smallOld, bytes: 10); try age(smallOld, days: 400)
        let items = try await ForgottenScanner(root: dir, minBytes: 1000, olderThanDays: 180).scan()
        #expect(items.map(\.url.lastPathComponent) == ["bigOld.bin"])
    }
}

@Test func forgottenTreatsPackageAsSingleItem() async throws {
    try await withTempDirAsync { dir in
        let app = try makeApp(in: dir, name: "Old", bundleID: "com.acme.old")
        try makeFile(app.appendingPathComponent("Contents/MacOS/bin"), bytes: 5000)
        try age(app, days: 400)
        let items = try await ForgottenScanner(root: dir, minBytes: 1000, olderThanDays: 180).scan()
        #expect(items.count == 1)
        #expect(items[0].url.lastPathComponent == "Old.app")
        #expect(items[0].bytes >= 5000)
    }
}

@Test func forgottenCancelledScanReturnsPromptlyAndDeletesNothing() async throws {
    try await withTempDirAsync { dir in
        for i in 0..<3000 { try makeFile(dir.appendingPathComponent("d\(i % 30)/f\(i)"), bytes: 1) }
        let scanner = ForgottenScanner(root: dir, minBytes: 0, olderThanDays: 0, now: Date().addingTimeInterval(86400))
        let task = Task { try await scanner.scan() }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        let started = Date()
        _ = await task.result
        #expect(Date().timeIntervalSince(started) < 1.0)
        var count = 0
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let _ = walker?.nextObject() { count += 1 }
        #expect(count >= 3000)
    }
}

// MARK: Duplicates

@Test func duplicatesIdenticalFilesAreGrouped() async throws {
    try await withTempDirAsync { dir in
        try write(dir.appendingPathComponent("a.bin"), 7, count: 100)
        try write(dir.appendingPathComponent("sub/b.bin"), 7, count: 100)
        let groups = try await DuplicatesScanner(roots: [dir]).groups()
        #expect(groups.count == 1)
        #expect(groups[0].extras.count == 1)
    }
}

@Test func duplicatesSameSizeDifferentContentNotGrouped() async throws {
    try await withTempDirAsync { dir in
        try write(dir.appendingPathComponent("a.bin"), 1, count: 100)
        try write(dir.appendingPathComponent("b.bin"), 2, count: 100)
        #expect(try await DuplicatesScanner(roots: [dir]).groups().isEmpty)
    }
}

@Test func duplicatesHardlinksAreNotDuplicates() async throws {
    try await withTempDirAsync { dir in
        let a = dir.appendingPathComponent("a.bin")
        try write(a, 7, count: 100)
        try FileManager.default.linkItem(at: a, to: dir.appendingPathComponent("link.bin"))
        #expect(try await DuplicatesScanner(roots: [dir]).groups().isEmpty)
    }
}

@Test func duplicatesZeroByteFilesAreIgnored() async throws {
    try await withTempDirAsync { dir in
        try write(dir.appendingPathComponent("a"), 0, count: 0)
        try write(dir.appendingPathComponent("b"), 0, count: 0)
        #expect(try await DuplicatesScanner(roots: [dir]).groups().isEmpty)
    }
}

@Test func duplicatesKeepIsOldest() async throws {
    try await withTempDirAsync { dir in
        let older = dir.appendingPathComponent("z-older.bin"), newer = dir.appendingPathComponent("a-newer.bin")
        try write(newer, 5, count: 64)
        try write(older, 5, count: 64)
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: older.path)
        let groups = try await DuplicatesScanner(roots: [dir]).groups()
        #expect(groups[0].keep.url.lastPathComponent == "z-older.bin")
        #expect(groups[0].extras.map(\.url.lastPathComponent) == ["a-newer.bin"])
    }
}

@Test func finderEmptyIsAllowedForTheChosenBinOnly() {
    let bin = URL(fileURLWithPath: "/Users/someone/.Trash")
    // Same policy the Trash screen builds: the chosen bins are the roots.
    #expect(FinderTrash.mayEmpty(bin, policy: PathPolicy(allowedRoots: [bin])))
    #expect(!FinderTrash.mayEmpty(bin, policy: PathPolicy(allowedRoots: [URL(fileURLWithPath: "/Users/someone/Downloads")])))
}
