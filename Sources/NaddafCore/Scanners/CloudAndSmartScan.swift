import Foundation

public struct CloudFolder: Sendable, Hashable {
    public let name: String
    public let url: URL
    public let isICloud: Bool
}

/// Works only on cloud folders that are already synced to this Mac. No sign-in, no network.
public struct CloudFoldersScanner: Sendable {
    private let home: URL

    public init(home: URL) { self.home = home }

    private var iCloudRoot: URL { home.appendingPathComponent("Library/Mobile Documents") }

    public func folders() -> [CloudFolder] {
        var found: [CloudFolder] = []
        let drive = iCloudRoot.appendingPathComponent("com~apple~CloudDocs")
        if FS.exists(drive) { found.append(CloudFolder(name: "iCloud Drive", url: drive, isICloud: true)) }
        for url in FS.children(of: home.appendingPathComponent("Library/CloudStorage")) {
            found.append(CloudFolder(name: url.lastPathComponent, url: url, isICloud: false))
        }
        for url in FS.children(of: home) {
            let name = url.lastPathComponent
            if name == "Dropbox" || name.hasPrefix("OneDrive") || name == "Google Drive" {
                found.append(CloudFolder(name: name, url: url, isICloud: false))
            }
        }
        return found
    }

    public func largest(in folder: CloudFolder, limit: Int) -> [ScanItem] {
        var files: [ScanItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: folder.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        while let url = walker.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append(ScanItem(url: url, bytes: Int64(v.fileSize ?? 0), reason: "In \(folder.name)",
                                  safety: .review, group: folder.name))
        }
        return Array(files.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// Frees local space for an iCloud file; the file stays in iCloud.
    public func evict(_ url: URL) throws {
        let allowed = iCloudRoot.standardizedFileURL.pathComponents
        let candidate = url.standardizedFileURL.pathComponents
        guard candidate.count > allowed.count, Array(candidate.prefix(allowed.count)) == allowed else {
            throw NaddafError.notAllowed
        }
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

public struct SmartScanSection: Sendable {
    public let name: String
    public let items: [ScanItem]
    public let error: String?
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Runs several scanners at once. A failing scanner is reported in its section, not thrown.
public struct SmartScan: Sendable {
    private let sections: [(name: String, scanner: any Scanner)]

    public init(sections: [(name: String, scanner: any Scanner)]) { self.sections = sections }

    public func run() async -> [SmartScanSection] {
        await withTaskGroup(of: (Int, SmartScanSection).self) { group in
            for (index, entry) in sections.enumerated() {
                group.addTask {
                    do {
                        return (index, SmartScanSection(name: entry.name, items: try await entry.scanner.scan(), error: nil))
                    } catch is CancellationError {
                        return (index, SmartScanSection(name: entry.name, items: [], error: "cancelled"))
                    } catch {
                        return (index, SmartScanSection(name: entry.name, items: [], error: error.localizedDescription))
                    }
                }
            }
            var done: [(Int, SmartScanSection)] = []
            for await result in group { done.append(result) }
            return done.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
