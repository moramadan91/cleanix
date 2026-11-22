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

    /// Fixed maintenance argv. Purge access management has its own allowlist.
    public static var adminAllowlist: Set<[String]> {
        Set(allCases.filter(\.needsAdmin).flatMap { $0.commands(home: URL(fileURLWithPath: "/nonexistent")) })
    }
}

public protocol PrivilegedRunner: Sendable {
    func run(_ argv: [String]) async throws -> String
    /// Runs several tasks (each a list of argv run in order); one result per task.
    func runTasks(_ tasks: [[[String]]]) async -> [Result<String, Error>]
}

extension PrivilegedRunner {
    /// Default: one task after another, a failed command stops only its own task.
    public func runTasks(_ tasks: [[[String]]]) async -> [Result<String, Error>] {
        var results: [Result<String, Error>] = []
        for commands in tasks {
            do {
                var output = ""
                for argv in commands { output += try await run(argv) }
                results.append(.success(output))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }
}

/// Runs allowlisted commands through the macOS administrator password prompt.
public struct AdminPromptRunner: PrivilegedRunner {
    public init() {}

    public func run(_ argv: [String]) async throws -> String {
        guard MaintenanceTask.adminAllowlist.contains(argv) || argv == PurgeAccess.removeCommand
        else { throw NaddafError.notAllowed }
        return try await Self.prompt(Self.quote(argv))
    }

    /// All tasks in ONE password prompt: each task's commands run with &&, and a marker line
    /// after each task carries its exit status, so every task still gets its own result.
    public func runTasks(_ tasks: [[[String]]]) async -> [Result<String, Error>] {
        guard !tasks.isEmpty else { return [] }
        do {
            let script = try Self.batchScript(tasks)
            for task in tasks {
                if let path = PurgeAccess.installRuleFile(in: task), !PurgeAccess.containsCurrentUsersRule(path) {
                    throw NaddafError.notAllowed
                }
            }
            let output = try await Self.prompt(script)
            return Self.parseBatch(output, count: tasks.count)
        } catch {
            return tasks.map { _ in .failure(error) } // cancelled prompt or a refused command: nothing ran
        }
    }

    static let marker = "__cleanix_task_"

    static func quote(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    /// The shell script for a batch. Throws if any command is not on the allowlist.
    static func batchScript(_ tasks: [[[String]]], purgeUser: String = NSUserName()) throws -> String {
        let allow = MaintenanceTask.adminAllowlist
        return try tasks.enumerated().map { i, commands in
            let script: String
            if let path = PurgeAccess.installRuleFile(in: commands),
               let rule = PurgeAccess.ruleText(user: purgeUser) {
                script = purgeInstallShell(fileName: URL(fileURLWithPath: path).lastPathComponent, rule: rule)
            } else if commands == [PurgeAccess.removeCommand] || (!commands.isEmpty && commands.allSatisfy(allow.contains)) {
                script = commands.map(quote).joined(separator: " && ")
            } else {
                throw NaddafError.notAllowed
            }
            return "{ " + script + "; } 2>&1; echo \"\(marker)\(i)=$?\""
        }.joined(separator: "; ")
    }

    private static func purgeInstallShell(fileName: String, rule: String) -> String {
        // Stage the expected bytes under root ownership. The app's input file
        // must never be opened by the privileged shell.
        let commands = PurgeAccess.installScript(ruleFile: "$rule").map { argv in
            argv.map { $0 == "$rule" ? "\"$rule\"" : quote([$0]) }.joined(separator: " ")
        }
        return """
        (umask 077; dir=$(/usr/bin/mktemp -d /private/tmp/cleanix-purge.XXXXXXXX) || exit 1; \
        rule="$dir"/\(quote([fileName])); trap '/bin/rm -f "$rule"; /bin/rmdir "$dir"' EXIT; \
        printf '%s\\n' \(quote([String(rule.dropLast())])) > "$rule" && \(commands.joined(separator: " && ")))
        """
    }

    /// Splits the batch output back into one result per task, by the marker lines.
    static func parseBatch(_ output: String, count: Int) -> [Result<String, Error>] {
        var results = [Result<String, Error>](repeating: .failure(NaddafError.notAllowed), count: count)
        var text = ""
        // do shell script turns \n into \r, so split on any line ending.
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard line.hasPrefix(marker), let eq = line.firstIndex(of: "="),
                  let i = Int(line[line.index(line.startIndex, offsetBy: marker.count)..<eq]), i < count,
                  let status = Int32(line[line.index(after: eq)...]) else {
                text += line + "\n"
                continue
            }
            results[i] = status == 0 ? .success(text)
                : .failure(NSError(domain: "Maintenance", code: Int(status), userInfo: [NSLocalizedDescriptionKey: text]))
            text = ""
        }
        return results
    }

    private static func prompt(_ shell: String) async throws -> String {
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
    userRunner: PrivilegedRunner = ProcessRunner(),
    installPurgeAccess: Bool = false,
    purgeAccessInstalled: Bool = PurgeAccess.isInstalled
) async -> [MaintenanceTask: Result<String, Error>] {
    var results: [MaintenanceTask: Result<String, Error>] = [:]
    if tasks.contains(.freeRAM), purgeAccessInstalled,
       let output = try? await userRunner.run(PurgeAccess.passwordlessPurge) {
        results[.freeRAM] = .success(output)
    }

    let admin = tasks.filter { $0.needsAdmin && results[$0] == nil }
    let user = tasks.filter { !$0.needsAdmin }
    var adminCommands = admin.map { $0.commands(home: home) }
    let ruleFile = installPurgeAccess && !purgeAccessInstalled && admin.contains(.freeRAM)
        ? try? PurgeAccess.makeRuleFile() : nil
    defer {
        if let ruleFile { try? FileManager.default.removeItem(atPath: ruleFile) }
    }
    // A separate task lets purge run even if rule installation fails.
    if let ruleFile { adminCommands.insert(PurgeAccess.installScript(ruleFile: ruleFile), at: 0) }
    let adminResults = adminCommands.isEmpty ? [] : await runner.runTasks(adminCommands)
    for (task, result) in zip(admin, adminResults.dropFirst(ruleFile == nil ? 0 : 1)) {
        results[task] = result
    }
    for (task, result) in zip(user, await userRunner.runTasks(user.map { $0.commands(home: home) })) {
        results[task] = result
    }
    return results
}
