import Testing
import Foundation
@testable import NaddafCore

private func scanner(_ home: URL, apps: URL, running: Set<String> = []) -> AppCacheScanner {
    AppCacheScanner(home: home, appDirs: [apps], runningBundleIDs: { running })
}

/// Fake home with one installed app "Writer" (com.acme.writer) and caches in four places.
private func writerFixture(_ dir: URL) throws -> (home: URL, apps: URL) {
    let home = dir.appendingPathComponent("home")
    let apps = dir.appendingPathComponent("Applications")
    try makeApp(in: apps, name: "Writer", bundleID: "com.acme.writer")
    let lib = home.appendingPathComponent("Library")
    try makeFile(lib.appendingPathComponent("Caches/com.acme.writer/blob"), bytes: 1000)
    try makeFile(lib.appendingPathComponent("Containers/com.acme.writer/Data/Library/Caches/c"), bytes: 500)
    try makeFile(lib.appendingPathComponent("Application Support/Writer/Cache/d"), bytes: 300)
    try makeFile(lib.appendingPathComponent("Application Support/Writer/Code Cache/js/e"), bytes: 200)
    return (home, apps)
}

@Test func groupsCachesFromAllLocationsUnderOneApp() async throws {
    try await withTempDirAsync { dir in
        let (home, apps) = try writerFixture(dir)
        let groups = try await scanner(home, apps: apps).groups()
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 4)
        #expect(groups[0].bytes == 2000)
    }
}

@Test func resolvesAppNameFromInstalledAppBundle() async throws {
    try await withTempDirAsync { dir in
        let (home, apps) = try writerFixture(dir)
        let g = try await scanner(home, apps: apps).groups()[0]
        #expect(g.appName == "Writer")
        #expect(g.bundleID == "com.acme.writer")
        #expect(g.appURL?.lastPathComponent == "Writer.app")
    }
}

@Test func unknownFolderShownUnderRawFolderName() async throws {
    try await withTempDirAsync { dir in
        let home = dir.appendingPathComponent("home")
        try makeFile(home.appendingPathComponent("Library/Caches/org.unknown.tool/x"), bytes: 40)
        let groups = try await scanner(home, apps: dir.appendingPathComponent("none")).groups()
        #expect(groups.count == 1)
        #expect(groups[0].appName == "org.unknown.tool")
        #expect(groups[0].bundleID == nil)
        #expect(groups[0].appURL == nil)
    }
}

@Test func neverIncludesCookiesLocalStorageIndexedDB() async throws {
    try await withTempDirAsync { dir in
        let (home, apps) = try writerFixture(dir)
        let support = home.appendingPathComponent("Library/Application Support/Writer")
        try makeFile(support.appendingPathComponent("Cookies"), bytes: 999)
        try makeFile(support.appendingPathComponent("IndexedDB/f"), bytes: 999)
        try makeFile(support.appendingPathComponent("Local Storage/g"), bytes: 999)
        try makeFile(support.appendingPathComponent("Session Storage/h"), bytes: 999)
        let groups = try await scanner(home, apps: apps).groups()
        let paths = groups.flatMap(\.items).map(\.url.path)
        for banned in ["Cookies", "IndexedDB", "Local Storage", "Session Storage"] {
            #expect(!paths.contains { $0.contains(banned) })
        }
        #expect(groups[0].bytes == 2000)
    }
}

@Test func marksRunningAppUsingInjectedClosure() async throws {
    try await withTempDirAsync { dir in
        let (home, apps) = try writerFixture(dir)
        let running = try await scanner(home, apps: apps, running: ["com.acme.writer"]).groups()
        let idle = try await scanner(home, apps: apps).groups()
        #expect(running[0].isRunning)
        #expect(!idle[0].isRunning)
    }
}

@Test func appleBundlesMarkedSystemAndReview() async throws {
    try await withTempDirAsync { dir in
        let home = dir.appendingPathComponent("home")
        try makeFile(home.appendingPathComponent("Library/Caches/com.apple.Safari/x"), bytes: 60)
        let g = try await scanner(home, apps: dir.appendingPathComponent("none")).groups()[0]
        #expect(g.isSystem)
        #expect(g.items.allSatisfy { $0.safety == .review })
    }
}

@Test func sortedBySizeDescendingAndSkipsEmpty() async throws {
    try await withTempDirAsync { dir in
        let home = dir.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        try makeFile(caches.appendingPathComponent("org.small.app/a"), bytes: 100)
        try makeFile(caches.appendingPathComponent("org.big.app/a"), bytes: 900)
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("org.empty.app"),
                                                withIntermediateDirectories: true)
        let groups = try await scanner(home, apps: dir.appendingPathComponent("none")).groups()
        #expect(groups.map(\.bytes) == [900, 100])
    }
}

@Test func handlesArabicAppFolderNames() async throws {
    try await withTempDirAsync { dir in
        let home = dir.appendingPathComponent("home")
        try makeFile(home.appendingPathComponent("Library/Application Support/تطبيق/Cache/x"), bytes: 50)
        let groups = try await scanner(home, apps: dir.appendingPathComponent("none")).groups()
        #expect(groups.count == 1)
        #expect(groups[0].appName == "تطبيق")
        #expect(groups[0].bytes == 50)
    }
}
