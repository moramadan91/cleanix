import Foundation

/// Device-level junk: logs, Xcode build data, npm and Homebrew caches.
/// Generic per-app caches in Library/Caches belong to `AppCacheScanner`.
public struct SweepScanner: Scanner {
    private let home: URL

    public init(home: URL) { self.home = home }

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []

        func add(_ urls: [URL], group: String, reason: String) throws {
            for url in urls {
                try Task.checkCancellation()
                let bytes = FS.size(of: url)
                if bytes > 0 {
                    items.append(ScanItem(url: url, bytes: bytes, reason: reason, safety: .safe, group: group))
                }
            }
        }

        let library = home.appendingPathComponent("Library")
        try add(FS.children(of: library.appendingPathComponent("Logs")), group: "Logs", reason: "Log files")
        try add(FS.children(of: library.appendingPathComponent("Developer/Xcode/DerivedData")),
                group: "Developer", reason: "Xcode build data")
        try add([home.appendingPathComponent(".npm/_cacache")], group: "Developer", reason: "npm cache")
        try add([library.appendingPathComponent("Caches/Homebrew")], group: "Developer", reason: "Homebrew cache")
        return items
    }
}
