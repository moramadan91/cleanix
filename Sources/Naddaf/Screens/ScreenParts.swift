import SwiftUI
import AppKit
import NaddafCore

/// Spinner shown while a scan runs.
struct ScanningView: View {
    var text = L("common.scanning")

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(text).font(.system(size: 18, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Result of a clean: freed size, failures, Undo (quarantine only) and Scan again.
struct DoneView: View {
    let result: CleanResult
    var undoable = false
    var onUndo: (() -> Void)?
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                .frame(width: 96, height: 96)
                .glassEffect(.clear, in: .circle)
            Text(String(format: L("common.cleaned"), formatBytes(result.freedBytes)))
                .font(.system(size: 28, weight: .bold))
            if undoable { Text(L("preview.undo")).foregroundStyle(.secondary) }
            if !result.failed.isEmpty {
                Text(String(format: L("common.failedCount"), result.failed.count)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 12) {
                if let onUndo { Button(L("common.undo"), action: onUndo).buttonStyle(.liquid(big: true)) }
                Button(L("common.rescan"), action: onRescan).buttonStyle(.liquid(prominent: true, big: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Liquid-glass button used everywhere: a clear glass capsule, amber-tinted glass when prominent.
struct LiquidButtonStyle: ButtonStyle {
    var prominent = false
    var big = false
    /// Compact capsule for secondary bar actions (Select all, Start over).
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: big ? 17 : small ? 11 : 13, weight: big ? .bold : .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: big ? 150 : nil)
            .padding(.horizontal, big ? 30 : small ? 10 : 14)
            .padding(.vertical, big ? 12 : small ? 4 : 6)
            // Clear glass, no tint: the button takes the colour of whatever is behind it.
            // Not .interactive(): that glass runs its own press handling, which competed with the
            // Button for the click so some clicks were lost. The press scale below gives the feedback.
            .glassEffect(.clear, in: .capsule)
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(prominent ? 0.45 : 0.3), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Clear glass tick box: a frosted rounded square with a white tick, no system blue.
struct GlassCheckStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(configuration.isOn ? 0.3 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(configuration.isOn ? 0.6 : 0.3), lineWidth: 1))
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ToggleStyle where Self == GlassCheckStyle {
    static var glassCheck: GlassCheckStyle { GlassCheckStyle() }
}

/// Small clear-glass capsule label (e.g. "quit the app first").
struct GlassBadge: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .glassEffect(.clear, in: .capsule)
    }
}

/// Order of a file or app list; one choice shared by every list (remembered).
enum ListSort: String, CaseIterable, Identifiable {
    case largest, smallest, nameAZ, nameZA
    static let key = "listSort"
    var id: Self { self }
    var title: String { L("sort.\(rawValue)") }

    func sorted<T>(_ list: [T], name: (T) -> String, bytes: (T) -> Int64) -> [T] {
        switch self {
        case .largest: list.sorted { bytes($0) > bytes($1) }
        case .smallest: list.sorted { bytes($0) < bytes($1) }
        case .nameAZ: list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .nameZA: list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedDescending }
        }
    }
}

/// Small glass capsule that opens the sort choices.
struct SortMenu: View {
    @Binding var sort: ListSort

    var body: some View {
        Menu {
            Picker("", selection: $sort) {
                ForEach(ListSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(sort.title, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.liquid(small: true))
        .fixedSize()
    }
}

extension View {
    /// Search field drawn as a clear glass capsule (small, so it sits quietly beside a list).
    func glassField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 5)
            // Not glassEffect: a focused field's blinking caret made the glass re-render (~30% idle CPU).
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }
}

extension ButtonStyle where Self == LiquidButtonStyle {
    static func liquid(prominent: Bool = false, big: Bool = false, small: Bool = false) -> LiquidButtonStyle {
        LiquidButtonStyle(prominent: prominent, big: big, small: small)
    }
}

/// Main action at the bottom of a screen.
struct ActionButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.liquid(prominent: true, big: true))
            .disabled(disabled)
    }
}

/// Wraps any async item source as a `Scanner`, so screens can reuse `ScanListView`.
struct ClosureScanner: NaddafCore.Scanner {
    let run: @Sendable () async throws -> [ScanItem]
    func scan() async throws -> [ScanItem] { try await run() }
}

/// Catalog value for `<prefix>.<raw>`, or the raw text when the catalog has none.
func localized(_ prefix: String, _ raw: String) -> String {
    let key = "\(prefix).\(raw)"
    let value = L(key)
    if value != key { return value }
    guard prefix == "reason" else { return raw }
    // Browser reasons ("Chrome history") share their text with the group titles.
    let asGroup = L("group.\(raw)")
    if asGroup != "group.\(raw)" { return asGroup }
    // Reasons built with a name or number: "Left by Slack", "In Downloads for 90+ days"...
    let patterns: [(String, String)] = [
        (#"^In Downloads for (\d+)\+ days$"#, "reason.fmt.downloads"),
        (#"^Not modified for (\d+)\+ days$"#, "reason.fmt.notModified"),
        (#"^Duplicate of (.+)$"#, "reason.fmt.duplicate"),
        (#"^Left by (.+)$"#, "reason.fmt.leftBy"),
        (#"^In (.+)$"#, "reason.fmt.in"),
    ]
    for (pattern, fmt) in patterns {
        if let m = raw.firstMatch(of: try! Regex<(Substring, Substring)>(pattern)) {
            return String(format: L(fmt), String(m.1))
        }
    }
    return raw
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Layered glass panel that holds a list (lists never sit straight on the background).
struct GlassPanel: ViewModifier {
    /// Height of the list inside; the panel hugs it instead of stretching over empty space.
    @State private var contentHeight: CGFloat = .infinity

    func body(content: Content) -> some View {
        // Capped width and centred: keeps lists readable and clear of the sidebar's hover pills.
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, h in
                contentHeight = h
            }
            .frame(maxHeight: contentHeight)
            .padding(8)
            .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 22))
            .frame(maxWidth: 560)
    }
}

extension View {
    func glassPanel() -> some View { modifier(GlassPanel()) }
}

/// Glass-free list row background used by every list screen.
struct RowBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(highlighted ? 0.12 : 0.04)))
    }
}

/// Path shown with the home folder as "~".
func displayPath(_ url: URL) -> String {
    url.path(percentEncoded: false).replacingOccurrences(of: AppEnv.shared.home.path, with: "~")
}

/// Localized name of a scanner group ("Logs", "Developer"...), or the raw name if it has none.
func groupTitle(_ group: String) -> String { localized("group", group) }
