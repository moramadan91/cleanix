import Foundation
import Testing
@testable import NaddafCore

struct SpaceAdviceTests {
    let home = URL(fileURLWithPath: "/Users/test")
    func at(_ path: String) -> URL { home.appendingPathComponent(path) }

    @Test func cachesLogsAndTrashAreSafe() {
        #expect(SpaceAdvice.safety(of: at("Library/Caches/com.google.Chrome"), home: home) == .safe)
        #expect(SpaceAdvice.safety(of: at("Library/Logs/App"), home: home) == .safe)
        #expect(SpaceAdvice.safety(of: at(".Trash/old.mov"), home: home) == .safe)
        #expect(SpaceAdvice.safety(of: at("Library/Developer/Xcode/DerivedData/X"), home: home) == .safe)
    }

    @Test func cacheSubfolderInsideAppSupportIsSafe() {
        #expect(SpaceAdvice.safety(of: at("Library/Application Support/Discord/Cache"), home: home) == .safe)
        #expect(SpaceAdvice.safety(of: at("Library/Application Support/Discord/Code Cache/x"), home: home) == .safe)
    }

    @Test func appDataAndSettingsAreRisky() {
        #expect(SpaceAdvice.safety(of: at("Library"), home: home) == .risky)
        #expect(SpaceAdvice.safety(of: at("Library/Preferences"), home: home) == .risky)
        #expect(SpaceAdvice.safety(of: at("Library/Application Support/Discord"), home: home) == .risky)
        #expect(SpaceAdvice.safety(of: at("Library/Containers/com.x"), home: home) == .risky)
        #expect(SpaceAdvice.safety(of: at(".ssh"), home: home) == .risky)
        #expect(SpaceAdvice.safety(of: home, home: home) == .risky)
    }

    @Test func personalFilesNeedReview() {
        #expect(SpaceAdvice.safety(of: at("Documents/report.pdf"), home: home) == .review)
        #expect(SpaceAdvice.safety(of: at("Movies"), home: home) == .review)
        #expect(SpaceAdvice.safety(of: at("Downloads/setup.dmg"), home: home) == .review)
    }

    @Test func safeBytesSumsOnlySafeDescendants() {
        let caches = DiskNode(name: "Caches", url: at("Library/Caches"), bytes: 300)
        let prefs = DiskNode(name: "Preferences", url: at("Library/Preferences"), bytes: 50)
        let lib = DiskNode(name: "Library", url: at("Library"), bytes: 350, children: [caches, prefs])
        let docs = DiskNode(name: "Documents", url: at("Documents"), bytes: 900)
        let root = DiskNode(name: "test", url: home, bytes: 1250, children: [lib, docs])
        #expect(SpaceAdvice.safeBytes(root, home: home) == 300)
    }
}
