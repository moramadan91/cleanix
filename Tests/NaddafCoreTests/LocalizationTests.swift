import Foundation
import Testing

/// Checks the app's String Catalog: every key has Arabic and English, and every literal `L("...")`
/// key used in the app code exists.
struct LocalizationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalogURL = root.appendingPathComponent("Sources/Naddaf/Resources/Localizable.xcstrings")

    static func catalog() throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    @Test func everyKeyHasArabicAndEnglish() throws {
        let strings = try Self.catalog()
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            let locs = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for lang in ["ar", "en"] {
                let unit = (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                let state = unit?["state"] as? String ?? ""
                #expect(!value.isEmpty, "\(key) has no \(lang)")
                #expect(state == "translated", "\(key) \(lang) is \(state)")
            }
        }
    }

    @Test func everyLiteralKeyUsedInCodeExists() throws {
        let strings = try Self.catalog()
        let sources = Self.root.appendingPathComponent("Sources/Naddaf")
        let regex = try NSRegularExpression(pattern: #"\bL\("([^"\\]+)"\s*(?=[,)])"#)
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = (text as NSString).substring(with: match.range(at: 1))
                if strings[key] == nil { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        #expect(missing.isEmpty, "missing keys: \(missing)")
    }
}
