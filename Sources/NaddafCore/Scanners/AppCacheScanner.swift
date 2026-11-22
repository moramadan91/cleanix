import Foundation

public struct AppCacheGroup: Identifiable, Sendable {
    public let id: String
    public let appName: String
    public let bundleID: String?
    public let appURL: URL?
    public let isRunning: Bool
    public let isSystem: Bool
    public let items: [ScanItem]
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Lists cache folders per app so the user can choose which to clear.
/// Only cache folders are included: never cookies, local storage, IndexedDB or logins.
public struct AppCacheScanner: Sendable {
    private let home: URL
    private let appDirs: [URL]
    private let runningBundleIDs: @Sendable () -> Set<String>

    private static let supportCacheNames = ["Cache", "Caches", "Code Cache", "GPUCache", "DawnCache", "ShaderCache"]

    public init(home: URL, appDirs: [URL], runningBundleIDs: @escaping @Sendable () -> Set<String>) {
        self.home = home
        self.appDirs = appDirs
        self.runningBundleIDs = runningBundleIDs
    }

    private struct App { let name: String; let bundleID: String; let url: URL }
    private struct Candidate { let rawName: String; let url: URL }

    public func groups() async throws -> [AppCacheGroup] {
        let apps = loadApps()
        let byID = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(apps.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let running = runningBundleIDs()

        var grouped: [String: (app: App?, raw: String, urls: [URL])] = [:]
        for candidate in candidates(bundleIDs: Set(byID.keys)) {
            try Task.checkCancellation()
            let app = byID[candidate.rawName] ?? byName[candidate.rawName.lowercased()]
            let key = app?.bundleID ?? candidate.rawName
            var entry = grouped[key] ?? (app, candidate.rawName, [])
            entry.urls.append(candidate.url)
            grouped[key] = entry
        }

        var result: [AppCacheGroup] = []
        for (key, entry) in grouped {
            let isSystem = key.hasPrefix("com.apple.")
            let name = entry.app?.name ?? entry.raw
            var items: [ScanItem] = []
            for url in entry.urls {
                try Task.checkCancellation()
                let bytes = FS.size(of: url)
                if bytes > 0 {
                    items.append(ScanItem(url: url, bytes: bytes, reason: "Cache",
                                          safety: isSystem ? .review : .safe, group: name))
                }
            }
            guard !items.isEmpty else { continue }
            result.append(AppCacheGroup(
                id: key, appName: name, bundleID: entry.app?.bundleID, appURL: entry.app?.url,
                isRunning: entry.app.map { running.contains($0.bundleID) } ?? false,
                isSystem: isSystem, items: items))
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    private func loadApps() -> [App] {
        appDirs.flatMap { FS.children(of: $0) }
            .filter { $0.pathExtension == "app" }
            .compactMap { url in
                let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                guard let id = plist?["CFBundleIdentifier"] as? String else { return nil }
                let name = (plist?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
                return App(name: name, bundleID: id, url: url)
            }
    }

    private func candidates(bundleIDs: Set<String>) -> [Candidate] {
        let lib = home.appendingPathComponent("Library")
        var out: [Candidate] = []
        for dir in ["Caches", "HTTPStorages"] {
            out += FS.children(of: lib.appendingPathComponent(dir))
                .map { Candidate(rawName: $0.lastPathComponent, url: $0) }
        }
        for container in FS.children(of: lib.appendingPathComponent("Containers")) {
            let caches = container.appendingPathComponent("Data/Library/Caches")
            if FS.exists(caches) { out.append(Candidate(rawName: container.lastPathComponent, url: caches)) }
        }
        for group in FS.children(of: lib.appendingPathComponent("Group Containers")) {
            let caches = group.appendingPathComponent("Library/Caches")
            guard FS.exists(caches) else { continue }
            let name = group.lastPathComponent
            let owner = bundleIDs.first { name.hasSuffix($0) }
            out.append(Candidate(rawName: owner ?? name, url: caches))
        }
        for app in FS.children(of: lib.appendingPathComponent("Application Support")) {
            let name = app.lastPathComponent
            for cacheName in Self.supportCacheNames + ["Service Worker/CacheStorage"] {
                let url = app.appendingPathComponent(cacheName)
                if FS.exists(url) { out.append(Candidate(rawName: name, url: url)) }
            }
        }
        return out
    }
}
