import Foundation

/// Extensions installed in Chromium browsers (every profile) and Safari. Review only: browsers manage
/// their own extensions, so Cleanix lists them and shows them in Finder, it never removes them.
public struct BrowserExtensionsScanner: Scanner {
    private let home: URL
    private let safariLister: @Sendable () -> [URL]

    static let chromium = [("Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"),
                           ("Edge", "Microsoft Edge"), ("Vivaldi", "Vivaldi")]

    public init(home: URL, safariLister: @escaping @Sendable () -> [URL] = BrowserExtensionsScanner.safariExtensions) {
        self.home = home
        self.safariLister = safariLister
    }

    public func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        let support = home.appendingPathComponent("Library/Application Support")
        for (browser, folder) in Self.chromium {
            for profile in FS.children(of: support.appendingPathComponent(folder)) {
                for ext in FS.children(of: profile.appendingPathComponent("Extensions")) {
                    try Task.checkCancellation()
                    // Newest version folder with a manifest ("1.10_0" is newer than "1.9_0").
                    guard let version = FS.children(of: ext)
                        .filter({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) })
                        .max(by: { compareVersions($0.lastPathComponent, $1.lastPathComponent) == .orderedAscending }),
                          let name = Self.name(inExtension: version) else { continue }
                    items.append(ScanItem(url: ext, bytes: FS.size(of: ext), reason: "Browser extension",
                                          safety: .review, group: browser, title: name))
                }
            }
        }
        for appex in safariLister() {
            items.append(ScanItem(url: appex, bytes: FS.size(of: appex), reason: "Browser extension",
                                  safety: .review, group: "Safari", title: appex.deletingPathExtension().lastPathComponent))
        }
        return items
    }

    /// Manifest name, with `__MSG_key__` looked up in `_locales/<default_locale>/messages.json`.
    static func name(inExtension dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = name.dropFirst(6).dropLast(2).lowercased()
        let locale = manifest["default_locale"] as? String ?? "en"
        guard let msgData = try? Data(contentsOf: dir.appendingPathComponent("_locales/\(locale)/messages.json")),
              let messages = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
              let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
              let message = entry["message"] as? String else { return String(key) }
        return message
    }

    /// Safari web extensions and content blockers registered with the system.
    @Sendable public static func safariExtensions() -> [URL] {
        ["com.apple.Safari.web-extension", "com.apple.Safari.content-blocker", "com.apple.Safari.extension"]
            .flatMap { parsePluginkit(run("/usr/bin/pluginkit", ["-mAv", "-p", $0])) }
    }

    static func parsePluginkit(_ output: String) -> [URL] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let path = line.split(separator: "\t").last, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(path))
        }
    }

    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
