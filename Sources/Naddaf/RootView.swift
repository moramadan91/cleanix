import SwiftUI
import AppKit
import NaddafCore

struct RootView: View {
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
                Sidebar(selection: $selection)
                    .zIndex(1) // the hover pill must draw above the page, not under it
                VStack(spacing: 0) {
                    if !hasDiskAccess { DiskAccessBanner().padding(.top, 12) }
                    SectionPage(section: selection)
                }
            }
        }
        // Language switch at the physical top-right in both languages (leading is the right edge in Arabic),
        // opposite the window buttons.
        .overlay(alignment: lang == "ar" ? .topLeading : .topTrailing) {
            Button(lang == "ar" ? "English" : "العربية") { lang = lang == "ar" ? "en" : "ar" }
                .padding(.top, 12).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lang == "ar" ? .topLeading : .topTrailing)
                .ignoresSafeArea() // up into the title-bar row, level with the window buttons
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

private struct Sidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        // Nine icons must fit any window height: 9 items + 8 gaps + room for the traffic lights.
        GeometryReader { geo in
            let gap: CGFloat = 10
            let size = max(40, min(62, (geo.size.height - 44 - 16 - gap * 8) / 9))
            GlassEffectContainer(spacing: gap) {
                VStack(spacing: gap) {
                    ForEach(AppSection.allCases) { section in
                        SidebarItem(section: section, isSelected: selection == section, size: size) { selection = section }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 44)
        }
        .frame(width: 98)
    }
}

/// Icon button that grows into a glass pill showing the full name while the pointer is over it.
private struct SidebarItem: View {
    let section: AppSection
    let isSelected: Bool
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    private var glass: Glass {
        // Untinted: the disc takes the colour behind it. Selected is frosted so it still stands out.
        isSelected ? .regular.tint(.white.opacity(0.28)) : .clear
    }

    var body: some View {
        // The glass circle never changes size (resizing glass every frame is what made the pill stutter).
        // The pill is a plain capsule fill that grows behind it, which the GPU animates cheaply.
        Button(action: action) {
            HStack(spacing: 6) {
                // Glass symbol on a glass disc tinted with the section hue; no hard shadows.
                Image(systemName: section.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.6)],
                                                    startPoint: .top, endPoint: .bottom))
                    .frame(width: size, height: size)
                    .glassEffect(glass, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(isSelected ? 0.7 : 0), lineWidth: 1.5))
                Text(section.title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(hovering ? 1 : 0)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(hovering || isSelected ? 1 : 0.92))
            .frame(width: hovering ? 240 : size, height: size, alignment: .leading)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .opacity(hovering ? 1 : 0)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.22), value: hovering)
        .frame(width: size, height: size, alignment: .leading)
        .zIndex(hovering ? 1 : 0)
        .accessibilityLabel(section.title)
    }
}

/// One page per section: title on top, the section's tabs (if any), then the screen.
private struct SectionPage: View {
    let section: AppSection
    @State private var tabs: [AppSection: SectionTab] = [:]

    var body: some View {
        // Title sits top-center, clear of the sidebar pills.
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(section.title)
                    .font(.system(size: 34, weight: .bold))
                Text(section.subtitle)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .multilineTextAlignment(.center)
            .padding(.top, 40)
            .id("text-\(section.id)")
            .transition(.opacity)

            let all = SectionTab.tabs(for: section)
            let current = tabs[section] ?? all.first
            if all.count > 1 {
                TabStrip(tabs: all, selection: Binding(get: { current ?? all[0] }, set: { tabs[section] = $0 }))
                    .padding(.top, 18)
            }
            SectionContent(section: section, tab: current)
                .id("\(section.id)-\(current?.rawValue ?? "")")
                // Short lists sit under the tabs; the title never drifts down with them.
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
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
        .glassEffect(.regular.tint(.white.opacity(0.04)), in: .capsule)
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
            Button(title, action: action)
                .buttonStyle(.liquid(prominent: true, big: true))
            .padding(.bottom, 34)
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
