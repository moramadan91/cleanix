import Foundation

public enum MaintenanceTask: CaseIterable, Sendable, Hashable {
    case freeRAM, flushDNS, reindexSpotlight, thinSnapshots, speedUpMail

    public var needsAdmin: Bool { self != .speedUpMail }

    /// Fixed commands only. Nothing here is built from user input.
    public func commands(home: URL) -> [[String]] {
        switch self {
        case .freeRAM: return [["/usr/sbin/purge"]]
        case .flushDNS: return [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]]
        case .reindexSpotlight: return [["/usr/bin/mdutil", "-E", "/"]]
        case .thinSnapshots: return [["/usr/bin/tmutil", "thinlocalsnapshots", "/", "10000000000", "4"]]
        case .speedUpMail:
            let mail = home.appendingPathComponent("Library/Mail")
            return FS.children(of: mail).filter { $0.lastPathComponent.hasPrefix("V") }
                .map { $0.appendingPathComponent("MailData/Envelope Index") }
                .filter { FS.exists($0) }
                .map { ["/usr/bin/sqlite3", $0.path, "VACUUM;"] }
        }
    }

    /// Every argv that may ever run with administrator rights.
    public static var adminAllowlist: Set<[String]> {
        Set(allCases.filter(\.needsAdmin).flatMap { $0.commands(home: URL(fileURLWithPath: "/nonexistent")) })
    }
}

public protocol PrivilegedRunner: Sendable {
    func run(_ argv: [String]) async throws -> String
}

/// Runs an allowlisted command through the macOS administrator password prompt.
public struct AdminPromptRunner: PrivilegedRunner {
    public init() {}

    public func run(_ argv: [String]) async throws -> String {
        guard MaintenanceTask.adminAllowlist.contains(argv) else { throw NaddafError.notAllowed }
        let shell = argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try await ProcessRunner().run(
            ["/usr/bin/osascript", "-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}

/// Runs a command as the current user.
public struct ProcessRunner: PrivilegedRunner {
    public init() {}

    public func run(_ argv: [String]) async throws -> String {
        guard let exe = argv.first else { throw NaddafError.notAllowed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(argv.dropFirst())
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw NSError(domain: "Maintenance", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text]) }
        return text
    }
}

public func runMaintenance(
    _ tasks: [MaintenanceTask],
    home: URL,
    runner: PrivilegedRunner,
    userRunner: PrivilegedRunner = ProcessRunner()
) async -> [MaintenanceTask: Result<String, Error>] {
    var results: [MaintenanceTask: Result<String, Error>] = [:]
    for task in tasks {
        let active = task.needsAdmin ? runner : userRunner
        var output = ""
        do {
            for argv in task.commands(home: home) { output += try await active.run(argv) }
            results[task] = .success(output)
        } catch {
            results[task] = .failure(error)
        }
    }
    return results
}
