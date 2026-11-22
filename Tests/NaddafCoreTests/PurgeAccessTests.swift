import Darwin
import Foundation
import Testing
@testable import NaddafCore

@Test func purgeRuleAllowsOnlyArgumentlessPurgeForTheUser() {
    let grant = " ALL=(root) NOPASSWD: /usr/sbin/purge \"\"\n"
    #expect(PurgeAccess.ruleText(user: "mohamed") == "mohamed" + grant)
    #expect(PurgeAccess.ruleText(user: "Cleanix-test_1.dev") == "Cleanix-test_1.dev" + grant)
    #expect(PurgeAccess.ruleText(user: "ALL") == "\"ALL\"" + grant)
    #expect(PurgeAccess.ruleText(user: "USER_1") == "\"USER_1\"" + grant)
}

@Test(arguments: ["two words", "%staff", "#0", "user\n", "", String(repeating: "a", count: 40),
                  "a:b", "a,b", "a=b", "a\\b", "a\u{0301}"])
func purgeRuleRejectsInvalidUsers(user: String) {
    #expect(PurgeAccess.ruleText(user: user) == nil)
}

private let validRuleFile = FileManager.default.temporaryDirectory
    .appendingPathComponent("cleanix-purge-Ab12-34.sudoers").path

@Test func purgeAccessUsesExactArgv() {
    let path = "/private/etc/sudoers.d/cleanix-purge"
    #expect(PurgeAccess.rulePath == path)
    #expect(PurgeAccess.installScript(ruleFile: validRuleFile) == [
        ["/usr/sbin/visudo", "-c", "-f", validRuleFile],
        ["/usr/bin/install", "-m", "0440", "-o", "root", "-g", "wheel", validRuleFile, path],
    ])
    #expect(PurgeAccess.removeCommand == ["/bin/rm", "-f", path])
    #expect(PurgeAccess.passwordlessPurge == ["/usr/bin/sudo", "-n", "/usr/sbin/purge"])
}

@Test func purgeAccessAllowlistAcceptsOnlyTheExactPairAndRemoval() throws {
    let pair = PurgeAccess.installScript(ruleFile: validRuleFile)
    let script = try AdminPromptRunner.batchScript([pair, [PurgeAccess.removeCommand]], purgeUser: "testuser")
    #expect(script.contains("'/usr/sbin/visudo' '-c' '-f' \"$rule\" && '/usr/bin/install'"))
    #expect(script.contains("printf '%s\\n' 'testuser ALL=(root) NOPASSWD: /usr/sbin/purge \"\"' > \"$rule\""))
    #expect(script.contains(AdminPromptRunner.quote(PurgeAccess.removeCommand)))
    #expect(!script.contains(validRuleFile))

    var changedDestination = pair
    changedDestination[1][8] = "/private/etc/sudoers"
    var extraArguments = pair
    extraArguments[0].append("-q")
    var mismatchedSource = pair
    mismatchedSource[1][7] = validRuleFile.replacingOccurrences(of: "Ab12", with: "Cd34")
    let rejected = [
        PurgeAccess.installScript(ruleFile: "/private/etc/cleanix-purge-test.sudoers"),
        PurgeAccess.installScript(ruleFile: validRuleFile.replacingOccurrences(of: "Ab12", with: "../Ab12")),
        PurgeAccess.installScript(ruleFile: validRuleFile + "\n"),
        changedDestination, extraArguments, mismatchedSource, Array(pair.reversed()),
        [pair[0]], [pair[1]], [["/bin/rm", "-rf", "/"]],
        [PurgeAccess.removeCommand + ["/private/etc/sudoers"]],
    ]
    for task in rejected {
        #expect(throws: NaddafError.notAllowed) {
            _ = try AdminPromptRunner.batchScript([task], purgeUser: "testuser")
        }
    }
}

private actor PurgeRecorder: PrivilegedRunner {
    let failPasswordless: Bool
    let failInstall: Bool
    private(set) var calls: [[String]] = []
    private(set) var batches: [[[[String]]]] = []
    private(set) var ruleFileMode: Int?

    init(failPasswordless: Bool = false, failInstall: Bool = false) {
        self.failPasswordless = failPasswordless
        self.failInstall = failInstall
    }

    func run(_ argv: [String]) async throws -> String {
        calls.append(argv)
        if failPasswordless { throw NaddafError.noAccess }
        return "passwordless"
    }

    func runTasks(_ tasks: [[[String]]]) async -> [Result<String, Error>] {
        batches.append(tasks)
        return tasks.map { task in
            if let path = PurgeAccess.installRuleFile(in: task) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                ruleFileMode = attributes?[.posixPermissions] as? Int
                return failInstall ? .failure(NaddafError.noAccess) : .success("installed")
            }
            return .success("admin purge")
        }
    }
}

@Test(arguments: [false, true])
func purgeTriesPasswordlessBeforeAdmin(failPasswordless: Bool) async throws {
    let admin = PurgeRecorder(), user = PurgeRecorder(failPasswordless: failPasswordless)
    let home = URL(fileURLWithPath: "/nonexistent-naddaf-home")
    let results = await runMaintenance([.freeRAM], home: home, runner: admin, userRunner: user,
                                       installPurgeAccess: true, purgeAccessInstalled: true)
    #expect(await user.calls == [PurgeAccess.passwordlessPurge])
    let expected = failPasswordless ? "admin purge" : "passwordless"
    #expect(try results[.freeRAM]?.get() == expected)
    let expectedBatches = failPasswordless ? [[MaintenanceTask.freeRAM.commands(home: home)]] : []
    #expect(await admin.batches == expectedBatches)
}

@Test func purgeInstallsBeforePurgeInOneBatchAndCleansUpOnFailure() async throws {
    let admin = PurgeRecorder(failInstall: true), user = PurgeRecorder()
    let home = URL(fileURLWithPath: "/nonexistent-naddaf-home")
    let results = await runMaintenance([.freeRAM], home: home, runner: admin, userRunner: user,
                                       installPurgeAccess: true, purgeAccessInstalled: false)
    #expect(await user.calls.isEmpty)
    let batches = await admin.batches
    let batch = try #require(batches.first)
    #expect(batches.count == 1)
    #expect(batch.count == 2)
    let path = try #require(PurgeAccess.installRuleFile(in: batch[0]))
    #expect(await admin.ruleFileMode == 0o600)
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(batch.last == MaintenanceTask.freeRAM.commands(home: home))
    #expect(try results[.freeRAM]?.get() == "admin purge")
}

private func visudoStatus(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Test(.enabled(if: geteuid() != 0 && (try? visudoStatus(["-V"])) == 0))
func generatedPurgeRulePassesUnprivilegedVisudo() throws {
    try withTempDir { dir in
        let file = dir.appendingPathComponent("cleanix-purge-test.sudoers")
        for user in ["testuser", "ALL"] {
            let rule = try #require(PurgeAccess.ruleText(user: user))
            try Data(rule.utf8).write(to: file)
            #expect(try visudoStatus(["-c", "-f", file.path]) == 0)
        }
    }
}
