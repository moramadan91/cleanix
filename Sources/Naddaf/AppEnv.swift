import Foundation
import NaddafCore

/// Where the app reads and cleans. `--demo-home <path>` swaps the real home for a fake one,
/// so screens can be tried without touching real files.
final class AppEnv: Sendable {
    static let shared = AppEnv()

    let home: URL
    let canonicalHome: URL
    let isDemo: Bool
    let appDirs: [URL]
    let quarantine: Quarantine
    let cleaner: Cleaner
    private let uninstallPolicy: PathPolicy

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
        let base = home
        let lib = base.appendingPathComponent("Library")
        canonicalHome = base.standardizedFileURL.resolvingSymlinksInPath()
        let userApps = AppEnv.userOnly(appDirs)
        uninstallPolicy = PathPolicy(allowedRoots: userApps)
        quarantine = Quarantine(root: lib.appendingPathComponent("Application Support/Naddaf/Quarantine"), home: base)
        // Allowlist: only the folders the scanners report from. Everything else is refused by Cleaner.
        let roots = ["Caches", "HTTPStorages", "Containers", "Group Containers", "Application Support",
                     "Logs", "Developer/Xcode/DerivedData", "Mail Downloads", "Preferences",
                     "Saved Application State", "Cookies", "Safari", "WebKit",
                     "Developer/CoreSimulator/Caches", "Developer/Xcode/iOS DeviceSupport",
                     "iTunes/iPhone Software Updates", "Messages/Attachments"].map { lib.appendingPathComponent($0) }
            + AppEnv.userFolders.map { base.appendingPathComponent($0) }
            + [base.appendingPathComponent(".npm")]
            + userApps
        cleaner = Cleaner(policy: PathPolicy(allowedRoots: roots), quarantine: quarantine)
    }

    /// Allow only the Library paths present in the confirmed uninstall preview.
    func uninstallCleaner(for items: [ScanItem]) -> Cleaner {
        let canonicalLibrary = canonicalHome.appendingPathComponent("Library")
        let libraryPrefixes = [canonicalLibrary.path, home.appendingPathComponent("Library").standardizedFileURL.path]
            .map { $0 + "/" }
        let reviewedPaths = items.compactMap { item -> URL? in
            let path = item.url.standardizedFileURL.path
            guard let prefix = libraryPrefixes.first(where: { path.hasPrefix($0) }) else { return nil }
            return canonicalLibrary.appendingPathComponent(String(path.dropFirst(prefix.count)))
        }
        return Cleaner(policy: uninstallPolicy.allowingExactPaths(reviewedPaths), quarantine: quarantine)
    }

    /// Personal folders the Clutter screens look in (and the only ones they may clean).
    static let userFolders = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]

    /// App folders the user installs into (never /System).
    var userAppDirs: [URL] { AppEnv.userOnly(appDirs) }

    private static func userOnly(_ dirs: [URL]) -> [URL] { dirs.filter { !$0.path.hasPrefix("/System") } }
}

func formatBytes(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file).locale(Lang.locale))
}
