import Foundation

public struct LoginItem: Sendable, Hashable {
    public enum Kind: Sendable { case launchAgent, launchDaemon }
    public let name: String
    public let url: URL
    public let kind: Kind
    public let program: String?
    public let enabled: Bool
}

/// Reads launch agents and daemons. Disabling a user agent moves its plist to the quarantine (undoable).
public struct LoginItemsReader: Sendable {
    private let agentDirs: [URL]
    private let daemonDirs: [URL]

    public init(agentDirs: [URL], daemonDirs: [URL] = []) {
        self.agentDirs = agentDirs
        self.daemonDirs = daemonDirs
    }

    public func items() -> [LoginItem] {
        read(agentDirs, kind: .launchAgent) + read(daemonDirs, kind: .launchDaemon)
    }

    public func disable(_ item: LoginItem, using quarantine: Quarantine) throws {
        guard item.kind == .launchAgent else { throw NaddafError.readOnly }
        _ = try quarantine.stash(item.url)
    }

    private func read(_ dirs: [URL], kind: LoginItem.Kind) -> [LoginItem] {
        dirs.flatMap { FS.children(of: $0) }
            .filter { $0.pathExtension == "plist" }
            .compactMap { url in
                guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
                let name = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                let disabled = (plist["Disabled"] as? Bool) ?? false
                return LoginItem(name: name, url: url, kind: kind, program: program, enabled: !disabled)
            }
            .sorted { $0.name < $1.name }
    }
}
