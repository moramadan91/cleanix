import SwiftUI

/// Fully static gradient: it only changes (with a short fade) when the section changes.
/// A continuously drifting glow was measured at about 3.9% idle CPU, because SwiftUI redraws
/// every frame for it, so it was removed to keep the app light.
struct AuroraBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            Theme.bg
            LinearGradient(colors: [tint.opacity(0.34), .clear], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.rose.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

/// Glass is used on small elements only, never full-screen.
struct GlassCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Big section icon made of layers: no live 3D, nothing animated.
struct SectionHero: View {
    let section: AppSection

    var body: some View {
        ZStack {
            Circle().fill(section.tint.opacity(0.16)).frame(width: 300, height: 300)
            Circle().fill(section.tint.opacity(0.22)).frame(width: 220, height: 220)
            Image(systemName: section.symbol)
                .font(.system(size: 84, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 170, height: 170)
                .glassEffect(.regular.tint(section.tint.opacity(0.35)), in: .circle)
        }
        .accessibilityHidden(true)
    }
}
