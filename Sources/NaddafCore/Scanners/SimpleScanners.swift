import Foundation

/// Files that Mail saved when attachments were opened.
public struct MailAttachmentsScanner: Scanner {
    private let mailDownloads: [URL]

    public init(mailDownloads: [URL]) { self.mailDownloads = mailDownloads }

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for root in mailDownloads {
            for url in FS.children(of: root) {
                try Task.checkCancellation()
                let bytes = FS.size(of: url)
                if bytes > 0 {
                    items.append(ScanItem(url: url, bytes: bytes, reason: "Mail attachment", safety: .review, group: "Mail"))
                }
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
}

/// Top-level entries in Downloads that were last modified before the cutoff.
public struct DownloadsScanner: Scanner {
    private let downloads: URL
    private let olderThanDays: Int
    private let now: Date

    public init(downloads: URL, olderThanDays: Int, now: Date = Date()) {
        self.downloads = downloads
        self.olderThanDays = olderThanDays
        self.now = now
    }

    public func scan() async throws -> [ScanItem] {
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86400)
        var items: [ScanItem] = []
        for url in FS.children(of: downloads) where !url.lastPathComponent.hasPrefix(".") {
            try Task.checkCancellation()
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            items.append(ScanItem(url: url, bytes: FS.size(of: url), reason: "In Downloads for \(olderThanDays)+ days",
                                  safety: .review, group: "Downloads"))
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
}

/// Browser data in separate groups: cache is safe, history and cookies need review.
public struct PrivacyScanner: Scanner {
    private let home: URL

    public init(home: URL) { self.home = home }

    private struct Browser { let name: String; let cache: [String]; let history: [String]; let cookies: [String] }

    private static let browsers: [Browser] = [
        Browser(name: "Safari", cache: ["Library/Caches/com.apple.Safari"],
                history: ["Library/Safari/History.db"], cookies: ["Library/Cookies/Cookies.binarycookies"]),
        Browser(name: "Chrome", cache: ["Library/Caches/Google/Chrome"],
                history: ["Library/Application Support/Google/Chrome/Default/History"],
                cookies: ["Library/Application Support/Google/Chrome/Default/Cookies"]),
        Browser(name: "Brave", cache: ["Library/Caches/BraveSoftware/Brave-Browser"],
                history: ["Library/Application Support/BraveSoftware/Brave-Browser/Default/History"],
                cookies: ["Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"]),
        Browser(name: "Firefox", cache: ["Library/Caches/Firefox"], history: [], cookies: []),
    ]

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        func add(_ paths: [String], browser: String, kind: String, safety: Safety) throws {
            for path in paths {
                try Task.checkCancellation()
                let url = home.appendingPathComponent(path)
                guard FS.exists(url) else { continue }
                let bytes = FS.size(of: url)
                if bytes > 0 {
                    items.append(ScanItem(url: url, bytes: bytes, reason: "\(browser) \(kind)", safety: safety,
                                          group: "\(browser) \(kind)"))
                }
            }
        }
        for b in Self.browsers {
            try add(b.cache, browser: b.name, kind: "cache", safety: .safe)
            try add(b.history, browser: b.name, kind: "history", safety: .review)
            try add(b.cookies, browser: b.name, kind: "cookies", safety: .review)
        }
        let profiles = FS.children(of: home.appendingPathComponent("Library/Application Support/Firefox/Profiles"))
        for profile in profiles {
            try add(["places.sqlite"].map { profile.appendingPathComponent($0).path.replacingOccurrences(of: home.path + "/", with: "") },
                    browser: "Firefox", kind: "history", safety: .review)
            try add(["cookies.sqlite"].map { profile.appendingPathComponent($0).path.replacingOccurrences(of: home.path + "/", with: "") },
                    browser: "Firefox", kind: "cookies", safety: .review)
        }
        return items
    }
}
