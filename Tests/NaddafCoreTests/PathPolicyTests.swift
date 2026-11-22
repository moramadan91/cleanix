import Testing
import Foundation
@testable import NaddafCore

@Test func allowsFileInsideRoot() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("root")
        let file = root.appendingPathComponent("a/b.txt")
        try makeFile(file)
        #expect(PathPolicy(allowedRoots: [root]).isAllowed(file))
    }
}

@Test func rejectsRootItself() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!PathPolicy(allowedRoots: [root]).isAllowed(root))
    }
}

@Test func rejectsOutsidePath() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("root")
        let other = dir.appendingPathComponent("other/x.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile(other)
        #expect(!PathPolicy(allowedRoots: [root]).isAllowed(other))
    }
}

@Test func rejectsSiblingWithSamePrefix() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("cache")
        let sibling = dir.appendingPathComponent("cache-evil/x.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile(sibling)
        #expect(!PathPolicy(allowedRoots: [root]).isAllowed(sibling))
    }
}

@Test func rejectsDotDotEscape() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("root")
        let outside = dir.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile(outside)
        let sneaky = root.appendingPathComponent("../outside.txt")
        #expect(!PathPolicy(allowedRoots: [root]).isAllowed(sneaky))
    }
}

@Test func rejectsSymlinkInsideRootPointingOutside() throws {
    try withTempDir { dir in
        let root = dir.appendingPathComponent("root")
        let outsideDir = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile(outsideDir.appendingPathComponent("secret.txt"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)
        let policy = PathPolicy(allowedRoots: [root])
        #expect(!policy.isAllowed(link))
        #expect(!policy.isAllowed(link.appendingPathComponent("secret.txt")))
    }
}
