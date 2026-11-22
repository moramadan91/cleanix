import SwiftUI

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
        if hovering { return .regular.tint(section.tint.opacity(0.85)).interactive() }
        if isSelected { return .regular.tint(Theme.accent.opacity(0.32)).interactive() }
        return .regular.interactive()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: section.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .frame(width: size, height: size)
                if hovering {
                    Text(section.title)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(hovering ? Color.white : (isSelected ? Theme.accent : Color.white.opacity(0.92)))
            .frame(width: hovering ? 240 : size, height: size, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .capsule)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.18), value: hovering)
        .frame(width: size, height: size, alignment: .leading)
        .zIndex(hovering ? 1 : 0)
        .accessibilityLabel(section.title)
    }
}

/// Placeholder page for each section; the real screens replace the body in later tasks.
private struct SectionPage: View {
    let section: AppSection

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 22) {
                    Text(section.title)
                        .font(.system(size: 58, weight: .bold))
                    Text(section.subtitle)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white.opacity(0.75))
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(section.features, id: \.self) { feature in
                            Label(feature, systemImage: "checkmark")
                                .font(.system(size: 18, weight: .semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .glassEffect(.regular.tint(section.tint.opacity(0.30)), in: .capsule)
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("text-\(section.id)")
                .transition(.opacity)
                SectionHero(section: section)
                    .frame(maxWidth: .infinity)
                    .id("hero-\(section.id)")
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
            .padding(.horizontal, 40)
            .frame(maxHeight: .infinity)

            Button {} label: {
                Text(L("common.scan"))
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 220, height: 58)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .padding(.bottom, 34)
        }
    }
}
