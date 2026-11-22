import Foundation
import NaddafCore

/// Where the app reads and cleans. `--demo-home <path>` swaps the real home for a fake one,
/// so screens can be tried without touching real files.
final class AppEnv: Sendable {
    static let shared = AppEnv()

    let home: URL
    let isDemo: Bool
    let appDirs: [URL]
    let quarantine: Quarantine
    let cleaner: Cleaner

    private init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--demo-home"), i + 1 < args.count {
            home = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            isDemo = true
            appDirs = [home.appendingPathComponent("Applications")]
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
            isDemo = false
            appDirs = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                       home.appendingPathComponent("Applications")]
        }
        let lib = home.appendingPathComponent("Library")
        quarantine = Quarantine(root: lib.appendingPathComponent("Application Support/Naddaf/Quarantine"))
        // Allowlist: only the folders the scanners report from. Everything else is refused by Cleaner.
        let roots = ["Caches", "HTTPStorages", "Containers", "Group Containers", "Application Support",
                     "Logs", "Developer/Xcode/DerivedData"].map { lib.appendingPathComponent($0) }
            + [home.appendingPathComponent(".npm")]
        cleaner = Cleaner(policy: PathPolicy(allowedRoots: roots), quarantine: quarantine)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
