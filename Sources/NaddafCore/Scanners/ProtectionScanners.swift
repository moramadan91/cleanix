import Foundation
import SQLite3

public struct PermissionEntry: Sendable, Hashable {
    public let service: String
    public let client: String
    public let allowed: Bool
    public let lastModified: Date
}

/// Read-only view of the TCC privacy database. Needs Full Disk Access on the real file.
public struct PermissionsReader: Sendable {
    private let tccDB: URL

    public init(tccDB: URL) { self.tccDB = tccDB }

    public func entries() throws -> [PermissionEntry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(tccDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw NaddafError.noAccess
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT service, client, auth_value, last_modified FROM access", -1, &statement, nil) == SQLITE_OK else {
            throw NaddafError.noAccess
        }
        defer { sqlite3_finalize(statement) }
        var result: [PermissionEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let service = String(cString: sqlite3_column_text(statement, 0))
            let client = String(cString: sqlite3_column_text(statement, 1))
            result.append(PermissionEntry(
                service: service, client: client, allowed: sqlite3_column_int(statement, 2) == 2,
                lastModified: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3)))))
        }
        return result
    }
}

public enum SignatureStatus: Sendable { case ok, unsigned, notNotarized }

public protocol SignatureVerifier: Sendable {
    func status(of url: URL) -> SignatureStatus
}

/// Uses `codesign` and `spctl`. This reports signing problems only; it does not detect malware.
public struct CodesignVerifier: SignatureVerifier {
    public init() {}

    public func status(of url: URL) -> SignatureStatus {
        if run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path]) != 0 { return .unsigned }
        if run("/usr/sbin/spctl", ["--assess", "--type", "execute", url.path]) != 0 { return .notNotarized }
        return .ok
    }

    private func run(_ exe: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Apps and launch agents whose signature needs review.
public struct SuspiciousScanner: Scanner {
    private let appDirs: [URL]
    private let agentDirs: [URL]
    private let verifier: SignatureVerifier

    public init(appDirs: [URL], agentDirs: [URL], verifier: SignatureVerifier) {
        self.appDirs = appDirs
        self.agentDirs = agentDirs
        self.verifier = verifier
    }

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for app in appDirs.flatMap({ FS.children(of: $0) }) where app.pathExtension == "app" {
            try Task.checkCancellation()
            if let reason = Self.reason(verifier.status(of: app)) {
                items.append(ScanItem(url: app, bytes: FS.size(of: app), reason: reason, safety: .review, group: "Apps"))
            }
        }
        for plist in agentDirs.flatMap({ FS.children(of: $0) }) where plist.pathExtension == "plist" {
            try Task.checkCancellation()
            guard let dict = NSDictionary(contentsOf: plist),
                  let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first,
                  FS.exists(URL(fileURLWithPath: program)),
                  let reason = Self.reason(verifier.status(of: URL(fileURLWithPath: program))) else { continue }
            items.append(ScanItem(url: plist, bytes: FS.size(of: plist), reason: reason, safety: .review, group: "Launch agents"))
        }
        return items
    }

    private static func reason(_ status: SignatureStatus) -> String? {
        switch status {
        case .ok: return nil
        case .unsigned: return "Not signed"
        case .notNotarized: return "Not notarized"
        }
    }
}
