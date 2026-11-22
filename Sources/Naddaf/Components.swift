import SwiftUI

/// Static, rich gradient per section. It never animates by itself, only crossfades when the
/// section changes: a continuously moving background measured 3.9% idle CPU, so it stays still.
struct AuroraBackground: View {
    let section: AppSection
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        ZStack {
            Theme.bg
            LinearGradient(colors: [section.tint.opacity(0.78), section.tint2.opacity(0.40), .clear],
                           startPoint: .topLeading, endPoint: .bottom)
            RadialGradient(colors: [section.tint2.opacity(0.65), .clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 760)
            // Soft spotlight behind the hero icon (the hero sits at the trailing side).
            RadialGradient(colors: [.white.opacity(0.13), .clear],
                           center: UnitPoint(x: direction == .rightToLeft ? 0.25 : 0.75, y: 0.45),
                           startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
        .id(section)
        .transition(.opacity)
    }
}

/// Large layered hero: glow, rings, glass satellites and a glass orb holding the section symbol.
/// The symbol plays a built-in SF Symbols effect every couple of seconds. That runs outside the
/// app's own render loop, and stops when the window is inactive or Reduce Motion is on.
struct SectionHero: View {
    let section: AppSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var tick = 0

    private var live: Bool { scenePhase == .active && !reduceMotion }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [section.tint2.opacity(0.60), .clear], center: .center,
                                     startRadius: 30, endRadius: 270))
                .frame(width: 540, height: 540)
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1).frame(width: 420, height: 420)
            Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1).frame(width: 340, height: 340)
            satellite(size: 36, x: 150, y: -178)
            satellite(size: 20, x: -196, y: 96)
            satellite(size: 28, x: 176, y: 150)
            icon
        }
        .frame(width: 460, height: 460)
        .accessibilityHidden(true)
    }

    private func satellite(size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(section.tint.opacity(0.55)), in: .circle)
            .offset(x: x, y: y)
    }

    /// The glass orb and its glow are separate, static layers. Only the bare symbol animates on top,
    /// so the glass is not re-rendered every frame (that made idle CPU about 21%).
    private var icon: some View {
        ZStack {
            Circle()
                .fill(section.tint2.opacity(0.55))
                .frame(width: 250, height: 250)
                .blur(radius: 30)
            Color.clear
                .frame(width: 250, height: 250)
                .glassEffect(.regular.tint(section.tint.opacity(0.55)), in: .circle)
            Image(systemName: section.symbol)
                .font(.system(size: 116, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.wiggle, options: .nonRepeating, value: section.motion == .wiggle ? tick : -1)
                .symbolEffect(.bounce, options: .nonRepeating, value: section.motion == .bounce ? tick : -1)
                .symbolEffect(.pulse, options: .nonRepeating, value: section.motion == .pulse ? tick : -1)
                .symbolEffect(.variableColor.iterative, options: .nonRepeating, value: section.motion == .variable ? tick : -1)
        }
        .onHover { if $0 && live { tick += 1 } }
        .task(id: section) { if live { tick += 1 } }
        // The symbol plays once when a section opens and once on hover, then stays still.
        // A looping effect cost about 20% idle CPU; a one-shot every 9 seconds still averaged about 4%.
    }
}
