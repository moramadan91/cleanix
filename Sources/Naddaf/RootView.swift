import SwiftUI
import NaddafCore

struct RootView: View {
    @State var selection: AppSection = .smartScan

    var body: some View {
        ZStack {
            AuroraBackground(section: selection)
            HStack(spacing: 0) {
                Sidebar(selection: $selection)
                    .zIndex(1) // the hover pill must draw above the page, not under it
                SectionPage(section: selection)
            }
        }
        // The window itself stays left-to-right (the app bundle has no ar.lproj), so mirror the layout
        // by hand whenever the strings resolved to Arabic: sidebar on the right, text right-aligned.
        .environment(\.layoutDirection, Bundle.module.preferredLocalizations.first == "ar" ? .rightToLeft : .leftToRight)
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
        isSelected ? .regular.tint(Theme.accent.opacity(0.45)) : .regular.tint(section.tint.opacity(0.22))
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
                Text(section.title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(hovering ? 1 : 0)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.white : (isSelected ? Theme.accent : Color.white.opacity(0.92)))
            .frame(width: hovering ? 240 : size, height: size, alignment: .leading)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [section.tint, section.tint2], startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
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

/// Placeholder page for each section; the real screens replace the body in later tasks.
private struct SectionPage: View {
    let section: AppSection

    var body: some View {
        // Title sits top-center, clear of the sidebar pills; the hero fills the middle.
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

            if section == .cleanup {
                TabStrip(selection: $cleanupTab).padding(.top, 18)
                switch cleanupTab {
                case .appCaches: AppCachesView(section: section)
                case .sweep:
                    ScanListView(section: section, mode: .clean(.quarantine)) { SweepScanner(home: env.home) }
                        .id(CleanupTab.sweep)
                case .trash:
                    ScanListView(section: section, mode: .emptyTrash) {
                        TrashScanner(trashRoots: [env.home.appendingPathComponent(".Trash")])
                    }
                    .id(CleanupTab.trash)
                case .mail:
                    ScanListView(section: section, mode: .clean(.trash)) {
                        let lib = env.home.appendingPathComponent("Library")
                        return MailAttachmentsScanner(mailDownloads: [
                            lib.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads"),
                            lib.appendingPathComponent("Mail Downloads")])
                    }
                    .id(CleanupTab.mail)
                case .shredder: ShredderView()
                }
            } else {
                IntroHero(section: section, soon: true) {}
            }
        }
        .frame(maxWidth: .infinity)
    }

    @State private var cleanupTab = CleanupTab.appCaches
    private var env: AppEnv { .shared }
}

enum CleanupTab: String, CaseIterable, Identifiable {
    case sweep, appCaches, trash, mail, shredder
    var id: String { rawValue }
    var title: String { L("cleanup.tab.\(rawValue)") }
}

private struct TabStrip: View {
    @Binding var selection: CleanupTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CleanupTab.allCases) { tab in
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(selection == tab ? Color.black : Color.white.opacity(0.85))
                        .background(Capsule().fill(selection == tab ? Theme.accent : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Section intro: big hero in the middle and the Scan button at the bottom.
struct IntroHero: View {
    let section: AppSection
    var soon = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            SectionHero(section: section)
                .id("hero-\(section.id)")
                .transition(.scale(scale: 0.86).combined(with: .opacity))
            Spacer(minLength: 0)
            if soon { Text(L("common.soon")).font(.callout).foregroundStyle(.secondary).padding(.bottom, 10) }
            Button(action: action) {
                Text(L("common.scan"))
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 220, height: 58)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(soon)
            .padding(.bottom, 34)
        }
    }
}
