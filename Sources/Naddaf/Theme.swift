import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Amber Dusk: dusk-violet base, amber accent for controls. Each section adds its own vivid pair of hues
/// to the background only; buttons and selection stay amber.
enum Theme {
    static let bg = Color(hex: 0x14101C)
    static let accent = Color(hex: 0xFFB04A)
    static let rose = Color(hex: 0xFF6B8A)
}

/// Looks a string up in the app's own resource bundle (Arabic and English).
/// The app's own language, switchable inside the app (stored in UserDefaults); defaults to the system's.
enum Lang {
    static let key = "naddaf.lang"
    static var current: String {
        UserDefaults.standard.string(forKey: key)
            ?? (Bundle.module.preferredLocalizations.first == "ar" ? "ar" : "en")
    }
    static var isArabic: Bool { current == "ar" }
    static var direction: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }
    static var locale: Locale { Locale(identifier: current) }
    /// The ar.lproj / en.lproj inside the resource bundle (Foundation caches Bundle instances).
    static func bundle(for language: String) -> Bundle {
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
    }
}

func L(_ key: String, language: String = Lang.current) -> String {
    Lang.bundle(for: language).localizedString(forKey: key, value: nil, table: "Localizable")
}

/// Which built-in SF Symbols effect a section's icon plays.
enum SymbolMotion { case wiggle, bounce, pulse, variable }

enum AppSection: String, CaseIterable, Identifiable {
    case overview, smartScan, cleanup, protection, performance, apps, clutter, diskMap, cloud

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.medium"
        case .smartScan: "sparkles"
        case .cleanup: "trash"
        case .protection: "hand.raised"
        case .performance: "bolt"
        case .apps: "square.grid.2x2"
        case .clutter: "folder"
        case .diskMap: "chart.pie"
        case .cloud: "icloud"
        }
    }

    var motion: SymbolMotion {
        switch self {
        case .overview, .smartScan: .variable
        case .cleanup, .apps, .cloud: .bounce
        case .protection, .clutter: .wiggle
        case .performance, .diskMap: .pulse
        }
    }

    /// Main hue of the section (top of the background, glass tint).
    var tint: Color {
        switch self {
        case .overview: Color(hex: 0x7C5CFF)
        case .smartScan: Color(hex: 0xFFAA3D)
        case .cleanup: Color(hex: 0x2FD1A0)
        case .protection: Color(hex: 0xFF5C8A)
        case .performance: Color(hex: 0x9BD12E)
        case .apps: Color(hex: 0x4C8DFF)
        case .clutter: Color(hex: 0x1FC8D6)
        case .diskMap: Color(hex: 0xF5C542)
        case .cloud: Color(hex: 0x5AB8FF)
        }
    }

    /// Deeper second hue (bottom glow).
    var tint2: Color {
        switch self {
        case .overview: Color(hex: 0x3B2A8F)
        case .smartScan: Color(hex: 0xFF5A3D)
        case .cleanup: Color(hex: 0x0E7C6B)
        case .protection: Color(hex: 0x8E1F5E)
        case .performance: Color(hex: 0x2F6B12)
        case .apps: Color(hex: 0x2230A8)
        case .clutter: Color(hex: 0x0D6B80)
        case .diskMap: Color(hex: 0x6E4A0C)
        case .cloud: Color(hex: 0x1E5FB5)
        }
    }

    var title: String { L("section.\(rawValue).title") }
    var subtitle: String { L("section.\(rawValue).subtitle") }

    var features: [String] {
        (1...4).compactMap { i in
            let key = "section.\(rawValue).f\(i)"
            let value = L(key)
            return value == key ? nil : value
        }
    }
}
