import Foundation
import Testing
@testable import NaddafCore

private let home = URL(fileURLWithPath: "/Users/quarantine-test", isDirectory: true)

private func record(_ path: String, under root: URL = home) -> QuarantineRecord {
    QuarantineRecord(original: root.appendingPathComponent(path),
                     stored: URL(fileURLWithPath: "/quarantine/stored"), date: Date(timeIntervalSince1970: 0))
}

@Test(arguments: [
    ("Library/Caches/com.example.Editor", QuarantineVerdict.Kind.cache),
    ("Library/Logs/editor.log", .logs),
    ("Library/Containers/com.example.Editor/Data/Library/Caches/Preview", .cache),
    ("Library/WebKit/com.example.Editor/WebsiteData/NetworkCache/file", .cache),
    ("Library/Containers/com.example.Editor/Data/Library/WebKit/WebsiteData/NetworkCache/file", .cache),
    ("Library/Developer/Xcode/DerivedData/Test", .cache),
    ("Library/Developer/Xcode/Archives/Caches/file", .cache),
    ("Library/Application Support/Google/Chrome/Default/Code Cache/file", .cache),
    ("Library/Application Support/Firefox/Profiles/default.test/cache2/entries", .cache),
    ("Library/iTunes/iPhone Software Updates/update.ipsw", .download),
    (".npm/_cacache", .cache),
    ("tmp/directory/file", .other),
    ("temp/file", .other),
    (".Trash/file", .other),
])
func quarantineSafePaths(example: (path: String, kind: QuarantineVerdict.Kind)) {
    let result = QuarantineVerdict.classify(record: record(example.path), home: home,
                                           installedBundleIDs: ["com.example.Editor", "com.google.Chrome", "com.apple.mail"])
    #expect(result.verdict == .safe)
    #expect(result.kind == example.kind)
    #expect(result.reasonKey.hasPrefix("quarantine.reason."))
}

@Test(arguments: [
    ("Library/Application Support/com.example.Editor/File", QuarantineVerdict.Kind.appData),
    ("Library/HTTPStorages/com.example.Editor", .settings),
    ("Library/Saved Application State/com.example.Editor.savedState", .settings),
    ("Library/Mail Downloads/file.pdf", .download),
    ("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/file.pdf", .download),
    ("Library/Preferences/com.example.Editor.plist", .settings),
    ("Library/Containers/com.example.Editor/Data/Documents/Database", .appData),
    ("Library/Group Containers/group.com.example.Editor/Data", .appData),
    ("Library/Cookies/com.example.Editor.binarycookies", .settings),
    ("Library/LaunchAgents/com.example.Editor.plist", .settings),
    ("Library/Application Scripts/com.example.Editor", .settings),
    ("Library/Developer/Xcode/Archives/2026/Test.xcarchive/Products/Cache", .other),
    ("Library/WebKit/com.example.Editor/WebsiteData/LocalStorage/db", .appData),
    ("Downloads/report.pdf", .download),
    ("Applications/Utilities/Editor.app", .app),
    ("somewhere/file", .other),
])
func quarantineReviewPaths(example: (path: String, kind: QuarantineVerdict.Kind)) {
    let result = QuarantineVerdict.classify(record: record(example.path), home: home, installedBundleIDs: ["com.apple.mail"])
    #expect(result.verdict == .review)
    #expect(result.kind == example.kind)
}

@Test(arguments: [
    ("Documents/Cache/file", QuarantineVerdict.Kind.document),
    ("Desktop/report.pdf", .document),
    ("Pictures/album", .media),
    ("Movies/clip.mov", .media),
    ("Music/song.m4a", .media),
    ("Library/Mobile Documents/com~apple~CloudDocs/report.pdf", .document),
    ("Library/Keychains/login.keychain-db", .settings),
    ("Library/Application Support/com.example.Editor/database", .appData),
    ("Library/Preferences/COM.EXAMPLE.Editor.plist", .settings),
    ("Library/Containers/com.example.Editor/Data/Library/Application Support/database", .appData),
    ("Library/Application Support/Google/Chrome/Default/History", .appData),
    ("Library/Application Support/Google/Chrome/Default/Local Extension Settings/extension/cache/file", .appData),
])
func quarantineUnsafePaths(example: (path: String, kind: QuarantineVerdict.Kind)) {
    let result = QuarantineVerdict.classify(record: record(example.path), home: home,
                                           installedBundleIDs: ["com.example.Editor", "com.google.Chrome"])
    #expect(result.verdict == .unsafe)
    #expect(result.kind == example.kind)
}

@Test func quarantineClassifiesAppNamesAndFallsBackToFolderNames() {
    let installed = ["com.example.Editor"]
    let names = ["com.example.Editor": "Acme Editor"]
    for folder in ["Acme Editor", "com.example.Editor"] {
        let result = QuarantineVerdict.classify(
            record: record("Library/Application Support/\(folder)/database"), home: home,
            installedBundleIDs: Set(installed), installedAppNames: names
        )
        #expect(result.verdict == .unsafe)
        #expect(result.reasonKey == "quarantine.reason.installed")
        #expect(result.owningApp == "Acme Editor")
    }
    let uninstalled = QuarantineVerdict.classify(
        record: record("Library/Containers/com.example.Former"), home: home,
        installedBundleIDs: Set(installed), installedAppNames: names
    )
    #expect(uninstalled.verdict == .review)
    #expect(uninstalled.owningApp == "com.example.Former")
}

@Test func quarantinePathsOutsideHomeDefaultToReview() {
    let neighbor = URL(fileURLWithPath: home.path + "-neighbor", isDirectory: true)
    let result = QuarantineVerdict.classify(record: record("Library/Caches/data", under: neighbor),
                                           home: home, installedBundleIDs: [])
    #expect(result.verdict == .review)
    #expect(result.reasonKey == "quarantine.reason.unknown")
}

@Test func quarantineDeleteRemovesOnlyItsSlotAndPersists() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("q")
        let quarantine = Quarantine(root: root, retentionDays: 12)
        let original = dir.appendingPathComponent("cache/a.txt")
        let other = dir.appendingPathComponent("cache/b.txt")
        try makeFile(original)
        try makeFile(other)
        let removed = try quarantine.stash(original)
        let surviving = try quarantine.stash(other)

        try quarantine.delete(removed)
        try quarantine.delete(removed)

        #expect(quarantine.retentionDays == 12)
        #expect(!FileManager.default.fileExists(atPath: removed.stored.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: surviving.stored.path))
        #expect(quarantine.records().map(\.original) == [other])
        #expect(Quarantine(root: root).records().map(\.original) == [other])
    }
}

@Test func quarantineRestorePreservesBothFilesWhenOriginalExists() throws {
    try withTempDir { dir in
        let quarantine = Quarantine(root: dir.appendingPathComponent("q"), home: dir)
        let original = dir.appendingPathComponent("cache/file")
        try makeFile(original, bytes: 10)
        let record = try quarantine.stash(original)
        try makeFile(original, bytes: 20)

        #expect(throws: CocoaError(.fileWriteFileExists)) { try quarantine.restore(record) }
        #expect(FS.size(of: original) == 20)
        #expect(FS.size(of: record.stored) == 10)
        #expect(quarantine.records() == [record])
    }
}

@Test func quarantineDeleteClearsMissingSlotFromReopenedIndex() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("q")
        let original = dir.appendingPathComponent("cache/file")
        try makeFile(original)
        let record = try Quarantine(root: root).stash(original)
        try FileManager.default.removeItem(at: record.stored.deletingLastPathComponent())

        let reopened = Quarantine(root: root)
        try reopened.delete(record)
        #expect(reopened.records().isEmpty)
        #expect(Quarantine(root: root).records().isEmpty)
    }
}

@Test(arguments: ["delete", "restore", "purge"])
func quarantineDropsInvalidSlotsWithoutRemovingFiles(operation: String) throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("q")
        let original = dir.appendingPathComponent("restored")
        let outside = dir.appendingPathComponent("outside/keep")
        let nested = root.appendingPathComponent("\(UUID())/extra/keep")
        let nonUUID = root.appendingPathComponent("not-a-uuid/keep")
        let link = root.appendingPathComponent(UUID().uuidString)
        for file in [outside, nested, nonUUID] { try makeFile(file) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let records = [outside, nested, nonUUID, link.appendingPathComponent("keep")].map {
            QuarantineRecord(original: original, stored: $0, date: Date(timeIntervalSince1970: 0))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: root.appendingPathComponent("index.json"))
        let quarantine = Quarantine(root: root, home: dir)
        let indexed = quarantine.records()
        #expect(indexed.count == records.count)

        switch operation {
        case "delete":
            for record in indexed { try quarantine.delete(record) }
        case "restore":
            for record in indexed { try quarantine.restore(record) }
        default:
            try quarantine.purgeExpired()
        }

        for file in [outside, nested, nonUUID, link] {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(quarantine.records().isEmpty)
        #expect(Quarantine(root: root, home: dir).records().isEmpty)
    }
}

@Test func quarantineRestoreRejectsParentSymlinkOutsideHome() throws {
    try withTempDir { dir in
        let home = dir.appendingPathComponent("home")
        let outside = dir.appendingPathComponent("outside")
        let original = home.appendingPathComponent("data/missing/file")
        try makeFile(original)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let quarantine = Quarantine(root: home.appendingPathComponent("q"), home: home)
        let record = try quarantine.stash(original)
        let data = home.appendingPathComponent("data")
        try FileManager.default.removeItem(at: data)
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: outside)

        #expect(throws: CocoaError(.fileWriteNoPermission)) { try quarantine.restore(record) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("missing").path))
        #expect(FileManager.default.fileExists(atPath: record.stored.path))
        #expect(quarantine.records() == [record])
    }
}

@Test func quarantineAcceptsLegacyIndexThroughSymlinkedRoot() throws {
    try withTempDir { dir in
        let target = dir.appendingPathComponent("target")
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let root = alias.appendingPathComponent("q")
        let quarantine = Quarantine(root: root, home: dir)
        let original = dir.appendingPathComponent("original")
        try makeFile(original)
        let stashed = try quarantine.stash(original)
        let legacy = QuarantineRecord(original: original, stored: root
            .appendingPathComponent(stashed.stored.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(stashed.stored.lastPathComponent), date: stashed.date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacy]).write(to: root.appendingPathComponent("index.json"))
        let reopened = Quarantine(root: root, home: dir)

        try reopened.restore(try #require(reopened.records().first))

        #expect(stashed.stored.path.contains("/target/q/"))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: stashed.stored.deletingLastPathComponent().path))
        #expect(reopened.records().isEmpty)
    }
}
