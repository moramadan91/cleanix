import Testing
import Foundation
@testable import NaddafCore

@Test func sweepFindsLogsDerivedDataNpmAndHomebrew() async throws {
    try await withTempDirAsync { home in
        try makeFile(home.appendingPathComponent("Library/Logs/app.log"), bytes: 100)
        try makeFile(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Proj-abc/x.o"), bytes: 200)
        try makeFile(home.appendingPathComponent(".npm/_cacache/y"), bytes: 300)
        try makeFile(home.appendingPathComponent("Library/Caches/Homebrew/z"), bytes: 400)
        let items = try await SweepScanner(home: home).scan()
        let groupBySize = Dictionary(uniqueKeysWithValues: items.map { ($0.bytes, $0.group) })
        #expect(items.count == 4)
        #expect(groupBySize[100] == "Logs")
        #expect(groupBySize[200] == "Developer")
        #expect(groupBySize[300] == "Developer")
        #expect(groupBySize[400] == "Developer")
        #expect(items.allSatisfy { $0.safety == .safe })
    }
}

@Test func sweepSizesIncludeNestedFiles() async throws {
    try await withTempDirAsync { home in
        let base = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Big")
        try makeFile(base.appendingPathComponent("a/b/c.bin"), bytes: 1000)
        try makeFile(base.appendingPathComponent("d.bin"), bytes: 500)
        let items = try await SweepScanner(home: home).scan()
        #expect(items.count == 1)
        #expect(items[0].bytes == 1500)
    }
}

@Test func sweepLeavesGenericAppCachesToAppCachesScreen() async throws {
    try await withTempDirAsync { home in
        try makeFile(home.appendingPathComponent("Library/Caches/com.acme.writer/blob"), bytes: 50)
        let items = try await SweepScanner(home: home).scan()
        #expect(items.isEmpty)
    }
}

@Test func sweepHandlesArabicAndDecomposedNames() async throws {
    try await withTempDirAsync { home in
        try makeFile(home.appendingPathComponent("Library/Logs/ملف تجربة.log"), bytes: 70)
        try makeFile(home.appendingPathComponent("Library/Logs/cafe\u{301}.log"), bytes: 80)
        let items = try await SweepScanner(home: home).scan()
        #expect(Set(items.map(\.bytes)) == [70, 80])
    }
}

@Test func sweepWithNoFoldersReturnsEmpty() async throws {
    try await withTempDirAsync { home in
        let items = try await SweepScanner(home: home).scan()
        #expect(items.isEmpty)
    }
}
