import Testing
import Foundation
@testable import NaddafCore

// MARK: Remover

@Test func removerListsAppsWithVendorAndSource() async throws {
    try await withTempDirAsync { dir in
        let apps = dir.appendingPathComponent("Applications")
        try makeApp(in: apps, name: "Writer", bundleID: "com.acme.writer")
        let store = try makeApp(in: apps, name: "Notes2", bundleID: "com.zeta.notes")
        try makeFile(store.appendingPathComponent("Contents/_MASReceipt/receipt"))
        let list = await RemoverScanner(appDirs: [apps], home: dir.appendingPathComponent("home")).apps()
        #expect(list.map(\.name) == ["Notes2", "Writer"])
        #expect(list.first { $0.name == "Writer" }?.vendor == "Acme")
        #expect(list.first { $0.name == "Writer" }?.source == .other)
        #expect(list.first { $0.name == "Notes2" }?.source == .appStore)
    }
}

@Test func removerLeftoversMatchByBundleIDNotBySubstring() async throws {
    try await withTempDirAsync { dir in
        let apps = dir.appendingPathComponent("Applications")
        let home = dir.appendingPathComponent("home")
        try makeApp(in: apps, name: "Pro", bundleID: "com.acme.pro")
        let lib = home.appendingPathComponent("Library")
        try makeFile(lib.appendingPathComponent("Caches/com.acme.pro/x"), bytes: 10)
        try makeFile(lib.appendingPathComponent("Application Support/Pro/y"), bytes: 20)
        try makeFile(lib.appendingPathComponent("Application Support/Photoshop Pro/z"), bytes: 30)
        try makeFile(lib.appendingPathComponent("Preferences/com.acme.pro.plist"), bytes: 5)
        let scanner = RemoverScanner(appDirs: [apps], home: home)
        let app = await scanner.apps()[0]
        #expect(Set(scanner.leftovers(for: app).map(\.bytes)) == [10, 20, 5])
    }
}

@Test func removerOrphanLeftoversForMissingApps() async throws {
    try await withTempDirAsync { dir in
        let apps = dir.appendingPathComponent("Applications")
        let home = dir.appendingPathComponent("home")
        try makeApp(in: apps, name: "Writer", bundleID: "com.acme.writer")
        let caches = home.appendingPathComponent("Library/Caches")
        try makeFile(caches.appendingPathComponent("com.gone.app/x"), bytes: 10)
        try makeFile(caches.appendingPathComponent("com.acme.writer/y"), bytes: 20)
        try makeFile(caches.appendingPathComponent("com.apple.Safari/z"), bytes: 30)
        let orphans = await RemoverScanner(appDirs: [apps], home: home).orphanLeftovers()
        #expect(orphans.map(\.group) == ["com.gone.app"])
    }
}

@Test func removerUnusedUsesLastUsedDate() async throws {
    try await withTempDirAsync { dir in
        let apps = dir.appendingPathComponent("Applications")
        try makeApp(in: apps, name: "Old", bundleID: "com.acme.old")
        try makeApp(in: apps, name: "Recent", bundleID: "com.acme.recent")
        try makeApp(in: apps, name: "Unknown", bundleID: "com.acme.unknown")
        let now = Date()
        let scanner = RemoverScanner(appDirs: [apps], home: dir.appendingPathComponent("home"), lastUsed: { url in
            switch url.lastPathComponent {
            case "Old.app": return now.addingTimeInterval(-400 * 86400)
            case "Recent.app": return now.addingTimeInterval(-86400)
            default: return nil
            }
        })
        #expect(await scanner.unused(olderThanDays: 90, now: now).map(\.name) == ["Old"])
    }
}

// MARK: Login items

private func writePlist(_ url: URL, _ dict: [String: Any]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
}

@Test func loginItemsParsesLabelAndProgram() throws {
    try withTempDir { dir in
        let agents = dir.appendingPathComponent("LaunchAgents")
        try writePlist(agents.appendingPathComponent("a.plist"), [
            "Label": "com.acme.helper", "ProgramArguments": ["/usr/bin/true", "--x"], "Disabled": true,
        ])
        let items = LoginItemsReader(agentDirs: [agents]).items()
        #expect(items.count == 1)
        #expect(items[0].name == "com.acme.helper")
        #expect(items[0].program == "/usr/bin/true")
        #expect(!items[0].enabled)
    }
}

@Test func loginItemsDisableMovesPlistToQuarantine() throws {
    try withTempDir { dir in
        let agents = dir.appendingPathComponent("LaunchAgents")
        try writePlist(agents.appendingPathComponent("a.plist"), ["Label": "com.acme.helper"])
        let reader = LoginItemsReader(agentDirs: [agents])
        let q = Quarantine(root: dir.appendingPathComponent("q"))
        try reader.disable(reader.items()[0], using: q)
        #expect(reader.items().isEmpty)
        #expect(q.records().count == 1)
    }
}

@Test func loginItemsDaemonsAreReadOnly() throws {
    try withTempDir { dir in
        let daemons = dir.appendingPathComponent("LaunchDaemons")
        try writePlist(daemons.appendingPathComponent("d.plist"), ["Label": "com.acme.daemon"])
        let reader = LoginItemsReader(agentDirs: [], daemonDirs: [daemons])
        let item = try #require(reader.items().first)
        #expect(throws: NaddafError.readOnly) {
            try reader.disable(item, using: Quarantine(root: dir.appendingPathComponent("q")))
        }
    }
}

// MARK: Disk map

@Test func diskMapChildrenSizesSumToParentAndSortDescending() async throws {
    try await withTempDirAsync { dir in
        try makeFile(dir.appendingPathComponent("a"), bytes: 100)
        try makeFile(dir.appendingPathComponent("b/c"), bytes: 200)
        try makeFile(dir.appendingPathComponent("b/d"), bytes: 300)
        let tree = try await buildDiskTree(root: dir, depth: 3)
        #expect(tree.bytes == 600)
        #expect(tree.children.reduce(0) { $0 + $1.bytes } == 600)
        #expect(tree.children.map(\.bytes) == [500, 100])
    }
}

@Test func diskMapFoldsTinyEntriesIntoOther() async throws {
    try await withTempDirAsync { dir in
        try makeFile(dir.appendingPathComponent("big"), bytes: 10000)
        for i in 0..<5 { try makeFile(dir.appendingPathComponent("tiny\(i)"), bytes: 1) }
        let tree = try await buildDiskTree(root: dir, depth: 1)
        #expect(tree.children.map(\.name) == ["big", "Other"])
        #expect(tree.children[1].bytes == 5)
    }
}

@Test func diskMapDoesNotFollowSymlinks() async throws {
    try await withTempDirAsync { dir in
        let root = dir.appendingPathComponent("root")
        let outside = dir.appendingPathComponent("outside")
        try makeFile(root.appendingPathComponent("mine"), bytes: 10)
        try makeFile(outside.appendingPathComponent("huge"), bytes: 5000)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let tree = try await buildDiskTree(root: root, depth: 3)
        #expect(tree.bytes == 10)
    }
}

// MARK: Shredder

@Test func shredRemovesFileImmediately() async throws {
    try await withTempDirAsync { dir in
        let file = dir.appendingPathComponent("a.txt")
        try makeFile(file, bytes: 42)
        let result = await shred([file], policy: PathPolicy(allowedRoots: [dir]))
        #expect(result.removed == [file])
        #expect(result.freedBytes == 42)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func shredRemovesLockedFile() async throws {
    try await withTempDirAsync { dir in
        let file = dir.appendingPathComponent("locked.txt")
        try makeFile(file)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        let result = await shred([file], policy: PathPolicy(allowedRoots: [dir]))
        #expect(result.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func shredRefusesOutsidePolicy() async throws {
    try await withTempDirAsync { dir in
        let root = dir.appendingPathComponent("allowed")
        let file = dir.appendingPathComponent("other.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile(file)
        let result = await shred([file], policy: PathPolicy(allowedRoots: [root]))
        #expect(result.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func shredRemovesDirectoryRecursively() async throws {
    try await withTempDirAsync { dir in
        let folder = dir.appendingPathComponent("tree")
        try makeFile(folder.appendingPathComponent("a/b/c"), bytes: 7)
        let result = await shred([folder], policy: PathPolicy(allowedRoots: [dir]))
        #expect(result.freedBytes == 7)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
