import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Amber Dusk: dusk-violet base, amber accent for controls, rose only as a soft glow in the background.
enum Theme {
    static let bg = Color(hex: 0x14101C)
    static let accent = Color(hex: 0xFFB04A)
    static let rose = Color(hex: 0xFF6B8A)
}

/// Looks a string up in the app's own resource bundle (Arabic and English).
func L(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .module)
}

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

    /// Low-saturation tint per section, derived from the dusk family. Used for the background only.
    var tint: Color {
        switch self {
        case .overview: Color(hex: 0x8E7CC3)
        case .smartScan: Color(hex: 0xE09F45)
        case .cleanup: Color(hex: 0x6FB59B)
        case .protection: Color(hex: 0xC77D9B)
        case .performance: Color(hex: 0xD99058)
        case .apps: Color(hex: 0x7C9BD1)
        case .clutter: Color(hex: 0x5FB0B7)
        case .diskMap: Color(hex: 0x9A8FD6)
        case .cloud: Color(hex: 0x6FA3D9)
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
