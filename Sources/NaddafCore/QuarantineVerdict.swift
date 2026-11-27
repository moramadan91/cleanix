import Foundation

public enum QuarantineVerdict: String, CaseIterable, Sendable {
    case safe, review, unsafe

    public enum Kind: String, Sendable {
        case cache, logs, settings, appData, app, document, media, download, other

        public var labelKey: String { "quarantine.kind.\(rawValue)" }
    }

    public static func classify(
        record: QuarantineRecord, home: URL, installedBundleIDs: Set<String>
    ) -> (verdict: Self, kind: Kind, reasonKey: String) {
        let result = classify(record: record, home: home, installedBundleIDs: installedBundleIDs, installedAppNames: [:])
        return (result.verdict, result.kind, result.reasonKey)
    }

    /// Installed app names are keyed by bundle ID. They also match data folders named after the app.
    public static func classify(
        record: QuarantineRecord, home: URL, installedBundleIDs: Set<String>, installedAppNames: [String: String]
    ) -> (verdict: Self, kind: Kind, reasonKey: String, owningApp: String?) {
        let root = home.standardizedFileURL.pathComponents
        let original = record.original.standardizedFileURL.pathComponents
        let relative = original.starts(with: root) ? Array(original.dropFirst(root.count)) : []
        let path = relative.map { $0.lowercased() }

        func result(_ verdict: Self, _ kind: Kind, _ reason: String, owner: String? = nil)
            -> (Self, Kind, String, String?) {
            (verdict, kind, "quarantine.reason." + reason, owner)
        }

        switch path.first {
        case "documents", "desktop": return result(.unsafe, .document, "personal")
        case "pictures", "movies", "music": return result(.unsafe, .media, "personal")
        case "downloads": return result(.review, .download, "downloads")
        case "applications":
            if let index = path.dropFirst().firstIndex(where: { $0.hasSuffix(".app") }) {
                return result(.review, .app, "application", owner: String(relative[index].dropLast(4)))
            }
        case ".npm": return result(.safe, .cache, "rebuild")
        case "tmp", "temp", ".trash", ".trashes", "trash": return result(.safe, .other, "temporary")
        default: break
        }
        guard path.first == "library", path.count >= 2 else { return result(.review, .other, "unknown") }
        let library = Array(path.dropFirst())
        let area = library[0]
        let containerPath = library.dropFirst(2)
        let containerLibrary = area == "containers" && containerPath.starts(with: ["data", "library"])
            ? containerPath.dropFirst(2) : []
        let entry = relative.count > 2 ? ownerName(relative[2]) : nil
        let browser = browsers.first {
            library.starts(with: $0.path)
                || ($0.path.first == "application support" && library.starts(with: ["caches"] + $0.path.dropFirst()))
        }
        // These folders sometimes use a product or vendor directory in place of a bundle ID.
        let candidate = browser?.id ?? entry
        let installedID = installedBundleIDs.sorted().first { id in
            guard let candidate else { return false }
            let name = installedAppNames[id]
            return id.caseInsensitiveCompare(candidate) == .orderedSame
                || name?.caseInsensitiveCompare(candidate) == .orderedSame
                || (area == "group containers" && candidate.lowercased().hasSuffix("." + id.lowercased()))
        }
        let owner = installedID.flatMap { installedAppNames[$0] } ?? browser?.name ?? entry

        if area == "mobile documents" || area == "cloudstorage" { return result(.unsafe, .document, "personal") }
        if area == "keychains" || containerLibrary.first == "keychains" {
            return result(.unsafe, .settings, "keychain")
        }
        if area == "caches", library.count > 1 { return result(.safe, .cache, "rebuild", owner: owner) }
        if area == "logs", library.count > 1 { return result(.safe, .logs, "rebuild", owner: owner) }
        let settingsFolders = ["httpstorages", "saved application state"]
        if settingsFolders.contains(area) || containerLibrary.first.map(settingsFolders.contains) == true {
            return result(.review, .settings, "settings", owner: owner)
        }
        if containerLibrary.first == "caches" {
            return result(.safe, .cache, "rebuild", owner: owner)
        }
        if library.starts(with: ["developer", "xcode", "deriveddata"])
            || library.starts(with: ["developer", "coresimulator", "caches"])
            || (library.starts(with: ["developer", "xcode", "archives"])
                && cacheBeforeArchive(library.dropFirst(3))) {
            return result(.safe, .cache, "rebuild")
        }
        let webKit = area == "webkit" ? library[...] : containerLibrary
        let webKitCache = webKit.first == "webkit" && webKit.dropFirst().contains(where: cacheFolders.contains)
        let browserCache = browser.map { isBrowserCache(library.dropFirst($0.path.count)) } ?? false
        if webKitCache || browserCache {
            return result(.safe, .cache, "rebuild", owner: owner)
        }
        if area == "mail downloads" || containerLibrary.first == "mail downloads" {
            return result(.review, .download, "downloads", owner: area == "containers" ? owner : nil)
        }
        if ["ios software updates", "iphone software updates", "ipad software updates", "ipod software updates"]
                .contains(area == "itunes" ? library.dropFirst().first ?? "" : area) {
            return result(.safe, .download, "redownload", owner: area == "containers" ? owner : nil)
        }
        if ["tmp", "temp", "temporaryitems", "trash", ".trash"].contains(area) {
            return result(.safe, .other, "temporary")
        }

        switch area {
        case "application support", "containers", "preferences":
            let kind: Kind = area == "preferences" ? .settings : .appData
            if installedID != nil { return result(.unsafe, kind, "installed", owner: owner) }
            return result(.review, kind, kind == .settings ? "settings" : "appData", owner: owner)
        case "cookies", "launchagents", "application scripts":
            return result(.review, .settings, "settings", owner: owner)
        case "group containers", "safari", "webkit":
            return result(.review, .appData, "appData", owner: owner)
        default: return result(.review, .other, "unknown")
        }
    }

    private static let cacheFolders: Set<String> = [
        "cache", "caches", "cache2", "code cache", "gpucache", "dawncache", "networkcache", "diskcache", "mediacache",
        "favicon cache",
    ]

    private static let browsers: [(path: [String], id: String, name: String)] = [
        (["application support", "google", "chrome"], "com.google.Chrome", "Chrome"),
        (["application support", "bravesoftware", "brave-browser"], "com.brave.Browser", "Brave"),
        (["application support", "chromium"], "org.chromium.Chromium", "Chromium"),
        (["application support", "firefox"], "org.mozilla.firefox", "Firefox"),
        (["application support", "microsoft edge"], "com.microsoft.edgemac", "Microsoft Edge"),
        (["safari"], "com.apple.Safari", "Safari"),
    ]

    private static func cacheBeforeArchive(_ path: ArraySlice<String>) -> Bool {
        path.prefix { !$0.hasSuffix(".xcarchive") }.contains(where: cacheFolders.contains)
    }

    private static func isBrowserCache(_ path: ArraySlice<String>) -> Bool {
        guard let first = path.first else { return false }
        if cacheFolders.contains(first) { return true }
        if first == "profiles" {
            return path.dropFirst(2).first.map(cacheFolders.contains) ?? false
        }
        if first == "default" || first.hasPrefix("profile ") || first == "guest profile" || first == "system profile" {
            return path.dropFirst().first.map(cacheFolders.contains) ?? false
        }
        return false
    }

    private static func ownerName(_ component: String) -> String {
        for suffix in [".plist", ".savedstate", ".binarycookies"] where component.lowercased().hasSuffix(suffix) {
            return String(component.dropLast(suffix.count))
        }
        return component
    }
}
