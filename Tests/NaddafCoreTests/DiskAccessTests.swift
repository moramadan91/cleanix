import Foundation
import Testing
@testable import NaddafCore

@Suite struct DiskAccessTests {
    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("naddaf-probe-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func readableProbeMeansGranted() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DiskAccess.granted(probe: url))
    }

    @Test func unreadableProbeMeansNotGranted() throws {
        let url = try tempFile()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(!DiskAccess.granted(probe: url))
    }

    @Test func missingProbeDoesNotNag() {
        let url = URL(fileURLWithPath: "/nonexistent/naddaf/\(UUID().uuidString)")
        #expect(DiskAccess.granted(probe: url))
    }

    @Test func probeLivesInHomeLibrary() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(DiskAccess.probe(home: home).path == "/Users/someone/Library/Application Support/com.apple.TCC/TCC.db")
    }
}
