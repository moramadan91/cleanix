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

/// Owns a clean independently of its view, so navigating away doesn't interrupt file operations.
@MainActor
@Observable
final class CleaningRun {
    private static let minimumDuration = 2.5
    let started = Date.now
    private let deadline = ContinuousClock.now + .seconds(minimumDuration)
    private(set) var itemName: String
    private var measuredProgress: Double?
    private var progressFloor = 0.0
    private var finished = false

    init(firstItem: String = "") { itemName = firstItem }

    convenience init(items: [ScanItem]) {
        self.init(firstItem: items.first.map { $0.title ?? $0.url.lastPathComponent } ?? "")
    }

    func clean(_ items: [ScanItem], using cleaner: Cleaner, disposal: Disposal) async -> CleanResult {
        await perform { progress in await cleaner.clean(items, disposal: disposal, progress: progress) }
    }

    func perform<Result: Sendable>(
        _ operation: @escaping @Sendable (@escaping CleanProgress) async -> Result
    ) async -> Result {
        let result = await Task.detached(priority: .userInitiated) {
            await operation { name, fraction in await self.report(name, fraction: fraction) }
        }.value
        measuredProgress = 1
        try? await ContinuousClock().sleep(until: deadline)
        finished = true
        try? await Task.sleep(for: .milliseconds(180))
        return result
    }

    private func report(_ name: String, fraction: Double?) {
        itemName = name
        if let fraction { progressFloor = max(progressFloor, fraction) }
        measuredProgress = fraction
    }

    func progress(at date: Date, reduceMotion: Bool) -> Double {
        if finished { return 1 }
        if reduceMotion { return min(0.99, progressFloor) }
        let elapsed = max(0, date.timeIntervalSince(started))
        let paced = min(1, elapsed / Self.minimumDuration)
        let estimated = 0.9 * (1 - exp(-elapsed / 2))
        return min(0.99, max(progressFloor, measuredProgress ?? estimated) * paced)
    }
}

struct CleaningView: View {
    let run: CleaningRun
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.screenIsVisible) private var isVisible
    @Environment(\.sectionTint) private var tint

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isVisible)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(run.started))
            let sweep = reduceMotion ? 0 : elapsed
            let progress = run.progress(at: context.date, reduceMotion: reduceMotion)
            let size: CGFloat = compact ? 50 : 170
            VStack(spacing: compact ? 7 : 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.15)).depthGlass(Circle(), lift: compact ? 0.4 : 1)
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .rotationEffect(.degrees(sin(sweep * 6) * 28), anchor: .topTrailing)
                    if !reduceMotion {
                        ForEach(0..<4) { index in
                            let age = (sweep * 1.4 + Double(index) / 4).truncatingRemainder(dividingBy: 1)
                            Circle().fill(tint)
                                .frame(width: size * 0.045, height: size * 0.045)
                                .offset(x: size * (-0.12 - age * 0.32), y: size * (0.19 - age * 0.18))
                                .opacity((1 - age) * 0.8)
                        }
                    }
                }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
                Text(L("common.cleaning")).font(.system(size: compact ? 14 : 20, weight: .semibold))
                Text(run.itemName)
                    .font(.system(size: compact ? 11 : 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
                GeometryReader { geometry in
                    Capsule().fill(.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: geometry.size.width * progress)
                        }
                }
                .frame(height: 5)
                .frame(maxWidth: compact ? 240 : 280)
                .accessibilityRepresentation {
                    ProgressView(value: progress) { Text(L("common.cleaning")) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .preference(key: ScreenCleaningPreference.self, value: true)
    }
}

struct CompletionCheckmark: View {
    var size: CGFloat = 96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var circle = 0.0
    @State private var check = 0.0
    @State private var popped = false

    var body: some View {
        ZStack {
            Color.clear.depthGlass(Circle(), lift: 1.4)
            Circle().inset(by: 4)
                .trim(from: 0, to: reduceMotion ? 1 : circle)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Path { path in
                path.move(to: CGPoint(x: size * 0.29, y: size * 0.51))
                path.addLine(to: CGPoint(x: size * 0.44, y: size * 0.66))
                path.addLine(to: CGPoint(x: size * 0.72, y: size * 0.37))
            }
            .trim(from: 0, to: reduceMotion ? 1 : check)
            .stroke(.linearGradient(colors: [.white, .white.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .scaleEffect(reduceMotion || popped ? 1 : 0.88)
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.32)) { circle = 1 }
            try? await Task.sleep(for: .milliseconds(270))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.29)) { check = 1 }
            try? await Task.sleep(for: .milliseconds(290))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.55)) { popped = true }
        }
    }
}

struct CompletionTitle<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .opacity(reduceMotion || visible ? 1 : 0)
            .accessibilityHidden(!reduceMotion && !visible)
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { visible = true }
            }
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
            CompletionCheckmark()
            CompletionTitle {
                Text(String(format: L("common.cleaned"), formatBytes(result.freedBytes)))
                    .font(.system(size: 28, weight: .bold))
            }
            if undoable { Text(L("preview.undo")).foregroundStyle(.secondary) }
            if !result.failed.isEmpty {
                Text(String(format: L("common.failedCount"), result.failed.count)).foregroundStyle(Theme.accent)
            }
            // Two same-size circles, apart: red goes back, green scans again (same on every screen).
            HStack(spacing: 44) {
                if let onUndo { RoundActionButton(title: L("common.undo"), size: 92, tint: Color(hex: 0xFF4D5E), action: onUndo) }
                RoundActionButton(title: L("common.rescan"), size: 92, tint: Color(hex: 0x2FD1A0), action: onRescan)
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
            .depthGlass(Capsule(), lift: small ? 0.3 : prominent ? 1 : 0.6)
            .contentShape(Capsule())
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
            .depthGlass(Capsule(), lift: 0.3)
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
        RoundActionButton(title: title, action: action).disabled(disabled)
    }
}

/// The one main action of a screen: a round glass button with a static ring in the section's colour.
struct RoundActionButton: View {
    let title: String
    var size: CGFloat = 112
    /// Overrides the section colour (red Undo, green Scan again).
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(title, action: action).buttonStyle(RoundGlassStyle(size: size, fixedTint: tint))
    }
}

private struct RoundGlassStyle: ButtonStyle {
    let size: CGFloat
    var fixedTint: Color?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.sectionTint) private var sectionTint

    func makeBody(configuration: Configuration) -> some View {
        let tint = fixedTint ?? sectionTint
        return configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .padding(14)
            .frame(width: size, height: size)
            .depthGlass(Circle(), lift: 1.4)
            // A fixed colour (red/green) fills the glass too, so it reads on any section background.
            .background(Circle().fill(tint.opacity(fixedTint == nil ? 0 : 0.55)))
            .contentShape(Circle())
            .background(Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1.5).frame(width: size + 22, height: size + 22))
            .background(Circle().fill(tint.opacity(0.30)).frame(width: size + 30, height: size + 30).blur(radius: 18))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .padding(.vertical, 11)
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
        (#"^(\d+) items$"#, "reason.fmt.items"),
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

/// Clear glass that reads as 3D: lit rim on top, soft shadow under it. Static, so it costs no idle CPU.
struct DepthGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var lift: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .glassEffect(.clear, in: shape)
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.25), radius: 10 * lift, y: 6 * lift)
    }
}

extension View {
    func depthGlass<S: InsettableShape>(_ shape: S, lift: CGFloat = 1) -> some View {
        modifier(DepthGlass(shape: shape, lift: lift))
    }
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
            .depthGlass(RoundedRectangle(cornerRadius: 22))
            .frame(maxWidth: 760)
    }
}

extension View {
    func glassPanel() -> some View { modifier(GlassPanel()) }
}

/// List row background. Long lists use a light fill with a lit rim (no per-row glass, so scrolling
/// stays smooth); short lists pass `glass` for real depth glass.
struct RowBackground: ViewModifier {
    var highlighted = false
    var glass = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        let padded = content.padding(.horizontal, 14).padding(.vertical, 7)
        if glass {
            padded
                .background(shape.fill(.white.opacity(highlighted ? 0.10 : 0)))
                .depthGlass(shape, lift: 0.4)
        } else {
            padded
                .background(shape.fill(LinearGradient(colors: [.white.opacity(highlighted ? 0.16 : 0.07), .white.opacity(highlighted ? 0.09 : 0.025)],
                                                      startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }
}

/// Path shown with the home folder as "~".
func displayPath(_ url: URL) -> String {
    url.path(percentEncoded: false).replacingOccurrences(of: AppEnv.shared.home.path, with: "~")
}

/// Localized name of a scanner group ("Logs", "Developer"...), or the raw name if it has none.
func groupTitle(_ group: String) -> String { localized("group", group) }
