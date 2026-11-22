import Foundation

/// Device-level junk: logs, Xcode and simulator data, package-manager caches, iPhone backups and
/// firmware, Messages attachments. Things that cannot be downloaded again are `.review` (start unticked).
/// Generic per-app caches in Library/Caches belong to `AppCacheScanner`.
public struct SweepScanner: Scanner {
    private let home: URL

    public init(home: URL) { self.home = home }

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []

        func add(_ urls: [URL], group: String, reason: String, safety: Safety = .safe) throws {
            for url in urls {
                try Task.checkCancellation()
                let bytes = FS.size(of: url)
                if bytes > 0 {
                    items.append(ScanItem(url: url, bytes: bytes, reason: reason, safety: safety, group: group))
                }
            }
        }

        let library = home.appendingPathComponent("Library")
        try add(FS.children(of: library.appendingPathComponent("Logs")), group: "Logs", reason: "Log files")
        try add(FS.children(of: library.appendingPathComponent("Developer/Xcode/DerivedData")),
                group: "Developer", reason: "Xcode build data")
        try add([home.appendingPathComponent(".npm/_cacache")], group: "Developer", reason: "npm cache")
        try add([library.appendingPathComponent("Caches/Homebrew")], group: "Developer", reason: "Homebrew cache")
        try add([library.appendingPathComponent("Developer/CoreSimulator/Caches")], group: "Developer", reason: "Simulator cache")
        try add(["pip", "Yarn", "CocoaPods"].map { library.appendingPathComponent("Caches/\($0)") },
                group: "Developer", reason: "Package cache")
        try add(FS.children(of: library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport")),
                group: "Developer", reason: "Device support files", safety: .review)
        try add(FS.children(of: library.appendingPathComponent("Application Support/MobileSync/Backup")),
                group: "Devices", reason: "iPhone backup", safety: .review)
        try add(FS.children(of: library.appendingPathComponent("iTunes/iPhone Software Updates")),
                group: "Devices", reason: "iPhone software update")
        try add([library.appendingPathComponent("Messages/Attachments")], group: "Messages",
                reason: "Messages attachments", safety: .review)
        return items
    }
}
