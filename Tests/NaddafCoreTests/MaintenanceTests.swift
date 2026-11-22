import Testing
import Foundation
@testable import NaddafCore

private final class Recorder: PrivilegedRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let failing: Set<String>
    init(failing: Set<String> = []) { self.failing = failing }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func record(_ argv: [String]) { lock.lock(); _calls.append(argv); lock.unlock() }
    func run(_ argv: [String]) async throws -> String {
        record(argv)
        if failing.contains(argv[0]) { throw NaddafError.noAccess }
        return "ok"
    }
}

private func isFailure(_ r: Result<String, Error>?) -> Bool {
    if case .failure = r { return true }
    return false
}

private let noHome = URL(fileURLWithPath: "/nonexistent-naddaf-home")

@Test func maintenanceAdminCommandsAreFromFixedAllowlist() {
    let allow = MaintenanceTask.adminAllowlist
    for task in MaintenanceTask.allCases where task.needsAdmin {
        for argv in task.commands(home: noHome) { #expect(allow.contains(argv)) }
    }
    #expect(allow.contains(["/usr/sbin/purge"]))
    #expect(!allow.contains(["/bin/rm", "-rf", "/"]))
}

@Test func maintenanceAdminTasksGoThroughAdminRunner() async {
    let admin = Recorder(), user = Recorder()
    let results = await runMaintenance([.freeRAM, .flushDNS], home: noHome, runner: admin, userRunner: user)
    #expect(admin.calls.count == 3)
    #expect(user.calls.isEmpty)
    #expect(results.values.allSatisfy { !isFailure($0) })
}

@Test func maintenanceMailTaskUsesUserRunner() async throws {
    try await withTempDirAsync { home in
        try makeFile(home.appendingPathComponent("Library/Mail/V10/MailData/Envelope Index"))
        let admin = Recorder(), user = Recorder()
        _ = await runMaintenance([.speedUpMail], home: home, runner: admin, userRunner: user)
        #expect(admin.calls.isEmpty)
        #expect(user.calls.count == 1)
        #expect(user.calls[0].first == "/usr/bin/sqlite3")
    }
}

@Test func maintenanceOneFailureDoesNotStopOthers() async {
    let admin = Recorder(failing: ["/usr/sbin/purge"])
    let results = await runMaintenance([.freeRAM, .flushDNS], home: noHome, runner: admin)
    #expect(isFailure(results[.freeRAM]))
    #expect(!isFailure(results[.flushDNS]))
}

@Test func maintenanceNeverRunsArbitraryArgv() async {
    await #expect(throws: NaddafError.notAllowed) {
        _ = try await AdminPromptRunner().run(["/bin/rm", "-rf", "/"])
    }
}
