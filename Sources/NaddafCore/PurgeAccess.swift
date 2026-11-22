import Darwin
import Foundation

public enum PurgeAccess {
    public static let rulePath = "/private/etc/sudoers.d/cleanix-purge"
    public static let removeCommand = ["/bin/rm", "-f", rulePath]
    public static let passwordlessPurge = ["/usr/bin/sudo", "-n", "/usr/sbin/purge"]
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: rulePath) }

    public static func ruleText(user: String) -> String? {
        guard user.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_.-]{0,31}/.matchingSemantics(.unicodeScalar)) != nil
        else { return nil }
        // These names can be parsed as aliases or reserved words in sudoers.
        let keywords = ["Defaults", "User_Alias", "Runas_Alias", "Host_Alias", "Cmnd_Alias",
                        "sudoedit", "sha224", "sha256", "sha384", "sha512"]
        let name = user.wholeMatch(of: /[A-Z][A-Z0-9_]*/) != nil || keywords.contains(user)
            ? "\"\(user)\"" : user
        return "\(name) ALL=(root) NOPASSWD: /usr/sbin/purge \"\"\n"
    }

    public static func installScript(ruleFile: String) -> [[String]] {
        [
            ["/usr/sbin/visudo", "-c", "-f", ruleFile],
            ["/usr/bin/install", "-m", "0440", "-o", "root", "-g", "wheel", ruleFile, rulePath],
        ]
    }

    // The two lines must form one task with the same file, in this order.
    static func installRuleFile(in commands: [[String]]) -> String? {
        guard let check = commands.first, check.count == 4 else { return nil }
        let path = check[3]
        let prefix = FileManager.default.temporaryDirectory.path + "/"
        let namePattern = /cleanix-purge-[A-Za-z0-9-]+\.sudoers/.matchingSemantics(.unicodeScalar)
        guard path.hasPrefix(prefix), path.dropFirst(prefix.count).wholeMatch(of: namePattern) != nil,
              commands == installScript(ruleFile: path) else { return nil }
        return path
    }

    static func makeRuleFile() throws -> String {
        guard let rule = ruleText(user: NSUserName()) else { throw NaddafError.notAllowed }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cleanix-purge-\(UUID()).sudoers")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NaddafError.noAccess }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: Data(rule.utf8))
            try file.close()
            return url.path
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func containsCurrentUsersRule(_ path: String) -> Bool {
        guard let rule = ruleText(user: NSUserName()) else { return false }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return false }
        let expected = Data(rule.utf8)
        return (try? file.read(upToCount: expected.count + 1)) == expected
    }

    public static func setEnabled(_ enabled: Bool) async throws {
        let runner = AdminPromptRunner()
        if enabled {
            let path = try makeRuleFile()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let results = await runner.runTasks([installScript(ruleFile: path)])
            guard let result = results.first else { throw NaddafError.noAccess }
            _ = try result.get()
        } else {
            _ = try await runner.run(removeCommand)
        }
    }
}
