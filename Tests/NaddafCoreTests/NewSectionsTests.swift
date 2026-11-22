import Testing
import Foundation
import SQLite3
@testable import NaddafCore

private func age(_ url: URL, days: Int) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: url.path)
}

// MARK: 12A Mail, 12B Downloads, 12D Privacy

@Test func mailReportsFilesWithSize() async throws {
    try await withTempDirAsync { dir in
        try makeFile(dir.appendingPathComponent("a.pdf"), bytes: 100)
        try makeFile(dir.appendingPathComponent("b.zip"), bytes: 300)
        let items = try await MailAttachmentsScanner(mailDownloads: [dir]).scan()
        #expect(items.map(\.bytes) == [300, 100])
        #expect(items.allSatisfy { $0.group == "Mail" })
    }
}

@Test func mailEmptyWhenFolderMissing() async throws {
    let items = try await MailAttachmentsScanner(mailDownloads: [URL(fileURLWithPath: "/nonexistent-naddaf")]).scan()
    #expect(items.isEmpty)
}

@Test func downloadsOnlyOlderThanThreshold() async throws {
    try await withTempDirAsync { dir in
        let old = dir.appendingPathComponent("old.dmg"), fresh = dir.appendingPathComponent("fresh.dmg")
        try makeFile(old, bytes: 10); try age(old, days: 100)
        try makeFile(fresh, bytes: 10)
        let items = try await DownloadsScanner(downloads: dir, olderThanDays: 30).scan()
        #expect(items.map(\.url.lastPathComponent) == ["old.dmg"])
    }
}

@Test func downloadsIgnoresHiddenFiles() async throws {
    try await withTempDirAsync { dir in
        let hidden = dir.appendingPathComponent(".DS_Store")
        try makeFile(hidden, bytes: 10); try age(hidden, days: 100)
        #expect(try await DownloadsScanner(downloads: dir, olderThanDays: 30).scan().isEmpty)
    }
}

@Test func privacySeparatesCacheFromHistoryAndCookies() async throws {
    try await withTempDirAsync { home in
        try makeFile(home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache/x"), bytes: 100)
        try makeFile(home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"), bytes: 20)
        try makeFile(home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies"), bytes: 30)
        let items = try await PrivacyScanner(home: home).scan()
        let byGroup = Dictionary(uniqueKeysWithValues: items.map { ($0.group, $0.safety) })
        #expect(byGroup["Chrome cache"] == .safe)
        #expect(byGroup["Chrome history"] == .review)
        #expect(byGroup["Chrome cookies"] == .review)
        #expect(items.count == 3)
    }
}

@Test func privacyMissingBrowsersAreSkipped() async throws {
    try await withTempDirAsync { home in
        let items = try await PrivacyScanner(home: home).scan()
        #expect(items.isEmpty)
    }
}

// MARK: 12E Permissions, 12F Suspicious

private func makeTCC(_ url: URL, rows: [(String, String, Int, Int)]) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER, last_modified INTEGER)", nil, nil, nil)
    for r in rows {
        sqlite3_exec(db, "INSERT INTO access VALUES ('\(r.0)', '\(r.1)', \(r.2), \(r.3))", nil, nil, nil)
    }
}

@Test func permissionsReadsEntries() throws {
    try withTempDir { dir in
        let db = dir.appendingPathComponent("TCC.db")
        try makeTCC(db, rows: [("kTCCServiceCamera", "com.acme.app", 2, 1_700_000_000),
                               ("kTCCServiceMicrophone", "com.acme.app", 0, 1_700_000_001)])
        let entries = try PermissionsReader(tccDB: db).entries()
        #expect(entries.count == 2)
        #expect(entries[0].service == "kTCCServiceCamera" && entries[0].allowed)
        #expect(!entries[1].allowed)
        #expect(entries[0].lastModified == Date(timeIntervalSince1970: 1_700_000_000))
    }
}

@Test func permissionsUnreadableDBThrowsNoAccess() {
    #expect(throws: NaddafError.noAccess) {
        _ = try PermissionsReader(tccDB: URL(fileURLWithPath: "/nonexistent-naddaf/TCC.db")).entries()
    }
}

private struct FakeVerifier: SignatureVerifier {
    let table: [String: SignatureStatus]
    func status(of url: URL) -> SignatureStatus { table[url.lastPathComponent] ?? .ok }
}

@Test func suspiciousFlagsUnsignedAndNotNotarizedAppsAndSkipsOk() async throws {
    try await withTempDirAsync { dir in
        let apps = dir.appendingPathComponent("Applications")
        try makeApp(in: apps, name: "Good", bundleID: "com.a.good")
        try makeApp(in: apps, name: "Bad", bundleID: "com.a.bad")
        try makeApp(in: apps, name: "Plain", bundleID: "com.a.plain")
        let verifier = FakeVerifier(table: ["Bad.app": .unsigned, "Plain.app": .notNotarized])
        let items = try await SuspiciousScanner(appDirs: [apps], agentDirs: [], verifier: verifier).scan()
        #expect(Set(items.map(\.url.lastPathComponent)) == ["Bad.app", "Plain.app"])
        #expect(items.allSatisfy { $0.safety == .review })
    }
}

@Test func suspiciousFlagsAgentsWhoseProgramIsUnsigned() async throws {
    try await withTempDirAsync { dir in
        let agents = dir.appendingPathComponent("LaunchAgents")
        let badProg = dir.appendingPathComponent("badprog"), goodProg = dir.appendingPathComponent("goodprog")
        try makeFile(badProg); try makeFile(goodProg)
        func plist(_ name: String, program: String) throws {
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["Label": name, "ProgramArguments": [program]],
                                               format: .xml, options: 0).write(to: agents.appendingPathComponent("\(name).plist"))
        }
        try plist("bad", program: badProg.path)
        try plist("good", program: goodProg.path)
        try plist("missing", program: dir.appendingPathComponent("nothing").path)
        let verifier = FakeVerifier(table: ["badprog": .unsigned])
        let items = try await SuspiciousScanner(appDirs: [], agentDirs: [agents], verifier: verifier).scan()
        #expect(items.map(\.url.lastPathComponent) == ["bad.plist"])
    }
}

// MARK: 12G Cloud, 12H Smart Scan

@Test func cloudDetectsFoldersByName() throws {
    try withTempDir { home in
        try makeFile(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/doc"))
        try makeFile(home.appendingPathComponent("Dropbox/a"))
        try makeFile(home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/b"))
        try makeFile(home.appendingPathComponent("Documents/c"))
        let folders = CloudFoldersScanner(home: home).folders()
        #expect(Set(folders.map(\.name)) == ["iCloud Drive", "Dropbox", "OneDrive-Personal"])
        #expect(folders.first { $0.name == "iCloud Drive" }?.isICloud == true)
    }
}

@Test func cloudLargestSortedDescending() throws {
    try withTempDir { home in
        let drop = home.appendingPathComponent("Dropbox")
        try makeFile(drop.appendingPathComponent("a"), bytes: 10)
        try makeFile(drop.appendingPathComponent("b"), bytes: 300)
        try makeFile(drop.appendingPathComponent("sub/c"), bytes: 50)
        let scanner = CloudFoldersScanner(home: home)
        let folder = try #require(scanner.folders().first)
        #expect(scanner.largest(in: folder, limit: 2).map(\.bytes) == [300, 50])
    }
}

@Test func cloudEvictRejectsNonICloudPath() throws {
    try withTempDir { home in
        let file = home.appendingPathComponent("Dropbox/a")
        try makeFile(file)
        #expect(throws: NaddafError.notAllowed) { try CloudFoldersScanner(home: home).evict(file) }
    }
}

// `Scanner` also exists in Foundation, so the protocol is qualified here.
private struct FakeScanner: NaddafCore.Scanner {
    var bytes: [Int64] = []
    var fail = false
    var hang = false
    func scan() async throws -> [ScanItem] {
        if hang { try await Task.sleep(for: .seconds(10)) }
        if fail { throw NaddafError.noAccess }
        return bytes.map { ScanItem(url: URL(fileURLWithPath: "/fake/\($0)"), bytes: $0, reason: "", safety: .safe, group: "g") }
    }
}

@Test func smartScanAggregatesSectionsWithTotals() async {
    let sections = await SmartScan(sections: [("A", FakeScanner(bytes: [10, 20])), ("B", FakeScanner(bytes: [5]))]).run()
    #expect(sections.map(\.name) == ["A", "B"])
    #expect(sections.map(\.bytes) == [30, 5])
}

@Test func smartScanFailingScannerIsReportedNotFatal() async {
    let sections = await SmartScan(sections: [("A", FakeScanner(bytes: [10])), ("B", FakeScanner(fail: true))]).run()
    #expect(sections[0].error == nil)
    #expect(sections[1].error != nil)
}

@Test func smartScanCancellationStopsAll() async {
    let smart = SmartScan(sections: [("A", FakeScanner(hang: true)), ("B", FakeScanner(hang: true))])
    let task = Task { await smart.run() }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let started = Date()
    let sections = await task.value
    #expect(Date().timeIntervalSince(started) < 1.0)
    #expect(sections.allSatisfy { $0.error == "cancelled" })
}
