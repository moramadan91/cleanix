import Foundation
import CoreServices

public struct AppInfo: Sendable, Hashable {
    public enum Source: Sendable { case appStore, other }
    public let name: String
    public let bundleID: String
    public let url: URL
    public let bytes: Int64
    public let vendor: String
    public let source: Source
}

/// Lists installed apps and the files they leave behind in ~/Library.
public struct RemoverScanner: Sendable {
    private let appDirs: [URL]
    private let home: URL
    private let lastUsed: @Sendable (URL) -> Date?

    private static let leftoverFolders = [
        "Application Support", "Caches", "Preferences", "Containers", "Logs", "Saved Application State", "HTTPStorages",
    ]

    public init(appDirs: [URL], home: URL, lastUsed: @escaping @Sendable (URL) -> Date? = RemoverScanner.spotlightLastUsed) {
        self.appDirs = appDirs
        self.home = home
        self.lastUsed = lastUsed
    }

    public static func spotlightLastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { return nil }
        return date
    }

    public func apps() async -> [AppInfo] {
        appDirs.flatMap { FS.children(of: $0) }
            .filter { $0.pathExtension == "app" }
            .compactMap { url -> AppInfo? in
                let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                guard let id = plist?["CFBundleIdentifier"] as? String else { return nil }
                let name = (plist?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let store = FS.exists(url.appendingPathComponent("Contents/_MASReceipt/receipt"))
                return AppInfo(name: name, bundleID: id, url: url, bytes: FS.size(of: url),
                               vendor: Self.vendor(from: id), source: store ? .appStore : .other)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Leftovers matched by exact bundle ID, or by exact app name in Application Support, Caches and Logs.
    public func leftovers(for app: AppInfo) -> [ScanItem] {
        let lib = home.appendingPathComponent("Library")
        var items: [ScanItem] = []
        for folder in Self.leftoverFolders {
            for entry in FS.children(of: lib.appendingPathComponent(folder)) {
                let base = Self.baseName(entry.lastPathComponent)
                let byName = ["Application Support", "Caches", "Logs"].contains(folder) && base == app.name
                guard base == app.bundleID || byName else { continue }
                let bytes = FS.size(of: entry)
                if bytes > 0 {
                    items.append(ScanItem(url: entry, bytes: bytes, reason: "Left by \(app.name)",
                                          safety: .review, group: app.name))
                }
            }
        }
        return items
    }

    /// Bundle-ID-looking entries in ~/Library whose app is not installed (Apple's own excluded).
    public func orphanLeftovers() async -> [ScanItem] {
        let installed = Set(await apps().map(\.bundleID))
        let lib = home.appendingPathComponent("Library")
        var items: [ScanItem] = []
        for folder in Self.leftoverFolders {
            for entry in FS.children(of: lib.appendingPathComponent(folder)) {
                let base = Self.baseName(entry.lastPathComponent)
                guard Self.looksLikeBundleID(base), !base.hasPrefix("com.apple."), !installed.contains(base) else { continue }
                let bytes = FS.size(of: entry)
                if bytes > 0 {
                    items.append(ScanItem(url: entry, bytes: bytes, reason: "App not installed",
                                          safety: .review, group: base))
                }
            }
        }
        return items
    }

    /// Apps with a known last-used date older than the cutoff. Unknown dates are not listed.
    public func unused(olderThanDays: Int, now: Date = Date()) async -> [AppInfo] {
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86400)
        return await apps().filter { app in lastUsed(app.url).map { $0 < cutoff } ?? false }
    }

    private static func vendor(from bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 2 else { return "Other" }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
    }

    private static func baseName(_ name: String) -> String {
        for suffix in [".plist", ".savedState"] where name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        return name
    }

    private static func looksLikeBundleID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil
    }
}
