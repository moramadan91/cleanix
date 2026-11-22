import Foundation
import Testing
@testable import NaddafCore

@Test func comparesNumericAppVersions() {
    #expect(compareVersions("1.2", "1.2.0") == .orderedSame)
    #expect(compareVersions("1.10", "1.9") == .orderedDescending)
    #expect(compareVersions("1.02.000", "1.2") == .orderedSame)
    #expect(compareVersions("1.2 (300)", "1.2 400") == .orderedSame)
    #expect(compareVersions(" 1.2(300) ", "1.2") == .orderedSame)
    #expect(compareVersions("2.0b1", "2.0") == .orderedAscending)
    #expect(compareVersions("2.0", "2.0b1") == .orderedDescending)
    #expect(compareVersions("2.0b10", "2.0b9") == .orderedDescending)
}

@Test func appcastUsesNewestShortVersionFromAttributesAndElements() {
    let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item><enclosure sparkle:shortVersionString="1.10" sparkle:version="999"/></item>
            <item><sparkle:version>1001</sparkle:version></item>
            <item><sparkle:shortVersionString>
              1.9
            </sparkle:shortVersionString><sparkle:version>1000</sparkle:version></item>
          </channel>
        </rss>
        """
    #expect(UpdateChecker.appcastVersion(in: Data(xml.utf8)) == "1.10")

    let elementIsNewer = xml.replacingOccurrences(of: "1.9", with: "1.11")
    #expect(UpdateChecker.appcastVersion(in: Data(elementIsNewer.utf8)) == "1.11")
}

@Test func appcastFallsBackToBuildVersion() {
    let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item><sparkle:version>10</sparkle:version></item>
            <item><enclosure sparkle:version="11"/></item>
          </channel>
        </rss>
        """
    #expect(UpdateChecker.appcastVersion(in: Data(xml.utf8)) == "11")
    #expect(UpdateChecker.appcastVersion(in: Data("<rss/>".utf8)) == nil)
}

@Test func appStoreLookupParsesFirstResult() throws {
    let json = """
        {"results":[{"version":"2.0","trackViewUrl":"https://apps.apple.com/app/id123"},{"trackName":"Other"}]}
        """
    let result = try #require(UpdateChecker.storeResult(in: Data(json.utf8)))
    #expect(result.version == "2.0")
    #expect(result.storeURL?.absoluteString == "https://apps.apple.com/app/id123")
    #expect(UpdateChecker.storeResult(in: Data(#"{"results":[]}"#.utf8)) == nil)
}

@Test func updateCheckerUsesFakeFeedsAndReturnsOnlyNewerVersions() async throws {
    try await withTempDirAsync { dir in
        let spark = "https://updates.example.test/spark"
        let current = "https://updates.example.test/current"
        let failure = "https://updates.example.test/fail"
        try makeVersionedApp(in: dir, name: "Spark", installed: "1.9", feed: spark)
        try makeVersionedApp(in: dir, name: "Current", installed: "1.2.0", feed: current)
        try makeVersionedApp(in: dir, name: "Offline", installed: "1.0", feed: failure)
        try makeVersionedApp(in: dir, name: "Insecure", installed: "1.0", feed: "http://updates.example.test/spark")
        try makeVersionedApp(in: dir, name: "NoFeed", installed: "1.0")
        try makeApp(in: dir, name: "NoVersion", bundleID: "com.acme.noversion")
        let store = try makeVersionedApp(in: dir, name: "Store", installed: "2.0b1")
        try makeFile(store.appendingPathComponent("Contents/_MASReceipt/receipt"))

        let requests = FakeUpdateRequests()
        let checker = UpdateChecker { url in
            await requests.record(url)
            switch url.absoluteString {
            case spark:
                return appcast(with: "1.10")
            case current:
                return appcast(with: "1.2")
            case "https://itunes.apple.com/lookup?bundleId=com.acme.store":
                return Data(#"{"results":[{"version":"2.0","trackViewUrl":"https://apps.apple.com/app/id123"}]}"#.utf8)
            default:
                throw URLError(.cannotConnectToHost)
            }
        }

        let apps = await RemoverScanner(appDirs: [dir], home: dir).apps()
        let updates = await checker.check(apps)
        #expect(updates.map(\.app.name) == ["Spark", "Store"])
        #expect(updates.map(\.installed) == ["1.9", "2.0b1"])
        #expect(updates.map(\.latest) == ["1.10", "2.0"])
        #expect(updates.first?.storeURL == nil)
        #expect(updates.last?.storeURL?.absoluteString == "https://apps.apple.com/app/id123")
        #expect(await requests.urls.sorted() == [spark, current, failure,
                                                 "https://itunes.apple.com/lookup?bundleId=com.acme.store"].sorted())
    }
}

@discardableResult
private func makeVersionedApp(in dir: URL, name: String, installed: String, feed: String? = nil) throws -> URL {
    let bundle = try makeApp(in: dir, name: name, bundleID: "com.acme.\(name.lowercased())")
    let url = bundle.appendingPathComponent("Contents/Info.plist")
    let data = try Data(contentsOf: url)
    var plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    plist["CFBundleShortVersionString"] = installed
    plist["SUFeedURL"] = feed
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    return bundle
}

private func appcast(with version: String) -> Data {
    Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item><enclosure sparkle:shortVersionString="\(version)"/></item></channel>
        </rss>
        """.utf8)
}

private actor FakeUpdateRequests {
    private(set) var urls: [String] = []

    func record(_ url: URL) { urls.append(url.absoluteString) }
}
