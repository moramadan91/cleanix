import SwiftUI

struct RootView: View {
    @State var selection: AppSection = .smartScan

    var body: some View {
        ZStack {
            AuroraBackground(tint: selection.tint)
                .animation(.easeInOut(duration: 0.4), value: selection)
            HStack(spacing: 0) {
                Sidebar(selection: $selection)
                SectionPage(section: selection)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

private struct Sidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                ForEach(AppSection.allCases) { section in
                    Button { selection = section } label: {
                        Image(systemName: section.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(selection == section ? Theme.accent : .white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selection == section ? .regular.tint(Theme.accent.opacity(0.25)).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 14))
                    .help(section.title)
                    .accessibilityLabel(section.title)
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Placeholder page for each section; the real screens replace the body in later tasks.
private struct SectionPage: View {
    let section: AppSection

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 40) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(section.title)
                        .font(.system(size: 46, weight: .semibold))
                    Text(section.subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(section.features, id: \.self) { feature in
                            Label(feature, systemImage: "checkmark.circle")
                                .labelStyle(FeatureLabelStyle(tint: section.tint))
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SectionHero(section: section)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 48)
            .frame(maxHeight: .infinity)

            Button {} label: {
                Text(L("common.scan"))
                    .font(.title3.weight(.semibold))
                    .frame(width: 150, height: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .padding(.bottom, 36)
        }
    }
}

private struct FeatureLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.foregroundStyle(tint)
            configuration.title.font(.title3.weight(.medium))
        }
    }
}
