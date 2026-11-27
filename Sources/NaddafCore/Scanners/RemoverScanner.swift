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
    private static let nameMatchFolders: Set<String> = ["Application Support", "Caches", "Logs"]
    private static let deniedNames: Set<String> = [
        "accounts", "adobe", "apple", "application scripts", "application support", "applications", "assistant", "audio",
        "autosave information", "backup", "backups", "cache", "caches", "calendars", "cloudstorage",
        "colors", "components", "containers", "cookies", "data", "developer", "documents", "downloads",
        "dictionaries", "extensions", "favorites", "files", "fonts", "google", "group containers", "httpstorages",
        "internet plug-ins", "keyboard layouts",
        "keychains", "launchagents", "launchdaemons", "library", "logs", "mail", "messages", "metadata",
        "microsoft", "mobile documents", "personalizationportrait", "photos", "preferencepanes", "preferences",
        "printers", "quicklook", "reminders", "safari", "safaribrowsersandboxbroker",
        "saved application state", "screen savers", "scripts", "services", "settings", "shared", "sounds",
        "spellings", "spotlight", "system", "tools", "utilities", "voices", "webkit", "widgets",
        // Other ~/Library top-level folders macOS owns.
        "assistants", "biome", "compositions", "daemon containers", "gamekit", "homekit", "input methods",
        "intents", "keyboard", "maps", "news", "passes", "sharing", "shortcuts", "spelling", "staging",
        "stickers", "suggestions", "translation", "trial", "weather",
        // Generic helper apps nested in vendor folders.
        "agent", "helper", "installer", "launcher", "setup", "support", "uninstall", "uninstaller", "updater",
        "update", "crash reporter", "crashreporter",
    ]
    private static let deniedNameKeys = Set(deniedNames.map(nameKey))

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

    /// Find apps up to four levels below each root, treating bundles as leaves.
    @concurrent
    public func apps(measuringSize: Bool = true) async -> [AppInfo] {
        var seen: Set<URL> = []
        let urls = appDirs.flatMap { Self.appBundles(in: $0, depth: 4) }
            .filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath()).inserted }
        let found = await withTaskGroup(of: AppInfo?.self) { group in
            for url in urls {
                _ = group.addTaskUnlessCancelled {
                    let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                    guard let id = plist?["CFBundleIdentifier"] as? String else { return nil }
                    let name = (plist?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
                    let store = FS.exists(url.appendingPathComponent("Contents/_MASReceipt/receipt"))
                    return AppInfo(name: name, bundleID: id, url: url, bytes: measuringSize ? FS.size(of: url) : 0,
                                   vendor: Self.vendor(from: id), source: store ? .appStore : .other)
                }
            }
            var out: [AppInfo] = []
            for await app in group { if let app { out.append(app) } }
            return out
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func appBundles(in root: URL, depth: Int) -> [URL] {
        guard depth > 0, !Task.isCancelled, root.pathExtension.lowercased() != "app" else { return [] }
        return FS.children(of: root).flatMap { url -> [URL] in
            guard !Task.isCancelled,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink == false else { return [] }
            if url.pathExtension.lowercased() == "app" { return [url] }
            return appBundles(in: url, depth: depth - 1)
        }
    }

    /// Leftovers matched by bundle ID or exact app name in selected Library locations.
    public func leftovers(for app: AppInfo) -> [ScanItem] {
        leftovers(for: app, in: leftoverCandidates())
    }

    /// Share directory listings across all apps and bound the number of concurrent disk walks.
    @concurrent
    public func scanLeftovers(
        for apps: [AppInfo], onResult: @Sendable (URL, [ScanItem]) async -> Void
    ) async {
        guard !apps.isEmpty, !Task.isCancelled else { return }
        let candidates = leftoverCandidates()
        // Multiple installed versions with the same name and bundle ID share the same Library paths.
        let appGroups = Dictionary(grouping: apps, by: { LeftoverIdentity(bundleID: $0.bundleID, name: $0.name) })
        await withTaskGroup(of: ([AppInfo], [ScanItem]).self) { group in
            var pending = appGroups.values.makeIterator()
            var active = 0
            while !Task.isCancelled {
                if active < 4, let versions = pending.next(), let app = versions.first {
                    if group.addTaskUnlessCancelled(operation: { (versions, leftovers(for: app, in: candidates)) }) {
                        active += 1
                    }
                } else if let (versions, items) = await group.next() {
                    active -= 1
                    guard !Task.isCancelled else { break }
                    for app in versions { await onResult(app.url, items) }
                } else {
                    break
                }
            }
        }
    }

    private struct LeftoverIdentity: Hashable {
        let bundleID: String
        let name: String
    }

    private func leftoverCandidates() -> [String: [URL]] {
        let library = home.appendingPathComponent("Library")
        let canonicalLibrary = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Library")
        let folders = Self.leftoverFolders + ["Group Containers", "WebKit", "Application Scripts", "LaunchAgents", "Cookies"]
        var candidates: [String: [URL]] = [:]
        for folder in folders + [""] {
            guard !Task.isCancelled else { break }
            let location = folder.isEmpty ? library : library.appendingPathComponent(folder)
            let expected = folder.isEmpty ? canonicalLibrary : canonicalLibrary.appendingPathComponent(folder)
            if location.resolvingSymlinksInPath().path == expected.path {
                candidates[folder] = FS.children(of: location)
            }
        }
        return candidates
    }

    private func leftovers(for app: AppInfo, in candidates: [String: [URL]]) -> [ScanItem] {
        let name = Self.nameKey(app.name)
        let matchName = name.count >= 4 && !Self.deniedNameKeys.contains(name) && !name.hasPrefix("com.apple.")
            && !app.bundleID.lowercased().hasPrefix("com.apple.")
        let hasValidID = app.bundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
        let bundleID = hasValidID ? app.bundleID : nil
        let canonicalLibrary = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Library")
        var matched: [URL] = []
        for (folder, entries) in candidates {
            let checkName = matchName && (folder.isEmpty || Self.nameMatchFolders.contains(folder))
            let expectedParent = folder.isEmpty ? canonicalLibrary : canonicalLibrary.appendingPathComponent(folder)
            for entry in entries {
                guard !Task.isCancelled else { return [] }
                let entryName = entry.lastPathComponent
                let byID = bundleID.map { Self.matchesBundleID($0, entry: entryName, folder: folder) } ?? false
                let byName = checkName && Self.nameKey(entryName) == name
                    && (!folder.isEmpty || (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
                guard byID || byName else { continue }
                guard entry.resolvingSymlinksInPath().path == expectedParent.appendingPathComponent(entryName).path else {
                    continue
                }
                matched.append(entry)
            }
        }
        return Self.withoutNestedPaths(matched, url: { $0 }).map { url in
            ScanItem(url: url, bytes: FS.size(of: url), reason: "Left by \(app.name)", safety: .review, group: app.name)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Keep one copy of each path, and omit descendants already covered by another selected path.
    public static func withoutNestedPaths<T>(_ items: [T], url: (T) -> URL) -> [T] {
        let paths = Set(items.map { url($0).standardizedFileURL.path })
        var seen: Set<String> = []
        return items.filter { item in
            var current = url(item).standardizedFileURL
            guard seen.insert(current.path).inserted else { return false }
            while current.pathComponents.count > 1 {
                current.deleteLastPathComponent()
                if paths.contains(current.path) { return false }
            }
            return true
        }
    }

    private static func matchesBundleID(_ id: String, entry: String, folder: String) -> Bool {
        switch folder {
        case "": false
        case "Group Containers": entry == id || entry.hasSuffix("." + id)
        case "LaunchAgents": entry == id + ".plist" || (entry.hasPrefix(id + ".") && entry.hasSuffix(".plist"))
        case "Cookies": entry == id + ".binarycookies"
        case "HTTPStorages": entry == id + ".binarycookies" || baseName(entry) == id
        case "WebKit", "Application Scripts": entry == id
        default: baseName(entry) == id
        }
    }

    private static func nameKey(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    /// Settings and caches at exact bundle-ID paths in the user's Library.
    public func resetItems(for app: AppInfo) -> [ScanItem] {
        let id = app.bundleID
        guard !id.isEmpty, id != ".", id != "..",
              id.utf8.allSatisfy({ "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-".utf8.contains($0) })
        else { return [] }

        let lib = home.appendingPathComponent("Library")
        let canonicalLibrary = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Library")
        let paths = ["Preferences/\(id).plist", "Caches/\(id)", "Saved Application State/\(id).savedState",
                     "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies", "WebKit/\(id)",
                     "Containers/\(id)/Data/Library/Caches"]
        return paths.compactMap { path in
            let url = lib.appendingPathComponent(path)
            guard url.resolvingSymlinksInPath().path == canonicalLibrary.appendingPathComponent(path).path else { return nil }
            let bytes = FS.size(of: url)
            guard bytes > 0 else { return nil }
            return ScanItem(url: url, bytes: bytes, reason: "Settings and cache", safety: .review, group: app.name)
        }
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
