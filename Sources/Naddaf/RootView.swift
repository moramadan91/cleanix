import SwiftUI
import AppKit
import NaddafCore

struct RootView: View {
    /// Sparkle's check: shows the new version if there is one, or says the app is up to date.
    var checkForUpdates: () -> Void = {}
    @State var selection: AppSection = .smartScan
    @State private var hasDiskAccess = RootView.checkDiskAccess()
    /// Changing it rebuilds the whole tree (`.id`), so every L() string and the direction flip at once.
    @AppStorage(Lang.key) private var lang = Lang.current

    private static func checkDiskAccess() -> Bool {
        DiskAccess.granted(probe: DiskAccess.probe(home: AppEnv.shared.home))
    }

    var body: some View {
        ZStack {
            AuroraBackground(section: selection)
            HStack(spacing: 0) {
                Sidebar(selection: $selection, lang: $lang, checkForUpdates: checkForUpdates)
                VStack(spacing: 0) {
                    if !hasDiskAccess { DiskAccessBanner().padding(.top, 12) }
                    SectionPage(section: selection)
                }
            }
        }
        .id(lang)
        // Coming back from System Settings: check again so the banner goes away by itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasDiskAccess = RootView.checkDiskAccess()
        }
        // The window itself stays left-to-right, so mirror the layout by hand for Arabic:
        // sidebar on the right, text right-aligned.
        // Every button without its own style is liquid glass.
        .buttonStyle(.liquid())
        .environment(\.layoutDirection, Lang.direction)
        .animation(.spring(duration: 0.5, bounce: 0.2), value: selection)
        .frame(minWidth: 1060, minHeight: 680)
    }
}

/// Labelled sidebar as in the Windows version: logo and name on top, one row per section with its
/// coloured icon, language and updates at the bottom, and a thin line between it and the page.
private struct Sidebar: View {
    @Binding var selection: AppSection
    @Binding var lang: String
    let checkForUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let mark = Self.mark { Image(nsImage: mark).resizable().frame(width: 28, height: 28) }
                Text("Cleanix").font(.system(size: 17, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.bottom, 18)
            ForEach(AppSection.allCases) { section in
                SidebarItem(section: section, isSelected: selection == section) { selection = section }
            }
            Spacer(minLength: 12)
            Button(action: checkForUpdates) {
                Label(L("update.check"), systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.liquid(small: true))
            Button { lang = lang == "ar" ? "en" : "ar" } label: {
                Text(lang == "ar" ? "English" : "العربية").frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 44) // clear of the window buttons
        .padding(.bottom, 18)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color(hex: 0x0A0810).opacity(0.35))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
        .ignoresSafeArea()
    }

    private static let mark: NSImage? = {
        (Bundle.module.url(forResource: "mark", withExtension: "png")
            ?? Bundle.module.url(forResource: "mark", withExtension: "png", subdirectory: "Brand"))
            .flatMap(NSImage.init(contentsOf:))
    }()
}

private struct SidebarItem: View {
    let section: AppSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(section.tint)
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(isSelected || hovering ? 1 : 0.62))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(isSelected ? 0.10 : hovering ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension EnvironmentValues {
    /// A screen calls this when its scan starts, so the page can offer Start over.
    @Entry var screenStarted: @MainActor @Sendable () -> Void = {}
    /// Colour of the current section, for the ring around the round main button.
    @Entry var sectionTint: Color = .white
}

/// One screen: a section, plus its tab when the section has tabs.
private struct ScreenKey: Hashable {
    let section: AppSection
    let tab: SectionTab?
}

/// One page per section: title on top, the section's tabs (if any), then the screen.
/// Every screen you open stays alive behind the current one, so a scan keeps running while you
/// look elsewhere and you come back to where you left it. Start over rebuilds that one screen.
private struct SectionPage: View {
    let section: AppSection
    @State private var tabs: [AppSection: SectionTab] = [:]
    @State private var visited: [ScreenKey] = []
    @State private var started: Set<ScreenKey> = []
    @State private var generation: [ScreenKey: Int] = [:]

    var body: some View {
        // Title sits top-center, clear of the sidebar pills.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.system(size: 28, weight: .bold))
                Text(section.subtitle)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(.top, 26)
            .padding(.horizontal, 40)
            .id("text-\(section.id)")
            .transition(.opacity)

            let all = SectionTab.tabs(for: section)
            let current = tabs[section] ?? all.first
            if all.count > 1 {
                TabStrip(tabs: all, selection: Binding(get: { current ?? all[0] }, set: { tabs[section] = $0 }))
                    .padding(.top, 14)
                    .padding(.horizontal, 40)
            }
            let now = ScreenKey(section: section, tab: current)
            ZStack {
                ForEach(visited.contains(now) ? visited : visited + [now], id: \.self) { key in
                    SectionContent(section: key.section, tab: key.tab)
                        .id(generation[key, default: 0])
                        .environment(\.screenStarted) { started.insert(key) }
                        .environment(\.sectionTint, key.section.tint)
                        // Short lists sit under the tabs; the title never drifts down with them.
                        .frame(maxHeight: .infinity, alignment: .top)
                        .opacity(key == now ? 1 : 0)
                        .allowsHitTesting(key == now)
                        .accessibilityHidden(key != now)
                }
            }
            .onChange(of: now, initial: true) { if !visited.contains(now) { visited.append(now) } }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            let now = ScreenKey(section: section, tab: tabs[section] ?? SectionTab.tabs(for: section).first)
            if started.contains(now) {
                Button(L("common.startOver")) {
                    generation[now, default: 0] += 1
                    started.remove(now)
                }
                .buttonStyle(.liquid(small: true))
                .padding(.top, 34).padding(.horizontal, 40)
            }
        }
    }
}

private struct TabStrip: View {
    let tabs: [SectionTab]
    @Binding var selection: SectionTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(selection == tab ? Color.white : Color.white.opacity(0.75))
                        .glassEffect(selection == tab ? .clear : .identity, in: .capsule)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .depthGlass(Capsule(), lift: 0.6)
    }
}

/// Section intro: hero in the middle (shrinks to fit short windows) and the main button at the bottom.
struct IntroHero: View {
    let section: AppSection
    var title = L("common.scan")
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                SectionHero(section: section)
                    .scaleEffect(min(1, geo.size.height / 470))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .id("hero-\(section.id)")
            .transition(.scale(scale: 0.86).combined(with: .opacity))
            RoundActionButton(title: title, action: action)
                .padding(.bottom, 30)
        }
    }
}

/// Shown until the app has Full Disk Access; without it Trash, Mail and app data read as empty.
private struct DiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 16, weight: .semibold))
            Text(L("access.banner")).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Button(L("access.open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .glassEffect(.clear, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .frame(maxWidth: 640)
    }
}
