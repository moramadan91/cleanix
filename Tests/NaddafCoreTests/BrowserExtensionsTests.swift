import Testing
import Foundation
@testable import NaddafCore

@Test func chromiumExtensionsResolveLocalizedNames() async throws {
    try await withTempDirAsync { home in
        let ext = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Extensions/abcdef/1.2_0")
        try makeFile(ext.appendingPathComponent("manifest.json"))
        try #"{"name":"__MSG_appName__","default_locale":"en","version":"1.2"}"#.write(
            to: ext.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try makeFile(ext.appendingPathComponent("_locales/en/messages.json"))
        try #"{"appname":{"message":"Grammar Helper"}}"#.write(
            to: ext.appendingPathComponent("_locales/en/messages.json"), atomically: true, encoding: .utf8)
        let brave = home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/Extensions/xyz/3.0")
        try makeFile(brave.appendingPathComponent("manifest.json"))
        try #"{"name":"Dark Reader"}"#.write(to: brave.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let items = try await BrowserExtensionsScanner(home: home, safariLister: { [] }).scan()
        #expect(Set(items.map(\.title)) == ["Grammar Helper", "Dark Reader"])
        #expect(Set(items.map(\.group)) == ["Chrome", "Brave"])
        #expect(items.allSatisfy { $0.safety == .review })
        #expect(items.first { $0.group == "Chrome" }?.url.lastPathComponent == "abcdef")
    }
}

@Test func pluginkitOutputGivesSafariExtensionPaths() {
    let out = """
    +    com.acme.blocker.ext(1.4)\t1D2C\t2025-01-01 10:00:00 +0000\t/Applications/Acme.app/Contents/PlugIns/Acme Blocker.appex
    -    com.other.ext(2.0)\t9F9F\t2025-01-01 10:00:00 +0000\t/Applications/Other.app/Contents/PlugIns/Other.appex

    """
    let urls = BrowserExtensionsScanner.parsePluginkit(out)
    #expect(urls.map(\.lastPathComponent) == ["Acme Blocker.appex", "Other.appex"])
}

@Test func chromiumPicksNewestVersionFolder() async throws {
    try await withTempDirAsync { home in
        let ext = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Extensions/abc")
        for (folder, name) in [("1.9_0", "Old"), ("1.10_0", "New")] {
            let dir = ext.appendingPathComponent(folder)
            try makeFile(dir.appendingPathComponent("manifest.json"))
            try #"{"name":"\#(name)"}"#.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        let items = try await BrowserExtensionsScanner(home: home, safariLister: { [] }).scan()
        #expect(items.map(\.title) == ["New"])
    }
}
