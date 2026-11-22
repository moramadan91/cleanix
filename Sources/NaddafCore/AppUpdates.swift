import Foundation

/// Compares numeric version components, treating omitted components as zero.
public func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    let lhs = AppVersion(a)
    let rhs = AppVersion(b)
    for index in 0..<max(lhs.parts.count, rhs.parts.count) {
        let left = index < lhs.parts.count ? lhs.parts[index] : ""
        let right = index < rhs.parts.count ? rhs.parts[index] : ""
        // Compare digit counts first so components can exceed the range of Int.
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        if left != right { return left < right ? .orderedAscending : .orderedDescending }
    }
    if lhs.suffix.isEmpty != rhs.suffix.isEmpty {
        return lhs.suffix.isEmpty ? .orderedDescending : .orderedAscending
    }
    return lhs.suffix.compare(rhs.suffix, options: .numeric)
}

private struct AppVersion {
    let parts: [Substring]
    let suffix: Substring

    init(_ version: String) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.prefix { !$0.isWhitespace && $0 != "(" }
        let numeric = token.prefix { ($0.isASCII && $0.isNumber) || $0 == "." }
        parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == "0" }) }
        suffix = token.dropFirst(numeric.count)
    }
}

public struct AppUpdate: Sendable, Hashable {
    public let app: AppInfo
    public let installed: String
    public let latest: String
    public let storeURL: URL?
}

public struct UpdateChecker: Sendable {
    private let fetch: @Sendable (URL) async throws -> Data
    private static let timeout: TimeInterval = 10

    public init() {
        self.init { url in
            let request = URLRequest(url: url, timeoutInterval: Self.timeout)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    public init(fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.fetch = fetch
    }

    public func check(_ apps: [AppInfo]) async -> [AppUpdate] {
        await withTaskGroup(of: (Int, AppUpdate?).self) { group in
            var remaining = apps.enumerated().makeIterator()
            for _ in 0..<8 {
                guard let (index, app) = remaining.next() else { break }
                _ = group.addTaskUnlessCancelled { (index, await update(for: app)) }
            }
            var updates: [(Int, AppUpdate)] = []
            while let (index, update) = await group.next() {
                if let update { updates.append((index, update)) }
                if let (nextIndex, app) = remaining.next() {
                    _ = group.addTaskUnlessCancelled { (nextIndex, await self.update(for: app)) }
                }
            }
            return updates.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func update(for app: AppInfo) async -> AppUpdate? {
        let plist = NSDictionary(contentsOf: app.url.appendingPathComponent("Contents/Info.plist"))
        func installedVersion(for key: String) -> String? {
            guard let value = (plist?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        let short = installedVersion(for: "CFBundleShortVersionString")
        let installed: String?
        let latest: String
        let storeURL: URL?
        if app.source == .appStore {
            guard let short else { return nil }
            var lookup = URLComponents()
            lookup.scheme = "https"
            lookup.host = "itunes.apple.com"
            lookup.path = "/lookup"
            lookup.queryItems = [URLQueryItem(name: "bundleId", value: app.bundleID)]
            guard let url = lookup.url, let data = try? await fetchWithTimeout(url),
                  let result = Self.storeResult(in: data) else { return nil }
            installed = short
            latest = result.version
            storeURL = result.storeURL
        } else {
            guard let feed = plist?["SUFeedURL"] as? String, let url = Self.httpsURL(feed),
                  let data = try? await fetchWithTimeout(url),
                  let version = Self.appcastVersion(in: data) else { return nil }
            switch version {
            case .short(let value):
                installed = short
                latest = value
            case .build(let value):
                installed = installedVersion(for: "CFBundleVersion")
                latest = value
            }
            storeURL = nil
        }
        guard let installed, compareVersions(latest, installed) == .orderedDescending else { return nil }
        return AppUpdate(app: app, installed: short ?? installed, latest: latest, storeURL: storeURL)
    }

    private func fetchWithTimeout(_ url: URL) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await fetch(url) }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.timeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw URLError(.cancelled) }
            return data
        }
    }

    enum AppcastVersion: Equatable {
        case short(String)
        case build(String)
    }

    static func appcastVersion(in data: Data) -> AppcastVersion? {
        let parser = XMLParser(data: data)
        let appcast = AppcastParser()
        parser.delegate = appcast
        guard parser.parse() else { return nil }
        return appcast.latest
    }

    static func storeResult(in data: Data) -> (version: String, storeURL: URL?)? {
        guard let lookup = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (lookup["results"] as? [Any])?.first as? [String: Any],
              let rawVersion = result["version"] as? String else { return nil }
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return nil }
        let storeURL = (result["trackViewUrl"] as? String).flatMap(httpsURL).map { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "macappstore"
            return components?.url ?? url
        }
        return (version, storeURL)
    }

    private static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    private enum Field: String {
        case short = "sparkle:shortVersionString"
        case build = "sparkle:version"
    }

    private var inItem = false
    private var versions: [Field: String] = [:]
    private var field: Field?
    private var text = ""
    var latest: UpdateChecker.AppcastVersion? {
        versions[.short].map(UpdateChecker.AppcastVersion.short)
            ?? versions[.build].map(UpdateChecker.AppcastVersion.build)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "item" {
            inItem = true
        } else if inItem && name == "enclosure" {
            if let version = attributes[Field.short.rawValue] { append(version, to: .short) }
            if let version = attributes[Field.build.rawValue] { append(version, to: .build) }
        } else if inItem, let field = Field(rawValue: name) {
            self.field = field
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if field != nil { text += String(decoding: data, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if let field, name == field.rawValue {
            append(text, to: field)
            self.field = nil
        } else if name == "item" {
            inItem = false
        }
    }

    private func append(_ value: String, to field: Field) {
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return }
        if versions[field].map({ compareVersions(version, $0) == .orderedDescending }) ?? true {
            versions[field] = version
        }
    }
}
